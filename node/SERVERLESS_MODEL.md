# Raven Serverless Model V1

**Status:** Binding product definition for terminal + flagged mobile path  
**Branch:** `feature/raven-serverless-v1`  
**Start commit:** `18fa01e2a32ef014387ae2857ca272f34555cddd`

## Exact meaning of “serverless”

Raven **does not require** a Raven-operated central message server (FastAPI inbox, WebSocket fan-out, or cloud message DB) for 1:1 text delivery on the V1 envelope path.

### Three planes (do not collapse)

| Plane | Meaning |
|-------|---------|
| **Trust / friendship** | QR/OOB + fingerprint + signed prekey + local contacts. **Never** a central people directory. |
| **Delivery** | Store-carry-forward of opaque ciphertext (mesh / relay / Internet dial). |
| **Interop (Bridge)** | Untrusted cross-transport forward of the **same** `RavenEnvelopeV1` (DTN gateway sense — Fall), not a social introducer. |

See `docs/SERVERLESS_FRIEND_MESH_BRIDGE_DESIGN.md`. V1 mesh claim: **Spray-and-Wait bounds** (`replication_budget` / hop / TTL) — not BUBBLE/SimBet.

Allowed (non-trusted) helpers:

- User-run or community **relay / store / bridge / bootstrap** nodes that forward **opaque** `RavenEnvelopeV1` bytes only
- Manual peer dial, LAN, BLE, DHT discovery records (signed)
- Optional push/APNs for wake — **never** as the E2EE plaintext path

Forbidden as mandatory dependencies for ash↔ash or ash↔iOS (`FeatureFlag.ravenEnvelopeV1` ON):

- FastAPI message APIs
- Central user-directory as sole contact discovery
- Server-held conversation plaintext or conversation keys

## One envelope rule

> One Raven message → one canonical encrypted `RavenEnvelopeV1` → any available route (direct Internet, relay, encrypted store, LAN, BLE Bridge) without trusting a central Raven message server.

Bridge / relay / store **never decrypt**. Endpoint ATSAM / Noise / interim seal owns plaintext.

## Component map

| Component | Role |
|-----------|------|
| `raven-core` | Identity, address, envelope, seal/ATSAM KATs, MessageRouter, forward queue |
| `raven-node` | Always-on daemon: secure Noise/RLB1 LAN endpoint on `:7420`, same-user IPC, and a separate authenticated bridge-pull listener on configurable `:7422`; legacy raw InternetTransport remains fail-closed |
| `ash` / `raven` | Terminal UI + policy IPC client — closing ash must not stop the node |
| iOS (flag ON) | Parallel path: LAN + BLE RVN1 + ChatWire Delivered; MeshEnvelope default when flag OFF |

## Centralization inventory (baseline)

| Dependency | Role today | Serverless V1 |
|------------|------------|---------------|
| FastAPI `server/` | Legacy inbox / auth / prekey HTTP | **Not required** for flagged envelope path |
| WebSocket / RealtimeEngine | Online fan-out | Optional wake only |
| APNs | Push | Optional wake only |
| ATSAM online prekey HTTP | First contact | Prefer QR / offline bundle; HTTP optional |
| BLEMeshEngine MeshEnvelope | Default mobile mesh | Remains when flag OFF |
| `raven-node` TCP / bridge | Local serverless | **Required** for terminal path |

## Honest limitations (software)

- `ash send` currently dials the contact's secure LAN endpoint directly. The
  service publishes its separate bridge address in
  `<data-dir>/service-bridge.addr`, and explicit authenticated bridge-pull
  clients work, but automatic production A→B→C route selection/discovery is
  **not wired into `ash send`**. The A–B–C harness remains transport evidence,
  not a claim that the terminal command automatically finds a bridge.
- Full rust-libp2p DHT + DCUtR on real CGNAT: **experimental/held** — bounded client composition exists, but no production endpoint coordinator or relay server is wired; multi-NAT hardware proof is still BLOCKED.
- ML-KEM hybrid pairing in Rust: **known-root + X25519 subset**; full PQ stack remains iOS-primary until ported.
- Real GATT in headless `raven-node`: mock_ble for CI; iOS BLEMeshEngine for hardware.
- External crypto review + notarized signing: **BLOCKED_HUMAN**.
