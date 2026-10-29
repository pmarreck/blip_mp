# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Qualify the experimental signed reciprocal entry with the 64-byte magnitude guard; failing-first sign, zero, promotion, classifier, native/GMP, alias and allocation-failure checks pass, plus the complete suite, build and evaluation (context: docs/plan_context/performance-follow-up.md#signed-reciprocal-qualification; done 2026-10-28 19:47 EDT; this commit).
- [x] Qualify paired signed reciprocal/public and reciprocal/GMP probes; parser and CLI fail before implementation, matching BLIP call boundaries confirmed in assembly, full suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#signed-reciprocal-timing-probe; done 2026-10-28 19:56 EDT; this commit).
- [x] Measure signed reciprocal/public and reciprocal/GMP probes; Answer: candidate saves 47–48% CPU versus current BLIP at 4,096-byte dividends but takes 1.92–1.94× GMP CPU; all 110 processes correct, thirteen cohorts unbaselined and three inconclusive, default unchanged (context: docs/plan_context/performance-follow-up.md#signed-reciprocal-results; done 2026-10-28 20:03 EDT; this commit).
- [x] Qualify the 64-byte small-divisor guard in actual public dispatch with an explicit fixed entry and nine-byte divisor control; failing-first controls, full suite, production build and all-system evaluation pass (context: docs/plan_context/performance-follow-up.md#public-small-divisor-selection-experiment; done 2026-10-28 20:14 EDT; this commit).
- [ ] Measure the actual public small-divisor selection against its fixed predecessor and GMP before retaining it; include below-cutoff dividends and nine-byte divisors as controls (context: docs/plan_context/performance-follow-up.md#public-small-divisor-selection-experiment).
- [ ] Narrow Nix artifact source closures and separate compilation from test-execution timing after the current arithmetic experiment; preserve complete required coverage and isolated controls (context: docs/plan_context/performance-follow-up.md#build-feedback-follow-up).

## Follow-up and existing backlog



- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
