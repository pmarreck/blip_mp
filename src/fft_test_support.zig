//! Test-only adapters retain numerical fixtures while exercising encoded storage.
const std = @import("std");
const residue = @import("fft_residue.zig");
const allocator = std.testing.allocator;

fn pack(values: []const u64) ![]u8 {
	const bytes = try allocator.alloc(u8, values.len * residue.slot_bytes);
	@memset(bytes, 0xa5);
	for (values, 0..) |v, i| residue.write(bytes, i, v);
	return bytes;
}
fn unpack(bytes: []const u8, values: []u64) !void {
	var expected = @import("bignum.zig").Mp.init(allocator);
	defer expected.deinit();
	var zero = @import("bignum.zig").Mp.init(std.testing.allocator);
	defer zero.deinit();
	try zero.setI64(0);
	for (values, 0..) |*v, i| {
		v.* = residue.read(bytes, i);
		try expected.setI64(0);
		try expected.addU64(&zero, v.*);
		try std.testing.expectEqualSlices(u8, expected.bytes(), residue.encoded(bytes, i));
	}
}
pub fn permute(comptime fun: anytype, a: []u64) !void {
	const bytes = try pack(a);
	defer allocator.free(bytes);
	fun(bytes);
	try unpack(bytes, a);
}
pub fn roundTrip(comptime fun: anytype, a: []u64, invert: bool) !void {
	const bytes = try pack(a);
	defer allocator.free(bytes);
	fun(bytes, invert);
	try unpack(bytes, a);
}
pub fn transform(comptime fun: anytype, a: []u64, tw: []const u64) !void {
	const bytes = try pack(a);
	defer allocator.free(bytes);
	const tw_bytes = try pack(tw);
	defer allocator.free(tw_bytes);
	fun(bytes, tw_bytes);
	try unpack(bytes, a);
}
pub fn stockham(comptime fun: anytype, a: []u64, scratch: []u64, tw: []const u64) !void {
	const bytes = try pack(a);
	defer allocator.free(bytes);
	const sc = try allocator.alloc(u8, scratch.len * residue.slot_bytes);
	defer allocator.free(sc);
	@memset(sc, 0);
	const tw_bytes = try pack(tw);
	defer allocator.free(tw_bytes);
	fun(bytes, sc, tw_bytes);
	try unpack(bytes, a);
	try unpack(sc, scratch);
}
