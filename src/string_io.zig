// String I/O over Mp values (M12-A3).
//
// `setStr(slice, base)` parses an ASCII string into an Mp; supports bases
// 2, 8, 10, 16. Optional leading "-" for negatives. Empty input → error;
// invalid digits for the chosen base → error.
//
// `toString(allocator, base)` formats an Mp as an ASCII string. Caller owns
// the returned buffer (allocated via `allocator`). Negative values get a
// leading "-".
//
// Implementation:
//   - Bases 2/8/16 (power-of-2): bit-extract from magnitude bytes; trivial.
//   - Base 10: for parse, Horner's method (running = running*10 + digit).
//     For format, repeated divide-by-10^19 (largest 10^k ≤ u64.max), format
//     each chunk via std.fmt, glue together.

const std = @import("std");
const bignum = @import("bignum.zig");
const sign_mod = @import("sign.zig");

const Mp = bignum.Mp;
const ArithError = bignum.ArithError;

pub const StringError = error{
	EmptyString,
	InvalidDigit,
	UnsupportedBase,
} || ArithError;

/// Parse `slice` as an integer in `base` (must be 2, 8, 10, or 16) into `self`.
/// Allows optional leading "-". Whitespace is NOT trimmed (caller's job).
pub fn setStr(self: *Mp, slice: []const u8, base: u8) StringError!void {
	if (base != 2 and base != 8 and base != 10 and base != 16) return error.UnsupportedBase;
	if (slice.len == 0) return error.EmptyString;
	var i: usize = 0;
	var negative = false;
	if (slice[0] == '-') {
		negative = true;
		i = 1;
		if (slice.len == 1) return error.EmptyString;
	} else if (slice[0] == '+') {
		i = 1;
		if (slice.len == 1) return error.EmptyString;
	}
	const digits = slice[i..];
	if (digits.len == 0) return error.EmptyString;
	// Validate every char up front; reject empty digit run.
	for (digits) |c| {
		if (digitValue(c, base) == null) return error.InvalidDigit;
	}

	// Build value via Horner's method. Use a working Mp as accumulator.
	const allocator = self.allocator;
	var acc = Mp.init(allocator);
	defer acc.deinit();
	try acc.setI64(0);
	var radix = Mp.init(allocator);
	defer radix.deinit();
	try radix.setI64(@intCast(base));
	var dval = Mp.init(allocator);
	defer dval.deinit();
	var tmp = Mp.init(allocator);
	defer tmp.deinit();

	for (digits) |c| {
		const d = digitValue(c, base).?;
		try tmp.mul(&acc, &radix);
		try dval.setI64(@intCast(d));
		try acc.add(&tmp, &dval);
	}

	if (negative and acc.cachedSign() != 0) {
		try sign_mod.neg(self, &acc);
	} else {
		try self.setBytes(acc.bytes());
	}
}

inline fn digitValue(c: u8, base: u8) ?u8 {
	const v: u8 = switch (c) {
		'0'...'9' => c - '0',
		'a'...'z' => c - 'a' + 10,
		'A'...'Z' => c - 'A' + 10,
		else => return null,
	};
	if (v >= base) return null;
	return v;
}

/// Format `self` as an ASCII string in `base` (must be 2, 8, 10, or 16).
/// Returns a buffer owned by the caller (allocated via `allocator`).
pub fn toString(self: *const Mp, allocator: std.mem.Allocator, base: u8) StringError![]u8 {
	if (base != 2 and base != 8 and base != 10 and base != 16) return error.UnsupportedBase;
	if (self.cachedSign() == 0) {
		const buf = allocator.alloc(u8, 1) catch return error.OutOfMemory;
		buf[0] = '0';
		return buf;
	}
	switch (base) {
		2 => return formatPow2(self, allocator, 1),
		8 => return formatPow2(self, allocator, 3),
		16 => return formatPow2(self, allocator, 4),
		10 => return formatBase10(self, allocator),
		else => unreachable,
	}
}

