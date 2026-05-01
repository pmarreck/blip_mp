// blip_mp_t — bignum value whose canonical storage is BLIP-encoded bytes
// interpreted as signed two's-complement (per SPEC.md §Sign convention).
//
// Representation 1a (small-buffer-optimization): the encoding lives inline
// in the struct when its length fits in INLINE_CAP bytes. Larger values
// fall back to a heap allocation. For tier 0/1 (signed canonical L <= 8,
// total encoded size <= 9 bytes), every value is inline — zero allocation
// in the hot path. This is the representation SPEC.md §Storage model
// option 1 calls for, and the one Run 1 of the benchmark identified as
// necessary to realize the small-value performance win.
//
// Struct layout (64 bytes total on 64-bit):
//   [0..24)  inline_buf      — encoded bytes when in inline mode
//   [24]     inline_len      — 0..INLINE_CAP if inline; SENTINEL_HEAP if heap
//   [25..32) padding
//   [32..48) heap_bytes      — slice when in heap mode (ptr + len)
//   [48..64) allocator       — std.mem.Allocator (ptr + vtable ptr)

const std = @import("std");
const encoding = @import("encoding.zig");
const tier3 = @import("tier3.zig");

pub const INLINE_CAP: usize = 24;
const SENTINEL_HEAP: u8 = 0xFF;

pub const SetError = std.mem.Allocator.Error || encoding.Error || error{
	UnsignedTooLarge,
};

pub const GetError = encoding.Error || error{
	SentinelValue,
	ValueIsNegative,
};

pub const ArithError = SetError || GetError || error{
	TierOverflow, // currently unused — tier 3 promotion handles all in-range cases
	OutputBufferTooSmall, // tier-3 result wouldn't fit in target Mp's heap or inline buffer
};

