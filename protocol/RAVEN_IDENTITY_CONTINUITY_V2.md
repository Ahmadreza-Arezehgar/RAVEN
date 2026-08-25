# RAVEN Identity Continuity and Recovery V2

**Profile:** `RavenIdentityContinuityV2`

**Document revision:** 6

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no V2 address, identity migration, guardian ceremony, key rotation, account recovery, session reset, public recovery log, codec, database migration, live callsite, or Release flag

**Depends on:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md), [`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md), [`RAVEN_ADDRESS_V1.md`](RAVEN_ADDRESS_V1.md), [`RAVEN_ID_RESOLUTION_V1.md`](RAVEN_ID_RESOLUTION_V1.md), [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md)

**Related but authority-independent:** [`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md) restores eligible user data under a separate recovery secret; it is not an identity recovery factor.

**Unblocks when APPROVED:** a stable V2 continuity identity whose operational key can rotate; non-custodial device-loss/compromise recovery; proactive V1→V2 migration; continuity-aware ID Resolution, device authorization, messaging, and social repositories

> Recovery continues an identity authority. It does not recover deleted plaintext, session roots, old message keys, a forgotten V1 private key, or proof of a real-world person.

---

## 0. Why V2 is necessary

Raven Identity V1 deliberately defines an Ed25519 public key as the identity and derives `RavenAddressV1` directly from that key. Losing the private key loses the identity. Replacing the key changes the identity and address. Those frozen bytes cannot be reinterpreted without breaking every verifier and safety number.

Raven therefore does **not** claim to recover an unprepared V1 identity. It introduces a new V2 concept:

```text
immutable continuity anchor / address
            |
            +-- current operational identity key
            +-- current recovery-policy commitment
            +-- append-only continuity event DAG
```

The V2 address identifies the immutable genesis anchor, not the current operational key. Operational keys and device authorizations can rotate while the continuity identifier remains stable.

Existing V1 users may migrate only while they still control the V1 key (§13). If the V1 key was lost before a valid migration record was created and pinned, there is no cryptographic recovery path.

---

## 1. Goals and non-goals

### 1.1 Goals

1. Stable continuity across operational-key rotation and device loss.
2. No Raven-operated recovery server, escrow database, phone-number reset, or support override.
3. Pre-authorized M-of-N recovery using independent, dedicated recovery keys.
4. No secret-sharing of plaintext, message history, session roots, or social graph with guardians.
5. Exact append-only evidence; no hidden history rewrite or last-arrival-wins rule.
6. Explicit handling of compromise, partitions, stale policy, guardian collusion, and conflicting quorum events.
7. Key-role separation among continuity anchor, operational identity, devices, recovery delegates, namespaces, and sessions.
8. Multi-source distribution plus Key Transparency/monitoring without making one directory authoritative.
9. Safe migration for prepared V1 identities without changing V1 parsing.
10. Honest user-visible continuity states rather than a misleading “account recovered” boolean.

### 1.2 Non-goals

V2 does not provide:

