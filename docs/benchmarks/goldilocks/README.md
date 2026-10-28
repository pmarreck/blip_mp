# Paired and fused Goldilocks transforms

## Centered storage experiment

For the Goldilocks prime `p = 2^64 - 2^32 + 1`, each field element has a unique
representative in `[-floor(p/2), floor(p/2)]`. Store `r` when `r <= p/2` and
`r-p` otherwise. Both endpoints fit in signed 64 bits, so their canonical BLIP
encodings need at most eight payload bytes plus one header byte. The positive
codec sometimes needs a ninth payload byte for sign extension.

The experimental centered codec therefore reserves nine bytes per slot rather
than ten. The representation stays variable length, zero remains an immediate,
and every stored integer represents the same field element modulo `p`. Reading
a negative representative adds `p` before the existing unsigned field arithmetic.
This differs from biasing every value by a constant, which would change its
residue. No new BLIP symbol or format rule is needed.

The hypothesis is that 10% less residue capacity and fewer sign-extension writes
can outweigh the sign conversion on each read/write. Nine-byte stride alignment
and extra conversion instructions may instead make it slower. Qualification
starts with independent signed-BLIP and DFT checks, then compares complete fused
products with the existing positive codec in the same executable. Production
keeps the positive codec until measurements support a change. Allocated capacity
alone does not establish a resident-memory or runtime improvement.

The codec passed 10,050 independently constructed signed values with both round
trips, all signed payload boundaries, poisoned capacity and unaligned canaries.
The direct DFT corpus now checks both codecs, both directions and fused/unfused
stages at lengths 1–64. Forty additional centered products match GMP across
packing, zero, dense-carry and one-point-transform boundaries. The codec,
transform and product tests each failed against their empty implementations.

Run `./bm --verified-goldilocks --config profiling-centered.json` for complete
products at 1024, 16384, 65536, 100000, 131072 and 262144 bytes per operand.
The `gold-centered-products-v1` mode compares positive radix-2, positive fused
and centered fused products using rotating ABCCBA batches. Each sample retains
all three CPU/wall components; compare centered fused with positive fused to
isolate storage. Packing, twiddle preparation, transforms, carry output and
GMP-derived byte verification are timed. Prepared scratch allocations are not.
Each affinity cohort uses five processes, six samples per process, two products
per batch and a 120-second process deadline. No historical baseline is approved.

The new parser mode first failed its test. Fixture corruption and allocation
failure controls cover the new mode, and the CLI verifies component names,
positive samples and normalization. The complete native suite passed in 100
seconds of mixed Nix preparation/check time, with 15,535 integration GMP
comparisons unchanged. Production build and all-system evaluation passed.

### Centered result

Campaign `blip-mp-centered-20261028T085038Z` measured commit
`5e26e9d17cf9d7b05140c4812a723ce52c50165a`, with source hash
`9d09e185050a5dca187d6ca169ec9c18ad272acec909997274f9c0a5e8c8be6d`
unchanged. All ten processes verified their products. Both affinity cohorts
were `UNBASELINED` after one attempt, with no approved baseline epoch.

| Operand bytes | Centered/positive fused CPU, 1 CPU | Centered/positive fused CPU, 12 CPUs |
|---:|---:|---:|
| 1024 | 1.377 | 1.378 |
| 16384 | 1.413 | 1.410 |
| 65536 | 1.413 | 1.413 |
| 100000 | 1.424 | 1.422 |
| 131072 | 1.425 | 1.425 |
| 262144 | 1.397 | 1.413 |

These are medians of 30 paired sample ratios per size and cohort. Every process
mean was slower with centered storage. The [summary](centered-summary.json)
retains process ratios, sample ranges, selected CPU/wall components and verdicts.
The 10% smaller slot capacity did not compensate for roughly 38–43% more CPU
time in these complete products. Production retains positive representatives.

The measured executable had SHA-256
`f1df5875dccc0103281e134fe38fe5e0d8350c944fa05187da4688913c037160`.
Its centered fused forward transform occupied 2195 bytes, versus 1946 bytes
for the positive codec. The centered reader emitted variable `SHLX`/`SARX`
sign-extension instructions even for eight-byte payloads, followed by a
sign-mask/add sequence to recover the unsigned field value. Function entry
reserved 152 stack bytes versus 128; both also accessed red-zone storage.
These static observations do not measure dynamic spills or attribute the
entire timing difference to a particular instruction.