/// Format a non-zero value in a power-of-2 base. `bits_per_digit` ∈ {1, 3, 4}.
/// Walks the magnitude bits high-to-low, packing `bits_per_digit` bits per
/// output character. Leading zero digits are skipped.
fn formatPow2(self: *const Mp, allocator: std.mem.Allocator, bits_per_digit: u3) StringError![]u8 {
	const total_bits = self.bitLen();
	std.debug.assert(total_bits > 0);
	const negative = self.cachedSign() < 0;
	// Number of digits = ceil(total_bits / bits_per_digit).
	const n_digits = (total_bits + bits_per_digit - 1) / bits_per_digit;
	const buf_len = n_digits + @as(usize, if (negative) 1 else 0);
	const buf = allocator.alloc(u8, buf_len) catch return error.OutOfMemory;
	var pos: usize = 0;
	if (negative) {
		buf[0] = '-';
		pos = 1;
	}
	// Walk digits high to low. For digit index `d`, bits are
	// [d*bits_per_digit .. d*bits_per_digit + bits_per_digit).
	var d_idx: usize = n_digits;
	while (d_idx > 0) {
		d_idx -= 1;
		var v: u8 = 0;
		var b: u3 = 0;
		while (b < bits_per_digit) : (b += 1) {
			const bit_pos = d_idx * bits_per_digit + b;
			v |= @as(u8, self.bitAt(bit_pos)) << b;
		}
		buf[pos] = digitChar(v);
		pos += 1;
	}
	return buf;
}

inline fn digitChar(v: u8) u8 {
	return if (v < 10) ('0' + v) else ('a' + (v - 10));
}

