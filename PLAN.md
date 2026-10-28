# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Select the chunk-reading B-Z fallback after paired samples show 6–19× gains with near-parity recursive controls; preserve unbaselined/inconclusive verdicts and pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 06:34 EDT; this commit).
- [x] Select the 128-byte B-Z cutoff after paired samples show 78–94% CPU savings with near-parity odd-width controls; preserve cohort verdicts and pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 06:46 EDT; this commit).
- [ ] Compare the selected B-Z cutoff directly against chunk-reading Knuth over a bounded wider size sweep before considering the public division threshold.
- [x] Report inverse-probe significant widths and correct the historical recursive-HGCD fallback attribution; pass the complete suite, build and all-system evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 06:29 EDT; this commit).
- [x] Establish exact 4095/4096/4097-bit inverse fixtures with GMP, accepted-width and allocation-failure controls; pass the complete suite, build and all-system evaluation (context: docs/plan_context/performance-follow-up.md; done 2026-10-28 06:41 EDT; this commit).
- [ ] Measure wider-window versus recursive inverse calls on an expanded exact-width corpus with paired timing and verified results before changing dispatch.
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
