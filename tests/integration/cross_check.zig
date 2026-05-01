// Cross-validation: every blip_mp arithmetic result must equal the GMP
// reference for the same inputs. Catches any "looks right" bug that unit
// tests might have missed.
//
// Test plan: for each (op, bit_width), generate N random signed value pairs,
// compute blip_mp result and GMP result, normalise both to (sign, magnitude
// bytes LE), assert byte-for-byte equality. On any mismatch, print the
// inputs and both results in hex and exit nonzero. Run as part of `./test`.

const std = @import("std");
const blip_mp = @import("blip_mp");
const Mp = blip_mp.Mp;

// ── GMP extern declarations ──────────────────────────────────────────────────
// gmp.h does `#define mpz_add __gmpz_add` etc. — we declare the underlying
// symbols directly. mpz_t is `struct __mpz_struct[1]` in C; we model it as
// the equivalent Zig extern struct. `_mp_d` points to mp_limb_t which is u64
// on aarch64-darwin / x86_64-linux 64-bit ABIs.

const Limb = u64;
const mpz_struct = extern struct {
	_mp_alloc: c_int,
	_mp_size: c_int,
	_mp_d: ?[*]Limb,
};
const mpz_t = mpz_struct;

extern "c" fn __gmpz_init(rop: *mpz_t) void;
extern "c" fn __gmpz_clear(rop: *mpz_t) void;
extern "c" fn __gmpz_set_si(rop: *mpz_t, op: c_long) void;
extern "c" fn __gmpz_neg(rop: *mpz_t, op: *const mpz_t) void;
extern "c" fn __gmpz_add(rop: *mpz_t, op1: *const mpz_t, op2: *const mpz_t) void;
extern "c" fn __gmpz_sub(rop: *mpz_t, op1: *const mpz_t, op2: *const mpz_t) void;
extern "c" fn __gmpz_mul(rop: *mpz_t, op1: *const mpz_t, op2: *const mpz_t) void;
extern "c" fn __gmpz_import(
	rop: *mpz_t,
	count: usize,
	order: c_int,
	size: usize,
	endian: c_int,
	nails: usize,
	op: [*]const u8,
) void;
extern "c" fn __gmpz_export(
	rop: ?[*]u8,
	countp: *usize,
	order: c_int,
	size: usize,
	endian: c_int,
	nails: usize,
	op: *const mpz_t,
) ?[*]u8;
extern "c" fn __gmpz_get_str(str: ?[*]u8, base: c_int, op: *const mpz_t) [*]u8;
extern "c" fn __gmpz_sizeinbase(op: *const mpz_t, base: c_int) usize;

// ── Helpers ──────────────────────────────────────────────────────────────────

const Sign = enum { neg, zero, pos };

const NormalForm = struct {
	sign: Sign,
	magnitude: []u8, // LE bytes, no trailing zeros (canonical magnitude)
	allocator: std.mem.Allocator,

	fn deinit(self: *NormalForm) void {
		self.allocator.free(self.magnitude);
	}
};

/// Convert a signed two's-complement BLIP-encoded slice into the canonical
/// (sign, unsigned magnitude LE bytes) form used for cross-comparison.
fn normalizeBlip(blip: []const u8, allocator: std.mem.Allocator) !NormalForm {
	if (blip.len == 0) return error.EmptyInput;
	// Get payload bytes (LE two's-complement).
	const b0 = blip[0];
	const payload: []const u8 = if (b0 < 0x80) blip[0..1] else blk: {
		const hdr = try blip_mp.tier3.parseHeader(blip);
		break :blk blip[hdr.bytes_consumed .. hdr.bytes_consumed + hdr.L];
	};
	// Determine sign from high bit of high byte.
	const high_bit_set = (payload[payload.len - 1] & 0x80) != 0;
	if (b0 < 0x80) {
		// Immediate: 0..127, always non-negative.
		const sign: Sign = if (b0 == 0) .zero else .pos;
		const mag = try allocator.dupe(u8, blip[0..1]);
		const trimmed = trimMag(mag);
		return .{ .sign = sign, .magnitude = mag[0..trimmed], .allocator = allocator };
	}
	if (!high_bit_set) {
		// Positive length-prefixed: payload IS the magnitude.
		const mag = try allocator.dupe(u8, payload);
		const trimmed = trimMag(mag);
		return .{ .sign = if (trimmed == 0) .zero else .pos, .magnitude = mag[0..trimmed], .allocator = allocator };
	}
	// Negative: magnitude = -value = (~payload + 1) interpreted as unsigned.
	const mag = try allocator.dupe(u8, payload);
	negateInPlace(mag);
	const trimmed = trimMag(mag);
	return .{ .sign = if (trimmed == 0) .zero else .neg, .magnitude = mag[0..trimmed], .allocator = allocator };
}

