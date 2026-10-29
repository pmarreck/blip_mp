# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Can reciprocal division be selected only for winning cases? Answer: The tested guard already selected dividend magnitudes ≥64 bytes and divisors ≤8 bytes; selected cases improved, but unselected paths regressed with changed code generation; the explicit experimental entry remains available and automatic dispatch needs isolation and remeasurement (context: docs/plan_context/performance-follow-up.md#selective-dispatch-clarification-october-29; done 2026-10-29 11:32 EDT; this commit).
- [x] What is the unsigned-interoperability choice? Answer: Optional adapters for consumers that interpret BLIP payloads as unsigned; BLIP itself supports either interpretation, and this library deliberately chooses signed two's complement; earlier strictness wording was misleading (context: TERMINOLOGY.md#signedness-and-optional-interoperability; done 2026-10-29 11:32 EDT; this commit).
- [x] Adopt MIT in LICENSE, current documentation and package metadata; the built package includes the matching license text, complete tests/build/all-system evaluation pass (done 2026-10-29 11:33 EDT; this commit).

## Follow-up and existing backlog

- [ ] Decide whether optional unsigned-BLIP import/export adapters are needed for a concrete consumer; the signed representation conforms to the specification's signed interpretation, and binary-base GMP float validation remains conditional on a consumer (context: TERMINOLOGY.md#signedness-and-optional-interoperability).
- [x] Choose MIT or Apache-2.0 before release; Answer: MIT, explicitly selected October 29, 2026 (done 2026-10-29 11:27 EDT; this commit).
