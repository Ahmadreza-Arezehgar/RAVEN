# RAVEN + RDAP — Ownership & Baseline Freeze (Sprint 0)

**بستهٔ فریز مالکیت و خط پایه | Ownership & Baseline Freeze Package**  
Date: 2026-09-04 · Org: RAVEN + RDAP engineering

## Purpose

This package freezes **who owns what**, **how risk is classified**, and **what must be true** before feature work starts. Without a baseline freeze, PRs merge without required review, trust boundaries stay implicit, and Raven↔RDAP gaps accumulate silently.

هدف: قبل از شروع فیچر، مالکیت، مرز اعتماد، و قوانین مرژ مشخص و قابل اجرا باشند.

## What must be true before feature work

| Gate | Required state |
|------|----------------|
| Ownership | Every critical path has a primary owner (role #) + team handle |
| Risk | R0–R3 classes published; R3 cannot be self-merged by anyone |
| Reviews | Approval matrix enforced via branch protection / rulesets |
| CODEOWNERS | Active on GitHub Org repos (not personal-account repos) |
| CI | Required status checks on `main` for RAVEN and RDAP |
| Baseline | Protocol versions, experimental flags, perf numbers, known gaps recorded |
| Security | Trust boundaries + known security/interop gaps documented |

Feature PRs that touch R2/R3 surfaces **must not** land until the Sprint 0 checklist (`08-sprint0-checklist.md`) is complete or explicitly waived by Architecture Board + Security Board.

## Document map

| File | Contents |
|------|----------|
| [`01-risk-classes.md`](01-risk-classes.md) | R0–R3 definitions + no-self-merge-R3 rule |
| [`02-org-structure.md`](02-org-structure.md) | 5 domains, roles #1–#20, boards, text org chart |
| [`03-role-charters.md`](03-role-charters.md) | Per-role ownership paths, skills, 90-day KPI |
| [`04-approval-matrix.md`](04-approval-matrix.md) | Change type → owner → mandatory second approval |
| [`05-codeowners-draft.md`](05-codeowners-draft.md) | Proposed CODEOWNERS mapping + Org blocker note |
| [`06-github-teams.md`](06-github-teams.md) | Teams to create; Org prerequisite |
| [`07-ninety-day-outcomes.md`](07-ninety-day-outcomes.md) | Outcomes O1–O7 |
| [`08-sprint0-checklist.md`](08-sprint0-checklist.md) | Deliverables checklist with status columns |
| [`09-audit-snapshot-2026-09-04.md`](09-audit-snapshot-2026-09-04.md) | Factual audit as of 2026-09-04 |
| [`artifacts/CODEOWNERS.raven`](artifacts/CODEOWNERS.raven) | Ready-to-paste CODEOWNERS for RAVEN |
| [`artifacts/CODEOWNERS.rdap`](artifacts/CODEOWNERS.rdap) | Ready-to-paste CODEOWNERS for RDAP |

## Non-goals

- Assigning named humans to roles (use role numbers / `@Raven-ASHCO/*` teams only until staffing is confirmed).
- Cloning or modifying live repos from this package (docs + paste-ready artifacts only).
- Inventing current CODEOWNERS or branch protection that do not exist (see audit).

## Next step

Complete [`08-sprint0-checklist.md`](08-sprint0-checklist.md), create/use a GitHub Organization, stand up teams in [`06-github-teams.md`](06-github-teams.md), then apply CODEOWNERS + branch protection.
