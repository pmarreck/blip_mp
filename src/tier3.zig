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
const fft = @import("fft.zig");

// FFT dispatch threshold (bytes per operand). Operand payload-byte count
// at-or-above which the production multiply path uses the NTT-based
// `fft.mulMagnitudesWithScratch` instead of Toom-3 / Karatsuba / schoolbook.
//
// Currently DISABLED (99999). Even after M6-4-E.1+E.2 (caller-supplied
// scratch + Stockham auto-sort wired through `fft_scratch` cache,
// eliminating per-call alloc/free of 5 large u64 buffers), the FFT path
// at 32K-bit measures ~128K ns/op vs Toom-3's 119K ns — a ~7-8% gap
// remains across our entire supported size range:
//   16K-bit:  Toom-3 39K vs FFT  56K  (FFT 1.43x slower)
//   32K-bit:  Toom-3 119K vs FFT 128K (FFT 1.08x slower)
//   49K-bit:  Toom-3 206K vs FFT 258K (FFT 1.25x slower)
// 65K-bit and up exceed MAX_FFT_COMBINED_LEN=14000 so always use Toom-3.
//
// E.1+E.2 dropped FFT from 135K → 128K at 32K-bit (a real 4-5% win on
// the FFT path itself) — see PLAN.md M6-4-E for the remaining levers
// (E.3: hand-scheduled aarch64 inline asm; E.4: accept Toom-3).
pub const FFT_THRESHOLD: usize = 99999;

// ── Per-thread FFT scratch cache (M6-4-E.1) ──────────────────────────────────
//
// Eliminates the per-call alloc/free of the 5 large u64 buffers FFT
// multiplication needs (pa, pb, tw_fwd, tw_inv, stockham_scratch). At
// N=8192 those allocations cost ~4-8 K ns on libc malloc; with caller-
// supplied scratch we pay that once per thread, never again.
//
// The cache holds the largest buffers we've ever requested. Because the
// 4 "N-sized" buffers and "N/2-sized" twiddle tables compose monotonically,
// we just track `cached_N` and grow on first miss for a larger size.
// Any subsequent call with `N <= cached_N` reuses the existing slabs in O(1).
//
// Thread-local: each thread has its own cache. No locking. The cost is one
// `threadlocal` lookup per FFT-eligible mul (single TLS load on aarch64).
//
// Allocator: borrowed from the FFT path's `fft_alloc` argument the first
// time we allocate; reused thereafter. If a different allocator is passed
// later the cache transparently reallocates — but in practice every caller
// uses the same `Mp.allocator` for its lifetime.
const FftScratch = struct {
	cached_N: usize = 0,
	pa: []u64 = &.{},
	pb: []u64 = &.{},
	tw_fwd: []u64 = &.{},
	tw_inv: []u64 = &.{},
	stockham: []u64 = &.{},
	owner_alloc: ?std.mem.Allocator = null,

	fn ensureCapacity(self: *FftScratch, allocator: std.mem.Allocator, N: usize) !void {
		if (self.cached_N >= N and self.owner_alloc != null) {
			// Cache hit. Allocator identity is checked on alloc to avoid
			// freeing under the wrong allocator below.
			if (allocatorEq(self.owner_alloc.?, allocator)) return;
			// Allocator changed — release under the old one and re-alloc.
			self.releaseUnsafe();
		}
		// Need to (re)allocate with the new size.
		if (self.owner_alloc) |old_alloc| {
			old_alloc.free(self.pa);
			old_alloc.free(self.pb);
			old_alloc.free(self.tw_fwd);
			old_alloc.free(self.tw_inv);
			old_alloc.free(self.stockham);
		}
		self.pa = try allocator.alloc(u64, N);
		errdefer allocator.free(self.pa);
		self.pb = try allocator.alloc(u64, N);
		errdefer allocator.free(self.pb);
		self.tw_fwd = try allocator.alloc(u64, N / 2);
		errdefer allocator.free(self.tw_fwd);
		self.tw_inv = try allocator.alloc(u64, N / 2);
		errdefer allocator.free(self.tw_inv);
		self.stockham = try allocator.alloc(u64, N);
		self.cached_N = N;
		self.owner_alloc = allocator;
	}

	fn releaseUnsafe(self: *FftScratch) void {
		if (self.owner_alloc) |a| {
			a.free(self.pa);
			a.free(self.pb);
			a.free(self.tw_fwd);
			a.free(self.tw_inv);
			a.free(self.stockham);
		}
		self.* = .{};
	}
};

inline fn allocatorEq(a: std.mem.Allocator, b: std.mem.Allocator) bool {
	return a.ptr == b.ptr and a.vtable == b.vtable;
}

threadlocal var fft_scratch: FftScratch = .{};

/// Release any per-thread FFT scratch buffers held by this thread.
/// Optional: long-lived processes that want to reclaim memory after a
/// burst of large multiplications can call this. Tests use it to satisfy
/// leak detectors when the production code allocates through a tracked
/// allocator. Idempotent.
pub fn releaseFftScratch() void {
	fft_scratch.releaseUnsafe();
}

// Two-prime CRT FFT dispatch threshold (bytes per operand). Lifts the
// per-operand cap from ~7K bytes (single-prime) to ~32K bytes by running the
// convolution under TWO NTT-friendly primes (998244353 and 985661441) and
// CRT-merging each digit via Garner's form. See `mulMagnitudesCRT` in fft.zig.
//
// Default: DISABLED (99999). Bench (2026-05-02, M4) shows CRT-FFT loses to
// Toom-3 across the entire supported range:
//   16384-bit:  Toom-3  39196 ns vs CRT-FFT 176547 ns (4.5x slower)
//   32768-bit:  Toom-3 117304 ns vs CRT-FFT 379836 ns (3.2x slower)
//   49152-bit:  Toom-3 200425 ns vs CRT-FFT 807460 ns (4.0x slower)
//   65536-bit:  Toom-3 353955 ns vs CRT-FFT 818249 ns (2.3x slower)
//   98304-bit:  Toom-3 606920 ns vs CRT-FFT 1891244 ns (3.1x slower)
// CRT doubles the NTT work (two convolutions instead of one) so the constant
// factor is ~2x worse than the single-prime FFT, which already lost to Toom-3.
// Path forward: SIMD butterflies (NEON ~2-4x), Stockham auto-sort (skip the
// bit-reverse), or Montgomery multiplication. Until then, kept correctness-
// validated and ready to enable behind this single threshold.
pub const FFT_CRT_THRESHOLD: usize = 99999;

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

