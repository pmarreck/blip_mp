// blip_mp_t — bignum value whose canonical storage is BLIP-encoded bytes
// interpreted as signed two's-complement (per SPEC.md §Sign convention).
//
// Representation 1b: { bytes: []u8, allocator }. `bytes` is the entire
// BLIP-encoded value (header + payload). Always heap-allocated for now;
// small-buffer-optimization is a later step once benchmarks justify it.
//
// For Milestone 1 the API is restricted to values that fit in i64
// (signed canonical L ≤ 8). u64 inputs > i64.max are rejected with
// `error.UnsignedTooLarge` — they require L=9 with a leading-zero
// sign byte, which is tier-2+ territory.

const std = @import("std");
const encoding = @import("encoding.zig");

pub const SetError = std.mem.Allocator.Error || encoding.Error || error{
	UnsignedTooLarge,
};

pub const GetError = encoding.Error || error{
	SentinelValue,
	ValueIsNegative, // getU64 on a negative value
};

/// Tier 0/1 arithmetic operates within i64 range. Overflow into tier 2+ is
/// out of scope until Milestone 3; for now we error out so callers learn.
pub const ArithError = SetError || GetError || error{
	TierOverflow, // result would not fit in i64; promotion to tier 3 required
};

pub const Mp = struct {
	bytes: []u8,
	allocator: std.mem.Allocator,

	pub fn init(allocator: std.mem.Allocator) Mp {
		return .{ .bytes = &[_]u8{}, .allocator = allocator };
	}

	pub fn deinit(self: *Mp) void {
		if (self.bytes.len != 0) {
			self.allocator.free(self.bytes);
			self.bytes = &[_]u8{};
		}
	}

	/// Replace this value with the canonical signed BLIP encoding of `value`.
	pub fn setI64(self: *Mp, value: i64) SetError!void {
		const need = encoding.encodedSizeI64(value);
		const buf = try self.allocator.alloc(u8, need);
		errdefer self.allocator.free(buf);
		const written = try encoding.encodeI64Canonical(buf, value);
		std.debug.assert(written == need);
		if (self.bytes.len != 0) self.allocator.free(self.bytes);
		self.bytes = buf;
	}

	/// Replace this value with the canonical signed BLIP encoding of `value`.
	/// For Milestone 1, only u64 values up to i64.max are accepted; values
	/// above that require L=9 (sign byte) and are out of scope for tier 0/1.
	pub fn setU64(self: *Mp, value: u64) SetError!void {
		if (value > std.math.maxInt(i64)) return error.UnsignedTooLarge;
		return self.setI64(@intCast(value));
	}

	/// Decode this value as i64. Errors on sentinels.
	pub fn getI64(self: *const Mp) GetError!i64 {
		const dec = try encoding.decodeI64(self.bytes);
		if (dec.is_sentinel) return error.SentinelValue;
		return dec.value;
	}

	/// Decode this value as u64. Errors on sentinels or negative values.
	pub fn getU64(self: *const Mp) GetError!u64 {
		const v = try self.getI64();
		if (v < 0) return error.ValueIsNegative;
		return @intCast(v);
	}

	/// Compare a vs b, returning std.math.Order. Tier 0/1: both decode to i64.
	/// Returns error if either side fails to decode (sentinels, overlong, etc).
	pub fn cmp(a: *const Mp, b: *const Mp) GetError!std.math.Order {
		const av = try a.getI64();
		const bv = try b.getI64();
		return std.math.order(av, bv);
	}

	pub fn sign(self: *const Mp) GetError!i2 {
		const v = try self.getI64();
		if (v > 0) return 1;
		if (v < 0) return -1;
		return 0;
	}

	/// r = a + b. Tier 0/1 fast path: decode both as i64, native add with
	/// overflow detection, re-encode canonically. Errors with TierOverflow
	/// if the sum can't fit in i64 (caller would need tier 3 — out of scope).
	pub fn add(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		const av = try a.getI64();
		const bv = try b.getI64();
		const ov = @addWithOverflow(av, bv);
		if (ov[1] != 0) return error.TierOverflow;
		try r.setI64(ov[0]);
	}

	/// r = a - b. Same tier 0/1 contract as add.
	pub fn sub(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		const av = try a.getI64();
		const bv = try b.getI64();
		const ov = @subWithOverflow(av, bv);
		if (ov[1] != 0) return error.TierOverflow;
		try r.setI64(ov[0]);
	}

	/// r = a * b. Widens to i128 to capture the full product, then narrows
	/// back to i64. Errors with TierOverflow if the product exceeds i64.
	pub fn mul(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		const av: i128 = @as(i128, try a.getI64());
		const bv: i128 = @as(i128, try b.getI64());
		const product: i128 = av * bv;
		if (product < std.math.minInt(i64) or product > std.math.maxInt(i64)) {
			return error.TierOverflow;
		}
		try r.setI64(@intCast(product));
	}
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Mp.setU64(5) stores [0x05] and getU64 returns 5" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(5);
	try testing.expectEqualSlices(u8, &[_]u8{0x05}, x.bytes);
	try testing.expectEqual(@as(u64, 5), try x.getU64());
}

