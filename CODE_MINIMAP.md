# CODE_MINIMAP.md — blip_mp

Per-file index of important code locations. Updated as files are added.

## Top-level

- `SPEC.md` — original design spec for BLIP-storage bignum library
- `PROJECT_OVERVIEW.md` — goals, terminology, non-goals, architecture
- `PLAN.md` — milestone checklist
- `CODE_MINIMAP.md` — this file
- `AGENTS.md` / `CLAUDE.md` — agent briefing (symlinks; not committed)
- `ZIG_RECENT_API_CHANGES_2025.md` — Zig 0.14/0.15 API reference (symlink)
- `flake.nix` — Nix derivation; pulls libblip from sibling repo
- `build.zig`, `build.zig.zon` — Zig build config
- `./build`, `./test`, `./bm` — top-level Bash drivers (per CLAUDE.md conventions)

## src/

- `src/blip_mp.zig` — public Zig surface. Re-exports `encoding` and `bignum`; aliases `Mp = bignum.Mp`. `refAllDecls` ensures every test in dependent files runs.
- `src/encoding.zig` — BLIP integer encoding restricted to the **signed two's-complement** reading (per SPEC.md §Sign convention). One encoder, one decoder; the "where is the sign bit" question is settled by definition (high bit of high payload byte). Functions:
  - `Endian` enum (little/big payload endianness — BLIP permits per-value E bit; decoder honours both)
  - `Error` (BufferTooSmall, UnexpectedEndOfInput, OverlongEncoding)
  - `Decoded` struct (value: i64, bytes_read, endian, is_sentinel)
  - `minPayloadBytesSigned(i64)` — picks smallest L whose i(L*8) range contains value; 0 for immediate range
  - `encodedSizeI64(i64)` / `encodeI64Canonical` / `decodeI64` — canonical signed encode/decode
- `src/bignum.zig` — `Mp` bignum struct (**representation 1a (SBO) + heap reuse + sign-extended inline tail**: 24-byte inline buffer + reuse-aware heap fallback. Tier 0/1 stays inline → zero allocation. For length-prefixed inline values, `inline_buf[1..9]` ALWAYS holds the full sign-extended i64 in LE — public `bytes()` returns only the canonical `[0..inline_len]` slice but internal arithmetic reads the i64 in a single u64 load. This invariant is maintained by `setI64` (single u64 STR for the tail) and `setBytes` (sign-extends canonical payload to byte 9 after copy). For tier 3, `heap_buf` tracks the full allocation and `heap_used` tracks the active value length; `ensureHeapCapacity` reuses the buffer when cap suffices, doubles on grow. Struct size 72 bytes / one cache line + 8B). Signed two's-complement payload.
  - Layout: `inline_buf: [24]u8 align(8)`, `inline_len: u8` (sentinel `0xFF` = heap mode), `heap_used: usize`, `heap_buf: []u8`, `allocator`
  - `INLINE_CAP = 24` — covers all tier 0/1 (max encoded size 9 bytes) plus headroom
  - `Mp.init(allocator)` / `Mp.deinit()` — deinit frees heap_buf if non-empty
  - `Mp.bytes()` accessor — returns `inline_buf[0..inline_len]` or `heap_buf[0..heap_used]`
  - `Mp.isInline()` — discriminator query
  - `Mp.setI64(v)` / `Mp.setU64(v)` — routes to inline path when encoded size ≤ INLINE_CAP, heap fallback otherwise (with cap reuse)
  - `Mp.setBytes(slice)` — install a raw BLIP encoding; reuses heap_buf when cap suffices
  - `Mp.getI64()` / `Mp.getU64()`
  - `Mp.cmp(other)`, `Mp.sign()`
  - `Mp.add(r, a, b)` / `Mp.sub(r, a, b)` — tier 0/1 fast path with cross-tier promotion to tier 3 on i64 overflow (no more `error.TierOverflow` for in-range cases)
  - `Mp.mul(r, a, b)` — tier 0/1 only; tier-3 mul is an open follow-up
  - `Mp.divMod(q, r, a, b)` / `Mp.div` / `Mp.mod` — truncated division (GMP `mpz_tdiv_qr` semantics)
  - `Mp.bitAt(i)` / `Mp.bitLen()` — magnitude bit access (used by powm)
  - `Mp.powm(r, base, exp, m)` — modular exponentiation (square-and-multiply / sliding-window / Montgomery sliding-window dispatch)
  - `Mp.invMod(r, a, m) -> bool` — modular multiplicative inverse via classical Extended Euclidean Algorithm. Returns `true` iff inverse exists (gcd=1); `false` with `r=0` when no inverse. Matches GMP `mpz_invert` return convention. Tracks one Bezout coefficient (s) on `a`; doesn't materialise the t coefficient on `m` since it's unused. Reduces `a` into [0, |m|) before iteration; returns result in [0, |m|). ~bitLen(m) iterations, each one Knuth division (Mp.divMod) — slower than a binary GCD variant but trivially correct.
  - Internal: `ensureHeapCapacity(cap)`, `decodeInlineSmall`, `tier3Op`, `euclideanReduce` (mod into Euclidean range — used by invMod)
  - Error sets: `SetError`, `GetError`, `ArithError`

