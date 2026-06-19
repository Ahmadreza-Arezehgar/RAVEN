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

## Xcode integration (one-time) — already wired

This is **done** in `RAVEN.xcodeproj` (committed). Recorded here for the next
person / a clean re-add. `gomobile bind` emits a **static** framework (the
binary is an `ar` archive, not a dylib), so the steps differ from a dynamic one:

1. Run `./build-xcframework.sh` (needs `go` + `gomobile`). Output:
   `RavenLibp2p.xcframework` (device `ios-arm64` + `ios-arm64_x86_64-simulator`).
   The built framework is **git-ignored** (≈200 MB) — rebuild it on a fresh
   checkout before the first device/sim build.
2. Add it to the RAVEN target's **Link Binary With Libraries** phase only —
   i.e. **Do Not Embed**. (It is static; embedding a static framework is wrong
   and Apple rejects it.) `FRAMEWORK_SEARCH_PATHS` must include
   `$(PROJECT_DIR)/Libp2pBridge`.
3. Add **`-lresolv`** to `OTHER_LDFLAGS`. Go's `net`/DNS resolver (pulled in by
   go-libp2p) references `res_9_ninit`/`res_9_nclose`/`res_9_nsearch` from
   `libresolv`; without it the link fails with "Undefined symbols".
4. `LibP2PBridgeTransport` (in `RAVEN/Core/Mesh/MeshProtocols.swift`) is guarded
   by `#if canImport(RavenLibp2p)` — the real implementation activates once the
   framework is linked; otherwise it is a no-op stub so the app still builds.

> gomobile naming note (verified at integration): the Swift-facing delegate
> protocol is **`RavenbridgeDelegateProtocol`** (the class `RavenbridgeDelegate`
> is the gomobile proxy, not the protocol), its callbacks must be `@objc`, and
> the free function `RavenbridgeNewNode(seed, delegate, &error)` takes an
> `NSError` out-param (it is *not* a throwing call — only the instance methods
> `start`/`send` import as `throws`).

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