test "Mp.setU64 round-trip for values up to i64.max" {
	const cases = [_]u64{ 0, 1, 127, 128, 255, 256, 65535, 65536, std.math.maxInt(u32), std.math.maxInt(u32) + 1, std.math.maxInt(i64) };
	for (cases) |v| {
		var x = Mp.init(testing.allocator);
		defer x.deinit();
		try x.setU64(v);
		try testing.expectEqual(v, try x.getU64());
	}
}

test "Mp.setU64 rejects values above i64.max (tier 0/1 limit)" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try testing.expectError(error.UnsignedTooLarge, x.setU64(std.math.maxInt(u64)));
	try testing.expectError(error.UnsignedTooLarge, x.setU64(@as(u64, std.math.maxInt(i64)) + 1));
}

test "Mp.setU64 reuse: second set replaces previous bytes without leak" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(5);
	try x.setU64(std.math.maxInt(i64));
	try testing.expectEqual(@as(u64, std.math.maxInt(i64)), try x.getU64());
	try testing.expectEqual(@as(usize, 9), x.bytes.len); // 1 header + 8 payload (signed canonical for i64.max)
}

test "Mp.setU64 produces single-byte form for immediate range" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(127);
	try testing.expectEqual(@as(usize, 1), x.bytes.len);
	try testing.expectEqual(@as(u8, 0x7F), x.bytes[0]);
}

test "Mp.setU64(128) produces signed-canonical [0x82, 0x80, 0x00] (NOT [0x81, 0x80])" {
	// This is the spec-tension test: pure BLIP would emit [0x81, 0x80] (2 bytes),
	// but that decodes to -128 under signed two's-complement, not +128.
	// Mp uses signed canonical, so +128 needs L=2 with a leading zero on the high end.
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(128);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x80, 0x00 }, x.bytes);
	try testing.expectEqual(@as(u64, 128), try x.getU64());
}

test "Mp.setI64 negative round-trip" {
	const cases = [_]i64{ -1, -127, -128, -129, -32768, -32769, std.math.minInt(i64) };
	for (cases) |v| {
		var x = Mp.init(testing.allocator);
		defer x.deinit();
		try x.setI64(v);
		try testing.expectEqual(v, try x.getI64());
	}
}

test "Mp.setI64(-1) bytes match spec example" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(-1);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xFF }, x.bytes);
}

test "Mp.getU64 errors on negative value" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setI64(-1);
	try testing.expectError(error.ValueIsNegative, x.getU64());
}

test "Mp.cmp across signs and magnitudes" {
	const Pair = struct { a: i64, b: i64, order: std.math.Order };
	const cases = [_]Pair{
		.{ .a = 0, .b = 0, .order = .eq },
		.{ .a = 5, .b = 5, .order = .eq },
		.{ .a = 5, .b = 6, .order = .lt },
		.{ .a = 6, .b = 5, .order = .gt },
		.{ .a = -1, .b = 0, .order = .lt },
		.{ .a = 0, .b = -1, .order = .gt },
		.{ .a = -1, .b = 1, .order = .lt },
		.{ .a = -128, .b = -129, .order = .gt },
		.{ .a = std.math.maxInt(i64), .b = std.math.minInt(i64), .order = .gt },
	};
	for (cases) |c| {
		var a = Mp.init(testing.allocator);
		defer a.deinit();
		var b = Mp.init(testing.allocator);
		defer b.deinit();
		try a.setI64(c.a);
		try b.setI64(c.b);
		try testing.expectEqual(c.order, try a.cmp(&b));
	}
}

test "Mp.sign returns -1/0/+1" {
	var z = Mp.init(testing.allocator);
	defer z.deinit();
	try z.setI64(0);
	try testing.expectEqual(@as(i2, 0), try z.sign());
	try z.setI64(42);
	try testing.expectEqual(@as(i2, 1), try z.sign());
	try z.setI64(-42);
	try testing.expectEqual(@as(i2, -1), try z.sign());
}

// ── Arithmetic tests ────────────────────────────────────────────────────────

