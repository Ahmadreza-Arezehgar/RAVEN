# Appendix G5 — Joint Raven↔RDAP revoke policy (docs-first)

**Status:** Proposed with ADR 0004 — Identity §4/G5.7 answers ACK’d; awaiting **ACK G5** on this predicate; Crypto **ACK** G5.4/G5.5  
**Date:** 2026-09-04  
**Owners:** Raven↔RDAP + Identity AuthZ; Crypto consult on session fail-closed  
**Normative refs:** `protocol/RAVEN_DEVICE_REVOCATION_V1.md`, Identity `docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md` (PR #5), ADR 0004 D3

## G5.1 Core distinction (do not conflate)

| Stack | Revokes | Wire / store | Effect |
|---|---|---|---|
| **RAVEN (R)** | **Device lineage** (`device_id`, `device_ed_pub`, `device_x_pub`, `device_cert_hash`) under one user identity | `RVDR1` + local sticky denylist | Device loses PairInit / envelope / ACK / bind; **identity address remains** |
| **RDAP (A)** | Peer **identity address** (`rvn1…`) | JSON `revocations_file` (hot-reload) | Reject verify / signed HTTP / task accept for that address |

**Identity V1 tiers:**

- **User identity** Ed25519 → `RavenAddressV1` — RDAP ash-style pin / `trusted_peers` (even if a seed file is named `device_ed25519.seed`).
- **Device** Ed25519/X25519 → `device_ed_pub` / cert — **RVDR1 covers this lineage only** and does **not** revoke the address.

**M1 pin Ed25519 ≢ `device_ed_pub`.** RVDR1 cannot cover the pin key.

Naming: **device-lineage revoke** (R) vs **RDAP address deny** (A). Avoid “identity revoke.”

## G5.2 O6/M1 apply rules (Architect + Identity binding)

Per ADR 0004 D3: same raven-node RVN1; PairInit / device-cert / transcript binding; ash-style contact pin of that RVN1 (user identity → RVN1). **Pin ≢ `device_ed_pub`.**

1. **A ↛ R (always):** Address deny MUST NOT mint RVDR1. **No automatic file cross-write** either direction.

2. **R ↛ auto address-deny (playbook A):** Accepted RVDR1 MUST NOT by itself write the identity into `revocations_file`, remove the ash-style pin, or imply layer-A address deny. Stolen device / seed safe → lineage revoke + data-plane fail-closed only.

3. **R → fail-closed on bound data-plane (mandatory):** When accepted RVDR1 covers the **device lineage material actually used** for ATSAM / `LanDial` / task on this node, RDAP MUST refuse that bound data-plane (lineage-scoped; Crypto hard deny — not soft `ATSAM_SESSION_REQUIRED` same-lineage re-pair) — even when the address is absent from `revocations_file`. Predicate = covering **lineage ids**, **not** pin≡`device_ed_pub`.

4. **Address deny = playbook B/C** + explicit operator `revocations_file` + `IDENTITY_REVOKE_EXHAUSTED` while marker active. Verify-time only; no auto-edit of trust/revoke files on RVDR1.

## G5.3 Incident playbooks

| Incident | Must do | Must not |
|---|---|---|
| **A. Stolen device; seed safe** | RVDR1 / sticky; close sessions; re-pair **new** lineage; data-plane fail-closed while that lineage was ATSAM peer | **Do not** auto address-deny |
| **B. Identity seed compromised** | Continuity; **address deny** on controlled nodes; revoke **all** lineages; re-pin new address | Clear old address deny only after new pin live |
| **C. RDAP peer misbehavior** | Address deny + replace ash-style pin | Lineage revoke only if device-scoped |
| **D. Partition lag** | Documented residual | No “revoked everywhere” UX after local apply alone |

## G5.4 Normative extras

- Signed HTTP invite/trust = ash-style pin of same RVN1 (control plane only).
- OPEN MODE = no authz claim; never O6/shared default.
- Signed-mode: **require** revocations file path (empty `[]` OK; missing path fail-closed).
- Soft-load P0 = Sprint 1 / out of this ADR.

## G5.5 Session fail-closed (Crypto ACK)

Fail closed for further origination; RDAP never claims success after Raven refuse; no auto-heal; re-pair only on **new** lineage. Prefer distinct hard deny (`DEVICE_REVOKED` / `ATSAM_LINEAGE_REVOKED`); freeze IPC string with Identity at M2. Until freeze: any Raven refuse on revoked lineage = hard deny.

## G5.6 Harness expectations

| Case | Expected |
|---|---|
| Address on deny list only | RDAP reject; Raven device may still be authorized |
| E4 / playbook A: RVDR1 covers peer device lineage **in use** | ATSAM / `LanDial` / task refuse **without** address on revoke list; re-pair **new** lineage ⇒ succeed; address revoke file **never written** |
| Playbook B/C (separate) | Explicit address-deny test (`revocations_file` / pin replace); not implied by RVDR1 |
| Exhausted marker | A2A fail-closed for that address |

## G5.7 Closed decisions (not open questions)

- Pin ≢ `device_ed_pub` (premise **deleted**).
- No auto-edit of trust/revoke files on RVDR1.
- Exhausted marker ⇒ RDAP address A2A fail-closed: **yes**.
- Signed-mode require revocations path: **yes** (empty OK).
- Continuity: rotate/re-pin before clearing old address deny.
- B-playbook fan-out: ops script, not protocol auto (V1).

## G5.8 Review

Engineering SoT playbooks: PR #5 `docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md` — must match this G5.2 four-point predicate. ADR body Identity ACK and §4/G5.7 answers stand; this appendix awaits Identity **ACK G5** on this predicate.