/// Subtract: r = a - b. Same chunked-ladder approach as addPayloads, but with
/// borrow propagation via @subWithOverflow. Two's-complement-direct, no sign-
/// magnitude. Mirrors the u512/u256/u128/u64 chunking that lets LLVM emit
/// optimal SBC chains on aarch64 (closing the >4096-bit sub gap to GMP and
/// erasing what was a ~10-100x regression vs. addPayloads).
pub fn subPayloads(
	a: []const u8,
	b: []const u8,
	n: usize,
	out: []u8,
) usize {
	std.debug.assert(out.len >= n + 1);
	const sa = signExtByte(a);
	const sb = signExtByte(b);
	const sa_word: u64 = if (sa == 0xFF) ~@as(u64, 0) else 0;
	const sb_word: u64 = if (sb == 0xFF) ~@as(u64, 0) else 0;

	var borrow: u64 = 0;
	var i: usize = 0;
	// Chunked u512 path: 64 bytes per iter when operands are large enough
	// (4096-bit and up). Each u512 sub compiles to 8 SBCS instructions on
	// aarch64. Mirrors the addPayloads chunking ladder.
	const both_end = chunkEndForLen(@min(a.len, b.len), n);
	const both_end_64 = both_end - (both_end % 64);
	while (i + 64 <= both_end_64) : (i += 64) {
		const av: u512 = std.mem.readInt(u512, a[i..][0..64], .little);
		const bv: u512 = std.mem.readInt(u512, b[i..][0..64], .little);
		const d1 = @subWithOverflow(av, bv);
		const d2 = @subWithOverflow(d1[0], borrow);
		std.mem.writeInt(u512, out[i..][0..64], d2[0], .little);
		borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
	}
	// u256 chunks for the next size band.
	const both_end_32 = both_end - (both_end % 32);
	while (i + 32 <= both_end_32) : (i += 32) {
		const av: u256 = std.mem.readInt(u256, a[i..][0..32], .little);
		const bv: u256 = std.mem.readInt(u256, b[i..][0..32], .little);
		const d1 = @subWithOverflow(av, bv);
		const d2 = @subWithOverflow(d1[0], borrow);
		std.mem.writeInt(u256, out[i..][0..32], d2[0], .little);
		borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
	}
	// u128 chunks for the remaining 16-byte slots.
	while (i + 16 <= both_end) : (i += 16) {
		const av: u128 = std.mem.readInt(u128, a[i..][0..16], .little);
		const bv: u128 = std.mem.readInt(u128, b[i..][0..16], .little);
		const d1 = @subWithOverflow(av, bv);
		const d2 = @subWithOverflow(d1[0], borrow);
		std.mem.writeInt(u128, out[i..][0..16], d2[0], .little);
		borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
	}
	// u64 chunks within the both-have-real-bytes region.
	while (i + 8 <= both_end) : (i += 8) {
		const av: u64 = std.mem.readInt(u64, a[i..][0..8], .little);
		const bv: u64 = std.mem.readInt(u64, b[i..][0..8], .little);
		const d1 = @subWithOverflow(av, bv);
		const d2 = @subWithOverflow(d1[0], borrow);
		std.mem.writeInt(u64, out[i..][0..8], d2[0], .little);
		borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
	}
	// u64 chunks past one operand's real-bytes boundary — at least one side
	// reads from sign-extension fill words.
	while (i + 8 <= n) : (i += 8) {
		const av: u64 = readPayloadChunk(a, i, sa_word);
		const bv: u64 = readPayloadChunk(b, i, sb_word);
		const d1 = @subWithOverflow(av, bv);
		const d2 = @subWithOverflow(d1[0], borrow);
		std.mem.writeInt(u64, out[i..][0..8], d2[0], .little);
		borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
	}
	// Per-byte tail (last < 8 bytes).
	while (i < n) : (i += 1) {
		const av: i32 = payloadByteAt(a, i, sa);
		const bv: i32 = payloadByteAt(b, i, sb);
		const diff = av - bv - @as(i32, @intCast(borrow));
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
	// Two's-complement negate: invert all bytes, add 1 with carry. The naive
	// per-byte form was the original M3 implementation. Chunked u64 form
	// (mirrors the addPayloads / subPayloads pattern from M3 and iter 6):
	// invert the chunk, add carry as u128 to detect overflow, write low 64
	// bits back. ~6-8x faster at 256+ bytes (2K+ bit) than per-byte.
	if (payload.len < 8) {
		var carry: u16 = 1;
		for (payload) |*p| {
			const v: u16 = @as(u16, ~p.*) + carry;
			p.* = @truncate(v);
			carry = v >> 8;
		}
		return;
	}

	var i: usize = 0;
	var carry: u64 = 1;
	const chunks = payload.len / 8;
	while (i < chunks) : (i += 1) {
		const off = i * 8;
		const x = std.mem.readInt(u64, payload[off..][0..8], .little);
		const inverted = ~x;
		const sum: u128 = @as(u128, inverted) + @as(u128, carry);
		std.mem.writeInt(u64, payload[off..][0..8], @truncate(sum), .little);
		carry = @intCast(sum >> 64);
	}
	// Tail bytes (< 8) of the input.
	var b: usize = chunks * 8;
	while (b < payload.len) : (b += 1) {
		const v: u16 = @as(u16, ~payload[b]) + @as(u16, @intCast(carry));
		payload[b] = @truncate(v);
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

/// Read 8 bytes from `buf` starting at byte_off. Past-end bytes read as 0.
inline fn readChunkOrZero(buf: []const u8, byte_off: usize) u64 {
	if (byte_off + 8 <= buf.len) {
		return std.mem.readInt(u64, buf[byte_off..][0..8], .little);
	}
	if (byte_off >= buf.len) return 0;
	var bytes: [8]u8 = .{0} ** 8;
	@memcpy(bytes[0 .. buf.len - byte_off], buf[byte_off..]);
	return std.mem.readInt(u64, &bytes, .little);
}

/// Write 8 bytes (val LE) to `buf` at byte_off. Bytes past buf.len silently dropped.
inline fn writeChunkTruncated(buf: []u8, byte_off: usize, val: u64) void {
	if (byte_off + 8 <= buf.len) {
		std.mem.writeInt(u64, buf[byte_off..][0..8], val, .little);
		return;
	}
	if (byte_off >= buf.len) return;
	var bytes: [8]u8 = undefined;
	std.mem.writeInt(u64, &bytes, val, .little);
	@memcpy(buf[byte_off..], bytes[0 .. buf.len - byte_off]);
}

/// Chunked u64*u64 = u128 schoolbook for ANY-length unsigned LE byte arrays.
/// Reads/writes partial trailing chunks with zero-fill / truncate, so no
/// stack-pad round-trip is needed. Same O(n²) work as the aligned variant
/// but applies uniformly to non-multiple-of-8 sizes (common in Toom-3
/// recursive sub-mults).
pub fn mulMagnitudesU64Unaligned(a: []const u8, b: []const u8, r: []u8) void {
	std.debug.assert(r.len >= a.len + b.len);
	@memset(r[0 .. a.len + b.len], 0);
	if (a.len == 0 or b.len == 0) return;

	const a_chunks = (a.len + 7) / 8;
	const b_chunks = (b.len + 7) / 8;

	var i: usize = 0;
	while (i < a_chunks) : (i += 1) {
		const ai = readChunkOrZero(a, i * 8);
		if (ai == 0) continue;
		var carry: u64 = 0;
		var j: usize = 0;
		while (j < b_chunks) : (j += 1) {
			const bj = readChunkOrZero(b, j * 8);
			const r_off = (i + j) * 8;
			const r_chunk = readChunkOrZero(r, r_off);
			const prod: u128 = @as(u128, ai) * @as(u128, bj) + r_chunk + carry;
			writeChunkTruncated(r, r_off, @truncate(prod));
			carry = @intCast(prod >> 64);
		}
		// Propagate the final carry into higher r positions (chunked).
		var pos = i + b_chunks;
		while (carry != 0) {
			const r_off = pos * 8;
			if (r_off >= r.len) break; // by math, carry should be 0 here
			const r_chunk = readChunkOrZero(r, r_off);
			const sum: u128 = @as(u128, r_chunk) + @as(u128, carry);
			writeChunkTruncated(r, r_off, @truncate(sum));
			carry = @intCast(sum >> 64);
			pos += 1;
		}
	}
}

/// Dispatch wrapper: prefer chunked u64 for any size > 0. Aligned sizes use
/// the tighter `mulMagnitudesU64`; unaligned sizes use the partial-chunk
/// `mulMagnitudesU64Unaligned`. Per-byte schoolbook is reserved for the
/// rare case of zero-length operands (effectively unreachable).
pub fn mulMagnitudes(a: []const u8, b: []const u8, r: []u8) void {
	if (a.len == 0 or b.len == 0) {
		@memset(r[0 .. a.len + b.len], 0);
		return;
	}
	if (a.len % 8 == 0 and b.len % 8 == 0) {
		mulMagnitudesU64(a, b, r);
		return;
	}
	mulMagnitudesU64Unaligned(a, b, r);
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
/// byte-loops + memset of z1_full + recursive call frames) amortises only
/// when the saved sub-multiplication is bigger than the overhead.
///
/// Re-tuned 2026-05-02: for our chunked-u64 schoolbook (≈ 0.0105 ns/byte²
/// on aarch64 M-series), schoolbook at 256 B costs ≈ 690 ns while the
/// 3-recursion Karatsuba split into 128-B sub-mults plus two t-byte adds,
/// one t-byte sum-add, and two subtractions costs ≈ 880 ns. Crossover
/// empirically lands near 384 B (3072-bit), so bump the threshold to that.
/// At 384 B Karatsuba and schoolbook are both ≈ 1550 ns; above 384 the
/// Karatsuba scaling advantage (n^1.585 vs n²) takes over rapidly.
///
/// Side benefit: aligns RSA-2048 (256 B operands) with the schoolbook
/// fast path which beats GMP's mpn_mul_n at this size.
pub const KARATSUBA_THRESHOLD: usize = 384;

/// out[0..max(a.len, b.len)] = (a + b) mod 2^(8*out.len). Returns carry-out
/// (0 or 1). For Karatsuba: caller passes out of length t (the larger half),
/// captures the carry separately, and uses the carry-bit trick to keep the
/// recursive multiplication at exactly t bytes (staying on the chunked-u64
/// fast path that requires 8-byte alignment).
fn addUnsignedFixedLen(a: []const u8, b: []const u8, out: []u8) u8 {
	std.debug.assert(out.len >= a.len and out.len >= b.len);
	const longer = if (a.len >= b.len) a else b;
	const shorter = if (a.len >= b.len) b else a;
	var carry: u64 = 0;
	var i: usize = 0;
	// Chunked u64 path for the both-have-real-bytes prefix. Karatsuba's
	// caller passes operands of equal length t = ⌈n/2⌉ bytes, where t is
	// usually a multiple of 8 (the carry-bit trick keeps recursive calls
	// 8-byte-aligned). So this fast path covers ~all of the input.
	const both_aligned = shorter.len - (shorter.len % 8);
	while (i < both_aligned) : (i += 8) {
		const av = std.mem.readInt(u64, longer[i..][0..8], .little);
		const bv = std.mem.readInt(u64, shorter[i..][0..8], .little);
		const s1 = @addWithOverflow(av, bv);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u64, out[i..][0..8], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	// Per-byte tail of shorter (< 8 bytes).
	while (i < shorter.len) : (i += 1) {
		const sum: u16 = @as(u16, longer[i]) + @as(u16, shorter[i]) + @as(u16, @intCast(carry));
		out[i] = @truncate(sum);
		carry = sum >> 8;
	}
	// Chunked propagation through longer-only region, then per-byte tail.
	const longer_aligned = longer.len - ((longer.len - i) % 8);
	while (i + 8 <= longer_aligned) : (i += 8) {
		const av = std.mem.readInt(u64, longer[i..][0..8], .little);
		const s = @addWithOverflow(av, carry);
		std.mem.writeInt(u64, out[i..][0..8], s[0], .little);
		carry = s[1];
	}
	while (i < longer.len) : (i += 1) {
		const sum: u16 = @as(u16, longer[i]) + @as(u16, @intCast(carry));
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

// ── Helpers for Toom-Cook (sign-magnitude byte arithmetic) ──────────────────

/// Multiply unsigned LE byte array by a small constant c (1..255).
/// Chunked u64 inner loop: each iteration multiplies an 8-byte chunk by c
/// (u64 * u8 = u72, fits in u128) and produces an 8-byte result chunk + 1
/// carry byte. ~8× faster than per-byte for large `a_len`.
pub fn mulSmallConst(a: []const u8, a_len: usize, c: u8, out: []u8) usize {
	std.debug.assert(out.len > a_len);
	if (c == 0 or a_len == 0) return 0;

	var carry: u64 = 0;
	var i: usize = 0;
	const aligned_end = a_len - (a_len % 8);
	while (i < aligned_end) : (i += 8) {
		const word = std.mem.readInt(u64, a[i..][0..8], .little);
		const prod: u128 = @as(u128, word) * @as(u128, c) + @as(u128, carry);
		std.mem.writeInt(u64, out[i..][0..8], @truncate(prod), .little);
		carry = @intCast(prod >> 64);
	}
	// Per-byte tail (< 8 bytes remaining).
	while (i < a_len) : (i += 1) {
		const prod: u32 = @as(u32, a[i]) * @as(u32, c) + @as(u32, @intCast(carry & 0xFF));
		out[i] = @truncate(prod);
		carry = (carry >> 8) + (prod >> 8);
	}
	if (carry != 0) {
		out[i] = @intCast(carry & 0xFF);
		i += 1;
		// At most 1 extra byte for u8 c (carry ≤ 255).
	}
	while (i > 0 and out[i - 1] == 0) i -= 1;
	return i;
}

/// In-place exact division by 2 of an unsigned LE byte array.
/// Chunked u64: each iteration shifts an 8-byte word right by 1, with the
/// low bit of the next-higher word's previous value carrying in via OR
/// at the high bit. Walks high-to-low.
pub fn divExactBy2(a: []u8, a_len: usize) usize {
	if (a_len == 0) return 0;
	var carry_bit: u64 = 0; // 0 or 0x8000_0000_0000_0000
	// Process 8-byte chunks from high end down.
	const aligned_high = a_len - (a_len % 8);
	var i: usize = a_len;
	// Per-byte tail at the high end (above aligned_high).
	while (i > aligned_high) {
		i -= 1;
		const cur = a[i];
		const new_carry_byte: u8 = if ((cur & 1) != 0) 0x80 else 0;
		a[i] = (cur >> 1) | @as(u8, @intCast(carry_bit >> 56));
		carry_bit = @as(u64, new_carry_byte) << 56;
	}
	// Chunked high-to-low.
	while (i >= 8) {
		i -= 8;
		const word = std.mem.readInt(u64, a[i..][0..8], .little);
		const new_carry: u64 = (word & 1) << 63;
		const shifted = (word >> 1) | carry_bit;
		std.mem.writeInt(u64, a[i..][0..8], shifted, .little);
		carry_bit = new_carry;
	}
	var n = a_len;
	while (n > 0 and a[n - 1] == 0) n -= 1;
	return n;
}

/// In-place exact division by 3 (caller guarantees a is divisible by 3).
/// Hensel division: 3⁻¹ mod 256 = 0xAB. q[i] = (a[i] - borrow) * 0xAB mod 256.
/// New borrow = floor((q[i] * 3 + (a[i] - borrow) >> 8) / 256). For exact
/// division this is just floor((q[i] * 3) / 256) since the low byte matches.
pub fn divExactBy3(a: []u8, a_len: usize) usize {
	// Hensel exact division: 3⁻¹ ≡ 0xAB (mod 256), 3⁻¹ ≡ 0xAAAA_AAAA_AAAA_AAAB (mod 2^64).
	// Chunked u64 form: at each chunk, subtract carried borrow, multiply by inv3
	// (mod 2^64), and propagate borrow = (q * 3) >> 64 + 1 (if subtract underflowed).
	// Used by Toom-3 interpolation (and Toom-4 in future work). ~8x faster than
	// the per-byte form at 256+ byte inputs (16K+ bit Toom-3 path).
	const inv3_u8: u8 = 0xAB;
	const inv3_u64: u64 = 0xAAAA_AAAA_AAAA_AAAB;

	var i: usize = 0;
	const aligned_end = a_len - (a_len % 8);
	var borrow_wide: u64 = 0;
	while (i < aligned_end) : (i += 8) {
		const word = std.mem.readInt(u64, a[i..][0..8], .little);
		const sub = @subWithOverflow(word, borrow_wide);
		const q: u64 = sub[0] *% inv3_u64;
		std.mem.writeInt(u64, a[i..][0..8], q, .little);
		// New borrow: high half of q * 3 + 1 if sub underflowed.
		const prod: u128 = @as(u128, q) * 3;
		borrow_wide = @intCast(prod >> 64);
		if (sub[1] != 0) borrow_wide += 1;
	}
	// Per-byte tail. Carry the residual borrow as u16.
	var borrow: u16 = @intCast(borrow_wide);
	while (i < a_len) : (i += 1) {
		const cur: i32 = @as(i32, a[i]) - @as(i32, borrow);
		const cur_low: u8 = @truncate(@as(u32, @bitCast(cur)) & 0xFF);
		const q_byte: u8 = @truncate(@as(u32, cur_low) *% @as(u32, inv3_u8) & 0xFF);
		a[i] = q_byte;
		const prod: u16 = @as(u16, q_byte) * 3;
		var new_borrow: u16 = prod >> 8;
		if (cur < 0) new_borrow += 1;
		borrow = new_borrow;
	}
	var n = a_len;
	while (n > 0 and a[n - 1] == 0) n -= 1;
	return n;
}

/// Multiply a sign-magnitude value by a small unsigned constant c (0..255).
/// Returns the new (sign, len) pair; output magnitude in `out`.
/// `c == 0` zeroes the result. Sign-magnitude `0` (sign=0) absorbs any c.
pub fn mulSmallSignedConst(in: SM, mag: []const u8, c: u8, out: []u8) SM {
	if (in.sign == 0 or c == 0) return .{ .sign = 0, .len = 0 };
	const new_len = mulSmallConst(mag, in.len, c, out);
	return .{ .sign = in.sign, .len = new_len };
}

/// In-place exact division by 5 (caller guarantees a is divisible by 5).
/// Hensel division: 5⁻¹ mod 256 = 0xCD (since 5 * 0xCD = 1025 ≡ 1 mod 256).
/// Used by Toom-4 interpolation.
pub fn divExactBy5(a: []u8, a_len: usize) usize {
	// Hensel exact division: 5⁻¹ ≡ 0xCD (mod 256), 5⁻¹ ≡ 0xCCCC_CCCC_CCCC_CCCD (mod 2^64).
	// Same chunked-u64 pattern as divExactBy3.
	const inv5_u8: u8 = 0xCD;
	const inv5_u64: u64 = 0xCCCC_CCCC_CCCC_CCCD;

	var i: usize = 0;
	const aligned_end = a_len - (a_len % 8);
	var borrow_wide: u64 = 0;
	while (i < aligned_end) : (i += 8) {
		const word = std.mem.readInt(u64, a[i..][0..8], .little);
		const sub = @subWithOverflow(word, borrow_wide);
		const q: u64 = sub[0] *% inv5_u64;
		std.mem.writeInt(u64, a[i..][0..8], q, .little);
		const prod: u128 = @as(u128, q) * 5;
		borrow_wide = @intCast(prod >> 64);
		if (sub[1] != 0) borrow_wide += 1;
	}
	var borrow: u16 = @intCast(borrow_wide);
	while (i < a_len) : (i += 1) {
		const cur: i32 = @as(i32, a[i]) - @as(i32, borrow);
		const cur_low: u8 = @truncate(@as(u32, @bitCast(cur)) & 0xFF);
		const q_byte: u8 = @truncate(@as(u32, cur_low) *% @as(u32, inv5_u8) & 0xFF);
		a[i] = q_byte;
		const prod: u16 = @as(u16, q_byte) * 5;
		var new_borrow: u16 = prod >> 8;
		if (cur < 0) new_borrow += 1;
		borrow = new_borrow;
	}
	var n = a_len;
	while (n > 0 and a[n - 1] == 0) n -= 1;
	return n;
}

/// Schoolbook (textbook) long division of unsigned LE magnitude `a[0..a_len]`
/// by single-byte divisor `b`, in place. Walks high-to-low maintaining a
/// 16-bit window: w = (r << 8) | a[i]; q_byte = w/b; r = w%b. Quotient
/// canonically trimmed of trailing zero bytes; remainder returned.
/// This is the inner loop M7-3 (Knuth Algorithm D) reduces to for the
/// small-divisor case.
/// Caller guarantees b != 0.
pub fn divModSingleByte(a: []u8, a_len: usize, b: u8) struct { q_len: usize, rem: u8 } {
	std.debug.assert(b != 0);
	if (a_len == 0) return .{ .q_len = 0, .rem = 0 };
	var r: u16 = 0;
	const bb: u16 = @as(u16, b);
	var i: usize = a_len;
	while (i > 0) {
		i -= 1;
		const w: u16 = (r << 8) | @as(u16, a[i]);
		a[i] = @intCast(w / bb);
		r = w % bb;
	}
	var n = a_len;
	while (n > 0 and a[n - 1] == 0) n -= 1;
	return .{ .q_len = n, .rem = @intCast(r) };
}

/// Same schoolbook long division as `divModSingleByte`, but operating on
/// 8-byte (u64) chunks: at each step the window is (r << 64) | chunk and
/// the divide is u128/u64 → u128 quotient, u128%u64 → u64 remainder. On
/// aarch64 this lowers to a single `udiv` x-register followed by `umsub`
/// per chunk — roughly 4-6× faster than per-byte for aligned input.
///
/// Strategy for unaligned inputs: process the high partial chunk
/// byte-by-byte first to drive `r` to where the next-lowest 8-byte
/// boundary aligns; then process aligned u64 chunks down to byte 0.
/// (Picking the *low* tail instead would leave the schoolbook invariant
/// inconsistent — we'd need a chunked window with a sub-chunk shift count
/// which is awkward and slower than just walking the low byte tail
/// straight via `divModSingleByte` semantics. Doing the partial-chunk
/// work at the *high* end keeps the chunked loop pure.)
/// Caller guarantees b != 0.
pub fn divModSingleU64(a: []u8, a_len: usize, b: u64) struct { q_len: usize, rem: u64 } {
	std.debug.assert(b != 0);
	if (a_len == 0) return .{ .q_len = 0, .rem = 0 };

	// Per-byte processing of the high tail so the remaining a[0..aligned_high]
	// is an integer multiple of 8 bytes.
	const aligned_high: usize = a_len - (a_len % 8);
	var r: u64 = 0;
	var i: usize = a_len;
	while (i > aligned_high) {
		i -= 1;
		// 72-bit window safely fits in u128 (8-bit shift + 64-bit r).
		const w: u128 = (@as(u128, r) << 8) | @as(u128, a[i]);
		const q: u64 = @truncate(w / @as(u128, b));
		// q always fits in u8 only when r < b initially; in general
		// q here can exceed u8 because the shift was only 8 bits but
		// r is u64. Each per-byte step is the same inner loop as
		// divModSingleByte but with a u64 running remainder. We only
		// store one byte per step, so q must be ≤ 0xFF: it is, because
		// after the prior step r < b ≤ u64.max, and (r << 8) | byte is
		// still less than (b << 8), so q < 256. The truncate is exact.
		a[i] = @intCast(q);
		r = @intCast(w % @as(u128, b));
	}

	// Chunked u64 high-to-low.
	while (i >= 8) {
		i -= 8;
		const chunk: u64 = std.mem.readInt(u64, a[i..][0..8], .little);
		const w: u128 = (@as(u128, r) << 64) | @as(u128, chunk);
		const q: u64 = @truncate(w / @as(u128, b));
		std.mem.writeInt(u64, a[i..][0..8], q, .little);
		r = @truncate(w % @as(u128, b));
	}

	var n = a_len;
	while (n > 0 and a[n - 1] == 0) n -= 1;
	return .{ .q_len = n, .rem = r };
}

/// Knuth Algorithm D long division (TAOCP vol 2 §4.3.1) on byte-base (b=256).
///
/// Computes q = u / v and r = u %% v for unsigned LE magnitudes u and v.
/// Caller guarantees:
///   - v_len >= 2 (single-byte/u64 divisors must use divModSingleByte/U64)
///   - v[v_len-1] != 0 (v is canonical — no trailing zero byte)
///   - u[u_len-1] != 0 OR u_len == 0 (u is canonical)
///   - q_out has capacity ≥ max(u_len - v_len + 1, 1)
///   - r_out has capacity ≥ v_len
///   - work has capacity ≥ u_len + 1 + v_len  (normalized dividend + divisor)
///
/// Returns canonical lengths (trimmed of trailing zeros). q_len may be 0
/// (when u < v); r_len may be 0 (when u is exactly divisible).
///
/// Algorithm phases:
///   D1 (normalize): shift u and v left by `s` bits where s = clz(v[v_len-1])
///     in the byte sense — i.e., s is the number of leading zero BITS in the
///     top byte. After normalization v[v_len-1] >= 128, which bounds q_hat
///     overestimation to at most 2 (and after refinement, at most 1).
///   D2..D7 (main loop): for j from m down to 0, estimate q_hat from the
///     top 2 bytes of u at position j+n, refine with v[n-2], multiply-and-
///     subtract un[j..j+n+1] -= q_hat*v, correct if subtract went negative.
///   Denormalize: shift remainder right by s.
pub fn divModKnuth(
	u: []const u8, u_len_in: usize,
	v: []const u8, v_len: usize,
	q_out: []u8, r_out: []u8,
	work: []u8,
) struct { q_len: usize, r_len: usize } {
	std.debug.assert(v_len >= 2);
	std.debug.assert(v[v_len - 1] != 0);

	// Trim u of trailing zeros to canonical length.
	var u_len: usize = u_len_in;
	while (u_len > 0 and u[u_len - 1] == 0) u_len -= 1;

	// Special case: u < v (in length, OR same length but u < v) → q=0, r=u.
	if (u_len < v_len) {
		@memcpy(r_out[0..u_len], u[0..u_len]);
		return .{ .q_len = 0, .r_len = u_len };
	}
	if (u_len == v_len) {
		const cmp = cmpUnsignedLE(u, u_len, v, v_len);
		if (cmp < 0) {
			@memcpy(r_out[0..u_len], u[0..u_len]);
			return .{ .q_len = 0, .r_len = u_len };
		}
		if (cmp == 0) {
			q_out[0] = 1;
			return .{ .q_len = 1, .r_len = 0 };
		}
		// u > v at same length → q is single byte (1..255), r = u - v.
		// Fall through to the main algorithm; it handles this correctly.
	}

	std.debug.assert(work.len >= u_len + 1 + v_len);

	// D1: Normalize. Shift count s = number of leading zero bits in v[v_len-1].
	const top = v[v_len - 1];
	const s: u3 = @intCast(@clz(top));

	// Normalized buffers in `work`:
	//   un = work[0 .. u_len + 1]
	//   vn = work[u_len + 1 .. u_len + 1 + v_len]
	const un_buf = work[0 .. u_len + 1];
	const vn = work[u_len + 1 .. u_len + 1 + v_len];

	if (s == 0) {
		@memcpy(un_buf[0..u_len], u[0..u_len]);
		un_buf[u_len] = 0;
		@memcpy(vn, v[0..v_len]);
	} else {
		// Left-shift u by s bits into un_buf (high byte may receive carry).
		var carry: u16 = 0;
		var i: usize = 0;
		while (i < u_len) : (i += 1) {
			const w: u16 = (@as(u16, u[i]) << s) | carry;
			un_buf[i] = @truncate(w);
			carry = w >> 8;
		}
		un_buf[u_len] = @intCast(carry);
		// Left-shift v by s bits into vn.
		var carry_v: u16 = 0;
		i = 0;
		while (i < v_len) : (i += 1) {
			const w: u16 = (@as(u16, v[i]) << s) | carry_v;
			vn[i] = @truncate(w);
			carry_v = w >> 8;
		}
		// vn[v_len-1] now has high bit set (>= 128); no extension needed.
		std.debug.assert(carry_v == 0);
		std.debug.assert((vn[v_len - 1] & 0x80) != 0);
	}

	const n = v_len;
	const m = u_len - v_len; // q has m+1 bytes (positions 0..=m).

	// Initialize q_out to all zeros so we can write only non-zero positions.
	@memset(q_out[0 .. m + 1], 0);

	// Main loop: D2 .. D7. Process quotient bytes from high to low.
	const v_top: u16 = vn[n - 1];
	const v_second: u16 = vn[n - 2];
	var j_plus_one: usize = m + 1;
	while (j_plus_one > 0) {
		j_plus_one -= 1;
		const j = j_plus_one;

		// D3: Estimate q_hat.
		const u_top: u16 = un_buf[j + n];
		const u_next: u16 = un_buf[j + n - 1];
		const window: u32 = (@as(u32, u_top) << 8) | @as(u32, u_next);
		var qhat: u32 = window / v_top;
		if (qhat > 0xFF) qhat = 0xFF;
		var rhat: u32 = window - qhat * v_top;
		// Refine: while qhat * v[n-2] > (rhat << 8) + u[j+n-2]:
		const u_third: u32 = un_buf[j + n - 2];
		while (true) {
			const lhs: u64 = @as(u64, qhat) * @as(u64, v_second);
			const rhs: u64 = (@as(u64, rhat) << 8) + u_third;
			if (lhs <= rhs) break;
			qhat -= 1;
			rhat += v_top;
			if (rhat >= 256) break;
		}

		// D4: Multiply and subtract un[j..j+n+1] -= qhat * vn[0..n].
		// Standard Knuth form: accumulator `acc` is signed (i64). Each step:
		//   p = qhat * vn[k]
		//   t = un[j+k] - acc - (p & 0xFF)   (i64; can be negative or large)
		//   un[j+k] = t & 0xFF                (low byte of t in two's-comp form)
		//   acc = (p >> 8) - (t >> 8)         (arithmetic right shift on signed t)
		// `acc` represents the borrow propagated to the next byte. Using signed
		// right-shift handles underflow correctly even when borrow >= 2.
		var acc: i64 = 0;
		var k: usize = 0;
		while (k < n) : (k += 1) {
			const p: u64 = @as(u64, qhat) * @as(u64, vn[k]);
			const t: i64 = @as(i64, un_buf[j + k]) - acc - @as(i64, @intCast(p & 0xFF));
			un_buf[j + k] = @truncate(@as(u64, @bitCast(t)) & 0xFF);
			acc = @as(i64, @intCast(p >> 8)) - (t >> 8);
		}
		// Final byte at un[j+n]: subtract any remaining acc.
		const t_top: i64 = @as(i64, un_buf[j + n]) - acc;
		un_buf[j + n] = @truncate(@as(u64, @bitCast(t_top)) & 0xFF);
		const went_negative = t_top < 0;

		// D5: Test remainder. If negative, qhat was 1 too high — correct.
		if (went_negative) {
			qhat -= 1;
			// Add vn back to un[j..j+n+1], ignoring final carry (cancels the
			// "negative" we just detected).
			var carry: u16 = 0;
			k = 0;
			while (k < n) : (k += 1) {
				const sum: u16 = @as(u16, un_buf[j + k]) + @as(u16, vn[k]) + carry;
				un_buf[j + k] = @truncate(sum);
				carry = sum >> 8;
			}
			// Final carry into un[j+n] cancels the underflow byte.
			const top_sum: u16 = @as(u16, un_buf[j + n]) + carry;
			un_buf[j + n] = @truncate(top_sum);
		}

		q_out[j] = @intCast(qhat);
	}

	// D7: Denormalize. The remainder is in un_buf[0..n]; right-shift by s bits.
	if (s == 0) {
		@memcpy(r_out[0..n], un_buf[0..n]);
	} else {
		// Right-shift by s bits, walking high to low.
		var carry: u16 = 0;
		var i: usize = n;
		while (i > 0) {
			i -= 1;
			const cur: u16 = un_buf[i];
			r_out[i] = @intCast(((cur | (carry << 8)) >> s) & 0xFF);
			carry = cur & ((@as(u16, 1) << s) - 1);
		}
	}

	// Canonicalize lengths.
	var q_len: usize = m + 1;
	while (q_len > 0 and q_out[q_len - 1] == 0) q_len -= 1;
	var r_len: usize = n;
	while (r_len > 0 and r_out[r_len - 1] == 0) r_len -= 1;
	return .{ .q_len = q_len, .r_len = r_len };
}

/// Worst-case scratch needed by `divModKnuth` for the given dividend/divisor lengths.
pub fn divModKnuthScratchNeed(u_len: usize, v_len: usize) usize {
	return u_len + 1 + v_len;
}

/// Möller-Granlund 2/1 reciprocal: precompute `v = floor((2^128 - 1)/d) - 2^64`
/// where `d` is a normalized 64-bit divisor (high bit set). Used by the
/// `div2by1` primitive in Knuth's q_hat estimate to replace a hardware
/// 128/64 udiv with a multiply-add. Reference: Möller & Granlund 2010,
/// "Improved division by invariant integers", IEEE Trans. Comput., Alg. 2.
inline fn invertLimb(d: u64) u64 {
	std.debug.assert((d >> 63) == 1); // d must be normalized.
	// numer = 2^128 - 1 - d * 2^64 = ((~d) << 64) | (2^64 - 1)
	const numer: u128 = (@as(u128, ~d) << 64) | std.math.maxInt(u64);
	return @truncate(numer / @as(u128, d));
}

/// Möller-Granlund Algorithm 4: 2-limb / 1-limb division using the
/// precomputed reciprocal `v_inv = invertLimb(d)`. Returns the exact
/// quotient (q) and remainder (r) for `(u1 * 2^64 + u0) / d`, with
/// preconditions: `d` normalized and `u1 < d`. Replaces the hardware
/// 128/64 udiv with a multiply-add and at most two correction subtracts.
/// On modern CPUs (esp. aarch64) udiv x is high-latency; mul-mul-cmp wins.
inline fn div2by1(u_hi: u64, u_lo: u64, d: u64, v_inv: u64) struct { q: u64, r: u64 } {
	// GMP `udiv_qrnnd_preinv` formulation of Möller-Granlund Algorithm 4.
	// Pre: d normalized (high bit set), u_hi < d, v_inv = invertLimb(d).
	// The +1 is folded into the high addend so the 128-bit sum captures
	// all carries mod 2^128 — a bare `+` in Zig is checked-overflow UB,
	// so we use `+%` explicitly throughout.
	//
	//   (qh, ql) = u_hi * v_inv                         128-bit product
	//   (qh, ql) += ((u_hi + 1) << 64) | u_lo           128-bit add (mod 2^128)
	//   r = u_lo - qh * d                               mod 2^64
	//   if r > ql:  qh -= 1; r += d
	//   if r >= d:  qh += 1; r -= d                     rare correction
	const prod: u128 = @as(u128, u_hi) *% @as(u128, v_inv);
	const addend: u128 = (@as(u128, u_hi +% 1) << 64) | @as(u128, u_lo);
	const sum: u128 = prod +% addend;
	var qh: u64 = @truncate(sum >> 64);
	const ql: u64 = @truncate(sum);
	var r: u64 = u_lo -% (qh *% d);
	if (r > ql) {
		qh -%= 1;
		r +%= d;
	}
	if (r >= d) {
		qh +%= 1;
		r -%= d;
	}
	return .{ .q = qh, .r = r };
}

/// Möller-Granlund Algorithm 6: 3/2 reciprocal of a normalized 2-limb divisor.
/// Given the top 2 normalized divisor limbs `(d1, d0)` (d1 has high bit set),
/// returns `vinv = floor((B^3 - 1) / (d1*B + d0)) - B`. Used by `div3by2`.
inline fn invertLimb2(d1: u64, d0: u64) u64 {
	std.debug.assert((d1 >> 63) == 1);
	var v: u64 = invertLimb(d1);
	var p: u64 = d1 *% v;
	p +%= d0;
	if (p < d0) {
		v -%= 1;
		if (p >= d1) {
			v -%= 1;
			p -%= d1;
		}
		p -%= d1;
	}
	const t: u128 = @as(u128, v) *% @as(u128, d0);
	const t1: u64 = @truncate(t >> 64);
	const t0: u64 = @truncate(t);
	p +%= t1;
	if (p < t1) {
		v -%= 1;
		// Compare (p, t0) >= (d1, d0)?
		if (p > d1 or (p == d1 and t0 >= d0)) {
			v -%= 1;
		}
	}
	return v;
}

/// Möller-Granlund Algorithm 5: 3-limb / 2-limb division using `invertLimb2`.
/// Returns the exact quotient (≤ B - 1) and 2-limb remainder, given:
///   * `(u_hi, u_mid, u_lo)` — 3 dividend limbs, with `(u_hi, u_mid) < (d1, d0)`
///   * `(d1, d0)` — normalized 2-limb divisor (d1 high bit set)
///   * `vinv` — invertLimb2(d1, d0)
/// Replaces a hardware 192/128 divide with a multiply-add chain plus at most
/// one or two corrections. Used in the inner Knuth loop to estimate q_hat
/// such that q_hat is **at most 1 too high** vs the true quotient digit
/// against the full multi-limb divisor — eliminating the v_second refinement
/// loop entirely and leaving D5 to fix the rare +1.
inline fn div3by2(u_hi: u64, u_mid: u64, u_lo: u64, d1: u64, d0: u64, vinv: u64) struct { q: u64, r1: u64, r0: u64 } {
	// (q1, q0) = u_hi * vinv
	const prod: u128 = @as(u128, u_hi) *% @as(u128, vinv);
	// (q1, q0) += (u_hi, u_mid)
	const sum: u128 = prod +% ((@as(u128, u_hi) << 64) | @as(u128, u_mid));
	var q1: u64 = @truncate(sum >> 64);
	const q0: u64 = @truncate(sum);
	// r1 = u_mid - q1 * d1   (mod B)
	var r1: u64 = u_mid -% (q1 *% d1);
	// (t1, t0) = q1 * d0
	const t: u128 = @as(u128, q1) *% @as(u128, d0);
	// r = (r1, u_lo) - t - (d1, d0)
	const r_init: u128 = (@as(u128, r1) << 64) | @as(u128, u_lo);
	const d_full: u128 = (@as(u128, d1) << 64) | @as(u128, d0);
	var r: u128 = r_init -% t -% d_full;
	r1 = @truncate(r >> 64);
	q1 +%= 1;
	if (r1 >= q0) {
		q1 -%= 1;
		r +%= d_full;
	}
	if (r >= d_full) {
		q1 +%= 1;
		r -%= d_full;
	}
	return .{ .q = q1, .r1 = @truncate(r >> 64), .r0 = @truncate(r) };
}

/// Knuth Algorithm D (TAOCP vol 2 §4.3.1) in base b = 2^64. Operates on
/// little-endian u64-limb arrays. The structural change vs `divModKnuth`
/// (byte-base): we do roughly 8× fewer iterations of the outer loop and
/// 8× fewer q_hat refinements per quotient digit. The q_hat estimate uses
/// the Möller-Granlund 2/1 reciprocal trick (precomputed at D1 normalize)
/// so each inner step is a multiply-add instead of a hardware 128/64 udiv.
///
/// Inputs (all little-endian, limb[0] = lowest 64 bits):
///   u: dividend buffer; u[0..u_len] contains the canonical dividend (no
///      trailing zero limb) BUT the slice itself must have capacity for
///      one extra high limb (u_len + 1) — the D1 normalize-shift may
///      overflow into u[u_len], and the scan window references u[j+n]
///      so we always need one limb past the canonical top.
///   v: divisor; v[0..v_len], canonical (no trailing zero), v_len ≥ 2.
///   q: output quotient, capacity ≥ u_len - v_len + 1
///   r: output remainder, capacity ≥ v_len
///
/// The function does NOT mutate the caller's u beyond u_len (it copies
/// into its own work — but to avoid a separate scratch arg we use the
/// trailing capacity of u). Actually for clarity: u[0..u_len] is mutated
/// in place (normalized then progressively reduced to remainder-bytes).
/// Caller must supply `u` with capacity ≥ u_len + 1 limbs so the D1 shift
/// has space for the carry-out.
///
/// Returns canonical (q_len, r_len). q_len ≤ u_len - v_len + 1; r_len ≤ v_len.
/// q_len may be 0 (when u < v); r_len may be 0 (when u is exactly divisible).
pub fn divModKnuthU64(
	u: []u64, u_len_in: usize,
	v: []const u64, v_len: usize,
	q: []u64, r: []u64,
) struct { q_len: usize, r_len: usize } {
	std.debug.assert(v_len >= 2);
	std.debug.assert(v[v_len - 1] != 0);

	// Trim u of trailing zero limbs.
	var u_len: usize = u_len_in;
	while (u_len > 0 and u[u_len - 1] == 0) u_len -= 1;

	// Special case: u < v by length, OR same length but lex less. q=0, r=u.
	if (u_len < v_len) {
		var k: usize = 0;
		while (k < u_len) : (k += 1) r[k] = u[k];
		return .{ .q_len = 0, .r_len = u_len };
	}
	if (u_len == v_len) {
		var cmp: i8 = 0;
		var k: usize = u_len;
		while (k > 0) {
			k -= 1;
			if (u[k] != v[k]) {
				cmp = if (u[k] > v[k]) 1 else -1;
				break;
			}
		}
		if (cmp < 0) {
			var i: usize = 0;
			while (i < u_len) : (i += 1) r[i] = u[i];
			return .{ .q_len = 0, .r_len = u_len };
		}
		if (cmp == 0) {
			q[0] = 1;
			return .{ .q_len = 1, .r_len = 0 };
		}
		// u > v at same length → q is single limb (1..2^64-1), r = u - v.
		// Falls through to main algorithm.
	}

	std.debug.assert(u.len >= u_len + 1);

	// D1: Normalize. s = clz of v[v_len-1] within a u64 (0..63).
	const top = v[v_len - 1];
	const s: u6 = @intCast(@clz(top));

	// Normalized divisor `vn`: stack fast-path for v_len ≤ 1024 limbs (= 64K
	// bit divisor — covers RSA-32K and below); heap fallback via c_allocator
	// for anything larger. The streaming pi-spigot in ../pi pushes past the
	// stack cap at ~1700 digits (divisor t grows linearly with iteration
	// count). OOM here is an unrecoverable condition consistent with the
	// other std.debug.assert calls in this file — heap-fallback callers that
	// can survive OOM should size their workloads to fit the stack path.
	const VN_FAST_MAX = 1024;
	var vn_stack: [VN_FAST_MAX]u64 = undefined;
	var vn_heap: ?[]u64 = null;
	defer if (vn_heap) |h| std.heap.c_allocator.free(h);
	const vn: []u64 = if (v_len <= VN_FAST_MAX) vn_stack[0..v_len] else blk: {
		const h = std.heap.c_allocator.alloc(u64, v_len) catch @panic(
			"tier3.divModKnuthU64: out of memory allocating heap-fallback vn scratch",
		);
		vn_heap = h;
		break :blk h;
	};

	if (s == 0) {
		var i: usize = 0;
		while (i < v_len) : (i += 1) vn[i] = v[i];
		// u stays as-is; high "extra" limb is set to 0 below.
		u[u_len] = 0;
	} else {
		// Left-shift v by s bits across limbs.
		var carry_v: u64 = 0;
		var i: usize = 0;
		while (i < v_len) : (i += 1) {
			const lo = v[i] << s;
			vn[i] = lo | carry_v;
			carry_v = v[i] >> @as(u6, @intCast(64 - @as(u7, s)));
		}
		std.debug.assert(carry_v == 0);
		// Left-shift u by s bits in place; carry goes into u[u_len].
		var carry_u: u64 = 0;
		i = 0;
		while (i < u_len) : (i += 1) {
			const lo = u[i] << s;
			const hi = u[i] >> @as(u6, @intCast(64 - @as(u7, s)));
			u[i] = lo | carry_u;
			carry_u = hi;
		}
		u[u_len] = carry_u;
	}

	const n = v_len;
	const m = u_len - v_len; // q has m+1 limbs.

	// Initialize q to zero so we can write only non-zero positions.
	@memset(q[0 .. m + 1], 0);

	const v_top: u64 = vn[n - 1];
	const v_second: u64 = vn[n - 2];
	// Möller-Granlund 3/2 reciprocal: one udiv-based precompute amortized
	// across all m+1 quotient digits. The resulting q_hat from `div3by2`
	// is at most 1 too high vs the true digit (vs Knuth's classical 2 too
	// high), so the v_second refinement loop is unnecessary — the rare
	// over-by-one is recovered by the D5 add-back below.
	const v_inv: u64 = invertLimb2(v_top, v_second);

	// Main loop D2..D7 — process quotient limbs from high to low.
	var j_plus_one: usize = m + 1;
	while (j_plus_one > 0) {
		j_plus_one -= 1;
		const j = j_plus_one;

		// D3: Estimate q_hat using Möller-Granlund 3/2.
		// Precondition for div3by2: (u_top, u_next) < (v_top, v_second).
		// When this fails, the true q_hat = 2^64 - 1 (capped). Detect with
		// a single 128-bit lex compare and fall through.
		const u_top: u64 = u[j + n];
		const u_next: u64 = u[j + n - 1];
		const u_third: u64 = u[j + n - 2];
		var qhat: u64 = undefined;
		const u_hi128: u128 = (@as(u128, u_top) << 64) | @as(u128, u_next);
		const v_hi128: u128 = (@as(u128, v_top) << 64) | @as(u128, v_second);
		if (u_hi128 >= v_hi128) {
			// Cap at maxInt(u64). The classical Knuth subtract+add-back below
			// will recover if this is one too high.
			qhat = std.math.maxInt(u64);
		} else {
			const dq = div3by2(u_top, u_next, u_third, v_top, v_second, v_inv);
			qhat = dq.q;
		}

		// D4: Multiply and subtract  u[j..j+n+1] -= qhat * vn[0..n].
		// Per-limb scheme:
		//   p = qhat * vn[k]              (u128: high64 = mul carry, low64 = digit)
		//   total_sub = low64 + carry_lo  (u128 to absorb carry)
		//   diff = u[j+k] - total_sub_lo  (with borrow tracking)
		//   carry_lo := total_sub_hi + p_hi (next position's pending subtraction lo)
		//   borrow accumulates across limbs.
		var carry_lo: u64 = 0; // pending sub from previous mul step (high half of prior product + sub-overflow)
		var borrow: u64 = 0;   // 0 or 1 from previous limb's sub
		var k: usize = 0;
		while (k < n) : (k += 1) {
			const p: u128 = @as(u128, qhat) * @as(u128, vn[k]);
			const p_lo: u64 = @truncate(p);
			const p_hi: u64 = @truncate(p >> 64);
			// Combine the running carry into this limb's subtrahend.
			const sub_full: u128 = @as(u128, p_lo) + @as(u128, carry_lo);
			const sub_lo: u64 = @truncate(sub_full);
			const sub_hi: u64 = @truncate(sub_full >> 64);
			// Now subtract sub_lo plus the previous borrow from u[j+k].
			const a = u[j + k];
			const d1 = @subWithOverflow(a, sub_lo);
			const d2 = @subWithOverflow(d1[0], borrow);
			u[j + k] = d2[0];
			borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
			// Next limb's "pending subtrahend" = high 64 of p plus any high overflow of sub_full.
			carry_lo = p_hi + sub_hi;
		}
		// Final limb: subtract carry_lo + borrow from u[j+n].
		const a_top = u[j + n];
		const dfin1 = @subWithOverflow(a_top, carry_lo);
		const dfin2 = @subWithOverflow(dfin1[0], borrow);
		u[j + n] = dfin2[0];
		const went_negative = (@as(u64, dfin1[1]) + @as(u64, dfin2[1])) != 0;

		// D5: Test remainder. If negative, decrement qhat and add vn back.
		if (went_negative) {
			qhat -= 1;
			var add_carry: u64 = 0;
			k = 0;
			while (k < n) : (k += 1) {
				const s1 = @addWithOverflow(u[j + k], vn[k]);
				const s2 = @addWithOverflow(s1[0], add_carry);
				u[j + k] = s2[0];
				add_carry = @as(u64, s1[1]) + @as(u64, s2[1]);
			}
			// Final carry into u[j+n] cancels the negative we detected.
			u[j + n] +%= add_carry;
		}

		q[j] = qhat;
	}

	// D7: Denormalize. Right-shift u[0..n] by s bits into r.
	if (s == 0) {
		var i: usize = 0;
		while (i < n) : (i += 1) r[i] = u[i];
	} else {
		var carry: u64 = 0;
		var i: usize = n;
		while (i > 0) {
			i -= 1;
			const cur = u[i];
			r[i] = (cur >> s) | (carry << @as(u6, @intCast(64 - @as(u7, s))));
			carry = cur & ((@as(u64, 1) << s) - 1);
		}
	}

	// Canonicalize lengths.
	var q_len: usize = m + 1;
	while (q_len > 0 and q[q_len - 1] == 0) q_len -= 1;
	var r_len: usize = n;
	while (r_len > 0 and r[r_len - 1] == 0) r_len -= 1;
	return .{ .q_len = q_len, .r_len = r_len };
}

/// In-place multi-limb two's-complement negate: limbs[..] = (~limbs + 1) over
/// the full LE limb array. Used by `divModSigned` to flip a negative payload
/// (sign-extended into limbs) to its magnitude in one chunked pass — avoids
/// the byte-level `negateInPlace` + `bytesToLimbs` sequence (~8× fewer scalar
/// operations on aarch64 / x86_64). Compiles to a clean ADCS-style chain.
inline fn negateLimbsInPlace(limbs: []u64) void {
	var carry: u64 = 1;
	for (limbs) |*p| {
		// (~p + carry) — carry propagates only when ~p == 0xFFFF_FFFF_FFFF_FFFF
		// (i.e. p == 0). Use addWithOverflow to express this without a u128.
		const inv = ~p.*;
		const r = @addWithOverflow(inv, carry);
		p.* = r[0];
		carry = r[1];
	}
}

/// Pack a canonical two's-complement BLIP payload directly into a u64 limb
/// array as a positive magnitude. Returns the canonical (trailing-zero-trimmed)
/// limb count.
///
/// For positive payloads (sign-extension byte 0x00), bytes are read into limbs
/// LE — high partial limb is zero-extended (matches `bytesToLimbs`). For
/// negative payloads (sign-extension byte 0xFF), bytes are read with the high
/// partial limb sign-extended to 0xFF in its unread bytes, then the entire
/// limb array is negated in place — yielding the positive magnitude.
///
/// This collapses the previous `@memcpy(mag_buf, pay) + negateInPlace(mag_buf)
/// + trim + bytesToLimbs(mag_buf, limbs)` sequence into a single pass. Limbs
/// must be sized to `(pay.len + 7) / 8` (or larger). Limbs past the input are
/// zeroed.
fn payloadToMagLimbs(pay: []const u8, neg: bool, limbs: []u64) usize {
	@memset(limbs, 0);
	if (pay.len == 0) return 0;
	const sign_fill: u8 = if (neg) 0xFF else 0x00;
	const max_full = pay.len / 8;
	const tail_start = max_full * 8;
	// Full 8-byte chunks: direct readInt.
	var i: usize = 0;
	while (i < max_full and i < limbs.len) : (i += 1) {
		limbs[i] = std.mem.readInt(u64, pay[i * 8 ..][0..8], .little);
	}
	// Tail bytes (< 8): pad upper bytes with sign_fill so negation is correct.
	if (tail_start < pay.len and i < limbs.len) {
		var tail: [8]u8 = .{sign_fill} ** 8;
		const remaining = pay.len - tail_start;
		@memcpy(tail[0..remaining], pay[tail_start..]);
		limbs[i] = std.mem.readInt(u64, &tail, .little);
		i += 1;
	}
	// For negative payloads, sign-extend the unused high limbs to 0xFFFF...FF
	// before negation so the magnitude comes out correct.
	if (neg) {
		while (i < limbs.len) : (i += 1) limbs[i] = std.math.maxInt(u64);
		negateLimbsInPlace(limbs);
	}
	// Canonical limb length = trim trailing zero limbs.
	var n: usize = limbs.len;
	while (n > 0 and limbs[n - 1] == 0) n -= 1;
	return n;
}

/// Write a magnitude held in `limbs[0..n_limbs]` as a canonical two's-complement
/// LE payload byte sequence into `dst`. Returns the canonical payload length.
///
/// Combines what was previously `limbsToBytes + trim + encodeMagAsTwosComp`
/// into a single pass:
///   - Skips writing trailing zero high limbs (only writes "live" magnitude).
///   - For positive output, the magnitude bytes are emitted directly; a 0x00
///     sign-extension byte is appended only when the high mag byte has bit 7
///     set.
///   - For negative output, the magnitude is negated as it is emitted (per-byte
///     ~b + carry); a 0xFF sign-extension byte is appended only when the high
///     post-negation byte has bit 7 clear.
///   - Empty input (`n_limbs == 0` or all-zero) emits a single 0x00 byte.
///
/// Assumes `dst.len >= n_limbs * 8 + 1` (caller-provided buffer). Always
/// returns a length ≥ 1.
fn writeMagLimbsAsTwosComp(limbs: []const u64, n_limbs_in: usize, neg: bool, dst: []u8) usize {
	// Trim trailing zero limbs for safety (caller usually pre-trims, but handle).
	var n_limbs = n_limbs_in;
	while (n_limbs > 0 and limbs[n_limbs - 1] == 0) n_limbs -= 1;
	if (n_limbs == 0) {
		dst[0] = 0x00;
		return 1;
	}
	// Compute byte length of the live magnitude (high non-zero limb's MSB).
	const high = limbs[n_limbs - 1];
	const high_bytes: usize = 8 - (@as(usize, @clz(high)) >> 3);
	const mag_byte_len = (n_limbs - 1) * 8 + high_bytes;
	std.debug.assert(dst.len >= mag_byte_len + 1);

	if (!neg) {
		// Positive: write full limbs as LE bytes.
		var i: usize = 0;
		while (i + 1 < n_limbs) : (i += 1) {
			std.mem.writeInt(u64, dst[i * 8 ..][0..8], limbs[i], .little);
		}
		// High limb: write only the live bytes.
		var tail_buf: [8]u8 = undefined;
		std.mem.writeInt(u64, &tail_buf, high, .little);
		@memcpy(dst[(n_limbs - 1) * 8 ..][0..high_bytes], tail_buf[0..high_bytes]);
		// Sign-extension byte if MSB of high byte set.
		if ((dst[mag_byte_len - 1] & 0x80) != 0) {
			dst[mag_byte_len] = 0x00;
			return mag_byte_len + 1;
		}
		return mag_byte_len;
	}
	// Negative: negate as we emit. For multi-limb magnitudes, the byte-level
	// 2's complement is (~m + 1) over the full live range. We emit per-limb
	// (NOT~) with proper carry; only write the live byte range of the high
	// limb. The negation is well-defined because caller guarantees the
	// magnitude is non-zero.
	var carry: u64 = 1;
	var i: usize = 0;
	while (i + 1 < n_limbs) : (i += 1) {
		const inv = ~limbs[i];
		const r = @addWithOverflow(inv, carry);
		std.mem.writeInt(u64, dst[i * 8 ..][0..8], r[0], .little);
		carry = r[1];
	}
	// High limb: negate then write only the live byte range. Writing only
	// `high_bytes` is correct because the bytes above the live range are
	// always 0xFF post-negation (sign-extension of a negative two's-comp
	// representation), and we don't include those in the canonical payload.
	const high_inv = ~high;
	const high_neg = @addWithOverflow(high_inv, carry);
	var tail_buf: [8]u8 = undefined;
	std.mem.writeInt(u64, &tail_buf, high_neg[0], .little);
	@memcpy(dst[(n_limbs - 1) * 8 ..][0..high_bytes], tail_buf[0..high_bytes]);
	// Apply canonicalization for the negative case:
	//   - If high mag byte had bit 7 set (which is why the magnitude needed
	//     `high_bytes` bytes), then post-negation that byte may have its
	//     bit 7 clear → need 0xFF sign-extension byte.
	//   - Or the post-negation high byte may equal 0xFF AND the next-down
	//     byte's bit 7 is set: the 0xFF is redundant and can be trimmed.
	// The simplest correct approach: append 0xFF if needed, then run a tight
	// canonical-trim loop on the trailing 0xFF run (only at the high end).
	var out_len = mag_byte_len;
	if ((dst[out_len - 1] & 0x80) == 0) {
		dst[out_len] = 0xFF;
		out_len += 1;
	}
	// Canonical trim of trailing 0xFF if next-down has bit 7 set.
	while (out_len > 1 and dst[out_len - 1] == 0xFF and (dst[out_len - 2] & 0x80) != 0) {
		out_len -= 1;
	}
	return out_len;
}

/// Signed truncated division on raw BLIP payloads (two's-complement LE).
/// Implements GMP `mpz_tdiv_qr` semantics:
///   sign(q) = sign(a) XOR sign(b)
///   sign(rem) = sign(a)  (or 0)
///   |rem| < |b|
///
/// Inputs `a_pay`/`b_pay` are two's-complement LE payload byte slices (the
/// raw payload region of a BLIP value). The function:
///   1. Extracts magnitudes by negating any negative payload into scratch.
///   2. Dispatches to `divModSingleU64` (for 1..8-byte divisor magnitudes) or
///      `divModKnuth` (for 9+ byte divisor magnitudes).
///   3. Re-encodes quotient and remainder magnitudes as canonical two's-comp
///      payloads (negating if their signs are negative). Writes into `q_pay`
///      and `r_pay` buffers; returns canonical lengths (≥ 1).
///
/// Caller guarantees:
///   - b_pay is not all-zero (DivisionByZero must be checked at the top level).
///   - q_pay has capacity ≥ a_mag_len + 2 (extra for sign-extension byte).
///   - r_pay has capacity ≥ b_mag_len + 2.
///   - work has capacity ≥ a_mag_len + b_mag_len + divModKnuthScratchNeed(a_mag_len, b_mag_len)
///     (covers magnitude scratch + Knuth working buffer).
pub const DivModResult = struct { q_len: usize, r_len: usize };

pub fn divModSigned(
	a_pay: []const u8, b_pay: []const u8,
	q_pay: []u8, r_pay: []u8,
	work: []u8,
) DivModResult {
	const a_neg = signExtByte(a_pay) == 0xFF;
	const b_neg = signExtByte(b_pay) == 0xFF;

	// Cheap upper bound on b's magnitude byte length: canonical 2's-comp can
	// shrink by at most one byte (a sign-extension byte). So b_mag_len ≤ 8
	// implies b_pay.len ≤ 9. We can dispatch the multi-byte fast path early
	// without materialising the byte magnitude buffer.
	if (b_pay.len >= 10) {
		return divModSignedLarge(a_pay, b_pay, a_neg, b_neg, q_pay, r_pay, work);
	}

	// Small-divisor path — keeps the byte-scratch layout because
	// `divModSingleU64` operates on bytes in place.
	// Layout work as: [a_mag | b_mag | knuth_scratch].
	const a_mag_buf = work[0..a_pay.len];
	const b_mag_buf = work[a_pay.len .. a_pay.len + b_pay.len];

	@memcpy(a_mag_buf, a_pay);
	@memcpy(b_mag_buf, b_pay);
	if (a_neg) negateInPlace(a_mag_buf);
	if (b_neg) negateInPlace(b_mag_buf);

	// Canonicalize magnitudes (trim trailing zeros). After negation a positive
	// payload of length L becomes a magnitude of length ≤ L (high byte may have
	// been a sign-extension 0xFF that becomes 0x00 after negation, etc).
	var a_mag_len: usize = a_pay.len;
	while (a_mag_len > 0 and a_mag_buf[a_mag_len - 1] == 0) a_mag_len -= 1;
	var b_mag_len: usize = b_pay.len;
	while (b_mag_len > 0 and b_mag_buf[b_mag_len - 1] == 0) b_mag_len -= 1;

	// Zero dividend → q=0, r=0.
	if (a_mag_len == 0) {
		q_pay[0] = 0;
		r_pay[0] = 0;
		return .{ .q_len = 1, .r_len = 1 };
	}

	// Compute unsigned q_mag and r_mag.
	var q_mag_len: usize = 0;
	var r_mag_len: usize = 0;

	if (b_mag_len <= 8) {
		// Single-u64 divisor path. Quotient overwrites a_mag in place; we then
		// copy it into q_pay. Remainder is a u64.
		// Build the divisor as u64 LE.
		var divisor: u64 = 0;
		for (0..b_mag_len) |k| divisor |= @as(u64, b_mag_buf[k]) << @intCast(8 * k);
		const out = divModSingleU64(a_mag_buf, a_mag_len, divisor);
		// Copy quotient bytes to q_pay.
		@memcpy(q_pay[0..out.q_len], a_mag_buf[0..out.q_len]);
		q_mag_len = out.q_len;
		// Write remainder bytes to r_pay (LE).
		var rem = out.rem;
		var i: usize = 0;
		while (rem != 0 or i == 0) : (i += 1) {
			r_pay[i] = @truncate(rem);
			rem >>= 8;
			if (i + 1 >= r_pay.len) break;
		}
		// Trim trailing zeros to canonical magnitude length (may be 0 if rem == 0).
		r_mag_len = i;
		while (r_mag_len > 0 and r_pay[r_mag_len - 1] == 0) r_mag_len -= 1;
	} else {
		// b_pay.len ≤ 9 but b_mag_len > 8 → use the limb-direct large path.
		return divModSignedLarge(a_pay, b_pay, a_neg, b_neg, q_pay, r_pay, work);
	}

	// Determine output signs. Truncated semantics:
	//   q_neg = (a_neg XOR b_neg) AND q_mag != 0
	//   r_neg = a_neg AND r_mag != 0
	const q_is_neg = (a_neg != b_neg) and q_mag_len != 0;
	const r_is_neg = a_neg and r_mag_len != 0;

	// Re-encode q_mag as canonical two's-comp payload in q_pay.
	q_mag_len = encodeMagAsTwosComp(q_pay, q_mag_len, q_is_neg);
	r_mag_len = encodeMagAsTwosComp(r_pay, r_mag_len, r_is_neg);

	return .{ .q_len = q_mag_len, .r_len = r_mag_len };
}

/// Multi-byte-divisor path of `divModSigned` that skips the byte-magnitude
/// scratch buffer entirely. Inputs are read directly into u64 limb slots
/// (with sign-fill + in-limb negation when negative); outputs are written
/// directly as canonical two's-complement BLIP payload bytes (with negation
/// fused into the per-limb write loop).
///
/// This collapses 6 byte-level passes (memcpy×2, byte-trim×2, bytesToLimbs×2,
/// limbsToBytes×2, byte-trim×2, encodeMagAsTwosComp×2) into 2 limb-level passes
/// + 2 limb→byte writes. At 2K-bit / 1K-bit this saves ~150-200 ns of pure
/// data shuffling.
fn divModSignedLarge(
	a_pay: []const u8, b_pay: []const u8,
	a_neg: bool, b_neg: bool,
	q_pay: []u8, r_pay: []u8,
	work: []u8,
) DivModResult {
	// Carve aligned u64 work region. We don't need a/b byte scratch on this
	// path, so the entire `work` budget can be used for limb slots. Step over
	// any leading misalignment so we can cast as []u64.
	const align_skip = (8 - (@intFromPtr(work.ptr) % 8)) % 8;
	const work_aligned = work[align_skip..];
	std.debug.assert(@intFromPtr(work_aligned.ptr) % 8 == 0);

	// Maximum limb counts we may write into. We use the payload byte length
	// upper bound (canonical magnitude can be slightly less). Knuth needs
	// u with (a_limbs + 1) slots so the D1 normalisation shift has carry-out
	// space.
	const a_limbs_max = (a_pay.len + 7) / 8;
	const b_limbs_max = (b_pay.len + 7) / 8;
	const u_lim_bytes = (a_limbs_max + 1) * 8;
	const q_lim_bytes = a_limbs_max * 8;
	const r_lim_bytes = b_limbs_max * 8;
	const v_lim_bytes = b_limbs_max * 8;
	std.debug.assert(work_aligned.len >= u_lim_bytes + q_lim_bytes + r_lim_bytes + v_lim_bytes);

	const u_lim_raw = std.mem.bytesAsSlice(u64, work_aligned[0..u_lim_bytes]);
	const q_lim_raw = std.mem.bytesAsSlice(u64, work_aligned[u_lim_bytes .. u_lim_bytes + q_lim_bytes]);
	const r_lim_raw = std.mem.bytesAsSlice(u64, work_aligned[u_lim_bytes + q_lim_bytes .. u_lim_bytes + q_lim_bytes + r_lim_bytes]);
	const v_lim_off = u_lim_bytes + q_lim_bytes + r_lim_bytes;
	const v_lim_raw = std.mem.bytesAsSlice(u64, work_aligned[v_lim_off .. v_lim_off + v_lim_bytes]);
	const u_lim: []u64 = @alignCast(u_lim_raw);
	const q_lim: []u64 = @alignCast(q_lim_raw);
	const r_lim: []u64 = @alignCast(r_lim_raw);
	const v_lim: []u64 = @alignCast(v_lim_raw);

	// Pack inputs into limb form as positive magnitudes (sign-fill + negate
	// in-limb when negative). `u_lim` covers a_limbs_max + 1 slots; we only
	// pack into the first a_limbs_max — `payloadToMagLimbs` zeros all of its
	// argument, so we slice down to avoid touching the carry-out slot, then
	// zero it explicitly below.
	const a_lim = payloadToMagLimbs(a_pay, a_neg, u_lim[0..a_limbs_max]);
	u_lim[a_limbs_max] = 0; // Knuth needs u[u_len_in] writable for D1 carry.
	const b_lim = payloadToMagLimbs(b_pay, b_neg, v_lim[0..b_limbs_max]);

	// Zero dividend → q=0, r=0.
	if (a_lim == 0) {
		q_pay[0] = 0;
		r_pay[0] = 0;
		return .{ .q_len = 1, .r_len = 1 };
	}
	// Caller asserts b_pay non-zero, so b_lim > 0. The kernel needs v_len ≥ 2
	// (multi-byte path guarantee). If b somehow reduced to 1 limb (shouldn't
	// happen — caller dispatched here because b_pay.len ≥ 10 OR b_mag > 8
	// bytes), fall back: we'd hit a kernel assertion. So sanity-guard:
	std.debug.assert(b_lim >= 2);

	// Determine output signs (computed BEFORE Knuth so we can route directly
	// into `writeMagLimbsAsTwosComp` without a separate re-encode step).
	const got = divModKnuthU64(u_lim, a_lim, v_lim, b_lim, q_lim, r_lim);
	const q_is_neg = (a_neg != b_neg) and got.q_len != 0;
	const r_is_neg = a_neg and got.r_len != 0;

	// Write quotient and remainder directly as canonical 2's-complement BLIP
	// payload bytes — fuses limb→byte unpack + sign-extension append + canonical
	// trim into one pass.
	const q_len = writeMagLimbsAsTwosComp(q_lim, got.q_len, q_is_neg, q_pay);
	const r_len = writeMagLimbsAsTwosComp(r_lim, got.r_len, r_is_neg, r_pay);

	return .{ .q_len = q_len, .r_len = r_len };
}

/// Take an unsigned magnitude `mag` of length `mag_len` (in `buf[0..mag_len]`,
/// LE bytes), and re-encode it into the same buffer as a canonical two's-comp
/// payload of the appropriate sign. Returns the new canonical payload length.
///
/// Rules:
///   - If `mag_len == 0`: store [0x00] and return 1.
///   - If positive: payload = magnitude bytes, possibly with a 0x00
///     sign-extension byte appended IF the high bit of the high magnitude byte is set.
///   - If negative: payload = (~magnitude + 1) of length L, possibly with
///     extra 0xFF sign-extension byte if high bit of high byte is clear after negation.
///   - Then canonicalize trailing 0x00 / 0xFF.
inline fn encodeMagAsTwosComp(buf: []u8, mag_len: usize, is_negative: bool) usize {
	if (mag_len == 0) {
		buf[0] = 0x00;
		return 1;
	}
	if (!is_negative) {
		// High bit of high mag byte set → need 0x00 sign-extension byte.
		if ((buf[mag_len - 1] & 0x80) != 0) {
			buf[mag_len] = 0x00;
			return canonicalLen(buf[0 .. mag_len + 1]);
		}
		return canonicalLen(buf[0..mag_len]);
	}
	// Negative: in-place negate (treat buf[0..mag_len] as the magnitude).
	negateInPlace(buf[0..mag_len]);
	if ((buf[mag_len - 1] & 0x80) == 0) {
		buf[mag_len] = 0xFF;
		return canonicalLen(buf[0 .. mag_len + 1]);
	}
	return canonicalLen(buf[0..mag_len]);
}

/// Worst-case scratch needed by `divModSigned` for the given input payload lengths.
///
/// Layout: [a_mag | b_mag | knuth_work].
///
/// The knuth_work portion now sizes for the u64-base path: u (a_limbs+1),
/// q (a_limbs), r (b_limbs), v (b_limbs) — all u64 limb slots — plus up to
/// 8 bytes of alignment slack (knuth_work may start mid-u64 because a_mag/b_mag
/// have arbitrary byte lengths). We take the max of byte-base and u64-base
/// budgets so callers can use either path interchangeably.
pub fn divModSignedScratchNeed(a_pay_len: usize, b_pay_len: usize) usize {
	const byte_path = divModKnuthScratchNeed(a_pay_len, b_pay_len);
	const a_lim = (a_pay_len + 7) / 8;
	const b_lim = (b_pay_len + 7) / 8;
	const u64_path = 8 + (a_lim + 1) * 8 + a_lim * 8 + b_lim * 8 + b_lim * 8;
	const knuth = if (byte_path > u64_path) byte_path else u64_path;
	return a_pay_len + b_pay_len + knuth;
}

/// Compare two unsigned LE byte arrays. Returns -1/0/+1.
pub fn cmpUnsignedLE(a: []const u8, a_len: usize, b: []const u8, b_len: usize) i8 {
	if (a_len != b_len) return if (a_len > b_len) 1 else -1;

	// Chunked u64 high-to-low. For LE multi-byte arrays, the chunk at offset
	// `off` represents bytes off..off+8 — and unsigned u64 comparison of the
	// LE-interpreted chunk correctly orders these positions because byte
	// off+7 occupies bits 56-63 of the u64 (dominates the unsigned compare),
	// matching its dominant role in the magnitude.
	const chunk_aligned: usize = (a_len / 8) * 8;

	// Tail bytes (high end, > chunk_aligned) — scan first since they're
	// higher magnitude.
	var bi: usize = a_len;
	while (bi > chunk_aligned) {
		bi -= 1;
		if (a[bi] != b[bi]) return if (a[bi] > b[bi]) 1 else -1;
	}

	// Aligned u64 chunks, top to bottom. Each compare is one LDR x + LDR x +
	// CMP on aarch64 — handles 8 bytes per iteration vs the 8 LDR/LDR/CMP
	// pairs of the per-byte form.
	var ci: usize = chunk_aligned / 8;
	while (ci > 0) {
		ci -= 1;
		const off = ci * 8;
		const av = std.mem.readInt(u64, a[off..][0..8], .little);
		const bv = std.mem.readInt(u64, b[off..][0..8], .little);
		if (av != bv) return if (av > bv) 1 else -1;
	}
	return 0;
}

/// Add two unsigned LE byte arrays. out has capacity ≥ max(a,b)+1. Chunked u64.
pub fn addUnsignedLE(a: []const u8, a_len: usize, b: []const u8, b_len: usize, out: []u8) usize {
	const longer_len = @max(a_len, b_len);
	std.debug.assert(out.len > longer_len);
	const longer: []const u8 = if (a_len >= b_len) a else b;
	const shorter: []const u8 = if (a_len >= b_len) b else a;
	const shorter_len = @min(a_len, b_len);
	var carry: u64 = 0;
	var i: usize = 0;
	// Chunked u64 path for the both-have-real-bytes prefix.
	const both_aligned = shorter_len - (shorter_len % 8);
	while (i < both_aligned) : (i += 8) {
		const av = std.mem.readInt(u64, longer[i..][0..8], .little);
		const bv = std.mem.readInt(u64, shorter[i..][0..8], .little);
		const s1 = @addWithOverflow(av, bv);
		const s2 = @addWithOverflow(s1[0], carry);
		std.mem.writeInt(u64, out[i..][0..8], s2[0], .little);
		carry = @as(u64, s1[1]) + @as(u64, s2[1]);
	}
	// Per-byte tail of shorter.
	while (i < shorter_len) : (i += 1) {
		const sum: u16 = @as(u16, longer[i]) + @as(u16, shorter[i]) + @as(u16, @intCast(carry));
		out[i] = @truncate(sum);
		carry = sum >> 8;
	}
	// Chunked propagation through longer-only region.
	const longer_aligned = longer_len - ((longer_len - i) % 8);
	while (i + 8 <= longer_aligned) : (i += 8) {
		const av = std.mem.readInt(u64, longer[i..][0..8], .little);
		const s = @addWithOverflow(av, carry);
		std.mem.writeInt(u64, out[i..][0..8], s[0], .little);
		carry = s[1];
	}
	while (i < longer_len) : (i += 1) {
		const sum: u16 = @as(u16, longer[i]) + @as(u16, @intCast(carry));
		out[i] = @truncate(sum);
		carry = sum >> 8;
	}
	if (carry != 0) {
		out[longer_len] = @intCast(carry);
		return longer_len + 1;
	}
	var n = longer_len;
	while (n > 0 and out[n - 1] == 0) n -= 1;
	return n;
}

/// Subtract: out = a - b (unsigned). Caller guarantees a >= b. Chunked u64.
pub fn subUnsignedLE(a: []const u8, a_len: usize, b: []const u8, b_len: usize, out: []u8) usize {
	std.debug.assert(out.len >= a_len);
	std.debug.assert(b_len <= a_len);
	var borrow: u64 = 0;
	var i: usize = 0;
	const b_aligned = b_len - (b_len % 8);
	while (i < b_aligned) : (i += 8) {
		const av = std.mem.readInt(u64, a[i..][0..8], .little);
		const bv = std.mem.readInt(u64, b[i..][0..8], .little);
		const d1 = @subWithOverflow(av, bv);
		const d2 = @subWithOverflow(d1[0], borrow);
		std.mem.writeInt(u64, out[i..][0..8], d2[0], .little);
		borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
	}
	while (i < b_len) : (i += 1) {
		const diff: i32 = @as(i32, a[i]) - @as(i32, b[i]) - @as(i32, @intCast(borrow));
		out[i] = @truncate(@as(u32, @bitCast(diff)) & 0xFF);
		borrow = if (diff < 0) 1 else 0;
	}
	const a_aligned = a_len - ((a_len - i) % 8);
	while (i + 8 <= a_aligned) : (i += 8) {
		const av = std.mem.readInt(u64, a[i..][0..8], .little);
		const d = @subWithOverflow(av, borrow);
		std.mem.writeInt(u64, out[i..][0..8], d[0], .little);
		borrow = d[1];
	}
	while (i < a_len) : (i += 1) {
		const diff: i32 = @as(i32, a[i]) - @as(i32, @intCast(borrow));
		out[i] = @truncate(@as(u32, @bitCast(diff)) & 0xFF);
		borrow = if (diff < 0) 1 else 0;
	}
	var n = a_len;
	while (n > 0 and out[n - 1] == 0) n -= 1;
	return n;
}

/// Sign-magnitude tuple. `mag[0..len]` is the unsigned magnitude.
pub const SM = struct { sign: i8, len: usize };

/// Signed add: r = a + b in sign-magnitude form. r_buf receives magnitude.
/// Caller guarantees r_buf has capacity ≥ max(a_len, b_len) + 1.
pub fn smAdd(
	a_sign: i8, a: []const u8, a_len: usize,
	b_sign: i8, b: []const u8, b_len: usize,
	r_buf: []u8,
) SM {
	if (a_sign == 0) {
		@memcpy(r_buf[0..b_len], b[0..b_len]);
		return .{ .sign = b_sign, .len = b_len };
	}
	if (b_sign == 0) {
		@memcpy(r_buf[0..a_len], a[0..a_len]);
		return .{ .sign = a_sign, .len = a_len };
	}
	if (a_sign == b_sign) {
		const len = addUnsignedLE(a, a_len, b, b_len, r_buf);
		return .{ .sign = a_sign, .len = len };
	}
	// Different signs: r = ±(|a| - |b|)
	const cmp = cmpUnsignedLE(a, a_len, b, b_len);
	if (cmp == 0) return .{ .sign = 0, .len = 0 };
	if (cmp > 0) {
		const len = subUnsignedLE(a, a_len, b, b_len, r_buf);
		return .{ .sign = a_sign, .len = len };
	}
	const len = subUnsignedLE(b, b_len, a, a_len, r_buf);
	return .{ .sign = b_sign, .len = len };
}

// ── Toom-Cook 3-way multiplication ───────────────────────────────────────────
//
// Splits each n-byte operand into 3 parts (low/mid/high of size m bytes
// each, where m = ⌈n/3⌉; high may be shorter). Each part is treated as a
// coefficient of a polynomial in B = 2^(8m). Multiplication of two such
// polynomials produces a degree-4 polynomial. Toom-3 evaluates at 5 points
// {0, 1, -1, 2, ∞}, performs 5 sub-multiplications (vs Karatsuba's 3 of
// half-size), then interpolates. Asymptotic O(n^log_3 5) ≈ O(n^1.46),
// beating Karatsuba's O(n^1.58).
//
// Below TOOM3_THRESHOLD bytes the constant overhead exceeds the savings.

pub const TOOM3_THRESHOLD: usize = 2048;

/// Conservative scratch for `mulToom3` on n-byte equal-length operands.
/// Each level needs ~12 buffers of size m+1 (where m ≈ n/3) plus
/// karatsubaScratchNeed(m) for sub-products. Geometric series: ≤ 16n.
pub fn toom3ScratchNeed(n: usize) usize {
	return 16 * n + 256;
}

/// Toom-Cook 3-way multiply. a.len == b.len. Result fills r[0..2*n].
/// Falls back to Karatsuba below TOOM3_THRESHOLD.
pub fn mulToom3(a: []const u8, b: []const u8, r: []u8, scratch: []u8) void {
	std.debug.assert(a.len == b.len);
	const n = a.len;
	std.debug.assert(r.len >= 2 * n);

	if (n < TOOM3_THRESHOLD) {
		mulKaratsuba(a, b, r, scratch);
		return;
	}

	// Split: m = ⌈n/3⌉ for low/mid; high = n - 2m (may be ≤ m).
	const m = (n + 2) / 3;
	const a0_len = m;
	const a1_len = m;
	const a2_len = n - 2 * m; // 1..m
	const a0 = a[0..a0_len];
	const a1 = a[a0_len .. a0_len + a1_len];
	const a2 = a[a0_len + a1_len ..];
	const b0 = b[0..a0_len];
	const b1 = b[a0_len .. a0_len + a1_len];
	const b2 = b[a0_len + a1_len ..];

	// Sub-product result sizes: each up to 2(m+1) bytes (for the +1-extended evals).
	const slot = m + 2; // intermediate buffer width
	const psl = 2 * slot; // sub-product width

	// Scratch layout (offsets in `scratch`):
	//   eval_a1     [0   .. slot]
	//   eval_b1     [slot .. 2slot]
	//   eval_a_m1   [2slot .. 3slot]   (sign in returned SM)
	//   eval_b_m1   [3slot .. 4slot]
	//   eval_a2     [4slot .. 5slot]
	//   eval_b2     [5slot .. 6slot]
	//   v0          [6slot .. 6slot + psl]      (= a0*b0)        — also written to r[0..2m]
	//   v1          [6slot + psl   .. 6slot + 2psl]
	//   v_m1        [6slot + 2psl  .. 6slot + 3psl]
	//   v2          [6slot + 3psl  .. 6slot + 4psl]
	//   v_inf       [6slot + 4psl  .. 6slot + 4psl + 2*a2_len]   — also written to r[4m..]
	//   work1       [6slot + 5psl  .. 6slot + 6psl]
	//   work2       [6slot + 6psl  .. 6slot + 7psl]
	//   work3       [6slot + 7psl  .. 6slot + 8psl]
	//   sub_scratch (Karatsuba): rest
	std.debug.assert(scratch.len >= toom3ScratchNeed(n));

	const ea1 = scratch[0..slot];
	const eb1 = scratch[slot .. 2 * slot];
	const eam1 = scratch[2 * slot .. 3 * slot];
	const ebm1 = scratch[3 * slot .. 4 * slot];
	const ea2 = scratch[4 * slot .. 5 * slot];
	const eb2 = scratch[5 * slot .. 6 * slot];
	const v0_buf = scratch[6 * slot .. 6 * slot + psl];
	const v1_buf = scratch[6 * slot + psl .. 6 * slot + 2 * psl];
	const vm1_buf = scratch[6 * slot + 2 * psl .. 6 * slot + 3 * psl];
	const v2_buf = scratch[6 * slot + 3 * psl .. 6 * slot + 4 * psl];
	const vinf_buf = scratch[6 * slot + 4 * psl .. 6 * slot + 5 * psl];
	const work1 = scratch[6 * slot + 5 * psl .. 6 * slot + 6 * psl];
	const work2 = scratch[6 * slot + 6 * psl .. 6 * slot + 7 * psl];
	const work3 = scratch[6 * slot + 7 * psl .. 6 * slot + 8 * psl];
	const sub_scratch = scratch[6 * slot + 8 * psl ..];

	// ── Evaluations ──
	// a1_eval = a0 + a1 + a2; b1_eval = b0 + b1 + b2  (positive)
	const a01_len = addUnsignedLE(a0, a0_len, a1, a1_len, work1);
	const a1_evln = addUnsignedLE(work1, a01_len, a2, a2_len, ea1);
	const b01_len = addUnsignedLE(b0, a0_len, b1, a1_len, work1);
	const b1_evln = addUnsignedLE(work1, b01_len, b2, a2_len, eb1);

	// a_m1_eval = a0 + a2 - a1 (signed); b_m1_eval similar
	const a02_len = addUnsignedLE(a0, a0_len, a2, a2_len, work1);
	const am1_sm = smAdd(1, work1, a02_len, -1, a1, a1_len, eam1);
	const b02_len = addUnsignedLE(b0, a0_len, b2, a2_len, work1);
	const bm1_sm = smAdd(1, work1, b02_len, -1, b1, a1_len, ebm1);

	// a2_eval = a0 + 2*a1 + 4*a2 (positive); b2_eval similar
	@memcpy(ea2[0..a0_len], a0);
	var ea2_len = a0_len;
	{
		const m2_len = mulSmallConst(a1, a1_len, 2, work1);
		ea2_len = addUnsignedLE(ea2, ea2_len, work1, m2_len, ea2);
		const m4_len = mulSmallConst(a2, a2_len, 4, work1);
		ea2_len = addUnsignedLE(ea2, ea2_len, work1, m4_len, ea2);
	}
	@memcpy(eb2[0..a0_len], b0);
	var eb2_len = a0_len;
	{
		const m2_len = mulSmallConst(b1, a1_len, 2, work1);
		eb2_len = addUnsignedLE(eb2, eb2_len, work1, m2_len, eb2);
		const m4_len = mulSmallConst(b2, a2_len, 4, work1);
		eb2_len = addUnsignedLE(eb2, eb2_len, work1, m4_len, eb2);
	}

	// ── 5 sub-multiplications ──
	// Pad all operand evaluations to a uniform `slot` byte length (zero-extend
	// on the high end). This lets every sub-multiplication use Karatsuba
	// uniformly — when lengths differ or aren't 8-byte multiples, mulMagnitudes
	// falls back to per-byte schoolbook which is dramatically slower.
	@memset(v0_buf, 0);
	{
		// v0 = a0 * b0 (size m × m).
		mulKaratsuba(a0[0..a0_len], b0[0..a0_len], v0_buf[0 .. 2 * a0_len], sub_scratch);
	}
	const v0_len = trimLen(v0_buf[0 .. 2 * a0_len]);

	@memset(vinf_buf, 0);
	{
		// v_inf = a2 * b2 (size a2_len × a2_len). Pad if a2_len < a0_len for chunking,
		// but keep it simple: use mulKaratsuba directly (handles small sizes via fallback).
		mulKaratsuba(a2, b2, vinf_buf[0 .. 2 * a2_len], sub_scratch);
	}
	const vinf_len = trimLen(vinf_buf[0 .. 2 * a2_len]);

	// v1, v_m1, v2: pad operands to `slot` bytes uniformly so Karatsuba applies.
	// (slot = m + 2, large enough for all eval results.)
	if (a1_evln < slot) @memset(ea1[a1_evln..slot], 0);
	if (b1_evln < slot) @memset(eb1[b1_evln..slot], 0);
	if (am1_sm.len < slot) @memset(eam1[am1_sm.len..slot], 0);
	if (bm1_sm.len < slot) @memset(ebm1[bm1_sm.len..slot], 0);
	if (ea2_len < slot) @memset(ea2[ea2_len..slot], 0);
	if (eb2_len < slot) @memset(eb2[eb2_len..slot], 0);

	@memset(v1_buf, 0);
	mulKaratsuba(ea1[0..slot], eb1[0..slot], v1_buf[0..psl], sub_scratch);
	const v1_len = trimLen(v1_buf[0..psl]);

	@memset(vm1_buf, 0);
	if (am1_sm.len > 0 and bm1_sm.len > 0) {
		mulKaratsuba(eam1[0..slot], ebm1[0..slot], vm1_buf[0..psl], sub_scratch);
	}
	const vm1_len = trimLen(vm1_buf[0..psl]);
	const vm1_sign: i8 = @intCast(@as(i32, am1_sm.sign) * @as(i32, bm1_sm.sign));

	@memset(v2_buf, 0);
	mulKaratsuba(ea2[0..slot], eb2[0..slot], v2_buf[0..psl], sub_scratch);
	const v2_len = trimLen(v2_buf[0..psl]);

	// ── Interpolation ──
	// c0 = v0
	// c4 = v_inf
	// S = (v1 + v_m1) / 2 = c0 + c2 + c4  → c2 = S - c0 - c4
	// D = (v1 - v_m1) / 2 = c1 + c3
	// 6c3 = v2 - c0 - 4c2 - 16c4 - 2D  → c3 = ... / 6
	// c1 = D - c3

	// Compute (v1 + v_m1) using sign-magnitude.
	const sum_sm = smAdd(1, v1_buf, v1_len, vm1_sign, vm1_buf, vm1_len, work1);
	// /2 (exact)
	var s_len = sum_sm.len;
	if (s_len > 0) s_len = divExactBy2(work1, s_len);
	// c2 = (S - v0) - v_inf
	const tmp_sm = smAdd(sum_sm.sign, work1, s_len, -1, v0_buf, v0_len, work2);
	const c2_sm = smAdd(tmp_sm.sign, work2, tmp_sm.len, -1, vinf_buf, vinf_len, work3);
	// (Save c2 in work3.)

	// Compute D = (v1 - v_m1) / 2  → into work1 (overwriting S).
	const diff_sm = smAdd(1, v1_buf, v1_len, @intCast(-@as(i32, vm1_sign)), vm1_buf, vm1_len, work1);
	var d_len = diff_sm.len;
	if (d_len > 0) d_len = divExactBy2(work1, d_len);
	const d_sign = diff_sm.sign;

	// Compute t = v2 - c0 - 4c2 - 16c4 - 2D, then c3 = t / 6.
	// Build into work2.
	@memcpy(work2[0..v2_len], v2_buf[0..v2_len]);
	var t_sm = SM{ .sign = 1, .len = v2_len };
	{
		// t -= v0
		const t1 = smAdd(t_sm.sign, work2, t_sm.len, -1, v0_buf, v0_len, work2);
		t_sm = .{ .sign = t1.sign, .len = t1.len };
	}
	// 4 * c2 → into a temp via mulSmallConst on the magnitude.
	var four_c2_buf: [16384]u8 = undefined; // big enough for any practical c2; spill to vinf_buf if needed.
	const four_c2_dst: []u8 = if (c2_sm.len + 1 <= four_c2_buf.len) four_c2_buf[0 .. c2_sm.len + 1] else blk: {
		// Fall back to using vinf_buf as scratch (vinf_buf has psl bytes which is plenty).
		break :blk vinf_buf[0 .. c2_sm.len + 1];
	};
	const four_c2_len = if (c2_sm.len > 0) mulSmallConst(work3, c2_sm.len, 4, four_c2_dst) else 0;
	{
		const t1 = smAdd(t_sm.sign, work2, t_sm.len, @intCast(-@as(i32, c2_sm.sign)), four_c2_dst, four_c2_len, work2);
		t_sm = .{ .sign = t1.sign, .len = t1.len };
	}
	// 16 * v_inf — use mulSmallConst with c=16. Use four_c2_buf as scratch.
	const sixteen_vinf_dst = four_c2_dst;
	const sixteen_vinf_len = mulSmallConst(vinf_buf, vinf_len, 16, sixteen_vinf_dst);
	{
		const t1 = smAdd(t_sm.sign, work2, t_sm.len, -1, sixteen_vinf_dst, sixteen_vinf_len, work2);
		t_sm = .{ .sign = t1.sign, .len = t1.len };
	}
	// 2 * D
	const two_d_dst = four_c2_dst;
	const two_d_len = mulSmallConst(work1, d_len, 2, two_d_dst);
	{
		const t1 = smAdd(t_sm.sign, work2, t_sm.len, @intCast(-@as(i32, d_sign)), two_d_dst, two_d_len, work2);
		t_sm = .{ .sign = t1.sign, .len = t1.len };
	}
	// /6
	if (t_sm.len > 0) {
		const after2 = divExactBy2(work2, t_sm.len);
		const after3 = divExactBy3(work2, after2);
		t_sm.len = after3;
	}
	const c3_sm = t_sm; // c3 in work2

	// c1 = D - c3
	const c1_sm = smAdd(d_sign, work1, d_len, @intCast(-@as(i32, c3_sm.sign)), work2, c3_sm.len, ea1);
	// (c1 in ea1, reusing — we don't need ea1 anymore.)

	// ── Compose result: c0 + c1*B + c2*B^2 + c3*B^3 + c4*B^4 ──
	// r[0..2m] gets c0 (= v0). r[4m..4m+2*a2_len] gets c4 (= v_inf).
	@memcpy(r[0 .. 2 * m], v0_buf[0 .. 2 * m]);
	@memcpy(r[4 * m .. 4 * m + 2 * a2_len], vinf_buf[0 .. 2 * a2_len]);
	// Zero the gap r[2m..4m] for the upcoming additions.
	@memset(r[2 * m .. 4 * m], 0);

	// Add c2 at offset 2m (signed; c2 is non-negative for valid Toom-3).
	if (c2_sm.len > 0) {
		if (c2_sm.sign > 0) {
			addUnsignedInPlace(r[2 * m ..], work3[0..c2_sm.len]);
		} else {
			subUnsignedInPlace(r[2 * m ..], work3[0..c2_sm.len]);
		}
	}
	// Add c1 at offset m.
	if (c1_sm.len > 0) {
		if (c1_sm.sign > 0) {
			addUnsignedInPlace(r[m..], ea1[0..c1_sm.len]);
		} else {
			subUnsignedInPlace(r[m..], ea1[0..c1_sm.len]);
		}
	}
	// Add c3 at offset 3m.
	if (c3_sm.len > 0) {
		if (c3_sm.sign > 0) {
			addUnsignedInPlace(r[3 * m ..], work2[0..c3_sm.len]);
		} else {
			subUnsignedInPlace(r[3 * m ..], work2[0..c3_sm.len]);
		}
	}
}

/// Trim trailing zero bytes from a buffer's view. Returns canonical length.
fn trimLen(buf: []const u8) usize {
	var n = buf.len;
	while (n > 0 and buf[n - 1] == 0) n -= 1;
	return n;
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
	fft_alloc: ?std.mem.Allocator,
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
	// Algorithm selection: CRT-FFT (extended range) → single-prime FFT →
	// Toom-3 (≥ 2K bytes) → Karatsuba (≥ 256) → chunked u64 schoolbook.
	const can_fft_crt = fft_alloc != null and a_pay.len == b_pay.len and a_pay.len >= FFT_CRT_THRESHOLD and a_pay.len + b_pay.len <= fft.MAX_FFT_CRT_COMBINED_LEN;
	const can_fft = fft_alloc != null and a_pay.len == b_pay.len and a_pay.len >= FFT_THRESHOLD and a_pay.len + b_pay.len <= fft.MAX_FFT_COMBINED_LEN;
	if (can_fft_crt) {
		_ = try fft.mulMagnitudesCRT(fft_alloc.?, scratch_a[0..a_pay.len], scratch_b[0..b_pay.len], scratch_r[0..r_len]);
	} else if (can_fft) {
		// E.1 + E.2 — use cached caller-supplied scratch. First call per
		// thread allocs the 5 buffers under fft_alloc; every subsequent
		// call with N <= cached_N reuses them. Saves 4-8 K ns/mul at N=8192.
		const need_len_fft = a_pay.len + b_pay.len;
		var N_fft: usize = 1;
		while (N_fft < need_len_fft) N_fft <<= 1;
		try fft_scratch.ensureCapacity(fft_alloc.?, N_fft);
		_ = fft.mulMagnitudesWithScratch(
			scratch_a[0..a_pay.len],
			scratch_b[0..b_pay.len],
			scratch_r[0..r_len],
			fft_scratch.pa,
			fft_scratch.pb,
			fft_scratch.tw_fwd,
			fft_scratch.tw_inv,
			fft_scratch.stockham,
		);
	} else if (a_pay.len == b_pay.len and a_pay.len >= TOOM3_THRESHOLD and scratch_k.len >= toom3ScratchNeed(a_pay.len)) {
		@memset(scratch_r[0..r_len], 0);
		mulToom3(scratch_a[0..a_pay.len], scratch_b[0..b_pay.len], scratch_r[0..r_len], scratch_k);
	} else if (a_pay.len == b_pay.len and a_pay.len >= KARATSUBA_THRESHOLD and scratch_k.len >= karatsubaScratchNeed(a_pay.len)) {
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

// ── Montgomery arithmetic for arbitrary odd modulus (M7-4.3) ────────────────
//
// Replaces the Knuth-Algorithm-D "mul-then-mod" inner loop of `Mp.powm` with
// CIOS Montgomery: each multiplication carries a fused reduction whose cost is
// a second multiply-add chain (no division), saving the dominant per-iteration
// cost in modular exponentiation.
//
// Definitions (k_limbs = ceil(m_byte_len / 8)):
//   R   = 2^(64 * k_limbs)        // R > m, R is a power of 2 aligned to a u64 limb
//   x'  = (x * R) mod m            // Montgomery form of x
//   montMul(a', b') = a' * b' * R^-1 mod m   // returns Mont form of (a*b mod m)
//
// To go in:  a' = montMul(a, R^2 mod m)
// To go out: a  = montMul(a', 1)
//
// All intermediate buffers are u64-limb arrays in little-endian order
// (limb[0] = least significant). The modulus passed in is also k_limbs of u64.
// Limb arrays are not exposed to callers — the high-level powm path packs
// BLIP magnitude bytes into u64 limbs then unpacks at the end.

/// Returns `(-m^(-1)) mod 2^64` for odd `m`. Newton's iteration converges
/// quadratically for the 2-adic inverse of an odd number; six iterations from
/// the seed `x = m mod 2^64` give 64 bits of precision (1, 2, 4, 8, 16, 32, 64).
/// Final negate flips `x = m^-1 mod 2^64` to `-m^-1 mod 2^64` so `t + u*m`'s
/// low limb cancels in the Montgomery reduction step.
pub fn modInvNeg64(m: u64) u64 {
	std.debug.assert((m & 1) == 1); // m must be odd for a 2-adic inverse to exist
	// Initial guess: m has the property that x = m gives 4 correct low bits
	// when m is odd (since m * m == 1 mod 8 iff m == 1 or 7 mod 8 ... use the
	// safe seed instead). The standard tight seed for 5-bit accuracy of m^-1 mod
	// 2^k for odd m is `(3*m) ^ 2` — gives 5 correct bits, then 6 doublings
	// reach 5 * 2^6 = 320 bits, well past 64. We use a slightly more
	// conservative starting point that is independently verified.
	var x: u64 = m;             // ≥ 4 bits correct
	x = x *% (2 -% m *% x);     // ≥ 8 bits
	x = x *% (2 -% m *% x);     // ≥ 16 bits
	x = x *% (2 -% m *% x);     // ≥ 32 bits
	x = x *% (2 -% m *% x);     // ≥ 64 bits
	x = x *% (2 -% m *% x);     // double-check (idempotent past 64 bits)
	// Now x == m^-1 mod 2^64. Negate two's-complement to get -m^-1.
	return 0 -% x;
}

/// CIOS Montgomery reduction of a wide (2*k_limbs) accumulator into a
/// k_limbs-wide result `out`. After this call `out` holds `(t * R^-1) mod m`,
/// reduced into `[0, m)`.
///
/// `t` length must be exactly `2 * m.len` (read-write — overwritten with
/// scratch). `out.len == m.len`.
fn montReduceCios(t: []u64, m: []const u64, m_inv_neg: u64, out: []u64) void {
	const k = m.len;
	std.debug.assert(t.len >= 2 * k + 1);
	std.debug.assert(out.len == k);

	// Process k digits — each iteration zeroes one low limb of `t` by adding
	// u_i * m at offset i, where u_i = t[i] * m_inv_neg mod 2^64.
	var i: usize = 0;
	while (i < k) : (i += 1) {
		const u: u64 = t[i] *% m_inv_neg;
		// t[i..] += u * m (k+1 limbs touched, last is the carry slot).
		var carry: u64 = 0;
		var j: usize = 0;
		while (j < k) : (j += 1) {
			// product = t[i+j] + u * m[j] + carry
			const prod: u128 = @as(u128, u) * @as(u128, m[j]) + @as(u128, t[i + j]) + @as(u128, carry);
			t[i + j] = @truncate(prod);
			carry = @intCast(prod >> 64);
		}
		// Propagate carry up the rest of t. Track an additional carry-out
		// because the final t[2k] may itself overflow once across the k outer
		// passes (we collect those into `extra_high`).
		var pos: usize = i + k;
		while (carry != 0 and pos < t.len) {
			const sum: u128 = @as(u128, t[pos]) + @as(u128, carry);
			t[pos] = @truncate(sum);
			carry = @intCast(sum >> 64);
			pos += 1;
		}
		// By construction t[i] is now zero (the whole point of u).
		std.debug.assert(t[i] == 0);
	}
	// After k iterations, the answer lives in t[k..2k] (and possibly the
	// carry slot t[2k]). Copy it down. If extra carry was set or result >= m,
	// subtract m once.
	const high_carry: u64 = if (t.len > 2 * k) t[2 * k] else 0;

	// out = t[k..2k]
	@memcpy(out, t[k .. 2 * k]);

	// Conditional subtraction: if high_carry != 0 OR out >= m, subtract m.
	// (After CIOS, out is bounded by 2m so a single subtract suffices.)
	const need_sub = high_carry != 0 or cmpLimbsGE(out, m);
	if (need_sub) {
		subLimbsInPlace(out, m);
	}
}

/// Returns true iff a >= b (both same length, LE limb arrays).
inline fn cmpLimbsGE(a: []const u64, b: []const u64) bool {
	std.debug.assert(a.len == b.len);
	var i: usize = a.len;
	while (i > 0) {
		i -= 1;
		if (a[i] != b[i]) return a[i] > b[i];
	}
	return true; // equal
}

/// In-place subtraction: `target -= sub` (caller guarantees target >= sub).
inline fn subLimbsInPlace(target: []u64, sub: []const u64) void {
	std.debug.assert(target.len == sub.len);
	var borrow: u64 = 0;
	var i: usize = 0;
	while (i < target.len) : (i += 1) {
		const a = target[i];
		const b = sub[i];
		const d1 = @subWithOverflow(a, b);
		const d2 = @subWithOverflow(d1[0], borrow);
		target[i] = d2[0];
		borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
	}
}

/// Montgomery multiplication: `out = a * b * R^-1 mod m`. All limb arrays are
/// LE u64 of length `k = m.len`. `scratch` length must be at least `2*k + 1`
/// (used as the wide intermediate `t`). Caller supplies all buffers.
pub fn montMul(
	a: []const u64,
	b: []const u64,
	m: []const u64,
	m_inv_neg: u64,
	out: []u64,
	scratch: []u64,
) void {
	const k = m.len;
	std.debug.assert(a.len == k and b.len == k and out.len == k);
	std.debug.assert(scratch.len >= 2 * k + 1);

	// Stage 1: schoolbook multiply a * b → t (2k limbs, plus carry slot).
	@memset(scratch[0 .. 2 * k + 1], 0);
	var i: usize = 0;
	while (i < k) : (i += 1) {
		const ai = a[i];
		if (ai == 0) continue;
		var carry: u64 = 0;
		var j: usize = 0;
		while (j < k) : (j += 1) {
			const prod: u128 = @as(u128, ai) * @as(u128, b[j]) + @as(u128, scratch[i + j]) + @as(u128, carry);
			scratch[i + j] = @truncate(prod);
			carry = @intCast(prod >> 64);
		}
		// Propagate the final carry up.
		var pos: usize = i + k;
		while (carry != 0 and pos < scratch.len) {
			const sum: u128 = @as(u128, scratch[pos]) + @as(u128, carry);
			scratch[pos] = @truncate(sum);
			carry = @intCast(sum >> 64);
			pos += 1;
		}
	}

	// Stage 2: Montgomery-reduce t into out.
	montReduceCios(scratch, m, m_inv_neg, out);
}

/// Pack a little-endian byte slice into a little-endian u64 limb array of
/// length `k_limbs`. Bytes past the input are zero-extended; bytes past the
/// limbs are dropped (caller responsibility to size correctly).
pub fn bytesToLimbs(bytes: []const u8, limbs: []u64) void {
	@memset(limbs, 0);
	const max_full = (bytes.len / 8);
	var i: usize = 0;
	while (i < max_full and i < limbs.len) : (i += 1) {
		limbs[i] = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
	}
	// Tail bytes (< 8) of the input.
	const tail_start = max_full * 8;
	if (tail_start < bytes.len and i < limbs.len) {
		var tail: [8]u8 = .{0} ** 8;
		const remaining = bytes.len - tail_start;
		@memcpy(tail[0..remaining], bytes[tail_start..]);
		limbs[i] = std.mem.readInt(u64, &tail, .little);
	}
}

/// Unpack a little-endian u64 limb array into a little-endian byte slice.
/// `bytes.len` may be less than `limbs.len * 8` — extra high bytes dropped.
pub fn limbsToBytes(limbs: []const u64, bytes: []u8) void {
	@memset(bytes, 0);
	const max_full = bytes.len / 8;
	var i: usize = 0;
	while (i < max_full and i < limbs.len) : (i += 1) {
		std.mem.writeInt(u64, bytes[i * 8 ..][0..8], limbs[i], .little);
	}
	const tail_start = max_full * 8;
	if (tail_start < bytes.len and i < limbs.len) {
		var tail: [8]u8 = undefined;
		std.mem.writeInt(u64, &tail, limbs[i], .little);
		const remaining = bytes.len - tail_start;
		@memcpy(bytes[tail_start..], tail[0..remaining]);
	}
}

/// Compute `R^2 mod m` where R = 2^(64*k_limbs), m has length k_limbs.
/// Algorithm: start with x = 1, then double mod m for `2 * 64 * k_limbs` bits.
/// O(k_limbs * k_limbs) work — fine because this runs once per powm call.
/// Result written into `out` (length k_limbs).
pub fn computeR2ModM(m: []const u64, out: []u64) void {
	const k = m.len;
	std.debug.assert(out.len == k);
	@memset(out, 0);
	out[0] = 1;
	const total_bits: usize = 2 * 64 * k;
	var bit: usize = 0;
	while (bit < total_bits) : (bit += 1) {
		// out = (out << 1) mod m. Track top-bit carry-out.
		var c: u64 = 0;
		var i: usize = 0;
		while (i < k) : (i += 1) {
			const new_top = out[i] >> 63;
			out[i] = (out[i] << 1) | c;
			c = new_top;
		}
		// Reduce: if c set OR out >= m, subtract m (handles "modulus has top
		// bit set so out is at most 2m-1 after a single shift").
		if (c != 0 or cmpLimbsGE(out, m)) {
			subLimbsInPlace(out, m);
		}
	}
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

test "cmpUnsignedLE: chunked vs naive equivalence across sizes" {
	// Naive reference (per-byte high-to-low) inline for cross-check.
	const naive = struct {
		fn cmp(a: []const u8, a_len: usize, b: []const u8, b_len: usize) i8 {
			if (a_len != b_len) return if (a_len > b_len) 1 else -1;
			var i: usize = a_len;
			while (i > 0) {
				i -= 1;
				if (a[i] > b[i]) return 1;
				if (a[i] < b[i]) return -1;
			}
			return 0;
		}
	}.cmp;
	const sizes = [_]usize{ 1, 7, 8, 9, 15, 16, 17, 23, 32, 100, 256, 1024 };
	var prng = std.Random.DefaultPrng.init(0xC0FFEE_5EED);
	const r = prng.random();
	var iter: usize = 0;
	while (iter < 200) : (iter += 1) {
		for (sizes) |sz| {
			const a = try testing.allocator.alloc(u8, sz);
			defer testing.allocator.free(a);
			const b = try testing.allocator.alloc(u8, sz);
			defer testing.allocator.free(b);
			for (a) |*p| p.* = r.int(u8);
			for (b) |*p| p.* = r.int(u8);
			try testing.expectEqual(naive(a, sz, b, sz), cmpUnsignedLE(a, sz, b, sz));
			// Also test equal: cmp(a, a) == 0
			try testing.expectEqual(@as(i8, 0), cmpUnsignedLE(a, sz, a, sz));
		}
	}
}

test "negateInPlace: chunked path correctness across sizes (8/16/24/...)" {
	// Sizes spanning the chunked (>= 8) + tail boundary, with random
	// payloads. Verify against the per-byte reference by negating twice
	// (involution: negate(negate(x)) == x).
	const sizes = [_]usize{ 8, 9, 15, 16, 17, 23, 32, 64, 100, 256, 257, 1024 };
	var prng = std.Random.DefaultPrng.init(0xCAFE_BEEF_FAB);
	const r = prng.random();
	for (sizes) |sz| {
		const buf = try testing.allocator.alloc(u8, sz);
		defer testing.allocator.free(buf);
		const orig = try testing.allocator.alloc(u8, sz);
		defer testing.allocator.free(orig);
		for (buf) |*p| p.* = r.int(u8);
		@memcpy(orig, buf);
		negateInPlace(buf);
		negateInPlace(buf);
		try testing.expectEqualSlices(u8, orig, buf);
	}
}

test "negateInPlace: known multi-limb -1 round-trip" {
	// 16 bytes of 0xFF = -1 as i128 → negation should give 1 as i128 LE.
	var p = [_]u8{0xFF} ** 16;
	negateInPlace(&p);
	try testing.expectEqual(@as(u8, 1), p[0]);
	for (1..16) |i| try testing.expectEqual(@as(u8, 0), p[i]);
	// And back: 1 → -1.
	negateInPlace(&p);
	for (0..16) |i| try testing.expectEqual(@as(u8, 0xFF), p[i]);
}

test "negateLimbsInPlace: zero stays zero" {
	var l = [_]u64{ 0, 0, 0 };
	negateLimbsInPlace(&l);
	try testing.expectEqual(@as(u64, 0), l[0]);
	try testing.expectEqual(@as(u64, 0), l[1]);
	try testing.expectEqual(@as(u64, 0), l[2]);
}

test "negateLimbsInPlace: 1 -> -1 (all ones over array)" {
	var l = [_]u64{ 1, 0, 0 };
	negateLimbsInPlace(&l);
	try testing.expectEqual(@as(u64, std.math.maxInt(u64)), l[0]);
	try testing.expectEqual(@as(u64, std.math.maxInt(u64)), l[1]);
	try testing.expectEqual(@as(u64, std.math.maxInt(u64)), l[2]);
}

test "negateLimbsInPlace: round-trip (negate twice == identity)" {
	const orig = [_]u64{ 0x12345678_9ABCDEF0, 0xCAFEBABE_DEADBEEF, 0x0102_0304_0506_0708, 0 };
	var l = orig;
	negateLimbsInPlace(&l);
	negateLimbsInPlace(&l);
	for (l, orig) |x, o| try testing.expectEqual(o, x);
}

test "payloadToMagLimbs: positive aligned (8 bytes = 1 limb)" {
	var limbs = [_]u64{ 0, 0 };
	const pay = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
	const n = payloadToMagLimbs(&pay, false, &limbs);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u64, 0x0807060504030201), limbs[0]);
	try testing.expectEqual(@as(u64, 0), limbs[1]);
}

test "payloadToMagLimbs: positive 9-byte (partial high limb)" {
	var limbs = [_]u64{ 0, 0 };
	const pay = [_]u8{ 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12 };
	const n = payloadToMagLimbs(&pay, false, &limbs);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u64, 0xFF), limbs[0]);
	try testing.expectEqual(@as(u64, 0x12), limbs[1]);
}

test "payloadToMagLimbs: negative -1 (single 0xFF byte)" {
	var limbs = [_]u64{0};
	const pay = [_]u8{0xFF};
	const n = payloadToMagLimbs(&pay, true, &limbs);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u64, 1), limbs[0]);
}

test "payloadToMagLimbs: negative -129 (LE: 7F FF) -> mag 129 in 1 limb" {
	var limbs = [_]u64{ 0, 0 };
	const pay = [_]u8{ 0x7F, 0xFF };
	const n = payloadToMagLimbs(&pay, true, &limbs);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u64, 129), limbs[0]);
}

test "payloadToMagLimbs: trailing zero limbs trimmed" {
	var limbs = [_]u64{ 0, 0, 0, 0 };
	const pay = [_]u8{ 0x42 };
	const n = payloadToMagLimbs(&pay, false, &limbs);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u64, 0x42), limbs[0]);
}

