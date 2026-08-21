# RAVEN ID Resolution V1

**Version:** 1 (architecture and security draft; wire not frozen)

**Document revision:** 7

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this draft authorizes no resolver deployment, DHT trust, Key Transparency service, short-ID UI, contact mutation, codec, or Release flag

**Approval prerequisites:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md) **Approved** (met) + [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md) **APPROVED** (met)

**Unblocks when approved:** safe Raven ID paste/search UX; DeviceSet resolution; future social discovery; Carrier Conformance identity fixtures

This companion defines how a human-entered Raven identifier produces a bounded set of cryptographically checkable identity/device candidates without allowing a resolver, DHT, relay, alias publisher, or transparency-log operator to become the contact trust root.

The product rule is:

> Resolution discovers candidates. Only the user's explicit local acceptance creates a contact.

After contact acceptance, resolution still does not answer where a peer is
reachable. [`RAVEN_PRIVATE_RENDEZVOUS_V1.md`](RAVEN_PRIVATE_RENDEZVOUS_V1.md)
defines the separate, production-disabled known-peer path-candidate layer. A
resolved DeviceSet/prekey, DHT answer, PeerId, Bonjour result, relay address, or
mailbox response never becomes rendezvous/contact/session authority by itself.

Before mutual contact, an exact verified result may be handed to
[`RAVEN_PRIVATE_INTRODUCTION_V1.md`](RAVEN_PRIVATE_INTRODUCTION_V1.md) only
after a separate explicit user action. That protocol can enqueue one bounded
inert proposal; it cannot create a contact, message, PairInit, route, presence,
or notification permission. Resolution never performs the provider write.

This revision freezes architecture, trust states, input classes, and security gates. It intentionally does not freeze bytes or authorize implementation. A later revision must freeze every record layout, domain string, cap, error, and three-language vector before this document can become APPROVED.

---

## 0. Normative language and precedence

The key words MUST, MUST NOT, SHOULD, and MAY are interpreted as in BCP 14 when capitalized.

The Unified Serverless Architecture V2 remains binding. This document MUST NOT weaken:

- contact as the durable trust root;
- exact endpoint-object identity;
- device-certificate and signed-revocation checks;
- carrier opacity;
- the prohibition on treating aliases, discovery, sessions, or reachability as contacts.

If an older Alias, Profile, Discovery, or DHT document conflicts with this companion after approval, this companion governs ID resolution only. Existing signed V1 records remain parseable but do not silently gain stronger trust semantics.

---

## 1. Goals and non-goals

### 1.1 Goals

| Goal | Meaning |
|---|---|
| Correct identity | A resolved candidate binds the full identity Ed25519 key to its canonical `RavenAddressV1` |
| Correct devices | Every advertised device carries an exact valid identity-signed certificate and current local revocation checks |
| No silent redirect | Alias/handle changes, ambiguity, stale results, and split views are visible and fail closed before contact mutation |
| Offline verification | QR/file/NFC contact credentials can be verified without contacting their issuer when evidence is complete |
| Resolver diversity | Raven does not require one Raven-operated global directory |
| Lookup privacy | Optional profiles reduce what a directory and network observer learn, with explicit residual leakage |
| Usable input | Full addresses, display addresses, contact cards, short Raven Codes, and namespaced handles have distinct safe UX |
| Multi-device | DeviceSet updates add current devices without treating omission as revocation |

### 1.2 Non-goals

