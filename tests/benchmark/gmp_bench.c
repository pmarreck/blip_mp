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
#define ITERATIONS 5000000ULL

typedef struct {
	const char *name;
	long min;
	long max;
} Bucket;

static const Bucket BUCKETS[] = {
	{"immediate (0..127)", 1, 127},
	{"L=1 (128..255)", 128, 255},
	{"L=2 (256..32767)", 1000, 32000},
	{"L=3 (32768..8M)", 100000, 8000000},
	{"L=4 (>8M..2G)", 10000000, 1000000000},
};

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
	for (uint64_t i = 0; i < ITERATIONS; i++) {
		mpz_add(result, pool[i & (POOL_SIZE - 1)], pool[(i + 1) & (POOL_SIZE - 1)]);
	}
	clock_gettime(CLOCK_MONOTONIC, &end);

	double elapsed_ns = (end.tv_sec - start.tv_sec) * 1e9 + (end.tv_nsec - start.tv_nsec);

	/* Sanity: print result limb so optimizer keeps the loop body. */
	volatile mp_limb_t guard = mpz_size(result) > 0 ? mpz_getlimbn(result, 0) : 0;
	(void)guard;

	for (int i = 0; i < POOL_SIZE; i++) mpz_clear(pool[i]);
	mpz_clear(result);

	return elapsed_ns / (double)ITERATIONS;
}

int main(void) {
	printf("=== GMP tier-0/1 add benchmark ===\n");
	printf("pool_size=%d iterations=%llu\n\n", POOL_SIZE, (unsigned long long)ITERATIONS);

	size_t n = sizeof(BUCKETS) / sizeof(BUCKETS[0]);
	for (size_t i = 0; i < n; i++) {
		double ns_per_op = benchmark_bucket(&BUCKETS[i]);
		printf("RESULT bucket=%s ns_per_op=%.2f\n", BUCKETS[i].name, ns_per_op);
	}
	return 0;
}
