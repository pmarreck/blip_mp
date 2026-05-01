# blip_mp — BLIP-Native Multi-Precision Integers

A research-grade arbitrary-precision integer library where the **canonical storage form is BLIP** (variable-length integer encoding) instead of GMP's fixed-width-limb-array representation. Goal: dramatic overhead reduction for small and medium bignums while remaining competitive with GMP on large numbers.

**Status:** rough design spec — soliciting implementation attempts.

## Motivation

GMP's `mpz_t` is the de facto bignum representation in serious numerical software. Its weakness: **overhead per number is fixed and structural**, regardless of how large the actual value is.

```
mpz_t = { int _mp_alloc, int _mp_size, mp_limb_t *_mp_d }
       = 16 bytes of struct
       + heap allocation for _mp_d
       + alignment padding

Even storing the value 5:
  16 bytes struct + 8 bytes heap (one limb) + malloc bookkeeping
  ≈ 24+ bytes spread across two cache lines, mediated by the allocator
```

For workloads dominated by small or medium numbers (accumulator loops, EC scalars, polynomial coefficients, hash-derived integers), this is a 5-25× memory blowup over the actual information content, plus an allocator round-trip on every value created or destroyed.

BLIP gives you:

- `5` → 1 byte (immediate mode, no header)
- `2^32` → 5 bytes (header + 4 LE payload bytes)
- `2^256` → 33 bytes
- `2^4096` → 513 bytes contiguous

…all self-describing, all contiguous, no separate allocation for the digits, no `_mp_alloc` capacity bookkeeping. The size is encoded in the header.

## Hypothesis

A bignum library where storage is BLIP-encoded can:

1. **Beat GMP on small-number workloads by 1.5–3×** by skipping the struct + heap entirely and using native CPU arithmetic for values that fit in u8/u64.
2. **Beat GMP on cache-bound bignum-array workloads** by being contiguous and pointer-free.
3. **Match GMP on large-number arithmetic** by unpacking to limb buffers on demand and calling `mpn_*` (or equivalent) primitives.
4. **Beat GMP on serialization** because the storage form *is* the wire form (no `mpz_export` round-trip, self-delimiting on streams).

## Design

### Storage model

Every `blip_mp_t` is a contiguous byte buffer holding **one BLIP integer**. The buffer's length is determined by parsing the BLIP header. There is no separate length field, no allocator bookkeeping field, no pointer indirection for small values.

The sign is encoded by the value's two's-complement interpretation of the BLIP payload (BLIP itself is signedness-agnostic; the payload is raw bytes, the application chooses the interpretation). For arithmetic we treat the payload as **signed two's complement** of width `L*8` bits.

Two storage modes for the public type:

```
blip_mp_t — fixed inline (e.g. 32 bytes): value is in-place if it fits;
            otherwise the struct holds a pointer to a heap blob.
            Discriminator bit lives in a normally-unused header slot
            (the BLIP value-mode escape: bytes[0] == 0xFF or similar).

OR

blip_mp_t = struct { uint8_t *bytes; size_t len; }
            16 bytes always, payload always on heap, but
            len includes the BLIP header.
            Allocator skipped for tier-0 by inlining bytes[0..2] in struct.
```

The first option (small-buffer-optimization) is more aggressive but trickier; the second is closer to a drop-in. Either could be the answer.

### Arithmetic tiering

Operations dispatch on the value's BLIP encoding:

| Tier | Operand sizes | Strategy |
|------|---------------|----------|
| **0** | Both immediate (L=0) | Native `u7+u7` → `u8`, may promote to tier 1 |
| **1** | Both ≤ L=8 | Native `u64` arithmetic with overflow detection; promote on overflow |
| **2** | One ≤ L=8 | Mixed: small operand stays in register, large goes through tier 3 path |
| **3** | Both > L=8 | Unpack to limb buffer (`mp_limb_t[]`), call `mpn_add_n` / `mpn_mul_n` / etc., re-encode to BLIP. Optionally cache the unpacked form across operations. |

The tier-0/1 paths are **the win**: no allocation, no struct overhead, no `mpn_*` call. Pure arithmetic on stack-resident values. For workloads where most operands are small, this is where the speedup comes from.

