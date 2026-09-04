# Three-path verification board — Sprint 0

**As of:** 2026-09-04 ~13:45 Europe/Madrid (Eng Program)  
**Owner:** Eng Program (#2) · consult SRE Perf (#19), P2P Network (#6), BLE Transport (#9)  
**Scope:** Honesty board for `mesh` | `bridge` | `direct` — **no invented reliability numbers**

Companion: [`blockers-ownership-board.md`](blockers-ownership-board.md) · evidence inventory: [`docs/network/raven-swarm-connectivity-matrix.md`](../../network/raven-swarm-connectivity-matrix.md)

---

## Manager SoT (accepted 2026-09-04)

1. SRE honesty map + bar: Delivered+ACK+dedup+opaque; ≥2 OS or WAIVE; no CI≠hardware conflation.
2. DTN Bridge claim: opaque custody + cooperative hop/repl/TTL + sealed-ACK-only — Forwarded≠Delivered.
3. Direct internet: localhost/LAN + fail-closed ≠ WAN claim (P2P).
4. Terminal #1: Win named-pipe/MSVC + CLI DX doctor/install/send evidence.
5. Try-phase: consolidate executed green/red only (linked CI or agent smoke). Docs-only ≠ Proven.

## Manager Path A lock (2026-09-04)

**Path A (mesh / NAT / relay) is locked.** Honest cells only:

| Cell | Lock |
|------|------|
| Reservation | **localhost only** |
| Two-client circuit | **NOT proven** |
| WAN | **NOT proven** |
| Auto-fallback | **NOT proven** |
| DCUtR | **NOT proven** |
| Hop server | **missing** |
| Multi-NAT | **BLOCKED_HARDWARE** |
| NAT hold | **intact** |

**Do not call mesh relay reliable.** Continue **B** (bridge) + **C** (direct) + **terminal**.

## FOUNDER RULE (try phase = execute)

**Try-phase = execute:** consolidate **executed green/red only** (linked CI or agent smoke). **Docs-only ≠ Proven.**

ADR text, gap notes, matrices, and this board **do not** flip a cell to Proven.

Applies to **terminal reliability** (Win / macOS / Linux) **and** these three paths (`mesh` | `bridge` | `direct`).

---

## Founder Priority #1

Terminal Win / macOS / Linux reliability **and** this three-path matrix sit **above O6 M1+**.

**Do not schedule M1 engineering until the terminal board is green** (CEO override only). M1–M3 production code gate remains **closed** on the blockers board.

---

## Paths (none Proven on this board)

| Path | Honest status | What exists (not Proven) | What would Proven require |
|------|---------------|--------------------------|---------------------------|
| **mesh** (Path A) | **Not Proven** — **locked** | **Path A lock:** localhost reservation only. Two-client circuit / WAN / auto-fallback / DCUtR **NOT proven**. Hop server **missing**. Multi-NAT **BLOCKED_HARDWARE**. NAT hold **intact**. Policy/sim (`network_sim_1000`) + `mock_ble` hygiene ≠ live mesh. **Do not call mesh relay reliable.** | Executed green/red only (linked CI or agent smoke) on a **named** mesh path after the lock lifts. CI ≠ hardware. |
| **bridge** | **Not Proven** | Strongest **software** evidence on `main` (`bridge_v1`, `bridge_abc` / serverless proof scripts). Still **docs/software ≠ Proven** until a linked green CI run or agent-executed smoke is attached to this cell. | Linked green CI URL or agent-executed smoke for the named bridge path. Cross-OS (≥2 of Linux, macOS, Windows) remains a terminal-board concern (see B10 / menu-smoke). |
| **direct** | **Not Proven** | Founder honesty: terminal-to-terminal **direct Internet is not proven**; shipping message path is fail-closed. Localhost/LAN + fail-closed `internet_dial_smoke` **≠** WAN reliability. See connectivity matrix §0. | Linked green CI or agent-executed smoke that dials a **non-loopback / non-RFC1918** peer on the named direct path. `127.0.0.1` (incl. B12 `127.0.0.1:7420`) is **not** Proven direct. |

---

## Terminal reliability (gate in front of M1)

| OS | Honest status | Notes |
|----|---------------|-------|
| Linux | **Not Proven** on this board | Menu-smoke sole CI is [RAVEN#16](https://github.com/Raven-ASHCO/RAVEN/pull/16) (Apple APPROVE + Core ACK; SRE converge DONE). **Proven flip only after executed green** (linked CI or agent smoke). |
| macOS | **Not Proven** on this board | Same #16 rust-macos menu-smoke when green. Keychain / launchd / notarization are **out of scope** for menu-smoke. |
| Windows | **Not Proven** on this board | Compile P0-1 **DONE** — [RAVEN#20](https://github.com/Raven-ASHCO/RAVEN/pull/20) **and** [RAVEN#21](https://github.com/Raven-ASHCO/RAVEN/pull/21) **MERGED** (not CI-held). Remaining B10 open P0 = named-pipe IPC + install→doctor→send CI. Docs/helpers **not** e2e-proven. Loopback B12 ≠ Proven. **Do not greenlight duplicate compile fixes.** |

**Merge order (Eng Program):** #20 done → land #16 **when green** → [RAVEN#19](https://github.com/Raven-ASHCO/RAVEN/pull/19) rebases **preserving** menu-smoke. B1 required-check enable still needs green + Manager GO.

---

## Non-claims

- This file does **not** enable required CI checks.
- This file does **not** greenlight M1–M3 production code.
- Soft soak / fail-rate bounds wait for the SRE Perf (#19) snapshot ([`perf-baseline-2026-09-04.md`](perf-baseline-2026-09-04.md) — harvest in flight; docs-only ≠ Proven).
- B11 `install.sh` ([RAVEN#17](https://github.com/Raven-ASHCO/RAVEN/pull/17)) is a hazard track, **not** install Proven.
- Path A lock: do **not** call mesh relay reliable. Localhost reservation only; circuit/WAN/auto-fallback/DCUtR **NOT proven**; hop server missing; multi-NAT **BLOCKED_HARDWARE**; NAT hold intact. Continue **B+C+terminal**.
