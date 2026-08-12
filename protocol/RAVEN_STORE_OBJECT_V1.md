# RAVEN Store Object V1

**Version:** 1 (`rvn1`)  
**Status:** Binding for offline store-and-forward mailboxes  
**Companions:** [`RAVEN_ROUTING_TAG_V1.md`](RAVEN_ROUTING_TAG_V1.md), [`RAVEN_ENVELOPE_V1.md`](RAVEN_ENVELOPE_V1.md), [`RAVEN_BRIDGE_V1.md`](RAVEN_BRIDGE_V1.md)

## 1. Purpose

A store node holds **opaque** packed `RavenEnvelopeV1` bytes indexed only by rotating mailbox tags. It never receives content keys, usernames, or full Raven addresses as public mailbox names.

## 2. Mailbox tag (opaque, rotating)

Endpoints derive tags from shared route key material (same family as routing tags):

```
mailbox_tag = HMAC-SHA256(K_route, "rvn1/mailbox" || epoch_be8 || slot_be8)[:16]
```

Store-facing **rendezvous hint** (unlinkable from tag without K_route):

```
store_tag = SHA-256("raven/relay-tag/v1" || mailbox_tag)[:16]
```

| Rule | Requirement |
|------|-------------|
| Epoch | unix-day or explicit u64; rotate ≥ daily when online |
| Overlap | accept `epoch-1` and `epoch` during ±skew window |
| Stability | MUST NOT use permanent stable recipient tags |
| Public index | store indexes `store_tag` only — never usernames / `rvn1…` addresses |

## 3. Store object wire (custody record)

Magic `RSO1` (4 B). Layout:

```
magic(4) || version(1=0x01) || store_tag(16) || message_id(16)
  || created_at_ms_be8 || expires_at_ms_be8 || flags_u16_be
  || u32_be(envelope_len) || packed_raven_envelope || custody_sig(64)?
```

| Field | Meaning |
|-------|---------|
| `flags` bit0 | `custody_sig` present |
| `packed_raven_envelope` | exact `RavenEnvelopeV1` bytes (immutable ciphertext) |
| `custody_sig` | optional Ed25519 by storing node over `"rvn1/store-custody"‖object_without_sig` — proves custody, **not** content authenticity |

Max `envelope_len`: 1 MiB. Max objects per `store_tag`: implementation-defined ≤ 256. Max total store: operator policy.

## 4. Retrieval

Claimant presents `store_tag` (+ optional proof-of-knowledge of mailbox_tag via challenge). Store returns matching non-expired objects. Forged retrieval without tag knowledge MUST fail closed. After verified recipient ACK (opaque relay of ACK envelope), store MAY delete by `message_id`.

## 5. Replication / TTL

Replication factor ≤ 3 diverse store nodes. TTL from envelope `expires_at` and object `expires_at_ms` (earlier wins). Expired objects MUST be deleted. Disk exhaustion → refuse new puts with error `STORE_FULL` ([`RAVEN_ERROR_CODES_V1.md`](RAVEN_ERROR_CODES_V1.md)).

## 6. Privacy honesty

E2EE does **not** hide timing or volume. Store operators see sizes, arrival times, and `store_tag` reuse patterns.

## 7. Vectors / tests

| Id | Evidence |
|----|----------|
| Tag unlinkability | `shared-vectors/rvn1/store/mailbox_tag_001.json` |
| Rust | `raven_core::store_object` unit tests + forward_queue store-carry |
| Demo | `scripts/bridge_abc_demo.sh` store-carry path |

## 8. Bridge interaction

When egress is down, Bridge persists packed envelopes (forward queue). When a store role is enabled, objects MAY additionally be published under `store_tag` derived from the envelope `routing_tag` via `opaque_store_tag`.