- Proving a person's legal or real-world identity.
- Making bare aliases globally unique.
- Creating a Raven-owned username registry.
- Treating a valid profile, follow, shared Circle, or session as contact consent.
- Instant global device revocation during a partition.
- Hiding all lookup timing, size, IP, namespace, or access patterns.
- Trusting raw DHT order, first-seen network order, DNS, Bonjour, AutoNAT, relay, or social popularity.
- Executing identity recovery or changing RavenAddressV1 authority. [`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md) defines a separate, production-disabled V2 architecture; this companion may resolve its evidence only after both profiles are APPROVED.
- Publishing private contact/follow graphs.

No blockchain, cryptocurrency, NFT, or proof-of-stake is required or authorized.

### 1.3 Adversaries and unavoidable limits

The design considers a malicious or compromised resolver, DHT/store, namespace operator, transparency log, witness, OHTTP relay/gateway, contact candidate, and network path; a compromised device key; Unicode/confusable input; replayed valid records; stale local state; candidate floods; and collusion among deployment roles.

The design does **not** make a compromised V1 user identity key honest. That key can authorize devices and sign resolution updates. Continuity V2 uses a distinct genesis-derived address/control-event profile and cannot retroactively recover an unprepared V1 key.

No partitioned lookup can prove it has learned every globally published revocation. A first-time resolver may hold a valid unexpired certificate while an RVDR1 claim is being withheld elsewhere. Certificate expiry, transparency freshness, multi-source sync, and sticky local deny reduce this window but do not eliminate it. UI and security claims must retain Device Revocation V1's eventual-only semantics.

---

## 2. Identity classes shown to users

Raven separates the cryptographic identity from human labels.

| Class | Example | Authority | Trust meaning |
|---|---|---|---|
| **Canonical address** | `rvn1...` | Derived from identity Ed25519 public key | Self-certifying locator after full key/address check |
| **Display address** | grouped `rvn1:....` form | Presentation of canonical address | Same as canonical only after strict normalization/checksum |
| **Contact credential** | QR/file/NFC exact bytes | Identity-signed data plus optional transparency evidence | Offline candidate verification; still requires user Accept |
| **Raven Code** | future shortened hash locator | Derived from canonical address; untrusted index returns candidates | Locator only; collision/ambiguity checked against full address |
| **Bare alias** | `@ahmad` | Any identity may self-claim | Discovery only; never unique, never one-click trust |
| **Namespaced handle** | `@ahmad@community.example` | Self-certifying namespace configuration + identity self-signature + transparency evidence | Unique only within that authenticated namespace and proof policy; the displayed domain is not the trust root |
| **Local petname** | `Dad`, `Workshop Alice` | Device owner | Local UI label only; never transmitted as authority |

The UI MUST visually distinguish these classes. It MUST NOT display a bare alias as though it were a globally registered Raven ID.

---

## 3. Required resolution records

This section specifies semantic records. Exact wire formats remain open until vector freeze.

### 3.1 `RavenDeviceSetV1`

An identity-signed snapshot advertising devices that the owner currently
offers for explicitly typed operations. A reference's purpose is part of the
signed snapshot; an introduction prekey is never a session prekey.

Required semantic fields:

```text
version
identity_address
identity_ed25519_pub
generation_u64
issued_at_ms
expires_at_ms
device_certificates[]                  # exact cert signing bytes + signatures
session_prekey_references[]            # PairInit/session purpose only
introduction_descriptor_references[]?  # Private Introduction purpose only
introduction_prekey_references[]?      # Private Introduction purpose only
profile_record_digest?
previous_device_set_digest?
revocation_evidence[]?       # bounded exact RVDR1 records or content-addressed references
signature_by_identity
```

Rules:

1. Recompute `RavenAddressV1` from `identity_ed25519_pub`; mismatch rejects the entire set.
2. Verify the DeviceSet signature with that exact identity key.
3. Verify every device certificate signature, address binding, key lengths, validity window, and unique lineage.
4. Every descriptor/prekey reference must declare one exact purpose and bind
   to exactly one advertised certificate/device lineage. Cross-purpose reuse
   rejects the set.
5. Apply local block and the append-only union from Device Revocation V1 before exposing a device as usable.
6. Device omission is **not revocation**. An omitted certificate remains denied only by expiry, local policy, or an accepted RVDR1 record.
7. `generation` is monotonic per identity. Equal generation with different exact bytes is authenticated equivocation and MUST fail closed for automatic update.
8. A newer valid DeviceSet MUST NOT clear a stored revocation or local block.
9. Empty sets MAY mean “no device currently advertised” but MUST NOT delete existing trust evidence.
10. All counts, bytes, certs, and prekeys are bounded before allocation.
11. Included revocation evidence is union-applied before device selection. It is a propagation aid, not a proof that no other revoke exists.
12. A DeviceSet that advertises a lineage covered by included or locally stored RVDR1 evidence is internally inconsistent; that lineage is denied and automatic contact/session update fails closed.

### 3.2 `RavenNamespaceConfigV1`

A signed configuration chain establishes the cryptographic authority behind a namespaced handle. A DNS name, HTTPS origin, DHT key, relay location, or application display string is never this authority by itself.

Required semantic fields:

```text
version
namespace_id                       # self-certifying identifier rooted in root_namespace_pub
namespace_display_label            # advisory presentation, not an authority key
root_namespace_pub                 # immutable root Ed25519 public key for this namespace_id
config_sequence_u64
issued_at_ms
expires_at_ms
previous_config_digest?            # absent only for sequence 1
config_signing_pub
grant_signing_pub
normalization_profile_id
normalization_profile_digest
key_transparency_profile_id
key_transparency_log_configs[]     # exact config digests, keys, suites, endpoints, validity
verification_mode                  # contact-monitor | auditors | threshold-witnesses
witness_or_auditor_policy?
maximum_staleness_ms
monitoring_window_ms
privacy_profile_id?
migration_or_shutdown?
signature_by_previous_config_key?  # required after sequence 1
signature_by_new_config_key        # proof of possession for config_signing_pub
root_signature                     # required for sequence 1 and root-authorized exceptional changes
```

Rules:

1. `namespace_id` is derived from an exact, domain-separated encoding of the immutable `root_namespace_pub` and namespace scheme/version. The exact derivation is frozen with the wire vectors; `namespace_display_label` and DNS name are not inputs that can replace the root key.
2. Sequence 1 must be signed by `root_namespace_pub`. A client first trusts it only through an application-pinned configuration, an exact QR/file/NFC/contact credential, or explicit user import with fingerprint confirmation.
3. DNS, HTTPS, DHT, a resolver response, and a social link may locate a configuration but cannot authenticate first trust unless a separately approved DNSSEC/WebPKI bootstrap profile binds the exact `namespace_id` and config digest. Without that profile the result is discovery-only.
4. Every later configuration has a strictly increasing sequence, binds the exact previous config digest, verifies under the previously authorized config key, and verifies under the new config key when that key changes. A gap, rollback, missing cross-signature, or equal sequence with different bytes is a namespace conflict.
5. The immutable root key does not rotate in-place. Loss or compromise of that root requires explicit re-trust as a new namespace ID. Operator, grant, log, witness, privacy, and policy keys may rotate only through the authenticated chain.
6. Every grant, ResolveRecord, transparency proof, VOPRF epoch, and accepted pin binds the exact `namespace_id` and `namespace_config_digest`; a proof valid under another configuration is invalid for this lookup.
7. Normalization/profile changes are versioned configuration changes. Existing pinned handles continue under their pinned policy until an authenticated, user-visible migration succeeds; a client never re-normalizes them silently.
8. Log migration includes a trustworthy final tree head from the old configuration, a binding to the new log configuration, and the required monitor/auditor/witness evidence. During incomplete migration, new contact acceptance is refused.
9. A config chain is append-only local evidence. Ordinary later success cannot erase a stored conflict or split-view quarantine.
10. Counts, endpoints, witnesses, keys, and configuration bytes are bounded before allocation. Unknown configuration extensions are rejected until a version explicitly defines them.

The first-trust UI must show both the human display label and a stable namespace fingerprint derived from `namespace_id`. A familiar domain alone must never make an imported configuration trusted.

### 3.3 `RavenResolveRecordV1`

An identity-signed mapping from one discoverable label to one canonical identity and one DeviceSet.

Required semantic fields:

```text
version
label_kind                    # raven-code | bare-alias | namespaced-handle
normalized_label
namespace_id?                 # mandatory for namespaced-handle
namespace_config_digest?      # mandatory for namespaced-handle
identity_address
identity_ed25519_pub
device_set_digest
profile_record_digest?
public_repo_descriptor_digests[]? # bounded discovery hints; never contact/session authority
sequence_u64
issued_at_ms
expires_at_ms
previous_record_digest?
identity_signature
namespace_grant?              # mandatory if namespace claims uniqueness
namespace_grant_digest?       # digest of the exact grant above
transparency_label?           # exact unique, user-visible log label
transparency_profile_id?
transparency_log_config_digest?
```

The identity self-signature proves only that the identity claims this label. It does not prove global uniqueness or real-world identity.

For a namespaced handle, `namespace_grant` must bind at least the self-certifying namespace ID, exact namespace config digest, normalized handle, identity address, validity interval, grant sequence, previous grant/record digest, normalization policy digest, and transparency label/profile/log config. It verifies with the exact grant key authorized by that namespace configuration. A namespace grant cannot authorize device keys by itself.

ResolveRecord chain rules are:

1. The chain is scoped by `(namespace_id, normalized_label)` for namespaced handles and by `(label_kind, normalized_label, identity_address)` for non-unique self-claims.
2. Exact replay is idempotent. A lower sequence is stale. Equal sequence with different exact bytes is authenticated equivocation. A higher sequence must bind the immediately previous accepted digest except for a separately authenticated namespace migration genesis.
3. A namespaced label has exactly one current identity value under one exact config/log view. Multiple simultaneously valid identity grants, conflicting latest records, or multiple configurations claiming the same pinned namespace ID cause `Ambiguous` plus namespace quarantine; arrival order never resolves the conflict.
4. `transparency_label` is the exact normalized user-visible handle committed by Key Transparency. An unauthenticated hidden UUID cannot substitute for it.
5. The identity signature, namespace grant, DeviceSet, and transparency evidence are independently verified. Success in one layer never authorizes another.
6. Every advertised public-repository descriptor digest is only a content-addressed discovery hint. A client fetches and verifies the exact descriptor under the separately APPROVED social profile. Omission does not delete a pinned subscription; inclusion does not create a contact, authorize PairInit, or prove repository completeness.

### 3.4 `RavenContactCredentialV1`

A bounded offline bundle containing exact records and proofs needed to verify one candidate:

```text
credential_version
identity_address + identity_ed25519_pub
exact RavenDeviceSetV1
exact profile/alias/resolve records selected by the owner
optional namespaced namespace grant
exact RavenNamespaceConfigV1 chain required by that grant
optional Key Transparency Search credential and monitor metadata
credential_expiry
identity signature over canonical credential binding
```

The credential MUST NOT contain identity private keys, device private keys, prekey secrets, contact graph, stable network addresses, mailbox tags, or local petnames.

Offline verification may produce `CandidateVerifiedOffline`; it cannot prove evidence that became stale after credential creation. A namespaced credential must include the exact pinned namespace config chain and any log-migration proof needed by its evidence; fetching replacement config bytes during scan is forbidden. The UI must show the evidence time, namespace fingerprint, and require online refresh when policy demands it.

---

## 4. Input classes and resolution state machine

### 4.1 Classification before network

The resolver first classifies and strictly parses input without I/O:

```text
canonical/display RavenAddress
contact credential bytes / QR
Raven Code
namespaced handle
bare alias
otherwise: reject
```

Ambiguous grammar is rejected; it is never tried as multiple input classes. Before namespace-config verification, a namespaced handle parser only validates bounded outer syntax and retains exact input bytes; it does not treat a network-supplied normalization policy as authoritative. The authoritative `normalized_label` is produced only after the exact authenticated normalization profile is selected. Unicode normalization is class-specific and must be frozen with vectors. No class may silently fall back to another after verification failure.

### 4.2 State machine

```text
INPUT
  -> PARSED
  -> CANDIDATES_FETCHED
  -> NAMESPACE_CONFIG_VERIFIED_OR_NOT_APPLICABLE
  -> RECORD_SIGNATURES_VERIFIED
  -> TRANSPARENCY_VERIFIED_OR_EXPLICITLY_ABSENT
  -> DEVICE_SET_VERIFIED
  -> LOCAL_BLOCK_REVOCATION_APPLIED
  -> CANDIDATE_READY_FOR_USER
       -> PUBLIC_VIEW_ONLY                 # optional; no contact/session authority
       -> USER_SENDS_PRIVATE_INTRODUCTION  # optional; no contact/session authority
          -> OUTGOING_INTRODUCTION_PENDING
       -> USER_ACCEPT_LOCAL_EVIDENCE
          -> CONTACT_COMMIT
          -> PairInit / messaging may begin
```

No PairInit, prekey claim, session allocation, durable contact mutation, or message enqueue may occur before `CONTACT_COMMIT`.
An APPROVED Private Introduction provider write is a distinct pre-contact
endpoint operation, not a chat-message enqueue and not an exception for
PairInit. A verified acceptance returned through that protocol must itself pass
current identity/DeviceSet/certificate/revocation/block checks before it can
cause the sender's separate local `CONTACT_COMMIT`.

`PUBLIC_VIEW_ONLY` may support an explicitly public signed feed under an APPROVED social-object profile. It may create a local public subscription, but it MUST NOT create a messaging contact, authorize PairInit, expose private/contact inventory, import a capability, or convert public popularity into trust. The full canonical identity—not its handle—remains the repository authority.

If a result advertises public repository descriptors, the user/client selects an exact descriptor only after verifying its owner address/key and descriptor chain. Resolver order, source count, handle popularity, and repository activity are forbidden tie-breakers for authenticity. Source endpoints and signed repository-head announcements remain availability hints under the social profile; they do not become identity or contact evidence.

### 4.3 Result states

| Result | Meaning | May send? |
|---|---|---|
| `VerifiedAddressCandidate` | Full identity key matches canonical address; DeviceSet and local policy valid | Only after explicit Accept/commit |
| `VerifiedTransparentHandleCandidate` | Address checks plus an exact trusted namespace config, grant, and current transparency proof/monitor policy | Only after explicit Accept/commit |
| `OfflineCredentialCandidate` | Exact credential verifies but freshness may be limited | Only after explicit Accept and policy allows offline evidence |
| `Ambiguous` | More than one live valid identity candidate | No; user must obtain stronger evidence |
| `KeyChanged` | Previously pinned label now maps to a different identity or conflicting DeviceSet | No automatic replacement |
| `Stale` | Evidence exceeds allowed age/monitor window | No |
| `SplitViewSuspected` | Tree heads/proofs conflict or monitor fails | No; namespace quarantined |
| `RevokedOrBlocked` | Candidate/device denied by local state | No |
| `DiscoveryOnly` | Bare alias/profile claim without transparency policy | No one-click send/contact |
| `Unavailable` | No verified result | No |

Errors and result states must not reveal whether a blocked identity exists to an unauthenticated remote caller.

---

## 5. Canonical address and contact-card path

### 5.1 Canonical address

Entering a complete `RavenAddressV1` is the strongest server-independent locator, but the address does not contain the full identity public key or current DeviceSet. A resolver may fetch candidate credentials from untrusted stores keyed by the address.

For each returned candidate it MUST:

1. parse with strict sizes and no trailing bytes;
2. recompute the address from the included identity public key;
3. compare the full address, not only a display fingerprint;
4. verify DeviceSet and record signatures;
5. apply local block/revocation;
6. retain all valid conflicting candidates as evidence rather than silently choosing network-first.

An untrusted store can withhold a candidate but cannot substitute a different identity without failing the full address check.

### 5.2 QR/file/NFC credential

The credential path does not require a directory. The scanner/parser must enforce an absolute byte cap before allocation and must treat QR/NFC transport metadata as unauthenticated.

The UI shows:

- canonical Raven address;
- stable safety fingerprint derived by the existing identity profile;
- device count and certificate freshness;
- transparency status, namespace, and evidence time if present;
- revocation/block result;
- an explicit `Add contact` action.

Scanning never auto-accepts friendship and never POSTs to a legacy central service.

---

## 6. Raven Code: shorter self-derived locator

The future wire revision may define a shorter `RavenCodeV1` derived from the canonical identity-address payload plus a checksum. This draft freezes constraints, not the formula:

1. It is a **locator**, not a replacement cryptographic identity.
2. It must retain at least 128 bits of collision/preimage material before checksum.
3. It is deterministically recomputed from the resolved full identity key/address.
4. An untrusted index keyed by the code may return zero or multiple bounded candidates.
5. Every candidate must pass the full address/key/DeviceSet pipeline.
6. Two valid full identities producing the same code yield `Ambiguous`, never a tie-break.
7. The UI displays the full safety fingerprint before first contact acceptance.
8. No resolver may silently expand a Raven Code into a bare alias search.

The vector freeze must include adversarial collision-bucket, checksum, normalization, truncation, and candidate-flood cases. The security review must decide whether the shorter form provides acceptable malicious-key-grinding resistance.

---

## 7. Aliases and namespaced handles

### 7.1 Bare Alias V1

`RavenAliasRecordV1` remains a self-signed claim. Multiple identities may legitimately claim the same alias. A resolver may return all bounded valid candidates, but bare alias lookup always results in `DiscoveryOnly` or `Ambiguous` unless the user independently verifies the canonical identity.

No sequence comparison across different identities creates uniqueness. Arrival order, lexicographic address, popularity, proximity, and resolver preference are forbidden tie-breaks.

### 7.2 Namespaced handle

A namespaced handle has the semantic form:

```text
@local-name@namespace-display-label
```

The string is a presentation locator. Its authenticated identity is the self-certifying `namespace_id` from `RavenNamespaceConfigV1`; resolving a display label to arbitrary configuration bytes never establishes trust. The namespace is an explicit authority with a published policy, signing key, and transparency-log configuration. It may enforce uniqueness **inside that namespace only**. Raven itself need not operate a namespace.

Clients must display the namespace label and, before first trust or after a config conflict, a stable namespace fingerprint. `@alice@family.example` and `@alice@journalists.example` are unrelated handles, while two different namespace IDs using the same display label are also unrelated and must not be merged.

### 7.3 Namespace policy

A namespace policy must freeze:

- canonical name normalization and confusable handling;
- grant/update/recovery/reassignment rules;
- maximum grant lifetime;
- namespace signing keys and rotation;
- exact Key Transparency configuration(s);
- witness/auditor/contact-monitoring mode;
- stale limit and reasonable monitoring window;
- privacy lookup profile;
- abuse/rate limits;
- migration and shutdown procedure.

Changing policy or transparency configuration is a versioned, user-visible event. It cannot silently weaken verification for an already pinned contact.

### 7.4 Bootstrap, rotation, and uniqueness

The namespace trust sequence is:

```text
locate display label
  -> obtain bounded RavenNamespaceConfigV1 candidates
  -> match an app pin / exact credential / explicit imported namespace fingerprint
  -> verify the complete config chain
  -> verify the exact grant and ResolveRecord under that config
  -> verify the exact transparency label and proof under that log config
  -> require one current identity value
```

A typed handle obtained from a webpage, DNS, search engine, relay, DHT, or message remains discovery-only until the namespace root is authenticated. TOFU based only on the first network answer is forbidden for the `VerifiedTransparentHandleCandidate` state.

Operator-key rotation preserves the same namespace ID only through the authenticated config chain. Root compromise, an unchained replacement configuration, or incomplete log migration creates a different/untrusted namespace and requires explicit user re-trust. A namespace must not issue overlapping current grants for one normalized label to different identities; if it does, clients preserve both as evidence, return `Ambiguous`, and quarantine automatic resolution.

---

## 8. Key Transparency and split-view defense

### 8.1 Role

Key Transparency does not make an alias true. It makes a namespace operator's label-to-value history globally consistent or detectably forked under the selected deployment assumptions.

The log label must represent the **unique and user-visible namespaced handle**, not an unauthenticated hidden UUID. The value binds the exact latest `RavenResolveRecordV1`/identity address and DeviceSet digest.

### 8.2 Approved deployment profiles

Before production, Raven must approve at least one concrete profile based on a pinned, reviewed version of the IETF Key Transparency architecture/protocol or an independently reviewed equivalent. The profile is identified by exact protocol revision, cipher suite, log public parameters, log key, namespace config digest, verification mode, and staleness rules. A proof under a different log/config is never interchangeable.

A profile must choose one of:

- **Contact monitoring:** clients retain state and gossip/check tree heads through authenticated peers or an anonymous path;
- **Independent auditing:** one or more named auditors sign verified tree heads, with a frozen non-collusion policy;
- **Threshold witnesses:** an explicit M-of-N witness set signs acceptable tree heads.

“The resolver returned a signed record” is not a transparency profile.

### 8.3 Client state

Clients persist, with crash-safe monotonic updates:

- self-certifying namespace ID and exact greatest accepted namespace config digest/sequence;
- authenticated config-chain and log-migration state;
- log configuration/version;
- greatest verified tree head and size;
- per-owned-label monitoring state;
- monitor obligations for recently looked-up labels;
- pinned handle→identity mapping;
- conflicting tree heads/proofs and quarantine state;
- last successful monitor time and allowed staleness deadline.

State loss weakens detection and must be surfaced. Restoring an older local snapshot must not silently roll back the greatest verified tree head.

### 8.4 Fork handling

Conflicting valid tree heads, an invalid consistency/search proof, disappearance of a monitored version, or a handle result incompatible with a pinned identity causes `SplitViewSuspected`:

1. quarantine automatic resolution for that namespace;
2. preserve exact evidence;
3. do not mutate contacts, DeviceSets, prekeys, or sessions;
4. allow manual full-address/QR verification outside the namespace;
5. never let a later ordinary success silently clear the quarantine.

Repair/clear requires a separately specified evidence and user/admin process.

### 8.5 Offline credentials

Key Transparency credentials may package exact verified Search request/response evidence for offline checking. The credential also carries the exact namespace config chain, exact log configuration, monitoring obligation, and expiry. Recipients must not fetch substitute config bytes during verification and must not treat an old credential as proof of current non-revocation.

The IETF Key Transparency documents are still Internet-Drafts as of this revision. Raven must pin a reviewed revision and update intentionally; floating “latest draft” behavior is forbidden.

---

## 9. Privacy-preserving lookup

### 9.1 Leakage baseline

Ordinary directory lookup may reveal the queried handle, requester IP, timing, namespace, result size, and repeated-query linkage. Transparency does not automatically hide those properties.

### 9.2 Optional VOPRF index

A privacy profile may use a VOPRF conforming to RFC 9497 so the client obtains a deterministic opaque lookup key while the VOPRF server does not learn the normalized private input or output under the protocol assumptions.

The VOPRF output is only an index label. It does not verify identity, ensure handle uniqueness, replace a transparency proof, or prevent dictionary enumeration by malicious clients.

The VOPRF input and output derivation must be domain-separated by the exact namespace ID, namespace config digest, normalization profile, VOPRF suite/key ID, and key epoch. Outputs are never reused across namespaces or epochs. Key rotation requires an authenticated config update, a bounded dual-read migration window if approved, deterministic index rebuild rules, and explicit retirement; silently trying an unpinned server key is forbidden.

### 9.3 Network unlinkability

If the VOPRF/directory origin must not learn the client's network address, the profile may use Oblivious HTTP (RFC 9458) through an independently operated relay. The relay learns network endpoints; the gateway/target learns the plaintext request; collusion, timing, padding, and traffic-analysis limitations must be documented.

The OHTTP relay MUST be operationally independent from the gateway/target whenever the privacy claim assumes non-collusion. If the VOPRF service and directory are co-operated, the profile must account for timing/linkage between the blinded evaluation and the subsequent opaque-key lookup; it cannot claim those phases are unlinkable merely because RFC 9497 hides the VOPRF input.

### 9.4 Enumeration controls

Private lookup still needs bounded access:

- per-credential and per-epoch query limits;
- constant-shape or bucket-padded responses;
- no “does this blocked person exist” oracle;
- no unlimited prefix/fuzzy search;
- namespace-specific capability/invite for private communities;
- explicit behavior when privacy service is unavailable.

Failure MUST NOT silently fall back from private lookup to plaintext handle lookup. The user may explicitly choose a less-private retry after seeing the privacy change.

---

## 10. DeviceSet, revocation, and session admission

Resolution supplies candidates; the endpoint still performs ordinary trust checks.

### 10.1 Device selection

For each device selected for PairInit or message fan-out:

1. certificate is present in the accepted DeviceSet;
2. certificate identity/address, device ID, Ed25519 key, X25519 key, capabilities, and validity all verify;
3. prekey bundle binds to that exact device/certificate;
4. no accepted RVDR1 target covers its `device_id`, `device_ed_pub`, `device_x_pub`, or cert hash;
5. local contact exists and is not blocked;
6. transport identity binding matches the selected device key.

Passing these checks proves validity against the verifier's current evidence, not global revocation freshness. New resolution/session attempts should acquire fresh transparency and revocation evidence when connectivity permits, while remaining fail-closed on any locally stored deny.

### 10.2 Updates

A fresher DeviceSet may add a new device only after full verification. It may not reset ratchets or automatically merge sessions. Each device/session has explicit durable state.

A removed DeviceSet entry is not itself a revoke. A new device reusing any revoked lineage identifier is denied even if its new certificate signature is valid.

### 10.3 Resolution versus authorization

`RAVEN_CAPABILITIES_V1` advertises protocol support; it is not a community authorization token. Device certificate capability bits, identity protocol capability bits, namespace grants, community delegations, public-feed subscriptions, and contact trust are distinct namespaces and must not be conflated. A handle change never rekeys a public repository, and following a verified public identity never authorizes private messaging.

Public-feed subscription state is keyed by full canonical identity plus exact repository ID/descriptor digest and remains a local read policy. It is never cached under a bare handle and MUST NOT unlock private/contact Object Sync. [`RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md`](RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md) defines the separate asymmetric pull architecture; it and the corresponding umbrella/Carrier Conformance revisions must be APPROVED before network use.

A resolver/search result that exposes a public repository candidate enters `STRANGER_DISCOVERY` under [`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md) unless the user already has an exact local subscription. Resolver score, namespace reputation, repeated results, popularity, or transparent-handle status cannot assign rank, notification permission, contact affinity, or a stronger attention lane.

