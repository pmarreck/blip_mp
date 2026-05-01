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
