//! Canonical positive signed-BLIP residues in field-sized capacity slots.
//! Unused capacity is not part of the encoding and may contain arbitrary bytes.
const std = @import("std");
pub const Small = FieldCodec(u32);
pub const Gold = FieldCodec(u64);
// General scalar codec retained for callers that need the full u64 range.
pub const slot_bytes = Gold.slot_bytes;
pub const encoded = Gold.encoded;
pub const read = Gold.read;
pub const write = Gold.write;

fn FieldCodec(comptime Word: type) type {
	return struct {
		const word_bytes = @sizeOf(Word);
		pub const slot_bytes: usize = if (Word == u32) 5 else 10;
		pub const max_value: u64 = if (Word == u32) std.math.maxInt(i32) else std.math.maxInt(u64);
		/// Zero needs only its immediate byte; leave spare capacity untouched.
		pub fn clear(bytes: []u8) void {
			std.debug.assert(bytes.len % @This().slot_bytes == 0);
			var i: usize = 0;
			while (i < bytes.len) : (i += @This().slot_bytes) bytes[i] = 0;
		}
		pub fn encoded(bytes: []const u8, index: usize) []const u8 {
			const slot = bytes[index * @This().slot_bytes ..][0..@This().slot_bytes];
			return slot[0..if (slot[0] < 128) @as(usize, 1) else 1 + @as(usize, slot[0] & 31)];
		}
		pub fn read(bytes: []const u8, index: usize) u64 {
			const slot = bytes[index * @This().slot_bytes ..][0..@This().slot_bytes];
			if (Word == u32 and slot[0] == 0x84) return std.mem.readInt(u32, slot[1..5], .little);
			if (slot[0] < 128) return slot[0];
			const len = slot[0] & 31;
			std.debug.assert(slot[0] >= 0x82 and len < @This().slot_bytes);
			const value = std.mem.readInt(Word, slot[1..][0..word_bytes], .little);
			return if (len >= word_bytes) value else @as(u64, value) & ((@as(u64, 1) << @as(u6, @intCast(len * 8))) - 1);
		}
		pub fn write(bytes: []u8, index: usize, value: u64) void {
			std.debug.assert(value <= max_value);
			const slot = bytes[index * @This().slot_bytes ..][0..@This().slot_bytes];
			if (Word == u32 and value >= 1 << 23) {
				slot[0] = 0x84;
				std.mem.writeInt(u32, slot[1..5], @intCast(value), .little);
				return;
			}
			if (value < 128) {
				slot[0] = @intCast(value);
				return;
			}
			const len: u8 = @intCast((65 - @as(usize, @clz(value)) + 7) / 8);
			slot[0] = 0x80 | len;
			std.mem.writeInt(Word, slot[1..][0..word_bytes], @intCast(value), .little);
			if (Word == u64) slot[9] = 0;
		}
	};
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

test "field-sized residue slots preserve canonical encodings and neighbors" {
	try std.testing.expectEqual(@as(usize, 5), Small.slot_bytes);
	try std.testing.expectEqual(@as(usize, 10), Gold.slot_bytes);
	const Mp = @import("bignum.zig").Mp;
	var expected = Mp.init(std.testing.allocator);
	defer expected.deinit();
	var zero = Mp.init(std.testing.allocator);
	defer zero.deinit();
	try zero.setI64(0);
	inline for (.{ Small, Gold }) |Codec| {
		var storage: [3 * Codec.slot_bytes + 1]u8 = @splat(0xa5);
		const bytes = storage[1..];
		const cases = [_]u64{ 0, 1, 127, 128, 255, 32767, 32768, 8388607, 8388608, 985661440, 998244352, 2147483647, 2147483648, 9223372036854775807, 9223372036854775808, 18446744069414584320, 18446744073709551615 };
		for (cases) |value| {
			if (value > Codec.max_value) continue;
			try expected.addU64(&zero, value);
			Codec.write(bytes, 1, value);
			try std.testing.expectEqualSlices(u8, expected.bytes(), Codec.encoded(bytes, 1));
			@memset(bytes[Codec.slot_bytes + Codec.encoded(bytes, 1).len .. 2 * Codec.slot_bytes], 0xa5);
			try std.testing.expectEqual(value, Codec.read(bytes, 1));
			try std.testing.expectEqual(@as(u8, 0xa5), storage[0]);
			try std.testing.expectEqual(@as(u8, 0xa5), bytes[Codec.slot_bytes - 1]);
			try std.testing.expectEqual(@as(u8, 0xa5), bytes[2 * Codec.slot_bytes]);
		}
	}
}

test "zero initialization touches only the canonical immediate byte" {
	inline for (.{ Small, Gold }) |Codec| {
		var bytes: [7 * Codec.slot_bytes]u8 = @splat(0xa5);
		Codec.clear(&bytes);
		for (0..7) |i| {
			try std.testing.expectEqual(@as(u64, 0), Codec.read(&bytes, i));
			try std.testing.expectEqualSlices(u8, &.{0}, Codec.encoded(&bytes, i));
			for (bytes[i * Codec.slot_bytes + 1 .. (i + 1) * Codec.slot_bytes]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
		}
	}
}
