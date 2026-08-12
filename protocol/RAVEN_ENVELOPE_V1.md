# RAVEN Envelope V1

**Version:** 1 (`rvn1`)
**Status:** Frozen. See [`SPEC.md`](SPEC.md) for scope and versioning policy.
**Audience:** re-implementers of the wire codec and anyone writing a relay,
bridge, or transport adapter.

> This is the one wire object every transport carries unchanged — internet
> bridge, BLE mesh, or any future transport (invariants 5 and 6,
> [`SPEC.md`](SPEC.md)). A transport MUST NOT decrypt, reformat, or re-derive
> fields of this envelope; it forwards the bytes.

---

## 1. Byte layout

Big-endian throughout. Fixed 86-byte prefix, then three length-delimited
variable fields, in this exact order.

| Off | Size | Field | Notes |
|----|----|----|----|
| 0 | 4 | `magic` | ASCII `RVN1` = `0x52564E31` |
| 4 | 1 | `version` | `0x01` |
| 5 | 1 | `env_type` | 1=message, 2=ack, 3=alias-gossip, 4=capabilities |
| 6 | 2 | `flags` | bit0=hybridPQ, bit1=bleOriginated; rest reserved, MUST be 0 |
| 8 | 16 | `message_id` | 128-bit CSPRNG |
| 24 | 16 | `routing_tag` | `RavenRoutingTagV1` — recipient locator; rotates ([`RAVEN_ROUTING_TAG_V1.md`](RAVEN_ROUTING_TAG_V1.md)) |
| 40 | 8 | `dest_device_hint` | truncated hint or 0; **MUTABLE**, excluded from signature |
| 48 | 8 | `created_at` | unix ms |
| 56 | 8 | `expires_at` | unix ms |
| 64 | 1 | `hop_limit` | **MUTABLE**, excluded from signature |
| 65 | 1 | `replication_budget` | **MUTABLE**, excluded from signature |
| 66 | 12 | `anti_replay_nonce` | per-envelope |
| 78 | 2 | `hdr_len` | length of `ratchet_header_ciphertext` |
| 80 | 4 | `body_len` | length of `message_ciphertext` |
| 84 | 2 | `auth_len` | length of `sender_authentication` (Ed25519 sig = 64) |
| 86 | `hdr_len` | `ratchet_header_ciphertext` | opaque ATSAM/Noise header |
| … | `body_len` | `message_ciphertext` | opaque sealed frame (`RVNA1`/`RVNS1`/`RVNH1`) |
| … | `auth_len` | `sender_authentication` | Ed25519 signature over signing bytes |

86 bytes is the sum of the fixed-offset columns above (`4+1+1+2+16+16+8+8+8+1+1+12+2+4+2`).

**Vector:** `shared-vectors/rvn1/envelope/message_alice_to_bob.json` (`env_type=1`,
signed by alice's identity key; `packed_hex` is the full byte-for-byte wire
form).

## 2. Signing bytes — the mutable-field rule

Three fields are legitimately mutated in transit by relays: `dest_device_hint`
(a relay may refine or clear a delivery hint), `hop_limit` and
`replication_budget` (both decremented on each hop). Everything else in the
prefix, plus the ciphertext blobs, must be exactly what the sender wrote.

Canonical signing bytes are built by taking the fixed 86-byte prefix with the
three mutable fields **zeroed** and `auth_len` set to the canonical value `64`,
then appending `SHA-256(ratchet_header_ciphertext)` and
`SHA-256(message_ciphertext)`:

```
signing_bytes =
    prefix_with(dest_device_hint=0, hop_limit=0, replication_budget=0, auth_len=64)
    || SHA-256(ratchet_header_ciphertext)
    || SHA-256(message_ciphertext)
```

150 bytes total (86 + 32 + 32). `sender_authentication` is the Ed25519
signature over exactly this value.

This binds everything immutable — including the *lengths* and *content* of
both ciphertext blobs, via their hashes — and binds nothing a relay is allowed
to touch. This closes a class of flaw where a naive "sign the whole prefix"
scheme would either (a) force relays to re-sign on every hop-count decrement
(defeating end-to-end authentication), or (b) leave `hop_limit`/
`replication_budget`/`dest_device_hint` unauthenticated as a side effect of
being excluded, without that exclusion being an explicit, audited design
decision. Here it is explicit and by design: those three fields are *never*
part of what a signature promises, on purpose.

