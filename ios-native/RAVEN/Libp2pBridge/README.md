# RavenLibp2p — serverless internet bridge (go-libp2p → iOS)

The serverless replacement for the server bridge (`/api/mesh/bridge-envelope` +
`/pending-bridges`). A go-libp2p host, compiled to an iOS xcframework via
`gomobile bind`, that carries the opaque E2E-encrypted RAVEN envelope between two
online devices over the libp2p network (DHT discovery + Circuit Relay v2 +
DCUtR hole-punching) — no server. See ../../../LIBP2P_BRIDGE_PLAN.md.

## Build

```sh
./build-xcframework.sh        # → RavenLibp2p.xcframework (device + simulator)
```

Status: **builds clean** against go-libp2p v0.48 (188 MB xcframework, ios-arm64 +
ios-arm64_x86_64-simulator). The binary is gitignored — rebuild from source.

## Generated Swift API (module `RavenLibp2p`)

```swift
import RavenLibp2p

// Delegate (implement on the Swift side; callbacks arrive on a background thread):
//   RavenbridgeDelegate.onEnvelope(_:idempotencyKey:)   // inbound opaque envelope
//   RavenbridgeDelegate.onStatus(_:peerID:)             // connectivity + our PeerID

let node = RavenbridgeNewNode(ed25519KeyData, delegate)   // throws
try node.start(bootstrapCSV)                               // DHT + relay
try node.send(peerIDStr, envelopeB64: ..., idempotencyKey: ...)
let myPeerID = node.peerID()
try node.stop()
```

## Xcode integration (one-time)

1. Run `./build-xcframework.sh`.
2. Drag `RavenLibp2p.xcframework` into the RAVEN target → **Embed & Sign**
   (it is a dynamic framework). Adding it via the Xcode UI is strongly preferred
   over hand-editing `project.pbxproj` (binary-framework refs + the Embed
   build phase are error-prone by hand).
3. `LibP2PBridgeTransport` (in `RAVEN/Core/Mesh/MeshProtocols.swift`) is guarded
   by `#if canImport(RavenLibp2p)` — its real implementation activates once the
   framework is linked; until then it is a no-op stub so the app still builds.

## Identity

The libp2p host identity is RAVEN's **own Ed25519 device key**
(`DeviceIdentityService`). The libp2p PeerID therefore derives from the same
public key as the device fingerprint, so a QR-scanned contact's PeerID is
computable locally with no directory. `NewNode` accepts the 32-byte CryptoKit
seed or the 64-byte std key.

## Bootstrap nodes

`start(bootstrapCSV)` takes comma-separated multiaddrs of libp2p bootstrap peers
for DHT entry. Ship these via remote-config so they can be updated without an app
update. (Run a couple of cheap/community bootstrap+relay nodes, or reuse public
IPFS bootstrap peers for the DHT.)

## Honest limitation

libp2p makes **both-online** delivery serverless. **Offline** store-and-forward
still needs an always-on **mailbox node** (community/self-run) — not
zero-infrastructure. See the plan doc.