The tier-3 path is the GMP-parity case. We can either link to libgmp's `mpn_*` layer (just the limb-level primitives, not the `mpz_*` wrappers) or reimplement. Linking is easier; reimplementing might allow further tuning around BLIP-specific patterns (e.g., the result's L is often known closely after the operation, allowing direct in-place re-encoding).

### Public API sketch (C)

```c
// Storage
blip_mp_t *blip_mp_new(void);
void       blip_mp_free(blip_mp_t *x);
void       blip_mp_set_u64(blip_mp_t *r, uint64_t v);
void       blip_mp_set_i64(blip_mp_t *r, int64_t v);
void       blip_mp_set_bytes(blip_mp_t *r, const uint8_t *buf, size_t len);

// BLIP I/O — storage form IS wire form
size_t     blip_mp_encoded_size(const blip_mp_t *x);
size_t     blip_mp_to_blip(uint8_t *out, size_t cap, const blip_mp_t *x);
ssize_t    blip_mp_from_blip(blip_mp_t *r, const uint8_t *buf, size_t len);

// Arithmetic
void       blip_mp_add(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
void       blip_mp_sub(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
void       blip_mp_mul(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
void       blip_mp_div(blip_mp_t *q, blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *b);
void       blip_mp_mod(blip_mp_t *r, const blip_mp_t *a, const blip_mp_t *m);
void       blip_mp_powm(blip_mp_t *r, const blip_mp_t *base, const blip_mp_t *exp, const blip_mp_t *m);

// Comparison (zero-decode for BLIP-vs-BLIP if same E bit)
int        blip_mp_cmp(const blip_mp_t *a, const blip_mp_t *b);
int        blip_mp_sign(const blip_mp_t *x);

// Bit ops (require unpack, may benefit from BE-mode storage for sortability)
void       blip_mp_shl(blip_mp_t *r, const blip_mp_t *a, unsigned bits);
void       blip_mp_shr(blip_mp_t *r, const blip_mp_t *a, unsigned bits);
```

### Endianness consideration

BLIP's E bit selects per-value LE or BE payload. For arithmetic, **LE is strictly better** (matches limb order on LE hosts, no swap on unpack). For storage that needs lexicographic comparison without decoding, BE wins. The library should:

- Default to **LE** for all freshly-computed values
- Accept BE-encoded inputs transparently (decode swaps once)
- Optionally re-encode to BE on serialization if the caller asks for sort-friendly output

### Sign convention

BLIP encodes raw bytes; signedness is the application's call. For `blip_mp_t` we adopt:

- The BLIP payload is a **two's-complement signed integer of width `L*8` bits**.
- Encoders MUST emit the minimum L that contains the value (canonical form):
  - `5` → immediate (L=0, value=5)
  - `-1` → L=1, payload=`0xFF`
  - `-128` → L=1, payload=`0x80`
  - `-129` → L=2, payload=`0x7F 0xFF`
- `0` → immediate (L=0, value=0)
- Overlong encodings (e.g., `5` written with L=1 as `0x05`) are **sentinels per BLIP spec** and are not valid `blip_mp_t` values — they are reserved at the BLIP layer.

### Comparison: GMP vs blip_mp

| Aspect | GMP `mpz_t` | `blip_mp_t` |
|---|---|---|
| Bytes for `5` | 16 (struct) + 8 (heap) | 1 |
| Bytes for `2^32` | 16 + 8 | 5 |
| Bytes for `2^256` | 16 + 32 | 33 |
| Bytes for `2^4096` | 16 + 512 | 513 |
| Allocations per value | ≥ 1 | 0 (small) or 1 (large) |
| Cache locality on arrays | Poor (pointer chase) | Excellent (contiguous) |
| Serialization | `mpz_export` + length metadata | Direct (storage IS wire) |
| Native serialization framing | None | Self-delimiting |
| Tier-0 small arithmetic | Same as large | Native u64, no setup |
| Large arithmetic | Hand-tuned mpn assembly | Unpack → mpn → re-encode |

## Open design questions

