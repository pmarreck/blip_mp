// Tier 3: large-number arithmetic that operates DIRECTLY on BLIP payload
// bytes. No intermediate limb-array conversion. The payload IS the two's-
// complement value; arithmetic happens in place on those bytes.
//
// Why no limbs: the bytes are already in arithmetic-ready form (LE two's-
// complement). Converting to a limb array would only add round-trip overhead
// without any algorithmic benefit, breaking the spec's hypothesis #2
// ("beat GMP on cache-bound workloads by being contiguous and pointer-free").
// Two's-complement add/sub work bit-position-locally, so pos+pos, pos+neg,
// neg+neg all dispatch through the same byte loop with no sign-magnitude case.
//
// For speed, the inner loop reads u64 chunks at a time (LE) when the payload
// length permits, falling back to per-byte tail handling. Carry propagation
// uses Zig's `@addWithOverflow`.

const std = @import("std");
const encoding = @import("encoding.zig");

// ── Header read/write supporting L >= 32 (continuation) ──────────────────────

pub const Header = struct {
	L: usize,
	endian: encoding.Endian,
	bytes_consumed: usize,
};

/// Parse a BLIP header from `buf`. Returns L (any size, supports continuation),
/// endianness, and the header length. For an immediate (b0 < 0x80) returns L=0
/// with consumed=1; the caller must handle the immediate case before this if
/// they need the value of the immediate byte.
pub fn parseHeader(buf: []const u8) encoding.Error!Header {
	if (buf.len < 1) return error.UnexpectedEndOfInput;
	const b0 = buf[0];
	if (b0 < 0x80) return .{ .L = 0, .endian = .little, .bytes_consumed = 1 };
	const endian: encoding.Endian = if ((b0 & 0x40) != 0) .big else .little;
	const continuation = (b0 & 0x20) != 0;
	var L: usize = b0 & 0x1F;
	var pos: usize = 1;
	if (continuation) {
		var shift: u6 = 5;
		while (true) {
			if (pos >= buf.len) return error.UnexpectedEndOfInput;
			const n = buf[pos];
			pos += 1;
			L |= @as(usize, n & 0x7F) << shift;
			shift += 7;
			if ((n & 0x80) == 0) break;
		}
	}
	return .{ .L = L, .endian = endian, .bytes_consumed = pos };
}

/// Write a BLIP header for an L-byte LE payload. Returns header length in bytes.
pub fn writeHeader(out: []u8, L: usize) encoding.Error!usize {
	if (L < 32) {
		if (out.len < 1) return error.BufferTooSmall;
		out[0] = 0x80 | @as(u8, @intCast(L));
		return 1;
	}
	if (out.len < 2) return error.BufferTooSmall;
	out[0] = 0x80 | 0x20 | @as(u8, @intCast(L & 0x1F));
	var L_rem: usize = L >> 5;
	var pos: usize = 1;
	while (L_rem >= 128) {
		if (pos >= out.len) return error.BufferTooSmall;
		out[pos] = 0x80 | @as(u8, @intCast(L_rem & 0x7F));
		pos += 1;
		L_rem >>= 7;
	}
	if (pos >= out.len) return error.BufferTooSmall;
	out[pos] = @as(u8, @intCast(L_rem & 0x7F));
	pos += 1;
	return pos;
}

// ── Payload-direct two's-complement primitives ───────────────────────────────

/// Returns the sign-extension byte for a payload (0x00 if positive, 0xFF if
/// negative), determined by the high bit of the high byte. Empty payload
/// (immediate-zero case) returns 0x00.
pub fn signExtByte(payload: []const u8) u8 {
	if (payload.len == 0) return 0x00;
	return if ((payload[payload.len - 1] & 0x80) != 0) 0xFF else 0x00;
}

/// Read byte `i` from a payload, sign-extending past its end with the
/// appropriate fill byte. Used to do "logically-padded-to-N" reads without
/// materialising a padded copy.
inline fn payloadByteAt(payload: []const u8, i: usize, sign_ext: u8) u8 {
	return if (i < payload.len) payload[i] else sign_ext;
}

