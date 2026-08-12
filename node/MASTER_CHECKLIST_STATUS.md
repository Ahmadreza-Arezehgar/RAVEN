# MASTER_CHECKLIST_STATUS — Raven Serverless Terminal Messaging

**Branch:** `feature/raven-serverless-v1`  
**Baseline start commit:** `18fa01e2a32ef014387ae2857ca272f34555cddd`  
**Primary land commit:** `ce328dd` (local only — not pushed)  
**Checklist source:** `docs/MASTER_ENGINEERING_CHECKLIST.md` (also mirrored under `node/`)  
**Updated:** 2026-08-12  

Status legend: `NOT_STARTED` | `IN_PROGRESS` | `IMPLEMENTED` | `REVIEWED` | `FROZEN` | `BLOCKED_HUMAN`

Reviewer for all IMPLEMENTED rows: **pending human** unless noted.

**Last green proofs (this machine):** `cargo test -p raven-core -p ash`; `bridge_v1`; `two_node_demo`; `lan_path_smoke`; `internet_dial_smoke`; `bridge_abc_demo` (incl. reverse); `python3 -m pytest` (25); iOS `RavenEnvelope*` XCTest (25) on iPhone 17 sim.

| § | Section | Status | Evidence / notes |
|---|---------|--------|------------------|
| 1 | Completion Rules | IMPLEMENTED | This file + local commits required for SHA evidence |
| 2 | Non-Negotiable Product Requirements | IN_PROGRESS | 1:1 text path; groups/media out of scope |
| 3 | Exact Meaning of Serverless | IMPLEMENTED | `docs/SERVERLESS_MODEL.md` |
| 4 | V1 Scope | IMPLEMENTED | Text 1:1 only documented |
| 5 | Repository and Baseline Safety | IN_PROGRESS | Branch + baseline dump + secret scan report; SBOM/history scan partial; credential rotation BLOCKED_HUMAN |
| 6 | Required Architecture Decisions | IN_PROGRESS | ADRs 0001–0003 landed; remaining ADRs stubbed as follow-ups |
| 7 | Prior-Art Review | IMPLEMENTED | `docs/PRIOR_ART_REVIEW_V1.md` |
| 8 | Phase A Protocol Freeze | IN_PROGRESS | Existing rvn1 freeze; gaps: PREKEY, STORE_OBJECT, BLE_FRAMING, TRANSPORT_INTERFACE, ERROR_CODES, DELIVERY_STATE, INTEROP_MATRIX; Bridge formalized `protocol/RAVEN_BRIDGE_V1.md` |
| 9 | Raven Identity | IMPLEMENTED | protocol + raven-core + iOS fingerprint binding |
| 10 | Raven Address | FROZEN | `RAVEN_ADDRESS_V1` + vectors |
| 11 | Aliases and Contacts | IN_PROGRESS | ash contacts.json; alias gossip vectors exist |
| 12 | Asynchronous First Contact | IN_PROGRESS | Interim seal + Noise/ATSAM on iOS; Rust prekey bundle not full |
| 13 | Cryptographic Requirements | IN_PROGRESS | Envelope auth + ATSAM root/KDF/AEAD KATs; ML-KEM eng BLOCKED (iOS primary) |
| 14 | Key Storage | IN_PROGRESS | identity.seed 0600; Keychain on iOS; encrypted DB partial |
| 15 | Canonical Raven Envelope | FROZEN | vectors + rust/swift/python |
| 16 | Delivery States and ACK | IMPLEMENTED | queue states + ChatWire Delivered + ACK relay |
| 17 | Raven Node Core | IN_PROGRESS | raven-node daemon; roles via policy; bounds partial |
| 18 | Background Service Integration | IN_PROGRESS | launchd/systemd scripts + Windows notes; notarization BLOCKED_HUMAN |
| 19 | Local IPC Security | IN_PROGRESS | `raven-core::ipc` framing + tests; UDS daemon bind partial |
| 20 | Terminal Command and Installation | IMPLEMENTED | `ash` + `raven` bins; doctor; never overwrite `/bin/ash` |
| 21–25 | Terminal menus / send / history | IN_PROGRESS | ash interactive Messages/Send/Contacts/Status |
| 26 | Secure CLI Usage | IMPLEMENTED | `--stdin-text` preferred; argv warning |
| 27 | Local DB and Queues | IMPLEMENTED | SQLite outbox + forward_queue; expires i64 clamp fix |
| 28 | Internet P2P Networking | IN_PROGRESS | InternetTransport hello+frame+dial smoke (TCP); QUIC/libp2p DHT not complete |
| 29 | DHT and Peer Discovery | NOT_STARTED | ADR target; manual dial works |
| 30 | Bootstrap Nodes | NOT_STARTED | |
| 31 | NAT Traversal | BLOCKED_HUMAN | Needs multi-NAT hardware; software AutoNAT stubs not full DCUtR |
| 32 | Offline Store-and-Forward | IMPLEMENTED | store-carry in bridge_abc + queue; opaque tags helper |
| 33 | Raven Bridge Definition | IMPLEMENTED | protocol + node BRIDGE_V1 + bridge_v1 + abc reverse |
| 34 | Transport Adapter Architecture | IN_PROGRESS | mock_ble + LAN + InternetTransport; GATT dual backend boundary |
| 35 | Routing Policy | IMPLEMENTED | select_path + node_policy |
| 36–37 | Bluetooth Transport / Forwarding | IN_PROGRESS | iOS GATT flagged; raven-node mock_ble CI; CoreBluetooth headless BLOCKED |
| 38 | Mobile Compatibility | IN_PROGRESS | RavenEnvelope* + senderUserId resolver |
| 39 | Multi-Device User Support | NOT_STARTED | |
| 40 | Dedup and Replay | IMPLEMENTED | bridge_v1 cases |
| 41 | Out-of-Order | IN_PROGRESS | ATSAM skipped-key on iOS; Rust AEAD known-root |
| 42 | Abuse and Spam Controls | IMPLEMENTED | per-peer rate limits |
| 43 | Privacy and Metadata | IN_PROGRESS | redacted logs; caps generic |
| 44 | Logging and Diagnostics | IMPLEMENTED | ash doctor/status; no secrets |
| 45 | Security Threat Model | IN_PROGRESS | existing THREAT_MODEL; align pass pending human |
| 46 | Parser and Fuzzing | NOT_STARTED | unit negatives exist; fuzz CI open |
| 47 | Cross-Platform Interop | IN_PROGRESS | shared-vectors + runners |
| 48–51 | Mandatory tests | IN_PROGRESS | demos green; 10k scale / fuzz / ANSI open |
| 52 | Packaging | IN_PROGRESS | install scripts local; MSI/notarize BLOCKED_HUMAN |
| 53 | Node Operator Controls | IMPLEMENTED | ash node bridge/store/relay |
| 54 | Migration | NOT_STARTED | flag keeps MeshEnvelope default |
| 55 | Open-Source Readiness | IN_PROGRESS | AGPL; publish not done (no GitHub push) |
| 56 | Documentation | IN_PROGRESS | SERVERLESS_MODEL, ADRs, TERMINAL_DEMO, BRIDGE |
| 57 | CI Requirements | NOT_STARTED | local suites only |
| 58 | Phase Exit Gates | IN_PROGRESS | A partial; B largely; C partial; D partial; E partial; F software mock; G packaging partial |
| 59 | Final Serverless Proof | NOT_STARTED | Needs physical multi-device / offline mobile / CGNAT — software substitutes exist for A–B–C |
| 60 | Final Definition of Done | NOT_STARTED | External review BLOCKED_HUMAN; NAT/BLE hardware leftovers |

