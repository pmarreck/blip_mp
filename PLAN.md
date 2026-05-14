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
- [ ] **M6-4-E.3** Hand-scheduled aarch64 inline asm for the butterfly inner loop — schedules mul/umulh on scalar pipes WHILE NEON handles add/sub/load/store. Architecturally what M4 wants, fragile (M-series-specific). ~9-10K ns gap remaining; this is the last lever.
- [ ] **M6-4-E.4** OR accept Toom-3 as production winner in supported range. FFT primitives essential when extending past Toom-3's natural crossover (~512K-bit+).

## Milestone 7 — Division, modulo, and modular exponentiation

The big missing arithmetic feature. Required for serious crypto applications (RSA, DH, ECC scalar operations). Same correctness-first discipline: every result bit-identical to GMP's `mpz_tdiv_qr` / `mpz_mod` / `mpz_powm`, validated via cross-check.

**Goal:** ship `Mp.div` (truncated), `Mp.mod`, `Mp.divMod`, `Mp.powm` with at least competitive performance vs GMP across the typical operand range. Same byte-direct paradigm as add/sub/mul — read u64/u128 chunks from BLIP payload bytes, write canonical bytes back.

### M7-1 — Tier 0/1 division (i64 fast path)

- [ ] **M7-1.1** `Mp.divMod_i64` using native `@divTrunc` + `@mod`. Dispatch from `Mp.div`/`Mp.mod` when both operands fit in i64 (which is most accumulator workloads). Test: round-trip vs Zig builtins; sign convention matches GMP's `mpz_tdiv_qr` (truncated, quotient sign = sign(a)*sign(b), remainder sign = sign(a)).
- [ ] **M7-1.2** Wire into Mp.div / Mp.mod with tier-3 promotion stub (returns `error.NotImplemented` for now). Cross-check `Mp.divMod` vs GMP for 100+ random i64 pairs.

### M7-2 — Tier 3 division by single byte (the foundation)

The classic schoolbook long division reduces to "divide a multi-byte number by a single byte (or single u64) and capture the remainder." Every higher-level division algorithm uses this as its inner loop. Hensel division (already used in `divExactBy3`/`divExactBy5`) handles the EXACT case; we need TRUNCATED division for the general case.

- [ ] **M7-2.1** `divModSingleByte(a: []u8, b: u8) -> { quotient: []u8 (in place), remainder: u8 }`. Schoolbook: `r = 0; for i from high to low: r = r*256 + a[i]; q[i] = r/b; r = r%b`. Test: 100K random (multi-byte dividend × single-byte divisor) pairs vs GMP `mpz_tdiv_qr_ui`.
- [ ] **M7-2.2** Chunked u64 form `divModSingleU64(a: []u8, b: u64) -> u64 remainder` — read 8 bytes at a time. Test: equivalence to byte-at-a-time.
- [ ] **M7-2.3** Bench. This is the inner loop everything else uses; it must be fast.

### M7-3 — Tier 3 long division (Knuth Algorithm D)

The general dividend / divisor case where divisor is multi-byte. Knuth Algorithm D in TAOCP volume 2 §4.3.1 is the standard reference (essentially: normalize the divisor so its high byte ≥ 128, do schoolbook quotient digit estimation per quotient byte using top-byte-pair / top-byte, correct off-by-one with multi-byte multiply-and-subtract).

- [ ] **M7-3.1** `divModKnuth(dividend: []u8, divisor: []u8, q: []u8, r: []u8) -> { q_len, r_len }`. Test: cross-check against GMP `mpz_tdiv_qr` for 1K random pairs across {64, 128, 256, 512, 1024, 2048, 4096} bit dividends and {32, 64, 128, 256, 512} bit divisors.
- [ ] **M7-3.2** Sign handling — `mpz_tdiv_qr` truncated semantics. Both inputs may be negative. Quotient sign = sign(a) XOR sign(b); remainder sign = sign(a). Test: 8 sign combinations × random sizes.
- [ ] **M7-3.3** Wire into `Mp.div` / `Mp.mod` / `Mp.divMod` for tier-3 operands. Add to `tests/integration/cross_check.zig` so the 8240-check suite picks up div/mod.

### M7-4 — Modular exponentiation `Mp.powm(base, exp, mod) = base^exp mod mod`

The single most-used bignum operation in real crypto (RSA encrypt/decrypt/sign/verify, DH key exchange, EC scalar multiplication via doubling). Square-and-multiply is the basic algorithm; sliding-window and/or Montgomery's ladder are the standard optimizations.

