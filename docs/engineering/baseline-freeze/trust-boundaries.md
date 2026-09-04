# Trust Boundaries — Architect Draft (Sprint 0)

**Status:** Architect draft — **not Security Board approved**  
**Primary owner:** #1 Principal Architect  
**Mandatory reviewers (checklist):** #17 Security Assurance Lead (Security Board chair), #6 Identity Lead  
**Also consult:** #5 Crypto Lead (ATSAM/keys), #4 Raven↔RDAP Interop, #14 RDAP Protocol Lead  
**Date:** 2026-09-04  
**Risk class of *changing* a boundary in code:** R3 (`risk-classes.md`, `approval-matrix.md` row “Trust boundary change”). This markdown is R0 documentation of the current model.

> **Coordination note.** Sprint 0 checklist assigns Trust boundaries to **#1, #17, #6**. This file is the Architect (#1) draft. Security Board (#17) and Identity (#6) are invited to mark gaps, reclassify residual risk, and reject undocumented assumptions before this row is treated as an assurance artifact. #1 will not self-merge any follow-up R3 change that *implements* a boundary.

Cross-links: [`architecture-dependency-map.md`](architecture-dependency-map.md), [`risk-classes.md`](risk-classes.md), [`approval-matrix.md`](approval-matrix.md), [`org-structure.md`](org-structure.md), [`docs/THREAT_MODEL.md`](../../THREAT_MODEL.md), [`protocol/SECURITY_ERRATA_RVN1_2026-08-13.md`](../../../protocol/SECURITY_ERRATA_RVN1_2026-08-13.md).

---

## How to read this draft

For each boundary:

- **Trusted** — components allowed to see or decide the protected asset.
- **Untrusted** — anything on the other side of the cut; authenticate and bound it.
- **Must validate** — concrete checks that already exist or are **required but not live**.
- **Owner role(s)** — primary + board, matching `approval-matrix.md`.
- **Threat-model rows** — `THREAT_MODEL.md` adversary classes.
- **Gaps** — undocumented assumptions or missing enforcement.

**Global posture (2026-08-13):** RVN1 is under a **production hold**. Older “Protected” verdicts that depend on live ATSAM E2EE, authenticated ACKs, or bounded multi-hop forwarding are superseded (`THREAT_MODEL.md` executable-posture table). Boundaries below describe the *intended* cut plus what the audited code actually does.

---

## TB1 — Process / IPC boundary (client ↔ raven-node)

**Cut:** A user-facing process (`ash` / `raven`, future RDAP helper, **UNKNOWN** iOS/Windows hosts) talks to the `raven-node` daemon. Unix: UDS `data_dir/raven-node.sock`. Windows: documented named pipe `\\.\pipe\raven-node` — **client not landed** (`node/scripts/install/WINDOWS_SERVICE.md`).

| | |
|--|--|
| **Trusted** | `raven-node` process (same euid as the connecting client). OS peer-cred. Data-dir owner. |
| **Untrusted** | Any other local process, other UIDs, stale sockets, malicious `IpcRequest` bytes, argv/`ps` observers. |
| **Must validate** | `IPC_VERSION == 1`; frame ≤ `MAX_IPC_FRAME` (256 KiB); JSON tag `op`; **refuse** substrings `seed` / `private_key` / `plaintext` / `recovery`; envelope decode on `EnqueueSealed`; `expected_pub_hex` on `LanDial`; UID match via `SO_PEERCRED` / `getpeereid`. Socket mode `0600`, unlink/rebind on start. |
| **Evidence** | `node/crates/raven-core/src/ipc.rs`; `node/crates/raven-node/src/ipc_server.rs`; ADR 0003; `protocol/RAVEN_ERROR_CODES_V1.md` (`IPC_*`). |
| **Owners** | #7 Core Runtime (IPC/daemon), #1 (boundary shape), #17 if authz/peer-cred changes. Identity #6 if IPC ever carried credentials (it must not). |
| **THREAT_MODEL** | §3.7 stolen unlocked device (out of scope once attacker is the user); §3.16 local malware (out of scope); MASTER checklist “Local IPC Security” in `node/MASTER_ENGINEERING_CHECKLIST.md` §19. |
| **Risk class** | Changing IPC auth or allowing secrets on the wire: **R3**. Adding a non-secret op: **R2**. |

