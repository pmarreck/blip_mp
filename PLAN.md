# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Qualify multiplication CLI failure diagnostics and fresh exact-commit CI; Answer: 500 six-mode reproductions and the local suite passed, then c380c3f CI passed in 195 seconds; the earlier empty-log failure remains unexplained and future failures now report context (context: docs/plan_context/performance-follow-up.md#measurement-infrastructure-follow-up; done 2026-10-28 17:06 EDT; commit c380c3f).
- [x] Rerun the corrected selected-public signed comparison with prechecked record IDs; Answer: selected B-Z saves 32–52% CPU on sampled balanced/long even widths but short quotients cost 26–29% more and the odd control stays near parity; all 50 processes correct, ten cohorts unbaselined, public dispatch unchanged (context: docs/plan_context/performance-follow-up.md#selected-signed-division-results; done 2026-10-28 17:08 EDT; this commit).
- [x] Qualify the byte-padding B-Z candidate and paired probe with failing-first scaling, full-result, alias/OOM and boundary checks; full suite, production build and all-system evaluation pass, default unchanged (context: docs/plan_context/performance-follow-up.md#byte-padding-candidate-qualification; done 2026-10-28 17:27 EDT; this commit).
- [x] Measure byte padding against the fixed quotient-1024 kernel; Answer: balanced odd widths near 8–16 KiB save 26–51% CPU, but gap 1,025 regresses 1.75–2.85× and some balanced widths regress; reject broad selection, preserve 180 correct processes and 22 unbaselined/four inconclusive cohorts (context: docs/plan_context/performance-follow-up.md#byte-padding-results; done 2026-10-28 17:33 EDT; this commit).
- [ ] Measure padding across intermediate divisor widths and relative quotient gaps to qualify a narrower selection rule; keep current dispatch until supported (context: docs/plan_context/performance-follow-up.md#byte-padding-results).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
