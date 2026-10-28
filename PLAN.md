# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Qualify a matched comparison of public BLIP, Knuth, selected B-Z and GMP with failing-first schedule, arithmetic/corruption, allocation and CLI checks; preserve the original cutoff-128 probe and pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#selected-kernel-gmp-comparison-qualification; done 2026-10-28 15:28 EDT; this commit).
- [x] How does selected division now compare with GMP? Answer: public BLIP takes 2.0–11.2× GMP CPU across 8–16,384-byte divisors; selected B-Z saves 29%/49% versus Knuth at 8,192/16,384 bytes but still takes 5.12×/5.74× GMP time; all ten processes correct, both cohorts unbaselined, public threshold unchanged (context: docs/plan_context/performance-follow-up.md#selected-kernel-gmp-results; done 2026-10-28 15:33 EDT; this commit).
- [x] Qualify a paired Knuth/selected-B-Z probe with independent divisor-width and dividend-gap axes, failing-first set classification and CLI checks, full oracle/corruption/OOM coverage and passing tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#quotient-geometry-crossover-qualification; done 2026-10-28 15:39 EDT; this commit).
- [x] Map the aligned short-quotient crossover; Answer: B-Z takes 18–25× Knuth time at an eight-byte dividend gap and 1.42–1.64× at 2,048 bytes, approaching parity at 4,096 bytes; all 35 processes correct, six cohorts unbaselined and no dispatch change (context: docs/plan_context/performance-follow-up.md#quotient-geometry-crossover-results; done 2026-10-28 15:45 EDT; this commit).
- [ ] Qualify and measure an outer Knuth fallback through a 2,048-byte dividend gap for divisors at least 4,096 bytes wide, preserving the current entry and covering boundary and neighboring-alignment controls before selection (context: docs/plan_context/performance-follow-up.md#quotient-geometry-crossover-results).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
