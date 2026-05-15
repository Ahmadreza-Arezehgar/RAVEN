# MeshV1 — `MESH_PROTOCOL.md` v1 reference implementation for iOS

Wire-level RAVEN mesh stack: envelopes, canonical signing, chunking, dedup, spray-and-wait routing, pairing code, fingerprint. Mirrors the Kotlin port at `RAVEN-Android/modules/mesh/`.

The Android port already shipped against `shared-vectors/v1/`. This package brings iOS to the same level, validated against the **same fixtures**, so cross-platform interop becomes a unit-test problem rather than a real-device debugging marathon.

## What's in / out

In:

- `MeshConstants` — service UUID, char UUIDs, chunking constants, spray defaults, TTL, hop limits, dedup retention, rate limit.
- `MeshEnvelopes` — `SecureMeshEnvelope`, `SignedMeshPayload`, `EncryptedMeshPayload`, `MeshPostEnvelope`, `MeshACKEnvelope`, `StopCommand`, `MeshMessageFrame`, `GeoFence` — all with the short JSON keys iOS shipped.
- `MeshCanonicalizers` — `DmSigningCanonicalizer`, `PostSigningCanonicalizer`, `AckSigningCanonicalizer`, `StopSigningCanonicalizer`, `FrameJsonCanonicalizer` — the 5 signing rules from §D.
- `MeshChunking` — encode (single + multi), `ChunkReassembler`, CRC32 message-hash derivation.
- `MeshDedupKeys` — exact prefix-keyed strings per §E.
- `MeshSprayAndWait` — binary spray split, probabilistic gossip.
- `MeshPairingCode` — 6-digit code per §F.
- `MeshFingerprint` — `XXXX-XXXX-XXXX` from Ed25519 pub.

Out (separate work):

- `CBCentralManager` / `CBPeripheralManager` integration with these primitives. The existing `RAVEN/Services/MeshService.swift` uses a different service UUID (`BA5E0000-…`) and the legacy simple envelope. Migrating that service to use this package is tracked separately.
- Encryption seal/open — that lives in `CryptoService` and just consumes the AES key derived via HKDF.

## Tests

```sh
swift test --package-path RAVEN-iOS/MeshV1
```

The test target consumes fixtures from `RAVEN-iOS/MeshV1/Tests/MeshV1Tests/Resources/v1/`, which is a **copy** of `shared-vectors/v1/`. Re-sync after `python3 shared-vectors/generate_v1.py`:

```sh
tools/sync-vectors.sh
```

## Integrating into the iOS app

Two options:

1. **Local Swift Package** — In `RAVEN.xcodeproj`, add a local package reference to `MeshV1/`. Then `import MeshV1` from `MeshService.swift` and rewrite to use the v1 types.
2. **Copy sources** — pull the `Sources/MeshV1/*.swift` into the existing `RAVEN/Services/Mesh/` directory and add to the app target. Simpler if you don't want a package dependency.

Path 1 keeps the wire layer testable in isolation; path 2 is faster to wire up.
