# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Refresh the direct GMP comparison after the quotient-gap selection; Answer: public BLIP takes 2.2–11.2× GMP CPU time, selected B-Z saves 28–29%/48–49% versus Knuth at 8,192/16,384 bytes but still takes 5.10–5.13×/5.74–5.76× GMP time; fifteen correct processes, one unbaselined and one inconclusive cohort (context: docs/plan_context/performance-follow-up.md#gmp-refresh-after-bounded-quotient-selection; done 2026-10-28 16:44 EDT; this commit).
- [x] Correct the signed probe binding; Answer: the first configuration and signed boundary tests called the fixed cutoff-128 wrapper; preserve that control run, add an explicit selected entry with failing-first resource/CLI regressions, rebind signed alias/OOM checks and pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#signed-selected-kernel-probe-binding-correction; done 2026-10-28 16:49 EDT; this commit).
- [x] Qualify multiplication CLI failure diagnostics and fresh exact-commit CI; Answer: 500 six-mode reproductions and the local suite passed, then c380c3f CI passed in 195 seconds; the earlier empty-log failure remains unexplained and future failures now report context (context: docs/plan_context/performance-follow-up.md#measurement-infrastructure-follow-up; done 2026-10-28 17:06 EDT; commit c380c3f).
- [x] Rerun the corrected selected-public signed comparison with prechecked record IDs; Answer: selected B-Z saves 32–52% CPU on sampled balanced/long even widths but short quotients cost 26–29% more and the odd control stays near parity; all 50 processes correct, ten cohorts unbaselined, public dispatch unchanged (context: docs/plan_context/performance-follow-up.md#selected-signed-division-results; done 2026-10-28 17:08 EDT; this commit).
- [ ] Qualify a byte-padding B-Z normalization candidate for neighboring divisor widths with failing-first scaling, full-result, alias/OOM and boundary checks, then measure it against the fixed selected kernel before changing dispatch (context: docs/plan_context/performance-follow-up.md#selected-signed-division-results).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
