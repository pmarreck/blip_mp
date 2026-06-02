// Bit scan / population count over Mp values (M12-A6).
//
// Operates on the BLIP payload as a two's-complement bit vector with implicit
// infinite sign extension (0x00 byte for non-negatives, 0xFF byte for negatives).
// Matches GMP semantics:
//   - mpz_popcount: count of 1-bits. For negatives the count is conceptually
//     infinite, returned as `std.math.maxInt(usize)`.
//   - mpz_scan0(start): position of the first 0-bit at or after `start`. For
//     non-negatives, infinite high-bit run of 0s ensures success. For negatives,
//     if no 0-bit exists in the payload at/after `start` then the high run of
//     1s extends forever → returns maxInt(usize).
//   - mpz_scan1(start): position of the first 1-bit at or after `start`.
//     Symmetric: succeeds for negatives, may return maxInt for non-negatives.

const std = @import("std");
const bignum = @import("bignum.zig");
const tier3 = @import("tier3.zig");

const Mp = bignum.Mp;

const NOT_FOUND: usize = std.math.maxInt(usize);

/// Hamming weight of the two's-complement bit pattern. For non-negative values
/// counts 1-bits in the payload (sign-extension bytes are 0 → contribute 0).
/// For negative values the conceptual answer is "infinite 1-bits" — return
/// `std.math.maxInt(usize)` per GMP `mpz_popcount`.
pub fn popcount(self: *const Mp) usize {
	if (self.cachedSign() < 0) return NOT_FOUND;
	const pay = self.payload();
	if (pay.len == 0) return 0;
	var total: usize = 0;
	// Chunked u64 over the payload — cheap on aarch64 (single CNT instr per
	// 8-byte block via @popCount lowering).
	var i: usize = 0;
	while (i + 8 <= pay.len) : (i += 8) {
		const v = std.mem.readInt(u64, pay[i..][0..8], .little);
		total += @popCount(v);
	}
	while (i < pay.len) : (i += 1) {
		total += @popCount(pay[i]);
	}
	return total;
}

/// First 0-bit position at or after `start`. Returns `maxInt(usize)` if no
/// 0-bit exists at or after `start` (only possible for negative values).
pub fn scan0(self: *const Mp, start: usize) usize {
	return scanCommon(self, start, 0);
}

/// First 1-bit position at or after `start`. Returns `maxInt(usize)` if no
/// 1-bit exists at or after `start` (only possible for non-negative values).
pub fn scan1(self: *const Mp, start: usize) usize {
	return scanCommon(self, start, 1);
}

/// Shared scan core. `target` is 0 (for scan0) or 1 (for scan1). Strategy:
/// XOR each byte with `xor_mask` so the search becomes "first 1-bit"; walk
/// payload bytes from `start`'s containing byte upward; in each non-zero
/// byte use `@ctz` to find the bit position. Past the payload, the
/// sign-extension byte ^ xor_mask either matches (immediate success at the
/// max of `start` / payload_end_bit) or never matches (NOT_FOUND).
fn scanCommon(self: *const Mp, start: usize, target: u1) usize {
	const pay = self.payload();
	const sext = tier3.signExtByte(pay);
	const xor_mask: u8 = if (target == 0) 0xFF else 0x00;

	var bit_pos = start;
	const start_byte = start / 8;
	const start_bit_in_byte: u3 = @intCast(start & 7);

	var byte_idx = start_byte;
	if (byte_idx < pay.len) {
		// First byte: mask off bits below start_bit_in_byte.
		const first_byte = pay[byte_idx] ^ xor_mask;
		const first_masked = first_byte & (@as(u8, 0xFF) << start_bit_in_byte);
		if (first_masked != 0) {
			return byte_idx * 8 + @ctz(first_masked);
		}
		byte_idx += 1;
		while (byte_idx < pay.len) : (byte_idx += 1) {
			const b = pay[byte_idx] ^ xor_mask;
			if (b != 0) {
				return byte_idx * 8 + @ctz(b);
			}
		}
		bit_pos = pay.len * 8;
	}

	// Past the payload: the sign-extension byte determines existence.
	const sign_xor = sext ^ xor_mask;
	if (sign_xor != 0) {
		// Every bit at or past `payload.len * 8` IS the sign-ext bit, which
		// matches the target. Return whichever is later (start or payload end).
		return if (bit_pos < start) start else bit_pos;
	}
	return NOT_FOUND;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "scan: popcount on small positives matches @popCount" {
	const a = std.testing.allocator;
	const cases = [_]i64{ 0, 1, 2, 3, 7, 0xFF, 0xFFFF, 0xDEADBEEF, std.math.maxInt(i32), std.math.maxInt(i64) };
	for (cases) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		const expected: usize = @popCount(@as(u64, @intCast(v)));
		try testing.expectEqual(expected, popcount(&x));
	}
}

test "scan: popcount on negatives returns maxInt(usize) (GMP semantics)" {
	const a = std.testing.allocator;
	const cases = [_]i64{ -1, -2, -100, std.math.minInt(i32), std.math.minInt(i64) };
	for (cases) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		try testing.expectEqual(NOT_FOUND, popcount(&x));
	}
}

