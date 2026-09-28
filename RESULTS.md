# Results after the BLIP-residue migration

Follow-up: [storage-aware FFT measurements](docs/benchmarks/storage-aware/README.md)
reduce forced small-prime products by 33.6–35.2% and Goldilocks by 5.3–7.6%
relative to the 16-byte BLIP implementation. The tables below preserve the
earlier migration comparison; they are not timings of the follow-up revision.
[Recursive and asymmetric product results](docs/benchmarks/storage-aware/RESEARCH.md)
record the next experiments, including null results and correctness fixes.
The final immediate-add samples vary from 4.41 to 7.31 ns; their median loses
to GMP, leaving three winning buckets in that final comparison.

Measured September 27, 2026 on an AMD Ryzen Threadripper 3990X (Zen 2,
64 cores / 128 threads), Linux 6.18.43 x86_64, Zig 0.16.0 ReleaseFast,
GMP 6.3.0. The arithmetic revision is `8a7c515`; the baseline is `a6d0d3e`.

BLIP wins the four small-addition buckets in this run: 4.57–4.81 ns versus
5.81–5.95 ns for ordinary GMP, about 1.21–1.30× faster. Ordinary GMP wins the
other 67 matched size/operation buckets. BLIP wins 46 of 71 matched buckets
against GMP built without assembly. That control also differs in algorithms
and compiler, so it cannot attribute the difference to storage alone.

All `./test` groups and `./build` passed. The GMP integration suite made
13,053 comparisons with zero mismatches, including 24 forced single-prime,
CRT and Goldilocks products. [Representation and verification](docs/REPRESENTATION.md)
explains the byte-buffer audit and per-residue BLIP tests.

## Before and after

Three-run medians, ns/op. Positive change means slower than the baseline.
The final column is BLIP/GMP: below 1 favors BLIP. Division bucket width is
the dividend width; divisors use half as many bytes.

| Operation / bucket | Before ns | After ns | Change | GMP ns | After / GMP |
|---|---:|---:|---:|---:|---:|
| add L=0 (immediate, 0..127) | 4.56 | 4.57 | +0.2% | 5.95 | 0.77 |
| add L=2 (128..32K) | 4.73 | 4.80 | +1.5% | 5.81 | 0.83 |
| add L=3 (~16-bit..~24-bit) | 4.73 | 4.81 | +1.7% | 5.81 | 0.83 |
| add L=4 (~32-bit) | 4.73 | 4.81 | +1.7% | 5.82 | 0.83 |
| add 32768-bit | 351.80 | 357.94 | +1.7% | 156.88 | 2.28 |
| mul 1024-bit | 370.28 | 387.15 | +4.6% | 143.55 | 2.70 |
| mul 2048-bit | 1162.27 | 1194.56 | +2.8% | 464.22 | 2.57 |
| mul 32768-bit | 148597.00 | 162544.00 | +9.4% | 34480.10 | 4.71 |
| mul 65536-bit | 440462.00 | 504407.00 | +14.5% | unmeasured | n/a |
| divMod 1024-bit | 345.65 | 351.88 | +1.8% | 143.87 | 2.45 |
| divMod 2048-bit | 818.26 | 832.45 | +1.7% | 310.62 | 2.68 |
| divMod 65536-bit | 398028.00 | 404432.00 | +1.6% | 76326.40 | 5.30 |
| powm 1024-bit | 759259.00 | 833949.00 | +9.8% | 296565.00 | 2.81 |
| powm 2048-bit | 5205600.00 | 5588680.00 | +7.4% | 2020870.00 | 2.77 |
| invMod 2048-bit | 62701.70 | 62895.40 | +0.3% | 15472.40 | 4.07 |

ATTENTION: 65,536-bit multiplication regressed 14.5% (baseline range
438,730–441,883 ns; after range 492,126–507,214 ns). The 32,768-bit product
regressed 9.4%, and 1,024-bit powm regressed 9.8%. These costs are retained
in the report. They have not been attributed to a specific instruction or
allocation change. Those multiplication sizes do not dispatch to FFT, so
BLIP residue encoding is not an explanation for those particular regressions.

## Method and limits

- `./bm --stable 3` ran before and after, with warmup and per-bucket ranges.
  Both builds used ReleaseFast and emitted no debug banner. `MUTE_DEBUG_STATUS`
  was not set. Inputs and iteration counts were unchanged across revisions.
- The full machine was not reserved for the benchmark. Other projects were
  active; repetitions expose some variation but cannot eliminate load, CPU
  frequency or process-layout effects. There was no CPU affinity pinning.
- GMP and BLIP use the existing size-matched suites. Not all operand pools are
  byte-identical between the two implementations. These are measured suite
  comparisons, not universal rankings or a controlled storage-only ablation.
