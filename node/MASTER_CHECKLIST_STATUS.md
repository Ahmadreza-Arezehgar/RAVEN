# MASTER_CHECKLIST_STATUS — Raven Serverless Terminal Messaging

**Branch:** `feature/raven-serverless-v1`  
**Baseline start commit:** `18fa01e2a32ef014387ae2857ca272f34555cddd`  
**Primary land commit:** `ce328dd` (local only — not pushed)  
**This session land:** *(filled after commit)*  
**Checklist source:** `docs/MASTER_ENGINEERING_CHECKLIST.md` (also mirrored under `node/`)  
**Updated:** 2026-08-12  

Status legend: `NOT_STARTED` | `IN_PROGRESS` | `IMPLEMENTED` | `REVIEWED` | `FROZEN` | `BLOCKED_HUMAN` | `BLOCKED_HARDWARE`

Reviewer for all IMPLEMENTED rows: **pending human** unless noted.

**Last green proofs (this machine):** `cargo test -p raven-core` (67 lib + bridge_v1 12 + fuzz_smoke 3 + reliability 4); `cargo test -p ash`; `raven-node ipc` ↔ `raven ipc-ping` UDS; prior: `two_node_demo`, `lan_path_smoke`, `internet_dial_smoke`, `bridge_abc_demo`; `python3 -m pytest` (25); iOS `RavenEnvelope*` XCTest (25).

| § | Section | Status | Evidence / notes |
|---|---------|--------|------------------|
| 1 | Completion Rules | IMPLEMENTED | This file + local commits required for SHA evidence |
| 2 | Non-Negotiable Product Requirements | IN_PROGRESS | 1:1 text path; groups/media out of scope |
| 3 | Exact Meaning of Serverless | IMPLEMENTED | `docs/SERVERLESS_MODEL.md` |
| 4 | V1 Scope | IMPLEMENTED | Text 1:1 only documented |
| 5 | Repository and Baseline Safety | IN_PROGRESS | Branch + baseline dump + secret scan report; SBOM/history scan partial; credential rotation BLOCKED_HUMAN |
| 6 | Required Architecture Decisions | IN_PROGRESS | ADRs 0001–0003 landed; remaining ADRs stubbed as follow-ups |
| 7 | Prior-Art Review | IMPLEMENTED | `docs/PRIOR_ART_REVIEW_V1.md` |
| 8 | Phase A Protocol Freeze | IMPLEMENTED | All gap specs landed under `protocol/` (see table); independent freeze review still BLOCKED_HUMAN |
| 9 | Raven Identity | IMPLEMENTED | protocol + raven-core + iOS fingerprint binding |
| 10 | Raven Address | FROZEN | `RAVEN_ADDRESS_V1` + vectors |
| 11 | Aliases and Contacts | IN_PROGRESS | ash contacts.json + sanitize; alias gossip vectors exist |
| 12 | Asynchronous First Contact | IN_PROGRESS | `RAVEN_PREKEY_BUNDLE_V1` + `prekey_bundle` Rust; iOS ATSAMPrekeyService HTTP still legacy optional |
| 13 | Cryptographic Requirements | IN_PROGRESS | Envelope auth + ATSAM root/KDF/AEAD KATs; **Rust ML-KEM-768 hybrid pairing** (`atsam_mlkem`) green; CryptoKit CT interop KAT still open |
| 14 | Key Storage | IN_PROGRESS | identity.seed 0600; Keychain on iOS; encrypted DB partial |
| 15 | Canonical Raven Envelope | FROZEN | vectors + rust/swift/python |
| 16 | Delivery States and ACK | IMPLEMENTED | `RAVEN_DELIVERY_STATE_V1` + queue states + ACK relay |
| 17 | Raven Node Core | IN_PROGRESS | raven-node daemon; roles via policy; bounds partial |
| 18 | Background Service Integration | IN_PROGRESS | launchd/systemd scripts + Windows notes; notarization BLOCKED_HUMAN |
| 19 | Local IPC Security | IMPLEMENTED | UDS `raven-node ipc` + `raven ipc-ping` / doctor; mode 0600; secret-field refuse |
| 20 | Terminal Command and Installation | IMPLEMENTED | `ash` + `raven` bins; doctor conflict vs `/bin/ash` + PATH which; never overwrite `/bin/ash` |
| 21–25 | Terminal menus / send / history | IN_PROGRESS | ash interactive Messages/Send/Contacts/Status; bidi/ANSI sanitize on aliases |
| 26 | Secure CLI Usage | IMPLEMENTED | `--stdin-text` preferred; argv warning |
| 27 | Local DB and Queues | IMPLEMENTED | SQLite outbox + forward_queue; expires i64 clamp fix |
| 28 | Internet P2P Networking | IN_PROGRESS | InternetTransport hello+frame+dial smoke (TCP); signed discovery records; full libp2p QUIC/Kad swarm not claimed |
| 29 | DHT and Peer Discovery | IN_PROGRESS | `discovery::PeerRecord` + `DiscoveryStore` DHT-ready; live Kad network open |
| 30 | Bootstrap Nodes | NOT_STARTED | |
| 31 | NAT Traversal | BLOCKED_HARDWARE | `node/NAT_TRAVERSAL.md` — software substitutes documented |
| 32 | Offline Store-and-Forward | IMPLEMENTED | `RAVEN_STORE_OBJECT_V1` + rotating mailbox/store tags + `StoreMailbox`; bridge store-carry |
| 33 | Raven Bridge Definition | IMPLEMENTED | protocol + node BRIDGE_V1 + bridge_v1 + abc reverse |
| 34 | Transport Adapter Architecture | IMPLEMENTED | `RAVEN_TRANSPORT_INTERFACE_V1` + mock_ble + LAN + Internet + store |
| 35 | Routing Policy | IMPLEMENTED | select_path + node_policy |
| 36–37 | Bluetooth Transport / Forwarding | IN_PROGRESS | `RAVEN_BLE_FRAMING_V1`; iOS GATT flagged; raven-node mock_ble CI; CoreBluetooth headless BLOCKED_HARDWARE |
| 38 | Mobile Compatibility | IN_PROGRESS | RavenEnvelope* + senderUserId resolver |
| 39 | Multi-Device User Support | NOT_STARTED | |
| 40 | Dedup and Replay | IMPLEMENTED | bridge_v1 cases |
| 41 | Out-of-Order | IN_PROGRESS | ATSAM skipped-key on iOS; Rust AEAD known-root |
| 42 | Abuse and Spam Controls | IMPLEMENTED | per-peer rate limits |
| 43 | Privacy and Metadata | IN_PROGRESS | redacted logs; caps generic |
| 44 | Logging and Diagnostics | IMPLEMENTED | ash doctor/status; no secrets |
| 45 | Security Threat Model | IN_PROGRESS | existing THREAT_MODEL; align pass pending human |
| 46 | Parser and Fuzzing | IN_PROGRESS | `tests/fuzz_smoke.rs` CI smoke; long campaign open |
| 47 | Cross-Platform Interop | IN_PROGRESS | `RAVEN_INTEROPERABILITY_MATRIX` + shared-vectors |
| 48–51 | Mandatory tests | IN_PROGRESS | demos green; 1k always-on + opt-in 10k script; ANSI/bidi tests green |
| 52 | Packaging | IN_PROGRESS | install scripts local; MSI/notarize BLOCKED_HUMAN |
| 53 | Node Operator Controls | IMPLEMENTED | ash node bridge/store/relay |
| 54 | Migration | NOT_STARTED | flag keeps MeshEnvelope default |
| 55 | Open-Source Readiness | IN_PROGRESS | AGPL; publish not done (no GitHub push) |
| 56 | Documentation | IN_PROGRESS | SERVERLESS_MODEL, ADRs, TERMINAL_DEMO, BRIDGE, NAT_TRAVERSAL, protocol freeze set |
| 57 | CI Requirements | NOT_STARTED | local suites only |
| 58 | Phase Exit Gates | IN_PROGRESS | A docs complete pending human freeze; B–G partial |
| 59 | Final Serverless Proof | NOT_STARTED | Needs physical multi-device / offline mobile / CGNAT — software substitutes exist for A–B–C |
| 60 | Final Definition of Done | NOT_STARTED | External review BLOCKED_HUMAN; NAT/BLE hardware leftovers |

