// Bitwise ops over BLIP-encoded Mp values (M12-A1).
//
// Semantics match GMP: operands are treated as two's-complement integers
// of conceptually-infinite precision, sign-extending the BLIP payload past
// its real bytes with the sign-extension byte (0x00 for non-negative,
// 0xFF for negative). Result is canonicalised back into BLIP.

const std = @import("std");
const bignum = @import("bignum.zig");
const tier3 = @import("tier3.zig");
const encoding = @import("encoding.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

/// Trim trailing redundant sign-extension bytes from a two's-complement LE
/// payload buffer. Returns the canonical length. Empty/zero payloads collapse
/// to length 0.
fn canonicalLen(pay: []const u8) usize {
	var n = pay.len;
	while (n > 0) {
		const high = pay[n - 1];
		if (n == 1) {
			// A single 0x00 byte represents zero — collapse to len=0 so the
			// caller picks the immediate-zero encoding.
			if (high == 0x00) return 0;
			return 1;
		}
		const next = pay[n - 2];
		if (high == 0x00 and (next & 0x80) == 0) {
			n -= 1;
			continue;
		}
		if (high == 0xFF and (next & 0x80) != 0) {
			n -= 1;
			continue;
		}
		return n;
	}
	return 0;
}

/// Install a canonical two's-complement LE payload into `out` as a BLIP value.
/// Handles the immediate (0..127) special case and arbitrary tier-3 sizes.
fn installPayload(out: *Mp, pay_canon: []const u8) ArithError!void {
	// Immediate-zero: BLIP encodes 0 as a single 0x00 byte.
	if (pay_canon.len == 0) {
		var buf = [_]u8{0x00};
		try out.setBytes(buf[0..1]);
		return;
	}
	// Immediate form 0..127: single byte, no header.
	if (pay_canon.len == 1 and pay_canon[0] < 0x80) {
		var buf = [_]u8{pay_canon[0]};
		try out.setBytes(buf[0..1]);
		return;
	}
	// Length-prefixed form. Header is at most ~5 bytes for absurdly long L.
	var hdr_buf: [10]u8 = undefined;
	const hdr_len = tier3.writeHeader(&hdr_buf, pay_canon.len) catch return error.OutOfMemory;
	const need = hdr_len + pay_canon.len;
	// Use heap scratch for the assembled BLIP slice. Mp.setBytes copies it.
	const scratch = out.allocator.alloc(u8, need) catch return error.OutOfMemory;
	defer out.allocator.free(scratch);
	@memcpy(scratch[0..hdr_len], hdr_buf[0..hdr_len]);
	@memcpy(scratch[hdr_len..], pay_canon);
	try out.setBytes(scratch);
}

const BinOp = enum { and_op, or_op, xor_op };

inline fn applyOp(comptime Op: BinOp, a: u8, b: u8) u8 {
	return switch (Op) {
		.and_op => a & b,
		.or_op => a | b,
		.xor_op => a ^ b,
	};
}

fn bitwiseBinary(
	comptime Op: BinOp,
	out: *Mp,
	a: *const Mp,
	b: *const Mp,
) ArithError!void {
	const a_pay = a.payload();
	const b_pay = b.payload();
	const sa = tier3.signExtByte(a_pay);
	const sb = tier3.signExtByte(b_pay);
	const n = @max(a_pay.len, b_pay.len);
	if (n == 0) {
		// Both zero. Result is zero.
		try installPayload(out, &.{});
		return;
	}
	const tmp = out.allocator.alloc(u8, n) catch return error.OutOfMemory;
	defer out.allocator.free(tmp);
	var i: usize = 0;
	while (i < n) : (i += 1) {
		const av = if (i < a_pay.len) a_pay[i] else sa;
		const bv = if (i < b_pay.len) b_pay[i] else sb;
		tmp[i] = applyOp(Op, av, bv);
	}
	const canon = canonicalLen(tmp);
	try installPayload(out, tmp[0..canon]);
}

pub fn bitwiseAnd(out: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	return bitwiseBinary(.and_op, out, a, b);
}

pub fn bitwiseOr(out: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	return bitwiseBinary(.or_op, out, a, b);
}

pub fn bitwiseXor(out: *Mp, a: *const Mp, b: *const Mp) ArithError!void {
	return bitwiseBinary(.xor_op, out, a, b);
}

/// One's complement: ~x. Per GMP `mpz_com`, this is -(x+1) in two's complement.
pub fn bitwiseNot(out: *Mp, a: *const Mp) ArithError!void {
	const a_pay = a.payload();
	const sa = tier3.signExtByte(a_pay);
	if (a_pay.len == 0) {
		// ~0 == -1 → single byte 0xFF.
		var buf = [_]u8{ 0x80 | 1, 0xFF };
		try out.setBytes(buf[0..2]);
		return;
	}
	// Need one extra byte slot in case complementing changes the sign-extension.
	const tmp = out.allocator.alloc(u8, a_pay.len + 1) catch return error.OutOfMemory;
	defer out.allocator.free(tmp);
	var i: usize = 0;
	while (i < a_pay.len) : (i += 1) tmp[i] = ~a_pay[i];
	tmp[a_pay.len] = ~sa;
	const canon = canonicalLen(tmp);
	try installPayload(out, tmp[0..canon]);
}

/// Left shift: out = a << n. Equivalent to a * 2^n.
pub fn shl(out: *Mp, a: *const Mp, n: usize) ArithError!void {
	const a_pay = a.payload();
	if (a_pay.len == 0 or n == 0) {
		// Zero or no-op shift.
		if (a_pay.len == 0) {
			try installPayload(out, &.{});
		} else {
			try installPayload(out, a_pay);
		}
		return;
	}
	const sa = tier3.signExtByte(a_pay);
	const byte_shift = n / 8;
	const bit_shift: u3 = @intCast(n % 8);
	// Result needs: byte_shift zero bytes + a_pay.len bytes (each may produce
	// a high carry into the next byte) + 1 sign-extension byte to be safe.
	const out_len = a_pay.len + byte_shift + 1;
	const tmp = out.allocator.alloc(u8, out_len) catch return error.OutOfMemory;
	defer out.allocator.free(tmp);
	@memset(tmp[0..byte_shift], 0);
	if (bit_shift == 0) {
		@memcpy(tmp[byte_shift .. byte_shift + a_pay.len], a_pay);
		tmp[out_len - 1] = sa;
	} else {
		var carry: u8 = 0;
		var i: usize = 0;
		while (i < a_pay.len) : (i += 1) {
			const v = a_pay[i];
			tmp[byte_shift + i] = (v << bit_shift) | carry;
			carry = v >> @intCast(8 - @as(u4, bit_shift));
		}
		// Tail byte includes shifted-in sign-extension bits.
		const sa_shifted = (sa << bit_shift) | carry;
		tmp[byte_shift + a_pay.len] = sa_shifted;
	}
	const canon = canonicalLen(tmp);
	try installPayload(out, tmp[0..canon]);
}

/// Right shift (arithmetic / floor): out = floor(a / 2^n). Per GMP
/// `mpz_fdiv_q_2exp`: for negative a this rounds toward -infinity (so
/// shr(-1, k) == -1 for any k, NOT zero).
pub fn shr(out: *Mp, a: *const Mp, n: usize) ArithError!void {
	const a_pay = a.payload();
	if (n == 0) {
		try installPayload(out, a_pay);
		return;
	}
	const sa = tier3.signExtByte(a_pay);
	if (a_pay.len == 0) {
		try installPayload(out, &.{});
		return;
	}
	const total_bits = a_pay.len * 8;
	if (n >= total_bits) {
		// Shifted past everything: positives → 0, negatives → -1.
		if (sa == 0xFF) {
			var buf = [_]u8{ 0x80 | 1, 0xFF };
			try out.setBytes(buf[0..2]);
		} else {
			try installPayload(out, &.{});
		}
		return;
	}
	const byte_shift = n / 8;
	const bit_shift: u3 = @intCast(n % 8);
	// Arithmetic right shift over two's-complement bytes IS floor division
	// by 2^n — no separate correction needed. The sign-extension fill below
	// supplies the implicit infinite 1s for negative values, so the lost
	// bits round toward -infinity automatically.
	const out_len = a_pay.len - byte_shift + 1; // +1 for sign-ext padding
	const tmp = out.allocator.alloc(u8, out_len) catch return error.OutOfMemory;
	defer out.allocator.free(tmp);
	if (bit_shift == 0) {
		@memcpy(tmp[0 .. a_pay.len - byte_shift], a_pay[byte_shift..]);
		tmp[a_pay.len - byte_shift] = sa;
	} else {
		var i: usize = 0;
		while (i < a_pay.len - byte_shift) : (i += 1) {
			const lo = a_pay[byte_shift + i];
			const hi: u8 = if (byte_shift + i + 1 < a_pay.len)
				a_pay[byte_shift + i + 1]
			else
				sa;
			tmp[i] = (lo >> bit_shift) | (hi << @intCast(8 - @as(u4, bit_shift)));
		}
		tmp[a_pay.len - byte_shift] = sa >> bit_shift;
		// Sign-extension of the high bit if sa is 0xFF.
		if (sa == 0xFF) {
			const fill_shift: u3 = @intCast(8 - @as(u4, bit_shift));
			const fill: u8 = @as(u8, 0xFF) << fill_shift;
			tmp[a_pay.len - byte_shift] |= fill;
		}
	}
	const canon = canonicalLen(tmp);
	try installPayload(out, tmp[0..canon]);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectI64(want: i64, got: *const Mp) !void {
	try testing.expectEqual(want, try got.getI64());
}

test "bitwiseAnd: small positives" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, 12);
	defer x.deinit();
	var y = try Mp.fromI64(a, 10);
	defer y.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try bitwiseAnd(&r, &x, &y);
	try expectI64(8, &r);
}

