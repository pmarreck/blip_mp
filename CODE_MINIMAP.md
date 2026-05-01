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
- `src/bignum.zig` — `Mp` bignum struct (representation 1b: `{bytes, allocator}`, always heap, signed two's-complement payload).
  - `Mp.init(allocator)` / `Mp.deinit()`
  - `Mp.setI64(v)` / `Mp.setU64(v)` (rejects v > i64.max for tier 0/1)
  - `Mp.getI64()` / `Mp.getU64()` (rejects negative for u64)
  - `Mp.cmp(other)` returns `std.math.Order`
  - `Mp.sign()` returns -1/0/+1
  - `Mp.add(r, a, b)` / `Mp.sub(r, a, b)` / `Mp.mul(r, a, b)` — tier 0/1 only, errors `TierOverflow` if result exceeds i64
  - Error sets: `SetError`, `GetError`, `ArithError`

## tests/

(none yet — to be created in Milestone 0)

Planned:
- `tests/unit/encoding_test.zig` — round-trip encode/decode tests
- `tests/unit/arithmetic_test.zig` — tier 0/1 add/sub/mul/cmp
- `tests/benchmark/small_accumulator.zig` — vs GMP
- `tests/benchmark/small_accumulator_gmp.c` — GMP reference implementation
