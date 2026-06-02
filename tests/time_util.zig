//! Shared monotonic-clock helper for the benchmark + cross-check harnesses.
//! std.time.Timer was removed in Zig 0.16 and the replacement
//! (std.Io.Clock.now) needs an Io instance these exes don't otherwise want.
//! They already link libc (for std.heap.c_allocator / GMP parity), so we
//! call clock_gettime directly. Consolidated from three identical copies.

const std = @import("std");

pub const TimeSpec = extern struct { tv_sec: c_long, tv_nsec: c_long };
extern "c" fn clock_gettime(clk_id: c_int, tp: *TimeSpec) c_int;

/// Monotonic nanosecond timestamp via CLOCK_MONOTONIC.
pub fn nowNs() u64 {
	var ts: TimeSpec = undefined;
	_ = clock_gettime(@intFromEnum(std.posix.CLOCK.MONOTONIC), &ts);
	return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
