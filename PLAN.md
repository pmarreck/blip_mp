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

## Milestone 6 — Toom-Cook 4-way and FFT multiplication

The path to multiplication parity with (and beat) GMP at all sizes ≥ 4K-bit. Strict TDD throughout — each substep gets a failing test, a passing implementation, then cross-validation against schoolbook for many random inputs before the next step starts.

### M6-2 — Toom-Cook 4-way multiplication (the warm-up)

Bridges Toom-3 and FFT. O(n^log_4 7) ≈ O(n^1.40). Splits each operand into 4 parts, evaluates at 7 points {0, 1, -1, 2, -2, 1/2, ∞}, performs 7 sub-multiplications, then interpolates. Should win in the 4K-16K bit range where Toom-3's per-call overhead is amortized but FFT's huge constant isn't yet justified.

Substeps (each is one TDD cycle):

- [ ] **M6-2.1** Helper: `divExactBy5` (Hensel division by 5; needed for Toom-4 interpolation matrix). Test: round-trip `mul × 5` then `divExactBy5`.
- [ ] **M6-2.2** Helper: `mulSmallSignedConst(a_sm, c, out_sm)` — sign-magnitude scalar multiplication. Test against per-byte reference.
- [ ] **M6-2.3** `mulToom4(a, b, r, scratch)` — equal-length operands. Recurse to Karatsuba for sub-mults below TOOM4_THRESHOLD. Bodrato-Zanoni interpolation matrix. Test: cross-check against schoolbook for sizes 32K-bit through 256K-bit (the range Toom-4 might apply).
- [ ] **M6-2.4** Algorithm-selector update: dispatch Toom-4 above TOOM4_THRESHOLD (start with 4096 bytes / 32K-bit; calibrate via bench).
- [ ] **M6-2.5** Bench at 16K, 32K, 64K, 128K-bit. Decide threshold. Update RESULTS.md.

Expected gain: ~15-30% over Toom-3 at 32K+ bit. Modest but real.

### M6-3 — Schönhage-Strassen FFT multiplication (the headliner)

O(n log n log log n). The asymptotic queen of bignum multiplication. Closes the 8K+ bit mul gap to GMP definitively.

Plan: Number-Theoretic Transform (NTT) over a prime field. Single-prime initially (covers ≤ ~32K-bit operand sizes); two-prime CRT extension later if we want to keep going to ~megabit operand sizes.

**Limb-independent BLIP-paradigm note:** the NTT operates on an array of integers in [0, p). These are *algorithm-internal scratch* (the FFT digit-frequency-domain values), NOT a parallel storage of the operand. We read bytes from BLIP encodings as FFT digits via the same `readChunkOrZero` pattern Karatsuba already uses; we write the carry-propagated result back to BLIP bytes at the end. The transform array IS a u64 array, but it's no more "limb storage" than Karatsuba's u64 chunked reads are. The bytes remain the canonical operand representation throughout.

Substeps (each is one TDD cycle):

