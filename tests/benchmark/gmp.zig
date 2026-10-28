//! GMP's public mpz ABI, confined to independent benchmark oracles.
pub const Z = extern struct { allocated: c_int, size: c_int, data: ?*anyopaque };
pub extern "c" fn __gmpz_init(value: *Z) void;
pub extern "c" fn __gmpz_clear(value: *Z) void;
pub extern "c" fn __gmpz_import(value: *Z, count: usize, order: c_int, size: usize, endian: c_int, nails: usize, bytes: [*]const u8) void;
pub extern "c" fn __gmpz_export(bytes: [*]u8, count: *usize, order: c_int, size: usize, endian: c_int, nails: usize, value: *const Z) ?[*]u8;
pub extern "c" fn __gmpz_invert(result: *Z, a: *const Z, m: *const Z) c_int;
pub extern "c" fn __gmpz_tdiv_qr(q: *Z, r: *Z, a: *const Z, b: *const Z) void;
