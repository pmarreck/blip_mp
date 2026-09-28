# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Storage-aware optimization (BDFN (Benevolent Dictator For Now), 2026-09-27 evening)

- [x] Inspect sibling BLIP reserved symbols and evaluate context-defined fixed-width types as a design proposal, without changing the format. (done 2026-09-27 19:57 EDT)
- [x] Start research experiments after the FFT work: recursive Toom-3 and asymmetric multiplication, with failing tests and before/after measurements. (done 2026-09-27 20:14 EDT)
- [x] Evaluate remaining research candidates for tighter packing, sparse transforms and truncated Montgomery work; retain measured null results and rank further experiments. (done 2026-09-27 20:09 EDT)
- [x] Publish before/after evidence and update README, results, representation notes and optimization research; commit passing units of work. (done 2026-09-27 20:09 EDT)

## Current work (BDFN, 2026-09-27)



## Follow-up and existing backlog

- [ ] Investigate unstable immediate-add timing (4.41–7.31 ns) in the final rerun before renewing the four-bucket GMP-win claim (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Measure blocked-product crossover, cold allocation costs and wider ratios; continue fused Goldilocks, sparse/truncated FFT and Montgomery experiments in ranked order (context: docs/benchmarks/storage-aware/RESEARCH.md).

- [ ] Profile remaining non-FFT multiplication/powm regressions; the initial FFT overhead is partly recovered by 119dba3 (evidence: RESULTS.md).
- [x] Evaluate recursive Toom-3 and BLIP FFT stage fusion with GMP oracles and repeated benchmarks (research: docs/OPTIMIZATION_RESEARCH.md). (done 2026-09-27 20:09 EDT)
- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Investigate the pre-existing ReleaseSafe self-copy panic in Mp.addU64(&self, 0), observed while preparing the residue encoding oracle.
- [ ] Reconcile benchmark aggregation follow-ups with the recorded completion of ./bm --stable N (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