/// Add two two's-complement LE byte payloads, writing the result to `out`.
/// Operands are LOGICALLY zero/sign-extended to `n` bytes (no copy needed).
/// `out` must have capacity for at least `n + 1` bytes (extra byte holds
/// the sign-extension if both same-sign inputs overflow). Returns the byte
/// count actually used (n or n+1), pre-canonicalisation.
///
/// Inner loop reads up to 8 bytes at a time as u64 (little-endian) when both
/// operands have a full chunk of real bytes available — that's an 8× cut in
/// inner-loop iterations vs per-byte. Boundary chunks (where one operand's
/// real bytes run out and we fall back to sign-extension) and the final tail
/// are handled per-byte. No separate "limbs" data structure — we reinterpret
/// the contiguous payload bytes through readInt/writeInt.
pub fn addPayloads(
	a: []const u8,
	b: []const u8,
	n: usize,
	out: []u8,
) usize {
	std.debug.assert(out.len >= n + 1);
	const sa = signExtByte(a);
	const sb = signExtByte(b);
	// Sign-extension fill words for the chunked path.
	const sa_word: u64 = if (sa == 0xFF) ~@as(u64, 0) else 0;
	const sb_word: u64 = if (sb == 0xFF) ~@as(u64, 0) else 0;

	var carry: u64 = 0;
	var i: usize = 0;
	// Chunked u64 path: only when BOTH operands have a full 8-byte chunk
	// available at offset i. Boundaries fall through to the per-byte tail.
	const chunk_end = chunkEndForLen(@min(a.len, b.len), n);
	while (i + 8 <= chunk_end) : (i += 8) {
		const av: u64 = std.mem.readInt(u64, a[i..][0..8], .little);
		const bv: u64 = std.mem.readInt(u64, b[i..][0..8], .little);
		const s1 = @addWithOverflow(av, bv);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u64, out[i..][0..8], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	// Continue with remaining full chunks past one operand's real-bytes
	// boundary. This time at least one side reads from sign-extension.
	while (i + 8 <= n) : (i += 8) {
		const av: u64 = readPayloadChunk(a, i, sa_word);
		const bv: u64 = readPayloadChunk(b, i, sb_word);
		const s1 = @addWithOverflow(av, bv);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u64, out[i..][0..8], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	// Per-byte tail (last < 8 bytes).
	while (i < n) : (i += 1) {
		const av: u64 = payloadByteAt(a, i, sa);
		const bv: u64 = payloadByteAt(b, i, sb);
		const sum = av + bv + carry;
		out[i] = @truncate(sum);
		carry = sum >> 8;
	}

	// Same-sign overflow detection.
	const result_high_bit = (out[n - 1] & 0x80) != 0;
	const a_neg = sa == 0xFF;
	const b_neg = sb == 0xFF;
	if (a_neg == b_neg and a_neg != result_high_bit) {
		out[n] = if (a_neg) 0xFF else 0x00;
		return n + 1;
	}
	return n;
}

/// Number of bytes from offset 0 where BOTH operands still have real
/// payload bytes (no sign-extension needed). Used to find the "fast path"
/// region of the chunked add loop.
inline fn chunkEndForLen(min_payload_len: usize, n: usize) usize {
	const m = @min(min_payload_len, n);
	return m - (m % 8);
}

/// Read 8 bytes at offset i from a payload, sign-extending past end with
/// `sign_word`. Used by the chunked add inner loop on its second pass.
inline fn readPayloadChunk(payload: []const u8, i: usize, sign_word: u64) u64 {
	if (i + 8 <= payload.len) {
		return std.mem.readInt(u64, payload[i..][0..8], .little);
	}
	// Partial chunk: real bytes for offsets [i..payload.len), sign for the rest.
	var bytes: [8]u8 = undefined;
	const real = if (payload.len > i) payload.len - i else 0;
	if (real > 0) @memcpy(bytes[0..real], payload[i..][0..real]);
	const fill: u8 = if (sign_word == 0) 0 else 0xFF;
	@memset(bytes[real..], fill);
	return std.mem.readInt(u64, &bytes, .little);
}

/// Subtract: r = a - b. Same approach as addPayloads but with borrow.
/// Two's-complement-direct, no sign-magnitude.
pub fn subPayloads(
	a: []const u8,
	b: []const u8,
	n: usize,
	out: []u8,
) usize {
	std.debug.assert(out.len >= n + 1);
	const sa = signExtByte(a);
	const sb = signExtByte(b);

	var borrow: i32 = 0;
	var i: usize = 0;
	while (i < n) : (i += 1) {
		const av: i32 = payloadByteAt(a, i, sa);
		const bv: i32 = payloadByteAt(b, i, sb);
		const diff = av - bv - borrow;
		out[i] = @truncate(@as(u32, @bitCast(diff)) & 0xFF);
		borrow = if (diff < 0) 1 else 0;
	}

	// Overflow check. For a - b, the dangerous case is opposite-sign inputs.
	// If a and b have different signs, a - b has the sign of a; if the result
	// flipped sign relative to a, we overflowed.
	const result_high_bit = (out[n - 1] & 0x80) != 0;
	const a_neg = sa == 0xFF;
	const b_neg = sb == 0xFF;

	if (a_neg != b_neg and a_neg != result_high_bit) {
		out[n] = if (a_neg) 0xFF else 0x00;
		return n + 1;
	}
	return n;
}

/// Trim redundant sign-extension bytes from a two's-complement payload. The
/// canonical form drops trailing 0x00 bytes (for positives) or trailing 0xFF
/// bytes (for negatives), as long as the remaining high bit still encodes
/// the correct sign. Returns the canonical length (>= 1).
pub fn canonicalLen(payload: []const u8) usize {
	if (payload.len <= 1) return @max(payload.len, 1);
	const sign_byte: u8 = if ((payload[payload.len - 1] & 0x80) != 0) 0xFF else 0x00;
	var n = payload.len;
	while (n > 1) {
		const high = payload[n - 1];
		const next = payload[n - 2];
		// Drop high byte if it equals the sign-extension AND removing it
		// preserves the sign bit (i.e., next byte's high bit matches).
		const next_high_bit_set = (next & 0x80) != 0;
		const sign_is_negative = sign_byte == 0xFF;
		if (high == sign_byte and next_high_bit_set == sign_is_negative) {
			n -= 1;
			continue;
		}
		break;
	}
	return n;
}

// ── BLIP-level wrappers ──────────────────────────────────────────────────────

/// Materialise the payload portion of a BLIP-encoded value. For an immediate
/// (b0 < 0x80) returns a one-byte slice of the immediate value. For length-
/// prefixed, returns the payload slice (no header). Caller may need to
/// allocate an extension if downstream code wants a specific min length.
pub fn payloadOf(blip: []const u8) encoding.Error![]const u8 {
	if (blip.len == 0) return error.UnexpectedEndOfInput;
	if (blip[0] < 0x80) {
		// Immediate. The byte itself is the payload.
		return blip[0..1];
	}
	const hdr = try parseHeader(blip);
	if (blip.len < hdr.bytes_consumed + hdr.L) return error.UnexpectedEndOfInput;
	return blip[hdr.bytes_consumed .. hdr.bytes_consumed + hdr.L];
}

/// r = a + b. Operates on raw BLIP-encoded slices. Result is canonically
/// encoded (header + payload) into `out`. Returns total bytes written.
/// `scratch` must have at least `max(a_payload_len, b_payload_len) + 1` bytes.
pub fn addRawBlip(
	a_blip: []const u8,
	b_blip: []const u8,
	scratch: []u8,
	out: []u8,
) !usize {
	const a_pay = try payloadOf(a_blip);
	const b_pay = try payloadOf(b_blip);
	const n = @max(a_pay.len, b_pay.len);
	std.debug.assert(scratch.len >= n + 1);
	const result_len = addPayloads(a_pay, b_pay, n, scratch);
	const canon = canonicalLen(scratch[0..result_len]);
	return try writeBlip(scratch[0..canon], out);
}

/// r = a - b.
pub fn subRawBlip(
	a_blip: []const u8,
	b_blip: []const u8,
	scratch: []u8,
	out: []u8,
) !usize {
	const a_pay = try payloadOf(a_blip);
	const b_pay = try payloadOf(b_blip);
	const n = @max(a_pay.len, b_pay.len);
	std.debug.assert(scratch.len >= n + 1);
	const result_len = subPayloads(a_pay, b_pay, n, scratch);
	const canon = canonicalLen(scratch[0..result_len]);
	return try writeBlip(scratch[0..canon], out);
}

/// Write a canonical BLIP encoding for the given two's-complement LE payload.
/// Special cases the immediate range (single-byte 0..127 → no header).
pub fn writeBlip(payload: []const u8, out: []u8) !usize {
	std.debug.assert(payload.len >= 1);
	// Immediate path: 0..127 in a single byte.
	if (payload.len == 1 and payload[0] < 0x80) {
		if (out.len < 1) return error.BufferTooSmall;
		out[0] = payload[0];
		return 1;
	}
	const hdr_len = try writeHeader(out, payload.len);
	if (out.len < hdr_len + payload.len) return error.BufferTooSmall;
	@memcpy(out[hdr_len .. hdr_len + payload.len], payload);
	return hdr_len + payload.len;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "writeHeader: L=1..31 (no continuation)" {
	var buf: [4]u8 = undefined;
	const n = try writeHeader(&buf, 5);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u8, 0x85), buf[0]);

	const n2 = try writeHeader(&buf, 31);
	try testing.expectEqual(@as(usize, 1), n2);
	try testing.expectEqual(@as(u8, 0x9F), buf[0]);
}

test "writeHeader: L=32 (continuation kicks in)" {
	var buf: [4]u8 = undefined;
	const n = try writeHeader(&buf, 32);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0xA0), buf[0]);
	try testing.expectEqual(@as(u8, 0x01), buf[1]);
}