- recovery of a V1 identity after its only private key is already lost;
- recovery of deleted chat history, old ratchet keys, media keys, or private archives; eligible data recovery is a separate, independently keyed [`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md) operation;
- proof that the recovering party is the same biological/legal person;
- instant global activation/revocation under partition;
- a central support override, administrator reset, email/SMS fallback, or mandatory cloud account;
- hidden or deniable recovery: an activated recovery event is durable public continuity evidence;
- universal protection when M recovery delegates collude or their keys are compromised;
- a right for a guardian to read contacts, messages, repositories, aliases, or device secrets;
- automatic trust of a new operational key by legacy V1 implementations;
- FROST, Shamir sharing, custom DKG, blockchain, stake, or proof-of-personhood in the baseline;
- post-quantum identity authentication: the baseline delegate/operational signatures are classical Ed25519 and make no quantum-forgery claim;
- automatic restoration of active sessions after recovery;
- global consensus over two conflicting valid threshold recoveries.

---

## 2. Threat model and unavoidable limits

The design considers:

- loss or theft of every current device;
- compromise of the current operational identity private key;
- compromise, loss, coercion, collusion, or unavailability of recovery delegates;
- a malicious recovery coordinator substituting a new key/event;
- phishing a guardian into signing a generic or different operation;
- replay, truncation, sequence gaps, event forks, policy rollback, and source withholding;
- a compromised directory, resolver, transparency log, witness, relay, mirror, or carrier;
- correlation of recovery delegates and identities through public evidence or network traffic;
- stale backup restoration and protected-state corruption;
- attacker-created normal rotations racing a legitimate recovery;
- two independently assembled valid recovery quorums;
- advisory timestamp manipulation and partition-dependent first-seen times.

If at least M current recovery delegate keys collude, they can authorize a recovery. Cryptography cannot distinguish their collusion from the owner's intended quorum. If two valid quorums produce conflicting events in the same recovery generation, Raven preserves both and enters terminal continuity conflict; it does not choose by time, digest order, popularity, source count, or arrival.

No partitioned verifier can prove it has the globally latest policy/event. Protected pins, multi-source sync, Key Transparency monitoring, delay windows, and contact confirmation reduce risk but do not create instant global knowledge.

The baseline threat model is classical for identity/recovery signatures. ATSAM's hybrid confidentiality does not make Ed25519 recovery authorization post-quantum. A future hybrid/PQ signature transition needs a new profile, cross-signing/migration rules, vectors, and review; it cannot silently relabel these bytes as quantum-authenticated.

---

## 3. Identity layers and identifiers

### 3.1 Continuity identity

A later wire companion must freeze a canonical `RavenContinuityGenesisV2` with at least:

```text
profile_and_version
genesis_nonce[32]                 # nonzero CSPRNG
initial_operational_ed_pub[32]
genesis_context[32]
initial_recovery_policy_core_digest
initial_device_policy_digest?
created_at_ms                     # advisory; never ordering authority
continuity_id
operational_signature
```

Derivation is deliberately two-stage and non-circular:

1. `genesis_context = H("Raven/v2/continuity/genesis-context" || profile || genesis_nonce || initial_operational_ed_pub)`.
2. Construct the sequence-1 recovery-policy **core** against `genesis_context`; it has no `continuity_id` field because that ID does not exist yet.
3. Compute `initial_recovery_policy_core_digest` over that canonical core, excluding all authorization signatures/proofs.
4. Compute `continuity_id = H("Raven/v2/continuity/id" || canonical_genesis_core_without_continuity_id_or_signatures)`, which includes both `genesis_context` and the exact bootstrap-policy core digest.
5. The initial operational key signs the final canonical genesis signing preimage containing `continuity_id`.

Later policies/events bind both the resulting `continuity_id` and immutable `genesis_context`. A different bootstrap policy produces a different continuity ID. RNG failure, all-zero nonce, or owner-local nonce collision refuses creation. No mutable alias, handle, source, device ID, server URL, timestamp, or recovery delegate label is an identity input.

The exact `RavenAddressV2` encoding is a separate freeze. It derives from `continuity_id`, uses a new version byte/profile, and is never accepted as RavenAddressV1. The visible address remains stable across all valid V2 control events.

### 3.2 Operational identity key

The current operational Ed25519 key:

- signs V2 DeviceSets, device certificates, resolution records, repo writer grants, capabilities, and normal control events;
- is authorized only by the exact active continuity state/generation;
- is not the immutable address anchor;
- may rotate without changing the V2 address;
- cannot alone change/reduce the recovery policy;
- cannot cancel or override a valid recovery quorum by itself.

Every V2 signature-bearing record binds at least `(continuity_id, continuity_generation, control_head_digest, operational_key_digest, profile)` so bytes from another generation/key cannot transplant.

### 3.3 Device keys

Device Ed25519/X25519 keys remain separate from the operational identity key. Device certificates bind the exact V2 continuity state and are invalid for new admission after that state is superseded. Recovery activates a default **retire-all-prior-device-lineages** barrier; selectively preserving an old device is forbidden in baseline V2 because a lost/compromised device may be the reason for recovery.

### 3.4 Recovery delegate keys

Each delegate uses a dedicated Ed25519 recovery key generated only for one continuity identity and policy lineage. It MUST NOT reuse:

- the delegate's own Raven identity/operational/device key;
- the subject's operational/device key;
- a namespace/log/witness key;
- a recovery key from another identity or policy generation;
- a messaging/session/capability key.

Dedicated pseudonymous keys prevent the public recovery proof from automatically revealing the guardian's Raven identity. The act of using a key still reveals that recovery public key and may be linkable through ceremony/network metadata; UI and documentation must say so.

---

## 4. Recovery policy

### 4.1 Public commitment

A `RavenRecoveryPolicyV2` semantically contains:

```text
policy_profile
continuity_id?                    # absent only in bootstrap core
genesis_context[32]
continuity_generation
policy_sequence_u64
previous_policy_digest?
delegate_count_n
threshold_m
delegate_merkle_root
delegate_leaf_profile
allowed_recovery_actions
activation_delay_ms
policy_not_after_ms?
ceremony_policy_digest
policy_nonce[32]
current_operational_signature?    # absent in embedded bootstrap; genesis signature authorizes it
prior_policy_quorum_proofs[]?     # absent only at genesis
```

The bootstrap policy core has sequence 1, no continuity ID, no previous digest, and is committed by the genesis derivation in §3.1. Later policy objects include the exact continuity ID, increment sequence exactly by one, bind the immediately previous exact policy-object digest, and require both:

1. the current operational key; and
2. M valid delegates from the **previous** policy.

An operational-key compromise alone therefore cannot replace guardians or lower the threshold. A guardian quorum alone performs recovery but cannot silently alter policy through a normal update path.

Every policy has a canonical **core** separate from its authorization block. `policy_core_digest` excludes `current_operational_signature` and quorum signatures/proofs; each authorization signs that exact core digest plus the previous exact policy-object digest. The exact policy-object digest covers core and canonical authorizations. No signature, proof, Merkle root, policy digest, or continuity ID is defined through a self-referential preimage.

### 4.2 Threshold bounds

For an enabled policy:

```text
2 <= M <= N <= 16
```

Production UX SHOULD default to a loss-tolerant policy such as 2-of-3, but this document does not freeze a universal default. `N < M + 1` provides no tolerance for losing one delegate and must be clearly warned. Recovery may also be disabled; disabled does not mean centrally recoverable.

A delegate is an independent recovery **factor**, not necessarily another person. It may be a separate offline recovery card, hardware device, the owner's secondary device, or a trusted person's dedicated recovery key. UX must encourage distinct failure domains; storing enough factors under one phone, one password manager, one cloud account, or one custodian defeats the threshold claim and is reported as a degraded policy.

### 4.3 Merkle-committed delegates

Each leaf commits to:

```text
leaf_version
genesis_context[32]
policy_sequence_u64
policy_nonce[32]
unique_leaf_index_u16
recovery_ed_pub[32]
allowed_action_bits
leaf_nonce[32]
```

Leaves are canonically ordered by index before building the domain-separated Merkle tree. Duplicate indices/keys/nonces, all-zero keys/nonces, unknown critical action bits, or out-of-range leaves reject the policy.

Leaves bind the immutable genesis context, policy sequence, unique index, action scope, and policy nonce; they do **not** bind the policy digest that depends on their own Merkle root. The final guardian assignment additionally carries and verifies the exact completed policy-object/core digests.

The public policy reveals M/N and the root but not every delegate key. A recovery proof reveals only participating keys/leaves and their inclusion paths. This hides non-participating delegates, not the threshold size or the recovery event.

### 4.4 Policy expiry and freshness

Policy expiry is a maximum authorization window, not proof of global freshness. An expired greatest-known policy never causes fallback to an older policy. Recovery pauses until a valid successor/explicit repair is verified. A source-provided lower policy, higher source count, or older valid signature cannot reset the greatest local pin.

Because retirement knowledge is eventual, a recovery under a withheld older policy can produce conflict when a newer policy is later learned. Raven does not resolve that ambiguity with untrusted timestamps; it enters recovery-policy conflict and requires explicit evidence/re-trust.

---

## 5. Guardian assignment and ceremony

### 5.1 Assignment

For a human/remote guardian, the guardian generates the dedicated key locally and returns only its public key plus a domain-separated proof of possession over the proposed policy context. The owner never receives that guardian private key. An owner-managed offline card/hardware factor may be generated by the owner's ceremony device only through an explicit export flow that verifies the backup and then wipes temporary material.

The owner gives each delegate an encrypted/offline `RavenRecoveryAssignmentV2` containing only:

- exact continuity address/ID and human safety fingerprint;
- exact policy digest/sequence;
- that delegate's key material or public-key assignment, leaf, and Merkle path;
- M/N, allowed action bits, expiry, and ceremony instructions;
- a local owner label chosen by the guardian;
- recovery software/profile version and checksum.

Assignment does not reveal contacts, devices, aliases, message history, social graph, repositories, other delegates, or session keys. Accepting it creates neither a Raven contact nor a public graph edge.

Before marking setup ready, the owner verifies a proof of possession for every intended delegate leaf and confirms that at least M factors are in distinct intended failure domains. These readiness proofs remain local and do not reveal the full leaf set publicly. A policy may still exist cryptographically when setup is incomplete, but UI must show `RECOVERY_NOT_READY` and production workflows must not claim recoverability.

The assignment secret is protected at rest using the platform-approved protected-store profile or an explicit offline medium. Screenshot/cloud clipboard/export requires a separate warning and does not become a supported silent backup.

### 5.2 Signing ceremony

A guardian signs only an exact `RavenRecoveryProposalV2` digest displaying:

```text
continuity fingerprint
current known generation/head fingerprint
policy fingerprint and M-of-N
new operational-key fingerprint
event kind and retire-all-devices effect
coarse activation-delay policy
unique ceremony nonce
proposal digest / short verification words
```

The proposal can move by QR, local file, NFC, cable, or an already authenticated channel. Transport does not authenticate it. The guardian verifies the exact continuity/policy assignment, scans/parses bounded bytes, compares the human fingerprint through an independent channel when policy requires, and explicitly approves.

The canonical proposal core is byte-for-byte the recovery/deactivation event core **excluding only** its authorization block. It includes every authority-relevant field, including exact base/parent, next generation, policy digest, action, new key (if any), delay parameters, event nonce, and bounded observed-head evidence. The final event embeds that unchanged core. The coordinator may only append a canonical authorization block sorted by unique delegate leaf index plus the exact new-key proof of possession where required; it cannot edit or add unsigned semantics.

Guardian signatures and the new-key proof bind the exact event-core digest. They cannot be replayed for another identity, policy, generation, operation, head set, action, or key. Duplicate signer/leaf indices reject the event rather than counting twice.

The coordinator never receives a guardian private key or generic signing oracle. A rejected, timed-out, or incomplete ceremony has no identity effect.

### 5.3 Recovery share hygiene

Temporary proposal bytes, signature nonces, decrypted assignment material, and intermediate secret buffers are zeroized. Long-lived delegate secrets are non-exportable where the approved platform allows, otherwise encrypted with an explicit backup/export policy. Logs show only redacted fingerprints/error classes.

---

## 6. Continuity event DAG

### 6.1 State coordinates

Each active state has:

```text
(continuity_id, continuity_generation_u64, operation_sequence_u64, control_head_digest)
```

Genesis is `(generation=0, operation_sequence=0)`. All arithmetic uses checked increments; wrap is terminal.

### 6.2 Event types

| Event | Authorization | Effect |
|---|---|---|
| `NORMAL_KEY_ROTATION` | Current operational signature + exact new-key proof of possession | Same generation; `sequence+1`; new operational key; policy unchanged |
| `POLICY_UPDATE` | Current operational signature + current-policy M-of-N proofs | Same generation; `sequence+1`; new policy sequence/root |
| `RECOVERY_ROTATION` | Current-policy M-of-N proofs + exact new-key proof of possession | `generation+1`, sequence resets to 0; new operational key; retire all prior devices/sessions |
| `RECOVERY_AND_POLICY_ROTATION` | Current-policy M-of-N proofs + exact new-key proof of possession | Same recovery effect plus new policy committed by old quorum |
| `DEACTIVATE` | Current-policy M-of-N proofs plus frozen delay/confirmation policy | Terminal no-new-admission state; not erasure |

Normal rotation and policy update bind the exact current head as parent. Recovery binds an exact base in the immediately prior continuity generation, the exact policy digest valid at that base, checked `base_generation + 1`, and bounded `observed_superseded_head_digests[]` as signed evidence. It cannot skip a recovery generation. Observed heads aid audit but neither omission nor inclusion changes quorum authority. Every event that installs a new operational key carries a signature by that new key over the exact event/proposal core; this proves possession but supplies no recovery authority. The event never deletes or rewrites superseded bytes.

### 6.3 Selection and conflicts

Rules:

1. Exact event replay is idempotent.
2. A normal event with the wrong generation, non-consecutive sequence, or non-current parent is stale/gap/fork evidence; it does not silently become current.
3. A valid recovery at generation `g+1` supersedes every normal operational branch in generation `g` once admitted and activated.
4. Two different valid quorum-authorized recovery events targeting the same next generation are **terminal recovery conflict**. Neither wins by timestamp, arrival, digest order, source, witness count, or popularity.
5. Two different normal events in one unique `(generation, sequence, parent)` slot are authenticated operational-key conflict and suspend automatic key advancement until a valid later recovery or explicit re-trust.
6. An unknown gap never authorizes skipping.
7. A lower generation never becomes current after a higher generation is protected/pinned.
8. A newly learned policy/recovery contradiction is preserved and surfaced; it is never silently rewritten into a single history.

### 6.4 Activation delay

A policy may require a delay before a verified recovery event becomes active. Since there is no trusted global clock, each verifier measures the delay from its own protected first-verified monotonic event. During pending recovery:

- no new contact acceptance, PairInit, device authorization, public writer grant, capability grant, or sensitive send is allowed under either competing key;
- existing UI shows `RECOVERY_PENDING`, the new key fingerprint, evidence source/time limits, and independent confirmation actions;
- exact event replay is idempotent and does not reset the delay;
- state rollback/reinstall does not restart or bypass the protected first-seen marker;
- a local user may apply a separately frozen out-of-band confirmation policy, but a source/relay cannot accelerate activation.

Activation occurs at different real times across partitions. The delay reduces surprise; it is not global consensus.

The current operational key alone cannot cancel a quorum event because it may be compromised. Cancellation/replacement requires a valid quorum event under the controlling policy or explicit local re-trust after terminal conflict.

---

## 7. Recovery admission pipeline

Before any continuity mutation:

1. parse exact bounded bytes and reject unknown critical fields;
2. recompute continuity/event/policy/proposal digests and address binding;
3. load protected greatest continuity/policy heads and pending journals;
4. verify event coordinates, base/parent, generation, sequence, and checked arithmetic;
5. verify every revealed delegate key/leaf/Merkle proof and reject duplicates;
6. verify at least M distinct valid signatures for the exact action;
7. apply local block/quarantine and conflict rules;
8. reserve bounded storage/CPU before expensive optional proof work;
9. create candidate continuity state, retire-all barrier, and exact output intents;
10. persist protected journal → SQL/index mutation → protected head/anchor → clear journal;
11. only after commit release UI state, resolution publication, DeviceSet issuance, or re-pair work.

Failure before protected journal leaves canonical state unchanged. Recovery after a persisted journal always rolls forward idempotently. It never rolls back a generation, reuses a one-shot ceremony, releases a new key before commit, or clears conflict evidence by quota eviction.

---

## 8. After an activated recovery

### 8.1 Devices and sessions

Activation atomically marks every pre-recovery device certificate/lineage ineligible for new V2 admission. The new operational key issues a fresh DeviceSet and fresh device certificates. All ATSAM/Noise sessions authenticated under prior continuity state close; peers re-run explicit V2 PairInit after local recovery policy permits.

Recovery does not decrypt old ciphertext or reconstruct skipped keys. Locally retained history remains only where that local endpoint already possesses approved at-rest keys.

### 8.2 Resolution and transparency

ID Resolution publishes the exact recovery/control event chain, new DeviceSet, new operational key, and transparency evidence. Resolver presence, DHT order, namespace handle, mirror popularity, or a server timestamp cannot activate the event. Contacts/owners monitor the stable continuity ID and greatest pinned generation/head.

Key Transparency can make conflicting views detectable under its deployment assumptions; it is not a recovery authority. A log/operator cannot mint a valid quorum event.

### 8.3 Social repositories

V2 social repository ownership binds `continuity_id` plus historical control-head evidence, not one forever-operational key. Old immutable records remain verifiable against the control state admitted at their writer slot. New writer grants and records use the activated operational key/generation.

Advisory record time cannot prove “created before compromise.” Previously admitted records retain exact historical evidence. Records first presented after recovery under retired devices/keys may be denied according to the greatest known continuity/revocation state.

### 8.4 Sovereign communities

For an APPROVED [`RAVEN_SOVEREIGN_COMMUNITIES_V1.md`](RAVEN_SOVEREIGN_COMMUNITIES_V1.md) room, stable identity-level participation may continue only under its explicit recovery policy. Every pre-recovery device/MLS leaf becomes ineligible and must be removed; the recovered device publishes a fresh KeyPackage and rejoins through a newly authorized governance+MLS transition. Recovery never restores or clones an MLS tree, epoch secret, Welcome, KeyPackage private key, or room replay state.

### 8.5 Contacts and trust UX

Recovery continuity is a cryptographic authority transition, not proof that the same human is holding the device. Existing contacts choose a local policy:

- accept after valid activated quorum plus monitoring evidence;
- require safety-number/QR confirmation;
- quarantine and contact through another channel;
- reject and create a new contact manually.

No UI may show “verified same person” based solely on recovery. It may show “same Raven V2 continuity anchor; operational key recovered by configured M-of-N policy.”

### 8.6 User-owned archive

Identity recovery and archive recovery are non-interchangeable. Recovery guardians, quorum signatures, continuity events, operational keys, and device certificates do not decrypt a user archive. An archive recovery key does not authorize a continuity event or new Raven device.

After identity recovery, an independently recovered archive may restore eligible history and historical evidence only through the quarantined import rules of [`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md). It never restores prior device/session/ratchet/prekey state. The recovered identity creates a fresh device lineage and fresh sessions; contacts and archived pins undergo current cert/revocation/resolution checks before any send.

