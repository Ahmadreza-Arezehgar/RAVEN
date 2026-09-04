# G5 — Cross-stack revoke policy (RAVEN device lineage ↔ RDAP address)

**Status:** Draft (docs-first)  
**Owners:** Identity AuthZ · Raven↔RDAP · RDAP Protocol  
**Repos:** `Raven-ASHCO/RAVEN`, `Raven-ASHCO/raven-distributed-agent-protocol`  
**Related:** `docs/engineering/SPRINT0_IDENTITY_THREAT_MODEL.md`, `protocol/RAVEN_DEVICE_REVOCATION_V1.md`, RDAP `team_agents/raven_identity.py`; G5 ADR appendix forthcoming with ADR 0004 (`docs/adr/0004-raven-rdap-atsam-transport.md` appendix G5 / `docs/adr/0004-appendix-g5-raven-rdap-revoke.md` — not on this branch yet)  
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

### 2.2 Authority rules (updated)

1. **Crypto paths (RAVEN)** authorize a *device key* only if Identity V1 cert verifies, validity window holds, and no covering lineage revoke (and no exhausted/corrupt fail-closed marker when RVDR1 prod is enabled).
2. **RDAP task / HTTP paths** authorize a *peer address* only if pinned in `trusted_peers`, not effectively A2A-denied, signature verifies, and replay is fresh — when `require_signed_tasks` is on.
3. **A ↛ R (always):** Adding an RVN1 to RDAP `revocations_file` MUST NOT mint or forge RVDR1.
4. **R → A (conditional effective deny):** RDAP MUST treat a peer as A2A-denied at **verify time** (do not auto-edit `trusted_peers` / revocations file) **if and only if** an accepted RVDR1’s denied lineage identifiers cover the **cryptographic material actually bound into that peer’s auth path on this node**.
   - **Identity-correct M1 (normative):** RDAP/ash pin = **user identity** Ed25519 → `RavenAddressV1`. RVDR1 targets **device lineage** (`device_id` / `device_ed_pub` / `device_x_pub` / `device_cert_hash`) and does **not** revoke the address. Therefore a normal device-lineage RVDR1 does **not** satisfy this predicate and MUST NOT auto layer-A address-deny (Sprint 0 playbook A).
   - **R → data-plane (mandatory for O6):** When RVDR1 covers the peer device lineage used for PairInit/ATSAM, RDAP MUST fail-closed **ATSAM/LanDial task send-recv** (no task-success after Raven refuse) even if layer A does not fire.
   - Pinning `device_ed_pub` as the RDAP peer key is **non-conformant** to Identity V1; do not document M1 as pin ≡ `device_ed_pub`.
5. Outside the conditional above, playbooks A/B/C stand — no silent inference either way.
6. While `IDENTITY_REVOKE_EXHAUSTED` is active for an identity namespace, RDAP MUST fail-closed A2A for that address (authz state untrustworthy).

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
- Silent inference that a normal device-lineage RVDR1 ⇒ layer-A address deny. **R → A** is verify-time and **Identity-correct M1 only** (pin ≢ `device_ed_pub`); **R → data-plane** fail-closed is separate and mandatory for O6.
- Using unsigned gossip to clear either deny-set.

## 3. Implementation expectations (docs → later eng)

| ID | Expectation | Stack |
|----|-------------|-------|
| E1 | Signed-mode RDAP: document that empty/missing revoke file means “no addresses revoked,” not “revocation disabled”; misconfig runbooks required | RDAP |
| E2 | OPEN MODE (`require_signed_tasks=false`) makes **no** authz claim; forbidden as default for shared/prod demos | RDAP |
| E3 | Authz code paths MUST use fail-closed registry/revoke loaders (`*_checked`); soft `unwrap_or_default` banned on those paths (P0 — held for Sprint 1 batch) | RAVEN |
| E4 | Joint test: Identity-correct M1 — device-lineage RVDR1 does **not** alone fail RDAP layer-A verify; **R → data-plane** fail-closed when RVDR1 covers PairInit/ATSAM lineage; `IDENTITY_REVOKE_EXHAUSTED` fail-closes A2A; playbook B still address-revokes | Interop / Adversarial QA |
| E5 | Operator one-pager: “stolen phone” vs “stolen identity” decision tree pointing at §2.3 | Docs |

## 4. Open questions for joint owners

1. Should signed-mode RDAP **require** a revocations file path (even if empty list) to force conscious config? **RDAP Protocol recommends YES for signed mode.**
2. After Continuity V2 activation, is address rotation mandatory before clearing RDAP address revoke?
3. Who owns automated “B-playbook” fan-out of address revoke to fleet nodes (ops script vs protocol)?

## 5. Ack checklist

- [ ] Identity AuthZ (author)
- [ ] Raven↔RDAP
- [ ] RDAP Protocol
- [x] Architect (Sprint 0 §2.4 trust-boundary ACK; §2.2 A↛R + conditional R→A / Identity-correct M1)
