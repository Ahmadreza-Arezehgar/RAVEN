# CODEOWNERS touch list — ADR 0004 / O6

**Risk class:** R3 (ATSAM / crypto transport). **No R3 self-merge.**

Required ack before merge: Architect (`@Raven-ASHCO/architecture` #1), Crypto ATSAM (`@Raven-ASHCO/crypto` #3), Identity AuthZ (`@Raven-ASHCO/identity` #15). Security Board as the review matrix requires.

M1–M3 **production enablement** is subordinate to `docs/THREAT_MODEL.md` + `protocol/SECURITY_ERRATA_RVN1_2026-08-13.md` HOLD. ADR ack does not lift the RVN1 production hold.

Proposed when M1–M2 land:
- ADR 0004 docs: architecture (+ rdap team if available on this repo)
- Future raven-node IPC extensions: existing core + identity rules
- Future ATSAM session-ensure used by RDAP: crypto + core
- RDAP repo: pointer docs under `@Raven-ASHCO/rdap`; new IPC client module rdap + identity; mesh.py stays experimental / network

Treat M1–M3 crypto/identity/revoke-apply wiring as R3: Code Owner review; no self-merge.
