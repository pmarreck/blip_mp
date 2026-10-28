# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] How does improved division compare with GMP? Answer: public BLIP takes 1.8–11.1× GMP CPU time on the sampled 2:1 operands; earlier 6–19× and 78–94% gains compare older BLIP kernels; all correctness checks pass, timing cohorts remain unbaselined/inconclusive (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:03 EDT; this commit).
- [x] Compare exact-width inverse algorithms on sixteen cases per width; Answer: recursion takes 3.3–3.4× wider-window CPU time at 4,096/4,097 bits, with near-parity at the 4,095-bit fallback control; keep public dispatch and preserve unbaselined/inconclusive verdicts (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:20 EDT; this commit).
- [x] Qualify a sixteen-case exact-width inverse corpus and paired HGCD probe with failing-first oracle, corruption, allocation and CLI controls; pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:12 EDT; this commit).
- [ ] Qualify an explicit signed B-Z division entry point and compare it with current public dispatch near the kernel crossover across operand geometries before selecting a lower threshold (context: docs/plan_context/performance-follow-up.md).
- [x] Add an explicit signed B-Z entry point with GMP, sign/normalization, aliasing, native-boundary and allocation-recovery controls; pass full tests/build/evaluation while preserving normal dispatch (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:32 EDT; this commit).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
