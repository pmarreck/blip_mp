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
- **Cryptographic multiplication (1024, 1536, 3072 bit): 1.12–1.46× faster**
- **Large addition (4096+ bits): 1.03–1.28× faster**
- **Large multiplication (16384+ bits via Toom-3): 1.03× faster** (modest)
- **Modular exponentiation (RSA-2048): 11% faster than GMP** (Mp.powm with Montgomery, M7-4.3) — at 1024 and 3072 bit we're at parity. This is the headliner for any serious crypto workload (RSA encrypt/decrypt/sign, DH key exchange, ECC scalar mul).
- **Long division (2048-bit / 1024-bit): 24% faster than GMP** (Mp.divMod with u64-base Knuth Algorithm D) — 36× faster than the byte-base implementation that originally lagged by 28.8×.
- **Correctness: 12029/12029 random GMP cross-validation tests pass** across add, sub, mul, div, mod, divMod, powm, invMod — the complete modular-arithmetic API.

### The honest losses

We're slower than GMP at:
- **128–2048 bit addition** (0.36–0.79× of GMP). Bookkeeping overhead in our `tier3Op` dominates at small sizes; closing the gap is implementation polish, not algorithm.
- **128–256 bit multiplication** (0.40–0.67×). Same per-op overhead.
- **8192+ bit multiplication** (0.52–0.72×). GMP uses Schönhage-Strassen FFT mul. We have a full pure-Zig FFT stack (single-prime NTT + two-prime CRT + NEON-SIMD butterflies) but it's currently gated off in production — even with the 1.40× speedup from vectorization (32K-bit FFT path: 191K → 135K ns), Toom-3 still wins at 117K ns. 13–15% gap remaining; M6-4-E ladder in PLAN.md targets the alloc-elimination + Stockham + inline-asm levers needed to flip it.

### Surprise: GMP's hand-tuned aarch64 asm gives ~0% advantage on Apple Silicon

We built a second GMP variant with `--disable-assembly` and ran the same benchmark. The asm advantage is essentially zero across all our test sizes. At 4096-bit and 32768-bit add, **the C reference code is actually faster than the asm.** Modern clang `-O3` generates near-optimal ADCS chains from C `__builtin_add_overflow` that the hand-tuned asm can't beat — and the asm becomes an opaque call boundary that breaks inlining.

**Implication:** every gap to GMP is purely algorithmic. We don't need inline asm. We need FFT mul and tighter bookkeeping. Both are pure-Zig achievable.

---

## Quick start

Requires [Nix](https://nixos.org/) (handles the Zig 0.16.0 toolchain and GMP build for benchmarks).

```bash
git clone https://github.com/pmarreck/blip_mp
cd blip_mp

./build           # native ReleaseFast build via nix
./test            # 76+ unit tests + 8240-check GMP cross-validation
./result/bin/blip_mp_bench    # run the bench (after nix build .#packages.<sys>.bench)
```

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
- **Modular inverse lags GMP** by ~7-8× at 1024-2048 bit (down from 29-38× before M9 Lehmer). Closing the remainder requires half-GCD (sub-quadratic divide-and-conquer reformulation), planned as M10.
- **Single platform validated** — numbers above are all aarch64-darwin (Apple M-series). x86_64 may shift the picture, especially around the asm-vs-clang result.
- **No C FFI yet** — public surface is Zig-only. Adding `include/blip_mp.h` is a clear extension.
- **Not optimized for non-aligned operand sizes** — `tier3Op` works on any size but is fastest when payload lengths are multiples of 8 bytes (which most cryptographic sizes are).

**What it isn't trying to be:**
- Not a full GMP replacement. No `mpf_t` (floats), no `mpq_t` (rationals), no `mpfr` (extended-precision floats).
- Not chasing huge-number records. GMP's per-arch asm tuning is decades of work; we stop being competitive at 64K+ bit operands until FFT lands.
- Not asm-tuned. The M5-5 controlled experiment showed asm gives ~0% on M-series. We may need to revisit on x86_64 if the picture differs.

---

## Roadmap

**In priority order:**

1. **Finish the FFT-vs-Toom-3 flip** (M6-4-E in PLAN.md). The FFT primitives, CRT extension, and NEON-SIMD butterfly are all shipped and correctness-validated; closed Toom-3 gap from 1.93× to 1.15×. Remaining 13–15% needs caller-supplied scratch (eliminates 4 per-call allocs ≈ 6–9K ns), wiring Stockham into production, and possibly hand-scheduled aarch64 inline asm for the butterfly inner loop.

2. **Tighter `tier3Op` bookkeeping** for 128–2048 bit add. Closes the small-add gap (currently 0.36–0.79× of GMP). Pure refactoring — fold `bytes()` indirection, aliasing check, ensureHeapCapacity into a single inline path with size-specialized variants. Probably ~half-day of work.

3. **Cross-platform validation on x86_64 Linux + Windows.** Two M-series-specific findings need verification on x86_64: (a) "GMP asm gives ~0% on M-series, AVX-512 may shift it" (M5-5); (b) "pure-NEON Montgomery loses to scalar-inside-vector because of M4's dual scalar mul pipes" (M6-4-A.6) — different scheduler may flip this.

4. **Half-GCD for `Mp.invMod`** — closes the remaining 7-8× gap to GMP. M9 Lehmer dropped the gap from 30-38× to 7-8×; sub-quadratic half-GCD is the next algorithmic step.

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