/// Format a non-zero value in base 10. Strategy: repeatedly divide |self| by
/// 10^19 (largest 10^k ≤ u64.max), format each chunk with `std.fmt`. The
/// most-significant chunk has no leading zeros; lower chunks are zero-padded
/// to 19 digits.
fn formatBase10(self: *const Mp, allocator: std.mem.Allocator) StringError![]u8 {
	const negative = self.cachedSign() < 0;
	const allocator_local = self.allocator;
	// Working magnitude.
	var mag = Mp.init(allocator_local);
	defer mag.deinit();
	try sign_mod.abs(&mag, self);

	const chunk_divisor: u64 = 10_000_000_000_000_000_000; // 10^19
	var div_mp = Mp.init(allocator_local);
	defer div_mp.deinit();
	// 10^19 fits in u64 but not i64.maxInt — build via setBytes for the BLIP form.
	// 10^19 = 0x8AC7230489E80000; high bit set, so canonical positive payload
	// needs trailing zero byte: payload = LE bytes of 10^19, with extra 0x00.
	// 9 bytes total. Header = 0x80 | 9 = 0x89.
	{
		var le: [8]u8 = undefined;
		std.mem.writeInt(u64, &le, chunk_divisor, .little);
		var blip: [10]u8 = undefined;
		blip[0] = 0x89;
		@memcpy(blip[1..9], &le);
		blip[9] = 0x00;
		try div_mp.setBytes(&blip);
	}

	// chunks[i] = the i-th lowest 19-digit chunk.
	var chunks = std.array_list.Managed(u64).init(allocator);
	defer chunks.deinit();

	var q = Mp.init(allocator_local);
	defer q.deinit();
	var rem = Mp.init(allocator_local);
	defer rem.deinit();

	while (mag.cachedSign() != 0) {
		try Mp.divMod(&q, &rem, &mag, &div_mp);
		// rem fits in [0, 10^19) → fits u64.
		const chunk: u64 = blk: {
			if (rem.cachedSign() == 0) break :blk 0;
			// Extract magnitude as u64. payload is LE non-negative bytes ≤ 8.
			const pay = rem.payload();
			std.debug.assert(pay.len <= 9);
			var v: u64 = 0;
			var shift: u6 = 0;
			for (pay) |b| {
				v |= @as(u64, b) << shift;
				if (shift == 56) break;
				shift += 8;
			}
			break :blk v;
		};
		try chunks.append(chunk);
		try mag.setBytes(q.bytes());
	}

	// Now print: top chunk no padding, others padded to 19 digits, with leading '-' if negative.
	// Estimate buffer: chunks.len * 19 + 2.
	const out = try allocator.alloc(u8, chunks.items.len * 19 + 1);
	var pos: usize = 0;
	if (negative) {
		out[pos] = '-';
		pos += 1;
	}
	// Highest chunk first.
	const top = chunks.items[chunks.items.len - 1];
	const top_str = std.fmt.bufPrint(out[pos..], "{d}", .{top}) catch return error.OutOfMemory;
	pos += top_str.len;
	// Remaining chunks zero-padded to 19.
	var i: usize = chunks.items.len - 1;
	while (i > 0) {
		i -= 1;
		const s = std.fmt.bufPrint(out[pos..], "{d:0>19}", .{chunks.items[i]}) catch return error.OutOfMemory;
		pos += s.len;
	}
	// Shrink to actual length.
	const final = allocator.realloc(out, pos) catch out[0..pos];
	return final;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn expectStr(allocator: std.mem.Allocator, want: []const u8, got: []u8) !void {
	defer allocator.free(got);
	try testing.expectEqualSlices(u8, want, got);
}

test "string_io: setStr base 10 small positives + negatives + zero" {
	const a = std.testing.allocator;
	const cases = [_]struct { s: []const u8, want: i64 }{
		.{ .s = "0", .want = 0 },
		.{ .s = "1", .want = 1 },
		.{ .s = "-1", .want = -1 },
		.{ .s = "42", .want = 42 },
		.{ .s = "-42", .want = -42 },
		.{ .s = "1234567890", .want = 1234567890 },
		.{ .s = "-1234567890", .want = -1234567890 },
		.{ .s = "+7", .want = 7 },
	};
	for (cases) |c| {
		var x = Mp.init(a);
		defer x.deinit();
		try setStr(&x, c.s, 10);
		try testing.expectEqual(c.want, try x.getI64());
	}
}

test "string_io: setStr rejects empty / invalid / unsupported base" {
	const a = std.testing.allocator;
	var x = Mp.init(a);
	defer x.deinit();
	try testing.expectError(error.EmptyString, setStr(&x, "", 10));
	try testing.expectError(error.EmptyString, setStr(&x, "-", 10));
	try testing.expectError(error.EmptyString, setStr(&x, "+", 10));
	try testing.expectError(error.InvalidDigit, setStr(&x, "12a", 10));
	try testing.expectError(error.InvalidDigit, setStr(&x, "1 0", 10));
	try testing.expectError(error.UnsupportedBase, setStr(&x, "10", 3));
	try testing.expectError(error.UnsupportedBase, setStr(&x, "10", 36));
}

test "string_io: setStr base 16" {
	const a = std.testing.allocator;
	const cases = [_]struct { s: []const u8, want: i64 }{
		.{ .s = "0", .want = 0 },
		.{ .s = "ff", .want = 255 },
		.{ .s = "FF", .want = 255 },
		.{ .s = "DeadBeef", .want = 0xDEADBEEF },
		.{ .s = "-100", .want = -256 },
	};
	for (cases) |c| {
		var x = Mp.init(a);
		defer x.deinit();
		try setStr(&x, c.s, 16);
		try testing.expectEqual(c.want, try x.getI64());
	}
}

test "string_io: setStr base 2" {
	const a = std.testing.allocator;
	const cases = [_]struct { s: []const u8, want: i64 }{
		.{ .s = "0", .want = 0 },
		.{ .s = "1", .want = 1 },
		.{ .s = "1010", .want = 10 },
		.{ .s = "11111111", .want = 255 },
		.{ .s = "-101", .want = -5 },
	};
	for (cases) |c| {
		var x = Mp.init(a);
		defer x.deinit();
		try setStr(&x, c.s, 2);
		try testing.expectEqual(c.want, try x.getI64());
	}
}

test "string_io: setStr base 8" {
	const a = std.testing.allocator;
	const cases = [_]struct { s: []const u8, want: i64 }{
		.{ .s = "0", .want = 0 },
		.{ .s = "7", .want = 7 },
		.{ .s = "10", .want = 8 },
		.{ .s = "777", .want = 511 },
	};
	for (cases) |c| {
		var x = Mp.init(a);
		defer x.deinit();
		try setStr(&x, c.s, 8);
		try testing.expectEqual(c.want, try x.getI64());
	}
}

test "string_io: toString small positives + negatives + zero in base 10" {
	const a = std.testing.allocator;
	const cases = [_]struct { v: i64, want: []const u8 }{
		.{ .v = 0, .want = "0" },
		.{ .v = 1, .want = "1" },
		.{ .v = -1, .want = "-1" },
		.{ .v = 42, .want = "42" },
		.{ .v = -42, .want = "-42" },
		.{ .v = 1234567890, .want = "1234567890" },
		.{ .v = std.math.maxInt(i32), .want = "2147483647" },
	};
	for (cases) |c| {
		var x = Mp.init(a);
		defer x.deinit();
		try x.setI64(c.v);
		const s = try toString(&x, a, 10);
		try expectStr(a, c.want, s);
	}
}

test "string_io: toString base 16 / 2 / 8 small values" {
	const a = std.testing.allocator;
	{
		var x = Mp.init(a);
		defer x.deinit();
		try x.setI64(0xDEADBEEF);
		const s = try toString(&x, a, 16);
		try expectStr(a, "deadbeef", s);
	}
	{
		var x = Mp.init(a);
		defer x.deinit();
		try x.setI64(10);
		const s = try toString(&x, a, 2);
		try expectStr(a, "1010", s);
	}
	{
		var x = Mp.init(a);
		defer x.deinit();
		try x.setI64(511);
		const s = try toString(&x, a, 8);
		try expectStr(a, "777", s);
	}
	{
		var x = Mp.init(a);
		defer x.deinit();
		try x.setI64(-256);
		const s = try toString(&x, a, 16);
		try expectStr(a, "-100", s);
	}
}

test "string_io: round-trip across bases for tier-0/1 values" {
	const a = std.testing.allocator;
	const values = [_]i64{ 0, 1, -1, 7, -7, 100, -100, 0xDEADBEEF, -0xDEADBEEF, std.math.maxInt(i32), std.math.minInt(i32), 1234567890123 };
	const bases = [_]u8{ 2, 8, 10, 16 };
	for (values) |v| {
		for (bases) |b| {
			var x = Mp.init(a);
			defer x.deinit();
			try x.setI64(v);
			const s = try toString(&x, a, b);
			defer a.free(s);
			var y = Mp.init(a);
			defer y.deinit();
			try setStr(&y, s, b);
			try testing.expectEqual(v, try y.getI64());
		}
	}
}

test "string_io: round-trip large values (256-bit / 1024-bit / 2048-bit) in all bases" {
	const a = std.testing.allocator;
	var prng = std.Random.DefaultPrng.init(0xBE5710);
	const random_mp = @import("random_mp.zig");
	const bit_widths = [_]usize{ 256, 1024, 2048 };
	const bases = [_]u8{ 2, 8, 10, 16 };
	for (bit_widths) |bits| {
		for (0..3) |_| {
			var x = Mp.init(a);
			defer x.deinit();
			try random_mp.setRandomBits(&x, prng.random(), bits);
			for (bases) |b| {
				const s = try toString(&x, a, b);
				defer a.free(s);
				var y = Mp.init(a);
				defer y.deinit();
				try setStr(&y, s, b);
				try testing.expectEqual(std.math.Order.eq, x.cmp(&y));
			}
			// Also test negative round-trip.
			var nx = Mp.init(a);
			defer nx.deinit();
			try sign_mod.neg(&nx, &x);
			for (bases) |b| {
				const s = try toString(&nx, a, b);
				defer a.free(s);
				var y = Mp.init(a);
				defer y.deinit();
				try setStr(&y, s, b);
				try testing.expectEqual(std.math.Order.eq, nx.cmp(&y));
			}
		}
	}
}

test "string_io: toString base 10 of a known very-large value" {
	const a = std.testing.allocator;
	// 2^200 has decimal representation
	// 1606938044258990275541962092341162602522202993782792835301376
	var x = Mp.init(a);
	defer x.deinit();
	// Build 2^200 via setBytes: payload = [0]*25 + [0x01], no need for trailing
	// 0 because high bit is 0. 26 payload bytes.
	var pay = [_]u8{0} ** 26;
	pay[25] = 0x01;
	var blip: [27]u8 = undefined;
	blip[0] = 0x80 | 26;
	@memcpy(blip[1..27], &pay);
	try x.setBytes(&blip);
	const s = try toString(&x, a, 10);
	defer a.free(s);
	try testing.expectEqualSlices(
		u8,
		"1606938044258990275541962092341162602522202993782792835301376",
		s,
	);
}

test "string_io: setStr+toString agree on a long decimal literal" {
	const a = std.testing.allocator;
	const big = "123456789012345678901234567890123456789012345678901234567890";
	var x = Mp.init(a);
	defer x.deinit();
	try setStr(&x, big, 10);
	const s = try toString(&x, a, 10);
	defer a.free(s);
	try testing.expectEqualSlices(u8, big, s);
}
