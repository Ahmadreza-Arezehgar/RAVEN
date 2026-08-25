# ADR 0002 — Internet networking

**Status:** Experimental / production hold
**Date:** 2026-08-12

## Decision

1. **V1 laboratory path:** `InternetTransport` in `raven-core` / `raven-node` defines framing and an authenticated hello, but the default executable does not yet carry the indexed endpoint actor or sealed-ACK lifecycle. It is not a shipping message path and is not a relay server.
2. **Target path:** `rust-libp2p` QUIC + TCP + Noise, DHT for signed discovery, AutoNAT / relay / DCUtR where network conditions permit.

## Why not full libp2p in the first land

Compile/integration cost and incomplete CGNAT hardware matrix. A real non-localhost
endpoint path remains an acceptance requirement. Until indexed endpoint commit,
exact retry, and sealed ACK are wired end-to-end, gates must report an Internet
production hold rather than delivery.

`scripts/internet_dial_smoke.sh` is therefore a negative gate: it succeeds only
when the raw path refuses with the exact `ATSAM_SESSION_REQUIRED` diagnostic.

## Invariants

- Transport encryption/auth ≠ Raven E2EE
- Relays never decrypt sealed content
- Capability ads are generic (`ble`/`internet`/`relay`/`store`/`bridge`) — never contact graphs