fn negateInPlace(buf: []u8) void {
	var carry: u16 = 1;
	for (buf) |*p| {
		const v: u16 = @as(u16, ~p.*) + carry;
		p.* = @truncate(v);
		carry = v >> 8;
	}
}

fn trimMag(mag: []u8) usize {
	var n = mag.len;
	while (n > 0 and mag[n - 1] == 0) n -= 1;
	return n;
}

/// Convert a GMP mpz_t into the same (sign, magnitude LE bytes) form.
/// `mpz_sgn` and `mpz_size` are static-inline macros in gmp.h (not exported
/// library symbols), so we read `_mp_size` directly.
fn normalizeGmp(z: *const mpz_t, allocator: std.mem.Allocator) !NormalForm {
	const ms = z._mp_size;
	if (ms == 0) {
		return .{ .sign = .zero, .magnitude = try allocator.alloc(u8, 0), .allocator = allocator };
	}
	const sign: Sign = if (ms > 0) .pos else .neg;
	const limbs: usize = @intCast(if (ms > 0) ms else -ms);
	const cap = limbs * @sizeOf(Limb);
	const buf = try allocator.alloc(u8, cap);
	var written: usize = 0;
	_ = __gmpz_export(buf.ptr, &written, -1, 1, 0, 0, z); // LSB first, byte size, native endian
	const trimmed = trimMag(buf[0..written]);
	return .{ .sign = sign, .magnitude = buf[0..trimmed], .allocator = allocator };
}

/// Compare two NormalForms; returns true iff they encode the same value.
fn nfEqual(a: NormalForm, b: NormalForm) bool {
	if (a.sign != b.sign) return false;
	if (a.magnitude.len != b.magnitude.len) return false;
	return std.mem.eql(u8, a.magnitude, b.magnitude);
}

/// Print a NormalForm as a hex string to stderr (via std.debug.print).
fn nfPrint(nf: NormalForm) void {
	const sign_char: u8 = switch (nf.sign) {
		.neg => '-',
		.zero => '0',
		.pos => '+',
	};
	std.debug.print("[{c}]", .{sign_char});
	if (nf.magnitude.len == 0) {
		std.debug.print("0", .{});
		return;
	}
	// High byte first for readability (BE).
	var i: usize = nf.magnitude.len;
	while (i > 0) {
		i -= 1;
		std.debug.print("{x:0>2}", .{nf.magnitude[i]});
	}
}

// ── Test runners ─────────────────────────────────────────────────────────────

const Op = enum { add, sub, mul };

fn opName(op: Op) []const u8 {
	return switch (op) {
		.add => "add",
		.sub => "sub",
		.mul => "mul",
	};
}

fn runOp(blip_r: *Mp, blip_a: *const Mp, blip_b: *const Mp, op: Op) !void {
	switch (op) {
		.add => try blip_r.add(blip_a, blip_b),
		.sub => try blip_r.sub(blip_a, blip_b),
		.mul => try blip_r.mul(blip_a, blip_b),
	}
}

fn gmpOp(gmp_r: *mpz_t, gmp_a: *const mpz_t, gmp_b: *const mpz_t, op: Op) void {
	switch (op) {
		.add => __gmpz_add(gmp_r, gmp_a, gmp_b),
		.sub => __gmpz_sub(gmp_r, gmp_a, gmp_b),
		.mul => __gmpz_mul(gmp_r, gmp_a, gmp_b),
	}
}