**Allowed ops today:** `Ping`, `Status`, `SetPolicy`, `EnqueueSealed` (already-sealed envelope only), `LanDial`. Daemon “never seals from plaintext here.”

### Gaps / assumptions (TB1)

| ID | Gap | Assumption if unreviewed |
|----|-----|--------------------------|
| G1 | Same-UID is the entire local authz model | Any code running as the user is the user (`THREAT_MODEL` §3.16). No macOS/Windows code-signing check of the client binary. |
| G2 | Windows named-pipe client missing | Windows path is `--send-stdin` spawn (plaintext on a pipe to a child — still local, but **not** the UDS auth story). |
| G3 | `ash` also opens `queue.sqlite`, `contacts.json`, `forward_queue.sqlite` **directly** | IPC is not the only client↔node coupling. A compromised `ash` is a compromised data-dir. See undocumented deps D8. |
| G4 | No RDAP IPC client | RDAP does not cross this boundary at all (integration gap). |
| G5 | iOS/Watch/Windows app IPC | **UNKNOWN** — trees absent from this checkout. |

---

## TB2 — Network boundary (swarm / BLE / bridge)

**Cut:** Bytes arriving from LAN TCP, InternetTransport (`RIH1` + length-prefixed frames), libp2p (`raven-swarm`), BLE GATT / mock-BLE, or a Bridge hop. Relays and stores are **untrusted** (`SERVERLESS_FRIEND_MESH_BRIDGE_DESIGN.md` plane 2–3).

| | |
|--|--|
| **Trusted** | Local envelope parser + (intended) ATSAM endpoint. Path selection in `raven_core::transport`. |
| **Untrusted** | Every peer, relay, store, DHT participant, BLE neighbor, ISP, Bridge operator. FastAPI **must not** be on this path. |
| **Must validate** | Size → strict `RVN1` decode → TTL → route/session → outer auth → AEAD open → transactional commit (`THREAT_MODEL` §3.3 intended order). Caps are generic (`ble`/`internet`/`relay`/`store`/`bridge`) — never contact graphs (ADR 0002). BLE: `validate_opaque_rvn1` before TX (`RAVEN_BLE_FRAMING_V1.md`). Swarm mailbox: endpoint-supplied 16-byte `store_tag`, no derive-from-routing-tag (`mailbox.rs`). |
| **Evidence** | ADR 0002; `RAVEN_TRANSPORT_INTERFACE_V1.md`; `RAVEN_BRIDGE_V1.md`; `RAVEN_BLE_FRAMING_V1.md`; `docs/MESH_PROTOCOL.md` (legacy GATT JSON); `raven-node/src/main.rs` frame limits; `raven-swarm`. |
| **Owners** | #9 Network, #10 Transport, #2 Protocol (wire), #12 Apple (GATT), #17 for hold/errata. |
| **THREAT_MODEL** | §3.1 malicious relay; §3.2 store; §3.3 malicious peer; §3.4 passive ISP; §3.8/3.9 Sybil/eclipse; §3.15 malformed packet; §3.17 traffic analysis (out of scope). |

**Two encryption layers (design):** transport Noise/TLS ≠ Raven E2EE. Relays never decrypt sealed content (ADR 0002).

**Legacy vs RVN1:** `docs/MESH_PROTOCOL.md` is SoT for **shipped iOS GATT JSON** (including `Data.hashValue` chunk-key quirk). `RAVEN_BLE_FRAMING_V1.md` is SoT for **RVN1** (`RBF1` chunks). Do not mix parsers.

### Gaps / assumptions (TB2)

| ID | Gap | Assumption if unreviewed |
|----|-----|--------------------------|
| G6 | Hop / `replication_budget` **not** in sender signature | Cooperative policy only; Byzantine relay can raise them (`SPEC.md` invariant 7, errata). |
| G7 | Peer scoring / Sybil resistance “future work” | Connection caps bound resources, not identity (`THREAT_MODEL` §3.8). |
| G8 | Public Internet Kad / multi-NAT | `NAT_STATUS` / `RAVEN_NAT_CONNECTIVITY_V1.md` **BLOCKED_HARDWARE**; experimental bin only. |
| G9 | Go `Libp2pBridge` cited at `ios-native/RAVEN/Libp2pBridge/bridge.go` | **UNKNOWN** in this snapshot; ADR 0001 allows it as a mobile helper until Rust parity. |
| G10 | RDAP HTTP `:9001` and Git relay are **additional** network cuts, not Raven transports | Signed A2A ≠ envelope path. See TB4. |
| G11 | Mock-BLE is TCP on loopback | CI stand-in; not a radio security claim (`SERVERLESS_MODEL.md`). |

