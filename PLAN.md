# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Measure guarded padding through signed wrappers; Answer: 6,145-byte cases save 11–12% CPU and 16,385-byte cases save 44–45%, while 12,290-byte cases gain only 1–2% with some process losses; all 55 processes correct, ten cohorts unbaselined, candidate stays experimental (context: docs/plan_context/performance-follow-up.md#guarded-signed-results; done 2026-10-28 18:26 EDT; this commit).
- [x] Qualify the direct public/fixed/guarded/GMP comparison with failing-first width, binding and CLI checks; full suite, production build and all-system evaluation pass (context: docs/plan_context/performance-follow-up.md#guarded-direct-comparison-qualification; done 2026-10-28 18:32 EDT; this commit).
- [x] Measure guarded division against GMP; Answer: public BLIP takes 6.2–11.2× GMP CPU and the guarded kernel takes 4.9–5.8× across six 6,145–16,385-byte divisor widths; 15 correct processes, both cohorts unbaselined, guard stays experimental (context: docs/plan_context/performance-follow-up.md#guarded-direct-gmp-results; done 2026-10-28 18:43 EDT; this commit).
- [ ] Qualify an identical-input variable-small-divisor benchmark and test whether the existing reciprocal primitive can improve repeated byte-payload division without stored limb arrays (context: docs/plan_context/performance-follow-up.md#small-divisor-follow-up).

## Follow-up and existing backlog



- [x] Qualify the guarded padding entry and signed wrapper against the fixed kernel; classifier, binding, alias/OOM, full suite, production build and all-system evaluation pass, normal divider unchanged (context: docs/plan_context/performance-follow-up.md#guarded-padding-qualification; done 2026-10-28 18:21 EDT; this commit).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