**Vector:** `shared-vectors/rvn1/envelope/message_alice_to_bob.json` carries
both `signing_bytes_hex` and `packed_hex` so an implementation can verify it
computes the same 150-byte signing input and the same signature.
**Tamper vector:** `shared-vectors/rvn1/negative/envelope_tampered_body.json`
— the same envelope with `message_ciphertext` altered *after* signing;
expected `verify_result: reject`, because the appended
`SHA-256(message_ciphertext)` no longer matches what was signed.

## 3. `env_type` registry

| Value | Meaning | Spec |
|---|---|---|
| 1 | message | this document (body only — content format is the ATSAM/Noise sealed frame, out of scope here) |
| 2 | ack | [`RAVEN_ACK_V1.md`](RAVEN_ACK_V1.md) |
| 3 | alias-gossip | [`RAVEN_ALIAS_V1.md`](RAVEN_ALIAS_V1.md) |
| 4 | capabilities | [`RAVEN_CAPABILITIES_V1.md`](RAVEN_CAPABILITIES_V1.md) |

`env_type` values above 4 are reserved. A receiver seeing an unrecognized
`env_type` under the currently-supported `version` should drop the envelope
(it cannot safely interpret `message_ciphertext`'s inner structure); this is
distinct from an unsupported `version`, which is a hard drop per
[`SPEC.md`](SPEC.md)'s versioning policy.

## 4. Size limits and known transport-level issue

The field widths alone bound `hdr_len` to 65,535 bytes and `body_len` to
4,294,967,295 bytes (4 GiB) — `auth_len` is a 2-byte field but MUST equal 64
for any `env_type` that requires an Ed25519 `sender_authentication`, per the
canonical signing-bytes rule in §2. No implementation should treat the field
widths as the real limit.

**Recommended practical ceiling:** implementations SHOULD enforce a hard total
envelope-size limit well below the field-width theoretical maximum. The
current internet-bridge transport already does this at the transport layer:
`ios-native/RAVEN/Libp2pBridge/bridge.go:47` sets
`maxEnvelopeBytes = 24 * 1024 * 1024` (24 MiB), sized to fit a serverless
media message (inline-embedded AES-encrypted attachment bytes, capped at
10 MB raw) plus envelope overhead.

> **Known issue — DoS to close in Phase B.** The 24 MiB check in
> `bridge.go` (`ios-native/RAVEN/Libp2pBridge/bridge.go:242-245`) compares the
> attacker-supplied length prefix against the 24 MiB ceiling, then
> **immediately allocates a buffer of the full claimed length**
> (`env := make([]byte, envLen)`) *before* running any of the size → decode →
> version → structure checks in §5 below. A hostile peer can open many
> concurrent libp2p streams, each declaring a length near 24 MiB, forcing
> large allocations ahead of any envelope validation — a memory-exhaustion
> vector distinct from (and not fixed by) the per-frame ceiling itself. Phase
> B should validate structure incrementally (e.g. read and check the 86-byte
> prefix before allocating room for the variable-length fields) or cap total
> concurrent unvalidated allocation per remote peer, not just per-frame size.

## 5. "No plaintext identities on the wire"

None of the fixed-prefix fields, and neither of the two opaque
length-delimited blobs, carry a username, `userId`, alias, or
conversation/room identifier in the clear:

- `message_id` is random 128-bit CSPRNG output with no semantic meaning
  outside the sender/recipient's own local session state.
- `routing_tag` is a rotating HMAC output
  ([`RAVEN_ROUTING_TAG_V1.md`](RAVEN_ROUTING_TAG_V1.md)) that a relay cannot
  invert to any identity without holding the sender/recipient pair's
  `K_route`.
- `dest_device_hint` is explicitly a *hint*: it is mutable, excluded from the
  signature (§2), and MUST be treated by any receiver as unauthenticated —
  never as a verified recipient identity. Implementations MUST NOT put
  anything more identifying than a small opaque hint value in it.
- Everything with actual semantic content (message text, alias claims, ACK
  status, capability bits) lives inside `ratchet_header_ciphertext` /
  `message_ciphertext`, which are opaque to any party without the session key.

## 6. Incoming-processing pipeline

Implementations MUST apply these checks in this order. Each stage either
drops/rejects and stops, or passes the envelope to the next stage.

1. **size** — reject the raw frame if it exceeds the transport's configured
   maximum before attempting to parse anything (§4).
2. **decode** — parse the fixed 86-byte prefix; total byte length must equal
   `86 + hdr_len + body_len + auth_len` exactly, or the envelope is malformed.
   **Vector:** `shared-vectors/rvn1/negative/envelope_bad_magic.json` — the
   `magic` byte zeroed; expected `unpack_result: reject`.
3. **version** — the `version` byte must equal the version this
   implementation supports. Higher → drop per [`SPEC.md`](SPEC.md); this
   implementation treats it as a decode failure, but conceptually it is its
   own forward-compatibility gate, not "malformed."
4. **structure** — `env_type` is in the registry (§3), reserved `flags` bits
   are zero, and the declared lengths are internally consistent (already
   enforced by decode's total-length check, but revalidated here against
   `env_type`-specific expectations, e.g. `auth_len == 64`).
5. **dedup** — `message_id` checked against a bounded recently-seen set;
   a duplicate is dropped silently, no error surfaced.
6. **replay** — `anti_replay_nonce` checked against a per-sender/per-tag
   replay window. This is distinct from dedup: dedup is keyed on the envelope
   identity (`message_id`); replay defends against a captured-and-resent
   ciphertext even if an attacker altered `message_id`.
7. **TTL** — `expires_at` compared against the local validation clock; past
   expiry, the envelope is dropped by relays before further processing.
   **Vector:** `shared-vectors/rvn1/negative/envelope_expired.json` —
   `expires_at_ms` one second before `validation_clock_ms`; expected
   `relay_action: drop`.
8. **hop/replication** — for relays only: `hop_limit` and
   `replication_budget` must both be greater than zero before re-broadcasting;
   both are decremented before the envelope is forwarded onward.
9. **tag/session** — `routing_tag` is matched against locally-known sessions
   ([`RAVEN_ROUTING_TAG_V1.md`](RAVEN_ROUTING_TAG_V1.md)); if no local session
   recognizes the tag, the envelope is "not for me" and is relayed or dropped
   per the node's role, not authenticated or decrypted locally.
10. **authenticate** — verify `sender_authentication` against `signing_bytes`
    (§2) using the sender's device Ed25519 key, resolved via a known session
    or `RavenDeviceCertificateV1` ([`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md)).
    **Vector:** `shared-vectors/rvn1/negative/envelope_tampered_body.json` —
    tampering after signing fails exactly here.
11. **decrypt** — only after authentication succeeds, hand
    `ratchet_header_ciphertext` and `message_ciphertext` to the session
    sealer to recover plaintext.
12. **commit** — persist the decrypted content locally. This is the point at
    which the message becomes visible to the application/user.
13. **ACK** — emit a `RavenAckV1` (`env_type=2`) back to the sender per
    [`RAVEN_ACK_V1.md`](RAVEN_ACK_V1.md).

## 7. Binding sealed content frames (`RVNA1` / `RVNS1` / `RVNH1`)

This section binds existing sealed-content magics into `message_ciphertext`
**without changing** the 86-byte prefix or signing-bytes rule above.

| Layer | Magic | Where it lives |
|---|---|---|
| Outer transport object | `RVN1` (4 bytes) | Envelope offset 0 |
| ATSAM sealed body | `RVNA1\0\0\0` (8 bytes) | Start of `message_ciphertext` |
| Noise sealed body | `RVNS1\0\0\0` (8 bytes) | Start of `message_ciphertext` |
| Noise handshake | `RVNH1\0\0\0` (8 bytes) | Start of `message_ciphertext` |

Normative rules:

1. For `env_type = 1`, production `message_ciphertext` is an opaque sealed
   content frame (raw bytes on this binary wire — **not** base64). Base64 is
   a legacy MeshEnvelope/JSON encoding detail only.
2. `ratchet_header_ciphertext` is opaque to relays; length may be zero when
   the sealer encodes session state inside the body (e.g. RVNA1 v2 index).
3. Relays MUST NOT inspect or rewrite bytes inside either ciphertext field.
4. Codec test fixtures MAY use non-decryptable placeholder bodies to lock
   pack/sign layout (`shared-vectors/rvn1/envelope/message_alice_to_bob.json`
   does exactly that). Those placeholders are **not** ATSAM KATs.
5. Full primitive → threat → vector → implementation mapping:
   [`ATSAM_PRIMITIVE_MAPPING_V1.md`](ATSAM_PRIMITIVE_MAPPING_V1.md).

Mesh JSON (`MeshEnvelope`) remains the shipping BLE/app carrier until Phase G;
the target object for internet + eventual BLE is this `RavenEnvelopeV1`.

## Reference implementation

`protocol/reference/raven_protocol/envelope.py`. Vectors:
`shared-vectors/rvn1/envelope/message_alice_to_bob.json`,
`shared-vectors/rvn1/negative/envelope_bad_magic.json`,
`shared-vectors/rvn1/negative/envelope_tampered_body.json`,
`shared-vectors/rvn1/negative/envelope_expired.json`.
