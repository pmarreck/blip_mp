# CODE_MINIMAP.md — blip_mp

Per-file index of important code locations. Refreshed 2026-05-03 after the M1–M11 work landed.

## Top-level docs / config

- `SPEC.md` — original design spec for BLIP-storage bignum library
- `PROJECT_OVERVIEW.md` — goals, terminology, non-goals, architecture
- `PLAN.md` — milestone checklist and roadmap (M0 through M11)
- `RESULTS.md` — headline benchmark results, M5-5 controlled experiment writeup, win/loss breakdown
- `BENCHMARK_RESULTS.md` — per-run history (Run 1..N) with each milestone's bench
- `README.md` — project landing page (GitHub-facing)
- `CODE_MINIMAP.md` — this file
- `AGENTS.md` / `CLAUDE.md` — agent briefing (symlinks; not committed)
- `ZIG_RECENT_API_CHANGES_2025.md` — Zig 0.14/0.15/0.16 API reference (symlink)
- `flake.nix` — Nix derivation; ships gmp + gmp-noasm for the controlled experiment
- `build.zig`, `build.zig.zon` — Zig build config; defines `default` (lib), `bench` (executables incl. blip_mp_bench, gmp_bench, gmp_noasm_bench, fft_microbench, cross_check), `c-smoke` / `c-smoke-run` (FFI smoke test), `checks.test`
- `./build`, `./test`, `./bm` — top-level Bash drivers (per CLAUDE.md conventions)

## src/ — core library (≈11K lines)

### `src/blip_mp.zig` (16 lines)
Public Zig surface. Re-exports `encoding`, `bignum`, `tier3`, `fft`; aliases `Mp = bignum.Mp`. `refAllDecls` ensures every test in dependent files runs.

### `src/encoding.zig` (289 lines)
BLIP integer encoding restricted to **signed two's-complement** reading (per SPEC.md §Sign convention). One encoder, one decoder; the "where is the sign bit" question is settled by definition (high bit of high payload byte).
- `Endian` enum (little/big payload endianness — BLIP permits per-value E bit; decoder honours both)
- `Error` (BufferTooSmall, UnexpectedEndOfInput, OverlongEncoding)
- `Decoded { value: i64, bytes_read, endian, is_sentinel }`
- `minPayloadBytesSigned(i64)` — picks smallest L whose i(L*8) range contains value; 0 for immediate range
- `encodedSizeI64`, `encodeI64Canonical`, `decodeI64`
- `headerInfoLookup` — 256-entry comptime table: maps a byte's leading bits to (immediate vs length-prefixed, is sentinel, etc.)

### `src/bignum.zig` (4516 lines)
The `Mp` bignum type. **Representation 1a (SBO) + heap reuse + sign-extended inline tail.** 24-byte inline buffer + reuse-aware heap fallback. Tier 0/1 zero-alloc. For length-prefixed inline values, `inline_buf[1..9]` ALWAYS holds the full sign-extended i64 in LE — public `bytes()` returns only the canonical `[0..inline_len]` slice but internal arithmetic reads the i64 in a single u64 load. Struct = 72 bytes (one cache line + 8B).

**Layout**:
- `inline_buf: [24]u8 align(8)`, `inline_len: u8` (sentinel `0xFF` = heap mode)
- `heap_offset: u8` (start offset within heap_buf for direct-write tier3Op)
- `cached_pay_off: u8`, `cached_sign: i8`, `cached_pay_len: u32` — cached metadata avoids per-op header reparse
- `heap_used: usize`, `heap_buf: []u8`, `allocator`

