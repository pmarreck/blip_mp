# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Select the 128-byte B-Z cutoff after paired samples show 78–94% CPU savings with near-parity odd-width controls; preserve cohort verdicts and pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 06:46 EDT; this commit).
- [x] Compare selected B-Z against Knuth across 8–16,384-byte divisors; Answer: B-Z saves about 23% at 16,384 bytes but loses at 8,192 bytes, with public dispatch unchanged (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:03 EDT; this commit).
- [x] How does improved division compare with GMP? Answer: public BLIP takes 1.8–11.1× GMP CPU time on the sampled 2:1 operands; earlier 6–19× and 78–94% gains compare older BLIP kernels; all correctness checks pass, timing cohorts remain unbaselined/inconclusive (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:03 EDT; this commit).
- [x] Prepare a four-method matched-input division probe with native and GMP oracles, mirrored timing, cleanup and CLI controls; pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 12:55 EDT; this commit).
- [ ] Measure wider-window versus recursive inverse calls on an expanded exact-width corpus with paired timing and verified results before changing dispatch.
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
