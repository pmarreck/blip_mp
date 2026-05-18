/* Tier-0/1 add throughput benchmark for GMP — same shape as blip_mp_bench.zig.
 *
 * Workload: pre-build a pool of mpz_t values, then time N iterations of
 *   mpz_add(result, pool[i % POOL_SIZE], pool[(i+1) % POOL_SIZE])
 *
 * Build via build.zig (links libgmp from Nix). Run produces RESULT lines
 * matching the blip_mp_bench format for easy diffing.
 */

#include <gmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#define POOL_SIZE 256
#define ITERATIONS_SMALL 5000000ULL
#define ITERATIONS_LARGE 500000ULL

typedef struct {
	const char *name;
	long min;
	long max;
} Bucket;

static const Bucket BUCKETS[] = {
	{"L=0 (immediate, 0..127)", 1, 127},
	{"L=2 (128..32K)", 128, 32000},
	{"L=3 (~16-bit..~24-bit)", 100000, 8000000},
	{"L=4 (~32-bit)", 10000000, 1000000000},
};

typedef struct {
	const char *name;
	int bits;
} LargeBucket;

static const LargeBucket LARGE_BUCKETS[] = {
	{"128-bit",   128},
	{"192-bit",   192},
	{"256-bit",   256},
	{"384-bit",   384},
	{"512-bit",   512},
	{"768-bit",   768},
	{"1024-bit",  1024},
	{"1536-bit",  1536},
	{"2048-bit",  2048},
	{"3072-bit",  3072},
	{"4096-bit",  4096},
	{"6144-bit",  6144},
	{"8192-bit",  8192},
	{"16384-bit", 16384},
	{"32768-bit", 32768},
};

#define LARGEST_BYTES (32768 / 8)

/* Mirrors of the modular-arith buckets in tests/benchmark/blip_mp_bench.zig.
 * Smaller per-bucket since each op (divMod, powm, invMod) is more expensive. */
static const LargeBucket DIVMOD_BUCKETS[] = {
	{"256-bit",  256},
	{"512-bit",  512},
	{"1024-bit", 1024},
	{"2048-bit", 2048},
	{"4096-bit", 4096},
	{"8192-bit", 8192},
	{"16384-bit", 16384},
	{"32768-bit", 32768},
	{"65536-bit", 65536},
};
static const LargeBucket POWM_BUCKETS[] = {
	{"512-bit",  512},
	{"1024-bit", 1024},
	{"2048-bit", 2048},
	{"3072-bit", 3072},
};
static const LargeBucket INVMOD_BUCKETS[] = {
	{"128-bit",  128},
	{"192-bit",  192},
	{"256-bit",  256},
	{"384-bit",  384},
	{"512-bit",  512},
	{"768-bit",  768},
	{"1024-bit", 1024},
	{"1536-bit", 1536},
	{"2048-bit", 2048},
};

static uint64_t divmod_iters(int bits) {
	if (bits <= 512) return 200000ULL;
	if (bits <= 2048) return 50000ULL;
	if (bits <= 4096) return 20000ULL;
	if (bits <= 8192) return 5000ULL;
	if (bits <= 16384) return 1000ULL;
	if (bits <= 32768) return 300ULL;
	return 100ULL;
}
static uint64_t powm_iters(int bits) {
	if (bits <= 512) return 5000ULL;
	if (bits <= 1024) return 1000ULL;
	if (bits <= 2048) return 200ULL;
	return 50ULL;
}
static uint64_t invmod_iters(int bits) {
	if (bits <= 256) return 100000ULL;
	if (bits <= 512) return 50000ULL;
	if (bits <= 1024) return 10000ULL;
	return 2000ULL;
}

/* Fill an mpz_t with random positive bytes of given count, derived from a seed.
 * Matches blip_mp_bench.zig:buildRandomPositiveMp's payload generation. */