For a mutually accepted contact, exact verified device certificates may become
input to Private Rendezvous. Resolution itself MUST NOT publish stable route
addresses, derive pairwise lookup capabilities, report online status, dial a
candidate, or infer mutual acceptance. A bare Raven ID/private-prekey lookup
cannot silently fall back to a public rendezvous namespace or inbox.

If a future resolver supports Identity Continuity V2, its durable key is the full continuity ID/address plus exact greatest control generation/head. The current operational key is a versioned value authorized by that head, not a replacement identity. Resolution must return and verify the complete bounded control/policy/recovery evidence required by the V2 profile; a bare new key, alias update, server timestamp, or migration claim never substitutes. V1 and V2 records remain distinct input classes.

---

## 11. Cache and pinning rules

### 11.1 Cache keys

Durable caches are keyed by full canonical values:

- identity cache: full `identity_address`;
- DeviceSet: `(identity_address, generation, exact_digest)`;
- bare alias: `(normalized_alias, identity_address)`;
- namespace config: `(namespace_id, config_sequence, exact_config_digest)`;
- namespaced handle: `(namespace_id, namespace_config_digest, normalized_handle)` plus transparency version;
- transparency state: `(namespace_id, namespace_config_digest, exact_log_configuration_id)`;
- accepted public-repository descriptor: `(identity_address, repo_id, exact_descriptor_digest)`, only after separate social-profile verification and explicit local subscription.