- [ ] **M7-4.1** Square-and-multiply `Mp.powm` using `Mp.mul` + `Mp.mod` from M7-3. Constant-time variant NOT required for this milestone (we're a numerical library, not a crypto primitive — leave the constant-time variant for a later "secure-mode" pass). Test: cross-check vs GMP `mpz_powm` for 100 random RSA-style triples (base 2048-bit, exp 2048-bit, mod 2048-bit; verify result matches).
- [ ] **M7-4.2** Sliding-window optimization (window size 4-6) — precomputes a small table of `base^k` for k in {1, 3, 5, ..., 2^w - 1}, scans the exponent in w-bit chunks. Reduces multiplication count by ~25-40%. Test: equivalence to square-and-multiply.
- [ ] **M7-4.3** Montgomery-form `powm` — reuse the `montMul` infrastructure from M6-4-B. Each multiplication + mod becomes one Montgomery multiplication. Massive win at 1024+ bit. Test: equivalence to non-Mont version.
- [ ] **M7-4.4** Bench. Compare to `mpz_powm` at RSA-1024, RSA-2048, RSA-3072. Target: within 2× of GMP at all sizes (GMP has decades of `mpn_powm` tuning; getting close is real work).

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

- [x] **M11.1 — Standalone HGCD primitive (NOT wired into invMod)** (2026-05-02 EST) — Shipped `Mp.HGCDMatrix` (multi-precision 2x2 with parity-tracked sign convention) + `Mp.hgcd(out_M, a, b, target_bits, allocator)` iterative Lehmer-style primitive that accumulates the reduction matrix via `composeOuter`. Bit-for-bit oracle test (HGCD-applied-to-(a,b) == classical-EEA-stepped-to-half-bit-threshold) passes across {64,128,256,512,1024,2048}-bit random pairs (12 iters/size). Plus identity + one-step EEA structural tests. Did NOT touch `Mp.invMod` (deferred to M11.2). Notable derivation finding: matrix composition formulas are identical across all four parity-of-self × parity-of-outer cases — only the parity bit flips.
- [ ] **M11.1.2 — True recursive HGCD with O(M(n) log n)** — Build the divide-and-conquer recursion on top of M11.1's matrix machinery (recurse on top half-bits, compose with EEA correction step, recurse on top quarter-bits, compose). The iterative scaffold + composeOuter make this an additive change rather than a rewrite. Substantial: matrix-by-matrix products at the n-bit level themselves cost O(M(n)) so recursion depth and base-case threshold need careful tuning.
- [ ] **M11.2 — Integration into Mp.invMod** — Apply the HGCD-produced matrix to `(s0, s1)` Bezout coefficients alongside `(r0, r1)`. Expected gain: 2-4× over M10 wider-window Lehmer at 2048-bit; combined with M10 ~5-10× over M9. Would close residual gap to GMP at RSA-2048 (currently 3.23×). **Status (2026-05-04)**: code shipped (`Mp.invModHGCDRecursive` exists at `src/bignum.zig:1538`) but PROD-disabled — recursive HGCD wins require sub-quadratic matrix-product cost, which in turn requires FFT mul to beat Toom-3 in production. **Blocked on M6-4-E.3** (FFT butterfly hand-asm closes the 13-15% gap that currently keeps FFT_THRESHOLD = 99999). Once M6-4-E.3 lands and FFT becomes viable in production, route `Mp.invMod` to `invModHGCDRecursive` for tier-3 sizes ≥ ~512-bit. Three-way oracle (Lehmer / wider-window / recursive) test already passing in `tests/integration/cross_check.zig`.
- [ ] **Original framing (kept for context)** — true sub-quadratic O(M(n) log n) divide-and-conquer reformulation. References: Yap §2.6, GMP `mpn/generic/hgcd*.c`, TAOCP §4.5.3 problem 35. Lehmer remains the recursion base.

## Milestone 12 — Tier A GMP feature parity (surface, not perf)

**Goal:** cover the GMP `mpz_*` operations real consumers reach for that we currently lack. Perf is secondary; correctness via GMP cross-checks is mandatory for every op. Strict TDD: failing test first, watch it fail, minimal impl, rerun, refactor.

Each item: (a) Mp method in `src/bignum.zig`, (b) C FFI `export fn` + header decl in `src/c_api.zig` + `include/blip_mp.h`, (c) unit tests in `tests/unit/<feature>_test.zig`, (d) GMP cross-validation in `tests/integration/cross_check.zig` if applicable.

- [ ] **M12-A1 — Bitwise**: `Mp.bitwiseAnd / bitwiseOr / bitwiseXor / bitwiseNot / shl(n) / shr(n)`. GMP semantics: two's-complement on negatives (`mpz_and`, `mpz_ior`, `mpz_xor`, `mpz_com`, `mpz_mul_2exp`, `mpz_fdiv_q_2exp`). Pure-byte loops. Tests cover both signs, sign extension across length, zero operands, shifts past total bit length.
- [ ] **M12-A2 — Sign / abs / fits**: `Mp.neg`, `Mp.abs`, `Mp.fitsI64`, `Mp.fitsU64`, `Mp.fitsI32`, `Mp.fitsU32`. Trivial wrappers; test boundary values exhaustively.
- [ ] **M12-A3 — String I/O hex+decimal**: `Mp.setStr(slice, base)` + `Mp.toString(allocator, base)` for bases 2, 8, 10, 16. Hex/binary/octal: pure bit-manipulation. Decimal: repeated div/mod by chunked u64 powers of 10 (use existing Knuth divMod). Tests: round-trip across {tier-0/1, 256-bit, 1024-bit, 2048-bit, 4096-bit} for each base; negative numbers; leading-zero / all-zero / single-digit edge cases. Decimal output round-trip vs `std.fmt`.
- [ ] **M12-A4 — GCD / LCM**: `Mp.gcd(a, b)` + `Mp.lcm(a, b)`. Initial impl via existing classical EEA scaffold (factor out from `invModClassical`). LCM via `|a*b| / gcd(a,b)`. Tests: known pairs, coprime pairs, one-zero edge, both-zero (gcd(0,0)=0), GMP cross-check across {64, 256, 1024, 2048}-bit pairs.
- [ ] **M12-A5 — Random**: `Mp.setRandomBits(rng, bits)` + `Mp.setRandomBelow(rng, n)` (uniform in [0, n)). Use `std.Random` interface (caller provides). Cross-check via `mpz_urandomb`/`mpz_urandomm` semantics (modulo deterministic with seeded RNG comparison is pointless; instead test distribution properties: bitLen ≤ bits, < n, never produces n itself, hits all bit positions).
- [ ] **M12-A6 — Misc small**: `Mp.popcount` (Hamming weight; for negatives, count of 0-bits in two's-complement infinite extension is `mpz_popcount` semantics — return `usize.max` per GMP), `Mp.scan0(start)` / `Mp.scan1(start)` (find first 0-bit / 1-bit at or after position).

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
- [ ] `toStringFixed(allocator, a, frac_digits)` — pad/truncate fractional part to fixed width (deferred — canonical covers the demo headline)
- [ ] `toStringScientific(allocator, a)` — "1.234e-5" form (deferred)

### M14-8 — IEEE754 interop
- [x] `setF64(self, v)` — DONE 2026-05-13. NaN/±∞ → NotRepresentable; ±0 → zero (no signed zero).
- [x] `getF64Exact(self)` — DONE 2026-05-14. Errors NotRepresentable / NonTerminating rather than silently rounding. Round-trip with setF64 verified across 12 sample values.
- [ ] `getF64(self, mode: RoundMode)` — accepts a rounding mode for inexact cases (deferred — caller can compose roundToScale + getF64Exact for now)
- [x] **KILLSHOT TEST**: setF64(0.1) → toDecimal → "0.1000000000000000055511151231257827021181583404541015625" ✅

### M14-9 — C FFI surface
- [x] DONE 2026-05-14. 26 export fns covering all of M14-1 through M14-8 (lifecycle, construction, queries, canonicalize, cmp/eq, add/sub/mul, divExact/Precision, toBinary/Decimal, roundToScale/Mp, toStringCanonical, getF64Exact). 4 new c_smoke test functions exercise the FFI end-to-end.

### M14-10 — GMP comparison (still pending)
- [ ] mpf_t / mpq_t cross-validation in `tests/integration/cross_check.zig`. Substantial setup — needs gmp_bench.c extension to build mpq_class / mpf_class fixtures and call them via the cross-check binary. Defer until after the deferred M14-7/8 items.

### Test queueing convention
Every M14-N item lands as: (a) failing test added that exercises the API as the spec demands, (b) `error.SkipZigTest` placeholder while not yet implemented (test is in the suite as a known-skipped TODO), (c) implementation lands, (d) skip removed, (e) test passes. This keeps the suite green per project policy while making the queued behaviors visible in the test run.

## Milestone 13 — Tier B GMP feature parity (number theory + crypto)

- [ ] **M13-B1 — Miller-Rabin primality**: `Mp.isProbablyPrime(rng, witnesses)` + `Mp.nextPrime(out, n)`. Deterministic small-prime sieve trial-div first, then Miller-Rabin with caller-supplied witness count. Built on existing `powm`. Tests: known primes (2, 3, 5, 7, …, 2^521-1 Mersenne), known composites (Carmichael 561, 1729, 2465), cross-check 1000 random {32, 64, 256, 512}-bit cases vs `mpz_probab_prime_p`.
- [ ] **M13-B2 — Integer square root + nth root**: `Mp.isqrt(out, n)` (floor(sqrt(n))) + `Mp.iroot(out, n, k)` (floor(n^(1/k))) + `Mp.isPerfectSquare(n)` + `Mp.isqrtRem(out_root, out_rem, n)`. Newton iteration; halt when iterates stop decreasing. Tests: perfect squares 0..1024 + spot-check large; near-misses (n²-1, n²+1); GMP cross-check for `mpz_sqrt`/`mpz_root`.
- [ ] **M13-B3 — Jacobi / Legendre / Kronecker symbols**: `Mp.jacobi(a, n)` (n odd positive), `Mp.legendre` (n odd prime; alias to jacobi but doc-distinct), `Mp.kronecker(a, n)` (extends to all n via Kronecker rules). Standard reciprocity-based recursion with bit-tricks for the (2/n) case. Tests: known values (Jacobi(2/15)=1, (3/15)=0, etc.), cross-check vs `mpz_jacobi`/`mpz_kronecker` on 500 random pairs.
- [ ] **M13-B4 — Combinatorial**: `Mp.factorial(out, n)` (n: u32), `Mp.binomial(out, n, k)` (n: u32, k: u32), `Mp.fibonacci(out, n)` (n: u32, fast-doubling identity). Mostly throughput-bound on existing `mul`. Tests: small known values 0..20!, binomial(50, 25) = 126410606437752, fib(100), GMP cross-check at fac(1000), fib(10000).

## Open follow-ups (ranked)

- [ ] **M6-4-E.3** — hand-scheduled aarch64 inline asm for the FFT butterfly inner loop. Would close the residual 13-15% FFT-vs-Toom-3 gap on M-series and finally enable FFT_THRESHOLD < 99999 in production. **Status update (2026-05-04):** x86_64 picture has now landed (see x86_64 task below). On x86_64-linux Zen 4, GMP-asm advantage over GMP-noasm is 1.65–3.88× — the equivalent x86_64 hand-asm investment is large but its target is well-defined. The M-series-specific NEON inline-asm work for FFT butterflies is now justified on its own merits (closes a real ~13-15% gap that nothing else will), with no need to wait further. Fragile but isolated to one inner loop.
- [x] **x86_64 cross-platform validation (Linux)** — DONE 2026-05-04 EST. Set up via `ssh framework-nixos` (NixOS x86_64 Framework laptop, AMD Ryzen 9 7940HS Zen 4, AVX-512+AVX2+BMI/ADX). Two real x86_64-linux build issues found and fixed: `build.zig` needed explicit `link_libc=true` for unit tests (macOS auto-links libSystem; Linux doesn't); `flake.nix` `gmp-noasm` needed `--enable-fat` filtered (incompatible with `--disable-assembly` on x86_64). All 213 unit tests + 12029 GMP cross-validations + C FFI smoke pass. **Headline finding (opposite of M5-5 on aarch64): GMP-asm IS load-bearing on x86_64**, giving 1.17–3.98× over GMP-noasm. **vs GMP-noasm-x86_64**: blip-pure-Zig wins at 22+ size/op pairs (storage paradigm wins again). **vs GMP-asm-x86_64**: blip wins all tier-0/1; loses tier-3 by 1.5–4× (= the GMP-asm advantage). Detailed numbers in BENCHMARK_RESULTS.md Run 18 + RESULTS.md "Cross-platform validation" section. Windows still pending.
- [x] **Windows cross-platform validation** — DEFERRED to Garnix CI matrix (2026-05-04). Per Peter: Garnix matrix covers Windows x86_64 + aarch64 builds; no perf-on-real-Windows-host pass needed yet — there's no real CLI to exercise on Windows beyond the static lib + tests, and Garnix already covers that. Revisit if/when we ship an end-user CLI tool.
- [ ] **Statistical bench harness** — `hyperfine` integration + N-run aggregation; current numbers are 3-5-run hand medians.
- [ ] **Lehmer-style q_hat refinement in divModKnuthU64** — closes the ~180 ns inner-kernel gap to GMP's `mpn_tdiv_qr` (~290 ns vs our ~470 ns at 2K-bit). Would push full Mp.divMod from 1.51× lose to ~1.05× tie at 2048-bit.
- [ ] **BLIP wire interop**: a separate "unsigned BLIP" mode for round-tripping with strict-spec BLIP producers.