## Protocol freeze gap list (§8)

| Spec | Status |
|------|--------|
| PREKEY_BUNDLE_V1 | MISSING formal md |
| STORE_OBJECT_V1 | MISSING |
| BLE_FRAMING_V1 | MISSING (carrier in code) |
| TRANSPORT_INTERFACE_V1 | MISSING (InternetTransport in code) |
| ERROR_CODES_V1 | MISSING |
| DELIVERY_STATE_V1 | MISSING formal |
| INTEROP_MATRIX | MISSING |
| RAVEN_BRIDGE_V1 | LANDED `protocol/RAVEN_BRIDGE_V1.md` |

## Local proof commands (software)

```bash
cd node
cargo test -p raven-core -p ash
cargo test -p raven-core --test bridge_v1
./scripts/two_node_demo.sh
./scripts/lan_path_smoke.sh
./scripts/internet_dial_smoke.sh
./scripts/bridge_abc_demo.sh
cd ../protocol/reference && python3 -m pytest -q
```

## Honest BLOCKED_HUMAN leftovers

- External crypto/protocol review
- Live credential rotation if history scan finds secrets
- Apple notarized signing
- Physical 3-phone / multi-NAT CGNAT proof
- Full rust-libp2p DHT + DCUtR on real networks
- ML-KEM engine port to Rust (known-root subset done)
