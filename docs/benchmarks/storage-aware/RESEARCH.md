# First multiplication research experiments

These follow the canonical-residue FFT changes in `a80073f`. Same Linux
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

## Verified crossover and allocation probe

`./bm --verified-multiplication` runs the shared measurement engine with
`profiling-multiplication.json`. Each geometry uses identical fixed positive
operands for four methods: chunk-reading schoolbook, blocked multiplication,
public `Mp.mul` with reused buffers, and public `Mp.mul` with newly allocated
result/scratch buffers. Direct kernel methods use prepared byte storage. All
stored arithmetic scratch remains byte-based; GMP supplies the independent
product before timing and is not itself timed.

The shorter lengths are 1024, 1536, 2047, 2048, 2049 and 4096 bytes around
the 2:1 boundary. The longer length is twice that size minus one, exactly twice,
or twice plus one. Wider 4:1, 8:1 and 16:1 ratios use 2048/4096-byte shorter
operands. Each case declares separate 1/12-CPU affinity cohorts, five fresh
processes and five samples. Boundary batches contain 100 verified products;
wider-ratio batches contain 20. Results are nanoseconds per product, including
the complete GMP-derived byte comparison and any measured buffer cleanup.

The cold-buffer case releases the result and thread-local multiplication scratch
before and after each operation. Input construction and GMP calculation remain
outside timing. It measures library allocation lifetime, with libc and hardware
caches potentially warm; it is not a fresh-process or cold-memory measurement.
Allocation counts are not collected during timing. A correctness test checks
that repeated warm public calls allocate nothing for its 4096-by-8192 fixture,
while repeated cold calls allocate and release storage. Failure-injection tests
exercise cleanup after every injected Zig allocation failure in a small complete fixture.

The complete suite checks every geometry, both sides of the shorter-length and
2:1 thresholds, public and direct-kernel results, corrupted expected results,
CLI output and argument rejection. SIMD changes are deferred while this probe
isolates algorithm selection and allocation costs; no production arithmetic or
dispatch threshold changes are part of the measurement adapter.

The complete native suite, including 13,111 existing GMP comparisons, and the
production build passed in 87 seconds combined; mixed Nix preparation/check
time was 86 seconds. All-system evaluation passed, with execution on Linux
x86_64 only. The initial adapter failed all five new behavioral tests, and the
new command route failed before implementation. The final adapter also passed
the optimized CLI checks and ReleaseSafe cleanup/corruption controls.

## October 28 crossover observations

Commit `bb28dc7` completed 48 cases at 04:10:19–04:12:30 UTC. All 315 fresh
processes, including 15 automatic five-process retries, verified their products.
Forty-two cases were unbaselined and six remained inconclusive. No baseline was
approved. Host load at the initial snapshot was 26.29. The source digest stayed
`f7376327e2e7fd25798e0fcb760980f1854b4bf934384d37a6ecc341dc65dc6d`.

[The complete selected-process summary](crossover-summary.jsonl) retains all
192 size/method/affinity rows and their case verdicts. Raw processes and retries
remain in external history under prefix `blip-mp-multiplication-20261028T041012Z-`
plus each case name from `profiling-multiplication.json`. The table below shows
one-CPU direct-kernel mean CPU microseconds, including result verification.

| Longer × shorter bytes | Schoolbook | Blocked |
|---|---:|---:|
| 2047 × 1024 | 44.33 | 28.16 |
| 4093 × 2047 | 172.89 | 87.89 |
| 4095 × 2048 | 171.93 | 112.31 |
| 4096 × 2048 | 134.28 | 111.14 |
| 4097 × 2048 | 184.37 | 131.69 |
| 8191 × 4096 | 686.53 | 341.38 |
| 8192 × 4096 | 510.41 | 337.12 |
| 8193 × 4096 | 686.30 | 394.85 |

The sampled region just below 2:1 favors blocked products, and the 2047-byte
shorter operand also benefits before the current 2048-byte public threshold.
These observations motivate a broader crossover experiment rather than a new
universal dispatch rule. Alignment matters: schoolbook selects different paths
when both byte lengths are divisible by eight. The one-byte tail above 2:1 also
forces an extra padded balanced product in the current blocked implementation.
The next narrow candidate handles a final block that fits a native register
with the existing byte-direct multiply-by-u64 operation.

Wider ratios generally retain the blocked benefit, but separate processes can
occupy different timing modes. For example, direct blocked 32768-by-4096 products
took 2441.76 microseconds in the selected one-CPU process versus 1351.65 with
12 CPUs allowed, while public warm calls took 1360.41 and 1383.45 respectively.
This discrepancy prevents treating every isolated ratio as an algorithm effect.

The cold-buffer measurement does not establish a reliable allocation penalty.
For 65536-by-4096 public products, warm/cold means were 2755.82/5378.05
microseconds in the one-CPU cohort, but 2863.83/2788.01 with 12 CPUs allowed.
Smaller cases likewise include cold calls both above and below warm calls.
Correctness and allocation-lifetime controls passed; separating the small
allocation cost from process modes requires a contemporaneous paired experiment.
No production dispatch or claim of improved GMP-relative performance follows
from this campaign.

## Register-sized tail candidate

`mulBlockedShortTail` retains the same byte-buffer workspace and balanced full
blocks as `mulBlocked`. For a final block of one through eight bytes, with a
shorter operand of at least eight bytes, it reads one temporary `u64` factor
and calls `mulMagnitudeByU64`. Only the returned significant product bytes are
added to the result. A zero factor therefore adds no stale workspace bytes.
Larger tails keep the padded balanced path. Production dispatch still uses
the original padded implementation while this candidate is measured.

The focused ReleaseSafe controls compare dense random, all-255 and zero-tail
inputs in both operand orders, with exact output/scratch canaries, across shorter
lengths 7, 8, 128 and 2048 and tails one through nine bytes. The existing GMP
probe also checks the candidate. Both controls failed against an empty candidate
before passing with the implementation. This replaces an unnecessary balanced
product with a linear operation; SIMD changes are deferred while testing that
algorithmic reduction.

Run `./bm --verified-multiplication --config profiling-short-tail.json` to compare
`blocked` and `blocked_tail` in the same optimized executable. The one-byte and
eight-byte tails exercise the candidate; the nine-byte tail controls its unchanged
fallback. Each uses six shorter lengths, five processes and five samples in
separate 1/12-CPU affinity cohorts. No baseline is approved by running it.

The complete native suite and production build passed in 125 seconds combined,
with 124 seconds of mixed Nix preparation/check time. All-system evaluation
passed. The candidate remains separate from production selection until measured.
