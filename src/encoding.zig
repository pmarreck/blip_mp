// BLIP integer encoding (per BLIP_SPEC_CONCISE.md, treated as a stable standard).
//
// IMMEDIATE       0_xxxxxxx                                value 0..127, single byte
// LENGTH-PREFIXED 1_E_C_LLLLL [continuation...] [payload]   value >= 128
//   E = endianness of payload (0=LE, 1=BE)
//   C = continuation flag (1 means more L bits follow as varint)
//   For tier 0/1 (L <= 8), continuation never fires.
//
// SENTINELS: an L=1, E=0 encoding whose payload byte < 0x80 is overlong
// and is reserved (TRUE/FALSE/NIL/application sentinels).
// Encoders MUST emit canonical (shortest) form for real values.

const std = @import("std");

pub const Endian = enum(u1) {
	little = 0,
	big = 1,
};

/// Returns the minimum number of payload bytes needed to represent `value`
/// as an unsigned little-endian integer. For value 0 returns 0 (encodes as
/// the immediate byte 0x00, no payload).
pub fn minPayloadBytes(value: u64) usize {
	if (value == 0) return 0;
	const bits = 64 - @clz(value);
	return (bits + 7) / 8;
}

/// Returns the number of bytes that encodeU64(value) would produce.
/// Includes the header byte and any payload bytes.
pub fn encodedSizeU64(value: u64) usize {
	if (value < 128) return 1; // immediate
	const L = minPayloadBytes(value);
	// L for u64 is at most 8, so the header fits in one byte (no continuation).
	return 1 + L;
}

pub const Error = error{
	BufferTooSmall,
	UnexpectedEndOfInput,
	OverlongEncoding,
	OverlongHeader, // L<32 emitted with continuation set, or L>=32 emitted without
};

/// Canonical (shortest-form) BLIP encode of an unsigned u64 in little-endian.
/// For u64 inputs, L is at most 8, so the header is always one byte (no
/// continuation). Returns the number of bytes written into `out`.
pub fn encodeU64Canonical(out: []u8, value: u64) Error!usize {
	if (value < 128) {
		if (out.len < 1) return Error.BufferTooSmall;
		out[0] = @intCast(value);
		return 1;
	}
	const L = minPayloadBytes(value);
	// L is in 1..8 here, fits in the low 5 bits of the header (no continuation).
	const need = 1 + L;
	if (out.len < need) return Error.BufferTooSmall;
	out[0] = 0x80 | @as(u8, @intCast(L)); // E=0 (LE), C=0
	var i: usize = 0;
	while (i < L) : (i += 1) {
		out[1 + i] = @truncate(value >> @intCast(8 * i));
	}
	return need;
}

/// Decoded result of a single BLIP value read from a buffer.
pub const Decoded = struct {
	value: u64,
	bytes_read: usize,
	endian: Endian,
	is_sentinel: bool, // true if this was an overlong L=1 LE encoding
};

/// Decode a BLIP value from `buf`. Recognises the overlong L=1, E=0 encoding
/// and flags it as `is_sentinel = true` (caller decides whether to accept).
pub fn decodeU64(buf: []const u8) Error!Decoded {
	if (buf.len < 1) return Error.UnexpectedEndOfInput;
	const b0 = buf[0];
	if (b0 < 0x80) {
		return .{ .value = b0, .bytes_read = 1, .endian = .little, .is_sentinel = false };
	}
	const endian: Endian = if ((b0 & 0x40) != 0) .big else .little;
	const continuation = (b0 & 0x20) != 0;
	var L: usize = b0 & 0x1F;
	var pos: usize = 1;
	if (continuation) {
		var shift: u6 = 5;
		while (true) {
			if (pos >= buf.len) return Error.UnexpectedEndOfInput;
			const n = buf[pos];
			pos += 1;
			L |= @as(usize, n & 0x7F) << shift;
			shift += 7;
			if ((n & 0x80) == 0) break;
		}
	}
	if (L > 8) return Error.OverlongEncoding; // u64 cap
	if (pos + L > buf.len) return Error.UnexpectedEndOfInput;
	var value: u64 = 0;
	switch (endian) {
		.little => {
			var i: usize = 0;
			while (i < L) : (i += 1) {
				value |= @as(u64, buf[pos + i]) << @intCast(8 * i);
			}
		},
		.big => {
			var i: usize = 0;
			while (i < L) : (i += 1) {
				value = (value << 8) | buf[pos + i];
			}
		},
	}
	const sentinel = (L == 1 and endian == .little and value < 128);
	return .{ .value = value, .bytes_read = pos + L, .endian = endian, .is_sentinel = sentinel };
}

