# ADR 0004 — Raven↔RDAP production ATSAM transport (O6)

**Status:** Proposed (awaiting Architect + Crypto + Identity ack)  
**Date:** 2026-09-04  
**Deciders (required ack before merge):** Architect, Crypto ATSAM, Identity AuthZ  
**Author:** Raven↔RDAP Integration Lead  
**Repos:** `Raven-ASHCO/RAVEN`, `Raven-ASHCO/raven-distributed-agent-protocol`  
**Related:** ADR 0003 (wire/crypto/identity/IPC), `protocol/RAVEN_MAILBOX_TRANSPORT_V1.md`, RDAP README “Important integration gap”, Manager Sprint 0 decisions 2026-09-04

## Context

RDAP today exchanges recipient-bound, Ed25519-signed A2A tasks primarily over **cleartext HTTP** on a trusted LAN, with an optional **experimental plaintext** libp2p mailbox (`raven-swarm-mailbox-experimental`, env `RDAP_ENABLE_EXPERIMENTAL_PLAINTEXT_MAILBOX` / `--experimental-plaintext-mailbox`). Task JSON may sit in an RVN1 field named `message_ciphertext` without being confidential.

Production Raven messaging is fail-closed: without a persisted authenticated **ATSAM** session, `raven-node` refuses origination with `ATSAM_SESSION_REQUIRED`. Local clients talk to the daemon over UDS IPC and may only **`EnqueueSealed`** / **`LanDial`** already-sealed frames — the daemon does not seal plaintext for callers.

RDAP also keeps a separate identity under `.team/keys`, while `raven-node` uses `~/.raven`. Unifying “A2A over production Raven Node” is the O6 KPI: a **two-device encrypted E2E harness**.

## Manager decisions locked for M0 (2026-09-04)

1. **O6 = transport E2E harness only.** Do **not** block on `RAVEN_USER_OWNED_AGENT_RUNTIME_V1` approval.
2. **Demo / confidentiality claim path = production ATSAM via `raven-node` only.** Signed HTTP may remain LAN bootstrap / control plane but **must never** be claimed confidential.
3. **O6 primary path = `LanDial` direct.** Production mailbox / offline is stretch, not a gate.
4. **M1 harness:** pin/use the **same RVN1** as local `raven-node` first. Document distinct `USER_AGENT_DEVICE` as follow-on per draft §3 — **do not** block M2 on a distinct credential.

## Decision

### D1 — Carrier of record for O6

Any claim of confidential / encrypted RDAP task delivery MUST mean:

- Task and reply application payloads are sealed under a **production ATSAM** session bound to the peer’s pinned Raven identity.
- Sealed `RavenEnvelopeV1` frames are submitted to and received from a running **`raven-node`** via documented IPC (`LanDial` primary; `EnqueueSealed` only where the dial path already established session/routing as specified by Crypto/Node IPC).
- The experimental swarm mailbox binary and cleartext HTTP A2A are **out of scope** for confidentiality claims.

### D2 — Control plane vs data plane

| Plane | Allowed in O6 | Confidentiality claim |
|---|---|---|
| Signed HTTP A2A (LAN) | Bootstrap, invite/trust, Agent Card, ping, status | **No** |
| HTTPS + Bearer | Optional hardening of control plane | Transport TLS only; still not Raven E2EE |
| ATSAM via `raven-node` `LanDial` | **Primary** task/reply data plane | **Yes** (O6 demo path) |
| Production opaque mailbox / bridge | Stretch | Yes if used; **not** O6 gate |
| `raven-swarm-mailbox-experimental` plaintext | Lab only, opt-in | **Never** |

Status / doctor surfaces MUST report an explicit carrier enum, e.g. `atsam_rvn1` | `http_signed` | `experimental_plaintext_mailbox`.

### D3 — Identity bridge (M1 minimal)

