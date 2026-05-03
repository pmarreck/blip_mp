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

	if (failures == 0) {
		printf("c_smoke: all checks passed\n");
		return 0;
	}
	fprintf(stderr, "c_smoke: %d failure(s)\n", failures);
	return 1;
}
