# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Refresh nixpkgs, flake-utils and systems pins; remove Jujutsu, retain Zig 0.16.0, and pass all three supported-system evaluations, native tests and production build. (done 2026-10-27 21:16 EDT; this commit)
- [x] Run the complete suite through Nix checks and include C API, 13,111 GMP comparisons and CLI checks in CI without changing checkout output links; native preparation and checks passed in 218 seconds, with execution time not separately measured. (done 2026-10-27 21:16 EDT; this commit)
- [x] Publish with an explicit remote lease; verify remote 1fc1c40 and its successful exact-commit CI run (159 seconds). (done 2026-10-14 19:34 EDT; 1fc1c40)

## Follow-up and existing backlog

- [ ] Integrate verified immediate-add probes with the shared performance engine, then investigate the 4.41–7.31 ns variation using separate single-core and 12-core cohorts (context: docs/plan_context/performance-follow-up.md).

- [ ] Measure blocked-product crossover, cold allocation costs and wider ratios; continue fused Goldilocks, sparse/truncated FFT and Montgomery experiments in ranked order (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
