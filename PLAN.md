# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Qualify an experimental reciprocal small-divisor kernel and paired fixed-control probe; failing-first native-oracle, GMP, corruption, allocation and CLI controls pass, plus full suite, build and evaluation; assembly confirms division removed from the inner loop (context: docs/plan_context/performance-follow-up.md#reciprocal-small-divisor-qualification; done 2026-10-28 19:30 EDT; this commit).
- [x] Measure reciprocal reuse against the fixed small-divisor kernel; Answer: 20–27% CPU savings at 64-byte dividends and 51–52% at 4,096 bytes, with short-input regressions; 65 correct processes, six cohorts unbaselined and two inconclusive, public dispatch unchanged (context: docs/plan_context/performance-follow-up.md#reciprocal-small-divisor-results; done 2026-10-28 19:35 EDT; this commit).
- [x] Qualify the experimental signed reciprocal entry with the 64-byte magnitude guard; failing-first sign, zero, promotion, classifier, native/GMP, alias and allocation-failure checks pass, plus the complete suite, build and evaluation (context: docs/plan_context/performance-follow-up.md#signed-reciprocal-qualification; done 2026-10-28 19:47 EDT; this commit).
- [x] Qualify paired signed reciprocal/public and reciprocal/GMP probes; parser and CLI fail before implementation, matching BLIP call boundaries confirmed in assembly, full suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#signed-reciprocal-timing-probe; done 2026-10-28 19:56 EDT; this commit).
- [ ] Measure signed reciprocal/public and reciprocal/GMP probes, then verify any proposed public selection through its actual consumer path (context: docs/plan_context/performance-follow-up.md#signed-reciprocal-timing-probe).
- [ ] Narrow Nix artifact source closures and separate compilation from test-execution timing after the current arithmetic experiment; preserve complete required coverage and isolated controls (context: docs/plan_context/performance-follow-up.md#build-feedback-follow-up).

## Follow-up and existing backlog



- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
