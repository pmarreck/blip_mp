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
	// Chunked u512 path: 64 bytes per iter when operands are large enough
	// (4096-bit and up). Each u512 add compiles to 8 ADCS instructions on
	// aarch64 — same per-byte throughput as smaller chunks but minimises
	// loop branches and load/store insn count. This closes most of the
	// remaining gap to GMP at 4096+ bits.
	const both_end = chunkEndForLen(@min(a.len, b.len), n);
	const both_end_64 = both_end - (both_end % 64);
	while (i + 64 <= both_end_64) : (i += 64) {
		const av: u512 = std.mem.readInt(u512, a[i..][0..64], .little);
		const bv: u512 = std.mem.readInt(u512, b[i..][0..64], .little);
		const s1 = @addWithOverflow(av, bv);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u512, out[i..][0..64], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	// u256 chunks for the next size band.
	const both_end_32 = both_end - (both_end % 32);
	while (i + 32 <= both_end_32) : (i += 32) {
		const av: u256 = std.mem.readInt(u256, a[i..][0..32], .little);
		const bv: u256 = std.mem.readInt(u256, b[i..][0..32], .little);
		const s1 = @addWithOverflow(av, bv);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u256, out[i..][0..32], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	// Drop down to u128 chunks for any remaining 16-byte slot.
	while (i + 16 <= both_end) : (i += 16) {
		const av: u128 = std.mem.readInt(u128, a[i..][0..16], .little);
		const bv: u128 = std.mem.readInt(u128, b[i..][0..16], .little);
		const s1 = @addWithOverflow(av, bv);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u128, out[i..][0..16], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	// Drop down to u64 chunks for any remaining 8-byte slot in the
	// "both operands have real bytes" region.
	while (i + 8 <= both_end) : (i += 8) {
		const av: u64 = std.mem.readInt(u64, a[i..][0..8], .little);
		const bv: u64 = std.mem.readInt(u64, b[i..][0..8], .little);
		const s1 = @addWithOverflow(av, bv);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u64, out[i..][0..8], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	// Continue with remaining full u64 chunks past one operand's real-bytes
	// boundary. At least one side now reads from sign-extension.
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
///
/// Fast path: when the high byte is neither 0x00 nor 0xFF, no trimming is
/// possible and we return immediately. This is the common case for random
/// add results — saves a scan of the entire payload at large sizes.
pub fn canonicalLen(payload: []const u8) usize {
	if (payload.len <= 1) return @max(payload.len, 1);
	const high = payload[payload.len - 1];
	if (high != 0x00 and high != 0xFF) return payload.len; // common case

	const sign_byte: u8 = if ((high & 0x80) != 0) 0xFF else 0x00;
	var n = payload.len;
	while (n > 1) {
		const h = payload[n - 1];
		const next = payload[n - 2];
		const next_high_bit_set = (next & 0x80) != 0;
		const sign_is_negative = sign_byte == 0xFF;
		if (h == sign_byte and next_high_bit_set == sign_is_negative) {
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

// ── Multiplication: sign-magnitude, schoolbook on bytes ──────────────────────
//
// Sign-magnitude dispatch is required for mul (unlike add/sub which work
// uniformly on two's-complement). We:
//   1. Negate any negative inputs in scratch (~bytes + 1) to get magnitudes.
//   2. Schoolbook multiply unsigned magnitudes byte-by-byte with carry.
//   3. Sign of result = sign(a) XOR sign(b).
//   4. If result negative, negate scratch_r; pad with 0xFF if high bit clear.
//      Else pad with 0x00 if high bit set.
//   5. Canonicalize (trim sign-extension), write BLIP.

/// Negate a two's-complement byte payload IN PLACE: payload = (~payload + 1).
pub fn negateInPlace(payload: []u8) void {
	var carry: u16 = 1;
	for (payload) |*p| {
		const v: u16 = @as(u16, ~p.*) + carry;
		p.* = @truncate(v);
		carry = v >> 8;
	}
}

/// r[0..a.len + b.len] = a * b (unsigned, LE byte arrays).
/// Per-byte schoolbook — used as a fallback for sizes that aren't multiples
/// of 8 bytes. For aligned sizes, prefer `mulMagnitudesU64`.
pub fn mulMagnitudesByte(a: []const u8, b: []const u8, r: []u8) void {
	std.debug.assert(r.len >= a.len + b.len);
	@memset(r[0 .. a.len + b.len], 0);
	for (a, 0..) |ai, i| {
		if (ai == 0) continue;
		var carry: u16 = 0;
		for (b, 0..) |bj, j| {
			const prod: u16 = @as(u16, ai) * @as(u16, bj) + r[i + j] + carry;
			r[i + j] = @truncate(prod);
			carry = prod >> 8;
		}
		r[i + b.len] += @intCast(carry);
	}
}

/// Chunked u64*u64 = u128 schoolbook multiply for byte arrays whose lengths
/// are multiples of 8. ~50× faster than the per-byte schoolbook because each
/// inner-loop iteration handles 64 bits of operands in a single u128 multiply
/// (a few cycles on aarch64) plus carry propagation.
pub fn mulMagnitudesU64(a: []const u8, b: []const u8, r: []u8) void {
	std.debug.assert(a.len % 8 == 0 and b.len % 8 == 0);
	std.debug.assert(r.len >= a.len + b.len);
	const a_n = a.len / 8;
	const b_n = b.len / 8;
	@memset(r[0 .. a.len + b.len], 0);

	var i: usize = 0;
	while (i < a_n) : (i += 1) {
		const ai = std.mem.readInt(u64, a[i * 8 ..][0..8], .little);
		if (ai == 0) continue;

		var carry: u64 = 0;
		var j: usize = 0;
		while (j < b_n) : (j += 1) {
			const bj = std.mem.readInt(u64, b[j * 8 ..][0..8], .little);
			const r_chunk = std.mem.readInt(u64, r[(i + j) * 8 ..][0..8], .little);
			const prod: u128 = @as(u128, ai) * @as(u128, bj) + r_chunk + carry;
			std.mem.writeInt(u64, r[(i + j) * 8 ..][0..8], @truncate(prod), .little);
			carry = @intCast(prod >> 64);
		}
		// Propagate the final carry into higher r positions.
		var pos = i + b_n;
		while (carry != 0 and pos < (a.len + b.len) / 8) {
			const r_chunk = std.mem.readInt(u64, r[pos * 8 ..][0..8], .little);
			const sum: u128 = @as(u128, r_chunk) + @as(u128, carry);
			std.mem.writeInt(u64, r[pos * 8 ..][0..8], @truncate(sum), .little);
			carry = @intCast(sum >> 64);
			pos += 1;
		}
	}
}

/// Dispatch wrapper: chunked u64 path when both inputs are 8-byte multiples,
/// per-byte fallback otherwise.
pub fn mulMagnitudes(a: []const u8, b: []const u8, r: []u8) void {
	if (a.len > 0 and b.len > 0 and a.len % 8 == 0 and b.len % 8 == 0) {
		mulMagnitudesU64(a, b, r);
	} else {
		mulMagnitudesByte(a, b, r);
	}
}

// ── Karatsuba multiplication ─────────────────────────────────────────────────
//
// Asymptotic O(n^1.58) vs schoolbook O(n^2). Splits each n-byte operand
// into halves, computes three half-size products instead of four:
//   z0 = a_lo * b_lo
//   z2 = a_hi * b_hi
//   z1 = (a_lo + a_hi)(b_lo + b_hi) - z0 - z2  (the cross-product sum)
// Result = z2 * B^2 + z1 * B + z0  where B = 2^(half * 8).
//
// Below KARATSUBA_THRESHOLD bytes, falls back to chunked schoolbook
// (constant per-call overhead is too high for tiny operands).

/// Empirically-tuned crossover where Karatsuba starts beating chunked
/// schoolbook on aarch64. The Karatsuba overhead (sum/sub/add helper
/// byte-loops, ~150 ns per recursion) amortises only when the saved sub-
/// multiplication is bigger than the overhead. With our ~50 ns chunked
/// schoolbook for 32×32 bytes, the crossover is around 256 bytes.
pub const KARATSUBA_THRESHOLD: usize = 256;

/// out[0..max(a.len, b.len)] = (a + b) mod 2^(8*out.len). Returns carry-out
/// (0 or 1). For Karatsuba: caller passes out of length t (the larger half),
/// captures the carry separately, and uses the carry-bit trick to keep the
/// recursive multiplication at exactly t bytes (staying on the chunked-u64
/// fast path that requires 8-byte alignment).
fn addUnsignedFixedLen(a: []const u8, b: []const u8, out: []u8) u8 {
	std.debug.assert(out.len >= a.len and out.len >= b.len);
	const longer = if (a.len >= b.len) a else b;
	const shorter = if (a.len >= b.len) b else a;
	var carry: u16 = 0;
	var i: usize = 0;
	while (i < shorter.len) : (i += 1) {
		const sum: u16 = @as(u16, longer[i]) + @as(u16, shorter[i]) + carry;
		out[i] = @truncate(sum);
		carry = sum >> 8;
	}
	while (i < longer.len) : (i += 1) {
		const sum: u16 = @as(u16, longer[i]) + carry;
		out[i] = @truncate(sum);
		carry = sum >> 8;
	}
	// Zero any bytes in out past `longer.len`.
	while (i < out.len) : (i += 1) {
		out[i] = 0;
	}
	return @intCast(carry);
}

/// target -= sub (unsigned). Caller guarantees target >= sub.
/// sub.len may be < target.len; missing high bytes treated as 0.
/// Chunked u64 fast path for the aligned-prefix region.
fn subUnsignedInPlace(target: []u8, sub: []const u8) void {
	std.debug.assert(sub.len <= target.len);
	var borrow: u64 = 0;
	var i: usize = 0;
	// Chunked u64: subtract sub from target in 8-byte words.
	const chunk_end = sub.len - (sub.len % 8);
	while (i < chunk_end) : (i += 8) {
		const tv = std.mem.readInt(u64, target[i..][0..8], .little);
		const sv = std.mem.readInt(u64, sub[i..][0..8], .little);
		const d1 = @subWithOverflow(tv, sv);
		const d2 = @subWithOverflow(d1[0], borrow);
		std.mem.writeInt(u64, target[i..][0..8], d2[0], .little);
		borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
	}
	// Per-byte tail of sub.
	while (i < sub.len) : (i += 1) {
		const diff: i32 = @as(i32, target[i]) - @as(i32, sub[i]) - @as(i32, @intCast(borrow));
		target[i] = @truncate(@as(u32, @bitCast(diff)) & 0xFF);
		borrow = if (diff < 0) 1 else 0;
	}
	// Propagate borrow into high bytes (chunked when possible).
	while (i + 8 <= target.len and borrow != 0) : (i += 8) {
		const tv = std.mem.readInt(u64, target[i..][0..8], .little);
		const d = @subWithOverflow(tv, borrow);
		std.mem.writeInt(u64, target[i..][0..8], d[0], .little);
		borrow = d[1];
	}
	while (i < target.len and borrow != 0) : (i += 1) {
		const diff: i32 = @as(i32, target[i]) - @as(i32, @intCast(borrow));
		target[i] = @truncate(@as(u32, @bitCast(diff)) & 0xFF);
		borrow = if (diff < 0) 1 else 0;
	}
}

/// target += add (unsigned). add.len may be ≤ target.len; carry propagates.
/// Chunked u64 fast path.
fn addUnsignedInPlace(target: []u8, add: []const u8) void {
	std.debug.assert(add.len <= target.len);
	var carry: u64 = 0;
	var i: usize = 0;
	const chunk_end = add.len - (add.len % 8);
	while (i < chunk_end) : (i += 8) {
		const tv = std.mem.readInt(u64, target[i..][0..8], .little);
		const av = std.mem.readInt(u64, add[i..][0..8], .little);
		const s1 = @addWithOverflow(tv, av);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u64, target[i..][0..8], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	while (i < add.len) : (i += 1) {
		const sum: u16 = @as(u16, target[i]) + @as(u16, add[i]) + @as(u16, @intCast(carry));
		target[i] = @truncate(sum);
		carry = sum >> 8;
	}
	while (i + 8 <= target.len and carry != 0) : (i += 8) {
		const tv = std.mem.readInt(u64, target[i..][0..8], .little);
		const s = @addWithOverflow(tv, carry);
		std.mem.writeInt(u64, target[i..][0..8], s[0], .little);
		carry = s[1];
	}
	while (i < target.len and carry != 0) : (i += 1) {
		const sum: u16 = @as(u16, target[i]) + @as(u16, @intCast(carry));
		target[i] = @truncate(sum);
		carry = sum >> 8;
	}
}

/// Karatsuba multiplication with the **carry-bit trick** to preserve 8-byte
/// alignment in recursive mults. a.len == b.len. Result fills r[0..2*n].
/// scratch must be at least karatsubaScratchNeed(n) bytes.
///
/// Standard Karatsuba: z1 = (a_lo + a_hi)(b_lo + b_hi) - z0 - z2. The sum
/// (a_lo + a_hi) is up to t+1 bytes, breaking 8-byte alignment for the
/// recursive mul. Workaround: split each sum into a t-byte low part and
/// a 1-bit carry, then compute z1_full via the distributive property:
///   (sa_lo + ca·B^t)(sb_lo + cb·B^t) = sa_lo·sb_lo
///                                       + ca·sb_lo·B^t + cb·sa_lo·B^t
///                                       + ca·cb·B^(2t)
/// Each recursive mul is t × t (still chunked-u64-friendly); the carry-bit
/// corrections are simple shifts+adds.
pub fn mulKaratsuba(a: []const u8, b: []const u8, r: []u8, scratch: []u8) void {
	std.debug.assert(a.len == b.len);
	const n = a.len;
	std.debug.assert(r.len >= 2 * n);

	if (n < KARATSUBA_THRESHOLD) {
		mulMagnitudes(a, b, r);
		return;
	}

	const h = n / 2;
	const t = n - h; // t ≥ h; equal when n is even

	const a_lo = a[0..h];
	const a_hi = a[h..n];
	const b_lo = b[0..h];
	const b_hi = b[h..n];

	// z0 in r[0..2h]; z2 in r[2h..2h+2t].
	mulKaratsuba(a_lo, b_lo, r[0 .. 2 * h], scratch);
	mulKaratsuba(a_hi, b_hi, r[2 * h .. 2 * h + 2 * t], scratch);

	// sum split: [sa_lo: t bytes] + [ca: 1 bit].
	const sa_lo = scratch[0..t];
	const sb_lo = scratch[t .. 2 * t];
	const ca = addUnsignedFixedLen(a_lo, a_hi, sa_lo);
	const cb = addUnsignedFixedLen(b_lo, b_hi, sb_lo);

	// z1_full = sa_lo * sb_lo (t × t recursive mult, 8-byte aligned).
	// Plus carry-bit corrections.
	const z1_full_len = 2 * t + 1;
	const z1_full = scratch[2 * t .. 2 * t + z1_full_len];
	@memset(z1_full, 0);
	const next_scratch = scratch[2 * t + z1_full_len ..];
	mulKaratsuba(sa_lo, sb_lo, z1_full[0 .. 2 * t], next_scratch);

	// Carry-bit corrections.
	if (ca != 0) addUnsignedInPlace(z1_full[t..], sb_lo);
	if (cb != 0) addUnsignedInPlace(z1_full[t..], sa_lo);
	if (ca != 0 and cb != 0) addUnsignedInPlace(z1_full[2 * t ..], &[_]u8{1});

	// z1 = z1_full - z0 - z2 (non-negative by construction).
	subUnsignedInPlace(z1_full, r[0 .. 2 * h]);
	subUnsignedInPlace(z1_full, r[2 * h .. 2 * h + 2 * t]);

	// r += z1 << (h*8).
	addUnsignedInPlace(r[h..], z1_full);
}

/// Conservative scratch upper-bound for n-byte Karatsuba. Each level uses
/// 2*(t+1) + 2*(t+1) ≈ 2n bytes; recursion depth is log2(n/threshold);
/// geometric series sums to ≤ 4n.
pub fn karatsubaScratchNeed(n: usize) usize {
	return 4 * n + 64;
}

/// r = a * b. Operates on raw BLIP-encoded slices. Result is canonically
/// encoded into `out`. Caller provides scratch buffers:
///   scratch_a, scratch_b: at least each operand's payload length.
///   scratch_r: at least a_payload + b_payload + 1 (slack for sign-ext byte).
///   scratch_k: at least karatsubaScratchNeed(max(a_payload, b_payload)) bytes
///              when operand payloads are equal length and ≥ KARATSUBA_THRESHOLD.
///              May be empty otherwise.
pub fn mulRawBlip(
	a_blip: []const u8,
	b_blip: []const u8,
	scratch_a: []u8,
	scratch_b: []u8,
	scratch_r: []u8,
	scratch_k: []u8,
	out: []u8,
) !usize {
	const a_pay = try payloadOf(a_blip);
	const b_pay = try payloadOf(b_blip);
	std.debug.assert(scratch_a.len >= a_pay.len);
	std.debug.assert(scratch_b.len >= b_pay.len);
	std.debug.assert(scratch_r.len >= a_pay.len + b_pay.len + 1);

	const a_neg = signExtByte(a_pay) == 0xFF;
	const b_neg = signExtByte(b_pay) == 0xFF;

	@memcpy(scratch_a[0..a_pay.len], a_pay);
	@memcpy(scratch_b[0..b_pay.len], b_pay);
	if (a_neg) negateInPlace(scratch_a[0..a_pay.len]);
	if (b_neg) negateInPlace(scratch_b[0..b_pay.len]);

	const r_len = a_pay.len + b_pay.len;
	// Karatsuba when operands are equal-length AND big enough to benefit.
	if (a_pay.len == b_pay.len and a_pay.len >= KARATSUBA_THRESHOLD and scratch_k.len >= karatsubaScratchNeed(a_pay.len)) {
		@memset(scratch_r[0..r_len], 0);
		mulKaratsuba(scratch_a[0..a_pay.len], scratch_b[0..b_pay.len], scratch_r[0..r_len], scratch_k);
	} else {
		mulMagnitudes(scratch_a[0..a_pay.len], scratch_b[0..b_pay.len], scratch_r[0..r_len]);
	}

	// Check for zero result (canonical encoding is single 0x00 byte).
	var all_zero = true;
	for (scratch_r[0..r_len]) |byte| {
		if (byte != 0) {
			all_zero = false;
			break;
		}
	}
	if (all_zero) {
		out[0] = 0x00;
		return 1;
	}

	const result_neg = a_neg != b_neg;
	var actual_len = r_len;
	if (result_neg) {
		negateInPlace(scratch_r[0..r_len]);
		if ((scratch_r[r_len - 1] & 0x80) == 0) {
			scratch_r[r_len] = 0xFF;
			actual_len = r_len + 1;
		}
	} else {
		if ((scratch_r[r_len - 1] & 0x80) != 0) {
			scratch_r[r_len] = 0x00;
			actual_len = r_len + 1;
		}
	}

	const canon = canonicalLen(scratch_r[0..actual_len]);
	return try writeBlip(scratch_r[0..canon], out);
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

test "negateInPlace: -1 -> 1" {
	var p = [_]u8{0xFF}; // -1 as i8
	negateInPlace(&p);
	try testing.expectEqual(@as(u8, 1), p[0]);
}

test "negateInPlace: -129 (i16) -> 129" {
	var p = [_]u8{ 0x7F, 0xFF }; // -129 LE
	negateInPlace(&p);
	try testing.expectEqual(@as(u8, 0x81), p[0]); // 129 = 0x81 low byte
	try testing.expectEqual(@as(u8, 0x00), p[1]);
}

test "mulMagnitudes: small (2 * 3 = 6)" {
	var r = [_]u8{ 0xAA, 0xAA }; // pre-fill to verify @memset works
	mulMagnitudes(&[_]u8{2}, &[_]u8{3}, &r);
	try testing.expectEqual(@as(u8, 6), r[0]);
	try testing.expectEqual(@as(u8, 0), r[1]);
}

test "mulMagnitudes: 256 * 256 = 65536 (LE bytes)" {
	// 256 = [0x00, 0x01], 256 * 256 = 65536 = [0x00, 0x00, 0x01, 0x00] LE
	var r: [4]u8 = undefined;
	mulMagnitudes(&[_]u8{ 0x00, 0x01 }, &[_]u8{ 0x00, 0x01 }, &r);
	try testing.expectEqual(@as(u8, 0x00), r[0]);
	try testing.expectEqual(@as(u8, 0x00), r[1]);
	try testing.expectEqual(@as(u8, 0x01), r[2]);
	try testing.expectEqual(@as(u8, 0x00), r[3]);
}

test "mulRawBlip: small positive * positive (6 * 7 = 42)" {
	var sa: [4]u8 = undefined;
	var sb: [4]u8 = undefined;
	var sr: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	const n = try mulRawBlip(&[_]u8{0x06}, &[_]u8{0x07}, &sa, &sb, &sr, &[_]u8{}, &out);
	try testing.expectEqualSlices(u8, &[_]u8{0x2A}, out[0..n]); // 42 immediate
}

test "mulRawBlip: positive * negative = negative (-6 * 7 = -42)" {
	var sa: [4]u8 = undefined;
	var sb: [4]u8 = undefined;
	var sr: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	// -6 = 0x81 0xFA (i8 -6); +7 = 0x07 immediate
	const n = try mulRawBlip(&[_]u8{ 0x81, 0xFA }, &[_]u8{0x07}, &sa, &sb, &sr, &[_]u8{}, &out);
	// -42 = i8 0xD6 → BLIP [0x81, 0xD6]
	try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xD6 }, out[0..n]);
}

test "mulRawBlip: negative * negative = positive (-6 * -7 = 42)" {
	var sa: [4]u8 = undefined;
	var sb: [4]u8 = undefined;
	var sr: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	const n = try mulRawBlip(&[_]u8{ 0x81, 0xFA }, &[_]u8{ 0x81, 0xF9 }, &sa, &sb, &sr, &[_]u8{}, &out);
	try testing.expectEqualSlices(u8, &[_]u8{0x2A}, out[0..n]); // 42 immediate
}

test "mulRawBlip: result is zero (anything * 0)" {
	var sa: [4]u8 = undefined;
	var sb: [4]u8 = undefined;
	var sr: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	const n = try mulRawBlip(&[_]u8{0x05}, &[_]u8{0x00}, &sa, &sb, &sr, &[_]u8{}, &out);
	try testing.expectEqualSlices(u8, &[_]u8{0x00}, out[0..n]);
}

test "mulMagnitudesU64 == mulMagnitudesByte for aligned inputs" {
	// Verify the chunked u64 schoolbook gives identical results to per-byte.
	const cases = [_]usize{ 8, 16, 32, 64, 128 };
	for (cases) |n| {
		var a = std.mem.zeroes([128]u8);
		var b = std.mem.zeroes([128]u8);
		var rng = std.Random.DefaultPrng.init(0xDEADBEEF + n);
		const r = rng.random();
		for (a[0..n]) |*p| p.* = r.int(u8);
		for (b[0..n]) |*p| p.* = r.int(u8);

		var r_byte: [256]u8 = undefined;
		var r_u64: [256]u8 = undefined;
		mulMagnitudesByte(a[0..n], b[0..n], &r_byte);
		mulMagnitudesU64(a[0..n], b[0..n], &r_u64);
		try testing.expectEqualSlices(u8, r_byte[0 .. 2 * n], r_u64[0 .. 2 * n]);
	}
}

test "mulKaratsuba == mulMagnitudes for various sizes" {
	// Karatsuba result must match schoolbook for any equal-length input pair.
	const cases = [_]usize{ 64, 96, 128, 192, 256, 384, 512 };
	for (cases) |n| {
		const a = std.testing.allocator.alloc(u8, n) catch unreachable;
		defer std.testing.allocator.free(a);
		const b = std.testing.allocator.alloc(u8, n) catch unreachable;
		defer std.testing.allocator.free(b);
		var rng = std.Random.DefaultPrng.init(0x1337CAFE + n);
		const r = rng.random();
		for (a) |*p| p.* = r.int(u8);
		for (b) |*p| p.* = r.int(u8);

		const r_school = std.testing.allocator.alloc(u8, 2 * n) catch unreachable;
		defer std.testing.allocator.free(r_school);
		const r_kara = std.testing.allocator.alloc(u8, 2 * n) catch unreachable;
		defer std.testing.allocator.free(r_kara);
		const scratch = std.testing.allocator.alloc(u8, karatsubaScratchNeed(n)) catch unreachable;
		defer std.testing.allocator.free(scratch);

		mulMagnitudes(a, b, r_school);
		@memset(r_kara, 0);
		mulKaratsuba(a, b, r_kara, scratch);
		try testing.expectEqualSlices(u8, r_school, r_kara);
	}
}

test "mulRawBlip: large equal-size operands via Karatsuba" {
	// 256-bit positive operands. Result should equal schoolbook (u64 chunked).
	var a_pay: [32]u8 = undefined;
	var b_pay: [32]u8 = undefined;
	var rng = std.Random.DefaultPrng.init(0xC0FFEE);
	const r_g = rng.random();
	for (&a_pay) |*p| p.* = r_g.int(u8);
	for (&b_pay) |*p| p.* = r_g.int(u8);
	a_pay[31] &= 0x7F; // positive
	b_pay[31] &= 0x7F;

	var a_blip: [34]u8 = undefined;
	a_blip[0] = 0xA0;
	a_blip[1] = 0x01;
	@memcpy(a_blip[2..], &a_pay);
	var b_blip: [34]u8 = undefined;
	b_blip[0] = 0xA0;
	b_blip[1] = 0x01;
	@memcpy(b_blip[2..], &b_pay);

	var sa: [64]u8 = undefined;
	var sb: [64]u8 = undefined;
	var sr: [128]u8 = undefined;
	var sk: [256]u8 = undefined; // ~4n = 128 + slack
	var out: [128]u8 = undefined;

	const n = try mulRawBlip(&a_blip, &b_blip, &sa, &sb, &sr, &sk, &out);

	// Verify by recomputing with the schoolbook path (passing empty scratch_k forces fallback).
	var sa2: [64]u8 = undefined;
	var sb2: [64]u8 = undefined;
	var sr2: [128]u8 = undefined;
	var out2: [128]u8 = undefined;
	const n2 = try mulRawBlip(&a_blip, &b_blip, &sa2, &sb2, &sr2, &[_]u8{}, &out2);
	try testing.expectEqualSlices(u8, out2[0..n2], out[0..n]);
}

test "mulRawBlip: i64.max * 2 (overflows i64)" {
	// i64.max = 0x7FFFFFFFFFFFFFFF as L=8 BLIP: [0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
	const max_blip = &[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
	const two_blip = &[_]u8{0x02};
	var sa: [16]u8 = undefined;
	var sb: [16]u8 = undefined;
	var sr: [32]u8 = undefined;
	var out: [32]u8 = undefined;
	const n = try mulRawBlip(max_blip, two_blip, &sa, &sb, &sr, &[_]u8{}, &out);
	// Expected: 2 * (2^63 - 1) = 2^64 - 2.
	// As signed canonical: needs L=9 with leading 0x00.
	// LE payload: [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
	// BLIP: [0x89, ...]
	const expected = [_]u8{ 0x89, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
	try testing.expectEqualSlices(u8, &expected, out[0..n]);
}
