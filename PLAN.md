# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Fix the reproduced Mp.addU64(&self, 0) alias panic; require ReleaseSafe unit tests and pass the complete suite, 13,111 GMP checks and production build. (done 2026-10-14 15:38 EDT; this commit)
- [x] Honor the temporary scheduling hold through its release; ordinary single-job build budgets apply again. (done 2026-10-14 15:43 EDT; this commit)
- [x] Sanitize all 160 history commits with a verified private backup; preserve author metadata, arithmetic behavior and benchmark measurements, and remap current evidence references. (done 2026-10-14 17:29 EDT; this commit)
- [x] Pass the sanitized history audit, full suite with 13,111 GMP comparisons, production build and all three native Linux CI targets. (done 2026-10-14 17:29 EDT; this commit)
- [ ] Publish with an explicit remote lease and confirm the exact remote commit and CI result.

## Scoped fixed-length canonical residues


## Follow-up and existing backlog

- [ ] Integrate verified immediate-add probes with the shared performance engine, then investigate the 4.41–7.31 ns variation using separate single-core and 12-core cohorts (context: docs/plan_context/performance-follow-up.md).

- [ ] Measure blocked-product crossover, cold allocation costs and wider ratios; continue fused Goldilocks, sparse/truncated FFT and Montgomery experiments in ranked order (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by a80073f (evidence: RESULTS.md).
- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
