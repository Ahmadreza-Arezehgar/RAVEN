# RAVEN Delivery State V1

**Version:** 1 (`rvn1`)  
**Status:** Binding (aligns ACK machine + local queues)  
**Companions:** [`RAVEN_ACK_V1.md`](RAVEN_ACK_V1.md), [`RAVEN_ENVELOPE_V1.md`](RAVEN_ENVELOPE_V1.md)

## 1. Logical sender-side machine

```
CREATED → ENCRYPTED → QUEUED → ROUTE_DISCOVERING → FORWARDED
                                              ↓
                                    DELIVERED_TO_DEVICE → READ
                                              ↓
                                       EXPIRED / FAILED
```

| State | Wire / local trigger |
|-------|----------------------|
| CREATED | local object exists |
| ENCRYPTED | sealed content present |
| QUEUED | signed envelope in outbox (`DeliveryState::Queued`) |
| ROUTE_DISCOVERING | resolving path / DHT / dial |
| FORWARDED | handed to ≥1 transport (`Sent` / forward_queue `Forwarded`) — **not** recipient receipt |
| DELIVERED_TO_DEVICE | **only** verified ACK status=1 |
| READ | **only** verified ACK status=2 |
| EXPIRED | TTL before delivered |
| FAILED | routes exhausted / unrecoverable |

## 2. Local persistence mapping (`raven-core`)

| Queue enum | Logical |
|------------|---------|
| `DeliveryState::Queued` | QUEUED |
| `DeliveryState::Sent` | FORWARDED |
| `DeliveryState::Delivered` | DELIVERED_TO_DEVICE |
| `DeliveryState::Failed` | FAILED |

Bridge forward queue uses `ForwardState` for custody only — must not alone advance to DELIVERED_TO_DEVICE.

## 3. Non-goals

Transport TCP ACK, BLE write success, or bridge enqueue MUST NOT mark delivered. Relays MUST NOT emit recipient ACKs.

## 4. Tests

`reliability` restart mid-queue; `bridge_v1` ACK reverse relay; ACK vectors under `shared-vectors/rvn1/ack/`.
