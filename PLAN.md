# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone

- [x] Add fused complete subtrees to truncated Goldilocks, retain both controls, pass 92,736 independent transform cases and 13,183 GMP comparisons, and add a separate paired measurement mode; full native tests/build and all-system evaluation pass (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 02:28 EDT; this commit).
- [x] Measure truncated products: all ten processes verify; 15–22% CPU savings just above padding jumps and regressions elsewhere keep fusion in production; derive exact Montgomery carry bounds and its unfavorable scalar product count (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 02:15 EDT; this commit).
- [x] Add rotating Stockham/fused/truncated product measurements around padding jumps, with separate history labels and preserved correctness/CLI controls; pass full native tests/build and all-system evaluation (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 01:55 EDT; this commit).
- [x] Add experimental input/output-truncated Goldilocks transforms with 46,368 independent DFT/mixed-inverse cases and GMP product checks; pass the complete native suite/build (context: docs/benchmarks/goldilocks/TRUNCATED.md; done 2026-10-28 01:51 EDT; this commit).

## Follow-up and existing backlog


- [ ] Measure fused-subtree Goldilocks against full fusion and recursive truncation across 16 sizes in 1/12-CPU cohorts; select production behavior only from verified evidence (context: docs/benchmarks/goldilocks/TRUNCATED.md).

- [ ] Finish the retained-workload GMP-verified powm probe and profile remaining non-FFT multiplication/powm regressions; Montgomery carry bounds are documented, with no scalar product-count win (context: docs/benchmarks/storage-aware/MONTGOMERY.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
