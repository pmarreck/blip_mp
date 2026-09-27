# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current work (BDFN (Benevolent Dictator For Now), 2026-09-27)

- [x] Replace production limb-array storage with byte buffers; pass the storage audit and 13,053 GMP comparisons (done 2026-09-27 16:30 EDT).
- [x] BLIP-encode every stored FFT residue and twiddle; verify canonical encodings, transforms and allocation failure cleanup (done 2026-09-27 16:30 EDT).
- [x] Capture three-run ReleaseFast medians, forced FFT samples and hyperfine CPU/wall logs before and after migration (done 2026-09-27 16:37 EDT).
- [x] Update README, RESULTS and BENCHMARK_RESULTS; preserve historical results and flag regressions and unmatched buckets (done 2026-09-27 16:37 EDT).
- [x] Research GMP algorithms and SIMD; record verified gaps and untested BLIP experiments in docs/OPTIMIZATION_RESEARCH.md (done 2026-09-27 16:37 EDT).

## Documentation

- [x] Establish INTENT.md with BDFN's BLIP origin and size-dependent GMP framing; migrate terminology and preserve the roadmap history (done 2026-09-27 15:58 EDT; a6d0d3e).

## Follow-up and existing backlog

- [ ] Profile the September regressions: 65,536-bit multiplication +14.5%, 1,024-bit powm +9.8%, and BLIP FFT passes 2.30–3.87× baseline (evidence: RESULTS.md).
- [ ] Evaluate recursive Toom-3 and BLIP FFT stage fusion with GMP oracles and repeated benchmarks (research: docs/OPTIMIZATION_RESEARCH.md).
- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Investigate the pre-existing ReleaseSafe self-copy panic in Mp.addU64(&self, 0), observed while preparing the residue encoding oracle.
- [ ] Reconcile benchmark aggregation follow-ups with the recorded completion of ./bm --stable N (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