Short codes, display names, petnames, and network addresses are not durable trust keys.

### 11.2 Pin-on-accept

Contact commit stores:

- canonical identity address and full identity public key;
- exact accepted credential/DeviceSet digests;
- safety fingerprint;
- input class and exact namespace ID/config/log evidence if any;
- acceptance time and user-confirmation event;
- current known revocation evidence state.

Future resolution to a different identity produces `KeyChanged`; it never rewrites the contact automatically.

### 11.3 Unknown candidates

Unknown/stranger results use a small TTL/LRU ephemeral cache keyed by full identity key/address and source policy. They cannot evict trusted contacts, accepted DeviceSets, revocations, or pending session work. No lookup result creates durable session secrets before Accept.

---

## 12. Failure and adversarial behavior

| Failure | Required behavior |
|---|---|
| Bad address checksum/length/version | Reject before network |
| Address does not match identity public key | Reject candidate |
| Bad identity/DeviceSet/cert signature | Reject candidate; no partial device acceptance |
| Expired record/cert/proof | Stale/unavailable; no automatic fallback |
| Equal DeviceSet generation, different bytes | Equivocation; fail closed and retain evidence |
| Multiple live bare-alias identities | Ambiguous; no tie-break |
| Namespace display label resolves to unpinned config/root | DiscoveryOnly; require exact trusted config or explicit fingerprint confirmation |
| Equal namespace config sequence, different bytes | Config equivocation; quarantine namespace and retain both |
| Config update lacks previous digest/cross-signature | Reject update; keep old pin only within its validity/staleness policy |
| Root key changes in place | Reject; treat as a new namespace requiring explicit re-trust |
| Incomplete old-log→new-log migration | SplitViewSuspected/Stale; refuse new contact acceptance |
| Multiple current namespace grants for one label | Ambiguous + namespace quarantine; no resolver tie-break |
| Namespace grant mismatch | Reject |
| Invalid KT Search/consistency/monitor proof | SplitViewSuspected; quarantine namespace |
| KT service unavailable inside staleness window | May use last verified pin only under frozen policy; no new identity |
| KT unavailable after staleness deadline | Refuse new resolution/update |
| VOPRF/OHTTP unavailable | Refuse private path; explicit user decision required for plaintext lookup |
| DeviceSet omits old device | No implicit revoke |
| Valid DeviceSet includes revoked lineage | Device remains denied |
| Resolver returns too many candidates/bytes | Capacity error before parse/allocation; no eviction of trusted state |
| DHT/order conflict | Preserve bounded candidates; network order has no authority |
| Repo descriptor owner/address mismatch | Reject public-view candidate; no contact/session mutation |
| ResolveRecord omits a previously pinned repo hint | No implicit unfollow, deletion, or repository revocation |
| Conflicting repo descriptor/head hints | Preserve bounded evidence for social-profile verification; resolver/source count cannot choose |
| Process crash during pin/contact commit | Old or new complete state only; never contact without accepted evidence |