test "writeMagLimbsAsTwosComp: positive single byte (5)" {
	const limbs = [_]u64{5};
	var dst: [16]u8 = undefined;
	const n = writeMagLimbsAsTwosComp(&limbs, 1, false, &dst);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u8, 5), dst[0]);
}

test "writeMagLimbsAsTwosComp: positive 128 (needs 0x00 sign-ext)" {
	const limbs = [_]u64{128};
	var dst: [16]u8 = undefined;
	const n = writeMagLimbsAsTwosComp(&limbs, 1, false, &dst);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0x80), dst[0]);
	try testing.expectEqual(@as(u8, 0x00), dst[1]);
}

test "writeMagLimbsAsTwosComp: negative -1" {
	const limbs = [_]u64{1};
	var dst: [16]u8 = undefined;
	const n = writeMagLimbsAsTwosComp(&limbs, 1, true, &dst);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u8, 0xFF), dst[0]);
}

test "writeMagLimbsAsTwosComp: negative -128 (single byte 0x80)" {
	const limbs = [_]u64{128};
	var dst: [16]u8 = undefined;
	const n = writeMagLimbsAsTwosComp(&limbs, 1, true, &dst);
	try testing.expectEqual(@as(usize, 1), n);
	try testing.expectEqual(@as(u8, 0x80), dst[0]);
}

