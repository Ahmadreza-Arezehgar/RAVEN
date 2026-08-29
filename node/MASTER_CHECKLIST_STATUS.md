# MASTER_CHECKLIST_STATUS — Raven Serverless Terminal Messaging

> **Historical status snapshot (2026-08-12), not current acceptance.** The
> former aggregate reliability/NAT/proof generators are absent and the 100%
> claim below has not been recomputed for this checkout. See
> [current verification status](FINAL_SERVERLESS_PROOF.md).

**Branch:** `feature/raven-serverless-v1`  
**Baseline start commit:** `18fa01e2a32ef014387ae2857ca272f34555cddd`  
**Updated:** 2026-08-12 (historical reliability 20× + former automatable 100% claim)
**Checklist source:** `docs/MASTER_ENGINEERING_CHECKLIST.md`  
**Walk log:** `docs/MASTER_CHECKLIST_WALK_IN_PROGRESS.md`  
**Automatable 100% ledger:** `docs/CHECKLIST_100_AUTOMATABLE.md`

> **Historical record: automatable checklist = 100% PASS.** This is not a current result.
> Absolute marketing DoD (§60) is **not** claimed — physical BLE / CGNAT / notarize / external review remain BLOCKED_*.

Status legend: `NOT_STARTED` | `IN_PROGRESS` | `IMPLEMENTED` | `REVIEWED` | `FROZEN` | `BLOCKED_HUMAN` | `BLOCKED_HARDWARE` | `PASS_SOFTWARE_SUBSTITUTE` | `HISTORICAL RESULT`

Reviewer for all IMPLEMENTED rows: **pending human** unless noted.

**Historical green records (this machine; not rerun for the current tree):**
- Archived reliability artifact → `RELIABILITY_20_GREEN` (generator removed)
- Archived Lima Docker NAT artifact → **PASS** (generator removed)
- Linux: musl `ash --help` inside Lima `ash-amd64-preflight`
- Windows: `ash.exe` PE32+ self-check (`PASS_SOFTWARE_SUBSTITUTE`; wine blocked on sudo/gstreamer)
- iOS: iPhone + iPad sim XCTest loops (Discovery / ContactRequest / RavenEnvelope*) **TEST SUCCEEDED**
- Desktop: `cargo test -p raven-core -p ash`; service SQLite race fixed (WAL busy_timeout + warmup)

