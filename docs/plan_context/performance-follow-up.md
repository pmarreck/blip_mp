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
