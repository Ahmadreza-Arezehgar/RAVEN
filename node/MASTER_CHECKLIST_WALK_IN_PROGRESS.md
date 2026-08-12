# Master Engineering Checklist — Walk In Progress

**Branch:** `feature/raven-serverless-v1`  
**Walk started:** 2026-08-12 (this session)  
**Baseline HEAD at walk start:** `6189f2e`  
**Security-fix commit:** `113bf33af5f65da7df96f1efa50a38ca48c92cde`  
**Operator:** automated desktop agent (evidence-backed; human review still required)

> Formal §1–§60 walk. Status values: `PASS` | `FAIL` | `BLOCKED_HUMAN` | `BLOCKED_HARDWARE` | `IN_PROGRESS`.  
> No item marked PASS without concrete evidence (test name, script, SHA, or file).

---

## Session evidence pack (this machine)

| Proof | Result | Artifact / command |
|-------|--------|-------------------|
| §59 harness | **17/17 PASS** | `scripts/final_serverless_proof.sh` → `node/proof_artifacts/20260812T165958Z-56946` (`AUTOMATED_PROOF_GREEN`) |
| raven-core + ash tests | PASS | `cargo test -p raven-core -p ash` (incl. `discovery_v1` 26 tests after anti-spam) |
| bridge / mailbox / swarm / two_node / lan | PASS | `node/scripts/{two_node_demo,bridge_abc_demo,mailbox_opaque_smoke,libp2p_swarm_smoke,lan_path_smoke,bootstrap_manual_peer_smoke}.sh` |
| macOS build | PASS | `cargo build -p raven-core -p ash -p raven-node` |
| Windows cross | PASS (compile) | `x86_64-pc-windows-gnu` → `ash.exe` / `raven.exe` / `raven-node.exe` |
| Linux cross | PASS (compile) | `aarch64-unknown-linux-musl` + `x86_64-unknown-linux-musl` static `ash`/`raven-node` (Docker daemon **down** — no in-container runtime) |
| iOS XCTest | PASS | ContactRequestInbox (+ anti-spam), Discovery*, RavenEnvelope*, RavenServerlessLan*, Mesh*, RavenBleRvn1* — **TEST SUCCEEDED** |
| MeshEnvelope default | PASS (safe OFF) | `FeatureFlags.swift` `.ravenEnvelopeV1` default `false` |
| `--send` argv refuse | PASS | `raven-node run --send …` exits 2 with `REFUSE:` |
| UDS peer UID | PASS (compile+link) | `ipc_server.rs` `getpeereid` / `SO_PEERCRED` |

---

## Sections 1–60 (honest)

