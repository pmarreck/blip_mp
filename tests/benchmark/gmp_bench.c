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

int main(void) {
	printf("=== GMP add benchmark ===\n");
	printf("small_iters=%llu large_iters=%llu\n\n",
		(unsigned long long)ITERATIONS_SMALL, (unsigned long long)ITERATIONS_LARGE);

	size_t n = sizeof(BUCKETS) / sizeof(BUCKETS[0]);
	for (size_t i = 0; i < n; i++) {
		double ns_per_op = benchmark_bucket(&BUCKETS[i]);
		printf("RESULT bucket=%s ns_per_op=%.2f\n", BUCKETS[i].name, ns_per_op);
	}
	size_t m = sizeof(LARGE_BUCKETS) / sizeof(LARGE_BUCKETS[0]);
	for (size_t i = 0; i < m; i++) {
		double ns_per_op = benchmark_large_bucket(&LARGE_BUCKETS[i]);
		printf("RESULT bucket=%s ns_per_op=%.2f\n", LARGE_BUCKETS[i].name, ns_per_op);
	}
	return 0;
}
