# BLIP algorithm types: investigation, not a format change

BDFN (Benevolent Dictator For Now) proposed fixed-length or algorithm-defined integer types on September 27,
2026. This note evaluates them against the sibling BLIP specification at commit
`5128c62`. Neither repository's wire format is changed by this experiment.

## What the existing format already provides

[BLIP_SPEC.md](../../BLIP/BLIP_SPEC.md) calls the two-byte patterns `81 00`
through `81 7f` **sentinels**. The container
[BLIP_WIRE_SPEC.md](../../BLIP/BLIP_WIRE_SPEC.md) uses some as attribute
**sigils**. TRUE, FALSE, NIL and VAL occupy the high four values. Container
attributes and historical type assignments occupy other values, so an extension
needs a namespace audit before assigning a number.

The integer header is `1_E_C_LLLLL`. All bits have meanings already. Reserving
an additional bit would change integer decoding. A sentinel escape is a more
plausible extension point and can be rejected by an integer-only decoder.
The spec requires recognizing sentinels; its implementation advice also
mentions a discouraged permissive interpretation. A fail-closed contextual
extension must test actual decoders, not rely on that advice being uniform.

For our positive signed residues below 2^31, the ordinary header `84` already
means a four-byte little-endian payload. A single equality check selects its
read path. Values below 2^23 require shorter canonical encodings; zero is the
single byte `00`. Thus the format already supports the proposed cheap length
check. Writing still requires selecting the canonical width.

## Candidate designs

| Design | Potential gain | Cost or unresolved contract |
|---|---|---|
| Current canonical integers, field-sized capacity | Five-byte small-field slots, ten-byte full-u64 slots; no format change | Variable live length and encoding work remain |
| Per-value fixed-width sentinel type | Constant-width stores and reads | Two-byte sentinel plus four-byte value is six bytes; no longer today's canonical integer encoding |
| Algorithm-defined sentinel type | Width, modulus or signed interpretation can follow a registered context | Needs context identity, version, range checks and deterministic rejection outside that context |
| One context header for a block of raw values | Amortized type overhead and regular access | Violates the current requirement that every stored residue independently has canonical variable-length BLIP encoding |

A contextual type must specify payload length, byte order, signedness, modulus
where applicable, allowed values, canonical form and treatment of unknown
contexts. Unknown context must fail before payload traversal. A length alone
cannot distinguish two fields with different moduli.

## Next decision

Measure the existing header fast path and stage fusion first. Consider an
explicitly separate typed-BLIP experiment only if encoding remains a measured
bottleneck. Its acceptance tests would include decoding without context,
wrong-context rejection, truncated payloads, noncanonical values and namespace
collisions, alongside end-to-end arithmetic and memory measurements.

No sentinel number or reserved bit is selected here. Adopting such a type would
require an explicit change to the present canonical-integer storage contract.
