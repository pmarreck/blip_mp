// BLIP integer encoding — signed two's-complement only.
//
// We commit to ONE interpretation: payload bytes are signed two's-complement
// of width L*8 bits. The "where is the sign bit" question is answered by
// definition (high bit of the high byte). The encoder only has one real
// choice — picking L — and it always picks the smallest L whose two's-comp
// range contains the value.
//
// Encoding (per BLIP_SPEC_CONCISE.md, restricted to the signed reading):
//
//   IMMEDIATE       0_xxxxxxx                    value 0..127 (positive only)
//   LENGTH-PREFIXED 1_E_C_LLLLL [cont...] [pl]   value outside immediate range
//     E = endianness of payload (0=LE, 1=BE)
//     C = continuation bit (1 means more L bits follow as varint)
//     For our i64 universe (L <= 8), continuation never fires.
//
// SENTINELS: per BLIP spec, an L=1, E=0 encoding whose payload byte < 0x80
// is overlong (the value would have fit in immediate). Reserved for
// TRUE/FALSE/NIL/application sentinels. Our encoder NEVER emits these;
// our decoder flags them as `is_sentinel = true` (caller decides).

const std = @import("std");

pub const Endian = enum(u1) {
	little = 0,
	big = 1,
};

pub const Error = error{
	BufferTooSmall,
	UnexpectedEndOfInput,
	OverlongEncoding,
};

pub const Decoded = struct {
	value: i64,
	bytes_read: usize,
	endian: Endian,
	is_sentinel: bool,
};

/// Cheap header-byte classifier — comptime-built 256-entry lookup avoids
/// the bit-juggling on every parse. For the immediate range (b0 < 0x80)
/// the payload IS the byte and `has_continuation` is irrelevant.
pub const HeaderInfo = packed struct {
	is_immediate: bool, // b0 < 0x80
	has_continuation: bool, // bit 5 set (only meaningful when length-prefixed)
	endian_be: bool, // bit 6 set (only meaningful when length-prefixed)
	low5: u5, // L low-5 bits (only meaningful when length-prefixed)
};

const HEADER_LUT: [256]HeaderInfo = blk: {
	@setEvalBranchQuota(2000);
	var t: [256]HeaderInfo = undefined;
	for (0..256) |i| {
		const b = @as(u8, @intCast(i));
		t[i] = .{
			.is_immediate = b < 0x80,
			.has_continuation = (b & 0x20) != 0,
			.endian_be = (b & 0x40) != 0,
			.low5 = @intCast(b & 0x1F),
		};
	}
	break :blk t;
};

/// Look up the structural meaning of a BLIP first byte. Single load, no math.
pub inline fn headerInfoLookup(b0: u8) HeaderInfo {
	return HEADER_LUT[b0];
}

/// Minimum payload byte-width needed to represent `value` as signed two's
/// complement. Returns 0 for values 0..127 (the immediate range — no payload
/// is needed at all). Otherwise returns the smallest L in 1..8 whose i(L*8)
/// range contains `value`. Caps at 8 for any i64 input.
///
/// Implementation: count the bits needed including the sign bit via `@clz`.
/// For positive values, that's `64 - @clz(value) + 1`. For negative values,
/// the symmetric magnitude is `~value` (e.g., -1 has ~v == 0, requiring
/// 0+1=1 bit; -128 has ~v == 127, requiring 7+1=8 bits → L=1). Round up to
/// byte multiple. Replaces a 7-iter range-check loop with ~3 instructions.
pub fn minPayloadBytesSigned(value: i64) usize {
	if (value >= 0 and value < 128) return 0; // immediate
	const u: u64 = if (value >= 0)
		@bitCast(value)
	else
		~@as(u64, @bitCast(value));
	const bits: usize = 64 - @clz(u) + 1; // +1 for the sign bit
	return (bits + 7) / 8;
}

/// Bytes that encodeI64Canonical(value) would produce.
pub fn encodedSizeI64(value: i64) usize {
	const L = minPayloadBytesSigned(value);
	if (L == 0) return 1; // immediate
	return 1 + L;
}

