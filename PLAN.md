# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Fix the reproduced Goldilocks CLI clock-resolution failure with larger smoke inputs, injected invalid-clock controls and captured failure diagnostics; 128 repeated checks and the full native suite/build pass (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 03:23 EDT; this commit).

## Follow-up and existing backlog


- [x] Measure the fused-subtree crossover and select at most seven-eighths occupancy within the two measured transform lengths; paired medians save about 7% at the cutoffs, with inconclusive/unbaselined history retained (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 03:01 EDT; this commit).

- [x] Add the retained-workload GMP-verified powm probe with allocation, timing, CLI and CI controls; pass full native tests/build and all-system evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 03:06 EDT; this commit).
- [x] Measure the verified powm baseline and sample its 3072-bit path: about 88% of whole-process user-cycle samples fall in montMul; preserve inconclusive/unbaselined verdicts and prepare an isolated symmetric-squaring candidate (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 03:27 EDT; this commit).
- [ ] Measure the isolated symmetric Montgomery-squaring candidate against the verified public baseline; qualify any dispatch boundary before production selection (context: docs/benchmarks/storage-aware/MONTGOMERY.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