- For the O6 harness, RDAP MUST pin and use the **same RVN1 address and Ed25519 device key material** already owned by the local `raven-node` data dir (`~/.raven` or configured `--data-dir`), not a divergent `.team/keys` pair created in isolation.
- Mapping mechanism (read-only import, symlink of public material + IPC-mediated signing, or documented export) is an M1 implementation choice; **private keys MUST NOT** appear in IPC JSON (per ADR 0003 / `ipc.rs`).
- Distinct `USER_AGENT_DEVICE` credentials (agent runtime draft §3) are **documented follow-on**; M2 must not wait on them.

### D4 — Sealing ownership (M2)

- Sealing and session ratchet state live in **Raven** (`raven-core` / `raven-node`), not in Python reimplementations of ATSAM.
- Python RDAP obtains sealed frames only through: (a) IPC to a node that already holds the session, or (b) a future approved FFI/bindings surface owned by Crypto — **not** by stuffing plaintext into `message_ciphertext`.
- Fail-closed: without a usable ATSAM session, RDAP MUST surface `ATSAM_SESSION_REQUIRED` (or equivalent) and refuse to claim send success.

### D5 — Harness acceptance (M3)

Two devices (physical or VM), each with `raven-node` + RDAP:

1. Mutual pin of the same RVN1 identities used by each node.
2. Alice `ask` → Bob completes (echo provider fine); markers e.g. `RAVEN_A2A_OK_*`.
3. Data-plane frames are ATSAM-sealed (asserted by harness / negative: drop session → refuse).
4. Docs: replace “Important integration gap” with pointer to this ADR and O6 encrypted path.
5. Experimental mailbox remains available only behind explicit opt-in and labeled non-confidential.

### D6 — Merge / production gate

- **No production code merge** implementing M1–M3 until Architect, Crypto ATSAM, and Identity AuthZ **ack this ADR** (comment on PR or recorded ack in Eng Program tracker).
- ADR file lands under `docs/adr/0004-raven-rdap-atsam-transport.md` (and mirror `node/adr/` if that tree remains in sync).
- RDAP repo gets a short pointer to this RAVEN ADR (single source of truth in RAVEN) in a follow-up.

## Consequences

### Positive

- Honest security claims; closes the documented integration gap for the demo path.
- Reuses existing fail-closed ATSAM + IPC seams instead of a parallel crypto stack in Python.
- Clear split of control vs data plane reduces “signed = encrypted” confusion.

### Negative / costs

- O6 needs a working Python↔`raven-node` IPC client and session-ensure UX before task send.
- Same-key M1 is simpler but defers proper agent principal separation.
- HTTP control plane remains a LAN trust assumption unless operators add HTTPS.

### Out of scope (explicit)

- Approving or implementing `RAVEN_USER_OWNED_AGENT_RUNTIME_V1`.
- Making experimental mailbox production-ready.
- Full offline/DTN mailbox as O6 exit criterion.
- Changing Noise / libp2p swarm defaults unrelated to RDAP task path.

## Milestone sketch (for Eng Program; refine after ack)

| ID | Name | Target window (from 2026-09-04) | Owners (roles) |
|---|---|---|---|
| M0 | Spec freeze (this ADR) | Week 0–1 | Raven↔RDAP + Architect + Crypto + Identity |
| M1 | Identity bridge (same RVN1) | Week 1–3 | Identity + Node IPC + Python Runtime |
| M2 | Sealed carrier via IPC / LanDial | Week 3–6 | Node IPC + Crypto + RDAP Protocol + Python Runtime |
| M3 | Two-device encrypted harness | Week 6–8 | Adversarial QA + SRE + Eng Program + CLI DX |
| M4 | Doc/status: deprecate confidential claims for plaintext carriers | Parallel M3 | RDAP Protocol + Assurance |

Stretch: production mailbox offline leg after M3 green.

## References

- `node/crates/raven-core/src/ipc.rs` — `EnqueueSealed`, `LanDial`
- RDAP `team_agents/mesh.py` — experimental plaintext carrier
- RDAP README — Important integration gap
- RAVEN README — `ATSAM_SESSION_REQUIRED` / `unsafe-interim`

## Appendix G5 — Joint Raven↔RDAP revoke policy

See also `docs/adr/0004-appendix-g5-raven-rdap-revoke.md`.

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