static void fill_pos_mpz(mpz_t out, int byte_count, uint64_t seed) {
	unsigned char *payload = (unsigned char *)malloc((size_t)byte_count);
	if (!payload) { perror("malloc"); exit(1); }
	uint64_t s = seed;
	for (int k = 0; k < byte_count; k++) {
		s ^= s << 13; s ^= s >> 7; s ^= s << 17;
		payload[k] = (unsigned char)(s & 0xFF);
	}
	payload[byte_count - 1] &= 0x7F;
	if (payload[byte_count - 1] == 0) payload[byte_count - 1] = 0x40;
	mpz_import(out, (size_t)byte_count, -1, 1, 0, 0, payload);
	free(payload);
}
static void fill_pos_odd_mpz(mpz_t out, int byte_count, uint64_t seed) {
	unsigned char *payload = (unsigned char *)malloc((size_t)byte_count);
	if (!payload) { perror("malloc"); exit(1); }
	uint64_t s = seed;
	for (int k = 0; k < byte_count; k++) {
		s ^= s << 13; s ^= s >> 7; s ^= s << 17;
		payload[k] = (unsigned char)(s & 0xFF);
	}
	payload[byte_count - 1] &= 0x7F;
	if (payload[byte_count - 1] == 0) payload[byte_count - 1] = 0x40;
	payload[0] |= 1;
	mpz_import(out, (size_t)byte_count, -1, 1, 0, 0, payload);
	free(payload);
}

static double benchmark_bucket(const Bucket *bucket) {
	mpz_t pool[POOL_SIZE];
	for (int i = 0; i < POOL_SIZE; i++) {
		mpz_init(pool[i]);
		double t = (double)i / (double)(POOL_SIZE - 1);
		double span = (double)(bucket->max - bucket->min);
		long v = bucket->min + (long)(t * span);
		mpz_set_si(pool[i], v);
	}

	mpz_t result;
	mpz_init(result);

	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC, &start);
	for (uint64_t i = 0; i < ITERATIONS_SMALL; i++) {
		mpz_add(result, pool[i & (POOL_SIZE - 1)], pool[(i + 1) & (POOL_SIZE - 1)]);
	}
	clock_gettime(CLOCK_MONOTONIC, &end);

	double elapsed_ns = (end.tv_sec - start.tv_sec) * 1e9 + (end.tv_nsec - start.tv_nsec);

	volatile mp_limb_t guard = mpz_size(result) > 0 ? mpz_getlimbn(result, 0) : 0;
	(void)guard;

	for (int i = 0; i < POOL_SIZE; i++) mpz_clear(pool[i]);
	mpz_clear(result);

	return elapsed_ns / (double)ITERATIONS_SMALL;
}

static double benchmark_large_bucket(const LargeBucket *lb) {
	mpz_t pool[POOL_SIZE];
	const int byte_count = lb->bits / 8;
	unsigned char *payload = (unsigned char *)malloc((size_t)byte_count);
	if (!payload) { perror("malloc"); exit(1); }
	for (int i = 0; i < POOL_SIZE; i++) {
		mpz_init(pool[i]);
		uint64_t s = 0xCAFEBEEFULL + (uint64_t)i;
		for (int k = 0; k < byte_count; k++) {
			s ^= s << 13; s ^= s >> 7; s ^= s << 17;
			payload[k] = (unsigned char)(s & 0xFF);
		}
		payload[byte_count - 1] &= 0x7F; /* positive */
		mpz_import(pool[i], (size_t)byte_count, -1, 1, 0, 0, payload);
	}
	free(payload);

	mpz_t result;
	mpz_init(result);

	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC, &start);
	for (uint64_t i = 0; i < ITERATIONS_LARGE; i++) {
		mpz_add(result, pool[i & (POOL_SIZE - 1)], pool[(i + 1) & (POOL_SIZE - 1)]);
	}
	clock_gettime(CLOCK_MONOTONIC, &end);

	double elapsed_ns = (end.tv_sec - start.tv_sec) * 1e9 + (end.tv_nsec - start.tv_nsec);

	volatile mp_limb_t guard = mpz_size(result) > 0 ? mpz_getlimbn(result, 0) : 0;
	(void)guard;

	for (int i = 0; i < POOL_SIZE; i++) mpz_clear(pool[i]);
	mpz_clear(result);

	return elapsed_ns / (double)ITERATIONS_LARGE;
}

