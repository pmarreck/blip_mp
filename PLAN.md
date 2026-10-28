# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Prepare the paired Montgomery small-width sweep with accepted/rejected classifier sets, expanded GMP fixtures and CLI checks; pass full native tests/build and all-system evaluation (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 03:56 EDT; this commit).

## Follow-up and existing backlog



- [x] Measure paired public Montgomery squaring: all ten processes verify, every process mean favors symmetry and medians save about 3–18% across 512–3072 bits; retain unbaselined verdicts (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 04:12 EDT; this commit).
- [x] Qualify and select symmetric Montgomery squaring for 64–384-byte modulus magnitudes; retain explicit paired controls, pass 2304 new public GMP boundary comparisons and full native tests/build/all-system evaluation (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 04:36 EDT; this commit).
- [x] Prepare nine-byte centered signed-BLIP Goldilocks storage with independent codec/DFT/GMP controls and a paired complete-product probe; pass full native tests/build and all-system evaluation (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 04:49 EDT; this commit).
- [ ] Measure centered signed-BLIP Goldilocks products, inspect generated conversion code and retain or reject the storage experiment before any production selection (context: docs/benchmarks/goldilocks/README.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