// ── Tests (drive the spec) ────────────────────────────────────────────────────

const testing = std.testing;

fn expectEncode(value: u64, expected: []const u8) !void {
	var buf: [16]u8 = undefined;
	const written = try encodeU64Canonical(&buf, value);
	try testing.expectEqualSlices(u8, expected, buf[0..written]);
	try testing.expectEqual(expected.len, encodedSizeU64(value));
}

test "encode 5 -> [0x05] (BLIP immediate)" {
	try expectEncode(5, &[_]u8{0x05});
}

test "encode boundary values per spec worked examples" {
	// Immediate range
	try expectEncode(0, &[_]u8{0x00});
	try expectEncode(127, &[_]u8{0x7F});
	// Length-prefixed, LE (E=0)
	try expectEncode(128, &[_]u8{ 0x81, 0x80 });
	try expectEncode(256, &[_]u8{ 0x82, 0x00, 0x01 });
	try expectEncode(65535, &[_]u8{ 0x82, 0xFF, 0xFF });
	try expectEncode(65536, &[_]u8{ 0x83, 0x00, 0x00, 0x01 });
	try expectEncode(std.math.maxInt(u64), &[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
}

test "encode then decode round-trip across boundaries" {
	const cases = [_]u64{ 0, 1, 127, 128, 255, 256, 65535, 65536, 16_777_215, 16_777_216, std.math.maxInt(u32), std.math.maxInt(u32) + 1, std.math.maxInt(u64) };
	for (cases) |v| {
		var buf: [16]u8 = undefined;
		const written = try encodeU64Canonical(&buf, v);
		const got = try decodeU64(buf[0..written]);
		try testing.expectEqual(v, got.value);
		try testing.expectEqual(written, got.bytes_read);
		try testing.expectEqual(Endian.little, got.endian);
		try testing.expectEqual(false, got.is_sentinel);
	}
}

test "decode sentinel: overlong L=1 LE with payload < 0x80 is flagged" {
	// 0x81 0x05 — would be value 5 if interpreted, but is a sentinel
	const got = try decodeU64(&[_]u8{ 0x81, 0x05 });
	try testing.expect(got.is_sentinel);
	try testing.expectEqual(@as(u64, 5), got.value);
	try testing.expectEqual(@as(usize, 2), got.bytes_read);
}

test "tier 0/1 never triggers continuation (L <= 8 fits in low 5 bits)" {
	// For all u64 values, the canonical L is in 0..8, far below the
	// continuation threshold of 32. So the header is always one byte.
	const cases = [_]u64{ 0, 127, 128, std.math.maxInt(u64) };
	for (cases) |v| {
		var buf: [16]u8 = undefined;
		const written = try encodeU64Canonical(&buf, v);
		if (v < 128) {
			try testing.expectEqual(@as(usize, 1), written);
		} else {
			// Header byte should not have the C (continuation) bit set.
			try testing.expectEqual(@as(u8, 0), buf[0] & 0x20);
		}
	}
}

test "decode of immediate value 0 yields {value=0, len=1}" {
	const got = try decodeU64(&[_]u8{0x00});
	try testing.expectEqual(@as(u64, 0), got.value);
	try testing.expectEqual(@as(usize, 1), got.bytes_read);
	try testing.expect(!got.is_sentinel);
}

test "decode rejects truncated input" {
	try testing.expectError(Error.UnexpectedEndOfInput, decodeU64(&[_]u8{}));
	// Header says L=2 but only 1 payload byte present.
	try testing.expectError(Error.UnexpectedEndOfInput, decodeU64(&[_]u8{ 0x82, 0x00 }));
}

// ── Signed (two's-complement) canonical encoding ────────────────────────────
//
// For blip_mp_t use: payload bytes are interpreted as signed two's-complement
// of width L*8 bits. Canonical L is the smallest byte-width whose two's-
// complement range contains the value.
//
// Examples (LE):
//   0    -> [0x00]              (immediate)
//   5    -> [0x05]              (immediate; positive < 128 fits in u7)
//   -1   -> [0x81, 0xFF]        (L=1, i8 = -1)
//  -128  -> [0x81, 0x80]        (L=1, i8 = -128, most-negative)
//   128  -> [0x82, 0x80, 0x00]  (L=2; +128 doesn't fit in i8)
//  -129  -> [0x82, 0x7F, 0xFF]  (L=2, i16 = -129)
//
// NOTE: this is *different* from encodeU64Canonical, which is the
// signedness-agnostic pure-BLIP encoding (unsigned interpretation).

/// Returns the minimum number of payload bytes needed to represent `value`
/// as signed two's complement. For values in -128..127 returns 1 (or 0 for
/// 0..127 since those fit in immediate). For values outside i8, grows to
/// 2/4/8 etc. Caps at 8 for i64 (i64 range fits in 8 bytes).
pub fn minPayloadBytesSigned(value: i64) usize {
	if (value >= 0 and value < 128) return 0; // immediate
	// Signed two's-comp range for L bytes: [-(2^(8L-1)), 2^(8L-1)-1].
	// Smallest L where value fits is the smallest L >= 1 with the property.
	var L: usize = 1;
	while (L < 8) : (L += 1) {
		const bits: u6 = @intCast(8 * L - 1);
		const max: i64 = (@as(i64, 1) << bits) - 1;
		const min: i64 = -(@as(i64, 1) << bits);
		if (value >= min and value <= max) return L;
	}
	return 8; // any i64 fits in 8 bytes
}

/// Bytes that encodeI64Canonical(value) would produce.
pub fn encodedSizeI64(value: i64) usize {
	const L = minPayloadBytesSigned(value);
	if (L == 0) return 1; // immediate
	return 1 + L;
}

/// Canonical signed (two's-complement) BLIP encode of an i64 in LE.
/// Produces the minimum-L encoding whose two's-comp interpretation equals `value`.
/// L is at most 8 for any i64 input (fits in header low 5 bits, no continuation).
pub fn encodeI64Canonical(out: []u8, value: i64) Error!usize {
	if (value >= 0 and value < 128) {
		if (out.len < 1) return Error.BufferTooSmall;
		out[0] = @intCast(value);
		return 1;
	}
	const L = minPayloadBytesSigned(value);
	const need = 1 + L;
	if (out.len < need) return Error.BufferTooSmall;
	out[0] = 0x80 | @as(u8, @intCast(L));
	const u: u64 = @bitCast(value); // two's-complement bit pattern
	var i: usize = 0;
	while (i < L) : (i += 1) {
		out[1 + i] = @truncate(u >> @intCast(8 * i));
	}
	return need;
}

/// Decode a BLIP value as signed two's-complement.
/// Reads the same encoding format as decodeU64 but sign-extends the payload.
/// `is_sentinel` is reported (caller decides). Big-endian payloads are also
/// handled (the BLIP spec permits mixed endianness per value).
pub fn decodeI64(buf: []const u8) Error!struct {
	value: i64,
	bytes_read: usize,
	endian: Endian,
	is_sentinel: bool,
} {
	const dec = try decodeU64(buf);
	if (dec.value == 0 and dec.bytes_read == 1 and buf[0] == 0x00) {
		return .{ .value = 0, .bytes_read = 1, .endian = .little, .is_sentinel = false };
	}
	// Immediate path: value 0..127 is positive, no sign extension.
	if (buf[0] < 0x80) {
		return .{ .value = @intCast(dec.value), .bytes_read = dec.bytes_read, .endian = dec.endian, .is_sentinel = false };
	}
	// Length-prefixed path: figure out L from the header so we know which
	// bit position is the sign bit, then sign-extend.
	// Re-derive L: header low-5-bits + continuation if any. Since u64 cap
	// already rejected L > 8, L is in 1..8 here.
	const L: u6 = @intCast(dec.bytes_read - 1); // payload length (no continuation in our subset)
	if (L == 8) {
		return .{ .value = @bitCast(dec.value), .bytes_read = dec.bytes_read, .endian = dec.endian, .is_sentinel = dec.is_sentinel };
	}
	const sign_bit_pos: u6 = 8 * L - 1;
	const sign_mask: u64 = @as(u64, 1) << sign_bit_pos;
	if ((dec.value & sign_mask) != 0) {
		// Sign-extend: set all bits above sign_bit_pos.
		const extension: u64 = ~((@as(u64, 1) << @intCast(8 * L)) - 1);
		const signed_bits: u64 = dec.value | extension;
		return .{ .value = @bitCast(signed_bits), .bytes_read = dec.bytes_read, .endian = dec.endian, .is_sentinel = dec.is_sentinel };
	}
	return .{ .value = @intCast(dec.value), .bytes_read = dec.bytes_read, .endian = dec.endian, .is_sentinel = dec.is_sentinel };
}

// ── Signed encoding tests ────────────────────────────────────────────────────

fn expectEncodeI64(value: i64, expected: []const u8) !void {
	var buf: [16]u8 = undefined;
	const written = try encodeI64Canonical(&buf, value);
	try testing.expectEqualSlices(u8, expected, buf[0..written]);
	try testing.expectEqual(expected.len, encodedSizeI64(value));
}

test "signed encode: immediate range positives" {
	try expectEncodeI64(0, &[_]u8{0x00});
	try expectEncodeI64(5, &[_]u8{0x05});
	try expectEncodeI64(127, &[_]u8{0x7F});
}

test "signed encode: spec worked examples" {
	try expectEncodeI64(-1, &[_]u8{ 0x81, 0xFF });
	try expectEncodeI64(-128, &[_]u8{ 0x81, 0x80 });
	try expectEncodeI64(-129, &[_]u8{ 0x82, 0x7F, 0xFF });
}

test "signed encode: positive values requiring L bump" {
	// +128 needs L=2 because i8 max is +127
	try expectEncodeI64(128, &[_]u8{ 0x82, 0x80, 0x00 });
	// +32767 fits in i16
	try expectEncodeI64(32767, &[_]u8{ 0x82, 0xFF, 0x7F });
	// +32768 needs L=4 (next power-of-two byte width above i16; we don't do L=3)
	// Actually our minPayloadBytesSigned grows L by 1 each step, so +32768
	// fits in i24 (L=3). Verify what canonical means here.
	// i24 max = 2^23 - 1 = 8388607, so +32768 fits in i24 → L=3.
	try expectEncodeI64(32768, &[_]u8{ 0x83, 0x00, 0x80, 0x00 });
}

test "signed encode: i64 extremes" {
	try expectEncodeI64(std.math.maxInt(i64), &[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
	try expectEncodeI64(std.math.minInt(i64), &[_]u8{ 0x88, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80 });
}

test "signed round-trip across boundaries" {
	const cases = [_]i64{ 0, 1, 5, 127, 128, -1, -128, -129, 32767, 32768, -32768, -32769, std.math.maxInt(i32), std.math.minInt(i32), std.math.maxInt(i64), std.math.minInt(i64) };
	for (cases) |v| {
		var buf: [16]u8 = undefined;
		const written = try encodeI64Canonical(&buf, v);
		const got = try decodeI64(buf[0..written]);
		try testing.expectEqual(v, got.value);
		try testing.expectEqual(written, got.bytes_read);
	}
}