test "bitwiseOr: small positives" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, 12);
	defer x.deinit();
	var y = try Mp.fromI64(a, 10);
	defer y.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try bitwiseOr(&r, &x, &y);
	try expectI64(14, &r);
}

test "bitwiseXor: x ^ x == 0" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, 0xDEADBEEF);
	defer x.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try bitwiseXor(&r, &x, &x);
	try expectI64(0, &r);
}

test "bitwiseAnd: with zero" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, 0xDEADBEEF);
	defer x.deinit();
	var z = try Mp.fromI64(a, 0);
	defer z.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try bitwiseAnd(&r, &x, &z);
	try expectI64(0, &r);
}

test "bitwiseAnd / Or / Xor: i64 spot checks across sign combinations" {
	const a = std.testing.allocator;
	const cases = [_]struct { x: i64, y: i64 }{
		.{ .x = 0x12345678, .y = 0x0FFFFFFF },
		.{ .x = -1, .y = 0x55 },
		.{ .x = -1, .y = -1 },
		.{ .x = -7, .y = 12 },
		.{ .x = 0x7FFFFFFF, .y = -0x8000_0000 },
		.{ .x = std.math.minInt(i64), .y = 1 },
	};
	for (cases) |c| {
		var x = try Mp.fromI64(a, c.x);
		defer x.deinit();
		var y = try Mp.fromI64(a, c.y);
		defer y.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try bitwiseAnd(&r, &x, &y);
		try expectI64(c.x & c.y, &r);
		try bitwiseOr(&r, &x, &y);
		try expectI64(c.x | c.y, &r);
		try bitwiseXor(&r, &x, &y);
		try expectI64(c.x ^ c.y, &r);
	}
}

