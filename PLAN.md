# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Measure the centered common-header reader: median CPU gains leave complete products 20–27% slower than positive storage; retain positive production storage and preserve inconclusive/unbaselined verdicts (context: docs/benchmarks/goldilocks/README.md; done 2026-10-28 05:08 EDT; this commit).
- [x] Add an identical-input GMP-verified Burnikel–Ziegler/Knuth probe with paired timing, allocation and CLI controls; pass full native tests/build and all-system evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 05:27 EDT; this commit).
- [x] Measure paired division curves and fallback boundaries; all 20 processes verify, with unbaselined results showing separate fallback and recursive costs (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 06:00 EDT; this commit).
- [x] Prepare an explicit chunk-reading B-Z fallback candidate with GMP, allocation and paired timing controls; pass the complete suite, build and all-system evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 06:00 EDT; this commit).
- [ ] Measure the chunk-reading B-Z fallback candidate against the old fallback with recursive widths as controls; select only if supported, then investigate recursive cutoffs (context: docs/plan_context/performance-follow-up.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
