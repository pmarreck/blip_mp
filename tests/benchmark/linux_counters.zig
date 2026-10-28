//! Linux perf group decoding. Counter IDs identify events independently of order.
const std = @import("std");

pub const Snapshot = struct {
	cycles: u64,
	instructions: u64,
	enabled_ns: u64,
	running_ns: u64,
};

pub fn decode(raw: []const u64, cycles_id: u64, instructions_id: u64) !Snapshot {
	if (raw.len != 7 or raw[0] != 2 or cycles_id == instructions_id) return error.InvalidCounters;
	const cycles, const instructions = if (raw[4] == cycles_id and raw[6] == instructions_id)
		.{ raw[3], raw[5] }
	else if (raw[6] == cycles_id and raw[4] == instructions_id)
		.{ raw[5], raw[3] }
	else
		return error.InvalidCounters;
	return .{ .cycles = cycles, .instructions = instructions, .enabled_ns = raw[1], .running_ns = raw[2] };
}

pub fn difference(current: Snapshot, previous: Snapshot) !Snapshot {
	var delta: Snapshot = undefined;
	inline for (std.meta.fields(Snapshot)) |field| {
		@field(delta, field.name) = std.math.sub(u64, @field(current, field.name), @field(previous, field.name)) catch return error.InvalidCounters;
	}
	if (delta.enabled_ns == 0 or delta.cycles == 0 or delta.instructions == 0) return error.EmptyCounters;
	if (delta.enabled_ns != delta.running_ns) return error.MultiplexedCounters;
	return delta;
}

pub const Event = enum { cycles, instructions };

const linux = std.os.linux;
pub fn attributes(event: Event, group_fd: i32) linux.perf_event_attr {
	const total_time_enabled = 1 << 0;
	const total_time_running = 1 << 1;
	const event_id = 1 << 2;
	const group = 1 << 3;
	return .{
		.type = .HARDWARE,
		.config = @intFromEnum(if (event == .cycles) linux.PERF.COUNT.HW.CPU_CYCLES else linux.PERF.COUNT.HW.INSTRUCTIONS),
		.read_format = total_time_enabled | total_time_running | event_id | group,
		.flags = .{ .disabled = group_fd == -1, .exclude_kernel = true, .exclude_hv = true },
	};
}
pub fn checked(result: usize) !usize {
	if (linux.errno(result) != .SUCCESS) return error.CounterUnavailable;
	return result;
}

pub const Native = struct {
	last_errno: linux.E = .SUCCESS,
	fn check(self: *Native, result: usize) !usize {
		self.last_errno = linux.errno(result);
		return checked(result);
	}
	pub fn open(self: *Native, event: Event, group_fd: i32) !i32 {
		var attr = attributes(event, group_fd);
		return @intCast(try self.check(linux.perf_event_open(&attr, 0, -1, group_fd, linux.PERF.FLAG.FD_CLOEXEC)));
	}
	pub fn id(self: *Native, fd: i32) !u64 {
		var result: u64 = 0;
		_ = try self.check(linux.ioctl(fd, linux.PERF.EVENT_IOC.ID, @intFromPtr(&result)));
		return result;
	}
	pub fn close(_: *Native, fd: i32) void { _ = linux.close(fd); }
	pub fn enable(self: *Native, fd: i32) !void {
		_ = try self.check(linux.ioctl(fd, linux.PERF.EVENT_IOC.ENABLE, linux.PERF.IOC_FLAG_GROUP));
	}
	pub fn disable(self: *Native, fd: i32) !void {
		_ = try self.check(linux.ioctl(fd, linux.PERF.EVENT_IOC.DISABLE, linux.PERF.IOC_FLAG_GROUP));
	}
	pub fn read(self: *Native, fd: i32) ![7]u64 {
		var raw: [7]u64 = undefined;
		const bytes = std.mem.asBytes(&raw);
		const count = try self.check(linux.read(fd, bytes.ptr, bytes.len));
		if (count != bytes.len) return error.InvalidCounters;
		return raw;
	}
};

