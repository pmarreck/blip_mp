# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Storage-aware optimization (BDFN (Benevolent Dictator For Now), 2026-09-27 evening)

- [x] Specialize canonical BLIP residue storage for the FFT field; test tight capacity, every length boundary and poisoned padding, then measure codec and transform costs. (done 2026-09-27 19:57 EDT)
- [x] Fuse FFT stages and avoid redundant zero/twiddle work where measured; preserve canonical BLIP for every stored intermediate and compare complete multiplication. (done 2026-09-27 19:57 EDT)
- [x] Inspect sibling BLIP reserved symbols and evaluate context-defined fixed-width types as a design proposal, without changing the format. (done 2026-09-27 19:57 EDT)
- [ ] Start research experiments after the FFT work: recursive Toom-3 and asymmetric multiplication, with failing tests and before/after measurements.
- [ ] Evaluate remaining research candidates for tighter packing, sparse transforms and truncated Montgomery work; retain measured null results and rank further experiments.
- [ ] Publish before/after evidence and update README, results, representation notes and optimization research; commit passing units of work.

## Current work (BDFN, 2026-09-27)

- [x] Update README, RESULTS and BENCHMARK_RESULTS; preserve historical results and flag regressions and unmatched buckets (done 2026-09-27 16:37 EDT).
- [x] Research GMP algorithms and SIMD; record verified gaps and untested BLIP experiments in docs/OPTIMIZATION_RESEARCH.md (done 2026-09-27 16:37 EDT).

## Documentation


## Follow-up and existing backlog

- [ ] Profile the September regressions: 65,536-bit multiplication +14.5%, 1,024-bit powm +9.8%, and BLIP FFT passes 2.30–3.87× baseline (evidence: RESULTS.md).
- [ ] Evaluate recursive Toom-3 and BLIP FFT stage fusion with GMP oracles and repeated benchmarks (research: docs/OPTIMIZATION_RESEARCH.md).
- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Investigate the pre-existing ReleaseSafe self-copy panic in Mp.addU64(&self, 0), observed while preparing the residue encoding oracle.
- [ ] Reconcile benchmark aggregation follow-ups with the recorded completion of ./bm --stable N (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
