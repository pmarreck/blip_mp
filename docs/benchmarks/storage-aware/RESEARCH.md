# First multiplication research experiments

These follow the canonical-residue FFT changes in `119dba3`. Same Linux
Threadripper host and Zig 0.16.0 ReleaseFast configuration as the
[FFT experiment](README.md). Three alternating runs compare corrected flat
Toom-3, recursive Toom-3, and recursion plus blocked asymmetric dispatch.
Raw files are `research-{1,2,3}-{flat,recursive,final}.txt`;
[research-summary.jsonl](research-summary.jsonl) retains ranges and CPU medians.

## Correctness findings before optimization

A new ReleaseSafe test across Toom thresholds failed in the existing
interpolation code. `c1` can need roughly twice an evaluation operand's width,
but its destination was a single evaluation slice. ReleaseFast omitted the
bounds check and could write into adjacent dead evaluation capacity. A second
problem used a fixed 16 KiB temporary, then fell back to overwriting `v_inf`
while that coefficient was still needed for composition.

Both are fixed by reusing dead evaluation storage as explicitly sized,
nonoverlapping product-width regions. This removes the fixed-size temporary.
The scratch-size guarantee is unchanged. The flat benchmark baseline includes
these two fixes, so their effect is not credited to recursion.

The blocked-product test subsequently failed on a one-byte final block padded
to 2048 bytes. Toom's signed evaluation compared a zero-padded middle coefficient
using its nominal slice length. Trimming its significant length before that
comparison fixes the wrong sign decision. Tests now cover dense random inputs,
all-255 values, sparse and zero operands, exact scratch bounds, reversed operands,
and public signed/aliased multiplication against GMP.

## Initial candidate (superseded by crossover tuning below)

Median nanoseconds. Balanced rows use the same byte count for both operands;
asymmetric rows use the stated pair. CPU is process CPU time, including timer
overhead. Wall time is monotonic elapsed time.

| Product | Flat wall | Recursive wall | Final wall | Final CPU | Wall change |
|---|---:|---:|---:|---:|---:|
| 512 × 512 | 3790 | 3795 | 3845 | 4316 | +1.5% |
| 4096 × 4096 | 144126 | 143874 | 145314 | 144903 | +0.8% |
| 8192 × 8192 | 433100 | 432982 | 437973 | 435510 | +1.1% |
| 32768 × 32768 | 3966931 | 3004126 | 2994195 | 2973588 | -24.5% |
| 512 × 256, Mp | 2239 | 2188 | 2210 | 2707 | -1.3% |
| 4096 × 2048, Mp | 125333 | 123841 | 100230 | 100189 | -20.0% |
| 8192 × 4096, Mp | 477517 | 475979 | 296162 | 295047 | -38.0% |
| 32768 × 16384, Mp | 7775807 | 7870973 | 2519113 | 2502624 | -67.6% |

ATTENTION: this superseded candidate improved the largest balanced product
24.5% and sampled eligible asymmetric products 20.0–67.6%. No meaningful balanced improvement was
measured at 8192 bytes or below. The final small balanced samples rise 0.8–1.5%,
which is retained rather than rounded into a win. Shared-machine load and code
layout can affect these measurements.

This candidate recursed through Toom above the existing 2048-byte threshold.
The retained implementation uses 8192 bytes for recursive subproducts and keeps
2048 bytes for top-level selection. The scratch recurrence fits the
existing bound: each level consumes `22*slot`, the largest child needs
`16*slot+256`, and `38*slot+256 <= 16*n+256` when `n >= 2048` and
`slot = ceil(n/3)+2`.

Blocked public dispatch requires a shorter payload of at least 2048 bytes and
a length ratio of at least 2:1. Workspace is `19*shorter+256` bytes and is
reused across blocks. Only a partial final block is padded. This adds allocation
and memory cost to unequal products that formerly needed no recursive workspace;
the measured end-to-end Mp timings include scratch-cache reuse after warmup.
Cold allocation and crossover tuning at other shapes remain unmeasured.