test "writeHeader: L=128 (1024-bit)" {
	var buf: [4]u8 = undefined;
	const n = try writeHeader(&buf, 128);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0xA0), buf[0]);
	try testing.expectEqual(@as(u8, 0x04), buf[1]);
}

test "writeHeader: L=512 (4096-bit)" {
	var buf: [4]u8 = undefined;
	const n = try writeHeader(&buf, 512);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0xA0), buf[0]);
	try testing.expectEqual(@as(u8, 0x10), buf[1]);
}

test "parseHeader / writeHeader round-trip across L sizes" {
	const cases = [_]usize{ 1, 2, 8, 16, 31, 32, 33, 64, 128, 256, 512, 1024 };
	for (cases) |L| {
		var buf: [8]u8 = undefined;
		const n = try writeHeader(&buf, L);
		const hdr = try parseHeader(&buf);
		try testing.expectEqual(L, hdr.L);
		try testing.expectEqual(n, hdr.bytes_consumed);
	}
}

test "signExtByte: positive payload returns 0x00" {
	try testing.expectEqual(@as(u8, 0x00), signExtByte(&[_]u8{0x05}));
	try testing.expectEqual(@as(u8, 0x00), signExtByte(&[_]u8{ 0xFF, 0x7F }));
}

test "signExtByte: negative payload returns 0xFF" {
	try testing.expectEqual(@as(u8, 0xFF), signExtByte(&[_]u8{0x80}));
	try testing.expectEqual(@as(u8, 0xFF), signExtByte(&[_]u8{ 0x00, 0xFF }));
}

