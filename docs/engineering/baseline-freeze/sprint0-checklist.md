# Sprint 0 Checklist — Ownership & Baseline Freeze

Status legend: `NOT STARTED` · `IN PROGRESS` · `BLOCKED` · `DONE` · `WAIVED`

| Deliverable | Owner (role) | Status | Evidence / notes |
|-------------|--------------|--------|------------------|
| Architecture map | #1 | DONE | Architect deliverable: [`architecture-dependency-map.md`](architecture-dependency-map.md) (PR cites Cargo.toml, ADRs 0001–0003, MESH/SERVERLESS, THREAT_MODEL, RDAP `main`). **Lock accepted;** founder try-phase **executed evidence** required before any pathway is “proven” (§2.1). Pass = **Delivered + ACK + dedup + opaque** on a **named** path; **≥2 OS** or Architecture **and** Security **WAIVE**; labels **per OS × path**. Aligns SRE honesty bar ([PR #29](https://github.com/Raven-ASHCO/RAVEN/pull/29) `terminal-path-reliability.md`). **Bridge:** sealed-ACK-only / opaque — no decrypt, no mint endpoint ACKs. |
| Trust boundaries | #1, #17, #6 | DONE | Architect draft: [`trust-boundaries.md`](trust-boundaries.md). **OPEN-ID-P0:** Identity docs [PR#5](https://github.com/Raven-ASHCO/RAVEN/pull/5) (`SPRINT0_IDENTITY_THREAT_MODEL.md` §3.2 P0 + G5); Architect ack on §2.4 + P0 note; **code held.** **#17 + #6 countersign still requested** (not a self-approval of the assurance artifact). |
| Component ownership | Domain leads #2–#20 | NOT STARTED | Role charters drafted in `03-role-charters.md` |
| CODEOWNERS | #20, #1 | BLOCKED | Draft in `artifacts/`; **blocked on GitHub Org** (see audit) |
| PR risk classification | #17, #1 | IN PROGRESS | Classes defined in `01-risk-classes.md`; not yet enforced in PR template |
| Required review matrix | #17 | IN PROGRESS | `04-approval-matrix.md` drafted; not enforced in branch protection |
| CI required checks | #20 | NOT STARTED | Workflows exist (`raven-serverless.yml`, `selftest.yml`); not required on `main` |
| Current protocol versions | #2, #3, #14 | IN PROGRESS | Inventory: `protocol/PROTOCOL_VERSIONS.md` (linked from `protocol/SPEC.md`); production-disabled evidence in `protocol/RAVEN_INTEROPERABILITY_MATRIX.md` §5. Docs only; CI YAML alignment is DevSecOps. |
| Experimental-only features | #2, #14, #10 | NOT STARTED | |
| Known security / interop / Raven↔RDAP gaps | #4, #17, #18 | NOT STARTED | |
| Performance baseline | #19 SRE Perf | IN PROGRESS | Soft budgets draft until snapshot lands. Evidence: [`docs/engineering/baseline-freeze/perf-baseline-2026-09-04.md`](perf-baseline-2026-09-04.md) (SRE Perf owning; harvest in flight). |
| 90-day roadmap | #1, Eng Mgmt | IN PROGRESS | Outcomes O1–O7 in `07-ninety-day-outcomes.md` |

## Exit criteria for feature work

All rows **DONE** or **WAIVED** (waiver requires Architecture Board + Security Board written note).  
**CODEOWNERS** may remain BLOCKED only if Eng Management accepts interim named-reviewer fallback **and** `main` protection is already DONE.

## Blocker

- [ ] Create GitHub org `Raven-ASHCO` (blocked on founder action in GitHub UI)
