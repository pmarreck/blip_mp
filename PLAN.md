# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Measure signed reciprocal/public and reciprocal/GMP probes; Answer: candidate saves 47–48% CPU versus current BLIP at 4,096-byte dividends but takes 1.92–1.94× GMP CPU; all 110 processes correct, thirteen cohorts unbaselined and three inconclusive, default unchanged (context: docs/plan_context/performance-follow-up.md#signed-reciprocal-results; done 2026-10-28 20:03 EDT; this commit).
- [x] Qualify the 64-byte small-divisor guard in actual public dispatch with an explicit fixed entry and nine-byte divisor control; failing-first controls, full suite, production build and all-system evaluation pass (context: docs/plan_context/performance-follow-up.md#public-small-divisor-selection-experiment; done 2026-10-28 20:14 EDT; this commit).
- [x] Measure three public reciprocal-dispatch variants; reject them for 3–16% regressions in unselected controls, restore the preceding public arithmetic source, retain the experimental candidate and all evidence; full suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#public-dispatch-decision; done 2026-10-28 20:49 EDT; this commit).
- [x] Narrow Nix compilation sources and expose compilation/test-step durations; source-set control fails before implementation, documentation leaves source/derivation paths unchanged, full suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#compilation-source-boundary; done 2026-10-28 20:38 EDT; this commit).
- [ ] Profile the division-probe correctness runner's ten-second execution and reduce avoidable work while preserving all required controls; retain separate compilation and execution evidence (context: docs/plan_context/performance-follow-up.md#compilation-source-boundary).

## Follow-up and existing backlog



- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
