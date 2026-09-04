# Appendix G5 — Joint Raven↔RDAP revoke policy (docs-first)

**Status:** Proposed with ADR 0004 (Identity AuthZ Sprint 0 alignment)  
**Date:** 2026-09-04  
**Owners:** Raven↔RDAP + Identity AuthZ (ack required); Crypto consult on session fail-closed  
**Normative refs:** `protocol/RAVEN_DEVICE_REVOCATION_V1.md` (APPROVED companion; production still gated), RDAP `team_agents/raven_identity.py` (`load_revocations`, verify paths), ADR 0004 D3 (same RVN1 for O6/M1)

## G5.1 Two different instruments (do not conflate)

| Layer | Instrument | Target | Who mints | Sticky? | Scope |
|---|---|---|---|---|---|
| **R** | `RavenDeviceRevocationV1` (`RVDR1`) | **Device lineage**: `device_id` + `device_ed_pub` + `device_x_pub` + `device_cert_hash` under an `identity_address` | Owning **identity** Ed25519 key | Yes — append-only union; never clears | Messenger / PairInit / ATSAM authorization for that lineage |
| **A** | RDAP `revocations_file` | **RVN1 address** (peer principal string) | Local operator / deployment policy | Local file; hot-reload; not a signed global record | A2A HTTP + delegation verify; cancel auth; task accept |

**RAVEN non-goal (normative):** RVDR1 does **not** revoke an entire Raven identity/address.  
**RDAP today:** address revoke is exactly that coarser local deny — “do not accept this peer address.”

Naming rule for docs and UI: call layer R **device-lineage revoke**; call layer A **RDAP address deny** (avoid “identity revoke” for either unless a future RAVEN identity-revoke profile exists).

## G5.2 Honest coupling under O6/M1 (same RVN1)

ADR 0004 M1 pins RDAP to the **same RVN1** as local `raven-node`. That does **not** merge the instruments; it tightens **apply** rules:

1. **R → A (mandatory fail-closed for O6 data plane):**  
   If the local node has accepted an RVDR1 whose denied lineage identifiers cover the **peer device material** RDAP is using for that pin (for M1 single-device: the peer Ed25519 used in trust / ATSAM), then RDAP MUST treat that peer as **A2A-denied** for both control-plane verify and ATSAM task send/recv — even if the address is absent from `revocations_file`.  
   Rationale: signed HTTP or LanDial must not resurrect a lineage Raven already retired.

2. **A ↛ R (no auto-mint):**  
   Adding an RVN1 to RDAP `revocations_file` MUST NOT mint or forge RVDR1. It is local A2A policy only. Operators who need Raven-wide lineage retire still use identity-signed RVDR1 via ash/`raven-node` paths.

3. **Local self vs peer:**  
   Revoking **own** compromised device uses RVDR1 (layer R). Removing a **peer** from the agent team uses layer A (and/or untrust). Do not document “rdap revoke” as a substitute for device retirement.

4. **Follow-on (post-M2, distinct `USER_AGENT_DEVICE`):**  
   When agent credentials diverge from device lineage, layer A may deny an agent address without RVDR1; layer R may retire a device without deleting every agent grant — exact mapping deferred to Identity after agent-runtime gates; **not** an O6 blocker.

## G5.3 Partition and propagation (shared honesty)

Both layers inherit Raven’s **no instant global revoke**:

- RVDR1: eventual propagation as public endpoint objects; partitioned verifiers may still trust until they learn (`RAVEN_DEVICE_REVOCATION_V1` §1 non-claim).
- RDAP address deny: local file only unless operators distribute it out-of-band; no claim of mesh-wide A2A revoke in O6.

Status surfaces SHOULD expose separately:

- `raven_device_revocations_applied` (count / digests as appropriate)
- `rdap_address_deny_list` (configured path + count)
- `rdap_effective_peer_deny` (union after R→A apply)

## G5.4 Session / crypto fail-closed (Crypto consult)

When layer R denies a lineage used for an ATSAM session:

- Existing sessions MUST fail closed for further origination toward that peer (align `ATSAM_SESSION_REQUIRED` / session actor policy — exact opcode owned by Crypto).
- RDAP MUST NOT report task success after Raven refuse.
- Re-pair / new lineage required; no automatic session heal after revoke (RAVEN non-goal).

## G5.5 O6 harness expectations (docs / tests later)

| Case | Expected |
|---|---|
| Peer in `revocations_file` only | RDAP reject signed HTTP + refuse ATSAM ask; Raven may still have device authorized |
| RVDR1 applied covering peer device; address not in file | RDAP effective deny + Raven fail-closed; harness asserts both |
| Neither | Normal O6 encrypted path |
| Experimental mailbox | Still non-confidential; revoke policy still applies to task accept if drained into RDAP |

## G5.6 CODEOWNERS / review

- Appendix rides with ADR 0004: Architecture + Identity + Crypto ack.  
- Future code bridging R→A apply: `@Raven-ASHCO/identity` + `@Raven-ASHCO/rdap` (+ crypto for session close).  
- Risk class R3 for any revoke-apply wiring.

## G5.7 Open questions for Identity AuthZ Sprint 0

1. Confirm M1 single-device: peer pin Ed25519 ≡ device_ed_pub covered by RVDR1 (no separate identity-key pin in RDAP yet)?  
2. Should R→A apply also **remove** peer from `trusted_peers` live file, or only deny at verify time? (Recommend: deny at verify; optional UX untrust later.)  
3. Exhausted-marker / `IDENTITY_REVOKE_EXHAUSTED` — does RDAP inherit namespace fail-closed for that identity address in O6? (Recommend: yes, treat address as A2A-denied while marker active.)
