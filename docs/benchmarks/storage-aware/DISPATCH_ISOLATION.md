# Reciprocal dispatch isolation, November 2, 2026

The earlier public-dispatch trials improved eligible reciprocal division but
regressed some bypassed inputs. Their operand guard was already selective.
This experiment changes call boundaries rather than narrowing that guard.

## Frozen reference

Source `f506ac10685775e5f94f769fdcdd976f6c5b388f` uses the retained public
entry and original experimental reciprocal entry. The bounded reference
configuration selects 1-, 8- and 9-byte divisors from the preceding signed
probe, with thirteen dividend widths from 8 through 4,097 bytes. Every width
uses 32 fixtures covering four sign combinations and eight normalization
shifts, six balanced samples and 512 repetitions per fixture. Affinity cohorts
allow 1 or 12 CPUs, with five fresh processes each and one variation retry.

All 40 reference processes, including retries, verified their results. Four
cohorts finished `UNBASELINED`; the 8-byte/12-CPU and 9-byte/1-CPU cohorts
remained `INCONCLUSIVE`. No baseline epoch was approved. The unchanged source
digest was `9c658ac1f8059d71ca98478f0c244ceb356ccd80c8f4a21e02d77136a909187a`.
The probe SHA-256 was
`85621bbc497ca8f3889483fbe8fc6a3af7c24465c1f0e169bf3564d8c8798774`.

Optimized x86_64 assembly shows the original experimental entry reserving
`0x4088` stack bytes before its small-value checks. The public entry performs
those checks before its large scratch frame. This motivates isolation; it
does not establish how much of any timing difference the frame explains.

## Candidates

- `isolated` retains local native arithmetic for small values and forces the
  large reciprocal helper out of line.
- `thin` checks cached payload bounds, delegates bypassed inputs to the
  existing public entry, and calls the large helper out of line for possible
  reciprocal inputs. The magnitude kernel still applies its exact guard.

`profiling-division-isolation.json` pairs each candidate with the retained
public entry and ordinary GMP. Input preparation and warmup are outside
timing. Each timed call checks the complete quotient and remainder. BLIP
conversion, arithmetic allocation and encoding remain included; GMP uses
preconverted inputs. Outputs and scratch are reused, so cold allocation is
unmeasured. CPU and monotonic wall samples remain separate. A result on this
Linux x86_64 host does not establish a benefit on other architectures.

Both placeholder entries failed the new poisoned-output control before
implementation. The completed candidates pass native and GMP-derived results,
all sign combinations, input/output aliases, zero-divisor rejection, zero
dividends, minimum-i64 promotion and allocation-failure enumeration. The
signedness table below also passes its native-i256 and inline-storage checks.

The expanded four-process correctness runner passed all 74 tests in a rounded
four seconds when built alone and six seconds during the concurrent full
build. The latter exceeds the five-second execution budget. Compilation and
other test groups were concurrent; these observations do not isolate a
particular cause of the difference. No tests were removed or shortened.

The first full run failed because a signed CLI smoke measurement rejected a
non-advancing CPU clock. The smoke corpus now uses 64/65/256/257-byte dividends
to increase batch duration. Unit and measurement corpora retain all the tiny
widths, and clock failure remains an error. CLI failures now identify the
comparison and divisor width.

After that smoke change, the complete entry point passed in 28 seconds with
prepared correctness artifacts reused. The preceding run passed 649 Zig tests
but failed the CLI clock check; it is retained as a failed full run. Production
build and all-system evaluation passed. Only Linux x86_64 executed these tests.

Optimized assembly and LLVM IR confirm that the isolated entry tail-calls a
separate helper containing the 4,096/4,096/8,192-byte scratch arrays. The thin
entry occupies 40 machine-code bytes and tail-jumps to either the retained
public entry or that helper. The retained public entry's instruction sequence
matches the frozen reference after normalizing relocated addresses. Adding
these call sites also made the compiler outline the old experimental entry's
large helper, another reason to compare the new candidates against the
retained public entry rather than assuming the old experiment's code layout
remains fixed. These are code-generation findings, not timing conclusions.

The existing single-divisor kernels have a carry-dependent recurrence. SIMD
and dependency acceleration are unchanged in this call-boundary experiment;
there is no new packed-arithmetic claim. The primary question is whether
dispatch and compiler layout retain the known arithmetic gains without
penalizing bypassed paths.

## Signedness

BLIP leaves signedness to application context. This library chooses signed
two's complement once and caches sign and payload metadata. There is no
per-operation selection between signed and unsigned types.

The representation has costs. A nonnegative magnitude whose top bit is set
needs a zero sign-padding byte. At a payload-length header boundary, that
extra payload byte can also require another header byte. Tests compare powers
of two against native `i256` values at independently listed boundaries:

| Absolute value | Positive encoded bytes | Negative encoded bytes |
|---|---:|---:|
| 2^7 | 3 | 2 |
| 2^15 | 4 | 3 |
| 2^63 | 10 | 9 |
| 2^183 | 25 | 24 |
| 2^247 | 34 | 32 |

At 2^183, the negative value fits the 24-byte inline buffer while its positive
counterpart requires heap storage. These are encoded lengths and inline
decisions, not whole-object memory measurements.

Division copies payloads to scratch and negates negative inputs before its
unsigned magnitude kernel, then restores quotient/remainder signs. That is a
cost of this signed representation and implementation. Adding a signedness
tag to BLIP would not by itself remove those conversions. A separate
sign-and-magnitude design or algorithm-local unsigned residues could have
different tradeoffs; neither has been qualified by this experiment.
