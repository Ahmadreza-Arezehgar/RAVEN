# MASTER_CHECKLIST_STATUS — Raven Serverless Terminal Messaging

**Branch:** `feature/raven-serverless-v1`  
**Baseline start commit:** `18fa01e2a32ef014387ae2857ca272f34555cddd`  
**Primary land commit:** `ce328dd` (local only — not pushed)  
**Prior lands:** `11e59ee` / `3ccc258` / `679e5e8` / `cd0b13e` / `0bd0b68` / `eea1029` / `7acbef7` (local only — not pushed)  
**This session:** iOS Discovery search UI (local only — not pushed)  
**Prior lands:** `8b89f36` Discovery V1 / `7290487` docs (local only — not pushed)  
**Prior lands:** `215ba30` / `7acbef7` / `eea1029` / `0bd0b68` / `cd0b13e` (local only — not pushed)  
**Checklist source:** `docs/MASTER_ENGINEERING_CHECKLIST.md` (also mirrored under `node/`)  
**Updated:** 2026-08-12  

> **IMPLEMENTATION + PROOF HARNESS COMPLETE** for automatable §59 software steps.  
> This is **not** marketing READY / full user “start full test” DoD. Formal §-by-§ walk follows user testing.  
> Hardware + external human review remain BLOCKED_*.

Status legend: `NOT_STARTED` | `IN_PROGRESS` | `IMPLEMENTED` | `REVIEWED` | `FROZEN` | `BLOCKED_HUMAN` | `BLOCKED_HARDWARE`

Reviewer for all IMPLEMENTED rows: **pending human** unless noted.

**Last green proofs (this machine):** `scripts/final_serverless_proof.sh` → `AUTOMATED_PROOF_GREEN` (17/17); `cargo test -p raven-core` (+ bridge_v1 / fuzz_smoke / reliability); `cargo test -p ash`; mailbox / swarm / bootstrap / lan / internet / two_node / bridge_abc demos; unsigned `scripts/release/build_unsigned.sh`.

