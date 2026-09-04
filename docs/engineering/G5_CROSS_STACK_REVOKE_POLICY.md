# G5 — Cross-stack revoke policy (RAVEN device lineage ↔ RDAP address)

**Status:** Draft (docs-first). Architect full-ACK’d G5 on 2026-09-04 (PR #5 §2.2+E4). ADR 0004 appendix G5 on PR #3 must still be rewritten to the same predicate before Architecture ACKs that appendix. Soft-load P0 still held.  
**Owners:** Identity AuthZ · Raven↔RDAP · RDAP Protocol  
**Repos:** `Raven-ASHCO/RAVEN`, `Raven-ASHCO/raven-distributed-agent-protocol`  
**Related:** `docs/engineering/SPRINT0_IDENTITY_THREAT_MODEL.md`, `protocol/RAVEN_DEVICE_REVOCATION_V1.md`, RDAP `team_agents/raven_identity.py`; forthcoming ADR 0004 appendix G5 (`docs/adr/0004-appendix-g5-raven-rdap-revoke.md`) — Architect ruling + Identity alignment (not on this branch yet; must be rewritten to this predicate before Architecture ACKs that appendix)  
**Date:** 2026-09-04

## 1. Problem

RAVEN and RDAP both talk about “revoke,” but they revoke **different authorities**:

| Stack | What is revoked | Wire / store | Effect |
|-------|-----------------|--------------|--------|
| **RAVEN** | A **device lineage** (`device_id`, `device_ed_pub`, `device_x_pub`, `device_cert_hash`) under one user identity | `RavenDeviceRevocationV1` (`RVDR1`) + local sticky denylist | Device keys lose PairInit / envelope / ACK / Noise bind authority; identity address remains |
| **RDAP** | A **peer identity address** (`rvn1…`) | JSON revoke list consumed by `verify_delegation` / HTTP auth | Node rejects signed tasks / HTTP from that address |

Without a joint policy, operators can:

- revoke a stolen phone in RAVEN and still accept RDAP tasks from the same identity’s other (or same) device path if address pin remains trusted;
- revoke an RDAP peer address and leave RAVEN device certs unrevoked for mesh/crypto peers who never see the RDAP file.

## 2. Normative mapping (draft)

### 2.1 Definitions

- **Identity address** — `RavenAddressV1` derived from the user Ed25519 public key.
- **Device lineage** — the tuple permanently denied by RVDR1 (§2 of Device Revocation V1).
- **RDAP trust pin** — entry in `trusted_peers` (address → public key hex).
- **RDAP address revoke** — membership in the hot-reloaded revocations set.

### 2.2 Authority rules

1. **Crypto paths (RAVEN)** authorize a device key only if Identity V1 cert verifies, validity window holds, and no covering lineage revoke (and no exhausted/corrupt fail-closed marker when RVDR1 prod is enabled).
2. **RDAP task/HTTP paths** authorize a peer address only if pinned in `trusted_peers`, not in the address deny set, signature verifies, and replay is fresh — when `require_signed_tasks` is on.
3. **A ↛ R (always):** Adding an RVN1 to RDAP `revocations_file` MUST NOT mint or forge RVDR1.
4. **R ↛ auto address-deny:** An accepted RVDR1 MUST NOT by itself require writing the identity `rvn1…` into RDAP `revocations_file`. Playbook A (stolen device, seed safe): other/new lineages under that identity may remain valid; do not conflate device-lineage revoke with address deny. Pin address ≠ `device_ed_pub` without an explicit binding.
5. **R → fail-closed on bound data-plane (mandatory):** If ATSAM / LanDial / RDAP task paths are using **device key material covered by an applied RVDR1**, those paths MUST refuse (session close / task reject / no task-success after Raven refuse). This is **lineage-scoped** deny, not address-scoped. Predicate = covering lineage identifiers (`device_id` / `device_ed_pub` / `device_x_pub` / `device_cert_hash`), **not** “pin string equals device_ed_pub.”
6. **Address revoke** remains playbook B/C (identity seed compromise or peer policy), plus operator file / `IDENTITY_REVOKE_EXHAUSTED` fail-closed for that address namespace while the marker is active.
7. Effective denies at verify time only — do not auto-edit `trusted_peers` or `revocations_file` from RVDR1 apply.

### 2.3 Incident playbooks

| Incident | Must do (normative intent) | Optional / later |
|----------|----------------------------|------------------|
| **A. Single device compromised; identity seed safe** | Mint/apply **RVDR1** (or local sticky denylist) for that lineage; close sessions; re-pair on **new** lineage (no id/key reuse). | Notify contacts; push revoke object via OOB/carriers. **Do not** RDAP-address-revoke unless tasks from that identity must stop entirely. |
| **B. Identity seed compromised (or suspected)** | Continuity / recovery path (Identity Continuity V2 when applicable); **RDAP address revoke** for that address on all controlled nodes; revoke **all** known device lineages; re-pin new address after recovery. | Contact warning UX; social-repo updates. |
| **C. RDAP peer misbehavior / key disagreement** | **RDAP address revoke** + remove or replace trust pin. | If the peer’s *device* is also a RAVEN contact, also apply device lineage revoke when the misbehavior is device-scoped. |
| **D. Partition / stale peer** | Accept documented lag: a peer that has not observed RVDR1 may still trust the device until sync. UX MUST NOT claim “revoked everywhere” after local apply alone. | Prefer short cert TTLs as backstop. |

### 2.4 Non-goals (V1 policy)

- Instant global revoke across partitions.
- Server CRL/OCSP.
- Silent inference that “address revoked ⇒ all devices denied in RAVEN” without an explicit device revoke (**A ↛ R always**), except playbook **B**.
- Silent inference that an accepted RVDR1 ⇒ RDAP address deny / `revocations_file` entry (**R ↛ auto address-deny**; playbook A). **R → fail-closed on bound data-plane** is lineage-scoped and mandatory.
- Using unsigned gossip to clear either deny-set.

## 3. Implementation expectations (docs → later eng)

| ID | Expectation | Stack |
|----|-------------|-------|
| E1 | Signed-mode RDAP: document that empty/missing revoke file means “no addresses revoked,” not “revocation disabled”; misconfig runbooks required | RDAP |
| E2 | OPEN MODE (`require_signed_tasks=false`) makes **no** authz claim; forbidden as default for shared/prod demos | RDAP |
| E3 | Authz code paths MUST use fail-closed registry/revoke loaders (`*_checked`); soft `unwrap_or_default` banned on those paths (P0 — held for Sprint 1 batch) | RAVEN |
| E4 | Joint test: RVDR1 covering peer device material used on bound ATSAM/LanDial/task paths ⇒ those paths refuse (lineage-scoped). Same RVDR1 MUST NOT alone imply RDAP address deny / `revocations_file` entry (playbook A). Address deny tested separately (playbook B/C). | Interop / Adversarial QA |
| E5 | Operator one-pager: “stolen phone” vs “stolen identity” decision tree pointing at §2.3 | Docs |

## 4. Open questions for joint owners

1. Should signed-mode RDAP **require** a revocations file path (even if empty list) to force conscious config? **RDAP Protocol recommends YES for signed mode.**
2. After Continuity V2 activation, is address rotation mandatory before clearing RDAP address revoke?
3. Who owns automated “B-playbook” fan-out of address revoke to fleet nodes (ops script vs protocol)?

## 5. Ack checklist

- [x] Identity AuthZ (author)
- [x] Raven↔RDAP (ACK G5 — ADR 0004 appendix on PR #3 rewritten to §2.2 predicate, 2026-09-04)
- [x] RDAP Protocol (ACK on RDAP PR #2 docs/rdap-revocation.md)
- [x] Architect (full G5 ACK on PR #5 §2.2+E4, 2026-09-04)
