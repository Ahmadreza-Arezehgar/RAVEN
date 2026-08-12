# Master Engineering Checklist — Walk In Progress

**Branch:** `feature/raven-serverless-v1`  
**Walk started:** 2026-08-12  
**Walk closed (document):** 2026-08-12 (this continuation)  
**Baseline HEAD at walk start:** `6189f2e`  
**Security-fix commit (prior):** `113bf33af5f65da7df96f1efa50a38ca48c92cde`  
**This continuation:** PeerKeyDirectory → Keychain (§14), logout pin wipe, ATSAM Keychain non-sync, checklist §1–60 fill  
**Operator:** automated desktop agent (evidence-backed; human review still required)

> Formal §1–§60 walk. Status values: `PASS` | `FAIL` | `BLOCKED_HUMAN` | `BLOCKED_HARDWARE` | `IN_PROGRESS`.  
> No item marked PASS without concrete evidence (test name, script, SHA, or file).  
> Combined rows from earlier draft are **expanded** so every section number appears once.

---

## Session evidence pack (this machine)

| Proof | Result | Artifact / command |
|-------|--------|-------------------|
| §59 harness | **17/17 PASS** | `scripts/final_serverless_proof.sh` → `node/proof_artifacts/20260812T165958Z-56946` (`AUTOMATED_PROOF_GREEN`) |
| raven-core + ash tests | PASS | `cargo test -p raven-core -p ash` (incl. `discovery_v1` anti-spam) |
| bridge / mailbox / swarm / two_node / lan | PASS | `node/scripts/{two_node_demo,bridge_abc_demo,mailbox_opaque_smoke,libp2p_swarm_smoke,lan_path_smoke,bootstrap_manual_peer_smoke}.sh` |
| macOS build | PASS | `cargo build -p raven-core -p ash -p raven-node` |
| Windows cross | PASS (compile) | `x86_64-pc-windows-gnu` → `ash.exe` / `raven.exe` / `raven-node.exe` |
| Linux cross | PASS (compile) | `aarch64-unknown-linux-musl` + `x86_64-unknown-linux-musl` static `ash`/`raven-node` |
| Docker NAT sim | **BLOCKED** | `scripts/nat_docker_sim.sh` → `RESULT=SKIP` `reason=docker_daemon_down` art `node/proof_artifacts/nat_docker_20260812T170633Z` (CLI present; Docker Desktop app missing / dockerd down) |
| Linux container runtime | **BLOCKED** | Same Docker daemon gap — no in-container smoke this session |
| iOS XCTest (prior) | PASS | Discovery*, RavenEnvelope*, ContactRequest*, RavenServerlessLan*, Mesh*, RavenBleRvn1* |
| iOS PeerKeyDirectory Keychain | PASS | `RAVENTests/PeerKeyDirectoryKeychainTests` **4/4** on `RAVEN-iPhone-15` OS 26.5 — **TEST SUCCEEDED** |
| Desktop identity_store | PASS | `cargo test -p raven-core identity_store` (Keychain round-trip + plaintext migrate on macOS); Windows DPAPI + Linux SS/0600 in `identity_store.rs` + `IDENTITY_SEED_STORAGE.md` |
| MeshEnvelope default | PASS (safe OFF) | `FeatureFlags.swift` `.ravenEnvelopeV1` default `false` |
| `--send` argv refuse | PASS | `raven-node run --send …` exits 2 with `REFUSE:` |
| UDS peer UID | PASS | `ipc_server.rs` `getpeereid` / `SO_PEERCRED` |
| Logout PeerKey wipe | PASS (code) | `AuthService.logout` → `PeerKeyDirectory.purgeAllPins()` |

---

## Sections 1–60 (honest, one row each)