---

## 9. Protected local state

Protected state includes:

- exact continuity genesis/address binding;
- greatest generation/operation head and full bounded conflict set;
- greatest policy sequence/digest and policy conflict state;
- pending recovery first-seen marker and activation deadline basis;
- admitted recovery events/quorum evidence and exact digest index;
- retire-all barrier and DeviceSet/session re-pair work items;
- Key Transparency monitor heads/proofs/quarantine;
- V1→V2 migration pin where applicable;
- recovery-assignment secrets on guardian devices, in a separate namespace;
- mutation journals/anchors and monotonic generation.

Public SQLite/indexes contain only non-secret metadata/digests needed for bounded lookup. Recovery private keys, assignment plaintext, session keys, contacts, messages, and local labels never enter public indexes or logs.

Missing/corrupt protected continuity state fails closed for automatic V2 authorization. A stale backup cannot lower generation/policy/head or resurrect old devices. Repair consumes exact externally verified event bytes through a separately specified journaled procedure; it never resets to first trust silently.

---

## 10. Privacy and metadata

Recovery has unavoidable metadata:

- an activated event reveals that recovery/rotation occurred;
- M participating dedicated public keys and inclusion proofs become visible;
- event distribution reveals timing, network source, and interested verifiers;
- repeated use of one recovery key links those events;
- V1→V2 migration publicly links two addresses when the record is shared.

