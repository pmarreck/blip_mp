# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Qualify longer fixed tiny-division batches after a reproduced non-advancing CPU clock; 500 native reproductions and the full suite pass, strict clock errors retained, changed methods versioned, underlying cause unresolved (context: docs/plan_context/performance-follow-up.md#tiny-division-clock-follow-up; done 2026-10-28 18:21 EDT; this commit).
- [ ] Measure guarded padding through signed wrappers against the fixed kernel in both affinity cohorts, preserve every diagnostic attempt and report results without changing the public threshold (context: docs/plan_context/performance-follow-up.md#guarded-padding-qualification).

## Follow-up and existing backlog



- [x] Qualify the padding-shape probe across intermediate widths and relative quotient gaps with failing-first domain, long-capacity, oracle and CLI controls; full suite, build and evaluation pass (context: docs/plan_context/performance-follow-up.md#padding-shape-follow-up; done 2026-10-28 17:40 EDT; this commit).
- [x] Measure padding by odd recursion leaf and quotient gap; Answer: a candidate guard of leaf >=6 KiB and dividend >=2*divisor covers 8–52% median CPU savings in 36 cells, with one diagnostic process losing 0.5%; all 165 processes correct, 32 cohorts unbaselined, dispatch unchanged (context: docs/plan_context/performance-follow-up.md#padding-shape-results; done 2026-10-28 17:57 EDT; this commit).
- [x] Qualify the guarded padding entry and signed wrapper against the fixed kernel; classifier, binding, alias/OOM, full suite, production build and all-system evaluation pass, normal divider unchanged (context: docs/plan_context/performance-follow-up.md#guarded-padding-qualification; done 2026-10-28 18:21 EDT; this commit).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
