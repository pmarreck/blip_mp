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

- [ ] `blip_mp_get_u64` round-trip (set then get, all values in `[0, u32_max]`)
- [ ] `blip_mp_set_i64` / `blip_mp_get_i64` for signed two's-complement
- [ ] `blip_mp_cmp` zero-decode comparison for same-encoding-class operands
- [ ] `blip_mp_add` tier 0/1: native `u64` with overflow detect, promote on overflow
- [ ] `blip_mp_sub` tier 0/1
- [ ] `blip_mp_mul` tier 0/1 (use `@mulWithOverflow` or `u128` widen)
- [ ] Canonicalization pass: shrink `L` after sign-extension cancellation
- [ ] C FFI header (`include/blip_mp.h`) covering the above
- *Curiosity poke:* tier 1 → tier 1 add can overflow into tier-2 territory (L=9). Do we promote in-place, or always allocate? Memory custody of `bytes` matters here.
- *Curiosity poke:* `-1` has 4 valid L encodings (1,2,4,8). Add must produce canonical L on output, even when both inputs were L=8. This is the "carry-out smaller than operand" trap from SPEC §Open question 7.

## Milestone 2 — Benchmark harness (proof or disproof)

- [ ] Add `gmp` to `flake.nix` for the comparison build
- [ ] `tests/benchmark/small_accumulator.zig` — sum of u32 array as bignum, 1M iterations
- [ ] Same workload in C against GMP, compiled with the same `-O3` (or equivalent)
- [ ] `./bm` runs both, reports ratio, asserts no `DEBUG BUILD` banner present
- [ ] **Decision point**: if blip_mp ≥ 1.5× faster on this workload, proceed to Milestone 3. If not, document findings in `BENCHMARK_RESULTS.md` and stop.
- *Curiosity poke:* allocator choice matters. GMP uses libc malloc by default; we should compare apples-to-apples (same allocator), or measure each with its native allocator and report both numbers.

## Milestone 3 — Tier 3 (only if Milestone 2 succeeds)

Out of scope for first proof. Sketch only — flesh out after the small-value win is demonstrated.

- [ ] Decide: link libgmp's mpn layer, or reimplement?
- [ ] Unpack/repack between BLIP payload and aligned `mp_limb_t[]` buffer
- [ ] Tier 3 add/sub/mul, validated against GMP for correctness
- [ ] Cross-tier promotion paths (tier 1 overflow → tier 3 alloc)

## Done items

(none yet — project just initialized 2026-04-30)