Mitigations:

- dedicated one-identity/one-policy delegate keys;
- rotate used delegate keys/policy after every activated recovery;
- private assignment transport and protected storage;
- OHTTP/multi-source fetch where an approved profile exists;
- padding/batching without false anonymity claims;
- no human names/contact addresses in public leaves/events;
- no public list of non-participating delegates;
- no read/receipt callback to delegates after event activation;
- locally chosen guardian labels never leave the guardian device.

If coordinator, delegate distribution service, transparency log, and resolver are co-operated, Raven must not claim unlinkability merely because keys are pseudonymous.

---

## 11. Why baseline uses individual signatures, not threshold signatures

Baseline quorum proof is a bounded list of M independent Ed25519 signatures plus Merkle inclusion proofs. This is larger and reveals participating recovery public keys, but it is simple to verify across platforms, exposes exactly who in the committed policy authorized the event, and needs no new distributed key generation protocol.

RFC 9591 FROST can produce Ed25519-verifiable threshold signatures, but its key generation is outside the core protocol (apart from an informative trusted-dealer construction), nonce handling is subtle, and a production DKG/resharing/backup ceremony would require its own reviewed companion. Raven therefore MUST NOT label a list of signatures as FROST or silently replace it with custom Shamir/DKG code.

A future FROST profile may reduce proof size and signer disclosure only after exact DKG, share verification, resharing, nonce, abort, malicious-participant, platform custody, vectors, and independent-review gates are approved. It cannot change the V2 continuity/conflict semantics.

