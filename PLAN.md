# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Add the GMP-verified multiplication probe, dispatch-boundary and wider-ratio cohorts, cold/warm allocation controls, CLI routing and complete-suite/CI integration; pass full native tests/build and all-system evaluation (context: docs/benchmarks/storage-aware/RESEARCH.md; done 2026-10-28 00:09 EDT; this commit).
- [x] Complete bounded add-variation controls: SMT integer contention raises mixed-add cycles with stable instructions, another core sharing L3 does not reproduce that slowdown, and the fixed-address binary excludes main-code ASLR; historical outliers and L1/L2 attribution remain unresolved (context: docs/plan_context/performance-follow-up.md; done 2026-10-27 23:53 EDT; this commit).
- [x] Execute inverse cross-checks with eight bounded workers, preserving all 3900 pairs, 3223 inverses, result comparisons and leak checks; pass the full suite/build and measure core execution at 6.251 seconds, with the five-second budget still unmet (context: docs/plan_context/performance-follow-up.md; done 2026-10-27 23:42 EDT; this commit).
- [x] Replace the CRT fuzz test's quadratic reference with an independently checked GMP byte oracle; retain all 100 seeded cases and ReleaseSafe checks, reducing that test from 9.996 to 0.989 seconds and core execution to 15.531 seconds (context: docs/plan_context/performance-follow-up.md; done 2026-10-27 23:33 EDT; this commit).

## Follow-up and existing backlog


- [ ] Measure the GMP-verified blocked-product probe across dispatch boundaries, cold allocation costs and wider ratios (context: docs/benchmarks/storage-aware/RESEARCH.md).
- [ ] Continue fused Goldilocks, sparse/truncated FFT and Montgomery experiments in ranked order after the blocked-product measurements (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
