# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Qualify and select symmetric Montgomery squaring for 64–384-byte modulus magnitudes; retain explicit paired controls, pass 2304 new public GMP boundary comparisons and full native tests/build/all-system evaluation (context: docs/benchmarks/storage-aware/MONTGOMERY.md; done 2026-10-28 04:36 EDT; this commit).
- [x] Prepare nine-byte centered signed-BLIP Goldilocks storage with independent codec/DFT/GMP controls and a paired complete-product probe; pass full native tests/build and all-system evaluation (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 04:49 EDT; this commit).
- [x] Measure centered Goldilocks storage: all ten processes verify but paired medians regress about 38–43%; retain positive production storage and preserve the unbaselined result and code inspection (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 04:59 EDT; this commit).
- [x] Measure the centered common-header reader: median CPU gains leave complete products 20–27% slower than positive storage; retain positive production storage and preserve inconclusive/unbaselined verdicts (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 05:08 EDT; this commit).
- [ ] Establish an identical-input GMP-verified comparison of Burnikel–Ziegler and chunk-reading Knuth division before changing native leaf dispatch or recursion thresholds (context: docs/plan_context/performance-follow-up.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
