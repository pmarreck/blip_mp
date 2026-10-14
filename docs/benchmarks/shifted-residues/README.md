# One canonical BLIP length through modular representatives

Measured September 27, 2026, Linux 6.18.43 x86_64, AMD Threadripper 3990X,
Zig 0.16.0 ReleaseFast. Baseline source: `eef46a4`, already using five-byte
small-field slots and fused radix-4 stages. No BLIP specification change.

BDFN (Benevolent Dictator For Now) proposed restricting the lengths available within an algorithm so that
decoding could use fewer comparisons. The experiment chooses a modular
representative range whose values all require the same canonical length.
For `p=998244353`, encode `r+p` for each residue `0 <= r < p`. Every stored
integer lies between 998244353 and 1996488705, inclusive, requiring exactly
four signed payload bytes after the ordinary `84` header. Field zero is the
integer `p`, encoded `84 01 00 80 3b`.

Five-run median wall times fall 22.5–43.4% across all twenty size/pattern
combinations. The single-prime multiplication backend now uses shifted
arithmetic. Its scratch allocation remains five bytes per slot. Normal `Mp`
dispatch thresholds remain unchanged; these measurements do not establish a
new win over GMP or a memory reduction.

## Same-kernel comparison

The benchmark instantiates the same transform and carry loop in three modes:

- `canonical`: store least nonnegative residues with their natural BLIP widths.
- `shifted_boundary`: store `r+p`, subtract `p` on reads and add it on writes.
- `shifted_arithmetic`: store `r+p` and keep arithmetic operands in `[p,2p)`.

All three store canonical BLIP integers. The first name distinguishes the
historical implementation; it does not imply the other two are noncanonical.

For shifted operands `a,b`, addition starts with `s=a+b-p` and subtracts `p`
if `s>=2p`. Subtraction starts with `d=a+p-b` and adds `p` if `d<p`.
Multiplication returns `(a*b)%p+p`. The largest product is
3985967149192577025, which fits u64. At output, subtract `p` after inverse
scaling before feeding the carry loop. Every stored intermediate, including
twiddles, has the same header; ReleaseSafe assertions check the range.

Boundary shifting captures most of the benefit. Keeping arithmetic shifted
saves a further 2.1–4.1% relative to that variant across the measured cases.
This comparison supports removing repeated encoding-width work as the main
benefit; it is not an instruction-level profile.

## Random-input results

Five-run medians, nanoseconds per complete product; sizes are bytes **per
operand**, not bits. Setup of input buffers and allocation is outside timing.
Twiddle generation, zero initialization, three transforms, pointwise products,
inverse scaling and carry output are included.

| Bytes each | Reduced wall | Boundary wall | Shifted wall | Wall reduction | Shifted wall range |
|---:|---:|---:|---:|---:|---:|
| 128 | 12069 | 9359 | 9057 | 25.0% | 8962–9170 |
| 512 | 60842 | 42895 | 41709 | 31.4% | 41390–42032 |
| 2048 | 304172 | 193430 | 187550 | 38.3% | 186125–188303 |
| 4096 | 665529 | 405072 | 395213 | 40.6% | 392512–408330 |
| 7000 | 1339094 | 868699 | 837616 | 37.4% | 833305–840558 |

| Bytes each | Reduced CPU | Boundary CPU | Shifted CPU | CPU reduction |
|---:|---:|---:|---:|---:|
| 128 | 12485 | 9828 | 9517 | 23.8% |
| 512 | 60953 | 43164 | 41904 | 31.3% |
| 2048 | 302925 | 192125 | 185910 | 38.6% |
| 4096 | 660748 | 402751 | 392475 | 40.6% |
| 7000 | 1328496 | 861680 | 832656 | 37.3% |

All-255, zero-A and sparse products also improve. Zero initialization is a
deliberate adverse case: shifted zero writes five bytes where the old codec
wrote only its immediate header. Its complete products still improve
29.4–43.4%. See [summary.jsonl](summary.jsonl) for every CPU/wall median and
minimum/maximum across runs, including sparse and carry-heavy cases.

## Method and evidence

`tests/benchmark/shifted_residues.zig` uses identical seeded inputs for all
three variants. Each trial runs all three and rotates their order. Each case
has three warmups, then 100 iterations for 128/512 bytes or 32 for larger
inputs. Five separate process runs produce the reported medians. CPU timings
include the adjacent wall-clock reads; the two clocks need not agree exactly.

- [Baseline source executable](baseline.txt) and [initial fixed-order exploration](exploratory.txt).
- Interleaved runs [1](repeat-1.txt), [2](repeat-2.txt), [3](repeat-3.txt), [4](repeat-4.txt), [5](repeat-5.txt).
- [Final default-backend verification run](final-default.txt).

Reproduce all three modes from this revision:

```bash
nix develop -c zig build bench -Doptimize=ReleaseFast --summary none
./zig-out/bin/fft_microbench
```

Repeat five times and retain the `SHIFT` lines. Each line is that process's
mean ns/product for the named variant, size and pattern; take the median of
the five means. The executable also runs existing arithmetic and FFT controls.
`MUTE_DEBUG_STATUS` was unset and no debug banner appeared.

The machine also ran other projects and builds. There was no CPU affinity or
exclusive reservation. Rotated order and repeated measurements reduce order
bias but do not establish cross-machine performance. At 4096 bytes the shifted
FFT still takes about 395 microseconds; the preceding Toom measurements are
about 145 microseconds. This evidence does not justify enabling single-prime
FFT in normal dispatch. Goldilocks and CRT remain unchanged.

## Correctness

Tests were written and observed failing before their implementation. Codec
tests compare exact bytes with the independent `Mp` encoder, including zero,
signed-width boundaries and maximum field values. Set classifiers cover wrong
headers, truncation and out-of-range representatives. Scalar/SIMD arithmetic
is checked against u128 modular results. Complete products are checked against
schoolbook arithmetic through the 14,000-byte combined bound, with unaligned
scratch, canaries, empty operands, and canonical encodings of stored results.

`./test`, `./build`, and the full native ReleaseSafe unit suite pass.
GMP integration makes 13,111 comparisons with zero
mismatches, including 58 forced products across single-prime, CRT, Goldilocks,
Toom-3 and the two explicit shifted modes. The codec is an internal trusted
representation: `isValid` validates externally supplied bytes, while ReleaseFast
reads assume that contract. A generic BLIP reader correctly decodes `p` as the
integer `p`; interpreting it as field zero requires the modular context.

The measured optimization uses established modular equivalence. This local
experiment makes no mathematical novelty claim.