test "bitwiseNot: ~x == -(x+1) per GMP semantics" {
	const a = std.testing.allocator;
	const cases = [_]i64{ 0, 1, -1, 5, -5, 0x12345678, -0x12345678, std.math.maxInt(i32), std.math.minInt(i32) };
	for (cases) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try bitwiseNot(&r, &x);
		try expectI64(~v, &r);
	}
}

test "shl: x << 0 == x; 1 << 4 == 16; 1 << 63 round-trips through shr" {
	const a = std.testing.allocator;
	{
		var x = try Mp.fromI64(a, 42);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shl(&r, &x, 0);
		try expectI64(42, &r);
	}
	{
		var x = try Mp.fromI64(a, 1);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shl(&r, &x, 4);
		try expectI64(16, &r);
		try shl(&r, &x, 10);
		try expectI64(1024, &r);
	}
}

test "shl: i64 spot checks (positives that don't overflow i64)" {
	const a = std.testing.allocator;
	const cases = [_]struct { x: i64, n: u6 }{
		.{ .x = 1, .n = 1 },
		.{ .x = 1, .n = 7 },
		.{ .x = 1, .n = 8 },
		.{ .x = 1, .n = 9 },
		.{ .x = 1, .n = 32 },
		.{ .x = 0xABCD, .n = 16 },
		.{ .x = 3, .n = 60 }, // 3 << 60 fits in i64
	};
	for (cases) |c| {
		var x = try Mp.fromI64(a, c.x);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shl(&r, &x, c.n);
		const want: i64 = c.x << c.n;
		try expectI64(want, &r);
	}
}

