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

## Measurement method

Run `./bm --verified-truncated` for the separate `gold-truncated-products-v1`
history cohort. It compares Stockham, fused and truncated complete products in
the same process using six rotating mirrored batches. Every timed product is
compared in full with a GMP reference prepared outside timing. CPU and wall
components remain separate; the engine's primary value averages all three.
The original `gold-paired-layouts-v1` mode and its component meanings are retained.

The configuration uses five processes in each of the 1-CPU and 12-CPU affinity
cohorts. Balanced operand lengths are 1024, 1025, 1537, 4096, 4097, 6145, 16384,
16385, 65535, 65536, 65537, 98305 and 100000 bytes. These include nearly full
transforms, lengths just above padding jumps, and intermediate fill ratios.
Allocation is outside timing. Result restoration, packing, twiddle generation,
transforms, carry output and result verification remain inside timing.

Before implementation, the new mode failed parsing/fixture/allocation-cleanup
tests, and the new shell route failed its CLI check. All modes retain bounded
input classifiers, injected batch-order/error controls, corrupted-reference
rejection and allocation-failure cleanup. The complete entry point and CI run
the extended CLI schema checks, including preserved original method labels.

The extended adapter passed the complete native suite in 106 seconds of mixed
Nix preparation/check time, plus the production build and all-system evaluation.
SIMD work remains deferred while the measured question is whether pruning
outweighs recursive control and lost stage fusion. The existing fused control
uses scalar BMI2 multiplication; no vectorization benefit is assumed here.

## First complete-product result

Campaign `blip-mp-truncated-20261028T060552Z` measured commit
`a62962387f03bf26faed0c4d5120eb75830f8a6a` on the same Ryzen Threadripper 3990X,
Linux 6.18, Zig 0.16.0 ReleaseFast and GMP 6.3.0 configuration as the fused
comparison. The source hash stayed
`4fddce8029f209f3b07210d280541492bae87d592c00471442353052f21f3d0a`.
All ten processes verified their products. Both affinity cohorts were
`UNBASELINED` after one attempt; no historical baseline has been approved.

| Bytes per operand | Truncated/fused CPU ratio, 1 CPU | Truncated/fused CPU ratio, 12 CPUs |
|---:|---:|---:|
| 1024 | 1.446 | 1.447 |
| 1025 | 0.855 | 0.852 |
| 1537 | 1.176 | 1.173 |
| 4096 | 1.433 | 1.429 |
| 4097 | 0.825 | 0.824 |
| 6145 | 1.144 | 1.143 |
| 16384 | 1.418 | 1.422 |
| 16385 | 0.808 | 0.804 |
| 65535 | 1.414 | 1.406 |
| 65536 | 1.412 | 1.411 |
| 65537 | 0.786 | 0.783 |
| 98305 | 1.113 | 1.110 |
| 100000 | 1.124 | 1.126 |

Ratios below one favor truncation. Each cell is the upper median of 30 paired
sample ratios across the five processes. Every process mean agreed on the
direction of the result at each size. The [summary](truncated-summary.jsonl)
also preserves comparisons with Stockham, CPU/wall component means and process
ratios. Full records remain in external performance history.

Just above the sampled padding jumps, truncation saved 15–22% CPU time versus
fusion. Nearly full transforms lost roughly 41–45%; intermediate fill ratios
also lost, including 12–13% at 100000 bytes. Keep fusion in production. The next
candidate should prune partial regions while using fused passes for complete
subtrees; its correctness and cost need separate verification.

The successful campaign waited roughly six minutes for admission. An earlier
launch completed measurement but saved no records because a trailing separator
in the supplied run identifier produced an invalid history ID. The corrected
launch retained the same source/settings; it is not a selected timing retry.

## Fused complete subtrees

The next candidate keeps the same partial-region recurrence. When a forward
subtree has all inputs and outputs present, or an inverse subtree requests all
outputs, it calls the fused kernel. Strided twiddle reads share the original
canonical-BLIP table without copying or creating a native-word array. The full
transform control is compiled separately with unit stride, so it does not pay
for the new dynamic stride multiplication.

Empty candidate transforms and products first failed the independent oracles.
Both recursive and fused-subtree variants now run through the complete small
DFT/mixed-inverse corpus, totaling 92,736 cases. GMP packing/carry/canary controls
include both variants, and the forced-backend integration corpus adds the new
product at every existing Goldilocks size. Production dispatch is unchanged.

`./bm --verified-hybrid` compares full fusion, recursive truncation and fused
subtrees in the same rotating mirrored batches. Its separate history method is
`gold-hybrid-products-v1`; original modes retain their labels and meaning. The
same padding-boundary sizes are extended with 131071, 131072 and 131073 bytes
to cover another jump above the production threshold. Each process has an
explicit 60-second deadline for this expanded sweep. The new mode and shell
route first failed their existing behavioral/CLI controls before implementation.

The complete native suite passed with 13,183 GMP comparisons in 100 seconds of
mixed Nix preparation/check time. The production build and all-system evaluation
passed. The ReleaseFast probe had SHA-256
`c3ff2b4e390efbe4a164b3aea18ccb45a1a50a23fac7be6e53a3bfe712360567`.
The full fused forward/inverse functions retained their 1946/2178-byte sizes.
Forward disassembly differed in the operands of a register move/multiply pair,
so this is not a claim of identical machine bytes. SIMD work remains deferred
while the combined scalar layout is measured.

