# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Reconcile the immediate-add benchmark and aggregation backlog against code; record measurement gaps before another performance claim (context: docs/plan_context/performance-follow-up.md). (done 2026-10-14 14:32 EDT; this commit)
- [x] Fix the reproduced Mp.addU64(&self, 0) alias panic; require ReleaseSafe unit tests and pass the complete suite, 13,111 GMP checks and production build. (done 2026-10-14 15:38 EDT; this commit)
- [ ] Honor the temporary scheduling hold on further expensive work; the completed validation job has released its build lease.
- [ ] Keep publication on hold until the unpublished-history privacy decision is resolved (walking decision blip-mp-unpublished-history-privacy, revision 1).

## Scoped fixed-length canonical residues

- [x] Retain only measured improvements, run the full tests/build and GMP oracle, update benchmark/representation docs, and capture successful collaboration evidence in the private ledger. (done 2026-09-27 22:06 EDT; source and evidence in this commit)

## Follow-up and existing backlog

- [ ] Integrate verified immediate-add probes with the shared performance engine, then investigate the 4.41–7.31 ns variation using separate single-core and 12-core cohorts (context: docs/plan_context/performance-follow-up.md).

- [ ] Measure blocked-product crossover, cold allocation costs and wider ratios; continue fused Goldilocks, sparse/truncated FFT and Montgomery experiments in ranked order (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by 119dba3 (evidence: RESULTS.md).
- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
