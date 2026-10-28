# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Fix the reproduced Goldilocks CLI clock-resolution failure with larger smoke inputs, injected invalid-clock controls and captured failure diagnostics; 128 repeated checks and the full native suite/build pass (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 03:23 EDT; this commit).
- [x] Measure fused-subtree products: all 15 processes verify; paired medians save about 15% at 100000 bytes and 34–40% just above padding jumps, with losses near full transforms; retain the inconclusive one-CPU cohort and prepare a distinct crossover sweep (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 02:40 EDT; this commit).

## Follow-up and existing backlog


- [x] Measure the fused-subtree crossover and select at most seven-eighths occupancy within the two measured transform lengths; paired medians save about 7% at the cutoffs, with inconclusive/unbaselined history retained (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 03:01 EDT; this commit).

- [x] Add the retained-workload GMP-verified powm probe with allocation, timing, CLI and CI controls; pass full native tests/build and all-system evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 03:06 EDT; this commit).
- [ ] Measure the verified powm baseline and sample the public path before choosing a Montgomery optimization (context: docs/plan_context/performance-follow-up.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