---

## 12. Distribution without a central recovery server

Genesis, policies, and control/recovery events are immutable public authenticated records after umbrella registration. They may be distributed through:

- direct contact exchange;
- multiple user-selected resolvers/transparency monitors;
- content-addressed public stores/mirrors;
- QR/file/NFC recovery bundles;
- approved public repository source profiles;
- local mesh candidate hints;
- offline backups containing exact public evidence.

Every source is untrusted for authority and completeness. Verifiers union exact valid evidence, preserve conflicts, and pin greatest states. There is no `ResetAccount` RPC, single recovery database, first-source winner, or server-generated recovery timestamp.

A source may withhold an event. Multi-source monitoring and user/contact warnings reduce eclipse risk, but offline first-time verifiers cannot prove global completeness.

---

## 13. Proactive V1 → V2 migration

### 13.1 Migration bridge

A V1 owner who still controls the exact Raven Identity V1 key may create:

```text
RavenIdentityMigrationV1ToV2
  exact_v1_address
  exact_v1_identity_pub
  exact_v2_continuity_id_and_address
  exact_v2_genesis_digest
  migration_nonce
  created_at / expiry policy
  v1_identity_signature
  v2_initial_operational_signature
```

Both signatures bind all fields and each other. The bridge is a new versioned public record; no old V1 byte is reinterpreted.

