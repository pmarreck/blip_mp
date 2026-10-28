# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Select fused Goldilocks after paired product medians show 23–25% lower CPU time than Stockham, omit permutation scratch, retain the threshold and pass full native tests/build plus all-system evaluation (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 01:47 EDT; this commit).
- [x] Add rotating paired Goldilocks product/pass measurements, corruption and allocation-failure controls, CLI/CI integration and 1/12-CPU cohorts; pass full native tests/build and all-system evaluation (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 01:14 EDT; this commit).
- [x] Add experimental paired/fused Goldilocks transforms, independently check field DFTs/canonical bytes and GMP products, fix one-point twiddle initialization, inspect scalar code and pass the complete native suite/build (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 01:01 EDT; this commit).
- [x] Enable the native-sized blocked tail after paired medians show 14–18% gains and a near-zero nine-byte fallback; retain the padded control and pass the complete native suite/build (context: docs/benchmarks/storage-aware/RESEARCH.md; done 2026-10-28 00:53 EDT; this commit).

## Follow-up and existing backlog


- [ ] Complete and measure the independently checked input/output-truncated Goldilocks product experiment, then continue Montgomery experiments (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
