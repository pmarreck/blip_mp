# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Add experimental input/output-truncated Goldilocks transforms with 46,368 independent DFT/mixed-inverse cases and GMP product checks; pass the complete native suite/build (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 01:51 EDT; this commit).
- [x] Select fused Goldilocks after paired product medians show 23–25% lower CPU time than Stockham, omit permutation scratch, retain the threshold and pass full native tests/build plus all-system evaluation (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 01:47 EDT; this commit).
- [x] Add rotating paired Goldilocks product/pass measurements, corruption and allocation-failure controls, CLI/CI integration and 1/12-CPU cohorts; pass full native tests/build and all-system evaluation (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 01:14 EDT; this commit).
- [x] Add experimental paired/fused Goldilocks transforms, independently check field DFTs/canonical bytes and GMP products, fix one-point twiddle initialization, inspect scalar code and pass the complete native suite/build (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 01:01 EDT; this commit).

## Follow-up and existing backlog


- [ ] Measure input/output-truncated Goldilocks products against Stockham and fused layouts across padding boundaries, then continue Montgomery experiments (context: docs/benchmarks/goldilocks/TRUNCATED.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
