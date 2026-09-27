# Storage-aware FFT experiment, September 27, 2026

Host: AMD Threadripper 3990X, Linux x86_64, Zig 0.16.0 ReleaseFast.
Baseline arithmetic: `505426a` (same arithmetic as `8a7c515`). The added
`tests/benchmark/storage_aware.zig` measures identical seeded operands with
setup outside timing. CPU samples use process CPU time; wall uses monotonic
time. CPU-clock overhead is included, particularly visible for tiny products.
This was a shared machine without CPU affinity, while compilation also ran.

`repeat-{1,2,3}-{baseline,compact,header,fused}.txt` are three sequential,
alternating rounds. `summary.jsonl` contains medians and observed min/max.
Earlier `00` through `03` files are exploratory samples, excluded from these
medians. Transform passes use 200 iterations; products use 100 iterations at
512/4096 bytes and 10 at larger sizes, after three warmups.

## Ablation

| Variant | Change from preceding variant |
|---|---|
| baseline | Canonical BLIP in 16-byte slots |
| compact | Five-byte small-field slots, ten-byte Goldilocks slots; CRT merge feeds carry directly |
| header | Common `84` read/write fast path for small-field residues |
| fused | Radix-4 small-field transforms; header-only zero initialization; inverse scale feeds carry directly |

The compact stage changes access width as well as capacity. The fused stage
combines three changes. These measurements isolate those groups, not individual
instructions. Ordinary Toom-3 and asymmetric Mp multiplication are controls;
their code is unchanged in these four variants. Their variation cautions against
attributing every small change to the layout.

## Median wall time, nanoseconds

Sizes below are bytes **per operand**. Asymmetric control uses size × size/2.

| Workload | Baseline | Compact | Header | Fused | Change |
|---|---:|---:|---:|---:|---:|
| Radix-4 pass, N=8192 | 198628 | 188158 | 132796 | 136161 | -31.4% |
| Small FFT, 512 bytes | 88693 | 80397 | 73119 | 58895 | -33.6% |
| Small FFT, 4096 bytes | 993260 | 897550 | 777182 | 643650 | -35.2% |
| Gold FFT, 512 bytes | 62896 | 61132 | 61260 | 58111 | -7.6% |
| Gold FFT, 4096 bytes | 617733 | 606366 | 609782 | 581247 | -5.9% |
| Gold FFT, 8192 bytes | 1323440 | 1293214 | 1293432 | 1252976 | -5.3% |
| Gold FFT, 32768 bytes | 6057658 | 5835944 | 5858265 | 5649026 | -6.7% |

ATTENTION: small FFT multiplication improved 33.6–35.2%; all eight sampled
small-field transform variants improved 21.3–42.0%. Repeated runs confirm the
large initial change. Gold FFT CPU medians improve 5.8–7.2%, consistent with
wall time. The controls vary from -1.3% to +2.6% in their final wall medians.

Five-byte capacity is 68.75% less than the former 16-byte slots; ten-byte capacity
is 37.5% less. These are buffer-capacity calculations, not whole-process RSS
measurements. Every live residue remains an ordinary canonical signed BLIP
integer. No sentinel or wire format was added.

FFT still loses to Toom-3 in these products. At 4096 bytes, fused small FFT takes
643650 ns, Gold FFT 581247 ns, and Toom-3 143793 ns. Dispatch thresholds are
unchanged. The old fixed-u64 radix-4 pass measured 85858 ns earlier that day;
the current 136161 ns remains slower, though those runs were not interleaved.

## Reproduction

Build each source variant with `nix develop -c zig build bench --summary none`.
Preserve its `zig-out/bin/fft_microbench` executable before building another
variant, then run the four executables in the order above three times, capturing
both stdout and stderr. No debug banner may appear and `MUTE_DEBUG_STATUS` must
be unset. The final source contains the fused variant; the intermediate source
changes are described above, and raw timing lines retain all samples.

Correctness is checked separately with canonical-byte and poisoned-padding
oracles, transform fixtures, GMP products, allocation failure tests and the
storage audit through `./test`. Performance is not a deterministic unit-test
assertion.