- `src/tier3.zig` — large-number arithmetic operating DIRECTLY on BLIP payload bytes. No auxiliary limb-array conversion (Peter's "no limbs" insight). Pure-Zig, no GMP dep.
  - `Header { L, endian, bytes_consumed }` — header descriptor
  - `parseHeader` / `writeHeader` — supports L >= 32 with continuation varint
  - `signExtByte(payload)` — returns 0x00 or 0xFF based on payload's high bit
  - `addPayloads(a, b, n, out)` — two's-complement byte-direct add. **Cascading inner loop**: u512 chunks (64 bytes) → u256 (32) → u128 (16) → u64 (8) → per-byte tail. Each chunk size compiles to a sequence of ADCS instructions on aarch64. Returns `n` or `n+1` (extra byte for same-sign overflow).
  - `subPayloads(a, b, n, out)` — same shape with borrow propagation; opposite-sign-overflow detection.
  - `canonicalLen(payload)` — trims redundant high sign-extension bytes (0x00 for positives / 0xFF for negatives) preserving sign. Fast path: returns immediately when high byte is neither 0x00 nor 0xFF.
  - `payloadOf(blip)` — returns the payload slice from a BLIP-encoded value.
  - `negateInPlace(payload)` — two's-complement negation `~payload + 1` for sign-magnitude conversion (used by mul).
  - `mulMagnitudes(a, b, r)` — schoolbook unsigned multiply on LE byte arrays. r[0..a.len + b.len].
  - `addRawBlip` / `subRawBlip` / `mulRawBlip` / `writeBlip` — high-level wrappers over the above.

## tests/

- `tests/integration/cross_check.zig` — exhaustive GMP cross-validation (12029 random comparisons across add/sub/mul/divq/divr/powm/invMod at 18 bit-widths from 8 to 8192 bit). Wall-clock perf snapshots for powm (RSA sizes) and invMod (256/512/1024/2048-bit). Built as `cross_check` exe alongside the bench binaries; run by `./test` after the unit-test pass.
- `tests/benchmark/blip_mp_bench.zig` — Zig executable. Small buckets measure `Mp.add` (full path) and `raw` (zero-alloc theoretical ceiling). Large buckets (256/1024/4096-bit) measure the tier-3 path. Pseudo-random pool seeded from index for the large buckets. Uses libc malloc (apples-to-apples with GMP). Times via direct `clock_gettime` extern (`std.time.Timer` was removed in Zig 0.16).
- `tests/benchmark/gmp_bench.c` — C executable. Same workload shape using GMP `mpz_add`. Built via build.zig with `-O3` and `-lgmp` (paths threaded from Nix via `-Dgmp-include-path` / `-Dgmp-lib-path`). Bench-only dependency; the blip_mp core has no GMP requirement.

## tests/

(none yet — to be created in Milestone 0)

Planned:
- `tests/unit/encoding_test.zig` — round-trip encode/decode tests
- `tests/unit/arithmetic_test.zig` — tier 0/1 add/sub/mul/cmp
- `tests/benchmark/small_accumulator.zig` — vs GMP
- `tests/benchmark/small_accumulator_gmp.c` — GMP reference implementation