- The legacy `./bm` combined table prints zeros for missing GMP buckets. They
  mean **unmeasured**, not zero runtime. The derived TSV uses `NA`; this report
  excludes them from win counts and ratios.
- The normal Mp.mul sweep ends at 98,304 bits, below the reachable Goldilocks
  dispatch threshold. Forced FFT timings are needed to measure encoded-residue
  costs; correctness tests separately exercise much larger FFT operands.
- Per-operation timings use a monotonic wall clock. Hyperfine's process totals
  provide CPU (user/system) and wall time for the complete BLIP benchmark,
  including setup; they are not per-operation CPU times or a GMP comparison.

Raw evidence: [before](docs/benchmarks/2026-09-27-before.txt),
[after](docs/benchmarks/2026-09-27-after.txt),
[all operation comparisons](docs/benchmarks/2026-09-27-comparison.tsv).
Nix binary paths are recorded in the raw logs for exact local reruns.

The [May results](docs/benchmarks/2026-05-results.md) remain a historical record
for older implementations and machines. The [optimization research](docs/OPTIMIZATION_RESEARCH.md)
distinguishes known algorithm gaps, existing SIMD techniques and untested
BLIP-specific experiments.

## Forced FFT cost

N=8,192 transform points, 200 passes per sample, medians of three samples.
Input refresh and twiddle construction are outside each pass timing; decoding
and encoding inside the butterflies are included. Each sample uses the same
seeded data, alternating baseline and migrated binaries.

| Transform | Before ns/pass | After ns/pass | After / before |
|---|---:|---:|---:|
| nttWithTwiddles_scalar | 114461 | 286664 | 2.50 |
| nttWithTwiddlesVec | 75952 | 261394 | 3.44 |
| nttWithTwiddlesMontVec | 95573 | 264511 | 2.77 |
| nttStockhamVec | 66171 | 256393 | 3.87 |
| nttStockhamVecU4 | 65415 | 244008 | 3.73 |
| nttStockhamVecU8 | 71808 | 240692 | 3.35 |
| nttStockhamMontVec | 81746 | 259636 | 3.18 |
| nttRadix4Vec | 85858 | 197512 | 2.30 |

ATTENTION: these transform variants take roughly 2.30–3.87× their former time.
This is the measured cost of the initial 16-byte BLIP-slot implementation, not a lower
bound on BLIP arithmetic. Radix-4 is the fastest measured encoded variant here,
which makes register-local stage fusion a useful follow-up experiment. No
production threshold was changed on the basis of these primitive timings.

Raw [alternating FFT samples](docs/benchmarks/2026-09-27-fft.txt) include scalar
and SIMD primitive measurements as well as full passes. The larger slot
capacity doubles the coefficient/twiddle buffer allocation from 8 to 16 bytes
per element; it does not imply the entire Mp operation doubles its memory.

## Whole-process CPU and wall time

Hyperfine, one warmup and three measured executions per binary. CPU columns
are mean process user/system seconds; wall is mean ± standard deviation.

| Workload | Wall seconds | User CPU seconds | System CPU seconds |
|---|---:|---:|---:|
| before | 13.406 ± 0.087 | 13.311 | 0.013 |
| after | 13.670 ± 0.133 | 13.576 | 0.011 |
| before-fft | 0.409 ± 0.007 | 0.405 | 0.002 |
| after-fft | 0.911 ± 0.007 | 0.904 | 0.002 |

[Full-benchmark timing JSON](docs/benchmarks/2026-09-27-process-times.json)
and [FFT timing JSON](docs/benchmarks/2026-09-27-fft-process-times.json) retain
every wall-time sample. The aggregate full benchmark rose about 2%; aggregate
FFT-microbenchmark time includes scalar primitives and setup, so it is not the
same ratio as a single NTT pass.

## Reproducing the runs

For a fresh current-revision measurement, run `./bm --stable 3` and `./bm --micro`.
For the exact local comparison recorded here, use the binaries named in the
before/after logs:

```bash
nix develop -c hyperfine --warmup 1 --runs 3 \
  --export-json process-times.json \
  --command-name before '/nix/store/iql16fa0qaynjldjhpxzhs7ws84l2b8v-blip_mp-bench-0.0.1/bin/blip_mp_bench' \
  --command-name after '/nix/store/z5b52wrpcsx9grgpi82x3sp4xcfv3kps-blip_mp-bench-0.0.1/bin/blip_mp_bench'
```

Substitute `fft_microbench` for `blip_mp_bench` to measure whole FFT-benchmark
process times. For the per-transform table, run those two FFT binaries
alternately three times and take each implementation's median `ns_per_pass`.
The Nix store paths are local evidence; rebuilding the two commits provides
portable source reproduction, subject to the machine and dependency versions.
