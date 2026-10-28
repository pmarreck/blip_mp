# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Diagnose recurring ClockFailed errors; Answer: a sixteen-call batch advanced wall time 6.312 microseconds while process CPU timestamps stayed equal; version affected methods to v2 with sixteen repeats on small widths, retain strict failures/context, pass 500 bounded reproductions and full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#tiny-division-clock-batches; done 2026-10-28 16:05 EDT; this commit).
- [x] Qualify the wider outer quotient fallback with failing-first floor/gap allocation classification, signed oracle/alias/OOM coverage and neighboring-alignment probes; full tests/build/evaluation pass while default dispatch stays unchanged (context: docs/plan_context/performance-follow-up.md#wider-quotient-fallback-qualification; done 2026-10-28 16:15 EDT; this commit).
- [x] Measure the wider quotient fallback; Answer: reject the universal 2,048-byte gap cutoff because neighboring 4,098/8,194-byte divisors regress despite aligned-width gains; all 105 processes correct, seventeen cohorts unbaselined and one inconclusive (context: docs/plan_context/performance-follow-up.md#wider-quotient-fallback-results; done 2026-10-28 16:25 EDT; this commit).
- [x] Qualify and select the 1,024-byte outer fallback cutoff; Answer: every process mean favors Knuth through this sampled gap, with 18–55% paired CPU savings at the boundary; failing-first allocation classification, signed alias/OOM checks and full tests/build/evaluation pass, fixed comparators and public threshold retained (context: docs/plan_context/performance-follow-up.md#bounded-quotient-fallback-selection; done 2026-10-28 16:32 EDT; this commit).
- [ ] Measure selected signed B-Z against current public division across short, balanced and long dividend geometries before changing public dispatch (context: docs/plan_context/performance-follow-up.md#bounded-quotient-fallback-selection).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