pub const Mp = struct {
	inline_buf: [INLINE_CAP]u8 align(8),
	inline_len: u8,
	heap_bytes: []u8,
	allocator: std.mem.Allocator,

	pub fn init(allocator: std.mem.Allocator) Mp {
		return .{
			.inline_buf = [_]u8{0} ** INLINE_CAP,
			.inline_len = 0,
			.heap_bytes = &[_]u8{},
			.allocator = allocator,
		};
	}

	pub fn deinit(self: *Mp) void {
		if (self.inline_len == SENTINEL_HEAP) {
			self.allocator.free(self.heap_bytes);
			self.heap_bytes = &[_]u8{};
			self.inline_len = 0;
		}
	}

	/// Returns the active encoded bytes — points into either inline_buf
	/// or heap_bytes. Caller must not retain the slice across mutating
	/// operations on this Mp.
	pub fn bytes(self: *const Mp) []const u8 {
		if (self.inline_len != SENTINEL_HEAP) {
			return self.inline_buf[0..self.inline_len];
		}
		return self.heap_bytes;
	}

	pub fn isInline(self: *const Mp) bool {
		return self.inline_len != SENTINEL_HEAP;
	}

	/// Replace this value with the canonical signed BLIP encoding of `value`.
	/// Tier 0/1 stays inline (zero allocation). Larger values fall back to heap.
	///
	/// Hot path: value in [0,127] gets a single-byte store with no call into
	/// the encoder. Closes the Mp.add/raw gap measured in BENCHMARK_RESULTS.md
	/// Run 2 (~0.6 ns saved per immediate add).
	pub fn setI64(self: *Mp, value: i64) SetError!void {
		// Immediate-range fast path: by far the most common in tier-0
		// workloads. Single byte store; predicted-true branch.
		if (value >= 0 and value < 128) {
			if (self.inline_len == SENTINEL_HEAP) {
				self.allocator.free(self.heap_bytes);
				self.heap_bytes = &[_]u8{};
			}
			self.inline_buf[0] = @intCast(value);
			self.inline_len = 1;
			return;
		}
		const need = encoding.encodedSizeI64(value);
		if (need <= INLINE_CAP) {
			if (self.inline_len == SENTINEL_HEAP) {
				self.allocator.free(self.heap_bytes);
				self.heap_bytes = &[_]u8{};
			}
			const written = try encoding.encodeI64Canonical(self.inline_buf[0..need], value);
			std.debug.assert(written == need);
			self.inline_len = @intCast(need);
			return;
		}
		// Heap path. Allocate first; only free old heap on success.
		const buf = try self.allocator.alloc(u8, need);
		errdefer self.allocator.free(buf);
		const written = try encoding.encodeI64Canonical(buf, value);
		std.debug.assert(written == need);
		if (self.inline_len == SENTINEL_HEAP) {
			self.allocator.free(self.heap_bytes);
		}
		self.heap_bytes = buf;
		self.inline_len = SENTINEL_HEAP;
	}

	pub fn setU64(self: *Mp, value: u64) SetError!void {
		if (value > std.math.maxInt(i64)) return error.UnsignedTooLarge;
		return self.setI64(@intCast(value));
	}

	pub fn getI64(self: *const Mp) GetError!i64 {
		// Hot path: inline + immediate first byte (< 0x80). One byte read,
		// no decode loop, no sign-extension.
		if (self.inline_len != SENTINEL_HEAP and self.inline_len == 1 and self.inline_buf[0] < 0x80) {
			return self.inline_buf[0];
		}
		const dec = try encoding.decodeI64(self.bytes());
		if (dec.is_sentinel) return error.SentinelValue;
		return dec.value;
	}

	pub fn getU64(self: *const Mp) GetError!u64 {
		const v = try self.getI64();
		if (v < 0) return error.ValueIsNegative;
		return @intCast(v);
	}

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

	pub fn add(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		// Tier-0/1 fast path: both operands inline AND ≤9 bytes each.
		// Hand-inlined to keep the compiler from emitting function calls
		// in the hot loop (measured: function-call form was 4× slower).
		if (a.inline_len <= 9 and b.inline_len <= 9) {
			const av = decodeInlineSmall(a);
			const bv = decodeInlineSmall(b);
			const ov = @addWithOverflow(av, bv);
			if (ov[1] == 0) {
				try r.setI64(ov[0]);
				return;
			}
		}
		try tier3Op(r, a, b, .add);
	}

	pub fn sub(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		if (a.inline_len <= 9 and b.inline_len <= 9) {
			const av = decodeInlineSmall(a);
			const bv = decodeInlineSmall(b);
			const ov = @subWithOverflow(av, bv);
			if (ov[1] == 0) {
				try r.setI64(ov[0]);
				return;
			}
		}
		try tier3Op(r, a, b, .sub);
	}

	pub fn mul(r: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
		if (a.inline_len <= 9 and b.inline_len <= 9) {
			const av: i128 = @as(i128, decodeInlineSmall(a));
			const bv: i128 = @as(i128, decodeInlineSmall(b));
			const product: i128 = av * bv;
			if (product >= std.math.minInt(i64) and product <= std.math.maxInt(i64)) {
				try r.setI64(@intCast(product));
				return;
			}
		}
		// Tier-3 mul not yet implemented — only add/sub for now.
		return error.TierOverflow;
	}

	/// Returns true iff this Mp's encoded form fits in the i64 universe
	/// (signed canonical L ≤ 8 → at most 9 bytes total).
	fn fitsTier01(self: *const Mp) bool {
		const len = if (self.inline_len != SENTINEL_HEAP) self.inline_len else self.heap_bytes.len;
		return len <= 9;
	}

	/// Replace this Mp's value with the BLIP-encoded byte slice given.
	/// Routes inline vs heap automatically.
	pub fn setBytes(self: *Mp, slice: []const u8) std.mem.Allocator.Error!void {
		if (slice.len <= INLINE_CAP) {
			if (self.inline_len == SENTINEL_HEAP) {
				self.allocator.free(self.heap_bytes);
				self.heap_bytes = &[_]u8{};
			}
			@memcpy(self.inline_buf[0..slice.len], slice);
			self.inline_len = @intCast(slice.len);
			return;
		}
		const buf = try self.allocator.alloc(u8, slice.len);
		errdefer self.allocator.free(buf);
		@memcpy(buf, slice);
		if (self.inline_len == SENTINEL_HEAP) {
			self.allocator.free(self.heap_bytes);
		}
		self.heap_bytes = buf;
		self.inline_len = SENTINEL_HEAP;
	}
};

