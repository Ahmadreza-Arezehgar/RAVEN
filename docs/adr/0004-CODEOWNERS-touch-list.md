# CODEOWNERS touch list — ADR 0004 / O6

Required ack before merge: `@Raven-ASHCO/architecture`, `@Raven-ASHCO/crypto`, `@Raven-ASHCO/identity`.

Proposed when M1–M2 land:
- ADR 0004 docs: architecture (+ rdap team if available on this repo)
- Future raven-node IPC extensions: existing core + identity rules
- Future ATSAM session-ensure used by RDAP: crypto + core
- RDAP repo: pointer docs under `@Raven-ASHCO/rdap`; new IPC client module rdap + identity; mesh.py stays experimental / network

Treat M1–M2 crypto/identity wiring as R3: Code Owner review; no self-merge.
