# G5 — Cross-stack revoke policy (RAVEN device lineage ↔ RDAP address)

**Status:** Draft (docs-first)  
**Owners:** Identity AuthZ · Raven↔RDAP · RDAP Protocol  
**Repos:** `Raven-ASHCO/RAVEN`, `Raven-ASHCO/raven-distributed-agent-protocol`  
**Related:** `docs/engineering/SPRINT0_IDENTITY_THREAT_MODEL.md`, `protocol/RAVEN_DEVICE_REVOCATION_V1.md`, RDAP `team_agents/raven_identity.py`  
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

1. **Crypto paths (RAVEN)** authorize a *device key* only if Identity V1 cert verifies, validity window holds, and no covering lineage revoke (and no exhausted/corrupt fail-closed marker when RVDR1 prod is enabled).
2. **RDAP task / HTTP paths** authorize a *peer address* only if pinned in `trusted_peers`, not in the address revoke set, signature verifies, and replay is fresh — when `require_signed_tasks` is on.
3. **Neither stack’s revoke clears the other automatically** in V1. Propagation is an explicit operator or automation action under this policy.

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
- Silent inference that “address revoked ⇒ all devices denied in RAVEN” without an explicit device revoke (and vice versa), except playbook **B**.
- Using unsigned gossip to clear either deny-set.

## 3. Implementation expectations (docs → later eng)

| ID | Expectation | Stack |
|----|-------------|-------|
| E1 | Signed-mode RDAP: document that empty/missing revoke file means “no addresses revoked,” not “revocation disabled”; misconfig runbooks required | RDAP |
| E2 | OPEN MODE (`require_signed_tasks=false`) makes **no** authz claim; forbidden as default for shared/prod demos | RDAP |
| E3 | Authz code paths MUST use fail-closed registry/revoke loaders (`*_checked`); soft `unwrap_or_default` banned on those paths (P0 — held for Sprint 1 batch) | RAVEN |
| E4 | Joint test: device revoked in RAVEN vectors does not alone fail RDAP verify unless address revoke applied (and inverse for playbook B) | Interop / Adversarial QA |
| E5 | Operator one-pager: “stolen phone” vs “stolen identity” decision tree pointing at §2.3 | Docs |

## 4. Open questions for joint owners

1. Should signed-mode RDAP **require** a revocations file path (even if empty list) to force conscious config?
2. After Continuity V2 activation, is address rotation mandatory before clearing RDAP address revoke?
3. Who owns automated “B-playbook” fan-out of address revoke to fleet nodes (ops script vs protocol)?

## 5. Ack checklist

- [ ] Identity AuthZ (author)
- [ ] Raven↔RDAP
- [ ] RDAP Protocol
- [ ] Architect (trust-boundary alignment with Sprint 0 note)
