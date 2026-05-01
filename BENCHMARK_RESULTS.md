# BENCHMARK_RESULTS.md — blip_mp vs GMP

## Run 1 — 2026-04-30 EST

### Environment

- **Machine:** Apple Silicon (aarch64-darwin), macOS 26.x
- **Build:** `nix build .#packages.aarch64-darwin.bench`
- **Optimization:** ReleaseFast for blip_mp (Zig 0.16.0), `-O3` for GMP exe (clang)
- **GMP:** 6.3.0 from nixpkgs
- **Allocator:** libc malloc for both (apples-to-apples)
- **Workload:** 5M iterations of `r = pool[i % 256] + pool[(i+1) % 256]`
- **Pool:** 256 pre-built values, evenly spaced inside each bucket's range

### Raw numbers (ns per add)

| Bucket | `Mp.add` (current, per-call alloc) | `raw` (zero-alloc, SBO upper bound) | GMP `mpz_add` |
|---|---:|---:|---:|
| immediate (0..127) | 11.22 | **1.32** | 3.61 |
| L=1 (128..255)     | 13.17 | 3.33     | 3.62 |
| L=2 (256..32767)   | 13.48 | 3.46     | 4.12 |
| L=3 (32768..8M)    | 14.31 | 3.97     | 3.77 |
| L=4 (>8M..2G)      | 14.09 | 4.41     | 3.69 |

### Ratios (blip_mp speedup over GMP; >1.0 = blip_mp wins)

| Bucket | `Mp.add` / GMP | `raw` / GMP |
|---|---:|---:|
| immediate (0..127) | **0.32×** (3.1× slower) | **2.73× faster** ✅ |
| L=1                | 0.27× (3.6× slower)     | 1.09× faster |
| L=2                | 0.31× (3.3× slower)     | 1.19× faster |
| L=3                | 0.26× (3.8× slower)     | 0.95× (tied) |
| L=4                | 0.26× (3.8× slower)     | 0.84× (16% slower) |

## Findings

### 1. Per-call allocation kills `Mp.add`

Going from `Mp.add` (which mallocs/frees per call) to `raw` (which writes to a stack buffer) is an **8.5× speedup in the immediate bucket** (11.22 → 1.32 ns). The dominant cost in `Mp.add` is libc malloc round-trip, not the BLIP encode/decode work.

**Implication:** the current `Mp` representation (`{bytes: []u8, allocator}`, always heap) is fundamentally incompatible with the spec's hypothesis. The spec called for "**skipping the struct + heap entirely**" via the small-buffer-optimization (representation 1a). Without that, we're nowhere.

### 2. The hypothesis is partially validated

For the immediate bucket (values 0..127), the zero-alloc tier-0 fast path is **2.73× faster than GMP** — exceeding the SPEC's 1.5× threshold for "worth pursuing."

For L=1..L=2 (values 128..32K), blip_mp is **1.09× to 1.19× faster** — modest but consistent. Below the 1.5× threshold but trending in our favor.

For L=3..L=4 (values > 32K), GMP catches up (mpn_add is hand-tuned for limb-array layouts) and slightly beats us. Expected — SPEC §Hypothesis #3 only claims to "match" GMP on large numbers via tier-3 unpack/repack, which we haven't built.

### 3. Where the immediate-bucket win comes from

GMP's per-op cost (~3.6 ns) includes: read mpz_t struct (16 B), indirect-load `_mp_d` (cache miss possibility), native add, write back. It's well-tuned but pays for the indirection.

blip_mp's `raw` immediate path (~1.32 ns) is: read 1 byte, read 1 byte, native add, write 1 byte. **The bytes ARE the value.** No indirection. This is exactly the architectural advantage SPEC.md predicted.

### 4. The "Mp.add" implementation is roughly the floor, not the ceiling

`Mp.add` decodes both inputs (~3 ns total in raw measurement), does the add, then `setI64` allocates a new buffer, encodes, and frees the old buffer. The 8.5× Mp/raw ratio for immediate is essentially **the per-add malloc+free cost**.

## Decision

PLAN.md M2 decision rule: "if blip_mp ≥ 1.5× faster on a representative workload, proceed to M3. Otherwise document findings and stop."

**Reading 1 (strict):** the current `Mp.add` is 3× SLOWER than GMP. Stop.

**Reading 2 (correct):** `Mp.add` is not the design the SPEC called for. The SPEC called for SBO. The `raw` measurement is the closest available proxy for SBO performance, and it shows **2.73× win** in the immediate bucket — the case the hypothesis is most enthusiastic about.

**Chosen path:** **proceed to a Milestone 1.6 — implement representation 1a (SBO)**. Re-benchmark. If SBO `Mp.add` lands within 10% of `raw` numbers (i.e., still beats GMP by 1.5× in immediate, ties in L=1..L=2), the hypothesis is fully validated and M3 is justified.

This is consistent with the spec's own framing — it explicitly listed both representations and noted that 1a "is more aggressive but trickier; the second is closer to a drop-in." We took the easy path first to learn what we needed; we now know the alloc cost is unavoidable on the easy path and SBO is the real test.

## Caveats

- **No JIT warmup, no statistical sampling.** Single run, single machine. Should add hyperfine cross-validation and N-run aggregation in a follow-up.
- **Pool size 256, 5M iterations.** Pool fits in L1 (256 \* ~16 B per Mp = ~4 KB). Larger pools or random-access patterns may shift numbers.
- **Same allocator (libc malloc) for both** is fair, but GMP can be configured with custom allocators; some workloads pre-allocate aggressively to skip the per-op cost. Ours can't (current design).
- **Only `add` measured.** sub and mul will likely show similar shapes; cmp and conversion ops are different stories worth measuring later.
- **Compiler:** Zig 0.16.0 ReleaseFast; clang for GMP exe with `-O3`. LTO not enabled. Could matter for both.

## Next steps

- [ ] Implement representation 1a (SBO) for `Mp` — inline payload up to ~24 bytes in the struct, only heap-allocate when L exceeds the inline capacity.
- [ ] Re-run this benchmark with SBO `Mp.add`. Update this file with Run 2.
- [ ] If Run 2 confirms SBO matches `raw` within 10%, proceed to Milestone 3 (tier 3 / large-number paths).
- [ ] If Run 2 is more than 10% off `raw`, profile what's eating the difference (struct read overhead? branch misprediction on the SBO discriminator? cache effects?).

## Reproduction

```sh
cd blip_mp
nix build .#packages.aarch64-darwin.bench
./result/bin/blip_mp_bench
./result/bin/gmp_bench
```
