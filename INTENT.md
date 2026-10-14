# blip_mp intent

## Purpose and intended users

BDFN (Benevolent Dictator For Now)'s sibling `../BLIP` project established a self-describing encoding for
arbitrary-length integers without requiring GMP-style fixed-width limb arrays
as their representation. `blip_mp` builds an independent arithmetic library on
that encoding, keeping BLIP bytes as the canonical integer storage and working
directly on their payloads.

BLIP puts length information in the header and leaves the payload bytes intact.
This allows arithmetic to read contiguous chunks without stripping continuation
bits from each payload byte. The encoding is defined in the sibling project's
[BLIP_SPEC.md](../BLIP/BLIP_SPEC.md).

Test whether this variable-length storage can reduce allocation, memory and
serialization costs while matching or beating GMP in arithmetic performance.

Recorded benchmarks already show wins over GMP at particular integer sizes and
operations, alongside losses elsewhere. BDFN reaffirmed this size-dependent
framing on September 27, 2026. Establishing where the library is useful requires
mapping those wins and losses on each target platform.

The intended users are developers embedding exact arithmetic through Zig or
the C API, and people doing exact calculations from the shell through `bp`.
Recorded use cases include accumulators, polynomial coefficients, modular
arithmetic, exact decimal computation, finance and binary fixed-point work.
These are intended applications, not evidence of adoption.

## Desired outcomes

- Keep the encoded bytes as the integer's canonical value and wire form, so
  serialization does not require conversion from a separate stored limb array.
- Make small values cheap through native arithmetic and inline storage, with
  automatic promotion when results need more space.
- Preserve and expand the measured wins over GMP, reporting performance by
  operation, operand size and platform. The May roadmap records the broader
  ambition of matching or beating GMP at all sizes; useful wins at particular
  sizes are already a result of the project.
- Provide exact integer and fixed-point arithmetic. For `Fp`, represent values
  as an arbitrary-precision mantissa times a binary or decimal base raised to a
  per-value scale. Precision loss must be explicit through the chosen operation,
  rounding mode, exactness result or quotient/remainder result.
- Make the C API usable by downstream consumers and exercise it through the
  `bp` Forth-style RPN calculator, including user-defined words.

The original go/no-go criterion was at least 1.5× GMP's speed on a representative
small-value workload. The April 30 roadmap records a 1.68× immediate-add result
after inline storage and the decision to continue. Preserve that as the initial
experiment's result; it does not establish universal performance or memory wins.

## Scope and constraints

The library covers signed integers, arithmetic, comparisons, bit operations,
number theory, modular operations, text conversion, and exact binary/decimal
fixed-point arithmetic. `bp` provides a practical consumer of that surface.
Its exact division rejects non-terminating decimal results.

Keep computation in the Zig core and I/O in adapters. The C interface is the
public foreign-language contract. Keep GMP as a comparison oracle and benchmark
dependency; the April 30 decision chose independent byte-direct arithmetic for
the core. Reimplement the required integer encoding from the BLIP specification
without importing the sibling project's archive and compression dependencies.

Use canonical signed two's-complement BLIP encodings with the minimum payload
width and an immediate form for small nonnegative values. Document the signed
interpretation explicitly; interoperability with strict unsigned-BLIP producers
remains an unresolved extension.

Eliminate all stored fixed-width limb arrays, including division scratch and
FFT intermediates. BDFN reaffirmed this requirement on September 27, 2026,
to demonstrate that BLIP storage is sufficient for the arithmetic. Reading byte buffers into
register-sized chunks is compatible with this goal. The roadmap records remaining
storage exceptions; calling the implementation fully limbless requires an audit.

BDFN further specified that every stored FFT intermediate residue must itself
have a canonical variable-length BLIP encoding, including twiddle factors and
scratch values. This supersedes the May proposal to store fixed-width residues
in byte buffers. Allocation capacity may exceed an encoding's length; temporary
register values remain arithmetic operands. Measure the cost of this representation.

Maintain portable behavior across macOS ARM64, Linux ARM64/x86_64 and Windows
ARM64/x86_64. Distinguish build coverage, executed correctness tests and measured
performance on each platform. Prefer portable Zig; the May 18 record defers hand
assembly. Do not treat an optimization proposal as approval to change that choice.

The project does not promise full GMP API or ABI compatibility, an unrestricted
rational-number type, or an IEEE754/MPFR replacement. `Fp` supports finite
base-scaled values and explicit treatment of inexact operations. The initial
integer-only and no-CLI boundaries were expanded by M14 and M16. The original
1024-bit performance boundary was superseded by the later all-sizes goal.

## How success is verified

- Run [`./test`](test) for Zig unit tests, GMP differential checks, C API tests
  and `bp` CLI tests. Cover signed boundaries, promotion, canonicalization,
  aliasing and documented error behavior. Use GMP rational comparisons for
  representable `Fp` results.
- Use [`./bm`](bm) in ReleaseFast with repeated measurements and reported
  variation. Record CPU, OS, compiler, operand sizes and GMP configuration.
  Compare against ordinary GMP; use GMP without assembly as a separate control.
  Apple Silicon results cannot establish x86_64 performance.
- Verify arithmetic through consumer-facing paths as well as isolated kernels.
  Measure allocation, total resident representation and serialization separately
  before claiming improvements in those areas; encoded byte length alone does
  not measure the size of an `Mp` object.
- Preserve results that disprove an optimization hypothesis. Enable new
  algorithms only when correctness and measured performance justify dispatch.

Historical measurements live in [BENCHMARK_RESULTS.md](BENCHMARK_RESULTS.md)
and [RESULTS.md](RESULTS.md). They are evidence for the configurations measured,
not guarantees for future builds.

## Open decisions and document authority

The license remains undecided between MIT and Apache-2.0; choose before release.
Strict unsigned-BLIP wire interoperability also needs a defined contract before
implementation.

This document consolidates the original overview and the decisions recorded in
the [legacy roadmap](docs/plan_context/legacy-roadmap.md), especially M3, M14,
M15, M16 and the May 17–18 performance notes. It establishes no new claim that
those goals have been met. The original overview is recoverable from Git at
`d3b9102:PROJECT_OVERVIEW.md`.

[PLAN.md](PLAN.md) holds current work, [TERMINOLOGY.md](TERMINOLOGY.md) defines
project terms, and [CODE_MINIMAP.md](CODE_MINIMAP.md) maps the implementation.
[SPEC.md](SPEC.md) preserves the original design proposal; its older alternatives
and scope exclusions do not override the later decisions collected here.