static double benchmark_large_bucket_sub(const LargeBucket *lb) {
	mpz_t pool[POOL_SIZE];
	const int byte_count = lb->bits / 8;
	unsigned char *payload = (unsigned char *)malloc((size_t)byte_count);
	if (!payload) { perror("malloc"); exit(1); }
	for (int i = 0; i < POOL_SIZE; i++) {
		mpz_init(pool[i]);
		uint64_t s = 0xCAFEBEEFULL + (uint64_t)i;
		for (int k = 0; k < byte_count; k++) {
			s ^= s << 13; s ^= s >> 7; s ^= s << 17;
			payload[k] = (unsigned char)(s & 0xFF);
		}
		payload[byte_count - 1] &= 0x7F; /* positive */
		mpz_import(pool[i], (size_t)byte_count, -1, 1, 0, 0, payload);
	}
	free(payload);

	mpz_t result;
	mpz_init(result);

	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC, &start);
	for (uint64_t i = 0; i < ITERATIONS_LARGE; i++) {
		mpz_sub(result, pool[i & (POOL_SIZE - 1)], pool[(i + 1) & (POOL_SIZE - 1)]);
	}
	clock_gettime(CLOCK_MONOTONIC, &end);

	double elapsed_ns = (end.tv_sec - start.tv_sec) * 1e9 + (end.tv_nsec - start.tv_nsec);

	volatile mp_limb_t guard = mpz_size(result) > 0 ? mpz_getlimbn(result, 0) : 0;
	(void)guard;

	for (int i = 0; i < POOL_SIZE; i++) mpz_clear(pool[i]);
	mpz_clear(result);

	return elapsed_ns / (double)ITERATIONS_LARGE;
}

static uint64_t mul_iters(int bits) {
	if (bits <= 256) return 500000ULL;
	if (bits <= 1024) return 100000ULL;
	if (bits <= 4096) return 20000ULL;
	return 5000ULL;
}

static double benchmark_large_bucket_mul(const LargeBucket *lb) {
	mpz_t pool[POOL_SIZE];
	const int byte_count = lb->bits / 8;
	unsigned char *payload = (unsigned char *)malloc((size_t)byte_count);
	if (!payload) { perror("malloc"); exit(1); }
	for (int i = 0; i < POOL_SIZE; i++) {
		mpz_init(pool[i]);
		uint64_t s = 0xCAFEBEEFULL + (uint64_t)i;
		for (int k = 0; k < byte_count; k++) {
			s ^= s << 13; s ^= s >> 7; s ^= s << 17;
			payload[k] = (unsigned char)(s & 0xFF);
		}
		payload[byte_count - 1] &= 0x7F;
		mpz_import(pool[i], (size_t)byte_count, -1, 1, 0, 0, payload);
	}
	free(payload);

	mpz_t result;
	mpz_init(result);

	const uint64_t iters = mul_iters(lb->bits);
	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC, &start);
	for (uint64_t i = 0; i < iters; i++) {
		mpz_mul(result, pool[i & (POOL_SIZE - 1)], pool[(i + 1) & (POOL_SIZE - 1)]);
	}
	clock_gettime(CLOCK_MONOTONIC, &end);

	double elapsed_ns = (end.tv_sec - start.tv_sec) * 1e9 + (end.tv_nsec - start.tv_nsec);

	volatile mp_limb_t guard = mpz_size(result) > 0 ? mpz_getlimbn(result, 0) : 0;
	(void)guard;

	for (int i = 0; i < POOL_SIZE; i++) mpz_clear(pool[i]);
	mpz_clear(result);

	return elapsed_ns / (double)iters;
}