/// Set both a blip_mp Mp and a GMP mpz_t to the same value. For small values
/// (i64 range) uses set_si; for large uses byte import.
fn setBoth(
	mp: *Mp,
	gmp: *mpz_t,
	allocator: std.mem.Allocator,
	rng: std.Random,
	bits: usize,
) !void {
	if (bits <= 60) {
		// Use a bit-width-bounded i64 to stay well clear of overflow.
		const mask: i64 = if (bits >= 63) std.math.maxInt(i64) else (@as(i64, 1) << @intCast(bits)) - 1;
		const raw = rng.int(i64);
		const value = (raw & mask) * if (rng.boolean()) @as(i64, 1) else @as(i64, -1);
		try mp.setI64(value);
		__gmpz_set_si(gmp, @intCast(value));
		return;
	}
	// Large path: random byte payload, random sign. Use the FULL byte_count
	// without trimming — trimming would expose new high bytes whose high
	// bit might be set, which GMP imports as unsigned (positive) but BLIP's
	// setBytes interprets as signed two's-complement (negative). Keeping
	// the original byte_count with the masked high byte ensures both
	// implementations see exactly the same value.
	const byte_count = (bits + 7) / 8;
	const payload = try allocator.alloc(u8, byte_count);
	defer allocator.free(payload);
	for (payload) |*p| p.* = rng.int(u8);
	payload[byte_count - 1] &= 0x7F; // keep magnitude positive (and < 2^(bits-1))

	// Skip negative for the unlikely all-zero case (no canonical -0).
	const all_zero = blk: {
		for (payload) |b| if (b != 0) break :blk false;
		break :blk true;
	};
	const negative = !all_zero and rng.boolean();

	// Import to GMP (unsigned magnitude, then maybe negate).
	__gmpz_import(gmp, byte_count, -1, 1, 0, 0, payload.ptr);
	if (negative) __gmpz_neg(gmp, gmp);

	// Build BLIP encoding for the same value (signed two's-comp). High bit
	// of the high byte is guaranteed clear by the &0x7F mask above, so the
	// payload bytes ARE a valid signed-positive two's-comp encoding for L=byte_count.
	const blip_buf = try allocator.alloc(u8, byte_count + 16);
	defer allocator.free(blip_buf);
	if (!negative) {
		const hdr_len = try blip_mp.tier3.writeHeader(blip_buf, byte_count);
		@memcpy(blip_buf[hdr_len .. hdr_len + byte_count], payload);
		try mp.setBytes(blip_buf[0 .. hdr_len + byte_count]);
	} else {
		// Negate: payload bytes -> ~payload + 1 of length byte_count. After
		// negation the high bit of the high byte is set (since the magnitude
		// is in (0, 2^(bits-1))), giving a valid signed-negative two's-comp.
		const neg_payload = try allocator.alloc(u8, byte_count);
		defer allocator.free(neg_payload);
		@memcpy(neg_payload, payload);
		negateInPlace(neg_payload);
		const hdr_len = try blip_mp.tier3.writeHeader(blip_buf, byte_count);
		@memcpy(blip_buf[hdr_len .. hdr_len + byte_count], neg_payload);
		try mp.setBytes(blip_buf[0 .. hdr_len + byte_count]);
	}
}

const TestSpec = struct { op: Op, bits: usize, iters: usize };

fn iterCount(op: Op, bits: usize) usize {
	// Mul scales as O(n^2) or O(n^1.58); cap to keep wall-clock reasonable.
	if (op == .mul) {
		if (bits <= 256) return 200;
		if (bits <= 1024) return 100;
		if (bits <= 4096) return 50;
		return 20;
	}
	// add/sub are cheap.
	if (bits <= 1024) return 200;
	if (bits <= 8192) return 100;
	return 50;
}

const SIZES = [_]usize{ 8, 16, 32, 60, 64, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192 };
const OPS = [_]Op{ .add, .sub, .mul };

