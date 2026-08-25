# RAVEN Bridge V1 (protocol)

**Version:** 1  
**Status:** Binding for opaque cross-transport forward  
**Companion:** `node/BRIDGE_V1.md` (operator/demo), `docs/SERVERLESS_MODEL.md`

## Definition

A Raven Bridge is an **untrusted** cross-transport forwarding function inside Raven Node that receives the same opaque end-to-end encrypted `RavenEnvelopeV1` on one transport and forwards or stores it for another transport **without** decrypting, re-originating, or changing the logical `message_id`.

## Invariants

1. Same `message_id` across transports.
2. Same `message_ciphertext` + `sender_authentication` bytes (immutable).
3. Only mutable hop fields may change: `hop_limit`, `replication_budget`, `dest_device_hint`.
4. Bridge MUST NOT access conversation keys / ATSAM roots / Noise sessions.
5. Recipient ACK (`env_type=ack`) is emitted only by the true endpoint; Bridge may **relay** ACK bytes opaquely.
6. Dedup, TTL (`expires_at`), hop, replication, and per-peer rate limits apply.
7. Capability advertisement is generic (`bridge`/`ble`/`internet`/`store`/`relay`) — never contact graphs.

## Roles

| Role | Decrypt? | Emit Delivered ACK? |
|------|----------|---------------------|
| Endpoint | Yes (if capable) | Yes (recipient only) |
| Bridge / Relay / Store | No | No (may forward opaque ACK) |

Multi-role devices: BridgeSubsystem and endpoint ingest MUST be separated (iOS: `RavenEnvelopeBridgeService` vs `RavenEnvelopeChatWire`).

## Transports

- LAN / Internet: `u32 BE || RavenEnvelopeV1` — see [`RAVEN_TRANSPORT_INTERFACE_V1.md`](RAVEN_TRANSPORT_INTERFACE_V1.md)
- mock_ble (CI): same framing over TCP
- BLE GATT (iOS): `RavenBleRvn1Carrier` behind `FeatureFlag.ravenEnvelopeV1` — see [`RAVEN_BLE_FRAMING_V1.md`](RAVEN_BLE_FRAMING_V1.md)

## Store-Carry-Bridge

When egress radio is down, persist packed envelope to forward queue; flush when path returns. SQLite expires timestamps MUST clamp to `i64::MAX` (signed INTEGER). Opaque mailbox / store objects: [`RAVEN_STORE_OBJECT_V1.md`](RAVEN_STORE_OBJECT_V1.md). Delivery vs custody: [`RAVEN_DELIVERY_STATE_V1.md`](RAVEN_DELIVERY_STATE_V1.md).

## Errors

Mapped codes: [`RAVEN_ERROR_CODES_V1.md`](RAVEN_ERROR_CODES_V1.md) (`ENVELOPE_*`, `STORE_*`, `RATE_LIMITED`, …).

## Tests

- `raven-core` `bridge_v1` cases 1–10+
- `scripts/bridge_abc_demo.sh` A–B–C + store-carry
- iOS `RavenEnvelopeBridgeServiceTests` (simulator; no physical radios required for decision tests)
- Interop: [`RAVEN_INTEROPERABILITY_MATRIX.md`](RAVEN_INTEROPERABILITY_MATRIX.md)
