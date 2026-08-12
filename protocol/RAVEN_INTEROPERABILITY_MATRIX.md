# RAVEN Interoperability Matrix V1

**Version:** 1  
**Status:** Living evidence table for Phase A/B freeze  
**Updated:** 2026-08-12

## 1. Wire object parity

| Object | Spec | Python ref | Rust `raven-core` | Swift iOS | Notes |
|--------|------|------------|-------------------|-----------|-------|
| Identity / address | IDENTITY / ADDRESS | yes | yes | yes | bech32m `rvn` |
| Envelope RVN1 | ENVELOPE | yes | yes | yes (`RavenEnvelope*`) | 25 XCTest green |
| ACK | ACK | yes | yes | chat wire | |
| Routing tag | ROUTING_TAG | yes | yes | GhostRoute related | |
| Alias / caps / cert | ALIAS / CAPS / IDENTITY | yes | signing bytes | partial | |
| Prekey bundle | PREKEY_BUNDLE | structural vectors | `prekey_bundle` | `ATSAMPrekeyService` | HTTP legacy optional |
| Store object | STORE_OBJECT | vectors | `store_object` | bridge store path | |
| BLE framing | BLE_FRAMING | — | `ble_adapter` + mock | `RavenBleRvn1Carrier` | GATT hardware BLOCKED |
| Internet hello/frame | TRANSPORT | — | `internet` | LAN settings tests | |
| ATSAM root/KDF/AEAD | MAPPING | shared-vectors atsam/ | yes known-root | primary | ML-KEM: Rust+iOS |
| Bridge opaque forward | BRIDGE | — | `bridge` + demos | `RavenEnvelopeBridgeService` | |

## 2. Transport matrix

| Path | Software proof | Hardware leftover |
|------|----------------|-------------------|
| LAN TCP | `lan_path_smoke`, two_node | — |
| Internet dial | `internet_dial_smoke` | multi-NAT / CGNAT |
| mock_ble | `bridge_v1`, `bridge_abc` | — |
| BLE GATT | iOS unit/sim | physical 3-phone mesh |
| Store-carry | bridge_abc store path | diverse store ops |
| DHT discovery | signed record format | live libp2p DHT network |

## 3. Sealed content

| Frame | Rust | Swift |
|-------|------|-------|
| RVNA1 v2 known-root | seal + atsam_aead | ATSAMMessageSealer |
| RVNA1 hybrid pairing | `atsam_mlkem` + root HKDF | ATSAMHybridPairing (CryptoKit ML-KEM on new OS) |
| Noise RVNS1/RVNH1 | interim pairwise | NoiseSession |

## 4. How to extend

Add a row when a new platform claims parity; require shared-vector id or demo script SHA evidence in `docs/MASTER_CHECKLIST_STATUS.md`.