test "native counter attributes select user thread events and grouped identified reads" {
	for (std.enums.values(Event)) |event| {
		const attr = attributes(event, if (event == .cycles) -1 else 10);
		try std.testing.expectEqual(linux.PERF.TYPE.HARDWARE, attr.type);
		try std.testing.expectEqual(@as(u64, if (event == .cycles) 0 else 1), attr.config);
		try std.testing.expectEqual(@as(u64, 15), attr.read_format);
		try std.testing.expectEqual(event == .cycles, attr.flags.disabled);
		try std.testing.expect(attr.flags.exclude_kernel and attr.flags.exclude_hv);
		try std.testing.expect(!attr.flags.exclude_user and !attr.flags.inherit);
	}
}

test "native syscall results preserve success and reject every Linux errno" {
	for ([_]usize{ 0, 10, 56, 4096 }) |value| try std.testing.expectEqual(value, try checked(value));
	for (1..4096) |errno| {
		const raw: usize = @bitCast(-@as(isize, @intCast(errno)));
		try std.testing.expectError(error.CounterUnavailable, checked(raw));
	}
}

pub fn Group(comptime Backend: type) type {
	return struct {
		const Self = @This();
		backend: *Backend,
		leader: i32,
		follower: i32,
		cycles_id: u64,
		instructions_id: u64,
		closed: bool = false,
		state: enum { idle, running, failed } = .idle,
		previous: Snapshot = .{ .cycles = 0, .instructions = 0, .enabled_ns = 0, .running_ns = 0 },
		pub fn init(backend: *Backend) !Self {
			const leader = try backend.open(.cycles, -1);
			errdefer backend.close(leader);
			const follower = try backend.open(.instructions, leader);
			errdefer backend.close(follower);
			return .{ .backend = backend, .leader = leader, .follower = follower,
				.cycles_id = try backend.id(leader), .instructions_id = try backend.id(follower) };
		}
		pub fn deinit(self: *Self) void {
			if (self.closed) return;
			self.backend.close(self.follower);
			self.backend.close(self.leader);
			self.closed = true;
		}
		pub fn begin(self: *Self) !void {
			if (self.closed or self.state != .idle) return error.InvalidState;
			self.state = .failed;
			try self.backend.enable(self.leader);
			self.state = .running;
		}
		pub fn finish(self: *Self) !Snapshot {
			if (self.closed or self.state != .running) return error.InvalidState;
			self.state = .failed;
			try self.backend.disable(self.leader);
			const raw = try self.backend.read(self.leader);
			const current = try decode(&raw, self.cycles_id, self.instructions_id);
			const delta = try difference(current, self.previous);
			self.previous = current;
			self.state = .idle;
			return delta;
		}
	};
}

pub const Fake = struct {
	fail_at: usize = 0,
	calls: usize = 0,
	live: [2]bool = .{ false, false },
	closed: usize = 0,
	active: bool = false,
	reads: u64 = 0,
	fn step(self: *Fake) !void {
		self.calls += 1;
		if (self.calls == self.fail_at) return error.Injected;
	}
	pub fn open(self: *Fake, event: Event, group_fd: i32) !i32 {
		try self.step();
		const index = @intFromEnum(event);
		try std.testing.expectEqual(@as(i32, if (event == .cycles) -1 else 10), group_fd);
		self.live[index] = true;
		return 10 + @as(i32, @intCast(index));
	}
	pub fn id(self: *Fake, fd: i32) !u64 {
		try self.step();
		return @intCast(fd + 100);
	}
	pub fn close(self: *Fake, fd: i32) void {
		const index: usize = @intCast(fd - 10);
		std.debug.assert(self.live[index]);
		self.live[index] = false;
		self.closed += 1;
		if (fd == 10) self.active = false;
	}
	pub fn enable(self: *Fake, fd: i32) !void {
		try self.step();
		try std.testing.expectEqual(@as(i32, 10), fd);
		try std.testing.expect(!self.active);
		self.active = true;
	}
	pub fn disable(self: *Fake, fd: i32) !void {
		try self.step();
		try std.testing.expectEqual(@as(i32, 10), fd);
		try std.testing.expect(self.active);
		self.active = false;
	}
	pub fn read(self: *Fake, fd: i32) ![7]u64 {
		try self.step();
		try std.testing.expectEqual(@as(i32, 10), fd);
		try std.testing.expect(!self.active);
		self.reads += 1;
		return .{ 2, 10 * self.reads, 10 * self.reads, 40 * self.reads, 110, 20 * self.reads, 111 };
	}
};

