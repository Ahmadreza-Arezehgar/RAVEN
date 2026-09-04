# Sprint 0 Checklist — Ownership & Baseline Freeze

Status legend: `NOT STARTED` · `IN PROGRESS` · `BLOCKED` · `DONE` · `WAIVED`

| Deliverable | Owner (role) | Status | Evidence / notes |
|-------------|--------------|--------|------------------|
| Architecture map | #1 | DONE | Architect deliverable: [`architecture-dependency-map.md`](architecture-dependency-map.md) (PR cites Cargo.toml, ADRs 0001–0003, MESH/SERVERLESS, THREAT_MODEL, RDAP `main`) |
| Trust boundaries | #1, #17, #6 | DONE | Architect draft: [`trust-boundaries.md`](trust-boundaries.md). **OPEN-ID-P0** (soft-load fail-open on corrupt denylist) recorded; await Identity docs PR. **#17 + #6 review still requested** (not a self-approval of the assurance artifact). |
| Component ownership | Domain leads #2–#20 | NOT STARTED | Role charters drafted in `03-role-charters.md` |
| CODEOWNERS | #20, #1 | BLOCKED | Draft in `artifacts/`; **blocked on GitHub Org** (see audit) |
| PR risk classification | #17, #1 | IN PROGRESS | Classes defined in `01-risk-classes.md`; not yet enforced in PR template |
| Required review matrix | #17 | IN PROGRESS | `04-approval-matrix.md` drafted; not enforced in branch protection |
| CI required checks | #20 | NOT STARTED | Workflows exist (`raven-serverless.yml`, `selftest.yml`); not required on `main` |
| Current protocol versions | #2, #3, #14 | IN PROGRESS | Inventory: `protocol/PROTOCOL_VERSIONS.md` (linked from `protocol/SPEC.md`); production-disabled evidence in `protocol/RAVEN_INTEROPERABILITY_MATRIX.md` §5. Docs only; CI YAML alignment is DevSecOps. |
| Experimental-only features | #2, #14, #10 | NOT STARTED | |
| Known security / interop / Raven↔RDAP gaps | #4, #17, #18 | NOT STARTED | |
| Performance baseline | #11 | NOT STARTED | |
| 90-day roadmap | #1, Eng Mgmt | IN PROGRESS | Outcomes O1–O7 in `07-ninety-day-outcomes.md` |

## Exit criteria for feature work

All rows **DONE** or **WAIVED** (waiver requires Architecture Board + Security Board written note).  
**CODEOWNERS** may remain BLOCKED only if Eng Management accepts interim named-reviewer fallback **and** `main` protection is already DONE.

## Blocker

- [ ] Create GitHub org `Raven-ASHCO` (blocked on founder action in GitHub UI)