---

## TB3 — Crypto / identity boundary (ATSAM, keys, peer pinning)

**Cut:** Long-term Ed25519 user identity, device certificates, PairInit / prekeys, ATSAM session roots, and the **pin** that makes a network peer “this person.” Transport PeerId is a different namespace (ADR 0003; swarm derives libp2p key from `SHA-256("raven/libp2p-peer-key/v1" ‖ seed)`).

| | |
|--|--|
| **Trusted** | Platform keystore for the 32-byte seed (`identity_store.rs`, `docs/IDENTITY_SEED_STORAGE.md`). Intended ATSAM indexed-session actor (production-disabled). Human OOB check (QR / fingerprint / safety number). |
| **Untrusted** | Relays, DHT, anyone presenting an address without a local pin, RDAP’s **separate** `.team/keys` principal, `unsafe-demo-crypto` / proto `0x7F` interim sealer, lab Full Braid FFI. |
| **Must validate** | Address checksum (`RAVEN_ADDRESS_V1`); device cert + registry; contact add with `--verify-fp`; `LanDial.expected_pub_hex`; PairInit transcript bind (disabled); refuse logging seeds; RDAP `validate_address_public_key` + pin on trust/invite. |
| **Evidence** | ADR 0003; `RAVEN_IDENTITY_V1.md`; `RAVEN_PAIR_INIT_V1.md`; `ATSAM_*`; `docs/IDENTITY_SEED_STORAGE.md`; ash `contact add`; RDAP `raven_identity.py` + README trust model. |
| **Owners** | #6 Identity (pins, certs, authz), #5 Crypto (ATSAM/primitives/RNG), #3 Spec (versioned identity records), #17 Security Board second on R3. **#1 must not self-merge.** |
| **THREAT_MODEL** | §3.5 active MITM; §3.6 stolen locked device; §3.13 alias impersonation; §3.14 downgrade; errata on publicly derivable interim cipher. |
| **Risk class** | Any key-handling / ATSAM / pin-rule change: **R3**. |

**Pinning today (terminal):** local `contacts.json` maps petname/tag → `rvn1…` + pub hex + optional fingerprint (`SERVERLESS_FRIEND_MESH_BRIDGE_DESIGN.md`). Friendship never uses FastAPI.

**Pinning today (RDAP):** invite line `RDAP1 <name> <rvn1> <ed25519> <url>`; `trust` live-checks signed Agent Card against that pin. **Different key** from raven-node unless an operator copies material by hand (not a supported API).

### Gaps / assumptions (TB3)

| ID | Gap | Assumption if unreviewed |
|----|-----|--------------------------|
| G12 | ATSAM session / PairInit / prekey lifecycle **production-disabled** | Default `raven-node` origination requires authenticated session; demo sealer is feature-gated. No production E2EE claim. |
| G13 | Two identity stores (raven-node vs RDAP `.team/keys`) | Address format is shared; **principal is not**. A pin in `contacts.json` does not authorize an RDAP peer and vice versa. |
| G14 | Linux Secret Service vs locked-file fallback | `IDENTITY_SEED_STORAGE.md` vs `identity_store.rs` comments disagree on whether locked-file is “approved fallback” or “lab/CI override only”. **Needs #6+#5 resolution.** |
| G15 | `AfterFirstUnlockThisDeviceOnly` on iOS | Keys may be available while locked after first unlock (`THREAT_MODEL` §3.6). |
| G16 | Windows RDAP key files lack tested DACL-equivalent to POSIX `0600` | RDAP README Windows security hold. |
| G17 | Human QR/safety-number check is user responsibility | Crypto cannot prove the human (`THREAT_MODEL` §3.5). |
| G18 | Full Braid / ML-KEM incremental FFI | Lab/DEBUG only; Release `compile_error!`. Still an identity-adjacent binary interface if linked. |