/// Canonical signed (two's-complement) BLIP encode of an i64 in LE.
/// L is at most 8 for any i64 input — fits in the header low 5 bits, no
/// continuation. Returns the number of bytes written into `out`.
///
/// Hot path: when `out` has at least 9 bytes capacity (the typical case —
/// e.g., when called against Mp's 24-byte inline_buf), writes the full u64
/// little-endian in one store via `std.mem.writeInt`. Trailing bytes past L
/// are scribbled but inert (the caller tracks the active length via `need`).
/// On aarch64 this compiles to a single STR instruction vs the per-byte loop's
/// 2-8 STRBs. Fallback byte-loop covers tight buffers (≤ 8 bytes capacity).
pub fn encodeI64Canonical(out: []u8, value: i64) Error!usize {
	if (value >= 0 and value < 128) {
		if (out.len < 1) return Error.BufferTooSmall;
		out[0] = @intCast(value);
		return 1;
	}
	const L = minPayloadBytesSigned(value);
	const need = 1 + L;
	if (out.len < need) return Error.BufferTooSmall;
	out[0] = 0x80 | @as(u8, @intCast(L)); // E=0 (LE), C=0
	// Bulk-store path: out has room for the full 8-byte u64 (most callers).
	if (out.len >= 9) {
		std.mem.writeInt(u64, out[1..][0..8], @bitCast(value), .little);
		return need;
	}
	// Fallback for tight buffers.
	const u: u64 = @bitCast(value);
	var i: usize = 0;
	while (i < L) : (i += 1) {
		out[1 + i] = @truncate(u >> @intCast(8 * i));
	}
	return need;
}

