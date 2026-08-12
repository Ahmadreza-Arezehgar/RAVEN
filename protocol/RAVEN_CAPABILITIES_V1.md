# RAVEN Capabilities V1

**Version:** 1 (`rvn1`)
**Status:** Frozen. See [`SPEC.md`](SPEC.md) for scope and versioning policy.
**Audience:** re-implementers of feature negotiation between clients.

---

## 1. Signed capability set

`RavenProtocolCapabilitiesV1` is a self-signed, identity-scoped claim about
what protocol features an identity supports — carried on the wire as an
`env_type=4` `RavenEnvelopeV1` body ([`RAVEN_ENVELOPE_V1.md`](RAVEN_ENVELOPE_V1.md)).

| Field | Type | Meaning |
|---|---|---|
| `identity_address` | string | the `RavenAddressV1` making the claim ([`RAVEN_ADDRESS_V1.md`](RAVEN_ADDRESS_V1.md)) |
| `capability_bits` | u64 bitmask | the identity-scoped protocol capability set |
| `expires_at_ms` | u64 | unix ms |

**Signing bytes** (`lp(x) = len_be2 || x`, `u64(n)` = 8-byte big-endian):

```
"rvn1/caps" || lp(identity_address) || u64(capability_bits) || u64(expires_at_ms)
```

Signed by `identity_address`'s own Ed25519 identity key — the same
self-attestation pattern used by `RavenAliasRecordV1`
([`RAVEN_ALIAS_V1.md`](RAVEN_ALIAS_V1.md)).

**Vector:** `shared-vectors/rvn1/capabilities/alice_v1.json` — alice's
identity claiming `capability_bits = 15` (`0b1111`).

> `capability_bits` here is a distinct namespace from
> `RavenDeviceCertificateV1.capabilities` in
> [`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md) §2 — that one is
> device-scoped ("this device may act as a bridge/relay"); this one is
> identity-scoped ("this identity's protocol implementation supports these
> wire features"). The two bitmasks are unrelated and MUST NOT be conflated.

## 2. Authenticated negotiation

The legacy shipping mesh transport advertises a *different*, **unsigned**
`Capabilities` bitmask over a BLE GATT characteristic
(`ios-native/RAVEN/RAVEN/Core/Mesh/RUMProtocolV2.swift:155-218`; see
[`../docs/MESH_PROTOCOL.md`](../docs/MESH_PROTOCOL.md) §A) — anyone in radio
range, including an on-path relay, can observe or alter that read before a
peer sees it, and neither side can tell.

`RavenProtocolCapabilitiesV1` closes that gap: a peer's claimed capability set
is cryptographically bound to its identity via the Ed25519 signature. An
on-path relay or MITM position cannot flip a bit — say, stripping a
`pqHybridKEM` or `hopAuth`-equivalent bit from an unsigned advertisement to
force both sides into a weaker negotiated mode — without invalidating the
signature.

## 3. Downgrade protection

Because the record is both signed and time-bound (`expires_at_ms`), a
verifier caches the freshest signed capability set it has seen for a given
`identity_address` and refuses to silently accept a "downgrade" (fewer bits)
claim unless that claim is itself freshly signed and unexpired. An attacker
cannot replay an old, validly-signed, lower-capability record to force a
downgrade once its `expires_at_ms` has passed.

**Scope note:** unlike `RavenAliasRecordV1`, this record carries no explicit
monotonic `sequence` field — freshness relies on `expires_at_ms` alone. If a
verifier receives two differently-signed capability records for the same
identity with *overlapping* validity windows, V1 does not specify a
tie-breaking rule for that case (there is no sequence number to break the
tie). Implementers SHOULD handle it conservatively — negotiate to the
intersection of the two claimed bit sets — until a later protocol version
adds an explicit sequence field. This is a deliberate scope-out, not an
oversight: it is not backed by a vector because V1 does not define the
behavior.

## 4. Mapping to legacy RUM v2 capability bits — known platform drift

The legacy, unsigned `Capabilities` `OptionSet`/enum described in §2 is
maintained independently on each platform today, and has already drifted.
Bits 0 through 12 agree across all four current clients; bit 13 does not:

| Bit | Name | iOS/macOS | Windows | Android |
|---|---|---|---|---|
| `1<<13` | `doubleRatchet` | present — `ios-native/RAVEN/RAVEN/Core/Mesh/RUMProtocolV2.swift:217` (also `RAVEN-MacApp/RAVEN/Core/Mesh/RUMProtocolV2.swift:210`) | **absent** — enum ends at `RotatingPeerId = 1u << 12`, `RAVEN-Windows/src/Mesh/RumProtocolV2.cs:243` | **absent** — object ends at `ROTATING_PEER_ID = 1u shl 12`, `RAVEN-Android/legacy/mesh-protocol/RumProtocolV2.kt:247` |

The bit is not mis-numbered on Windows/Android — it is entirely unallocated
there, not merely unset. Consequence: a Windows or Android peer cannot
advertise or negotiate `doubleRatchet` support via the legacy RUM v2 handshake
at all. (Android does have its own `DoubleRatchet` implementation —
`RAVEN-Android/feature/e2ee/src/main/kotlin/.../DoubleRatchet.kt` — but it is
not wired into `RumProtocolV2.Capabilities` negotiation, so peers cannot
discover support for it through this mechanism.)

This is exactly the kind of drift `RavenProtocolCapabilitiesV1`'s single,
signed, platform-agnostic bit namespace is meant to prevent going forward: one
registry, referenced by every implementation, rather than four hand-copied
enums. V1 does not yet map every legacy RUM v2 bit onto
`RavenProtocolCapabilitiesV1.capability_bits` — reconciling the two namespaces
is Phase B/C scope, not part of this freeze.

## Reference implementation

Signing bytes are built inline in `protocol/reference/generate_rvn1.py` from
the shared `lp`/`u64` helpers in `protocol/reference/raven_protocol/_canon.py`
(no dedicated `capabilities.py` module exists yet — the record is simple
enough that the generator constructs it directly; a re-implementer should
still treat the signing-bytes formula in §1 as frozen). Vector:
`shared-vectors/rvn1/capabilities/alice_v1.json`.