test "writeMagLimbsAsTwosComp: negative -129 (LE: 7F FF)" {
	const limbs = [_]u64{129};
	var dst: [16]u8 = undefined;
	const n = writeMagLimbsAsTwosComp(&limbs, 1, true, &dst);
	try testing.expectEqual(@as(usize, 2), n);
	try testing.expectEqual(@as(u8, 0x7F), dst[0]);
	try testing.expectEqual(@as(u8, 0xFF), dst[1]);
}

test "writeMagLimbsAsTwosComp: zero magnitude → single 0x00" {
	const limbs = [_]u64{ 0, 0 };
	var dst: [16]u8 = undefined;
	const n_pos = writeMagLimbsAsTwosComp(&limbs, 2, false, &dst);
	try testing.expectEqual(@as(usize, 1), n_pos);
	try testing.expectEqual(@as(u8, 0x00), dst[0]);
	const n_neg = writeMagLimbsAsTwosComp(&limbs, 2, true, &dst);
	try testing.expectEqual(@as(usize, 1), n_neg);
	try testing.expectEqual(@as(u8, 0x00), dst[0]);
}

test "writeMagLimbsAsTwosComp: positive multi-limb 9-byte mag" {
	// magnitude = 0x12 << 64 | 0xFF = LE bytes [FF,00,00,00,00,00,00,00,12]
	// Positive, high byte 0x12 has bit 7 clear → no sign-ext byte.
	const limbs = [_]u64{ 0xFF, 0x12 };
	var dst: [32]u8 = undefined;
	const n = writeMagLimbsAsTwosComp(&limbs, 2, false, &dst);
	try testing.expectEqual(@as(usize, 9), n);
	try testing.expectEqual(@as(u8, 0xFF), dst[0]);
	try testing.expectEqual(@as(u8, 0x12), dst[8]);
}

