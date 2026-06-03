// c_smoke — C-FFI smoke test for blip_mp.
//
// Dogfoods the public C API exactly as a downstream Rust/Lua/Python binding
// would: opaque handles, libc-visible lifetime (create/destroy), integer
// error codes (no exceptions), const-correctness on read-only ops.
//
// Per CLAUDE.md, this IS the consumer that validates the FFI boundary —
// blip_mp is forbidden from having a Zig CLI that imports the core directly.
//
// Exit code 0 = all checks passed; nonzero = first failure (logged to stderr).

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blip_mp.h"

static int failures = 0;

#define CHECK(cond, msg)                                                    \
	do {                                                                \
		if (!(cond)) {                                              \
			fprintf(stderr,                                     \
				"[FAIL] %s:%d: %s\n",                       \
				__FILE__, __LINE__, msg);                   \
			failures++;                                         \
		}                                                           \
	} while (0)

#define CHECK_OK(call)                                                      \
	do {                                                                \
		int _rc = (call);                                           \
		if (_rc != BLIP_MP_OK) {                                    \
			fprintf(stderr,                                     \
				"[FAIL] %s:%d: " #call                      \
				" returned %d (expected 0)\n",              \
				__FILE__, __LINE__, _rc);                   \
			failures++;                                         \
		}                                                           \
	} while (0)

static void test_lifecycle(void) {
	blip_mp_t *m = blip_mp_create();
	CHECK(m != NULL, "blip_mp_create returned NULL");
	if (m == NULL) return;

	// Default value is zero.
	CHECK(blip_mp_is_zero(m) == 1, "fresh Mp should be zero");
	CHECK(blip_mp_sign(m) == 0, "fresh Mp should have sign 0");

	blip_mp_destroy(m);
	// Destroy of NULL should be a no-op (mirrors free()).
	blip_mp_destroy(NULL);
}

static void test_set_get_i64(void) {
	blip_mp_t *m = blip_mp_create();
	CHECK(m != NULL, "create");
	if (m == NULL) return;

	const int64_t inputs[] = {
		0, 1, -1, 127, -128, 128, -129,
		(int64_t)INT32_MAX, (int64_t)INT32_MIN,
		(int64_t)INT64_MAX, (int64_t)INT64_MIN,
		0xdeadbeefLL, -0xcafebabeLL,
	};
	for (size_t i = 0; i < sizeof(inputs) / sizeof(inputs[0]); i++) {
		CHECK_OK(blip_mp_set_i64(m, inputs[i]));
		int64_t got = 0;
		CHECK_OK(blip_mp_get_i64(m, &got));
		if (got != inputs[i]) {
			fprintf(stderr,
				"[FAIL] roundtrip i64 %" PRId64
				" -> %" PRId64 "\n",
				inputs[i], got);
			failures++;
		}
		// sign agrees with the value.
		int sign = blip_mp_sign(m);
		int expected_sign = (inputs[i] > 0) - (inputs[i] < 0);
		CHECK(sign == expected_sign, "sign mismatch");
		CHECK(blip_mp_is_zero(m) == (inputs[i] == 0 ? 1 : 0),
			"is_zero mismatch");
	}
	blip_mp_destroy(m);
}

static void test_u64_roundtrip(void) {
	blip_mp_t *m = blip_mp_create();
	CHECK(m != NULL, "create for u64 roundtrip");
	if (m == NULL) return;

	const uint64_t u_inputs[] = {
		0, 1, 127, 128, 0xFFFF, 0xFFFFFFFF, 0xDEADBEEFCAFEULL,
		(uint64_t)INT64_MAX,
	};
	for (size_t i = 0; i < sizeof(u_inputs) / sizeof(u_inputs[0]); i++) {
		CHECK_OK(blip_mp_set_u64(m, u_inputs[i]));
		uint64_t got = 0;
		CHECK_OK(blip_mp_get_u64(m, &got));
		if (got != u_inputs[i]) {
			fprintf(stderr,
				"[FAIL] roundtrip u64 %" PRIu64
				" -> %" PRIu64 "\n",
				u_inputs[i], got);
			failures++;
		}
	}
	// Set a negative value via i64 then verify get_u64 errors.
	CHECK_OK(blip_mp_set_i64(m, -1));
	uint64_t neg_out = 0;
	int err = blip_mp_get_u64(m, &neg_out);
	CHECK(err != BLIP_MP_OK, "get_u64 should error on negative value");

	// set_u64 with a value > i64.max should error out.
	int oor = blip_mp_set_u64(m, ((uint64_t)INT64_MAX) + 1ULL);
	CHECK(oor != BLIP_MP_OK, "set_u64 should error on value > i64.max");

	blip_mp_destroy(m);
}

static void test_bit_access(void) {
	blip_mp_t *m = blip_mp_create();
	CHECK(m != NULL, "create for bit access");
	if (m == NULL) return;

	// 0 has bit_len 0; bit_at any position is 0.
	CHECK_OK(blip_mp_set_i64(m, 0));
	CHECK(blip_mp_bit_len(m) == 0, "bit_len(0) == 0");
	CHECK(blip_mp_bit_at(m, 0) == 0, "bit_at(0, 0) == 0");
	CHECK(blip_mp_bit_at(m, 100) == 0, "bit_at(0, 100) == 0");

	// 1 has bit_len 1, bit_at(0) == 1, all else 0.
	CHECK_OK(blip_mp_set_i64(m, 1));
	CHECK(blip_mp_bit_len(m) == 1, "bit_len(1) == 1");
	CHECK(blip_mp_bit_at(m, 0) == 1, "bit_at(1, 0) == 1");
	CHECK(blip_mp_bit_at(m, 1) == 0, "bit_at(1, 1) == 0");

	// 0xFF: bit_len 8, bits 0..7 all set.
	CHECK_OK(blip_mp_set_i64(m, 0xFF));
	CHECK(blip_mp_bit_len(m) == 8, "bit_len(0xFF) == 8");
	for (size_t i = 0; i < 8; i++) {
		CHECK(blip_mp_bit_at(m, i) == 1, "bit_at(0xFF, i) == 1 for i in 0..8");
	}
	CHECK(blip_mp_bit_at(m, 8) == 0, "bit_at(0xFF, 8) == 0");

	// 0x100: bit_len 9, only bit 8 set.
	CHECK_OK(blip_mp_set_i64(m, 0x100));
	CHECK(blip_mp_bit_len(m) == 9, "bit_len(0x100) == 9");
	for (size_t i = 0; i < 8; i++) {
		CHECK(blip_mp_bit_at(m, i) == 0, "bit_at(0x100, i) == 0 for i in 0..8");
	}
	CHECK(blip_mp_bit_at(m, 8) == 1, "bit_at(0x100, 8) == 1");
	CHECK(blip_mp_bit_at(m, 9) == 0, "bit_at(0x100, 9) == 0");

	// Sign is ignored — magnitude bits.
	CHECK_OK(blip_mp_set_i64(m, -0x100));
	CHECK(blip_mp_bit_len(m) == 9, "bit_len(-0x100) == 9 (sign ignored)");
	CHECK(blip_mp_bit_at(m, 8) == 1, "bit_at(-0x100, 8) == 1");

	blip_mp_destroy(m);
}

