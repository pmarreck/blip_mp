# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Qualify and compare signed B-Z with current public division; Answer: sampled recursive balanced/long dividends save 21–28%/18–44% at favorable widths, but short quotients take 59–68× current CPU time; keep dispatch unchanged (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 14:00 EDT; this commit).
- [x] Qualify an explicit B-Z leading-block shortcut with failing allocation/result and CLI controls, signed GMP/aliasing/OOM checks and unchanged comparison paths; pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#leading-block-experiment; done 2026-10-28 14:06 EDT; this commit).
- [ ] Measure the qualified B-Z leading-block shortcut against the fixed signed B-Z path across three operand geometries before selecting it (context: docs/plan_context/performance-follow-up.md#leading-block-experiment).
- [ ] Audit local branches and worktrees against the five-per-kind budget, verify ownership and integration, preserve dirty or unique work, retire only obsolete allocations, and report before/after counts to the coordinator.
- [x] Fix Mp heap growth leaving a freed buffer after replacement allocation failure; preserve the old value and verify cleanup with focused and full-corpus failure injection (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:44 EDT; this commit).
- [x] Qualify paired public division over three geometries with complete sign/normalization, oracle, corruption, allocation and CLI controls; pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 13:44 EDT; this commit).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