1. **Inline vs. heap.** Does the tier-0 fast path require a small-buffer-optimization in the struct (inline 32 bytes), or is the heap fast enough? Worth benchmarking.
2. **Limb-buffer caching.** For repeated operations on the same operand (e.g., modexp's base), should we cache the unpacked limb form? If so, where (struct field? thread-local?).
3. **In-place vs. copy semantics.** GMP is in-place via `r = a + b` writing to `r` (mutable). Should `blip_mp_t` follow GMP or favor immutable + return-by-value with copy-on-write?
4. **Linking to libgmp's `mpn_*`.** Acceptable for tier 3? Or do we want a fully-independent library?
5. **Thread safety.** Allocator-free tier-0/1 paths are inherently thread-safe. Tier 3's heap usage requires choices.
6. **Alignment.** `mpn_*` typically wants `mp_limb_t`-aligned buffers. BLIP payloads are byte-addressable. The unpack step needs to copy into an aligned buffer anyway, so this might be a non-issue.
7. **Negative numbers and L.** `-1` can be encoded as L=1, L=2, L=4, L=8 (all `0xFF...`). Canonical form picks the smallest. But carry-out from `add` may produce a value whose canonical L is smaller than the operand L (due to sign-extension cancellation). The encoder needs a canonicalization pass.

## Benchmark plan (when implementation exists)

Benchmark `blip_mp` against GMP across the value-size spectrum, with attention to:

| Workload | Expected outcome |
|---|---|
| Small accumulator (sum of u32 array as bignum) | blip_mp wins big |
| Fermat primality test on small primes (<2^32) | blip_mp wins big |
| Curve25519 scalar mult (~256 bits) | blip_mp wins moderately |
| RSA-2048 modexp | Roughly equal |
| RSA-4096 modexp | Roughly equal (GMP slight edge) |
| Bignum array creation/destruction (1M values) | blip_mp wins big (no malloc) |
| Serialization round-trip | blip_mp wins big |
| Sorted bignum comparison (B-tree key) | blip_mp wins big with BE storage |

The "wins big" bar is **at least 50% faster** to be worth the effort. Anything less and the value of replacing GMP is dubious.

## Constraints / non-goals

- **Not** a full GMP replacement. We are building a *bignum integer* library only. No `mpf_t` (floats), no `mpq_t` (rationals), no `mpfr` (extended precision floats).
- **Not** a fork of GMP. Independent library that may *link to libgmp's mpn layer* for tier 3 if convenient.
- **Not** a serialization library that wraps GMP. The point is to make the storage native, not just provide an export format.
- **Not** trying to beat GMP on huge numbers (>1024 bits). GMP's per-architecture asm tuning is decades of work; we benefit from it via the mpn layer rather than competing with it.

## Suggested first implementation steps

1. **Skeleton library**: pick C or Zig (Zig is preferred for the BLIP project's existing codebase; C is more portable for GMP linkage). Design the `blip_mp_t` storage and the BLIP encode/decode primitives (already exist as `blip_encode`/`blip_decode` in the BLIP library — link against `libblip`).
2. **Tier 0/1 only**: implement add/sub/mul/cmp for L ≤ 8 with native u64 arithmetic and overflow promotion paths.
3. **Microbenchmark vs. GMP**: small-value workloads only at this point. If blip_mp isn't dramatically faster here, the hypothesis is wrong and we stop.
4. **Tier 3**: link libgmp's mpn layer, implement unpack/repack, validate big-number arithmetic correctness against GMP.
5. **Full benchmark suite**: run the workloads in §Benchmark plan.
6. **Iterate**: if hypothesis holds, productize; otherwise document findings and shelve.

## References

- BLIP encoding: `../BLIP/BLIP_SPEC.md`, `../BLIP/BLIP_SPEC_CONCISE.md`
- BLIP C FFI: `../BLIP/src/blip.h` (functions: `blip_encode`, `blip_decode`, `blip_encoded_size`, `blip_xxhash64`)
- GMP internals: <https://gmplib.org/manual/Internals>
- GMP `mpn_*` low-level API: <https://gmplib.org/manual/Low_002dlevel-Functions>
- Prior art for small-bignum optimization: FLINT's `fmpz_t` (single-limb fast path with promotion to mpz on overflow). FLINT proves the concept works; blip_mp would generalize it from "single limb" to "L≤8 BLIP".

## License intent

MIT or Apache-2.0 (TBD), to permit linkage with both libgmp (LGPLv3) and downstream commercial use.

---

**For the implementing LLM:** this is a research project. The hypothesis is well-defined; the tier-0/1 small-value win is where to focus first. If you can show a clean 2× speedup on a representative small-value workload using a minimal viable implementation, the project is worth pursuing further. If the speedup isn't there, document why honestly and stop — there's no point engineering a worse GMP.