---

## 13. UX contract

### 13.1 Terminal

Future commands should separate discovery from trust:

```text
ash resolve <RavenAddress|RavenCode|@name@namespace>
ash contact add --credential <file-or-stdin>
ash contact accept <candidate-id>
ash send <accepted-contact> <message>
```

`ash send @bare-alias ...` is forbidden. A resolver result must be reviewed/accepted once, after which the local contact identifier is used.

### 13.2 Apple UI

The Add Contact screen shows:

- what was entered/scanned;
- canonical Raven address;
- fingerprint and identity-key change status;
- DeviceSet device count/freshness;
- transparency namespace, proof mode, and staleness;
- namespace fingerprint and config-change status;
- ambiguity, block, and revocation warnings;
- explicit Accept or Refuse.

Messages such as “ready to chat” may appear only after durable contact commit and usable verified device/prekey material exist.

### 13.3 Honest labels

Suggested UI states:

- `Address verified`;
- `Handle verified by <namespace> transparency`;
- `Offline credential — checked at <time>`;
- `Ambiguous name — compare full address`;
- `Identity changed — sending disabled`;
- `Transparency problem — use QR/full address`;
- `Device revoked or blocked`.

“Verified person” is forbidden unless a separate real-world credential system supplies that claim.

---

## 14. Persistence and crash safety

