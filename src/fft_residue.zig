//! Canonical positive signed-BLIP residues in fixed-capacity byte slots.
//! The header determines the encoded length; unused slot bytes are not digits.
const std = @import("std");
pub const slot_bytes: usize = 16;

pub fn encoded(bytes: []const u8, index: usize) []const u8 {
	const slot = bytes[index * slot_bytes ..][0..slot_bytes];
	return slot[0..if (slot[0] < 128) @as(usize, 1) else 1 + @as(usize, slot[0] & 31)];
}
pub fn read(bytes: []const u8, index: usize) u64 {
	const slot = bytes[index * slot_bytes ..][0..slot_bytes];
	if (slot[0] < 128) return slot[0];
	const len = slot[0] & 31;
	std.debug.assert(slot[0] >= 0x82 and slot[0] <= 0x89);
	const value = std.mem.readInt(u64, slot[1..9], .little);
	return if (len >= 8) value else value & ((@as(u64, 1) << @as(u6, @intCast(len * 8))) - 1);
}
pub fn write(bytes: []u8, index: usize, value: u64) void {
	const slot = bytes[index * slot_bytes ..][0..slot_bytes];
	if (value < 128) {
		slot[0] = @intCast(value);
		return;
	}
	const len: u8 = @intCast((65 - @as(usize, @clz(value)) + 7) / 8);
	slot[0] = 0x80 | len;
	std.mem.writeInt(u64, slot[1..9], value, .little);
	slot[9] = 0; // positive sign extension for values >= 2^63

}

test "residues match canonical BLIP at all signed payload boundaries" {
	const Mp = @import("bignum.zig").Mp;
	var expected = Mp.init(std.testing.allocator);
	defer expected.deinit();
	var zero = @import("bignum.zig").Mp.init(std.testing.allocator);
	defer zero.deinit();
	try zero.setI64(0);
	var storage: [slot_bytes * 3 + 1]u8 = @splat(0xa5);
	const bytes = storage[1..]; // no alignment contract
	const values = [_]u64{ 0, 1, 127, 128, 255, 32767, 32768, 8388607, 8388608, 2147483647, 2147483648, 549755813887, 549755813888, 140737488355327, 140737488355328, 36028797018963967, 36028797018963968, 9223372036854775807, 9223372036854775808, 18446744069414584320, 18446744073709551615 };
	for (values) |value| {
		try expected.setI64(0);
		try expected.addU64(&zero, value);
		write(bytes, 1, value);
		try std.testing.expectEqualSlices(u8, expected.bytes(), encoded(bytes, 1));
		// Poison capacity past the encoding: decoding must ignore it.
		@memset(bytes[slot_bytes + encoded(bytes, 1).len .. 2 * slot_bytes], 0xa5);
		try std.testing.expectEqual(value, read(bytes, 1));
		try std.testing.expectEqual(@as(u8, 0xa5), storage[0]);
		try std.testing.expectEqual(@as(u8, 0xa5), bytes[0]);
		try std.testing.expectEqual(@as(u8, 0xa5), bytes[2 * slot_bytes]);
	}
}
