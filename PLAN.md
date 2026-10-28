# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Qualify and compare signed B-Z with current public division; Answer: sampled recursive balanced/long dividends save 21–28%/18–44% at favorable widths, but short quotients take 59–68× current CPU time; keep dispatch unchanged (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 14:00 EDT; this commit).
- [ ] Qualify a trivial-leading-block B-Z shortcut with failing allocation/result controls and a fixed old-path comparator, then measure signed calls across the same operand geometries before selecting it (context: docs/plan_context/performance-follow-up.md#division-geometry-follow-up).
- [x] Fix Mp heap growth leaving a freed buffer after replacement allocation failure; preserve the old value and verify cleanup with focused and full-corpus failure injection (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:44 EDT; this commit).
- [x] Qualify paired public division over three geometries with complete sign/normalization, oracle, corruption, allocation and CLI controls; pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:44 EDT; this commit).
- [x] Add an explicit signed B-Z entry point with GMP, sign/normalization, aliasing, native-boundary and allocation-recovery controls; pass full tests/build/evaluation while preserving normal dispatch (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:32 EDT; this commit).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