---

## TB4 — RDAP agent / runtime boundary (signed tasks, reply, replay)

**Cut:** Untrusted natural-language / tool context vs delegated authority. RDAP today is an **experimental A2A companion**, not the approved `RAVEN_USER_OWNED_AGENT_RUNTIME_V1` executor.

| | |
|--|--|
| **Trusted** | Operator-pinned peer (address+key); verified HTTP signature (`raven.a2a.http-request.v1`); verified delegation (`raven.a2a.delegation.v2`); local revocation file (fail-closed); replay caches (transport and delegation, durable SQLite). |
| **Untrusted** | Task text, LLM output, tool results, Git history outside the `.team` allowlist, mDNS discover (TOFU), `--open` unsigned mode, `--allow-shell` (full OS user), remote model providers (plaintext leaves E2EE). |
| **Must validate** | Default reject unsigned RPC/tasks; pin match on card and reply; nonce+expiry+skew; replay `first_time`; owner-scoped task store; cancel requires owner’s fresh Raven HTTP signature; body/in-flight limits (`TEAM_MAX_*`). Mailbox path: operator flag `--experimental-plaintext-mailbox` — **must not** be sold as confidential. |
| **Evidence** | RDAP `README.md`; `team_agents/server.py`, `client.py`, `raven_identity.py`, `task_store.py`, `mesh.py`, `tools.py`. Runtime *intent*: `protocol/RAVEN_USER_OWNED_AGENT_RUNTIME_V1.md` (not approved; does not name RDAP). |
| **Owners** | #14 RDAP Protocol, #15 RDAP Runtime, #4 Interop, #16 UX/tooling, #6 if identity merge, #17 if security interop. |
| **THREAT_MODEL** | Raven TM does **not** enumerate A2A/LLM/tool threats. Runtime spec §2 does (prompt injection, capability replay, confused deputy). **Gap: no joint TM row.** |
| **Risk class** | Carrier onto ATSAM / identity merge / unsigned-default change: **R3**. Tool policy / LLM endpoint: **R2–R3**. |

**Honest output modes** (runtime spec §3.2): recommendation vs user-confirmed draft vs delegated agent action. RDAP `ask` is mode-3-shaped (distinct key, signed task) but **without** the Raven capability verifier / human-approval executor in that spec.

### Gaps / assumptions (TB4)

| ID | Gap | Assumption if unreviewed |
|----|-----|--------------------------|
| G19 | RDAP ↛ raven-node ATSAM | Tasks never enter `EnqueueSealed`. Production Raven confidentiality **does not apply**. |
| G20 | `env_type=4` + zeroed `sender_authentication` on mailbox envelopes | Outer RVN1 auth is vacant; “E2E auth lives INSIDE body sig” (`mesh.py`). A Raven node that later accepts these as capabilities or as signed envelopes will mis-handle them. |
| G21 | `store_tag = SHA-256("rdap-task:" ‖ address)[:16]` | Stable, address-derived, not `K_route` rotating mailbox (`RAVEN_STORE_OBJECT_V1.md`). Linkable and not a Raven polling capability. |
| G22 | Runtime spec vs RDAP implementation | Spec forbids treating model output as authority; RDAP still sends task text to an LLM/tools. Enforcement is signature+pin+path policy, not the AR1–AR12 capability machine. |
| G23 | `--allow-shell` / `--open` | Documented foot-guns; default off. Any default-on change is R3. |
| G24 | Joint Raven↔RDAP threat row missing | O6 (`ninety-day-outcomes.md`) still NOT STARTED on the checklist. |

---

## TB5 — Persistence boundary (SQLite / SQLCipher)

**Cut:** On-disk state vs process memory vs platform secret stores.

