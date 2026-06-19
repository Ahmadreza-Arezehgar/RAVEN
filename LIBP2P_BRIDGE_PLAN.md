# Serverless Internet Bridge — libp2p Implementation Plan

**Status:** Phase B of the messenger pivot. Phase A (serverless key-based identity)
is done; local BLE mesh relay is already serverless. This plan covers the **internet
bridge** — letting two devices that are both online but not in BLE range exchange
messages with **no central server**.

## What the bridge replaces

Today the bridge uses the server as the rendezvous:
- **Upload** (offline-neighbour → internet): `MeshGatewayService.handleOutboundFromNeighbour`
  → `POST /api/mesh/bridge-envelope { envelope_b64, idempotency_key }` (server stores 24h,
  fans out over WS, serves to reconnecting clients).
- **Drain** (internet → offline-neighbour): `MeshBridgeReceiver.drainPendingBridges`
  → `GET /api/mesh/pending-bridges?since=<iso>` → `[PendingBridgeEnvelope]` → `ingest(...)`.

The envelope is already an **opaque, E2E-encrypted blob** (the server never decrypts).
That zero-knowledge property must be preserved by any replacement.

## Why libp2p, and the iOS reality

libp2p gives serverless peer discovery (Kademlia DHT), NAT traversal (Circuit Relay v2 +
DCUtR hole-punching), and authenticated/encrypted transport (Noise) — without a server we run.

**There is no production-ready native Swift libp2p.** The proven path (used by **Berty**, a
real serverless P2P messenger, on iOS) is:

> **go-libp2p** compiled to a static `.xcframework` via **`gomobile bind`**, with a thin
> Swift wrapper. (rust-libp2p + a C-FFI/UniFFI binding is the alternative.)

This is a **heavy native dependency** (~10–30 MB binary) and a real build/CI step. The Go
toolchain + gomobile are **not** installed in the current dev environment — setting them up
is the first prerequisite.

## Identity mapping (elegant: reuse the device key)

libp2p host identities ARE Ed25519 keypairs, and RAVEN's `DeviceIdentityService` already
generates an Ed25519 keypair on first launch. So:

- Feed RAVEN's **existing Ed25519 private key** into the go-libp2p host as its identity.
- The libp2p **PeerID** is then deterministically derived from RAVEN's device public key.
- Maintain a 1:1 map **RAVEN fingerprint ⇄ libp2p PeerID** (both derive from the same pubkey).
- QR pairing already carries the Ed25519 identity key inline — so a scanned contact's PeerID
  is computable locally, **no directory lookup needed**.

This means contacts added by QR/proximity can be dialed over libp2p with zero server.

## Architecture — where it slots in

Introduce a `BridgeTransport` seam (see `MeshProtocols.swift`) with two ops mirroring the
server bridge: `uploadEnvelope(_:idempotencyKey:recipientHint:)` and
`drainPending(since:) -> [BridgeEnvelopeItem]`, plus `isConnected`. Implementations:

1. `ServerBridgeTransport` — wraps today's `/api/mesh/*` calls (legacy; server is off).
2. `LibP2PBridgeTransport` — calls into the gomobile xcframework. **This is the target.**

`MeshGatewayService` (upload) and `MeshBridgeReceiver` (drain) route through
`BridgeTransport.current` instead of `NetworkService` directly.

### Online → online (the part libp2p fully solves, truly $0)
- Both peers run a libp2p host. Discover the recipient via the **DHT** (`FindPeer(peerID)`)
  or a **rendezvous** namespace; dial directly, or via **Circuit Relay v2** when NAT-blocked,
  then **DCUtR** hole-punch to upgrade to a direct connection.
- Send the opaque envelope over a RAVEN protocol stream (`/raven/bridge/1.0.0`).
- Zero server. This is genuinely serverless.

