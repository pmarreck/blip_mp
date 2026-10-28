# Truncated Montgomery carry bounds

This is a derivation checkpoint, not a measured optimization. The current
`tier3.montMul` first forms the full product and then cancels its low chunks
with word-at-a-time Montgomery reduction. Both phases read temporary native
chunks from magnitude byte buffers. It does not separately multiply by a
full-width inverse, so a truncated-product proposal must beat that existing
operation count.

The 2024 paper by Didier, El Mrabet, Glandus and Robert describes a truncated
reduction and batch AVX512 implementation. Its relevant observation is that
the canceled low part determines the carry into the retained high part.
Its batch SIMD timings do not predict this project's single-product timings.
See [the paper, Section 5](https://arxiv.org/html/2410.18129v1#S5).

## Reduction identity

Use an odd modulus `m<R`, `R=B^k`, and reduced operands `a,b<m`. Let `T=a*b`,
`q=(-T*m^-1) mod R`, and `L=T mod R`. The low part of `q*m` is zero when `L=0`
and `R-L` otherwise. Therefore

```
(T + q*m)/R = floor(T/R) + floor(q*m/R) + (L != 0).
```

The result is less than `2*m`, since `T<m*R` and `q<R`; one subtraction suffices.
This requires exact high multiplication. Discarding low partial products without
recovering their incoming carry is insufficient. The standard input bound and
single correction also appear in [FLINT's REDC description](https://fredrikj.net/fdoc/html/algorithms/arithmetic/montgomery.html#reduction).
No lazy-residue bound from a wider-radix implementation is assumed here.

## Exact high product with a known low part

The following derivation uses radix digits as mathematical notation. A future
implementation must keep magnitude byte buffers and temporary arithmetic
scalars, without introducing stored native-word arrays.

For two `k`-digit values `x,y`, retain every full partial product with `i+j>=k-1`
and the high halves of products with `i+j=k-2`. Express their sum as `U` in units
of `B^(k-1)`. Call the omitted nonnegative value `D`, so

```
x*y = B^(k-1)*U + D
c = floor(D/B^(k-1)).
```

For `k>=2`, bound each omitted low half by `B-1`, and each full product by
`(B-1)^2`. Summing the lower diagonals gives

```
D <= (k-2)*B^(k-1) + (k-1)*(B-2)*B^(k-2) + 1
D/B^(k-1) < 2*k-3.
```

When `2*k-3<=B`, this proves `0<=c<B`. If the top digit of the known low product
is `ell`, then `ell=(U+c) mod B`, uniquely determining

```
c = (ell - (U mod B)) mod B
floor(x*y/R) = floor((U+c)/B).
```

For Montgomery reduction, `x=q`, `y=m`, and the known low product is `(-L) mod R`.
The practical `B=2^64` chunk width satisfies the bound for every buffer length
addressable in 32/64-bit address spaces. The one-digit case uses its
ordinary native product and needs no omitted-diagonal construction.

The bound matters. With `B=2`, `k=4`, `x=y=15`, the construction has `U=26`,
`D=17`, and `c=2`. The known boundary digit is zero, so recovering `c` modulo
two incorrectly gives zero. It predicts a high product of 13 instead of 14.
This deliberately invalid small-radix case is a useful negative control for
future exhaustive tests.

## Cost and next implementation decision

A dense schoolbook full product uses `k^2` chunk multiplications. A low product
uses `k*(k+1)/2`; this exact high construction uses that same count plus `k-1`
boundary products. Including `T`, the proposed reduction therefore uses
`2*k^2+2*k-1` chunk products, plus full-width inverse preparation.

The existing code uses `k^2` products for `T`, `k^2` for cancellation and `k`
low-word factors: `2*k^2+k`. Thus the scalar schoolbook version has no product
count advantage here. Avoid assuming the paper's reduction savings apply to
this baseline. Subquadratic low/high products could change that comparison at
larger sizes, but require new kernels and their own measurements.

Before implementing a production candidate, profile the existing Montgomery
path by size. If a high-product prototype is warranted, first exhaust affordable
small radices with native full-product oracles, retain the invalid-bound negative
control above, check native-width carry boundaries against GMP, and verify
allocation/aliasing behavior. Measure conversion/precomputation separately from
repeated modular products. No Montgomery speedup or SIMD benefit is claimed.

## Verified public baseline and sampling

Campaign `blip-mp-powm-20261028T070827Z` measured commit
`c6f00e01510f6a5b85df82cbd11dbf518b0581b2` on the existing x86_64 Zen 2 host,
Zig 0.16.0 ReleaseFast and GMP 6.3.0. Source hash
`a7875990ec047b153d01ade309e6702cd75b0f73b2938b884b4158c9bbddfd3d`
stayed unchanged. All 15 processes verified their results. The one-CPU cohort
was `INCONCLUSIVE` after its allowed retry; the 12-CPU cohort was `UNBASELINED`.
No baseline epoch was approved.

| Nominal bits | Median process-mean CPU, 1 CPU | Median process-mean CPU, 12 CPUs |
|---:|---:|---:|
| 512 | 0.141 ms | 0.142 ms |
| 1024 | 0.797 ms | 0.797 ms |
| 2048 | 5.447 ms | 5.474 ms |
| 3072 | 17.153 ms | 17.128 ms |

These descriptive medians use the five final processes, each averaging five
complete 256-case passes. They differ from the engine's selected process and
do not override its verdict. The [summary](powm-baseline-summary.json) keeps
both representations, individual process means, source identity and verdicts;
full records, including the earlier attempt, remain in external history.
At 2048 bits, one final one-CPU process averaged 7.203 ms, illustrating the
variation. These are public BLIP-operation times with setup, allocation and
full result verification. GMP supplies correctness, not a timed competitor.

A separate Linux `perf record` diagnostic sampled user-space cycles at 99 Hz
while the original probe ran its 3072-bit workload on one CPU. It recorded
3268 samples with none reported lost. About 88.30% of weighted samples fell
in `tier3.montMul`, 4.43% in `memset`, and 4.46% in two GMP arithmetic routines.
The profile covers the whole process, including GMP reference preparation and
warmup; its percentages are not a breakdown of the probe's timed interval.
The original executable hash is recorded in the
[probe notes](../../plan_context/performance-follow-up.md#verified-modular-exponentiation-probe).

The next candidate reuses `squareMagnitudesU64` before the existing Montgomery
reduction. Sliding-window exponentiation currently sends every squaring through
general multiplication even though the symmetric product kernel already exists.
It reduces the product phase from `k^2` chunk products to `k*(k+1)/2`, with the
same reduction afterward. That count is a hypothesis for runtime improvement,
not a measured speedup. The isolated candidate first failed a new GMP test
against an empty implementation, then passed 288 cases across nine buffer
widths, four modulus patterns, four input patterns and both output-alias modes.
The corpus includes dirty scratch, unaligned buffers, zero/one values, dense
carry cases and canaries. Its complete native suite/build and all-system
evaluation passed before measurement; production remains unchanged.

The candidate's ReleaseFast executable had SHA-256
`8f6692d6899e610024d22c7f1bbe354bdb80cad9476016ab37060aeb212dc8ee`.
The symmetric product and Montgomery reduction compiled to scalar BMI2 `MULX`
and carry loops, occupying 428 and 427 bytes respectively. The wrapper and
general multiplication were inlined in this build. SIMD remains deferred while
the existing algorithmic saving is measured on the complete public operation.

## Separate-process result and paired follow-up

Campaign `blip-mp-powm-square-20261028T072227Z` measured the isolated candidate
tree based on `c6f00e0`, with source digest
`ae38a780e1a696df3d84b9b230572e45849ce935d2818113be2903c5570e40be`
unchanged throughout. All ten processes verified their results; both cohorts
were `UNBASELINED` after one attempt. The candidate changes the three Montgomery
squaring call sites and adds the symmetric primitive and its GMP tests. It
does not change the exponentiation window, input generators or measurement
method. The [summary](powm-square-summary.json) preserves process means.

| Nominal bits | Candidate/baseline median CPU, 1 CPU | Candidate/baseline median CPU, 12 CPUs |
|---:|---:|---:|
| 512 | 1.019 | 0.980 |
| 1024 | 1.010 | 0.914 |
| 2048 | 0.844 | 0.850 |
| 3072 | 0.861 | 0.861 |

These ratios divide medians of five final process means from separate
campaigns. They suggest savings at 2048/3072 bits, but the inconsistent smaller
results and the baseline's inconclusive cohort prevent choosing a cutoff from
this comparison alone. Production continues to use general Montgomery products.

The paired follow-up uses explicit `Mp.powm` and `Mp.powmSymmetric` entry points
in one executable. The latter retains the same validation, setup, sign and
aliasing behavior and changes only the Montgomery squaring primitive. Each
sample runs ABBA or BAAB half-pool batches, alternating order by round. Both
methods visit all 256 identical cases once per sample. Five samples keep each
method's CPU/wall components; the primary engine samples average both methods.
Each method receives a full warmup pass. This controls linear timing drift,
while nonlinear interference and code-layout effects can still matter.

Run `./bm --verified-powm --config profiling-powm-paired.json`. The method
`powm-paired-squaring-v1` and separate case names preserve the original workload
history. Its two affinity cohorts use five processes each and 180-second
per-process deadlines. Deterministic injected batches check order, case ranges,
normalization, drift cancellation and error propagation; they failed against
the empty adapter. The new argument form and CLI report also failed before
implementation. Both arithmetic paths retain GMP corruption and allocation
failure controls. No production squaring selection follows until measured.

The paired implementation passed the complete native suite with 13,231 GMP
comparisons in 96 seconds of mixed Nix preparation/check time. The production
build and all-system evaluation passed. The independent Montgomery-square
corpus adds 288 direct GMP cases in the unit suite; those are separate from
the integration comparison count. Production `Mp.powm` still uses the general
product, and the original single-method probe retains its measurement label.