- [ ] **M6-3.1** Pick the prime. Probably `p = 998244353` (29-bit, supports transforms up to length 2^23). Document the choice + the constraint it places on operand size + digit width.
- [ ] **M6-3.2** Modular arithmetic helpers (`addModP`, `subModP`, `mulModP`). Test: closure under field operations + identity laws on random values.
- [ ] **M6-3.3** Modular exponentiation `powMod(base, exp, p)` for computing root-of-unity powers. Test: known small values; round-trip `g^(p-1) ≡ 1 mod p` for primitive root `g`.
- [ ] **M6-3.4** Find an Nth primitive root of unity for our chosen N. Test: `omega^N ≡ 1 mod p` and `omega^(N/2) ≡ -1 mod p`.
- [ ] **M6-3.5** Bit-reversal permutation `bitReverse(arr)`. Test: idempotent (apply twice = identity).
- [ ] **M6-3.6** Forward NTT (Cooley-Tukey, in-place, radix-2 butterfly). Test against naive O(n²) DFT on small arrays for many random inputs.
- [ ] **M6-3.7** Inverse NTT (same as forward NTT with inverse root + final scaling by N⁻¹). Test: forward then inverse = identity, on random arrays.
- [ ] **M6-3.8** Pointwise multiplication mod p. Trivial; test for correctness.
- [ ] **M6-3.9** Byte-to-digit packing (`bytesToDigits(bytes, M)` where M is digit width in bits). Test: round-trip with `digitsToBytes`.
- [ ] **M6-3.10** Carry propagation from digit array back to bytes. Test: known small examples.
- [ ] **M6-3.11** Top-level `mulFFT(a, b, r, scratch)`. Composes 3.9 → 3.6 (forward NTT both) → 3.8 (pointwise) → 3.7 (inverse NTT) → 3.10 (carry-propagate). Test: cross-check against schoolbook for many random sizes from 1K to 32K-bit.
- [ ] **M6-3.12** Algorithm-selector update: dispatch FFT above FFT_THRESHOLD. Calibrate via bench (probably 8K-16K bit operand size).
- [ ] **M6-3.13** Bench at all sizes 8K-32K-bit. Compare to GMP. Update RESULTS.md.
- [x] **M6-3.1–3.7** NTT primitives + Cooley-Tukey forward/inverse over p=998244353 (2026-05-02 EST)
- [x] **M6-3.8–3.12** mulMagnitudes + dispatcher integration; 8240/8240 GMP cross-checks pass for 24K and 32K bit when enabled (2026-05-02 EST)
- [x] **M6-3.13** Bench + precomputed-twiddle optimization (2.14× FFT-path speedup, 410K → 191K ns at 32K-bit) + honest disable: single-prime FFT 1.77× SLOWER than Toom-3 even with twiddle precomp (2026-05-02 EST)
- [x] **M6-3.14** Two-prime CRT extension (Field abstraction, F1=998244353/F2=985661441, MAX_FFT_CRT_COMBINED_LEN=65536). Schoolbook-validated up to 256K-bit. Gated off — CRT loses to Toom-3 by 2.3–4.5× across the entire supported range because it doubles NTT work atop an already-losing constant factor (2026-05-02 EST)

### M6-4 — FFT constant-factor crusade (the actual win path)

The honest verdict from M6-3.13/3.14: pure-software NTT in u64 land cannot beat the compiler's `% P` magic-number lowering on aarch64 (verified empirically — Barrett, Montgomery's simpler half, none win when reduction is per-multiply with no amortization). The crossover with Toom-3 sits above our test range. Three independent multiplicative levers must compound to flip it:

#### M6-4-A — NEON-SIMD vectorized butterflies (highest ROI per unit work)

Modular butterflies on aarch64 NEON: pack 2 × u64 lanes per `uint64x2_t`, do `add`/`sub`/`mul` lane-wise, lower `% P` to magic-number multiply via vectorized `umulh` (the high-half multiply). Expected 2-3× on the inner loop (more if we pack 4 × u32 by halving the prime).