test "addPayloads: tiny same-length positive (5 + 7 = 12)" {
	var out: [4]u8 = undefined;
	const n = addPayloads(&[_]u8{0x05}, &[_]u8{0x07}, 1, &out);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u8, 0x0C), out[0]);
}

test "addPayloads: tiny mixed-length (100 + 200 = 300; 1-byte + 2-byte)" {
	// 100 = [0x64] (immediate); 200 = [0xC8, 0x00] (signed L=2)
	var out: [4]u8 = undefined;
	const n = addPayloads(&[_]u8{0x64}, &[_]u8{ 0xC8, 0x00 }, 2, &out);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0x2C), out[0]); // 300 & 0xFF
	try testing.expectEqual(@as(u8, 0x01), out[1]); // (300 >> 8) & 0xFF
}

test "addPayloads: same-sign overflow extends by one byte (positive)" {
	// 100 + 100 = 200. As signed i8 (L=1), inputs are positive (0x64 each).
	// Sum = 0xC8, high bit set → would decode as -56. Overflow → extend.
	var out: [4]u8 = undefined;
	const n = addPayloads(&[_]u8{0x64}, &[_]u8{0x64}, 1, &out);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0xC8), out[0]);
	try testing.expectEqual(@as(u8, 0x00), out[1]); // sign extension byte for positive overflow
}