The bounded follow-up adds a direct `0x88` header check before variable-length
sign extension. Short canonical encodings retain the existing decoder. Its
`centered_fast` probe mode compares positive fused, original centered fused and
the common-header variant on identical inputs. Run
`./bm --verified-goldilocks --config profiling-centered-fast.json`; it uses
the same sizes, process/sample counts and deadlines with a distinct
`gold-centered-common-header-v1` definition. This tests decoding cost; production
storage remains unchanged.

Both centered readers pass the same 10,050 canonical encoding and round-trip
cases each. The independent DFT and GMP product corpora cover the new reader,
and the new probe mode first failed its parser test. Full native tests passed
in 136 seconds of mixed Nix preparation/check time, including 15,535 integration
GMP comparisons. Production build and all-system evaluation also passed.

## Existing layout measurements

This experiment follows the [blocked multiplication measurements](../storage-aware/RESEARCH.md).
It compares three layouts with the same Goldilocks field arithmetic and canonical
signed-BLIP residue codec. The October 28 comparison supports selecting the fused
layout at the existing production threshold; Stockham remains a measurement control.

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
the workspace contract. Production now omits the permutation allocation as well;
resident memory and cold allocation time have not been measured. SIMD work is deferred until the scalar layout comparison and generated
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
Execution coverage is Linux x86_64; this was the initial experimental implementation.

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

## Measurement requirements

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

## October 28 result and production selection

Campaign `blip-mp-gold-layouts-20261028T051646Z-` measured commit
`5ac7a7ad4699c81d2892ae684653e7a433719371`. Its source hash stayed
`9bf3382d1a351958d66c7e42cc16f0e8665db4ef2a20266901143b78953c6353`
throughout. The host used a Ryzen Threadripper 3990X, Linux 6.18, Zig 0.16.0
ReleaseFast and GMP 6.3.0. The shared engine was pinned to
`ecf713b81a74a51f76719bf9debc44fe23a0b331`. Admission took about 14 minutes;
the admitted campaign ran about 119 seconds. No host settings changed.

All 30 processes, including two five-process retries, verified their results.
Both product cohorts and the one-CPU pass cohort were `UNBASELINED`: no accepted
historical baseline exists. The 12-CPU pass cohort remained `INCONCLUSIVE` for
sample variation after its single allowed retry. These are within-process
layout comparisons, not green historical performance gates.

| Operand bytes each | Fused CPU reduction, 1 CPU | Fused CPU reduction, 12 CPUs |
|---:|---:|---:|
| 1024 | 24.7% | 24.6% |
| 4096 | 23.9% | 24.0% |
| 16384 | 23.8% | 23.8% |
| 65535 | 24.0% | 24.1% |
| 65536 | 24.2% | 24.1% |
| 65537 | 22.7% | 22.7% |
| 100000 | 22.8% | 22.8% |

Each table cell uses the median of 30 paired sample ratios from the final
five-process attempt (the upper middle value for this even sample count).
Every complete-product process mean favored fusion, including the retained
retry attempt: the fused/Stockham ratios ranged from 0.664 to 0.816 across
105 size/process observations. Paired radix-2 alone saved roughly 7–8% at the
median, with one final-attempt process/size regression. The
[summary records](layout-summary.jsonl) preserve component CPU/wall means,
sample ratios, final-attempt process ratios and verdicts. Full attempts remain
in the configured external performance history.

The one-CPU isolated pass medians favored fusion by 22–24%. The inconclusive
12-CPU pass result remains a limitation; it is not evidence for a historical
gate pass. Complete-product evidence supports selecting fusion while retaining
the 99999-byte threshold and all existing eligibility conditions. This does
not establish a new crossover against Toom, a full public-call speedup, or a
GMP timing win. GMP supplies correctness references outside the timed region.

Production scratch now allocates four buffers totaling `3*N` ten-byte slots,
down from five buffers totaling `4*N`. The allocation test first failed with
five allocations, then checks exact capacity, reuse, growth and idempotent
release. Allocation-failure controls cover both cache types. Public GMP checks
use exact 99998-, 99999- and 100000-byte payloads, all four sign combinations
and both operand-alias positions. The encoded-residue representation is unchanged.

The final complete native suite passed in 98 seconds of mixed Nix preparation
and checking, with 13,159 GMP comparisons. The production build and all-system
evaluation also passed. This is executed Linux x86_64 coverage; evaluation alone
does not establish runtime coverage on other platforms. The suite's previously
recorded five-second execution target remains unmet.

The next experiment is an [input/output-truncated transform](TRUNCATED.md) that
uses known zero coefficients to skip work around padding boundaries.
