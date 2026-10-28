# Paired and fused Goldilocks transforms

This experiment follows the [blocked multiplication measurements](../storage-aware/RESEARCH.md).
It compares three layouts with the same Goldilocks field arithmetic and canonical
signed-BLIP residue codec. Production continues to select Stockham until measured
evidence supports a change.

| Layout | Forward output / inverse input | Transform storage |
|---|---|---|
| Stockham control | Natural order | Ping-pong residue buffers |
| Paired radix-2 | Bit-reversed order | In-place residues |
| Paired fused stages | Bit-reversed order | In-place residues, two stages per pass |

The paired forward transform uses decimation in frequency; its inverse uses
decimation in time. Their shared frequency permutation permits pointwise
multiplication without reordering. The inverse leaves the final multiplication
by `N^-1` to the existing carry/output pass.

For each group of four residues, fusion replaces two stages' eight encoded
reads and eight encoded writes with four reads and four writes. Intermediate
values remain temporary arithmetic scalars. Each stored output and twiddle
still uses the ordinary canonical variable-length BLIP encoding. A final
unpaired radix-2 stage handles odd stage counts. Register pressure and changed
access order could outweigh the saved codec work; that is a measurement question.

The experimental multiplication entry point accepts an empty Stockham scratch
slice for either paired layout. Its transform buffers require `3*N` ten-byte
slots, versus `4*N` for the control, including both twiddle tables. This describes
the workspace contract, not measured resident memory or a production allocation
change. SIMD work is deferred until the scalar layout comparison and generated
machine code establish the remaining bottleneck.

## Correctness controls

The first transform test failed against empty implementations before the
radix-2 pair passed. Fusion then passed the same independent direct-DFT oracle,
whose multiplication uses native `u128` remainder arithmetic. It checks both
directions separately at lengths 1 through 64, including odd/even stage counts,
zero, impulse, all-`p-1` and seeded random inputs. Each output is also compared
with `Mp`'s canonical encoding; unaligned buffers have boundary canaries.

The complete-product test failed against an empty adapter. Reusing the original
Stockham product code then exposed its one-point-transform bug: initialization
wrote a twiddle into a zero-length table. The regression now exercises that
case with all three layouts. No twiddles are written when `N == 1`.

GMP product controls cover one-byte operands, odd byte packing, unequal lengths,
carry-heavy all-255 values, sparse values and zero, with result/workspace
canaries. The existing forced-backend integration corpus also checks both new
layouts at balanced lengths 7, 257, 4096, 7000, 16385 and 100000 bytes with
random and all-255 inputs. Paired calls receive no permutation scratch.

The complete native suite, including 13,135 GMP comparisons, and the production
build passed in 100 seconds. Mixed Nix preparation/check time was 99 seconds.
Execution coverage is Linux x86_64; the new layouts remain experimental.

## Initial generated-code inspection

The ReleaseFast integration executable had SHA-256
`c3a932a15a8e1d6b9f00830b17a5c4fa69f6685277d3f1229656e9386614b704`.
Its paired radix-2 forward function occupied 676 bytes, versus 1946 bytes for
the fused version, which also contains its radix-2 fallback. Both use scalar
BMI2 multiplication; neither forward function contains packed SIMD arithmetic.
The fused function reserves another 128 stack bytes and includes stack reads
and writes within its butterfly code. The radix-2 function also uses stack
storage through the red zone. Static references are not dynamic spill counts.
This confirms that register pressure is a real concern, but establishes no
timing result. Inspect the final measurement binary as well.

## Next measurement

Measure complete products and isolated forward/inverse passes in ReleaseFast,
with Stockham, paired radix-2 and fused layouts in the same process. Preserve
full arithmetic checks, component CPU/wall timings, separate 1/12-CPU cohorts,
process variation and the shared engine's external history. Inspect the generated
code for scalar arithmetic, spills and vectorization before selecting a layout.
Neither pairing nor stage fusion is claimed as a new algorithm.

## Verified measurement adapter

Run `./bm --verified-goldilocks` through the shared measurement engine. The
configuration declares complete products and forward/inverse pairs as separate
cases, each with five processes in separate 1/12-CPU affinity cohorts. Product
sizes are balanced operand byte lengths; pass sizes are transform lengths.
Products include 65535, 65536 and 65537 bytes to cross a padding jump, and
100000 bytes to reach the existing production Goldilocks region.

Each process records six samples. A sample runs mirrored batches of the three
layouts, then rotates their roles in the next sample. Across six samples each
layout occupies outer, middle and central positions equally. Each component
reports CPU/wall nanoseconds per operation over two batches of two operations.
The primary engine sample averages the three components. Its variation gate
therefore does not replace inspection of each component and paired ratio.

Product timing includes packing, twiddle generation, all three transforms,
carry/output work and the full GMP-derived result comparison. GMP computes its
reference outside timing. Pass timing uses prepared twiddles and includes
restoring the input, a forward/inverse pair without final scaling, and checking
every canonical output against an independently computed `N*x mod p` value.
All layouts share prepared arena storage; allocation costs are not measured.

The adapter's initial stubs failed all five behavioral tests. Controls cover
input classification, mirrored/rotated batch order, linear drift cancellation,
error propagation, corruption rejection for every layout/mode, and cleanup at
every allocation failure. The command route and CLI report failed before their
implementations; their checks are included in `./test` and the CI manifest.

The final adapter passed the complete native suite and production build in
129 seconds, including 128 seconds of mixed Nix preparation/check time.
All-system evaluation passed. Its ReleaseFast probe had SHA-256
`e42c7707d90986d2b056372502f0890c819082ef3c9e9ab68c9cb01d84a91d0c`.
Forward function sizes matched the initial inspection. The paired radix-2
inverse occupied 620 bytes; the fused inverse occupied 2178 bytes and reserved
another 136 stack bytes, with stack traffic inside the transform. Neither
inverse function contained packed SIMD arithmetic. These are compiler-output
observations, not runtime instruction counts or performance results.
