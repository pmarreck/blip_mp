# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Measure the wider quotient fallback; Answer: reject the universal 2,048-byte gap cutoff because neighboring 4,098/8,194-byte divisors regress despite aligned-width gains; all 105 processes correct, seventeen cohorts unbaselined and one inconclusive (context: docs/plan_context/performance-follow-up.md#wider-quotient-fallback-results; done 2026-10-28 16:25 EDT; this commit).
- [x] Qualify and select the 1,024-byte outer fallback cutoff; Answer: every process mean favors Knuth through this sampled gap, with 18–55% paired CPU savings at the boundary; failing-first allocation classification, signed alias/OOM checks and full tests/build/evaluation pass, fixed comparators and public threshold retained (context: docs/plan_context/performance-follow-up.md#bounded-quotient-fallback-selection; done 2026-10-28 16:32 EDT; this commit).
- [x] Refresh the direct GMP comparison after the quotient-gap selection; Answer: public BLIP takes 2.2–11.2× GMP CPU time, selected B-Z saves 28–29%/48–49% versus Knuth at 8,192/16,384 bytes but still takes 5.10–5.13×/5.74–5.76× GMP time; fifteen correct processes, one unbaselined and one inconclusive cohort (context: docs/plan_context/performance-follow-up.md#gmp-refresh-after-bounded-quotient-selection; done 2026-10-28 16:44 EDT; this commit).
- [x] Correct the signed probe binding; Answer: the first configuration and signed boundary tests called the fixed cutoff-128 wrapper; preserve that control run, add an explicit selected entry with failing-first resource/CLI regressions, rebind signed alias/OOM checks and pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#signed-selected-kernel-probe-binding-correction; done 2026-10-28 16:49 EDT; this commit).
- [ ] Qualify multiplication CLI failure diagnostics and fresh exact-commit CI after an empty-log failure that did not recur in 500 six-mode reproductions (context: docs/plan_context/performance-follow-up.md#measurement-infrastructure-follow-up).
- [ ] Rerun the corrected selected-public signed comparison with prechecked record IDs under the history store limit; the first corrected run failed storage and retained no results (context: docs/plan_context/performance-follow-up.md#measurement-infrastructure-follow-up).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
