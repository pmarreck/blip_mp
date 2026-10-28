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
The cause remains unestablished. Instrumentation was removed before the final
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
