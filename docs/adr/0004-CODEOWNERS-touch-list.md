# CODEOWNERS touch list — ADR 0004 / O6

Risk class R3; approvers Architect #1, Crypto #3, Identity #15 (+ Security Board as matrix); No R3 self-merge; M1–M3 production enablement subordinate to `docs/THREAT_MODEL.md` + `protocol/SECURITY_ERRATA_RVN1_2026-08-13.md` HOLD.

Required ack before merge: `@Raven-ASHCO/architecture` (#1), `@Raven-ASHCO/crypto` (#3), `@Raven-ASHCO/identity` (#15). Security Board as the review matrix requires. **No R3 self-merge.**

ADR ack does not lift the RVN1 production hold.

Proposed when M1–M2 land:
- ADR 0004 docs: architecture (+ rdap team if available on this repo)
- Future raven-node IPC extensions: existing core + identity rules
- Future ATSAM session-ensure used by RDAP: crypto + core
- RDAP repo: pointer docs under `@Raven-ASHCO/rdap`; new IPC client module rdap + identity; mesh.py stays experimental / network

Treat M1–M3 crypto/identity/revoke-apply wiring as R3: Code Owner review; no self-merge.
