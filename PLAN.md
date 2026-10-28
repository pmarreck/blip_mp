# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Add the verified immediate-add probe and pinned shared performance engine; pass ReleaseSafe oracle tests, optimized JSON checks, 13,111 GMP comparisons, production build and all-system evaluation. (done 2026-10-27 21:43 EDT; this commit)
- [x] Measure the three add fixtures on separate 1/12-CPU cohorts; all 45 processes verified, four cases unbaselined and two inconclusive, with no baseline approval or new GMP claim (context: docs/plan_context/performance-follow-up.md). (done 2026-10-27 21:43 EDT; this commit)
- [x] Refresh nixpkgs, flake-utils and systems pins; remove Jujutsu, retain Zig 0.16.0, and pass all three supported-system evaluations, native tests and production build. (done 2026-10-27 21:16 EDT; this commit)
- [x] Run the complete suite through Nix checks and include C API, 13,111 GMP comparisons and CLI checks in CI without changing checkout output links; native preparation and checks passed in 218 seconds, with execution time not separately measured. (done 2026-10-27 21:16 EDT; this commit)

## Follow-up and existing backlog

- [ ] Investigate immediate-add variation with cycle/instruction evidence and interleaved fixtures; keep the first noisy observations unapproved (context: docs/plan_context/performance-follow-up.md).
- [ ] Attribute unit execution latency and move repeated timing work from five division tests and the inverse-modulo benchmark to verified optimized probes, retaining all correctness assertions (context: docs/plan_context/performance-follow-up.md).

- [ ] Measure blocked-product crossover, cold allocation costs and wider ratios; continue fused Goldilocks, sparse/truncated FFT and Montgomery experiments in ranked order (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