static double benchmark_large_bucket_divmod(const LargeBucket *lb) {
	const int dividend_bytes = lb->bits / 8;
	const int divisor_bytes = (dividend_bytes / 2) > 0 ? dividend_bytes / 2 : 1;
	mpz_t dividend_pool[POOL_SIZE], divisor_pool[POOL_SIZE];
	for (int i = 0; i < POOL_SIZE; i++) {
		mpz_init(dividend_pool[i]);
		mpz_init(divisor_pool[i]);
		fill_pos_mpz(dividend_pool[i], dividend_bytes, 0xD1DULL + (uint64_t)i);
		fill_pos_mpz(divisor_pool[i], divisor_bytes, 0xDDULL + (uint64_t)i);
	}

	mpz_t q, r;
	mpz_init(q); mpz_init(r);

	const uint64_t iters = divmod_iters(lb->bits);
	/* Warmup before measurement (matches blip_mp_bench.zig's pattern). */
	mpz_tdiv_qr(q, r, dividend_pool[0], divisor_pool[0]);

	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC, &start);
	for (uint64_t i = 0; i < iters; i++) {
		mpz_tdiv_qr(q, r, dividend_pool[i & (POOL_SIZE - 1)], divisor_pool[i & (POOL_SIZE - 1)]);
	}
	clock_gettime(CLOCK_MONOTONIC, &end);
	double elapsed_ns = (end.tv_sec - start.tv_sec) * 1e9 + (end.tv_nsec - start.tv_nsec);

	volatile mp_limb_t guard = mpz_size(q) > 0 ? mpz_getlimbn(q, 0) : 0;
	(void)guard;
	for (int i = 0; i < POOL_SIZE; i++) { mpz_clear(dividend_pool[i]); mpz_clear(divisor_pool[i]); }
	mpz_clear(q); mpz_clear(r);
	return elapsed_ns / (double)iters;
}

static double benchmark_large_bucket_powm(const LargeBucket *lb) {
	const int byte_count = lb->bits / 8;
	mpz_t base_pool[POOL_SIZE], exp_pool[POOL_SIZE], mod_pool[POOL_SIZE];
	for (int i = 0; i < POOL_SIZE; i++) {
		mpz_init(base_pool[i]); mpz_init(exp_pool[i]); mpz_init(mod_pool[i]);
		fill_pos_mpz(base_pool[i], byte_count, 0xBA5EULL + (uint64_t)i);
		fill_pos_mpz(exp_pool[i], byte_count, 0x77ULL + (uint64_t)i);
		fill_pos_odd_mpz(mod_pool[i], byte_count, 0x70DULL + (uint64_t)i);
	}

	mpz_t result;
	mpz_init(result);

	const uint64_t iters = powm_iters(lb->bits);
	/* Warmup before measurement. */
	mpz_powm(result, base_pool[0], exp_pool[0], mod_pool[0]);

	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC, &start);
	for (uint64_t i = 0; i < iters; i++) {
		mpz_powm(result, base_pool[i & (POOL_SIZE - 1)], exp_pool[i & (POOL_SIZE - 1)], mod_pool[i & (POOL_SIZE - 1)]);
	}
	clock_gettime(CLOCK_MONOTONIC, &end);
	double elapsed_ns = (end.tv_sec - start.tv_sec) * 1e9 + (end.tv_nsec - start.tv_nsec);

	volatile mp_limb_t guard = mpz_size(result) > 0 ? mpz_getlimbn(result, 0) : 0;
	(void)guard;
	for (int i = 0; i < POOL_SIZE; i++) { mpz_clear(base_pool[i]); mpz_clear(exp_pool[i]); mpz_clear(mod_pool[i]); }
	mpz_clear(result);
	return elapsed_ns / (double)iters;
}

static double benchmark_large_bucket_invmod(const LargeBucket *lb) {
	const int byte_count = lb->bits / 8;
	mpz_t a_pool[POOL_SIZE], m_pool[POOL_SIZE];
	for (int i = 0; i < POOL_SIZE; i++) {
		mpz_init(a_pool[i]); mpz_init(m_pool[i]);
		fill_pos_mpz(a_pool[i], byte_count, 0xA1AULL + (uint64_t)i);
		fill_pos_odd_mpz(m_pool[i], byte_count, 0x6DULL + (uint64_t)i);
	}

	mpz_t r;
	mpz_init(r);

	const uint64_t iters = invmod_iters(lb->bits);
	/* Warmup before measurement. */
	(void)mpz_invert(r, a_pool[0], m_pool[0]);

	struct timespec start, end;
	clock_gettime(CLOCK_MONOTONIC, &start);
	uint64_t ok_count = 0;
	for (uint64_t i = 0; i < iters; i++) {
		if (mpz_invert(r, a_pool[i & (POOL_SIZE - 1)], m_pool[i & (POOL_SIZE - 1)])) ok_count++;
	}
	clock_gettime(CLOCK_MONOTONIC, &end);
	double elapsed_ns = (end.tv_sec - start.tv_sec) * 1e9 + (end.tv_nsec - start.tv_nsec);

	volatile mp_limb_t guard = mpz_size(r) > 0 ? mpz_getlimbn(r, 0) : 0;
	(void)guard;
	(void)ok_count;
	for (int i = 0; i < POOL_SIZE; i++) { mpz_clear(a_pool[i]); mpz_clear(m_pool[i]); }
	mpz_clear(r);
	return elapsed_ns / (double)iters;
}

