// c_api.zig — public C FFI for blip_mp.
//
// This is the layer that downstream C/Rust/Lua/Python consumers link
// against. The exported symbols mirror `include/blip_mp.h`. All internal
// allocations go through `std.heap.c_allocator` so the lifetime model
// matches libc (callers may freely mix blip_mp handles with their own
// malloc'd memory).
//
// Error mapping: Zig errors are flattened into the small set of
// BLIP_MP_ERR_* integer codes declared in the header. Unknown errors fall
// back to BLIP_MP_ERR_INVALID_INPUT (paranoid default).

const std = @import("std");
const blip_mp = @import("blip_mp.zig");
const Mp = blip_mp.Mp;

const allocator = std.heap.c_allocator;

// Public error codes — kept in lockstep with include/blip_mp.h.
pub const BLIP_MP_OK: c_int = 0;
pub const BLIP_MP_ERR_DIVISION_BY_ZERO: c_int = 1;
pub const BLIP_MP_ERR_OUT_OF_MEMORY: c_int = 2;
pub const BLIP_MP_ERR_NOT_IMPLEMENTED: c_int = 3;
pub const BLIP_MP_ERR_INVALID_INPUT: c_int = 4;
pub const BLIP_MP_ERR_OUT_OF_RANGE: c_int = 5;
pub const BLIP_MP_ERR_NO_INVERSE: c_int = 6;

/// Translate a Zig error from any of `Mp`'s error sets into the C code
/// surface. Centralised so every export uses the same mapping rules.
fn mapError(err: anyerror) c_int {
	return switch (err) {
		error.DivisionByZero => BLIP_MP_ERR_DIVISION_BY_ZERO,
		error.OutOfMemory => BLIP_MP_ERR_OUT_OF_MEMORY,
		error.NotImplementedTier3, error.NegativeExponentNotSupported => BLIP_MP_ERR_NOT_IMPLEMENTED,
		error.UnsignedTooLarge, error.OutputBufferTooSmall, error.TierOverflow => BLIP_MP_ERR_OUT_OF_RANGE,
		error.SentinelValue, error.ValueIsNegative => BLIP_MP_ERR_OUT_OF_RANGE,
		error.BufferTooSmall, error.UnexpectedEndOfInput, error.OverlongEncoding => BLIP_MP_ERR_INVALID_INPUT,
		else => BLIP_MP_ERR_INVALID_INPUT,
	};
}

// --- Lifecycle ---------------------------------------------------------

export fn blip_mp_create() ?*Mp {
	const mp = allocator.create(Mp) catch return null;
	mp.* = Mp.init(allocator);
	return mp;
}

export fn blip_mp_destroy(mp: ?*Mp) void {
	if (mp) |m| {
		m.deinit();
		allocator.destroy(m);
	}
}

// --- Setters / getters -------------------------------------------------

export fn blip_mp_set_i64(mp: *Mp, value: i64) c_int {
	mp.setI64(value) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_get_i64(mp: *const Mp, out: *i64) c_int {
	const v = mp.getI64() catch |e| return mapError(e);
	out.* = v;
	return BLIP_MP_OK;
}

export fn blip_mp_set_u64(mp: *Mp, value: u64) c_int {
	mp.setU64(value) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_get_u64(mp: *const Mp, out: *u64) c_int {
	const v = mp.getU64() catch |e| return mapError(e);
	out.* = v;
	return BLIP_MP_OK;
}

export fn blip_mp_set_bytes(mp: *Mp, bytes: [*]const u8, len: usize) c_int {
	const slice = bytes[0..len];
	mp.setBytes(slice) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_byte_len(mp: *const Mp) usize {
	return mp.bytes().len;
}

export fn blip_mp_bytes(mp: ?*const Mp) ?[*]const u8 {
	if (mp) |m| {
		const b = m.bytes();
		if (b.len == 0) return null;
		return b.ptr;
	}
	return null;
}

// --- Comparison / sign --------------------------------------------------

export fn blip_mp_cmp(a: *const Mp, b: *const Mp) c_int {
	// Mp.cmp is now error-free and tier-3-aware (sign-first dispatch +
	// byte-level magnitude comparison; no i64 overflow risk).
	return switch (a.cmp(b)) {
		.lt => -1,
		.eq => 0,
		.gt => 1,
	};
}

export fn blip_mp_sign(mp: *const Mp) c_int {
	return @intCast(mp.cachedSign());
}

export fn blip_mp_is_zero(mp: *const Mp) c_int {
	return if (mp.cachedSign() == 0) 1 else 0;
}

// --- Arithmetic --------------------------------------------------------

export fn blip_mp_add(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	r.add(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_sub(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	r.sub(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_mul(r: *Mp, a: *const Mp, b: *const Mp) c_int {
	r.mul(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_div(q: *Mp, a: *const Mp, b: *const Mp) c_int {
	q.div(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_mod(rem: *Mp, a: *const Mp, b: *const Mp) c_int {
	rem.mod(a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_div_mod(q: *Mp, rem: *Mp, a: *const Mp, b: *const Mp) c_int {
	Mp.divMod(q, rem, a, b) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_powm(r: *Mp, base: *const Mp, exp: *const Mp, m: *const Mp) c_int {
	r.powm(base, exp, m) catch |e| return mapError(e);
	return BLIP_MP_OK;
}

export fn blip_mp_inv_mod(r: *Mp, a: *const Mp, m: *const Mp) c_int {
	const ok = r.invMod(a, m) catch |e| return mapError(e);
	return if (ok) BLIP_MP_OK else BLIP_MP_ERR_NO_INVERSE;
}

// Force the linker to retain every exported symbol when compiled as part
// of a library (otherwise ReleaseFast may strip unreferenced exports).
comptime {
	_ = blip_mp_create;
	_ = blip_mp_set_u64;
	_ = blip_mp_get_u64;
	_ = blip_mp_destroy;
	_ = blip_mp_set_i64;
	_ = blip_mp_get_i64;
	_ = blip_mp_set_bytes;
	_ = blip_mp_byte_len;
	_ = blip_mp_bytes;
	_ = blip_mp_cmp;
	_ = blip_mp_sign;
	_ = blip_mp_is_zero;
	_ = blip_mp_add;
	_ = blip_mp_sub;
	_ = blip_mp_mul;
	_ = blip_mp_div;
	_ = blip_mp_mod;
	_ = blip_mp_div_mod;
	_ = blip_mp_powm;
	_ = blip_mp_inv_mod;
}
