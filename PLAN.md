# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current bounded milestone


## Follow-up and existing backlog



- [x] Measure the B-Z leading-block shortcut; Answer: paired medians save 40–43%/15–17%/6–8% CPU for short-quotient/balanced/long-dividend recursive cases, with fallback near parity and 45 correct processes; select the shortcut while preserving fixed controls and unbaselined/inconclusive verdicts (context: docs/plan_context/performance-follow-up.md#leading-block-results-and-selection; done 2026-10-28 14:20 EDT; this commit).
- [x] Qualify an explicit one-chunk quotient fallback with failing-first allocation classification across sixteen length differences, signed GMP/native/alias/OOM controls and five-geometry paired probes; pass full tests/build/evaluation (context: docs/plan_context/performance-follow-up.md#short-quotient-fallback-experiment; done 2026-10-28 14:30 EDT; this commit).
- [x] Compare short-quotient B-Z with fixed B-Z and public division; Answer: sampled eligible cases take 1/25–1/30 of fixed B-Z CPU time but remain 26–30% slower than public division, with a 34–40× public-path penalty just outside the cutoff; select the local fallback, retain the public threshold and preserve all verdicts (context: docs/plan_context/performance-follow-up.md#short-quotient-results-and-selection; done 2026-10-28 14:54 EDT; this commit).
- [x] Qualify carried-remainder leaf selection with failing-first allocation controls, signed GMP/native/alias/OOM coverage and paired probes; full tests/build/evaluation pass, with two earlier unexplained clock-check failures preserved (context: docs/plan_context/performance-follow-up.md#short-carried-remainder-experiment; done 2026-10-28 15:14 EDT; this commit).
- [ ] Measure B-Z leaf selection from each carried remainder's significant length against the fixed short-quotient entry; reject clock failures and preserve control geometries before selection or public-threshold changes (context: docs/plan_context/performance-follow-up.md#short-carried-remainder-experiment).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