### 13.2 Local acceptance

Migration does not mutate a contact automatically. Existing contacts verify the V1 address/key, V2 genesis/policy, both signatures, revocation/conflict state, and local block, then display the new V2 safety fingerprint and require the frozen migration consent policy. Until acceptance, V1 and V2 remain separate candidates.

After acceptance:

- new sessions use V2 only;
- V1 sessions close through normal durable workflow;
- the V1 contact entry retains immutable migration evidence;
- legacy clients see a changed/new address and cannot claim recovery support;
- public aliases/handles may point to V2 only through separately authenticated updates;
- V1 private key destruction is an explicit, delayed, backup-aware user action.

### 13.3 No post-loss invention

If the V1 key is already lost or compromised and no valid migration bridge was previously created/pinned, a V2 identity claiming continuity is discovery-only. Social popularity, matching alias/profile, contact signatures, device sessions, recovery guardians chosen afterward, or server records cannot recreate V1 authority.

A bridge first presented only after the V1 key is suspected compromised is not proof that it predates compromise; advisory creation time cannot solve that. Pre-compromise local/transparency pins or explicit out-of-band contact re-verification are required before claiming continuity.

---

## 14. Failure matrix

| Failure/event | Required outcome |
|---|---|
| Lost V1 key without prior migration | Unrecoverable V1; create new identity; no continuity claim |
| V2 operational key lost; fewer than M delegates | Recovery unavailable; no server override |
| M valid delegates sign exact proposal | Recovery pending/active only through durable pipeline and policy delay |
| Duplicate delegate key/index/signature | Reject; does not count toward M |
| Wrong Merkle proof/policy/generation/new key | Reject without continuity mutation |
| Lower policy/generation/head from source | Stale; preserve greatest protected pin |
| Equal unique event slot, different exact bytes | Authenticated conflict; quarantine |
| Two valid recovery quorums for same next generation | Terminal recovery conflict; no automatic winner |
| Normal attacker rotation races valid recovery | Pending hold; activated higher recovery generation supersedes normal branch |
| Recovery under learned-retired/stale policy | Reject or conflict according to prior admission evidence; never timestamp-LWW |
| Current operational key attempts policy change alone | Reject |
| Current operational key attempts recovery cancel alone | Reject |
| Guardian refuses/offline | No mutation; coordinator cannot forge/replace |
| Recovery activation crash | Roll forward exact journal; no old-key resurrection/new-key early release |
| Protected state rollback/corruption | Fail closed; explicit evidence repair |
| Old device sends after activation | Reject new admission; close/re-pair workflow |
| Old ciphertext/history requested | No recovery claim; only locally retained keys/history apply |
| Resolver/log omits recovery | Availability/freshness failure; monitor warning when detectable |
| Resolver/log invents event | Signature/quorum failure |
| Alias/handle points to new V2 identity | Discovery only; cannot substitute migration/quorum evidence |
| Guardian relationship exposed at use | Honest metadata warning; dedicated key limits identity linkage |
| Recovery event deactivates identity | Terminal no-new-admission; public replicas/history remain |