static void test_arithmetic(void) {
	blip_mp_t *a = blip_mp_create();
	blip_mp_t *b = blip_mp_create();
	blip_mp_t *r = blip_mp_create();
	CHECK(a && b && r, "create");
	if (!a || !b || !r) goto out;

	CHECK_OK(blip_mp_set_i64(a, 1234567890LL));
	CHECK_OK(blip_mp_set_i64(b, 9876543210LL));

	// add
	CHECK_OK(blip_mp_add(r, a, b));
	int64_t sum = 0;
	CHECK_OK(blip_mp_get_i64(r, &sum));
	CHECK(sum == 11111111100LL, "1234567890 + 9876543210");

	// sub
	CHECK_OK(blip_mp_sub(r, b, a));
	int64_t diff = 0;
	CHECK_OK(blip_mp_get_i64(r, &diff));
	CHECK(diff == 8641975320LL, "9876543210 - 1234567890");

	// mul
	CHECK_OK(blip_mp_set_i64(a, 100000LL));
	CHECK_OK(blip_mp_set_i64(b, 200000LL));
	CHECK_OK(blip_mp_mul(r, a, b));
	int64_t prod = 0;
	CHECK_OK(blip_mp_get_i64(r, &prod));
	CHECK(prod == 20000000000LL, "100000 * 200000");

	// div / mod
	CHECK_OK(blip_mp_set_i64(a, 100));
	CHECK_OK(blip_mp_set_i64(b, 7));
	blip_mp_t *q = blip_mp_create();
	blip_mp_t *rem = blip_mp_create();
	CHECK_OK(blip_mp_div_mod(q, rem, a, b));
	int64_t qv = 0, rv = 0;
	CHECK_OK(blip_mp_get_i64(q, &qv));
	CHECK_OK(blip_mp_get_i64(rem, &rv));
	CHECK(qv == 14 && rv == 2, "100 / 7 = (14, 2)");
	blip_mp_destroy(q);
	blip_mp_destroy(rem);

out:
	blip_mp_destroy(a);
	blip_mp_destroy(b);
	blip_mp_destroy(r);
}

static void test_cmp(void) {
	blip_mp_t *a = blip_mp_create();
	blip_mp_t *b = blip_mp_create();
	CHECK_OK(blip_mp_set_i64(a, -5));
	CHECK_OK(blip_mp_set_i64(b, 5));
	CHECK(blip_mp_cmp(a, b) == -1, "a < b");
	CHECK(blip_mp_cmp(b, a) == 1, "b > a");
	CHECK_OK(blip_mp_set_i64(b, -5));
	CHECK(blip_mp_cmp(a, b) == 0, "a == b");
	blip_mp_destroy(a);
	blip_mp_destroy(b);
}

static void test_division_by_zero(void) {
	blip_mp_t *a = blip_mp_create();
	blip_mp_t *b = blip_mp_create();
	blip_mp_t *q = blip_mp_create();
	blip_mp_t *r = blip_mp_create();
	CHECK_OK(blip_mp_set_i64(a, 100));
	CHECK_OK(blip_mp_set_i64(b, 0));

	int rc = blip_mp_div(q, a, b);
	CHECK(rc == BLIP_MP_ERR_DIVISION_BY_ZERO, "div by zero -> 1");
	rc = blip_mp_mod(r, a, b);
	CHECK(rc == BLIP_MP_ERR_DIVISION_BY_ZERO, "mod by zero -> 1");
	rc = blip_mp_div_mod(q, r, a, b);
	CHECK(rc == BLIP_MP_ERR_DIVISION_BY_ZERO, "div_mod by zero -> 1");

	blip_mp_destroy(a);
	blip_mp_destroy(b);
	blip_mp_destroy(q);
	blip_mp_destroy(r);
}

static void test_bytes_roundtrip(void) {
	// set value -> grab BLIP byte view -> install on another Mp via set_bytes
	// -> arith on the copy -> verify equality.
	blip_mp_t *a = blip_mp_create();
	blip_mp_t *b = blip_mp_create();
	CHECK_OK(blip_mp_set_i64(a, 0x123456789abcdef0LL));

	size_t n = blip_mp_byte_len(a);
	const uint8_t *p = blip_mp_bytes(a);
	CHECK(n > 0 && p != NULL, "byte view non-empty");

	// Copy off the buffer (per API contract, the pointer is invalidated by
	// the next mutation on `a`).
	uint8_t buf[64];
	CHECK(n <= sizeof(buf), "value fits in test buffer");
	memcpy(buf, p, n);

	CHECK_OK(blip_mp_set_bytes(b, buf, n));
	int64_t v = 0;
	CHECK_OK(blip_mp_get_i64(b, &v));
	CHECK(v == 0x123456789abcdef0LL, "set_bytes round-trip");

	// Equality via cmp.
	CHECK(blip_mp_cmp(a, b) == 0, "a == b after byte roundtrip");

	// Arithmetic on the copy.
	blip_mp_t *r = blip_mp_create();
	CHECK_OK(blip_mp_add(r, a, b));
	int64_t sum = 0;
	CHECK_OK(blip_mp_get_i64(r, &sum));
	CHECK(sum == 0x123456789abcdef0LL * 2, "a + a == 2a");

	blip_mp_destroy(r);
	blip_mp_destroy(a);
	blip_mp_destroy(b);
}

static void test_powm(void) {
	// 2^10 mod 1000 == 24
	blip_mp_t *base = blip_mp_create();
	blip_mp_t *exp = blip_mp_create();
	blip_mp_t *mod = blip_mp_create();
	blip_mp_t *r = blip_mp_create();
	CHECK_OK(blip_mp_set_i64(base, 2));
	CHECK_OK(blip_mp_set_i64(exp, 10));
	CHECK_OK(blip_mp_set_i64(mod, 1000));
	CHECK_OK(blip_mp_powm(r, base, exp, mod));
	int64_t v = 0;
	CHECK_OK(blip_mp_get_i64(r, &v));
	CHECK(v == 24, "2^10 mod 1000 == 24");

	blip_mp_destroy(base);
	blip_mp_destroy(exp);
	blip_mp_destroy(mod);
	blip_mp_destroy(r);
}

static void test_inv_mod(void) {
	// 3^-1 mod 11 == 4 (since 3*4 = 12 ≡ 1 mod 11)
	blip_mp_t *a = blip_mp_create();
	blip_mp_t *m = blip_mp_create();
	blip_mp_t *r = blip_mp_create();
	CHECK_OK(blip_mp_set_i64(a, 3));
	CHECK_OK(blip_mp_set_i64(m, 11));
	int rc = blip_mp_inv_mod(r, a, m);
	CHECK(rc == BLIP_MP_OK, "inv_mod returns OK when inverse exists");
	int64_t v = 0;
	CHECK_OK(blip_mp_get_i64(r, &v));
	CHECK(v == 4, "3^-1 mod 11 == 4");

	// 2^-1 mod 4 — gcd(2,4)=2, no inverse. Expect BLIP_MP_ERR_NO_INVERSE.
	CHECK_OK(blip_mp_set_i64(a, 2));
	CHECK_OK(blip_mp_set_i64(m, 4));
	rc = blip_mp_inv_mod(r, a, m);
	CHECK(rc == BLIP_MP_ERR_NO_INVERSE, "no-inverse case returns the right code");

	blip_mp_destroy(a);
	blip_mp_destroy(m);
	blip_mp_destroy(r);
}