/// Decode a single BLIP value from `buf`, interpreting the payload as signed
/// two's-complement. Sign-extends the L-byte payload up to a full i64.
/// Big-endian payloads are also handled (BLIP permits per-value endianness).
pub fn decodeI64(buf: []const u8) Error!Decoded {
	if (buf.len < 1) return Error.UnexpectedEndOfInput;
	const b0 = buf[0];
	if (b0 < 0x80) {
		// Immediate: 0..127, always positive, no sign extension.
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
	if (L == 0 or L > 8) return Error.OverlongEncoding; // L=0 in length-prefixed header is malformed; L>8 is out of i64 range
	if (pos + L > buf.len) return Error.UnexpectedEndOfInput;

	// Read L bytes as u64. Bulk-load path: when `buf` has ≥ 8 bytes available
	// past `pos`, do a single u64 load (single LDR on aarch64) and mask off
	// the high bytes. This is the hot path for inline-storage Mp (always ≥ 8
	// trailing bytes in the 24-byte inline_buf).
	var u: u64 = 0;
	switch (endian) {
		.little => {
			if (pos + 8 <= buf.len) {
				const raw = std.mem.readInt(u64, buf[pos..][0..8], .little);
				u = if (L == 8) raw else raw & ((@as(u64, 1) << @intCast(8 * L)) - 1);
			} else {
				var i: usize = 0;
				while (i < L) : (i += 1) {
					u |= @as(u64, buf[pos + i]) << @intCast(8 * i);
				}
			}
		},
		.big => {
			var i: usize = 0;
			while (i < L) : (i += 1) {
				u = (u << 8) | buf[pos + i];
			}
		},
	}
	// High bit of the L-byte two's-complement value:
	const sign_bit: u64 = @as(u64, 1) << @intCast(8 * L - 1);
	if ((u & sign_bit) != 0 and L < 8) {
		// Sign-extend by setting all bits above the L-byte payload.
		const top_bits: u64 = ~((@as(u64, 1) << @intCast(8 * L)) - 1);
		u |= top_bits;
	}
	const value: i64 = @bitCast(u);

	// Sentinel detection: overlong L=1, E=0 with payload < 0x80. In the
	// signed reading, these bytes decode to positive values 0..127 — which
	// would have fit in immediate. Our encoder never emits these.
	const is_sentinel = (L == 1 and endian == .little and buf[pos] < 0x80);
	return .{ .value = value, .bytes_read = pos + L, .endian = endian, .is_sentinel = is_sentinel };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectEncode(value: i64, expected: []const u8) !void {
	var buf: [16]u8 = undefined;
	const written = try encodeI64Canonical(&buf, value);
	try testing.expectEqualSlices(u8, expected, buf[0..written]);
	try testing.expectEqual(expected.len, encodedSizeI64(value));
}

test "encode immediate range positives" {
	try expectEncode(0, &[_]u8{0x00});
	try expectEncode(5, &[_]u8{0x05});
	try expectEncode(127, &[_]u8{0x7F});
}

test "encode spec worked examples (negatives)" {
	try expectEncode(-1, &[_]u8{ 0x81, 0xFF });
	try expectEncode(-128, &[_]u8{ 0x81, 0x80 });
	try expectEncode(-129, &[_]u8{ 0x82, 0x7F, 0xFF });
}

test "encode positives that need L bump (high bit forces wider signed type)" {
	// +128 needs L=2 (i8 max is +127); LE bytes [0x80, 0x00].
	try expectEncode(128, &[_]u8{ 0x82, 0x80, 0x00 });
	// +32767 fits in i16.
	try expectEncode(32767, &[_]u8{ 0x82, 0xFF, 0x7F });
	// +32768 fits in i24 (L=3); range ±2^23-1.
	try expectEncode(32768, &[_]u8{ 0x83, 0x00, 0x80, 0x00 });
}

test "encode i64 extremes" {
	try expectEncode(std.math.maxInt(i64), &[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F });
	try expectEncode(std.math.minInt(i64), &[_]u8{ 0x88, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80 });
}

test "round-trip across boundaries" {
	const cases = [_]i64{ 0, 1, 5, 127, 128, -1, -128, -129, 32767, 32768, -32768, -32769, std.math.maxInt(i32), std.math.minInt(i32), std.math.maxInt(i64), std.math.minInt(i64) };
	for (cases) |v| {
		var buf: [16]u8 = undefined;
		const written = try encodeI64Canonical(&buf, v);
		const got = try decodeI64(buf[0..written]);
		try testing.expectEqual(v, got.value);
		try testing.expectEqual(written, got.bytes_read);
	}
}

test "decode sentinel: overlong L=1 LE with payload < 0x80 is flagged" {
	// 0x81 0x05 — would decode to +5 if accepted, but is reserved as a sentinel.
	const got = try decodeI64(&[_]u8{ 0x81, 0x05 });
	try testing.expect(got.is_sentinel);
	try testing.expectEqual(@as(i64, 5), got.value);
	try testing.expectEqual(@as(usize, 2), got.bytes_read);
}

test "tier 0/1 never triggers continuation (L <= 8 fits in low 5 bits)" {
	const cases = [_]i64{ 0, 127, -128, std.math.maxInt(i64), std.math.minInt(i64) };
	for (cases) |v| {
		var buf: [16]u8 = undefined;
		const written = try encodeI64Canonical(&buf, v);
		if (v >= 0 and v < 128) {
			try testing.expectEqual(@as(usize, 1), written);
		} else {
			// Header byte should not have the C (continuation) bit set.
			try testing.expectEqual(@as(u8, 0), buf[0] & 0x20);
		}
	}
}

test "decode of immediate 0 yields value=0, len=1" {
	const got = try decodeI64(&[_]u8{0x00});
	try testing.expectEqual(@as(i64, 0), got.value);
	try testing.expectEqual(@as(usize, 1), got.bytes_read);
	try testing.expect(!got.is_sentinel);
}

test "decode rejects truncated input" {
	try testing.expectError(Error.UnexpectedEndOfInput, decodeI64(&[_]u8{}));
	// Header says L=2 but only 1 payload byte present.
	try testing.expectError(Error.UnexpectedEndOfInput, decodeI64(&[_]u8{ 0x82, 0x00 }));
}

test "decode big-endian payload (per-value E bit)" {
	// E=1, L=2, BE payload [0x01, 0x00] = +256.
	const got = try decodeI64(&[_]u8{ 0xC2, 0x01, 0x00 });
	try testing.expectEqual(@as(i64, 256), got.value);
	try testing.expectEqual(Endian.big, got.endian);
}
