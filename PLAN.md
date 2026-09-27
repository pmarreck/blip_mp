# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Documentation

- [x] Establish INTENT.md with BDFN (Benevolent Dictator For Now)'s BLIP origin and size-dependent GMP framing; migrate terminology and preserve the roadmap history (done 2026-09-27 15:58 EDT; this commit).

## Existing backlog to reconcile before implementation

- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Complete M15 byte-buffer storage for division and FFT intermediates, then audit the fully limbless claim (context: docs/plan_context/legacy-roadmap.md).
- [ ] Reconcile benchmark aggregation follow-ups with the recorded completion of ./bm --stable N (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
