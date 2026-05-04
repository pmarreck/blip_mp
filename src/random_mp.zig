// Uniform-random bignum sampling (M12-A5).
//
// Mirrors GMP `mpz_urandomb(rop, state, n)` (uniform in [0, 2^n)) and
// `mpz_urandomm(rop, state, n)` (uniform in [0, n)). Caller supplies the
// `std.Random` source so determinism (or lack of it) is the caller's choice.
// We use rejection sampling for `setRandomBelow`: draw `n.bitLen()` random bits
// and retry if the result is ≥ n. Worst-case 2 draws on average; fine.

const std = @import("std");
const bignum = @import("bignum.zig");
const tier3 = @import("tier3.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

/// Helper: install a magnitude-bytes-LE buffer as a non-negative Mp value.
/// `mag` is interpreted as little-endian unsigned. If `mag` happens to have
/// its high bit set, we prepend a 0x00 byte so the BLIP payload reads as
/// non-negative. Trailing zero bytes are trimmed (canonicalisation).
fn installNonNegMagnitude(out: *Mp, mag: []const u8) ArithError!void {
	// Trim trailing zeros (canonicalisation).
	var n = mag.len;
	while (n > 0 and mag[n - 1] == 0) n -= 1;
	if (n == 0) {
		// Zero.
		var buf = [_]u8{0x00};
		try out.setBytes(buf[0..1]);
		return;
	}
	// If high byte's high bit is set, the canonical positive payload needs
	// an extra trailing 0x00 byte.
	const needs_extra = (mag[n - 1] & 0x80) != 0;
	const pay_len = if (needs_extra) n + 1 else n;
	// Immediate form for tiny non-negatives: single byte 0..127.
	if (pay_len == 1 and mag[0] < 0x80) {
		var buf = [_]u8{mag[0]};
		try out.setBytes(buf[0..1]);
		return;
	}
	// Length-prefixed form. Header is at most ~5 bytes for absurdly long L.
	var hdr_buf: [10]u8 = undefined;
	const hdr_len = tier3.writeHeader(&hdr_buf, pay_len) catch return error.OutOfMemory;
	const need = hdr_len + pay_len;
	const scratch = out.allocator.alloc(u8, need) catch return error.OutOfMemory;
	defer out.allocator.free(scratch);
	@memcpy(scratch[0..hdr_len], hdr_buf[0..hdr_len]);
	@memcpy(scratch[hdr_len .. hdr_len + n], mag[0..n]);
	if (needs_extra) scratch[hdr_len + n] = 0x00;
	try out.setBytes(scratch);
}

/// Sample a uniform random integer in `[0, 2^bits)` into `self`. Bit count
/// `bits == 0` deterministically yields 0.
pub fn setRandomBits(self: *Mp, rng: std.Random, bits: usize) ArithError!void {
	if (bits == 0) {
		try self.setI64(0);
		return;
	}
	const byte_count = (bits + 7) / 8;
	const high_bits_in_top_byte: u3 = @intCast(bits % 8);
	const top_byte_mask: u8 = if (high_bits_in_top_byte == 0)
		0xFF
	else
		(@as(u8, 1) << high_bits_in_top_byte) - 1;

	const mag = self.allocator.alloc(u8, byte_count) catch return error.OutOfMemory;
	defer self.allocator.free(mag);
	rng.bytes(mag);
	mag[byte_count - 1] &= top_byte_mask;

	try installNonNegMagnitude(self, mag);
}

/// Sample a uniform random integer in `[0, n)` into `self`. Requires n > 0.
/// Strategy: rejection sampling — draw `n.bitLen()` random bits; retry if the
/// draw is ≥ n. Expected number of draws ≤ 2 because the bit-length window
/// always covers at least half of [0, n).
pub fn setRandomBelow(self: *Mp, rng: std.Random, n: *const Mp) ArithError!void {
	if (n.cachedSign() <= 0) return error.DivisionByZero; // misuse — n must be positive
	const bits = n.bitLen();
	// bits == 0 only when n == 0, already handled above.
	// Loop with a max retry guard to surface infinite loops in theory (won't happen).
	var attempts: usize = 0;
	while (attempts < 1024) : (attempts += 1) {
		try setRandomBits(self, rng, bits);
		if (self.cmp(n) == .lt) return;
	}
	// Should never reach here for valid inputs.
	return error.OutputBufferTooSmall;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "random: setRandomBits(0) deterministically yields 0" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(42);
	var x = Mp.init(a);
	defer x.deinit();
	try setRandomBits(&x, prng.random(), 0);
	try testing.expectEqual(@as(i8, 0), x.cachedSign());
}

test "random: setRandomBits respects bit budget (bitLen ≤ bits)" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(42);
	const bit_widths = [_]usize{ 1, 7, 8, 9, 16, 17, 32, 63, 64, 65, 128, 256, 1024 };
	for (bit_widths) |w| {
		for (0..20) |_| {
			var x = Mp.init(a);
			defer x.deinit();
			try setRandomBits(&x, prng.random(), w);
			try testing.expect(x.cachedSign() >= 0);
			try testing.expect(x.bitLen() <= w);
		}
	}
}

