# Performance follow-up, October 14, 2026

The 4.41–7.31 ns immediate-add variation remains unexplained. Source inspection
provides reasons to improve the measurement before drawing a new conclusion:

- `benchmarkMpAdd` starts timing without an in-process warmup, records only
  monotonic wall time, and does not independently check the computed sums.
- Its input pool is 1..127; sums cross the 127/128 representation boundary.
  The bucket describes operand widths and combines immediate and promoted
  results. Each 256-pair cycle contains 128 of each. Separate result-width
  controls would make a diagnosis more precise. GMP uses the same pool formula.
- The historical runs were not pinned to a declared CPU set. Scheduling,
  frequency and code placement remain hypotheses, not established causes.

No new timing or GMP-win claim follows from this source inspection. The next
measurement milestone needs a verified optimized probe, in-process warmups,
CPU and wall samples, and separate one-core and 12-core cohorts through the
shared performance-profiling engine. Keep observations outside this repository
and leave new cohorts unbaselined until explicitly approved. Compare unchanged
workloads; do not silently replace the historical mixed-result bucket with a
cheaper immediate-only workload.

The legacy roadmap's request for N-run aggregation is stale: `./bm --stable N`
already implements repeated runs and median/range output, as recorded in the
roadmap's completed-work section. That does not satisfy the newer external
history and performance-gate contract. Adoption of that contract remains work.

The unit module also contains five legacy `bench:` tests in `src/tier3.zig`
that print wall-clock timings without result assertions. Move those workloads
to verified optimized probes during that adoption. Their incidental output
from the ReleaseSafe correctness suite is not performance evidence.

The bounded correctness follow-up is the separately recorded ReleaseSafe panic
when adding zero in place. It can be repaired and checked without changing the
performance claims or starting an unbounded benchmark campaign.

## Verified immediate-add probe, October 27, 2026

`./bm --verified-add` delegates to the pinned shared performance engine through
the Nix development environment. `profiling.json` declares mixed, immediate-only
and promoted-only result fixtures, each measured in separate 1-core and 12-core
affinity cohorts. The kernel is single-threaded in both cohorts. Each case starts
five fresh processes, each with 250,000 warmup additions and five timed samples of
5,000,000 additions. The fixture is deterministic; the engine seed is recorded
but does not alter it.

The mixed pool retains the historical 256 values and adjacent-pair traversal.
Its 256-operation cycle has 128 immediate and 128 promoted results. The control
pools use 1..63 and 64..127, respectively. All fixtures reuse one result object,
as the historical benchmark does.

Every timed result is consumed, decoded and added to a checksum. Native integer
sums computed outside timing supply the oracle. Tests reject incorrect sums,
skipped work, corrupted inputs, malformed clock values and invalid CLI arguments.
The optimized CLI's JSON and all three cycle checksums are checked in Nix; the
ReleaseSafe oracle tests are included in `./test`.

The method is `immediate-add-checksum-v1`. CPU and wall samples include result
decoding, checksum accumulation and the optimizer barrier. No bookkeeping time
is subtracted. These values cannot be compared numerically with the earlier
4.41–7.31 ns measurements to claim an arithmetic improvement. The first useful
comparison is variation across equivalent runs and between the three fixtures.
CPU samples drive the engine's comparison; wall samples remain supplemental data.
The broad absolute bounds are sanity limits, not a performance promise. New
cohorts remain unbaselined until an explicit owner-approved epoch exists.

History stays outside the checkout. The default is the shared configured path;
an existing writable directory can be selected with `--history-url` or
`PERFORMANCE_HISTORY_URL`. For example:

```bash
mkdir -p "$HOME/.local/state/performance-profiling"
export PERFORMANCE_HISTORY_URL="file://$HOME/.local/state/performance-profiling"
./bm --verified-add --seed 0
```

On shared Linux hosts, prepare the Nix development environment first, then run
the engine under the installed resource wrapper:

```bash
nix develop -c true
build-budget --project blip_mp -- nix develop -c performance-profile run --mode bm --seed 0
```

Fresh host measurements are separate from cached Nix correctness checks. The
engine's exit status 3 means unbaselined or inconclusive, not a green gate.
SIMD and auto-vectorization changes are deferred until this measurement method
establishes the bottleneck; the current work changes measurement only. Existing
GMP comparisons and the legacy timing workloads remain available through the
older `./bm` modes. Migration of the five timing-only unit tests remains open.

### First observations

The October 27 campaign ran on Linux x86_64, an AMD Threadripper 3990X,
with Zig 0.16.0 ReleaseFast. CPU affinity was `0` or `0-11`; the recorded
one-minute host load average was 48.46. All 45 probe processes, including
automatic retries, verified their results. The source digest stayed unchanged.

Each mean below is from the engine-selected median process of the last attempt.
Ranges cover all 25 samples across that attempt's five processes. Units are
nanoseconds per addition including decoding/checksum overhead.

| Fixture | Allowed CPUs | CPU mean | Wall mean | CPU sample range | Attempts | Verdict |
|---|---:|---:|---:|---:|---:|---|
| Mixed | 1 | 5.98 | 6.04 | 5.65–8.15 | 1 | Unbaselined |
| Mixed | 12 | 6.02 | 6.06 | 5.67–9.79 | 1 | Unbaselined |
| Immediate | 1 | 4.75 | 4.85 | 3.65–5.71 | 2 | Unbaselined |
| Immediate | 12 | 5.11 | 5.19 | 3.75–8.87 | 2 | Inconclusive |
| Promoted | 1 | 16.91 | 17.40 | 12.26–25.29 | 2 | Inconclusive |
| Promoted | 12 | 14.70 | 15.40 | 8.21–18.91 | 1 | Unbaselined |

The promoted 12-CPU process means were 14.70, 14.77, 15.48, 8.53 and 8.55 ns.
The selected process passed the within-process noise check, but the full record
still has substantial variation between processes. No baseline was approved.
This is evidence that variation persists with verified work and CPU affinity;
it does not establish why the historical results varied. CPU variation means
time spent descheduled alone cannot explain it. CPU frequency, cache and code
placement remain hypotheses. Sequential fixture runs also confound result-width
comparisons with changes in host load. No GMP comparison was run in this campaign.

External observation IDs use prefix `blip-mp-add-20261028T0132Z-` plus each
case name in `profiling.json`. Their recorded source digest is
`683afef6e9eaee85aa17c55da737e4aebe422730121dde979046faaa780ddf21`.
The next diagnostic should collect cycle/instruction evidence and interleave
fixtures, rather than approve these noisy observations or loosen the policy.

The complete correctness suite passed in 284 seconds including preparation.
Process inspection observed the unit executable running for over a minute,
separately from compilation. In addition to the five division timing tests,
`bignum.zig` has an inverse-modulo timing test with correctness assertions.
Preserve those assertions when moving its repeated timing work out of the unit
suite. Precise per-test execution attribution remains outstanding.

### Interleaved hardware-counter diagnostic

`profiling-linux-counters.json` defines the next diagnostic using the same
verified additions, five fresh processes, 250,000 warmup additions per fixture
and 5,000,000 additions per sample. Each process prepares all three fixtures,
then measures six rounds. The order rotates through mixed, immediate and
promoted, giving every fixture two visits to each position. This reduces the
confounding from running whole fixture campaigns consecutively.

