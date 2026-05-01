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
- `src/bignum.zig` — `Mp` bignum struct (**representation 1a (SBO)**: 24-byte inline buffer + heap fallback. Tier 0/1 stays inline → zero allocation in the hot path. Struct size exactly 64 bytes / one cache line). Signed two's-complement payload.
  - Layout: `inline_buf: [24]u8 align(8)`, `inline_len: u8` (sentinel `0xFF` = heap mode), `heap_bytes: []u8`, `allocator: std.mem.Allocator`
  - `INLINE_CAP = 24` — covers all tier 0/1 (max encoded size 9 bytes) plus headroom
  - `Mp.init(allocator)` / `Mp.deinit()` — deinit only frees if currently in heap mode
  - `Mp.bytes()` accessor — returns active slice (inline or heap)
  - `Mp.isInline()` — discriminator query
  - `Mp.setI64(v)` / `Mp.setU64(v)` — routes to inline path when encoded size ≤ INLINE_CAP, heap fallback otherwise
  - `Mp.getI64()` / `Mp.getU64()`
  - `Mp.cmp(other)`, `Mp.sign()`
  - `Mp.add(r, a, b)` / `Mp.sub(r, a, b)` / `Mp.mul(r, a, b)` — tier 0/1 only, errors `TierOverflow` if result exceeds i64
  - Error sets: `SetError`, `GetError`, `ArithError`

## tests/

- `tests/benchmark/blip_mp_bench.zig` — Zig executable. Two implementations measured per bucket: `impl=Mp.add` (current SBO `Mp.add`) and `impl=raw` (zero-alloc tier-0/1 fast path, the theoretical ceiling). Five value buckets from immediate (0..127) through L=4 (>8M..2G). Uses libc malloc (apples-to-apples with GMP). Times via direct `clock_gettime` extern (`std.time.Timer` was removed in 0.16).
- `tests/benchmark/gmp_bench.c` — C executable. Same workload using GMP `mpz_add`. Built via build.zig with `-O3` and `-lgmp` (paths threaded from Nix via `-Dgmp-include-path` / `-Dgmp-lib-path`).

## tests/

(none yet — to be created in Milestone 0)

Planned:
- `tests/unit/encoding_test.zig` — round-trip encode/decode tests
- `tests/unit/arithmetic_test.zig` — tier 0/1 add/sub/mul/cmp
- `tests/benchmark/small_accumulator.zig` — vs GMP
- `tests/benchmark/small_accumulator_gmp.c` — GMP reference implementation
