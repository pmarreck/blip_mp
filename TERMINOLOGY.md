# blip_mp terminology

| Term | Meaning |
| --- | --- |
| BLIP | Byte Length Integer Prefix, a variable-length, self-describing byte encoding. The external specification is [../BLIP/BLIP_SPEC.md](../BLIP/BLIP_SPEC.md). This library applies a signed two's-complement interpretation. |
| Payload length (`L`) | Number of payload bytes after the header. `L=0` denotes the immediate form; `L=1..8` is the original tier-1 range. |
| Canonical form | The minimum-width signed encoding for a value, using the immediate form where possible. Overlong sentinel encodings are excluded from ordinary integer values. |
| Shifted field representative | Store `r+p` for residue `r` modulo `p`. This is the same field element with a different integer representative. Its BLIP encoding remains minimum-width for that integer; field zero is stored as the integer `p`. |
| Tier 0 / 1 / 2 / 3 | Original dispatch vocabulary: immediate operands; operands with payloads up to eight bytes; mixed small/large operands; large operands. Current dispatch details belong in code and the minimap. |
| `Mp` / `blip_mp_t` | Zig integer type / opaque C API handle. The original always-heap `{bytes, len}` proposal was replaced by inline storage with heap fallback. |
| SBO | Small-buffer optimization: store short encodings inside the integer object to avoid a separate payload allocation. |
| `Fp` | Exact fixed-point value represented by an `Mp` mantissa, a scale and a binary or decimal base. It does not represent every rational number. |
| `bp` | The Forth-style RPN calculator that consumes the library through its C API. |
| Limb | A genuinely stored fixed-width array element, such as a GMP limb. Production arithmetic no longer stores these arrays. |
| Chunk / view | A register-sized read of a byte buffer used for arithmetic. A transient `u64` value is not itself stored limb-array representation. |
| Fully limbless | Byte-buffer arithmetic without stored limb arrays. FFT residues additionally carry canonical variable-length BLIP encodings; see docs/REPRESENTATION.md for the checked scope. |
| mpn layer | GMP's low-level limb-array primitives. Linking these was an early alternative, superseded by independent arithmetic in the core. |

The limb/chunk distinction follows BDFN (Benevolent Dictator For Now)'s May 16 terminology decision recorded
in the [legacy roadmap](docs/plan_context/legacy-roadmap.md#terminology-note-added-2026-05-16).