## Combined-layout result and crossover follow-up

Campaign `blip-mp-hybrid-20261028T063128Z` measured commit
`a8d5e953847c3f9410e8ac682320a208b0992daa` with the same host/toolchain.
Its source hash stayed
`100bcff3a0fc2245f01db54c86f3213c97fbf62c083a8ef823a46665acf39dde`.
All 15 processes verified their products. The one-CPU cohort remained
`INCONCLUSIVE` for sample variation after its allowed retry; the 12-CPU cohort
was `UNBASELINED` after one attempt. Neither is a passed historical gate.

| Bytes per operand | Combined/full-fused CPU ratio, 1 CPU | Combined/full-fused CPU ratio, 12 CPUs |
|---:|---:|---:|
| 1024 | 1.079 | 1.080 |
| 1025 | 0.661 | 0.662 |
| 4096 | 1.058 | 1.058 |
| 4097 | 0.635 | 0.634 |
| 16384 | 1.048 | 1.051 |
| 16385 | 0.620 | 0.617 |
| 65536 | 1.044 | 1.042 |
| 65537 | 0.607 | 0.603 |
| 98305 | 0.837 | 0.839 |
| 100000 | 0.848 | 0.845 |
| 131071 | 1.020 | 1.020 |
| 131072 | 1.024 | 1.019 |
| 131073 | 0.602 | 0.604 |

These are upper medians of the final five processes' 30 paired sample ratios.
The [complete summary](hybrid-summary.jsonl) retains all 16 sizes, component
CPU/wall means and process ratios. At 100000 bytes, every process mean favored
the combined layout, including the earlier attempt: ratios ranged from 0.795
to 0.942. At 131073 bytes that range was 0.570–0.625. Nearly full transforms
still lost at the median. This supports testing a fill-ratio dispatch rather
than selecting the combined layout for every size.

The next sweep uses `profiling-hybrid-boundary.json` through
`./bm --verified-hybrid --config profiling-hybrid-boundary.json`. It samples
three-quarter through nearly-full transforms at two lengths, including both
sides of seven-eighths occupancy. That threshold is a hypothesis to test, not
an accepted crossover. The separate boundary cases use 120-second per-process
deadlines for their larger operands. The original inconclusive result stays
in history; the new sweep answers a different dispatch question.

## Occupancy dispatch

Campaign `blip-mp-hybrid-boundary-20261028T064355Z` measured commit
`3644b1f89d1e62025943a6c5ae6f8c986795a55a`. Its source hash stayed
`4e5e3beade4bbc2fc5b02dab667bb0ab7a195c5f583a8fa29a72ddbe10b5800f`.
All 15 processes verified their products. The one-CPU cohort was again
`INCONCLUSIVE` after its allowed retry; the 12-CPU cohort was `UNBASELINED`.
The campaign waited about two and a half minutes for admission and ran for
about eleven minutes. Neither cohort passes a historical performance gate.

| Bytes per operand | Combined/full-fused CPU ratio, 1 CPU | Combined/full-fused CPU ratio, 12 CPUs |
|---:|---:|---:|
| 100000 | 0.846 | 0.844 |
| 106496 | 0.876 | 0.878 |
| 114688 | 0.927 | 0.926 |
| 114689 | 0.945 | 0.949 |
| 122880 | 0.981 | 0.985 |
| 126976 | 1.016 | 1.016 |
| 131073 | 0.605 | 0.596 |
| 196608 | 0.813 | 0.809 |
| 212992 | 0.887 | 0.881 |
| 229376 | 0.929 | 0.929 |
| 229377 | 0.942 | 0.952 |
| 245760 | 0.989 | 0.998 |

Each ratio is the upper median of 30 paired samples in the final five
processes. The [complete boundary summary](hybrid-boundary-summary.jsonl)
retains all 16 sizes and all three method comparisons. At fifteen-sixteenths
occupancy, individual process means crossed one. Seven-eighths retains a
larger margin, so it is a conservative selection point rather than a claim
of the exact optimum.

Across all attempts, the 100000-byte process-mean ratios ranged from 0.838 to
0.965; at 114688 bytes they ranged from 0.836 to 0.976. At 229376 bytes one
process in the earlier inconclusive attempt reached 1.009, while the final
cohorts' medians were both 0.929. The cutoff is supported by repeated median
gains, not a guarantee that every process wins.

Production selects fused-subtree truncation when the convolution coefficient
count is at most seven-eighths of the transform length, within the measured
131072- and 262144-point transforms. The existing 99999-byte Goldilocks entry
threshold remains. Other sizes use full fusion. With equal-length operands,
this selects payload widths 99999–114688 and 131073–229376 bytes. The coefficient
count is `2*ceil(width/2)-1`, which matters at odd/even boundaries.

This is a layout choice inside the existing Goldilocks backend. It establishes
no new crossover against Toom, another FFT backend or GMP, and no measured
benefit on other architectures. Larger transforms retain their existing path.

The dispatch classifier first failed with the full-fusion-only implementation.
It now exhausts 424,292 payload widths against independently listed selection
intervals. Public GMP checks cover both signs and both operand-alias orders at
nine boundary widths, including transitions back to full fusion. The complete
native suite passed with 13,231 GMP comparisons in 89 seconds of mixed Nix
preparation/check time; this is not a test-execution-only duration.