## Protocol freeze gap list (§8)

| Spec | Status |
|------|--------|
| PREKEY_BUNDLE_V1 | LANDED `protocol/RAVEN_PREKEY_BUNDLE_V1.md` + vectors |
| STORE_OBJECT_V1 | LANDED `protocol/RAVEN_STORE_OBJECT_V1.md` + vectors |
| BLE_FRAMING_V1 | LANDED `protocol/RAVEN_BLE_FRAMING_V1.md` |
| TRANSPORT_INTERFACE_V1 | LANDED `protocol/RAVEN_TRANSPORT_INTERFACE_V1.md` |
| ERROR_CODES_V1 | LANDED `protocol/RAVEN_ERROR_CODES_V1.md` |
| DELIVERY_STATE_V1 | LANDED `protocol/RAVEN_DELIVERY_STATE_V1.md` |
| INTEROP_MATRIX | LANDED `protocol/RAVEN_INTEROPERABILITY_MATRIX.md` |
| RAVEN_BRIDGE_V1 | LANDED + aligned to new specs |

## Local proof commands (software)

```bash
cd node
cargo test -p raven-core -p ash
cargo test -p raven-core --test bridge_v1 --test fuzz_smoke
./scripts/two_node_demo.sh
./scripts/lan_path_smoke.sh
./scripts/internet_dial_smoke.sh
./scripts/bridge_abc_demo.sh
./scripts/reliability_10k.sh          # 1k subset; RAVEN_RELIABILITY_10K=1 for full 10k
# IPC:
raven-node ipc --data-dir /tmp/raven-ipc &
raven ipc-ping --data-dir /tmp/raven-ipc
cd ../protocol/reference && python3 -m pytest -q
```

## Honest leftovers

### BLOCKED_HUMAN
- External crypto/protocol freeze review (§8 exit)
- Live credential rotation if history scan finds secrets
- Apple notarized signing
- External DoD review (§60)

### BLOCKED_HARDWARE
- Physical 3-phone / multi-NAT CGNAT / DCUtR proof (`node/NAT_TRAVERSAL.md`)
- Headless CoreBluetooth desktop radio
- Live rust-libp2p Kad swarm on public Internet

### Software still open
- Bootstrap node set (§30)
- Multi-device (§39)
- CI wiring (§57)
- CryptoKit ↔ Rust ML-KEM ciphertext shared KATs
- Full 10k run is opt-in (`RAVEN_RELIABILITY_10K=1`)
