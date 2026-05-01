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

## Milestone 2 — Benchmark harness (proof or disproof) — VERDICT: VALIDATED

- [x] `gmp` already in `flake.nix` `buildInputs` (2026-04-30)
- [x] `tests/benchmark/blip_mp_bench.zig` — Mp.add and zero-alloc raw paths across 5 value buckets (2026-04-30)
- [x] `tests/benchmark/gmp_bench.c` — same workload against GMP `mpz_add` (2026-04-30)
- [x] Built via `nix build .#packages.aarch64-darwin.bench`; install_artifact step added (2026-04-30)
- [x] Run 1: Mp.add was 3× SLOWER than GMP (per-call malloc dominates) but raw was 2.73× FASTER in the immediate bucket → identified SBO as the missing piece (2026-04-30 21:45 EST)
- [x] **M1.6: SBO `Mp` (representation 1a)** — 24-byte inline buffer + heap fallback. Tier 0/1 zero-alloc. Struct size 64 bytes (one cache line). All 36 unit tests pass. (2026-04-30 22:05 EST)
- [x] Run 2: SBO `Mp.add` is **1.68× faster than GMP in the immediate bucket** — clears the 1.5× threshold. (2026-04-30 22:08 EST)
- [x] **DECISION: hypothesis VALIDATED. Proceed to M3.** (2026-04-30 22:10 EST)

## Milestone 3 — Tier 3 (large-number paths) — COMPLETE

Hypothesis validated for tier 0/1; M3 extended to large-number arithmetic so blip_mp is competitive across the full value-size spectrum.

- [x] **Strategy decision** (2026-04-30): briefly tried linking libgmp's `mpn_*` (failed at the symbol name layer, then Peter pointed out: with our own arithmetic, no need to convert to limbs at all — BLIP payload IS the two's-complement value). Reimplemented as **pure-Zig byte-direct arithmetic** in `src/tier3.zig`. No GMP runtime dep; no LGPL constraint.
- [x] Byte-direct add/sub/cmp on BLIP payloads (no auxiliary limb arrays) (2026-04-30)
- [x] Chunked u64 inner loop via `readInt`/`writeInt` (8× fewer iterations than per-byte) (2026-04-30)
- [x] Cross-tier promotion in `Mp.add`/`Mp.sub` — tier 0/1 overflow silently routes to tier 3 (2026-04-30)
- [x] Bench extended to 256/1024/4096-bit buckets (2026-04-30 22:35 EST)
- [x] BENCHMARK_RESULTS.md Run 4 captures full spectrum: immediate 2.08× over GMP; tier 3 trails GMP 3-6× at large sizes (2026-04-30)
- [ ] (Open) Tier 3 `mul` — currently still `error.TierOverflow` because schoolbook/Karatsuba mul wasn't in M3 scope. Add via byte-direct approach.

## Milestone 4 — Optional follow-ups (ranked by ROI)