test "sampling validates transitions and subtracts cumulative counts" {
	var backend: Fake = .{};
	var group = try Group(Fake).init(&backend);
	defer group.deinit();
	try std.testing.expectError(error.InvalidState, group.finish());
	for (0..2) |_| {
		try group.begin();
		try std.testing.expectError(error.InvalidState, group.begin());
		try std.testing.expectEqualDeep(Snapshot{ .cycles = 40, .instructions = 20, .enabled_ns = 10, .running_ns = 10 }, try group.finish());
	}
	group.deinit();
	try std.testing.expectError(error.InvalidState, group.begin());
	try std.testing.expectError(error.InvalidState, group.finish());
}

test "sampling syscall errors invalidate the group and cleanup stops it" {
	for (5..8) |failure| {
		var backend: Fake = .{ .fail_at = failure };
		var group = try Group(Fake).init(&backend);
		if (failure == 5) {
			try std.testing.expectError(error.Injected, group.begin());
		} else {
			try group.begin();
			try std.testing.expectError(error.Injected, group.finish());
		}
		try std.testing.expectError(error.InvalidState, group.begin());
		try std.testing.expectError(error.InvalidState, group.finish());
		group.deinit();
		try std.testing.expect(!backend.active);
		try std.testing.expectEqual([2]bool{ false, false }, backend.live);
	}
}

test "counter group releases partial opens and closes successful groups once" {
	for (1..5) |failure| {
		var backend: Fake = .{ .fail_at = failure };
		try std.testing.expectError(error.Injected, Group(Fake).init(&backend));
		try std.testing.expectEqual([2]bool{ false, false }, backend.live);
		try std.testing.expectEqual(@min(failure - 1, 2), backend.closed);
	}
	var backend: Fake = .{};
	var group = try Group(Fake).init(&backend);
	try std.testing.expectEqual([2]bool{ true, true }, backend.live);
	group.deinit();
	group.deinit();
	try std.testing.expectEqual(@as(usize, 2), backend.closed);
	try std.testing.expectEqual([2]bool{ false, false }, backend.live);
}

test "counter deltas exclude previous samples and reject multiplexed or empty work" {
	const previous: Snapshot = .{ .cycles = 100, .instructions = 80, .enabled_ns = 20, .running_ns = 20 };
	const current: Snapshot = .{ .cycles = 400, .instructions = 200, .enabled_ns = 100, .running_ns = 100 };
	try std.testing.expectEqualDeep(Snapshot{ .cycles = 300, .instructions = 120, .enabled_ns = 80, .running_ns = 80 }, try difference(current, previous));
	var changed = current;
	changed.running_ns = 90;
	try std.testing.expectError(error.MultiplexedCounters, difference(changed, previous));
	changed = current;
	changed.instructions = previous.instructions;
	try std.testing.expectError(error.EmptyCounters, difference(changed, previous));
	try std.testing.expectError(error.EmptyCounters, difference(previous, previous));
	inline for (std.meta.fields(Snapshot)) |field| {
		changed = current;
		@field(changed, field.name) = @field(previous, field.name) - 1;
		try std.testing.expectError(error.InvalidCounters, difference(changed, previous));
	}
}

test "counter group IDs select cycles and instructions in either order" {
	const expected: Snapshot = .{ .cycles = 400, .instructions = 200, .enabled_ns = 100, .running_ns = 100 };
	try std.testing.expectEqualDeep(expected, try decode(&.{ 2, 100, 100, 400, 17, 200, 29 }, 17, 29));
	try std.testing.expectEqualDeep(expected, try decode(&.{ 2, 100, 100, 200, 29, 400, 17 }, 17, 29));
}

test "counter group rejects truncated, missing, duplicate and unrelated events" {
	const cases = [_][]const u64{
		&.{},
		&.{ 2, 100, 100, 400, 17, 200 },
		&.{ 1, 100, 100, 400, 17 },
		&.{ 2, 100, 100, 400, 17, 200, 17 },
		&.{ 2, 100, 100, 400, 17, 200, 30 },
		&.{ 2, 100, 100, 400, 17, 200, 29, 99 },
	};
	for (cases) |raw| try std.testing.expectError(error.InvalidCounters, decode(raw, 17, 29));
	try std.testing.expectError(error.InvalidCounters, decode(&.{ 2, 100, 100, 400, 17, 200, 17 }, 17, 17));
}