The Linux adapter opens grouped hardware CPU-cycle and retired-instruction
events for the calling thread, excluding kernel and hypervisor execution. It
matches returned event IDs, subtracts cumulative snapshots between samples and
rejects empty, malformed or multiplexed observations. It never scales counts
or substitutes zero after a failed syscall. CPU duration still uses the process
clock, while counters cover the calling thread only. The counter interval also
includes clock reads and the user-space counter-control boundary; no overhead
is subtracted. Enabled/running durations are retained as raw nanoseconds.
The [Linux perf API](https://man7.org/linux/man-pages/man2/perf_event_open.2.html)
defines these scopes and group-read fields.

This is method `interleaved-add-counters-v1`, a separate measurement definition
from the first campaign. The shared engine compares only the mixed fixture's
CPU samples. All six CPU, wall, cycle and instruction samples for every fixture
remain in each raw report as supplemental diagnostics. The one-CPU and 12-CPU
cases remain single-threaded kernels with different allowed CPU sets. Neither
case provides a GMP comparison.

Run the Linux diagnostic with an existing writable external history directory:

```bash
nix develop -c true
build-budget --project blip_mp -- nix develop -c performance-profile run \
  --config profiling-linux-counters.json --mode bm --seed 0
```

Counter access is required; unavailable counters cause a failed diagnostic.
The command does not change host permissions or scheduling policy. A small
native qualification run successfully read both hardware events without
multiplexing. It establishes adapter access, not a timing result. Deterministic
tests use injected counters and clocks to check sample accounting, rotation,
failure propagation and cleanup; the complete suite includes them. Live PMU
measurements remain separate from cached Nix checks.

The first interleaved campaign ran at 02:25 UTC on October 28 (October 27 EDT),
on the same CPU/compiler with a recorded load average of 18.83. All ten
processes verified their sums, and all 180 samples had equal enabled/running
counter durations. Neither cohort needed a retry. Both verdicts were
`UNBASELINED`; no anchor was approved.

CPU means below come from the process selected by the mixed fixture's median
process mean. Ranges cover all 30 samples per fixture/cohort. Instructions are
rounded; the largest observed span was under 0.00005 instructions per addition.

| Fixture | Allowed CPUs | Selected CPU ns/add | CPU range | Cycles/add range | Instructions/add |
|---|---:|---:|---:|---:|---:|
| Mixed | 1 | 7.90 | 5.61–8.52 | 22.36–33.81 | 89 |
| Immediate | 1 | 5.27 | 3.49–5.45 | 13.89–21.57 | 58 |
| Promoted | 1 | 10.38 | 7.65–11.78 | 30.47–46.72 | 120 |
| Mixed | 12 | 5.82 | 5.60–7.16 | 22.32–28.50 | 89 |
| Immediate | 12 | 3.55 | 3.46–4.93 | 13.87–19.60 | 58 |
| Promoted | 12 | 7.78 | 7.63–9.04 | 30.42–36.02 | 120 |

The one-CPU mixed fixture's cycle/CPU-nanosecond ratio was 3.940–3.987,
while cycles per instruction ranged from 0.251 to 0.380. The other fixtures
changed similarly between those processes. This evidence points toward changing
execution efficiency despite stable instruction counts. Clock-rate variation
alone is insufficient to explain this campaign. It does not distinguish shared
core contention, cache behavior or code placement, and it does not establish
the cause of the historical measurements. The cycle/time ratio is a diagnostic
ratio with different user/thread and process-clock scopes, not a direct clock
frequency measurement. Separate contemporaneous controls are still needed.

Observation IDs use prefix `blip-mp-counters-20261028T0225Z-` followed by the
case names in `profiling-linux-counters.json`. The unchanged source digest was
`7e0512dc5e8b6a910959e97562fe079b53576a52fd9f1da0be148e907b29bdf8`.
The complete native suite and production build passed in 148 seconds combined;
118 seconds were the mixed Nix preparation/check phase. All-system evaluation
passed; only Linux x86_64 executed these tests and counter measurements.

## Unit latency and inverse probe

A fresh ReleaseSafe attribution run at source commit `c34cf02` measured the
502 core unit tests individually using a diagnostic copy of Zig 0.16.0's own
test runner. Monotonic timestamps surrounded each server-mode test, including
its setup and allocator cleanup. Assertions, result reporting and leak checks
were retained. Compiler time was separate: the build summary reported 41
seconds compiling the core unit executable and 41 seconds running it.
The measured per-test total was 40.995 seconds; process/protocol overhead is
outside that sum. This was a diagnostic measurement under the Nix builder,
not a fresh historical performance gate or a five-second budget pass.

| Test group | Measured wall seconds |
|---|---:|
| Repeated inverse-modulo benchmark | 16.813 |
| CRT multiplication fuzz, 100 iterations at 4096–16384 bytes | 9.946 |
| Lehmer/classical inverse comparisons | 4.271 |
| Stein/Lehmer inverse comparisons | 3.801 |
| Recursive/wider HGCD comparisons | 1.613 |
| Large asymmetric Burnikel–Ziegler division comparisons | 1.568 |
| Wider HGCD/Lehmer comparisons | 1.506 |
| All five division timing tests together | 0.036 |

The inverse timing loop was the largest removable timing-only cost. Its core
unit test now executes each original algorithm/width combination once, retains
every result equality assertion and also compares the returned existence flags.
The 12 widths, fixed random seed and 4096-bit bound for recursive HGCD remain.
The five division timing tests are still pending migration. Expensive correctness
cases remain in the complete suite; their coverage has not been reduced to meet
a timing target.

`./bm --verified-inverse` runs `profiling-inverse.json` through the shared engine.
It defines one-CPU and 12-CPU affinity cohorts for each of the four algorithms,
with five fresh processes, five samples per width and the historical iteration
counts. Fixture construction and GMP inversion happen before timing. Each
measured iteration checks both inverse existence and the full result against
GMP; these checks and any kernel allocations are included in CPU/wall timings.
One warmup call precedes each width. This is method `inverse-gmp-verified-v1`,
so its numbers are not interchangeable with the old unchecked unit timings.

The safety-enabled probe tests check all 47 supported algorithm/width pairs
against GMP and reject deliberate wrong values, negative values and incorrect
existence flags. The optimized CLI protocol checks cover every algorithm,
multiple width rows, routing through `./bm` and refusal of recursive 8192-bit
work. Both sets are part of `./test`; live performance runs stay outside cached
Nix checks. No algorithm dispatch, arithmetic implementation or historical
baseline changes are part of this migration.

A second fresh attribution run measured the retained inverse fixture test at
0.272 seconds, down from 16.813 seconds. The same 502 core tests totaled
24.352 seconds, versus 40.995 before the refactor. The new independent GMP
probe test executable added 0.277 seconds; immediate-add probe tests took
0.006 seconds. Core compilation took 44 seconds in that run. These are two
observations on a shared host, not a general speed guarantee. Arithmetic
performance was not changed. Core execution alone still exceeds the five-second
budget, with CRT fuzz remaining the largest test at 9.644 seconds.

The uninstrumented complete suite, optimized CLI protocol checks, 13,111 GMP
comparisons and production build passed in 109 seconds combined. All-system
evaluation passed; correctness and attribution execution were Linux x86_64 only.

The first optimized inverse campaign ran from 02:49:19 to 02:50:48 UTC on
October 28, at commit `3c9fb33`, with recorded host load 18.55. All 60 fresh
processes, including four automatic retries, verified their results. Five
cohorts remained unbaselined and three were inconclusive. No baseline was
approved. The fixed 128-bit and 8192-bit operand pairs have no inverse; their
timings measure the negative result path, not successful inversion.

The nominal 4096-bit pair does have an inverse. Selected-process mean CPU microseconds
per verified call are shown below, including result comparison overhead.
Algorithms ran in separate cases, so host variation limits comparisons.

| Algorithm | Allowed CPUs | 4096-bit µs/call | Attempts | Verdict |
|---|---:|---:|---:|---|
| Lehmer | 1 | 185.90 | 1 | Unbaselined |
| Lehmer | 12 | 191.19 | 2 | Inconclusive |
| Wider HGCD | 1 | 131.10 | 1 | Unbaselined |
| Wider HGCD | 12 | 132.54 | 2 | Inconclusive |
| Recursive entry, wider-HGCD fallback | 1 | 132.34 | 1 | Unbaselined |
| Recursive entry, wider-HGCD fallback | 12 | 137.66 | 2 | Inconclusive |
| Stein | 1 | 7885.17 | 1 | Unbaselined |
| Stein | 12 | 8171.44 | 2 | Unbaselined |

All widths and samples are retained in external observations with prefix
`blip-mp-inverse-20261028T0249Z-` and the case names in `profiling-inverse.json`.
The source digest stayed
`f3ef329623ba01cb7ca7cd5aa667655eb96e455df23c1dd3aa428014860b1708`.
GMP supplied correctness results outside timing; this campaign did not measure
GMP's performance or justify changing production inverse dispatch thresholds.

An October 28 width audit found that the historical generator sets the modulus's
highest payload byte to `01xxxxxx`. Every modulus therefore has one fewer
significant bit than its nominal payload capacity. In particular, the largest
allowed recursive-entry fixture is 4095 bits, below that entry point's
4096-bit recursive threshold. Every row labeled `recursive` in this campaign
executes a fallback; none measures recursive HGCD performance. The table above
now names that distinction explicitly.

The probe now reports each row's `modulus_bits` alongside its unchanged nominal
`size`. The CLI check failed before that field was added, and fixture tests
assert the exact significant width at every historical size. This metadata
addition preserves the inputs and timed work. A separate exact-width corpus
at and above the recursive threshold is required before comparing recursive
HGCD or changing its dispatch. Existing direct `hgcdRecursive` matrix tests
exercise a different entry point and do not fill this measurement gap.

The metadata correction passed the complete native suite in 132 seconds of
mixed Nix preparation/check time, plus the production/probe build and all-system
evaluation. It introduces no arithmetic or dispatch change.

The first exact-width correctness corpus uses deterministic dense operands at
4095, 4096 and 4097 significant modulus bits. Moduli are positive and odd;
the other operand has one fewer significant bit. Full-byte payloads receive
the required positive sign padding. Both wider-window and recursive inverse
entry points are checked against GMP, so the last two widths cross the
recursive wrapper's threshold. This is one operand pair per width, not a
performance sample or broad input-distribution study.

The original fixture failed the new width check with `expected 4096, found
4095`. The exact-width generator then passed those oracle checks. The initial
six-test inverse probe executed in 347 ms after 28 seconds of compilation;
the Nix build phase took 34 seconds. Separate checks classify the accepted
width set and inject failures through each fixture allocation. The inverse
probe build/test phase has a 120-second safety deadline and reports compilation
and test execution durations separately. Historical inputs and timings remain
unchanged; exact-width timing needs a separate paired measurement.

The complete native suite then passed in 91 seconds of mixed Nix
preparation/check time, including the accepted-width and allocation-failure
controls. Production/probe builds and all-system evaluation also passed.

### Paired exact-width inverse probe

Run `./bm --verified-inverse --config profiling-inverse-paired.json` to compare
wider-window HGCD and recursive inverse calls on the same exact-width corpus.
Each 4095-, 4096- and 4097-bit odd modulus width has sixteen deterministic
cases. Fourteen use a positive operand one bit smaller; the final two use
one and zero to guarantee invertible and noninvertible controls. The original
single-pair fixture is preserved as case zero. Fixture seeds are
`(0xEAC74096 XOR modulus_bits) + index*65537`.

Each method visits every case once per sample, with six alternating ABBA/BAAB
half-pool samples after a complete warmup. The previously tested paired timing
helper now accepts either algorithm enum. Its injected-clock, work-count and
linear-drift controls are shared with division. Inputs and GMP references are
prepared before timing; arithmetic allocation and full inverse/existence
verification remain inside timing. The result object is reused. Primary engine
values average both methods; component ratios compare them within each sample.
This experiment does not time GMP. Both affinity cohorts use five fresh
processes with a 120-second deadline per process and one permitted variation
retry. SIMD work remains deferred until this comparison establishes which
algorithmic path warrants profiling.

The corpus test failed when the placeholder repeated the old fixture. Parser,
pool verification and allocation-cleanup tests then failed against their
placeholders, and the CLI check failed before the new route was connected.
The corruption control changes the known inverse of one and requires both
methods to reject it. Width tests cover the complete bounded acceptance set.
No arithmetic or public dispatch change is part of the probe.

The thirteen inverse-probe tests execute in 511 ms after 32 seconds of
compilation. The complete native suite passed in 106 seconds of mixed Nix
preparation/check time. The production build and all-system evaluation passed.

### Paired exact-width inverse results, October 28, 2026

Campaign `blip-mp-inverse-exact-paired-20261028T171403Z` measured commit
`6638200dfb1a1715ad7f84f07a001c5b68576b1c` on Linux x86_64, Threadripper
3990X, Zig 0.16.0 ReleaseFast. All fifteen processes, including the variation
retry, verified every result against GMP. The source digest remained
`2ba265d52bea4e6aa98fbf80bd0d767c295432fe805a52a213d8d5b66a519f13`.
The single-CPU cohort is `UNBASELINED` after one attempt; the 12-CPU affinity
cohort is `INCONCLUSIVE` after two attempts. No baseline was approved. The
campaign waited about four and a half minutes for shared resource admission;
that wait is outside the timings. Measurements were recorded at 17:18:42–44 UTC.

Median within-sample recursive/wider-window CPU ratios across five selected
processes and six samples per process are:

| Significant modulus bits | Invertible cases / 16 | 1-CPU ratio | 12-CPU affinity ratio |
|---:|---:|---:|---:|
| 4,095 | 13 | 1.003 | 1.000 |
| 4,096 | 14 | 3.379 | 3.380 |
| 4,097 | 12 | 3.324 | 3.328 |

The 4,095-bit row invokes the same wider-window algorithm through both entry
points and remains near parity. At 4,096 and 4,097 bits, every process mean,
including diagnostics, favors wider-window HGCD. Recursive/wider-window ratios
range from 3.229 to 3.504. This supports retaining current public inverse
dispatch; it does not establish behavior at much larger widths or prove which
operation dominates recursive cost. The experiment does not time GMP.

The [summary](../benchmarks/storage-aware/inverse-paired-summary.json) preserves
component timings, paired ranges, and all process-mean ratios. Full samples
remain in external history under the campaign prefix and
`inverse_exact_paired_1core` / `inverse_exact_paired_12core` suffixes. The stale
source comments describing a 1,024-bit boundary and promising a future FFT
win have been corrected. The explicit recursive entry boundary remains 4,096
bits for controlled comparison; it is not a measured profitability crossover.

## Division probes

`./bm --verified-division` runs the six workloads formerly embedded in five
timing-only unit tests: byte-base Knuth at 2048/1024 bits, chunk-reading Knuth
at 2048/1024, 4096/2048 and 8192/4096 bits, and a 2048-bit dividend divided
by 101 or 65537. Seeds, random draw widths, operands and buffer-reset behavior
are retained. All stored benchmark input/work data use byte buffers.

Each fixture computes GMP's quotient and remainder before timing. Every measured
iteration compares the complete results, including zero-padding normalization.
The new `division-gmp-verified-v1` timings include those comparisons, required
input-buffer resets and an optimizer barrier. They cannot be substituted for
the former unchecked unit-test timings. The two single-divisor cases have
different divisors; their ratio is not an isolated kernel comparison.

`profiling-division.json` declares separate one-CPU and 12-CPU affinity cohorts,
five fresh processes and five samples per fixture. Batch sizes are explicit:
20,000 byte-base divisions; 100,000/50,000/20,000 chunk-reading divisions at
the three widths; and 200,000/500,000 single-byte/single-chunk divisions.
These are steady-state measurements with prepared storage and one warmup call;
fixture allocation and GMP calculation are outside timing. Allocation costs
remain unmeasured.

The complete correctness entry point runs all six fixtures repeatedly against
GMP, checks failure after deliberate quotient corruption, rejects wrong
remainders and invalid work counts, and exercises the optimized CLI for every
fixture. The old timing-only tests had no result assertions. Their workloads
remain covered, now with independent quotient/remainder assertions, while
existing division regression and randomized tests are unchanged. No arithmetic
implementation or production dispatch was changed by this migration.

The complete native suite, including the retained six division fixtures and
13,111 existing GMP comparisons, plus the production build passed in 104
seconds combined. The mixed Nix preparation/check phase took 102 seconds.
All-system evaluation passed; execution was Linux x86_64 only. The remaining
unit execution budget finding is unchanged by this small timing-loop migration.

The first division campaign ran at 03:10:30–03:11:08 UTC on October 28, with
host load 13.70 and commit `43c296f`. All 60 processes verified their results;
all 12 cohorts were unbaselined without retries. No baseline was approved.
The table reports selected-process mean CPU nanoseconds per verified division.

| Fixture | 1 allowed CPU | 12 allowed CPUs |
|---|---:|---:|
| Byte-base Knuth, 2048/1024 bits | 24969.71 | 20456.53 |
| Chunk-reading Knuth, 2048/1024 bits | 711.43 | 606.51 |
| Chunk-reading Knuth, 4096/2048 bits | 1928.59 | 1951.09 |
| Chunk-reading Knuth, 8192/4096 bits | 8853.57 | 6870.41 |
| 2048-bit dividend / 101 | 782.24 | 742.48 |
| 2048-bit dividend / 65537 | 141.55 | 110.83 |

The kernels are single-threaded in both cohorts. Between-process variation
remains visible; for example, one-CPU byte-base samples ranged from 20550.38
to 27319.46 ns. The byte-base and chunk-reading fixtures use different random
draw widths, so they are not identical-input comparisons. These results do not
establish a parallel speedup or a win over GMP, whose timings were not measured.
Records use prefix `blip-mp-division-20261028T2310EDT-` plus the configured
case names. Their actual chronology is the UTC interval above. Source stayed
`da51a8e8fcdd590ca4098aff7d04c14ec9baf54422abc2abe99269397ca8e7e8`.

### Identical-input division comparison

Run `./bm --verified-division --config profiling-division-paired.json` to compare
the existing Burnikel–Ziegler and chunk-reading Knuth byte-buffer entry points.
The `division-paired-kernels-v1` workload uses divisor widths of 64, 128, 256,
512, 1024 and 2048 bytes, each with a dividend twice as long. These are magnitude
kernel measurements, including their byte-wrapper setup; public signed-BLIP
encoding and sign handling are outside this experiment. GMP supplies full
quotient/remainder reference bytes and is not timed as a competitor.

Each width has 256 deterministic cases seeded by
`0xB2D151A5 + divisor_bytes*257 + case_index`. Divisor top bytes cover all eight
normalization shifts, with dense values mixed into the seeded corpus. Both
methods receive every case and a full warmup pass. Each of five samples repeats
each case four times, for 1024 divisions per method. ABBA/BAAB half-pool batches
alternate by sample; the report retains both CPU/wall components and uses their
mean as its primary engine sample. Mirroring cancels linear drift, but does not
remove nonlinear interference or code-layout effects.

Fixtures and GMP references are prepared outside timing. Arithmetic allocates
through one arena reset before every division, with capacity retained after
warmup for both methods. Arena reset, output poisoning, byte-buffer setup,
complete quotient/remainder comparisons and canary checks are timed. This
measures warmed arithmetic allocation behavior, not cold allocation cost.
The two affinity cohorts each use five processes and a 120-second process
deadline. No historical baseline is approved.

The allowed-width classifier exhausts widths zero through 4099 and checks
ordered-list constraints; it failed against an always-rejecting parser. The
shared fixture tests cover all 16 allowed widths, including odd lengths and
small-divisor boundaries, and reject corrupted GMP quotients. Partial allocation
failures are injected through both algorithms. Timing tests first failed against
empty adapters, then check equal case coverage, normalization, mirrored order,
linear drift and error propagation. Injected clocks reject stopped/backward CPU
or wall time. The new CLI report failed before its command was implemented.

This establishes a comparison method before changing native leaf dispatch or
recursive cutoffs. The existing four-byte recursion cutoff and small byte-Knuth
leaves are candidates for measurement, not evidence of a particular speedup.
The complete native suite passed in 112 seconds of mixed Nix preparation/check
time, with 15,535 integration GMP comparisons unchanged. Production build and
all-system evaluation also passed.

### Paired division baseline result

Campaign `blip-mp-division-paired-20261028T093148Z` measured commit
`d842aafd49da4087d3fac34db0c6555a6200acab`, with source hash
`e7141dae4b1d35013023ca1a842581c9f26729de91b6e4a38cf9f233ae611311`
unchanged. All ten processes verified their results. Both cohorts were
`UNBASELINED` after one attempt, with no approved baseline epoch. The campaign
spent at least four minutes in the admission queue, separate from execution.

| Divisor bytes | B-Z/Knuth paired CPU median, 1 CPU | B-Z/Knuth paired CPU median, 12 CPUs |
|---:|---:|---:|
| 64 | 70.19 | 70.36 |
| 128 | 64.73 | 64.80 |
| 256 | 52.58 | 52.69 |
| 512 | 35.59 | 35.50 |
| 1024 | 20.73 | 20.77 |
| 2048 | 11.57 | 11.56 |

Each median uses 25 paired sample ratios across five processes. The
[summary](../benchmarks/storage-aware/division-paired-summary.json) preserves
process means, ratio ranges, selected CPU/wall components and cohort verdicts.
The narrowing gap does not establish a crossover beyond the sampled widths.
These ratios compare existing magnitude kernels, with warmed allocation setup
included, and do not time GMP or public signed operations.

The current recursion reaches a four-byte cutoff, where tiny byte-Knuth leaves
and recursive setup can dominate. Before tuning it, the separate
`profiling-division-boundary.json` sweep covers 31/32, 63/64/65 and 127/128/129
divisor bytes. The B-Z entry point currently falls back to byte-Knuth for small
or odd divisor lengths; those rows must not be described as recursive B-Z.
The boundary configuration keeps the same workload and timing method, with
distinct case names and a `division-paired-boundary-v1` definition.

Campaign `blip-mp-division-boundary-20261028T094156Z` measured commit
`fd60b6978f2c8b081bb3307309315145e49994b5`, with source hash
`fb7d7eec93426ed9fab075b9d35a3e2de75d42edd00d0ea65ddce2e903485d35`
unchanged. All ten processes verified, and both cohorts were `UNBASELINED`
after one attempt. The [boundary summary](../benchmarks/storage-aware/division-boundary-summary.json)
keeps process ratios and the selected timing components.

| Divisor bytes | B-Z entry path | Entry/Knuth CPU median, 1 CPU | Entry/Knuth CPU median, 12 CPUs |
|---:|---|---:|---:|
| 31 | Byte-Knuth fallback | 6.51 | 6.63 |
| 32 | Byte-Knuth fallback | 6.73 | 6.75 |
| 63 | Byte-Knuth fallback | 11.64 | 11.68 |
| 64 | Recursive B-Z | 69.82 | 69.56 |
| 65 | Byte-Knuth fallback | 11.38 | 11.43 |
| 127 | Byte-Knuth fallback | 18.64 | 18.68 |
| 128 | Recursive B-Z | 64.66 | 64.75 |
| 129 | Byte-Knuth fallback | 18.33 | 18.43 |

These medians again use 25 paired sample ratios per size and cohort. They
separate the slower fallback from the still larger recursive overhead.
Neither campaign establishes a benefit from changing the recursive cutoff.

### Chunk-reading fallback experiment

The explicit `divModBurnikelZieglerChunkFallback` variant replaces only the
top-level small/odd-divisor fallback with the existing `divModBZLeaf` dispatcher.
That leaf already uses chunk-reading Knuth above eight divisor bytes and
byte-Knuth at smaller widths. The initial experiment kept the recursive calls,
cutoff and default entry point unchanged. The shared GMP fixture tests failed against an empty
candidate before passing with the reused leaf, including allocation failures.

Run `./bm --verified-division --config profiling-division-fallback.json` for a
paired old/new comparison on the boundary corpus. The 64/128-byte recursive
rows serve as unchanged algorithm controls. The `division-paired-fallbacks-v1`
mode retains the same fixtures, workload counts, allocation coverage and
mirrored timing as the baseline. Pair-selection and equal-coverage tests cover
both comparisons; warmup visits only the selected pair.

The complete native suite passed in 96 seconds of mixed Nix preparation/check
time. The production/probe build and all-system flake evaluation also passed.
This duration includes compilation and is not a test-execution measurement.

### Fallback result and selection

Campaign `blip-mp-division-fallback-20261028T101244Z` measured commit
`0642c6e49b4e94207a2b65b5042f12d7d39b274e`. Its source hash stayed
`2bc2c82afffd422fd1f14a85900716b2b0e878346031d93b0655f6ec5e02953c`.
All 15 processes verified their complete quotient/remainder results. The
one-CPU cohort was `UNBASELINED` after one attempt; the 12-CPU cohort remained
`INCONCLUSIVE` after its one permitted variation retry. No baseline was approved.
Shared admission delayed execution by more than ten minutes; that wait is
excluded from the samples.

| Divisor bytes | Path | Chunk/byte paired CPU median, 1 CPU | Chunk/byte paired CPU median, 12 CPUs |
|---:|---|---:|---:|
| 31 | Fallback | 0.161 | 0.161 |
| 32 | Fallback | 0.159 | 0.162 |
| 63 | Fallback | 0.086 | 0.086 |
| 64 | Unchanged recursion | 1.000 | 0.999 |
| 65 | Fallback | 0.089 | 0.088 |
| 127 | Fallback | 0.053 | 0.053 |
| 128 | Unchanged recursion | 0.998 | 0.998 |
| 129 | Fallback | 0.054 | 0.054 |

These are medians of 25 paired sample ratios from each selected attempt. Every
fallback process mean, including the diagnostic attempt, favored chunk reading.
The sampled fallback gains are about 6–19×, while unchanged recursive medians
stay within 0.2% of parity. Individual control process ratios ranged from about
0.969 to 1.058. The [summary](../benchmarks/storage-aware/division-fallback-summary.json)
retains all process ratios, selected CPU/wall components and cohort verdicts.

The default B-Z entry point now reuses the chunk-reading leaf for its fallback.
The old byte fallback remains explicit as `divModBurnikelZieglerByteFallback`,
and the paired probe labels it `burnikel_ziegler_byte_fallback` so later runs
keep a fixed control. GMP and allocation checks also exercise the default
entry point. That selection left the four-byte recursive cutoff and the public
B-Z integration threshold unchanged. This is a magnitude-kernel improvement; it neither
times GMP nor establishes a public signed-division speedup at the sampled sizes.

After selection, the complete native suite passed in 93 seconds of mixed Nix
preparation/check time. The production/probe build and all-system evaluation
also passed. The corpus now checks the default and all explicit B-Z variants,
including the exact-capacity remainder regression.

### Recursive cutoff experiment

The paired baseline leaves a separate recursive cost after the top-level
fallback is addressed. `divModBurnikelZieglerCutoff128` keeps the chunk-reading
fallback and raises only the recursive leaf condition from `n < 4` to
`n < 128` divisor bytes. For the sampled powers of two, this stops at 64-byte
leaves. The original recursion remains available as the comparison control.
The value 128 is a bounded first candidate, not a calibrated optimum.

Run `./bm --verified-division --config profiling-division-cutoff.json` for the
`division-paired-cutoffs-v1` comparison. It covers 64–2048-byte recursive
divisors plus 63/127/129-byte unchanged fallback controls. Both methods receive
identical inputs, allocation setup and GMP quotient/remainder checks. The
empty candidate failed the fixture and allocation tests before implementation;
the new CLI route also failed before being connected. Injected timing tests
cover both batch orders and exact input coverage for every comparison pair.

This experiment reduces recursive work before considering instruction-level
changes. No SIMD or compiler-vectorization claim follows from the baseline:
the current evidence measures complete calls, not an instruction profile.
The initial experiment kept the production cutoff at four bytes.

The complete native suite passed in 91 seconds of mixed Nix preparation/check
time. The production/probe build and all-system evaluation passed as well.

### Recursive cutoff result and selection

Campaign `blip-mp-division-cutoff-20261028T102909Z` measured commit
`64a07ec3f4c920af74a14993fcd640f6546ffffb`, with source hash
`24a6a526c5185b847b0cf40d1a8147c6b9f2863bad89d6e43035139baee323c5`
unchanged. All 20 processes verified their results. Both cohorts used their
single variation retry: the one-CPU cohort finished `UNBASELINED`, while the
12-CPU cohort remained `INCONCLUSIVE`. No baseline was approved. Admission
waited about seven minutes before the measured processes started.

| Divisor bytes | Path | Cutoff 128/4 paired CPU median, 1 CPU | Cutoff 128/4 paired CPU median, 12 CPUs |
|---:|---|---:|---:|
| 63 | Unchanged fallback | 1.001 | 1.002 |
| 64 | Recursive | 0.062 | 0.062 |
| 127 | Unchanged fallback | 0.998 | 1.002 |
| 128 | Recursive | 0.098 | 0.098 |
| 129 | Unchanged fallback | 1.000 | 0.999 |
| 256 | Recursive | 0.125 | 0.125 |
| 512 | Recursive | 0.150 | 0.150 |
| 1024 | Recursive | 0.181 | 0.182 |
| 2048 | Recursive | 0.220 | 0.220 |

Each median uses 25 paired ratios from its selected attempt. Every recursive
process mean, including diagnostics, favored the larger cutoff. The sampled
CPU savings are about 78–94%, or 4.6–16× speedups. Unchanged-control medians
remain within 0.25% of parity; their process means range more widely, about
0.923–1.130. The [summary](../benchmarks/storage-aware/division-cutoff-summary.json)
preserves the process ratios and cohort verdicts.

The default B-Z entry now uses the 128-byte recursive cutoff and chunk-reading
fallback. Both historical controls retain an explicit four-byte cutoff, and
the private recursion regressions still exercise that deeper tree. The public
B-Z integration threshold remains 99,999 divisor payload bytes. These kernel
measurements do not establish a crossover against Knuth or GMP, nor do they
calibrate 128 as the optimum. Lowering the public threshold requires a separate
comparison against the current public path.

After selecting the cutoff, the complete native suite passed in 101 seconds
of mixed Nix preparation/check time. The production/probe build and all-system
evaluation also passed. Existing private recursion regressions continue to
use the original four-byte cutoff so their deeper recursion remains covered.

### Matched division comparison with GMP

Run `./bm --verified-division --config profiling-division-competitors.json`
to compare public `Mp.divMod`, chunk-reading Knuth, the selected B-Z cutoff,
and GMP's `mpz_tdiv_qr` on identical positive operands. Divisor magnitude
widths span 8–16,384 bytes, with a dividend twice as wide. Each width has 64
deterministic cases covering all eight normalization shifts and dense values.
The report includes the significant divisor-bit range; byte capacity is not
an exact bit count.

Inputs are converted into each library's native representation before timing.
Public BLIP and GMP reuse their output objects. Byte kernels retain warmed
arena capacity; their arena reset and output poisoning remain inside timing.
Every call verifies both complete results: canonical-byte comparisons for public
BLIP, native `mpz_cmp` for GMP, and magnitude/canary checks for the byte kernels.
Thus these are verified-call costs with different native comparison adapters,
not isolated arithmetic-instruction timings or serialization measurements.

Eight samples rotate mirrored ABCDDCBA half-pool batches. Each sample visits
every case equally for every method: 16 repetitions per case through 128-byte
divisors, one repetition above that. The primary engine value averages all four
methods; individual components support within-sample ratios. Both affinity
cohorts use five fresh processes and 120-second process deadlines. No production
dispatch change is part of this comparison.

The empty adapter failed its width, scheduling, oracle, corruption and cleanup
controls. The allocation tests also exposed a fixture allocator-lifetime bug;
retained `Mp` objects now use the stable parent allocator. Small fixtures have
an independent native `u128` quotient/remainder oracle. The CLI assertion failed
before its new route was connected. Existing injected-clock tests cover the
shared timed-batch helper, and the four-method schedule has its own exact
coverage and normalization controls.

The complete native suite passed in 103 seconds of mixed Nix preparation/check
time. The optimized production/probe build and all-system evaluation also
passed. The shared timing helper's cross-module visibility was corrected after
the optimized CLI build exposed it; this did not change arithmetic.

### Matched division results, October 28, 2026

Campaign `blip-mp-division-competitors-20261028T165658Z` measured commit
`9e198bb4cda9bf504e22c35001b4cc9b39a1b63a` on Linux x86_64, Threadripper
3990X, Zig 0.16.0 ReleaseFast and ordinary GMP 6.3.0. All 15 processes,
including the five-process variation retry, verified every quotient and
remainder. The source digest stayed
`2c6da22ca8b26a12c0ed105c30b93628fe4b32c5ca2d5813edd5c19f744985ad`.
The single-CPU cohort was `UNBASELINED` after one attempt; the 12-CPU affinity
cohort was `INCONCLUSIVE` after two attempts because variation exceeded policy.
No baseline was approved. The algorithms are serial; the affinity cohorts do
not establish parallel scaling.

The table gives median within-sample CPU ratios across five selected processes
and eight samples per process. Each cell is **1-CPU / 12-CPU affinity**.
A ratio above 1 means the numerator takes more CPU time. Widths are divisor
magnitude bytes; dividends have twice that width. The
[summary](../benchmarks/storage-aware/division-competitors-summary.json)
also preserves sample ranges and every process-mean ratio, including the
diagnostic attempt. Full samples remain in external performance history under
the campaign prefix and the `division_competitors_1core` and
`division_competitors_12core` suffixes.

| Divisor bytes | Public BLIP / GMP | B-Z / GMP | B-Z / Knuth |
|---:|---:|---:|---:|
| 8 | 1.80 / 1.83 | 7.00 / 7.19 | 4.05 / 4.09 |
| 16 | 2.75 / 2.80 | 3.74 / 3.86 | 1.13 / 1.14 |
| 32 | 2.31 / 2.34 | 3.03 / 3.08 | 1.06 / 1.06 |
| 64 | 2.50 / 2.52 | 13.14 / 13.15 | 4.37 / 4.35 |
| 128 | 2.65 / 2.65 | 20.42 / 20.40 | 6.35 / 6.34 |
| 256 | 2.29 / 2.29 | 17.46 / 17.53 | 6.53 / 6.54 |
| 512 | 2.54 / 2.52 | 14.65 / 14.59 | 5.27 / 5.26 |
| 1,024 | 3.05 / 3.04 | 11.98 / 12.00 | 3.75 / 3.76 |
| 2,048 | 3.86 / 3.88 | 9.87 / 9.91 | 2.50 / 2.49 |
| 4,096 | 5.13 / 5.19 | 8.88 / 9.00 | 1.71 / 1.71 |
| 8,192 | 7.00 / 7.11 | 8.11 / 8.21 | 1.15 / 1.15 |
| 16,384 | 10.91 / 11.13 | 8.50 / 8.65 | 0.773 / 0.771 |

GMP wins at every sampled width, for both public BLIP and the improved B-Z
kernel. Every process-mean comparison, including diagnostics, agrees with that
direction. The earlier 6–19× and 78–94% gains were against the old byte fallback
and four-byte recursive cutoff, respectively. They do not imply wins over GMP.

The improved B-Z kernel crosses Knuth between the sampled 8,192- and
16,384-byte divisor widths for this 2:1 workload. At 16,384 bytes it saves
about 23% of CPU time; every process-mean B-Z/Knuth ratio is 0.765–0.794.
At 8,192 bytes every process mean still favors Knuth, with ratios 1.126–1.226.
This bounds a candidate crossover for the measured geometry, not a universal
dispatch threshold. Public division still uses the 99,999-byte B-Z threshold.
Before lowering it, measure nearby and odd widths, other dividend/divisor
ratios, and the complete public path with a controlled alternative dispatch.
The existing verification overhead differs between the public and kernel
adapters, as described above.

### Explicit signed B-Z entry point

`Mp.divModBurnikelZiegler` exposes the existing signed B-Z wrapper directly for
controlled comparisons with `Mp.divMod`. It preserves truncated division signs,
canonical BLIP results and division-by-zero rejection. It bypasses automatic
algorithm selection; the ordinary public dispatcher is unchanged.

The placeholder failed independent GMP-result and allocation controls before
implementation. Signed cases cover all four sign combinations and all eight
normalization shifts at 8-, 64-, 128- and 256-byte divisor widths, including
quotient/remainder outputs aliasing either input. Native integer boundary cases
also cover zero dividends and minimum signed integer divided by minus one.

The strict standard allocation-failure helper rejected a successful division
when the arena's optional capacity-retention allocation failed afterward. The
qualified control injects every allocation failure and accepts either a fully
verified result or `OutOfMemory`, while requiring induced failure and complete
release of tracked bytes. It covers 16- and 256-byte divisors. This preserves
the arena's documented ability to recover from failed cache retention; it does
not treat incorrect results or leaked memory as successful recovery.

The complete native suite passed in 120 seconds of mixed Nix preparation/check
time; the production build and all-system evaluation passed. An initial
boundary assertion incorrectly used `getU64` for positive `2^63`, although the
current getter decodes through `i64`. It now checks the exact canonical bytes.

### Paired public division probe

Run `./bm --verified-division --config profiling-division-public.json` to compare
ordinary `Mp.divMod` with explicit `Mp.divModBurnikelZiegler`. The configured
divisor magnitude widths are 8,192, 12,288, 16,384 and 16,385 bytes. Separate
cases use dividend widths of divisor-plus-one, twice the divisor, and four
times the divisor. The odd width exercises B-Z's Knuth fallback. Each width
has 32 inputs crossing all four sign combinations with all eight normalization
shifts. Small 64/65-byte widths are available for CLI and correctness controls.

GMP supplies magnitude quotient/remainder references before timing; truncated
sign rules produce each expected canonical BLIP value. Both methods receive
the same native inputs, reuse outputs and warm their thread-local scratch.
Every call compares both complete canonical results inside timing. Six
alternating ABBA/BAAB half-pool samples visit each input once per method.
Primary engine values average the two methods. This experiment does not time
GMP or measure cold allocation. The historical four-method competitor probe
keeps its existing inputs, method definition and workload.

The parser, corpus and partial-construction controls failed against their
placeholders. The corpus test asserts the complete sign/normalization set,
checks all three geometries and both even/odd widths, and makes both methods
reject deliberately corrupted quotient references. The CLI check failed before
the new route was connected. Existing injected timing controls are shared with
the inverse and kernel-division probes. Each geometry has separate one- and
twelve-CPU affinity cohorts, five processes and 120-second process deadlines.
SIMD remains deferred while this experiment tests algorithm selection.

Expanding allocation-failure coverage to all 32 signed cases exposed an existing
`Mp.ensureHeapCapacity` bug. It freed the current buffer before requesting its
replacement. A failed request left the object pointing to freed memory, causing
a double free during fixture cleanup. A focused regression independently
observed 98 bytes freed after an unsuccessful growth request. The replacement
is now allocated before the old buffer is released. The regression requires
the old encoded value to survive allocation failure and all storage to be freed
exactly once afterward. This correction does not change algorithm dispatch.

After the correction, the complete native suite passed in 84 seconds of mixed
Nix preparation/check time. The production build and all-system evaluation also
passed. Both the focused storage regression and the full signed-corpus
allocation sweep are part of the complete suite.

### Signed public division results, October 28, 2026

Campaign `blip-mp-division-public-20261028T174704Z` measured commit
`e7a85740baa52bd94759ab19510a0473b95b3802` with source digest
`55fd2979069e6921095ae9c1cebb6c3c3bd05f2679edb092cb672498768dca00`
unchanged. Linux x86_64, Threadripper 3990X and Zig 0.16.0 ReleaseFast match
the preceding competitor campaign. All 40 processes verified every result.
All six cohorts were `UNBASELINED`; balanced/12-CPU and long-dividend/1-CPU
each needed their one permitted variation retry. No baseline was approved.
Shared admission took about four minutes, excluded from timed samples.

Each cell below is the median B-Z/current CPU ratio for **1-CPU / 12-CPU
affinity**, using thirty paired samples per selected cohort. A value below one
favors explicit B-Z. Widths are magnitude bytes; the odd divisor uses the
Knuth fallback. These serial algorithms do not gain parallelism from affinity.

| Divisor bytes | Dividend = divisor + 1 byte | Dividend = 2 × divisor | Dividend = 4 × divisor |
|---:|---:|---:|---:|
| 8,192 | 59.21 / 59.24 | 1.095 / 1.107 | 0.818 / 0.817 |
| 12,288 | 59.23 / 59.39 | 0.787 / 0.789 | 0.598 / 0.597 |
| 16,384 | 67.97 / 67.81 | 0.724 / 0.756 | 0.560 / 0.559 |
| 16,385 | 1.293 / 1.298 | 1.005 / 1.004 | 0.999 / 0.998 |

The [summary](../benchmarks/storage-aware/division-public-summary.json) preserves
selected CPU/wall components, sample ranges and every process-mean ratio,
including diagnostic attempts. Full external records use the campaign prefix
and the six case names in `profiling-division-public.json`. The primary engine
sample averages both methods; the ratios above use paired components.

At recursive widths, every process mean, including retries, agrees with each
table cell's direction. B-Z saves about 21–28% for the larger balanced inputs
and 18–44% for long dividends. Short quotients instead cost about 59–68 times
the current path. The fallback costs about 29–30% extra for short quotients
and stays near parity for the other geometries. These findings support keeping
the public 99,999-byte threshold unchanged. They do not establish that the
existing threshold is optimal, or that an unconditional lower threshold is safe.
This campaign does not time GMP; the separate matched comparison above remains
the evidence for that competitor.

### Division geometry follow-up

Source inspection identifies two bounded candidates. The current wrapper sends
its highest normalized block through recursive division even though that block
has quotient zero or one. A comparison and at most one subtraction can establish
its initial remainder. First qualify this shortcut independently, retain the
old path as a fixed comparator, and measure complete calls. SIMD is deferred
while removing potentially unnecessary recursive work is tested.

The current block width also causes odd divisors, or even widths that halve
to large odd widths, to reach Knuth leaves. For example, the 16,385-byte control
does not qualify the neighboring 16,386-byte recursion shape. A later experiment
can pad both magnitudes by the same low zero bytes and undo that scale on the
remainder. [V8's B-Z implementation](https://chromium.googlesource.com/v8/v8.git/+/main/src/bigint/div-burnikel.cc)
already rounds the divisor to a suitable multiple and starts with its highest
two blocks. This is an established design to adapt and measure, not a novelty
claim. Its benefit for BLIP byte storage is unmeasured.

[GMP's small-quotient algorithm](https://gmplib.org/manual/Small-Quotient-Division)
uses only the leading portions to estimate a short quotient, then corrects it
with a full multiply/subtract. That supplies another candidate if avoiding the
trivial leading block leaves the measured short-quotient penalty. Recursive
division can benefit from Karatsuba and Toom multiplication already present
here; [GMP's divide-and-conquer discussion](https://gmplib.org/manual/Divide-and-Conquer-Division)
does not require FFT multiplication for a crossover.

### Leading-block experiment

`Mp.divModBurnikelZieglerLeadingBlock` is an explicit candidate that initializes
the highest block's quotient and remainder with a comparison and at most one
subtraction. All lower blocks use the existing recursive divider. The original
signed entry point, cutoff-128 kernel and ordinary dispatcher remain fixed
controls. Both variants share sign handling, canonical BLIP output encoding
and the same allocation wrapper.

An allocation-budget test first failed against the old implementation. It
divides a maximal 64-, 128- or 256-byte magnitude by half that byte range,
checks quotient one and the complete remainder, and protects exact-capacity
outputs with canaries. Eight allocations cover the top-level buffers; any
recursive request fails. The old path must report `OutOfMemory` and release
all bytes under that budget, while the candidate must return the exact result
without leaking. This is a resource-behavior check, not a timing claim.

The candidate also joins the existing GMP sign/normalization and input-alias
corpora, optional-cache allocation-failure sweep, native integer boundaries,
zero-divisor rejection and corrupted-reference checks. The new `leading`
probe route failed its CLI check before implementation. It compares the fixed
signed B-Z entry with the candidate under `division-leading-block-paired-v1`,
sharing the public probe's inputs, paired schedule and full-result checks.
`profiling-division-leading.json` retains all three operand geometries and the
odd-width fallback control. Run it through `./bm --verified-division --config
profiling-division-leading.json`.

The complete native suite passed in 89 seconds of mixed Nix preparation/check
time. The optimized production build and all-system evaluation also passed.

### Leading-block results and selection

Campaign `blip-mp-division-leading-20261028T181111Z` measured commit
`33673cf7e64645fb408350b86dd830f4d3a85415` with source digest
`8edd7e8245d5385118f7cf0811a3c337f278044e5a011828f9f8d5607b53c4a2`
unchanged. All 45 processes verified complete results. Both short-quotient
cohorts remained `INCONCLUSIVE` after one variation retry. The balanced
one-CPU cohort became `UNBASELINED` after its retry; the other three cohorts
were `UNBASELINED` on their first attempts. No baseline was approved.

The table gives median candidate/original B-Z CPU ratios across thirty paired
samples per selected cohort. Each cell is **1-CPU / 12-CPU affinity**. Hardware,
compiler, inputs, signs, normalization coverage and timed verification match
the public-path campaign above; this experiment times two explicit BLIP paths.

| Divisor bytes | Dividend = divisor + 1 byte | Dividend = 2 × divisor | Dividend = 4 × divisor |
|---:|---:|---:|---:|
| 8,192 | 0.584 / 0.574 | 0.827 / 0.826 | 0.920 / 0.918 |
| 12,288 | 0.599 / 0.596 | 0.842 / 0.842 | 0.931 / 0.929 |
| 16,384 | 0.583 / 0.584 | 0.852 / 0.852 | 0.937 / 0.938 |
| 16,385 | 1.009 / 0.999 | 1.001 / 1.001 | 0.998 / 0.999 |

At recursive widths, every process mean from both selected and diagnostic
attempts favors the shortcut. Median CPU savings are about 40–43% for short
quotients, 15–17% for balanced inputs and 6–8% for long dividends. The odd-width
fallback is unchanged and its medians remain within 0.9% of parity. Its
individual process ratios span 0.942–1.079, so these observations do not support
a claim of a small fallback speedup. The
[summary](../benchmarks/storage-aware/division-leading-summary.json) preserves
all process ratios, selected components, sample ranges and verdicts. Complete
external records use the campaign prefix and configured case-name suffixes.

The consistent recursive gains support selecting the shortcut inside the
default B-Z magnitude divider. The public integration threshold stays at
99,999 bytes. The explicit signed `Mp.divModBurnikelZiegler` comparator retains
the original cutoff-128 path; `Mp.divModBurnikelZieglerLeadingBlock` remains the
selected candidate's direct entry. This keeps the paired benchmark meaningful
after selection. The normalized one-block allocation test is extended to the
default kernel and fails before that selection.

The measured reduction does not resolve the earlier short-quotient regression
against current public division. A matched comparison is needed before assigning
its remaining ratio; multiplying medians from separate campaigns would not
provide that measurement. The next bounded candidate is to use the existing
Knuth leaf when the actual magnitude lengths prove the quotient fits one chunk,
before allocating recursive work. GMP was not timed in this campaign.

After selection, the complete native suite passed in 90 seconds of mixed Nix
preparation/check time. The optimized production build and all-system evaluation
passed. The fixed comparator and selected default both remain covered by the
complete suite.

### Short-quotient fallback experiment

`Mp.divModBurnikelZieglerShortQuotient` exposes a candidate that uses the existing
chunk-reading Knuth leaf when the trimmed dividend magnitude has fewer than
eight extra bytes over the divisor. If their lengths are `m` and `n`, then
`u < 256^m` and `v >= 256^(n-1)`, so `q < 256^(m-n+1)`. A difference below
eight therefore bounds the quotient to one 64-bit chunk. The existing zero,
smaller-dividend and same-value cases run before this decision. Inputs remain
byte buffers; no stored integer representation changes.

The candidate makes that decision before recursive scratch allocation and
otherwise retains the selected leading-block implementation. This is a bounded
first cutoff, not an optimum. The default B-Z kernel and public dispatcher are
unchanged during qualification. Explicit old, leading-block and short-quotient
entries keep the comparison paths separate.

A failing-first classifier test checks all sixteen length differences from
zero through fifteen at 64-, 128- and 256-byte divisors. With only one allocation
allowed, exactly differences zero through seven must complete. The dividend
includes two extra high zero bytes, requiring the decision to use its actual
magnitude. Independent power-of-256 identities establish every complete
quotient and remainder; exact quotient capacity and output canaries detect
overwrites, and allocation accounting requires complete cleanup. The initial
implementation failed the expected accepted set.

The signed corpus now includes dividends one, seven and eight bytes wider than
the divisor, plus twice-width and four-times-width dividends. It crosses all
four signs and eight normalization shifts, checks both complete GMP-derived
canonical results and rejects corrupted references. The candidate joins native
boundary, zero-divisor and input-alias controls. Allocation-failure enumeration
covers both short and balanced operands, including optional arena-cache recovery.
The new probe routes failed their CLI controls before implementation.

`profiling-division-short.json` compares the fixed leading-block path with the
candidate. `profiling-division-short-public.json` compares current public division
with the candidate. Both use 8,192-, 12,288-, 16,384- and 16,385-byte divisor
magnitudes, all five geometries, and separate 1/12-CPU affinity cohorts. Each
cohort retains five fresh processes, six paired ABBA/BAAB samples, 32 cases per
width and a 120-second process deadline. GMP supplies references outside timing.
At a length difference of eight, the bound allows nine quotient bytes even
though some actual quotients still fit in eight; this is deliberately conservative.
The existing three-geometry configurations and their method definitions retain
their previous inputs. SIMD remains deferred while this experiment tests the
choice of division algorithm.

The complete native suite passed in 87 seconds of mixed Nix preparation/check
time. The optimized production build and all-system evaluation also passed.

### Short-quotient results and selection

Two campaigns measured commit `c6e428fed7d6457d1ee4611cfb198fac5cef4d1a`
on the same Linux x86_64 hardware and Zig 0.16.0 ReleaseFast build:

- `blip-mp-division-short-20261028T183334Z`: candidate versus fixed leading-block
  B-Z; 65 correct processes, nine `UNBASELINED` cohorts and one `INCONCLUSIVE`
  cohort. One-chunk-limit/12-CPU, two-chunk-start/1-CPU and balanced/1-CPU each
  needed their one permitted variation retry; two-chunk-start/1-CPU remained
  inconclusive.
- `blip-mp-division-short-public-20261028T184011Z`: candidate versus current
  public division; 55 correct processes and ten `UNBASELINED` cohorts.
  One-chunk-limit/12-CPU needed one retry.

No baseline was approved. Each campaign's source digest stayed unchanged:
`71f1b9df9b76a74ae596d6ec687f01e1e0c1c37679d0c97d436a0539cb64b10b`
and `7d3acdb143a4e38778c50a361f9b513a0ed00c7dee922fdc6084b9174fafaed5`,
respectively. The engine includes the configuration in that digest. Both
campaigns recorded the same clean commit and probe binary SHA-256,
`7c6aa6cdce681b4e0948be646d92e2d2a173958283703a09bb4d14528bba3da3`.

Each cell below is a median paired CPU ratio for **1-CPU / 12-CPU affinity**,
using thirty samples from each selected cohort. Widths are magnitude bytes.
The first table compares the short-quotient candidate with fixed leading-block
B-Z. The first two columns exercise the new fallback at even divisor widths;
the remaining geometries and odd divisor are controls.

| Divisor bytes | Dividend = divisor + 1 | Dividend = divisor + 7 | Dividend = divisor + 8 | Dividend = 2 × divisor | Dividend = 4 × divisor |
|---:|---:|---:|---:|---:|---:|
| 8,192 | 0.0383 / 0.0382 | 0.0386 / 0.0398 | 0.994 / 0.991 | 0.997 / 0.996 | 0.999 / 0.998 |
| 12,288 | 0.0376 / 0.0373 | 0.0365 / 0.0387 | 0.992 / 0.992 | 0.996 / 0.998 | 0.999 / 0.998 |
| 16,384 | 0.0333 / 0.0334 | 0.0338 / 0.0344 | 0.991 / 0.991 | 0.997 / 0.997 | 0.998 / 0.998 |
| 16,385 | 1.005 / 1.008 | 1.006 / 1.009 | 1.002 / 1.004 | 0.998 / 0.999 | 1.001 / 1.002 |

The sampled new-fallback medians take about 1/25 to 1/30 of the fixed B-Z
time. Every process mean, including diagnostics, favors the candidate on those
rows. Control medians remain within about 1% of parity, while their individual
process ratios span roughly 0.941–1.069. Small control differences do not
establish another algorithmic gain. The
[B-Z comparison summary](../benchmarks/storage-aware/division-short-summary.json)
retains every process ratio, sample range, selected component and verdict.

The second table compares the candidate with current public `Mp.divMod`, using
the same corpus and identical canonical-result verification adapters.

| Divisor bytes | Dividend = divisor + 1 | Dividend = divisor + 7 | Dividend = divisor + 8 | Dividend = 2 × divisor | Dividend = 4 × divisor |
|---:|---:|---:|---:|---:|---:|
| 8,192 | 1.277 / 1.277 | 1.276 / 1.275 | 33.91 / 33.98 | 0.900 / 0.903 | 0.752 / 0.751 |
| 12,288 | 1.269 / 1.270 | 1.266 / 1.267 | 35.25 / 35.27 | 0.661 / 0.661 | 0.558 / 0.557 |
| 16,384 | 1.269 / 1.269 | 1.264 / 1.263 | 39.74 / 39.79 | 0.612 / 0.611 | 0.525 / 0.523 |
| 16,385 | 1.303 / 1.302 | 1.300 / 1.301 | 1.265 / 1.265 | 1.001 / 1.002 | 1.001 / 1.001 |

The new fallback still takes about 26–30% more CPU time than the public path
on short quotients. At a length difference of eight, even-width recursion
takes about 34–40 times the public path's time. Every process mean, including
retries, agrees with both losing directions. At the sampled recursive widths,
balanced and long dividends save about 10–39% and 25–48%, respectively; every
process mean agrees with those gains. The odd fallback stays near parity for
balanced/long dividends. The
[public comparison summary](../benchmarks/storage-aware/division-short-public-summary.json)
preserves all processes and timing details. Neither campaign times GMP.

The default B-Z magnitude divider selects the one-chunk fallback, preserving
the explicit leading-block and original cutoff-128 controls. Extending the
allocation classifier to the default entry first fails, then verifies that
selection. The public integration threshold remains 99,999 bytes. These data
support a local B-Z improvement while rejecting a simple lower size threshold;
quotient length and divisor alignment still matter. The eight-byte guard is a
conservative first cutoff, not an optimum or a claim about every operand shape.

Source inspection suggests a further bounded experiment: the top-level B-Z
loop already receives each remainder's significant length. A short carried
remainder can imply a short quotient for the next block, even in a balanced or
long division. Reuse that length to choose a leaf before recursive work, retain
the current entry as a fixed comparator, and measure complete signed calls.
The next experiment implements this internal shortcut with a fixed comparator.

After selection, the complete native suite passed in 91 seconds of mixed Nix
preparation/check time. The optimized production build and all-system evaluation
also passed. The default entry now passes the same allocation-bound classifier
as the measured candidate.

### Short carried-remainder experiment

`Mp.divModBurnikelZieglerShortCarry` retains the outer short-quotient fallback
and selects the Knuth leaf inside the top-level block loop when the carried
remainder has fewer than eight significant bytes. Normalization can turn a
balanced `2n`-byte dividend into `2n+1` bytes; its first carried remainder then
has only one byte. Recursing on the next padded block ignores that information.
The candidate uses the remainder length already returned by the preceding
division or subtraction. A zero carry requires trimming only the next low block.
The default and explicit short-quotient entry remain unchanged during measurement.

The failing-first resource check compares allocation counts with the fixed
short-quotient implementation at 64, 65, 128 and 256 bytes. Dense balanced inputs
that gain a normalization byte must allocate less; unshifted and odd-width
controls retain their counts. Every result is compared with GMP, with exact
quotient capacity, canaries and complete allocation cleanup. The placeholder
failed the reduced-allocation assertion. A separate exact identity covers a
highest block equal to the divisor, followed by zero and small blocks, producing
a power-of-256 quotient and remainder 123. Signed boundaries, input aliases,
allocation failures and the five-geometry corruption controls include the
candidate. The complete suite passed in 87 seconds of mixed Nix preparation/check
time; the optimized production build and all-system evaluation passed too.

Two preceding CLI-check attempts stopped with `ClockFailed`. All 25 signed
mode/geometry combinations subsequently passed outside the sandbox and under
syscall tracing inside it; temporary raw-clock instrumentation also passed.
At that checkpoint the cause was unestablished; the later
[small-batch diagnosis](#tiny-division-clock-batches) captured a native failure.
Instrumentation was removed before the final
suite, and failure context now identifies the mode and geometry. Clock checks
remain strict; these diagnostic runs are not performance observations.

`profiling-division-carry.json` pairs the fixed short-quotient entry with this
candidate at the same four widths, five geometries and 1/12-CPU affinities as
the preceding campaign. It retains 32 signed/normalization cases, six paired
samples and five processes per cohort. GMP supplies references outside timing;
this campaign does not time GMP. SIMD remains deferred while the experiment
tests whether significant-length metadata avoids unnecessary recursive work.

### Short-carry results and selection

Campaign `blip-mp-division-carry-20261028T191540Z` measured clean commit
`f735b0ad8fb6509c79c5875325a7db61f57f9125` on the same Linux x86_64 host,
with Zig 0.16.0 ReleaseFast. All 50 processes verified complete results without
clock failures. All ten cohorts were `UNBASELINED`, each on its first attempt;
no baseline was approved. The source digest remained
`deaacb6e280411594afc7dd24369e8429639bb1a02dc468877f51557d100ce70`.
The probe's SHA-256 was
`b01accb89fb6a576b29a456e24f126ef9085433e1aa2233db6490f0147a79fbd`.

Each cell is a median paired CPU ratio, candidate divided by fixed
short-quotient B-Z, for **1-CPU / 12-CPU affinity**. Widths are magnitude bytes.
Thirty paired samples contribute to each cell.

| Divisor bytes | Dividend = divisor + 1 | Dividend = divisor + 7 | Dividend = divisor + 8 | Dividend = 2 × divisor | Dividend = 4 × divisor |
|---:|---:|---:|---:|---:|---:|
| 8,192 | 1.000 / 1.000 | 1.000 / 1.000 | 0.999 / 1.000 | 0.759 / 0.758 | 0.890 / 0.889 |
| 12,288 | 1.001 / 1.000 | 1.000 / 1.001 | 0.999 / 0.999 | 0.773 / 0.771 | 0.897 / 0.897 |
| 16,384 | 1.000 / 1.000 | 1.000 / 1.000 | 0.998 / 0.999 | 0.789 / 0.789 | 0.906 / 0.908 |
| 16,385 | 1.000 / 1.000 | 1.000 / 1.000 | 1.000 / 1.000 | 0.999 / 0.997 | 1.003 / 0.998 |

At the sampled even widths, balanced divisions save about 21–24% CPU time
and long dividends save about 9–11%. Every process mean favors the candidate
in those cells. Control medians remain within about 0.4% of parity. Individual
control process ratios span 0.888–1.043, including an apparent gain on an
unchanged odd-width path; small control differences are not another optimization.
The [summary](../benchmarks/storage-aware/division-carry-summary.json) preserves
all sample ranges, process means, selected components and verdicts.

The default B-Z magnitude divider now selects the internal short-carry leaf;
the explicit short-quotient entry remains fixed. Extending the resource test
to the default first failed with 20 allocations instead of the candidate's 10.
Public dispatch still uses its 99,999-byte threshold. This experiment times
BLIP implementations only. Multiplying this gain into an older GMP ratio would
not constitute a fresh GMP comparison. The short-quotient cutoff cliff and
neighboring divisor alignments still need qualification before public dispatch
can change.

After selection, the complete suite passed in 89 seconds of mixed Nix
preparation/check time, including the default allocation regression. The
optimized production build and all-system evaluation passed.

### Selected-kernel GMP comparison qualification

`profiling-division-selected-competitors.json` retains the original matched
positive 2:1 corpus, widths, iteration counts, warmups, verification adapters
and 1/12-CPU cohorts. Its method is `division-selected-competitors-v1`. The
four methods are public BLIP, Knuth, selected B-Z and ordinary GMP. The selected
entry includes the leading-block, outer short-quotient and short-carry changes.
The original `competitors` mode still times the fixed cutoff-128 entry.

An injected schedule test first failed when the new mode timed the old B-Z
slot. It checks all eight mirrored rounds, full input visitation, normalization
and exclusion of the old slot. Complete-reference/corruption and partial-
allocation tests failed against a placeholder selected method, then passed
with the actual default magnitude divider. The new CLI mode failed its check
before routing was connected. Both modes remain in the complete entry point.

The full suite passed in 103 seconds of mixed Nix preparation/check time;
production build and all-system evaluation passed. This does not meet the
fast-feedback target or isolate test execution from compilation. The fresh
measurement still includes each method's native result-verification adapter;
it will not be reported as an instruction-only arithmetic comparison.

### Selected-kernel GMP results

Campaign `blip-mp-division-selected-competitors-20261028T192923Z` measured
clean commit `3319ea430337347ef0b3bb033849586e179c9813` with ordinary GMP
6.3.0 and Zig 0.16.0 ReleaseFast on Linux x86_64, on the same Threadripper
3990X. Both affinity cohorts were `UNBASELINED` on their first attempt; all
ten processes verified every result, and no baseline was approved. The source
digest stayed `9f8ec454147268d03cf8f418042c468163e6e9745d3bcffc109a74b84ae773f8`.
The probe SHA-256 was
`d336fca230205a8972bb367cf431afa0ea0fe60dabe1ad17bf6e8d3483822410`.

Cells show median paired CPU ratios for **1-CPU / 12-CPU affinity**, with
forty samples per cell. Divisor widths are magnitude bytes; dividends have
twice that width. The retained native verification adapters are included in
timing. This is a direct measurement of verified calls, not a projection from
the preceding BLIP-only gains.

| Divisor bytes | Public BLIP / GMP | Selected B-Z / GMP | Selected B-Z / Knuth |
|---:|---:|---:|---:|
| 8 | 2.04 / 2.04 | 7.98 / 7.93 | 4.13 / 4.15 |
| 16 | 2.93 / 2.93 | 3.88 / 3.88 | 1.11 / 1.11 |
| 32 | 2.30 / 2.31 | 3.02 / 3.03 | 1.06 / 1.06 |
| 64 | 2.48 / 2.48 | 10.17 / 10.25 | 3.37 / 3.37 |
| 128 | 2.65 / 2.65 | 11.79 / 11.86 | 3.68 / 3.71 |
| 256 | 2.33 / 2.33 | 9.22 / 9.25 | 3.45 / 3.46 |
| 512 | 2.55 / 2.55 | 7.60 / 7.60 | 2.73 / 2.74 |
| 1,024 | 3.08 / 3.06 | 6.35 / 6.33 | 1.97 / 1.96 |
| 2,048 | 3.96 / 3.95 | 5.54 / 5.53 | 1.36 / 1.36 |
| 4,096 | 5.26 / 5.22 | 5.30 / 5.25 | 0.994 / 0.994 |
| 8,192 | 7.13 / 7.10 | 5.13 / 5.12 | 0.714 / 0.714 |
| 16,384 | 11.21 / 11.20 | 5.74 / 5.74 | 0.510 / 0.510 |

GMP wins every process-mean comparison against public BLIP, Knuth and selected
B-Z at every sampled width. The selected B-Z kernel saves about 29% and 49%
against Knuth at 8,192 and 16,384 bytes. All process means agree with those
directions; their ratios span 0.710–0.744 and 0.509–0.554, respectively. At
4,096 bytes the methods are near parity, not a supported large gain. One
representative selected single-CPU process at 16,384 bytes spends 6.326 ms in
public BLIP, 6.347 ms in Knuth, 3.237 ms in selected B-Z and 0.564 ms in GMP.

The [complete summary](../benchmarks/storage-aware/division-selected-competitors-summary.json)
retains raw-sample ratio ranges, every process mean, selected component times
and verdicts. Public dispatch remains unchanged: the balanced power-of-two
cases do not resolve the short-quotient cliff or unfavorable divisor alignment.
The original matched comparison remains historical evidence for its fixed
cutoff-128 kernel; these current results supersede its headline ratios.

### Quotient-geometry crossover qualification

`profiling-division-geometry.json` compares the raw Knuth and selected B-Z
kernels while varying the dividend length independently of divisor width.
The engine's size coordinate is the extra magnitude bytes in the dividend,
not the actual quotient width. Divisors have 4,096, 8,192 or 16,384 bytes;
gaps are 1, 7, 8, then powers of two through the divisor width. This bounds
dividends at twice the divisor width. Neighboring and odd divisor alignments
are outside this initial experiment, and production thresholds are unchanged.

The method is `division-geometry-paired-v1`. Each point has 32 positive cases
covering all eight normalization shifts four times. Both kernels receive
identical byte inputs, retained-arena allocation and output poisoning, and
complete GMP-derived quotient/remainder plus canary checks inside timing.
Inputs and references are prepared before timing. Six ABBA/BAAB samples follow
one full warmup pass. Each width has five-process 1/12-CPU cohorts with a
120-second process deadline. GMP itself is not timed in this experiment.

The parser first failed a classifier test over complete width and gap sets;
accepted gaps must be ordered, unique and no larger than the chosen width.
The six small-width geometries verify their normalization coverage, reject
corrupted references and enumerate partial-allocation failures. The new CLI
check failed before routing was implemented. Existing injected timing tests
still govern the shared paired sampler. The complete suite passed in 86 seconds
of mixed Nix preparation/check time; production build and all-system evaluation
passed. SIMD remains deferred while these measurements resolve algorithm choice.

### Quotient-geometry crossover results

Campaign `blip-mp-division-geometry-20261028T194115Z` measured clean commit
`2dfa5799a7112315da788fc75e9af3afb78a7dcb` on the same Linux x86_64 host
with Zig 0.16.0 ReleaseFast. All 35 processes verified their results; all six
cohorts were `UNBASELINED`. The 16,384-byte/12-CPU cohort needed its single
variation retry. No baseline was approved. The source digest stayed
`c6dfd803ff30d1625dd8cf80526b7e42069b6f67540af7e521a599b688679ea8`;
the probe SHA-256 was
`ae221bd40d43dfc12671cd8b9df6ccebafac0ae7dfdc759ba7aa099eeb22747c`.

Cells are median paired CPU ratios, selected B-Z divided by Knuth, for
**1-CPU / 12-CPU affinity**. Each selected cohort supplies thirty paired
samples per cell. The gap is dividend magnitude bytes minus divisor magnitude
bytes, not the actual quotient width. A dash lies outside the declared domain.

| Extra dividend bytes | 4,096-byte divisor | 8,192-byte divisor | 16,384-byte divisor |
|---:|---:|---:|---:|
| 1 | 1.000 / 1.001 | 1.000 / 1.000 | 1.001 / 1.000 |
| 7 | 1.001 / 1.001 | 1.000 / 1.000 | 1.001 / 1.000 |
| 8 | 17.96 / 17.95 | 21.08 / 21.11 | 24.54 / 24.57 |
| 16 | 16.75 / 16.78 | 19.62 / 19.62 | 22.88 / 22.85 |
| 32 | 14.73 / 14.75 | 17.25 / 17.26 | 20.05 / 20.05 |
| 64 | 11.99 / 11.98 | 13.98 / 13.97 | 16.20 / 16.20 |
| 128 | 8.81 / 8.83 | 10.22 / 10.22 | 11.85 / 11.85 |
| 256 | 5.90 / 5.92 | 6.86 / 6.86 | 7.86 / 7.86 |
| 512 | 3.68 / 3.68 | 4.23 / 4.24 | 4.82 / 4.82 |
| 1,024 | 2.21 / 2.21 | 2.52 / 2.52 | 2.84 / 2.84 |
| 2,048 | 1.419 / 1.419 | 1.477 / 1.478 | 1.644 / 1.645 |
| 4,096 | 0.967 / 0.965 | 0.979 / 0.979 | 0.970 / 0.969 |
| 8,192 | — | 0.684 / 0.684 | 0.667 / 0.669 |
| 16,384 | — | — | 0.483 / 0.483 |

Every process mean, including retry diagnostics, favors Knuth at each sampled
gap from 8 through 2,048 bytes. The existing one-chunk fallback keeps gaps 1
and 7 near parity. At 4,096 extra bytes the methods are close; one 8,192-byte
divisor process reverses the small median advantage. Larger gaps at the two
larger divisor widths favor B-Z in every process. The
[summary](../benchmarks/storage-aware/division-geometry-summary.json) preserves
selected component means, sample ranges, all process means and verdicts. The 32-case paired method
differs from the 64-case four-way GMP probe, so their small crossover differences
are not evidence of another code change. GMP was not timed here.

These data motivate an experimental outer fallback through a 2,048-byte gap
for divisors at least 4,096 bytes wide. That is a conservative sampled bound,
not an optimum or a proof about unmeasured widths. Keep the current entry fixed,
qualify the new boundary and adjacent divisor alignments, and measure the
candidate before selecting it. The internal short-carry leaf and public
dispatch threshold remain unchanged by this measurement.

### Tiny division clock batches

CI for results commit `ad18de70c12efd805a1fba8599070d391a3c1b96` failed
the division CLI check in `short one_chunk_limit`, while its production build
and core tests passed. A failure-only diagnostic now retains wall-start,
CPU-start, CPU-end and wall-end readings. Synthetic stopped/backward clocks
first failed the recording test, then verified both complete context and strict
error rejection. Successful batches leave the diagnostic buffer untouched.

A bounded Nix-sandbox reproduction failed on attempt 70. The short-quotient
method had executed sixteen calls; wall time advanced 6,312 ns, but both
process-CPU readings were 1,159,784 ns. Thus a real small batch failed because
its CPU timestamps did not advance. This does not establish an operating-system
defect or the nominal resolution of the clock.

Public and geometry probes now use sixteen repetitions for divisor widths
through 128 bytes, matching the existing native competitor policy. A small
paired sample therefore performs 512 verified calls per method; large samples
still perform 32. Their `iterations` fields and normalization descriptions
record the actual work. The affected methods and configuration definitions
are versioned as `paired-v2`; historical v1 observations remain intact.
The native competitor probe reuses the same policy helper with unchanged work
counts and method version. No timing tolerance, zero fallback or hidden retry
was introduced. Future clock failures in the signed public probe retain the
diagnostic context.

The same 500-attempt bounded reproduction passed with the corrected binary.
That is finite qualification evidence, not a guarantee that clocks cannot fail.
The complete suite includes deterministic repetition-boundary, clock-error and
CLI iteration-count checks; it passed in 85 seconds of mixed Nix
preparation/check time. Production build and all-system evaluation passed.
No new arithmetic performance measurement or baseline approval follows from
this measurement fix.

### Wider quotient fallback qualification

`Mp.divModBurnikelZieglerWideQuotient` and its magnitude kernel expose a
candidate outer Knuth fallback for canonical divisor widths of at least 4,096
bytes and dividend gaps through 2,048 bytes. The existing zero, smaller-value,
equal-value and single-byte cases still precede dispatch. Smaller divisors
retain the old eight-byte guard. Internal short-carry handling is unchanged,
and the default divider does not select this candidate during qualification.

A failing-first allocation classifier covers five divisor widths around the
floor and gaps 0, 7, 8, 2,047, 2,048 and 2,049. With only one allocation allowed,
the accepted matrix distinguishes the old small-divisor rule, odd-width leaf
controls and the new inclusive boundary. Independent powers-of-256 identities
establish complete results, with two high padding bytes, exact quotient capacity,
canaries and complete cleanup. The old implementation failed the accepted set.
At 4,096-byte divisors, all four signs, eight normalization shifts, three alias
arrangements and allocation failures cover gaps 8, 2,048 and 2,049. Native
boundary, division-by-zero and minimum-integer checks include the signed entry.

`profiling-division-wide-quotient.json` pairs the fixed short-carry kernel with
the candidate, using method `division-wide-quotient-paired-v1`. Divisor widths
are 4,094, 4,096, 4,097, 4,098, 8,192, 8,194, 16,384, 16,385 and 16,386 bytes.
Each tests gaps 7, 8, 2,047, 2,048, 2,049 and a twice-width dividend. This
includes below-floor, existing-leaf, odd-width, neighboring-even-width and
balanced controls. Both 1/12-CPU cohorts retain five processes, 32 positive
cases, six paired samples and a 120-second process deadline. Complete GMP
references and canaries are checked on every call; GMP and public dispatch
are not timed. Small CLI fixtures use the corrected repetition policy.

New parser and neighboring-fixture controls failed before implementation;
placeholder methods failed the full-reference and allocation checks. The CLI
route also failed before it was connected. The complete suite passed in 91
seconds of mixed Nix preparation/check time; production build and all-system
evaluation passed. SIMD remains deferred while the measured algorithm choice
is being qualified.

### Wider quotient fallback results

The proposed inclusive 2,048-byte gap cutoff is rejected for default dispatch.
At clean commit `6a6e66d2764008e1aa33ba3d790983ee434ed310`, paired measurements
show that a cutoff derived from aligned widths regresses at neighboring even
widths. The table gives candidate/fixed-short-carry CPU ratios, with ranges
spanning the 1/12-CPU paired medians. Ratios below one favor the candidate.

| Divisor bytes | Gap 8 | Gap 2,047 | Gap 2,048 |
|---:|---:|---:|---:|
| 4,096 | 0.055 | 0.757–0.758 | 0.701–0.702 |
| 4,098 | 0.166–0.167 | 1.099–1.100 | 1.087–1.089 |
| 8,192 | 0.047 | 0.702–0.703 | 0.676 |
| 8,194 | 0.148 | 1.024–1.026 | 1.023–1.025 |
| 16,384 | 0.040 | 0.618–0.619 | 0.607–0.608 |
| 16,386 | 0.127 | 0.921–0.922 | 0.921–0.922 |

Every process mean, including diagnostic attempts, agrees on the direction of
each changed row. The eight-byte-gap cases improve about 6–25 times, relative
to the preceding B-Z kernel. Near the proposed upper cutoff, aligned widths
save 24–39% CPU, while 4,098-byte divisors regress 9–10% and 8,194-byte divisors
regress 2–3%. These are local kernel comparisons, with GMP supplying references
outside timing. They establish no new comparison with GMP or public dispatch.

Odd divisors, the 4,094-byte below-floor control, seven-byte gaps, 2,049-byte
gaps and balanced divisions retain the same algorithm. Their paired medians
range from 0.998 to 1.010; individual process means range from 0.923 to 1.049.
The [machine-readable summary](../benchmarks/storage-aware/division-wide-quotient-summary.json)
preserves sample ranges and all process means, including diagnostic attempts.

All 105 processes verified full quotient/remainder results and canaries.
Three cohorts used the single permitted variation retry. Seventeen cohorts
are unbaselined; the 8,192-byte/12-CPU cohort remains inconclusive. No baseline
was approved. All 18 source digests stayed
`b2acb95196f6613763b6f8eb946480e986515a102ebecd1ca769ba4ac1bc1cd1`;
the probe SHA-256 was
`d3c38a5b44bdcd3543e2e1a3a6466bd775fb422665c05ac80c00e79f077223d2`.
External records use prefix `blip-mp-division-wide-quotient-20261028T201907Z-`
and the case names in `profiling-division-wide-quotient.json`. Exact-commit CI
passed in 190 seconds.

Halving a width such as 4,098 produces a large odd leaf, whereas 4,096 continues
recursing. That structural difference is a plausible explanation for different
crossovers; these measurements do not isolate its causal contribution. The next
bounded experiment samples gaps 8 through 2,048 at 4,096, 4,098, 8,194 and
16,386 bytes using the same fixed methods. `profiling-division-gap-crossover.json`
records that sweep. A narrower universal cutoff is a hypothesis pending those
results; neither the candidate nor public integration threshold changes here.

### Bounded quotient fallback selection

Campaign `blip-mp-division-gap-crossover-20261028T202603Z` measured clean commit
`089a24267bf3b23feb758aca26afc36a3dd55593` with the fixed short-carry and
2,048-byte-gap experimental kernels. It adds gaps 16, 32, 64, 128, 256, 512
and 1,024 at 4,096, 4,098, 8,194 and 16,386-byte divisors. Knuth uses less
CPU in every process mean at every sampled gap through 1,024, including the
diagnostic attempts. At that upper bound, the paired medians save 18–55%.

| Divisor bytes | Knuth/B-Z at gap 512, 1 / 12 CPUs | At gap 1,024, 1 / 12 CPUs | All process means at gap 1,024 |
|---:|---:|---:|---:|
| 4,096 | 0.270 / 0.270 | 0.451 / 0.452 | 0.370–0.453 |
| 4,098 | 0.478 / 0.567 | 0.703 / 0.815 | 0.675–0.816 |
| 8,194 | 0.528 / 0.528 | 0.730 / 0.728 | 0.722–0.733 |
| 16,386 | 0.403 / 0.478 | 0.576 / 0.678 | 0.555–0.744 |

Some 1-CPU process ratios differ substantially from the 12-CPU cohort and the
preceding sweep despite identical code and data. Near gaps 2,047/2,048,
individual process means at 4,098 and 8,194 even cross parity. No cause is
assigned to that variation. The cutoff is kept at 1,024, where every process
mean remains below 0.816. This is finite evidence for the measured widths,
fixtures and platform, not proof of an optimal or universally faster cutoff.

All 50 processes verified full results and canaries. Two cohorts used their
single permitted variation retry. Seven cohorts are unbaselined; the
16,386-byte/12-CPU cohort remains inconclusive. No baseline was approved.
The source digest stayed
`23ef5f0666c590ef1bdfc38762f1bb2584b27bb16a1541e40ddcdfc380301653`.
The probe SHA-256 remained
`d3c38a5b44bdcd3543e2e1a3a6466bd775fb422665c05ac80c00e79f077223d2`,
matching the preceding boundary campaign. The
[summary](../benchmarks/storage-aware/division-gap-crossover-summary.json)
retains every process mean and selected-attempt sample range. Configuration
is `profiling-division-gap-crossover.json`; method and fixture policy remain
`division-wide-quotient-paired-v1`, with GMP references outside timing.

The default recursive entry now uses Knuth when the canonical divisor is at
least 4,096 bytes and the canonical dividend length exceeds it by at most
1,024 bytes. The explicit short-carry and 2,048-byte experimental entries stay
fixed. A one-allocation classifier first failed on the unchanged default,
then verifies the accepted set at five floor/odd/even widths and gaps 0, 7, 8,
1,023, 1,024, 1,025 and 2,048. Independent powers-of-256 identities check exact
outputs, high-zero input padding, capacities and canaries. Signed GMP-derived
tests cover all signs, normalization shifts and input aliases at 4,096 and
4,098 bytes on both sides of the new boundary; allocation-failure checks cover
the selected and recursive paths. The public integration threshold remains
99,999 payload bytes, and this selection establishes no fresh GMP comparison.

The complete suite passed in 93 seconds of mixed Nix preparation/check time;
the production build and all-system evaluation passed. The feedback budget
remains unmet; this duration includes compilation and is not a measured
test-execution-only time. `profiling-division-selected-public.json` prepares
the next paired signed comparison against current public division at five
geometries. Its initial binding was incorrect, as documented below.

### Signed selected-kernel probe binding correction

The first `profiling-division-selected-public.json` configuration called the
existing `public` mode. That mode intentionally invokes the fixed cutoff-128
`Mp.divModBurnikelZiegler` comparator, rather than the selected magnitude
kernel. The experiment's name was wrong; its method and component tags correctly
reported the older path. Campaign
`blip-mp-division-selected-public-20261028T203310Z`, measured at clean commit
`52e980f5ca55d2dcf25ab8405f324fc5120b73aa`, is therefore retained as a
[fixed-comparator recheck](../benchmarks/storage-aware/division-fixed-public-recheck-summary.json).
It is not evidence about the selected signed kernel and cannot justify changing
public dispatch. All 55 processes returned correct results; all ten cohorts
were unbaselined, with one variation retry. Its source digest stayed
`83e848e1840035e4277d36b1e6bd692c71fdcda98aea095ad0eed95f76de1d5f`.

The signed boundary tests added with the 1,024-byte selection also named this
fixed wrapper. The raw allocation classifier did exercise the selected kernel;
the explicit 2,048-byte wrapper covered the shared leaf implementation, but
neither established the intended signed binding. Those signed boundary and
allocation-failure tests now call `Mp.divModBurnikelZieglerSelected`, which
explicitly uses the same selected kernel as production's large-input path.
Native signed boundaries, zero-divisor checks, aliasing and corruption controls
include the new entry. The historical wrapper remains fixed.

A resource regression exercises the probe adapter at an eight-byte dividend
gap and an 8,192-byte divisor. It compares fresh allocator traffic against
the fixed short-carry method and requires lower allocation traffic, while
checking complete GMP-derived results and cleanup. It failed when
the new entry delegated to the old wrapper. A new `selected-public` CLI route
also failed before implementation. Its distinct method is
`division-selected-public-paired-v1`, with components `current` and `selected`;
the configuration now names that route. The original public-v2 mode remains
unchanged. Corrected timing results require a fresh campaign.

After correction, the complete suite passed in 87 seconds of mixed Nix
preparation/check time. The production build, all-system evaluation and tracked
flake-input check passed. Public arithmetic dispatch is unchanged.

### GMP refresh after bounded quotient selection

Campaign `blip-mp-division-bounded-competitors-20261028T203951Z` measured clean
commit `52e980f5ca55d2dcf25ab8405f324fc5120b73aa`. This four-way probe invokes
the selected magnitude kernel directly and is unaffected by the signed-mode
binding error above. It keeps the existing positive 2:1 dividend/divisor corpus,
64 fixtures, eight rotating four-way samples and ordinary GMP 6.3.0, under
Zig 0.16.0 ReleaseFast on Linux x86_64. These are verified-call timings;
the BLIP and GMP verification adapters differ. Results are CPU-time ratios,
with 1/12-CPU paired medians separated by a slash.

| Divisor bytes | Public BLIP / GMP | Selected B-Z / GMP | Selected B-Z / Knuth |
|---:|---:|---:|---:|
| 8 | 2.17 / 2.17 | 7.91 / 7.71 | 4.452 / 4.501 |
| 16 | 2.68 / 2.68 | 3.44 / 3.41 | 1.074 / 1.102 |
| 32 | 2.32 / 2.32 | 3.21 / 3.22 | 1.051 / 1.069 |
| 64 | 2.54 / 2.54 | 10.14 / 10.17 | 3.220 / 3.251 |
| 128 | 2.71 / 2.71 | 12.06 / 12.01 | 3.711 / 3.697 |
| 256 | 2.35 / 2.31 | 9.39 / 9.17 | 3.476 / 3.468 |
| 512 | 2.54 / 2.51 | 7.67 / 7.52 | 2.762 / 2.765 |
| 1,024 | 3.07 / 2.98 | 6.37 / 6.17 | 1.982 / 1.979 |
| 2,048 | 3.97 / 3.81 | 5.56 / 5.28 | 1.369 / 1.368 |
| 4,096 | 5.26 / 5.14 | 5.31 / 5.18 | 0.997 / 0.996 |
| 8,192 | 7.14 / 7.03 | 5.13 / 5.10 | 0.714 / 0.721 |
| 16,384 | 11.17 / 11.10 | 5.76 / 5.74 | 0.514 / 0.516 |

GMP wins every process mean at every width against all three BLIP paths.
At 8,192/16,384 bytes, selected B-Z saves 28–29%/48–49% against Knuth in the
paired medians. All process means, including diagnostic attempts, favor B-Z
over Knuth at those two widths. The new 1,024-byte gap guard does not change
algorithm selection for these twice-width dividends; differences from the
preceding campaign do not establish a new arithmetic improvement.

All fifteen processes verified full results. The one-CPU cohort is unbaselined;
the 12-CPU cohort remains inconclusive after its single variation retry. No
baseline was approved. Source digest
`fc867769e1f0c917a42acc06524ca71a639890224d127012c2d937b6971e5bba`
stayed fixed. Probe SHA-256
`4915dc3cd2f3d3712c108f27173ef722813f36e5b7c3b3d1a02221016d5701e9`
also matches the fixed signed-comparator recheck. The
[summary](../benchmarks/storage-aware/division-bounded-competitors-summary.json)
preserves every process mean, sample range and timing verdict; configuration
remains `profiling-division-selected-competitors.json` and method
`division-selected-competitors-v1`. Public integration remains unchanged.

### Measurement infrastructure follow-up

The first corrected signed campaign used a logical run ID that, after the
engine appended a case name, exceeded its 100-character record-ID limit.
The shared engine rejected the history write, leaving no observation records
or JSON report. That failed campaign supplies no retained timing evidence.
Future invocations precheck the combined identifiers and use a shorter prefix.
It is a storage failure, not a timing retry or baseline approval.

Exact-commit CI for `92c2c6e64e1353cb50cf32ce65dd27f04b8856fb` separately
failed `multiplication-probe-cli` after 182 seconds. The log was empty because
the check captured the probe's stderr and suppressed the JSON assertion output.
An exact-check reproduction with diagnostic capture passed once. A subsequent
bounded Nix-sandbox campaign passed 500 repetitions of all six multiplication
modes at 64/128-byte sizes and 128 iterations, including positive timing and
paired-average JSON assertions. The original failure remains unexplained;
these passes do not establish that it cannot recur.

The CLI check now reports the failing mode and captured stderr on probe
failure, unexpected stderr, or the JSON output on validation failure. Its
timed work and assertions are unchanged. Future failures should distinguish
a probe error from an output-contract failure instead of producing an empty
log. These diagnostic runs are not arithmetic benchmark observations.

The complete local suite passed with the diagnostic change in 93 seconds of
mixed Nix preparation/check time. Production build and all-system evaluation
passed. A fresh exact-commit CI result is still required.

Exact-commit CI subsequently passed for
`c380c3f630fdc8018382e5bf3723c32cd42844e9` in 195 seconds. This verifies the
current tree; it does not establish a cause or permanent fix for the earlier
intermittent failure.

### Selected signed division results

Campaign `blip-mp-selpub-20261028T210158Z` measured clean commit
`c380c3f630fdc8018382e5bf3723c32cd42844e9` using the corrected
`division-selected-public-paired-v1` method and components `current` and
`selected`. Combined record IDs were checked against the history store's
100-character limit before execution. The 32 fixtures cross four sign
combinations with eight normalization shifts. Both paths return canonical BLIP
values, compared in full on every timed call. Prepared inputs, reused outputs,
warmed scratch and six ABBA/BAAB samples match the earlier signed policy.

The table gives selected-B-Z/current-public CPU ratios. Each cell shows the
1/12-CPU paired medians; the gap is dividend bytes minus divisor bytes.

| Divisor bytes | Gap 1 | Gap 7 | Gap 8 | Twice-width dividend | Four-times-width dividend |
|---:|---:|---:|---:|---:|---:|
| 8,192 | 1.271 / 1.270 | 1.268 / 1.266 | 1.268 / 1.269 | 0.683 / 0.683 | 0.669 / 0.674 |
| 12,288 | 1.260 / 1.261 | 1.257 / 1.257 | 1.263 / 1.265 | 0.510 / 0.510 | 0.503 / 0.501 |
| 16,384 | 1.261 / 1.261 | 1.256 / 1.256 | 1.261 / 1.262 | 0.482 / 0.482 | 0.477 / 0.480 |
| 16,385 | 1.294 / 1.294 | 1.290 / 1.293 | 1.265 / 1.259 | 1.002 / 1.002 | 1.001 / 1.002 |

Every process mean favors selected B-Z on balanced/long even-width rows and
favors current public division on the short-quotient rows. The paired savings
are 32–52% for the former; the latter regress 26–29%. The odd-width long and
balanced controls stay near parity in the medians, with individual process
ratios from 0.990 to 1.023. The
[summary](../benchmarks/storage-aware/division-selected-public-summary.json)
retains all process means and sample ranges. The selected signed wrapper still
materializes magnitudes and manages an arena before its Knuth fallback. Those
costs are a plausible contributor to the short-quotient overhead; this comparison
does not isolate them causally.

All 50 processes verified their results. All ten cohorts are unbaselined,
without retries or an approved baseline. The source digest stayed
`35f4c7debfef8fae910369a2ca66ee19865b921d510bd9fdf3d9150cde5fe899`;
the probe SHA-256 was
`fd66a7d821ad18b3a507ec7afa52810b31e546289d6779aad1005a799ce7c096`.
GMP supplies correctness references outside timing here. These ratios must
not be multiplied into another campaign's GMP results.

Public dispatch remains at its existing 99,999-byte threshold. The next
algorithm experiment will scale both magnitudes by a power of 256 to pad the
divisor to a suitable recursive block multiple, then unscale the remainder.
The quotient is unchanged. This is an established normalization approach,
also used in [V8's B-Z divider](https://chromium.googlesource.com/v8/v8.git/+/main/src/bigint/div-burnikel.cc),
not a novel algorithm. With the current cutoff, suitable examples are
4,098 to 4,160 bytes and 16,385 to 16,640 bytes. The experiment must retain
fixed controls, cover neighboring widths and quotient boundaries, verify
scaling/denormalization with independent oracles, and measure the added copying
before selection. It will keep byte storage and the existing default dispatch
during qualification.

### Byte-padding candidate qualification

The experimental `divModBurnikelZieglerPadded` entry scales both magnitudes by
the same power of 256, runs the fixed selected kernel, and removes the scaling
from the remainder. All storage remains byte buffers. The quotient and its
required output capacity are unchanged. The helper rounds the divisor width to
the smallest recursive multiple whose leaf falls below the 128-byte cutoff.
It avoids scaling below 4,096 divisor bytes, at dividend-length gaps through
1,024 bytes, and when the width already has a suitable recursive shape.

This first implementation uses separate scaled input and remainder buffers so
the cost of allocation and copying remains visible. Fusing those copies into
normalization is a later measured option. SIMD changes are deferred while this
experiment addresses premature recursion termination at odd widths. The normal
divider and its public dispatch threshold remain unchanged.

Failing-first tests cover the rounding helper, overflow, exact output capacity,
high zero input padding, eight normalization shifts, and independently
constructed zero, unit and maximal remainders. Full GMP references cover nearby
divisor widths and quotient-length boundaries. Signed tests exercise four sign
combinations, output aliases and allocation failures. The paired adapter has
domain-classification and corrupted-reference controls; its CLI check first
failed because the new route did not exist.

`profiling-division-padding.json` defines a bounded paired experiment at 13
divisor widths around 4,096, 8,192 and 16,384 bytes, with gaps 7, 8, 1,024,
1,025 and the divisor width. Each 1-CPU and 12-CPU cohort uses five fresh
processes, 32 prepared cases, six ABBA/BAAB samples and complete GMP quotient
and remainder references. Components `quotient_1024` and `padded` identify the
fixed control and candidate. GMP supplies expected results outside timing;
this experiment does not measure GMP speed. No padding performance claim or
default selection has been made.

The complete suite passed in 90 seconds of mixed Nix preparation and checking;
the production build and all-system flake evaluation passed. Compilation and
execution were not separately instrumented, so this does not establish the
five-second execution budget. The focused probe check took 35 seconds for its
combined build phase and execution.

### Byte-padding results

The first paired sweep rejects unconditional padding above the existing
1,024-byte gap guard. Common scaling helps some balanced inputs but can force
expensive recursion when the quotient is still relatively short. The fixed
control is the selected B-Z kernel with its 1,024-byte Knuth fallback; these
are BLIP-to-BLIP ratios, with no timed GMP competitor.

| Divisor bytes | Padding / fixed CPU, gap 1,025 | Padding / fixed CPU, gap = divisor width |
|---:|---:|---:|
| 4,097 | 2.174 / 2.183 | 1.048 / 1.049 |
| 4,098 | 1.754 / 1.758 | 1.268 / 1.268 |
| 8,191 | 2.528 / 2.534 | 0.694 / 0.697 |
| 8,193 | 2.517 / 2.469 | 0.743 / 0.742 |
| 8,194 | 1.790 / 1.795 | 1.039 / 1.042 |
| 16,383 | 2.850 / 2.847 | 0.493 / 0.490 |
| 16,385 | 2.797 / 2.807 | 0.516 / 0.516 |
| 16,386 | 1.881 / 1.887 | 0.817 / 0.817 |

Cells give paired medians for the 1-CPU / 12-CPU affinity cohorts. Every
process-mean ratio, including diagnostic attempts, agrees with the direction
of each listed cell. The candidate delegates to the fixed kernel at gaps
through 1,024, at widths below 4,096, and at already suitable aligned widths;
those controls have paired medians near parity. This is evidence for an
operand-shape-dependent choice, not a general alignment benefit. The default
divider and public threshold remain unchanged. A follow-up must sample more
intermediate widths and quotient geometries before selecting a guard.

Campaign `blip-mp-pad-20261028T212730Z` measured commit
`00e0bb924a8bf86cd2202f750a710952101a97de` using
`profiling-division-padding.json`. All 180 processes verified their complete
results, including ten five-process timing retries. Twenty-two cohorts are
unbaselined. Four remain inconclusive: 4,094/12 CPU, 8,192/12 CPU,
8,193/12 CPU and 16,383/1 CPU. No baseline was approved. The
[summary](../benchmarks/storage-aware/division-padding-summary.json) preserves
all process means and the verdict attached to each row.

The platform was Linux x86_64 with a Threadripper 3990X, Zig 0.16.0
ReleaseFast and GMP 6.3.0 reference generation. Source digest
`2d0de98ee6dfb5f70a64fc9ccb4b00e81104aec111db7b8b8b389d110e2e829f`
remained unchanged; the probe SHA-256 was
`4b051d0ba07f3953a11b3263f3d036eb8383ce4722f7d66d175c9bbf553472f2`.
Exact-commit CI passed in 227 seconds. The single-threaded kernels do not
become parallel merely because a cohort permits 12 CPUs.

### Padding shape follow-up

The next experiment tests a more specific explanation for the mixed results:
padding may help when the unpadded recursion reaches a large odd leaf and the
dividend is sufficiently longer than the divisor. This is a hypothesis, not a
selected rule. `profiling-division-padding-shape.json` samples divisor widths
around 6,144, 8,192, 12,288 and 16,384 bytes, including odd neighbors and even
neighbors whose first halving reaches an odd width. Its gap axis is one
quarter, one half, one and three times the divisor width, rounding down the
first two. The longest inputs therefore have four times the divisor's width.

The new `padding-shape` mode retains the fixed `quotient_1024` and `padded`
components, full GMP references, 32 cases and six paired samples. It declares
`division-padding-shape-paired-v1` separately. Five fresh processes run in each
1-CPU and 12-CPU cohort. Arithmetic and dispatch are unchanged. This campaign
also does not time GMP.

Failing-first checks classify the complete accepted width and relative-gap
domains and verify long quotients against GMP, including corruption rejection.
The long-quotient check exposed the fixture's historical two-divisor-width
output capacity. Its allocation now grows when that capacity cannot hold the
quotient, while old workloads retain their original capacity and timed output
poisoning cost. The CLI check first failed on the missing mode, then checks the
full metadata and component-sample normalization at a small and a new large
width. These controls remain part of the complete test entry point.

The expanded probe passed the full suite in 87 seconds of mixed Nix
preparation/check time, plus the production build and all-system evaluation.
The focused probe's combined compilation/execution phase took 36 seconds.
These durations do not isolate test execution or establish its latency budget.

### Padding shape results

The expanded sweep supports testing a conservative guard based on the odd
leaf reached by repeatedly halving the original divisor width. Require that
leaf to be at least 6 KiB and the dividend to be at least twice the divisor's
byte length. This guard excludes the measured losses at widths 6,146 and
8,194, whose odd leaves are 3,073 and 4,097 bytes. It also excludes short
quotients that do not justify the added recursion. The 6 KiB bound is a
conservative candidate, not an optimal crossover estimate; the sampled
6,143-byte odd divisor also benefits on balanced and long inputs.

| Divisor bytes | Odd leaf bytes | Padding / fixed CPU, balanced | Padding / fixed CPU, 4:1 dividend |
|---:|---:|---:|---:|
| 6,145 | 6,145 | 0.836 / 0.838 | 0.822 / 0.826 |
| 8,191 | 8,191 | 0.687 / 0.689 | 0.673 / 0.674 |
| 8,193 | 8,193 | 0.738 / 0.738 | 0.733 / 0.729 |
| 12,287 | 12,287 | 0.516 / 0.515 | 0.505 / 0.505 |
| 12,289 | 12,289 | 0.591 / 0.593 | 0.584 / 0.586 |
| 12,290 | 6,145 | 0.917 / 0.916 | 0.919 / 0.922 |
| 16,383 | 16,383 | 0.489 / 0.490 | 0.480 / 0.482 |
| 16,385 | 16,385 | 0.520 / 0.527 | 0.513 / 0.524 |
| 16,386 | 8,193 | 0.829 / 0.828 | 0.839 / 0.830 |

Cells give paired medians for 1-CPU / 12-CPU affinity cohorts, against the
same fixed quotient-1024 BLIP kernel. The proposed guard covers 36 measured
cells with median CPU savings of 8–52%. All process-mean ratios in those cells
favor padding except one diagnostic process at width 16,386 and a balanced
dividend, which took 1.00456 times the fixed kernel's CPU time. That cohort's
selected attempt and its earlier campaign favor padding. Preserve this
exception rather than describing the result as an every-process win.

Half-width gaps have mixed results: width 6,145 loses about 5%, while 12,290
has a small median gain but individual processes lose up to 3%. Quarter-width
gaps usually lose, though the largest odd widths benefit. The conservative
guard leaves some measured gains unused to avoid a more complicated rule.
Aligned widths remain near parity. Arithmetic dispatch is still unchanged;
qualify the guarded entry and its signed wrapper before any selection, and
do not extrapolate this sweep into a performance claim above its tested range.

Campaign `blip-mp-shape-20261028T214046Z` measured commit
`5f9341344542c56dcfcca6b441117828a9a96c85` with
`profiling-division-padding-shape.json`. All 165 processes verified their
results, including one five-process timing retry at width 16,386 in the
1-CPU cohort. All 32 cohorts are unbaselined; no baseline was approved.
The [summary](../benchmarks/storage-aware/division-padding-shape-summary.json)
retains the smaller-gap losses, paired sample ranges and all process-mean ratios.
GMP supplies references outside timing, so these remain BLIP-to-BLIP results.

The Linux x86_64 / Threadripper 3990X / Zig 0.16.0 ReleaseFast configuration
is unchanged. Source digest
`054174534ffc91b216eef371f8f7073ae66c98d56b29d862b888190ed92c3bcc`
remained stable, and the probe SHA-256 was
`590169437e62ef5c9c765fed404ef47af150423b29a82939355d956f5eeef2e7`.
Exact-commit CI passed in 187 seconds.

### Guarded padding qualification

`divModBurnikelZieglerGuarded` is a separate experimental entry. It trims the
dividend's significant length, requires a gap at least the divisor width, and
extracts the odd part of that width with a trailing-zero count. An odd part
of at least 6 KiB selects common-byte padding; all other inputs use the fixed
quotient-1024 kernel. The length comparison uses subtraction to avoid overflow
from doubling the divisor width. The normal divider remains unchanged.

The guard first returned false and the entry called only the fixed kernel.
An exhaustive set classifier through 65,536 divisor bytes, native-size overflow
boundaries, and allocation-constrained dispatch checks failed against those
placeholders. The expected width set is constructed from odd leaves and their
powers-of-two multiples, independently of the implementation's bit operation.
Two high zero dividend bytes in the dispatch fixture verify that physical
capacity cannot change the decision. Signed checks cover kernel binding,
every sign, output aliases and allocation failures at both sides of the guard.

The `guarded-signed` probe compares `fixed_1024` with `guarded` through their
standard signed wrappers. A deliberate test build bound both labels to the
fixed kernel: complete arithmetic checks passed but the binding control failed.
The CLI check separately failed on the missing route. The corrected method is
`division-guarded-signed-paired-v1`, preserving the four-sign/eight-shift corpus,
32 cases, six paired samples and full canonical BLIP result comparisons.
`profiling-division-guarded-signed.json` declares five geometries at widths
6,145, 8,194, 12,290 and 16,385 bytes in 1-CPU and 12-CPU cohorts. The excluded
8,194-byte width is a control for the guard. GMP supplies references outside
timing, so this does not replace the direct GMP comparison.

### Guarded signed results

The signed-wrapper comparison confirms gains at 6,145 and 16,385 divisor
bytes, but the 12,290-byte case has only a small median gain. Keep the guard
experimental while measuring its direct GMP position and the marginal region.
The normal divider and public threshold remain unchanged.

| Divisor bytes | Guarded / fixed CPU, balanced | Guarded / fixed CPU, 4:1 dividend |
|---:|---:|---:|
| 6,145 | 0.894 / 0.892 | 0.885 / 0.882 |
| 8,194 (excluded control) | 0.999 / 1.000 | 0.999 / 0.998 |
| 12,290 | 0.980 / 0.980 | 0.989 / 0.986 |
| 16,385 | 0.561 / 0.561 | 0.555 / 0.556 |

Cells give paired medians for the 1-CPU / 12-CPU cohorts. The 6,145-byte
cases save about 11–12% CPU and the 16,385-byte cases save 44–45%; every
process mean favors the guard in those cells. At 12,290 bytes, median savings
are only 1–2%, and some processes lose up to 1.9%. The short-gap and excluded
control medians remain within 0.3% of parity, with wider individual-process
variation retained in the [summary](../benchmarks/storage-aware/division-guarded-signed-summary.json).

These are full signed calls with four sign combinations and eight normalization
shifts, compared against the fixed quotient-1024 signed wrapper. Differences
from the preceding positive byte-kernel experiment include the fixture corpus,
allocation and verification adapters, so their percentages are not interchangeable.
GMP supplies canonical quotient/remainder references outside timing; it is not
a timed competitor in this campaign.

Campaign `blip-mp-guard-20261028T222133Z` measured commit
`878bec6b4874435e62a312574294591440a089cc` using
`profiling-division-guarded-signed.json`. All 55 processes were correct,
including one five-process retry for `two_chunk_start` in the 12-CPU cohort.
All ten cohorts are unbaselined; no baseline was approved. Source digest
`f5fc23915eb0a7b4ce83ad5c72efa86fd297b97a5240d2d822d669a3ec375029`
remained stable and the probe SHA-256 was
`d69942a3901f078b2a5415c4f37c0b50d395c6272c8ebee312019d6b7bdc2e95`.
The Linux x86_64 / Threadripper 3990X / Zig 0.16.0 ReleaseFast / GMP 6.3.0
configuration is unchanged. Exact-commit CI passed in 211 seconds.

### Guarded direct comparison qualification

The `guarded-competitors` mode times public BLIP, the fixed quotient-1024
byte kernel, the guarded byte kernel and ordinary GMP on identical positive
2:1 operands. `profiling-division-guarded-competitors.json` selects divisor
widths 6,145, 8,192, 8,194, 12,290, 16,384 and 16,385 bytes, retaining aligned
and excluded controls alongside the padded cases. Five fresh processes run
in each 1-CPU and 12-CPU cohort. The method is
`division-guarded-competitors-v1`.

This retains the existing 64-fixture, eight-normalization-shift corpus,
256-call warmup and eight rotating ABCDDCBA samples. Each method visits all
64 cases per sample at these large widths. Full results are checked on every
call. Public BLIP compares canonical encodings, byte kernels compare quotient
and remainder magnitudes plus canaries, and GMP uses `mpz_cmp`; those adapter
costs remain included and differ between representations.

The new width classifier failed against a rejecting placeholder. A deliberately
miswired guarded method returned correct arithmetic through the fixed kernel,
but failed the allocation-based binding control against the padded kernel at
6,145 bytes. The CLI separately failed on the missing mode. Its checks now
exercise both 64-byte and 6,145-byte divisors, including component identities,
work counts, sample dimensions and normalization. Arithmetic dispatch is
unchanged.

The complete suite passed in 94 seconds of mixed Nix preparation/check time,
with the unit/C-API build phase accounting for 91 seconds including compilation
and execution. The production build and all-system evaluation passed. This
qualifies the measurement method; it does not establish execution-only test
latency or a new performance result.

### Guarded direct GMP results

GMP remains faster in the direct guarded-padding comparison. At the six
sampled divisor widths, public BLIP takes 6.2–11.2 times GMP's CPU time and
the experimental guarded byte kernel takes 4.9–5.8 times GMP's time. The
large local improvements therefore do not establish a division win over GMP.

| Divisor bytes | Public / GMP CPU | Fixed B-Z / GMP CPU | Guarded B-Z / GMP CPU | Guarded / fixed CPU |
|---:|---:|---:|---:|---:|
| 6,145 | 6.23 / 6.27 | 6.28 / 6.32 | 5.27 / 5.30 | 0.838 / 0.838 |
| 8,192 | 7.10 / 7.14 | 4.91 / 4.93 | 4.91 / 4.92 | 1.000 / 0.998 |
| 8,194 | 7.07 / 7.10 | 5.05 / 5.06 | 5.05 / 5.07 | 0.999 / 1.001 |
| 12,290 | 8.89 / 8.90 | 5.77 / 5.77 | 5.28 / 5.30 | 0.916 / 0.918 |
| 16,384 | 11.17 / 11.22 | 5.44 / 5.45 | 5.44 / 5.45 | 1.000 / 0.999 |
| 16,385 | 11.17 / 11.19 | 11.22 / 11.22 | 5.81 / 5.82 | 0.518 / 0.519 |

Cells give paired medians for 1-CPU / 12-CPU affinity cohorts. Dividends are
twice the divisor's magnitude byte width. At 6,145 bytes the guarded kernel
saves about 16% against the fixed B-Z control; at 16,385 bytes it saves 48%.
Every process mean favors the guard in those two widths. The 12,290-byte
case saves about 8% at the median, but one diagnostic process takes 3.8%
more CPU than the fixed control. The aligned and excluded widths remain
near parity between the two kernels. Their differences from earlier GMP
ratios are not attributed to padding, which those widths do not select.

The public path is still unchanged. Kernel-to-public ratios include different
allocation and verification adapters and cannot by themselves establish a
public dispatch crossover. The separate signed-wrapper campaign also found
only 1–2% median savings at 12,290 bytes. Keep the guard experimental; no
public threshold or historical baseline is selected from these results.

Campaign `blip-mp-guard-gmp-20261028T223257Z` measured commit
`7182b6ce897590ab0b5e741cf1997158214561ca` using
`profiling-division-guarded-competitors.json`. All 15 processes verified their
results, including the single permitted five-process retry of the 1-CPU case.
Both cohorts are unbaselined. The
[summary](../benchmarks/storage-aware/division-guarded-competitors-summary.json)
preserves all process-mean ratios and selected paired-sample ranges.

The platform was Linux x86_64 / Threadripper 3990X with Zig 0.16.0 ReleaseFast
and ordinary GMP 6.3.0. Source digest
`46868c8f77e7ec4c03c2ae6cc1f85d0361f1e97e6b319ed59339d695e7ac1fa7`
remained unchanged; probe SHA-256 was
`05662d3f475a8465e25c1da7412e33e7f7f8c4a5a5420d43465e67cbeb940866`.
Exact-commit CI passed in 201 seconds after about four minutes in the queue.

### Small divisor follow-up

The next bounded experiment concerns a large byte payload divided by a
register-sized value. The existing `divModSingleU64` walks 8-byte chunks and
handles a high partial chunk byte by byte. In the ReleaseFast x86_64 binary
used for the guarded GMP campaign, both loops call `__udivti3` once per step.
The compiler derives the remainder with a multiply and subtraction; it already
combines the source division and remainder operations. This is code-generation
evidence, not yet a profile attributing total public-call time to that helper.

`invertChunk` and `div2by1` already implement a reciprocal-assisted primitive
elsewhere in the library. Test whether its one-time normalization and reciprocal
cost can be amortized across a long payload. A separate native division for the
leading partial chunk is another candidate. Neither technique is claimed new.
Both can keep stored arbitrary-precision values in bytes and use register-local
operands without introducing a limb array.

First qualify an identical-input probe with variable divisors, full GMP
quotient/remainder checks and aligned/unaligned dividend lengths. The historical
`single_byte` and `single_chunk` cases use different constant divisors, 101 and
65,537, so their timings cannot isolate this proposed change. Retain the current
kernel as a fixed control, measure setup costs and short-input regressions, and
check the signed public path before selecting a dispatch rule. The loop's
remainder dependency limits straightforward SIMD across chunks of one division;
batch throughput is a separate workload. No small-divisor implementation change
has been made in this report.

### Variable small-divisor probe qualification

`single-variable` compares the current `divModSingleU64` byte kernel with
ordinary GMP on identical positive values. The divisor has 1, 2, 4 or 8
magnitude bytes and varies across 32 deterministic fixtures, including all
eight top-byte normalization shifts. Dividend lengths are 8/9, 16/17, 64/65,
256/257, 1,024/1,025 and 4,096/4,097 bytes. The adjacent lengths expose the
cost of a high partial chunk. This is an unsigned kernel comparison, not a
signed public-API result.

The method is `division-single-variable-paired-v1`.
`profiling-division-single-variable.json` declares five fresh processes for
each divisor width in both affinity cohorts. Each size gets 64 warmup calls
and six ABBA/BAAB samples. Fixed 512 repeats per fixture give 16,384 verified
calls per method/sample at every size, keeping these linear-time workloads
longer than the tiny recursive-probe batches. Strict clock-error handling and
the shared pairing/normalization controls remain in use.

The byte kernel includes copying the prepared dividend into its reusable
in-place output, decoding the variable divisor, and comparing every quotient
byte and the full remainder. GMP uses preconverted `mpz` inputs, reused result
objects and complete `mpz_cmp` checks. Those adapter costs differ and remain
included. Setup, reference generation and cold allocation are outside timing.

The width-pair classifier and three fixture/oracle/ownership tests failed
against their placeholders. Native `u128` arithmetic checks GMP references
at 8- and 16-byte dividends, and all accepted payload lengths exercise the
real kernel, GMP, output canaries and separate quotient/remainder-reference corruption.
Allocation-failure injection uses 257-byte values to exercise heap-backed
integer ownership. The CLI check first rejected the missing mode, then passed
schema, component, work-count and sample checks for every divisor width at
8, 9, 64 and 65 dividend bytes. No arithmetic dispatch changes accompany this
probe.

The complete suite passed in 91 seconds of mixed Nix preparation/check time;
the unit/C-API build phase took 88 seconds including compilation and execution.
The production build and all-system evaluation passed. This establishes no
execution-only test-latency result or new arithmetic speedup.

A later complete run, after adding separate remainder-reference corruption,
failed in the legacy CLI check without diagnostics. A bounded reproduction
using that exact executable failed on attempt 55 in `single_chunk` with
`ClockFailed`. Its smoke samples requested only two operations. This establishes
a legacy failure mode; the original empty log cannot prove the same cause.
The smoke check now requests 256 operations per sample, asserts that declared
count and reports failed commands with captured stderr. An injected failure
checks the diagnostic text and exit status. Strict clock errors and the actual
benchmark configurations remain unchanged.

All 3,000 invocations in the bounded legacy-mode reproduction passed with
256 operations per sample. The final complete suite passed in 90 seconds of
mixed Nix preparation/check time, including an 87-second unit/C-API build
phase. The production build and all-system evaluation passed. These checks
qualify the mitigation without identifying the clock's underlying cause.

### Variable small-divisor results

The current byte kernel wins at the smallest sampled dividends and loses as
the dividend grows. With 8- or 9-byte dividends, paired CPU ratios are
0.67–0.95 times GMP; every process mean, including diagnostic attempts, is
below one at those two lengths. At 4,096 bytes the kernel takes 3.21–3.43
times GMP's CPU time. These are unsigned byte-kernel measurements with the
adapter costs described above, not signed public-API results.

| Divisor bytes | 8-byte dividend: current / GMP | 64-byte dividend: current / GMP | 4,096-byte dividend: current / GMP |
|---:|---:|---:|---:|
| 1 | 0.67 / 0.90 | 1.72 / 1.85 | 3.28 / 3.43 |
| 2 | 0.87 / 0.86 | 2.12 / 2.19 | 3.41 / 3.41 |
| 4 | 0.83 / 0.75* | 1.83 / 1.90* | 3.39 / 3.39* |
| 8 | 0.87 / 0.83 | 1.76 / 1.94 | 3.21 / 3.36 |

Cells give paired medians for 1-CPU / 12-CPU affinity cohorts. The starred
4-byte-divisor, 12-CPU cohort remains inconclusive after its one permitted
variation retry. The 8-byte-divisor, 12-CPU cohort also retried once and is
unbaselined. The other six cohorts are unbaselined on their first attempt.
All 50 processes verified their complete results. No baseline is accepted.
Small-value ratios vary appreciably across processes, so this experiment
does not establish a precise public crossover or a universal speedup.

Campaign `blip-mp-single-20261028T231722Z` measured commit
`c99ce4a703b02a9d4efb57b3be4b7eaf82c8f255` on Linux x86_64 with a Threadripper
3990X, Zig 0.16.0 ReleaseFast and ordinary GMP 6.3.0. The measured executable
SHA-256 was `8d9bf2713f5c862bfdbdc96ada625da6df518a0b0100b74850fdc55b745a64fc`;
source digest `60db35aa87fd28ccc134c7e64ba0906aaf22d5e8907e63fced96a081f2e06e51`
stayed unchanged throughout. The [sanitized summary](../benchmarks/storage-aware/division-single-variable-summary.json)
retains all 96 size/cohort cells and every process ratio, including diagnostics.

The growing gap justifies testing reciprocal reuse for longer dividends.
Inspect the candidate's generated code and measure setup cost at small sizes
before selecting it. The existing public divider and all thresholds remain
unchanged.

### Reciprocal small-divisor qualification

`divModSingleReciprocal` is an experimental byte-payload entry point. It
divides the leading 1–8 bytes natively, then uses the existing normalized
Möller–Granlund reciprocal and correction primitive for lower chunks. The
reciprocal is computed once per call. Keeping the remainder normalized avoids
a remainder shift after each chunk. No stored limb array, heap allocation or
public dispatch change is introduced.

Two native-oracle tests failed against the placeholder before implementation.
They cover every payload length from zero through 64 bytes, all 64 divisor
bit positions, nearby powers of two, seeded values, zero/exact results and
the maximum divisor. Output canaries guard both ends. The paired adapter's
native-oracle, full-result corruption and allocation tests also failed before
the candidate was connected; its CLI check rejected the missing mode. The
completed adapter checks all eight normalization shifts at every accepted
divisor/dividend width, up to 4,097 bytes, against GMP.

`single-reciprocal` uses `division-single-reciprocal-paired-v1`, with the same
32 fixtures, 512 repeats, six ABBA/BAAB samples and two affinity cohorts as
the preceding probe. Its components are `current` and `reciprocal`. Both
include the same input copy, variable-divisor decode, complete quotient and
remainder comparison and canaries. Reciprocal setup remains inside every
timed call. GMP supplies references outside timing. This comparison can
establish a local kernel improvement, not a direct win over GMP or a signed
public-API crossover.

The first generated-code inspection found the fixed loop calling `__udivti3`
per chunk, while the candidate uses scalar multiply/shift/correction operations
with reciprocal division outside the loop. SIMD remains limited by the running
remainder dependency. The inspection also found two native leading-chunk
divides separated by an output write. Moving both calculations before the
write did not change the executable: both builds had SHA-256
`9470b41d80526ac94d5fc8bd0fbd3b6672ac42b29bbcccb29b09eeea9e9cc11b`.
The two leading divides remain a measured setup cost. Measure the compiled
result before selecting a cutoff or changing public behavior.

The complete suite passed in 89 seconds of mixed Nix preparation/check time;
the unit/C-API build phase took 87 seconds. Production build and all-system
evaluation passed. This is correctness qualification, not a performance verdict.

### Reciprocal small-divisor results

Reciprocal reuse reduces the current BLIP kernel's CPU time for every sampled
dividend length from 64 through 4,097 bytes. At 64 bytes it saves 20–27%; at
256 bytes, 44–45%; at 4,096 bytes, 51–52%. Every process mean, including
diagnostic attempts, favors the candidate at those longer lengths. This
compares BLIP kernels; GMP is only the correctness oracle for this campaign.

| Divisor bytes | 8-byte dividend: reciprocal / current | 16-byte dividend | 64-byte dividend | 256-byte dividend | 4,096-byte dividend |
|---:|---:|---:|---:|---:|---:|
| 1 | 1.397 / 1.399* | 1.708 / 1.660* | 0.797 / 0.796* | 0.558 / 0.558* | 0.484 / 0.485* |
| 2 | 1.365 / 1.363* | 1.564 / 1.592* | 0.780 / 0.781* | 0.559 / 0.557* | 0.486 / 0.485* |
| 4 | 1.275 / 1.272 | 1.534 / 1.531 | 0.753 / 0.755 | 0.555 / 0.554 | 0.487 / 0.488 |
| 8 | 0.927 / 1.003 | 1.266 / 1.276 | 0.726 / 0.733 | 0.548 / 0.547 | 0.492 / 0.492 |

Cells give paired medians for 1-CPU / 12-CPU affinity cohorts. Starred cohorts
remain inconclusive after their single permitted variation retry; the other
six are unbaselined. Five cohorts retried once, for 65 correct processes in
total. No baseline is accepted. The [sanitized summary](../benchmarks/storage-aware/division-single-reciprocal-summary.json)
retains all 96 size/cohort cells and diagnostic process ratios.

Short inputs often lose substantially: at 16 bytes, the candidate takes
1.27–1.71 times the fixed kernel's CPU time. The apparent 8-byte-divisor win
at an 8-byte dividend is inconsistent across cohorts and processes. Do not
replace the kernel unconditionally. A conservative experimental signed path
can retain the current kernel below 64 magnitude bytes, then measure full
public-wrapper costs and direct GMP comparisons before selecting anything.
This proposed boundary is the lowest sampled winning length, not a proven
optimal crossover; intervening lengths remain unmeasured.

Campaign `blip-mp-recip-20261028T233037Z` measured commit
`3d47f7e94c7fd5e2bf9dbba61a59f3c7166ffddb` on the same Linux x86_64,
Threadripper 3990X, Zig 0.16.0 ReleaseFast and GMP 6.3.0 configuration. Its
executable SHA-256 was `9470b41d80526ac94d5fc8bd0fbd3b6672ac42b29bbcccb29b09eeea9e9cc11b`;
source digest `ce75ccbdb70ec3934d543f1fbb8c7403d019cc5cae1538b0c198fb63b23f0f79`
stayed unchanged. Exact-commit CI passed. Public dispatch is unchanged.

### Signed reciprocal qualification

`Mp.divModSmallReciprocal` is an experimental comparison entry. It shares
the ordinary immediate-value fast path, sign conversion, scratch ownership
and result encoding with `Mp.divMod`. For divisors of at most eight magnitude
bytes, it selects reciprocal division only when the dividend has at least
64 magnitude bytes. Larger divisors retain the existing path. Ordinary
`Mp.divMod` still selects its original kernel.

The new entry first failed the existing sign, divide-by-zero and minimum-i64
promotion tests. A complete bounded length classifier failed before the
64-byte guard was implemented. The signed fixture tests then failed against
their placeholder before construction and execution were connected.

The fixtures cover four signs and eight normalization shifts. Native `i256`
division checks 8- and 16-byte input references. GMP checks the full results
at 16, 63, 64, 65, 257 and 4,097 dividend bytes, including a 9-byte-divisor
control for the unchanged larger-divisor path. Aliasing checks write quotient
and remainder over both inputs in both arrangements. Separate reference
corruptions must reject wrong quotients and remainders. Allocation-failure
injection covers partial signed fixture construction, heap-backed outputs
and cold division scratch.

All four signed fixture checks passed. The complete suite passed in 90
seconds of mixed Nix preparation/check time, including an 86-second unit/C-API
build phase. Production build and all-system evaluation passed. Timed signed
comparisons and direct GMP measurements remain outstanding.

### Signed reciprocal timing probe

`single-signed public` pairs the current public divider with the experimental
signed entry. `single-signed gmp` pairs ordinary GMP with that same entry.
The methods are `division-single-signed-public-paired-v1` and
`division-single-signed-gmp-paired-v1`. Both keep the reciprocal entry as the
second component, so candidate/reference CPU ratios have the same direction.

The configuration declares five fresh processes in each 1-CPU and 12-CPU
affinity cohort for both comparisons and all four divisor widths. Dividend
magnitudes span 8/9, 16/17, 63/64/65, 256/257, 1,024/1,025 and 4,096/4,097
bytes. Each row uses 32 fixtures covering four signs and eight normalization
shifts, 64 warmup calls and six ABBA/BAAB samples with 16,384 calls per method
per sample. Setup and cold allocation are outside timing. Public BLIP calls
include sign conversion, arithmetic allocation and result encoding; GMP uses
preconverted inputs and reusable results. Every call compares complete outputs.

The comparison/width classifier failed against its placeholder, and the CLI
check rejected the missing mode. The completed CLI contract checks both
component bindings, declared work counts, positive CPU/wall samples and
aggregate normalization at 8, 63, 64 and 65 bytes for every divisor width.

Generated-code inspection initially found the candidate inlined into the
adapter while the current public divider remained a function call. The adapter
now forbids inlining for both BLIP calls, giving the comparison a shared call
boundary. This is a benchmark control; library callers retain normal compiler
inlining decisions. The final public-dispatch change, if justified, must still
be measured through its actual consumer path.

The final executable contains separate calls to `Mp.divMod` and
`Mp.divModSmallReciprocal` in both warmup and timed paths. The candidate's
64-byte magnitude check precedes its reciprocal call. Executable SHA-256 is
`c1ff3c9dd8a020424a12bd67b6345d5e45e53360a0894bbd63b85071b2617654`.
The complete suite passed in 87 seconds of mixed Nix preparation/check time,
including an 85-second unit/C-API build phase. Production build and all-system
evaluation passed.

### Signed reciprocal results

The signed candidate preserves much of the kernel gain, while GMP remains
faster. At 4,096-byte dividends, the candidate saves 47–48% CPU relative to
current public BLIP division and takes 1.92–1.94 times GMP's CPU time. At
64 bytes it saves 14–20% against current BLIP; at 256 bytes, 37–39%.

| Divisor bytes | 64-byte dividend: candidate / current BLIP | 4,096-byte dividend: candidate / current BLIP | 4,096-byte dividend: candidate / GMP |
|---:|---:|---:|---:|
| 1 | 0.853 / 0.849 | 0.522 / 0.522 | 1.933 / 1.936 |
| 2 | 0.856 / 0.857* | 0.523 / 0.524* | 1.935 / 1.936 |
| 4 | 0.829 / 0.829 | 0.525 / 0.525 | 1.936 / 1.935 |
| 8 | 0.798 / 0.798* | 0.530 / 0.530* | 1.923 / 1.921* |

Cells give paired medians for 1-CPU / 12-CPU affinity cohorts. Starred
cohorts remain inconclusive after their permitted variation retry. Across
all sampled lengths of at least 64 bytes, every process mean, including
diagnostic attempts, favors the candidate over current BLIP. The weakest
such process ratio is 0.980. The unselected 63-byte control stays close to
parity at the median (0.987–1.001). Smaller control differences are not
attributed to reciprocal arithmetic, which those inputs never select.

The direct GMP comparison favors GMP at every sampled size: candidate/GMP
paired medians range from 1.73 to 3.13. The earlier unsigned raw-kernel wins
at 8/9 bytes therefore do not establish a signed public-API win. BLIP sign
conversion, allocation and canonical encoding remain inside these timings;
GMP starts with preconverted signed inputs. The two adapters have different
costs, and the reported ratios include them.

Campaign `blip-mp-signed-20261028T235632Z` measured commit
`ca614f5a3f6a55af065efe7a7e8325aca417f050`. All 110 processes verified their
full results. Six cohorts retried once; thirteen finished unbaselined and
three inconclusive (public comparison for 2- and 8-byte divisors at 12 CPUs,
and GMP comparison for 8-byte divisors at 12 CPUs). No baseline is accepted.
The [sanitized summary](../benchmarks/storage-aware/division-single-signed-summary.json)
retains all 208 size/cohort cells and diagnostic process ratios.

The platform remains Linux x86_64, Threadripper 3990X, Zig 0.16.0 ReleaseFast
and GMP 6.3.0. Executable SHA-256 is
`c1ff3c9dd8a020424a12bd67b6345d5e45e53360a0894bbd63b85071b2617654`;
source digest `b463e99a80f3db8bf5213aa9173a2ff87c8d73a3fad241e2c3a3bfc045d3fdae`
remained stable. Public dispatch is still unchanged. These results justify
testing the conservative 64-byte guard in the real public entry while retaining
an explicit fixed comparison entry, then measuring that actual dispatch before
claiming a shipped public speedup. Other platforms remain unmeasured.

### Public small-divisor selection experiment

The public `Mp.divMod` entry now exercises the qualified reciprocal guard:
dividend magnitudes of at least 64 bytes and divisor magnitudes of at most
8 bytes. `Mp.divModBeforeReciprocal` preserves the previous entry for paired
comparison. Larger-divisor dispatch, including the 99,999-byte B-Z threshold,
is unchanged. This selection still needs its actual-public-entry timing run
before retention is decided.

The signed probe now compares the actual public entry against either the fixed
entry or GMP. Its methods advance to `division-single-selected-public-paired-v1`
and `division-single-selected-gmp-paired-v1`, with `current` always the second
component. Nine-byte divisors add an unselected larger-divisor control. All
previous dividend sizes, sign combinations, work counts, call boundaries and
full-result comparisons remain. The configuration has twenty cohorts.

The parser's expanded width classifier, fixed-entry oracle checks and CLI
method/component checks failed before implementation. Native signed references
also cover the new nine-byte divisor, including dividends smaller than the
divisor. Alias and allocation-failure checks exercise the actual public entry.

The complete suite passed in 102 seconds of mixed Nix preparation/check time;
the unit/C-API build phase took 100 seconds. Production build and all-system
evaluation passed. Assembly confirms separate public/fixed calls and the
64-byte guard before the reciprocal call. Probe SHA-256 is
`fbc42146e4b450d91501945a675442f2e7c57a3c9a3d1133145ae05ce6a27fe4`.

#### Initial dispatch measurements

Campaign `blip-mp-selected-20261029T001429Z` measured commit
`1e4401a660f941b3a7522d5ea2f8038496a6e505`. At 4,096-byte dividends with
1/2/4/8-byte divisors, actual public division uses 0.520–0.528 times the old
entry's CPU and 1.918–1.928 times GMP's. Every process mean for selected sizes,
including diagnostics, favors the new path (ratios 0.511–0.929).

The nine-byte divisor control exposes a regression outside reciprocal
arithmetic. Public/fixed paired medians are 1.060/1.062 at nine-byte dividends
and 1.068/1.069 at 63-byte dividends (1-CPU/12-CPU affinity). These are about
8 and 15 ns per call, respectively. At 4,096-byte dividends the control is
near parity. Below-cutoff dividends with smaller divisors have paired medians
0.960–1.012. The dispatch change is held for investigation of the larger-divisor
regression.

Assembly shows the selected public entry tail-jumping into an outlined shared
helper, while the fixed entry has its helper inlined. The selected helper also
sets up its scratch frame before its immediate-value checks. The first follow-up
forces this small source-level wrapper to inline, preserving the benchmark's
explicit call boundaries. This is a code-generation hypothesis, not an established
explanation for the timing difference.

All 140 processes verified their results. Eight cohorts retried once; sixteen
finished unbaselined and four inconclusive (both comparisons for two- and
eight-byte divisors at 12 CPUs). No baseline is accepted. The
[initial dispatch summary](../benchmarks/storage-aware/division-single-dispatch-initial-summary.json)
retains all 260 cells and diagnostic process ratios. The executable hash is
unchanged from the qualification above; source digest
`97e14d1a9e6c9fa85423aab0d56f9937a42d025ec69f9784b24a89eb2cfe1b67`
remained stable. Platform, compiler, GMP and measurement work match the preceding
signed campaign. Shared admission delayed preparation by roughly three minutes;
queue and compilation time are outside the recorded probe samples.

The explicit-inlining variant passes the complete suite (103 seconds mixed,
99-second unit/C-API build phase), production build and all-system evaluation.
Its public entry performs immediate-value checks before tail-calling the larger
arithmetic helper; public and fixed benchmark call boundaries remain distinct.
Probe SHA-256 is
`247f8380caab982f2bc1ab7d8f1815fc5dd27e3c7556652a1cc95b32a5fcb6fb`.
Its performance is pending the next frozen-source comparison.

### Build feedback follow-up

Repeated full checks take roughly 90–120 seconds of mixed preparation and
execution. The package derivations currently use `src = self`, so documentation
and benchmark-data commits change their source inputs. The default development
shell also depends on every performance probe. This makes an otherwise unchanged
probe enter the build graph again after a report commit. Compilation and actual
test execution still need separate measurement.

After the current arithmetic experiment, narrow reproducible source closures
against each artifact's actual inputs and verify that all required tests remain
reachable. Preserve Nix as the canonical build path and use disposable fixture
trees for any source-boundary tests. Do not substitute cached verdicts for fresh
test-execution measurements.

### Tiny division clock follow-up

The first complete guarded-padding suite failed on a non-advancing process CPU
clock in the fixed-control method at 64 or 65 divisor bytes. A half-batch of
16 fixtures with 16 repeats took 99,149 ns of monotonic wall time, but the two
process CPU readings were identical. A separate bounded reproduction failed
on process 293 of 500, with the same symptom across 127,164 ns of wall time.
The arithmetic checks had passed. Both failures remain failures; no zero or
wall-clock substitution is accepted.

A startup trace found an unlimited CPU limit and no CPU timer setup. An
independent C recurrence with volatile state saw no stalled reading in 10,000
batches for each of the process and thread clocks, nor in 500 fresh processes
per clock with 100 batches each. These finite checks do not identify the cause
or establish that the native clock is universally reliable.

The mitigation under qualification raises fixed repetitions from 16 to 256
for divisor widths through 128 bytes. Larger widths retain one repetition.
Signed and geometry probes therefore declare 8,192 calls per method/sample at
small widths; the four-method competitor probe declares 16,384. All affected
previously published method and configuration versions advance. The new guarded
method remains v1. Historical result artifacts retain their original versions.
Stopped/backward clocks still fail, with the four observed readings preserved
where diagnostic support exists. The repetition-boundary test failed before
the implementation changed; existing injected-clock checks cover error behavior.

The updated probe passed all 500 bounded native reproductions. The full suite
passed in 120 seconds of mixed Nix preparation/check time; the production build
and all-system evaluation also passed. The unit/C-API build phase accounted for
117 seconds including compilation and execution. Execution-only latency was not
isolated, so this does not establish the five-second test budget. These results
qualify the experiment and batching mitigation without diagnosing the clock
failure or making a new performance claim.

### Exact-capacity remainder regression

Reviewing the B-Z entry point exposed a separate single-byte-divisor bug. With
exactly one byte of remainder capacity, a nonzero remainder was stored but its
reported length was zero: the capacity guard broke before incrementing the
length. Existing tests supplied extra remainder capacity and missed this case.

A native-arithmetic oracle now covers eight dividend boundaries and seven
nonzero byte divisors for all three B-Z variants, with exact remainder capacity
and output canaries. It failed with `expected 1, found 0` before the fix. Since
division by a byte leaves a remainder smaller than 256, the implementation now
writes that byte directly and derives its length from whether it is nonzero.
This branch is shared by the variants but is outside the paired performance
corpus, whose divisors are at least eight bytes.

The complete native suite passed in 91 seconds of mixed Nix preparation/check
time after the fix. Production/probe builds and all-system evaluation passed.

## CRT correctness-reference cost

At commit `43c296f`, a fresh diagnostic run split the 100-case CRT fuzz test
without changing its inputs or checks. Of its 9.996 seconds, schoolbook
reference multiplication consumed 9.032 seconds and CRT multiplication consumed
0.950 seconds. This localized most of that test's cost to its quadratic oracle.

The same 100 seeded operand pairs now use GMP for their reference products.
The FFT still runs in ReleaseSafe, with both result-length and full-byte
comparisons unchanged. Small schoolbook comparisons and the separate 16384-byte
schoolbook case remain. The GMP byte adapter has independent native-u128
boundary checks and refuses undersized output buffers before export. GMP is a
test-module dependency only; the production arithmetic implementation and its
runtime dependencies are unchanged.

With the same diagnostic instrumentation, the updated test took 0.989 seconds:
0.021 seconds in GMP and 0.954 seconds in CRT multiplication. The 497 core tests
totaled 15.531 seconds of per-test execution, excluding process/protocol overhead.
These are shared-host observations; CRT arithmetic itself has not become faster.
The five-second execution budget remains unmet.

The uninstrumented complete native suite and production build passed in 97
seconds combined, including 95 seconds of mixed Nix preparation/check time.
All-system evaluation passed; execution was Linux x86_64 only. The next latency
investigation is bounded parallel execution of the independent inverse corpus
cases, preserving every seeded operand pair, comparison and allocation check.

## Bounded inverse-corpus concurrency

The four inverse cross-check corpora now run with eight workers per test. Each
worker consumes the original seeded random stream, then performs arithmetic
only for its assigned case indices. Allocation checks use a private instance of
the standard testing allocator's exact type. Each worker releases its thread-local
scratch before checking for leaks. All workers join before results are read or
an error returns, including cleanup after a partial thread-spawn failure.

Before replacing the serial loops, a diagnostic build recorded their exact
case counts, inverse counts and indexed input fingerprints. These are now fixed
assertions in addition to every original existence and full-result comparison.

| Comparison | Cases | Inverses | Input fingerprint |
|---|---:|---:|---|
| Stein / Lehmer | 540 | 450 | `81f51a0ea3275c6b` |
| Lehmer / classical | 1200 | 994 | `9467db8a664af935` |
| Wider HGCD / Lehmer | 1120 | 921 | `20aa25b8afbe1ab1` |
| Recursive HGCD / wider HGCD | 1040 | 858 | `dbbe3c0944a5ed00` |

The fingerprint is a regression check, not a proof of input identity. It XORs
Wyhash values seeded by each case's one-based index over its two BLIP encodings.
An exhaustive assignment test checks one owner per case for worker counts one
through eight. A smaller corpus compares serial results against every supported
parallel count. Additional controls reject worker errors, incorrect inverse
existence and incorrect values. The initial empty implementation failed coverage
and count assertions; disabling result checks made the corruption control fail.

The final instrumented ReleaseSafe run measured the four corpora at 0.499,
0.613, 0.284 and 0.379 seconds respectively. The 500 core tests totaled 6.251
seconds of per-test wall time, down from 15.531 seconds before this change.
This excludes process/protocol overhead and sums test spans, not worker CPU time.
The one-second target and five-second complete-execution budget remain unmet.
No arithmetic or SIMD implementation changed; the measured opportunity was
independent correctness cases executing sequentially. Production performance
claims require the separate optimized probes.

The full native suite and production build passed in 95 seconds combined,
including 94 seconds of mixed Nix preparation/check time. The diagnostic core
compilation took 46 seconds. These shared-host observations establish a useful
test-feedback reduction without declaring a new performance baseline.

## Controlled SMT contention

At commit `5906f17`, a bounded experiment compared four consecutive conditions:
no added competitor, an integer competitor on the measured CPU's SMT sibling,
the same competitor on another core sharing L3, and no added competitor again.
The shared engine retained five fresh processes per 1/12-CPU cohort, six
interleaved samples per fixture and its single permitted timing retry.

The competitor was `stress-ng` 0.22.01 from the project's pinned Nixpkgs, using
`--cpu 1 --cpu-method int64 --verify --timeout 90s --metrics-brief` and explicit
CPU affinity. On this host CPU 0's sibling is 64; CPU 65 belongs to another core
in the same L3 group, `0-3,64-67`. The harness waited until the competitor child
had consumed CPU time, checked its affinity, and confirmed it remained alive
through each measurement. It then interrupted and reaped it. Both competitor
runs passed their checks. No host scheduling or SMT settings were changed.

The table gives selected-process means for the mixed-add fixture pinned to CPU 0.
The 12-CPU cohorts allowed migration across CPUs 0–11 and do not isolate the
same sibling relationship.

| Added competitor | CPU ns/add | Cycles/add | Instructions/add |
|---|---:|---:|---:|
| None, before | 6.339 | 23.662 | 89.000 |
| SMT sibling, integer work | 11.535 | 42.644 | 89.000 |
| Other core sharing L3, integer work | 6.164 | 22.480 | 89.000 |
| None, after | 5.741 | 22.460 | 89.000 |

SMT contention can reproduce a substantial slowdown with unchanged instruction
counts. This control does not distinguish shared execution resources from L1/L2
effects, and the other-core integer workload is not a deliberate cache-thrashing
test. It therefore does not rule out cache effects from other workloads. Host
load fell from 100.51 to 87.98 during the campaign; the first no-added-load
cohort still had individual samples as high as 18.54 ns/add. The original
historical outliers remain unassigned. Future close comparisons need matched,
contemporaneous controls and sibling-load awareness; CPU affinity alone is
insufficient isolation.

`readelf -h` identifies this probe as ELF `EXEC`, with entry address `0x1017970`.
Random placement of the main executable's code cannot explain process-to-process
variation for this binary. This does not exclude randomized data addresses or
code-layout differences between separately compiled binaries. The probe's SHA256
stayed `3405ddaab2f5d53875d585d9b15f2f057b81dff0286eb268fbf6101ba15f9d55`.

All 50 measured processes, including two five-process retries, verified their
results. Six cohorts were unbaselined; the 12-CPU before/SMT cohorts were
inconclusive. No baseline was approved. External records use prefix
`blip-mp-contention-20261028T035059Z-`, followed by the condition
(`idle_before`, `smt_int64`, `shared_l3_int64`, `idle_after`) and case name
`contention_<condition>_<1|12>core`. Records span 03:51:03–03:51:40 UTC on October
28. Each condition used a copy of `profiling-linux-counters.json` with its case
names and definitions suffixed by that condition; each source digest remained
stable within its run. The binaries and measured work were identical across
conditions. Execution waited for shared admission before starting; queue time
is excluded from the recorded probe samples.

## Verified modular-exponentiation probe

`./bm --verified-powm` measures the public `Mp.powm` path at 512, 1024, 2048 and
3072 bits. It reuses the existing positive-value generators and their per-case
base/exponent/modulus seeds. Moduli are odd. The named bit widths are nominal
payload capacities with the sign bit clear. Each sample visits all 256 cases
after one complete warmup pass; five samples preserve separate process-CPU and
monotonic-wall times. Historical benchmarks used different iteration counts
by size and did not verify each timed result, so their timings are not directly
interchangeable with this method.

GMP supplies every expected result before timing. Inside timing, each public
call includes its conversions, modulus setup, arithmetic allocation and full
result comparison. The result object is reused; inputs and expected values are
prepared outside timing. The two configured affinity cohorts use five processes
each and explicit 120-second process deadlines. These measurements establish a
current verified workload, not a timed comparison against GMP or an allocation
benchmark.

The empty adapter first failed parsing, fixture and allocation-cleanup tests.
Controls then check corrupted-reference rejection, native modular-power oracle
agreement including zero exponent/base and unit modulus, and every allocation
failure. Injected clocks and work recorders verify exact operation counts,
CPU/wall normalization and error propagation, including stopped/backward clocks.
That timing control failed against its placeholder before implementation. The
CLI check also failed against the empty executable, then verifies its schema,
positive samples, argument rejection and `./bm` routing. All checks are included
in the complete test entry point and the exact-commit CI manifest.

The [Montgomery carry derivation](../benchmarks/storage-aware/MONTGOMERY.md)
shows why a scalar schoolbook truncated reduction has no product-count advantage
over the current cancellation loop. Profile the measured public path before
selecting a replacement. SIMD is deferred until that baseline identifies the
dominant work; batch AVX512 results from other implementations do not establish
a benefit for a single public call here.

The initial ReleaseFast probe had SHA-256
`49022cec702e48b07c44651d1a3b8982ea65092634e1a7595ace66fa1827b4dc`.
Its `montMul` occupied 639 bytes. The two inner loops used scalar BMI2 `MULX`,
64-bit loads from the byte buffers, and scalar carry chains; no packed SIMD
arithmetic appeared in that function. This confirms that temporary chunk reads
compile to native loads. It does not identify the dominant runtime cost of the
whole public exponentiation.

After merging with the Goldilocks occupancy selection, the complete native
suite passed with 13,231 GMP comparisons in 115 seconds of mixed Nix
preparation/check time. The production build and all-system evaluation passed.
This is not a fresh performance measurement or a test-execution-only duration.
