# RavenContactRequestV1 / ContactAcceptV1

**Version:** 1 (`rvn1`)  
**Status:** Discovery V1  
**Companions:** [`docs/RAVEN_DISCOVERY_V1.md`](../docs/RAVEN_DISCOVERY_V1.md), [`RAVEN_PREKEY_BUNDLE_V1.md`](RAVEN_PREKEY_BUNDLE_V1.md), [`RAVEN_BRIDGE_V1.md`](RAVEN_BRIDGE_V1.md)

## Contact request

Sensitive fields live **inside** sealed ciphertext (`rvn1/contact-req-inner`).  
Outer object carries `request_id`, recipient address, expiry, ciphertext, sender auth.

Delivery: pack as `RavenEnvelopeV1` message body → **MessageRouter**
(direct / relay / store / BLE / Bridge). Same `message_id`. Bridge MUST NOT decrypt.

## Contact accept

Signed `ContactAcceptV1` from accepter to requester after local UI Accept.

## Rules

- Store/bridge see ciphertext only.
- Multi-transport arrivals dedup once on `message_id`.
- Local block does not require a central moderation server.
- Contact binding is by Raven ID; alias changes do not rebind identity.

## Reference

`raven_core::contact_request::{RavenContactRequestV1, ContactAcceptV1}`
