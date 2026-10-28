# Legacy roadmap reconciliation, October 27, 2026

This maps the unchecked items in [the historical roadmap](legacy-roadmap.md)
to the implementation at `4fc69be`. Historical checkboxes remain unchanged.
[PLAN.md](../../PLAN.md) holds actionable work; [INTENT.md](../../INTENT.md)
controls representation and scope. The complete native suite, including 13,111
GMP comparisons, passed before this review. Function presence establishes
implementation, not a performance win.

| Historical item | Current status and evidence | Remaining work |
|---|---|---|
| M1 scaffold, encoding, value type and initial commit | Flake, build graph, ZON, Bash commands, `encoding.zig`, `Mp.setU64` and boundary tests exist. The later signed-only encoding decision supersedes the separate unsigned encoder. | Strict unsigned wire interoperability still needs a contract. The first failing-test event is historical, not something to recreate. |
| Jujutsu and Garnix setup | Superseded by Git and Mechatron Prime CI. Commit `7704ed2` passed exact-commit CI. | Do not restore either retired tool. |
| C FFI header | Implemented in `include/blip_mp.h` and `src/c_api.zig`, exercised by the C smoke suite. | Normal maintenance; this is no longer a deferred M2 task. |
| Tier-3 multiplication returning TierOverflow | Superseded. `Mp.mul` and byte-backed schoolbook, Karatsuba, recursive Toom-3 and asymmetric blocked multiplication exist. | Performance work remains, especially asymmetric shapes and cold scratch allocation. |
| M6-2.1/2 helpers | `divExactBy5` and `mulSmallSignedConst` exist with round-trip and signed tests. | No need to implement them again. |
| M6-2.3–5 Toom-4 | No Toom-4 kernel or dispatcher exists. The roadmap's later “Toom-4 first” decision explicitly lowers its priority and retains only the helpers. | Keep shelved; do not revive it from the early checkboxes. |
| M6-3.1–11 prime, field arithmetic, roots, transforms, packing, carries and multiplication | Implemented in `fft.zig`, including single-prime, CRT and Goldilocks paths. `3cf3388`, `a80073f` and `d945d71` subsequently changed storage and transform passes. Forced-backend GMP tests remain in the full suite. | New layout/transform experiments belong to the ranked research work. |
| M6-3.12/13 FFT dispatch and GMP performance | Dispatch exists, but thresholds exclude single-prime and CRT paths throughout their supported ranges. Goldilocks is reachable for sufficiently large equal-size inputs. Historical benchmark runs exist. | Measure viable crossovers; no universal FFT/GMP win has been established. |
| M6-4-E.3 hand assembly and E.4 Toom-3 | Hand assembly remains deferred by the later owner decision. Toom-3 is the ordinary production choice in the measured range. | Portable storage-aware experiments remain active. Hand assembly is not a mandatory dependency to resume. |
| M11.2 recursive HGCD production dispatch | `invModHGCDRecursive` exists and has comparison tests, but `Mp.invMod` selects classical, Stein, Lehmer or wider-window HGCD paths. | Profile matrix composition and actual crossovers before dispatch changes. The old 2–4× projection is unproven for the current representation. |
| Binary-base mpf comparison | Conditional task remains conditional. Decimal/exact fixed-point support and GMP rational checks do not establish binary mpf compatibility. | Define the required contract before implementation. |
| B-Z threshold tuning | `BZ_INTEGRATION_THRESHOLD` is 99999 bytes, not the earlier 512. The recursive implementation and scratch cache exist. | Benchmark leaf multiplication, allocation and crossover costs before changing the threshold. |
| M15-2 byte-direct Knuth steps 2–3 and D1/D4/D5/D7 | Production `divModSignedLarge` now uses byte buffers and the byte-backed `divModKnuthU64` core. Partial-width/normalization tests compare with native u256 division. The allocating `divModSignedLargeBytes` wrapper remains separate. | The storage objective is met without switching production to that wrapper. Any wrapper change needs a measured benefit. No legacy limb-storage dual path needs restoring. |
| M15-3 FFT byte-buffer migration | Superseded by the stricter canonical-BLIP requirement. Every stored residue is encoded, with five-byte small-field and ten-byte Goldilocks capacities; shifted representatives give small-field residues a fixed canonical payload width. | Never substitute raw fixed-width residues merely to satisfy the older migration proposal. |
| M15-4 storage audit and documentation | `storage_audit.zig` classifies prohibited wide arrays/typed views and audits the five migrated arithmetic modules. Test-only numerical fixtures are excluded deliberately. README and results describe canonical residue storage. | Maintain the audit and distinguish its file coverage from a general proof. The code map's old 16-byte-slot description is corrected with this review. |
| Statistical benchmark harness | `./bm --stable N` and hyperfine support already exist. `4fc69be` adds verified immediate-add probes and external history through the shared engine. | Migrate remaining workloads, investigate variance, and keep fresh timing separate from cached correctness checks. |
| Lehmer-style quotient refinement proposal | Current Knuth estimates use Möller-Granlund 3/2 reciprocals; the roadmap separately records that change. This does not prove every later refinement idea is exhausted. | Profile current division rather than treating the old 470/290 ns estimate as a current baseline. |

The review also found and corrected two build-maintenance issues outside the
old algorithm checklists. `./build --debug` now uses the declared `debug` Nix
package, and `build.zig.zon` advertises the qualified Zig 0.16 minimum. The debug
CLI prints the required yellow marker; release output stays unchanged. Sandbox
tests cover routing, failed-build exit propagation and both CLI profiles. The
complete native suite passed in 163 seconds including preparation; all three
supported systems evaluated successfully. The compiler pin remains Zig 0.16.0.