| § | Section | Status | Evidence / notes |
|---|---------|--------|------------------|
| 1 | Completion Rules | IMPLEMENTED | This file + local commits required for SHA evidence |
| 2 | Non-Negotiable Product Requirements | IN_PROGRESS | 1:1 text path; groups/media out of scope |
| 3 | Exact Meaning of Serverless | IMPLEMENTED | `docs/SERVERLESS_MODEL.md` + three planes + Tag V1 |
| 4 | V1 Scope | IMPLEMENTED | Text 1:1 only documented |
| 5 | Repository and Baseline Safety | IMPLEMENTED | Branch + baseline + secret scan + rotate/FP table; live rotation only if HUMAN_CONFIRM is real (**BLOCKED_HUMAN** decision) |
| 6 | Required Architecture Decisions | IN_PROGRESS | ADRs 0001–0003 landed; remaining ADRs stubbed |
| 7 | Prior-Art Review | IMPLEMENTED | `docs/PRIOR_ART_REVIEW_V1.md` |
| 8 | Phase A Protocol Freeze | IMPLEMENTED | Specs + `docs/PROTOCOL_FREEZE_HASHES_V1.md`; independent freeze review **BLOCKED_HUMAN** |
| 9 | Raven Identity | IMPLEMENTED | protocol + raven-core + iOS fingerprint binding |
| 10 | Raven Address | FROZEN | `RAVEN_ADDRESS_V1` + vectors; `from_display` fixed |
| 11 | Aliases and Contacts | IMPLEMENTED | Soft Unique Tags; ash `contact *` / `find` / `nearby` / `alias publish`; Discovery V1; iOS FindContacts UI behind flag |
| 12 | Asynchronous First Contact | IMPLEMENTED | Real hybrid prekey publish; `contact add --prekey-file`; `contact request` E2EE; no FastAPI |
| 13 | Cryptographic Requirements | IN_PROGRESS | Envelope + ATSAM KATs + ML-KEM shared CT KATs; CryptoKit CT interop open |
| 14 | Key Storage | IN_PROGRESS | identity.seed 0600; Keychain on iOS; prekey_hybrid.secret 0600 |
| 15 | Canonical Raven Envelope | FROZEN | vectors + rust/swift/python |
| 16 | Delivery States and ACK | IMPLEMENTED | queue + ACK relay; §59 harness ACK/Delivered step |
| 17 | Raven Node Core | IMPLEMENTED | raven-node daemon + `service` (bridge+ipc) |
| 18 | Background Service Integration | IMPLEMENTED | launchd/systemd → `service`; Windows Task Scheduler script; notarization **BLOCKED_HUMAN** |
| 19 | Local IPC Security | IMPLEMENTED | UDS + EnqueueSealed → outbox/forward; secret-field refuse |
| 20 | Terminal Command and Installation | IMPLEMENTED | ash/raven; never overwrite `/bin/ash`; INSTALL_* docs |
| 21–25 | Terminal menus / send / history | IMPLEMENTED | petname-first; chat history; `/back` `/info` `/verify` `/block` |
| 26 | Secure CLI Usage | IMPLEMENTED | argv plaintext refused; seal-in-ash + IPC / `--send-stdin` |
| 27 | Local DB and Queues | IMPLEMENTED | SQLite outbox + forward_queue + chat_history.json |
| 28 | Internet P2P Networking | IMPLEMENTED | InternetTransport + libp2p swarm; FastAPI out of path |
| 29 | DHT and Peer Discovery | IN_PROGRESS | PeerRecord + AliasClaimStore + ProfileStore + DiscoveryResolver; public Internet Kad **BLOCKED_HARDWARE** |
| 30 | Bootstrap Nodes | IMPLEMENTED | disable-raven-defaults + manual peer; §59 harness + smoke |
| 31 | NAT Traversal | BLOCKED_HARDWARE | software substitutes: `docs/NAT_SOFTWARE_SIM.md` + `scripts/nat_docker_sim.sh` (SKIP if Docker down) |
| 32 | Offline Store-and-Forward | IMPLEMENTED | StoreObject + mailbox + §59 offline-recipient step |
| 33 | Raven Bridge Definition | IMPLEMENTED | DTN gateway sense — not social bridge |
| 34 | Transport Adapter Architecture | IMPLEMENTED | mock_ble framing + LAN + Internet + store + swarm |
| 35 | Routing Policy | IMPLEMENTED | Spray-and-Wait bounds |
| 36–37 | Bluetooth Transport / Forwarding | IN_PROGRESS | framing + `ble-status`; `--features corebluetooth` compile seam; headless GATT **BLOCKED_HARDWARE**; iOS carrier |
| 38 | Mobile Compatibility | IMPLEMENTED | RavenEnvelope* + inbox petname + exclusive serverless send path; iOS discovery search UI |
| 39 | Multi-Device User Support | IMPLEMENTED | DeviceCert + petname SyncContact + `ash device sync-*` / revoke |
| 40 | Dedup and Replay | IMPLEMENTED | bridge_v1 + §59 harness step 10 |
| 41 | Out-of-Order | IN_PROGRESS | ATSAM skipped-key on iOS; Rust AEAD |
| 42 | Abuse and Spam Controls | IMPLEMENTED | per-peer rate limits + block list |
| 43 | Privacy and Metadata | IN_PROGRESS | redacted logs; DHT privacy cost documented |
| 44 | Logging and Diagnostics | IMPLEMENTED | ash doctor + messaging_path + bootstrap summary |
| 45 | Security Threat Model | IMPLEMENTED | `docs/THREAT_MODEL.md` + external review packet; align pass **BLOCKED_HUMAN** |
| 46 | Parser and Fuzzing | IN_PROGRESS | fuzz_smoke CI; long campaign open |
| 47 | Cross-Platform Interop | IN_PROGRESS | interop matrix + shared vectors |
| 48–51 | Mandatory tests | IMPLEMENTED | demos green; mailbox; §59 harness aggregates; 10k opt-in |
| 52 | Packaging | IMPLEMENTED | unsigned release layout + SHA256 + INSTALL_*; MSI/notarize **BLOCKED_HUMAN** |
| 53 | Node Operator Controls | IMPLEMENTED | ash node bridge/store/relay/bootstrap |
| 54 | Migration | IMPLEMENTED | never silent FastAPI — ash assert + iOS exclusive path when flag ON |
| 55 | Open-Source Readiness | IN_PROGRESS | AGPL; publish not done (no GitHub push) |
| 56 | Documentation | IMPLEMENTED | SERVERLESS_MODEL, FRIEND_MESH_BRIDGE, TAG, PRIOR_ART, NAT, INSTALL_*, EXTERNAL_REVIEW_PACKET, FINAL_SERVERLESS_PROOF |
| 57 | CI Requirements | IMPLEMENTED | raven-serverless.yml: Linux/macOS/Windows + mailbox smoke + secret-scan + SBOM fail-on-missing |
| 58 | Phase Exit Gates | IN_PROGRESS | A docs complete pending human freeze; B–G software maximized |
| 59 | Final Serverless Proof | IMPLEMENTED | **Automated software harness green** (`scripts/final_serverless_proof.sh`); physical multi-device / CGNAT remain **BLOCKED_HARDWARE** |
| 60 | Final Definition of Done | BLOCKED_HUMAN | External review packet ready; notarize / hired auditors / phones remain human |