test "shr: x >> 0 == x; positives use truncating div" {
	const a = std.testing.allocator;
	const cases = [_]struct { x: i64, n: u6 }{
		.{ .x = 1024, .n = 4 },
		.{ .x = 1024, .n = 10 },
		.{ .x = 0x1234_5678, .n = 12 },
		.{ .x = std.math.maxInt(i32), .n = 1 },
	};
	for (cases) |c| {
		var x = try Mp.fromI64(a, c.x);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shr(&r, &x, c.n);
		try expectI64(c.x >> c.n, &r);
	}
}

test "shr: negative arithmetic shift (floor division per GMP)" {
	const a = std.testing.allocator;
	// -1 >> any → -1 (floor: -0.5, -0.25, … all round to -1)
	{
		var x = try Mp.fromI64(a, -1);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shr(&r, &x, 1);
		try expectI64(-1, &r);
		try shr(&r, &x, 100);
		try expectI64(-1, &r);
	}
	// -8 >> 1 == -4 (exact)
	{
		var x = try Mp.fromI64(a, -8);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shr(&r, &x, 1);
		try expectI64(-4, &r);
	}
	// -7 >> 1 → floor(-3.5) == -4
	{
		var x = try Mp.fromI64(a, -7);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shr(&r, &x, 1);
		try expectI64(-4, &r);
	}
	// -1024 >> 5 == -32 (exact); -1023 >> 5 == -32 (floor)
	{
		var x = try Mp.fromI64(a, -1024);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shr(&r, &x, 5);
		try expectI64(-32, &r);
	}
	{
		var x = try Mp.fromI64(a, -1023);
		defer x.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shr(&r, &x, 5);
		try expectI64(-32, &r);
	}
}

test "shr: positive shifted past total bit length → 0" {
	const a = std.testing.allocator;
	var x = try Mp.fromI64(a, 0xFF);
	defer x.deinit();
	var r = Mp.init(a);
	defer r.deinit();
	try shr(&r, &x, 1000);
	try expectI64(0, &r);
}

test "shl then shr round-trips for positives" {
	const a = std.testing.allocator;
	const cases = [_]i64{ 1, 7, 0x123, 0xABCD, 0xDEADBEEF };
	for (cases) |v| {
		var x = try Mp.fromI64(a, v);
		defer x.deinit();
		var s = Mp.init(a);
		defer s.deinit();
		var r = Mp.init(a);
		defer r.deinit();
		try shl(&s, &x, 17);
		try shr(&r, &s, 17);
		try expectI64(v, &r);
	}
}