int main(void) {
	printf("=== GMP add benchmark ===\n");
	printf("small_iters=%llu large_iters=%llu\n\n",
		(unsigned long long)ITERATIONS_SMALL, (unsigned long long)ITERATIONS_LARGE);

	size_t n = sizeof(BUCKETS) / sizeof(BUCKETS[0]);
	for (size_t i = 0; i < n; i++) {
		double ns_per_op = benchmark_bucket(&BUCKETS[i]);
		printf("RESULT mpz_add bucket=%s ns_per_op=%.2f\n", BUCKETS[i].name, ns_per_op);
	}
	size_t m = sizeof(LARGE_BUCKETS) / sizeof(LARGE_BUCKETS[0]);
	for (size_t i = 0; i < m; i++) {
		double ns_per_op = benchmark_large_bucket(&LARGE_BUCKETS[i]);
		printf("RESULT mpz_add bucket=%s ns_per_op=%.2f\n", LARGE_BUCKETS[i].name, ns_per_op);
	}

	printf("\n--- subtraction ---\n");
	for (size_t i = 0; i < m; i++) {
		double ns_per_op = benchmark_large_bucket_sub(&LARGE_BUCKETS[i]);
		printf("RESULT mpz_sub bucket=%s ns_per_op=%.2f\n", LARGE_BUCKETS[i].name, ns_per_op);
	}

	printf("\n--- multiplication ---\n");
	for (size_t i = 0; i < m; i++) {
		double ns_per_op = benchmark_large_bucket_mul(&LARGE_BUCKETS[i]);
		printf("RESULT mpz_mul bucket=%s ns_per_op=%.2f\n", LARGE_BUCKETS[i].name, ns_per_op);
	}

	printf("\n--- division (mpz_tdiv_qr, N-bit / ~N/2-bit) ---\n");
	size_t md = sizeof(DIVMOD_BUCKETS) / sizeof(DIVMOD_BUCKETS[0]);
	for (size_t i = 0; i < md; i++) {
		double ns_per_op = benchmark_large_bucket_divmod(&DIVMOD_BUCKETS[i]);
		printf("RESULT mpz_tdiv_qr bucket=%s ns_per_op=%.2f\n", DIVMOD_BUCKETS[i].name, ns_per_op);
	}

	printf("\n--- modular exponentiation (mpz_powm, base^exp mod n at N-bit) ---\n");
	size_t mp = sizeof(POWM_BUCKETS) / sizeof(POWM_BUCKETS[0]);
	for (size_t i = 0; i < mp; i++) {
		double ns_per_op = benchmark_large_bucket_powm(&POWM_BUCKETS[i]);
		printf("RESULT mpz_powm bucket=%s ns_per_op=%.2f\n", POWM_BUCKETS[i].name, ns_per_op);
	}

	printf("\n--- modular inverse (mpz_invert, a^-1 mod m at N-bit) ---\n");
	size_t mi = sizeof(INVMOD_BUCKETS) / sizeof(INVMOD_BUCKETS[0]);
	for (size_t i = 0; i < mi; i++) {
		double ns_per_op = benchmark_large_bucket_invmod(&INVMOD_BUCKETS[i]);
		printf("RESULT mpz_invert bucket=%s ns_per_op=%.2f\n", INVMOD_BUCKETS[i].name, ns_per_op);
	}
	return 0;
}
