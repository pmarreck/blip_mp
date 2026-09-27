//! Register-sized access to little-endian byte storage, without typed array views.
const std = @import("std");

pub inline fn read(bytes: []const u8, index: usize) u64 {
	return std.mem.readInt(u64, bytes[index * 8 ..][0..8], .little);
}

pub inline fn write(bytes: []u8, index: usize, value: u64) void {
	std.mem.writeInt(u64, bytes[index * 8 ..][0..8], value, .little);
}
