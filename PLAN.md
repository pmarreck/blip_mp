# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Compare short-quotient B-Z with fixed B-Z and public division; Answer: sampled eligible cases take 1/25–1/30 of fixed B-Z CPU time but remain 26–30% slower than public division, with a 34–40× public-path penalty just outside the cutoff; select the local fallback, retain the public threshold and preserve all verdicts (context: docs/plan_context/performance-follow-up.md#short-quotient-results-and-selection; done 2026-10-28 14:54 EDT; this commit).
- [x] Qualify carried-remainder leaf selection with failing-first allocation controls, signed GMP/native/alias/OOM coverage and paired probes; full tests/build/evaluation pass, with two earlier unexplained clock-check failures preserved (context: docs/plan_context/performance-follow-up.md#short-carried-remainder-experiment; done 2026-10-28 15:14 EDT; this commit).
- [x] Measure carried-remainder leaf selection; Answer: sampled balanced/long even-width divisions save 21–24%/9–11% CPU against fixed short-quotient B-Z, with control medians within 0.4% of parity; select locally after 50 correct processes and full tests/build/evaluation, retain unbaselined verdicts and public threshold (context: docs/plan_context/performance-follow-up.md#short-carry-results-and-selection; done 2026-10-28 15:23 EDT; this commit).
- [x] Qualify a matched comparison of public BLIP, Knuth, selected B-Z and GMP with failing-first schedule, arithmetic/corruption, allocation and CLI checks; preserve the original cutoff-128 probe and pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#selected-kernel-gmp-comparison-qualification; done 2026-10-28 15:28 EDT; this commit).
- [ ] Measure the qualified selected-kernel GMP comparison and report public versus kernel results separately (context: docs/plan_context/performance-follow-up.md#selected-kernel-gmp-comparison-qualification).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