---

## 15. Byte classes and future wire families

This document freezes semantics only. A future umbrella revision/wire companion must classify:

| Family | Intended class |
|---|---|
| V2 genesis, policy, control/recovery event, V1→V2 migration | Public authenticated `endpoint_object_bytes`, if registered |
| Guardian public approval proof | Nested exact evidence inside recovery event |
| Recovery proposal/assignment | Private ceremony bytes; never public endpoint object by default |
| Guardian assignment secret/key | Protected local secret; never Object Sync/carrier content |
| Resolution/transparency fetch/status | Scoped endpoint or carrier-control class as approved by its profile |
| Local pending/acceptance/conflict state | Protected local state |

Every wire family requires a new magic/version, canonical bytes, exact lengths, domains, signature coverage, replay identity, caps, errors, and Python/Rust/Swift vectors. V1 signatures, Device Certificates, addresses, RVDR1, PairInit V1, or Session V1 are never reinterpreted as continuity-aware V2.

---

## 16. Required vectors and adversarial tests

Three-language fixtures must compute:

- genesis core → continuity ID → RavenAddressV2 candidate encoding;
- operational signature and address/key binding;
- policy sequence/root, canonical Merkle tree, inclusion proof, duplicate rejection;
- M-of-N exact proposal signatures with M−1 refusal;
- normal rotation, policy update, recovery, recovery+policy rotation, deactivation;
- generation/sequence/parent/base transitions and checked overflow;
- exact replay, gaps, normal fork, recovery-vs-normal precedence, two-quorum terminal conflict;
- stale/withheld policy and later conflict behavior;
- delay first-seen persistence, replay-not-resetting-delay, local confirmation policy;
- retire-all prior device/session barrier;
- V1→V2 dual-signature migration and every cross-address/key negative;
- protected journal prepare/SQL/head/clear crash points;
- corrupt/stale backup repair and no rollback;
- Key Transparency/multi-source conflict and omission;
- zeroization/redacted logging and cross-account namespace separation.

Negative fixtures include truncation/oversize/non-canonical fields, unknown critical bits, wrong domain/profile, all-zero/duplicate keys/nonces, invalid M/N, bad leaf order/path, repeated signature, wrong proposal, wrong continuity/policy/generation/base/new key, expired policy, integer wrap, cross-identity replay, stale pin, forged migration, and partial journal corruption.

---

## 17. Simulations and physical gates

### 17.1 Deterministic simulations

| Simulation | Required evidence |
|---|---|
| 1,000 identities, multi-source partition | Valid events converge when evidence reconnects; conflicts preserved; no source authority |
| Operational-key compromise | Attacker normal rotations cannot defeat later valid higher recovery generation |
| Guardian compromise sweep | Fewer than M cannot recover; M collusion risk reported honestly |
| Two valid quorums | Terminal conflict on every implementation; no timestamp/source tie-break |
| Policy rotation withholding | Stale-policy ambiguity never silently activates/rolls back |
| Resolver/log split view | Monitor detects when evidence permits; no claim when partition hides it |
| Delay/reinstall/clock changes | Replay/reinstall/clock manipulation cannot reset/bypass protected first-seen delay |
| Crash matrix | No partial activation, old-key resurrection, early output, or journal rollback |
| Privacy trace | No contacts/messages/non-participant delegate identities in public recovery bytes |

Simulation is not proof of guardian honesty, global freshness, human identity, real platform custody, or network anonymity.

### 17.2 Physical gates

At minimum:

- iPhone owner + two independent guardian media/devices for a real 2-of-3 ceremony;
- Android/Linux/Windows/macOS guardian implementations where claimed;
- phone loss/reinstall, lock/unlock, reboot-before-first-unlock, kill at every journal phase;
- operational-key compromise simulation with attacker and legitimate recovery on different partitions;
- QR/file/NFC/cable assignment and proposal transfer as shipped;
- fresh device enrollment, old-device/session refusal, explicit contact re-pair;
- resolver/transparency multi-source reconnect;
- disk/log/packet inspection for assignment, contact, message, and delegate privacy;
- accessibility and human-confirmation review for fingerprints/recovery consequences.

One simulator, one device, or an in-process quorum is insufficient for a production recovery claim.

---

## 18. Production holds

No V2 continuity/recovery/migration path may be enabled until all of:

