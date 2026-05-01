# PLAN.md — blip_mp roadmap

Working order, smallest reviewable increments. Strict TDD where business logic exists.

## Milestone 0 — Scaffolding (greenfield, target: today)

- [x] Write `PROJECT_OVERVIEW.md` (2026-04-30)
- [x] Write `PLAN.md` (this file) (2026-04-30)
- [x] Write `CODE_MINIMAP.md` (stub) (2026-04-30)
- [ ] `flake.nix` with `nixpkgs` + `flake-utils` + `zig` + `gmp` + `hyperfine` (no external BLIP dep — we reimplement from spec)
- [ ] `build.zig` with: static lib `libblip_mp`, unit test step, `blip_mp_bench` exe; ReleaseFast default; `DEBUG BUILD` banner in bench
- [ ] `build.zig.zon` with name/version
- [ ] `./build`, `./test`, `./bm` Bash drivers
- [ ] First failing test: `encodeU64Canonical(5)` → bytes == `[0x05]` (single-byte BLIP immediate)
- [ ] Implement BLIP integer encoding in `src/encoding.zig` per `BLIP_SPEC_CONCISE.md`; pass first test plus boundary tests at 0/127/128/255/256/65535/65536/u64.max
- [ ] Wire `blip_mp_t` (`{bytes, len}`) and `setU64` over the encoding
- [ ] Test passes; first jj commit; verify Garnix CI green
- *Curiosity poke (resolved by spec):* `0` encodes as `[0x00]` immediate (single byte), per spec worked example.
- *Curiosity poke:* spec says continuation kicks in at `L >= 32`. For tier 0/1 (`L ≤ 8`) we never hit continuation. Worth a single test that asserts no-continuation for L=8, so we don't accidentally over-engineer.

## Milestone 1 — Tier 0/1 arithmetic (the hypothesis test)

- [x] `Mp.setU64` / `Mp.getU64` round-trip across boundaries (2026-04-30)
- [x] `Mp.setI64` / `Mp.getI64` signed two's-complement, with `encodeI64Canonical` / `decodeI64` primitives in encoding.zig (2026-04-30)
- [x] `Mp.cmp` and `Mp.sign` (2026-04-30)
- [x] `Mp.add` tier 0/1, native `i64` with `@addWithOverflow`, `error.TierOverflow` for results > i64.max (2026-04-30)
- [x] `Mp.sub` tier 0/1 (2026-04-30)
- [x] `Mp.mul` tier 0/1 via i128 widen for full product (2026-04-30)
- [x] Canonicalization on every `setI64` (re-encodes from scratch, naturally canonical) — verified by `add: canonical-L shrink after sign-extension cancellation` test (2026-04-30)
- [ ] C FFI header (`include/blip_mp.h`) covering the above (deferred to M2 alongside benchmark)
- *Resolved poke:* tier-1 → tier-1 overflow currently returns `error.TierOverflow` instead of promoting. For Milestone 1 (hypothesis test) this is fine — the small-value benchmark stays well under i64.max. Promotion to L=9+ is a Milestone 3 concern.
- *Resolved poke:* canonical-L is automatic since `setI64` always re-encodes from scratch. No separate canonicalization pass needed.
- *New poke:* `Mp.add` decodes both operands every call (one `decodeI64` per arg). For a tight accumulator loop, that's wasted work — we keep re-decoding the same operand. A bench-justified optimization: cache the i64 inside `Mp` for tier-0/1 values so add can short-circuit. Wait for benchmark numbers before optimizing.

## Milestone 1.5 — Cleanup (2026-04-30 EST)

- [x] Drop the unsigned `encodeU64Canonical`/`decodeU64` and tests — Peter correctly noted the dual-encoder split was self-inflicted. The "where is the sign bit" issue dissolves once we commit fully to signed two's-complement (the bit is, by definition, the high bit of the high payload byte). Encoder still picks L based on signed range; that's the only signedness-aware decision. (2026-04-30 21:25 EST)

## Milestone 2 — Benchmark harness (proof or disproof)

- [x] `gmp` already in `flake.nix` `buildInputs` (added during M0 in anticipation) (2026-04-30)
- [ ] `tests/benchmark/small_accumulator.zig` — accumulator loop summing N values into a bignum
- [ ] Same workload in C against GMP, same optimization level
- [ ] `./bm` runs both, reports ratio, asserts no `DEBUG BUILD` banner
- [ ] **Decision point**: if blip_mp ≥ 1.5× faster, proceed to M3. Otherwise document findings in `BENCHMARK_RESULTS.md` and stop.
- *Curiosity poke:* allocator choice matters. GMP uses libc malloc by default; should compare apples-to-apples (same allocator), or measure each with its native allocator and report both numbers.
- *Curiosity poke:* my current `Mp.add` decodes both operands every call. For a tight accumulator loop, that's wasted work. The bench may surface this as a bottleneck. Don't pre-optimize — let the numbers speak.

## Milestone 3 — Tier 3 (only if Milestone 2 succeeds)

Out of scope for first proof. Sketch only — flesh out after the small-value win is demonstrated.

- [ ] Decide: link libgmp's mpn layer, or reimplement?
- [ ] Unpack/repack between BLIP payload and aligned `mp_limb_t[]` buffer
- [ ] Tier 3 add/sub/mul, validated against GMP for correctness
- [ ] Cross-tier promotion paths (tier 1 overflow → tier 3 alloc)

## Done items

(none yet — project just initialized 2026-04-30)
