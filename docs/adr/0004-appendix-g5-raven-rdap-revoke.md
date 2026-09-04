# Appendix G5 — Joint Raven↔RDAP revoke policy (docs-first)

**Status:** Architect **ACK** Appendix G5 (restored 2026-09-04). Identity AuthZ **ACK** Appendix G5 (full). Crypto G5.4/G5.5 **ACK**. ADR 0004 three-way ACK complete. Docs-only; no M1; RVN1 HOLD bars production enablement.
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

## G5.2 O6/M1 apply rules (Architecture SoT = Identity PR #5 §2.2)

Engineering SoT: `docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md` (PR #5). ADR appendix MUST NOT diverge. Per ADR 0004 D3: ash-style pin = user identity → RVN1; **pin ≠ `device_ed_pub`** without explicit binding.

Copied from PR #5 §2.2 (3)–(7):

3. **A ↛ R (always):** Adding an RVN1 to RDAP `revocations_file` MUST NOT mint or forge RVDR1.
4. **R ↛ auto address-deny:** An accepted RVDR1 MUST NOT by itself require writing the identity `rvn1…` into RDAP `revocations_file`. Playbook A (stolen device, seed safe): other/new lineages under that identity may remain valid; do not conflate device-lineage revoke with address deny. Pin address ≠ `device_ed_pub` without an explicit binding.
5. **R → fail-closed on bound data-plane (mandatory):** If ATSAM / LanDial / RDAP task paths are using **device key material covered by an applied RVDR1**, those paths MUST refuse (session close / task reject / no task-success after Raven refuse). This is **lineage-scoped** deny, not address-scoped. Predicate = covering lineage identifiers (`device_id` / `device_ed_pub` / `device_x_pub` / `device_cert_hash`), **not** “pin string equals device_ed_pub.”
6. **Address revoke** remains playbook B/C (identity seed compromise or peer policy), plus operator file / `IDENTITY_REVOKE_EXHAUSTED` fail-closed for that address namespace while the marker is active.
7. Effective denies at verify time only — do not auto-edit `trusted_peers` or `revocations_file` from RVDR1 apply.

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
| E4 / playbook A: RVDR1 covering lineage **in use** | task / ATSAM / `LanDial` refuse **without** address on revoke list; re-pair **new** lineage succeeds; **no** address-file write for playbook A |
| Playbook B/C (separate) | Explicit address-deny test (`revocations_file` / pin replace); not implied by RVDR1 |
| Exhausted marker | A2A fail-closed for that address |

## G5.7 Closed decisions (not open questions)

- Pin ≢ `device_ed_pub` — premise **deleted**. This is **not** an open question asking pin≡device.
- No auto-edit of trust/revoke files on RVDR1.
- Exhausted marker ⇒ RDAP address A2A fail-closed: **yes**.
- Signed-mode require revocations path: **yes** (empty OK).
- Continuity: rotate/re-pin before clearing old address deny.
- B-playbook fan-out: ops script, not protocol auto (V1).

## G5.8 Review

Engineering SoT: PR #5 `docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md` §2.2 — G5.2 is a verbatim copy; appendix MUST NOT diverge. ADR body ACK stands. Architect Appendix G5 ACK withdrawn (conditional); awaiting re-ACK Appendix G5.