- [x] **M6-4-A.1** Microbench harness `tests/benchmark/fft_microbench.zig` (2026-05-02 EST)
- [x] **M6-4-A.2** Vectorized `addModP_x2` + `subModP_x2`. **1.66–1.85× lane speedup.** (2026-05-02 EST)
- [x] **M6-4-A.3** Vectorized `mulModP_x2` (hybrid scalar-inside-vector — exploits M4's dual scalar mul pipes alongside NEON). **1.34–1.43× lane speedup.** (2026-05-02 EST)
- [x] **M6-4-A.4** Vectorized butterfly `nttWithTwiddlesVec` — paired (k, k+1) lanes when half ≥ 2. (2026-05-02 EST)
- [x] **M6-4-A.5** Production `mulMagnitudes` switched to vec NTT. 8240/8240 GMP pass. (2026-05-02 EST)
- [x] **M6-4-A.6** Bench: 32K-bit FFT path 191K → 135K ns (1.40× full-FFT). Did NOT hit ≤ 95K target — Toom-3 still wins at 117K ns. The remaining 13–15% needs algorithmic restructuring or alloc-elimination, not more SIMD. (2026-05-02 EST)

Actual gain: 1.40× full-FFT speedup. Closed Toom-3 gap from 1.93× to 1.15×. Substantial but not flipped.

#### M6-4-B — Montgomery reduction (scaffolding shipped, integrates SLOWER on M4)

- [x] **M6-4-B.1–B.4** `to_mont` / `from_mont` / `montMul` (scalar) + `montMul_x2` (pure-NEON, no umulh) + `nttWithTwiddlesMontVec`. Bit-equivalent vs `(a*b)%P` on 100K random. (2026-05-02 EST)
- [x] **M6-4-B.5** Bench: Mont microbench WINS (0.70 vs 0.76 ns/vec_op for `mulModP_x2`), but integrates SLOWER (39K vs 35K ns/pass at N=8192). Mp.mul 32K-bit Mont-FFT: 152K ns (REGRESSES from 135K). (2026-05-02 EST)

Root cause (asm-verified): on M4, pure-NEON Mont moves all work onto NEON pipe, starving the dual scalar mul pipes that the existing `mulModP_x2` exploits. Mont kept as scaffolding for x86_64 / different M-series silicon revisions.

Actual gain: NEGATIVE on M4. Counter-intuitive but rigorously demonstrated.

#### M6-4-C — Stockham auto-sort (scaffolding shipped, ~9% per pass / ~1-2% per full mul)

- [x] **M6-4-C.1** `nttStockham` (scalar) + `nttStockhamVec` (vec). Bit-exact match across N in {2..8192}. (2026-05-02 EST)
- [x] **M6-4-C.2** Production NOT switched — pattern preserved. Stockham per-pass 32.7K vs 35.7K vec-CT (1.10×). (2026-05-02 EST)
- [x] **M6-4-C.3** Bench: bit-reversal at N=8192 cost only ~3K ns/pass not the projected ~8K. OOO + L1 prefetch hide most random-access cost on M-series. (2026-05-02 EST)

Actual gain: ~9% per NTT pass, ~1-2% per full mul.

#### M6-4-D — Radix-4 NTT (scaffolding + critical pedagogical correction)

- [x] **M6-4-D** `nttRadix4Vec` — radix-4 mixed (with one radix-2 pass when log2(N) is odd). Bit-exact vs vec-CT. **CRITICAL FINDING:** the classical 25% radix-4 mult-reduction comes from FLOATING-POINT FFT lit where multiplication by `i` is FREE. In NTT, `i = ω_4 mod p` is a generic non-trivial constant — full mulModP. Mult counts at N=8192: radix-2 = 53,248; radix-4 mixed = 53,248 (IDENTICAL). Bench: 36.7K vs 37.4K (1.02×, within noise). (2026-05-02 EST)

Actual gain: ~0%. Standard FFT trade-off literature corrected for NTT.

#### M6-4 cumulative status at 32K-bit Mp.mul (2026-05-02 EST)

```
Pre-SIMD (M6-3.13 baseline):    191K ns
Post-A.5 (vec NTT in production): 135K ns  (1.40× speedup)
Post-A.6 / B / C / D scaffolds:  135K ns  (no production change)
Toom-3 baseline:                 117K ns  ← still wins by 13–15%
```

Closed FFT-vs-Toom-3 gap from 1.93× to 1.15×. Substantial but not flipped.

#### M6-4-E — Remaining levers to flip the ratio (future work)

- [ ] **M6-4-E.1** Caller-supplied scratch — eliminate per-call alloc/free of `pa`/`pb`/`tw_fwd`/`tw_inv` (4 allocs × ~1-2K ns = 4-8K ns saved). Brings 32K-bit FFT from 135K → ~127K ns.
- [ ] **M6-4-E.2** Wire Stockham into production with caller-supplied scratch (avoids the extra-buffer regression that diluted M6-4-C.2). Brings to ~123K ns.
- [ ] **M6-4-E.3** Hand-scheduled aarch64 inline asm for the butterfly inner loop — schedules mul/umulh on scalar pipes WHILE NEON handles add/sub/load/store. Architecturally what M4 wants, fragile (M-series-specific). Possibly closes remaining 6-9 K ns.
- [ ] **M6-4-E.4** OR accept Toom-3 as production winner in supported range. FFT primitives essential when extending past Toom-3's natural crossover (~512K-bit+).

### Sequencing decision (revised after empirical M6-3 finding)

The "Toom-4 first" plan in M6-2 is now lower priority. Toom-3 is solidly the best of the schoolbook-class algorithms in our range. Until FFT-class can beat Toom-3 (M6-4), Toom-4's modest 15-30% gain isn't worth the implementation work. Leave M6-2 helpers in (divExactBy5, mulSmallSignedConst) as future-work building blocks.

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
