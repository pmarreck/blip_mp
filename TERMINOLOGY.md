# blip_mp terminology

| Term | Meaning |
| --- | --- |
| BLIP | Binary Large Integer Prefix, a length-prefix encoding with payload length and byte-order metadata. Its framing also serves arbitrary byte payloads. The external specification is [../BLIP/BLIP_SPEC.md](../BLIP/BLIP_SPEC.md). This library applies a signed two's-complement interpretation. |
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

## Signedness and optional interoperability

Signed and unsigned integer conventions can be documented separately while
sharing the same framing. That does not require distinct base formats or
reducing the immediate-value range. This library's existing signed convention
keeps all 0–127 immediates and uses length-prefixed payloads for negatives.

The sibling [BLIP specification](../BLIP/BLIP_SPEC.md#signedness) leaves payload
signedness to the application. `blip_mp` chooses signed two's complement.
The bytes alone do not identify the intended interpretation:

| Encoded bytes (hex) | Unsigned interpretation | Signed interpretation |
| --- | ---: | ---: |
| `81 FF` | 255 | -1 |
| `82 FF 00` | 255 | 255 |

Positive 255 therefore needs two payload bytes in this library's canonical
signed representation. An unsigned consumer can represent it in one payload
byte. Import/export adapters could convert between those conventions while
preserving the mathematical value; their need and error contract remain open.
Earlier references to "strict unsigned-BLIP" or "strict-spec BLIP producers"
describe this optional integration question imprecisely. Signed interpretation
is explicitly supported by BLIP and does not require a format extension.

This library fixes that interpretation at design time and caches sign metadata.
The representation can still cost space: positive 2^183 uses 25 encoded bytes
and heap storage, while negative 2^183 uses 24 and stays inline. The
[signedness investigation](docs/benchmarks/storage-aware/DISPATCH_ISOLATION.md#signedness)
checks this and other boundaries. Changing who specifies signedness would not
by itself remove sign padding or conversions to an unsigned arithmetic kernel.

## Framing and payload conventions

Core framing describes byte length and byte order. A payload convention supplies
numeric type, sign representation, precision and value-level canonicalization.
Integer rules such as trimming redundant sign-extension bytes cannot be applied
to arbitrary payloads: zero bytes, float widths and exact bit patterns may be
significant. Floats or other numeric formats can retain their own sign encoding
without a duplicate framing-level sign.

IEEE floating-point formats define numeric fields, while storage conventions
choose their memory layout; see the
[Oracle numerical computation guide](https://docs.oracle.com/cd/E19422-01/819-3693/ncg_math.html).
Wire formats can make that choice explicit: [XDR](https://www.rfc-editor.org/rfc/rfc4506.html#section-4.6)
uses big-endian floating-point bytes. BLIP's byte-order metadata can therefore
remain useful for such payloads, whose existing sign field needs no duplicate
framing-level sign. A variable-precision numeric format would still have to
define its own fields and precision; length alone does not identify those rules.

Opaque byte sequences are preserved without swapping. For structured payloads,
the payload schema determines which multibyte fields the byte-order metadata
governs. This clarification establishes no new float, posit or arbitrary-blob
codec in this library.