### Online → OFFLINE recipient (the honest hard part)
libp2p relays forward **live** traffic; they do **not store** for an offline peer. To match
the server's 24h store-and-forward you need an **always-on holder**. Options, in order of
honesty:
- **Community/self-run "mailbox" relay nodes** — always-on libp2p peers that accept and hold
  envelopes addressed to an offline PeerID until it reconnects (a thin pinning service over
  the same DHT). Decentralised, but **not zero-infrastructure** (someone runs them; they can
  be cheap/community/self-hosted, and anyone can run one).
- **Friend-device mailboxing** — a contact's online device holds envelopes for an offline
  peer (mirrors today's bridge-wake fan-out to 3 friends). Serverless but best-effort.
- **Degrade to BLE-only** for offline recipients — no internet store-and-forward; the message
  waits for physical proximity. Pure, but limited.

**Conclusion:** libp2p makes *both-online* delivery truly serverless; *offline* delivery still
needs an always-on holder (mailbox node) — that is a fundamental distributed-systems
constraint, not a libp2p limitation. Recommended: ship online↔online first; add community/
self-run mailbox nodes as the decentralised store-and-forward layer.

### Push wake-up (unchanged constraint)
iOS still cannot reliably receive in the background without APNs (a sender). Pure-serverless
means "open the app to receive over libp2p," or a tiny push-relay. Out of scope for the
bridge transport itself.

## Bootstrap & relay nodes
- **DHT bootstrap:** hardcode a small list of community-run libp2p bootstrap multiaddrs (and/or
  run our own cheap ones) so a fresh client can enter the DHT. Ship them in remote-config so
  they can be updated without an app update.
- **Relay reservations:** NAT'd clients reserve a slot on public Circuit Relay v2 relays.

## Build pipeline (the native chunk)
1. Install Go + `gomobile` (`go install golang.org/x/mobile/cmd/gomobile@latest; gomobile init`).
2. New Go module `bridge/` with go-libp2p: host (Ed25519 identity injected from Swift), DHT
   (`dht.New`, bootstrap), Circuit Relay v2 client, Noise, a `/raven/bridge/1.0.0` stream
   handler, and an inbox queue. Export a small gomobile-friendly API:
   `Start(privKey []byte, bootstrap []string)`, `Send(peerID, envelopeB64, idemKey)`,
   `Drain() []Item`, `OnEnvelope(callback)`, `PeerID() string`, `Stop()`.
   (gomobile only exports a restricted type set — keep the API to strings/[]byte/ints +
   a callback interface.)
3. `gomobile bind -target=ios -o RavenLibp2p.xcframework ./bridge` → add to the Xcode project.
4. `LibP2PBridgeTransport` (Swift) wraps the xcframework, injects
   `DeviceIdentityService` private key, conforms to `BridgeTransport`, bridges the callback to
   `MeshBridgeReceiver.ingest(...)`.

## Milestones
1. **Swift seam** — `BridgeTransport` protocol + `ServerBridgeTransport` + `LibP2PBridgeTransport`
   stub; route `MeshGatewayService`/`MeshBridgeReceiver` through it. *(compiles; no behaviour
   change yet — this commit)*
2. **Go libp2p node** — host + DHT + relay + stream handler; `gomobile bind` → xcframework.
3. **Identity wiring** — inject RAVEN Ed25519 key; verify fingerprint ⇄ PeerID; dial a
   QR-scanned contact.
4. **Online↔online delivery** — send/receive an envelope between two online devices, no server.
5. **Offline store-and-forward** — community/self-run mailbox node holds for offline peers.
6. **Bootstrap/relay hardening + remote-config of node lists.**

## Risks
- gomobile binary size + iOS background execution limits (libp2p connections suspend in
  background — same APNs-wake constraint).
- DHT churn / discovery latency on mobile; relay availability.
- Maintaining a Go dependency in an otherwise Swift codebase (build/CI complexity).
- Offline delivery is **not** zero-infrastructure (mailbox nodes).
