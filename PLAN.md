# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [ ] Compare the selected Goldilocks kernel, forced recursive Toom-3 and GMP on identical balanced inputs around transform/dispatch boundaries; verify all timed results and retain component CPU/wall samples before changing dispatch (context: docs/plan_context/performance-follow-up.md#goldilocks-crossover-comparison).
- [x] Qualify the 64-byte small-divisor guard in actual public dispatch with an explicit fixed entry and nine-byte divisor control; failing-first controls, full suite, production build and all-system evaluation pass (context: docs/plan_context/performance-follow-up.md#public-small-divisor-selection-experiment; done 2026-10-28 20:14 EDT; this commit).
- [x] Measure three public reciprocal-dispatch variants; reject them for 3–16% regressions in unselected controls, restore the preceding public arithmetic source, retain the experimental candidate and all evidence; full suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#public-dispatch-decision; done 2026-10-28 20:49 EDT; this commit).
- [x] Narrow Nix compilation sources and expose compilation/test-step durations; source-set control fails before implementation, documentation leaves source/derivation paths unchanged, full suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#compilation-source-boundary; done 2026-10-28 20:38 EDT; this commit).
- [x] Profile the division-probe correctness runner and partition all 70 tests across four checked processes; 12-CPU pilot falls from 10.1 to 3.9 seconds, integrated runner reports four seconds, no one-CPU gain; complete suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#division-correctness-execution; done 2026-10-28 21:29 EDT; this commit).

## Follow-up and existing backlog



- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Decide whether strict unsigned-BLIP import/export adapters are needed now or deferred until a concrete consumer; question pending because the earlier decision removed the dual encoder; binary-base GMP float validation remains conditional on a consumer (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
