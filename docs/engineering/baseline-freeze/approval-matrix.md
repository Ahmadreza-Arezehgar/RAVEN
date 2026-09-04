# Approval Matrix

Change type → primary owner (role) → mandatory second approval. Risk class from `01-risk-classes.md` still applies; this matrix names the human/role bar.

| Change type | Risk | Primary owner | Mandatory second approval |
|-------------|------|---------------|---------------------------|
| Docs / non-normative comments | R0 | Author’s domain lead (#2–#20 as applicable) | None (1 approving review sufficient) |
| Test-only / CI cosmetic | R0–R1 | #20 CI / DevEx Owner | None beyond 1 review |
| Internal refactor (no API/wire) | R1 | Path CODEOWNER team lead | 1 approval from owning team |
| Public API / CLI / config schema | R2 | #7 Core Runtime Lead or #15 RDAP Runtime Owner (repo) | #1 Principal Architect **or** #3 Spec & Versioning Owner |
| Protocol field / message (non-crypto) | R2–R3 | #2 Protocol Lead (RAVEN) or #14 RDAP Protocol Lead | #1 Architecture Board chair; if normative wire break → treat as R3 |
| Normative protocol version bump | R3 | #3 Spec & Versioning Owner | Architecture Board (#1) **and** notify #4 |
| Crypto primitive / algorithm / RNG | R3 | #5 Crypto Lead | Security Board (#17) — **no self-merge** |
| Identity / credentials / authz | R3 | #6 Identity Lead | Security Board (#17) — **no self-merge** |
| Trust boundary change | R3 | #1 Principal Architect | Security Board (#17) — **no self-merge** |
| Network stack behavior | R2 | #9 Network Lead | #10 Transport Lead **or** #11 Performance Owner |
| Transport / framing | R2 | #10 Transport Lead | #9 Network Lead **or** #2 Protocol Lead |
| Apple platform paths | R2 | #12 Apple Platform Lead | #7 Core Runtime Lead **or** #17 if entitlement/signing |
| Windows platform paths | R2 | #13 Windows Platform Lead | #7 Core Runtime Lead **or** #17 if entitlement/signing |
| Raven↔RDAP contract / interop | R2–R3 | #4 Raven↔RDAP Interop Architect | #14 + #2; if security-relevant → #17 |
| Performance budget / gate change | R2 | #11 Performance Owner | #19 Release Engineering Lead |
| Release / tag / publish / signing | R3 | #19 Release Engineering Lead | #17 Security Assurance Lead — **no self-merge** |
| Required CI checks / branch protection | R3 | #20 CI / DevEx Owner | #17 **or** Eng Management + #1 |
| Dependency bump (crypto/identity) | R3 | #5 or #6 (surface) | #17 — **no self-merge** |
| Dependency bump (non-crypto) | R1–R2 | #8 Core Libraries Owner | Owning path team |

## Rules

1. **R3: no self-merge** — author ≠ merging approver; Principal Architect (#1) included.
2. Second approver must be a **different person** than the author, even if the author holds both roles temporarily.
3. CODEOWNERS teams are the default review requestors; this matrix names the **role** that must actually approve for R2/R3.
4. Eng Management cannot substitute for Security Board or Architecture Board on R3.
