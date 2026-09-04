# Living blockers / ownership status — Sprint 0

**As of:** 2026-09-04 ~13:45 Europe/Madrid (Eng Program refresh after rebase onto latest `main`)  
**Owner:** Eng Program (#2)  
**Audience:** Manager (CEO)  
**Scope:** Ownership freeze only — no feature velocity metrics  
**Repos:** `Raven-ASHCO/RAVEN`, `Raven-ASHCO/raven-distributed-agent-protocol`

---

## Manager SoT (accepted 2026-09-04)

1. SRE honesty map + bar: Delivered+ACK+dedup+opaque; ≥2 OS or WAIVE; no CI≠hardware conflation.
2. DTN Bridge claim: opaque custody + cooperative hop/repl/TTL + sealed-ACK-only — Forwarded≠Delivered.
3. Direct internet: localhost/LAN + fail-closed ≠ WAN claim (P2P).
4. Terminal #1: Win named-pipe/MSVC + CLI DX doctor/install/send evidence.
5. Try-phase: consolidate executed green/red only (linked CI or agent smoke). Docs-only ≠ Proven.

## Founder rules (try phase = execute)

**Try-phase = execute:** consolidate **executed green/red only** (linked CI or agent smoke). **Docs-only ≠ Proven.** Applies to **terminal reliability** and the **three paths** (`mesh` | `bridge` | `direct`). See [`three-path-verification-board.md`](three-path-verification-board.md).

**Founder Priority #1:** Terminal Win / macOS / Linux reliability **and** the three-path matrices sit **above O6 M1+**. **Do not schedule M1 eng until the terminal board is green** (CEO override only).

---

## Executive snapshot

| Area | State |
|------|--------|
| Org + teams + CODEOWNERS + `main` protection | **DONE** (Raven-ASHCO live) |
| Required CI checks on `main` | **OPEN (B1)** — contexts still empty; RAVEN#19 CI-align is draft; **do not enable** until green + Manager GO |
| Specialist path coverage | **PARTIAL** — B3 **CLEARED** (RAVEN#7); B4 FlatBuffer FFI still `*` |
| Team bus factor | **Accepted (bot-only)** — founder sole GitHub member; escalate only if human reviewers added |
| Founder Priority #1 | Terminal L/M/W + three-path matrices **above** O6 M1+ |
| Critical path / O6 gate | **M0 ack gate ✅** — Architect M0 gate **CLOSED** (full ACK: body + G5 + HOLD/R3/IPC + Crypto D4; three-way Architect + Crypto + Identity) on [RAVEN#3](https://github.com/Raven-ASHCO/RAVEN/pull/3). **No Architect BLOCK. Do not await Architect re-ACK.** Docs merge = **Manager**. **No M1 code.** |
| Performance baseline | **#19 SRE Perf** — IN PROGRESS (harvest; docs-only ≠ Proven) |
| Menu-smoke | Sole CI via RAVEN#16 (Apple APPROVE + Core ACK); converge DONE with SRE; **Proven flip only after executed green** (linked CI or agent smoke) |

Org-create / personal-account CODEOWNERS blockers from morning audit are **cleared**. **B3 cleared** via merged RAVEN#7.

---

## Manager / Eng Program actions (current)

1. **B1:** RAVEN#19 CI-align **open (draft)**. Provisional pin set **after** next green `main` / PR runs. **Do not enable** required checks until names verified green **and** Manager GO.
2. **B3 CLEARED:** merged RAVEN#7 — `node/crates/raven-mlkem768-incremental-ffi/` → `@Raven-ASHCO/crypto` + `@Raven-ASHCO/core`.
3. **B2:** Accepted for bot-only org; escalate only if human reviewers added.
4. **Terminal first:** do not schedule M1 eng until terminal board green (CEO override only). Flag premature Raven↔RDAP / M1–M3 production PRs.
5. **Menu-smoke merge order:** #20 **done** → land #16 when green → #19 rebases **preserving** menu-smoke.
6. Keep this board under `docs/engineering/baseline-freeze/` (this PR). **M0 docs merge = Manager.** Architect M0 gate is **CLOSED** — do **not** await Architect re-ACK.

---

## CLI DX in-flight

| Track | Status | PR / next | Notes |
|-------|--------|-----------|-------|
| Windows MSVC `ash` `Command` ungate (compile P0-1) | **DONE / MERGED** via [RAVEN#20](https://github.com/Raven-ASHCO/RAVEN/pull/20) + [RAVEN#21](https://github.com/Raven-ASHCO/RAVEN/pull/21) | #20 + #21 on `main` | **Do not greenlight duplicate compile fixes.** Compile ungate only — docs/helpers **not** e2e-proven. |
| Menu-smoke (Linux + macOS) | In flight | [RAVEN#16](https://github.com/Raven-ASHCO/RAVEN/pull/16) | Apple APPROVE + Core ACK; SRE converge DONE. **Proven flip only after executed green** (linked CI or agent smoke). |
| `install.sh` fail-close (B11) | In flight (draft) | [RAVEN#17](https://github.com/Raven-ASHCO/RAVEN/pull/17) | Hazard retire / fail-close. **Not** install Proven. |
| Core doctor axes (presence / ready / send_path) | In flight | [RAVEN#22](https://github.com/Raven-ASHCO/RAVEN/pull/22) | `ash doctor` exit 0 ≠ send Proven. |
| Doctor identity-backend mismatch | In flight | [RAVEN#23](https://github.com/Raven-ASHCO/RAVEN/pull/23) | Identity usable / `daemon_ready` honesty. |
| Named-pipe IPC + install→doctor→send CI | **Open P0** (remaining B10) | B10 | Remaining B10 after compile P0-1 **DONE**. Docs/helpers **not** e2e-proven. |
| Win loopback `127.0.0.1:7420` | Excluded (B12) | — | Loopback ≠ WAN / named-pipe / terminal Proven. |

---

## Open blockers board

| ID | Blocker | Age | Owner (bot / role) | Severity | Notes |
|----|---------|-----|--------------------|----------|-------|
| B1 | Required status checks empty on `main` | 0d (since protection landed) | DevSecOps (#20) + Architect (#1) | High | Protection exists; `checks`/`contexts` = `[]` on RAVEN + RDAP. RAVEN#19 CI-align **open (draft)**. Provisional pin after green; **not enabling** until green + Manager GO. |
| B2 | Bus factor = 1 on all 12 GitHub teams | 0d | Manager + Eng Program | **Accepted (bot-only org)** | Escalate **only** if human reviewers are added. |
| B3 | Crypto FFI crate not specialist-owned | — | Crypto ATSAM (#3) + Rust Core (#5) | **CLEARED** | **CLEARED** via merged [RAVEN#7](https://github.com/Raven-ASHCO/RAVEN/pull/7) — `raven-mlkem768-incremental-ffi` → `crypto` + `core`. |
| B4 | FlatBuffer FFI crate not specialist-owned | 0d | Rust Core (#5) + Protocol Spec (#4) | Med | `node/crates/raven-fb-ffi/` → `*` only. |
| B5 | Platform trees missing vs CODEOWNERS | 0d | Apple (#10), Windows (#11) | Med | `/ios-native/`, `/RAVEN-Windows/` **absent** on `main` (gap notes #8 / #10). |
| B6 | No GitHub team for SRE/Perf | 0d | SRE Perf (#19) + Manager | Med | No `@Raven-ASHCO/perf` (or similar). |
| B7 | Review-latency baseline under-sampled | 0d | Eng Program (#2) | Low | Early sample was RAVEN#1 self-merge. More PRs merged today; **SLA still undefined** — exclude self-merges. Do not invent latency numbers here. |
| B8 | iOS / Apple tree landing (Phase 1+) | — | Apple (#10) + Eng Program | **PARKED** | **Phase 1+ PARKED** — Windows terminal **>** iOS landing this phase. See `apple-tree-gap.md`. |
| B10 | Windows terminal path — remaining P0 after compile | 0d | Windows (#11) + CLI DX (#12) + SRE Perf (#19) | High (Priority #1) | **Compile P0-1 DONE** — [RAVEN#20](https://github.com/Raven-ASHCO/RAVEN/pull/20) **and** [RAVEN#21](https://github.com/Raven-ASHCO/RAVEN/pull/21) **MERGED**. **Do not greenlight duplicate compile fixes.** **#21 is not CI-held.** Remaining open P0 = **named-pipe IPC** + **install→doctor→send CI**. Docs/helpers still **not** e2e-proven. |
| B11 | `install.sh` hazard | 0d | CLI DX (#12) + DevSecOps (#20) | High | [RAVEN#17](https://github.com/Raven-ASHCO/RAVEN/pull/17) (draft) — fail-close install path. **Not** install evidence; docs/PR ≠ Proven. |
| B12 | Win loopback `127.0.0.1:7420` | 0d | Windows (#11) + Node IPC (#8) | Med | Loopback bind/listen is **not** WAN / named-pipe Proven. Docs-only ≠ Proven. |

**Cleared:** GitHub Org missing · repos on personal account · no CODEOWNERS · unprotected `main` · no teams · **B3** (RAVEN#7) · **M0 ack gate ✅** (Architect M0 **CLOSED** — full ACK body+G5+HOLD/R3/IPC+Crypto D4 on RAVEN#3) · **B10 compile P0-1** (RAVEN#20 + #21 MERGED).

---

## Ownership matrix (bot → GitHub team → primary paths)

| # | Bot | GitHub team(s) | Primary ownership |
|---|-----|----------------|-------------------|
| 1 | Architect | `architecture` | ADR/docs, default `*`, architecture board |
| 2 | Eng Program | _(none — process)_ | Blockers board, dependency age, review latency, critical path |
| 3 | Crypto ATSAM | `crypto` | ATSAM protocol/*, atsam*/hybrid*, shared-vectors atsam, **mlkem incremental FFI (B3 cleared)** |
| 4 | Protocol Spec | `protocol` | `/protocol/`, wire meaning, SPEC |
| 5 | Rust Core | `core` | `raven-core` (non-crypto slices), `ash`, mlkem FFI (with crypto) |
| 6 | P2P Network | `network` | `raven-swarm`, bridge/forward_queue |
| 7 | DTN Forward | `network` (+ assurance on queue) | forward_queue / mailbox / store-and-forward semantics |
| 8 | Node IPC | `core` + `identity` | `raven-node` (incl. `ipc_server.rs`), IPC stability |
| 9 | BLE Transport | `transport` (+ apple on BLE) | `ble*` framing/adapters |
| 10 | Apple Platform | `apple` | `/ios-native/` **(path missing; B8 Phase 1+ PARKED)** |
| 11 | Windows Platform | `windows` | `/RAVEN-Windows/` **(path missing)**; terminal path is Priority #1 (B10) |
| 12 | CLI DX | `core` / `release` | `node/crates/ash` |
| 13 | RDAP Protocol | `rdap` + `protocol` | RDAP repo protocol + task lifecycle |
| 14 | Python Runtime | `rdap` | `team_agents` server/client/executor/task_store |
| 15 | Identity AuthZ | `identity` | RAVEN_IDENTITY*, device_*/prekey*, `raven_identity.py` |
| 16 | LLM Runtime | `rdap` | `team_agents/llm.py` |
| 17 | Raven↔RDAP | `architecture` + `rdap` + `assurance` | Interop contract; **gates critical path** |
| 18 | Adversarial QA | `assurance` | Fuzz/property/fault; shared-vectors assurance |
| 19 | SRE Perf | **NO TEAM** | Delivery latency / queue depth / **Performance baseline** / reliability evidence bar — **unowned as a GitHub team** |
| 20 | DevSecOps | `release` + `assurance` | `.github/`, branch protection, SBOM/CI |

Default catch-all on both repos: `@Raven-ASHCO/architecture` + `@Raven-ASHCO/release` (RDAP also `@rdap`).

---

## Unowned / weakly owned paths

| Path | Repo | Effective owners today | Gap |
|------|------|------------------------|-----|
| `node/crates/raven-mlkem768-incremental-ffi/**` | RAVEN | `crypto` + `core` | **B3 CLEARED** (RAVEN#7) |
| `node/crates/raven-fb-ffi/**` | RAVEN | `*` only | Should be `core` / `protocol` (B4) |
| `node/third_party/**` | RAVEN | `*` only | Vendored crypto/sqlite — need `crypto`/`release` eyes |
| `node/adr/**` | RAVEN | `*` (docs ADR is under `/docs/adr/` only) | Align or extend CODEOWNERS |
| `/ios-native/**`, `/RAVEN-Windows/**` | RAVEN | Named but **trees missing** | B8 Phase 1+ **PARKED**; B5 / B9 landing later |
| Perf / SLO docs & gates | both | none (no `perf` team) | No GitHub team for #19 |

---

## O6 milestone gate (M0 / RAVEN#3)

**M0 ack gate ✅.** Architect M0 gate is **CLOSED** — **full ACK** (ADR **body** + Appendix **G5** + **HOLD/R3/IPC** + Crypto **D4**). Three-way Architect + Crypto + Identity on merged [RAVEN#3](https://github.com/Raven-ASHCO/RAVEN/pull/3).

**No Architect BLOCK. Do not await Architect re-ACK.** Docs merge = **Manager**. **No M1 code.**

**Still closed:** M1–M3 **production** code until the **terminal-path board is green** (CEO override only). M0 ack ✅ ≠ terminal Proven ≠ license to land M1–M3 production code.

| ID | Name | Window | Owners | Status |
|----|------|--------|--------|--------|
| **M0** | Spec freeze (ADR 0004) | W0–1 | Raven↔RDAP + Architect + Crypto + Identity | **✅ CLOSED** — full ACK body+G5+HOLD/R3/IPC+Crypto D4; docs merge = Manager |
| **M1** | Identity bridge (same RVN1) | W1–3 | Identity + Node IPC + Python Runtime | **No M1 code.** No M1–M3 production code until terminal-path board green |
| **M2** | Sealed carrier via IPC/LanDial | W3–6 | Node IPC + Crypto + RDAP Protocol + Python Runtime | Blocked on M1 |
| **M3** | Two-device encrypted harness | W6–8 | Adversarial QA + SRE + **Eng Program** + CLI DX | Blocked on M2 |
| **M4** | Deprecate confidential claims for plaintext carriers | ∥ M3 | RDAP Protocol + Assurance | Parallel w/ M3; not separately greenlit |

**Stretch:** production mailbox offline leg **after** M3 green.

**Eng Program watch:** flag M1–M3 production / feature work; escalate blocked-dependency age; M3 harness coordination stays after terminal Priority #1.

---

## Critical path — terminal board → RDAP integration → identity → ATSAM → IPC

**Order is hard dependency.** Terminal Win/macOS/Linux reliability + three-path matrices **before** O6 M1+.

**Do not claim production Raven↔RDAP integration until lower layers are owned + CI-gated + Proven** (linked green CI or agent-executed smoke). Docs-only ≠ Proven.

Fake-integration watch: any PR that wires RDAP tasks to production raven-node ATSAM sessions, or lands M1–M3 **production** code, while B1 remains open **or** terminal board is not green → Eng Program flags as premature.

---

## Menu-smoke / terminal CI sequence

| Item | State |
|------|--------|
| Sole menu-smoke CI | [RAVEN#16](https://github.com/Raven-ASHCO/RAVEN/pull/16) — Apple **APPROVE** + Core **ACK**; converge **DONE** with SRE |
| Proven flip | **Only** after executed green/red recorded (linked CI or agent smoke). Docs-only ≠ Proven. |
| Merge order | #20 + #21 **MERGED** (compile P0-1 **DONE**) → land #16 **when green** → #19 rebases **preserving** menu-smoke |
| B10 remaining open P0 | **named-pipe IPC** + **install→doctor→send CI**. Docs/helpers **not** e2e-proven. **Do not greenlight duplicate compile fixes.** |
| #21 | **MERGED** with #20 — **not** CI-held. Compile P0-1 closed. |

---

## Review-latency baseline (Sprint 0)

| Metric | Value | Sample |
|--------|-------|--------|
| Early merged-PR sample | 1 | RAVEN#1 docs baseline freeze (author==merger, 0 reviews) |
| Approving reviews on that sample | **0** | author merged |
| Later `main` merges | several Sprint 0 docs/governance PRs | **Do not invent** new time-to-merge numbers here |

**Baseline declaration:** review latency **undefined / insufficient sample**. Exclude self-merges from SLA.

---

## Protection / governance checklist (live)

| Control | RAVEN | RDAP |
|---------|-------|------|
| Under `Raven-ASHCO` | Yes | Yes |
| `.github/CODEOWNERS` | Yes (B3 line live) | Yes |
| Required CI contexts | **None** (B1; #19 draft — do not enable) | **None** |
| Code owner reviews required | Yes | Yes |
| `enforce_admins` | Yes | Yes |

---

## Next actions

1. **DevSecOps (#20) + Eng Program:** RAVEN#19 draft CI-align; provisional pin **after green**; **do not enable** required checks until verified + Manager GO (B1).
2. **B3:** **CLEARED** (RAVEN#7). No further CODEOWNERS action on mlkem FFI.
3. **B2:** accepted for bot-only org; escalate only if human reviewers added.
4. **Founder Priority #1:** terminal L/M/W + three-path matrices; **no M1 eng** until terminal board green (CEO override only).
5. **Menu-smoke:** land #16 when green; #19 rebases preserving menu-smoke; Proven only after executed green (linked CI or agent smoke).
6. **B10:** compile P0-1 **DONE** (#20 + #21 MERGED). Remaining open P0 = named-pipe IPC + install→doctor→send CI. **Do not greenlight duplicate compile fixes.** Docs/helpers still not e2e-proven.
7. **B11 / B12:** track #17 fail-close; do not treat `install.sh` or Win loopback `127.0.0.1:7420` as Proven.
8. **B8 Phase 1+ PARKED** (Windows terminal > iOS landing).
9. **SRE Perf (#19):** Performance baseline remains #19; harvest in flight — docs-only ≠ Proven.
10. **Apple/Windows trees:** B5 remains; B8 parked. **Manager + SRE:** `perf` team or fold #19 (B6).
