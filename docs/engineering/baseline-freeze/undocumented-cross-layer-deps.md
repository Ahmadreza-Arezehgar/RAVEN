# Undocumented / Implicit Cross-Layer Dependencies

**Status:** Architect inventory (Sprint 0)  
**Owner:** #1 (draft); items assign recommended owners — not a CODEOWNERS change  
**Date:** 2026-09-04  
**Method:** Cargo.toml edges, module imports, RDAP `main` via GitHub API, ADRs, MESH/SERVERLESS/THREAT_MODEL. No runtime tracing.

Each row is a coupling that is **real in code or docs** but **not** captured as an allowed edge in a published architecture map (this Sprint 0 map is the first). “Propose” is the cheapest durable fix — not work authorized by this PR.

Legend for **Propose:** `document` = specify in protocol/docs; `ADR` = needs a numbered decision; `CODEOWNERS` = path-owner gap (do **not** edit CODEOWNERS in this PR; Manager already applied live files); `none` = accept as implicit, track only here.

---

## Inventory

| ID | From → To | Evidence | Risk | Recommended owner | Propose |
|----|-----------|----------|------|-------------------|---------|
| D1 | RDAP `mesh.py` → RVN1 `env_type=4` as “application/opaque” | RDAP `team_agents/mesh.py` `env_type=4` comment; frozen registry `protocol/RAVEN_ENVELOPE_V1.md` §3 and `raven-core` `EnvType::Capabilities = 4` | **R3** — RDAP mailbox objects are indistinguishable from capabilities envelopes; a future node ingest could apply the wrong inner parser or accept unsigned outer auth (`sender_authentication = 64 × 0x00`) | #2 + #14 + #4 | **ADR** (0006 in framework backlog) + protocol errata or reserved type |
| D2 | RDAP mailbox `store_tag` → address hash, not `K_route` mailbox | `mesh.py` `store_tag = sha256(b"rdap-task:" + peer_address)[:16]`; spec `protocol/RAVEN_STORE_OBJECT_V1.md` §2 (`HMAC` + daily rotate); Rust `store_object.rs` `mailbox_tag` | **R3** — stable, linkable store index; violates “MUST NOT use permanent stable recipient tags” if these objects ever hit a Raven store | #4 + #10 + #6 | **ADR** + **document** (RDAP must not reuse RSO1 polling namespace) |
| D3 | RDAP → `raven-swarm-mailbox-experimental` binary, not raven-node | `mesh.py` `BIN_NAME`, `build_swarm_bin()`; RDAP README “Important integration gap” | **R2** — operators infer “A2A over Raven Node”; actual path is a security-held experimental swarm bin | #4 + #15 | **document** (done in architecture map); **ADR** before any default-on |
| D4 | RDAP `mesh.py` → clones `Ahmadreza-Arezehgar/RAVEN` | `mesh.py` `_node_sources()` `git clone --depth 1 https://github.com/Ahmadreza-Arezehgar/RAVEN.git` | **R2** — wrong org, unsigned source of a transport binary; supply-chain | #14 + #20 + #17 | **CODEOWNERS** N/A (RDAP file); **document** + later **CODE** in RDAP (out of scope here) |
| D5 | RDAP `protocol/reference/` → vendored RAVEN codecs | RDAP README “kept byte-identical… do not edit it here”; RDAP tree has the same module list including Full Braid / PairInit | **R2** (drift = **R3** if vectors diverge) — two SoTs; no hash pin in either README | #3 + #14 | **document** (sync procedure + hash); optional CI; not CODEOWNERS unless a `shared-vectors` submodule is added |
| D6 | RDAP `raven_identity` → `raven_protocol.address` / `fingerprint` / `_canon.lp` | `team_agents/__init__.py` `_bootstrap_protocol_path`; `raven_identity.py` imports | **R2** — RDAP signing contexts (`raven.a2a.delegation.v2`, `raven.a2a.http-request.v1`) sit on RVN1 address math but are **absent** from `protocol/SPEC.md` | #14 + #2 + #3 | **document** (new `protocol/` or RDAP spec); **ADR** if claimed as Raven wire |
| D7 | RDAP identity store → `.team/keys` (not `identity_store`) | RDAP README; `RavenIdentity.load_or_create(keys_dir)` | **R3** if marketed as the same user; **R2** as accidental dual-principal | #6 + #15 | **ADR** (0007) |
| D8 | `ash` → `queue.sqlite` / `contacts.json` / `forward_queue.sqlite` **and** UDS IPC | `ash` `cli.rs` / `ext.rs` open the same filenames `raven-node` uses (`queue_path`, `bridge_run.rs`) | **R2** — TB1 is not the exclusive consistency boundary; WAL multi-writer; policy/contacts can race the daemon | #7 | **document** (concurrency contract); **ADR** if ash must become IPC-only |
| D9 | `ash` → spawn `raven-node` sibling binary | `ext.rs` `raven_node_bin()` = `current_exe().parent()/raven-node`; `ensure_mac_lan_daemon` | **R1–R2** — implicit install layout; PATH vs adjacent-bin; Windows service docs differ | #7 + #19 | **document** |
| D10 | `ash` + `raven-node` + `raven-swarm` → same `identity_store` if `data_dir` shared | `IDENTITY_SEED_STORAGE.md`; swarm `load_or_create_identity`; ash/node same APIs | **R3** — swarm derivation of libp2p key from seed (`main.rs` `libp2p_keypair_from_raven`) means **read access to the Raven seed** by the swarm process | #6 + #9 + #5 | **ADR** (seed vs transport-key isolation) + **document** |
| D11 | `raven-swarm` → domain-separated PeerId from Raven seed | `raven-swarm/src/main.rs` `SHA-256(b"raven/libp2p-peer-key/v1" \|\| seed)` | **R2** — documented in comments, not in ADR 0003 beyond “peer id separate.” Compromise of swarm process = seed in memory | #5 + #9 | **document** in IDENTITY + **ADR** if seed must never enter swarm |
| D12 | Duplicate ADRs `docs/adr/*` and `node/adr/*` | Both trees have 0001–0003 with the same titles | **R1** — review/CI may cite different paths; drift risk | #1 + #20 | **document** (framework §3); later R0 pointer PR — **not** CODEOWNERS |
| D13 | Windows IPC framing shared, client missing | `WINDOWS_SERVICE.md`; `ipc.rs` “UDS / named pipe payload”; ash UDS is `#[cfg(unix)]` | **R2** — Windows users get `--send-stdin` spawn (plaintext to child argv-adjacent stdin) | #13 + #7 | **document** (done in trust TB1); CODE later |
| D14 | Lab FFI → `raven-core` Full Braid / ML-KEM | `raven-fb-ffi`, `raven-mlkem768-incremental-ffi`; comments “Swift XCTest binder” | **R3** if linked in Release (mitigated by `compile_error!`); **R2** implicit iOS build graph **UNKNOWN** here | #5 + #12 + #8 | **document**; **CODEOWNERS** already has `ios-native/` and `atsam*` — FFI crates sit under `/node/crates/` **core** only |
| D15 | FFI crates not in default-members vs workspace members | `node/Cargo.toml` `members` includes FFI; `default-members` is core/node/swarm/ash | **R1** — easy to `cargo test --workspace` pull lab features | #8 + #20 | **document** |
| D16 | `THREAT_MODEL.md` → `ios-native/RAVEN/Libp2pBridge/bridge.go:135` | Citation in §3.4; tree **absent** from this checkout | **R2** — assurance cites a file reviewers cannot see in RAVEN-only clone | #12 + #17 + #9 | **document** (sparse-checkout / repo split honesty) |
| D17 | `CONTRIBUTING.md` → `ios-native/RAVEN/RAVEN.xcodeproj` and `server/` FastAPI | File in repo root; those directories **absent** | **R1** — onboarding implies a monorepo layout that this snapshot is not | #20 | **document** |
| D18 | CODEOWNERS → `/ios-native/`, `/RAVEN-Windows/` | `.github/CODEOWNERS` | **R1** — owners for empty paths; no review trigger until trees exist | #20 + #12 + #13 | **none** until trees land (Manager: CODEOWNERS already live) |
| D19 | Legacy MESH JSON GATT vs RVN1 `RBF1` | `docs/MESH_PROTOCOL.md` vs `protocol/RAVEN_BLE_FRAMING_V1.md` | **R2–R3** — two BLE framings; iOS flag OFF stays MeshEnvelope | #2 + #12 + #10 | **document** (already dual-spec); **ADR** before retiring MESH JSON |
| D20 | BLE service UUIDs only in MESH_PROTOCOL | `docs/MESH_PROTOCOL.md` §A `12345678-1234-1234-1234-123456789ABC`; `raven-core/src/ble_adapter.rs` has **no** GATT UUID / `RBF1` string (framing helpers only); `RAVEN_BLE_FRAMING_V1.md` does not restate the UUID | **R2** — hardware UUID lives in the legacy MESH doc, not the RVN1 BLE spec | #10 + #12 | **document** (copy UUID into BLE V1 or explicitly “legacy only”) |
| D21 | Shared LAN port `7420` / BLE `7421` | `paths.rs` `DEFAULT_LAN_LISTEN`; ash `DEFAULT_LAN_PORT`; `DEFAULT_BLE_LISTEN` | **R1** — magic numbers in two crates; conflict with other local software undocumented | #7 | **none** (or document in install notes) |
| D22 | Shared 1 MiB envelope / 256 KiB IPC vs RDAP 256 KiB RPC | `envelope.rs` `MAX_WIRE_ENVELOPE_BYTES`; `ipc.rs` `MAX_IPC_FRAME`; RDAP README `TEAM_MAX_RPC_BODY_BYTES` default 256 KiB; `mesh.py` `MAX_MAILBOX_OBJECT_BYTES = 1_048_576 + 59 + 64` | **R1** — parallel limits, not one constant; a raise on one side will desync | #2 + #14 + #11 | **document** |
| D23 | RDAP mailbox object size copies swarm comment | `mesh.py` “raven-swarm: MAX_ENVELOPE_LEN + 59-byte RSO1 + 64-byte custody”; `mailbox.rs` `MAX_STORE_OBJECT_WIRE_BYTES` | **R2** — duplicated protocol numbers without a shared crate/header | #3 + #14 | **document** (pin in `RAVEN_STORE_OBJECT_V1.md` — already 1 MiB; add prefix lengths) |
| D24 | Kad / mailbox protocol IDs only in Rust | `/raven/kad/1.0.0`, `/raven/offline-mailbox/1.0.0` in swarm sources; mailbox also in `RAVEN_MAILBOX_TRANSPORT_V1.md` | **R2** if RDAP or clients hardcode strings (mesh uses the **binary**, not the protocol id) | #9 + #2 | **none** for RDAP today; **document** if a second implementation appears |
| D25 | `PRIMARY_DEVICE_ID = "ash-primary"` used by core LAN/prekey | `paths.rs`; `lan_dispatch.rs` via `PRIMARY_DEVICE_ID` | **R2** — CLI product name baked into core device-id; Windows/iOS **UNKNOWN** | #6 + #7 | **document** |
| D26 | `RAVEN_DATA_DIR` / `ASH_DATA_DIR` / `~/.raven` vs `~/.raven-ash` | `paths.rs` `default_raven_data_dir` | **R1** — implicit profile migration | #7 | **document** (install + identity docs) |
| D27 | Workspace `[patch.crates-io] libsqlite3-sys` → raven fork | `node/Cargo.toml`; `third_party/libsqlite3-sys-raven` | **R2–R3** if a crate outside `node/` expected stock rusqlite | #8 + #5 | **document** (already in Cargo comments); live `.github/CODEOWNERS` has **no** `third_party/` line (do not edit in this PR) |
| D28 | SQLCipher lab feature unification vs default rusqlite | `raven-core` features `full-braid-durable-lab`; default `queue.rs` unencrypted | **R3** if release notes say “SQLCipher at rest” | #5 + #17 | **ADR** (0008) |
| D29 | `unsafe-demo-crypto` feature plumbing ash → core and node → core | `ash/Cargo.toml`, `raven-node/Cargo.toml` | **R3** if enabled in a shipping binary | #5 + #19 | **none** (feature + errata exist); release check is #19 |
| D30 | RDAP HTTP `:9001` / invite URL → not in Raven SPEC | RDAP README smoke; `rdap.py` wizard | **R2** — new internet-facing service beside raven-node `:7420` | #14 + #9 + #17 | **document** (port collision + firewall); **ADR** if it becomes a Raven-supported carrier |
| D31 | RDAP Git relay → GitHub/remote as store | README `relay-setup`; `team_agents/relay.py` | **R2** — third-party repo operator sees signed task JSON; not a Raven store node | #14 + #17 | **document** (honest TM row) |
| D32 | RDAP LLM providers → hosted HTTPS | `config.py` `LLM_PROVIDER_ENDPOINTS`; README | **R2** — plaintext leaves any Raven E2EE (runtime spec §0.1); implicit data-plane | #15 + #17 | **document** |
| D33 | Agent runtime spec → not wired to RDAP or raven-node | `protocol/RAVEN_USER_OWNED_AGENT_RUNTIME_V1.md` never mentions RDAP/IPC; status NOT YET APPROVED | **R2** — two “agent” stories | #4 + #15 + #1 | **ADR** + **document** |
| D34 | `RAVEN_USER_OWNED_AGENT_RUNTIME_V1` approval prereqs → five other unapproved V2/V1 drafts | Header of that spec | **R1** for architecture sequencing; **R3** if any is treated as live | #3 + #1 | **none** (already labeled) |
| D35 | Baseline-freeze README links `01-risk-classes.md` etc. | `docs/engineering/baseline-freeze/README.md` vs actual `risk-classes.md`, `sprint0-checklist.md` | **R0** — broken in-folder links; not a runtime dep | #1 | **document** (fix in a later R0 PR; not this map’s job unless we choose to) |
| D36 | Checklist cites `03-role-charters.md`, `artifacts/` | `sprint0-checklist.md` Component ownership / CODEOWNERS rows | **R0** — files **absent** in this snapshot | #1 / Eng Mgmt | **none** here |
| D37 | `messaging_path` / `ENV_SERVERLESS_RVN1` / FastAPI fail-closed | `messaging_path.rs`; `MIGRATION_SERVERLESS_V1.md` | **R2** — env flags are a hidden API across ash and core | #7 + #2 | **document** |
| D38 | PairInit lab in `ash` → core pair_init + IPC LanDial | `ash/src/pair_init_lab.rs`; production-disabled flags in core | **R3** if lab path can be reached without flags | #5 + #16 | **document** (experimental list — checklist row still NOT STARTED) |
| D39 | `raven-node` `corebluetooth` feature → Apple radio | `raven-node/Cargo.toml`; `corebluetooth_exp.rs` | **R2** — daemon growing a platform BLE seam; iOS is the hardware SoT today | #12 + #10 | **ADR** before default-on |
| D40 | Shared-vectors + Python reference as the **de facto** FFI contract for Swift/Dart | `protocol/SPEC.md`; README “Rust ⇄ Swift ⇄ Dart” | **R2** — clients embed core assumptions via vectors, not crates (correct) but **UNKNOWN** Dart/Swift trees | #3 + #18 | **none** (intended); flag missing trees |
| D41 | RDAP `ReplayCache` SQLite vs Raven `seen_inbound` | `raven_identity.py`; `queue.rs` `seen_inbound` | **R2** — two replay journals; a unified carrier must not double-accept | #4 + #7 + #6 | **ADR** when merging paths |
| D42 | RDAP Bearer token envs vs Raven IPC (no tokens) | RDAP README `TEAM_AUTH_TOKEN`, `RDAP_BEARER_TOKEN`; Raven IPC is peer-cred only | **R2** — different local authz theories | #15 + #7 + #17 | **document** |
| D43 | `scan_profile` / SQLCipher guard as build-time dep of sqlite patch | `raven-sqlcipher-profile-guard`; `libsqlite3-sys-raven` | **R1** — third_party coupling not in architecture map before now | #8 | **none** |
| D44 | Watch client | No path in RAVEN or RDAP trees | **UNKNOWN** | #12 | **none** until a tree exists |
| D45 | `docs/THREAT_MODEL.md` “`raven-security/THREAT_MODEL.md` historical” | Mentioned in header | **UNKNOWN** whether that tree exists anywhere | #17 | **document** |

---

## Patterns (not extra items)

1. **Dual SoT:** protocol numbers and reference codecs are copied (RDAP vendor, `mesh.py` constants, `node/adr` mirrors) instead of depended on.
2. **Dual principal:** RVN1 *address format* is reused by RDAP without the raven-node *keystore or ATSAM session*.
3. **Dual persistence:** ash and node share files; RDAP has a third tree (`.team`, replay sqlite).
4. **Cited-but-absent clients:** iOS/Windows/Go bridge/FastAPI appear in CODEOWNERS, CONTRIBUTING, and the threat model but not in this checkout — implicit “monorepo” dependency for reviewers.

---

## Recommended next documents (owners)

| Artifact | Owner | Closes |
|----------|-------|--------|
| ADR 0005–0007 (carrier, env_type, principals) | #1 draft, #4/#5/#6/#14 approve | D1–D3, D7, D10 |
| Raven↔RDAP gaps list (checklist row) | #4, #17, #18 | D3, D6, D31–D33 |
| Experimental-only features list | #2, #14, #10 | D29, D38, D39 |
| Current protocol versions table | #2, #3, #14 | D1, D19, D24 |

No CODEOWNERS edits in this PR (non-goal; live file already on `main`).
