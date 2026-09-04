# Appendix G5 — Joint Raven↔RDAP revoke policy (docs-first)

**Status:** Proposed with ADR 0004 — aligned to Identity AuthZ Sprint 0 `docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md`  
**Date:** 2026-09-04  
**Owners:** Raven↔RDAP + Identity AuthZ; Crypto consult on session fail-closed  
**Normative refs:** `protocol/RAVEN_DEVICE_REVOCATION_V1.md`, Identity G5 engineering draft, ADR 0004 D3, RDAP `team_agents/raven_identity.py`

## G5.1 Core distinction (do not conflate)

| Stack | Revokes | Wire / store | Effect |
|---|---|---|---|
| **RAVEN (R)** | **Device lineage** (`device_id`, `device_ed_pub`, `device_x_pub`, `device_cert_hash`) under one user identity | `RVDR1` + local sticky denylist | Device loses PairInit / envelope / ACK / bind; **identity address remains** |
| **RDAP (A)** | Peer **identity address** (`rvn1…`) | JSON `revocations_file` (hot-reload) | Reject `verify_delegation` / signed HTTP / task accept for that address |

Naming: **device-lineage revoke** (R) vs **RDAP address deny** (A). Avoid “identity revoke” unless a future RAVEN identity-revoke profile exists.

**File / mint cross-clear:** Neither stack’s revoke **file or mint** clears the other automatically in V1. Propagation of address-deny files or RVDR1 objects is an explicit operator or automation action (see playbooks). This does **not** weaken O6 **effective deny** in G5.2.

## G5.2 O6/M1 apply rules (same RVN1; no soft parallel identity)

Per ADR 0004 D3: RDAP binds to the local `raven-node` **user identity** that derives that RVN1; trust/invite MUST be an **ash-style contact pin** of that same RVN1 (no second pin namespace).

1. **No automatic file cross-write (V1):** RVDR1 apply MUST NOT auto-append the identity address to `revocations_file`. Address deny MUST NOT mint RVDR1 (**A ↛ R**).

2. **O6 effective deny (R → A at verify/send time):** If the local node has accepted an RVDR1 whose denied lineage identifiers cover the **peer device material bound to the current ash-style pin / ATSAM path**, RDAP MUST treat that peer as **A2A-denied** for control-plane verify and confidential send/recv — even when the address is absent from `revocations_file`.  
   Rationale: do not resurrect a retired lineage over signed HTTP or LanDial.  
   This is **not** playbook-A address revoke: after re-pair on a **new** lineage under the same address, re-pin and proceed without having poisoned the address deny list.

3. **Effective peer deny** = address-revoke-set ∪ pins whose current device material is RVDR1-covered ∪ (recommended) identity namespaces under `IDENTITY_REVOKE_EXHAUSTED` while the marker is active.

4. **`USER_AGENT_DEVICE` follow-on (after M2):** distinct principal under G5 — do not silently share revoke/authority with the user identity.

## G5.3 Incident playbooks (normative intent)

| Incident | Must do | Must not / notes |
|---|---|---|
| **A. Stolen device; identity seed safe** | Mint/apply **RVDR1** (or local sticky) for that lineage; close sessions; re-pair **new** lineage (no id/key reuse). O6 effective deny applies while old lineage is pinned. | **Do not** RDAP-address-revoke unless tasks from that identity must stop entirely. |
| **B. Identity seed compromised** | Continuity/recovery (Continuity V2 when applicable); **RDAP address revoke** on controlled nodes; revoke **all** known device lineages; re-pin **new** address after recovery. | Clear address deny on the old `rvn1…` only after new address is pinned (see G5.7). |
| **C. RDAP peer misbehavior / key disagreement** | **RDAP address revoke** + remove/replace ash-style pin. | Add device-lineage revoke only if the misbehavior is device-scoped. |
| **D. Partition / stale peer** | Documented lag: peers that have not observed RVDR1 may still trust until sync. | UX MUST NOT claim “revoked everywhere” after local apply alone. |

## G5.4 Normative extras

- **Signed HTTP invite/trust** = ash-style contact pin of that same RVN1 (ADR 0004 D3) — control plane only; never confidential.
- **OPEN MODE** (`require_signed_tasks=false`) makes **no** authz claim; forbidden as default for shared/prod / O6 demos.
- **Signed-mode revocations file path:** **required** when signed tasks are on. File may be empty (`[]` / `{"revoked":[]}`). **Missing path ⇒ fail-closed startup.** Empty list ⇒ no addresses revoked (not “revocation disabled”).
- Soft `unwrap_or_default` on registry/revoke loaders = **P0 held for Sprint 1** — out of this ADR.
- Status SHOULD expose separately: `raven_device_revocations_applied`, `rdap_address_deny_list`, `rdap_effective_peer_deny`.

## G5.5 Session fail-closed (Crypto)

When layer R denies a lineage used for an ATSAM session: fail closed for further origination; RDAP MUST NOT claim task success; re-pair on new lineage; no automatic session heal. Exact refuse opcode owned by Crypto.

## G5.6 Harness / joint tests (later eng)

| Case | Expected |
|---|---|
| Address on revoke list only | RDAP reject; Raven device may still be authorized |
| RVDR1 covers pinned device material; address **not** on list | RDAP **effective** deny + Raven fail-closed; re-pin new lineage → succeed without address-deny entry |
| Playbook B | Address deny + all lineages revoked |
| OPEN MODE | Not used in O6 harness |
| Experimental mailbox | Non-confidential; revoke/effective-deny still apply on accept |

## G5.7 Resolved open questions (Raven↔RDAP positions)

1. **Signed-mode require revocations file path (even if empty)?** **Yes** — see G5.4.  
2. **Continuity V2 → address rotation before clearing address revoke?** **Yes** — old address stays denied until new pin is live; Identity Continuity owns gate text.  
3. **B-playbook fleet fan-out?** **Ops/automation (script), not protocol auto**, for V1.  
4. **R→A remove from `trusted_peers` file?** **No** for V1 — verify/send-time effective deny only; optional UX untrust later.  
5. **`IDENTITY_REVOKE_EXHAUSTED`?** **Yes** — treat address as A2A-denied while marker active (O6 recommend).

## G5.8 Review

Appendix rides with ADR 0004 (Architect + Identity + Crypto). Engineering source of truth for playbooks: `docs/engineering/G5_CROSS_STACK_REVOKE_POLICY.md` (keep E4 aligned with G5.2 effective deny, not “device revoke never affects RDAP”).