test "addPayloads: same-sign overflow (negative)" {
	// (-128) + (-1) = -129. i8 inputs: 0x80 and 0xFF. Sum bytes: 0x7F, with
	// borrow into the second byte. As i8 result: 0x7F = +127, sign flipped
	// vs both inputs (negative) → overflow → extend with 0xFF.
	var out: [4]u8 = undefined;
	const n = addPayloads(&[_]u8{0x80}, &[_]u8{0xFF}, 1, &out);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0x7F), out[0]);
	try testing.expectEqual(@as(u8, 0xFF), out[1]); // sign extension for negative overflow
}

test "addPayloads: opposite-sign cannot overflow (no extension)" {
	// 100 + (-50) = 50. Both at L=1: 0x64 + 0xCE = ... let's compute.
	// 0x64 = 100, 0xCE (sign-ext to nothing here) = -50.
	// Sum bytes: 100 + 206 = 306 = 0x132. Low byte 0x32 = 50. Carry = 1.
	// (Carry doesn't extend because opposite signs.)
	// Result high bit = 0 (positive), and inputs had different signs → no overflow.
	var out: [4]u8 = undefined;
	const n = addPayloads(&[_]u8{0x64}, &[_]u8{0xCE}, 1, &out);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u8, 0x32), out[0]); // 50
}

test "subPayloads: 200 - 50 = 150" {
	// 200 = [0xC8, 0x00] L=2. 50 = [0x32] immediate. n=2.
	var out: [4]u8 = undefined;
	const n = subPayloads(&[_]u8{ 0xC8, 0x00 }, &[_]u8{0x32}, 2, &out);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0x96), out[0]); // 150
	try testing.expectEqual(@as(u8, 0x00), out[1]);
}

test "subPayloads: i64.max - i64.min overflows positively (extends)" {
	// i64.max = 0x7F FF... FF (8 bytes). i64.min = 0x80 00... 00.
	// Difference = 2^64 - 1 = all 1s in 8 bytes (negative looking).
	// Actually: i64.max - i64.min = (2^63 - 1) - (-2^63) = 2^64 - 1.
	// In 8 bytes that's 0xFF*8 = -1 in i64 view → wrong! Need to extend.
	const max = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
	const min = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80 };
	var out: [16]u8 = undefined;
	const n = subPayloads(&max, &min, 8, &out);
	try testing.expectEqual(@as(usize, 9), n);
	for (out[0..8]) |b| try testing.expectEqual(@as(u8, 0xFF), b);
	try testing.expectEqual(@as(u8, 0x00), out[8]); // sign extension byte
}

test "canonicalLen: trims trailing 0x00 from positives" {
	// 100 padded to L=2 = [0x64, 0x00]. Canonical: drop the 0x00 since 0x64's
	// high bit is 0 (positive), preserved.
	try testing.expectEqual(@as(usize, 1), canonicalLen(&[_]u8{ 0x64, 0x00 }));
	// But [0xC8, 0x00] (which is +200 in i16) must NOT trim — dropping the
	// 0x00 leaves 0xC8 with high bit set, flipping interpretation to -56.
	try testing.expectEqual(@as(usize, 2), canonicalLen(&[_]u8{ 0xC8, 0x00 }));
}

test "canonicalLen: trims trailing 0xFF from negatives" {
	// -1 in i16 = [0xFF, 0xFF]. Canonical: drop the high 0xFF since 0xFF
	// (low) has high bit set, sign-preserved.
	try testing.expectEqual(@as(usize, 1), canonicalLen(&[_]u8{ 0xFF, 0xFF }));
	// But [0x32, 0xFF] (= -206 in i16) must NOT trim — dropping leaves 0x32
	// (high bit clear, positive +50). Wait, [0x32, 0xFF] LE = 0xFF32 = -206 i16.
	// If we trim to [0x32] → +50 (positive). Not preserved. So no trim.
	try testing.expectEqual(@as(usize, 2), canonicalLen(&[_]u8{ 0x32, 0xFF }));
}

