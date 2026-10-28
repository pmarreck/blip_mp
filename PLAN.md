# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Map the aligned short-quotient crossover; Answer: B-Z takes 18–25× Knuth time at an eight-byte dividend gap and 1.42–1.64× at 2,048 bytes, approaching parity at 4,096 bytes; all 35 processes correct, six cohorts unbaselined and no dispatch change (context: docs/plan_context/performance-follow-up.md#quotient-geometry-crossover-results; done 2026-10-28 15:45 EDT; this commit).
- [x] Diagnose recurring ClockFailed errors; Answer: a sixteen-call batch advanced wall time 6.312 microseconds while process CPU timestamps stayed equal; version affected methods to v2 with sixteen repeats on small widths, retain strict failures/context, pass 500 bounded reproductions and full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#tiny-division-clock-batches; done 2026-10-28 16:05 EDT; this commit).
- [x] Qualify the wider outer quotient fallback with failing-first floor/gap allocation classification, signed oracle/alias/OOM coverage and neighboring-alignment probes; full tests/build/evaluation pass while default dispatch stays unchanged (context: docs/plan_context/performance-follow-up.md#wider-quotient-fallback-qualification; done 2026-10-28 16:15 EDT; this commit).
- [x] Measure the wider quotient fallback; Answer: reject the universal 2,048-byte gap cutoff because neighboring 4,098/8,194-byte divisors regress despite aligned-width gains; all 105 processes correct, seventeen cohorts unbaselined and one inconclusive (context: docs/plan_context/performance-follow-up.md#wider-quotient-fallback-results; done 2026-10-28 16:25 EDT; this commit).
- [ ] Map the narrower quotient-gap crossover at neighboring even widths before selecting a fallback cutoff (context: docs/plan_context/performance-follow-up.md#wider-quotient-fallback-results).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
