# PLAN

Purpose: [INTENT.md](INTENT.md). The [legacy roadmap](docs/plan_context/legacy-roadmap.md) preserves all prior tasks, decisions and measurements; its checkboxes include stale and conflicting statuses.

## Current work (BDFN (Benevolent Dictator For Now), 2026-09-27)

- [x] Replace production limb-array storage with byte buffers; pass the storage audit and 13,053 GMP comparisons (done 2026-09-27 16:30 EDT).
- [x] BLIP-encode every stored FFT residue and twiddle; verify canonical encodings, transforms and allocation failure cleanup (done 2026-09-27 16:30 EDT).
- [ ] Capture comparable ReleaseFast benchmarks before and after the migration, including repeated runs and platform details.
- [ ] Update README.md and linked benchmark/result documents with the new measurements and their limits.
- [ ] Research GMP's large-integer algorithms, existing SIMD paths and candidate optimizations; separate established techniques from untested or potentially novel ideas.

## Documentation

- [x] Establish INTENT.md with BDFN's BLIP origin and size-dependent GMP framing; migrate terminology and preserve the roadmap history (done 2026-09-27 15:58 EDT; a6d0d3e).

## Existing backlog to reconcile before implementation

- [ ] Reconcile legacy task statuses against code and Git history before selecting further work; retain unresolved tasks and dependencies (context: docs/plan_context/legacy-roadmap.md).
- [ ] Continue GMP performance work across operand sizes; measure FFT viability, recursive HGCD dependencies, division thresholds and small-divisor paths; hand assembly remains deferred per the May 18 record (context: docs/plan_context/legacy-roadmap.md).
- [ ] Investigate the pre-existing ReleaseSafe self-copy panic in Mp.addU64(&self, 0), observed while preparing the residue encoding oracle.
- [ ] Reconcile benchmark aggregation follow-ups with the recorded completion of ./bm --stable N (context: docs/plan_context/legacy-roadmap.md).
- [ ] Resolve strict unsigned-BLIP interoperability and conditional binary-base GMP float cross-validation requirements before implementation (context: docs/plan_context/legacy-roadmap.md).
- [ ] Choose MIT or Apache-2.0 before tagging a release.
