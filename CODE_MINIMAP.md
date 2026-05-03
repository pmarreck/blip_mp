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
- `Mp.hgcd(out_M, a, b, target_bits, allocator)` (M11.1) — half-GCD primitive. Reduces `(a, b)` until `bitLen(a') ≤ target_bits` (canonical use: `target_bits = bitLen(a) / 2`), outputting the accumulated reduction matrix in `out_M`. Iterative Lehmer-style with multi-precision matrix accumulation via `composeOuter`. Standalone — not yet integrated into `Mp.invMod` (M11.2 future work). Validated as bit-for-bit equivalent to classical EEA reduction stepped to the same target threshold across {64..2048}-bit random pairs.

**Internal helpers** (incomplete — see file):
- `decodeInlineSmall` (single-LDR i64 read), `ensureHeapCapacity`
- `tier3Op(comptime op: TierOp)` — generic tier-3 add/sub dispatcher
- `smallInlineTier3Add` / `sameSizeTier3Add(comptime N)` — fast paths for inline + size-matched ops; comptime-polymorphic on `op`, serves both `add` and `sub`
- `tier3MulOp` / `smallInlineTier3Mul` / `sameSizeTier3Mul(comptime N)` — fast paths for mul
- `tier3DivModOp` — wraps `tier3.divModSigned` with stack/heap scratch and `writeMpFromPayload`
- `writeMpFromPayload(dst, pay)` — encode canonical signed payload into Mp (inline vs heap routing)
- `topU128(self)` / `setU128(self, v)` — top-128-bit window helpers used by invModHGCD
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
- `cmpUnsignedLE(a, a_len, b, b_len) -> i8` — unsigned magnitude compare

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

### `src/c_api.zig` (172 lines)
C FFI surface (M8). `extern fn` exports wrap Mp ops with libc-allocator handle lifecycle. `mapError` translates Zig error sets to C error codes. `comptime { _ = ...; }` block defeats symbol-stripping in ReleaseFast static lib.

## include/

### `include/blip_mp.h` (110 lines)
Public C API. Opaque `blip_mp_t` handle. Lifecycle (create/destroy), setters/getters (set_i64/get_i64/set_u64/get_u64/set_bytes/byte_len/bytes), predicates (cmp/sign/is_zero), bit access (bit_at/bit_len), arithmetic (add/sub/mul/div/mod/div_mod), modular (powm/inv_mod). Error codes: OK, DIVISION_BY_ZERO, OUT_OF_MEMORY, NOT_IMPLEMENTED, INVALID_INPUT, OUT_OF_RANGE, NO_INVERSE.

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