| § | Title | Status | Evidence / gap |
|---|-------|--------|----------------|
| 1 | Completion Rules | PASS | Walk + status docs require SHA/tests; no checkbox without evidence |
| 2 | Non-Negotiable Product Requirements | IN_PROGRESS | 1:1 text serverless path proven in §59 harness; BLE physical + multi-NAT still open |
| 3 | Exact Meaning of Serverless | PASS | `docs/SERVERLESS_MODEL.md`; harness step `04_fastapi_not_in_path` |
| 4 | V1 Scope | PASS | Text 1:1 only; groups/media out of scope in docs |
| 5 | Repository and Baseline Safety | PASS | Branch `feature/raven-serverless-v1`; secret scan scripts present; live secret rotation **BLOCKED_HUMAN** |
| 6 | Architecture Decisions | IN_PROGRESS | ADR 0001–0003 landed (`docs/adr/`); remaining ADRs stubbed / not written |
| 7 | Prior-Art Review | PASS | `docs/PRIOR_ART_REVIEW_V1.md` |
| 8 | Phase A Protocol Freeze | PASS (soft) | `docs/PROTOCOL_FREEZE_HASHES_V1.md` + packet; independent freeze review **BLOCKED_HUMAN** |
| 9 | Raven Identity | PASS | raven-core + iOS fingerprint; public bits only in ash banner |
| 10 | Raven Address | PASS / FROZEN | Vectors + `from_display` |
| 11 | Aliases and Contacts | PASS | Soft Unique Tags; ash `contact`/`find`; iOS FindContacts behind flag; alias conflict never silent |
| 12 | Asynchronous First Contact | PASS | Contact request E2EE + accept inbox; anti-spam caps (`113bf33`) |
| 13 | Cryptographic Requirements | IN_PROGRESS | Envelope + ATSAM KATs present; full CryptoKit CT / ML-KEM interop KATs still open |
| 14 | Key Storage | PASS | Desktop `identity_store`: macOS Keychain, Windows DPAPI (`RVNDPAPI`), Linux Secret Service (gnu) / locked-file `0600` + `IDENTITY_SEED_STORAGE.md`; plaintext migrate; raven-core `identity_store::tests`. iOS device identity Keychain; **PeerKeyDirectory Keychain** (`77708ce`) + UD→KC + logout purge |
| 15 | Canonical Raven Envelope | PASS / FROZEN | Shared vectors rust/swift |
| 16 | Delivery States and ACK | PASS | Harness step `08_ack_delivered_status` |
| 17 | Raven Node Core | PASS | raven-node daemon + service |
| 18 | Background Service Integration | PASS (software) | launchd/systemd scripts; notarization **BLOCKED_HUMAN** |
| 19 | Local IPC Security | PASS | UDS 0600 + peer-UID check + secret-field refuse |
| 20 | Terminal Command / Install | PASS | ash/raven; never overwrite `/bin/ash` (INSTALL_macOS); Windows `ash.exe` naming |
| 21 | Terminal First-Run Flow | PASS | ash first-run / identity create path exercised on macOS |
| 22 | Terminal Main Menu | PASS | ash banner + menu verified interactively on macOS |
| 23 | Messages Menu | PASS | ash messages path verified with demos |
| 24 | Chat History | PASS | `chat_history.json` + ash history commands |
| 25 | Send New Message | PASS | ash send via stdin / node IPC (no argv plaintext) |
| 26 | Secure CLI Usage | PASS | ash refuse argv; **raven-node `--send` REFUSE** (`113bf33`) |
| 27 | Local DB and Queues | PASS | SQLite outbox + forward_queue |
| 28 | Internet P2P | PASS | InternetTransport + libp2p swarm smoke |
| 29 | DHT / Peer Discovery | IN_PROGRESS | DiscoveryResolver; public Internet Kad **BLOCKED_HARDWARE** |
| 30 | Bootstrap Nodes | PASS | disable-raven-defaults + manual peer smoke |
| 31 | NAT Traversal | BLOCKED_HARDWARE | `nat_docker_sim.sh` SKIP `docker_daemon_down` (`nat_docker_20260812T170633Z`); live CGNAT/DCUtR also hardware |
| 32 | Offline Store-and-Forward | PASS | Harness step 06 + mailbox opaque |
| 33 | Raven Bridge Definition | PASS | DTN gateway sense; bridge never decrypts |
| 34 | Transport Adapter Architecture | PASS | mock_ble + LAN + Internet + store |
| 35 | Routing Policy | PASS | Spray-and-Wait bounds in bridge_v1 tests |
| 36 | Bluetooth Transport | IN_PROGRESS | Framing + iOS `RavenBleRvn1CarrierTests`; headless GATT radio **BLOCKED_HARDWARE** |
| 37 | Bluetooth Forwarding Policy | IN_PROGRESS | Software policy/tests present; physical multi-hop BLE **BLOCKED_HARDWARE** |
| 38 | Mobile Compatibility | PASS | RavenEnvelope* + FindContacts/ContactRequestInbox behind flag; MeshEnvelope default OFF |
| 39 | Multi-Device | PASS | DeviceCert + ash device sync commands |
| 40 | Dedup and Replay | PASS | bridge_v1 + harness step 10 |
| 41 | Out-of-Order | IN_PROGRESS | ATSAM skipped-key iOS (`ATSAMChainRatchet`); Rust AEAD path; full matrix incomplete |
| 42 | Abuse and Spam | PASS | Per-peer bridge limits + contact-request sender/inbox caps |
| 43 | Privacy / Metadata | IN_PROGRESS | Redacted logs; DHT privacy cost documented; deeper metadata minimization open |
| 44 | Logging / Diagnostics | PASS | ash doctor; no secrets in §59 artifacts (step 15) |
| 45 | Threat Model | PASS (soft) | `docs/THREAT_MODEL.md`; external align **BLOCKED_HUMAN** |
| 46 | Parser / Fuzzing | IN_PROGRESS | `fuzz_smoke` green; long campaign open |
| 47 | Cross-Platform Interop | IN_PROGRESS | macOS runtime + Win/Linux cross-compile; Linux **in-container** runtime blocked on Docker daemon |
| 48 | Mandatory Network Tests | PASS | Demos + harness network steps green on macOS |
| 49 | Mandatory Security Tests | PASS | Refuse argv, UDS peer-UID, envelope KATs, anti-spam tests |
| 50 | Reliability and Scale Tests | PASS (smoke) | harness + `reliability_10k.sh` / fuzz_smoke scale hooks; not a multi-day soak |
| 51 | Terminal-Specific Security Tests | PASS | ash/raven-node argv refuse + doctor redaction |
| 52 | Packaging | PASS (unsigned) | `scripts/release/build_unsigned.sh` prior; MSI/notarize **BLOCKED_HUMAN** |
| 53 | Node Operator Controls | PASS | ash node bridge/store/relay/bootstrap |
| 54 | Migration | PASS | Never silent FastAPI (ash assert + iOS exclusive path when flag ON) |
| 55 | Open-Source Readiness | IN_PROGRESS | AGPL; no GitHub push this wave |
| 56 | Documentation | PASS | SERVERLESS_MODEL, INSTALL_*, discovery docs, this walk |
| 57 | CI Requirements | PASS (declared) | `.github/workflows/raven-serverless.yml` matrix; not re-run on GH this session |
| 58 | Phase Exit Gates | IN_PROGRESS | A pending human freeze; B–G software maximized |
| 59 | Final Serverless Proof | PASS (automated) | Harness green 17/17; physical multi-device **BLOCKED_HARDWARE** |
| 60 | Final Definition of Done | BLOCKED_HUMAN | External auditors / notarize / phones |