## Design memos / handoff

- `docs/RAVEN_DISCOVERY_V1.md` — multi-lane search / contact request (no central Raven DB)  
- `docs/EXTERNAL_REVIEW_PACKET.md` — threat model, freeze hashes, crypto map, vector cmds  
- `docs/PROTOCOL_FREEZE_HASHES_V1.md` — SHA-256 freeze  
- `docs/FINAL_SERVERLESS_PROOF.md` + `scripts/final_serverless_proof.sh`  
- `docs/PHYSICAL_BLE_THREE_DEVICE.md`  
- `docs/NAT_SOFTWARE_SIM.md` + `scripts/nat_docker_sim.sh`  
- `docs/SIGNING_NOTARIZATION_CHECKLIST.md` + `scripts/release/build_unsigned.sh`  
- `docs/INSTALL_{macOS,Linux,Windows}.md`

## Local proof commands (software)

```bash
bash scripts/final_serverless_proof.sh
cat node/proof_artifacts/LATEST/SUMMARY.md
cd node && cargo test -p raven-core -p ash
bash scripts/nat_docker_sim.sh          # SKIP ok if Docker down
bash scripts/release/build_unsigned.sh  # unsigned only
bash scripts/secret_history_scan.sh
bash scripts/freeze_protocol_hashes.sh
```

## Honest leftovers

### BLOCKED_HUMAN
- External crypto/protocol freeze review (packet ready)
- Confirm `server/setup-resend.sh` placeholder vs live key; rotate if live
- Apple notarized signing / Windows Authenticode
- External DoD review (§60)
- Operate physical phones for BLE proof

### BLOCKED_HARDWARE
- Physical 3-phone / multi-NAT CGNAT / DCUtR
- Headless CoreBluetooth desktop radio (compile seam only)
- Live rust-libp2p Kad on **public Internet**
- Docker NAT sim when Docker daemon unavailable (script SKIP)

### Software maximized this wave (REST)
- §59 automated proof harness + artifacts under `node/proof_artifacts/`
- External review packet + protocol freeze hashes
- Unsigned release layout + INSTALL_* + signing checklist
- NAT docker substitute + physical BLE operator doc
- raven-node `ble-status` + `--features corebluetooth` experiment seam
- Secret scan rotate/FP table

**IMPLEMENTATION + PROOF HARNESS COMPLETE** (automatable §59).  
**READY FOR FULL TEST (marketing) = NO** — user chooses when to start personal/hardware testing; formal checklist walk follows.
