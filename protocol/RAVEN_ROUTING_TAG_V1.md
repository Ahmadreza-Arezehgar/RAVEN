# RAVEN Routing Tag V1

**Version:** 1 (`rvn1`)
**Status:** Frozen. See [`SPEC.md`](SPEC.md) for scope and versioning policy.
**Audience:** re-implementers of routing/relay logic and store nodes.

---

## 1. Derivation

`RavenRoutingTagV1` is the value carried in `RavenEnvelopeV1.routing_tag`
([`RAVEN_ENVELOPE_V1.md`](RAVEN_ENVELOPE_V1.md)), offset 24, 16 bytes. It is
what a relay or store node matches envelopes against — never an identity, an
address, or an alias.

```
tag = HMAC-SHA256(K_route, "rvn1/route" || epoch_be8 || counter_be8)[:16]
```

`epoch` and `counter` are each 8-byte big-endian integers. `K_route` is a
per-pair symmetric key derived from the ATSAM key tree (the "GhostRoute"
label — see `ios-native/RAVEN/RAVEN/Core/Security/GhostRoute/GRConstants.swift`
for the corresponding label constant in the shipping app, e.g.
`"ATSAM/v1/GhostRoute/recipient"`; the ATSAM/Noise session layer that produces
`K_route` is out of scope for this document, which only defines what happens
to it once derived).

The exact allocation of ATSAM directional route subkeys plus `epoch` and
`counter` is session-profile-specific. The additive, production-disabled
[`ATSAM_INDEXED_SESSION_PROFILE_V1.md`](ATSAM_INDEXED_SESSION_PROFILE_V1.md)
freezes one allocation without changing this HMAC primitive. Implementations
MUST NOT guess counters or reinterpret existing RVNA1 v2 sessions as that
profile.

**Vector:** `shared-vectors/rvn1/routing/tag_alice_bob_000.json` — fixed test
`K_route` (`00 01 02 … 1f`), `epoch=1700000000`, `counter=0` →
`tag_hex = 611432077911411fb5470eb80f1ff119`.

## 2. Rotation

`epoch` and `counter` together select a fresh 16-byte tag for every
`(epoch, counter)` pair sharing the same `K_route`. Two tags derived from the
same `K_route` at different counters are computationally unlinkable to anyone
without `K_route` — nothing about the byte values reveals they share an
origin.

**Vector:** `shared-vectors/rvn1/routing/tag_unlinkable_001.json` — same
`K_route` and `epoch`, `counter=1` → `tag_hex = 67c458fa19224559ee16946fba7c9155`,
structurally unrelated to the `counter=0` tag in §1 above.

## 3. Store-node-cannot-derive

A relay or store node only ever observes `routing_tag` byte values as they
pass through `RavenEnvelopeV1` frames. It never has `K_route` — that key lives
only in the two endpoints' ATSAM key trees. Consequently a store node can:

- index, store, and forward envelopes keyed by the tag values it sees, and
- recognize a tag it has seen before (byte equality),

but it can **never**:

- compute the *next* tag in a sequence,
- confirm that two different tag values belong to the same conversation, or
- map a tag back to an `identity_address` or alias.

This is what lets an offline-store relay do its job (hold envelopes for a tag
until claimed) without becoming a linkability point for who is talking to
whom.

## 4. Explicit non-goal: not traffic-analysis resistance

Routing tags resist **linkage at the tag-value layer** — an observer who sees
two envelopes cannot tell, from the tag bytes alone, that they're addressed to
the same recipient, without `K_route`. They do **not** resist **global traffic
analysis**. An adversary who can observe timing, volume, envelope size, and
network position across the whole system — not just tag bytes — can still
correlate flows through side channels unrelated to the tag: e.g. "an envelope
of size X leaves peer A one hop before an envelope of similar size arrives at
peer B."

`RavenRoutingTagV1` is a metadata-minimization mechanism for one specific
field. It is not a mixnet and does not claim traffic-analysis resistance.
Cover traffic, batching, or timing obfuscation (see the `coverTraffic`
capability bit referenced in [`RAVEN_CAPABILITIES_V1.md`](RAVEN_CAPABILITIES_V1.md))
are separate, orthogonal defenses this document does not define.

## Reference implementation

`protocol/reference/raven_protocol/routing_tag.py`. Vectors:
`shared-vectors/rvn1/routing/tag_alice_bob_000.json`,
`shared-vectors/rvn1/routing/tag_unlinkable_001.json`.
