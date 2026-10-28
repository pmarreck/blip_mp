# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Move the five division timing tests to optimized probes; retain all six fixtures, add GMP quotient/remainder checks and corruption controls, and pass the full native suite, build and all-system evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-27 23:04 EDT; this commit).
- [x] Attribute core unit latency and move inverse timing loops to GMP-verified optimized probes; preserve all fixture comparisons, add existence checks, and measure core execution at 40.995 seconds before and 24.352 after (context: docs/plan_context/performance-follow-up.md; done 2026-10-27 22:47 EDT; this commit).
- [x] Investigate immediate-add variation with interleaved cycle/instruction measurements; ten processes verified, instruction counts stayed stable while cycles varied, and both cohorts remain unbaselined (context: docs/plan_context/performance-follow-up.md; done 2026-10-27 22:26 EDT; this commit).
- [x] Route debug builds through Nix, advertise Zig 0.16 as the minimum, and test routing, failure propagation and debug/release banners; pass the complete native suite, build and all-system evaluation. (done 2026-10-27 22:00 EDT; this commit)

## Follow-up and existing backlog

- [ ] Investigate the remaining 24-second core test execution with coverage-preserving changes, starting with CRT fuzz and inverse cross-check costs; do not weaken cases to meet the five-second budget (context: docs/plan_context/performance-follow-up.md).
- [ ] Distinguish shared-core contention, cache behavior and code placement as causes of add-cycle variation using bounded contemporaneous controls; preserve the unapproved observations (context: docs/plan_context/performance-follow-up.md).

- [ ] Measure blocked-product crossover, cold allocation costs and wider ratios; continue fused Goldilocks, sparse/truncated FFT and Montgomery experiments in ranked order (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