| § | Title | Status | Evidence / gap |
|---|-------|--------|----------------|
| 1 | Completion Rules | PASS | This walk + status docs require SHA/tests; no checkbox without evidence |
| 2 | Non-Negotiable Product Requirements | IN_PROGRESS | 1:1 text serverless path proven in harness; BLE physical + multi-NAT still open |
| 3 | Exact Meaning of Serverless | PASS | `docs/SERVERLESS_MODEL.md`; harness step `04_fastapi_not_in_path` |
| 4 | V1 Scope | PASS | Text 1:1 only; groups/media out of scope in docs |
| 5 | Repository and Baseline Safety | PASS | Branch `feature/raven-serverless-v1`; secret scan scripts present; live rotation **BLOCKED_HUMAN** |
| 6 | Architecture Decisions | IN_PROGRESS | ADR 0001–0003 landed; remaining ADRs stubbed |
| 7 | Prior-Art Review | PASS | `docs/PRIOR_ART_REVIEW_V1.md` |
| 8 | Phase A Protocol Freeze | PASS (soft) | Freeze hashes + packet; independent freeze review **BLOCKED_HUMAN** |
| 9 | Raven Identity | PASS | raven-core + iOS fingerprint; public bits only in ash banner |
| 10 | Raven Address | PASS / FROZEN | Vectors + `from_display` |
| 11 | Aliases and Contacts | PASS | Soft Unique Tags; ash `contact`/`find`; iOS FindContacts behind flag; alias conflict never silent |
| 12 | Asynchronous First Contact | PASS | Contact request E2EE + accept inbox; anti-spam caps added this session |
| 13 | Cryptographic Requirements | IN_PROGRESS | Envelope + ATSAM KATs; CryptoKit CT interop open |
| 14 | Key Storage | IN_PROGRESS | identity.seed 0600; iOS Keychain for device identity; PeerKeyDirectory still UserDefaults (known debt) |
| 15 | Canonical Raven Envelope | PASS / FROZEN | Shared vectors rust/swift |
| 16 | Delivery States and ACK | PASS | Harness step `08_ack_delivered_status` |
| 17 | Raven Node Core | PASS | raven-node daemon + service |
| 18 | Background Service Integration | PASS (software) | launchd/systemd scripts; notarization **BLOCKED_HUMAN** |
| 19 | Local IPC Security | PASS | UDS 0600 + peer-UID check + secret-field refuse |
| 20 | Terminal Command / Install | PASS | ash/raven; never overwrite `/bin/ash` (INSTALL_macOS); Windows `ash.exe` naming |
| 21–25 | Terminal UX / send / history | PASS | ash banner/find/contact verified interactively on macOS |
| 26 | Secure CLI Usage | PASS | ash refuse argv; **raven-node `--send` now REFUSE** (was warn) |
| 27 | Local DB and Queues | PASS | SQLite outbox + forward_queue |
| 28 | Internet P2P | PASS | InternetTransport + libp2p swarm smoke |
| 29 | DHT / Peer Discovery | IN_PROGRESS | DiscoveryResolver; public Internet Kad **BLOCKED_HARDWARE** |
| 30 | Bootstrap Nodes | PASS | disable-raven-defaults + manual peer smoke |
| 31 | NAT Traversal | BLOCKED_HARDWARE | Docker NAT sim SKIP (daemon down this session) |
| 32 | Offline Store-and-Forward | PASS | Harness step 06 + mailbox opaque |
| 33 | Raven Bridge Definition | PASS | DTN gateway sense; bridge never decrypts |
| 34 | Transport Adapter Architecture | PASS | mock_ble + LAN + Internet + store |
| 35 | Routing Policy | PASS | Spray-and-Wait bounds in bridge_v1 tests |
| 36–37 | Bluetooth | IN_PROGRESS | Framing + iOS carrier tests; headless GATT **BLOCKED_HARDWARE** |
| 38 | Mobile Compatibility | PASS | RavenEnvelope* + FindContacts/ContactRequestInbox behind flag; MeshEnvelope default OFF |
| 39 | Multi-Device | PASS | DeviceCert + ash device sync commands |
| 40 | Dedup and Replay | PASS | bridge_v1 + harness step 10 |
| 41 | Out-of-Order | IN_PROGRESS | ATSAM skipped-key iOS; Rust AEAD |
| 42 | Abuse and Spam | PASS | Per-peer bridge limits + contact-request sender/inbox caps |
| 43 | Privacy / Metadata | IN_PROGRESS | Redacted logs; DHT privacy cost documented |
| 44 | Logging / Diagnostics | PASS | ash doctor; no secrets in §59 artifacts (step 15) |
| 45 | Threat Model | PASS (soft) | `docs/THREAT_MODEL.md`; external align **BLOCKED_HUMAN** |
| 46 | Parser / Fuzzing | IN_PROGRESS | fuzz_smoke green; long campaign open |
| 47 | Cross-Platform Interop | IN_PROGRESS | macOS runtime + Win/Linux cross-compile; Linux runtime needs Docker/QEMU |
| 48–51 | Mandatory tests | PASS | Demos + harness aggregate |
| 52 | Packaging | PASS (unsigned) | `scripts/release/build_unsigned.sh` prior; MSI/notarize **BLOCKED_HUMAN** |
| 53 | Node Operator Controls | PASS | ash node bridge/store/relay/bootstrap |
| 54 | Migration | PASS | Never silent FastAPI (ash assert + iOS exclusive path when flag ON) |
| 55 | Open-Source Readiness | IN_PROGRESS | AGPL; no GitHub push this wave |
| 56 | Documentation | PASS | SERVERLESS_MODEL, INSTALL_*, discovery docs |
| 57 | CI Requirements | PASS (declared) | `raven-serverless.yml` matrix; not re-run on GH this session |
| 58 | Phase Exit Gates | IN_PROGRESS | A pending human freeze; B–G software maximized |
| 59 | Final Serverless Proof | PASS (automated) | Harness green; physical multi-device **BLOCKED_HARDWARE** |
| 60 | Final Definition of Done | BLOCKED_HUMAN | External auditors / notarize / phones |

---

## Progress estimate

- **Automatable software sections with evidence this walk:** ~48 / 60 (~80%) at PASS or soft-PASS  
- **Explicitly BLOCKED (human/hardware):** §31, parts of §2/§29/§36–37/§59 physical, §5/§8/§18/§45/§52/§60 human gates  
- **IN_PROGRESS (software debt):** §6, §13–14, §41, §43, §46–47, §55, §58  

**READY for user physical test?** **Partial YES for terminal software on this Mac** (ash/raven-node demos + §59 green). **NO for marketing DoD / multi-device BLE / notarized installers** until human+hardware gates clear.

---

## Security fixes landed this walk (summary)

1. Android Apple OAuth `state` validate + PKCE S256  
2. Android `SessionStore.clearAll` + `SignOutHooks` + `IdentityKeyService.reset` on sign-out  
3. `raven-node --send` REFUSE (scripts → `--send-stdin`)  
4. UDS IPC peer-UID check  
5. Contact-request anti-spam (Rust + Swift)

See parent final message table for files/SHAs after commit.
