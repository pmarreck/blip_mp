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

## Results and decision

Campaign `blip-mp-isolation-20261102T184821Z` measured source
`b1f8575a8098b7eaffb1826227fc64afb6269826` on Linux x86_64, Threadripper
3990X, Zig 0.16.0 ReleaseFast and GMP 6.3.0. All 225 processes, including the
single permitted retries, verified every result. Ten cohorts finished
`UNBASELINED`; fourteen remained `INCONCLUSIVE`. No epoch was approved.
Measurements were recorded at 18:49:02–19:01:51 UTC. These verdicts qualify
the timing conclusions; correctness passed throughout.

Each ratio below is the median of thirty paired CPU sample ratios from the
final five-process attempt. A dagger marks an inconclusive cohort. The
[candidate summary](division-isolation-summary.jsonl) preserves all 312 cells,
sample ranges, process-mean ratios and diagnostic attempts. The
[reference summary](division-isolation-before-summary.jsonl) preserves the
78 cells from `blip-mp-isolation-before-20261102T183444Z`.

| Candidate | Dividend / divisor bytes | Candidate/public CPU, 1 / 12 CPUs | Candidate/GMP CPU, 1 / 12 CPUs |
|---|---:|---:|---:|
| Isolated | 4,096 / 1 | 0.530† / 0.579† | 1.902† / 1.978 |
| Isolated | 4,096 / 8 | 0.584† / 0.587 | 1.911† / 1.910† |
| Thin | 4,096 / 1 | 0.563 / 0.528† | 1.989† / 1.973† |
| Thin | 4,096 / 8 | 0.539 / 0.566† | 1.916 / 1.903 |

Both candidates retain about 41–47% lower CPU time than the retained public
entry at these 4,096-byte dividends. Every process mean, including diagnostics,
favored a candidate in these cells; the full process-mean range was
0.516–0.746 times public CPU. Both still take 1.90–1.99 times GMP's CPU.
These calls include the signed BLIP adapter costs described above.

Bypassed inputs still prevent a clean automatic-dispatch conclusion:

| Candidate | Dividend / divisor bytes | Candidate/public CPU, 1 / 12 CPUs | Paired CPU difference, ns, 1 / 12 CPUs |
|---|---:|---:|---:|
| Isolated | 8 / 1 | 1.011† / 0.998† | +0.74 / -0.15 |
| Isolated | 8 / 9 | 1.016 / 1.055† | +1.54 / +6.37 |
| Thin | 8 / 1 | 1.027 / 1.046† | +1.94 / +2.34 |
| Thin | 8 / 8 | 1.037 / 1.048† | +2.28 / +3.69 |

For the thin 8-byte-dividend/1-byte-divisor control at 12-CPU affinity, all
ten process means across both attempts were higher than the public reference.
The isolated control results cross parity between processes and cohorts, so
their small differences cannot establish either absence or persistence of a
regression. Neither candidate justifies changing automatic public dispatch.
The explicit experimental entries remain available for known workloads; their
large-input gains do not establish an improvement for every call site.

Call isolation achieved the intended code layout, but it did not establish
regression-free selection. The next dispatch study would need to resolve the
remaining small-call costs and noise rather than assume the operand guard
alone is sufficient. No further retry or baseline approval was taken here.

Source SHA-256 remained
`bd901c5e96f3d0039a7548a817790f1c6c580cc4bc600652193c48ccce4b99aa`.
The executable SHA-256 was
`09fcb692f9afe19e31b47fd54779c06831acd0a1d04743a7f3d2587f5d8ed9d4`.
Reproduce with `./bm --verified-division --config profiling-division-isolation.json`;
use `profiling-division-isolation-before.json` at its recorded source revision
for the frozen reference. Historical approval remains a separate owner decision.

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
