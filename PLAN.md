# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Compare selected Goldilocks, recursive Toom and GMP across eight balanced sizes; FFT saves 16–50% CPU versus Toom at three widths but takes 5.8–8.4× GMP multiplication plus export; all 15 processes correct, both cohorts unbaselined, thresholds unchanged (context: docs/plan_context/performance-follow-up.md#goldilocks-crossover-results; done 2026-10-28 21:51 EDT; source e5e115d).
- [x] Measure three public reciprocal-dispatch variants; reject them for 3–16% regressions in unselected controls, restore the preceding public arithmetic source, retain the experimental candidate and all evidence; full suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#public-dispatch-decision; done 2026-10-28 20:49 EDT; commit df388c5).
- [x] Profile the division-probe correctness runner and partition all 70 tests across four checked processes; 12-CPU pilot falls from 10.1 to 3.9 seconds, integrated runner reports four seconds, no one-CPU gain; complete suite/build/evaluation pass (context: docs/plan_context/performance-follow-up.md#division-correctness-execution; done 2026-10-28 21:29 EDT; commit fb4c998).

## Follow-up and existing backlog

- [x] Complete the bounded performance investigation of FFT viability, recursive HGCD, division thresholds and small-divisor paths; measured size-specific gains and rejected regressions are documented, GMP still leads the measured large division/multiplication paths, hand assembly remains deferred (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 21:51 EDT; sources 6638200, 7182b6c, ca614f5, df388c5, e5e115d).
- [ ] Decide whether strict unsigned-BLIP import/export adapters are needed now or deferred until a concrete consumer; question pending because the earlier decision removed the dual encoder; binary-base GMP float validation remains conditional on a consumer (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