**Public API**:
- `Mp.init(allocator)` / `Mp.deinit()`
- `Mp.bytes()` / `Mp.payload()` / `Mp.cachedSign()` / `Mp.isInline()`
- `Mp.setI64(v)` / `Mp.setU64(v)` / `Mp.setBytes(slice)` / `Mp.getI64()` / `Mp.getU64()`
- `Mp.cmp(other)` — sign-first dispatch + byte-level magnitude comparison; tier-3-aware (no i64 overflow risk)
- `Mp.sign()`
- `Mp.bitAt(idx)` / `Mp.bitLen()` — magnitude bit access; minPow edge case handled
- `Mp.add(r, a, b)` / `Mp.sub(r, a, b)` — tier 0/1 fast path with cross-tier promotion to tier 3 on i64 overflow
- `Mp.mul(r, a, b)` — i128-widening tier-0/1 fast path; tier-3 routes through `tier3MulOp`
- `Mp.divMod(q, r, a, b)` / `Mp.div` / `Mp.mod` — truncated division (GMP `mpz_tdiv_qr` semantics)
- `Mp.powm(r, base, exp, mod)` — modular exponentiation; dispatcher routes to `powmMontgomery` for odd modulus ≥ 64 bits, `powmSlidingWindow` (square-and-multiply with 4-/5-/6-bit window) for ≤ 256-bit OR even modulus, `powmSquareAndMultiply` for tiny exponents
- `Mp.invMod(r, a, m) -> bool` — modular multiplicative inverse via Lehmer-augmented EEA. Returns `true` iff inverse exists. Dispatcher: `invModHGCD` (M10 wider-window u128) for moduli ≥ 256 bits → `invModLehmer` (M9) for 96-256 bits → `invModClassical` for smaller. `euclideanReduce` ensures result in [0, |m|)
- `Mp.HGCDMatrix` (M11.1, standalone — not yet wired into `invMod`) — 2x2 EEA-reduction matrix with multi-precision Mp coefficients `(a, b, c, d)` and a `parity_even` flag tracking the sign convention. Operations: `init/deinit`, `setIdentity`, `applyToPair(r0, r1)` (in-place reduction), `composeOuter(M_outer)` (matrix product `self <- M_outer · self`). All four parity-of-self × parity-of-outer cases yield the SAME composition formulas (only the parity bit flips) — discovered during derivation.
- `Mp.hgcd(out_M, a, b, target_bits, allocator)` (M11.1) — half-GCD primitive. Reduces `(a, b)` until `bitLen(a') ≤ target_bits` (canonical use: `target_bits = bitLen(a) / 2`), outputting the accumulated reduction matrix in `out_M`. Iterative Lehmer-style with multi-precision matrix accumulation via `composeOuter`. Standalone — not in production. Validated as bit-for-bit equivalent to classical EEA reduction stepped to the same target threshold across {64..2048}-bit random pairs.
- `Mp.hgcdRecursive(out_M, a, b, target_bits, allocator)` (M11.2.1) — TRULY recursive HGCD with multi-precision matrix entries. Phase 1: recurse on top n/2 bits, tryApply with rollback on gcd-invariant violation. Phase 2: classical EEA correction step if bitLen drop insufficient. Finish: bottoms out into iterative `hgcd`. Standalone — NOT in production due to architectural mismatch (see invMod docstring): without sub-quadratic mul, recursive HGCD's matrix-composition overhead exceeds Lehmer's; 8192-bit invMod ran 60× slower in trial wiring. Activation-ready building block for if/when FFT mul becomes production-viable. Cross-validated equivalent to iterative `hgcd` across {256..4096}-bit random pairs.
- `Mp.invModHGCDRecursive(r, a, m)` (M11.2.1) — wraps `hgcdRecursive` in EEA Bezout-tracking outer loop. NOT in production (see above). Useful as a 3-way correctness oracle alongside `invModLehmer` and `invModHGCD` (all three impls now bit-equivalent across all tested sizes — independent triangulation for any future regression).
- `setFromShiftedRight(out, src, shift_down)` (M11.2.1) — extracts top bits of a non-negative Mp into another Mp via byte-level shift. Used by recursion to materialise top-half-bits windows. General-purpose bit-window extraction primitive.

