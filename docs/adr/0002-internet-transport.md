# ADR 0002 — Internet networking

**Status:** Accepted (phased)  
**Date:** 2026-08-12

## Decision

1. **V1 shipping path:** `InternetTransport` in `raven-core` / `raven-node` — length-prefixed `RavenEnvelopeV1` over TCP with Ed25519 peer auth handshake, capability advertisement, and a dialable relay forwarder (opaque bytes only).
2. **Target path:** `rust-libp2p` QUIC + TCP + Noise, DHT for signed discovery, AutoNAT / relay / DCUtR where network conditions permit.

## Why not full libp2p in the first land

Compile/integration cost and incomplete CGNAT hardware matrix. A **real dial path** (non-localhost peers, opaque forward) unblocks Phase D proofs without faking path selection.

## Invariants

- Transport encryption/auth ≠ Raven E2EE
- Relays never decrypt sealed content
- Capability ads are generic (`ble`/`internet`/`relay`/`store`/`bridge`) — never contact graphs
