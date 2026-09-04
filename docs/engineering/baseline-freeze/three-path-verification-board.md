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

**Do not call mesh relay reliable.** Path B and Path C are locked below. **A+B+C board fills now present.** Continue **terminal**.

## Manager Path B lock (2026-09-04)

**Path B (DTN / bridge) claim language is locked.** Honest cells only:

| Cell | Lock |
|------|------|
| Opaque custody | **Proven (software)** — prefer executed green/red citations (linked CI or agent smoke). Docs-only ≠ Proven. |
| `ENDPOINT_ACK_ONLY` | **Proven (software)** — sealed-ACK-only; Forwarded≠Delivered. Prefer executed green/red citations. |
| Hop / replication | **cooperative-only** |
| Production mailbox | **held** |
| iOS | **blocked on B8** (Phase 1+ PARKED) |
| Flood-proof | **not claimed** |
| Byzantine-safe | **not claimed** |

**Claim language locked — not flood-proof / not Byzantine-safe.** Path C is locked below. **A+B+C board fills now present.** Continue **terminal**.

## Manager Path C lock (2026-09-04)

**Path C (direct Internet) claim language is locked.** Honest cells only:

| Cell | Lock |
|------|------|
| LAN / localhost | **Proven** (localhost/LAN software path) |
| WAN | **blocked / untested** — **NOT** a WAN reliability claim |
| Internet dial | **fail-closed proven** — **NOT** a WAN reliability claim |
| `ash_menu_smoke` | CLI DX [RAVEN#16](https://github.com/Raven-ASHCO/RAVEN/pull/16) |
| Windows | **honest fail-closed** until named-pipe (B10 #1) |

**A+B+C board fills now present.** Continue **terminal**.

## Node IPC (terminal input)

**Windows named-pipe gap = #1 blocker.** `ipc_server` is **UDS-only**; `ash --send-stdin` spawn has no Win pipe path. Linux/macOS UDS is **mostly green**. SCM+LAN parity = **P1 after pipe**. **Does not unblock WAN Path C.**

## Manager macOS slice (2026-09-04)

| Cell | Lock |
|------|------|
| CI unit / smoke | **Proven** |
| Menu smokes | **Not GHA-gated yet** — **decision:** wire `ash_menu_smoke` / `ash doctor` into CI (**not** operator-only) |
| Track | [RAVEN#16](https://github.com/Raven-ASHCO/RAVEN/pull/16) + [RAVEN#22](https://github.com/Raven-ASHCO/RAVEN/pull/22) |
| Notarize | **BLOCKED_HUMAN** residual |

## FOUNDER RULE (try phase = execute)

**Try-phase = execute:** consolidate **executed green/red only** (linked CI or agent smoke). **Docs-only ≠ Proven.**

ADR text, gap notes, matrices, and this board **do not** flip a cell to Proven.

Applies to **terminal reliability** (Win / macOS / Linux) **and** these three paths (`mesh` | `bridge` | `direct`).

---

## Founder Priority #1

Terminal Win / macOS / Linux reliability **and** this three-path matrix sit **above O6 M1+**.

**Do not schedule M1 engineering until the terminal board is green** (CEO override only). M0 docs ack is **✅ CLOSED / MERGED** ([RAVEN#3](https://github.com/Raven-ASHCO/RAVEN/pull/3) `ce087c7d9cfb`; three-way ACK **final**). M1–M3 **production** code remains **closed** (terminal + HOLD).

---

## Paths (honest cells — A+B+C locks filled)

| Path | Honest status | What exists (not Proven) | What would Proven require |
|------|---------------|--------------------------|---------------------------|
| **mesh** (Path A) | **Not Proven** — **locked** | **Path A lock:** localhost reservation only. Two-client circuit / WAN / auto-fallback / DCUtR **NOT proven**. Hop server **missing**. Multi-NAT **BLOCKED_HARDWARE**. NAT hold **intact**. Policy/sim (`network_sim_1000`) + `mock_ble` hygiene ≠ live mesh. **Do not call mesh relay reliable.** | Executed green/red only (linked CI or agent smoke) on a **named** mesh path after the lock lifts. CI ≠ hardware. |
| **bridge** (Path B) | **Locked** — opaque custody + `ENDPOINT_ACK_ONLY` **proven (software)** | **Path B lock:** hop/repl **cooperative-only**; prod mailbox **held**; iOS **blocked on B8**. Claim language locked — **not flood-proof / not Byzantine-safe**. Prefer executed green/red citations (`bridge_v1` / named smokes — do not invent run IDs here). | Broader Proven (flood / Byzantine / prod mailbox / iOS) is **out of claim**. |
| **direct** (Path C) | **Locked** — LAN/localhost **proven**; WAN **blocked/untested** | **Path C lock:** internet dial **fail-closed proven** — **NOT** a WAN reliability claim. `ash_menu_smoke` → CLI DX [RAVEN#16](https://github.com/Raven-ASHCO/RAVEN/pull/16). Windows **honest fail-closed** until named-pipe. Named-pipe/UDS work **does not unblock WAN**. See connectivity matrix §0. | WAN Proven would need executed green/red on a **non-loopback / non-RFC1918** peer. `127.0.0.1` (B12) is **not** WAN Proven. |

---

## Terminal reliability (gate in front of M1)

| OS | Honest status | Notes |
|----|---------------|-------|
| Linux | UDS **mostly green**; Path C LAN/localhost **proven** (not WAN) | `ash_menu_smoke` → CLI DX [RAVEN#16](https://github.com/Raven-ASHCO/RAVEN/pull/16). Internet dial **fail-closed proven** ≠ WAN claim. **Proven flip only after executed green** (linked CI or agent smoke). |
| macOS | CI unit/smoke **proven**; menu smokes **not GHA-gated yet** | **Decision:** wire `ash_menu_smoke`/`doctor` into CI (not operator-only). Track #16/#22. Notarize **BLOCKED_HUMAN**. UDS mostly green. Path C LAN/localhost proven ≠ WAN. |
| Windows | **Honest fail-closed** until named-pipe | Compile P0-1 **DONE** (#20 + #21 MERGED). Remaining B10: **#1 = named-pipe**. Then install→doctor→send CI. SCM+LAN parity = **P1 after pipe**. **Does not unblock WAN Path C.** Loopback B12 ≠ WAN Proven. |

**Merge order (Eng Program):** #20 done → land #16 **when green** → [RAVEN#19](https://github.com/Raven-ASHCO/RAVEN/pull/19) rebases **preserving** menu-smoke. B1 required-check enable still needs green + Manager GO.

---

## Non-claims

- This file does **not** enable required CI checks.
- This file does **not** greenlight M1–M3 production code (terminal + HOLD). M0 ADR 0004 is already **MERGED** (`ce087c7d9cfb`).
- Soft soak / fail-rate bounds wait for the SRE Perf (#19) snapshot ([`perf-baseline-2026-09-04.md`](perf-baseline-2026-09-04.md) — harvest in flight; docs-only ≠ Proven).
- B11 `install.sh` ([RAVEN#17](https://github.com/Raven-ASHCO/RAVEN/pull/17)) is a hazard track, **not** install Proven.
- Path A lock: do **not** call mesh relay reliable. Localhost reservation only; circuit/WAN/auto-fallback/DCUtR **NOT proven**; hop server missing; multi-NAT **BLOCKED_HARDWARE**; NAT hold intact.
- Path B lock: opaque custody + `ENDPOINT_ACK_ONLY` **proven (software)** only. Hop/repl cooperative-only; prod mailbox held; iOS blocked on B8. **Not flood-proof / not Byzantine-safe.** Prefer executed green/red citations.
- Path C lock: LAN/localhost **proven**; WAN **blocked/untested**; internet dial **fail-closed proven** — **NOT** a WAN reliability claim. `ash_menu_smoke` → CLI DX #16. Windows honest fail-closed until named-pipe.
- **A+B+C board fills now present.** Continue **terminal**.
- Node IPC: Windows named-pipe = **#1** remaining B10. Linux/macOS UDS mostly green. SCM+LAN parity = P1 after pipe. **Does not unblock WAN Path C.**
- macOS slice: CI unit/smoke **proven**. Menu smokes **not GHA-gated yet** — wire `ash_menu_smoke`/`doctor` into CI (not operator-only). Track #16/#22. Notarize **BLOCKED_HUMAN**.
