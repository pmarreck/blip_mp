# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Qualify the identical-input variable-small-divisor/GMP probe and longer legacy CLI smoke batches after a reproduced clock failure; oracle, corruption, allocation and diagnostic controls, 3,000 repeat invocations, full suite, build and evaluation pass (context: docs/plan_context/performance-follow-up.md#variable-small-divisor-probe-qualification; done 2026-10-28 19:16 EDT; this commit).
- [x] Measure current variable-small-divisor division against GMP; Answer: unsigned byte kernel takes 0.67–0.95× GMP CPU at 8/9-byte dividends and 3.21–3.43× at 4,096 bytes; all 50 processes correct, seven cohorts unbaselined and one inconclusive (context: docs/plan_context/performance-follow-up.md#variable-small-divisor-results; done 2026-10-28 19:21 EDT; this commit).
- [x] Qualify an experimental reciprocal small-divisor kernel and paired fixed-control probe; failing-first native-oracle, GMP, corruption, allocation and CLI controls pass, plus full suite, build and evaluation; assembly confirms division removed from the inner loop (context: docs/plan_context/performance-follow-up.md#reciprocal-small-divisor-qualification; done 2026-10-28 19:30 EDT; this commit).
- [x] Measure reciprocal reuse against the fixed small-divisor kernel; Answer: 20–27% CPU savings at 64-byte dividends and 51–52% at 4,096 bytes, with short-input regressions; 65 correct processes, six cohorts unbaselined and two inconclusive, public dispatch unchanged (context: docs/plan_context/performance-follow-up.md#reciprocal-small-divisor-results; done 2026-10-28 19:35 EDT; this commit).
- [ ] Qualify and measure a signed reciprocal path retaining the current kernel below 64 magnitude bytes, including aliases, allocation failures and direct GMP comparison before any public selection (context: docs/plan_context/performance-follow-up.md#reciprocal-small-divisor-results).
- [ ] Narrow Nix artifact source closures and separate compilation from test-execution timing after the current arithmetic experiment; preserve complete required coverage and isolated controls (context: docs/plan_context/performance-follow-up.md#build-feedback-follow-up).

## Follow-up and existing backlog



- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
