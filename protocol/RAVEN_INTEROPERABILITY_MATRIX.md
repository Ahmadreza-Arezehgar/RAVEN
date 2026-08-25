# RAVEN Interoperability Matrix V1

**Version:** 1  
**Status:** Living evidence table for Phase A/B freeze  
**Updated:** 2026-08-13

## 1. Wire object parity

| Object | Spec | Python ref | Rust `raven-core` | Swift iOS | Notes |
|--------|------|------------|-------------------|-----------|-------|
| Identity / address | IDENTITY / ADDRESS | yes | yes | yes | bech32m `rvn` |
| Envelope RVN1 | ENVELOPE | yes | yes | yes (`RavenEnvelope*`) | Shared positive and strict-negative vectors |
| ACK plaintext record | ACK | yes | yes | chat wire codec | live paths held by security errata |
| Indexed session / sealed ACK | INDEXED_SESSION | exact vectors | pure KDF/codec parity | exact KDF/codec parity | RVNA1 `0x03`; production disabled |
| PairInit / response | PAIR_INIT | exact codec/KDF/signature KAT | exact codec/verification/KAT | exact codec/verification/KAT | offline provisional root; disabled pending confidential carrier + durable endpoint actor |
| Routing tag | ROUTING_TAG | yes | yes | GhostRoute related | |
| Alias / caps / cert | ALIAS / CAPS / IDENTITY | yes | signing bytes | partial | |
| Prekey bundle | PREKEY_BUNDLE | structural vectors | `prekey_bundle` | `ATSAMPrekeyService` | HTTP legacy optional |
| Protected prekey lifecycle | local state, no wire type | normative state machine | `prekey_lifecycle` (production disabled) | pending | protected Rust actor; carrier and activation still blocked |
| Store object / mailbox transport | STORE_OBJECT / MAILBOX_TRANSPORT | vectors | strict object + real gated libp2p PUT/GET | bridge store path | restart retrieval proven; TTL-only deletion; endpoint activation held |
| NAT traversal composition | NAT_CONNECTIVITY | — | gated AutoNAT v2 client + Relay v2 client + DCUtR | Go bridge precedent | localhost TCP/QUIC/limit proof; real multi-NAT and CGNAT matrix pending |
| BLE framing | BLE_FRAMING | — | `ble_adapter` + mock | `RavenBleRvn1Carrier` | GATT hardware BLOCKED |
| Internet hello/frame | TRANSPORT | — | `internet` | LAN settings tests | |
| ATSAM root/KDF/AEAD | MAPPING | shared-vectors atsam/ | yes known-root | primary | ML-KEM: Rust+iOS |
| Bridge opaque forward | BRIDGE | — | `bridge` + demos | `RavenEnvelopeBridgeService` | |

## 2. Transport matrix

| Path | Software proof | Hardware leftover |
|------|----------------|-------------------|
| LAN TCP | `lan_path_smoke`, two_node | — |
| Internet/NAT | direct dial plus gated TCP/QUIC, Relay-client, AutoNAT-client, DCUtR localhost tests | multi-NAT / CGNAT / independently operated relay |
| mock_ble | `bridge_v1`, `bridge_abc` | — |
| BLE GATT | iOS unit/sim | physical 3-phone mesh |
| Store-carry | byte-identical libp2p sender-disconnect/store-restart/recipient-GET + bridge_abc | multi-store discovery/replication and real diverse operators |
| DHT discovery | signed record format | live libp2p DHT network |

## 3. Sealed content

| Frame | Rust | Swift |
|-------|------|-------|
| RVNA1 v2 known-root | seal + atsam_aead | ATSAMMessageSealer |
| RVNA1 `0x03` indexed ACK | pure KDF/codec + exact 143/293-byte vector | pure KDF/codec + same exact vector; not activated |
| RVNA1 hybrid PairInit | exact signed init/response + split ML-KEM + root HKDF | exact signed init/response verification + root HKDF; not activated |
| Noise RVNS1/RVNH1 | interim pairwise | NoiseSession |

## 4. How to extend

Add a row when a new platform claims parity; require shared-vector id or demo script SHA evidence in `docs/MASTER_CHECKLIST_STATUS.md`.
