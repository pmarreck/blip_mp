# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Measure guarded padding through signed wrappers; Answer: 6,145-byte cases save 11–12% CPU and 16,385-byte cases save 44–45%, while 12,290-byte cases gain only 1–2% with some process losses; all 55 processes correct, ten cohorts unbaselined, candidate stays experimental (context: docs/plan_context/performance-follow-up.md#guarded-signed-results; done 2026-10-28 18:26 EDT; this commit).
- [x] Qualify the direct public/fixed/guarded/GMP comparison with failing-first width, binding and CLI checks; full suite, production build and all-system evaluation pass (context: docs/plan_context/performance-follow-up.md#guarded-direct-comparison-qualification; done 2026-10-28 18:32 EDT; this commit).
- [x] Measure guarded division against GMP; Answer: public BLIP takes 6.2–11.2× GMP CPU and the guarded kernel takes 4.9–5.8× across six 6,145–16,385-byte divisor widths; 15 correct processes, both cohorts unbaselined, guard stays experimental (context: docs/plan_context/performance-follow-up.md#guarded-direct-gmp-results; done 2026-10-28 18:43 EDT; this commit).
- [x] Qualify the identical-input variable-small-divisor/GMP probe and longer legacy CLI smoke batches after a reproduced clock failure; oracle, corruption, allocation and diagnostic controls, 3,000 repeat invocations, full suite, build and evaluation pass (context: docs/plan_context/performance-follow-up.md#variable-small-divisor-probe-qualification; done 2026-10-28 19:16 EDT; this commit).
- [ ] Measure the current variable-small-divisor path against GMP, then test reciprocal reuse against a fixed control with TDD and signed-path qualification before any selection (context: docs/plan_context/performance-follow-up.md#small-divisor-follow-up).
- [ ] Narrow Nix artifact source closures and separate compilation from test-execution timing after the current arithmetic experiment; preserve complete required coverage and isolated controls (context: docs/plan_context/performance-follow-up.md#build-feedback-follow-up).

## Follow-up and existing backlog



- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
