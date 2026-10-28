# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Qualify and compare signed B-Z with current public division; Answer: sampled recursive balanced/long dividends save 21–28%/18–44% at favorable widths, but short quotients take 59–68× current CPU time; keep dispatch unchanged (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 14:00 EDT; this commit).
- [x] Qualify an explicit B-Z leading-block shortcut with failing allocation/result and CLI controls, signed GMP/aliasing/OOM checks and unchanged comparison paths; pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#leading-block-experiment; done 2026-10-28 14:06 EDT; this commit).
- [x] Measure the B-Z leading-block shortcut; Answer: paired medians save 40–43%/15–17%/6–8% CPU for short-quotient/balanced/long-dividend recursive cases, with fallback near parity and 45 correct processes; select the shortcut while preserving fixed controls and unbaselined/inconclusive verdicts (context: docs/plan_context/performance-follow-up.md#leading-block-results-and-selection; done 2026-10-28 14:20 EDT; this commit).
- [x] Audit and retire obsolete allocations; reduce seven local branches/nine worktrees to two/four, verify all retired commits in local/remote mainline, preserve two dirty checkouts and one unique experimental commit, and report to the coordinator (done 2026-10-28 14:11 EDT; this commit).
- [ ] Qualify a B-Z short-quotient Knuth fallback when magnitude lengths bound the quotient to one chunk, test the length boundary and signed/oracle/OOM behavior, and measure against fixed B-Z and current public division before selection (context: docs/plan_context/performance-follow-up.md#leading-block-results-and-selection).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
