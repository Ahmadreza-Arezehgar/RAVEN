# RavenContactRequestV1 / ContactAcceptV1

**Version:** 1 (`rvn1`)
**Status:** Codec frozen; product transport on security hold

**Companions:** [`docs/RAVEN_DISCOVERY_V1.md`](../docs/RAVEN_DISCOVERY_V1.md), [`RAVEN_PREKEY_BUNDLE_V1.md`](RAVEN_PREKEY_BUNDLE_V1.md), [`RAVEN_BRIDGE_V1.md`](RAVEN_BRIDGE_V1.md), [`RAVEN_PRIVATE_INTRODUCTION_V1.md`](RAVEN_PRIVATE_INTRODUCTION_V1.md)

> This V1 wire is session-root contact messaging, not first-contact bootstrap.
> The production-disabled Private Introduction companion defines the separate
> Raven-ID-to-inert-proposal architecture. It does not reinterpret this codec,
> reuse its keys, or open the held rootless APIs.

## Contact request

Sensitive fields live **inside** sealed ciphertext (`rvn1/contact-req-inner`).
Outer wire (`rvn1/contact-req-wire`) carries `request_id`, recipient address, expiry, ciphertext, sender auth + pub.

The ciphertext MUST be RVNA1 v2 under an authenticated ATSAM session root and
a crash-safely reserved chain index. Ed25519 public keys are never encryption
secrets. The rootless `create` / `open` compatibility APIs fail with
`CONTACT_REQ_SESSION_REQUIRED` in every build, including Debug and explicit
lab-feature builds.

Future delivery: pack **outer wire** as `RavenEnvelopeV1` message body only
after the durable indexed-session actor reserves the key/index and private
routing material. Bridge MUST NOT decrypt / `open`. The current ash and iOS UI
paths are deliberately held rather than synthesizing an incomplete session.

## Contact accept

Signed `ContactAcceptV1` from accepter to requester after local UI Accept.
Wire magic: `rvn1/contact-accept-wire`. A signature authenticates but does not
hide its Raven IDs, so the accept wire MUST be carried inside an authenticated
ATSAM-sealed body. Current product emission is held until that carrier exists.

Accept also binds a **local** contact: `raven_id` + petname, verification `TRUSTED_CONTACT`.
Decline drops pending. Block drops pending and adds sender pub to the local block list.

## Rules

- Store/bridge see ciphertext only (inner plaintext never on wire).
- Multi-transport arrivals dedup the authenticated object digest; `request_id`
  remains the inbox-level idempotency key after successful decryption.
- Decrypted sender ID and timestamps MUST equal their authenticated outer
  counterparts before an inbox row or contact binding is created.
- Local block does not require a central moderation server.
- Contact binding is by Raven ID; alias changes do not rebind identity.

## Reference

`raven_core::contact_request::{RavenContactRequestV1, ContactAcceptV1, ContactRequestInbox}`
