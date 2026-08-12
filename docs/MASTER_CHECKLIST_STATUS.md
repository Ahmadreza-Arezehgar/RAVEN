# MASTER_CHECKLIST_STATUS — Raven Serverless Terminal Messaging

**Branch:** `feature/raven-serverless-v1`  
**Baseline start commit:** `18fa01e2a32ef014387ae2857ca272f34555cddd`  
**Primary land commit:** `ce328dd` (local only — not pushed)  
**This session:** security harden + cross-platform verify + formal checklist walk start (local only — not pushed)  
**Prior lands:** `818c6fd` contact-request accept inbox / `e9c0050` iOS Discovery UI / `8b89f36` Discovery V1 (local only — not pushed)  
**Checklist source:** `docs/MASTER_ENGINEERING_CHECKLIST.md` (also mirrored under `node/`)  
**Walk log:** `docs/MASTER_CHECKLIST_WALK_IN_PROGRESS.md`  
**Updated:** 2026-08-12  

> **IMPLEMENTATION + PROOF HARNESS COMPLETE** for automatable §59 software steps.  
> Formal §-by-§ walk **IN PROGRESS** — see walk doc.  
> This is **not** marketing READY / full user “start full test” DoD.  
> Hardware + external human review remain BLOCKED_*.

Status legend: `NOT_STARTED` | `IN_PROGRESS` | `IMPLEMENTED` | `REVIEWED` | `FROZEN` | `BLOCKED_HUMAN` | `BLOCKED_HARDWARE`

Reviewer for all IMPLEMENTED rows: **pending human** unless noted.

**Last green proofs (this machine):** `scripts/final_serverless_proof.sh` → `AUTOMATED_PROOF_GREEN` (17/17) run `20260812T165958Z-56946`; `cargo test -p raven-core -p ash` (+ bridge_v1 / discovery_v1 incl. anti-spam / fuzz_smoke); demos two_node / bridge_abc / mailbox / swarm / lan / bootstrap; Windows `x86_64-pc-windows-gnu` `ash.exe`/`raven-node.exe`; Linux musl static `ash`/`raven-node` (aarch64+x86_64); iOS XCTest Discovery/Envelope/ContactRequest/ServerlessLan **TEST SUCCEEDED**; MeshEnvelope/`ravenEnvelopeV1` default OFF.