## Retained crossover and broader benchmark check

The broad `./bm --stable 3` rerun caught a regression at 98,304 bits: the
aggressive recursive candidate measured 834257 ns, versus 748098 ns in the
earlier migration run. Raising only the recursive crossover to 8192 bytes
removes that regression and gives up part of the largest balanced kernel win.
This choice is specific to the tested host; it is not an optimality proof.

Three further alternating rounds compared the corrected flat baseline with the
retained variant. Sizes are bytes; CPU includes the timer overhead described
above. Raw files are `tuned-{1,2,3}-{flat,final}.txt` and
[tuned-summary.jsonl](tuned-summary.jsonl).

| Product | Flat wall ns | Retained wall ns | Retained CPU ns | Wall change |
|---|---:|---:|---:|---:|
| 512 × 512 | 3814 | 3815 | 4291 | +0.0% |
| 4096 × 4096 | 143777 | 144796 | 144459 | +0.7% |
| 8192 × 8192 | 438251 | 432822 | 430925 | -1.2% |
| 32768 × 32768 | 3944746 | 3691401 | 3672039 | -6.4% |
| 512 × 256, Mp | 2249 | 2231 | 2742 | -0.8% |
| 4096 × 2048, Mp | 124317 | 100699 | 100575 | -19.0% |
| 8192 × 4096, Mp | 495545 | 297021 | 295858 | -40.1% |
| 32768 × 16384, Mp | 7982937 | 2671382 | 2656102 | -66.5% |

ATTENTION: the retained asymmetric improvements are 19.0–66.5%. The retained
largest balanced kernel improvement is 6.4%, not the earlier candidate's 24.5%.
The unchanged small-FFT control varies +2.7% at 512 bytes in this round.

Full public-API benchmarks were also alternated three times between the
aggressive and retained variants. The 98,304-bit product drops from 833464 to
741210 ns (-11.1%). The 65,536-bit product rises from 462684 to 475380 ns
(+2.7%), still below the earlier migration run's 504407 ns. Those earlier runs
were not interleaved with this experiment. No claim is made that every bucket
improved. See [full API comparison](tuned-full-summary.jsonl), raw
`tuned-*-*-full.txt` files and the [aggressive candidate's complete GMP run](full-suite-after.txt).

Validation: full ReleaseFast suite and build; a full ReleaseSafe suite for the
initial candidate and ReleaseSafe threshold tests after tuning; 13,087 GMP
comparisons, including 34 forced FFT/Toom products and 24 asymmetric public
products. [Red/green evidence](test-evidence.txt) records the failing tests.

ATTENTION: the final immediate-add samples are unstable at 7.31, 7.29 and
4.41 ns (median 7.29), versus the earlier complete run's 4.51 ns. The cause
is unassigned; no immediate-add code changed. This final three-run median
loses to GMP's separately measured 5.84 ns. Only the other three small-add
buckets win in the final 71 matched comparisons. The four-win migration
result remains historical evidence, not a current guarantee.

## Further experiments, ranked

1. Measure blocked crossover and allocation costs at 2:1 boundaries and wider
   ratios, then compare asymmetric Toom splits. Current measurements justify
   a conservative dispatch region, not a universally optimal threshold.
2. For FFT, measure paired inverse/forward layouts and fused Goldilocks stages.
   Dense small-prime residues usually occupy their full five-byte slots, making
   an offset table unlikely to save space there; this is a prediction to test.
3. Test sparse/truncated transforms around large padding jumps, with dense
   controls. Header-only zero initialization is implemented; zero-skipping
   butterflies and truncated transforms are not.
4. Derive truncated Montgomery carry bounds before implementation. No claim
   of a Montgomery speedup is made by this work.
5. Revisit contextual BLIP types only after profiling the remaining codec cost.
   The [type proposal](../../BLIP_ALGORITHM_TYPES.md) is not a wire-format change.