test "payloadToMagLimbs ↔ writeMagLimbsAsTwosComp round-trip (random)" {
	var rng = std.Random.DefaultPrng.init(0xD00D_CAFE);
	const r = rng.random();
	var i: usize = 0;
	while (i < 200) : (i += 1) {
		// Random byte length 1..40, random sign.
		const byte_len: usize = 1 + (r.int(usize) % 40);
		var pay: [40]u8 = undefined;
		var idx: usize = 0;
		while (idx < byte_len) : (idx += 1) pay[idx] = r.int(u8);
		// Force a canonical encoding by computing canonicalLen and then
		// adjusting if needed.
		const canon_len = canonicalLen(pay[0..byte_len]);
		const pay_canon = pay[0..canon_len];
		const neg = signExtByte(pay_canon) == 0xFF;
		// Pack to limbs.
		var limbs: [8]u64 = undefined;
		const n_lim_storage = (canon_len + 7) / 8;
		const n_lim = payloadToMagLimbs(pay_canon, neg, limbs[0..n_lim_storage]);
		// Write back.
		var dst: [64]u8 = undefined;
		const out_len = writeMagLimbsAsTwosComp(&limbs, n_lim, neg, &dst);
		// Round-trip should reproduce canonical payload exactly.
		try testing.expectEqual(canon_len, out_len);
		try testing.expectEqualSlices(u8, pay_canon, dst[0..out_len]);
	}
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
	const n = try mulRawBlip(&[_]u8{0x06}, &[_]u8{0x07}, &sa, &sb, &sr, &[_]u8{}, &out, null);
	try testing.expectEqualSlices(u8, &[_]u8{0x2A}, out[0..n]); // 42 immediate
}

