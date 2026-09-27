//! Syntax guard for production arithmetic storage. Test fixtures may use typed
//! arrays as independent inputs/oracles; production declarations may not.
const std = @import("std");
const testing = std.testing;

fn wideInteger(name: []const u8) bool {
	if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return false;
	const bits = std.fmt.parseInt(u16, name[1..], 10) catch return false;
	return bits > 8;
}

fn rejects(source: [:0]const u8) !bool {
	var tree = try std.zig.Ast.parse(testing.allocator, source, .zig);
	defer tree.deinit(testing.allocator);
	if (tree.errors.len != 0) return error.InvalidAuditSource;
	var aliases = std.StringHashMap(void).init(testing.allocator);
	defer aliases.deinit();
	var changed = true;
	while (changed) {
		changed = false;
		for (tree.rootDecls()) |decl| {
			if (tree.nodeTag(decl) == .test_decl) continue;
			var i = tree.firstToken(decl);
			const end = tree.lastToken(decl);
			while (i + 3 <= end) : (i += 1) {
				if (tree.tokenTag(i) == .keyword_const and tree.tokenTag(i + 1) == .identifier and
					tree.tokenTag(i + 2) == .equal and tree.tokenTag(i + 3) == .identifier)
				{
					const value = tree.tokenSlice(i + 3);
					const name = tree.tokenSlice(i + 1);
					if ((wideInteger(value) or aliases.contains(value)) and !aliases.contains(name)) {
						try aliases.put(name, {});
						changed = true;
					}
				}
			}
		}
	}
	for (tree.rootDecls()) |decl| {
		if (tree.nodeTag(decl) == .test_decl) continue;
		var i = tree.firstToken(decl);
		const end = tree.lastToken(decl);
		while (i <= end) : (i += 1) {
			const tag = tree.tokenTag(i);
			const word = tree.tokenSlice(i);
			if (tag == .identifier and (std.mem.eql(u8, word, "bytesAsSlice") or std.mem.eql(u8, word, "sliceAsBytes"))) return true;
			var type_index: ?u32 = null;
			if (tag == .r_bracket) {
				var j = i + 1;
				while (j <= end) {
					const next = tree.tokenTag(j);
					if (next == .keyword_const or next == .keyword_volatile or next == .keyword_allowzero) {
						j += 1;
					} else if (next == .keyword_align) {
						j += 2;
						var depth: usize = 1;
						while (j <= end and depth > 0) : (j += 1) {
							if (tree.tokenTag(j) == .l_paren) depth += 1;
							if (tree.tokenTag(j) == .r_paren) depth -= 1;
						}
					} else break;
				}
				if (j <= end) type_index = j;
			} else if (tag == .identifier and i + 2 <= end and tree.tokenTag(i + 1) == .l_paren and
				(std.mem.eql(u8, word, "alloc") or std.mem.eql(u8, word, "alignedAlloc") or std.mem.eql(u8, word, "dupe")))
			{
				type_index = i + 2;
			}
			if (type_index) |j| {
				if (tree.tokenTag(j) == .identifier) {
					const name = tree.tokenSlice(j);
					if (wideInteger(name) or aliases.contains(name)) return true;
				}
			}
		}
	}
	return false;
}

test "storage audit classifies allowed byte arithmetic and forbidden limb storage" {
	const cases = [_][:0]const u8{
		"fn f(a: []u8) void {}",
		"fn f(a: []const u64) void {}",
		"const S = struct { a: [32]u64 };",
		"fn f() void { const a = allocator.alloc(u32, 4); }",
		"fn f(a: []u8) void { const v = std.mem.readInt(u64, a[0..8], .little); }",
		"fn f(a: []u8) void { const v = std.mem.bytesAsSlice(u64, a); }",
		"test \"oracle\" { var a: [4]u64 = undefined; }",
		"fn f(a: @Vector(2, u64)) void {}",
		"fn f() void { const a = allocator.alignedAlloc(u128, .@\"16\", 4); }",
		"const Word = u64; fn f(a: []Word) void {}",
		"fn f(a: []align(8) const u64) void {}",
		"// []u64 in a comment\nconst text = \"[]u64\";",
	};
	var rejected: u16 = 0;
	for (cases, 0..) |source, index| {
		if (try rejects(source)) rejected |= @as(u16, 1) << @intCast(index);
	}
	try testing.expectEqual(@as(u16, 0b011100101110), rejected);
}

test "production arithmetic has byte storage without limb array views" {
	const sources = .{
		.{ "bignum.zig", @embedFile("bignum.zig") },
		.{ "tier3.zig", @embedFile("tier3.zig") },
		.{ "fft.zig", @embedFile("fft.zig") },
		.{ "chunks.zig", @embedFile("chunks.zig") },
		.{ "fft_residue.zig", @embedFile("fft_residue.zig") },
	};
	inline for (sources) |entry| {
		if (try rejects(entry[1])) {
			std.debug.print("Forbidden production storage in {s}\n", .{entry[0]});
			return error.StoredLimbArray;
		}
	}
}