**Internal helpers** (incomplete — see file):
- `decodeInlineSmall` (single-LDR i64 read), `ensureHeapCapacity`
- `tier3Op(comptime op: TierOp)` — generic tier-3 add/sub dispatcher
- `smallInlineTier3Add` / `sameSizeTier3Add(comptime N)` — fast paths for inline + size-matched ops; comptime-polymorphic on `op`, serves both `add` and `sub`
- `tier3MulOp` / `smallInlineTier3Mul` / `sameSizeTier3Mul(comptime N)` — fast paths for mul
- `tier3DivModOp` — wraps `tier3.divModSigned` with stack/heap scratch and `writeMpFromPayload`
- `writeMpFromPayload(dst, pay)` — encode canonical signed payload into Mp (inline vs heap routing)
- `topU64(self, shift_down)` / `topU128(self, shift_down)` — top-N-bit window extractors used by invModLehmer / invModHGCD inner loops. Iter-31: fast path via `std.mem.readInt(u64, ...)` for the common in-payload case (single LDR x instead of per-byte build chain). Slow path retained for partial-trailing-bytes near the magnitude top.
- `setU128(self, v)` / `setFromShiftedRight(out, src, shift_down)` — magnitude materialization (HGCD top-window extraction)
- `mpToU64Mag(self)` — Lehmer single-precision bottom-out helper. Iter-32: same readInt fast-path treatment as topU64.
- `lehmerFinishSinglePrecision` — u62 inner loop bottoming out invModHGCD recursion
- `montMul` / `montSquare` / `montReduce` — Montgomery primitives for arbitrary odd modulus, used by powmMontgomery (NOT the FFT-prime Mont — that's separate in fft.zig)
- `Error sets`: `SetError`, `GetError`, `ArithError` (incl. `DivisionByZero`, `NotImplementedTier3`, `NegativeExponentNotSupported`)

### `src/tier3.zig` (4593 lines)
Large-number arithmetic operating directly on BLIP payload bytes — no auxiliary limb-array conversion (Peter's "no limbs" insight). Pure-Zig, no GMP dep.

**BLIP / sign primitives**:
- `Header { L, endian, bytes_consumed }`, `parseHeader`, `writeHeader` (supports L >= 32 with continuation varint)
- `signExtByte(payload)` — 0x00 or 0xFF based on payload's high bit
- `canonicalLen(payload)` — trims redundant high sign-extension bytes
- `payloadOf(blip)`, `negateInPlace(payload)`

**Tier-3 add / sub**:
- `addPayloads(a, b, n, out)` — two's-complement byte-direct add. Cascading inner loop: u512 → u256 → u128 → u64 → per-byte tail. Each chunk size compiles to ADCS sequences on aarch64.
- `subPayloads(a, b, n, out)` — same shape with borrow propagation (chunked u512/u256/u128/u64 — added in iteration 6 to mirror addPayloads which had the optimization since M3)
- `addUnsignedLE(a, a_len, b, b_len, out)` / `subUnsignedLE` — unsigned magnitude variants
- `addUnsignedFixedLen(a, b, out) -> u8` / `addUnsignedInPlace` / `subUnsignedInPlace` — Karatsuba-internal helpers. `addUnsignedFixedLen` chunked u64 in iter 33 (was per-byte) — produced 3 new mul GMP-flips at 4096/6144/8192-bit (16-21% Karatsuba leaf speedup).
- `cmpUnsignedLE(a, a_len, b, b_len) -> i8` — unsigned magnitude compare. Chunked u64 high-to-low (iter 18); LE u64 unsigned-compare correctly orders LE bytes.
- `negateInPlace(payload)` — two's-complement negate. Chunked u64/u128 (iter 17, was per-byte). Mp-side smallInlineTier3Mul + sameSizeTier3Mul delegate to it (iter 30) for negative-result encoding.
- `divExactBy3` / `divExactBy5` — chunked u64 Hensel division (iter 20). Constants 0xAB / 0xCD generalized to 0xAAAA_AAAA_AAAA_AAAB / 0xCCCC_CCCC_CCCC_CCCD (3⁻¹ / 5⁻¹ mod 2^64). Used by Toom-3 interpolation.

**Tier-3 mul**:
- `mulMagnitudes(a, a_len, b, b_len, r)` — schoolbook unsigned multiply
- `mulMagnitudesU64Unaligned(a, a_len, b, b_len, r)` — chunked u64 schoolbook (handles unaligned inputs)
- `mulSmallConst(mag, mag_len, c, out)` — magnitude × u8
- `mulSmallSignedConst(in, mag, c, out)` — sign-magnitude × u8 (M6-2.2 helper)
- `mulKaratsuba(a, b, r, scratch)` — Karatsuba with the carry-bit trick. `KARATSUBA_THRESHOLD = 384` (raised from 256 in iteration 7 to fix the 2048-bit anomaly)
- `mulToom3(a, b, r, scratch)` — Toom-Cook 3-way (Bodrato-Zanoni interpolation). `TOOM3_THRESHOLD = 2048`
- `divExactBy3` / `divExactBy5` — Hensel-style exact division (Toom interp helpers)
- `mulRawBlip(a_blip, b_blip, scratch_a, scratch_b, scratch_r, scratch_k, out, fft_alloc)` — full mul dispatcher

**Tier-3 div**:
- `divModSingleByte(a, a_len, b: u8) -> { q_len, rem: u8 }` — schoolbook inner loop
- `divModSingleU64(a, a_len, b: u64) -> { q_len, rem: u64 }` — chunked u64 form (~14× faster, M7-2)
- `divModKnuth(u, u_len, v, v_len, q, r) -> { q_len, r_len }` — byte-base Knuth Algorithm D (M7-3, kept as future-removal scaffolding; no longer in dispatch path)
- `divModKnuthU64(u, u_len, v, v_len, q, r) -> { q_len, r_len }` — u64-base Knuth D (M7-3.u64; 36× over byte form, beats GMP at 2K-bit kernel)
- `divModSigned(a_pay, b_pay, q_pay, r_pay, work) -> { q_len, r_len }` — sign + BLIP wrapper
- `divModSignedLarge` — multi-byte-divisor fast path skipping byte↔limb intermediates (iteration 12)
- `divModSignedScratchNeed`, `divModKnuthScratchNeed` — scratch sizing helpers

**Tier-3 conversion / Montgomery**:
- `bytesToLimbs(bytes, limbs)` / `limbsToBytes(limbs, bytes)` — byte ↔ u64 array round-trip
- `payloadToMagLimbs(pay, neg, limbs) -> usize` — fused: copy + negate + trim + bytesToLimbs (iteration 12)
- `writeMagLimbsAsTwosComp(limbs, n_limbs, neg, dst) -> usize` — fused: limbsToBytes + negate + sign-ext + trim (iteration 12)
- `negateLimbsInPlace(limbs)` — multi-limb 2's-complement negate (ADC chain)
- `cmpLimbsGE(a, b)` / `subLimbsInPlace(a, b)` — Mont reduction helpers
- `modInvNeg64(m: u64) -> u64` — Newton's method for (-m^-1) mod 2^64
- `montMul` / `computeR2ModM` — arbitrary-odd-modulus Montgomery primitives (used by Mp.powm)

**FFT scratch cache** (M6-4-E.1):
- `FFT_THRESHOLD: usize = 99999` (FFT gated off in production; M6-4-E.3 inline asm needed to flip)
- `FftScratch` thread-local cache + `getFftScratch` / `releaseFftScratch`

### `src/bitwise.zig` (M12-A1)
GMP-compatible bitwise ops over Mp's two's-complement BLIP payload: `bitwiseAnd / bitwiseOr / bitwiseXor / bitwiseNot / shl / shr`. Each runs a byte-level loop over `max(a.payload.len, b.payload.len)` with `tier3.signExtByte` supplying the implicit infinite-extension byte. `shr` is arithmetic right shift, which is floor division in two's-complement (no explicit floor correction needed). Result canonicalises via `canonicalLen` before re-emit through `installPayload` → `tier3.writeHeader` → `Mp.setBytes`.

### `src/sign.zig` (M12-A2)
`neg / abs / fitsI64 / fitsU64 / fitsI32 / fitsU32`. Negation via add-1-then-not equivalent; abs branches on `cachedSign`. The `fits*` predicates are pure (no allocator) — compare bitLen + sign to the target type's range.

### `src/scan.zig` (M12-A6)
`popcount / scan0 / scan1` — Hamming weight + first-bit search. Matches GMP `mpz_popcount` / `mpz_scan0` / `mpz_scan1` semantics. Negatives return `usize.max` for popcount (infinite 1-bits in two's-complement). Inner loop reads u64 chunks via `readInt` then `@popCount`/`@ctz`/`@clz`. scan0 on a positive looking past its bitLen finds the first 0 of the implicit-zero tail.

### `src/gcd.zig` (M12-A4)
Classical Euclidean `gcd(a, b)` extracted as a free function (Mp.invModClassical has the same loop inline for the Bezout track). `lcm(a, b) = |a/gcd*b|`. Both always return non-negative; gcd(0,0)=0, lcm(0,x)=0.

### `src/random_mp.zig` (M12-A5)
`setRandomBits(rng, bits)` — fills (bits+7)/8 bytes from `std.Random`, masks high bits past `bits`, prepends 0x00 if needed to encode positive. `setRandomBelow(rng, n)` — rejection sampling: draw n.bitLen() bits, retry if ≥ n.

### `src/string_io.zig` (M12-A3)
`setStr(slice, base)` / `toString(allocator, base)` for bases 2 / 8 / 10 / 16. Power-of-2 bases use bit extraction; base-10 toString chunks via `10^19` divMod for u64-fast inner loop. Negative numbers get a leading `-`. Errors: `EmptyString / InvalidDigit / UnsupportedBase`.

### `src/primes.zig` (M13-B1)
Miller-Rabin probabilistic primality. `isProbablyPrime(rng, witnesses)` — sieve trial-divides by first 54 primes (< 256) for fast composite rejection, then `witnesses` rounds of Miller-Rabin using `powm` from M7. `nextPrime(out, n)` — scan with 20 internal witnesses. Carmichael 561 / 1729 / 2465 / 6601 / 10585 all correctly flagged composite.

### `src/roots.zig` (M13-B2)
`isqrt / isqrtRem / iroot / isPerfectSquare` via Newton iteration. Initial estimate from bitLen(n). Halts when iterates stop decreasing. Errors `NegativeOperand` for isqrt(n<0), `ZeroExponent` for iroot(_, 0). Odd-k roots of negative inputs are allowed (return negative root).

### `src/symbols.zig` (M13-B3)
`jacobi(a, n) / legendre(a, p) / kronecker(a, n)`. Quadratic reciprocity recursion using bit-tricks for the (2/n) factor and (-1)^((a-1)(n-1)/4) for swap-flip. Kronecker generalises to all n (incl. negative, 0, 2). Result ∈ {-1, 0, +1}.

### `src/combinatorial.zig` (M13-B4)
`factorial(out, n: u32)` — straightforward product loop. `binomial(out, n, k)` — symmetric reduction (use min(k, n-k)), repeated mul/div pattern. `fibonacci(out, n)` — fast-doubling identity: F(2k) = F(k)·(2·F(k+1) − F(k)), F(2k+1) = F(k)² + F(k+1)². Verified against fib(100) = 354224848179261915075.

### `src/fp.zig` (M14 — arbitrary-precision fixed-point, "the IEEE754 disruption")
Exact arbitrary-precision fixed-point on top of Mp. **No NaN, no ±∞, no signed zero, no denormals, no silent rounding** — every op succeeds bit-exactly, takes a caller-supplied precision budget, or errors loudly.
- `Fp = struct { mantissa: Mp, scale: i32, base: Base { binary=2, decimal=10 } }` — dynamic precision per-value, mirroring blip_mp's variable-length-self-describing-storage philosophy.
- Construction: `setI64 / setRationalDecimal / setRationalBinary / setStr / setF64`. setF64 bit-decodes IEEE754 (NaN/±∞ → NotRepresentable; ±0 collapses).
- Comparison: `canonicalize / cmp / eq` — scale-aligned compare; errors `MixedBases` on cross-base.
- Arithmetic: `add / sub / mul`. mul is exact-by-construction (mantissas multiply, scales sum).
- Division: `divExact` (exact-or-error), `divPrecision` (caller-supplied digit budget, returns bool exact), `divQR` (truncating-int quotient + exact reconstructible remainder).
- Cross-base: `toDecimal` (always exact), `toBinary` (errors NonTerminating when needed — e.g. 0.1₁₀ has no terminating binary form).
- Rounding: `roundToScale(target_scale, mode)` + `roundToMp(mode)` with 8 explicit modes (`.exact_or_error / .toward_zero / .toward_pos_inf / .toward_neg_inf / .half_up / .half_down / .half_to_even / .half_to_odd`).
- Output: `toStringCanonical(allocator)` — splice radix point into Mp.toString output; produces `"0.3"`, `"0.025"`, `"1500"`, etc. `toStringFixed(allocator, x, frac_digits)` — pad/round (banker) to fixed fractional width. `toStringScientific(allocator, x)` — `[-]M.MMMeE` (decimal) / `[-]M.MMMpE` (binary, C99 hex-float style with binary digits).
- IEEE754: `getF64Exact` — encode back to f64 ONLY if exactly representable; errors otherwise. `getF64(self, mode)` — general counterpart that rounds >53-bit mantissas via `roundToScale(mode)`; carry-up renormalize handled.
- Headline test: `0.1 + 0.2 == 0.3 EXACTLY` (and the inverse killshot: setF64(0.1) → toDecimal → 55-digit decimal expansion of the IEEE754 lie).

### `src/fft.zig` (2082 lines)
Pure-Zig FFT mul stack (M6-3 + M6-4). Currently gated off in production but correctness-validated at every level.

**Field abstraction** (M6-3.14):
- `Field { p, primitive_root, max_ntt_len }` with comptime-generic methods
- `F1` (p = 998244353), `F2` (p = 985661441) — two NTT-friendly primes for two-prime CRT

**Modular arith** (single-prime API for backwards compat):
- `P` constant, `addModP` / `subModP` / `mulModP` / `powMod` / `invModP` / `nthRootOfUnity`
- `BARRETT_M` constant (used in earlier Barrett experiment; reverted — kept as future-work scaffold)

**NTT primitives** (M6-3 ladder):
- `bitReversePermute(a)` — radix-2 bit-reversal
- `nttWithTwiddles(a, twiddles)` — scalar Cooley-Tukey
- `ntt(a, invert)` — wrapper builds twiddles inline; for tests only

**SIMD** (M6-4-A):
- `addModP_x2` / `subModP_x2` / `mulModP_x2` — `@Vector(2, u64)` lane ops; ~1.4-1.7× lane speedup (mulModP_x2 is hybrid scalar-inside-vector exploiting M4 dual scalar mul pipes per M6-4-A.6 finding)
- `nttWithTwiddlesVec(a, twiddles)` — vec NTT used in production mulMagnitudes

**Algorithmic variants** (M6-4-B/C/D scaffolding — not in production path):
- `montMul` / `toMont` / `fromMont` / `montMul_x2` / `nttWithTwiddlesMontVec` — Mont-form NTT scaffolding
- `nttStockham` / `nttStockhamVec` — Stockham auto-sort variants
- `nttRadix4Vec` — radix-4 mixed (with one radix-2 pass when log2(N) odd)

**Mul integration**:
- `mulMagnitudes(allocator, a, b, out) -> usize` — single-prime FFT mul (allocates own buffers)
- `mulMagnitudesWithScratch(a, b, out, pa, pb, tw_fwd, tw_inv, stockham_scratch) -> usize` — caller-supplied scratch path used by tier3 dispatcher
- `mulMagnitudesCRT` — two-prime variant for ≥ 56K-bit operand sizes (M6-3.14)
- `MAX_FFT_COMBINED_LEN`, `MAX_FFT_CRT_COMBINED_LEN` — single/two-prime caps

### `src/c_api.zig`
C FFI surface (M8 + M12/M13 sweep + M14-9 Fp sweep). `extern fn` exports wrap every public op with libc-allocator handle lifecycle. `mapError` translates the full Zig error union (`SetError | ArithError | StringError | SymbolError | RootError | FpError`) into ~11 integer error codes. Opaque handles: `blip_mp_t` (Mp), `blip_mp_rng_t` (DefaultPrng), `blip_mp_fp_t` (Fp). `comptime { _ = ...; }` retain block defeats ReleaseFast symbol-stripping in the static lib. Full surface: ~90 exports total.

## include/

### `include/blip_mp.h`
Public C API. Three opaque handles (`blip_mp_t`, `blip_mp_rng_t`, `blip_mp_fp_t`). Surface: integer lifecycle / set / get / arithmetic / modular (M8 baseline); bitwise / sign / scan / gcd / random / string I/O / primes / roots / symbols / combinatorial (M12 + M13); full Fp arithmetic + cross-base + rounding + format + IEEE754 interop (M14-9). Worked example block at top of the Fp section showing the `0.1 + 0.2 == "0.3"` demo in pure C. 11 error codes: OK, DIVISION_BY_ZERO, OUT_OF_MEMORY, NOT_IMPLEMENTED, INVALID_INPUT, OUT_OF_RANGE, NO_INVERSE, NEGATIVE_OPERAND, BUFFER_TOO_SMALL, MIXED_BASES, NON_TERMINATING, NOT_REPRESENTABLE.

## tests/

### `tests/integration/cross_check.zig`
Exhaustive GMP cross-validation. **12029 random comparisons** spanning add/sub/mul (8240) + divq/divr (2300) + powm (720) + invMod (762 + 7 no-inverse boolean checks). 18 bit-widths from 8 to 8192 bit. Run by `./test` after the unit-test pass. Each op produces results bit-identical to GMP's corresponding `mpz_*` function.

### `tests/benchmark/blip_mp_bench.zig`
Comprehensive Mp bench. Small-value buckets (immediate / L=2..L=4) measure tier-0/1 hot paths. `LARGE_BUCKETS` (128..32768 bit) measure tier-3 add/sub/mul. Dedicated `DIVMOD_BUCKETS` / `POWM_BUCKETS` / `INVMOD_BUCKETS` (iteration 9) for the modular-arith ops. Times via direct `clock_gettime` extern (`std.time.Timer` was removed in Zig 0.16).

### `tests/benchmark/gmp_bench.c`
C executable benchmarking GMP at the same buckets/iterations. Built with `-O3 -Wall -Wextra`. Bench-only dependency; the blip_mp core has no GMP requirement. Linked against system GMP via `-Dgmp-include-path=...` / `-Dgmp-lib-path=...` flags (auto-supplied by the nix `bench` package). The same C source is also used to build `gmp_noasm_bench` against the `--disable-assembly` GMP variant for the M5-5 controlled experiment.

### `tests/benchmark/fft_microbench.zig`
Isolated microbench for FFT primitives (M6-4-A.1 work). Times scalar vs vec `mulModP` / `addModP` / `subModP` lane ops, and full-NTT-pass (N=8192) for nttWithTwiddles / nttWithTwiddlesVec / nttStockhamVec / nttRadix4Vec / nttWithTwiddlesMontVec.

### `tests/cli/c_smoke.c` (~350 lines)
End-to-end FFI smoke test (M8 + iters 24/25 expansions). Exercises lifecycle (incl. NULL-safety), i64 + u64 set/get roundtrip + error cases, bit access (bit_at/bit_len with 0/1/0xFF/0x100/-0x100 sweeps including out-of-range and sign-ignore semantics), arithmetic (add/sub/mul/div/mod/divMod), powm + invMod (with no-inverse case), set_bytes → arith → bytes() round-trip, sign / cmp / is_zero predicates, error returns. Built as `c-smoke` binary; runs via `c-smoke-run` step. Wired into `./test` as the third group alongside Zig units and 12029 GMP cross-checks.
