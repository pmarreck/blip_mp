# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Clarify BLIP's original intent and name; Answer: BLIP means "Binary Large Integer Prefix"; length framing and byte-order metadata serve arbitrary payloads, and sign/type semantics belong to payload conventions; corrected intent/terminology and verified float byte-order sources, existing suite passes (context: TERMINOLOGY.md#framing-and-payload-conventions; done 2026-11-06 15:36 EST; this commit).
- [x] Measure two reciprocal-isolation candidates against the retained public entry and GMP; both retain 41–47% CPU savings at 4,096-byte dividends but still take 1.90–1.99× GMP, bypassed controls remain noisy or slower, all 225 processes correct, fourteen cohorts inconclusive and ten unbaselined, public dispatch unchanged (context: docs/benchmarks/storage-aware/DISPATCH_ISOLATION.md#results-and-decision; done 2026-11-02 14:08 EST; source b1f8575).
- [x] Is application-defined signedness a problem or less optimal? Answer: Fixed application interpretation adds no per-call type selection, but two's-complement sign padding and magnitude conversions have costs; native/inline/header boundary tests verify the encoded-size examples, and alternative layouts remain unmeasured (context: docs/benchmarks/storage-aware/DISPATCH_ISOLATION.md#signedness; done 2026-11-02 13:48 EST; commit b1f8575).
- [x] Adopt MIT in LICENSE, current documentation and package metadata; the built package includes the matching license text, complete tests/build/all-system evaluation pass (done 2026-10-29 11:33 EDT; this commit).

## Follow-up and existing backlog

- [ ] Decide whether optional unsigned-BLIP import/export adapters are needed for a concrete consumer; the signed representation conforms to the specification's signed interpretation, and binary-base GMP float validation remains conditional on a consumer (context: TERMINOLOGY.md#signedness-and-optional-interoperability).
