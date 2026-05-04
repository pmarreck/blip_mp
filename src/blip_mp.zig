// blip_mp — BLIP-native multi-precision integers.
//
// Public Zig API. Re-exports the encoding primitives and the bignum type.
// Tests live in this file and in src/encoding.zig.

const std = @import("std");

pub const encoding = @import("encoding.zig");
pub const bignum = @import("bignum.zig");
pub const tier3 = @import("tier3.zig");
pub const fft = @import("fft.zig");
pub const bitwise = @import("bitwise.zig");
pub const sign = @import("sign.zig");
pub const combinatorial = @import("combinatorial.zig");
pub const roots = @import("roots.zig");
pub const symbols = @import("symbols.zig");
pub const primes = @import("primes.zig");
pub const scan = @import("scan.zig");
pub const Mp = bignum.Mp;

test {
	std.testing.refAllDecls(@This());
}
