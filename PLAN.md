# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Add experimental paired/fused Goldilocks transforms, independently check field DFTs/canonical bytes and GMP products, fix one-point twiddle initialization, inspect scalar code and pass the complete native suite/build (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 01:01 EDT; this commit).
- [x] Enable the native-sized blocked tail after paired medians show 14–18% gains and a near-zero nine-byte fallback; retain the padded control and pass the complete native suite/build (context: docs/benchmarks/storage-aware/RESEARCH.md; done 2026-10-28 00:53 EDT; this commit).
- [x] Add ABBA paired tail measurements with injected timing/error controls and full CLI checks; reproduce and fix the two-product CLI clock failure; pass full native tests/build and all-system evaluation (context: docs/benchmarks/storage-aware/RESEARCH.md; done 2026-10-28 00:44 EDT; this commit).
- [x] Add a byte-direct register-sized tail candidate with the padded kernel retained; pass native-width/carry/zero/canary and GMP controls, the full native suite/build and all-system evaluation (context: docs/benchmarks/storage-aware/RESEARCH.md; done 2026-10-28 00:28 EDT; this commit).

## Follow-up and existing backlog


- [ ] Validate and measure paired/fused Goldilocks layouts against Stockham, including complete products, isolated passes and generated-code inspection before production selection (context: docs/benchmarks/goldilocks/README.md).
- [ ] Continue sparse/truncated FFT and Montgomery experiments after the Goldilocks measurements (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
