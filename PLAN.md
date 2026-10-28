# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Measure carried-remainder leaf selection; Answer: sampled balanced/long even-width divisions save 21–24%/9–11% CPU against fixed short-quotient B-Z, with control medians within 0.4% of parity; select locally after 50 correct processes and full tests/build/evaluation, retain unbaselined verdicts and public threshold (context: docs/plan_context/performance-follow-up.md#short-carry-results-and-selection; done 2026-10-28 15:23 EDT; this commit).
- [x] Qualify a matched comparison of public BLIP, Knuth, selected B-Z and GMP with failing-first schedule, arithmetic/corruption, allocation and CLI checks; preserve the original cutoff-128 probe and pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#selected-kernel-gmp-comparison-qualification; done 2026-10-28 15:28 EDT; this commit).
- [x] How does selected division now compare with GMP? Answer: public BLIP takes 2.0–11.2× GMP CPU across 8–16,384-byte divisors; selected B-Z saves 29%/49% versus Knuth at 8,192/16,384 bytes but still takes 5.12×/5.74× GMP time; all ten processes correct, both cohorts unbaselined, public threshold unchanged (context: docs/plan_context/performance-follow-up.md#selected-kernel-gmp-results; done 2026-10-28 15:33 EDT; this commit).
- [x] Qualify a paired Knuth/selected-B-Z probe with independent divisor-width and dividend-gap axes, failing-first set classification and CLI checks, full oracle/corruption/OOM coverage and passing tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#quotient-geometry-crossover-qualification; done 2026-10-28 15:39 EDT; this commit).
- [ ] Measure the short-quotient crossover at aligned divisor widths before broadening the eight-byte fallback or changing public dispatch; qualify neighboring alignments separately (context: docs/plan_context/performance-follow-up.md#quotient-geometry-crossover-qualification).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
