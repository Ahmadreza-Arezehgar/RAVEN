# ADR 0003 — Wire, crypto, identity, bridge, IPC, services

**Status:** Accepted  
**Date:** 2026-08-12

## Wire serialization

Canonical object: binary `RavenEnvelopeV1` (`protocol/RAVEN_ENVELOPE_V1.md`). No JSON rewrite at relays.

## Crypto libraries

- Rust: `ed25519-dalek`, `x25519-dalek`, `chacha20poly1305`, `hkdf`/`sha2`
- iOS: CryptoKit + existing ATSAM / Noise
- Content seal: ATSAM RVNA1 (prefer v2) or interim `0x7F` for demos; Noise RVNS1/RVNH1 for first contact

## Identity

- User machine id: Ed25519 → `RavenAddressV1` (bech32m `rvn1…`)
- Serverless mobile binding: `userId == fingerprint(identityKey)` when using QR/verified pin
- Transport peer id: separate from Raven user identity (no BLE MAC / IP as Raven id)

## Bridge

Opaque cross-transport forward only — see `protocol/RAVEN_BRIDGE_V1.md`. BridgeSubsystem must not hold conversation keys.

## IPC / services

- Prefer Unix domain socket (macOS/Linux) with peer-cred checks; Windows named pipe notes
- `ash`/`raven` are clients; `raven-node` is the daemon
- launchd user agent / systemd user unit / Windows per-user process — closing the TUI must not stop the node
- Never overwrite `/bin/ash`; prefer `raven` binary + conflict detection