Resolution state participates in the Full Braid/endpoint durability architecture but uses separate domains and records.

Requirements:

1. protected monotonic anchor for greatest accepted namespace config, DeviceSet, and log state;
2. SQLCipher or approved encrypted store for public metadata where required by platform profile;
3. two-phase journal for contact accept, pin update, and transparency-state promotion;
4. prepare → durable SQL → protected anchor → clear journal;
5. recovery always roll-forward and idempotent; never roll back a greatest verified tree head;
6. exact conflicting proofs retained within bounded evidence quota;
7. platform unavailable/locked/corrupt states fail closed;
8. no plaintext file fallback for protected pins or contact decisions.

This draft authorizes no schema or implementation until the durability foundation and wire vectors are approved.

---

## 15. Test and acceptance matrix

### 15.1 Shared vectors

Python, Rust, and Swift must compute, not merely parse JSON:

- canonical/display address resolution;
- contact credential verification;
- DeviceSet generation/replay/equivocation;
- certificate/prekey binding;
- Raven Code derivation and collision bucket behavior;
- bare alias ambiguity;
- namespaced grant verification;
- namespace config bootstrap, chain continuity, config-key rotation, root-substitution refusal, and exact-config proof binding;
- KT Search/update/monitor credentials for a pinned protocol revision;
- VOPRF derivation, namespace/epoch separation, migration, and wrong-key proof rejection if the privacy profile is implemented;
- revocation union application;
- public repo descriptor hint binding, owner substitution rejection, omission-without-unfollow, and no-contact/no-PairInit side effects;
- every failure in §12.