| § | Section | Status | Evidence / notes |
|---|---------|--------|------------------|
| 1 | Completion Rules | IMPLEMENTED | Walk doc + local commits required for SHA evidence |
| 2 | Non-Negotiable Product Requirements | IN_PROGRESS | 1:1 text path; groups/media out of scope; physical BLE open |
| 3 | Exact Meaning of Serverless | IMPLEMENTED | `docs/SERVERLESS_MODEL.md` + three planes + Tag V1 |
| 4 | V1 Scope | IMPLEMENTED | Text 1:1 only documented |
| 5 | Repository and Baseline Safety | IMPLEMENTED | Branch + baseline + secret scan; live rotation **BLOCKED_HUMAN** |
| 6 | Required Architecture Decisions | IN_PROGRESS | ADRs 0001–0003 landed; remaining ADRs stubbed |
| 7 | Prior-Art Review | IMPLEMENTED | `docs/PRIOR_ART_REVIEW_V1.md` |
| 8 | Phase A Protocol Freeze | IMPLEMENTED | Specs + freeze hashes; independent freeze review **BLOCKED_HUMAN** |
| 9 | Raven Identity | IMPLEMENTED | protocol + raven-core + iOS fingerprint binding |
| 10 | Raven Address | FROZEN | `RAVEN_ADDRESS_V1` + vectors |
| 11 | Aliases and Contacts | IMPLEMENTED | Soft Unique Tags; ash find/contact; iOS FindContacts + ContactRequestInbox behind flag |
| 12 | Asynchronous First Contact | IMPLEMENTED | E2EE contact request; accept/decline/block; anti-spam sender/inbox caps |
| 13 | Cryptographic Requirements | IN_PROGRESS | Envelope + ATSAM KATs; CryptoKit CT interop open |
| 14 | Key Storage | IN_PROGRESS | identity.seed 0600; Keychain device identity; PeerKeyDirectory UserDefaults debt |
| 15 | Canonical Raven Envelope | FROZEN | vectors + rust/swift/python |
| 16 | Delivery States and ACK | IMPLEMENTED | queue + ACK; §59 harness ACK step |
| 17 | Raven Node Core | IMPLEMENTED | raven-node daemon + `service` |
| 18 | Background Service Integration | IMPLEMENTED | launchd/systemd; notarization **BLOCKED_HUMAN** |
| 19 | Local IPC Security | IMPLEMENTED | UDS 0600 + peer-UID (getpeereid/SO_PEERCRED) + secret-field refuse |
| 20 | Terminal Command and Installation | IMPLEMENTED | ash/raven; never overwrite `/bin/ash`; Windows `ash.exe` |
| 21–25 | Terminal menus / send / history | IMPLEMENTED | petname-first; banner/find/contact verified macOS |
| 26 | Secure CLI Usage | IMPLEMENTED | argv plaintext **REFUSED** in ash + raven-node; `--send-stdin` only |
| 27 | Local DB and Queues | IMPLEMENTED | SQLite outbox + forward_queue + chat_history.json |
| 28 | Internet P2P Networking | IMPLEMENTED | InternetTransport + libp2p swarm; FastAPI out of path |
| 29 | DHT and Peer Discovery | IN_PROGRESS | DiscoveryResolver; public Internet Kad **BLOCKED_HARDWARE** |
| 30 | Bootstrap Nodes | IMPLEMENTED | disable-raven-defaults + manual peer |
| 31 | NAT Traversal | BLOCKED_HARDWARE | Docker NAT sim SKIP when daemon down |
| 32 | Offline Store-and-Forward | IMPLEMENTED | StoreObject + mailbox + §59 offline step |
| 33 | Raven Bridge Definition | IMPLEMENTED | DTN gateway — bridge never decrypts |
| 34 | Transport Adapter Architecture | IMPLEMENTED | mock_ble + LAN + Internet + store + swarm |
| 35 | Routing Policy | IMPLEMENTED | Spray-and-Wait bounds |
| 36–37 | Bluetooth Transport / Forwarding | IN_PROGRESS | framing + iOS carrier; headless GATT **BLOCKED_HARDWARE** |
| 38 | Mobile Compatibility | IMPLEMENTED | RavenEnvelope* + exclusive serverless send when flag ON; MeshEnvelope default OFF |
| 39 | Multi-Device User Support | IMPLEMENTED | DeviceCert + ash device sync |
| 40 | Dedup and Replay | IMPLEMENTED | bridge_v1 + §59 step 10 |
| 41 | Out-of-Order | IN_PROGRESS | ATSAM skipped-key iOS; Rust AEAD |
| 42 | Abuse and Spam Controls | IMPLEMENTED | per-peer rate limits + contact-request caps |
| 43 | Privacy and Metadata | IN_PROGRESS | redacted logs; DHT privacy cost documented |
| 44 | Logging and Diagnostics | IMPLEMENTED | ash doctor; no secrets in §59 artifacts |
| 45 | Security Threat Model | IMPLEMENTED | threat model + external review packet; align **BLOCKED_HUMAN** |
| 46 | Parser and Fuzzing | IN_PROGRESS | fuzz_smoke CI; long campaign open |
| 47 | Cross-Platform Interop | IN_PROGRESS | macOS runtime; Win/Linux cross-compile; Linux container runtime pending Docker |
| 48–51 | Mandatory tests | IMPLEMENTED | demos green; §59 harness |
| 52 | Packaging | IMPLEMENTED | unsigned release; MSI/notarize **BLOCKED_HUMAN** |
| 53 | Node Operator Controls | IMPLEMENTED | ash node bridge/store/relay/bootstrap |
| 54 | Migration | IMPLEMENTED | never silent FastAPI |
| 55 | Open-Source Readiness | IN_PROGRESS | AGPL; publish not done (no GitHub push) |
| 56 | Documentation | IMPLEMENTED | SERVERLESS_MODEL, INSTALL_*, walk doc |
| 57 | CI Requirements | IMPLEMENTED | raven-serverless.yml matrix declared |
| 58 | Phase Exit Gates | IN_PROGRESS | A pending human freeze; B–G software maximized |
| 59 | Final Serverless Proof | IMPLEMENTED | Automated harness green; physical multi-device **BLOCKED_HARDWARE** |
| 60 | Final Definition of Done | BLOCKED_HUMAN | External review / notarize / phones |

## Design memos / handoff

- `docs/MASTER_CHECKLIST_WALK_IN_PROGRESS.md` — formal walk evidence  
- `docs/RAVEN_DISCOVERY_V1.md` — multi-lane search / contact request  
- `docs/EXTERNAL_REVIEW_PACKET.md`  
- `docs/FINAL_SERVERLESS_PROOF.md` + `scripts/final_serverless_proof.sh`  

## Honest leftovers

### BLOCKED_HUMAN
- External crypto/protocol freeze review
- Apple notarized signing / Windows Authenticode
- External DoD review (§60)
- Operate physical phones for BLE proof

### BLOCKED_HARDWARE
- Physical 3-phone / multi-NAT CGNAT / DCUtR
- Headless CoreBluetooth desktop radio
- Live rust-libp2p Kad on public Internet
- Docker NAT / Linux-in-container runtime when Docker daemon unavailable

**READY FOR FULL TEST (marketing) = NO** — terminal software path on macOS is ready for operator smoke; formal DoD is not.