fn doArith(
	comptime op: enum { add, sub, mul },
	a_v: i64,
	b_v: i64,
	expected: i64,
) !void {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(a_v);
	try b.setI64(b_v);
	switch (op) {
		.add => try r.add(&a, &b),
		.sub => try r.sub(&a, &b),
		.mul => try r.mul(&a, &b),
	}
	try testing.expectEqual(expected, try r.getI64());
}

fn expectArithOverflow(
	comptime op: enum { add, sub, mul },
	a_v: i64,
	b_v: i64,
) !void {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(a_v);
	try b.setI64(b_v);
	const got = switch (op) {
		.add => r.add(&a, &b),
		.sub => r.sub(&a, &b),
		.mul => r.mul(&a, &b),
	};
	try testing.expectError(error.TierOverflow, got);
}

test "add: tier 0 (immediate + immediate)" {
	try doArith(.add, 5, 7, 12);
	try doArith(.add, 0, 0, 0);
	try doArith(.add, 127, 0, 127);
}

test "add: tier 1 + sign mixing" {
	try doArith(.add, 100, 200, 300);
	try doArith(.add, 65535, 1, 65536);
	try doArith(.add, -1, 1, 0);
	try doArith(.add, -100, 50, -50);
	try doArith(.add, std.math.maxInt(i32), std.math.maxInt(i32), 2 * @as(i64, std.math.maxInt(i32)));
}

test "add: canonical-L shrink after sign-extension cancellation" {
	// -1 + 1 = 0 (immediate, L=0). Inputs are L=1 each; result must canonicalize.
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(-1);
	try b.setI64(1);
	try r.add(&a, &b);
	try testing.expectEqual(@as(i64, 0), try r.getI64());
	try testing.expectEqualSlices(u8, &[_]u8{0x00}, r.bytes); // canonical immediate
}

test "add: i64 overflow returns TierOverflow" {
	try expectArithOverflow(.add, std.math.maxInt(i64), 1);
	try expectArithOverflow(.add, std.math.minInt(i64), -1);
}

test "sub: basic and sign mixing" {
	try doArith(.sub, 10, 3, 7);
	try doArith(.sub, 3, 10, -7);
	try doArith(.sub, 0, 1, -1);
	try doArith(.sub, -5, -5, 0);
	try doArith(.sub, std.math.maxInt(i64), std.math.maxInt(i64), 0);
}

test "sub: i64 overflow returns TierOverflow" {
	try expectArithOverflow(.sub, std.math.minInt(i64), 1);
	try expectArithOverflow(.sub, std.math.maxInt(i64), -1);
}

test "mul: basic and sign mixing" {
	try doArith(.mul, 6, 7, 42);
	try doArith(.mul, -6, 7, -42);
	try doArith(.mul, -6, -7, 42);
	try doArith(.mul, 0, std.math.maxInt(i64), 0);
	try doArith(.mul, 1, std.math.maxInt(i64), std.math.maxInt(i64));
}

test "mul: i64 overflow returns TierOverflow" {
	try expectArithOverflow(.mul, std.math.maxInt(i64), 2);
	// (2^32) * (2^32) = 2^64, exceeds i64.max (2^63 - 1).
	try expectArithOverflow(.mul, @as(i64, 1) << 32, @as(i64, 1) << 32);
	// minInt(i64) * -1 also overflows (the absolute value 2^63 doesn't fit in i64).
	try expectArithOverflow(.mul, std.math.minInt(i64), -1);
}

test "mul: result canonicalizes (small product from large inputs)" {
	// 1_000_000 * 0 = 0 (immediate)
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(1_000_000);
	try b.setI64(0);
	try r.mul(&a, &b);
	try testing.expectEqualSlices(u8, &[_]u8{0x00}, r.bytes);
}

test "arithmetic does not mutate inputs" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(100);
	try b.setI64(200);
	const a_bytes_before = try testing.allocator.dupe(u8, a.bytes);
	defer testing.allocator.free(a_bytes_before);
	const b_bytes_before = try testing.allocator.dupe(u8, b.bytes);
	defer testing.allocator.free(b_bytes_before);
	try r.add(&a, &b);
	try testing.expectEqualSlices(u8, a_bytes_before, a.bytes);
	try testing.expectEqualSlices(u8, b_bytes_before, b.bytes);
}

test "arithmetic with aliasing (r = a; r.add(&r, &b))" {
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	try r.setI64(100);
	try b.setI64(50);
	try r.add(&r, &b); // r = r + b
	try testing.expectEqual(@as(i64, 150), try r.getI64());
}