pub fn main() !u8 {
	const allocator = std.heap.c_allocator;
	var rng_state = std.Random.DefaultPrng.init(0xCAFEBEEFDEADCC01);
	const rng = rng_state.random();

	std.debug.print("=== blip_mp vs GMP cross-validation ===\n", .{});
	std.debug.print("Sizes: {any}\n", .{SIZES});
	std.debug.print("Ops: add, sub, mul\n\n", .{});

	var total_checks: usize = 0;
	var total_failures: usize = 0;

	var blip_a = Mp.init(allocator);
	defer blip_a.deinit();
	var blip_b = Mp.init(allocator);
	defer blip_b.deinit();
	var blip_r = Mp.init(allocator);
	defer blip_r.deinit();

	var gmp_a: mpz_t = undefined;
	var gmp_b: mpz_t = undefined;
	var gmp_r: mpz_t = undefined;
	__gmpz_init(&gmp_a);
	__gmpz_init(&gmp_b);
	__gmpz_init(&gmp_r);
	defer {
		__gmpz_clear(&gmp_a);
		__gmpz_clear(&gmp_b);
		__gmpz_clear(&gmp_r);
	}

	for (OPS) |op| {
		for (SIZES) |bits| {
			const iters = iterCount(op, bits);
			var failures: usize = 0;
			for (0..iters) |i| {
				try setBoth(&blip_a, &gmp_a, allocator, rng, bits);
				try setBoth(&blip_b, &gmp_b, allocator, rng, bits);

				// Sanity: blip and gmp must agree on input values BEFORE the op.
				var nf_blip_a = try normalizeBlip(blip_a.bytes(), allocator);
				defer nf_blip_a.deinit();
				var nf_gmp_a = try normalizeGmp(&gmp_a, allocator);
				defer nf_gmp_a.deinit();
				if (!nfEqual(nf_blip_a, nf_gmp_a)) {
					std.debug.print("\nINPUT MISMATCH (a): op={s} bits={d} iter={d}\n", .{ opName(op), bits, i });
					std.debug.print("  blip a = ", .{});
					nfPrint(nf_blip_a);
					std.debug.print("\n  gmp  a = ", .{});
					nfPrint(nf_gmp_a);
					std.debug.print("\n", .{});
					failures += 1;
					total_checks += 1;
					continue;
				}
				var nf_blip_b = try normalizeBlip(blip_b.bytes(), allocator);
				defer nf_blip_b.deinit();
				var nf_gmp_b = try normalizeGmp(&gmp_b, allocator);
				defer nf_gmp_b.deinit();
				if (!nfEqual(nf_blip_b, nf_gmp_b)) {
					std.debug.print("\nINPUT MISMATCH (b): op={s} bits={d} iter={d}\n", .{ opName(op), bits, i });
					std.debug.print("  blip b = ", .{});
					nfPrint(nf_blip_b);
					std.debug.print("\n  gmp  b = ", .{});
					nfPrint(nf_gmp_b);
					std.debug.print("\n", .{});
					failures += 1;
					total_checks += 1;
					continue;
				}

				try runOp(&blip_r, &blip_a, &blip_b, op);
				gmpOp(&gmp_r, &gmp_a, &gmp_b, op);

				var nf_blip = try normalizeBlip(blip_r.bytes(), allocator);
				defer nf_blip.deinit();
				var nf_gmp = try normalizeGmp(&gmp_r, allocator);
				defer nf_gmp.deinit();

				if (!nfEqual(nf_blip, nf_gmp)) {
					failures += 1;
					if (failures <= 3) {
						std.debug.print("\nMISMATCH: op={s} bits={d} iter={d}\n", .{ opName(op), bits, i });
						std.debug.print("  a    = ", .{});
						nfPrint(nf_blip_a);
						std.debug.print("\n  b    = ", .{});
						nfPrint(nf_blip_b);
						std.debug.print("\n  blip = ", .{});
						nfPrint(nf_blip);
						std.debug.print("\n  gmp  = ", .{});
						nfPrint(nf_gmp);
						std.debug.print("\n", .{});
					}
				}
				total_checks += 1;
			}
			total_failures += failures;
			const status: []const u8 = if (failures == 0) "PASS" else "FAIL";
			std.debug.print("  {s} op={s:<3} bits={d:>5} iters={d:>4} fails={d}\n", .{ status, opName(op), bits, iters, failures });
		}
	}

	std.debug.print("\n=== Summary ===\n", .{});
	std.debug.print("Total checks: {d}\n", .{total_checks});
	std.debug.print("Failures:     {d}\n", .{total_failures});
	if (total_failures != 0) {
		std.debug.print("\nFAIL: {d} mismatches\n", .{total_failures});
		return 1;
	}
	std.debug.print("\nALL PASS — blip_mp results match GMP across {d} random tests.\n", .{total_checks});
	return 0;
}
