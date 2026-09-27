# Large-integer optimization research, September 27, 2026

BLIP storage can support the same arithmetic identities as other integer
representations. Whether it wins depends on the algorithm, operand shape,
compiler, allocation costs and machine. Canonical BLIP residues introduce
encoding work into FFT stores; the measurements must include that cost.
No new algorithm or discovery is claimed by this investigation.

## Gaps verified in this code

| Area | Current implementation | Established avenue to investigate |
|---|---|---|
| Balanced multiplication | Chunked schoolbook, Karatsuba, Toom-3; Toom-3's five products call Karatsuba | Recursive Toom-3, then Toom-4/6.5/8.5 where measurements justify them |
| Unbalanced multiplication | Several internal paths pad to equal length; public dispatch uses equal-length conditions for faster algorithms | Asymmetric Toom splits or blocked multiplication to avoid padding work |
| Squaring | A symmetry-aware basecase exists; large products largely share multiplication machinery | Dedicated recursive squaring and independent crossover thresholds |
| Division | Reciprocal-assisted Knuth D, byte-based Burnikel–Ziegler implementation | Block-wise Barrett with reciprocal reuse; benchmark before changing dispatch |
| Modular exponentiation | Montgomery reduction and sliding windows, with a quadratic multiply/reduce kernel | Truncated products, faster large-modulus reduction and reusable modulus setup |
| Inverse/GCD | Lehmer and recursive HGCD implementations already exist | Profile dispatch and matrix-product costs; HGCD is not a missing algorithm |

The source evidence is in `src/tier3.zig` (`mulToom3`, `mulKaratsuba`,
`mulMagnitudesAuto`, `montMul`, division helpers) and `src/bignum.zig`
(`powmMontgomery`, inverse dispatch). GMP documents its size-dependent
multiplication ladder and separate squaring thresholds, including higher-order
Toom and asymmetric multiplication. Its division menu includes Barrett and
special exact-division paths. These are established techniques, not prospective
BLIP discoveries. [GMP multiplication](https://gmplib.org/manual/Multiplication-Algorithms),
[GMP division](https://gmplib.org/manual/Division-Algorithms),
[GMP exact division](https://gmplib.org/manual/Exact-Division).

The current FFT thresholds also need careful description. Single-prime and CRT
thresholds are 99,999 bytes per operand, outside their respective allowed
combined lengths of 14,000 and 65,536 bytes. Those dispatch conditions cannot
fire. Goldilocks has the same threshold but allows 524,288 combined bytes, so
it remains reachable for sufficiently large equal-length inputs. A blanket
claim that every FFT backend is disabled is incorrect. This migration preserves
those choices and tests the backends directly.

## SIMD already exists

This project has two-lane vector butterflies, Stockham variants, unrolling,
Montgomery field arithmetic and radix-4 transforms. Those names identify source
algorithms; the emitted instructions and measured speed depend on the target.
A vector datatype alone does not establish a speedup.

FLINT's small-prime FFT implementation requires AVX2 or NEON. That is directly
relevant to independent modular residues in a transform. GMP's SIMD discussion
explains why ordinary multi-precision carry propagation offers fewer independent
lanes than signal-processing workloads.
[FLINT fft_small documentation](https://flintlib.org/doc/fft_small.html),
[GMP SIMD instructions](https://gmplib.org/manual/Assembly-SIMD-Instructions).

Didier, Mrabet, Glandus and Robert (2024) combine truncated multiplication with
AVX-512 VPMADD52 in batches of eight modular operations. They report roughly
20% improvement from their truncation technique over their non-truncated
implementation. Batch throughput and single-integer latency are different
experiments. Their word-sliced stored representation would also violate this
project's constraint if adopted verbatim. The September test host is a Zen 2
Threadripper 3990X with AVX2 and no AVX-512; that instruction-specific result
cannot be tested here.
[Paper and abstract](https://arxiv.org/abs/2410.18129).

Harvey and van der Hoeven proved an O(n log n) bit-complexity multiplication
algorithm, published in 2021. That theorem alone supplies neither a crossover
for this library nor a claim of practical speed at the sizes in its benchmarks.
[Original paper](https://annals.math.princeton.edu/2021/193-2/p04).

## Experiments worth running next

1. **Recursive Toom-3 and asymmetric products.** These address verified
   algorithm gaps without changing the representation. Compare full Mp.mul
   at equal and unequal lengths, including sizes immediately around each
   threshold. Include squaring and all-255 carry-heavy inputs. Reject dispatch
   changes whose wins disappear in repeated runs.
2. **Fuse FFT stages while values remain in registers.** Decode each BLIP
   residue once for a radix-4 or larger local butterfly, then encode each
   output once. Every stored intermediate still obeys BDFN (Benevolent Dictator For Now)'s constraint.
   Radix-4 already exists here, so stage fusion itself is not novel. The
   research question is how much encoding work can be removed without
   increasing register spills or instruction count. Check generated machine
   code and measure full multiplication as well as isolated passes.
3. **Pack BLIP residue slots more tightly.** Current slots reserve 16 bytes
   for encodings of 1–10 bytes. Prime-specific capacities of 5 or 10 bytes,
   or small blocks with offsets, could reduce cache traffic. This is an
   untested layout hypothesis. Benchmark decoding, writes, scratch footprint
   and end-to-end multiplication; random access must still be efficient.
4. **Exploit zeros before a transform becomes dense.** Immediate BLIP zero
   is cheap to identify. Test skipping zero-heavy initial butterflies or
   using a truncated transform when padding is substantial. Truncated FFTs
   are established; a BLIP-aware dispatch policy is a candidate experiment,
   not an established novelty. Include dense random inputs as a negative
   control so sparse wins do not conceal regressions.
5. **Truncated Montgomery work.** Derive which high/low products are needed
   for this reduction and prove carry bounds before omitting them. Compare
   with GMP on odd moduli around byte and chunk boundaries. Keep all saved
   values in byte payloads and any FFT subroutine residues in BLIP.

The potentially distinctive work is the combination of canonical variable-length
residues, register-local stage fusion and layouts tailored to their encoded
lengths. This search does not establish that combination as new. A credible
novelty claim would require a closer prior-art search and a reproducible result.

GMP without assembly remains a useful second comparison, but it does not isolate
the storage representation: algorithm selection, compiler and allocation behavior
also differ. An ablation within the same implementation would be needed to
attribute a speed difference specifically to BLIP.
