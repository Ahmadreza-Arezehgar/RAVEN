# Baseline Freeze — Sprint 0 Engineering Handoff

This directory is the **Sprint 0 engineering baseline**. It is the contract between
the founder and every engineering role. Do not invent a parallel checklist.

## Start here

1. Read **[sprint0-checklist.md](sprint0-checklist.md)** — the single source of
   truth for Sprint 0 completeness.
2. Read **[risk-classes.md](risk-classes.md)** — R0–R3 risk class definitions
   (no role may skip this).
3. Read **[codeowners-policy.md](codeowners-policy.md)** — who reviews what,
   and the R3 two-reviewer rule. **Live GitHub CODEOWNERS** (when present):
   [`/.github/CODEOWNERS`](../../../.github/CODEOWNERS) — not invented by this
   Architecture PR.
4. Read **[org-structure.md](org-structure.md)** — 18 engineering roles.
5. Read **[crate-ownership.md](crate-ownership.md)** — crate-to-role mapping.

## Architecture drafts (this PR — Principal Architect)

| File | Status |
| --- | --- |
| [architecture-dependency-map.md](architecture-dependency-map.md) | **DONE** — Architect draft. Layer map, allowed/forbidden deps, crate inventory, RDAP→node path. |
| [trust-boundaries.md](trust-boundaries.md) | **DONE** — Architect draft of TB1–TB5. **#17 Security Board + #6 Identity** still requested; this PR does not close that row. |
| [adr-framework.md](adr-framework.md) | **DONE** — ADR-0001 (layers), ADR-0002 (terminal-first), ADR-0003 (three pathways, not collapsed), ADR-0004 (O6 / Appendix G5 — pin ≢ `device_ed_pub`). |
| [undocumented-cross-layer-deps.md](undocumented-cross-layer-deps.md) | **DONE** — D1–D45 findings (mesh, identity, RDAP, build, iOS). |

These four files are **R0 documentation**. They do **not** authorize R3
crypto, CODEOWNERS, or feature code.

**Try-phase (normative, this PR):** docs, the architecture map, and ADRs
are **not** pass evidence. A pathway is **pass** only when **Delivered +
ACK + dedup + opaque** is shown on a **named** path, on **≥2 OS** or with
Architecture **and** Security **WAIVE**, with labels **per OS × path**.
Do not collapse the three planes (mesh / bridge / direct). **Do not
conflate software vs hardware.** Cross-link (may land on `main` via SRE):
[`terminal-path-reliability.md`](terminal-path-reliability.md),
[`reliability-evidence-bar.md`](reliability-evidence-bar.md). **Bridge** is
**sealed-ACK-only / opaque**: forward envelopes only — **must not decrypt
or mint endpoint ACKs**.

## Other Sprint 0 docs (this repo)

| File | Owner | Notes |
| --- | --- | --- |
| [sprint0-checklist.md](sprint0-checklist.md) | All | Completeness; Architecture + Trust rows updated on this PR |
| [risk-classes.md](risk-classes.md) | Founder / Security | R0–R3 |
| [crate-ownership.md](crate-ownership.md) | Architect / Founder | Crate → role |
| [codeowners-policy.md](codeowners-policy.md) | Founder | Policy; live file is `/.github/CODEOWNERS` if present |
| [org-structure.md](org-structure.md) | Founder | 18 roles |
| [handoff.md](handoff.md) | Founder | Handoff narrative |
| [apple-tree-gap.md](apple-tree-gap.md) | Apple / Founder | iOS/watchOS tree gap (exists on `main`) |
| [windows-tree-gap.md](windows-tree-gap.md) | Windows / Founder | Windows tree gap (exists on `main`) |

**Connectivity (founder Internet honesty, `main`):**
[`docs/network/raven-swarm-connectivity-matrix.md`](../../../network/raven-swarm-connectivity-matrix.md)
§0 — three planes; do not collapse. Mesh radio vs `mock_ble` vs Circuit
Relay v2 are not interchangeable (see D19/D20/D39 on this PR).

**Identity (merged on `main` via PR #5):**
[`docs/engineering/SPRINT0_IDENTITY_THREAT_MODEL.md`](../SPRINT0_IDENTITY_THREAT_MODEL.md),
[`docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md`](../G5_CROSS_STACK_REVOKE_POLICY.md).
Architect ACK: §2.4 + OPEN-ID-P0 is a **documented defect**, not a code
approval. Soft-load fail-open stays **held**.

## Next step after reading this folder

1. Confirm Architecture + Trust rows on [sprint0-checklist.md](sprint0-checklist.md)
   (Architect **DONE** draft; Trust still requests **#17 + #6**).
2. Do **not** treat this PR as merge-ready until **#17** countersigns.
3. Further work is **#17 / #6 / #3 / #8 / #9 / #11** per checklist — not
   a second Architecture rewrite.
