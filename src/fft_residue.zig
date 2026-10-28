//! Canonical signed-BLIP field representatives in field-sized capacity slots.
//! Unused capacity is not part of the encoding and may contain arbitrary bytes.
const std = @import("std");
pub const Small = FieldCodec(u32);
pub const Gold = FieldCodec(u64);
/// Experimental centered representatives in [-p/2, p/2], encoded as signed BLIP.
pub const CenteredGold = CenteredCodec(false);
pub const CenteredGoldFast = CenteredCodec(true);
fn CenteredCodec(comptime common_header: bool) type {
	return struct {
		pub const modulus: u64 = 18446744069414584321;
		pub const slot_bytes: usize = 9;
		pub fn encoded(bytes: []const u8, index: usize) []const u8 {
			const slot = bytes[index * @This().slot_bytes ..][0..@This().slot_bytes];
			return slot[0..if (slot[0] < 128) @as(usize, 1) else 1 + @as(usize, slot[0] & 31)];
		}
		/// Trusted algorithm-owned encodings only, as with the positive field codecs.
		pub fn read(bytes: []const u8, index: usize) u64 {
			const slot = bytes[index * @This().slot_bytes ..][0..@This().slot_bytes];
			if (slot[0] < 128) return slot[0];
			std.debug.assert(slot[0] >= 0x81 and slot[0] <= 0x88);
			const raw = std.mem.readInt(u64, slot[1..9], .little);
			const signed: i64 = if (common_header and slot[0] == 0x88) @bitCast(raw) else blk: {
				const shift: u6 = @intCast((8 - (slot[0] & 15)) * 8);
				break :blk @as(i64, @bitCast(raw << shift)) >> shift;
			};
			return @as(u64, @bitCast(signed)) +% (if (signed < 0) modulus else @as(u64, 0));
		}
		pub fn write(bytes: []u8, index: usize, value: u64) void {
			std.debug.assert(value < modulus);
			const slot = bytes[index * @This().slot_bytes ..][0..@This().slot_bytes];
			if (value < 128) { slot[0] = @intCast(value); return; }
			const negative = value > modulus / 2;
			const raw = if (negative) value -% modulus else value;
			const signless = if (negative) ~raw else raw;
			const len: u8 = @intCast((65 - @as(usize, @clz(signless)) + 7) / 8);
			slot[0] = 0x80 | len;
			std.mem.writeInt(u64, slot[1..9], raw, .little);
		}
		pub fn clear(bytes: []u8) void {
			std.debug.assert(bytes.len % @This().slot_bytes == 0);
			for (0..bytes.len / @This().slot_bytes) |i| @This().write(bytes, i, 0);
		}
	};
}
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

/// Algorithm-scoped representatives r+p. Each stored integer has the ordinary
/// canonical positive signed BLIP encoding 84 followed by four payload bytes.
pub fn Shifted(comptime modulus: u64) type {
	if (modulus < (1 << 23) or modulus > (1 << 30)) @compileError("shifted field must fit one canonical signed four-byte width");
	return struct {
		pub const slot_bytes: usize = 5;
		pub fn encoded(bytes: []const u8, index: usize) []const u8 {
			return bytes[index * 5 ..][0..5];
		}
		/// Validate once when admitting bytes from outside the trusted scope.
		pub fn isValid(bytes: []const u8) bool {
			if (bytes.len != 5 or bytes[0] != 0x84) return false;
			const value = std.mem.readInt(u32, bytes[1..5], .little);
			return value >= modulus and value < 2 * modulus;
		}
		pub fn read(bytes: []const u8, index: usize) u64 {
			const slot = @This().encoded(bytes, index);
			std.debug.assert(isValid(slot));
			return std.mem.readInt(u32, slot[1..5], .little);
		}
		pub fn write(bytes: []u8, index: usize, value: u64) void {
			std.debug.assert(value >= modulus and value < 2 * modulus);
			const slot = bytes[index * 5 ..][0..5];
			slot[0] = 0x84;
			std.mem.writeInt(u32, slot[1..5], @intCast(value), .little);
		}
		pub fn clear(bytes: []u8) void {
			std.debug.assert(bytes.len % 5 == 0);
			for (0..bytes.len / 5) |i| @This().write(bytes, i, modulus);
		}
	};
}

test "centered Goldilocks representatives match signed BLIP and both round trips" {
	inline for (.{ CenteredGold, CenteredGoldFast }) |Codec| try testCenteredCodec(Codec);
}