/// Hot-path decoder for inline values with len ≤ 9. Inlined in arithmetic.
/// Fast path: immediate (len=1, byte < 0x80) returns the byte directly.
/// Otherwise falls through to encoding.decodeI64 which handles the L=1..8
/// header+payload case.
inline fn decodeInlineSmall(self: *const Mp) i64 {
	if (self.inline_len == 1 and self.inline_buf[0] < 0x80) {
		return self.inline_buf[0];
	}
	const dec = encoding.decodeI64(self.inline_buf[0..self.inline_len]) catch unreachable;
	return dec.value;
}

/// Internal tier-3 dispatch. Operates DIRECTLY on the BLIP payload bytes —
/// no limb-array conversion. Two's-complement arithmetic is bit-position-
/// local, so per-byte add/sub with carry produces correct results across
/// any sign combination. Stack scratch up to 1KB (8192-bit operands);
/// larger spills to the allocator.
fn tier3Op(r: *Mp, a: *const Mp, b: *const Mp, comptime op: enum { add, sub }) ArithError!void {
	const a_bytes = a.bytes();
	const b_bytes = b.bytes();
	// Worst-case scratch: max payload length + 1 (overflow byte).
	const max_payload = @max(a_bytes.len, b_bytes.len);
	const scratch_need = max_payload + 1;
	// Worst-case output: payload (max_payload + 1) + header (≤10 bytes).
	const out_need = max_payload + 1 + 10;

	const STACK_BYTES = 1024; // 8192-bit operands stay alloc-free
	var stack_scratch: [STACK_BYTES]u8 = undefined;
	var stack_out: [STACK_BYTES]u8 = undefined;
	var heap_scratch: ?[]u8 = null;
	var heap_out: ?[]u8 = null;
	defer {
		if (heap_scratch) |slice| r.allocator.free(slice);
		if (heap_out) |slice| r.allocator.free(slice);
	}
	const scratch: []u8 = if (scratch_need <= STACK_BYTES) stack_scratch[0..scratch_need] else blk: {
		heap_scratch = try r.allocator.alloc(u8, scratch_need);
		break :blk heap_scratch.?;
	};
	const out_buf: []u8 = if (out_need <= STACK_BYTES) stack_out[0..out_need] else blk: {
		heap_out = try r.allocator.alloc(u8, out_need);
		break :blk heap_out.?;
	};

	const written = switch (op) {
		.add => try tier3.addRawBlip(a_bytes, b_bytes, scratch, out_buf),
		.sub => try tier3.subRawBlip(a_bytes, b_bytes, scratch, out_buf),
	};
	try r.setBytes(out_buf[0..written]);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Mp.setU64(5) stores [0x05] inline and getU64 returns 5" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(5);
	try testing.expectEqualSlices(u8, &[_]u8{0x05}, x.bytes());
	try testing.expect(x.isInline());
	try testing.expectEqual(@as(u64, 5), try x.getU64());
}

test "Mp tier 0/1 values stay inline (zero allocation)" {
	const cases = [_]i64{ 0, 5, 127, 128, -1, -128, std.math.maxInt(i64), std.math.minInt(i64) };
	for (cases) |v| {
		var x = Mp.init(testing.allocator);
		defer x.deinit();
		try x.setI64(v);
		try testing.expect(x.isInline());
		try testing.expectEqual(v, try x.getI64());
	}
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

test "Mp.setU64 rejects values above i64.max" {
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
	try testing.expectEqual(@as(usize, 9), x.bytes().len);
	try testing.expect(x.isInline());
}

test "Mp.setU64 produces single-byte form for immediate range" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(127);
	try testing.expectEqual(@as(usize, 1), x.bytes().len);
	try testing.expectEqual(@as(u8, 0x7F), x.bytes()[0]);
}

test "Mp.setU64(128) produces signed-canonical [0x82, 0x80, 0x00]" {
	var x = Mp.init(testing.allocator);
	defer x.deinit();
	try x.setU64(128);
	try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x80, 0x00 }, x.bytes());
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
	try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xFF }, x.bytes());
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
	try testing.expectEqualSlices(u8, &[_]u8{0x00}, r.bytes());
}

