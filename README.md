# blip_mp

**A pure-Zig multi-precision integer library that stores values as BLIP-encoded bytes (variable-length, self-describing) instead of GMP's fixed-width-limb-array representation.** Beats GMP at the most common bignum operations on Apple Silicon. Pure Zig, no inline assembly, no LGPL link constraint.

> *"Storage-as-wire-form" + small-buffer-optimization + lazy-on-demand metadata caching. Validated empirically against GMP's 8240-test cross-checked reference.*

---

## Why does this exist?

GMP's `mpz_t` is the de-facto bignum representation in serious numerical software. Its weakness: **per-value overhead is fixed and structural, regardless of how large the actual integer is.**

```
mpz_t = { int _mp_alloc, int _mp_size, mp_limb_t *_mp_d }
       ≈ 16 bytes of struct
       + heap allocation for _mp_d
       + alignment padding
       + allocator bookkeeping

Storing the value 5 takes ~24 bytes spread across two cache lines,
mediated by a malloc round-trip.
```

For workloads dominated by small or medium numbers (accumulator loops, EC scalars, polynomial coefficients, hash-derived integers), GMP's structural overhead is a 5–25× memory blowup over the actual information content, plus an allocator round-trip on every value created or destroyed.

**BLIP** ([spec](https://github.com/pmarreck/BLIP)) is a self-describing variable-length integer encoding:

| Value | BLIP bytes | GMP storage |
|---|---|---|
| `5` | 1 byte (immediate) | 24+ bytes (struct + heap) |
| `2^32` | 5 bytes (header + 4 LE) | 24+ bytes |
| `2^256` | 33 bytes | 16 bytes struct + 32 bytes heap |
| `2^4096` | 513 bytes contiguous | 16 + 512 + bookkeeping |

`blip_mp` builds an arbitrary-precision integer library directly on top of BLIP storage. No separate length field, no heap pointer indirection for small values, no allocator round-trip for accumulator loops. **The bytes ARE the value.**

---

## What did we measure?

Apple Silicon (M-series), aarch64-darwin, Zig 0.16.0 ReleaseFast, libc malloc.

### Headline wins

- **All `i64`-fitting values: 1.95–2.66× faster than GMP**
- **All three standard RSA mul sizes (1024, 2048, 3072 bit) beat GMP by 1.19–1.45×** — twelve mul sizes total beat GMP after the iter-33 Karatsuba-leaf cleanup added new wins at 4096, 6144, and 8192 bit too.
- **RSA-2048 trifecta**: blip_mp beats GMP at `mul` (1.16×) + `divMod` (1.31×) + `powm` (1.11×) at the most-deployed crypto operand size worldwide.
- **Addition at 768-bit and above: 1.04–1.28× faster than GMP** (eight sizes now beat GMP after the M5/M9 bookkeeping cleanup; was previously 1.03× at 4096+ only)
- **Subtraction at 256-bit and above: 1.03–2.11× faster than GMP** — ten Mp.sub sizes beat GMP after the chunked-`subPayloads` fix mirrored the long-standing addPayloads optimization. Headline: 6144-bit sub went 606 ns → 48 ns (12.7×).
- **Large multiplication (16384+ bits via Toom-3): 1.03× faster** (modest)
- **Modular exponentiation (RSA-2048): 13% faster than GMP** (Mp.powm with Montgomery, M7-4.3 + Möller-Granlund-improved inner div). At 1024 we beat by 3%; at 3072 by 8%. This is the headliner for any serious crypto workload (RSA encrypt/decrypt/sign, DH key exchange, ECC scalar mul).
- **Long division (2048-bit / 1024-bit): 24% faster than GMP** (Mp.divMod with u64-base Knuth Algorithm D) — 36× faster than the byte-base implementation that originally lagged by 28.8×.
- **Correctness: 12029/12029 random GMP cross-validation tests pass** across add, sub, mul, div, mod, divMod, powm, invMod — the complete modular-arithmetic API.

### The honest losses

We're slower than GMP at:
- **128-bit addition and subtraction** (~0.56–0.65× of GMP). The remaining gap at the smallest size is the load+store ABI cost difference from blip_mp's heavier struct (one cache line + 8B vs GMP's 24-byte mpz_t) — fundamental, not algorithmic. Other small sizes (192-512 bit) are now within 70-90% of GMP after the cleanup landed.
- **128–256 bit multiplication** (0.40–0.67×). Same per-op overhead.
- **16384+ bit multiplication** (0.55–0.87× post-iter-33). 8192-bit was 0.72× behind GMP pre-iter-33; the Karatsuba-leaf chunking flipped it to 1.04× WIN. 16384-bit closed from 0.68× → 0.87×. 32768-bit still in FFT territory (0.55×). GMP uses Schönhage-Strassen FFT mul above ~16K-bit. We have a full pure-Zig FFT stack (single-prime NTT + two-prime CRT + NEON-SIMD butterflies) shipped + correctness-validated but gated off in production — even with the 1.40× speedup from vectorization (32K-bit FFT path: 191K → 135K ns), Toom-3 still wins at 100K ns post-iter-33. M6-4-E ladder in PLAN.md targets the alloc-elimination + Stockham + inline-asm levers needed to flip it.

### Surprise: GMP's hand-tuned aarch64 asm gives ~0% advantage on Apple Silicon

We built a second GMP variant with `--disable-assembly` and ran the same benchmark. The asm advantage is essentially zero across all our test sizes. At 4096-bit and 32768-bit add, **the C reference code is actually faster than the asm.** Modern clang `-O3` generates near-optimal ADCS chains from C `__builtin_add_overflow` that the hand-tuned asm can't beat — and the asm becomes an opaque call boundary that breaks inlining.

**Implication on aarch64:** every gap to GMP is purely algorithmic. We don't need inline asm. We need FFT mul and tighter bookkeeping. Both are pure-Zig achievable.

### Cross-platform: x86_64 (AMD Zen 4) tells a different story

We ran the same `nix build .#bench` on a NixOS x86_64 Framework laptop (AMD Ryzen 9 7940HS — Zen 4 with full AVX-512, AVX2, BMI/ADX). Two clean findings:

1. **GMP-asm is load-bearing on x86_64**: 1.65–3.88× faster than GMP-noasm depending on size/op. Decades of hand-tuned `mpn_*` chains with `adcx`/`adox`/`mulx` + AVX2/AVX-512 paths IS doing real work on x86_64 — the M-series finding does NOT generalize.
2. **The BLIP-storage paradigm still wins on x86_64**: compared against GMP-noasm-x86_64 (the storage-paradigm-only baseline), pure-Zig blip_mp wins at 22+ size/op pairs — including 1.46× faster on immediate add, 1.30–1.68× faster on add at 4K–32K-bit, 1.5–1.8× faster on mul at 1K–8K-bit, and 1.73× faster on RSA-2048 powm.

So on x86_64 vs **GMP-asm**, blip_mp wins all tier-0/1 sizes but loses tier-3 by 1.5–4× (= the GMP-asm advantage above). Closing that on x86_64 would require equivalent hand-asm work in our codebase, OR upstream Zig codegen improvements for `adcx`/`adox` chains and AVX big-int SIMD. Full numbers in `BENCHMARK_RESULTS.md` Run 18 and `RESULTS.md` "Cross-platform validation" section.

**Cross-platform conclusion:** the architectural advantage of BLIP-storage + sign-extended SBO + byte-direct chunked arithmetic + Möller-Granlund div + Mont-form powm is **platform-independent**. On M-series it produces a clean win-on-most-things vs GMP. On Zen 4 it produces a clean win-on-most-things vs GMP-noasm. The GMP-asm gap on x86_64 is a separate axis (hand-tuned asm vs pure-Zig codegen) — orthogonal to the storage paradigm.

---

## Quick start

Requires [Nix](https://nixos.org/) (handles the Zig 0.16.0 toolchain and GMP build for benchmarks).

```bash
git clone https://github.com/pmarreck/blip_mp
cd blip_mp

./build           # native ReleaseFast build via nix; also builds bp
./test            # ~451 unit tests + 13029 GMP cross-checks + C FFI smoke + bp CLI smoke
./result/bin/blip_mp_bench    # run the bench (after nix build .#packages.<sys>.bench)
```

## `bp` — RPN exact-arithmetic calculator

`bp` is a Forth-style RPN calculator that ships in `./result/bin/bp` after `./build`. It dogfoods the C FFI — same headers any downstream Rust/Lua/Python binding would use — so every shipped fix to the FFI surface gets exercised by the calculator itself.

**Every value is an exact arbitrary-precision rational** (M14 `Fp`, base = decimal). No IEEE754. No silent precision loss. Division uses `divExact` and errors when the quotient has no terminating decimal expansion — there's no quiet rounding hiding under the hood.

```bash
bp 35 factorial 24 factorial \*       # → huge 64-digit exact integer
bp 0.1 0.2 +                          # → "0.3"  (the IEEE754 disruption demo)
bp 0.1 0.2 + 0.3 -                    # → "0"    (the proof)
bp 1 4 /                              # → "0.25" (terminates exactly)
bp 22 7 /                             # → ERROR: non-terminating expansion
bp 100 fib                            # → 354224848179261915075
bp 50 25 binomial                     # → 126410606437752
bp 48 18 gcd                          # → 6

echo "0.1 0.2 +" | bp                 # stdin form

# Forth-style ":" definitions — Phase 2:
bp : square dup \* \; 5 square        # → 25
bp : tau 6.28 \; tau 2 \*             # → 12.56
bp : ! drop 999 \;                  \ # redefines factorial in this run only;
   : real-fact ! \;                 \ # earlier defs that captured the original
   5 real-fact                        # → still 120 (Forth threaded-code semantics)
```

**Operators** (`bp --help` for full list with stack-effect comments):
`+ - * / % ^ neg abs dup drop swap factorial ! fibonacci fib binomial isqrt sqrt gcd lcm`

**Definitions**: `:` enters compile mode and consumes the next token as the new word's name. `;` is "immediate" — it executes even in compile mode and finalises the definition. The body is a list of *resolved* instruction pointers (builtin / user-word / literal-Fp), not text — so re-defining a builtin shadows it for *future* lookups but does NOT retroactively rebind any earlier compiled body. Classic Forth threaded code.

## Use as a library

In your own Zig code:

```zig
const std = @import("std");
const blip_mp = @import("blip_mp");
const Mp = blip_mp.Mp;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var a = Mp.init(allocator);
    defer a.deinit();
    var b = Mp.init(allocator);
    defer b.deinit();
    var r = Mp.init(allocator);
    defer r.deinit();

    try a.setI64(123_456_789);
    try b.setI64(987_654_321);
    try r.mul(&a, &b);

    // r.bytes() is the canonical signed-BLIP encoding — also the wire form.
    // No mpz_export round-trip needed.
    std.debug.print("Product encoded as {d} bytes\n", .{r.bytes().len});

    const value = try r.getI64(); // works because product fits in i64
    std.debug.print("Value: {d}\n", .{value});
}
```

---

## Architecture in one paragraph

`Mp` is a 72-byte struct (one cache line + 8B). Inline mode stores values up to 24 bytes encoded in `inline_buf`; heap mode uses `heap_buf` with a `heap_offset` field that lets results be written without shifting (the header gets placed directly before the payload). For inline length-prefixed values, an internal invariant maintains `inline_buf[1..9]` as the full sign-extended i64 — the arithmetic hot path reads it as a single `LDR` u64 load. Cached `(payload_offset, sign, payload_len)` fields skip per-op header parsing. Tier dispatch is automatic: i64-fitting values use native arithmetic; larger values use byte-direct two's-complement add/sub or Karatsuba/Toom-3 mul over the BLIP payload bytes. **No auxiliary "limb array" data structure exists** — we read u64/u128/u256/u512 chunks directly from the byte payload via `readInt`/`writeInt`. The bytes ARE the value, all the way through.

Full details in [`CODE_MINIMAP.md`](CODE_MINIMAP.md), benchmark history in [`BENCHMARK_RESULTS.md`](BENCHMARK_RESULTS.md), and the comprehensive results writeup in [`RESULTS.md`](RESULTS.md).

---

## Tradeoffs and limitations

**What this library is:** a research-grade arbitrary-precision integer library that validates the BLIP-storage paradigm and beats GMP at common sizes on Apple Silicon. Pure Zig, no asm, no LGPL constraint.

**What it isn't (yet):**
- **FFT multiplication is correctness-shipped but gated off** — full single-prime NTT + two-prime CRT + NEON-SIMD vectorized butterflies live in `src/fft.zig`, all bit-identical to GMP across 8240/8240 cross-checks at sizes up to 256K-bit. But constant factors keep Toom-3 ahead at every operand size in our supported range (M-series-specific finding: pure-NEON Montgomery integrates slower than the existing scalar-inside-vector form because it crowds the NEON pipe and starves M4's dual scalar mul pipes). The 13–15% remaining gap needs alloc-elimination + inline asm, planned in M6-4-E.
- **Modular inverse lags GMP** by ~4-6× at 1024-2048 bit (down from 29-38× before M9 Lehmer; further down from 7-8× after M10 wider-window Lehmer). Headline: 2048-bit invMod is now 3.96× behind GMP (was 7.85× pre-M10). Closing the remainder requires true recursive half-GCD, planned as M11.
- **Two platforms validated** — aarch64-darwin (Apple M-series) is the headline, x86_64-linux (AMD Zen 4 with AVX-512) is the cross-check. Library is bit-portable: 213 unit tests + 12029 GMP cross-validations + C FFI smoke pass on both. The asm-vs-clang result is M-series-specific; on x86_64 GMP's hand-asm is genuinely load-bearing (1.65–3.88× over GMP-noasm). Windows (x86_64 + aarch64) is covered by the Garnix CI cross-build matrix.
- **No C FFI yet** — public surface is Zig-only. Adding `include/blip_mp.h` is a clear extension.
- **Not optimized for non-aligned operand sizes** — `tier3Op` works on any size but is fastest when payload lengths are multiples of 8 bytes (which most cryptographic sizes are).

**What it isn't trying to be:**
- Not a full GMP replacement. No `mpf_t` (floats), no `mpq_t` (rationals), no `mpfr` (extended-precision floats).
- Not chasing huge-number records. GMP's per-arch asm tuning is decades of work; we stop being competitive at 64K+ bit operands until FFT lands.
- Not asm-tuned. The M5-5 controlled experiment showed asm gives ~0% on M-series — and we beat GMP-asm at 22+ sizes there anyway. **On x86_64 the picture differs**: GMP-asm gives 1.65–3.88× over GMP-noasm on Zen 4, so blip_mp loses tier-3 to GMP-asm on x86_64 (but still beats GMP-noasm-x86_64, the storage-paradigm baseline). Closing the x86_64 GMP-asm gap is future work — would require equivalent hand-asm or Zig compiler improvements for `adcx`/`adox` + AVX big-int codegen.

---

## Roadmap

**In priority order:**

1. **Finish the FFT-vs-Toom-3 flip** (M6-4-E in PLAN.md). The FFT primitives, CRT extension, and NEON-SIMD butterfly are all shipped and correctness-validated; closed Toom-3 gap from 1.93× to 1.15×. Remaining 13–15% needs caller-supplied scratch (eliminates 4 per-call allocs ≈ 6–9K ns), wiring Stockham into production, and possibly hand-scheduled aarch64 inline asm for the butterfly inner loop.

2. ~~**Tighter `tier3Op` bookkeeping**~~ — DONE 2026-05-02. Five new add wins (768/1536/2048/3072/4096 bit); 128-bit gap closed by ~40%; 1024-bit at parity. Implementation: fast-path specialization for fixed payload sizes that compile to single uN +% ADC chains, plus an inline-fits stack path.

3. **Cross-platform validation on x86_64 Linux + Windows.** Two M-series-specific findings need verification on x86_64: (a) "GMP asm gives ~0% on M-series, AVX-512 may shift it" (M5-5); (b) "pure-NEON Montgomery loses to scalar-inside-vector because of M4's dual scalar mul pipes" (M6-4-A.6) — different scheduler may flip this.

4. **True recursive half-GCD for `Mp.invMod` (M11)** — closes the remaining 4-6× gap to GMP. M10 (wider-window Lehmer) just landed at 3.96× of GMP at 2048-bit; true recursive HGCD with multi-precision matrix entries is sub-quadratic and would close most of what's left.

5. **C FFI header** (`include/blip_mp.h`) for downstream consumers.

6. **Toom-Cook 4-way** for 4K-16K bit mul. Deprioritized — its modest 15-30% gain isn't worth the implementation cost while FFT remains the headliner. M6-2.1 + M6-2.2 helpers (`divExactBy5`, `mulSmallSignedConst`) are in tier3.zig as future-work building blocks.

7. **`hyperfine` integration** in `./bm` for proper statistical benchmark aggregation. Current numbers are 3-run hand medians.

---

## License intent

MIT or Apache-2.0 (TBD before tagging a release). Both permit linkage with libgmp (LGPLv3) and downstream commercial use.

---

## Acknowledgments

- The [BLIP encoding spec](https://github.com/pmarreck/BLIP) by Peter Marreck.
- GMP team for the reference implementation we cross-validate against.
- Marco Bodrato and Alberto Zanoni for the Toom-3 interpolation formulas.

---

*See [SPEC.md](SPEC.md) for the original design hypothesis, [RESULTS.md](RESULTS.md) for the comprehensive technical writeup, [BENCHMARK_RESULTS.md](BENCHMARK_RESULTS.md) for per-run history, [PLAN.md](PLAN.md) for the milestone checklist, and [CODE_MINIMAP.md](CODE_MINIMAP.md) for the per-file index.*
