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

## Quick start

The [verified immediate-add probe](docs/plan_context/performance-follow-up.md#verified-immediate-add-probe-october-27-2026)
is available through `./bm --verified-add`. It records CPU and wall samples for
mixed, immediate and promoted results with separate CPU-affinity cohorts and
external measurement history. Its checksum overhead makes it a new measurement
method; it does not replace the historical benchmark numbers above.

`./bm --verified-inverse` measures Lehmer, wider HGCD, recursive HGCD and Stein
on the historical fixed fixtures. Every result is checked against GMP; CPU and
wall samples include that comparison. See the [measurement notes](docs/plan_context/performance-follow-up.md#unit-latency-and-inverse-probe)
for scope and retained correctness coverage.

`./bm --verified-division` measures the retained division fixtures with complete
GMP quotient/remainder checks. Repeated timing work runs outside the unit suite;
its [probe checks and method](docs/plan_context/performance-follow-up.md#division-probes)
remain part of `./test`.

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
`./bm --verified-truncated` compares the experimental
[truncated product](docs/benchmarks/goldilocks/TRUNCATED.md) against Stockham
and fusion around transform-padding boundaries.

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

**Definitions**: `:` enters compile mode and consumes the next token as the new word's name. `;` is "immediate" — it executes even in compile mode and finalises the definition. The body is a list of *resolved* instruction pointers (builtin / user-word / literal-Fp), not text — so re-defining a builtin shadows it for *future* lookups but does NOT retroactively rebind any earlier compiled body. Classic Forth threaded code.

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