| Store | Encryption | Contents | Who opens it |
|-------|------------|----------|--------------|
| `identity.seed` / Keychain / DPAPI / Secret Service | Platform | 32-byte Ed25519 seed | `identity_store.rs` (ash, node, swarm if same data-dir) |
| `queue.sqlite` | **rusqlite bundled SQLite — not SQLCipher in default features** | Outgoing envelopes + inbound seen IDs | `raven-core::queue`; ash **and** node |
| `forward_queue.sqlite` | Same (unencrypted SQLite) | Bridge custody | node `bridge_run`, ash status paths |
| Chat history / stage locks | SQLite | History, staged outbound | `chat_history.rs` |
| Indexed session / prekey lifecycle files | Intended protected store; **production-disabled** | Session/prekey actors | core modules with `PRODUCTION_ENABLED` flags |
| SQLCipher 4.17.0 | Lab feature `full-braid-durable-lab` only | Full Braid durable lab | `full_braid_durable_lab/*`; release must fail closed (`build.rs` comment in core) |
| RDAP replay `*.sqlite` | SQLite, mode `0600` on POSIX | Signature hashes + expiry | `raven_identity.py` `ReplayCache` |
| RDAP `.team/keys` | File; POSIX `0600`; Windows DACL **untested** | Agent Ed25519 | `RavenIdentity.load_or_create` |

| | |
|--|--|
| **Trusted** | OS user + disk encryption + platform keystore. Lab SQLCipher profile guard (when that feature is on). |
| **Untrusted** | Stolen disk without platform unlock; copied `data_dir`; other users if mode bits slip; RDAP Git relay (must not stage keys — allowlist in README). |
| **Must validate** | `0600` / DACL; no seed in logs; WAL schema race handling (`raven-node` comments); SQLCipher profile overrides rejected (`raven-sqlcipher-profile-guard`); RDAP relay exclude `.team/keys` and replay DBs. |
| **Evidence** | `queue.rs`, `IDENTITY_SEED_STORAGE.md`, `node/third_party/sqlcipher-4.17.0/PROVENANCE.md`, RDAP README. |
| **Owners** | #7 / #8 (default SQLite), #5 / #6 (keystore + SQLCipher lab), #17 (hold on calling default queues “encrypted at rest”), #15 (RDAP stores). |
| **THREAT_MODEL** | §3.6 locked device (partial); §3.7 unlocked (out of scope). No dedicated “DBA on the same UID” row. |

### Gaps / assumptions (TB5)

| ID | Gap | Assumption if unreviewed |
|----|-----|--------------------------|
| G25 | Default message queues are **not** SQLCipher | “Persistence boundary (sqlite/sqlcipher)” in the Sprint 0 prompt must not be read as “production uses SQLCipher.” SQLCipher is lab-gated. |
| G26 | Same files opened by ash and raven-node | Multi-process SQLite (WAL) is an implicit concurrency contract — not an ADR. |
| G27 | Swarm mailbox default persist `offline_mailbox_v1.json` | Feature-gated; JSON not SQLCipher (`mailbox.rs` `MAILBOX_DB_FILENAME`). |
| G28 | RDAP replay uses `journal_mode=DELETE` + `secure_delete=ON`, not Raven WAL queues | Two persistence dialects; no shared backup/migration story. |

---

## Role ownership summary

| Boundary | Primary role(s) | Board / second |
|----------|-----------------|----------------|
| TB1 IPC | #7, #1 | #17 if authz |
| TB2 Network | #9, #10, #2 | #12 BLE; #17 errata |
| TB3 Crypto/identity | #5, #6 | Security Board #17; #3 if spec version |
| TB4 RDAP runtime | #14, #15, #4 | #17 if interop security; #6 if identity merge |
| TB5 Persistence | #7, #8, #5 | #17 (encryption claims) |

Architecture Board (#1 chair, #2, #4, #7) owns the *shape* of these cuts. Security Board (#17 chair, #5, #6) owns *whether the cut is adequate*. Eng Management cannot waive R3 no-self-merge (`risk-classes.md`).

---

## Residual risk the Architect is **not** asserting as closed

1. Production E2EE / ACK / replay journals are **held** (`THREAT_MODEL.md` posture table).
2. RDAP confidentiality is **not** Raven E2EE on any current carrier.
3. Local same-UID malware is **out of scope**.
4. Traffic analysis is **out of scope**.
5. Client trees (iOS/Windows) were **not inspectable** in this RAVEN snapshot.

#17 / #6: please confirm or rewrite G1, G13–G16, G19–G21, G25 before this document is cited as an assurance baseline.