static void test_fp_disrupt_ieee754(void) {
	// The IEEE754 disruption demo — end-to-end via the C FFI.
	blip_mp_fp_t *x = blip_mp_fp_create();
	blip_mp_fp_t *y = blip_mp_fp_create();
	blip_mp_fp_t *r = blip_mp_fp_create();
	CHECK_OK(blip_mp_fp_set_str(x, "0.1", 3, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_set_str(y, "0.2", 3, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_add(r, x, y));
	CHECK_OK(blip_mp_fp_canonicalize(r));
	char buf[16];
	size_t need = 0;
	CHECK_OK(blip_mp_fp_to_string_canonical(r, buf, sizeof buf, &need));
	CHECK(need == 3, "0.1 + 0.2 prints as 3-char string");
	CHECK(buf[0] == '0' && buf[1] == '.' && buf[2] == '3', "0.1 + 0.2 == \"0.3\" via C FFI");

	blip_mp_fp_destroy(x);
	blip_mp_fp_destroy(y);
	blip_mp_fp_destroy(r);
}

static void test_fp_div_exact_or_error(void) {
	blip_mp_fp_t *a = blip_mp_fp_create();
	blip_mp_fp_t *b = blip_mp_fp_create();
	blip_mp_fp_t *r = blip_mp_fp_create();
	CHECK_OK(blip_mp_fp_set_i64(a, 1, 0, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_set_i64(b, 4, 0, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_div_exact(r, a, b));
	CHECK_OK(blip_mp_fp_set_i64(b, 3, 0, BLIP_MP_FP_BASE_DECIMAL));
	int rc = blip_mp_fp_div_exact(r, a, b);
	CHECK(rc == BLIP_MP_ERR_NON_TERMINATING, "1/3 errors NON_TERMINATING via FFI");
	int exact_flag = 99;
	CHECK_OK(blip_mp_fp_div_precision(r, a, b, 5, &exact_flag));
	CHECK(exact_flag == 0, "div_precision reports inexact for 1/3");

	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	blip_mp_fp_destroy(r);
}

static void test_fp_setf64_killshot(void) {
	// setF64(0.1) → toDecimal → string == the famous 55-digit lie.
	blip_mp_fp_t *x = blip_mp_fp_create();
	blip_mp_fp_t *d = blip_mp_fp_create();
	CHECK_OK(blip_mp_fp_set_f64(x, 0.1));
	CHECK_OK(blip_mp_fp_to_decimal(d, x));
	CHECK_OK(blip_mp_fp_canonicalize(d));
	char buf[80];
	size_t need = 0;
	CHECK_OK(blip_mp_fp_to_string_canonical(d, buf, sizeof buf, &need));
	const char *expected = "0.1000000000000000055511151231257827021181583404541015625";
	CHECK(need == strlen(expected), "0.1f64 prints as expected-length string");
	CHECK(memcmp(buf, expected, need) == 0, "0.1f64 prints its full bit-exact decimal expansion");

	blip_mp_fp_destroy(x);
	blip_mp_fp_destroy(d);
}

static void test_fp_round_modes(void) {
	blip_mp_fp_t *a = blip_mp_fp_create();
	blip_mp_t *m = blip_mp_create();
	CHECK_OK(blip_mp_fp_set_str(a, "2.5", 3, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_round_to_mp(m, a, BLIP_MP_FP_ROUND_HALF_UP));
	int64_t v = 0;
	CHECK_OK(blip_mp_get_i64(m, &v));
	CHECK(v == 3, "half_up rounds 2.5 → 3");
	CHECK_OK(blip_mp_fp_round_to_mp(m, a, BLIP_MP_FP_ROUND_HALF_TO_EVEN));
	CHECK_OK(blip_mp_get_i64(m, &v));
	CHECK(v == 2, "banker rounds 2.5 → 2 (even)");

	blip_mp_fp_destroy(a);
	blip_mp_destroy(m);
}

static void test_fp_to_string_fixed(void) {
	// Pad: "3.14" → 4 frac digits → "3.1400"
	blip_mp_fp_t *x = blip_mp_fp_create();
	CHECK_OK(blip_mp_fp_set_str(x, "3.14", 4, BLIP_MP_FP_BASE_DECIMAL));
	char buf[32];
	size_t need = 0;
	CHECK_OK(blip_mp_fp_to_string_fixed(x, 4, buf, sizeof buf, &need));
	CHECK(need == 6, "to_string_fixed need == 6");
	CHECK(memcmp(buf, "3.1400", need) == 0, "to_string_fixed pads trailing zeros");

	// Banker rounding: "3.149" → 2 frac digits → "3.15"
	CHECK_OK(blip_mp_fp_set_str(x, "3.149", 5, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_to_string_fixed(x, 2, buf, sizeof buf, &need));
	CHECK(need == 4, "rounded need == 4");
	CHECK(memcmp(buf, "3.15", need) == 0, "to_string_fixed rounds half-to-even");

	// Banker tie at 2.5 → 0 frac digits → "2"
	CHECK_OK(blip_mp_fp_set_str(x, "2.5", 3, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_to_string_fixed(x, 0, buf, sizeof buf, &need));
	CHECK(need == 1, "tie → 0 frac → need == 1");
	CHECK(buf[0] == '2', "banker rounds 2.5 → 2 (no decimal point)");

	// Zero with frac_digits → "0.000"
	CHECK_OK(blip_mp_fp_set_i64(x, 0, 0, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_to_string_fixed(x, 3, buf, sizeof buf, &need));
	CHECK(need == 5, "zero with frac_digits=3 need == 5");
	CHECK(memcmp(buf, "0.000", need) == 0, "zero pads to 0.000");

	blip_mp_fp_destroy(x);
}

static void test_fp_to_string_scientific(void) {
	blip_mp_fp_t *x = blip_mp_fp_create();
	char buf[32];
	size_t need = 0;

	// 3.14 → "3.14e0"
	CHECK_OK(blip_mp_fp_set_str(x, "3.14", 4, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_to_string_scientific(x, buf, sizeof buf, &need));
	CHECK(need == 6, "3.14 sci need == 6");
	CHECK(memcmp(buf, "3.14e0", need) == 0, "3.14 → 3.14e0");

	// 1500 → "1.5e3"
	CHECK_OK(blip_mp_fp_set_i64(x, 1500, 0, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_to_string_scientific(x, buf, sizeof buf, &need));
	CHECK(need == 5, "1500 sci need == 5");
	CHECK(memcmp(buf, "1.5e3", need) == 0, "1500 → 1.5e3");

	// -0.025 → "-2.5e-2"
	CHECK_OK(blip_mp_fp_set_str(x, "-0.025", 6, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_to_string_scientific(x, buf, sizeof buf, &need));
	CHECK(need == 7, "-0.025 sci need == 7");
	CHECK(memcmp(buf, "-2.5e-2", need) == 0, "-0.025 → -2.5e-2");

	// Binary 0.75 (= 3 × 2^-2) → "1.1p-1"
	CHECK_OK(blip_mp_fp_set_i64(x, 3, -2, BLIP_MP_FP_BASE_BINARY));
	CHECK_OK(blip_mp_fp_to_string_scientific(x, buf, sizeof buf, &need));
	CHECK(need == 6, "binary 0.75 sci need == 6");
	CHECK(memcmp(buf, "1.1p-1", need) == 0, "0.75_b → 1.1p-1");

	// Zero → "0"
	CHECK_OK(blip_mp_fp_set_i64(x, 0, 0, BLIP_MP_FP_BASE_DECIMAL));
	CHECK_OK(blip_mp_fp_to_string_scientific(x, buf, sizeof buf, &need));
	CHECK(need == 1, "zero sci need == 1");
	CHECK(buf[0] == '0', "zero → 0");

	blip_mp_fp_destroy(x);
}

static void test_fp_get_f64_with_mode(void) {
	blip_mp_fp_t *x = blip_mp_fp_create();
	double got = 0.0;

	// Exact value: 0.25 → with .exact_or_error → 0.25
	CHECK_OK(blip_mp_fp_set_rational_decimal(x, 1, 4));
	CHECK_OK(blip_mp_fp_get_f64(x, BLIP_MP_FP_ROUND_EXACT_OR_ERROR, &got));
	CHECK(got == 0.25, "exact_or_error: 1/4 → 0.25");

	// 2^53 + 1 with .half_to_even → 2^53 (banker tie picks even)
	CHECK_OK(blip_mp_fp_set_i64(x, ((int64_t)1 << 53) | 1, 0, BLIP_MP_FP_BASE_BINARY));
	CHECK_OK(blip_mp_fp_get_f64(x, BLIP_MP_FP_ROUND_HALF_TO_EVEN, &got));
	CHECK(got == (double)((int64_t)1 << 53), "banker: 2^53+1 → 2^53");

	// Same input with .exact_or_error → NOT_REPRESENTABLE
	int rc = blip_mp_fp_get_f64(x, BLIP_MP_FP_ROUND_EXACT_OR_ERROR, &got);
	CHECK(rc == BLIP_MP_ERR_NOT_REPRESENTABLE, "exact_or_error on >53 bits → NOT_REPRESENTABLE");

	// Same input with .toward_pos_inf → 2^53 + 2
	CHECK_OK(blip_mp_fp_get_f64(x, BLIP_MP_FP_ROUND_TOWARD_POS_INF, &got));
	CHECK(got == (double)(((int64_t)1 << 53) + 2), "toward_pos_inf: 2^53+1 → 2^53+2");

	blip_mp_fp_destroy(x);
}

// ======================================================================
// Expanded FFI coverage (fleet code-review 2026-06-01, WARN: inadequate
// FFI test coverage). The 47 exports below previously had ZERO smoke
// coverage. These are characterization tests over known-correct values
// plus an integer overflow / boundary matrix across the C ABI.
// ======================================================================

// Small constructors so each test reads as the math it checks.
static blip_mp_t *mk_i64(int64_t v) {
	blip_mp_t *m = blip_mp_create();
	if (m) blip_mp_set_i64(m, v);
	return m;
}
static int64_t as_i64(const blip_mp_t *m) {
	int64_t v = 0;
	blip_mp_get_i64(m, &v);
	return v;
}

static void test_gcd_lcm(void) {
	blip_mp_t *a = mk_i64(48), *b = mk_i64(18), *r = blip_mp_create();
	CHECK(a && b && r, "gcd/lcm: create");
	if (!a || !b || !r) goto done;
	CHECK_OK(blip_mp_gcd(r, a, b));
	CHECK(as_i64(r) == 6, "gcd(48,18) == 6");
	blip_mp_set_i64(a, 4);
	blip_mp_set_i64(b, 6);
	CHECK_OK(blip_mp_lcm(r, a, b));
	CHECK(as_i64(r) == 12, "lcm(4,6) == 12");
done:
	blip_mp_destroy(a);
	blip_mp_destroy(b);
	blip_mp_destroy(r);
}

static void test_symbols(void) {
	// jacobi(9,5): 9 = 3^2 is a QR mod 5 -> +1
	// legendre(6,7): 6 == -1 (mod 7), 7 == 3 (mod 4) -> -1
	// kronecker(5,2): (5/2) = (-1)^((25-1)/8) = -1  (jacobi requires odd n)
	blip_mp_t *a = blip_mp_create(), *n = blip_mp_create();
	CHECK(a && n, "symbols: create");
	if (!a || !n) goto done;
	int s = 99;
	blip_mp_set_i64(a, 9);
	blip_mp_set_i64(n, 5);
	CHECK_OK(blip_mp_jacobi(a, n, &s));
	CHECK(s == 1, "jacobi(9,5) == 1");
	blip_mp_set_i64(a, 6);
	blip_mp_set_i64(n, 7);
	CHECK_OK(blip_mp_legendre(a, n, &s));
	CHECK(s == -1, "legendre(6,7) == -1");
	blip_mp_set_i64(a, 5);
	blip_mp_set_i64(n, 2);
	CHECK_OK(blip_mp_kronecker(a, n, &s));
	CHECK(s == -1, "kronecker(5,2) == -1");
done:
	blip_mp_destroy(a);
	blip_mp_destroy(n);
}

static void test_roots(void) {
	blip_mp_t *n = mk_i64(100), *out = blip_mp_create(), *rem = blip_mp_create();
	CHECK(n && out && rem, "roots: create");
	if (!n || !out || !rem) goto done;
	CHECK_OK(blip_mp_isqrt(out, n));
	CHECK(as_i64(out) == 10, "isqrt(100) == 10");
	blip_mp_set_i64(n, 99);
	CHECK_OK(blip_mp_isqrt(out, n));
	CHECK(as_i64(out) == 9, "isqrt(99) == 9");
	blip_mp_set_i64(n, 102);
	CHECK_OK(blip_mp_isqrt_rem(out, rem, n));
	CHECK(as_i64(out) == 10 && as_i64(rem) == 2, "isqrt_rem(102) == 10 r2");
	blip_mp_set_i64(n, 27);
	CHECK_OK(blip_mp_iroot(out, n, 3));
	CHECK(as_i64(out) == 3, "iroot(27,3) == 3");
	blip_mp_set_i64(n, 28);
	CHECK_OK(blip_mp_iroot(out, n, 3));
	CHECK(as_i64(out) == 3, "iroot(28,3) == 3 (floor)");
	blip_mp_set_i64(n, 100);
	CHECK(blip_mp_is_perfect_square(n) == 1, "100 is a perfect square");
	blip_mp_set_i64(n, 101);
	CHECK(blip_mp_is_perfect_square(n) == 0, "101 is not a perfect square");
done:
	blip_mp_destroy(n);
	blip_mp_destroy(out);
	blip_mp_destroy(rem);
}

static void test_combinatorics(void) {
	blip_mp_t *out = blip_mp_create();
	CHECK(out != NULL, "combi: create");
	if (!out) return;
	CHECK_OK(blip_mp_factorial(out, 0));
	CHECK(as_i64(out) == 1, "0! == 1");
	CHECK_OK(blip_mp_factorial(out, 10));
	CHECK(as_i64(out) == 3628800, "10! == 3628800");
	CHECK_OK(blip_mp_binomial(out, 6, 3));
	CHECK(as_i64(out) == 20, "C(6,3) == 20");
	CHECK_OK(blip_mp_binomial(out, 5, 0));
	CHECK(as_i64(out) == 1, "C(5,0) == 1");
	CHECK_OK(blip_mp_fibonacci(out, 0));
	CHECK(as_i64(out) == 0, "fib(0) == 0");
	CHECK_OK(blip_mp_fibonacci(out, 1));
	CHECK(as_i64(out) == 1, "fib(1) == 1");
	CHECK_OK(blip_mp_fibonacci(out, 10));
	CHECK(as_i64(out) == 55, "fib(10) == 55");
	blip_mp_destroy(out);
}

static void test_primality(void) {
	blip_mp_rng_t *rng = blip_mp_rng_create(12345);
	CHECK(rng != NULL, "primality: rng create");
	if (!rng) return;
	blip_mp_t *p = mk_i64(97), *out = blip_mp_create();
	CHECK(p && out, "primality: create");
	if (!p || !out) {
		blip_mp_rng_destroy(rng);
		return;
	}
	int isp = 99;
	CHECK_OK(blip_mp_is_probably_prime(p, rng, 20, &isp));
	CHECK(isp == 1, "97 is probably prime");
	blip_mp_set_i64(p, 91); // 7 * 13
	CHECK_OK(blip_mp_is_probably_prime(p, rng, 20, &isp));
	CHECK(isp == 0, "91 is composite");
	blip_mp_set_i64(p, 89);
	CHECK_OK(blip_mp_next_prime(out, p, rng));
	CHECK(as_i64(out) == 97, "next_prime(89) == 97");
	blip_mp_destroy(p);
	blip_mp_destroy(out);
	blip_mp_rng_destroy(rng);
}

static void test_bitwise(void) {
	blip_mp_t *a = mk_i64(12), *b = mk_i64(10), *r = blip_mp_create();
	CHECK(a && b && r, "bitwise: create");
	if (!a || !b || !r) goto done;
	CHECK_OK(blip_mp_and(r, a, b));
	CHECK(as_i64(r) == 8, "12 & 10 == 8");
	CHECK_OK(blip_mp_or(r, a, b));
	CHECK(as_i64(r) == 14, "12 | 10 == 14");
	CHECK_OK(blip_mp_xor(r, a, b));
	CHECK(as_i64(r) == 6, "12 ^ 10 == 6");
	blip_mp_set_i64(a, 5);
	CHECK_OK(blip_mp_not(r, a));
	CHECK(as_i64(r) == -6, "~5 == -6 (-(a+1))");
	blip_mp_set_i64(a, 3);
	CHECK_OK(blip_mp_shl(r, a, 2));
	CHECK(as_i64(r) == 12, "3 << 2 == 12");
	blip_mp_set_i64(a, 100);
	CHECK_OK(blip_mp_shr(r, a, 2));
	CHECK(as_i64(r) == 25, "100 >> 2 == 25");
done:
	blip_mp_destroy(a);
	blip_mp_destroy(b);
	blip_mp_destroy(r);
}

static void test_neg_abs(void) {
	blip_mp_t *a = mk_i64(7), *r = blip_mp_create();
	CHECK(a && r, "neg/abs: create");
	if (!a || !r) goto done;
	CHECK_OK(blip_mp_neg(r, a));
	CHECK(as_i64(r) == -7, "neg(7) == -7");
	blip_mp_set_i64(a, -3);
	CHECK_OK(blip_mp_neg(r, a));
	CHECK(as_i64(r) == 3, "neg(-3) == 3");
	blip_mp_set_i64(a, -5);
	CHECK_OK(blip_mp_abs(r, a));
	CHECK(as_i64(r) == 5, "abs(-5) == 5");
	blip_mp_set_i64(a, 5);
	CHECK_OK(blip_mp_abs(r, a));
	CHECK(as_i64(r) == 5, "abs(5) == 5");
done:
	blip_mp_destroy(a);
	blip_mp_destroy(r);
}

static void test_fits_matrix(void) {
	blip_mp_t *m = mk_i64(100);
	CHECK(m != NULL, "fits: create");
	if (!m) return;
	CHECK(blip_mp_fits_i64(m) == 1 && blip_mp_fits_u64(m) == 1, "100 fits i64/u64");
	CHECK(blip_mp_fits_i32(m) == 1 && blip_mp_fits_u32(m) == 1, "100 fits i32/u32");

	blip_mp_set_i64(m, INT64_MAX);
	CHECK(blip_mp_fits_i64(m) == 1, "INT64_MAX fits i64");
	CHECK(blip_mp_fits_i32(m) == 0, "INT64_MAX does not fit i32");

	blip_mp_set_i64(m, INT64_MIN);
	CHECK(blip_mp_fits_i64(m) == 1, "INT64_MIN fits i64");
	CHECK(blip_mp_fits_u64(m) == 0, "INT64_MIN (negative) does not fit u64");

	blip_mp_set_i64(m, -1);
	CHECK(blip_mp_fits_i64(m) == 1, "-1 fits i64");
	CHECK(blip_mp_fits_u64(m) == 0 && blip_mp_fits_u32(m) == 0, "-1 does not fit unsigned");

	blip_mp_set_i64(m, (int64_t)INT32_MAX);
	CHECK(blip_mp_fits_i32(m) == 1, "INT32_MAX fits i32");
	blip_mp_set_i64(m, (int64_t)INT32_MAX + 1);
	CHECK(blip_mp_fits_i32(m) == 0, "INT32_MAX+1 does not fit i32");
	CHECK(blip_mp_fits_i64(m) == 1, "INT32_MAX+1 fits i64");

	// A value above i64 max, built via set_str (set_u64 rejects > i64max).
	CHECK_OK(blip_mp_set_str(m, "18446744073709551615", 20, 10)); // UINT64_MAX
	CHECK(blip_mp_fits_u64(m) == 1, "UINT64_MAX fits u64");
	CHECK(blip_mp_fits_i64(m) == 0, "UINT64_MAX does not fit i64");
	blip_mp_destroy(m);
}

static void test_int_boundary_abi(void) {
	// Round-trip the extremes across the C ABI (sign-extension is a classic bug).
	blip_mp_t *m = blip_mp_create();
	CHECK(m != NULL, "boundary: create");
	if (!m) return;
	int64_t iv = 0;
	uint64_t uv = 0;

	CHECK_OK(blip_mp_set_i64(m, INT64_MIN));
	CHECK_OK(blip_mp_get_i64(m, &iv));
	CHECK(iv == INT64_MIN, "INT64_MIN round-trips");

	CHECK_OK(blip_mp_set_i64(m, INT64_MAX));
	CHECK_OK(blip_mp_get_i64(m, &iv));
	CHECK(iv == INT64_MAX, "INT64_MAX round-trips");

	// Largest u64 storable via set_u64 is i64max (set_u64 rejects above that).
	CHECK_OK(blip_mp_set_u64(m, (uint64_t)INT64_MAX));
	CHECK_OK(blip_mp_get_u64(m, &uv));
	CHECK(uv == (uint64_t)INT64_MAX, "i64max round-trips through u64");

	int rc = blip_mp_set_u64(m, (uint64_t)INT64_MAX + 1);
	CHECK(rc == BLIP_MP_ERR_OUT_OF_RANGE, "set_u64 above i64max -> OUT_OF_RANGE");

	// Negative -> get_u64 must report OUT_OF_RANGE, not silently wrap.
	CHECK_OK(blip_mp_set_i64(m, -1));
	rc = blip_mp_get_u64(m, &uv);
	CHECK(rc == BLIP_MP_ERR_OUT_OF_RANGE, "get_u64(-1) -> OUT_OF_RANGE");

	// A value > i64max -> get_i64 must report OUT_OF_RANGE.
	CHECK_OK(blip_mp_set_str(m, "18446744073709551615", 20, 10));
	rc = blip_mp_get_i64(m, &iv);
	// UINT64_MAX needs a 9-byte signed BLIP payload (leading 0x00 to stay
	// positive); the i64 decoder rejects L>8 as OverlongEncoding -> INVALID_INPUT.
	// Key property: it REFUSES rather than silently truncating. (Arguably this
	// should be OUT_OF_RANGE since the value is well-formed but too large -
	// flagged for review; asserting current contract here.)
	CHECK(rc == BLIP_MP_ERR_INVALID_INPUT, "get_i64(UINT64_MAX) refuses (INVALID_INPUT)");
	blip_mp_destroy(m);
}

static void test_bit_introspection(void) {
	blip_mp_t *m = mk_i64(7); // 0b111
	CHECK(m != NULL, "bits: create");
	if (!m) return;
	CHECK(blip_mp_popcount(m) == 3, "popcount(7) == 3");
	CHECK(blip_mp_scan1(m, 0) == 0, "scan1(7,0) == 0");
	CHECK(blip_mp_scan0(m, 0) == 3, "scan0(7,0) == 3");
	blip_mp_set_i64(m, 255);
	CHECK(blip_mp_popcount(m) == 8, "popcount(255) == 8");
	blip_mp_set_i64(m, 0);
	CHECK(blip_mp_popcount(m) == 0, "popcount(0) == 0");
	blip_mp_set_i64(m, 12); // 0b1100
	CHECK(blip_mp_scan1(m, 0) == 2, "scan1(12,0) == 2");
	CHECK(blip_mp_scan0(m, 0) == 0, "scan0(12,0) == 0");
	blip_mp_set_i64(m, -1);
	CHECK(blip_mp_popcount(m) == SIZE_MAX, "popcount(negative) == SIZE_MAX");
	blip_mp_destroy(m);
}

static void test_str_roundtrip(void) {
	blip_mp_t *m = blip_mp_create();
	CHECK(m != NULL, "str: create");
	if (!m) return;
	CHECK_OK(blip_mp_set_str(m, "12345", 5, 10));
	CHECK(as_i64(m) == 12345, "set_str dec 12345");
	CHECK_OK(blip_mp_set_str(m, "ff", 2, 16));
	CHECK(as_i64(m) == 255, "set_str hex ff == 255");
	CHECK_OK(blip_mp_set_str(m, "-42", 3, 10));
	CHECK(as_i64(m) == -42, "set_str -42");

	int rc = blip_mp_set_str(m, "xyz", 3, 10);
	CHECK(rc != BLIP_MP_OK, "set_str invalid digits errors");

	// to_string round-trip + required length + buffer-too-small path.
	blip_mp_set_i64(m, 255);
	char buf[16];
	size_t required = 0;
	CHECK_OK(blip_mp_to_string(m, 16, buf, sizeof(buf), &required));
	CHECK(required == 2, "to_string(255, base16) required == 2");
	CHECK(strcmp(buf, "ff") == 0, "to_string(255, base16) == \"ff\"");

	char tiny[1];
	required = 0;
	rc = blip_mp_to_string(m, 16, tiny, sizeof(tiny), &required);
	CHECK(rc == BLIP_MP_ERR_BUFFER_TOO_SMALL, "to_string tiny buf -> BUFFER_TOO_SMALL");
	CHECK(required == 2, "to_string still reports required on small buf");

	// Size-probe pattern: buf=NULL, buf_len=0 must report required, NOT crash
	// or return NULL_HANDLE (regression guard for the defensive redesign).
	required = 0;
	rc = blip_mp_to_string(m, 16, NULL, 0, &required);
	CHECK(rc == BLIP_MP_ERR_BUFFER_TOO_SMALL, "to_string(NULL buf, 0) -> BUFFER_TOO_SMALL (size probe)");
	CHECK(required == 2, "to_string size-probe reports required == 2");
	blip_mp_destroy(m);
}

static void test_rng_ops(void) {
	// Same seed -> identical stream (determinism), and bounds are respected.
	blip_mp_rng_t *r1 = blip_mp_rng_create(777);
	blip_mp_rng_t *r2 = blip_mp_rng_create(777);
	CHECK(r1 && r2, "rng: create pair");
	if (!r1 || !r2) {
		blip_mp_rng_destroy(r1);
		blip_mp_rng_destroy(r2);
		return;
	}
	blip_mp_t *a = blip_mp_create(), *b = blip_mp_create();
	CHECK(a && b, "rng: create operands");
	if (!a || !b) goto done;
	CHECK_OK(blip_mp_set_random_bits(a, r1, 64));
	CHECK_OK(blip_mp_set_random_bits(b, r2, 64));
	CHECK(blip_mp_cmp(a, b) == 0, "same seed -> same random_bits");
	CHECK(blip_mp_bit_len(a) <= 64, "random_bits(64) bit_len <= 64");

	blip_mp_t *bound = mk_i64(1000);
	CHECK(bound != NULL, "rng: bound");
	if (bound) {
		CHECK_OK(blip_mp_set_random_below(a, r1, bound));
		CHECK(blip_mp_sign(a) >= 0, "random_below result is non-negative");
		CHECK(blip_mp_cmp(a, bound) < 0, "random_below result < bound");
		blip_mp_destroy(bound);
	}
done:
	blip_mp_destroy(a);
	blip_mp_destroy(b);
	blip_mp_rng_destroy(r1);
	blip_mp_rng_destroy(r2);
}

static void test_fp_orphans(void) {
	blip_mp_fp_t *a = blip_mp_fp_create();
	blip_mp_fp_t *b = blip_mp_fp_create();
	blip_mp_fp_t *r = blip_mp_fp_create();
	CHECK(a && b && r, "fp: create");
	if (!a || !b || !r) goto done;

	// 1/4 and 1/2 are exact in binary -> get_f64_exact must succeed.
	CHECK_OK(blip_mp_fp_set_rational_binary(a, 1, 4)); // 0.25
	CHECK_OK(blip_mp_fp_set_rational_binary(b, 1, 2)); // 0.5
	CHECK(blip_mp_fp_get_base(a) == BLIP_MP_FP_BASE_BINARY, "rational_binary -> base 2");

	double d = -1.0;
	CHECK_OK(blip_mp_fp_get_f64_exact(a, &d));
	CHECK(d == 0.25, "fp 1/4 get_f64_exact == 0.25");

	CHECK(blip_mp_fp_is_zero(a) == 0, "1/4 is not zero");
	CHECK_OK(blip_mp_fp_set_rational_binary(r, 0, 1));
	CHECK(blip_mp_fp_is_zero(r) == 1, "0/1 is zero");

	int c = 99;
	CHECK_OK(blip_mp_fp_cmp(a, b, &c));
	CHECK(c == -1, "cmp(1/4, 1/2) == -1");
	int eq = 99;
	CHECK_OK(blip_mp_fp_eq(a, a, &eq));
	CHECK(eq == 1, "eq(1/4, 1/4) == 1");
	CHECK_OK(blip_mp_fp_eq(a, b, &eq));
	CHECK(eq == 0, "eq(1/4, 1/2) == 0");

	CHECK_OK(blip_mp_fp_sub(r, b, a)); // 1/2 - 1/4 = 1/4
	CHECK_OK(blip_mp_fp_get_f64_exact(r, &d));
	CHECK(d == 0.25, "1/2 - 1/4 == 0.25");

	CHECK_OK(blip_mp_fp_mul(r, b, b)); // 1/2 * 1/2 = 1/4
	CHECK_OK(blip_mp_fp_get_f64_exact(r, &d));
	CHECK(d == 0.25, "1/2 * 1/2 == 0.25");

	// to_binary on an already-binary value preserves it.
	CHECK_OK(blip_mp_fp_to_binary(r, a));
	CHECK_OK(blip_mp_fp_get_f64_exact(r, &d));
	CHECK(d == 0.25, "to_binary(1/4) == 0.25");

	// get_scale / get_mantissa: smoke (borrowed mantissa, do NOT destroy).
	(void)blip_mp_fp_get_scale(a);
	blip_mp_t *mant = blip_mp_fp_get_mantissa(a);
	CHECK(mant != NULL, "fp_get_mantissa non-NULL");

	// round_to_scale on an integer value at scale 0 is the identity.
	blip_mp_fp_t *i = blip_mp_fp_create();
	if (i) {
		CHECK_OK(blip_mp_fp_set_i64(i, 5, 0, BLIP_MP_FP_BASE_BINARY)); // value 5
		CHECK_OK(blip_mp_fp_round_to_scale(r, i, 0, BLIP_MP_FP_ROUND_HALF_TO_EVEN));
		CHECK_OK(blip_mp_fp_get_f64_exact(r, &d));
		CHECK(d == 5.0, "round_to_scale(5 @ scale0) == 5");
		blip_mp_fp_destroy(i);
	}
done:
	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	blip_mp_fp_destroy(r);
}

// ======================================================================
// NULL-argument matrix (fleet review 2026-06-01 + Peter's "full defensive"
// directive). Every export is now NULL-safe: a NULL required handle returns
// a defined value, never a segfault. Status funcs -> BLIP_MP_ERR_NULL_HANDLE;
// value-returning queries -> documented out-of-band sentinels (see header).
// ======================================================================
static void test_null_matrix(void) {
	const int NH = BLIP_MP_ERR_NULL_HANDLE;

	// _destroy on NULL is a no-op (mirrors free()); must not crash.
	blip_mp_destroy(NULL);
	blip_mp_rng_destroy(NULL);
	blip_mp_fp_destroy(NULL);

	// --- Status functions: NULL handle -> BLIP_MP_ERR_NULL_HANDLE ---------
	CHECK(blip_mp_set_i64(NULL, 0) == NH, "set_i64(NULL)");
	CHECK(blip_mp_get_i64(NULL, NULL) == NH, "get_i64(NULL)");
	CHECK(blip_mp_set_u64(NULL, 0) == NH, "set_u64(NULL)");
	CHECK(blip_mp_get_u64(NULL, NULL) == NH, "get_u64(NULL)");
	CHECK(blip_mp_set_bytes(NULL, NULL, 0) == NH, "set_bytes(NULL)");
	CHECK(blip_mp_add(NULL, NULL, NULL) == NH, "add(NULL)");
	CHECK(blip_mp_sub(NULL, NULL, NULL) == NH, "sub(NULL)");
	CHECK(blip_mp_mul(NULL, NULL, NULL) == NH, "mul(NULL)");
	CHECK(blip_mp_div(NULL, NULL, NULL) == NH, "div(NULL)");
	CHECK(blip_mp_mod(NULL, NULL, NULL) == NH, "mod(NULL)");
	CHECK(blip_mp_div_mod(NULL, NULL, NULL, NULL) == NH, "div_mod(NULL)");
	CHECK(blip_mp_powm(NULL, NULL, NULL, NULL) == NH, "powm(NULL)");
	CHECK(blip_mp_inv_mod(NULL, NULL, NULL) == NH, "inv_mod(NULL)");
	CHECK(blip_mp_and(NULL, NULL, NULL) == NH, "and(NULL)");
	CHECK(blip_mp_or(NULL, NULL, NULL) == NH, "or(NULL)");
	CHECK(blip_mp_xor(NULL, NULL, NULL) == NH, "xor(NULL)");
	CHECK(blip_mp_not(NULL, NULL) == NH, "not(NULL)");
	CHECK(blip_mp_shl(NULL, NULL, 0) == NH, "shl(NULL)");
	CHECK(blip_mp_shr(NULL, NULL, 0) == NH, "shr(NULL)");
	CHECK(blip_mp_neg(NULL, NULL) == NH, "neg(NULL)");
	CHECK(blip_mp_abs(NULL, NULL) == NH, "abs(NULL)");
	CHECK(blip_mp_gcd(NULL, NULL, NULL) == NH, "gcd(NULL)");
	CHECK(blip_mp_lcm(NULL, NULL, NULL) == NH, "lcm(NULL)");
	CHECK(blip_mp_set_random_bits(NULL, NULL, 0) == NH, "set_random_bits(NULL)");
	CHECK(blip_mp_set_random_below(NULL, NULL, NULL) == NH, "set_random_below(NULL)");
	CHECK(blip_mp_set_str(NULL, NULL, 0, 10) == NH, "set_str(NULL)");
	CHECK(blip_mp_to_string(NULL, 10, NULL, 0, NULL) == NH, "to_string(NULL)");
	CHECK(blip_mp_is_probably_prime(NULL, NULL, 0, NULL) == NH, "is_probably_prime(NULL)");
	CHECK(blip_mp_next_prime(NULL, NULL, NULL) == NH, "next_prime(NULL)");
	CHECK(blip_mp_isqrt(NULL, NULL) == NH, "isqrt(NULL)");
	CHECK(blip_mp_isqrt_rem(NULL, NULL, NULL) == NH, "isqrt_rem(NULL)");
	CHECK(blip_mp_iroot(NULL, NULL, 2) == NH, "iroot(NULL)");
	CHECK(blip_mp_jacobi(NULL, NULL, NULL) == NH, "jacobi(NULL)");
	CHECK(blip_mp_legendre(NULL, NULL, NULL) == NH, "legendre(NULL)");
	CHECK(blip_mp_kronecker(NULL, NULL, NULL) == NH, "kronecker(NULL)");
	CHECK(blip_mp_factorial(NULL, 0) == NH, "factorial(NULL)");
	CHECK(blip_mp_binomial(NULL, 0, 0) == NH, "binomial(NULL)");
	CHECK(blip_mp_fibonacci(NULL, 0) == NH, "fibonacci(NULL)");
	CHECK(blip_mp_fp_set_i64(NULL, 0, 0, BLIP_MP_FP_BASE_BINARY) == NH, "fp_set_i64(NULL)");
	CHECK(blip_mp_fp_set_rational_decimal(NULL, 0, 1) == NH, "fp_set_rational_decimal(NULL)");
	CHECK(blip_mp_fp_set_rational_binary(NULL, 0, 1) == NH, "fp_set_rational_binary(NULL)");
	CHECK(blip_mp_fp_set_str(NULL, NULL, 0, BLIP_MP_FP_BASE_DECIMAL) == NH, "fp_set_str(NULL)");
	CHECK(blip_mp_fp_set_f64(NULL, 0.0) == NH, "fp_set_f64(NULL)");
	CHECK(blip_mp_fp_get_f64_exact(NULL, NULL) == NH, "fp_get_f64_exact(NULL)");
	CHECK(blip_mp_fp_canonicalize(NULL) == NH, "fp_canonicalize(NULL)");
	CHECK(blip_mp_fp_cmp(NULL, NULL, NULL) == NH, "fp_cmp(NULL)");
	CHECK(blip_mp_fp_eq(NULL, NULL, NULL) == NH, "fp_eq(NULL)");
	CHECK(blip_mp_fp_add(NULL, NULL, NULL) == NH, "fp_add(NULL)");
	CHECK(blip_mp_fp_sub(NULL, NULL, NULL) == NH, "fp_sub(NULL)");
	CHECK(blip_mp_fp_mul(NULL, NULL, NULL) == NH, "fp_mul(NULL)");
	CHECK(blip_mp_fp_div_exact(NULL, NULL, NULL) == NH, "fp_div_exact(NULL)");
	CHECK(blip_mp_fp_div_precision(NULL, NULL, NULL, 0, NULL) == NH, "fp_div_precision(NULL)");
	CHECK(blip_mp_fp_to_decimal(NULL, NULL) == NH, "fp_to_decimal(NULL)");
	CHECK(blip_mp_fp_to_binary(NULL, NULL) == NH, "fp_to_binary(NULL)");
	CHECK(blip_mp_fp_round_to_scale(NULL, NULL, 0, BLIP_MP_FP_ROUND_HALF_TO_EVEN) == NH, "fp_round_to_scale(NULL)");
	CHECK(blip_mp_fp_round_to_mp(NULL, NULL, BLIP_MP_FP_ROUND_HALF_TO_EVEN) == NH, "fp_round_to_mp(NULL)");
	CHECK(blip_mp_fp_to_string_canonical(NULL, NULL, 0, NULL) == NH, "fp_to_string_canonical(NULL)");
	CHECK(blip_mp_fp_to_string_fixed(NULL, 0, NULL, 0, NULL) == NH, "fp_to_string_fixed(NULL)");
	CHECK(blip_mp_fp_to_string_scientific(NULL, NULL, 0, NULL) == NH, "fp_to_string_scientific(NULL)");
	CHECK(blip_mp_fp_get_f64(NULL, BLIP_MP_FP_ROUND_HALF_TO_EVEN, NULL) == NH, "fp_get_f64(NULL)");

	// --- Value-returning queries: documented out-of-band sentinels --------
	CHECK(blip_mp_bytes(NULL) == NULL, "bytes(NULL) == NULL");
	CHECK(blip_mp_bit_at(NULL, 0) == -1, "bit_at(NULL) == -1");
	CHECK(blip_mp_bit_len(NULL) == SIZE_MAX, "bit_len(NULL) == SIZE_MAX");
	CHECK(blip_mp_byte_len(NULL) == SIZE_MAX, "byte_len(NULL) == SIZE_MAX");
	CHECK(blip_mp_cmp(NULL, NULL) == -2, "cmp(NULL) == -2");
	CHECK(blip_mp_sign(NULL) == -2, "sign(NULL) == -2");
	CHECK(blip_mp_is_zero(NULL) == -1, "is_zero(NULL) == -1");
	CHECK(blip_mp_fits_i64(NULL) == -1, "fits_i64(NULL) == -1");
	CHECK(blip_mp_fits_u64(NULL) == -1, "fits_u64(NULL) == -1");
	CHECK(blip_mp_fits_i32(NULL) == -1, "fits_i32(NULL) == -1");
	CHECK(blip_mp_fits_u32(NULL) == -1, "fits_u32(NULL) == -1");
	CHECK(blip_mp_popcount(NULL) == SIZE_MAX, "popcount(NULL) == SIZE_MAX");
	CHECK(blip_mp_scan0(NULL, 0) == SIZE_MAX, "scan0(NULL) == SIZE_MAX");
	CHECK(blip_mp_scan1(NULL, 0) == SIZE_MAX, "scan1(NULL) == SIZE_MAX");
	CHECK(blip_mp_is_perfect_square(NULL) == -1, "is_perfect_square(NULL) == -1");
	CHECK(blip_mp_fp_is_zero(NULL) == -1, "fp_is_zero(NULL) == -1");
	CHECK(blip_mp_fp_get_base(NULL) == -1, "fp_get_base(NULL) == -1");
	CHECK(blip_mp_fp_get_scale(NULL) == INT32_MIN, "fp_get_scale(NULL) == INT32_MIN");
	CHECK(blip_mp_fp_get_mantissa(NULL) == NULL, "fp_get_mantissa(NULL) == NULL");

	// --- Non-first NULL positions are guarded too (sampling) --------------
	blip_mp_t *m = blip_mp_create();
	if (m) {
		blip_mp_set_i64(m, 7);
		CHECK(blip_mp_add(m, NULL, m) == NH, "add(_, NULL, _) guarded");
		CHECK(blip_mp_add(m, m, NULL) == NH, "add(_, _, NULL) guarded");
		CHECK(blip_mp_powm(m, m, NULL, m) == NH, "powm 3rd-arg NULL guarded");
		int64_t iv = 0;
		(void)iv;
		CHECK(blip_mp_get_i64(m, NULL) == NH, "get_i64(_, NULL out) guarded");
		char buf[8];
		size_t req = 0;
		CHECK(blip_mp_to_string(m, 10, buf, sizeof(buf), NULL) == NH, "to_string NULL required guarded");
		CHECK(blip_mp_to_string(m, 10, NULL, 8, &req) == NH, "to_string NULL buf guarded");
		blip_mp_destroy(m);
	}
}

int main(void) {
	test_lifecycle();
	test_set_get_i64();
	test_u64_roundtrip();
	test_bit_access();
	test_arithmetic();
	test_cmp();
	test_division_by_zero();
	test_bytes_roundtrip();
	test_powm();
	test_inv_mod();
	test_fp_disrupt_ieee754();
	test_fp_div_exact_or_error();
	test_fp_setf64_killshot();
	test_fp_round_modes();
	test_fp_to_string_fixed();
	test_fp_to_string_scientific();
	test_fp_get_f64_with_mode();

	// Expanded coverage (fleet review 2026-06-01): the 47 exports below
	// previously had no smoke coverage; plus an int overflow/boundary matrix.
	test_gcd_lcm();
	test_symbols();
	test_roots();
	test_combinatorics();
	test_primality();
	test_bitwise();
	test_neg_abs();
	test_fits_matrix();
	test_int_boundary_abi();
	test_bit_introspection();
	test_str_roundtrip();
	test_rng_ops();
	test_fp_orphans();
	test_null_matrix();

	if (failures == 0) {
		printf("c_smoke: all checks passed\n");
		return 0;
	}
	fprintf(stderr, "c_smoke: %d failure(s)\n", failures);
	return 1;
}
