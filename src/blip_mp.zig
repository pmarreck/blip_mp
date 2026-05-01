// blip_mp — BLIP-native multi-precision integers.
//
// Public Zig API. Re-exports the encoding primitives and the bignum type.
// Tests live in this file and in src/encoding.zig.

const std = @import("std");

pub const encoding = @import("encoding.zig");
pub const bignum = @import("bignum.zig");
pub const tier3 = @import("tier3.zig");
pub const Mp = bignum.Mp;

test {
	std.testing.refAllDecls(@This());
}
