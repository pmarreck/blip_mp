//! GMP's public mpz ABI, confined to independent test and benchmark oracles.
const std = @import("std");
pub const Z = extern struct { allocated: c_int, size: c_int, data: ?*anyopaque };
pub extern const __gmp_version: [*:0]const u8;
pub extern "c" fn __gmpz_cmp(a: *const Z, b: *const Z) c_int;
pub extern "c" fn __gmpz_init(value: *Z) void;
pub extern "c" fn __gmpz_clear(value: *Z) void;
pub extern "c" fn __gmpz_import(value: *Z, count: usize, order: c_int, size: usize, endian: c_int, nails: usize, bytes: [*]const u8) void;
pub extern "c" fn __gmpz_export(bytes: [*]u8, count: *usize, order: c_int, size: usize, endian: c_int, nails: usize, value: *const Z) ?[*]u8;
pub extern "c" fn __gmpz_invert(result: *Z, a: *const Z, m: *const Z) c_int;
pub extern "c" fn __gmpz_tdiv_qr(q: *Z, r: *Z, a: *const Z, b: *const Z) void;
pub extern "c" fn __gmpz_neg(result: *Z, value: *const Z) void;
pub extern "c" fn __gmpz_mul(result: *Z, a: *const Z, b: *const Z) void;
pub extern "c" fn __gmpz_powm(result: *Z, a: *const Z, exponent: *const Z, modulus: *const Z) void;

pub fn product(a: []const u8, b: []const u8, output: []u8) !usize {
	const capacity = std.math.add(usize, a.len, b.len) catch return error.BufferTooSmall;
	if (output.len < capacity) return error.BufferTooSmall;
	var ga: Z = undefined;
	__gmpz_init(&ga);
	defer __gmpz_clear(&ga);
	var gb: Z = undefined;
	__gmpz_init(&gb);
	defer __gmpz_clear(&gb);
	var result: Z = undefined;
	__gmpz_init(&result);
	defer __gmpz_clear(&result);
	__gmpz_import(&ga, a.len, -1, 1, 0, 0, a.ptr);
	__gmpz_import(&gb, b.len, -1, 1, 0, 0, b.ptr);
	__gmpz_mul(&result, &ga, &gb);
	var length: usize = 0;
	_ = __gmpz_export(output.ptr, &length, -1, 1, 0, 0, &result);
	return length;
}

test "GMP byte product matches native u128 including zero and carry boundaries" {
	const cases = [_]u64{ 0, 1, 127, 128, 255, 256, 0xdeadbeef, std.math.maxInt(u64) };
	for (cases) |av| for (cases) |bv| {
		var a: [8]u8 = undefined;
		var b: [8]u8 = undefined;
		var expected: [16]u8 = undefined;
		var actual: [16]u8 = undefined;
		std.mem.writeInt(u64, &a, av, .little);
		std.mem.writeInt(u64, &b, bv, .little);
		std.mem.writeInt(u128, &expected, @as(u128, av) * bv, .little);
		const length = try product(&a, &b, &actual);
		try std.testing.expectEqualSlices(u8, std.mem.trimEnd(u8, &expected, &.{0}), actual[0..length]);
	};
}

test "GMP byte product refuses insufficient output capacity before export" {
	var output = [_]u8{0xa5} ** 5;
	try std.testing.expectError(error.BufferTooSmall, product(&.{ 255, 255 }, &.{ 255, 255 }, output[1..4]));
	try std.testing.expectEqualDeep([_]u8{0xa5} ** 5, output);
}
