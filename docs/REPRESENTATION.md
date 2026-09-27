# Arithmetic storage after the September 2026 migration

`Mp` stores a canonical signed BLIP integer. Arithmetic uses byte payloads,
with temporary scalar or SIMD register values between reads and writes.
Production division and Montgomery functions no longer accept, allocate or
cast to arrays of machine integers. Their buffers hold little-endian magnitude
bytes, sometimes zero-extended to reserve carry space. A 64-bit arithmetic step
reads eight bytes; that access width is not an auxiliary stored representation.

Every stored FFT coefficient, field residue and twiddle is independently BLIP
encoded. `src/fft_residue.zig` reserves 16 bytes per slot so butterfly indexing
is constant-time in the algorithmic sense. This is not a cryptographic timing
claim. The first byte identifies the live encoding; unused capacity is ignored.

| Residue | Canonical bytes (hex) | Live bytes | Reserved bytes |
|---|---|---:|---:|
| 0 | `00` | 1 | 16 |
| 127 | `7f` | 1 | 16 |
| 128 | `82 80 00` | 3 | 16 |
| 2^63 | `89 00 00 00 00 00 00 00 80 00` | 10 | 16 |

The final zero in the last example is the signed representation's positive sign
extension. Fixed-capacity slots contain variable-length encodings; they are not
a densely packed BLIP stream. Capacity doubled from the former eight-byte
residue arrays, and every butterfly store now encodes its result. The benchmark
report includes that cost. Packing slots more tightly remains an experiment.

`src/chunks.zig` serves magnitude-byte arithmetic; `src/fft_residue.zig` serves
encoded FFT values. FFT kernels never reinterpret their slots as integer arrays.
The public low-level FFT signatures now take byte slices whose lengths are
multiples of `fft.residue.slot_bytes`; callers must encode inputs through
`fft.residue.write`. The higher-level `Mp` and C APIs keep their existing shape.

Verification includes:

- An AST-based test rejects wide-integer arrays, allocator calls for those
  arrays and typed byte-array views in the migrated production modules. Its
  classifier is tested against sets of allowed and forbidden source snippets.
  This is a syntax guard, not a proof against arbitrary disguised storage.
- Residue tests compare canonical bytes with the independent `Mp` encoder at
  every positive signed-width boundary, including full-width Goldilocks values.
  Poisoned padding verifies that spare capacity does not affect decoding.
- Existing transform tests retain numerical fixtures through test-only adapters
  and compare outputs and canonical encodings. Wide-integer fixture arrays in
  tests and GMP's own representation are deliberately outside the core audit.
- The GMP integration test forces single-prime, CRT and Goldilocks products on
  seeded random and all-255 inputs at 7, 257, 4,096, 16,385 and 100,000 bytes,
  selecting backends only within their supported bounds.
- Division tests cover unaligned storage, partial final chunks and normalization
  shifts. Allocation-failure injection verifies FFT cache growth and cleanup.

These checks establish correctness for the tested cases and make representation
regressions detectable. They do not establish a universal performance or memory
advantage over GMP.