### 15.2 Split-view simulation

At minimum:

- honest log convergence;
- targeted malicious mapping shown only to one victim;
- conflicting signed tree heads gossiped between contacts;
- monitor removal/rollback;
- namespace/log key rotation and migration;
- same display label with two namespace roots and same-sequence config equivocation;
- client state loss/restore from stale backup;
- two independent witnesses with one malicious;
- offline credential that expires before reconnect.

No simulation may claim proof of real-world monitor availability.

### 15.3 Physical/process matrix

| Surface | Required scenario |
|---|---|
| iPhone A → iPhone B | QR credential → Accept → PairInit → message1 → ACK → message2 |
| Terminal → iPhone | Full address and namespaced handle paths; exact device binding |
| iPhone → Terminal | Offline credential, kill/relaunch, later online monitor |
| Linux/Windows/macOS | Protected pin persistence, rollback/corruption, concurrent accept |
| Partition | Alias/DeviceSet update withheld; no false instant-revoke claim |
| Public view | Follow verified repo from one device, relaunch, resolve through a different cache, and prove no contact/PairInit/private inventory mutation |
| Block/revoke | Every resolution/session/send path denied consistently |

### 15.4 Resource gates

Every parser and service must freeze maximum:

- input bytes and Unicode length;
- candidates per lookup;
- devices/certs/prekeys per DeviceSet;
- credential/proof bytes;
- concurrent lookups;
- transparency monitor entries/evidence;
- cache bytes and TTL;
- per-identity, per-namespace, and process-global work;
- lookup retries and private-service fallbacks.

No active trusted entry may be evicted merely to admit stranger-controlled data.

---

## 16. Migration from V1 discovery

1. `RavenAddressV1` remains canonical and unchanged.
2. `RavenAliasRecordV1` remains parseable as a self-claim but never becomes unique by reinterpretation.
3. `RavenProfileRecordV1` remains advisory public metadata; its `device_set_commitment` is not a usable DeviceSet without this companion's exact verified record.
4. Existing DHT alias/profile caches enter `DiscoveryOnly`; they cannot silently populate accepted contacts.
5. Existing local contacts keep their pinned canonical identity; a new resolver may enrich but not rebind them.
6. Server-issued legacy `userId` cannot be a KT primary label or canonical Raven identity.
7. Migration requires new versioned records and vectors; no old bytes are reinterpreted as `RavenResolveRecordV1` or `RavenDeviceSetV1`.
8. A legacy domain/alias cache does not bootstrap a namespace root. It may locate config candidates only and remains `DiscoveryOnly` until the exact namespace ID/config chain is authenticated.

---

## 17. Production holds

