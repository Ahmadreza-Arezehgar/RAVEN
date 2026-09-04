# Living blockers / ownership status — Sprint 0

**As of:** 2026-09-04 ~13:15 Europe/Madrid (Manager actions accepted)  
**Owner:** Eng Program (#2)  
**Audience:** Manager (CEO)  
**Scope:** Ownership freeze only — no feature velocity metrics  
**Repos:** `Raven-ASHCO/RAVEN`, `Raven-ASHCO/raven-distributed-agent-protocol`

---

## Executive snapshot

| Area | State |
|------|--------|
| Org + teams + CODEOWNERS + `main` protection | **DONE** (Raven-ASHCO live today) |
| Required CI checks on `main` | **OPEN** — contexts empty on both repos |
| Specialist path coverage | **PARTIAL** — catch-all `*` + several specialist gaps |
| Team bus factor | **Accepted (bot-only)** — founder sole GitHub member; escalate only if human reviewers added |
| Open PRs | **0** both repos |
| Review-latency baseline | **n=1** (see below) — not yet meaningful |
| Critical path / O6 gate | **M0 ADR only greenlit** (transport-scoped). M1 identity → M2 IPC seal → M3 harness blocked until M0. Flag feature-ahead-of-M0. |

Org-create / personal-account CODEOWNERS blockers from morning audit are **cleared**.

## Manager actions (2026-09-04) — Eng Program owner

1. **B1:** Track with DevSecOps — propose exact required check names **after next green `main` runs**; do **not** enable until names verified. (RAVEN: no post-transfer green runs yet; workflows include Raven Serverless Node, Raven Lab Gates, Raven iOS Protocol, Raven A2A Agent Team, build-raven-windows. RDAP recent success check name: `RDAP selftest`.)
2. **B3:** Ask Crypto + Core for CODEOWNERS line on `node/crates/raven-mlkem768-incremental-ffi/` → `@Raven-ASHCO/crypto` + `@Raven-ASHCO/core`.
3. **B2:** Documented accepted for bot-only org; escalate only if human reviewers added.
4. Continue flagging premature Raven↔RDAP integration PRs while B1/B3 open.
5. Land this board under `docs/engineering/baseline-freeze/` on RAVEN via docs PR.

---

## Open blockers board

| ID | Blocker | Age | Owner (bot / role) | Severity | Notes |
|----|---------|-----|--------------------|----------|-------|
| B1 | Required status checks empty on `main` | 0d (since protection landed) | DevSecOps (#20) + Architect (#1) | High | Protection exists; `checks`/`contexts` = `[]` on RAVEN + RDAP. Workflows exist but not enforced. |
| B2 | Bus factor = 1 on all 12 GitHub teams | 0d | Manager + Eng Program | **Accepted (bot-only org)** | Manager 2026-09-04: accepted for bot-only org for now. Escalate **only** if human reviewers are added. |
| B3 | Crypto FFI crate not specialist-owned | 0d | Crypto ATSAM (#3) + Rust Core (#5) | High (R3-adjacent) | `node/crates/raven-mlkem768-incremental-ffi/` falls to `*` (`architecture`+`release`) only. |
| B4 | FlatBuffer FFI crate not specialist-owned | 0d | Rust Core (#5) + Protocol Spec (#4) | Med | `node/crates/raven-fb-ffi/` → `*` only. |
| B5 | Platform trees missing vs CODEOWNERS | 0d | Apple (#10), Windows (#11) | Med | CODEOWNERS name `/ios-native/`, `/RAVEN-Windows/` but those trees are **absent** on `main`. |
| B6 | No GitHub team for SRE/Perf | 0d | SRE Perf (#19) + Manager | Med | No `@Raven-ASHCO/perf` (or similar). |
| B7 | Review-latency baseline under-sampled | 0d | Eng Program (#2) | Low | Only RAVEN#1 merged; 0 reviews; author==merger. |
| B8 | Sprint 0 checklist rows still mostly NOT STARTED (paper pack) | ~0–1d | Domain leads | Med | Architecture map, trust boundaries, etc. still open in baseline pack. |

**Cleared today:** GitHub Org missing · repos on personal account · no CODEOWNERS · unprotected `main` · no teams.

---

## Ownership matrix (bot → GitHub team → primary paths)

| # | Bot | GitHub team(s) | Primary ownership |
|---|-----|----------------|-------------------|
| 1 | Architect | `architecture` | ADR/docs, default `*`, architecture board |
| 2 | Eng Program | _(none — process)_ | Blockers board, dependency age, review latency, critical path |
| 3 | Crypto ATSAM | `crypto` | ATSAM protocol/*, atsam*/hybrid*, shared-vectors atsam |
| 4 | Protocol Spec | `protocol` | `/protocol/`, wire meaning, SPEC |
| 5 | Rust Core | `core` | `raven-core` (non-crypto slices), `ash` |
| 6 | P2P Network | `network` | `raven-swarm`, bridge/forward_queue |
| 7 | DTN Forward | `network` (+ assurance on queue) | forward_queue / mailbox / store-and-forward semantics |
| 8 | Node IPC | `core` + `identity` | `raven-node` (incl. `ipc_server.rs`), IPC stability |
| 9 | BLE Transport | `transport` (+ apple on BLE) | `ble*` framing/adapters |
| 10 | Apple Platform | `apple` | `/ios-native/` **(path missing)** |
| 11 | Windows Platform | `windows` | `/RAVEN-Windows/` **(path missing)** |
| 12 | CLI DX | `core` / `release` | `node/crates/ash` |
| 13 | RDAP Protocol | `rdap` + `protocol` | RDAP repo protocol + task lifecycle |
| 14 | Python Runtime | `rdap` | `team_agents` server/client/executor/task_store |
| 15 | Identity AuthZ | `identity` | RAVEN_IDENTITY*, device_*/prekey*, `raven_identity.py` |
| 16 | LLM Runtime | `rdap` | `team_agents/llm.py` |
| 17 | Raven↔RDAP | `architecture` + `rdap` + `assurance` | Interop contract; **gates critical path** |
| 18 | Adversarial QA | `assurance` | Fuzz/property/fault; shared-vectors assurance |
| 19 | SRE Perf | **NO TEAM** | Delivery latency / queue depth — **unowned in GitHub** |
| 20 | DevSecOps | `release` + `assurance` | `.github/`, branch protection, SBOM/CI |

Default catch-all on both repos: `@Raven-ASHCO/architecture` + `@Raven-ASHCO/release` (RDAP also `@rdap`).

---

## Unowned / weakly owned paths

| Path | Repo | Effective owners today | Gap |
|------|------|------------------------|-----|
| `node/crates/raven-mlkem768-incremental-ffi/**` | RAVEN | `*` only | Should be `crypto` (+ core) |
| `node/crates/raven-fb-ffi/**` | RAVEN | `*` only | Should be `core` / `protocol` |
| `node/third_party/**` | RAVEN | `*` only | Vendored crypto/sqlite — need `crypto`/`release` eyes |
| `node/adr/**` | RAVEN | `*` (docs ADR is under `/docs/adr/` only) | Align or extend CODEOWNERS |
| `/ios-native/**`, `/RAVEN-Windows/**` | RAVEN | Named but **trees missing** | Create dirs or trim CODEOWNERS |
| Perf / SLO docs & gates | both | none | No team for #19 |

---

## O6 milestone gate (Manager greenlight + Raven↔RDAP dates 2026-09-04)

**Greenlit now:** **M0 only** — ADR 0004 / spec freeze, **transport-scoped** O6.
**Merge gate:** no M1–M3 **production** code until Architect + Crypto + Identity **ack ADR 0004**.

| ID | Name | Window | Owners | Status |
|----|------|--------|--------|--------|
| **M0** | Spec freeze (ADR 0004) | W0–1 | Raven↔RDAP + Architect + Crypto + Identity | **GREENLIT** |
| **M1** | Identity bridge (same RVN1) | W1–3 | Identity + Node IPC + Python Runtime | Blocked on M0 ack |
| **M2** | Sealed carrier via IPC/LanDial | W3–6 | Node IPC + Crypto + RDAP Protocol + Python Runtime | Blocked on M1 |
| **M3** | Two-device encrypted harness | W6–8 | Adversarial QA + SRE + **Eng Program** + CLI DX | Blocked on M2 |
| **M4** | Deprecate confidential claims for plaintext carriers | ∥ M3 | RDAP Protocol + Assurance | Parallel w/ M3; not separately greenlit |

**Stretch:** production mailbox offline leg **after** M3 green.

**Eng Program watch:** flag M1–M3 production / feature work before ADR 0004 ack; escalate blocked-dependency age; M3 harness coordination.

---

## Critical path — RDAP integration → identity → ATSAM → IPC

Order is hard dependency. **Do not claim production Raven↔RDAP integration until lower layers are owned + CI-gated.**

Fake-integration watch: any PR that wires RDAP tasks to production raven-node ATSAM sessions while B1 or B3 remain open → Eng Program flags as premature.

---

## Review-latency baseline (Sprint 0)

| Metric | Value | Sample |
|--------|-------|--------|
| Open PRs | 0 | both repos |
| Merged PRs sampled | 1 | RAVEN#1 docs baseline freeze |
| Time-to-merge (create→merge) | **~3.4 min** | 10:49:18Z → 10:52:42Z |
| Approving reviews | **0** | author merged |

**Baseline declaration:** review latency **undefined / insufficient sample**. Exclude self-merges from SLA.

---

## Protection / governance checklist (live)

| Control | RAVEN | RDAP |
|---------|-------|------|
| Under `Raven-ASHCO` | Yes | Yes |
| `.github/CODEOWNERS` | Yes | Yes |
| Required CI contexts | **None** | **None** |
| Code owner reviews required | Yes | Yes |
| `enforce_admins` | Yes | Yes |

---

## Next actions

1. **DevSecOps (#20) + Eng Program:** after next green `main` runs, propose exact required check names; **do not enable** until verified (B1).
2. **Crypto (#3) + Core (#5):** CODEOWNERS line for `raven-mlkem768-incremental-ffi` → crypto+core (B3).
3. **B2:** accepted for bot-only org; escalate only if human reviewers added.
4. **Eng Program:** flag premature Raven↔RDAP integration PRs while B1/B3 open; weekday 09:00 Madrid refresh.
5. **Apple/Windows:** skeleton trees or trim dead CODEOWNERS globs (B5).
6. **Manager + SRE:** add `perf` team or fold #19 into assurance/release (B6).
