# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Prepare the paired Montgomery small-width sweep with accepted/rejected classifier sets, expanded GMP fixtures and CLI checks; pass full native tests/build and all-system evaluation (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 03:56 EDT; this commit).

## Follow-up and existing backlog



- [x] Measure the verified powm baseline and sample its 3072-bit path: about 88% of whole-process user-cycle samples fall in montMul; preserve inconclusive/unbaselined verdicts and prepare an isolated symmetric-squaring candidate (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 03:27 EDT; this commit).
- [x] Add paired public Montgomery-squaring measurements with shared fixtures, mirrored batches, independent GMP/canary controls and unchanged production dispatch; pass full native tests/build and all-system evaluation (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 03:43 EDT; this commit).
- [x] Measure paired public Montgomery squaring: all ten processes verify, every process mean favors symmetry and medians save about 3–18% across 512–3072 bits; retain unbaselined verdicts (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 04:12 EDT; this commit).
- [ ] Run the prepared small-width Montgomery sweep, select a conservative measured cutoff and verify partial-chunk modulus widths, signs and aliases before production dispatch (context: docs/benchmarks/storage-aware/MONTGOMERY.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
