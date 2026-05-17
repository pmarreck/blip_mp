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

- [x] **M6-4-E.1** Caller-supplied scratch via thread-local FftScratch cache in tier3.zig. mulMagnitudesWithScratch shipped. (2026-05-02 EST)
- [x] **M6-4-E.2** Stockham wired into production via mulMagnitudesWithScratch. **32K-bit Mp.mul: 135K → 128K ns. FFT-vs-Toom-3 gap 1.15× → 1.07-1.08×.** Honest finding: libc malloc on M4 costs ~700-900 ns per call, not the projected 1-2K ns; the rest of the win came from finally uncovering Stockham's per-pass +9% × 3 passes. (2026-05-02 EST)
- [~] **M6-4-E.3** Hand-scheduled aarch64 inline asm for the butterfly inner loop. **Status (2026-05-14): PARTIAL.** Three attempts logged on `yolo`:
  - Attempt A (`8af848af`): Stockham+Mont hybrid — NEGATIVE, 7-10% slower (Mont's pure-NEON reduction crowds the same pipes as add/sub).
  - Attempt B (`c8b7f00f`): nttStockhamVecU4 manual unroll-by-2 — **POSITIVE, real ~6% improvement (32360 → ~31285 ns at N=8192)**. Wired into mulMagnitudes' production path. Closes ~half the original 13-15% target.
  - Attempt C (`f45fd62a`): nttStockhamVecU8 unroll-by-4 — NEGATIVE, no improvement (hits L1 LSU bandwidth ceiling at U4 already; more butterflies in flight don't help when compute isn't the bottleneck).
  Bandwidth-bound finding: ~80B per butterfly (3 NEON loads + 2 NEON stores × 16B) × 4 butterflies = 20 LSU ops/iter, saturating the M-series LSU. Real inline asm probably ≤ 2-3% upside given this ceiling. Real next-step paths: (a) cache-tile blocking to reduce L1 churn, (b) stp-paired stores via output reordering, (c) hand asm if all else fails. None small.
- [ ] **M6-4-E.4** OR accept Toom-3 as production winner in supported range. FFT primitives essential when extending past Toom-3's natural crossover (~512K-bit+).

## Milestone 7 — Division, modulo, and modular exponentiation — COMPLETE (2026-05-02)

Full division surface + powm shipped in one tight day. All results bit-identical to GMP's `mpz_tdiv_qr` / `mpz_mod` / `mpz_powm`. Byte-direct paradigm preserved.

### M7-1 — Tier 0/1 division (i64 fast path) — DONE 2026-05-02

- [x] **M7-1.1 + M7-1.2** Native `@divTrunc`/`@mod` i64 fast path; tier-3 promotion wired; `Mp.div`/`Mp.mod` dispatch on operand size. GMP truncated semantics throughout.

### M7-2 — Tier 3 division by single byte (the inner loop) — DONE 2026-05-02

- [x] **M7-2.1 + M7-2.2** `divModSingleByte` schoolbook + chunked `divModSingleU64` (8 bytes/iter). Same byte-direct chunking pattern as add/sub/mul.

### M7-3 — Tier 3 long division (Knuth Algorithm D) — DONE 2026-05-02

- [x] **M7-3.1 + M7-3.2 + M7-3.3** Full Knuth D tier-3 div/mod/divMod. Sign handling per `mpz_tdiv_qr` semantics (8 sign combos covered). Wired into `Mp.div`/`Mp.mod`/`Mp.divMod`; cross-validated against GMP in `tests/integration/cross_check.zig`.
- [x] **M7-3 perf follow-on (2026-05-03)** — Möller-Granlund 2/1 + 3/2 reciprocal q_hat estimation in `divModKnuthU64`: **22% faster at RSA-2048**. blip beats GMP at 2K-bit divMod by 24%.
- [x] **M7-3 perf follow-on (2026-05-15)** — heap-fallback vn scratch for divisors > 64K-bit (avoids stack overflow on extreme sizes).
- [x] **M7-3 perf follow-on (2026-05-16)** — per-thread VN scratch cache eliminates per-call malloc in `divModKnuthU64`.

### M7-4 — Modular exponentiation `Mp.powm(base, exp, mod)` — DONE 2026-05-02

- [x] **M7-4.1 + M7-4.2** Square-and-multiply + sliding-window (window size 4-6) `powm`. GMP cross-checked at RSA-1024/2048/3072.
- [x] **M7-4.3** Montgomery-form `powm` via existing `montMul`. **Beats GMP at 2048-bit by 11%, parity at 1024/3072.**
- [x] **M7-4.4** Bench shipped; gmp_bench.c extended with `mpz_powm`/`mpz_invert`/`mpz_tdiv_qr` sweeps. Warmup pass added for low-iteration measurements (powm/divMod/invMod).

### M7-5 — Modular inverse `Mp.invMod(a, m) -> a^-1 mod m` (extended Euclidean)

Required to complete the modular-arithmetic surface. Used in RSA private-key derivation (CRT shortcut), elliptic curve point operations.

- [x] **M7-5.1** Classical Extended Euclidean (chosen over Stein's binary GCD for simplicity — reuses existing `Mp.divMod`). Returns `bool` indicating whether the inverse exists; sets `r = 0` and returns false when gcd(a, m) ≠ 1, matching GMP `mpz_invert` semantics. (2026-05-02 EST) Tests: 5 unit tests (small known cases, no-inverse cases, division-by-zero, 200-iter random fuzz with `(a·r) mod m == 1` verification, 256-bit Curve25519 prime modulus). Cross-validated vs GMP `mpz_invert` across 762 random (a, m) pairs at 8/32/64/128/256/512/1024/2048-bit widths — all match (existence bit + result value).
- [x] **M7-5.2** GMP-convention behavior on non-coprime inputs: returns `false` instead of erroring; `r` set to 0. Verified with explicit test cases (gcd=2, 3, 4, 5) AND cross-check existence-bit comparison for all `no-inverse` cases at every bit-width. (2026-05-02 EST)

### Sequencing for M7

Bottom-up: M7-1 (i64 fast path) → M7-2 (single-byte divisor, the inner loop) → M7-3 (general long division) → M7-4 (powm, the headliner) → M7-5 (invMod, completes the API). Each substep is a single TDD cycle.

Total expected: comparable scope to M3 (tier-3 add/sub/mul), maybe larger because Knuth Algorithm D's quotient-digit-estimation has subtleties.

### Sequencing decision (revised after empirical M6-3 finding)

The "Toom-4 first" plan in M6-2 is now lower priority. Toom-3 is solidly the best of the schoolbook-class algorithms in our range. Until FFT-class can beat Toom-3 (M6-4), Toom-4's modest 15-30% gain isn't worth the implementation work. Leave M6-2 helpers in (divExactBy5, mulSmallSignedConst) as future-work building blocks.

## Milestone 5 — done (2026-04-30 → 2026-05-01)

The bookkeeping/perf-polish iterations after the M3 baseline. All shipped.
- M5-1: cache (payload_offset, payload_len, sign) on Mp struct
- M5-2: small-N fast paths in tier3Op
- M5-3: Toom-Cook 3-way mul for 4K-8K bit
- M5-5: GMP-without-asm controlled experiment ("asm gives ~0% on M-series")
- Heap buffer reuse, sign-extended inline tail (i64 universe 1.95-2.66× over GMP), wide-int chunking (u512→u256→u128→u64 cascade), direct-write via heap_offset, Karatsuba + chunked schoolbook, 8240-check GMP cross-validation harness

See git history for per-item detail.

## Milestone 8 — C FFI header (DONE 2026-05-02)

- [x] `include/blip_mp.h` (110 lines) + `src/c_api.zig` (172 lines) + `tests/cli/c_smoke.c` (270 lines). Full FFI surface: lifecycle, setters/getters, predicates (cmp/sign/is_zero), arithmetic (add/sub/mul/div/mod/divMod), modular (powm/inv_mod). Wired into `./test` as the third group alongside Zig units + GMP cross-checks.

## Milestone 9 — Lehmer's GCD speedup for invMod (DONE 2026-05-02)

- [x] **Mp.invMod via Knuth Algorithm L** — single-precision EEA on top u62 of (r0, r1) with 2x2 unsigned matrix accumulation; matrix applied to multi-limb (r0, r1, s0, s1) per Lehmer step. **2.9-4.6× over classical EEA.** Plus latent tier3DivModOp buffer-sizing bug fix.

## Milestone 10 — wider-window Lehmer (intermediate; DONE 2026-05-02)

- [x] **invModHGCD u128 wider-window** — same Lehmer algorithm at u128 matrix entries. **1.83× over M9 Lehmer at 2048-bit.** Combined cumulative gap: 7.85× → 3.96× at RSA-2048. (NOT true sub-quadratic HGCD — that's M11.)

## Milestone 11 — true recursive half-GCD (IN PROGRESS)

- [x] **M11.1 — Standalone HGCD primitive (NOT wired into invMod)** (2026-05-03 EST) — Shipped `Mp.HGCDMatrix` (multi-precision 2x2 with parity-tracked sign convention) + `Mp.hgcd(out_M, a, b, target_bits, allocator)` iterative Lehmer-style primitive that accumulates the reduction matrix via `composeOuter`. Bit-for-bit oracle test (HGCD-applied-to-(a,b) == classical-EEA-stepped-to-half-bit-threshold) passes across {64,128,256,512,1024,2048}-bit random pairs (12 iters/size). Plus identity + one-step EEA structural tests. Notable derivation finding: matrix composition formulas are identical across all four parity-of-self × parity-of-outer cases — only the parity bit flips.
- [x] **M11.1.2 — True recursive HGCD `Mp.hgcdRecursive` + `Mp.invModHGCDRecursive`** (2026-05-03 EST) — Divide-and-conquer recursion built on M11.1's matrix machinery. `invModHGCDRecursive` shipped at `src/bignum.zig:1829`. Three-way oracle test (Lehmer / wider-window / recursive) passes in `tests/integration/cross_check.zig`.
- [ ] **M11.2 — Route Mp.invMod to invModHGCDRecursive in production** — Apply the HGCD-produced matrix to `(s0, s1)` Bezout coefficients alongside `(r0, r1)`. Expected gain: 2-4× over M10 wider-window Lehmer at 2048-bit. Would close residual gap to GMP at RSA-2048 (currently 3.23×). **Status (2026-05-16)**: code exists but PROD-disabled — recursive HGCD wins require sub-quadratic matrix-product cost, which in turn requires FFT mul to beat Toom-3 in production. **Blocked on M6-4-E.3** (FFT butterfly hand-asm). Once that lands, route `Mp.invMod` to `invModHGCDRecursive` for tier-3 sizes ≥ ~512-bit.
- [ ] **Original framing (kept for context)** — true sub-quadratic O(M(n) log n) divide-and-conquer reformulation. References: Yap §2.6, GMP `mpn/generic/hgcd*.c`, TAOCP §4.5.3 problem 35. Lehmer remains the recursion base.

## Milestone 12 — Tier A GMP feature parity (surface, not perf)

**Goal:** cover the GMP `mpz_*` operations real consumers reach for that we currently lack. Perf is secondary; correctness via GMP cross-checks is mandatory for every op. Strict TDD: failing test first, watch it fail, minimal impl, rerun, refactor.

Each item: (a) Mp method in `src/bignum.zig`, (b) C FFI `export fn` + header decl in `src/c_api.zig` + `include/blip_mp.h`, (c) unit tests in `tests/unit/<feature>_test.zig`, (d) GMP cross-validation in `tests/integration/cross_check.zig` if applicable.

- [x] **M12-A1 — Bitwise** (2026-05-04): `Mp.bitwiseAnd / bitwiseOr / bitwiseXor / bitwiseNot / shiftLeft / shiftRight`. GMP-compatible two's-complement on negatives. Pure byte loops.
- [x] **M12-A2 — Sign / abs / fits** (2026-05-04): `Mp.neg`, `Mp.abs`, `Mp.fitsI64`, `Mp.fitsU64`, `Mp.fitsI32`, `Mp.fitsU32`. Boundary values tested.
- [x] **M12-A3 — String I/O hex+decimal** — `setStr`/`toString` for bases 2/8/10/16 live in `src/string_io.zig`. Decimal output is sub-quadratic (recursive split-and-conquer formatting, commit `ac52490`).
- [x] **M12-A4 — GCD / LCM** (2026-05-04): `Mp.gcd(a, b)` + `Mp.lcm(a, b)` via classical EEA over `Mp.divMod`. In `src/gcd.zig`. GMP cross-check at {64, 256, 1024, 2048}-bit pairs.
- [x] **M12-A5 — Random** (2026-05-04): `setRandomBits` + `setRandomBelow` (uniform in [0, n)) via `std.Random` interface.
- [x] **M12-A6 — Misc small** (2026-05-04): `Mp.popcount`, `Mp.scan0`, `Mp.scan1`. GMP semantics on negatives (popcount returns `usize.max`).

## Milestone 14 — Fixed-point arithmetic ("the IEEE754 disruption")

**Goal:** arbitrary-precision **exact** fixed-point arithmetic on top of `Mp`. No NaN, no ±∞, no signed zero, no denormals, no silent rounding. Every operation that can't be represented exactly either errors or returns an explicit (quotient, remainder) pair. Built for finance, exact decimal computation, fixed-point DSP/graphics, and any domain where IEEE754's "0.1 + 0.2 ≠ 0.3" is unacceptable.

**Architecture: dynamic-precision per-value.**
```zig
pub const Fp = struct {
    mantissa: Mp,        // arbitrary-precision integer
    scale:    i32,       // exponent (mantissa * base^scale)
    base:     enum { binary, decimal },
};
```
Mirrors blip_mp's "variable-length self-describing storage" philosophy: each value carries its own scale. **Binary base** = fast ×2^n shifts (DSP, graphics, Q-format). **Decimal base** = bit-exact ×10^n (finance, human-facing values, no representation drift).

**Foundational rule: no silent precision loss.** Division takes a precision budget (max scale digits to compute) and either errors on inexact-overflow OR returns `(quotient, remainder)` so the caller sees the exact tail. Calling code makes every rounding decision explicit.

### M14-1 — Type & lifecycle  →  src/fp.zig
- [x] `Fp` struct + `init(allocator) Fp` + `deinit()` — DONE 2026-05-08
- [x] `setI64(v, scale, base)` — DONE 2026-05-08
- [x] `setRationalDecimal(num, den)` — DONE 2026-05-08 (errors NonTerminating for primes ∉ {2,5})
- [x] `setRationalBinary(num, den)` — DONE 2026-05-08 (errors NonTerminating for primes ≠ 2)
- [x] `setStr(s, base)` — DONE 2026-05-08 (parses "3.14", "-0.5", ".5", "100.", etc.)

### M14-2 — Comparison + canonical form
- [x] `cmp(a, b)` — DONE 2026-05-08 (errors MixedBases on cross-base)
- [x] `eq(a, b)` — DONE 2026-05-08
- [x] `canonicalize(self)` — DONE 2026-05-08

### M14-3 — Add / sub / mul (the easy three)
- [x] `add(out, a, b)` — DONE 2026-05-08
- [x] `sub(out, a, b)` — DONE 2026-05-08
- [x] `mul(out, a, b)` — DONE 2026-05-08 (exact-by-construction, no precision loss)
- [x] **HEADLINE TEST**: 0.1 + 0.2 == 0.3 EXACTLY ✅

### M14-4 — Division (the hard one)
- [x] `divExact(out, a, b)` — DONE 2026-05-08
- [x] `divPrecision(out, a, b, max_scale_digits)` — DONE 2026-05-08 (returns bool exact)
- [x] `divQR(quot, rem, a, b)` — DONE 2026-05-14 (reconstruction bit-exact)

### M14-5 — Cross-base conversions
- [x] `toBinary(out, a)` — DONE 2026-05-13 (errors NonTerminating on 0.1₁₀ etc.)
- [x] `toDecimal(out, a)` — DONE 2026-05-13 (always exact)

### M14-6 — Round / floor / ceil / trunc
- [x] `roundToScale(out, a, target_scale, mode)` — DONE 2026-05-13. 8 modes: exact_or_error / toward_zero / toward_pos_inf / toward_neg_inf / half_up / half_down / half_to_even (banker) / half_to_odd
- [x] `roundToMp(out, a, mode)` — DONE 2026-05-13

### M14-7 — String I/O
- [x] `toStringCanonical(allocator, a)` — DONE 2026-05-08
- [x] `toStringFixed(allocator, a, frac_digits)` — DONE 2026-05-04 EST. Pads with trailing zeros if canonical has fewer; rounds (banker / half-to-even) if more. Honors sign + zero special-case. 9 inline tests.
- [x] `toStringScientific(allocator, a)` — DONE 2026-05-04 EST. Decimal '[-]M.MMMeE'; binary '[-]M.MMMpE' (C99 hex-float style with binary digits, not hex). Single-digit mantissas omit the radix point. 8 inline tests.

### M14-8 — IEEE754 interop
- [x] `setF64(self, v)` — DONE 2026-05-13. NaN/±∞ → NotRepresentable; ±0 → zero (no signed zero).
- [x] `getF64Exact(self)` — DONE 2026-05-14. Errors NotRepresentable / NonTerminating rather than silently rounding. Round-trip with setF64 verified across 12 sample values.
- [x] `getF64(self, mode: RoundMode)` — DONE 2026-05-04 EST. Rounds >53-bit mantissas via roundToScale at chosen mode; carry-up renormalization handled. mode == .exact_or_error short-circuits to getF64Exact. Decimal-with-no-terminating-binary still errors NonTerminating (caller chose decimal). 8 inline tests.
- [x] **KILLSHOT TEST**: setF64(0.1) → toDecimal → "0.1000000000000000055511151231257827021181583404541015625" ✅

### M14-9 — C FFI surface
- [x] DONE 2026-05-14. 26 export fns covering all of M14-1 through M14-8 (lifecycle, construction, queries, canonicalize, cmp/eq, add/sub/mul, divExact/Precision, toBinary/Decimal, roundToScale/Mp, toStringCanonical, getF64Exact). 4 new c_smoke test functions exercise the FFI end-to-end.
- [x] DONE 2026-05-04 EST. 3 additional exports for M14-7b/c + M14-8 polish: `blip_mp_fp_to_string_fixed`, `blip_mp_fp_to_string_scientific`, `blip_mp_fp_get_f64`. 3 new c_smoke test fns covering each.

### M14-10 — GMP comparison
- [x] **mpq_t cross-validation** (2026-05-14): 1000 GMP `mpq` cross-checks pass in `tests/integration/cross_check.zig`.
- [ ] **mpf_t cross-validation** still pending if anyone needs binary-base mpf comparison.

### Test queueing convention
Every M14-N item lands as: (a) failing test added that exercises the API as the spec demands, (b) `error.SkipZigTest` placeholder while not yet implemented (test is in the suite as a known-skipped TODO), (c) implementation lands, (d) skip removed, (e) test passes. This keeps the suite green per project policy while making the queued behaviors visible in the test run.

## Milestone 13 — Tier B GMP feature parity (number theory + crypto)

- [x] **M13-B1 — Miller-Rabin primality** (2026-05-04): `Mp.isProbablyPrime(rng, witnesses)` + `Mp.nextPrime(out, n)`. Deterministic small-prime sieve + Miller-Rabin via `powm`. In `src/primes.zig`.
- [x] **M13-B2 — Integer square root + nth root** (2026-05-04): `Mp.isqrt`, `Mp.isqrtRem`, `Mp.iroot`, `Mp.isPerfectSquare`. Newton iteration. In `src/roots.zig`.
- [x] **M13-B3 — Jacobi / Legendre / Kronecker symbols** (2026-05-04): `Mp.jacobi`, `Mp.legendre`, `Mp.kronecker`. Standard reciprocity-based recursion.
- [x] **M13-B4 — Combinatorial** (2026-05-04): `Mp.factorial`, `Mp.binomial`, `Mp.fibonacci` (fast-doubling). In `src/combinatorial.zig`.

## Milestone 15 — Complete the storage-paradigm victory (fully limbless)

**Goal:** Eliminate ALL `[]u64` fixed-width-limb-array storage from blip_mp, including the FFT NTT path. Today blip_mp's add/sub/mul/sqr/mulU64/toString/etc. all operate **byte-direct** — payload bytes are read on demand into transient u64 register values (`readInt(u64, payload[i*8..][0..8], .little)`). Those u64s live in CPU registers for the duration of one inner-loop iteration, then evaporate. They are **values**, not stored limbs.

**Two remaining exceptions** to retire:
1. `tier3DivModSignedLarge` (`tier3.zig:2241`) packs the BLIP payload into a heap-allocated `[]u64` u_lim/v_lim limb array via `payloadToMagLimbs`, runs Knuth Algorithm D on it, then unpacks back to bytes via `writeMagLimbsAsTwosComp`.
2. The FFT NTT path (`fft.zig`) stores NTT residues in `[]u64` arrays (`fft_scratch.pa`/`pb`/`tw_fwd`/`tw_inv`/`stockham`).

**Important nuance** (clarified 2026-05-16 per Peter): the FFT's `[]u64` storage is a *representational choice*, NOT a mathematical requirement. What IS mathematically required is **u64-wide modular arithmetic** for the NTT ring operations (multiply two residues → u128 product → reduce mod p → u64 residue). The STORAGE for those residues can be a byte buffer with chunked u64 reads/writes (`readChunkOrZero` / `writeChunkTruncated`) just as easily as a `[]u64` array — both compile to the same machine code in ReleaseFast since chunked reads at 8-byte-aligned offsets are a single LDR. The only thing that changes is the buffer's type signature.

So fully-limbless is achievable, and the architectural claim becomes the cleaner:

> **blip_mp stores ALL values — including FFT NTT intermediates — as byte buffers. Arithmetic always operates via chunked u64 register reads/writes. There is no `[]u64` storage type in the library. Fixed-width modular arithmetic is a property of the *operations*, not of the *storage*.**

**Research already done** (2026-05-16 session): byte-direct Knuth D is feasible. No published variant exists in the literature (GMP, BearSSL, Java BigInteger, num-bigint, Zig std `math.big` all use uniform-limb storage) — but the math allows it. The inner-loop u64 arithmetic stays unchanged (preserves the 36× speedup over the byte-base divMod that was retired in M51); only the marshalling shim disappears. Estimated win: ~5-15% on divMod at 2K-8K bit (the size where marshalling overhead is meaningful), no regression elsewhere. Sub-task ordering matters — do B-Z first because it's the bigger general-purpose win AND it can be designed byte-direct from day one. FFT migration is mostly mechanical (last to land, after divMod is done).

### M15-1 — Burnikel-Ziegler recursive division (byte-direct) — DONE 2026-05-16
- [x] **Step 1**: byte-direct `shiftLeftByBitsMag` / `shiftRightByBitsMag` helpers (for B-Z normalization).
- [x] **Step 2**: `bzDiv2nByN` + `bzDiv3n_2n` scaffolding (Knuth stub for inner recursion).
- [x] **Step 3**: real recursive `bzDiv3n_2n` (Algorithm 3 from B-Z 1998). Bug found via TDD bisection: slice-bounds `r_work[mag_len..rp_len]` when `mag_len > rp_len` is UB in ReleaseFast.
- [x] **Step 4**: top-level wrapper. Normalize divisor (shift so top bit set), pad dividend to multiple of n_block, iterate blocks top-to-bottom via `bzDiv2nByN` with carried remainder. Odd-n Knuth fallback added (the recursive case requires even n to split halves cleanly).
- [x] **Step 5+6**: wired into `tier3DivModOp` (`src/bignum.zig`) via `tier3DivModOpBZ` helper. Routes to B-Z when `b_pay.len >= BZ_INTEGRATION_THRESHOLD` (currently 512 bytes = 4K-bit divisor). Below threshold, the existing limb-Knuth path (with Möller-Granlund) wins on constant factor. Canonical-zero convention aligned with Knuth (`q_len = 0` = zero quotient, not `q_len = 1` with `q[0] = 0`).
- [x] **Tests:** 1400+ random magnitude-divider trials at n ∈ {2, 4, 8, 16, 32, 64, 128} bytes, plus 120 large-asymmetric trials at v_len ∈ {64, 100, 128, 256, 510, 512}, plus 90 same-length stress trials, plus the existing 12000+ GMP cross-validation suite covering divq/divr at 4K/6K/8K-bit. All pass.
- [x] **Reference:** Burnikel-Ziegler 1998 "Fast Recursive Division" (MPI tech report).
- [ ] **Threshold tuning** — `BZ_INTEGRATION_THRESHOLD` set conservatively at 512 bytes (4K-bit). Bench-tuning to find the true crossover point with limb-Knuth is a follow-up.

### M15-2 — Byte-direct Knuth Algorithm D (the small-divisor base case)
- [x] **Step 1** (2026-05-17): `tier3.divModKnuthU64Bytes` API + delegation. New byte-direct entry that takes `[]u8` payload buffers (caller's u must be 8-byte-aligned with +8 slack for D1 carry). Currently delegates internally to `divModKnuthU64`: bytes ARE the limb storage at 8-byte-aligned offsets, so the cast to `[]u64` is free. Allocates v/q/r aligned scratch and memcpys bytes in (replaces the per-byte `readInt` of `payloadToMagLimbs`). 180-trial cross-check vs `divModKnuth` oracle passing.
- [ ] **Step 2** — Wire `divModSignedLarge` to use `divModKnuthU64Bytes` instead of the manual `payloadToMagLimbs` + `divModKnuthU64` + `writeMagLimbsAsTwosComp` chain. Requires propagating an allocator through `divModSigned` (currently takes a flat `work: []u8`). Cascades to `tier3DivModOp`. Modest perf win since the existing limb path is already optimized; main benefit is unifying on the byte-direct API.
- [ ] **Step 3** — Refactor `divModKnuthU64`'s body byte-direct (~400 lines mirroring the Knuth D inner loop with `readChunkOrZero` / `writeChunkTruncated` instead of `u_lim[i]`). After this, `[]u64` storage is eliminated from the divider entirely. Per PLAN expected gain: ~5-15% at 2K-8K bit (eliminating the pack/unpack round-trip). Substantial commit; could be split into "D1 normalize byte-direct" / "D2-D7 main loop byte-direct" / "D8 denormalize" sub-commits.
- [ ] **Critical tricky bit — D1 normalize.** The shift amount `s = clz(top_u64)` must be computed from the *unpadded* top u64 view (back out the partial-chunk zero-fill: `s_real = clz(top_chunk_u64) - (8 - top_partial_bytes) * 8`). Then apply that bit-shift across the whole byte payload, crossing both byte AND chunk boundaries. Test ladder for partial-chunk widths 1..7.
- [ ] **D4 multiply-subtract** stays per-u64-chunk because qhat × vn_chunk wants widening u128 mul; carries propagate at u64-chunk boundaries, not byte boundaries.
- [ ] **D5 add-back** mirrors D4 in chunked form.
- [ ] **D7 denormalize** is the inverse of D1 — same byte-boundary-crossing right-shift logic.
- [ ] **Verification strategy:** keep the existing `divModKnuthU64` as `divModKnuthLimbsLegacy`, run both in parallel under a debug feature flag for 10K+ cross-check iterations covering every partial-chunk width × every sign combo × every normalization shift amount. Assert bit-identical output. Drop the legacy after a green run.
- [ ] **Expected impact:** ~5-15% on divMod at 2K-8K bit (eliminates `payloadToMagLimbs` + `writeMagLimbsAsTwosComp` allocation + memcpy on the hot path). Larger relative win at smaller sizes.

### M15-3 — Migrate FFT NTT storage from `[]u64` to byte buffers
- [ ] Convert `FftScratch.pa`, `pb`, `tw_fwd`, `tw_inv`, `stockham` from `[]u64` to `[]u8` (sized as `N * 8` bytes each, 8-aligned via aligned allocator). Each "residue slot" is an 8-byte chunk holding a u64 modular value (typically 30-bit for the standard NTT-friendly prime).
- [ ] Replace all `pa[i]` / `pb[i]` etc. indexing with `readInt(u64, pa[i*8..][0..8], .little)` and `writeInt(u64, pa[i*8..][0..8], val, .little)`. Or wrap in a thin inline helper `residue(buf, i)` / `setResidue(buf, i, val)`.
- [ ] Verify NTT correctness with the existing FFT mul test suite (8240+ cross-validation tests pass at sizes up to 256K-bit). Bit-identical output required.
- [ ] Verify no perf regression — the chunked-u64 reads at 8-aligned offsets compile to single LDR/STR (verify by inspecting LLVM IR or objdump). If a regression appears at the FFT inner loop, fall back to a typed-view approach (`@ptrCast` the `[]u8` buffer to `[*]u64` at function entry, then index normally — semantically equivalent, type-safer locally, still backed by byte storage).
- [ ] **Expected impact:** zero perf delta (same machine code), but **the `[]u64` storage type is now eliminated from blip_mp entirely**. The architectural claim becomes fully honest.
- [ ] **Note:** the FFT_THRESHOLD is still 99999 (FFT path gated off in production) for unrelated perf reasons (M6-4-E ladder). M15-3 makes the storage migration anyway so when FFT does get enabled, the storage is already byte-native.

### M15-4 — Storage-paradigm completeness audit + docs
- [ ] Grep audit: `rg '\[\]u64' src/` should return ZERO hits for storage allocations (all of: tier3.zig, bignum.zig, fft.zig, string_io.zig, sign.zig, encoding.zig). Acceptable remaining hits: (a) test code; (b) inline-loop locals (`var carry: u64 = 0;` etc. — those are values, not arrays); (c) function-parameter views like `(buf: []u8) ... readInt(u64, buf[...], ...)` (those are byte buffers being viewed as u64, not u64 arrays).
- [ ] Update `RESULTS.md` "Architecture" section to claim **fully limbless** with the audit as evidence.
- [ ] Update `README.md` "Architecture in one paragraph" to drop the implicit-limb language and replace with the clean claim: "No `[]u64` storage anywhere — even FFT NTT intermediates live in byte buffers. Fixed-width modular arithmetic is a property of the *operations*, not of the *storage*."
- [ ] Update `CODE_MINIMAP.md` for `tier3DivModSignedLarge` (no longer packs to limbs) and `FftScratch` (now byte-backed).
- [ ] Consider an explicit `IsBlipMpLimbless()` compile-time test that statically asserts no `[]u64` field types exist in any struct in `src/` (or similar machine-checkable invariant).

### Sequencing
M15-1 (B-Z) lands first — biggest general-purpose win, designed byte-direct from the start. M15-2 (byte-direct Knuth D) completes divMod's byte-direct picture. M15-3 (FFT storage migration) is mostly mechanical and last — should be a small, contained PR. M15-4 (audit + docs) lands when all three are green.

### Out of scope for M15
- **Newton-Raphson reciprocal** for repeated-divisor contexts (powm's Montgomery loop). Possible future work if a workload demands it. The research-agent's analysis was: NR is wrong for pi spigot (divisor changes every iter), but right for any constant-modulus-many-divisions workload. Park as a future milestone if/when one materializes.
- **Barrett reduction.** Montgomery is already 21% faster than GMP at 1024-bit powm; Barrett wouldn't add anything for that workload.

### Terminology note (added 2026-05-16 per Peter)
Going forward, **"limb"** is used ONLY for genuinely stored fixed-width `[]u64` array elements. After M15 lands, no such storage exists in blip_mp at all — "limb" becomes a word we use exclusively to describe GMP's representation, never our own. **"u64 chunk"** or **"u64 view"** is the correct term for blip_mp's byte-direct register-resident reads. A u64 that lives in a CPU register for one inner-loop iteration is a *value*, not a limb. The distinction matters: it's what lets us claim **storage-paradigm independence** — bytes are the value, all the way through, including in the frequency domain.

## Milestone 16 — `bp` CLI: Forth-style RPN exact-arithmetic calculator (DONE 2026-05-15/16)

- [x] **M16-1** — RPN exact-arithmetic CLI dogfooding the C FFI (2026-05-15, commit `cb52f64`). Stack-based; consumes `Mp` values via the public C surface; first end-user surface that exercises the FFI as designed.
- [x] **M16-2** — Forth-style `:` user-word definitions (threaded code) (2026-05-15, commit `9460f6b`).
- [x] **M16-3** — argv whitespace tokenization (UX fix: no more escaping) (2026-05-15, commit `7d89200`).
- [x] **M16-4** — Three input forms + heredoc + redefinition demo (2026-05-15, commit `333e395`).
- [x] **M16-5** — Linux portability: `_POSIX_C_SOURCE` for `strdup()` (2026-05-16, commit `27ff5b7`).

The `bp` tool serves the architectural mandate (CLI dogfoods the C FFI, not direct Zig import). It's a Forth-style stack calculator that lets users do exact arbitrary-precision arithmetic from the shell.

## GMP-parity striving (2026-05-17 session findings)

User goal: match or beat GMP at all sizes. Honest current state on M4 aarch64
(bench variance is high — 17-60% run-to-run under thermal load — so all numbers
±30%):

| Op | blip strength | blip gap to GMP |
|----|---------------|-----------------|
| mul | **WINS 1.08-1.63× across 128-bit through 8K-bit** | loses 1.35-1.70× at 16K+ (GMP uses FFT) |
| powm | **WINS 7-12% at RSA-2048/3072** | tied at 1024-bit, 4.8% behind at 512-bit |
| divMod | competitive at 256-bit | 1.30-1.42× behind at 1K-8K (inner-kernel gap); 1.65-2.55× at 16K-64K (GMP uses Mu-Division/BZ) |
| invMod | — | **2.7-3.6× behind across all tested sizes** (256-bit through 2048-bit) |

### Optimization attempts this session

**Shipped (perf-neutral correctness improvements):**
- `divModKnuthU64`: alias `v→vn` when s=0 (skip normalization memcpy). 1-4% measured but within noise.
- B-Z thread-local arena (`tier3.bzArena`). Cuts B-Z's per-call malloc cost ~43% but B-Z still 15× slower than limb-Knuth at common sizes; scaffold for future.

**Reverted (failed micro-optimizations):**
- mul-sub unroll-by-2: regresses 17-25% at sizes ≥ 2K-bit (register pressure / dependency chain serialization).
- `noalias` annotations: regresses ~2× across all sizes (Zig's noalias has different semantics than C restrict here).
- GMP-style single-`cl` carry-borrow chain: regresses 14-35% at sizes ≥ 1K-bit (LLVM gives more ILP slack with two separate chains).
- Raised classical-EEA threshold for invMod from 96 to 256 bits: classical is 5× slower than Lehmer at 256-bit; original dispatch was correct.

### Identified-but-deferred levers

1. **Hand-asm aarch64 inner loops** (mpn_submul_1 equivalent). Would close the 1.3-1.4× mid-size divMod gap. Substantial fragile work; high risk of regression on x86_64.
2. **Stein's binary GCD with Bezout tracking** for small invMod. Would close the 2.7-3.6× invMod gap at 256-2048 bits. Substantial new algorithm.
3. **FFT mul activation** (continuing M6-4-E.3 NEON inline asm). Would close the 1.65-2.55× large-size divMod gap by making B-Z viable in production.
4. **Specialized 2-limb divisor divider** (mpn_divrem_2 equivalent). Modest gain at 256-bit divMod.
5. **Statistical bench harness** (hyperfine wrapper or N-run aggregation). **Critical prerequisite** for further work: current single-run bench variance (17-60%) under thermal load makes 1-10% optimization gains unmeasurable.

## Open follow-ups (ranked)

- [ ] **M6-4-E.3** — hand-scheduled aarch64 inline asm for the FFT butterfly inner loop. Would close the residual 13-15% FFT-vs-Toom-3 gap on M-series and finally enable FFT_THRESHOLD < 99999 in production. **Status update (2026-05-04):** x86_64 picture has now landed (see x86_64 task below). On x86_64-linux Zen 4, GMP-asm advantage over GMP-noasm is 1.65–3.88× — the equivalent x86_64 hand-asm investment is large but its target is well-defined. The M-series-specific NEON inline-asm work for FFT butterflies is now justified on its own merits (closes a real ~13-15% gap that nothing else will), with no need to wait further. Fragile but isolated to one inner loop.
- [x] **x86_64 cross-platform validation (Linux)** — DONE 2026-05-04 EST. Set up via `ssh framework-nixos` (NixOS x86_64 Framework laptop, AMD Ryzen 9 7940HS Zen 4, AVX-512+AVX2+BMI/ADX). Two real x86_64-linux build issues found and fixed: `build.zig` needed explicit `link_libc=true` for unit tests (macOS auto-links libSystem; Linux doesn't); `flake.nix` `gmp-noasm` needed `--enable-fat` filtered (incompatible with `--disable-assembly` on x86_64). All 213 unit tests + 12029 GMP cross-validations + C FFI smoke pass. **Headline finding (opposite of M5-5 on aarch64): GMP-asm IS load-bearing on x86_64**, giving 1.17–3.98× over GMP-noasm. **vs GMP-noasm-x86_64**: blip-pure-Zig wins at 22+ size/op pairs (storage paradigm wins again). **vs GMP-asm-x86_64**: blip wins all tier-0/1; loses tier-3 by 1.5–4× (= the GMP-asm advantage). Detailed numbers in BENCHMARK_RESULTS.md Run 18 + RESULTS.md "Cross-platform validation" section. Windows still pending.
- [x] **Windows cross-platform validation** — DEFERRED to Garnix CI matrix (2026-05-04). Per Peter: Garnix matrix covers Windows x86_64 + aarch64 builds; no perf-on-real-Windows-host pass needed yet — there's no real CLI to exercise on Windows beyond the static lib + tests, and Garnix already covers that. Revisit if/when we ship an end-user CLI tool.
- [ ] **Statistical bench harness** — `hyperfine` integration + N-run aggregation; current numbers are 3-5-run hand medians.
- [ ] **Lehmer-style q_hat refinement in divModKnuthU64** — closes the ~180 ns inner-kernel gap to GMP's `mpn_tdiv_qr` (~290 ns vs our ~470 ns at 2K-bit). Would push full Mp.divMod from 1.51× lose to ~1.05× tie at 2048-bit.
- [ ] **BLIP wire interop**: a separate "unsigned BLIP" mode for round-tripping with strict-spec BLIP producers.
