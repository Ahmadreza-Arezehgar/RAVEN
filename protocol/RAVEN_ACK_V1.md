# RAVEN Ack V1

**Version:** 1 (`rvn1`)
**Status:** Frozen. See [`SPEC.md`](SPEC.md) for scope and versioning policy.
**Audience:** re-implementers of delivery-state tracking on either the sending
or receiving side.

---

## 1. An ACK is a sealed `env_type=2` body

`RavenAckV1` is not a separate wire object with its own header — it is the
plaintext record that gets sealed (by the same ATSAM/Noise session sealer used
for message content) into `ratchet_header_ciphertext` +
`message_ciphertext` of an ordinary `RavenEnvelopeV1` with `env_type=2`
([`RAVEN_ENVELOPE_V1.md`](RAVEN_ENVELOPE_V1.md)).

Every rule in that document — the incoming-processing pipeline, the
mutable-field exclusion from the outer signature, dedup, replay, TTL — applies
identically to ACK envelopes. This document defines only what's specific to
the ACK payload itself.

## 2. Record and signing bytes

| Field | Type | Meaning |
|---|---|---|
| `acked_message_id` | 16 bytes | the `message_id` of the envelope being acknowledged |
| `status` | 1 byte | `1` = delivered, `2` = read |
| `ack_nonce` | 12 bytes | per-ack randomness, distinct from the outer envelope's `anti_replay_nonce` |
| `created_at` | u64 (8-byte BE) | unix ms |

**Signing bytes:**

```
"rvn1/ack" || acked_message_id(16) || status(1) || ack_nonce(12) || u64(created_at_ms)
```

This signature is **separate from and in addition to** the outer envelope's
`sender_authentication`. It is signed with the acknowledging device's Ed25519
device-identity key ([`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md)) — the same
key type that authenticates envelopes. The ack record itself carries no
embedded public-key field; a verifier resolves which key to check against via
the established session or the counterpart's known `RavenDeviceCertificateV1`,
not from anything inside the ack payload. Because the signature is over the
ack's own domain-separated bytes (not the envelope's), a verifier holding only
the counterpart's identity/device key material can confirm "the message was
received/read" independent of which transport or intermediary session carried
the envelope.

**Vector:** `shared-vectors/rvn1/ack/delivered_bob_to_alice.json` — bob
acknowledging alice's message (`status=1`, delivered).
**Wrong-signer vector:** `shared-vectors/rvn1/negative/ack_wrong_signer.json`
— the same signing bytes signed by alice's key but checked against bob's
public key; expected `verify_result: reject`.

`ack_nonce` is per-ack randomness for signature/domain separation — it exists
so two structurally identical acks don't produce identical signing bytes. It
is **not** a monotonic counter and MUST NOT be relied on as a replay-detection
mechanism on its own; see §4.

## 3. Delivery-state machine

```
CREATED → ENCRYPTED → QUEUED → ROUTE_DISCOVERING → FORWARDED → DELIVERED_TO_DEVICE → READ
                                                         ↓
                                                  EXPIRED / FAILED
```

| State | Meaning |
|---|---|
| `CREATED` | message object exists locally, not yet sealed |
| `ENCRYPTED` | sealed into `ratchet_header_ciphertext` + `message_ciphertext` |
| `QUEUED` | signed `RavenEnvelopeV1` built, handed to a transport-agnostic outbox |
| `ROUTE_DISCOVERING` | sender is resolving how to reach the recipient (DHT lookup, mesh peer discovery, relay selection) — the only state that is transport-specific |
| `FORWARDED` | the envelope has been handed to (or accepted by) at least one relay/transport — local transmission success, **not** recipient receipt |
| `DELIVERED_TO_DEVICE` | driven **only** by a verified `RavenAckV1` with `status=1` |
| `READ` | driven **only** by a verified `RavenAckV1` with `status=2` |
| `EXPIRED` | local `expires_at` reached (or a relay reported drop per the TTL stage, [`RAVEN_ENVELOPE_V1.md`](RAVEN_ENVELOPE_V1.md) §6) before `DELIVERED_TO_DEVICE` |
| `FAILED` | routes exhausted (`hop_limit`/`replication_budget` reached zero without reaching a relay) or an unrecoverable local error |

### The rule that matters most

**`FORWARDED → DELIVERED_TO_DEVICE` MUST be triggered only by successfully
authenticating and decrypting an inbound `env_type=2` envelope whose
`acked_message_id` matches and whose ack signature verifies against the
counterpart's known device key** (§2). Transport-level signals — "the stream
write succeeded," "a relay accepted the frame," "the bridge uplinked it" — MUST
NOT trigger this transition. They may only establish or hold `FORWARDED`.

> **Known issue — write-means-delivered, Phase B fix.**
> `ios-native/RAVEN/RAVEN/Core/Mesh/DeliveryJobRunner.swift:278-280` currently
> calls `DeliveryJobRepository.shared.markDelivered(messageId:channel:.bridge)`
> as soon as the libp2p stream write to the peer succeeds — i.e. on transport
> send success, not a verified ACK. The surrounding comment ("overall delivery
> state still tracked via ACK") shows this is intended as internal per-channel
> bookkeeping, not the protocol-level `DELIVERED_TO_DEVICE` transition — but
> the shared name `markDelivered` is a foot-gun: any future caller or UI
> surface that reads this per-channel flag as "message delivered" would
> violate the rule above. Phase B should rename this per-channel bookkeeping
> (e.g. `markTransmitted`) so `markDelivered`/`DELIVERED_TO_DEVICE` is reserved
> exclusively for a verified-ACK transition, and audit the same pattern on the
> `.mesh` and `.server` channels in the same file (around lines 363 and 556).

## 4. ACK replay and dedup

Because an ACK travels as an ordinary `env_type=2` envelope, envelope-level
dedup (keyed on the outer `message_id`) already prevents delivering the exact
same ack-envelope twice. That is not sufficient on its own: a recipient may
legitimately resend a semantically-identical ack (same `acked_message_id` +
`status`) inside a *fresh* envelope — with a new `message_id`, a new
`ack_nonce`, and a slightly different `created_at` — after, say, a
route-failure retry. Envelope dedup will not catch this, because it's a
different envelope.

Implementations MUST therefore also dedup at the application layer on
`(acked_message_id, status)`: a repeat `status=1` ack for a message already at
`DELIVERED_TO_DEVICE` is a no-op (idempotent), and a repeat `status=2` for a
message already at `READ` must not re-fire a "message read" notification.
`ack_nonce` uniqueness is not a substitute for this check — it exists for
signature domain separation (§2), not for idempotency tracking.

## Reference implementation

`protocol/reference/raven_protocol/ack.py`. Vectors:
`shared-vectors/rvn1/ack/delivered_bob_to_alice.json`,
`shared-vectors/rvn1/negative/ack_wrong_signer.json`.
