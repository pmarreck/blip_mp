//! Shared test-only assertion helpers for the blip_mp unit tests.
//! Consolidates wrappers that were duplicated across sign/gcd/roots/
//! bitwise/combinatorial. Not referenced by any production code path.

const std = @import("std");
const bignum = @import("bignum.zig");
const Mp = bignum.Mp;

/// Assert that an Mp decodes to the expected signed value (via getI64).
pub fn expectI64(want: i64, got: *const Mp) !void {
	try std.testing.expectEqual(want, try got.getI64());
}

/// Assert that an Mp decodes to the expected unsigned value (via getU64).
pub fn expectU64(want: u64, got: *const Mp) !void {
	try std.testing.expectEqual(want, try got.getU64());
}