test "mulRawBlip: positive * negative = negative (-6 * 7 = -42)" {
	var sa: [4]u8 = undefined;
	var sb: [4]u8 = undefined;
	var sr: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	// -6 = 0x81 0xFA (i8 -6); +7 = 0x07 immediate
	const n = try mulRawBlip(&[_]u8{ 0x81, 0xFA }, &[_]u8{0x07}, &sa, &sb, &sr, &[_]u8{}, &out, null);
	// -42 = i8 0xD6 → BLIP [0x81, 0xD6]
	try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xD6 }, out[0..n]);
}

test "mulRawBlip: negative * negative = positive (-6 * -7 = 42)" {
	var sa: [4]u8 = undefined;
	var sb: [4]u8 = undefined;
	var sr: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	const n = try mulRawBlip(&[_]u8{ 0x81, 0xFA }, &[_]u8{ 0x81, 0xF9 }, &sa, &sb, &sr, &[_]u8{}, &out, null);
	try testing.expectEqualSlices(u8, &[_]u8{0x2A}, out[0..n]); // 42 immediate
}

test "mulRawBlip: result is zero (anything * 0)" {
	var sa: [4]u8 = undefined;
	var sb: [4]u8 = undefined;
	var sr: [16]u8 = undefined;
	var out: [16]u8 = undefined;
	const n = try mulRawBlip(&[_]u8{0x05}, &[_]u8{0x00}, &sa, &sb, &sr, &[_]u8{}, &out, null);
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

	const n = try mulRawBlip(&a_blip, &b_blip, &sa, &sb, &sr, &sk, &out, null);

	// Verify by recomputing with the schoolbook path (passing empty scratch_k forces fallback).
	var sa2: [64]u8 = undefined;
	var sb2: [64]u8 = undefined;
	var sr2: [128]u8 = undefined;
	var out2: [128]u8 = undefined;
	const n2 = try mulRawBlip(&a_blip, &b_blip, &sa2, &sb2, &sr2, &[_]u8{}, &out2, null);
	try testing.expectEqualSlices(u8, out2[0..n2], out[0..n]);
}

test "mulSmallConst: byte-array * 3" {
	var out: [16]u8 = undefined;
	const a = [_]u8{ 0x55, 0x55, 0x55 }; // 0x555555 = 5_592_405
	const n = mulSmallConst(&a, a.len, 3, &out);
	// 5_592_405 * 3 = 16_777_215 = 0xFFFFFF
	try testing.expectEqual(@as(usize, 3), n);
	try testing.expectEqual(@as(u8, 0xFF), out[0]);
	try testing.expectEqual(@as(u8, 0xFF), out[1]);
	try testing.expectEqual(@as(u8, 0xFF), out[2]);
}

test "divExactBy5: round-trip" {
	// Cases with no trailing zeros (mulSmallConst trims, so round-trip
	// only round-trips canonical values).
	const cases = [_][]const u8{
		&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
		&[_]u8{ 0x12, 0x34, 0x56, 0x78 },
		&[_]u8{0x55},
		&[_]u8{ 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD },
		&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 },
	};
	for (cases) |a| {
		var prod_buf: [16]u8 = undefined;
		const prod_len = mulSmallConst(a, a.len, 5, &prod_buf);
		const back_len = divExactBy5(&prod_buf, prod_len);
		try testing.expectEqualSlices(u8, a, prod_buf[0..back_len]);
	}
}

test "mulSmallSignedConst: positive × positive" {
	const mag = [_]u8{ 0xC8, 0x00 }; // 200 unsigned
	var out: [4]u8 = undefined;
	const r = mulSmallSignedConst(.{ .sign = 1, .len = 2 }, &mag, 3, &out);
	// 200 * 3 = 600 = 0x258
	try testing.expectEqual(@as(i8, 1), r.sign);
	try testing.expectEqual(@as(usize, 2), r.len);
	try testing.expectEqual(@as(u8, 0x58), out[0]);
	try testing.expectEqual(@as(u8, 0x02), out[1]);
}

test "mulSmallSignedConst: negative × positive" {
	const mag = [_]u8{0x32}; // 50
	var out: [4]u8 = undefined;
	const r = mulSmallSignedConst(.{ .sign = -1, .len = 1 }, &mag, 4, &out);
	// -50 * 4 = -200, magnitude 200 = 0xC8
	try testing.expectEqual(@as(i8, -1), r.sign);
	try testing.expectEqual(@as(usize, 1), r.len);
	try testing.expectEqual(@as(u8, 0xC8), out[0]);
}

test "mulSmallSignedConst: zero result" {
	const mag = [_]u8{0x05};
	var out: [4]u8 = undefined;
	const r = mulSmallSignedConst(.{ .sign = 1, .len = 1 }, &mag, 0, &out);
	try testing.expectEqual(@as(i8, 0), r.sign);
	try testing.expectEqual(@as(usize, 0), r.len);
}

test "mulSmallSignedConst: zero magnitude" {
	var out: [4]u8 = undefined;
	const r = mulSmallSignedConst(.{ .sign = 0, .len = 0 }, &[_]u8{}, 5, &out);
	try testing.expectEqual(@as(i8, 0), r.sign);
	try testing.expectEqual(@as(usize, 0), r.len);
}

test "divExactBy5: known small values" {
	// 25 / 5 = 5
	var a = [_]u8{0x19};
	const n1 = divExactBy5(&a, 1);
	try testing.expectEqual(@as(usize, 1), n1);
	try testing.expectEqual(@as(u8, 0x05), a[0]);
	// 100 / 5 = 20
	var b = [_]u8{0x64};
	const n2 = divExactBy5(&b, 1);
	try testing.expectEqual(@as(usize, 1), n2);
	try testing.expectEqual(@as(u8, 0x14), b[0]);
}

test "divExactBy3: round-trip" {
	const cases = [_][]const u8{
		&[_]u8{ 0xFF, 0xFF, 0xFF },
		&[_]u8{ 0x12, 0x34, 0x56, 0x78 },
		&[_]u8{ 0x55 },
	};
	for (cases) |a| {
		// Multiply by 3, then divide by 3, expect identity.
		var prod_buf: [16]u8 = undefined;
		const prod_len = mulSmallConst(a, a.len, 3, &prod_buf);
		const back_len = divExactBy3(&prod_buf, prod_len);
		try testing.expectEqualSlices(u8, a, prod_buf[0..back_len]);
	}
}

test "divExactBy2: round-trip" {
	const cases = [_][]const u8{
		&[_]u8{ 0xFF, 0xFF, 0xFF },
		&[_]u8{ 0x12, 0x34, 0x56, 0x78 },
		&[_]u8{ 0x55 },
	};
	for (cases) |a| {
		var prod_buf: [16]u8 = undefined;
		const prod_len = mulSmallConst(a, a.len, 2, &prod_buf);
		const back_len = divExactBy2(&prod_buf, prod_len);
		try testing.expectEqualSlices(u8, a, prod_buf[0..back_len]);
	}
}

test "mulToom3 == mulMagnitudes for various sizes" {
	const cases = [_]usize{ 256, 384, 512, 1024 };
	for (cases) |n| {
		const a = std.testing.allocator.alloc(u8, n) catch unreachable;
		defer std.testing.allocator.free(a);
		const b = std.testing.allocator.alloc(u8, n) catch unreachable;
		defer std.testing.allocator.free(b);
		var rng = std.Random.DefaultPrng.init(0xDEADBEEF + n);
		const r = rng.random();
		for (a) |*p| p.* = r.int(u8);
		for (b) |*p| p.* = r.int(u8);

		const r_school = std.testing.allocator.alloc(u8, 2 * n) catch unreachable;
		defer std.testing.allocator.free(r_school);
		const r_toom = std.testing.allocator.alloc(u8, 2 * n) catch unreachable;
		defer std.testing.allocator.free(r_toom);
		const scratch = std.testing.allocator.alloc(u8, toom3ScratchNeed(n)) catch unreachable;
		defer std.testing.allocator.free(scratch);

		mulMagnitudes(a, b, r_school);
		@memset(r_toom, 0);
		mulToom3(a, b, r_toom, scratch);
		try testing.expectEqualSlices(u8, r_school, r_toom);
	}
}

test "mulRawBlip: i64.max * 2 (overflows i64)" {
	// i64.max = 0x7FFFFFFFFFFFFFFF as L=8 BLIP: [0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]
	const max_blip = &[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
	const two_blip = &[_]u8{0x02};
	var sa: [16]u8 = undefined;
	var sb: [16]u8 = undefined;
	var sr: [32]u8 = undefined;
	var out: [32]u8 = undefined;
	const n = try mulRawBlip(max_blip, two_blip, &sa, &sb, &sr, &[_]u8{}, &out, null);
	// Expected: 2 * (2^63 - 1) = 2^64 - 2.
	// As signed canonical: needs L=9 with leading 0x00.
	// LE payload: [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
	// BLIP: [0x89, ...]
	const expected = [_]u8{ 0x89, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
	try testing.expectEqualSlices(u8, &expected, out[0..n]);
}

// ── M7-2: divModSingleByte / divModSingleU64 tests ───────────────────────────

test "divModSingleByte: divisor = 1 (quotient = a, rem = 0)" {
	var a = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
	const r = divModSingleByte(&a, a.len, 1);
	try testing.expectEqual(@as(usize, 4), r.q_len);
	try testing.expectEqual(@as(u8, 0), r.rem);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0x78 }, a[0..r.q_len]);
}

test "divModSingleByte: magnitude all-zero" {
	var a = [_]u8{ 0, 0, 0, 0 };
	const r = divModSingleByte(&a, a.len, 7);
	try testing.expectEqual(@as(usize, 0), r.q_len);
	try testing.expectEqual(@as(u8, 0), r.rem);
}

test "divModSingleByte: empty input" {
	var a: [0]u8 = .{};
	const r = divModSingleByte(&a, 0, 7);
	try testing.expectEqual(@as(usize, 0), r.q_len);
	try testing.expectEqual(@as(u8, 0), r.rem);
}

test "divModSingleByte: 0xFFFF / 0xFF = 0x101 r 0" {
	// 0xFFFF = 65535; 65535 / 255 = 257 = 0x0101; rem = 0
	var a = [_]u8{ 0xFF, 0xFF };
	const r = divModSingleByte(&a, a.len, 0xFF);
	try testing.expectEqual(@as(usize, 2), r.q_len);
	try testing.expectEqual(@as(u8, 0), r.rem);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x01 }, a[0..r.q_len]);
}

test "divModSingleByte: small known values 1000 / 7" {
	// 1000 = 0x03E8 little-endian = [0xE8, 0x03]; 1000/7 = 142 r 6
	// 142 = 0x8E
	var a = [_]u8{ 0xE8, 0x03 };
	const r = divModSingleByte(&a, a.len, 7);
	try testing.expectEqual(@as(usize, 1), r.q_len);
	try testing.expectEqual(@as(u8, 6), r.rem);
	try testing.expectEqual(@as(u8, 142), a[0]);
}

test "divModSingleByte: trims trailing zero bytes" {
	// 0x100 / 2 = 0x80; result must be a single byte (high byte trimmed).
	var a = [_]u8{ 0x00, 0x01 };
	const r = divModSingleByte(&a, a.len, 2);
	try testing.expectEqual(@as(usize, 1), r.q_len);
	try testing.expectEqual(@as(u8, 0), r.rem);
	try testing.expectEqual(@as(u8, 0x80), a[0]);
}

test "divModSingleByte: round-trip via mulSmallConst (divisible)" {
	const cases = [_][]const u8{
		&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
		&[_]u8{ 0x12, 0x34, 0x56, 0x78 },
		&[_]u8{0x55},
		&[_]u8{ 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD },
		&[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 },
	};
	const divisors = [_]u8{ 2, 3, 5, 7, 11, 13, 17, 100, 200, 255 };
	for (cases) |a| {
		for (divisors) |d| {
			var prod_buf: [32]u8 = undefined;
			const prod_len = mulSmallConst(a, a.len, d, &prod_buf);
			const r = divModSingleByte(&prod_buf, prod_len, d);
			try testing.expectEqual(@as(u8, 0), r.rem);
			try testing.expectEqualSlices(u8, a, prod_buf[0..r.q_len]);
		}
	}
}

test "divModSingleByte: 1000 random pairs vs u256 oracle (a_len ≤ 32)" {
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0xC0FFEE_BABE);
	const r = rng.random();
	var i: usize = 0;
	while (i < 1000) : (i += 1) {
		const a_len = 1 + @as(usize, r.uintLessThan(u32, 32));
		const buf = try allocator.alloc(u8, a_len);
		defer allocator.free(buf);
		for (buf) |*p| p.* = r.int(u8);
		const divisor: u8 = 1 + r.uintLessThan(u8, 255); // 1..255

		// Reference via u256 (a_len ≤ 32 fits).
		var ref: u256 = 0;
		for (0..a_len) |k| ref |= @as(u256, buf[k]) << @intCast(8 * k);
		const q_ref: u256 = ref / @as(u256, divisor);
		const r_ref_v: u8 = @intCast(ref % @as(u256, divisor));

		// Compute via divModSingleByte.
		const work = try allocator.alloc(u8, a_len);
		defer allocator.free(work);
		@memcpy(work, buf);
		const out = divModSingleByte(work, a_len, divisor);

		// Compare remainder.
		try testing.expectEqual(r_ref_v, out.rem);

		// Compare quotient byte-by-byte using the canonical trimmed length.
		// Compute expected quotient bytes from q_ref and trim.
		var q_bytes: [32]u8 = undefined;
		for (0..32) |k| q_bytes[k] = @truncate(q_ref >> @intCast(8 * k));
		var expected_len: usize = 32;
		while (expected_len > 0 and q_bytes[expected_len - 1] == 0) expected_len -= 1;
		try testing.expectEqual(expected_len, out.q_len);
		try testing.expectEqualSlices(u8, q_bytes[0..expected_len], work[0..out.q_len]);
	}
}

test "divModSingleU64: divisor = 1 (quotient = a, rem = 0)" {
	var a = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
	const orig = a;
	const r = divModSingleU64(&a, a.len, 1);
	try testing.expectEqual(@as(usize, 16), r.q_len);
	try testing.expectEqual(@as(u64, 0), r.rem);
	try testing.expectEqualSlices(u8, &orig, a[0..r.q_len]);
}

test "divModSingleU64: empty input" {
	var a: [0]u8 = .{};
	const r = divModSingleU64(&a, 0, 7);
	try testing.expectEqual(@as(usize, 0), r.q_len);
	try testing.expectEqual(@as(u64, 0), r.rem);
}

test "divModSingleU64: matches divModSingleByte when divisor < 256 (aligned sizes)" {
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0xBADCAFE);
	const r = rng.random();
	const sizes = [_]usize{ 8, 16, 24, 32, 64, 128, 256 };
	for (sizes) |sz| {
		var trial: usize = 0;
		while (trial < 32) : (trial += 1) {
			const a = try allocator.alloc(u8, sz);
			defer allocator.free(a);
			for (a) |*p| p.* = r.int(u8);
			const d_byte: u8 = 1 + r.uintLessThan(u8, 255);

			const a_byte = try allocator.alloc(u8, sz);
			defer allocator.free(a_byte);
			@memcpy(a_byte, a);
			const a_u64 = try allocator.alloc(u8, sz);
			defer allocator.free(a_u64);
			@memcpy(a_u64, a);

			const r_byte = divModSingleByte(a_byte, sz, d_byte);
			const r_u64 = divModSingleU64(a_u64, sz, @as(u64, d_byte));

			try testing.expectEqual(r_byte.q_len, r_u64.q_len);
			try testing.expectEqual(@as(u64, r_byte.rem), r_u64.rem);
			try testing.expectEqualSlices(u8, a_byte[0..r_byte.q_len], a_u64[0..r_u64.q_len]);
		}
	}
}

test "divModSingleU64: matches divModSingleByte for non-aligned tail" {
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0x1234_5678);
	const r = rng.random();
	// Sizes that are NOT multiples of 8 — exercise the tail handling.
	const sizes = [_]usize{ 1, 2, 3, 5, 7, 9, 11, 15, 17, 23, 31, 33, 63, 65, 100, 127, 129 };
	for (sizes) |sz| {
		var trial: usize = 0;
		while (trial < 16) : (trial += 1) {
			const a = try allocator.alloc(u8, sz);
			defer allocator.free(a);
			for (a) |*p| p.* = r.int(u8);
			const d_byte: u8 = 1 + r.uintLessThan(u8, 255);

			const a_byte = try allocator.alloc(u8, sz);
			defer allocator.free(a_byte);
			@memcpy(a_byte, a);
			const a_u64 = try allocator.alloc(u8, sz);
			defer allocator.free(a_u64);
			@memcpy(a_u64, a);

			const r_byte = divModSingleByte(a_byte, sz, d_byte);
			const r_u64 = divModSingleU64(a_u64, sz, @as(u64, d_byte));

			try testing.expectEqual(r_byte.q_len, r_u64.q_len);
			try testing.expectEqual(@as(u64, r_byte.rem), r_u64.rem);
			try testing.expectEqualSlices(u8, a_byte[0..r_byte.q_len], a_u64[0..r_u64.q_len]);
		}
	}
}

test "divModSingleU64: 1000 random pairs vs u512 oracle (a_len ≤ 64, full u64 divisor)" {
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0xFEEDFACE);
	const r = rng.random();
	var i: usize = 0;
	while (i < 1000) : (i += 1) {
		const a_len = 1 + @as(usize, r.uintLessThan(u32, 64));
		const buf = try allocator.alloc(u8, a_len);
		defer allocator.free(buf);
		for (buf) |*p| p.* = r.int(u8);
		// Full u64 divisor range.
		var divisor: u64 = r.int(u64);
		if (divisor == 0) divisor = 1;

		var ref: u512 = 0;
		for (0..a_len) |k| ref |= @as(u512, buf[k]) << @intCast(8 * k);
		const q_ref: u512 = ref / @as(u512, divisor);
		const r_ref_v: u64 = @intCast(ref % @as(u512, divisor));

		const work = try allocator.alloc(u8, a_len);
		defer allocator.free(work);
		@memcpy(work, buf);
		const out = divModSingleU64(work, a_len, divisor);

		try testing.expectEqual(r_ref_v, out.rem);

		var q_bytes: [64]u8 = undefined;
		for (0..64) |k| q_bytes[k] = @truncate(q_ref >> @intCast(8 * k));
		var expected_len: usize = 64;
		while (expected_len > 0 and q_bytes[expected_len - 1] == 0) expected_len -= 1;
		try testing.expectEqual(expected_len, out.q_len);
		try testing.expectEqualSlices(u8, q_bytes[0..expected_len], work[0..out.q_len]);
	}
}

// ── M7-3: divModKnuth tests ──────────────────────────────────────────────────

/// Helper: compute a*b for unsigned LE byte arrays via mulMagnitudesU64Unaligned,
/// returning the canonical-trimmed length and writing into `r`.
fn testMulUnsigned(a: []const u8, b: []const u8, r: []u8) usize {
	mulMagnitudesU64Unaligned(a, b, r);
	var n = a.len + b.len;
	while (n > 0 and r[n - 1] == 0) n -= 1;
	return n;
}

test "divModKnuth: u < v → q=0, r=u" {
	const allocator = std.testing.allocator;
	const u = [_]u8{ 0xAB, 0xCD };
	const v = [_]u8{ 0x11, 0x22, 0x33 };
	var q: [4]u8 = undefined;
	var r: [4]u8 = undefined;
	const work = try allocator.alloc(u8, divModKnuthScratchNeed(u.len, v.len));
	defer allocator.free(work);
	const got = divModKnuth(&u, u.len, &v, v.len, &q, &r, work);
	try testing.expectEqual(@as(usize, 0), got.q_len);
	try testing.expectEqual(@as(usize, 2), got.r_len);
	try testing.expectEqualSlices(u8, &u, r[0..got.r_len]);
}

test "divModKnuth: u == v → q=1, r=0" {
	const allocator = std.testing.allocator;
	const v = [_]u8{ 0x11, 0x22, 0x33 };
	var q: [4]u8 = undefined;
	var r: [4]u8 = undefined;
	const work = try allocator.alloc(u8, divModKnuthScratchNeed(v.len, v.len));
	defer allocator.free(work);
	const got = divModKnuth(&v, v.len, &v, v.len, &q, &r, work);
	try testing.expectEqual(@as(usize, 1), got.q_len);
	try testing.expectEqual(@as(u8, 1), q[0]);
	try testing.expectEqual(@as(usize, 0), got.r_len);
}

test "divModKnuth: known small (0xFFFF / 0x0102 = 0xFD r 0x09)" {
	// 0xFFFF = 65535; 0x0102 = 258; 65535 / 258 = 253 (0xFD); 65535 - 253*258 = 65535 - 65274 = 261 = 0x0105.
	// Wait: 253 * 258 = 65274; 65535 - 65274 = 261. But 261 > 258 so 253 is too low.
	// Let me redo: 65535 / 258 = 254.012...; floor = 254. 254*258 = 65532; rem = 3.
	// So q = 254 = 0xFE, r = 3 = 0x03.
	const allocator = std.testing.allocator;
	const u = [_]u8{ 0xFF, 0xFF };
	const v = [_]u8{ 0x02, 0x01 }; // 258 LE
	var q: [4]u8 = undefined;
	var r: [4]u8 = undefined;
	const work = try allocator.alloc(u8, divModKnuthScratchNeed(u.len, v.len));
	defer allocator.free(work);
	const got = divModKnuth(&u, u.len, &v, v.len, &q, &r, work);
	try testing.expectEqual(@as(usize, 1), got.q_len);
	try testing.expectEqual(@as(u8, 0xFE), q[0]);
	try testing.expectEqual(@as(usize, 1), got.r_len);
	try testing.expectEqual(@as(u8, 0x03), r[0]);
}

test "divModKnuth: round-trip u = q*v, expect u/v == q exactly" {
	// Known divisible case: 0x010000 = 65536 = 256 * 256. v=[0x00, 0x01] (256 LE).
	// q=[0x00, 0x01] (256 LE). u=[0x00, 0x00, 0x01] (65536 LE).
	const allocator = std.testing.allocator;
	const u = [_]u8{ 0x00, 0x00, 0x01 };
	const v = [_]u8{ 0x00, 0x01 };
	var q: [4]u8 = undefined;
	var r: [4]u8 = undefined;
	const work = try allocator.alloc(u8, divModKnuthScratchNeed(u.len, v.len));
	defer allocator.free(work);
	const got = divModKnuth(&u, u.len, &v, v.len, &q, &r, work);
	try testing.expectEqual(@as(usize, 2), got.q_len);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, q[0..got.q_len]);
	try testing.expectEqual(@as(usize, 0), got.r_len);
}

test "divModKnuth: round-trip 100 random (q*v, v) pairs (small sizes)" {
	// Generate random q (1..16 bytes) and random v (2..8 bytes), compute u = q*v,
	// then divide u/v and assert quotient back == q, remainder == 0.
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0x1234_5678_9ABC_DEF0);
	const r_rng = rng.random();
	var trial: usize = 0;
	while (trial < 100) : (trial += 1) {
		const q_len_in = 1 + @as(usize, r_rng.uintLessThan(u32, 16));
		const v_len_in = 2 + @as(usize, r_rng.uintLessThan(u32, 7));
		const q_in = try allocator.alloc(u8, q_len_in);
		defer allocator.free(q_in);
		const v_in = try allocator.alloc(u8, v_len_in);
		defer allocator.free(v_in);
		for (q_in) |*p| p.* = r_rng.int(u8);
		for (v_in) |*p| p.* = r_rng.int(u8);
		// Ensure top bytes are non-zero (canonical).
		if (q_in[q_len_in - 1] == 0) q_in[q_len_in - 1] = 1;
		if (v_in[v_len_in - 1] == 0) v_in[v_len_in - 1] = 1;
		const u_buf = try allocator.alloc(u8, q_len_in + v_len_in + 1);
		defer allocator.free(u_buf);
		const u_len = testMulUnsigned(q_in, v_in, u_buf);

		const q_out = try allocator.alloc(u8, u_len);
		defer allocator.free(q_out);
		const r_out = try allocator.alloc(u8, v_len_in);
		defer allocator.free(r_out);
		const work = try allocator.alloc(u8, divModKnuthScratchNeed(u_len, v_len_in));
		defer allocator.free(work);
		const got = divModKnuth(u_buf, u_len, v_in, v_len_in, q_out, r_out, work);

		try testing.expectEqual(q_len_in, got.q_len);
		try testing.expectEqualSlices(u8, q_in, q_out[0..got.q_len]);
		try testing.expectEqual(@as(usize, 0), got.r_len);
	}
}