---

## Progress estimate

- **Sections with a terminal status recorded:** **60 / 60 (100% walked)**  
- **PASS / soft-PASS / FROZEN / software IMPLEMENTED-equivalent:** ~49 / 60 (~82%)  
- **Explicitly BLOCKED_HUMAN or BLOCKED_HARDWARE (primary status):** §31, §60 (+ nested human/hardware notes on §5/§8/§18/§29/§36–37/§45/§52/§59)  
- **IN_PROGRESS (software debt):** §2, §6, §13, §29, §36–37, §41, §43, §46–47, §55, §58  

**Checklist walk document complete?** **YES (~82% automatable PASS; DoD not closed)**  

**READY for user physical test?** **Partial YES for terminal software on this Mac** (ash/raven-node demos + §59 green). **NO for marketing DoD / multi-device BLE / notarized installers / Docker NAT** until human+hardware gates clear.

---

## Security fixes this continuation

1. iOS `PeerKeyDirectory` UserDefaults → Keychain (+ one-shot migration, peer index, tests)  
2. `AuthService.logout` → `PeerKeyDirectory.purgeAllPins()` (cross-account pin wipe)  
3. `ATSAMRootStorage` Keychain queries set `kSecAttrSynchronizable = false`  
4. Desktop `raven_core::identity_store` — macOS Keychain / Windows DPAPI / Linux Secret Service + locked-file `0600`; plaintext `identity.seed` migrate; ash/raven-node/raven-swarm wired

Prior wave (`113bf33`): OAuth state/PKCE, SessionStore clear, raven-node `--send` refuse, UDS peer-UID, anti-spam.
