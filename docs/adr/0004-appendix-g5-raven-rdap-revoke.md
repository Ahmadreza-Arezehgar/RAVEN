# Appendix G5 — Joint Raven↔RDAP revoke policy (docs-first)

**Status:** Proposed with ADR 0004 — revision addressing Identity **BLOCK** on G5.2 (2026-09-04)  
**Date:** 2026-09-04  
**Owners:** Raven↔RDAP + Identity AuthZ; Crypto consult on session fail-closed  
**Normative refs:** `protocol/RAVEN_DEVICE_REVOCATION_V1.md`, Identity `docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md`, ADR 0004 D3, RDAP `team_agents/raven_identity.py`

## G5.1 Core distinction (do not conflate)

| Stack | Revokes | Wire / store | Effect |
|---|---|---|---|
| **RAVEN (R)** | **Device lineage** (`device_id`, `device_ed_pub`, `device_x_pub`, `device_cert_hash`) under one user identity | `RVDR1` + local sticky denylist | Device loses PairInit / envelope / ACK / bind; **identity address remains** |
| **RDAP (A)** | Peer **identity address** (`rvn1…`) | JSON `revocations_file` (hot-reload) | Reject `verify_delegation` / signed HTTP / task accept for that address |

**Identity V1 tiers (normative):**

- **User identity** Ed25519 → `RavenAddressV1` — this is what RDAP pins (`trusted_peers` / ash-style contact pin / `raven_identity` address key), even if an on-disk seed file is named `device_ed25519.seed`.
- **Device** Ed25519/X25519 → `device_ed_pub` / cert — **RVDR1 covers this lineage only** and does **not** revoke the address.

Therefore: **M1 pin Ed25519 ≢ `device_ed_pub`.** RVDR1 cannot “cover” the pin key.

Naming: **device-lineage revoke** (R) vs **RDAP address deny** (A). Avoid “identity revoke.”

**File / mint cross-clear:** Neither stack’s revoke file or mint clears the other automatically in V1.

## G5.2 O6/M1 apply rules (Identity BLOCK revision)

Per ADR 0004 D3: RDAP binds to the local `raven-node` **user identity** that derives that RVN1; trust/invite MUST be an **ash-style contact pin** of that same RVN1 (no second pin namespace).

1. **R → data-plane fail-closed (mandatory for O6):**  
   If an accepted RVDR1 covers the peer **device lineage** used for PairInit/ATSAM with that contact, RDAP MUST fail-closed **ATSAM / `LanDial` task send-recv** (no task-success after Raven refuse) — even when the address is absent from `revocations_file`.

2. **R ↛ A (default):**  
   RVDR1 MUST NOT by itself imply layer-A **address deny**, remove the ash-style pin, or auto-edit `trusted_peers` / `revocations_file`. Address deny remains playbook **B** (seed compromise), explicit operator file action, or exhausted-marker policy (G5.7).

3. **A ↛ R (unchanged):**  
   Adding an RVN1 to `revocations_file` MUST NOT mint or forge RVDR1.

4. **Harness note (optional, documented):**  
   O6 single-device demos MAY set an **explicit knob** that also denies control-plane verify when that peer has no remaining authorized device. Default normative policy is **data-plane-only** fail-closed (preserves playbook **A**: stolen phone, seed safe → lineage revoke only; do not address-deny).

5. **`USER_AGENT_DEVICE` follow-on (after M2):** distinct principal under G5 — do not silently share revoke/authority with the user identity.

## G5.3 Incident playbooks (normative intent)

| Incident | Must do | Must not / notes |
|---|---|---|
| **A. Stolen device; identity seed safe** | Mint/apply **RVDR1** (or local sticky) for that lineage; close sessions; re-pair **new** lineage (no id/key reuse). O6 data-plane fail-closed while that lineage was the ATSAM peer. | **Do not** RDAP-address-deny unless *all* tasks from that identity must stop. |
| **B. Identity seed compromised** | Continuity/recovery; **RDAP address deny** on controlled nodes; revoke **all** known device lineages; re-pin **new** address after recovery. | Clear address deny on old `rvn1…` only after new address is pinned. |
| **C. RDAP peer misbehavior / key disagreement** | **RDAP address deny** + remove/replace ash-style pin. | Add device-lineage revoke only if device-scoped. |
| **D. Partition / stale peer** | Documented lag; peers that have not observed RVDR1 may still trust until sync. | UX MUST NOT claim “revoked everywhere” after local apply alone. |

## G5.4 Normative extras

- **Signed HTTP invite/trust** = ash-style contact pin of that same RVN1 — control plane only; never confidential.
- **OPEN MODE** (`require_signed_tasks=false`) = no authz claim; forbidden as default for shared/prod / O6 demos.
- **Signed-mode revocations file path:** **required** when signed tasks are on. Empty list OK (`[]` / `{"revoked":[]}`). **Missing path ⇒ fail-closed startup.**
- Soft `unwrap_or_default` on registry/revoke loaders = **P0 held for Sprint 1** — out of this ADR.
- Status SHOULD expose: `raven_device_revocations_applied`, `rdap_address_deny_list`, `rdap_data_plane_fail_closed` (and optional demo knob state).

## G5.5 Session fail-closed (Crypto)

When layer R denies the device lineage used for an ATSAM session: fail closed for further origination; RDAP MUST NOT claim task success; re-pair on new lineage; no automatic session heal. Exact refuse opcode owned by Crypto.

## G5.6 Harness / joint tests (later eng)

| Case | Expected |
|---|---|
| Address on deny list only | RDAP reject control + data plane; Raven device may still be authorized |
| RVDR1 covers peer device lineage; address **not** on list | **Data-plane** fail-closed (ATSAM/LanDial); control-plane verify may still succeed unless demo knob set; playbook A intact |
| Playbook B | Address deny + all lineages revoked |
| OPEN MODE | Not used in O6 harness |
| Exhausted marker active | A2A fail-closed for that address (G5.7) |

## G5.7 Open questions — Identity answers (adopted)

1. **Pin Ed25519 ≡ `device_ed_pub`?** **No.** Pin is **user identity** pub (→ RVN1). Premise deleted.
2. **Auto-edit `trusted_peers` / revocations on RVDR1?** **No** — verify/send-time data-plane fail-closed only; optional UX later.
3. **`IDENTITY_REVOKE_EXHAUSTED`?** **Yes** — while active for that identity namespace, RDAP MUST fail-closed A2A for that address (authz state untrustworthy).
4. **Signed-mode require revocations file path?** **Yes** (Raven↔RDAP; empty OK; missing fail-closed) — see G5.4.
5. **Continuity V2 clear address deny?** Rotate/re-pin new address before clearing old deny.
6. **B-playbook fan-out?** Ops/automation script, not protocol auto, for V1.

## G5.8 Review

Appendix rides with ADR 0004. Engineering playbook SoT: `docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md` — keep E4 aligned with **data-plane fail-closed**, not “RVDR1 ⇒ address deny.”