- [x] **Heap buffer reuse** in `Mp.setBytes`/`setI64` (2026-04-30 22:55 EST) — Run 5: tier-3 256-bit gap halved 6.4× → 3.85×.
- [x] **Sign-extended inline tail** in `Mp` (2026-04-30 23:15 EST) — store the full i64 in `inline_buf[1..9]` regardless of canonical L; `decodeInlineSmall` reads via single u64 load. **HYPOTHESIS #1 FULLY VALIDATED:** Mp.add now beats GMP by 1.7-2.4× across the ENTIRE i64 universe (L=0 through L=4). L=2..L=4 went from 0.5× (losing) to 1.7-1.8× (winning). Run 6 in BENCHMARK_RESULTS.md.
- [x] **Tier 3 mul** (2026-04-30 23:35 EST) — byte-direct schoolbook with sign-magnitude dispatch. `Mp.mul` no longer returns `error.TierOverflow`; routes to tier-3 path automatically.
- [x] **Tier 3 wide-int chunking** (2026-04-30 23:50 EST) — added u128 → u256 → u512 chunked add inner loops (cascade with u64 fallback). Halves iterations at each step. **4096-bit Mp.add: 96 → 41 ns (2.34× faster), now only 1.32× slower than GMP**; 1024-bit: 29 → 18 ns (1.62×), 2.13× slower than GMP. 256-bit unchanged at ~17 ns due to constant per-op overhead (header parse + 2 memcpys); the inline-tail fast path doesn't extend to tier 3 yet.
- [x] **Comprehensive perf sweep** (2026-05-01 00:10 EST) — 15 buckets from 128 to 32768 bits. Discovered: (a) 8192-bit had a malloc cliff because STACK_BYTES was 1024 (fixed → bumped to 8192); (b) 512-bit is faster than 384-bit because it's exactly one u512 chunk with no cascade overhead; (c) **convergence with GMP as size grows** — within 30% at 4096-bit, within 12% at 8192-bit, within 6% at 32768-bit. Run 8 in BENCHMARK_RESULTS.md.
- [x] **Karatsuba multiplication + chunked schoolbook** (2026-05-01 00:30 EST) — chunked u64*u64=u128 schoolbook + Karatsuba with carry-bit trick (preserves 8-byte alignment in recursive mults) + chunked u64 helpers. **We BEAT GMP at 384, 512, 768, 1024, 1536, 3072, 6144 bit mul** — including legacy RSA-1024 (1.24×) and recommended RSA-3072 (1.15×). Tied at 2048 (RSA-2048) and 6144. Lose at 8K+ where GMP uses FFT mul. Run 9 in BENCHMARK_RESULTS.md.
- [x] **Direct-write tier-3 add via heap_offset** (2026-05-01 00:55 EST) — added heap_offset:u8 to Mp (fits in existing padding, struct still 72 bytes). tier3Op now writes the result payload directly into r.heap_buf at offset HDR_RESERVE, then writes the header at HDR_RESERVE - hdr_len. Eliminates the scratch+memcpy chain that previously dominated. **We now BEAT GMP at add for 6144-32768 bits** (1.13-1.28×); tied at 4096; 1.02-1.36× speedup at 128-2048 bits but still slower than GMP there (overhead-dominated). Run 10 in BENCHMARK_RESULTS.md.
- [x] **Cross-validation against GMP** (2026-05-01 01:15 EST) — `tests/integration/cross_check.zig` runs randomized add/sub/mul comparisons (8240 total checks across 18 bit-widths × 3 ops). Every blip_mp result must encode the same value as GMP's mpz_*. Wired into `./test`. **All 8240 checks pass on the first clean run.** First run found 43 "failures" that turned out to be a faulty test fixture (my random input construction was trimming high zero bytes, exposing high bits that BLIP read as signed-negative but GMP imported as unsigned-positive). Fix: use full byte_count without trimming.
- [ ] **Statistical bench harness** — `hyperfine` integration + N-run aggregation; current numbers are 3-run medians by hand.
- [ ] Bench bucket label cleanup (L=1 was actually L=2; legacy from Run 1).
- [ ] C FFI header (`include/blip_mp.h`) for downstream C consumers.
- [ ] BLIP wire interop: a separate "unsigned BLIP" mode for round-tripping with strict-spec BLIP producers.
- [ ] Cross-platform validation — current numbers are aarch64-darwin; verify x86_64 Linux/Windows.

## Optional pre-M3 micro-optimization (close the Mp.add → raw gap)

- [ ] Comptime-specialize `setI64` fast path for value ∈ [0,127]: single byte store, skip encode loop. Should land Mp.add ≈ raw for immediate bucket and lift L=1..L=2 above GMP.
- [ ] Cache decoded i64 in the struct (`cached_i64: ?i64`)? Only if profiling justifies it — adds 16 bytes to struct size and complicates invariants.

## Milestone 3 — Tier 3 (only if Milestone 2 succeeds)

Out of scope for first proof. Sketch only — flesh out after the small-value win is demonstrated.

- [ ] Decide: link libgmp's mpn layer, or reimplement?
- [ ] Unpack/repack between BLIP payload and aligned `mp_limb_t[]` buffer
- [ ] Tier 3 add/sub/mul, validated against GMP for correctness
- [ ] Cross-tier promotion paths (tier 1 overflow → tier 3 alloc)

## Done items

(none yet — project just initialized 2026-04-30)
