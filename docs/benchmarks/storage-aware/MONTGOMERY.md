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
