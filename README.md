# blip_mp

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fblip_mp.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

A pure-Zig arbitrary-precision arithmetic library built on BDFN (Benevolent Dictator For Now)'s
[BLIP integer encoding](https://github.com/pmarreck/BLIP). Values use canonical,
variable-length signed BLIP bytes. Small values stay inline; larger values use
heap storage. GMP is used for testing and benchmarks, with no runtime dependency
in the library.

Project purpose and constraints: [INTENT.md](INTENT.md).

## What this experiment establishes

Arithmetic operates on byte payloads without stored integer limb arrays or
integer-array casts. Division and Montgomery scratch use magnitude bytes with
temporary register-sized reads. Every stored FFT coefficient, twiddle and
residue has its own canonical BLIP encoding. FFT slots reserve five bytes
for small-prime residues and ten for Goldilocks; unused capacity is not part of
the value.

BLIP's encoded length and an integer object's resident size are different
measurements. `Mp` is a 72-byte object in the current 64-bit build and contains
metadata and inline capacity. Compact wire encodings alone do not prove lower
resident memory than GMP.

## Measurements

The latest [results](RESULTS.md) and [benchmark log](BENCHMARK_RESULTS.md)
cover the September 27, 2026 migration on a Linux x86_64 Threadripper 3990X,
using Zig 0.16.0 ReleaseFast and GMP 6.3.0. They include before/after medians,
variation, FFT costs and reproducible commands. The migration run had four
small-addition buckets 1.21–1.30× faster than ordinary GMP. The final rerun
has three winning buckets; immediate-add timing varies from 4.41 to 7.31 ns
and needs investigation. The initial encoded FFT passes took 2.30–3.87× their former time. Subsequent
[storage-aware changes](docs/benchmarks/storage-aware/README.md) reduce forced
small-prime multiplication by 33.6–35.2% and Goldilocks by 5.3–7.6%, while
preserving canonical BLIP for every stored residue. Initial
[multiplication research](docs/benchmarks/storage-aware/RESEARCH.md) reduces a
32,768-byte balanced product by 6.4% and sampled asymmetric products by
19.0–66.5%. These compare BLIP revisions, not GMP.

The latest [scoped-residue experiment](docs/benchmarks/shifted-residues/README.md)
stores each small-field residue as `r+p`. Every resulting integer needs exactly
four payload bytes under the existing canonical BLIP rules, including field
zero. Five-run medians reduce complete forced FFT product time by 22.5–43.4%
relative to the preceding five-byte implementation. Normal `Mp` dispatch remains
unchanged; this result does not establish another win over GMP.

Wins depend on the operation, integer size and platform. The older Apple
Silicon and Zen 4 measurements remain historical records; they are not results
for this revision. GMP without assembly is a separate comparison and does not
by itself isolate BLIP's storage costs from algorithm or compiler differences.

The latest October 28 [matched division comparison](docs/plan_context/performance-follow-up.md#selected-kernel-gmp-results)
finds public BLIP division taking 2.0–11.2× ordinary GMP's CPU time across
8–16,384-byte divisors with dividends twice as wide. The earlier 6–19× fallback
speedups and 78–94% recursive CPU savings compare against older BLIP kernels.
The selected Burnikel–Ziegler kernel saves about 29% and 49% versus our Knuth
kernel at 8,192- and 16,384-byte divisors, respectively, but still takes about
5.12× and 5.74× GMP's time. Public dispatch is unchanged. All ten processes
verified their results; both affinity cohorts remain unbaselined, without retries.

A separate [signed public-path comparison](docs/plan_context/performance-follow-up.md#signed-public-division-results-october-28-2026)
finds B-Z saving 21–28% CPU time at 12,288/16,384-byte divisors with twice-width
dividends, and 18–44% across sampled recursive widths with four-times-width
dividends. When the dividend is only one byte wider, it takes 59–68× current
division's time. These compare two BLIP paths; GMP supplies correctness answers
outside timing. The six cohorts are unbaselined. Dispatch remains unchanged
because divisor width alone cannot predict the benefit.

Skipping B-Z's trivial highest block subsequently saves
[40–43%, 15–17% and 6–8% CPU time](docs/plan_context/performance-follow-up.md#leading-block-results-and-selection)
for short-quotient, balanced and long-dividend cases, respectively, against
the preceding B-Z implementation. The odd-width fallback stays near parity.
These gains support the local shortcut; they do not establish a new GMP win
or a lower public dispatch threshold. All 45 processes verified their results;
timing verdicts remain unbaselined or inconclusive.

A [short-quotient fallback](docs/plan_context/performance-follow-up.md#short-quotient-results-and-selection)
then takes about 1/25 to 1/30 of the selected B-Z path's CPU time on the sampled
eligible cases. It still takes 26–30% more time than current public division.
The measured balanced/long-dividend gains over the public path are 10–39% and
25–48%; a large penalty remains just beyond the short-quotient cutoff. The public
B-Z threshold therefore stays unchanged. All 120 processes across the two campaigns
verified their results, with unbaselined/inconclusive timing verdicts. GMP was
not timed in these campaigns.

Using each carried remainder's significant length to choose a division leaf
then saves [21–24% CPU on balanced divisions and 9–11% on long dividends](docs/plan_context/performance-follow-up.md#short-carry-results-and-selection)
against that short-quotient B-Z implementation at sampled even widths.
Control medians stay within about 0.4% of parity. All 50 processes verified their
results; all cohorts remain unbaselined. This local shortcut leaves the public
threshold unchanged and establishes no fresh comparison with GMP.

The [quotient-geometry sweep](docs/plan_context/performance-follow-up.md#quotient-geometry-crossover-results)
finds that selected B-Z still takes 1.42–1.64× Knuth's CPU time with a 2,048-byte
dividend gap at the sampled large aligned widths. A 4,096-byte gap puts the
methods near parity. All 35 processes verified their results; the six cohorts
remain unbaselined. The [wider fallback experiment](docs/plan_context/performance-follow-up.md#wider-quotient-fallback-results)
rejects a universal 2,048-byte gap cutoff: it saves 24–39% at aligned widths,
but regresses 9–10% at 4,098-byte divisors and 2–3% at 8,194 bytes near that
cutoff. Default dispatch stays unchanged. All 105 processes verified their
results; seventeen cohorts are unbaselined and one remains inconclusive.

## Quick start

The [verified immediate-add probe](docs/plan_context/performance-follow-up.md#verified-immediate-add-probe-october-27-2026)
is available through `./bm --verified-add`. It records CPU and wall samples for
mixed, immediate and promoted results with separate CPU-affinity cohorts and
external measurement history. Its checksum overhead makes it a new measurement
method; it does not replace the historical benchmark numbers above.

`./bm --verified-inverse` measures Lehmer, wider HGCD, the recursive entry point
and Stein on historical fixed fixtures. The recursive entry falls back at every
allowed fixture size; the probe reports significant modulus widths explicitly.
Every result is checked against GMP; CPU and
wall samples include that comparison. See the [measurement notes](docs/plan_context/performance-follow-up.md#unit-latency-and-inverse-probe)
for scope and retained correctness coverage.

The separate [exact-width paired inverse campaign](docs/plan_context/performance-follow-up.md#paired-exact-width-inverse-results-october-28-2026)
crosses the recursive threshold. Recursive inverse takes 3.3–3.4× wider-window
HGCD's CPU time at 4,096 and 4,097 bits, with near-parity at the 4,095-bit
fallback control. Public dispatch remains unchanged. All results agree with
GMP; timing verdicts remain unbaselined/inconclusive.

`./bm --verified-division` measures the retained division fixtures with complete
GMP quotient/remainder checks. Repeated timing work runs outside the unit suite;
its [probe checks and method](docs/plan_context/performance-follow-up.md#division-probes)
remain part of `./test`.
The [small-fixture clock fix](docs/plan_context/performance-follow-up.md#tiny-division-clock-batches)
versions the public/geometry probes to v2 and increases their small-batch
repetitions; large-case work counts and historical results remain intact.
The [paired fallback experiment](docs/plan_context/performance-follow-up.md#fallback-result-and-selection)
measured about 6–19× faster B-Z fallback calls at the sampled small and odd
divisor widths by reusing chunk-reading Knuth. The default fallback now uses
that leaf. Recursive controls stayed near parity; the cohorts remain unbaselined
or inconclusive. These kernel measurements do not time GMP or establish a public
division speedup.
The subsequent [recursive-cutoff comparison](docs/plan_context/performance-follow-up.md#recursive-cutoff-result-and-selection)
cut B-Z kernel CPU time by about 78–94% at sampled 64–2048-byte divisor widths.
The default recursive cutoff is now 128 bytes; the public B-Z integration
threshold is unchanged after the public-path comparison exposed severe
short-quotient regressions.

`./bm --verified-powm` measures public modular exponentiation on the retained
512–3072-bit workloads, with every result checked against GMP. Its
[method and controls](docs/plan_context/performance-follow-up.md#verified-modular-exponentiation-probe)
include modulus setup and arithmetic allocations in timing. GMP supplies the
correctness oracle; this probe does not time GMP itself.
The [Montgomery experiment](docs/benchmarks/storage-aware/MONTGOMERY.md)
records the baseline and a symmetric-squaring candidate. Paired measurements
show about 3–18% lower public-operation CPU time at the sampled 512–3072-bit
widths. A smaller-size sweep supports production selection for 64–384-byte
modulus magnitudes; other widths retain general multiplication. The cohorts
remain unbaselined and this comparison does not time GMP.

`./bm --verified-multiplication` compares schoolbook and blocked products on
identical inputs around the 2:1 dispatch boundary and at 4:1, 8:1 and 16:1 ratios.
It also compares public calls with reused and freshly allocated result/scratch
buffers. Every product is checked against GMP. See the
[measurement method](docs/benchmarks/storage-aware/RESEARCH.md#verified-crossover-and-allocation-probe).
The [paired final-block experiment](docs/benchmarks/storage-aware/RESEARCH.md#paired-tail-result-and-production-selection)
measured roughly 14–18% less CPU time for the sampled one- and eight-byte tails;
the unchanged nine-byte control stayed near zero at the median.

`./bm --verified-goldilocks` compares Stockham, paired radix-2 and fused stages
using [verified products and transform pairs](docs/benchmarks/goldilocks/README.md).
The fused layout reduced complete-product CPU time by about 23–25% versus
Stockham in the sampled sizes and is selected at the existing large-input
threshold. This comparison establishes no new GMP crossover; the measurement
notes retain the unbaselined and inconclusive cohort verdicts.

The [centered-residue experiment](docs/benchmarks/goldilocks/README.md#common-header-result-and-disposition)
reduced Goldilocks slot capacity from ten bytes to nine, but complete-product
CPU medians remained 20–27% slower even with a common-header shortcut.
Production retains positive BLIP representatives; the experiment's
inconclusive/unbaselined verdicts remain recorded.

`./bm --verified-truncated` compares the experimental
[truncated product](docs/benchmarks/goldilocks/TRUNCATED.md) against Stockham
and fusion around transform-padding boundaries.
Its first measurements saved 15–22% CPU time just above sampled padding jumps
but lost elsewhere, motivating fusion inside complete subtrees.
`./bm --verified-hybrid` tests whether fusing complete subtrees recovers those
losses while retaining truncation's padding-boundary gains.
Its first paired medians saved about 15% at 100000 bytes and 34–40% just above
padding jumps; nearly full transforms still lost. The subsequent crossover
sweep supports selecting it up to seven-eighths occupancy in the measured
131072- and 262144-point transforms. Full fusion remains the fallback. The
one-CPU cohort remained inconclusive after its allowed retry; these paired
observations do not establish a passed historical gate or a new GMP win.

Requires [Nix](https://nixos.org/) (handles the Zig 0.16.0 toolchain and GMP build for benchmarks).

```bash
git clone https://github.com/pmarreck/blip_mp
cd blip_mp

./build           # native ReleaseFast build via nix; also builds bp
./test            # unit tests + GMP cross-checks + C FFI smoke + bp CLI smoke
./result/bin/blip_mp_bench    # run the bench (after nix build .#packages.<sys>.bench)
```

`./build --debug` builds the debug package through Nix. Its `bp` executable
announces `DEBUG BUILD!` in yellow on stderr; release builds omit the marker.

## `bp` — RPN exact-arithmetic calculator

`bp` is a Forth-style RPN calculator that ships in `./result/bin/bp` after `./build`. It dogfoods the C FFI — same headers any downstream Rust/Lua/Python binding would use — so every shipped fix to the FFI surface gets exercised by the calculator itself.

**Every value is an exact arbitrary-precision rational** (M14 `Fp`, base = decimal). No IEEE754. No silent precision loss. Division uses `divExact` and errors when the quotient has no terminating decimal expansion — there's no quiet rounding hiding under the hood.

```bash
# Three ergonomic input forms — pick whichever's least painful:
bp 35 factorial 24 factorial '*'      # separate args (escape * for shell)
bp '35 factorial 24 factorial *'      # ONE quoted arg (no escaping needed)
echo '35 factorial 24 factorial *' | bp   # stdin pipe

# Headline IEEE754 disruption demos:
bp 0.1 0.2 +                          # → "0.3"  (the disruption)
bp '0.1 0.2 + 0.3 -'                  # → "0"    (the proof)
bp 1 4 /                              # → "0.25" (terminates exactly)
bp 22 7 /                             # → ERROR: non-terminating expansion
bp 100 fib                            # → 354224848179261915075
bp '50 25 binomial'                   # → 126410606437752
bp 48 18 gcd                          # → 6

# Forth-style ":" definitions — Phase 2 (threaded code, classical semantics):
bp ': square dup * ; 5 square'        # → 25
bp ': tau 6.28 ; tau 2 *'             # → 12.56

# Heredoc form (multi-line):
bp <<'EOF'
: square dup * ;
: cube dup square * ;
3 cube
EOF
# → 27

# Re-defining a builtin shadows it for FUTURE lookups but doesn't
# retroactively rebind earlier compiled bodies (classic Forth):
bp ': real-fact ! ;
    : ! drop 999 ;
    5 real-fact'                      # → still 120
```

**Operators** (`bp --help` for full list with stack-effect comments):
`+ - * / % ^ neg abs dup drop swap factorial ! fibonacci fib binomial isqrt sqrt gcd lcm`

**Definitions**: `:` enters compile mode and consumes the next token as the new word's name. `;` is "immediate" — it executes even in compile mode and finalizes the definition. The body is a list of *resolved* instruction pointers (builtin / user-word / literal-Fp), not text — so re-defining a builtin shadows it for *future* lookups but does NOT retroactively rebind any earlier compiled body. Classic Forth threaded code.

## Use as a library

In your own Zig code:

```zig
const std = @import("std");
const blip_mp = @import("blip_mp");
const Mp = blip_mp.Mp;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var a = Mp.init(allocator);
    defer a.deinit();
    var b = Mp.init(allocator);
    defer b.deinit();
    var r = Mp.init(allocator);
    defer r.deinit();

    try a.setI64(123_456_789);
    try b.setI64(987_654_321);
    try r.mul(&a, &b);

    // r.bytes() is the canonical signed-BLIP encoding — also the wire form.
    // No mpz_export round-trip needed.
    std.debug.print("Product encoded as {d} bytes\n", .{r.bytes().len});

    const value = try r.getI64(); // works because product fits in i64
    std.debug.print("Value: {d}\n", .{value});
}
```

---

## Architecture

The Zig core handles in-memory arithmetic. The C FFI and `bp` calculator are
consumers. Inline values use native scalar arithmetic; large add/sub operations
read chunks directly from the payload. Multiplication includes schoolbook,
Karatsuba, Toom-3 and three NTT backends. Division and modular exponentiation
also keep scratch in byte buffers. FFT arithmetic decodes BLIP residues into
registers and encodes every stored result.

The single-prime and CRT FFT thresholds currently exclude their entire supported
ranges. Goldilocks remains reachable at sufficiently large equal-length inputs.
Backend-specific correctness tests run independently of production dispatch.
See [CODE_MINIMAP.md](CODE_MINIMAP.md) for source locations.

## Scope and next experiments

The library includes exact binary/decimal fixed-point arithmetic, but does not
provide full GMP API compatibility, unrestricted rationals or MPFR semantics.
Portable behavior is intended across macOS ARM64, Linux ARM64/x86_64 and Windows
ARM64/x86_64. The current migration was executed and measured on Linux x86_64;
historical runs do not establish current cross-platform verification.

[Optimization research](docs/OPTIMIZATION_RESEARCH.md) compares the current
algorithm set with GMP and examines SIMD, recursive Toom, asymmetric products,
truncated Montgomery work and BLIP-aware FFT layouts. Candidate experiments are
marked as untested. Execution status lives in [PLAN.md](PLAN.md).

## License intent

MIT or Apache-2.0 (TBD before tagging a release). Both permit linkage with libgmp (LGPLv3) and downstream commercial use.

---

## Acknowledgments

- The [BLIP encoding spec](https://github.com/pmarreck/BLIP) by BDFN.
- GMP team for the reference implementation we cross-validate against.
- Marco Bodrato and Alberto Zanoni for the Toom-3 interpolation formulas.

---

*See [SPEC.md](SPEC.md) for the original design hypothesis, [RESULTS.md](RESULTS.md) for the comprehensive technical writeup, [BENCHMARK_RESULTS.md](BENCHMARK_RESULTS.md) for per-run history, [PLAN.md](PLAN.md) for the milestone checklist, and [CODE_MINIMAP.md](CODE_MINIMAP.md) for the per-file index.*