test "canonicalLen: leaves single byte alone" {
	try testing.expectEqual(@as(usize, 1), canonicalLen(&[_]u8{0x05}));
	try testing.expectEqual(@as(usize, 1), canonicalLen(&[_]u8{0xFF}));
}

test "addRawBlip: small + small (100 + 200 = 300)" {
	var scratch: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	const a_blip = &[_]u8{0x64};
	const b_blip = &[_]u8{ 0x82, 0xC8, 0x00 };
	const n = try addRawBlip(a_blip, b_blip, &scratch, &out);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x2C, 0x01 }, out[0..n]);
}

test "addRawBlip: positive + negative cancels to zero" {
	var scratch: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	const n = try addRawBlip(&[_]u8{ 0x82, 0xC8, 0x00 }, &[_]u8{ 0x82, 0x38, 0xFF }, &scratch, &out);
	// +200 + (-200) = 0 → immediate [0x00]
	try testing.expectEqualSlices(u8, &[_]u8{0x00}, out[0..n]);
}

test "addRawBlip: positive + smaller negative" {
	var scratch: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	// b = -50 as BLIP: header 0x81 (L=1) + payload 0xCE (i8 = -50)
	const n = try addRawBlip(&[_]u8{ 0x82, 0xC8, 0x00 }, &[_]u8{ 0x81, 0xCE }, &scratch, &out);
	// +200 + (-50) = +150 → L=2 [0x82, 0x96, 0x00]
	try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x96, 0x00 }, out[0..n]);
}

test "addRawBlip: 256-bit + 256-bit (both positive)" {
	// Build two 256-bit positive numbers as raw signed-canonical BLIP payloads.
	var a_payload: [32]u8 = undefined;
	var b_payload: [32]u8 = undefined;
	for (&a_payload, 0..) |*p, i| p.* = @intCast(i + 1);
	for (&b_payload, 0..) |*p, i| p.* = @intCast(i + 1);
	a_payload[31] = 0x10;
	b_payload[31] = 0x10;

	var a_blip: [34]u8 = undefined;
	a_blip[0] = 0xA0;
	a_blip[1] = 0x01;
	@memcpy(a_blip[2..], &a_payload);
	var b_blip: [34]u8 = undefined;
	b_blip[0] = 0xA0;
	b_blip[1] = 0x01;
	@memcpy(b_blip[2..], &b_payload);

	var scratch: [64]u8 = undefined;
	var out: [64]u8 = undefined;
	const n = try addRawBlip(&a_blip, &b_blip, &scratch, &out);

	// Result should be 2 * a (since a == b). Decode the result bytes and
	// verify each payload byte equals 2*a_payload[i] (modulo carry).
	const r_hdr = try parseHeader(out[0..n]);
	const r_pay = out[r_hdr.bytes_consumed .. r_hdr.bytes_consumed + r_hdr.L];

	// Compute expected by per-byte 2x with carry.
	var expected: [33]u8 = .{0} ** 33;
	var carry: u16 = 0;
	for (a_payload, 0..) |byte, i| {
		const sum = @as(u16, byte) * 2 + carry;
		expected[i] = @truncate(sum);
		carry = sum >> 8;
	}
	if (carry != 0) expected[32] = @truncate(carry);

	const expected_canon = canonicalLen(&expected);
	try testing.expectEqualSlices(u8, expected[0..expected_canon], r_pay);
}

test "addRawBlip → subRawBlip round-trip: r + b - b == a" {
	var scratch: [16]u8 = undefined;
	var sum_buf: [16]u8 = undefined;
	var diff_buf: [16]u8 = undefined;
	const a_blip = &[_]u8{ 0x83, 0x40, 0xE2, 0x01 }; // some L=3 value
	const b_blip = &[_]u8{ 0x82, 0xC8, 0x00 };
	const sum_n = try addRawBlip(a_blip, b_blip, &scratch, &sum_buf);
	const diff_n = try subRawBlip(sum_buf[0..sum_n], b_blip, &scratch, &diff_buf);
	try testing.expectEqualSlices(u8, a_blip, diff_buf[0..diff_n]);
}