1. this architecture is independently reviewed and **APPROVED**;
2. RavenAddressV2, continuity/event/policy/migration wire companion, and umbrella public-record classes are APPROVED;
3. Identity/Resolution/Revocation/Session/Social companions explicitly adopt continuity-generation and historical-key semantics;
4. exact bytes and negatives pass Python/Rust/Swift;
5. Key Transparency profile and multi-source monitoring are pinned/reviewed for the shipped mode;
6. Apple/Linux/Windows protected anchors/journals pass crash, corruption, rollback, and cross-account tests;
7. guardian ceremony UX and dedicated-key custody pass independent security/usability review;
8. 1,000-node partition/compromise/conflict simulations pass;
9. real multi-device physical recovery, old-session refusal, and re-pair matrices pass;
10. logs/telemetry/backups prove no recovery secret/contact/message leakage;
11. V1 migration never auto-merges and loss-before-migration remains honestly unrecoverable;
12. no FROST/DKG/secret-sharing claim exists without a separately APPROVED profile;
13. no lab/test flag, support override, email/SMS/cloud reset, or recovery server compiles into an enabled Release path;
14. external cryptographic/privacy review or explicit protocol-owner waiver records every residual risk, including the classical-only identity-authentication boundary and PQ migration plan;
15. human protocol-owner approval is recorded in this header.

Approval of this architecture alone does not enable production.

---

## 19. Open decisions

1. Exact RavenAddressV2 length/version/checksum and genesis-core encoding.
2. Exact policy/event/proposal/assignment wire layouts and signature domains.
3. Production M/N defaults, delay policy, accessibility, and no-recovery option UX.
4. Merkle hash/tree profile and proof caps.
5. Event DAG compaction without loss of historical/conflict evidence.
6. Exact interaction with Device Revocation V2 and identity-wide compromise markers.
7. Historical social-record/device-cert verification after key rotation/recovery.
8. Key Transparency label/value/log/witness profile for stable continuity IDs.
9. Guardian assignment backup/export and one-time-key rotation policy.
10. Whether a future FROST profile is worth DKG/resharing/custody complexity.
11. Deactivation confirmation/delay and inheritance/death scenarios.
12. Whether out-of-band contact confirmation can shorten a pending delay, and how it is locally auditable.
13. Recovery evidence retention and privacy in public mirrors.
14. V1→V2 migration rollout and legacy-client end-of-life policy.

---

## 20. Research foundations (informative only)

Raven claims no wire compatibility with these systems:

- [W3C DID Core — rotation and recovery](https://www.w3.org/TR/did-core/) — separates verification methods/controllers and explicitly discusses quorum/timelock recovery and key-purpose separation.
- [DID PLC method](https://github.com/did-method-plc/did-method-plc/blob/main/website/spec/v0.1/did-plc.md) — genesis-derived stable identifier, chained operations, rotation keys, and recovery; Raven rejects dependence on one central directory, server timestamps, and hidden history rewrites.
- [RFC 9591 — FROST](https://www.rfc-editor.org/info/rfc9591/) — reviewed two-round threshold Schnorr/Ed25519-compatible signatures; baseline Raven does not adopt it because production DKG/resharing/custody is not defined by the core RFC.
- [Matrix cross-signing](https://spec.matrix.org/latest/client-server-api/#cross-signing) — distinct master/self-signing/user-signing roles and device trust migration; Raven uses different bytes and a stable continuity event model.
- [Signal PIN / Secure Value Recovery](https://support.signal.org/hc/en-us/articles/360007059792-Signal-PIN) and [Secure Backups](https://signal.org/blog/introducing-secure-backups/) — recovery usability and explicit separation between account-supporting data and message-history backup; Raven does not require Signal's server/enclave model.
- [IETF Key Transparency architecture/protocol](https://datatracker.ietf.org/doc/draft-ietf-keytrans-architecture/) — monitoring and split-view detection for evolving identity bindings; not a recovery authority.

---

## 21. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial architecture: immutable V2 continuity anchor, rotatable operational identity, dedicated Merkle-committed M-of-N delegates, explicit guardian ceremony, append-only generation/event DAG, recovery-over-normal precedence with two-quorum terminal conflict, local first-seen delay, retire-all device/session barrier, protected roll-forward durability, multi-source/transparency distribution, proactive dual-signed V1→V2 migration, vectors/simulations/physical gates, and production holds |
| 2 | 2026-08-21 | Adversarial derivation hardening: non-circular `genesis_context → bootstrap policy core → continuity_id`; core versus authorization/object digests; delegate leaves bind context/sequence/nonce rather than their containing policy digest; independent-factor guidance; late post-compromise V1 bridge cannot prove continuity |
| 3 | 2026-08-21 | Ceremony/authority hardening: guardian-local key generation and proof of possession; explicit owner-managed offline-factor flow; setup-readiness proof; every installed operational key cross-signs its event; upper-layer adoption split into frozen V1 versus continuity-aware V2 profiles |
| 4 | 2026-08-21 | Coordinator-substitution hardening: proposal core equals final recovery-event core except canonical authorizations; every mutable semantic field and observed-head set is signed; new-key proof uses the same core; exact prior generation/base required and generation skipping forbidden |
| 5 | 2026-08-21 | User-data recovery boundary: linked the separately keyed User-Owned Archive; identity guardians cannot decrypt it, archive possession cannot recover identity, and restored history never revives prior devices/sessions/ratchets |
| 6 | 2026-08-21 | Sovereign-community recovery boundary: stable participant identity may survive policy review, but all old MLS device leaves/state are retired and a recovered device must rejoin through fresh KeyPackage plus governance/MLS transition |