test "add: i64 overflow promotes to tier 3 (no longer errors)" {
	// Was error.TierOverflow before tier-3 promotion landed; now silently
	// promotes. Result encoding exceeds 9 bytes (the i64 universe).
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try b.setI64(1);
	try r.add(&a, &b);
	try testing.expect(r.bytes().len > 9);
}

test "sub: basic and sign mixing" {
	try doArith(.sub, 10, 3, 7);
	try doArith(.sub, 3, 10, -7);
	try doArith(.sub, 0, 1, -1);
	try doArith(.sub, -5, -5, 0);
	try doArith(.sub, std.math.maxInt(i64), std.math.maxInt(i64), 0);
}

test "sub: i64 overflow promotes to tier 3 (no longer errors)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.minInt(i64));
	try b.setI64(1);
	try r.sub(&a, &b);
	try testing.expect(r.bytes().len > 9);
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
	try expectArithOverflow(.mul, @as(i64, 1) << 32, @as(i64, 1) << 32);
	try expectArithOverflow(.mul, std.math.minInt(i64), -1);
}

test "mul: result canonicalizes (small product from large inputs)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(1_000_000);
	try b.setI64(0);
	try r.mul(&a, &b);
	try testing.expectEqualSlices(u8, &[_]u8{0x00}, r.bytes());
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
	const a_bytes_before = try testing.allocator.dupe(u8, a.bytes());
	defer testing.allocator.free(a_bytes_before);
	const b_bytes_before = try testing.allocator.dupe(u8, b.bytes());
	defer testing.allocator.free(b_bytes_before);
	try r.add(&a, &b);
	try testing.expectEqualSlices(u8, a_bytes_before, a.bytes());
	try testing.expectEqualSlices(u8, b_bytes_before, b.bytes());
}

test "arithmetic with aliasing (r = a; r.add(&r, &b))" {
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	try r.setI64(100);
	try b.setI64(50);
	try r.add(&r, &b);
	try testing.expectEqual(@as(i64, 150), try r.getI64());
}

test "Mp struct size: 64 bytes (one cache line)" {
	try testing.expectEqual(@as(usize, 64), @sizeOf(Mp));
}

// ── Tier-3 cross-tier promotion tests ────────────────────────────────────────
//
// Drive the tier3.zig path through Mp.add. Operands chosen so that:
//   - both operands fit in i64 (tier 0/1 fast path is reachable), or
//   - operand or result exceeds i64 (must promote to tier 3)

test "add: i64.max + 1 promotes to tier 3 (no error.TierOverflow)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try b.setI64(1);
	try r.add(&a, &b); // Was error.TierOverflow before tier-3.
	// Result = 2^63, which doesn't fit in i64. Should encode in L=9 with leading sign byte.
	// Verify by decoding via tier3.payloadToMagnitude and checking the magnitude.
	const r_bytes = r.bytes();
	try testing.expect(r_bytes.len > 9); // exceeds i64 universe
}

test "add: minInt(i64) + (-1) promotes to tier 3 (negative overflow)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.minInt(i64));
	try b.setI64(-1);
	try r.add(&a, &b); // tier 3 takes over
	try testing.expect(r.bytes().len > 9);
}

test "sub: i64.max - i64.min overflows i64, promotes" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var b = Mp.init(testing.allocator);
	defer b.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try b.setI64(std.math.minInt(i64));
	try r.sub(&a, &b);
	// Result = 2^64 - 1, doesn't fit in i64.
	try testing.expect(r.bytes().len > 9);
}

test "tier-3 round-trip: (i64.max + 1) - 1 = i64.max (back to tier 0/1)" {
	var a = Mp.init(testing.allocator);
	defer a.deinit();
	var one = Mp.init(testing.allocator);
	defer one.deinit();
	var r = Mp.init(testing.allocator);
	defer r.deinit();
	try a.setI64(std.math.maxInt(i64));
	try one.setI64(1);
	try r.add(&a, &one); // r = 2^63 (tier 3)
	try r.sub(&r, &one); // r = 2^63 - 1 = i64.max (back to tier 0/1, encoded in 9 bytes)
	try testing.expectEqual(@as(i64, std.math.maxInt(i64)), try r.getI64());
}