test "random: setRandomBits(64) — distribution sanity (not all zero, not all max)" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(0xCAFEBABE);
	var any_nonzero = false;
	var any_high_bit = false;
	for (0..100) |_| {
		var x = Mp.init(a);
		defer x.deinit();
		try setRandomBits(&x, prng.random(), 64);
		if (x.cachedSign() != 0) any_nonzero = true;
		if (x.bitLen() == 64) any_high_bit = true;
	}
	try testing.expect(any_nonzero);
	try testing.expect(any_high_bit);
}

test "random: setRandomBits(1) only yields 0 or 1" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(7);
	var saw_zero = false;
	var saw_one = false;
	for (0..200) |_| {
		var x = Mp.init(a);
		defer x.deinit();
		try setRandomBits(&x, prng.random(), 1);
		const v = try x.getI64();
		try testing.expect(v == 0 or v == 1);
		if (v == 0) saw_zero = true;
		if (v == 1) saw_one = true;
	}
	try testing.expect(saw_zero);
	try testing.expect(saw_one);
}

test "random: setRandomBelow always returns a value < n" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(0xABCD1234);
	const ns = [_]i64{ 1, 2, 7, 100, 12345, 0x12345678, std.math.maxInt(i32) };
	for (ns) |nv| {
		var n_mp = Mp.init(a);
		defer n_mp.deinit();
		try n_mp.setI64(nv);
		for (0..50) |_| {
			var x = Mp.init(a);
			defer x.deinit();
			try setRandomBelow(&x, prng.random(), &n_mp);
			try testing.expect(x.cachedSign() >= 0);
			try testing.expect(x.cmp(&n_mp) == .lt);
		}
	}
}

test "random: setRandomBelow(1) always returns 0" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(13);
	var n = Mp.init(a);
	defer n.deinit();
	try n.setI64(1);
	for (0..30) |_| {
		var x = Mp.init(a);
		defer x.deinit();
		try setRandomBelow(&x, prng.random(), &n);
		try testing.expectEqual(@as(i8, 0), x.cachedSign());
	}
}

test "random: setRandomBelow rejects n == 0" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(1);
	var n = Mp.init(a);
	defer n.deinit();
	try n.setI64(0);
	var x = Mp.init(a);
	defer x.deinit();
	try testing.expectError(error.DivisionByZero, setRandomBelow(&x, prng.random(), &n));
}

test "random: setRandomBits(256) — uniform-ish bit distribution across 1000 draws" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(0xDEADC0DE);
	// Each bit position should be set in ~50% of draws. Crude check: count
	// the set bits across all draws and confirm it's between 40% and 60%.
	const draws = 200;
	const bits = 256;
	var total_set: usize = 0;
	for (0..draws) |_| {
		var x = Mp.init(a);
		defer x.deinit();
		try setRandomBits(&x, prng.random(), bits);
		// popcount via straight payload byte traversal.
		const pay = x.payload();
		for (pay) |b| total_set += @popCount(b);
	}
	const expected = (draws * bits) / 2;
	const lo = expected * 4 / 5;
	const hi = expected * 6 / 5;
	try testing.expect(total_set >= lo and total_set <= hi);
}
