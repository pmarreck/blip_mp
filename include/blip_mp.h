// blip_mp.h — public C API for the BLIP-storage multi-precision integer
// library. This is the FFI boundary that downstream consumers (C, Rust,
// Lua, Python, ...) link against. The Zig core is internal; this header
// is the contract.
//
// Conventions:
//   - All ops returning `int` use 0 (BLIP_MP_OK) for success and a positive
//     error code from BLIP_MP_ERR_* on failure.
//   - All `blip_mp_t*` parameters must come from `blip_mp_create()`. Caller
//     owns the handle and must release it via `blip_mp_destroy()`.
//   - Pointers returned by `blip_mp_bytes()` are borrowed views into the
//     handle's internal storage and are invalidated by the next mutating
//     call on that handle.
//   - The library uses `malloc`/`free` for all internal allocations so
//     callers can mix it freely with their own libc-allocated memory.

#ifndef BLIP_MP_H
#define BLIP_MP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a multi-precision integer.
typedef struct blip_mp_t blip_mp_t;

// --- Lifecycle ---------------------------------------------------------

// Allocate a fresh Mp handle initialised to zero. Returns NULL on OOM.
blip_mp_t *blip_mp_create(void);

// Release a handle. Safe to call with NULL (mirrors free()).
void blip_mp_destroy(blip_mp_t *mp);

// --- Setters / getters -------------------------------------------------

// Replace `mp`'s value with `value`. Returns 0 on success.
int blip_mp_set_i64(blip_mp_t *mp, int64_t value);

// Read `mp` as an int64. Writes the value to *out and returns 0 on success.
// Returns BLIP_MP_ERR_OUT_OF_RANGE if the value doesn't fit in i64.
int blip_mp_get_i64(const blip_mp_t *mp, int64_t *out);

// Replace `mp`'s value with `value` (unsigned). Returns 0 on success;
// BLIP_MP_ERR_OUT_OF_RANGE if value > i64.max (the BLIP encoding stores
// signed two's-complement payloads; values past i64.max would overflow).
int blip_mp_set_u64(blip_mp_t *mp, uint64_t value);

// Read `mp` as a uint64. Writes the value to *out and returns 0 on success.
// Returns BLIP_MP_ERR_OUT_OF_RANGE if the value doesn't fit in u64 OR if it
// is negative (callers wanting negative values should use blip_mp_get_i64).
int blip_mp_get_u64(const blip_mp_t *mp, uint64_t *out);

// Replace `mp`'s value with the BLIP-encoded byte slice [bytes, bytes+len).
// Returns 0 on success, BLIP_MP_ERR_INVALID_INPUT if the encoding is malformed.
int blip_mp_set_bytes(blip_mp_t *mp, const uint8_t *bytes, size_t len);

// Length of the BLIP encoding currently held by `mp`.
size_t blip_mp_byte_len(const blip_mp_t *mp);

// Borrowed pointer into `mp`'s internal BLIP-encoded buffer. Valid until the
// next mutating call on `mp`. Returns NULL if `mp` is NULL.
const uint8_t *blip_mp_bytes(const blip_mp_t *mp);

// --- Comparison / sign --------------------------------------------------

// Three-way compare: returns -1 if a<b, 0 if a==b, +1 if a>b.
int blip_mp_cmp(const blip_mp_t *a, const blip_mp_t *b);

// Sign of the value: -1, 0, or +1.
int blip_mp_sign(const blip_mp_t *mp);

// 1 if `mp` is zero, 0 otherwise.
int blip_mp_is_zero(const blip_mp_t *mp);

// --- Arithmetic --------------------------------------------------------
//
// All arithmetic ops return 0 on success and a BLIP_MP_ERR_* code on
// failure. The destination handle (`r`/`q`/`rem`) may alias either source.

int blip_mp_add(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_sub(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_mul(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_div(blip_mp_t *q, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_mod(blip_mp_t *rem, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_div_mod(blip_mp_t *q, blip_mp_t *rem,
                    const blip_mp_t *a, const blip_mp_t *b);

// Modular exponentiation: r = base^exp mod mod.
// Returns BLIP_MP_ERR_DIVISION_BY_ZERO when mod == 0.
// Returns BLIP_MP_ERR_INVALID_INPUT when exp < 0 (modular inverse needed).
int blip_mp_powm(blip_mp_t *r,
                 const blip_mp_t *base,
                 const blip_mp_t *exp,
                 const blip_mp_t *mod);

// Modular inverse: r = a^-1 mod m.
// Returns BLIP_MP_OK if the inverse exists (gcd(a,m) == 1) and writes it to r.
// Returns BLIP_MP_ERR_NO_INVERSE if no inverse exists; r is set to 0.
// Returns BLIP_MP_ERR_DIVISION_BY_ZERO if m == 0.
int blip_mp_inv_mod(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *m);

// --- Error codes -------------------------------------------------------

#define BLIP_MP_OK                    0
#define BLIP_MP_ERR_DIVISION_BY_ZERO  1
#define BLIP_MP_ERR_OUT_OF_MEMORY     2
#define BLIP_MP_ERR_NOT_IMPLEMENTED   3
#define BLIP_MP_ERR_INVALID_INPUT     4
#define BLIP_MP_ERR_OUT_OF_RANGE      5
#define BLIP_MP_ERR_NO_INVERSE        6

#ifdef __cplusplus
}
#endif

#endif // BLIP_MP_H
