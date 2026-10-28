# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Route debug builds through Nix, advertise Zig 0.16 as the minimum, and test routing, failure propagation and debug/release banners; pass the complete native suite, build and all-system evaluation. (done 2026-10-27 22:00 EDT; this commit)
- [x] Reconcile all unchecked legacy roadmap groups against current code, tests and Git history; preserve shelved work and unresolved dependencies (context: docs/plan_context/roadmap-reconciliation.md). (done 2026-10-27 21:49 EDT; this commit)
- [x] Add the verified immediate-add probe and pinned shared performance engine; pass ReleaseSafe oracle tests, optimized JSON checks, 13,111 GMP comparisons, production build and all-system evaluation. (done 2026-10-27 21:43 EDT; this commit)
- [x] Measure the three add fixtures on separate 1/12-CPU cohorts; all 45 processes verified, four cases unbaselined and two inconclusive, with no baseline approval or new GMP claim (context: docs/plan_context/performance-follow-up.md). (done 2026-10-27 21:43 EDT; this commit)

## Follow-up and existing backlog

- [ ] Investigate immediate-add variation with cycle/instruction evidence and interleaved fixtures; keep the first noisy observations unapproved (context: docs/plan_context/performance-follow-up.md).
- [ ] Attribute unit execution latency and move repeated timing work from five division tests and the inverse-modulo benchmark to verified optimized probes, retaining all correctness assertions (context: docs/plan_context/performance-follow-up.md).

- [ ] Measure blocked-product crossover, cold allocation costs and wider ratios; continue fused Goldilocks, sparse/truncated FFT and Montgomery experiments in ranked order (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