test "divModKnuth: random (u, v) pairs vs u4096 oracle (small)" {
	// Brute-force oracle: u up to 16 bytes (128 bits), v 2..8 bytes.
	// Use u256 for the oracle (16+8 = 24 bytes, well within u256).
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0xDEAD_BEEF_CAFE_C0DE);
	const r_rng = rng.random();
	var trial: usize = 0;
	while (trial < 200) : (trial += 1) {
		const u_len_in = 2 + @as(usize, r_rng.uintLessThan(u32, 15));
		const v_len_in = 2 + @as(usize, r_rng.uintLessThan(u32, 7));
		const u_in = try allocator.alloc(u8, u_len_in);
		defer allocator.free(u_in);
		const v_in = try allocator.alloc(u8, v_len_in);
		defer allocator.free(v_in);
		for (u_in) |*p| p.* = r_rng.int(u8);
		for (v_in) |*p| p.* = r_rng.int(u8);
		if (u_in[u_len_in - 1] == 0) u_in[u_len_in - 1] = 1;
		if (v_in[v_len_in - 1] == 0) v_in[v_len_in - 1] = 1;

		// Oracle via u256.
		var u_ref: u256 = 0;
		for (0..u_len_in) |k| u_ref |= @as(u256, u_in[k]) << @intCast(8 * k);
		var v_ref: u256 = 0;
		for (0..v_len_in) |k| v_ref |= @as(u256, v_in[k]) << @intCast(8 * k);
		const q_ref: u256 = u_ref / v_ref;
		const r_ref: u256 = u_ref % v_ref;

		const q_out = try allocator.alloc(u8, u_len_in + 1);
		defer allocator.free(q_out);
		const r_out = try allocator.alloc(u8, v_len_in);
		defer allocator.free(r_out);
		const work = try allocator.alloc(u8, divModKnuthScratchNeed(u_len_in, v_len_in));
		defer allocator.free(work);
		const got = divModKnuth(u_in, u_len_in, v_in, v_len_in, q_out, r_out, work);

		// Build expected q/r byte arrays and compare. u256 has 32 bytes.
		var q_bytes: [32]u8 = .{0} ** 32;
		for (0..32) |k| q_bytes[k] = @truncate(q_ref >> @intCast(8 * k));
		var q_expect_len: usize = 32;
		while (q_expect_len > 0 and q_bytes[q_expect_len - 1] == 0) q_expect_len -= 1;

		var r_bytes: [32]u8 = .{0} ** 32;
		for (0..32) |k| r_bytes[k] = @truncate(r_ref >> @intCast(8 * k));
		var r_expect_len: usize = 32;
		while (r_expect_len > 0 and r_bytes[r_expect_len - 1] == 0) r_expect_len -= 1;

		testing.expectEqual(q_expect_len, got.q_len) catch |e| {
			std.debug.print("trial {d}: u_len={d} v_len={d}, q_expect_len={d} got.q_len={d}\n", .{ trial, u_len_in, v_len_in, q_expect_len, got.q_len });
			std.debug.print("  u_in={any}\n  v_in={any}\n", .{ u_in, v_in });
			std.debug.print("  q_expect={any}\n  q_got={any}\n", .{ q_bytes[0..q_expect_len], q_out[0..got.q_len] });
			return e;
		};
		try testing.expectEqualSlices(u8, q_bytes[0..q_expect_len], q_out[0..got.q_len]);
		try testing.expectEqual(r_expect_len, got.r_len);
		try testing.expectEqualSlices(u8, r_bytes[0..r_expect_len], r_out[0..got.r_len]);
	}
}

test "divModKnuth: round-trip large (256-byte dividend, 32-byte divisor)" {
	// Build random q (up to 224 bytes) and v (32 bytes), compute u = q*v,
	// then divide back. 100 trials.
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0xC0DE_FACE_BAAD_F00D);
	const r_rng = rng.random();
	var trial: usize = 0;
	while (trial < 100) : (trial += 1) {
		const q_len_in: usize = 1 + @as(usize, r_rng.uintLessThan(u32, 224));
		const v_len_in: usize = 32;
		const q_in = try allocator.alloc(u8, q_len_in);
		defer allocator.free(q_in);
		const v_in = try allocator.alloc(u8, v_len_in);
		defer allocator.free(v_in);
		for (q_in) |*p| p.* = r_rng.int(u8);
		for (v_in) |*p| p.* = r_rng.int(u8);
		if (q_in[q_len_in - 1] == 0) q_in[q_len_in - 1] = 1;
		if (v_in[v_len_in - 1] == 0) v_in[v_len_in - 1] = 1;
		const u_buf = try allocator.alloc(u8, q_len_in + v_len_in + 1);
		defer allocator.free(u_buf);
		const u_len = testMulUnsigned(q_in, v_in, u_buf);

		const q_out = try allocator.alloc(u8, u_len);
		defer allocator.free(q_out);
		const r_out = try allocator.alloc(u8, v_len_in);
		defer allocator.free(r_out);
		const work = try allocator.alloc(u8, divModKnuthScratchNeed(u_len, v_len_in));
		defer allocator.free(work);
		const got = divModKnuth(u_buf, u_len, v_in, v_len_in, q_out, r_out, work);

		try testing.expectEqual(q_len_in, got.q_len);
		try testing.expectEqualSlices(u8, q_in, q_out[0..got.q_len]);
		try testing.expectEqual(@as(usize, 0), got.r_len);
	}
}

// ── divModKnuthU64 tests (M7-3 u64-base reformulation) ──────────────────────

/// Test helper: schoolbook multiply two u64 limb arrays into `r`.
/// Used to build u = q*v dividends for round-trip tests.
fn testMulLimbs(a: []const u64, b: []const u64, r: []u64) usize {
	@memset(r, 0);
	var i: usize = 0;
	while (i < a.len) : (i += 1) {
		var carry: u64 = 0;
		var k: usize = 0;
		while (k < b.len) : (k += 1) {
			const p: u128 = @as(u128, a[i]) * @as(u128, b[k]);
			const sum: u128 = @as(u128, r[i + k]) + p + @as(u128, carry);
			r[i + k] = @truncate(sum);
			carry = @truncate(sum >> 64);
		}
		r[i + b.len] = carry;
	}
	var n: usize = a.len + b.len;
	while (n > 0 and r[n - 1] == 0) n -= 1;
	return n;
}

test "divModKnuthU64: u < v → q=0, r=u" {
	const allocator = std.testing.allocator;
	const v_init = [_]u64{ 0x1111_2222_3333_4444, 0x5555_6666_7777_8888 };
	const u_init = [_]u64{ 0xDEAD_BEEF_CAFE_F00D };
	const u = try allocator.alloc(u64, u_init.len + 1); // +1 capacity for normalize
	defer allocator.free(u);
	u[0] = u_init[0];
	u[1] = 0;
	var q: [4]u64 = undefined;
	var r: [4]u64 = undefined;
	const got = divModKnuthU64(u, u_init.len, &v_init, v_init.len, &q, &r);
	try testing.expectEqual(@as(usize, 0), got.q_len);
	try testing.expectEqual(@as(usize, 1), got.r_len);
	try testing.expectEqual(u_init[0], r[0]);
}

test "divModKnuthU64: u == v → q=1, r=0" {
	const allocator = std.testing.allocator;
	const v_init = [_]u64{ 0x1111_2222_3333_4444, 0x5555_6666_7777_8888 };
	const u = try allocator.alloc(u64, v_init.len + 1);
	defer allocator.free(u);
	u[0] = v_init[0];
	u[1] = v_init[1];
	u[2] = 0;
	var q: [4]u64 = undefined;
	var r: [4]u64 = undefined;
	const got = divModKnuthU64(u, v_init.len, &v_init, v_init.len, &q, &r);
	try testing.expectEqual(@as(usize, 1), got.q_len);
	try testing.expectEqual(@as(u64, 1), q[0]);
	try testing.expectEqual(@as(usize, 0), got.r_len);
}

test "divModKnuthU64: round-trip — random q*v dividends recover q exactly" {
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0xCAFEFACE_DEADBEEF);
	const r_rng = rng.random();
	const v_lens = [_]usize{ 2, 4, 8, 16 };
	for (v_lens) |v_len| {
		var trial: usize = 0;
		while (trial < 100) : (trial += 1) {
			const q_len = 1 + @as(usize, r_rng.uintLessThan(u32, 16));
			const q_in = try allocator.alloc(u64, q_len);
			defer allocator.free(q_in);
			const v_in = try allocator.alloc(u64, v_len);
			defer allocator.free(v_in);
			for (q_in) |*p| p.* = r_rng.int(u64);
			for (v_in) |*p| p.* = r_rng.int(u64);
			if (q_in[q_len - 1] == 0) q_in[q_len - 1] = 1;
			if (v_in[v_len - 1] == 0) v_in[v_len - 1] = 1;
			const u_buf = try allocator.alloc(u64, q_len + v_len + 1); // +1 for normalize headroom
			defer allocator.free(u_buf);
			const u_len = testMulLimbs(q_in, v_in, u_buf[0 .. q_len + v_len]);

			const q_out = try allocator.alloc(u64, u_len);
			defer allocator.free(q_out);
			const r_out = try allocator.alloc(u64, v_len);
			defer allocator.free(r_out);
			const got = divModKnuthU64(u_buf, u_len, v_in, v_len, q_out, r_out);

			testing.expectEqual(q_len, got.q_len) catch |e| {
				std.debug.print("v_len={d} trial={d}: q_len={d} got.q_len={d}\n", .{ v_len, trial, q_len, got.q_len });
				return e;
			};
			try testing.expectEqualSlices(u64, q_in, q_out[0..got.q_len]);
			try testing.expectEqual(@as(usize, 0), got.r_len);
		}
	}
}

test "divModKnuthU64: cross-check vs byte-base divModKnuth (random small)" {
	// For each random (u, v), run BOTH the byte-base and u64-base algorithms;
	// the byte-base is already GMP-validated so it's a trusted oracle.
	const allocator = std.testing.allocator;
	var rng = std.Random.DefaultPrng.init(0xBAD_C0FFEE_C0DE);
	const r_rng = rng.random();
	var trial: usize = 0;
	while (trial < 500) : (trial += 1) {
		// Limb-aligned sizes 2..16 limbs for divisor; 2..32 limbs for dividend.
		const v_limbs = 2 + @as(usize, r_rng.uintLessThan(u32, 15));
		const u_limbs = v_limbs + @as(usize, r_rng.uintLessThan(u32, 17));

		// Build limb arrays.
		const v_lim = try allocator.alloc(u64, v_limbs);
		defer allocator.free(v_lim);
		const u_lim_orig = try allocator.alloc(u64, u_limbs);
		defer allocator.free(u_lim_orig);
		for (v_lim) |*p| p.* = r_rng.int(u64);
		for (u_lim_orig) |*p| p.* = r_rng.int(u64);
		if (v_lim[v_limbs - 1] == 0) v_lim[v_limbs - 1] = 1;
		if (u_lim_orig[u_limbs - 1] == 0) u_lim_orig[u_limbs - 1] = 1;

		// Byte-form versions for the byte-base oracle.
		const v_bytes = try allocator.alloc(u8, v_limbs * 8);
		defer allocator.free(v_bytes);
		const u_bytes = try allocator.alloc(u8, u_limbs * 8);
		defer allocator.free(u_bytes);
		limbsToBytes(v_lim, v_bytes);
		limbsToBytes(u_lim_orig, u_bytes);
		// Byte-form canonical lengths (trim trailing zero bytes).
		var v_byte_len: usize = v_bytes.len;
		while (v_byte_len > 0 and v_bytes[v_byte_len - 1] == 0) v_byte_len -= 1;
		var u_byte_len: usize = u_bytes.len;
		while (u_byte_len > 0 and u_bytes[u_byte_len - 1] == 0) u_byte_len -= 1;

		// Reference via byte-base Knuth.
		const q_ref = try allocator.alloc(u8, u_byte_len + 1);
		defer allocator.free(q_ref);
		const r_ref = try allocator.alloc(u8, v_byte_len);
		defer allocator.free(r_ref);
		const work_ref = try allocator.alloc(u8, divModKnuthScratchNeed(u_byte_len, v_byte_len));
		defer allocator.free(work_ref);
		const ref = divModKnuth(u_bytes, u_byte_len, v_bytes, v_byte_len, q_ref, r_ref, work_ref);

		// Now u64-base. Need u with capacity u_limbs+1.
		const u_lim = try allocator.alloc(u64, u_limbs + 1);
		defer allocator.free(u_lim);
		for (0..u_limbs) |i| u_lim[i] = u_lim_orig[i];
		u_lim[u_limbs] = 0;
		const q_lim = try allocator.alloc(u64, u_limbs);
		defer allocator.free(q_lim);
		const r_lim = try allocator.alloc(u64, v_limbs);
		defer allocator.free(r_lim);
		const got = divModKnuthU64(u_lim, u_limbs, v_lim, v_limbs, q_lim, r_lim);

		// Convert u64 outputs to bytes for comparison with the byte oracle.
		const q_lim_bytes = try allocator.alloc(u8, got.q_len * 8);
		defer allocator.free(q_lim_bytes);
		const r_lim_bytes = try allocator.alloc(u8, got.r_len * 8);
		defer allocator.free(r_lim_bytes);
		limbsToBytes(q_lim[0..got.q_len], q_lim_bytes);
		limbsToBytes(r_lim[0..got.r_len], r_lim_bytes);
		// Trim u64-output bytes to canonical length.
		var q_lim_byte_len: usize = q_lim_bytes.len;
		while (q_lim_byte_len > 0 and q_lim_bytes[q_lim_byte_len - 1] == 0) q_lim_byte_len -= 1;
		var r_lim_byte_len: usize = r_lim_bytes.len;
		while (r_lim_byte_len > 0 and r_lim_bytes[r_lim_byte_len - 1] == 0) r_lim_byte_len -= 1;

		testing.expectEqual(ref.q_len, q_lim_byte_len) catch |e| {
			std.debug.print(
				"trial {d}: u_limbs={d} v_limbs={d}, ref.q_len={d} u64.q_len_bytes={d}\n",
				.{ trial, u_limbs, v_limbs, ref.q_len, q_lim_byte_len },
			);
			return e;
		};
		try testing.expectEqualSlices(u8, q_ref[0..ref.q_len], q_lim_bytes[0..q_lim_byte_len]);
		try testing.expectEqual(ref.r_len, r_lim_byte_len);
		try testing.expectEqualSlices(u8, r_ref[0..ref.r_len], r_lim_bytes[0..r_lim_byte_len]);
	}
}

test "divModKnuthU64: edge — v top-limb already normalized (s=0)" {
	// Top limb has bit 63 set → normalize shift s = 0.
	const allocator = std.testing.allocator;
	const v = [_]u64{ 0x1234_5678_9ABC_DEF0, 0xC000_0000_0000_0001 };
	const u_init = [_]u64{ 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111, 0x2222_3333_4444_5555 };
	const u = try allocator.alloc(u64, u_init.len + 1);
	defer allocator.free(u);
	for (0..u_init.len) |i| u[i] = u_init[i];
	u[u_init.len] = 0;
	var q: [4]u64 = undefined;
	var r: [4]u64 = undefined;
	const got = divModKnuthU64(u, u_init.len, &v, v.len, &q, &r);

	// Cross-check vs byte-base.
	var v_bytes: [16]u8 = undefined;
	var u_bytes: [24]u8 = undefined;
	limbsToBytes(&v, &v_bytes);
	limbsToBytes(&u_init, &u_bytes);
	var q_ref_bytes: [25]u8 = undefined;
	var r_ref_bytes: [16]u8 = undefined;
	const work = try allocator.alloc(u8, divModKnuthScratchNeed(u_bytes.len, v_bytes.len));
	defer allocator.free(work);
	const ref = divModKnuth(&u_bytes, u_bytes.len, &v_bytes, v_bytes.len, &q_ref_bytes, &r_ref_bytes, work);

	var q_got_bytes: [32]u8 = .{0} ** 32;
	var r_got_bytes: [16]u8 = .{0} ** 16;
	limbsToBytes(q[0..got.q_len], q_got_bytes[0..@min(got.q_len * 8, q_got_bytes.len)]);
	limbsToBytes(r[0..got.r_len], r_got_bytes[0..@min(got.r_len * 8, r_got_bytes.len)]);
	var q_got_len: usize = q_got_bytes.len;
	while (q_got_len > 0 and q_got_bytes[q_got_len - 1] == 0) q_got_len -= 1;
	var r_got_len: usize = r_got_bytes.len;
	while (r_got_len > 0 and r_got_bytes[r_got_len - 1] == 0) r_got_len -= 1;

	try testing.expectEqual(ref.q_len, q_got_len);
	try testing.expectEqualSlices(u8, q_ref_bytes[0..ref.q_len], q_got_bytes[0..q_got_len]);
	try testing.expectEqual(ref.r_len, r_got_len);
	try testing.expectEqualSlices(u8, r_ref_bytes[0..ref.r_len], r_got_bytes[0..r_got_len]);
}

test "divModKnuthU64: edge — v top-limb has only bit 0 set (s=63)" {
	// Top limb = 1 → clz=63 → maximum normalize shift.
	const allocator = std.testing.allocator;
	const v = [_]u64{ 0x1234_5678_9ABC_DEF0, 0x0000_0000_0000_0001 };
	const u_init = [_]u64{ 0xAAAA_BBBB_CCCC_DDDD, 0xEEEE_FFFF_0000_1111, 0x2222_3333_4444_5555 };
	const u = try allocator.alloc(u64, u_init.len + 1);
	defer allocator.free(u);
	for (0..u_init.len) |i| u[i] = u_init[i];
	u[u_init.len] = 0;
	var q: [4]u64 = undefined;
	var r: [4]u64 = undefined;
	const got = divModKnuthU64(u, u_init.len, &v, v.len, &q, &r);

	// Cross-check vs byte-base.
	var v_bytes: [16]u8 = undefined;
	var u_bytes: [24]u8 = undefined;
	limbsToBytes(&v, &v_bytes);
	limbsToBytes(&u_init, &u_bytes);
	var v_byte_len: usize = v_bytes.len;
	while (v_byte_len > 0 and v_bytes[v_byte_len - 1] == 0) v_byte_len -= 1;
	var q_ref_bytes: [25]u8 = undefined;
	var r_ref_bytes: [16]u8 = undefined;
	const work = try allocator.alloc(u8, divModKnuthScratchNeed(u_bytes.len, v_byte_len));
	defer allocator.free(work);
	const ref = divModKnuth(&u_bytes, u_bytes.len, &v_bytes, v_byte_len, &q_ref_bytes, &r_ref_bytes, work);

	var q_got_bytes: [32]u8 = .{0} ** 32;
	var r_got_bytes: [16]u8 = .{0} ** 16;
	limbsToBytes(q[0..got.q_len], q_got_bytes[0..@min(got.q_len * 8, q_got_bytes.len)]);
	limbsToBytes(r[0..got.r_len], r_got_bytes[0..@min(got.r_len * 8, r_got_bytes.len)]);
	var q_got_len: usize = q_got_bytes.len;
	while (q_got_len > 0 and q_got_bytes[q_got_len - 1] == 0) q_got_len -= 1;
	var r_got_len: usize = r_got_bytes.len;
	while (r_got_len > 0 and r_got_bytes[r_got_len - 1] == 0) r_got_len -= 1;

	try testing.expectEqual(ref.q_len, q_got_len);
	try testing.expectEqualSlices(u8, q_ref_bytes[0..ref.q_len], q_got_bytes[0..q_got_len]);
	try testing.expectEqual(ref.r_len, r_got_len);
	try testing.expectEqualSlices(u8, r_ref_bytes[0..ref.r_len], r_got_bytes[0..r_got_len]);
}

test "divModKnuth: edge — top-byte-of-v already normalized (s=0)" {
	// v[v_len-1] >= 128 means s=0; tests the no-shift path.
	const allocator = std.testing.allocator;
	const u = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC };
	const v = [_]u8{ 0x33, 0xCC }; // 0xCC has high bit set
	var q: [8]u8 = undefined;
	var r: [8]u8 = undefined;
	const work = try allocator.alloc(u8, divModKnuthScratchNeed(u.len, v.len));
	defer allocator.free(work);
	const got = divModKnuth(&u, u.len, &v, v.len, &q, &r, work);
	// Reference via u128:
	const u_ref: u128 = 0xBC9A78563412;
	const v_ref: u128 = 0xCC33;
	const q_ref: u128 = u_ref / v_ref;
	const r_ref: u128 = u_ref % v_ref;
	var q_bytes: [16]u8 = undefined;
	for (0..16) |k| q_bytes[k] = @truncate(q_ref >> @intCast(8 * k));
	var q_expect_len: usize = 16;
	while (q_expect_len > 0 and q_bytes[q_expect_len - 1] == 0) q_expect_len -= 1;
	var r_bytes: [16]u8 = undefined;
	for (0..16) |k| r_bytes[k] = @truncate(r_ref >> @intCast(8 * k));
	var r_expect_len: usize = 16;
	while (r_expect_len > 0 and r_bytes[r_expect_len - 1] == 0) r_expect_len -= 1;
	try testing.expectEqual(q_expect_len, got.q_len);
	try testing.expectEqualSlices(u8, q_bytes[0..q_expect_len], q[0..got.q_len]);
	try testing.expectEqual(r_expect_len, got.r_len);
	try testing.expectEqualSlices(u8, r_bytes[0..r_expect_len], r[0..got.r_len]);
}