test "scan: popcount on tier-3 positive (multi-byte)" {
	const a = std.testing.allocator;
	// payload = [0xFF×8, 0x00] = 2^64 - 1.
	var x = Mp.init(a);
	defer x.deinit();
	const blip = [_]u8{ 0x89, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
	try x.setBytes(&blip);
	try testing.expectEqual(@as(usize, 64), popcount(&x));
}

test "scan: scan1 on small positives matches @ctz" {
	const a = std.testing.allocator;
	const cases = [_]i64{ 1, 2, 4, 8, 0x10, 0xFF, 0x100 };
	for (cases) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		const expected: usize = @ctz(@as(u64, @intCast(v)));
		try testing.expectEqual(expected, scan1(&x, 0));
	}
}

test "scan: scan1 on zero returns NOT_FOUND" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, 0);
	defer x.deinit();
	try testing.expectEqual(NOT_FOUND, scan1(&x, 0));
	try testing.expectEqual(NOT_FOUND, scan1(&x, 100));
}

test "scan: scan1 with start advancing past low set bit" {
	const a = std.testing.allocator;
	// 0b1010101 — set bits at 0, 2, 4, 6.
	var x = try Mp.fromI64(a, 0b1010101);
	defer x.deinit();
	try testing.expectEqual(@as(usize, 0), scan1(&x, 0));
	try testing.expectEqual(@as(usize, 2), scan1(&x, 1));
	try testing.expectEqual(@as(usize, 2), scan1(&x, 2));
	try testing.expectEqual(@as(usize, 4), scan1(&x, 3));
	try testing.expectEqual(@as(usize, 6), scan1(&x, 5));
	try testing.expectEqual(NOT_FOUND, scan1(&x, 7));
	try testing.expectEqual(NOT_FOUND, scan1(&x, 100));
}

test "scan: scan0 on positives finds infinite high-bit-zero run" {
	const a = std.testing.allocator;
	// 5 = 0b101 — bits 0 and 2 are 1, bit 1 is 0; bits 3+ are 0 (sign-ext).
	var x = try Mp.fromI64(a, 5);
	defer x.deinit();
	try testing.expectEqual(@as(usize, 1), scan0(&x, 0));
	try testing.expectEqual(@as(usize, 1), scan0(&x, 1));
	try testing.expectEqual(@as(usize, 3), scan0(&x, 2));
	try testing.expectEqual(@as(usize, 3), scan0(&x, 3));
	try testing.expectEqual(@as(usize, 100), scan0(&x, 100));
}

test "scan: scan0 on negatives finds first explicit 0-bit" {
	const a = std.testing.allocator;
	// -1 = all 1s in two's complement → no 0-bit anywhere.
	{
		var x = try Mp.fromI64(a, -1);
		defer x.deinit();
		try testing.expectEqual(NOT_FOUND, scan0(&x, 0));
		try testing.expectEqual(NOT_FOUND, scan0(&x, 100));
	}
	// -2 = ...111110 → bit 0 = 0, bits 1+ all 1.
	{
		var x = try Mp.fromI64(a, -2);
		defer x.deinit();
		try testing.expectEqual(@as(usize, 0), scan0(&x, 0));
		try testing.expectEqual(NOT_FOUND, scan0(&x, 1));
	}
	// -4 = ...111100 → bits 0, 1 = 0; bits 2+ all 1.
	{
		var x = try Mp.fromI64(a, -4);
		defer x.deinit();
		try testing.expectEqual(@as(usize, 0), scan0(&x, 0));
		try testing.expectEqual(@as(usize, 1), scan0(&x, 1));
		try testing.expectEqual(NOT_FOUND, scan0(&x, 2));
	}
}

test "scan: scan1 on negatives finds infinite high-bit-one run" {
	const a = std.testing.allocator;
	// -2 = ...11110 → bit 0=0, bits 1+ = 1.
	var x = try Mp.fromI64(a, -2);
	defer x.deinit();
	try testing.expectEqual(@as(usize, 1), scan1(&x, 0));
	try testing.expectEqual(@as(usize, 1), scan1(&x, 1));
	try testing.expectEqual(@as(usize, 100), scan1(&x, 100));
}

test "scan: scan crosses byte boundaries" {
	const a = std.testing.allocator;
	// 1 << 28 — bit 28 is the sole set bit.
	var x = try Mp.fromI64(a, @as(i64, 1) << 28);
	defer x.deinit();
	try testing.expectEqual(@as(usize, 28), scan1(&x, 0));
	try testing.expectEqual(@as(usize, 28), scan1(&x, 28));
	try testing.expectEqual(NOT_FOUND, scan1(&x, 29));
	try testing.expectEqual(@as(usize, 0), scan0(&x, 0));
	try testing.expectEqual(@as(usize, 27), scan0(&x, 27));
	try testing.expectEqual(@as(usize, 29), scan0(&x, 29));
}

test "scan: popcount of 2^63 (tier-3 positive)" {
	const a = std.testing.allocator;
	var minInt = try Mp.fromI64(a, std.math.minInt(i64));
	defer minInt.deinit();
	// 0 - minInt = 2^63 (tier-3). One bit set.
	var x = Mp.init(a);
	defer x.deinit();
	var zero = try Mp.fromI64(a, 0);
	defer zero.deinit();
	try x.sub(&zero, &minInt);
	try testing.expectEqual(@as(usize, 1), popcount(&x));
	try testing.expectEqual(@as(usize, 63), scan1(&x, 0));
	try testing.expectEqual(NOT_FOUND, scan1(&x, 64));
}
