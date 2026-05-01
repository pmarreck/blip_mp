# blip_mp — Project Overview

## Ultimate Goal

Prove (or honestly disprove) the hypothesis that an arbitrary-precision integer library whose **canonical storage is BLIP** (variable-length, self-describing, contiguous) can dramatically outperform GMP's `mpz_t` on **small- and medium-value workloads**, while staying competitive on large numbers.

The bar for "worth pursuing" is **≥ 1.5×** speedup vs GMP on a representative small-value benchmark using a minimal viable implementation. If we can't show that, we document why and stop.

## Why BLIP storage matters

GMP's `mpz_t` is `{int _mp_alloc, int _mp_size, mp_limb_t *_mp_d}` — 16 bytes of struct, plus a heap allocation for `_mp_d`, plus allocator bookkeeping. Storing the value `5` costs ~24 bytes spread across two cache lines and a malloc round-trip. For workloads dominated by small numbers (accumulators, EC scalars, polynomial coefficients, hash-derived integers), this is 5–25× memory blowup over the actual information content.

BLIP encodes `5` in **one byte** (immediate mode), `2^32` in 5 bytes, `2^256` in 33 bytes, all self-delimiting, all contiguous. The storage form *is* the wire form — no `mpz_export` round-trip.

## Tier dispatch (the win)

| Tier | Operands | Strategy |
|------|----------|----------|
| 0 | Both immediate (BLIP L=0) | Native `u8` arith, no alloc, no struct |
| 1 | Both ≤ L=8 | Native `u64` with overflow promotion |
| 2 | Mixed sizes | Small in register, large via tier 3 |
| 3 | Both > L=8 | Unpack to limb buffer, call mpn-style primitives, re-encode |

**Tiers 0 and 1 are where the speedup lives.** No allocation, no `mpn_*` call, just register arithmetic. Tier 3 is the GMP-parity case and is **out of scope for the first proof** — we ship tier 0/1 only and benchmark.

## Terminology

- **BLIP**: Byte Length Integer Prefix encoding. See `../BLIP/BLIP_SPEC.md`. Immediate values fit in one byte (no header); larger values have a header indicating payload length `L` and a payload of `L` bytes (LE or BE).
- **L**: BLIP payload length in bytes. `L=0` = immediate; `L=1..8` covers what we call tier 1.
- **`blip_mp_t`**: This library's bignum struct. **Representation 1b**: `{uint8_t *bytes; size_t len}` — always-heap payload, `len` includes the BLIP header. Simpler than the small-buffer-optimization variant; promotes to that only if benchmarks justify it.
- **Tier 0 / Tier 1 / Tier 3**: see table above.
- **Canonical form**: minimum-`L` encoding for a given two's-complement value. Overlong encodings are BLIP sentinels and not valid `blip_mp_t` values.
- **mpn layer**: GMP's low-level limb-array primitives (`mpn_add_n`, `mpn_mul_n`, etc.). Tier 3, when implemented, may link to it.

## Non-goals

- No `mpf_t` (floats), no `mpq_t` (rationals), no `mpfr`.
- Not a fork of GMP. May *link* to libgmp's mpn layer for tier 3 (if/when we get there).
- Not chasing huge numbers (>1024 bits). GMP's per-arch asm tuning is decades of work.
- No CLI app. The only executable is the benchmark harness.

## Architecture

```
[blip_mp_bench (Zig)] ──► C FFI (blip_mp.h) ──► [blip_mp Zig core]
                                                        │
                                                        ▼
                                       inlined BLIP encode/decode
                                       (per BLIP_SPEC, treated as a standard)
```

Pure Zig core, no I/O. C FFI is the public API. The benchmark harness exercises the FFI (dogfooding). No CLI for end users — this is a library + benchmark.

**BLIP integer encoding is treated as a stable external standard** and reimplemented from spec in this repo's `src/encoding.zig`. We do not depend on the sibling `BLIP` library — its full Zig module re-exports an entire archive ecosystem (compression, JXL, FLAC, etc.) which would be grotesque overkill for a bignum library that needs ~200 lines of encode/decode. Spec source of truth: `../BLIP/BLIP_SPEC_CONCISE.md`.

## License intent

MIT or Apache-2.0 (TBD), to permit linkage with both libgmp (LGPLv3) and downstream commercial use.

## References

- `SPEC.md` — full design spec
- `../BLIP/BLIP_SPEC.md` — BLIP encoding spec
- `../BLIP/src/blip.h` — BLIP C FFI
- GMP internals: <https://gmplib.org/manual/Internals>
- FLINT's `fmpz_t` — prior art (single-limb fast path with mpz promotion)
