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

// Returns the i-th bit of the magnitude (0 or 1). i indexes from the LSB.
// Out-of-range positions read as 0. Sign is ignored (operates on |mp|).
// Useful for downstream consumers implementing custom scalar-mul / sliding-
// window algorithms.
int blip_mp_bit_at(const blip_mp_t *mp, size_t i);

// Returns the bit length of the magnitude: 1 + position of the highest set
// bit, or 0 for value zero. Sign is ignored.
size_t blip_mp_bit_len(const blip_mp_t *mp);

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

// --- Bitwise (M12-A1) --------------------------------------------------
// Two's-complement semantics: operands behave as conceptually-infinite-
// precision signed integers, sign-extended past their stored bytes.
// Matches GMP mpz_and / mpz_ior / mpz_xor / mpz_com / mpz_mul_2exp /
// mpz_fdiv_q_2exp respectively.

int blip_mp_and(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_or(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_xor(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_not(blip_mp_t *r, const blip_mp_t *a);  // ~a == -(a+1)
int blip_mp_shl(blip_mp_t *r, const blip_mp_t *a, size_t n);
int blip_mp_shr(blip_mp_t *r, const blip_mp_t *a, size_t n);  // floor / arithmetic

// --- Sign / abs / fits (M12-A2) ----------------------------------------

int blip_mp_neg(blip_mp_t *r, const blip_mp_t *a);
int blip_mp_abs(blip_mp_t *r, const blip_mp_t *a);
// 1 if value fits in the given C type, 0 otherwise. No error returns.
int blip_mp_fits_i64(const blip_mp_t *mp);
int blip_mp_fits_u64(const blip_mp_t *mp);
int blip_mp_fits_i32(const blip_mp_t *mp);
int blip_mp_fits_u32(const blip_mp_t *mp);

// --- popcount / scan (M12-A6) ------------------------------------------
// Hamming weight + first-bit search. Matches GMP mpz_popcount / mpz_scan0
// / mpz_scan1 semantics: SIZE_MAX is the not-found / infinite-1s sentinel.

size_t blip_mp_popcount(const blip_mp_t *mp);   // SIZE_MAX for negatives
size_t blip_mp_scan0(const blip_mp_t *mp, size_t start);
size_t blip_mp_scan1(const blip_mp_t *mp, size_t start);

// --- GCD / LCM (M12-A4) ------------------------------------------------
// Both always return a non-negative result. gcd(0,0)=0, lcm(0,x)=0.

int blip_mp_gcd(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
int blip_mp_lcm(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);

// --- Random (M12-A5) ---------------------------------------------------
// Opaque RNG handle wrapping a deterministic xoroshiro128 (std.Random
// .DefaultPrng). Caller seeds it explicitly — the library does NOT
// auto-seed from /dev/urandom. For cryptographic use, seed from a
// system-provided entropy source first.

typedef struct blip_mp_rng_t blip_mp_rng_t;

// Allocate + seed an RNG. Returns NULL on OOM.
blip_mp_rng_t *blip_mp_rng_create(uint64_t seed);
void blip_mp_rng_destroy(blip_mp_rng_t *rng);

// Uniform random integer in [0, 2^bits).
int blip_mp_set_random_bits(blip_mp_t *mp, blip_mp_rng_t *rng, size_t bits);

// Uniform random integer in [0, n) via rejection sampling. n must be > 0.
int blip_mp_set_random_below(blip_mp_t *mp, blip_mp_rng_t *rng, const blip_mp_t *n);

// --- String I/O (M12-A3) -----------------------------------------------
// Bases 2, 8, 10, 16 supported. Negative values are formatted with a
// leading '-'. setStr accepts the same form on input.

// Parse `len` bytes starting at `str` as an integer in `base`.
int blip_mp_set_str(blip_mp_t *mp, const char *str, size_t len, uint8_t base);

// Format `mp` in `base` into the caller's buffer. `*required` is always
// written with the length the formatted string occupies (excluding NUL).
// If buf_len < required, returns BLIP_MP_ERR_BUFFER_TOO_SMALL. When
// buf_len > required, the buffer is NUL-terminated for C convenience.
int blip_mp_to_string(const blip_mp_t *mp,
                      uint8_t base,
                      char *buf,
                      size_t buf_len,
                      size_t *required);

// --- Primality (M13-B1) ------------------------------------------------
// Miller-Rabin probabilistic primality test (with deterministic small-
// prime sieve trial division first). `witnesses` controls confidence:
// per-witness probability of a false-positive is 1/4 worst-case, so
// 20 witnesses → < 1 in 10^12 false-positive rate.

int blip_mp_is_probably_prime(const blip_mp_t *mp,
                              blip_mp_rng_t *rng,
                              uint32_t witnesses,
                              int *out);  // 1 if probably prime, 0 if composite

// Smallest prime > n. Uses 20 internal witnesses.
int blip_mp_next_prime(blip_mp_t *out, const blip_mp_t *n, blip_mp_rng_t *rng);

// --- Roots (M13-B2) ----------------------------------------------------

int blip_mp_isqrt(blip_mp_t *out, const blip_mp_t *n);
int blip_mp_isqrt_rem(blip_mp_t *root, blip_mp_t *rem, const blip_mp_t *n);
// floor(n^(1/k)). Allows odd k for negative n (root is negative).
int blip_mp_iroot(blip_mp_t *out, const blip_mp_t *n, uint32_t k);
int blip_mp_is_perfect_square(const blip_mp_t *mp);

// --- Symbols (M13-B3) --------------------------------------------------
// Jacobi / Legendre / Kronecker symbols. *out receives one of {-1, 0, +1}.

int blip_mp_jacobi(const blip_mp_t *a, const blip_mp_t *n, int *out);
int blip_mp_legendre(const blip_mp_t *a, const blip_mp_t *p, int *out);
int blip_mp_kronecker(const blip_mp_t *a, const blip_mp_t *n, int *out);

// --- Combinatorial (M13-B4) --------------------------------------------

int blip_mp_factorial(blip_mp_t *out, uint32_t n);
int blip_mp_binomial(blip_mp_t *out, uint32_t n, uint32_t k);
int blip_mp_fibonacci(blip_mp_t *out, uint32_t n);

// ────────────────────────────────────────────────────────────────────
// Fp — exact arbitrary-precision fixed-point (M14 IEEE754 disruption)
// ────────────────────────────────────────────────────────────────────
//
// Each Fp carries (mantissa, scale, base). Every operation either
// succeeds bit-exactly, takes a caller-supplied precision budget,
// or errors loudly. No NaN, no ±∞, no signed zero, no denormals,
// no silent rounding — none of IEEE754's footguns.
//
// Demo (the "IEEE754 disruption" pitch):
//   blip_mp_fp_t *x = blip_mp_fp_create();
//   blip_mp_fp_t *y = blip_mp_fp_create();
//   blip_mp_fp_t *r = blip_mp_fp_create();
//   blip_mp_fp_set_str(x, "0.1", 3, BLIP_MP_FP_BASE_DECIMAL);
//   blip_mp_fp_set_str(y, "0.2", 3, BLIP_MP_FP_BASE_DECIMAL);
//   blip_mp_fp_add(r, x, y);
//   blip_mp_fp_canonicalize(r);
//   char buf[16]; size_t need;
//   blip_mp_fp_to_string_canonical(r, buf, sizeof buf, &need);
//   // buf == "0.3"  (literally, no IEEE754 lying)

typedef struct blip_mp_fp_t blip_mp_fp_t;

// Base wire values match the Zig Base enum.
#define BLIP_MP_FP_BASE_BINARY    2
#define BLIP_MP_FP_BASE_DECIMAL   10

// Rounding modes — caller MUST choose explicitly. No default.
#define BLIP_MP_FP_ROUND_EXACT_OR_ERROR   0  // error if any info would be lost
#define BLIP_MP_FP_ROUND_TOWARD_ZERO      1  // truncate magnitude
#define BLIP_MP_FP_ROUND_TOWARD_POS_INF   2  // ceiling
#define BLIP_MP_FP_ROUND_TOWARD_NEG_INF   3  // floor
#define BLIP_MP_FP_ROUND_HALF_UP          4  // ties away from zero
#define BLIP_MP_FP_ROUND_HALF_DOWN        5  // ties toward zero
#define BLIP_MP_FP_ROUND_HALF_TO_EVEN     6  // banker's rounding
#define BLIP_MP_FP_ROUND_HALF_TO_ODD      7  // ties to odd

// Lifecycle.
blip_mp_fp_t *blip_mp_fp_create(void);
void          blip_mp_fp_destroy(blip_mp_fp_t *fp);

// Construction. `base` is one of the BLIP_MP_FP_BASE_* constants.
int blip_mp_fp_set_i64(blip_mp_fp_t *fp, int64_t mantissa, int32_t scale, int base);
int blip_mp_fp_set_rational_decimal(blip_mp_fp_t *fp, int64_t num, int64_t den);
int blip_mp_fp_set_rational_binary(blip_mp_fp_t *fp, int64_t num, int64_t den);
int blip_mp_fp_set_str(blip_mp_fp_t *fp, const char *str, size_t str_len, int base);
// setF64: decode IEEE754 bit-exactly. NaN/±∞ → BLIP_MP_ERR_NOT_REPRESENTABLE.
int blip_mp_fp_set_f64(blip_mp_fp_t *fp, double v);

// getF64Exact: encode as IEEE754 ONLY if exactly representable.
//   BLIP_MP_ERR_NON_TERMINATING — decimal with no terminating binary form
//   BLIP_MP_ERR_NOT_REPRESENTABLE — needs >53 mantissa bits, or out of range
// Caller wanting silent rounding must round explicitly first.
int blip_mp_fp_get_f64_exact(const blip_mp_fp_t *fp, double *out);

// Queries.
int     blip_mp_fp_is_zero(const blip_mp_fp_t *fp);
int     blip_mp_fp_get_base(const blip_mp_fp_t *fp);
int32_t blip_mp_fp_get_scale(const blip_mp_fp_t *fp);
// Borrowed Mp pointer; valid until the next mutating call on fp.
// Pass to read-only blip_mp_* ops; do NOT destroy.
blip_mp_t *blip_mp_fp_get_mantissa(blip_mp_fp_t *fp);

// Canonical form: strip trailing factors-of-base from the mantissa.
int blip_mp_fp_canonicalize(blip_mp_fp_t *fp);

// Comparison. Same-base required; mixed bases error MIXED_BASES.
int blip_mp_fp_cmp(const blip_mp_fp_t *a, const blip_mp_fp_t *b, int *out);  // out ∈ {-1,0,1}
int blip_mp_fp_eq(const blip_mp_fp_t *a, const blip_mp_fp_t *b, int *out);   // out ∈ {0,1}

// Arithmetic. Same-base required.
int blip_mp_fp_add(blip_mp_fp_t *r, const blip_mp_fp_t *a, const blip_mp_fp_t *b);
int blip_mp_fp_sub(blip_mp_fp_t *r, const blip_mp_fp_t *a, const blip_mp_fp_t *b);
int blip_mp_fp_mul(blip_mp_fp_t *r, const blip_mp_fp_t *a, const blip_mp_fp_t *b);

// divExact: succeeds bit-exactly OR errors NON_TERMINATING (e.g. 1/3 in
// base 10). The no-silent-rounding cornerstone.
int blip_mp_fp_div_exact(blip_mp_fp_t *r, const blip_mp_fp_t *a, const blip_mp_fp_t *b);

// divPrecision: caller-supplied budget. *out_exact is 1 if bit-exact, 0
// if had to truncate. Caller decides how to react.
int blip_mp_fp_div_precision(blip_mp_fp_t *r,
                             const blip_mp_fp_t *a,
                             const blip_mp_fp_t *b,
                             uint32_t max_scale_digits,
                             int *out_exact);

// Cross-base. toDecimal always exact; toBinary errors NON_TERMINATING
// when needed (e.g. 0.1₁₀ in binary).
int blip_mp_fp_to_decimal(blip_mp_fp_t *out, const blip_mp_fp_t *x);
int blip_mp_fp_to_binary(blip_mp_fp_t *out, const blip_mp_fp_t *x);

// Rounding. `mode` is one of BLIP_MP_FP_ROUND_* — no default.
int blip_mp_fp_round_to_scale(blip_mp_fp_t *out,
                              const blip_mp_fp_t *a,
                              int32_t target_scale,
                              int mode);
int blip_mp_fp_round_to_mp(blip_mp_t *out, const blip_mp_fp_t *a, int mode);

// Format. Caller-provided buffer + required-len pattern.
int blip_mp_fp_to_string_canonical(const blip_mp_fp_t *fp,
                                   char *buf,
                                   size_t buf_len,
                                   size_t *required);

// Format with EXACTLY `frac_digits` digits after the radix point. Pads with
// trailing zeros if canonical form has fewer; rounds (banker's / half-to-even)
// if more. Honors sign.
int blip_mp_fp_to_string_fixed(const blip_mp_fp_t *fp,
                               uint32_t frac_digits,
                               char *buf,
                               size_t buf_len,
                               size_t *required);

// Format in scientific notation. Decimal: '[-]M.MMMeE'. Binary: '[-]M.MMMpE'
// (C99 hex-float style — but with binary digits, not hex). Single-digit
// mantissas omit the radix point ('5e0' not '5.e0'). Zero renders as '0'.
int blip_mp_fp_to_string_scientific(const blip_mp_fp_t *fp,
                                    char *buf,
                                    size_t buf_len,
                                    size_t *required);

// getF64 with explicit rounding mode for >53-bit mantissas. `mode` is one of
// BLIP_MP_FP_ROUND_*. Differs from get_f64_exact in that >53-bit significands
// are rounded rather than rejected. Errors:
//   NON_TERMINATING — decimal with no terminating binary expansion
//   NOT_REPRESENTABLE — magnitude exceeds f64 range, OR
//                       mode == EXACT_OR_ERROR with >53-bit mantissa
int blip_mp_fp_get_f64(const blip_mp_fp_t *fp, int mode, double *out);

// --- NULL-argument safety ----------------------------------------------
// Every exported function is NULL-safe: passing NULL for a required handle
// returns a defined value instead of dereferencing it. Functions that
// return a status code (int, BLIP_MP_OK on success) return
// BLIP_MP_ERR_NULL_HANDLE. Value-returning queries have no status channel,
// so they return a documented out-of-band sentinel on NULL:
//   blip_mp_cmp / blip_mp_sign ............... -2   (valid results are -1/0/1)
//   0/1 predicates (is_zero, fits_*, bit_at,
//     is_perfect_square, fp_is_zero, fp_get_base) -1
//   size_t queries (bit_len, byte_len,
//     popcount, scan0, scan1) ................ SIZE_MAX
//   blip_mp_fp_get_scale ..................... INT32_MIN
//   blip_mp_fp_get_mantissa / blip_mp_bytes .. NULL
// _destroy functions treat NULL as a no-op (mirroring free()).

// --- Error codes -------------------------------------------------------

#define BLIP_MP_OK                       0
#define BLIP_MP_ERR_DIVISION_BY_ZERO     1
#define BLIP_MP_ERR_OUT_OF_MEMORY        2
#define BLIP_MP_ERR_NOT_IMPLEMENTED      3
#define BLIP_MP_ERR_INVALID_INPUT        4
#define BLIP_MP_ERR_OUT_OF_RANGE         5
#define BLIP_MP_ERR_NO_INVERSE           6
#define BLIP_MP_ERR_NEGATIVE_OPERAND     7
#define BLIP_MP_ERR_BUFFER_TOO_SMALL     8
#define BLIP_MP_ERR_MIXED_BASES          9
#define BLIP_MP_ERR_NON_TERMINATING     10
#define BLIP_MP_ERR_NOT_REPRESENTABLE   11
#define BLIP_MP_ERR_NULL_HANDLE         12

#ifdef __cplusplus
}
#endif

#endif // BLIP_MP_H
