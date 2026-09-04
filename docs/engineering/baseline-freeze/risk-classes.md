# Risk Classes (R0–R3)

Every PR must declare a risk class. Reviewers confirm the class; CODEOWNERS and the approval matrix enforce minimum reviews.

| Class | Name | Examples | Review bar |
|-------|------|----------|------------|
| **R0** | Cosmetic / docs | Typos, README, non-normative comments, CI log formatting | 1 reviewer; owner team optional |
| **R1** | Isolated, non-security | Pure refactors with no API/wire change; test-only; tooling that cannot affect runtime trust | Primary owner team; 1 approval |
| **R2** | Behavioral / interface | Public API, CLI flags, config schema, non-crypto protocol fields, platform adapters (Apple/Windows), performance-sensitive paths | Primary owner + mandatory second approval per matrix |
| **R3** | Trust / crypto / protocol / release | Crypto primitives, key handling, identity, authn/authz, wire protocol normative changes, trust boundaries, release/signing, Raven↔RDAP security interop | Primary owner + Security Board or Architecture Board second; **no self-merge** |

## Hard rule: no self-merge on R3

**Nobody may self-merge an R3 change** — including the Principal Architect (#1), Eng Management, or any board chair. The author must obtain a distinct human approval from the mandatory second approver listed in `04-approval-matrix.md`.

Rationale: R3 changes alter the trust model or shipping surface; single-person merge removes the last control before production impact.

## Classification guidance

- If unsure between R2 and R3, classify as **R3**.
- Mixing R1 and R3 in one PR → treat the whole PR as **R3**.
- “Experimental-only” features that can be enabled in production builds are still **R2** (or **R3** if they touch trust).