This companion cannot be APPROVED, and no ID-only contact/send UX can be enabled, until:

1. exact wire layouts, domains, caps, errors, and vectors are frozen;
2. namespace ID/config bootstrap, chain, rotation, root-substitution, normalization migration, and same-sequence equivocation vectors pass in Python/Rust/Swift;
3. a concrete Key Transparency protocol revision/profile is pinned and independently reviewed;
4. owner and contact monitoring, split-view, state-loss, and log-migration tests pass;
5. privacy profile claims match VOPRF/OHTTP deployment and non-collusion assumptions;
6. DeviceSet/cert/prekey/revocation integration passes three-language tests;
7. Apple/Linux/Windows protected persistence and crash recovery pass;
8. Terminal and Apple UX require explicit contact acceptance;
9. no bare alias, untrusted namespace config, or unverified profile can reach PairInit/send;
10. production flags remain blocked by all umbrella companions and physical carrier gates;
11. independent security/privacy review has no open P0/P1;
12. if public-view discovery ships, its social repo descriptor/head profile and separate public-read carrier boundary are APPROVED with no contact escalation;
13. Attention Firewall V1 is APPROVED before resolver/search candidates can enter any public discovery/ranking/notification surface;
14. Identity Continuity V2 and its exact address/event/migration wires are APPROVED before any recovery-aware resolution, key change, or V1→V2 continuity UX ships;
15. Private Rendezvous V1 is APPROVED before an ID-only/contact workflow can
    locate, publish, query, or dial a peer path without an explicit OOB route;
16. human protocol-owner approval is recorded in this header.

Passing automated vectors alone is not approval.

---

## 18. Open decisions before vector freeze

1. Exact `RavenDeviceSetV1`, `RavenNamespaceConfigV1`, `RavenResolveRecordV1`, grant, and credential encoding.
2. Raven Code bit length, alphabet, checksum, and DHT/index policy.
3. Exact namespace-ID derivation, config-chain signatures, root-key custody, fingerprint presentation, and optional DNSSEC/WebPKI bootstrap profile.
4. Exact normalization/confusable profiles and migration rules.
5. Exact IETF Key Transparency draft/RFC revision and cipher suite.
6. Contact-monitoring versus witness threshold production profile.
7. Tree-head gossip packaging without turning control into public contact metadata.
8. VOPRF/OHTTP service separation, padding, key epochs, index rebuild, rate credentials, and offline behavior.
9. DeviceSet maximum size and prekey-reference delivery.
10. Protected monotonic-store domains and migration.
11. Exact adoption boundary for [`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md), including Address V2, control-event lookup, Key Transparency label/value, historical-key verification, and V1 migration.
12. Bounded packaging of public-repository descriptor hints without turning resolution into a firehose, repository host authority, or public-read authorization.
13. Exact handoff into Private Introduction without allowing the resolver to
    send, select a provider, or mutate contact state; then post-mutual-contact
    handoff into Private Rendezvous without exposing stable routes, contact
    graphs, or a public presence namespace.

---

## 19. Research references

These sources inform the design but are not incorporated as Raven wire formats:

- [IETF Key Transparency Architecture](https://datatracker.ietf.org/doc/draft-ietf-keytrans-architecture/) and [Protocol](https://datatracker.ietf.org/doc/draft-ietf-keytrans-protocol/) — work in progress; searchable append-only mappings, monitoring, fork detection, credentials, deployment modes.
- [RFC 9497 — Oblivious Pseudorandom Functions](https://www.rfc-editor.org/rfc/rfc9497.html) — OPRF/VOPRF/POPRF primitives for optional private index derivation.
- [RFC 9458 — Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458.html) — relay/gateway separation for optional network-address unlinkability.
- [`RAVEN_ADDRESS_V1.md`](RAVEN_ADDRESS_V1.md), [`RAVEN_ALIAS_V1.md`](RAVEN_ALIAS_V1.md), [`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md), and [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md) — existing Raven identity boundaries.

---

## 20. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial architecture/security draft: input classes, DeviceSet, ResolveRecord, offline credentials, Raven Code constraints, namespaced handles, Key Transparency, VOPRF/OHTTP privacy profile, split-view defense, contact-gated state machine, migration, and production holds |
| 2 | 2026-08-21 | Red-team hardening: self-certifying namespace configuration and bootstrap, authenticated config/key/log migration, ResolveRecord chain/equivocation rules, exact config binding for grants/KT/offline credentials, VOPRF epoch separation, read-only public-view branch without contact escalation, and new failure/acceptance gates |
| 3 | 2026-08-21 | Public-subscription boundary: optional content-addressed repository-descriptor hints; exact owner/descriptor verification; resolver/source/popularity non-authority; local subscription keys; explicit hold on non-contact Object Sync until a separate public-read carrier profile is approved |
| 4 | 2026-08-21 | Attention-plane boundary: public repo/search candidates enter only a local stranger lane; resolver transparency, popularity, or score cannot grant attention, rank, notification, contact, or private-sync authority |
| 5 | 2026-08-21 | Identity-continuity boundary: V1 remains key-bound and unrecoverable; separate V2 results key by stable continuity ID plus greatest control head; bare new keys/migrations cannot replace exact recovery evidence; production held on Address/Event/Migration V2 approval |
| 6 | 2026-08-21 | Private-rendezvous boundary: resolution ends at accepted identity/device/prekey evidence; path lookup, pairwise capabilities, presence labels and dial remain in a separate production-disabled companion; no bare-ID fallback to public rendezvous/inbox |
| 7 | 2026-08-21 | Private-introduction boundary: purpose-typed session versus introduction descriptor/prekey references; a verified candidate may enter an explicit production-disabled inert-proposal flow without becoming a contact, message, PairInit, route, presence or notification; only a separately verified acceptance can reach the sender's local contact commit |
