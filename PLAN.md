# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Measure truncated products: all ten processes verify; 15–22% CPU savings just above padding jumps and regressions elsewhere keep fusion in production; derive exact Montgomery carry bounds and its unfavorable scalar product count (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 02:15 EDT; this commit).
- [x] Add rotating Stockham/fused/truncated product measurements around padding jumps, with separate history labels and preserved correctness/CLI controls; pass full native tests/build and all-system evaluation (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 01:55 EDT; this commit).
- [x] Add experimental input/output-truncated Goldilocks transforms with 46,368 independent DFT/mixed-inverse cases and GMP product checks; pass the complete native suite/build (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 01:51 EDT; this commit).
- [x] Select fused Goldilocks after paired product medians show 23–25% lower CPU time than Stockham, omit permutation scratch, retain the threshold and pass full native tests/build plus all-system evaluation (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 01:47 EDT; this commit).

## Follow-up and existing backlog


- [ ] Combine truncated regions with fused complete subtrees, verify independently and measure against both existing layouts before selecting production behavior (context: docs/benchmarks/goldilocks/TRUNCATED.md).

- [ ] Finish the retained-workload GMP-verified powm probe and profile remaining non-FFT multiplication/powm regressions; Montgomery carry bounds are documented, with no scalar product-count win (context: docs/benchmarks/storage-aware/MONTGOMERY.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