fn testCenteredCodec(comptime Codec: type) !void {
	const Mp = @import("bignum.zig").Mp;
	var expected = Mp.init(std.testing.allocator);
	defer expected.deinit();
	var storage: [3 * Codec.slot_bytes + 1]u8 = @splat(0xa5);
	const bytes = storage[1..];
	var rng = std.Random.DefaultPrng.init(0xCE47_E2ED);
	// Independent signed-value inputs exercise every payload boundary in both
	// directions; the field mapping uses i128 arithmetic to avoid wrap tricks.
	for (0..10050) |i| {
		const half: i64 = @intCast(Codec.modulus / 2);
		const signed: i64 = if (i < 48) blk: {
			const boundary = @as(i128, 1) << @as(u7, @intCast(7 + 8 * (i / 6)));
			const delta: i128 = @intCast(i % 3);
			const candidate = if (i % 6 < 3) boundary - 1 + delta else -boundary - 1 + delta;
			break :blk @intCast(std.math.clamp(candidate, -half, half));
		} else if (i == 48) 0 else if (i == 49) -1 else rng.random().intRangeAtMost(i64, -half, half);
		const residue: u64 = @intCast(@mod(@as(i128, signed), @as(i128, Codec.modulus)));
		try expected.setI64(signed);
		@memset(&storage, 0xa5);
		Codec.write(bytes, 1, residue);
		try std.testing.expectEqualSlices(u8, expected.bytes(), Codec.encoded(bytes, 1));
		@memset(bytes[Codec.slot_bytes + Codec.encoded(bytes, 1).len .. 2 * Codec.slot_bytes], 0xa5);
		try std.testing.expectEqual(residue, Codec.read(bytes, 1));
		// Start the reverse direction from independently encoded canonical bytes.
		@memcpy(bytes[Codec.slot_bytes..][0..expected.bytes().len], expected.bytes());
		const decoded = Codec.read(bytes, 1);
		Codec.write(bytes, 1, decoded);
		try std.testing.expectEqualSlices(u8, expected.bytes(), Codec.encoded(bytes, 1));
		try std.testing.expectEqual(@as(u8, 0xa5), storage[0]);
		try std.testing.expectEqual(@as(u8, 0xa5), bytes[Codec.slot_bytes - 1]);
		try std.testing.expectEqual(@as(u8, 0xa5), bytes[2 * Codec.slot_bytes]);
	}
	Codec.clear(bytes);
	for (0..3) |i| {
		try std.testing.expectEqual(@as(u64, 0), Codec.read(bytes, i));
		try std.testing.expectEqualSlices(u8, &.{0}, Codec.encoded(bytes, i));
	}
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

test "shifted representatives have one canonical width including field zero" {
	const Mp = @import("bignum.zig").Mp;
	var expected = Mp.init(std.testing.allocator);
	defer expected.deinit();
	var zero = Mp.init(std.testing.allocator);
	defer zero.deinit();
	try zero.setI64(0);
	inline for (.{ 998244353, 985661441 }) |prime| {
		const Codec = Shifted(prime);
		var storage: [3 * Codec.slot_bytes + 1]u8 = @splat(0xa5);
		const bytes = storage[1..];
		var rng = std.Random.DefaultPrng.init(0x5157);
		for (0..1010) |i| {
			const boundaries = [_]u64{ 0, 1, 127, 128, 32767, 32768, 8388607, 8388608, prime - 2, prime - 1 };
			const r = if (i < boundaries.len) boundaries[i] else rng.random().uintLessThan(u64, prime);
			try expected.addU64(&zero, r + prime);
			Codec.write(bytes, 1, r + prime);
			try std.testing.expectEqualSlices(u8, expected.bytes(), Codec.encoded(bytes, 1));
			try std.testing.expectEqual(@as(u64, r + prime), Codec.read(bytes, 1));
			try std.testing.expectEqual(@as(u8, 0x84), bytes[Codec.slot_bytes]);
			try std.testing.expectEqual(@as(u8, 0xa5), bytes[Codec.slot_bytes - 1]);
			try std.testing.expectEqual(@as(u8, 0xa5), bytes[2 * Codec.slot_bytes]);
		}
		Codec.clear(bytes);
		for (0..3) |i| try std.testing.expectEqual(@as(u64, prime), Codec.read(bytes, i));
	}
}

test "shifted scope validation classifies headers widths and range boundaries" {
	const Codec = Shifted(998244353);
	const values = [_]u32{ 0, 998244352, 998244353, 998244354, 1996488705, 1996488706, 2147483647 };
	const expected = [_]bool{ false, false, true, true, true, false, false };
	var actual: [values.len]bool = undefined;
	var bytes: [6]u8 = @splat(0);
	bytes[0] = 0x84;
	for (values, 0..) |v, i| {
		std.mem.writeInt(u32, bytes[1..5], v, .little);
		actual[i] = Codec.isValid(bytes[0..5]);
	}
	try std.testing.expectEqualSlices(bool, &expected, &actual);
	std.mem.writeInt(u32, bytes[1..5], 998244353, .little);
	const headers = [_]u8{ 0, 0x81, 0x82, 0x83, 0x84, 0x85, 0xc4, 0xa4, 0xff };
	var header_results: [headers.len]bool = undefined;
	for (headers, 0..) |h, i| { bytes[0] = h; header_results[i] = Codec.isValid(bytes[0..5]); }
	try std.testing.expectEqualSlices(bool, &.{ false, false, false, false, true, false, false, false, false }, &header_results);
	bytes[0] = 0x84;
	var width_results: [7]bool = undefined;
	for (0..7) |len| width_results[len] = Codec.isValid(bytes[0..len]);
	try std.testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true, false }, &width_results);
}