| § | Section | Status | Evidence / notes |
|---|---------|--------|------------------|
| 1 | Completion Rules | IMPLEMENTED | Walk + SHA/test evidence required |
| 2 | Non-Negotiable Product Requirements | IMPLEMENTED | 1:1 text path proven; physical BLE listed separately |
| 3 | Exact Meaning of Serverless | IMPLEMENTED | `SERVERLESS_MODEL.md` + Tag V1 |
| 4 | V1 Scope | IMPLEMENTED | Text 1:1 only |
| 5 | Repository and Baseline Safety | IMPLEMENTED | Branch + secret scan; live rotation **BLOCKED_HUMAN** |
| 6 | Required Architecture Decisions | IMPLEMENTED | ADR 0001–0003; remaining deferred as non-blocking for V1 text path |
| 7 | Prior-Art Review | IMPLEMENTED | `PRIOR_ART_REVIEW_V1.md` |
| 8 | Phase A Protocol Freeze | IMPLEMENTED | Specs + freeze hashes; independent review **BLOCKED_HUMAN** |
| 9 | Raven Identity | IMPLEMENTED | raven-core + iOS fingerprint |
| 10 | Raven Address | FROZEN | Vectors |
| 11 | Aliases and Contacts | IMPLEMENTED | Soft Unique Tags; ash find/contact; matrix scenario 06 |
| 12 | Asynchronous First Contact | IMPLEMENTED | request/accept/block; matrix 06 |
| 13 | Cryptographic Requirements | IMPLEMENTED | Envelope + ATSAM KATs + tamper/replay matrix 09 (full ML-KEM interop optional debt) |
| 14 | Key Storage | IMPLEMENTED | identity_store Keychain/DPAPI/SS + iOS PeerKeyDirectory |
| 15 | Canonical Raven Envelope | FROZEN | rust/swift/python vectors |
| 16 | Delivery States and ACK | IMPLEMENTED | matrix + §59 |
| 17 | Raven Node Core | IMPLEMENTED | raven-node daemon + service |
| 18 | Background Service Integration | IMPLEMENTED | launchd/systemd + service survives ash; notarization **BLOCKED_HUMAN** |
| 19 | Local IPC Security | IMPLEMENTED | UDS 0600 + peer-UID |
| 20 | Terminal Command and Installation | IMPLEMENTED | ash/raven; Win `ash.exe` |
| 21 | Terminal First-Run Flow | IMPLEMENTED | ash identity create |
| 22 | Terminal Main Menu | IMPLEMENTED | banner verified |
| 23 | Messages Menu | IMPLEMENTED | demos |
| 24 | Chat History | IMPLEMENTED | chat_history.json |
| 25 | Send New Message | IMPLEMENTED | stdin / IPC |
| 26 | Secure CLI Usage | IMPLEMENTED | argv refuse |
| 27 | Local DB and Queues | IMPLEMENTED | SQLite outbox + forward_queue (busy_timeout) |
| 28 | Internet P2P Networking | IMPLEMENTED | matrix 01 |
| 29 | DHT and Peer Discovery | PASS_SOFTWARE_SUBSTITUTE | Local Kad/libp2p swarm; public Internet Kad **BLOCKED_HARDWARE** |
| 30 | Bootstrap Nodes | IMPLEMENTED | matrix 10 |
| 31 | NAT Traversal | PASS_SOFTWARE_SUBSTITUTE | Docker dual-net NAT sim **PASS** (Lima); live CGNAT **BLOCKED_HARDWARE** |
| 32 | Offline Store-and-Forward | IMPLEMENTED | matrix 04/07 |
| 33 | Raven Bridge Definition | IMPLEMENTED | bridge never decrypts |
| 34 | Transport Adapter Architecture | IMPLEMENTED | mock_ble + LAN + Internet + store |
| 35 | Routing Policy | IMPLEMENTED | Spray-and-Wait / bridge_v1 |
| 36 | Bluetooth Transport | PASS_SOFTWARE_SUBSTITUTE | Framing + iOS carrier tests; physical GATT **BLOCKED_HARDWARE** |
| 37 | Bluetooth Forwarding Policy | PASS_SOFTWARE_SUBSTITUTE | Software multi-hop mock_ble; physical **BLOCKED_HARDWARE** |
| 38 | Mobile Compatibility | IMPLEMENTED | iPhone + iPad sim loops |
| 39 | Multi-Device User Support | IMPLEMENTED | DeviceCert + ash device |
| 40 | Dedup and Replay | IMPLEMENTED | matrix 08/09 |
| 41 | Out-of-Order | IMPLEMENTED | ATSAM skipped-key + Rust AEAD path exercised |
| 42 | Abuse and Spam Controls | IMPLEMENTED | rate limits + contact caps |
| 43 | Privacy and Metadata | IMPLEMENTED | redacted logs; DHT cost documented |
| 44 | Logging and Diagnostics | IMPLEMENTED | ash doctor; no secrets in artifacts |
| 45 | Security Threat Model | IMPLEMENTED | threat model + review packet; align **BLOCKED_HUMAN** |
| 46 | Parser and Fuzzing | IMPLEMENTED | fuzz_smoke CI green (long campaign optional) |
| 47 | Cross-Platform Interop | IMPLEMENTED | macOS runtime + Win PE + Linux Lima/musl + Docker NAT |
| 48 | Mandatory Network Tests | IMPLEMENTED | matrix 01–05, 15 |
| 49 | Mandatory Security Tests | IMPLEMENTED | refuse argv, UDS, KATs, tamper |
| 50 | Reliability and Scale Tests | HISTORICAL RESULT | Archived ≥20-cycle result; generator absent |
| 51 | Terminal-Specific Security Tests | IMPLEMENTED | ash/raven-node refuse + doctor |
| 52 | Packaging | IMPLEMENTED | unsigned release; MSI/notarize **BLOCKED_HUMAN** |
| 53 | Node Operator Controls | IMPLEMENTED | ash node bridge/store/relay/bootstrap |
| 54 | Migration | IMPLEMENTED | never silent FastAPI |
| 55 | Open-Source Readiness | IMPLEMENTED | AGPL + docs; publish not pushed (operator) |
| 56 | Documentation | IMPLEMENTED | INSTALL_*, CHECKLIST_100, walk |
| 57 | CI Requirements | IMPLEMENTED | raven-serverless.yml declared |
| 58 | Phase Exit Gates | IMPLEMENTED | Software gates maximized; human freeze **BLOCKED_HUMAN** |
| 59 | Final Serverless Proof | HISTORICAL RESULT | Archived 17/17 snapshot; aggregate harness absent; physical multi-device **BLOCKED_HARDWARE** |
| 60 | Final Definition of Done | BLOCKED_HUMAN | External review / notarize / phones |

## Honest leftovers (absolute DoD only)

### BLOCKED_HUMAN
- External crypto/protocol freeze review
- Apple notarized signing / Windows Authenticode
- External DoD review (§60)
- Live secret rotation decisions

### BLOCKED_HARDWARE
- Physical 3-phone BLE mesh
- Live CGNAT / DCUtR hole-punch
- Headless CoreBluetooth desktop radio
- Public Internet Kad soak

**READY FOR FULL TEST (marketing) = NO.** Current automatable coverage is not
recomputed; absolute DoD still needs human, hardware, and independent review.
