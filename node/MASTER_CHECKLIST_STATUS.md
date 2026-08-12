# MASTER_CHECKLIST_STATUS — Raven Serverless Terminal Messaging

**Branch:** `feature/raven-serverless-v1`  
**Baseline start commit:** `18fa01e2a32ef014387ae2857ca272f34555cddd`  
**Primary land commit:** `ce328dd` (local only — not pushed)  
**Prior lands:** `11e59ee` / `3ccc258` / `679e5e8` / `cd0b13e` / `0bd0b68` (local only — not pushed)  
**This session:** implementation wave (local commit pending)  
**Checklist source:** `docs/MASTER_ENGINEERING_CHECKLIST.md` (also mirrored under `node/`)  
**Updated:** 2026-08-12  

> **Implementation wave — checklist formal walk AFTER user test.**  
> This file is a living status doc only. Do **not** treat the Master Checklist walkthrough as the current task. User starts testing when they choose; formal §-by-§ verification follows their test.

Status legend: `NOT_STARTED` | `IN_PROGRESS` | `IMPLEMENTED` | `REVIEWED` | `FROZEN` | `BLOCKED_HUMAN` | `BLOCKED_HARDWARE`

Reviewer for all IMPLEMENTED rows: **pending human** unless noted.

**Last green proofs (this machine):** `cargo test -p raven-core` (91 lib + bridge_v1 12 + fuzz_smoke 3 + reliability 4); `cargo test -p ash`; `./scripts/mailbox_opaque_smoke.sh`; prior libp2p/bootstrap/ML-KEM/demo smokes.

| § | Section | Status | Evidence / notes |
|---|---------|--------|------------------|
| 1 | Completion Rules | IMPLEMENTED | This file + local commits required for SHA evidence |
| 2 | Non-Negotiable Product Requirements | IN_PROGRESS | 1:1 text path; groups/media out of scope |
| 3 | Exact Meaning of Serverless | IMPLEMENTED | `docs/SERVERLESS_MODEL.md` + three planes + Tag V1 |
| 4 | V1 Scope | IMPLEMENTED | Text 1:1 only documented |
| 5 | Repository and Baseline Safety | IN_PROGRESS | Branch + baseline + `scripts/secret_history_scan.sh` + actionable `docs/SECRET_HISTORY_SCAN_REPORT.md`; credential rotation **BLOCKED_HUMAN** if hits |
| 6 | Required Architecture Decisions | IN_PROGRESS | ADRs 0001–0003 landed; remaining ADRs stubbed |
| 7 | Prior-Art Review | IMPLEMENTED | `docs/PRIOR_ART_REVIEW_V1.md` |
| 8 | Phase A Protocol Freeze | IMPLEMENTED | Gap specs landed; independent freeze review **BLOCKED_HUMAN** |
| 9 | Raven Identity | IMPLEMENTED | protocol + raven-core + iOS fingerprint binding |
| 10 | Raven Address | FROZEN | `RAVEN_ADDRESS_V1` + vectors; `from_display` fixed |
| 11 | Aliases and Contacts | IMPLEMENTED | Soft Unique Tags; ash `contact *`; iOS inbox uses `RavenTagDisplay` |
| 12 | Asynchronous First Contact | IMPLEMENTED | Real hybrid prekey publish; `contact add --prekey-file`; no FastAPI |
| 13 | Cryptographic Requirements | IN_PROGRESS | Envelope + ATSAM KATs + ML-KEM shared CT KATs |
| 14 | Key Storage | IN_PROGRESS | identity.seed 0600; Keychain on iOS; prekey_hybrid.secret 0600 |
| 15 | Canonical Raven Envelope | FROZEN | vectors + rust/swift/python |
| 16 | Delivery States and ACK | IMPLEMENTED | queue + ACK relay |
| 17 | Raven Node Core | IMPLEMENTED | raven-node daemon + `service` (bridge+ipc) |
| 18 | Background Service Integration | IMPLEMENTED | launchd/systemd → `service`; Windows Task Scheduler script; notarization **BLOCKED_HUMAN** |
| 19 | Local IPC Security | IMPLEMENTED | UDS + EnqueueSealed → outbox/forward; secret-field refuse |
| 20 | Terminal Command and Installation | IMPLEMENTED | ash/raven; never overwrite `/bin/ash` |
| 21–25 | Terminal menus / send / history | IMPLEMENTED | petname-first; chat history; `/back` `/info` `/verify` `/block` |
| 26 | Secure CLI Usage | IMPLEMENTED | argv plaintext refused; seal-in-ash + IPC / `--send-stdin` |
| 27 | Local DB and Queues | IMPLEMENTED | SQLite outbox + forward_queue + chat_history.json |
| 28 | Internet P2P Networking | IMPLEMENTED | InternetTransport + libp2p swarm; FastAPI out of path |
| 29 | DHT and Peer Discovery | IN_PROGRESS | PeerRecord + local Kad; public Internet Kad **BLOCKED_HARDWARE** |
| 30 | Bootstrap Nodes | IMPLEMENTED | `ash node add-bootstrap` / `disable-raven-defaults` / `show-bootstrap` |
| 31 | NAT Traversal | BLOCKED_HARDWARE | software substitutes documented |
| 32 | Offline Store-and-Forward | IMPLEMENTED | StoreObject + mailbox disk + opaque smoke |
| 33 | Raven Bridge Definition | IMPLEMENTED | DTN gateway sense — not social bridge |
| 34 | Transport Adapter Architecture | IMPLEMENTED | mock_ble framing + LAN + Internet + store + swarm |
| 35 | Routing Policy | IMPLEMENTED | Spray-and-Wait bounds |
| 36–37 | Bluetooth Transport / Forwarding | IN_PROGRESS | framing + env selector; headless GATT **BLOCKED_HARDWARE**; iOS carrier |
| 38 | Mobile Compatibility | IMPLEMENTED | RavenEnvelope* + inbox petname + exclusive serverless send path |
| 39 | Multi-Device User Support | IMPLEMENTED | DeviceCert + petname SyncContact + `ash device sync-*` / revoke |
| 40 | Dedup and Replay | IMPLEMENTED | bridge_v1 cases |
| 41 | Out-of-Order | IN_PROGRESS | ATSAM skipped-key on iOS; Rust AEAD |
| 42 | Abuse and Spam Controls | IMPLEMENTED | per-peer rate limits + block list |
| 43 | Privacy and Metadata | IN_PROGRESS | redacted logs; DHT privacy cost documented |
| 44 | Logging and Diagnostics | IMPLEMENTED | ash doctor + messaging_path + bootstrap summary |
| 45 | Security Threat Model | IN_PROGRESS | align pass **BLOCKED_HUMAN** |
| 46 | Parser and Fuzzing | IN_PROGRESS | fuzz_smoke CI; long campaign open |
| 47 | Cross-Platform Interop | IN_PROGRESS | interop matrix + shared vectors |
| 48–51 | Mandatory tests | IN_PROGRESS | demos green; mailbox smoke; 1k strengthened; 10k opt-in |
| 52 | Packaging | IN_PROGRESS | install scripts (incl. Windows ps1); MSI/notarize **BLOCKED_HUMAN** |
| 53 | Node Operator Controls | IMPLEMENTED | ash node bridge/store/relay/bootstrap |
| 54 | Migration | IMPLEMENTED | never silent FastAPI — ash assert + iOS exclusive path when flag ON |
| 55 | Open-Source Readiness | IN_PROGRESS | AGPL; publish not done (no GitHub push) |
| 56 | Documentation | IMPLEMENTED | SERVERLESS_MODEL, FRIEND_MESH_BRIDGE, RAVEN_TAG_V1, PRIOR_ART, NAT, ADRs |
| 57 | CI Requirements | IMPLEMENTED | raven-serverless.yml: Linux/macOS/Windows + mailbox smoke + secret-scan + SBOM fail-on-missing |
| 58 | Phase Exit Gates | IN_PROGRESS | A docs complete pending human freeze; B–G partial |
| 59 | Final Serverless Proof | BLOCKED_HARDWARE | Needs physical multi-device / offline mobile / CGNAT |
| 60 | Final Definition of Done | BLOCKED_HUMAN | External review + notarize leftovers |

