# Sprint 0 Checklist — Ownership & Baseline Freeze

Status legend: `NOT STARTED` · `IN PROGRESS` · `BLOCKED` · `DONE` · `WAIVED`

| Deliverable | Owner (role) | Status | Evidence / notes |
|-------------|--------------|--------|------------------|
| Architecture map | #1 | NOT STARTED | |
| Trust boundaries | #1, #17, #6 | NOT STARTED | |
| Component ownership | Domain leads #2–#20 | NOT STARTED | Role charters drafted in `03-role-charters.md` |
| CODEOWNERS | #20, #1 | BLOCKED | Draft in `artifacts/`; **blocked on GitHub Org** (see audit) |
| PR risk classification | #17, #1 | IN PROGRESS | Classes defined in `01-risk-classes.md`; not yet enforced in PR template |
| Required review matrix | #17 | IN PROGRESS | `04-approval-matrix.md` drafted; not enforced in branch protection |
| CI required checks | #20 | NOT STARTED | Workflows exist (`raven-serverless.yml`, `selftest.yml`); not required on `main` |
| Current protocol versions | #2, #3, #14 | NOT STARTED | |
| Experimental-only features | #2, #14, #10 | NOT STARTED | |
| Known security / interop / Raven↔RDAP gaps | #4, #17, #18 | NOT STARTED | |
| Performance baseline | #11 | NOT STARTED | |
| 90-day roadmap | #1, Eng Mgmt | IN PROGRESS | Outcomes O1–O7 in `07-ninety-day-outcomes.md` |

## Exit criteria for feature work

All rows **DONE** or **WAIVED** (waiver requires Architecture Board + Security Board written note).  
**CODEOWNERS** may remain BLOCKED only if Eng Management accepts interim named-reviewer fallback **and** `main` protection is already DONE.

## Blocker

- [ ] Create GitHub org `Raven-ASHCO` (blocked on founder action in GitHub UI)