// Quick monotonic-clock helper for the bench test, since std.time.Timer was
// removed in Zig 0.16. Returns nanoseconds since some unspecified epoch
// (suitable for measuring deltas only).
fn monoNanos() u64 {
	var ts: std.c.timespec = undefined;
	_ = std.c.clock_gettime(.MONOTONIC, &ts);
	return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "bench: divModKnuth at 2048-bit / 1024-bit" {
	// Mp.divMod-equivalent unsigned magnitude division: 256-byte dividend / 128-byte divisor.
	const allocator = std.testing.allocator;
	const u_len: usize = 256; // 2048 bits
	const v_len: usize = 128; // 1024 bits
	const iters: usize = 1000;

	const u_template = try allocator.alloc(u8, u_len);
	defer allocator.free(u_template);
	const v_template = try allocator.alloc(u8, v_len);
	defer allocator.free(v_template);
	var rng = std.Random.DefaultPrng.init(0x4242_4242);
	const rnd = rng.random();
	for (u_template) |*p| p.* = rnd.int(u8);
	for (v_template) |*p| p.* = rnd.int(u8);
	if (v_template[v_len - 1] == 0) v_template[v_len - 1] = 0xAA;
	if (u_template[u_len - 1] == 0) u_template[u_len - 1] = 0xCC;

	const q_buf = try allocator.alloc(u8, u_len + 2);
	defer allocator.free(q_buf);
	const r_buf = try allocator.alloc(u8, v_len + 2);
	defer allocator.free(r_buf);
	const work_buf = try allocator.alloc(u8, divModKnuthScratchNeed(u_len, v_len));
	defer allocator.free(work_buf);

	// Warm-up.
	_ = divModKnuth(u_template, u_len, v_template, v_len, q_buf, r_buf, work_buf);

	const t_start = monoNanos();
	{
		var i: usize = 0;
		while (i < iters) : (i += 1) {
			const out = divModKnuth(u_template, u_len, v_template, v_len, q_buf, r_buf, work_buf);
			std.mem.doNotOptimizeAway(&out);
		}
	}
	const t_total = monoNanos() - t_start;
	const ns_per_op = @as(f64, @floatFromInt(t_total)) / @as(f64, @floatFromInt(iters));
	std.debug.print(
		"\n[bench] divModKnuth 2048-bit / 1024-bit: {d:.0} ns/op\n",
		.{ns_per_op},
	);
}

test "bench: divModKnuthU64 at 2048-bit / 1024-bit" {
	// Same workload as the byte-base bench above so we can compare directly:
	// 256-byte / 128-byte == 32-limb / 16-limb in u64.
	const allocator = std.testing.allocator;
	const u_limbs: usize = 32; // 2048 bits
	const v_limbs: usize = 16; // 1024 bits
	const iters: usize = 1000;

	const u_template = try allocator.alloc(u64, u_limbs);
	defer allocator.free(u_template);
	const v_template = try allocator.alloc(u64, v_limbs);
	defer allocator.free(v_template);
	var rng = std.Random.DefaultPrng.init(0x4242_4242);
	const rnd = rng.random();
	for (u_template) |*p| p.* = rnd.int(u64);
	for (v_template) |*p| p.* = rnd.int(u64);
	if (v_template[v_limbs - 1] == 0) v_template[v_limbs - 1] = 0xAAAA_AAAA_AAAA_AAAA;
	if (u_template[u_limbs - 1] == 0) u_template[u_limbs - 1] = 0xCCCC_CCCC_CCCC_CCCC;

	const u_buf = try allocator.alloc(u64, u_limbs + 1);
	defer allocator.free(u_buf);
	const q_buf = try allocator.alloc(u64, u_limbs);
	defer allocator.free(q_buf);
	const r_buf = try allocator.alloc(u64, v_limbs);
	defer allocator.free(r_buf);

	// Warm-up.
	@memcpy(u_buf[0..u_limbs], u_template);
	u_buf[u_limbs] = 0;
	_ = divModKnuthU64(u_buf, u_limbs, v_template, v_limbs, q_buf, r_buf);

	const t_start = monoNanos();
	{
		var i: usize = 0;
		while (i < iters) : (i += 1) {
			@memcpy(u_buf[0..u_limbs], u_template);
			u_buf[u_limbs] = 0;
			const out = divModKnuthU64(u_buf, u_limbs, v_template, v_limbs, q_buf, r_buf);
			std.mem.doNotOptimizeAway(&out);
		}
	}
	const t_total = monoNanos() - t_start;
	const ns_per_op = @as(f64, @floatFromInt(t_total)) / @as(f64, @floatFromInt(iters));
	std.debug.print(
		"\n[bench] divModKnuthU64 2048-bit / 1024-bit: {d:.0} ns/op\n",
		.{ns_per_op},
	);
}

test "bench: divModKnuthU64 at 4096-bit / 2048-bit" {
	const allocator = std.testing.allocator;
	const u_limbs: usize = 64; // 4096 bits
	const v_limbs: usize = 32; // 2048 bits
	const iters: usize = 500;

	const u_template = try allocator.alloc(u64, u_limbs);
	defer allocator.free(u_template);
	const v_template = try allocator.alloc(u64, v_limbs);
	defer allocator.free(v_template);
	var rng = std.Random.DefaultPrng.init(0x4040_4040);
	const rnd = rng.random();
	for (u_template) |*p| p.* = rnd.int(u64);
	for (v_template) |*p| p.* = rnd.int(u64);
	if (v_template[v_limbs - 1] == 0) v_template[v_limbs - 1] = 0xAAAA_AAAA_AAAA_AAAA;
	if (u_template[u_limbs - 1] == 0) u_template[u_limbs - 1] = 0xCCCC_CCCC_CCCC_CCCC;

	const u_buf = try allocator.alloc(u64, u_limbs + 1);
	defer allocator.free(u_buf);
	const q_buf = try allocator.alloc(u64, u_limbs);
	defer allocator.free(q_buf);
	const r_buf = try allocator.alloc(u64, v_limbs);
	defer allocator.free(r_buf);

	@memcpy(u_buf[0..u_limbs], u_template);
	u_buf[u_limbs] = 0;
	_ = divModKnuthU64(u_buf, u_limbs, v_template, v_limbs, q_buf, r_buf);

	const t_start = monoNanos();
	var i: usize = 0;
	while (i < iters) : (i += 1) {
		@memcpy(u_buf[0..u_limbs], u_template);
		u_buf[u_limbs] = 0;
		const out = divModKnuthU64(u_buf, u_limbs, v_template, v_limbs, q_buf, r_buf);
		std.mem.doNotOptimizeAway(&out);
	}
	const t_total = monoNanos() - t_start;
	const ns_per_op = @as(f64, @floatFromInt(t_total)) / @as(f64, @floatFromInt(iters));
	std.debug.print("\n[bench] divModKnuthU64 4096-bit / 2048-bit: {d:.0} ns/op\n", .{ns_per_op});
}

test "bench: divModKnuthU64 at 8192-bit / 4096-bit" {
	const allocator = std.testing.allocator;
	const u_limbs: usize = 128; // 8192 bits
	const v_limbs: usize = 64; // 4096 bits
	const iters: usize = 200;

	const u_template = try allocator.alloc(u64, u_limbs);
	defer allocator.free(u_template);
	const v_template = try allocator.alloc(u64, v_limbs);
	defer allocator.free(v_template);
	var rng = std.Random.DefaultPrng.init(0x8080_8080);
	const rnd = rng.random();
	for (u_template) |*p| p.* = rnd.int(u64);
	for (v_template) |*p| p.* = rnd.int(u64);
	if (v_template[v_limbs - 1] == 0) v_template[v_limbs - 1] = 0xAAAA_AAAA_AAAA_AAAA;
	if (u_template[u_limbs - 1] == 0) u_template[u_limbs - 1] = 0xCCCC_CCCC_CCCC_CCCC;

	const u_buf = try allocator.alloc(u64, u_limbs + 1);
	defer allocator.free(u_buf);
	const q_buf = try allocator.alloc(u64, u_limbs);
	defer allocator.free(q_buf);
	const r_buf = try allocator.alloc(u64, v_limbs);
	defer allocator.free(r_buf);

	@memcpy(u_buf[0..u_limbs], u_template);
	u_buf[u_limbs] = 0;
	_ = divModKnuthU64(u_buf, u_limbs, v_template, v_limbs, q_buf, r_buf);

	const t_start = monoNanos();
	var i: usize = 0;
	while (i < iters) : (i += 1) {
		@memcpy(u_buf[0..u_limbs], u_template);
		u_buf[u_limbs] = 0;
		const out = divModKnuthU64(u_buf, u_limbs, v_template, v_limbs, q_buf, r_buf);
		std.mem.doNotOptimizeAway(&out);
	}
	const t_total = monoNanos() - t_start;
	const ns_per_op = @as(f64, @floatFromInt(t_total)) / @as(f64, @floatFromInt(iters));
	std.debug.print("\n[bench] divModKnuthU64 8192-bit / 4096-bit: {d:.0} ns/op\n", .{ns_per_op});
}

test "bench: divModSingleByte vs divModSingleU64 at 2048-bit" {
	const allocator = std.testing.allocator;
	const sz: usize = 256; // 2048 bits
	const iters: usize = 10_000;
	const divisor_byte: u8 = 0x65; // arbitrary
	const divisor_u64: u64 = 65537;

	const a_template = try allocator.alloc(u8, sz);
	defer allocator.free(a_template);
	var rng = std.Random.DefaultPrng.init(0xABCD_1234);
	const rnd = rng.random();
	for (a_template) |*p| p.* = rnd.int(u8);

	const work = try allocator.alloc(u8, sz);
	defer allocator.free(work);

	// Warm-up + byte form.
	{
		@memcpy(work, a_template);
		_ = divModSingleByte(work, sz, divisor_byte);
		@memcpy(work, a_template);
		_ = divModSingleU64(work, sz, divisor_u64);
	}

	const t_byte_start = monoNanos();
	{
		var i: usize = 0;
		while (i < iters) : (i += 1) {
			@memcpy(work, a_template);
			const r = divModSingleByte(work, sz, divisor_byte);
			std.mem.doNotOptimizeAway(&r);
		}
	}
	const t_byte_total = monoNanos() - t_byte_start;

	const t_u64_start = monoNanos();
	{
		var i: usize = 0;
		while (i < iters) : (i += 1) {
			@memcpy(work, a_template);
			const r = divModSingleU64(work, sz, divisor_u64);
			std.mem.doNotOptimizeAway(&r);
		}
	}
	const t_u64_total = monoNanos() - t_u64_start;

	const ns_per_byte = @as(f64, @floatFromInt(t_byte_total)) / @as(f64, @floatFromInt(iters));
	const ns_per_u64 = @as(f64, @floatFromInt(t_u64_total)) / @as(f64, @floatFromInt(iters));
	const ratio = ns_per_byte / ns_per_u64;
	std.debug.print(
		"\n[bench] divModSingleByte (256B / u8): {d:.0} ns/op\n[bench] divModSingleU64  (256B / u64): {d:.0} ns/op\n[bench] speedup ratio: {d:.2}x\n",
		.{ ns_per_byte, ns_per_u64, ratio },
	);
}

// ── Montgomery primitive tests (M7-4.3) ──────────────────────────────────────

test "modInvNeg64: m * modInvNeg64(m) +% 1 == 0 mod 2^64 for many odd m" {
	const cases = [_]u64{
		1, 3, 5, 7, 9, 11, 13, 15, 17,
		0x123, 0xDEAD_BEEF, 0xFFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFD,
		0x9E37_79B9_7F4A_7C15, // golden-ratio-derived odd
		0x123_4567_89AB_CDEF, // arbitrary
	};
	for (cases) |m| {
		const inv = modInvNeg64(m);
		// inv == -m^-1 mod 2^64, so m * inv == -1 mod 2^64, so m*inv +% 1 == 0.
		try testing.expectEqual(@as(u64, 0), m *% inv +% 1);
	}
}

test "modInvNeg64: random odd values" {
	var rng = std.Random.DefaultPrng.init(0xDEAD_BEEF_CAFE_BABE);
	const r = rng.random();
	var i: usize = 0;
	while (i < 256) : (i += 1) {
		var m = r.int(u64) | 1; // ensure odd
		if (m == 0) m = 1;
		const inv = modInvNeg64(m);
		try testing.expectEqual(@as(u64, 0), m *% inv +% 1);
	}
}

test "bytesToLimbs / limbsToBytes round-trip" {
	const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A };
	var limbs: [2]u64 = undefined;
	bytesToLimbs(&bytes, &limbs);
	try testing.expectEqual(@as(u64, 0x0807_0605_0403_0201), limbs[0]);
	try testing.expectEqual(@as(u64, 0x0000_0000_0000_0A09), limbs[1]);

	var roundtrip: [10]u8 = undefined;
	limbsToBytes(&limbs, &roundtrip);
	try testing.expectEqualSlices(u8, &bytes, &roundtrip);
}

test "montMul: tiny case (m=17) — verify (a*b mod m) == from_mont(montMul(to_mont(a), to_mont(b)))" {
	// k=1 limb, m=17. R = 2^64. R mod 17 = 16 (since 2^64 mod 17 = 1's-complement... compute).
	const m_val: u64 = 17;
	const m: [1]u64 = .{m_val};
	const m_inv_neg = modInvNeg64(m_val);

	// Compute R^2 mod m by hand: R = 2^64, R mod 17 = ?
	// 2^4 = 16 = -1 mod 17, so 2^8 = 1, so 2^64 = 1 mod 17. Hence R mod 17 = 1.
	// R^2 mod 17 = 1.
	const r2: [1]u64 = .{1};

	var scratch: [4]u64 = undefined;

	// to_mont(a) = montMul(a, R^2)
	const a_val: u64 = 5;
	const b_val: u64 = 7;
	var a_mont: [1]u64 = undefined;
	var b_mont: [1]u64 = undefined;
	const a_arr: [1]u64 = .{a_val};
	const b_arr: [1]u64 = .{b_val};
	montMul(&a_arr, &r2, &m, m_inv_neg, &a_mont, &scratch);
	montMul(&b_arr, &r2, &m, m_inv_neg, &b_mont, &scratch);

	// c_mont = montMul(a_mont, b_mont) — should be (a*b) in Mont form
	var c_mont: [1]u64 = undefined;
	montMul(&a_mont, &b_mont, &m, m_inv_neg, &c_mont, &scratch);

	// from_mont(c_mont) = montMul(c_mont, 1)
	const one: [1]u64 = .{1};
	var c: [1]u64 = undefined;
	montMul(&c_mont, &one, &m, m_inv_neg, &c, &scratch);

	const expected = (a_val * b_val) % m_val;
	try testing.expectEqual(expected, c[0]);
}

test "montMul: random small odd modulus equivalence to (a*b) mod m" {
	var rng = std.Random.DefaultPrng.init(0xCAFE_F00D_DEAD_BEEF);
	const r = rng.random();

	var scratch: [16]u64 = undefined;
	var i: usize = 0;
	while (i < 64) : (i += 1) {
		var m_val: u64 = r.int(u64) | 1; // odd
		if (m_val < 3) m_val = 3;
		const a_val = r.int(u64) % m_val;
		const b_val = r.int(u64) % m_val;
		const m: [1]u64 = .{m_val};
		const m_inv_neg = modInvNeg64(m_val);

		// R^2 mod m. R = 2^64. Compute (R mod m), then square mod m via u128.
		// R mod m = (2^64) mod m_val. Trick: R-1 is u64.max, so R mod m =
		// ((u64.max % m_val) + 1) % m_val.
		const r_mod: u64 = blk: {
			const partial = std.math.maxInt(u64) % m_val;
			break :blk (partial + 1) % m_val;
		};
		const r2_val: u64 = @truncate((@as(u128, r_mod) * @as(u128, r_mod)) % @as(u128, m_val));
		const r2: [1]u64 = .{r2_val};

		const a_arr: [1]u64 = .{a_val};
		const b_arr: [1]u64 = .{b_val};
		var a_mont: [1]u64 = undefined;
		var b_mont: [1]u64 = undefined;
		montMul(&a_arr, &r2, &m, m_inv_neg, &a_mont, &scratch);
		montMul(&b_arr, &r2, &m, m_inv_neg, &b_mont, &scratch);

		var c_mont: [1]u64 = undefined;
		montMul(&a_mont, &b_mont, &m, m_inv_neg, &c_mont, &scratch);

		const one: [1]u64 = .{1};
		var c: [1]u64 = undefined;
		montMul(&c_mont, &one, &m, m_inv_neg, &c, &scratch);

		const expected: u64 = @truncate((@as(u128, a_val) * @as(u128, b_val)) % @as(u128, m_val));
		try testing.expectEqual(expected, c[0]);
	}
}

test "montMul: 2-limb random equivalence to schoolbook+mod" {
	// k=2 limbs (128-bit modulus). Use u256 oracle in scratch.
	var rng = std.Random.DefaultPrng.init(0x1234_5678_9ABC_DEF0);
	const r = rng.random();

	var iter: usize = 0;
	while (iter < 32) : (iter += 1) {
		// Build a random odd 128-bit modulus.
		const m0 = r.int(u64) | 1;
		const m1 = r.int(u64) | 0x8000_0000_0000_0000; // ensure top bit set so it's truly k=2
		const m: [2]u64 = .{ m0, m1 };

		// Random a, b in [0, m).
		const a_lo = r.int(u64);
		const a_hi = r.int(u64) % m1;
		const a: [2]u64 = .{ a_lo, a_hi };
		const b_lo = r.int(u64);
		const b_hi = r.int(u64) % m1;
		const b: [2]u64 = .{ b_lo, b_hi };

		const m_inv_neg = modInvNeg64(m0);

		// Compute R^2 mod m using u512 arithmetic (R = 2^128, R^2 = 2^256 fits u512).
		const m_u512: u512 = @as(u512, m0) | (@as(u512, m1) << 64);
		const a_u512: u512 = @as(u512, a_lo) | (@as(u512, a_hi) << 64);
		const b_u512: u512 = @as(u512, b_lo) | (@as(u512, b_hi) << 64);
		const R: u512 = @as(u512, 1) << 128;
		const r2_u512 = (R * R) % m_u512;
		const r2: [2]u64 = .{
			@truncate(r2_u512 & std.math.maxInt(u64)),
			@truncate((r2_u512 >> 64) & std.math.maxInt(u64)),
		};

		var scratch: [16]u64 = undefined;
		var a_mont: [2]u64 = undefined;
		var b_mont: [2]u64 = undefined;
		montMul(&a, &r2, &m, m_inv_neg, &a_mont, &scratch);
		montMul(&b, &r2, &m, m_inv_neg, &b_mont, &scratch);

		var c_mont: [2]u64 = undefined;
		montMul(&a_mont, &b_mont, &m, m_inv_neg, &c_mont, &scratch);

		const one: [2]u64 = .{ 1, 0 };
		var c: [2]u64 = undefined;
		montMul(&c_mont, &one, &m, m_inv_neg, &c, &scratch);

		const expected_u512 = (a_u512 * b_u512) % m_u512;
		const got_u512 = @as(u512, c[0]) | (@as(u512, c[1]) << 64);
		try testing.expectEqual(expected_u512, got_u512);
	}
}

test "montMul: 8-limb (512-bit) random equivalence to schoolbook + Knuth div" {
	// k=8 limbs (512-bit modulus). Sanity-check at the size powm cares about.
	var rng = std.Random.DefaultPrng.init(0xABCD_EF01_2345_6789);
	const r = rng.random();
	var allocator = std.testing.allocator;

	const k: usize = 8;
	var iter: usize = 0;
	while (iter < 8) : (iter += 1) {
		var m: [8]u64 = undefined;
		for (&m) |*x| x.* = r.int(u64);
		m[0] |= 1;                                    // odd
		m[k - 1] |= 0x8000_0000_0000_0000;           // top bit set (truly k=8)

		var a: [8]u64 = undefined;
		var b: [8]u64 = undefined;
		for (&a, &b) |*ax, *bx| {
			ax.* = r.int(u64);
			bx.* = r.int(u64);
		}
		// Reduce a, b mod m via subtraction if needed (cheap since high limb dominates).
		while (cmpLimbsGE(&a, &m)) subLimbsInPlace(&a, &m);
		while (cmpLimbsGE(&b, &m)) subLimbsInPlace(&b, &m);

		const m_inv_neg = modInvNeg64(m[0]);

		// R^2 mod m: R = 2^512. Compute via repeated squaring of (R mod m).
		// R mod m: since m fits in 512 bits with high bit set, R = 2^512 > m, so
		// R mod m = R - m. Wait — but R = 2^512 and m has high bit at position
		// 511, so m in [2^511, 2^512). Hence R mod m = R - m (single sub).
		// Limb-wise: R is "1" at limb index 8; subtract m gives a value in [0, m).
		var r_mod_m: [8]u64 = undefined;
		// Compute R - m: borrow chain from limb 0.
		var borrow: u64 = 0;
		var i: usize = 0;
		while (i < 8) : (i += 1) {
			const a_lim: u64 = 0; // R's low 8 limbs are all 0
			const b_lim: u64 = m[i];
			const d1 = @subWithOverflow(a_lim, b_lim);
			const d2 = @subWithOverflow(d1[0], borrow);
			r_mod_m[i] = d2[0];
			borrow = @as(u64, d1[1]) + @as(u64, d2[1]);
		}
		// borrow consumed by R's "1" at limb 8 — disregard.

		// Now r2 = (r_mod_m * r_mod_m) mod m via montMul trick:
		// montMul(r_mod_m, r_mod_m) = r_mod_m^2 * R^-1 mod m
		// = R^2 * R^-1 mod m = R mod m. Hmm, that gives R mod m.
		// We need R^2 mod m. Compute via:
		// montMul(R mod m, R mod m, m, ...) = R^2 * R^-1 = R mod m. Not what we want.
		// Use: R^2 mod m = (R mod m)^2 mod m, computed externally with a big buffer.
		// We'll do that via Mp.mul + Mp.mod once to seed. But this test is already
		// at the tier3 layer — to avoid pulling Mp here, allocate u128-style.
		// Easiest: do schoolbook (r_mod_m * r_mod_m) into 16-limb scratch, then
		// reduce via repeated subtraction (slow but correct for testing).
		const sq_buf = try allocator.alloc(u64, 16);
		defer allocator.free(sq_buf);
		@memset(sq_buf, 0);
		// schoolbook square
		for (0..8) |ii| {
			var carry: u64 = 0;
			for (0..8) |jj| {
				const prod: u128 = @as(u128, r_mod_m[ii]) * @as(u128, r_mod_m[jj]) + @as(u128, sq_buf[ii + jj]) + @as(u128, carry);
				sq_buf[ii + jj] = @truncate(prod);
				carry = @intCast(prod >> 64);
			}
			var pos = ii + 8;
			while (carry != 0 and pos < 16) {
				const s: u128 = @as(u128, sq_buf[pos]) + @as(u128, carry);
				sq_buf[pos] = @truncate(s);
				carry = @intCast(s >> 64);
				pos += 1;
			}
		}
		// Reduce sq_buf mod m. We use montReduceCios trick:
		//   montReduce(sq_buf) = sq_buf * R^-1 mod m = (R mod m)^2 * R^-1 = R mod m.
		// Still not R^2 mod m. So instead: use direct repeated subtraction.
		// But sq_buf has up to 16 limbs and m has 8 — too many subtractions.
		// Use a different approach: compute R^2 mod m from scratch using
		// the "shift and reduce" pattern. R^2 = 2^1024.
		// Start with x = 1; for i in 0..1024: x = (2*x) mod m.
		var x: [8]u64 = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
		var bit: usize = 0;
		while (bit < 1024) : (bit += 1) {
			// x = (x << 1) mod m. Track top-bit carry.
			var c: u64 = 0;
			var jj: usize = 0;
			while (jj < 8) : (jj += 1) {
				const new_top = x[jj] >> 63;
				x[jj] = (x[jj] << 1) | c;
				c = new_top;
			}
			// If c set OR x >= m, subtract m.
			if (c != 0 or cmpLimbsGE(&x, &m)) {
				subLimbsInPlace(&x, &m);
			}
		}
		const r2 = x; // R^2 mod m

		var scratch: [32]u64 = undefined;
		var a_mont: [8]u64 = undefined;
		var b_mont: [8]u64 = undefined;
		montMul(&a, &r2, &m, m_inv_neg, &a_mont, &scratch);
		montMul(&b, &r2, &m, m_inv_neg, &b_mont, &scratch);

		var c_mont: [8]u64 = undefined;
		montMul(&a_mont, &b_mont, &m, m_inv_neg, &c_mont, &scratch);

		const one: [8]u64 = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
		var c: [8]u64 = undefined;
		montMul(&c_mont, &one, &m, m_inv_neg, &c, &scratch);

		// Reference: schoolbook a*b → 16 limbs, then reduce by repeated subtract
		// of (m << shift). Use the same shift-and-reduce loop as for R^2.
		const ref_buf = try allocator.alloc(u64, 16);
		defer allocator.free(ref_buf);
		@memset(ref_buf, 0);
		for (0..8) |ii| {
			var carry: u64 = 0;
			for (0..8) |jj| {
				const prod: u128 = @as(u128, a[ii]) * @as(u128, b[jj]) + @as(u128, ref_buf[ii + jj]) + @as(u128, carry);
				ref_buf[ii + jj] = @truncate(prod);
				carry = @intCast(prod >> 64);
			}
			var pos = ii + 8;
			while (carry != 0 and pos < 16) {
				const s: u128 = @as(u128, ref_buf[pos]) + @as(u128, carry);
				ref_buf[pos] = @truncate(s);
				carry = @intCast(s >> 64);
				pos += 1;
			}
		}
		// Now reduce ref_buf mod m using a 16-limb shift-down algorithm:
		// repeatedly subtract m shifted left by (limbs_high - 8 - 1) limbs * 64.
		// Easier: rebuild via "shift-1024-times" trick on a fresh accumulator.
		var acc: [8]u64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
		var b_idx: isize = 16 * 64 - 1;
		while (b_idx >= 0) : (b_idx -= 1) {
			// acc = (acc << 1) mod m
			var cc: u64 = 0;
			var jj: usize = 0;
			while (jj < 8) : (jj += 1) {
				const new_top = acc[jj] >> 63;
				acc[jj] = (acc[jj] << 1) | cc;
				cc = new_top;
			}
			// Add bit b_idx of ref_buf
			const bb_idx: usize = @intCast(b_idx);
			const limb_idx = bb_idx / 64;
			const bit_in_limb: u6 = @intCast(bb_idx % 64);
			const bit_val: u64 = (ref_buf[limb_idx] >> bit_in_limb) & 1;
			acc[0] |= bit_val;
			// Reduce
			if (cc != 0 or cmpLimbsGE(&acc, &m)) {
				subLimbsInPlace(&acc, &m);
			}
		}
		try testing.expectEqualSlices(u64, &acc, &c);
	}
}
