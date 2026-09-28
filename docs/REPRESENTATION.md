# Arithmetic storage after the September 2026 migration

`Mp` stores a canonical signed BLIP integer. Arithmetic uses byte payloads,
with temporary scalar or SIMD register values between reads and writes.
Production division and Montgomery functions no longer accept, allocate or
cast to arrays of machine integers. Their buffers hold little-endian magnitude
bytes, sometimes zero-extended to reserve carry space. A 64-bit arithmetic step
reads eight bytes; that access width is not an auxiliary stored representation.

Every stored FFT coefficient, field residue and twiddle is independently BLIP
encoded. `src/fft_residue.zig` reserves five bytes for small-prime residues
and ten for full-u64 Goldilocks residues, so butterfly indexing
is constant-time in the algorithmic sense. This is not a cryptographic timing
claim. The first byte identifies the live encoding; unused capacity is ignored.

Examples for codecs storing the least nonnegative representative:

| Residue | Canonical bytes (hex) | Live bytes | Reserved bytes |
|---|---|---:|---:|
| 0 | `00` | 1 | 5 or 10 |
| 127 | `7f` | 1 | 5 or 10 |
| 128 | `82 80 00` | 3 | 5 or 10 |
| 2^63 | `89 00 00 00 00 00 00 00 80 00` | 10 | 10 |

The final zero in the last example is the signed representation's positive sign
extension. Fixed-capacity slots contain variable-length encodings; they are not
a densely packed BLIP stream. The initial migration reserved 16 bytes per
slot. Field-sized slots now reduce that capacity by 68.75% and 37.5%, respectively.
The small-field codec recognizes the common `84` header directly. Fused stages,
CRT reconstruction and inverse scaling avoid redundant encoding round trips
while their temporary values remain in registers. Zero initialization writes
only the immediate header byte for these reduced-value codecs. See the
[measurements](benchmarks/storage-aware/README.md).

Single-prime multiplication now chooses the representative `r+p` for
`p=998244353`. Its entire range `[p,2p)` requires four signed payload bytes,
so every stored value has header `84` and occupies all five bytes of its slot.
Field zero is the integer `p`, encoded `84 01 00 80 3b`. This satisfies ordinary
minimum-width BLIP rules without padding small integers to a larger width.
The algorithm keeps scalar and SIMD operands shifted and reduces back to
`[0,p)` when feeding output carry propagation. Initialization writes five bytes
per zero. The [scoped-residue measurements](benchmarks/shifted-residues/README.md)
include this cost; slot allocation capacity is unchanged.

`src/chunks.zig` serves magnitude-byte arithmetic; `src/fft_residue.zig` serves
encoded FFT values. FFT kernels never reinterpret their slots as integer arrays.
The public low-level FFT signatures now take byte slices whose lengths are
multiples of `fft.residue.slot_bytes`; callers must encode inputs through
`fft.residue.write`. These low-level transforms, including `nttRadix4Vec`, still
use reduced representatives. Scratch from single-prime `mulMagnitudes` and
`mulMagnitudesWithScratch` instead uses `fft.shifted_residue`; its reader
returns `r+p`. `mulMagnitudesScoped` exposes the three measured storage/arithmetic
modes explicitly. Do not interchange their scratch representations.
Goldilocks uses `fft.gold_residue` and its separate stride; CRT stays reduced.
The higher-level `Mp` and C APIs keep their existing shape.

Verification includes:

- An AST-based test rejects wide-integer arrays, allocator calls for those
  arrays and typed byte-array views in the migrated production modules. Its
  classifier is tested against sets of allowed and forbidden source snippets.
  This is a syntax guard, not a proof against arbitrary disguised storage.
- Residue tests compare canonical bytes with the independent `Mp` encoder at
  every positive signed-width boundary, including full-width Goldilocks values.
  Poisoned padding verifies that spare capacity does not affect decoding.
- Shifted-codec tests classify sets of invalid headers, widths and ranges.
  Scalar and SIMD operations are checked against a u128 modular oracle.
  Complete shifted products are checked against schoolbook arithmetic, with
  canonical scratch-byte checks, unaligned buffers, canaries, empty inputs,
  zero, sparse and carry-heavy cases through the 14,000-byte combined bound.
- Existing transform tests retain numerical fixtures through test-only adapters
  and compare outputs and canonical encodings. Wide-integer fixture arrays in
  tests and GMP's own representation are deliberately outside the core audit.
- The GMP integration test forces single-prime, CRT and Goldilocks products on
  seeded random and all-255 inputs at 7, 257, 4,096, 7,000, 16,385 and 100,000 bytes,
  selecting backends only within their supported bounds. The same products now
  also force recursive Toom-3, including 100,000-byte operands, and both shifted
  small-field variants. The full integration run makes 13,111 GMP comparisons.
- Additional tests cover Toom interpolation workspace, sparse coefficients,
  partial blocked products, signed public dispatch and output aliasing.
- Division tests cover unaligned storage, partial final chunks and normalization
  shifts. Allocation-failure injection verifies FFT cache growth and cleanup.

These checks establish correctness for the tested cases and make representation
regressions detectable. They do not establish a universal performance or memory
advantage over GMP.
