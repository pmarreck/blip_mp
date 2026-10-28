# Input/output-truncated Goldilocks experiment

This experiment follows the fused transform comparison. It keeps every stored
residue and twiddle in canonical BLIP form, but avoids transform work on known
zero inputs and unneeded frequency outputs. Truncated Fourier transforms are
established algorithms: see [van der Hoeven's original work](https://www.texmacs.org/joris/issac04/issac04.html),
[Harvey's cache-friendly formulation](https://arxiv.org/html/0810.3203), and
[Harvey and Roche's in-place algorithms](https://arxiv.org/abs/1001.5272).
The implementation below uses a directly derived binary recurrence. It is
experimental until complete-product measurements justify selection.

## Representation and recurrence

The forward transform receives an `N`-slot buffer whose possibly nonzero prefix
has length `z`, and produces the first `t` frequency values in bit-reversed
order. With `h=N/2`, each butterfly computes `u=a+b` and `v=(a-b)*w`.
Both child inputs have possibly nonzero prefix `min(z,h)`. The left child needs
`min(t,h)` outputs; the right child is visited only when `t>h`. Zero input pairs
need no decoding or writes, and an absent upper input is a scalar zero.

The inverse has a mixed contract: its first `t` entries contain frequency values,
and its remaining entries contain known `N*x` coefficients. It recovers `N*x`
throughout, including preservation of the known suffix. This contract supports
an independent oracle rather than depending on a forward/inverse round trip.

When `t<=h`, the lower known tail becomes `(N*a+N*b)/2 = h*u`. After recursively
inverting the left child, `2*(h*u)-N*b` recovers the lower `N*a` coefficients.
The upper half stays unchanged. Division by two in the odd field uses
`(x>>1) + (x odd ? (p+1)/2 : 0)`, which remains below `p` without overflow.

When `t>h`, invert the full left child to obtain `h*u`. For the right known tail,
`(h*u-N*b)*w = h*v`. Invert that mixed right child, multiply by `w^-1`, and use
sum/difference butterflies to recover both `N*a` and `N*b`. Recursion ends at
one slot or zero requested outputs. Its stack holds indexing metadata and
temporary arithmetic scalars; all persistent numeric arrays are BLIP bytes.

For multiplication, packing gives `da=ceil(a.bytes/2)` and `db=ceil(b.bytes/2)`.
There are `da+db-1` potentially nonzero convolution coefficients. Choose the
next power of two at least that count, request that many forward outputs, and
multiply only those frequency pairs. Clear the remaining result slots before
the inverse because their known coefficients are zero. The existing inverse
scaling and carry pass completes the product. The output is initialized to zero
because the shorter transform can leave up to two result bytes unwritten when
no carry remains. No Stockham permutation buffer is required.

## Independent controls

Empty transform implementations first failed the direct-DFT tests. The forward
implementation then passed while the still-empty inverse failed separately.
The final small-transform corpus contains 44,733 forward cases and 1,635 mixed
inverse cases across lengths 1, 2, 4, 8, 16 and 32. It exhausts every input/output
prefix length, with zero, all-`p-1`, seeded random and every impulse position.
The oracle uses native `u128` remainder arithmetic, independently constructs
DFTs, and checks canonical encoded results and unaligned buffer canaries.
Inverse inputs come directly from that oracle with arbitrary known nonzero
coefficient tails. A diagnostic run measured about 39 ms for this corpus.

The complete-product adapter also failed against its empty implementation.
GMP controls cover odd/even byte packing, one-slot transforms, padding boundaries,
unequal lengths, carry-heavy all-255 inputs, sparse inputs and zero. The retained
Stockham, paired radix-2 and fused implementations remain comparison controls.
The forced-backend corpus adds balanced random and all-255 products at 7, 257,
4096, 7000, 16385 and 100000 bytes. The complete native suite passed with 13,171
GMP comparisons in 108 seconds of mixed Nix preparation/check time; the
production build also passed. Runtime coverage here is Linux x86_64.

At the combined input cap, each coefficient is bounded by
`131072 * 65535^2 < 2^49`, safely below the Goldilocks modulus. The inverse
therefore recovers the integer convolution without modular wraparound. Timing
and production selection remain separate steps; production still uses fusion.