## Design memos

- `docs/SERVERLESS_FRIEND_MESH_BRIDGE_DESIGN.md` — three planes  
- `docs/RAVEN_TAG_V1.md` — Zooko / Soft Unique Tags  
- `docs/MULTI_DEVICE_PARTITION_REVOCATION.md`  
- `docs/MIGRATION_SERVERLESS_V1.md`

## Local proof commands (software)

```bash
cd node
cargo test -p raven-core -p ash
cargo test -p raven-core --test bridge_v1 --test fuzz_smoke
./scripts/mailbox_opaque_smoke.sh
./scripts/reliability_10k.sh
bash ../scripts/secret_history_scan.sh
```

## Honest leftovers

### BLOCKED_HUMAN (§59/§60 gate)
- External crypto/protocol freeze review (§8)
- Live credential rotation if history scan finds real secrets (current hits are `.env.example` / README fixtures — human_review)
- Apple notarized signing
- External DoD review (§60)
- Waive or complete hardware proofs for §59

### BLOCKED_HARDWARE
- Physical 3-phone / multi-NAT CGNAT / DCUtR
- Headless CoreBluetooth desktop radio
- Live rust-libp2p Kad on **public Internet**

### Software maximized this wave
- Multi-device sync CLI + SyncContact petname/tag/pin + revocation disk
- ash bootstrap UX; chat history + slash cmds; argv plaintext refuse; IPC EnqueueSealed
- raven-node `service` (bridge+ipc); launchd/systemd/Windows install
- Real ML-KEM/X25519 prekey publish + contact `--prekey-file`
- Mailbox opaque put/get smoke; BLE frame encode/decode
- iOS: inbox RavenTagDisplay; localIsDestination; exclusive serverless send (no silent FastAPI)
- CI: mailbox smoke, Windows ps1 parse, SBOM fail-on-missing tree

**READY FOR FULL TEST = NO** until user chooses to start testing after this wave; formal checklist walk is AFTER their test. §59/§60 remain human/hardware.
