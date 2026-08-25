# RAVEN Carrier Conformance V1

**Version:** 1
**Document revision:** 4
**Status:** **REQUIRED / NOT YET APPROVED**
**Production:** **disabled** — this document authorizes no Release flag, live radio path, relay, mailbox, bridge, Object Sync implementation, or realtime-media transport
**Approval prerequisites:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md) **Approved**; [`RAVEN_OBJECT_SYNC_V1.md`](RAVEN_OBJECT_SYNC_V1.md) **APPROVED** (not yet met)
**Scope:** LAN/Wi-Fi, BLE, Internet direct, Circuit Relay/DCUtR, offline mailbox, terminating bridge/gateway, and explicit offline import

This companion defines one conformance boundary for every Raven carrier. It does **not** make those carriers identical. It makes their security meaning identical:

> A carrier moves exact immutable endpoint objects. It may prove local custody or link reachability. It never becomes the endpoint, never invents trust, and never turns a successful write into delivery.

The umbrella's three byte classes and invariants remain binding. This companion cannot override them.

---

## 0. Normative language and document boundary

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**, **MAY**, and **OPTIONAL** are interpreted as in RFC 2119 / RFC 8174.

Revision 1 is a design freeze candidate, not an implementation authorization. Before **APPROVED**, this document still requires:

1. independent byte/state/security review;
2. shared Python/Rust/Swift vectors;
3. provider-specific exporter proofs;
4. deterministic adversarial simulation;
5. physical per-carrier evidence;
6. protocol-owner approval.

### 0.1 Non-goals

This revision does not:

- replace ATSAM endpoint encryption, PairInit, Session V2, device certificates, revocation, or local contact policy;
- claim anonymity, traffic-analysis resistance, or Byzantine global copy limits;
- make libp2p PeerId, Noise static keys, Bonjour names, BLE identifiers, IP addresses, mailbox tags, relay vouchers, or QR payloads into Raven identities;
- define a universal radio frame that every carrier must copy;
- persist Object Sync control in mailboxes or forward it hop-by-hop over BLE;
- allow a carrier to parse message/ACK/social/community semantics;
- treat an ActivityPub/Matrix/Nostr/MIMI translator as an opaque Raven bridge;
- treat ICE/STUN/TURN/DTLS/SRTP/RTP/RTCP/SFrame packets as immutable endpoint
  objects or route them through `send_exact`/Object Sync/mailbox retry;
- approve the legacy RVN1 hop-mutable envelope, raw RVNP1, interim MeshContent, server fallback, or current placeholder hop-MAC chain;
- enable production.

---

### 0.2 Realtime-media boundary

[`RAVEN_PRIVATE_REALTIME_MEDIA_V1.md`](RAVEN_PRIVATE_REALTIME_MEDIA_V1.md)
defines a separate future class of ephemeral realtime transport bytes. Call
Offer/Answer/Update control records may be immutable endpoint objects and use
this conformance layer. Media-plane packets do not: they have independent
consent, loss, ordering, counter, congestion, replay and lifetime semantics.

### 0.3 Semantic interoperability-gateway boundary

[`RAVEN_SOVEREIGN_INTEROPERABILITY_GATEWAY_V1.md`](RAVEN_SOVEREIGN_INTEROPERABILITY_GATEWAY_V1.md)
defines a separate production-disabled endpoint/application role. Such a
gateway terminates foreign and Raven application protocols, may see plaintext,
and produces new attributed observation/projection objects. It never inherits
carrier opacity, link exporter state, endpoint delivery authority or permission
to rewrite `endpoint_object_bytes`. Conversely, an opaque Raven bridge cannot
parse or translate foreign social/message semantics. The same host may perform
both roles only with explicit credential, process, queue and log separation.

Carrier custody, a relay circuit, TURN allocation, SFU subscription, ICE
success or packet forwarding never means call acceptance, media authentication,
recipient delivery, Raven identity, community membership or Attention
permission. No carrier adapter may silently tunnel realtime packets through the
durable endpoint-object API to claim conformance.

---

## 1. Goals and threat model

### 1.1 Goals

| Goal | Required meaning |
|---|---|
| Exact object portability | The same `endpoint_object_bytes` can traverse any approved carrier without re-seal, re-encode, or digest drift. |
| Endpoint sovereignty | Only the endpoint actor decrypts, applies trust records, advances ratchets, mints endpoint ACKs, or marks Delivered/Read. |
| Honest custody | A transport can report `transmitted` or `custody_committed`; neither means recipient delivery. |
| Downgrade resistance | Required carrier properties are negotiated inside an authenticated, transcript-bound link; missing support refuses the feature, never activates legacy fallback. |
| Store-carry-forward | Disconnection, partitions, NAT, and radio churn can delay delivery without changing the endpoint object. |
| Multi-path safety | LAN, BLE, relay, and mailbox may carry the same object concurrently under one authoritative digest. |
| Metadata honesty | Every profile states exactly which addresses, identifiers, sizes, timing, and correlations each intermediary sees. |
| Bounded abuse | Allocation, parsing, retransmission, inventory, custody, replication, and crypto work have independent finite budgets. |
| Crash-safe retry | A process restart retries the exact staged bytes and never reports success from a partial carrier handoff. |

### 1.2 Adversaries

The design considers:

- an on-path attacker who drops, duplicates, reorders, truncates, injects, or modifies records;
- a malicious authenticated transport peer;
- an honest-but-curious relay, mailbox, bridge, ISP, local-network observer, or Bluetooth observer;
- a relay/mailbox that lies about custody, withholds rows, replays rows, or selectively degrades direct paths;
- a malicious bridge that loops, amplifies, transcodes, terminates links, or attempts to transplant control state;
- a compromised or stale discovery source advertising false addresses/capabilities;
- process death at every durable boundary;
- memory, disk, CPU, radio, connection, and store exhaustion;
- path changes, NAT rebinding, relay failure, and simultaneous carrier completion;
- SHA-256 digest-identity collision as an explicit terminal state even though constructing one is assumed infeasible.

### 1.3 Explicitly unprovided guarantees

Raven does not claim that:

- ciphertext hides size, timing, source IP, destination IP, radio presence, mailbox polling, or relationship patterns;
- a relay/store truthfully reports every row or forwards fairly;
- hop-local TTL or replication budgets are globally enforceable against colluding nodes;
- custody means delivery;
- path authentication means contact authentication;
- one carrier can erase already replicated copies on other devices;
- a direct route is more trustworthy than a relayed route.

---

## 2. Constitutional byte and identity rules

### 2.1 Three byte classes

| Class | Carrier treatment |
|---|---|
| `endpoint_object_bytes` | Exact immutable sealed endpoint object or companion-approved signed public endpoint record. Authoritative identity is `SHA-256(exact bytes)`. |
| `carrier_record_bytes` | Carrier-specific wrapper, fragments, custody metadata, padding, store tags, hop budgets, and route-local state. It may differ on every hop. |
| `carrier_control_bytes` | Handshake, link capability, flow control, Object Sync, relay/DCUtR coordination, inventory, and custody response. Never endpoint admission. |

The classes are disjoint. A parser MUST know the expected class from its demultiplexed channel before looking at a magic value. A magic value alone never changes class.

### 2.2 Authoritative digest

```text
object_digest = SHA-256(endpoint_object_bytes)
```

Rules:

1. The carrier computes this digest itself before admission.
2. A caller-supplied digest is comparison evidence only. Mismatch rejects before durable reservation.
3. Endpoint dedup, multi-path identity, exact retry, ACK correlation, and local cancellation use this digest.
4. Wrapper, fragment, message-ID, mailbox-page, custody-receipt, and transport hashes never replace it.
5. The digest is not an authenticity proof. The endpoint still verifies the exact object's signature/session authentication.
6. Two byte strings with the same digest but different length or bytes enter `DIGEST_COLLISION_QUARANTINE`; neither is selected, overwritten, forwarded, delivered, or silently evicted.
7. A collision quarantine is durable and non-evicting until explicit repair or a protocol-version migration.

### 2.3 Exact-byte rule

After endpoint admission, a conforming carrier MUST NOT:

- rewrite hop limits inside the endpoint object;
- normalize encodings;
- change padding inside the endpoint object;
- rebuild ciphertext, nonce, signature, `init_id`, message ID, or ACK;
- convert JSON and binary representations;
- unwrap and re-seal at a relay or bridge.

Fragmentation and padding occur only in `carrier_record_bytes`. Reassembly produces the byte-identical original before endpoint admission.

### 2.4 Object classes

A carrier adapter has a finite allow-list:

```text
SEALED_ENDPOINT_OBJECT
PUBLIC_AUTHENTICATED_ENDPOINT_RECORD
```

Unknown, legacy, raw, ambiguous, nested, or carrier-control magics are refused. A public authenticated endpoint record remains opaque to the carrier; only the endpoint/trust actor verifies and applies it.

---

## 3. Actors and trust separation

### 3.1 Actors

| Actor | May do | Must not do |
|---|---|---|
| Endpoint Actor | Verify contact/cert/revocation, open endpoint object, commit receipt, mint/verify endpoint ACK, advance Delivered/Read | Await network while holding mutation lease |
| Router | Select paths, reserve local budgets, enqueue exact staged bytes, stop local attempts after verified endpoint ACK | Decrypt, mint ACK, treat custody as delivery |
| Carrier Adapter | Frame, establish links, send/receive exact bytes, report local path/custody state | Interpret endpoint semantics or create trust |
| Relay/Store | Opaque bounded forwarding/storage and optional custody evidence | Decrypt, re-origin, parse social/session semantics, mint endpoint ACK |
| Terminating Bridge | Act as two independent carrier endpoints and rewrap unchanged endpoint bytes | Transplant link control/exporter/Object Sync state across links |
| Discovery Source | Offer untrusted bounded route candidates | Create a contact, session, or authorization |

### 3.2 Link classes

Every carrier security context is exactly one class. The byte value is frozen for
`RVCM1`; `0xff` and all unlisted values are reserved and rejected:

| Code | Class | Meaning | Endpoint objects | Object Sync |
|---:|---|---|---:|---:|
| 0 | `DISCOVERY_ONLY` | Unauthenticated address/capability hints | No | No |
| 1 | `ENDPOINT_AUTHENTICATED` | The two Raven devices terminate one authenticated link and exact device-certificate binding passed | Yes, subject to contact/revocation | Yes, if exporter/profile approved |
| 2 | `OPAQUE_CIRCUIT` | The Raven endpoints terminate one authenticated link carried unchanged through an opaque relay circuit; the relay is not a participant | Inside the end-to-end encrypted stream only | Inside that same stream only, if exporter/profile approved |
| 3 | `ADJACENT_HOP_AUTHENTICATED` | One mesh/bridge hop is authenticated, but it is not the final recipient session | Opaque store/forward under policy | Only a fresh independent round with that adjacent peer; never forwarded |
| 4 | `MAILBOX_CAPABILITY` | Store tag authorizes bounded opaque PUT/GET | Opaque records | No |
| 5 | `IMPORT_MEDIUM` | QR/file/cable/manual import | Bounded exact import | No live link |
| 6 | `BOUNDED_UNAUTHENTICATED_HOP` | A profile-approved untrusted mesh hop with strict local admission and quotas | Opaque fragments only | No |

`RVCM1`/`RVLN1`/`RVLB1`/`RVLC1` negotiation applies only to live authenticated classes
1–3. Classes 0 and 4–6 do not fabricate a two-party manifest exchange; their
approved profile freezes the equivalent baseline properties and enforces them
locally. An `OPAQUE_CIRCUIT` context is authenticated end to end by the Raven
devices. The switching relay itself has no Raven link class, exporter, manifest,
or endpoint authority.

Changing class requires an explicit state transition and usually a new authenticated session. Route discovery cannot promote a link class.

### 3.3 Trust gates

Before an endpoint link admits application frames, the host verifies:

1. local contact exists and permits the operation;
2. exact remote Raven identity and device certificate;
3. certificate signature, lineage, validity, role, and device keys;
4. local block policy;
5. approved revocation state;
6. expected-device binding for the authenticated link;
7. required carrier capability transcript.

These checks occur before Object Sync, endpoint decrypt, or durable receipt mutation. A relay/bridge need not be a contact merely to carry opaque bytes, but that fact grants it no endpoint authority.

---

## 4. Logical Carrier API

Names may differ, but semantics may not.

```text
probe(route_hints, local_policy, explicit_now) -> bounded RouteCandidate[]

establish(
  candidate,
  expected_remote_device?,
  required_profile,
  explicit_deadline
) -> AuthenticatedLink | OpaqueCapability | Error

admit(
  endpoint_object_bytes,
  supplied_digest?,
  endpoint_class,
  endpoint_expiry_evidence?,
  peer_eligibility_handle,
  local_policy
) -> DurableObjectHandle

send_exact(
  durable_object_handle,
  carrier_profile,
  route_candidate,
  attempt_identity,
  carrier_budget
) -> AttemptOutcome

receive_record(
  authenticated_or_capability_link,
  exact_carrier_record_bytes,
  local_budget
) -> ExactObjectCandidate | ControlOutcome | Error

report_custody(attempt_identity, custody_evidence) -> LocalCustodyOutcome
cancel_local(object_digest, reason) -> LocalCancellationOutcome
close(link) -> Result
```

### 4.1 API invariants

1. `probe` returns hints only; it performs no durable trust mutation.
2. `establish` has finite time/connection/crypto budgets.
3. `admit` recomputes the digest, validates class/length/expiry shape, reserves capacity, and persists exact bytes before returning a handle.
4. `send_exact` reads only the exact durable object bound to the handle. A caller cannot substitute new bytes under an old digest.
5. Carrier I/O runs outside endpoint/session mutation leases.
6. One attempt identity cannot be reused for different object, route, profile, wrapper, or bytes.
7. A byte-identical retry of the same attempt reuses its retained outcome; a new attempt gets the exact next monotonic attempt number and consumes budget again.
8. `cancel_local` only stops local future attempts. It cannot erase remote queues, relay buffers, radio copies, or mailbox rows.
9. Closing a link wipes exporter/control/replay secrets and never deletes endpoint durable evidence.

### 4.2 Attempt identity

```text
attempt_identity = (
  object_digest,
  carrier_profile,
  route_instance_id,
  attempt_u32
)
```

`attempt_u32` begins at zero and increases by exactly one per new logical carrier attempt. Same identity/different wrapper bytes is conflict. Transport-level retransmission inside one accepted attempt does not allocate a new attempt identity.

---

## 5. Admission, expiry, and collision behavior

### 5.1 Parse-before-allocation

Each carrier freezes:

- minimum and maximum record length;
- fixed-prefix length;
- checked length arithmetic;
- object count, fragment count, page count, and nesting caps;
- per-link, per-device, per-route, per-store-tag, and process-global bytes/work;
- deadlines and idle limits;
- exact allowed object classes and profile versions.

The receiver reads only the fixed prefix, refuses declared overflow, reserves worst-case memory/work, then reads the remainder. Trailing bytes and concatenated records are errors unless the stream framing explicitly defines multiple records.

### 5.2 Expiry

Carriers do not extend endpoint validity. The local effective carrier expiry is:

```text
effective_expiry = min(
  authenticated_endpoint_expiry_if_any,
  endpoint_admission_policy_expiry,
  wrapper_expiry,
  local_carrier_max_expiry
)
```

Rules:

- checked arithmetic only;
- a peer may shorten custody but cannot make an expired endpoint object valid;
- endpoint actors re-check their own validity windows after exact receipt;
- expiry removes pending carrier work only after durable outcome recording;
- expiry does not authorize deleting endpoint receipt/ACK replay evidence before its own horizon;
- mailbox/store expiry is TTL deletion, not endpoint rejection evidence;
- a late valid endpoint ACK may still be processed under the endpoint outstanding/replay policy even if one carrier attempt expired.

### 5.3 Collision and conflicting identity

| Input | Outcome |
|---|---|
| Same digest, exact same bytes | Idempotent replay; reuse durable handle/outcome |
| Same digest, different length/bytes | Durable collision quarantine; stop all attempts for that digest |
| Same attempt identity, different wrapper | Carrier conflict; no overwrite |
| Same fragment identity, different bytes | Drop whole assembly; retain bounded conflict evidence |
| Same custody identity, different receipt | Conflict; custody remains unproven |
| Same endpoint message ID, different digest | Separate untrusted objects until endpoint authentication; never overwrite by message ID |

---

## 6. Authenticated capability and downgrade contract

Capabilities are not trust. They only describe what an already classified link can safely do.

Initiator/responder are the authenticated handshake roles, never local/remote or
lexicographic identity order. A carrier whose handshake lacks canonical roles
must freeze an unambiguous role derivation in its profile before it may use
these records. Simultaneous dials are resolved to one retained authenticated
link before manifest exchange; records from the losing link cannot migrate.

### 6.1 Mandatory baseline features

Feature bits in this revision are:

| Bit | Name | Meaning |
|---:|---|---|
| 0 | `EXACT_ENDPOINT_BYTES` | No endpoint rewrite/reseal/normalization |
| 1 | `ENDPOINT_ACK_ONLY` | Transport/custody never marks Delivered |
| 2 | `DIGEST_RECOMPUTE` | Adapter recomputes SHA-256 of exact endpoint bytes |
| 3 | `STRICT_BOUNDS` | Finite parse/allocation/work/deadline limits |
| 4 | `NO_LEGACY_FALLBACK` | Failure cannot activate raw/interim/server fallback |
| 5 | `AUTHENTICATED_EXPORTER` | Approved post-handshake exporter is available |
| 6 | `OBJECT_SYNC_V1` | Exact approved RVOS1 profile supported |
| 7 | `HOP_CUSTODY_RECEIPT` | Authenticated hop custody evidence supported |
| 8 | `CARRIER_PADDING` | Approved bounded wrapper padding supported |
| 9 | `PATH_MIGRATION` | Profile-specific authenticated path migration supported |

Bits 0–4 are mandatory for every V2 carrier that carries endpoint objects. On
an `RVCM1` link they MUST appear in `required_features`, not merely
`optional_features`. Bits 5–6 are mandatory before Object Sync. Bit 7 MUST remain
off until custody-receipt bytes are approved; bits 8–9 remain off unless the
named carrier profile freezes their exact semantics. Unknown required bits are
unsupported and fail negotiation. Unknown optional bits are transcript-bound
but masked out of `effective_features`; they are never assumed.

### 6.2 `RVCM1` Carrier Manifest V1

`RVCM1` is exactly 72 bytes and is `carrier_control_bytes`:

```text
offset  size  field
0       5     magic = ASCII "RVCM1"
5       1     schema_rev = 1
6       1     role: initiator=0, responder=1
7       1     link_class
8       32    carrier_profile_digest
40      8     required_features_u64be
48      8     optional_features_u64be
56      4     max_endpoint_object_bytes_u32be
60      4     max_carrier_record_bytes_u32be
64      4     max_control_frame_bytes_u32be
68      2     max_inflight_records_u16be
70      2     reserved = zero
```

```text
carrier_profile_digest = SHA-256(
  "raven/carrier/profile/v1" || u16be(profile_len) || profile_ascii
)
```

Profile strings are printable ASCII `0x21..0x7e`, length `1..63`, with exact case and no aliases. Numeric values are nonzero, meet the selected profile's minimum viable values, and cannot exceed local profile maxima. A peer value below a profile minimum refuses the profile; it is not silently raised.

Manifest validation additionally requires:

- `role` is exactly 0 or 1 and matches the sender's authenticated handshake role;
- `link_class` is exactly 1, 2, or 3 and is allowed by the selected carrier profile;
- `required_features & optional_features == 0`;
- mandatory baseline bits 0–4 are in `required_features`;
- reserved bytes are zero and no trailing bytes exist;
- all numeric limits are within the selected profile's nonzero hard maxima.

Each authenticated role contributes exactly one manifest for the current link.
An exact duplicate is idempotent. Same `(current_link, sender_role)` with
different manifest bytes is terminal; a manifest from the local/reflected role
is rejected. Manifest bytes are link-local control and are never accepted from
discovery, a relay participant, a prior connection, or application payload.

### 6.3 Effective capability calculation

```text
supported_x = required_x OR optional_x
known_x     = supported_x AND KNOWN_FEATURE_MASK_V1

require:
  required_initiator subset_of known_responder
  required_responder subset_of known_initiator

effective_features = known_initiator AND known_responder
effective_numeric  = component-wise minimum(local manifests, profile maxima)
```

If any mandatory baseline bit is absent, link establishment for endpoint objects fails. If Object Sync bits/exporter are absent, ordinary exact object delivery MAY continue, but Object Sync is disabled without raw-digest fallback.

### 6.4 `RVLN1` Link Nonce Contribution V1

After both strict manifests are accepted, each authenticated role sends one
exact 40-byte nonce contribution as `carrier_control_bytes`:

```text
offset  size  field
0       5     magic = ASCII "RVLN1"
5       1     schema_rev = 1
6       1     sender_role: initiator=0, responder=1
7       1     reserved = zero
8       32    session_nonce
```

The nonce is generated after the authenticated handshake from the platform CSPRNG,
is nonzero, and is never reused across reconnect, resumption, or another path.
Entropy failure refuses the link; there is no clock/counter/device-ID fallback.
The receiver requires the opposite authenticated role. Exact replay is
idempotent; same `(current_link, sender_role)` with different bytes is terminal.
No carrier object is admitted before both contributions are present. Nonces are
retained only for the current link/replay horizon and wiped on close.

### 6.5 `RVLB1` Link Binding V1

After the authenticated handshake and exact device-certificate verification, both endpoints construct one role-canonical binding:

```text
offset  size  field
0       5     magic = ASCII "RVLB1"
5       1     schema_rev = 1
6       2     total_len_u16be
8       1     link_class
9       1     flags = 0
10      1     carrier_profile_len (1..63)
11      1     handshake_profile_len (1..63)
12      4     reserved = zero
16      32    provider_handshake_transcript_digest
48      32    initiator_identity_device_certificate_digest
80      32    responder_identity_device_certificate_digest
112     32    initiator_session_nonce
144     32    responder_session_nonce
176     72    exact initiator RVCM1
248     72    exact responder RVCM1
320     c     carrier_profile_ascii
320+c   h     handshake_profile_ascii
```

`total_len = 320 + c + h`, therefore `322..446`. The two nonce fields are copied
exactly from the accepted role-canonical `RVLN1` contributions.

Strict `RVLB1` validation requires:

- `total_len` equals the exact received length; no trailing or concatenated bytes;
- flags/reserved bytes are zero and both profile strings satisfy the ASCII rule;
- initiator/responder manifests have roles 0/1 respectively;
- the top-level `link_class` equals both manifest link classes;
- both `carrier_profile_digest` fields equal the digest of the exact embedded
  `carrier_profile_ascii` and the selected local profile;
- `handshake_profile_ascii` is one exact approved provider profile, not an alias;
- certificate digests equal the already verified role-canonical device
  certificates;
- both nonces are nonzero, are not equal to one another, and are fresh in the
  local bounded replay namespace.

```text
link_binding_digest = SHA-256(
  "raven/carrier/link-binding/v1" || exact_RVLB1
)

session_unique_nonce = SHA-256(
  "raven/carrier/session-nonce/v1"
  || initiator_session_nonce
  || responder_session_nonce
  || link_binding_digest
)
```

### 6.6 `RVLC1` Link Confirm V1

Each endpoint sends one encrypted/authenticated 72-byte confirmation over the established link:

```text
0       5     magic = ASCII "RVLC1"
5       1     schema_rev = 1
6       1     sender_role
7       1     reserved = zero
8       32    link_binding_digest
40      32    effective_capabilities_digest
```

```text
effective_capabilities_digest = SHA-256(
  "raven/carrier/effective-capabilities/v1"
  || exact initiator RVCM1
  || exact responder RVCM1
  || u64be(effective_features)
  || u32be(effective_max_endpoint_object_bytes)
  || u32be(effective_max_carrier_record_bytes)
  || u32be(effective_max_control_frame_bytes)
  || u16be(effective_max_inflight_records)
)
```

No endpoint object or Object Sync frame is accepted until both exact confirmations match local computation. Each side accepts exactly the opposite authenticated role's confirm; an exact duplicate is idempotent. Same role/binding with different confirm bytes, a same-role reflection, or a confirm from a different link is terminal for that link. A lost confirm is retried byte-identically under a finite count/deadline. Reconnect or re-authentication creates new manifests, nonces, binding, confirmation, exporter context, and replay namespace.

### 6.7 Downgrade rules

- Capability negotiation occurs only inside the authenticated link.
- Discovery advertisements MAY say a profile might exist; they never satisfy it.
- A required missing/stripped bit refuses that feature.
- A peer cannot request a lower security profile after a failed required profile on the same route attempt.
- A fallback to V1 raw LAN, RVNP1, interim MeshContent, server transport, plaintext inventory, early exporter, or unsigned capability is forbidden.
- User-visible troubleshooting may propose a different approved path; it must start a new explicit attempt and remain cryptographically equivalent at the endpoint layer.

---

## 7. Authenticated exporter mapping

Object Sync defines `RavenAuthenticatedLinkExporterV1`; this companion maps carrier handshakes to it. No carrier may improvise a traffic-key fallback.

### 7.1 Common exporter context

The `RVLX1.authenticated_handshake_transcript_digest` field is:

```text
SHA-256(
  "raven/carrier/authenticated-transcript/v1"
  || provider_handshake_transcript_digest
  || link_binding_digest
  || effective_capabilities_digest
)
```

The certificate digests, carrier/handshake profile strings, and `session_unique_nonce` are copied exactly into RVLX1 as defined by Object Sync. Initiator/responder are handshake roles.

`session_unique_nonce` becomes handshake-bound only after both `RVLC1`
confirmations authenticate its enclosing `RVLB1` on that same transport. RVLX1
construction/export is forbidden before that barrier.

### 7.2 Noise provider

For Raven LAN Noise and libp2p Noise:

1. the exact Noise pattern, DH, cipher, hash, prologue, and payload ordering are profile constants;
2. `provider_handshake_transcript_digest` is the final Noise handshake hash `h` after all handshake payloads;
3. Raven device certificate/static-key binding is verified before `RVCM1` acceptance;
4. an audited implementation MUST expose a dedicated post-handshake exporter secret derived from the final chaining key with an independent domain/output—not a directional transport key;
5. that provider secret backs `RavenAuthenticatedLinkExporterV1(label, context, len)` with exact length-delimited label/context domain separation;
6. if the implementation cannot expose and zeroize that exporter without changing standard transport keys, Object Sync remains disabled on that profile.

The exact KDF bytes and provider API remain a pre-approval vector item. An application-data “secret share” scheme or use of the Noise traffic key is not an implicit substitute.

### 7.3 TLS 1.3 / QUIC provider

TLS/QUIC uses the regular post-handshake TLS exporter with the exact Raven label/context. Early exporters, 0-RTT secrets, resumption PSKs, traffic keys, QUIC connection IDs, and address-validation tokens are forbidden substitutes. Exporter availability is required before Object Sync; ordinary endpoint delivery may operate without Object Sync if the rest of the carrier profile is approved.

Path validation proves reachability of a network address, not Raven contact or device identity.

### 7.4 Circuit Relay and DCUtR

- An opaque Circuit Relay carrying one end-to-end authenticated session preserves that session's exporter and RVLX1. The relay never sees or derives it.
- Relay termination/re-authentication creates a new independent link and exporter.
- DCUtR normally establishes a new direct authenticated connection. It therefore creates a new RVLB1/RVLX1 and aborts/restarts old Object Sync rounds; it does not transplant them.
- Endpoint objects may be retried byte-identically on the new path under the same `object_digest`.

### 7.5 Provider vector gate

For each approved provider, shared vectors MUST prove:

- exact handshake transcript digest;
- both manifest, nonce-contribution, binding, and confirm bytes;
- role-canonical certificate digests/nonces;
- exact RVLB1/RVLX1 bytes;
- identical exporter output at both endpoints;
- different output after role, cert, nonce, transcript, profile, capability, reconnect, or resumption change;
- opaque relay carriage preserves output;
- terminating relay/bridge and DCUtR re-authentication change it;
- no early/traffic-key fallback.

---

## 8. Custody and delivery are separate lattices

### 8.1 Per-attempt carrier lattice

```text
RESERVED
  -> WRAPPED
  -> ENQUEUED
  -> TRANSMIT_STARTED
  -> TRANSMITTED
  -> CUSTODY_COMMITTED?          # only if profile defines verifiable custody

Any nonterminal stage may also become:
  DEFERRED | EXPIRED | FAILED | LOCALLY_CANCELLED
```

These states describe one local carrier attempt. They never imply recipient delivery.

### 8.2 Endpoint delivery lattice

```text
QUEUED
  -> AWAITING_ENDPOINT_ACK
  -> DELIVERED_TO_DEVICE
  -> READ
```

Only a successfully authenticated/decrypted endpoint ACK with exact outstanding binding advances the endpoint lattice. The following are insufficient:

- socket/stream write completion;
- Noise/TLS handshake success;
- QUIC packet ACK;
- BLE write callback;
- relay reservation/voucher;
- DCUtR success;
- bridge forward;
- mailbox `STORED` or `GET`;
- Object Sync `Done`, page Ack, inventory equality, or exact-fetch enqueue;
- custody receipt;
- a server HTTP 2xx response.

### 8.3 Hop custody evidence

An approved profile MAY define authenticated `carrier_control_bytes` proving only that a named hop durably accepted exact `carrier_record_bytes`. Such evidence binds at least:

```text
carrier_profile
link_binding_digest or store identity
carrier_record_digest
inner_object_digest
accepted_at / bounded expiry
custody policy/result
```

It is never an endpoint object or endpoint ACK. A custody signature proves the signing store made the claim; it does not prove the store still holds the row, forwarded it, or delivered it.

### 8.4 Multi-path completion

The first locally verified endpoint ACK may:

1. advance endpoint delivery under its own transaction;
2. append local cancellation intents for remaining attempts by `object_digest`;
3. stop future local sends after that transaction commits.

It does not revoke bytes already handed to a carrier or delete remote copies. Duplicate valid ACKs are idempotent. Wrong signer/session/device/status/digest/outstanding rows never cancel attempts.

---

## 9. Carrier wrappers and hop-local metadata

### 9.1 Wrapper requirements

Every carrier wrapper profile specifies:

- version/magic and exact canonical encoding;
- record and endpoint-object length;
- inner object digest or an unambiguous recomputation rule;
- fragment/part identity;
- wrapper expiry and local hop/replication budget;
- optional padding rules;
- link/store binding;
- strict duplicate/conflict identity;
- per-record and cumulative limits;
- whether custody evidence exists;
- whether the wrapper may persist and for how long.

### 9.2 Hop-local budgets

Hop limit, bundle age, replication/spray count, ingress, egress, prior-hop hints, bridge-loop evidence, carrier padding, and attempt number live outside `endpoint_object_bytes`. They may be rewritten only according to the wrapper profile.

Unsigned budgets are local abuse controls, not global proofs. A receiving carrier clamps peer values to its own stricter limits. Arithmetic is checked; zero/exhausted drops or defers before enqueue.

### 9.3 Fragmentation

Fragment identity binds at least:

```text
(carrier_profile, transfer_id, object_digest, object_length,
 fragment_index, fragment_count)
```

Rules:

- reserve the whole assembly's bounded capacity before retaining fragment zero;
- exact duplicate is a no-op; conflicting duplicate destroys/quarantines the assembly;
- fragment count/size and aggregate length are checked before allocation;
- no partial endpoint admission;
- final reassembly length and SHA-256 must match before endpoint candidate release;
- fragment-level authentication does not replace endpoint authentication;
- an unauthenticated fragment source gets tighter quotas and no Object Sync.

### 9.4 Padding

Carrier padding is optional and outside the endpoint digest. Profiles freeze size classes, maximum overhead, randomness, removal rules, and abuse accounting. Padding MUST NOT be advertised as anonymity and MUST NOT cause the endpoint object to be rebuilt.

### 9.5 No path-proof claims from public-key-derived MACs

An HMAC key derivable from a public key is forgeable by anyone and cannot authenticate a relay. A sender-private-derived HMAC cannot be verified from the public key unless a separate authenticated verification construction exists. Therefore the current `HopMACChain.swift` scaffold is **non-conformant** and MUST NOT authorize forwarding, reputation, delivery, consensus, route proof, or `hopAuth` capability.

A future path-evidence profile requires a new reviewed signature/MAC key-distribution design and does not modify endpoint delivery semantics.

---

## 10. Router and path scheduler

### 10.1 Default order

The default preference is:

1. direct LAN/Wi-Fi authenticated endpoint link;
2. BLE direct or bounded mesh policy;
3. Internet direct;
4. Circuit Relay connection;
5. DCUtR upgrade over that relay, using new link state where re-authenticated;
6. remain on relay when upgrade fails;
7. offline mailbox when neither live path can deliver.

The router may skip unavailable/disallowed paths and may hedge on multiple paths. It must not change trust or downgrade endpoint security because one path is cheaper or faster.

### 10.2 Route score

Only local observations and authenticated carrier evidence affect route score:

- availability and recent bounded success/failure;
- latency, bandwidth, energy, metered-network, radio, and user policy;
- custody capability and durable queue health;
- privacy exposure class;
- relay/store allow-list and operator policy;
- path-specific quotas/backoff.

Unsigned remote priority, discovery rank, public relay claims, and “online” beacons cannot create authorization. Score affects scheduling only.

### 10.3 Hedging and spray

- Same exact object, same digest, independent attempt identities.
- A per-object global local attempt/byte/radio budget is reserved before fan-out.
- Direct hedging is small and finite.
- BLE replication uses an approved local spray policy; no Byzantine global-copy claim.
- Mailbox replication uses an explicit bounded store set and TTL.
- Retry/custody does not refund cumulative attempted-byte/work budgets.
- A carrier cannot recursively invoke the router and create a loop.

### 10.4 Bridge loop prevention

A terminating bridge keeps a bounded durable seen set keyed by inner `object_digest` plus local ingress/egress policy. A seen entry retains enough exact-byte identity (at least length plus exact bytes or an approved collision witness) to distinguish idempotent replay from same-digest/different-bytes quarantine; a digest-only set may not silently drop the latter. It unwraps one carrier record, preserves exact endpoint bytes, and creates a new wrapper on the other link. It MUST NOT forward a record back to its immediate ingress, copy Object Sync/control state, or treat a remote hop trace as authority.

Loop tokens and prior-hop hints are hop-local, link-scoped, bounded, and non-authoritative. Same identity/different bytes is conflict. Seen-set corruption disables bridging; it does not bypass dedup.

---

## 11. Per-carrier conformance profiles

### 11.1 Summary matrix

| Carrier | Link class | Required authentication/capability | Object Sync | Persistent wrapper | Main metadata exposed |
|---|---|---|---:|---:|---|
| LAN/Wi-Fi | `ENDPOINT_AUTHENTICATED` | Noise XX + Raven device bind + RVCM/RVLN/RVLB/RVLC | Yes after exporter vectors | No, except local outbox | LAN IP, Bonjour presence, timing/size |
| BLE end-to-end stream | `ENDPOINT_AUTHENTICATED` | Approved Noise/device bind over bounded GATT stream | Optional after exporter vectors | Transient reassembly | nearby radio, device timing/size |
| BLE mesh hop | `ADJACENT_HOP_AUTHENTICATED` or bounded unauthenticated hop | Opaque fragment/store policy; endpoint trust remains final | No forwarding of RVOS | Yes, bounded TTL | proximity, repeated transfer/size |
| Internet TCP/QUIC | `ENDPOINT_AUTHENTICATED` | libp2p/TLS/Noise plus exact Raven device bind and capability confirm | Yes after exporter vectors | No, except local outbox | IP/PeerId, timing/size |
| Circuit Relay | `OPAQUE_CIRCUIT` | Endpoints terminate unchanged encrypted session | Inside stream only | Transient flow buffers | relay sees both PeerIds/IPs/timing/size |
| DCUtR direct | new `ENDPOINT_AUTHENTICATED` link | New path/auth/binding unless provider proves same session | Restart on new context | No | relay and peers see coordination/address candidates |
| Offline mailbox | `MAILBOX_CAPABILITY` | Rotating endpoint-supplied store capability | No | Yes, TTL bounded | source PeerId/IP, store-tag reuse, timing/size |
| Terminating bridge | two independent links | Each side independently conforms | Never transplanted | Forward queue allowed | bridge sees both link metadata and exact ciphertext |
| QR/file/cable | `IMPORT_MEDIUM` | File/container authenticity is not contact trust | No | User-controlled | filesystem/provider/device metadata |

### 11.2 LAN/Wi-Fi profile

Requirements:

1. Canonical transport is Network.framework on Apple and a byte-compatible implementation on Terminal.
2. Noise profile is exact and versioned; current lab profile is `Noise_XX_25519_ChaChaPoly_BLAKE2s` with an empty prologue and Raven's signed device-static binding.
3. Before endpoint frames, both RLB1/certificate/prekey and expected device signing key are validated against contact/revocation policy.
4. Bonjour is discovery-only. TXT data is bounded, contains no contact graph or secret, and cannot satisfy trust/capability confirmation.
5. `includePeerToPeer` is an optional Apple path property, not a different trust profile.
6. Raw `u32 || RVN1`, RVNP1, interim MeshContent, or automatic legacy fallback is non-conformant.
7. Listener and dialer enforce connection, per-IP, frame, lifetime, idle, and handshake deadlines before allocation.
8. A successful TCP/QUIC write is `TRANSMITTED`, never Delivered.

### 11.3 BLE profile

Requirements:

1. BLE carries the same exact endpoint bytes as other carriers.
2. V1 `RBF1`/mock BLE is migration-only until a V2 fragment profile binds full `object_digest`, object length, transfer identity, and strict aggregate caps.
3. Legacy JSON MeshEnvelope fallback cannot claim V2.
4. End-to-end Object Sync is permitted only inside one approved authenticated encrypted stream between its two endpoints.
5. Mesh hops must not store/forward RVOS control. Adjacent authenticated peers may open independent rounds.
6. Background behavior follows OS truth; no claim of continuous operation when the platform suspends the app.
7. Radio advertisements expose only bounded discovery hints and rotating capabilities; they are not contacts.
8. Per-neighbor and process-global reassembly/spray budgets are mandatory.

### 11.4 Internet direct profile

Requirements:

1. TCP+Noise+Yamux or QUIC/TLS profile is exact and versioned.
2. libp2p PeerId authenticates the libp2p key, not the Raven identity. A post-handshake Raven device-certificate binding is mandatory.
3. Address/Identify/DHT/AutoNAT records are route hints only and expire under bounded policy.
4. QUIC connection migration validates reachability but never changes contact or endpoint authorization.
5. 0-RTT endpoint-object send is disabled unless a future revision proves replay-safe exact admission; Object Sync never uses early exporters.
6. Per-peer connection, stream, event, dial, address, and byte limits are finite.
7. Reconnection creates a new link binding/exporter even when PeerId is unchanged.

### 11.5 Circuit Relay and DCUtR profile

Requirements:

1. Relay v2 reservation and circuit limits are respected; Raven operates no implicit universal relay.
2. Relay participation is not a trust grant.
3. The relay forwards an opaque end-to-end encrypted stream and cannot demultiplex endpoint or RVOS semantics.
4. Reservation, circuit opening, or relay write proves no endpoint delivery.
5. DCUtR is attempted only over an existing relay connection. Failure leaves the usable relay path intact.
6. A new direct authenticated connection receives new capability/exporter/replay state.
7. Relay addresses, vouchers, PeerIds, and AutoNAT observations are excluded from Raven identity/contact decisions.

### 11.6 Offline mailbox profile

Requirements:

1. PUT/GET records contain only bounded opaque endpoint objects in an approved wrapper.
2. Store tags are rotating endpoint-supplied capabilities, never derived from an unseen per-message route tag.
3. No raw Raven address, username, contact graph, session key, or mailbox key is a public index.
4. `STORED` means custody only after strict record admission and durable store commit.
5. `GET` means bytes were returned, not endpoint admission or delivery.
6. V1 has TTL deletion only. An opaque endpoint ACK cannot authorize early deletion.
7. Stable bounded pagination, store/tag/object/byte/stream/TTL caps, and corrupt-store fail-closed behavior are mandatory.
8. Mailbox never stores RVOS control.
9. Current StoreObjectV1 supports only packed RavenEnvelopeV1 and uses V1 wrapper identity; it cannot claim V2 until a versioned wrapper carries/recomputes the umbrella's exact endpoint-object identity and supports approved public endpoint records.

### 11.7 Terminating bridge/gateway profile

Requirements:

1. Ingress and egress are independent carrier sessions and profiles.
2. Bridge preserves exact endpoint bytes and creates a new hop-local wrapper.
3. No exporter, traffic key, RVOS frame, inventory ID, replay record, or capability confirmation crosses sessions.
4. Endpoint objects may cross only after local wrapper/digest/expiry/loop/quota checks.
5. Bridge sees ciphertext and metadata but no plaintext/session root.
6. A bridge may relay an exact endpoint ACK object but cannot mint or interpret it.
7. A home gateway or bot requiring application semantics is an explicit endpoint/device member under its own companion—not an opaque bridge.

### 11.8 Offline import profile

QR, file, removable media, and cable are carriers, not trust roots. Import:

- rejects symlink/hardlink/special-file/path traversal and oversized/nested containers;
- parses one allow-listed exact record class;
- computes object digest before durable admission;
- applies contact/cert/revocation and endpoint verification afterward;
- records source as untrusted local provenance;
- never auto-adds contacts or activates executable content.

---

## 12. Object Sync integration

Object Sync is available only on a live `ENDPOINT_AUTHENTICATED` or
`OPAQUE_CIRCUIT` context in which the Raven devices terminate the same
end-to-end authenticated stream, with:

1. exact contact/device/revocation admission;
2. completed RVCM/RVLN/RVLB/RVLC transcript;
3. effective bits `AUTHENTICATED_EXPORTER` and `OBJECT_SYNC_V1`;
4. an approved provider vector;
5. Object Sync's own approved profile/caps/abuse store.

Rules:

- RVOS frames are current-session `carrier_control_bytes`.
- They are never endpoint objects, mailbox rows, BLE mesh objects, or bridge-transplanted control.
- Wire inventory uses link-local `inventory_id`, not raw object digest.
- Exact fetch calls the ordinary `send_exact` path after re-checking object availability, contact, revocation, eligibility, and budgets.
- Inventory equality is not delivery.
- A live-store change does not rewrite an immutable accepted snapshot; trust/policy/evidence loss still aborts.
- A path that re-authenticates creates a new RVLX1 and restarts the round.

---

## 13. Metadata and privacy contract

Every carrier profile publishes a machine-readable and human-readable disclosure table covering:

| Observer | Required disclosure examples |
|---|---|
| Local network | IP/MAC-adjacent presence, Bonjour service, packet sizes/timing |
| BLE observer | nearby radio identifiers, advertisement cadence, transfer sizes |
| ISP/NAT | endpoint/relay IPs, timing, volume |
| libp2p peer | PeerId, observed multiaddrs, connection reuse |
| Circuit Relay | both client PeerIds/addresses, circuit counterparties, timing, volume |
| Mailbox | source PeerId/IP, store-tag reuse, object count/size, polling/arrival times |
| Bridge | ingress/egress link metadata and identical ciphertext correlation |
| Recipient | authenticated sender/device, object class after endpoint open |

No profile uses the words anonymous, unlinkable, private, or metadata-hiding without a precise adversary and evidence. Equal exact ciphertext is inherently correlatable by an intermediary that sees it on multiple paths.

### 13.1 Optional privacy partitioning

A future oblivious relay/gateway profile MAY separate source-network metadata from a gateway that handles an encapsulated request, following the partitioning principle of OHTTP. It requires:

- distinct non-colluding operational roles for the claimed property;
- authenticated key configuration;
- explicit leakage and traffic-analysis limits;
- no endpoint trust delegation to relay/gateway;
- a new approved carrier profile and physical measurements.

Ordinary Circuit Relay is not automatically an oblivious service.

---

## 14. Resource and abuse supervision

Each profile supplies finite defaults and hard maxima for:

- discovery records and addresses;
- handshake bytes/work/time;
- manifests/confirms/replays;
- endpoint object and carrier record size;
- fragments, pages, streams, connections, pending dials, and in-flight records;
- retained bytes and assemblies;
- per-peer, per-device, per-store-tag, per-route, and process-global work;
- retry count and cumulative attempted bytes;
- mailbox rows/TTL and bridge queue size;
- BLE spray copies and radio duty;
- abuse score/backoff/tombstones.

### 14.1 Reservation order

```text
parse fixed prefix
  -> classify link/profile
  -> check replay/conflict identity
  -> reserve worst-case bytes/work/slot/deadline
  -> read/retain variable body
  -> verify wrapper/digest/link binding
  -> persist candidate/outcome
  -> release only permitted output
```

No crypto, allocation, disk write, or network output occurs before its corresponding budget reservation. Failed or malicious attempts consume abuse/cumulative budgets; exact idempotent replay reuses its recorded outcome and cannot create amplification.

### 14.2 Stranger and relay quotas

Unknown discovery/relay sources receive smaller ephemeral quotas and cannot cause durable contact/session/inventory state. Durable endpoint objects are retained only under explicit recipient/relay/store policy. Capacity never evicts safety evidence, active penalties, exact retries, or a live object to admit attacker input.

---

## 15. Durability and crash ordering

### 15.1 Outbound

```text
endpoint seals exact object on candidate state
  -> durable endpoint stage/outbox + protected head commit
  -> release endpoint mutation lease
  -> carrier wrapper/attempt reservation under carrier lease
  -> durable carrier queue if profile persists
  -> release carrier lease
  -> network/radio I/O
  -> record transmitted/custody outcome
  -> await verified endpoint ACK
```

No network is held inside the endpoint mutation lease. If stage/outbox commit fails, no carrier output exists. Restart uses exact staged bytes and original binding/timestamps.

### 15.2 Inbound

```text
carrier receives bounded record
  -> wrapper/link/digest/reassembly checks
  -> exact endpoint candidate
  -> host trust/dedup gates
  -> endpoint candidate decrypt/verify
  -> durable receipt/inbox + ACK intent + ratchet commit
  -> clear endpoint journal
  -> release exact ACK work
  -> carrier send outside lease
```

A carrier may durably store opaque bytes before endpoint processing, but that is custody only. Duplicate endpoint object reuses the exact committed ACK if available; it does not decrypt or advance the ratchet twice.

### 15.3 Carrier queue recovery

- Queue records bind inner digest, exact wrapper digest/bytes, profile, route, attempt, expiry, and state.
- Protected endpoint stage remains authoritative for retry bytes.
- Crash before carrier enqueue leaves endpoint outbox pending.
- Crash after durable carrier enqueue reuses that exact job.
- Crash after transmit but before outcome may retry exact bytes.
- Crash after custody commit but before local recording may reconcile authenticated custody evidence; absent evidence means unknown, not delivered.
- Queue corruption fails closed per profile; it cannot rebuild endpoint ciphertext.

---

## 16. Failure and downgrade matrix

| Scenario | Required outcome |
|---|---|
| Supplied digest mismatch | Reject before reservation/mutation |
| Same digest/different endpoint bytes | Durable collision quarantine; no winner |
| Wrapper says one digest, bytes hash to another | Reject; severe peer abuse |
| Endpoint object changed by bridge | Reject at digest/exact-byte gate |
| Unknown endpoint/control/wrapper magic | Reject in expected-class parser |
| Capability bit stripped | Confirm/binding mismatch or required-feature failure; no legacy fallback |
| Manifest role/class/profile/feature overlap or numeric cap outside profile range | Reject before nonce allocation or application traffic |
| Exact RVLN replay | Idempotent for that current link/role |
| RVLN same link/role with different bytes, reflection, zero/reused/equal nonce, or CSPRNG failure | Terminal/refuse link; no deterministic fallback |
| Same confirm identity/different bytes | Terminal link conflict |
| Old RVCM/RVLN/RVLB/RVLC on reconnect | New nonce/context rejects before object/control state |
| Noise/libp2p/TLS link authenticated but Raven device bind wrong | Refuse endpoint link |
| Bonjour/DHT/PeerId says contact | Ignore as trust evidence |
| QUIC path validation succeeds | Reachability only; no contact/delivery change |
| Direct path fails | Try approved next path; exact endpoint bytes unchanged |
| Relay succeeds, DCUtR fails | Continue approved relay path; no downgrade |
| DCUtR creates new authenticated link | New binding/exporter; restart Object Sync; exact object may retry |
| Relay/store lies about custody | At most local route policy changes; no Delivered |
| Mailbox STORED/GET | Custody/transfer only; no Delivered/delete-by-ACK |
| Bridge loops object | Seen-set/hop budget drops; endpoint object retained locally as policy requires |
| BLE fragment conflict | Destroy/quarantine assembly; no partial endpoint candidate |
| Reassembly/cap overflow | Refuse before allocation; debit abuse |
| Object expires while queued | Durable attempt expiry; no endpoint evidence deletion beyond its horizon |
| Contact deleted/block/revoked mid-attempt | Stop new release/retry; bytes already handed off cannot be recalled; inbound endpoint gate refuses |
| Stream write then process death | Retry/reconcile as transmitted-unknown; never Delivered |
| Receipt committed, ACK not materialized | Recover exact ACK intent and send once/idempotently |
| Object Sync frame at mailbox/BLE hop | Reject; do not persist/forward |
| HopMAC public-key placeholder presented | Ignore/refuse as authority; never advertise `hopAuth` |
| Abuse/accounting store corrupt | Disable affected carrier feature; ordinary endpoint state remains protected |
| All paths unavailable | Remain durably queued/deferred until expiry/user policy; no security downgrade |

---

## 17. Shared vectors, simulation, and physical gates

### 17.1 Shared-vector namespaces

```text
shared-vectors/rvn1/carrier_conformance/
  link_binding/
  capability_negotiation/
  exporter_noise_lan/
  exporter_libp2p_noise/
  exporter_tls_quic/
  exact_object_multi_carrier/
  custody_delivery_lattice/
  fragmentation/
  mailbox/
  bridge/
  negatives/
```

Python, Rust, and Swift MUST compute—not merely parse—the same:

- RVCM1/RVLN1/RVLB1/RVLC1 bytes and digests;
- effective capability intersection;
- session nonce and RVLX1 context;
- provider exporter outputs;
- exact object digest across wrappers;
- collision/replay/conflict decisions;
- attempt and custody state transitions;
- expiry and checked-budget outcomes.

### 17.2 Automated matrix

Required before physical testing:

1. exact object travels through every software carrier and exits byte-identical;
2. different wrappers retain one object digest;
3. endpoint object, carrier record, and control parser cross-class negatives;
4. capability strip/unknown/role/reconnect/replay conflicts;
5. no transport/custody path advances Delivered;
6. receipt-before-ACK crash recovery;
7. loss/reorder/duplicate/tamper/fragment conflict;
8. malicious size/count/work/stream amplification;
9. relay opacity and bridge-control transplant negatives;
10. mailbox restart, pagination churn, withholding, duplicate, and no-delete behavior;
11. no RVOS persistence at mailbox/BLE hop;
12. no legacy/raw/server fallback reachable;
13. strict production-hold diagnostics;
14. whole-suite repetition with no known hang/flake class.

### 17.3 Deterministic network simulation

At least 1,000 nodes with explicit seed and virtual monotonic time:

- LAN/BLE/Internet/relay/mailbox availability churn;
- partitions and later contact;
- NAT types, relay scarcity, DCUtR success/failure;
- 0–30% loss, duplication, reorder, and burst delay;
- malicious relays/stores/bridges and capability stripping;
- multi-path duplicate delivery and ACK racing;
- mailbox/bridge capacity exhaustion;
- BLE spray/loop/adversarial advertisements;
- contact deletion/revocation during flight;
- process death at every durable boundary;
- relationship metadata metrics and carrier byte/energy costs.

The simulator must report safety violations separately from liveness/latency. A liveness success cannot hide an exactness, delivery, trust, or quota failure.

### 17.4 Physical matrix

Every activated carrier runs message1 → verified sealed ACK → message2, kill/relaunch, exact-byte retry, duplicate, tamper, expiry, contact delete, block, revocation, and local storage failure:

1. macOS Terminal ↔ Linux Terminal LAN;
2. Terminal ↔ physical iPhone LAN;
3. two physical iPhones on infrastructure Wi-Fi;
4. two physical iPhones on Apple peer-to-peer Wi-Fi;
5. two physical iPhones BLE direct;
6. iPhone A → BLE relay B → iPhone C;
7. Internet direct, then relay + DCUtR upgrade;
8. relay-only when DCUtR fails;
9. offline mailbox with store restart;
10. BLE → gateway → Internet → recipient;
11. Windows Terminal ↔ Unix/iPhone;
12. path change/reconnect and exporter-context rejection.

One-device/simulator tests are useful automated evidence but do not satisfy multi-radio physical rows.

---

## 18. Migration and current implementation audit

No V1 artifact is reinterpreted as V2. Migration is explicit and versioned.

| Current surface | V2 status / required action |
|---|---|
| `raven-core::bridge` mutates RVN1 hop/replication fields | **Non-conformant.** V2 keeps inner endpoint bytes exact and moves budgets to wrapper/local state. |
| `authenticated_object_digest` uses a V1 domain/signing projection | Migration-only. V2 authoritative digest is raw SHA-256 of exact endpoint bytes. |
| `RAVEN_TRANSPORT_INTERFACE_V1` `RIH1` and raw framing | Legacy adapter only; needs device-bound capability/link transcript and exact class demux. |
| `RAVEN_BLE_FRAMING_V1` RBF1 by message ID | Migration-only; needs V2 digest/length/fragment binding and no JSON fallback. |
| `RAVEN_STORE_OBJECT_V1` | Production-disabled V1; needs a versioned V2 wrapper for all allowed endpoint-object classes and umbrella digest semantics. |
| `RAVEN_MAILBOX_TRANSPORT_V1` | Useful bounded experiment; remains production-disabled and cannot carry RVOS. |
| NAT connectivity experiment | Connectivity substrate only; currently has no endpoint payload/conformance binding. |
| `DeliveryJobRunner`, `MessageRouter`, and `MessageStore` call `markDelivered` after bridge/mesh/server success | Must be renamed/retyped as transmitted/custody bookkeeping; protocol Delivered remains verified-ACK-only. |
| `HopMACChain.swift` | Placeholder is non-authoritative and cryptographically non-conformant; capability remains disabled. |
| legacy MeshEnvelope/RVNP1/server fallback | Forbidden in a V2 route attempt. |
| secure LAN lab | Valuable interop evidence; production still waits for Session V2, Object Sync, this companion, crash, and physical gates. |

Migration adapters live behind default-off flags and must label their output as V1. A V2 peer never silently retries the same logical attempt using a V1 profile.

---

## 19. Production holds and approval criteria

### 19.1 Global holds

No carrier Release flag may be enabled until:

1. this document and Object Sync are **APPROVED**;
2. Session V2 and required trust companions are **APPROVED**;
3. exact vectors and provider exporter mappings pass Python/Rust/Swift;
4. endpoint and carrier durability/crash matrices pass;
5. carrier opacity and no-transport-delivery tests pass;
6. no legacy downgrade is reachable;
7. independent security review or a named/date/scope/risk owner waiver is recorded;
8. the carrier's physical rows pass;
9. privacy disclosure and abuse limits are shipped with the feature;
10. production builds fail closed when any required profile/provider is absent.

### 19.2 Per-profile holds

| Profile | Additional blockers |
|---|---|
| LAN/Wi-Fi | Noise exporter vector, device bind, listener/dialer crash recovery, physical rows 1–4 |
| BLE | V2 fragment profile, background lifecycle truth, spray simulation, physical rows 5–6 |
| Internet direct | Raven device bind over libp2p/TLS, exporter, NAT/QUIC lifecycle, physical row 7 |
| Circuit Relay/DCUtR | explicit relay policy, opaque-stream proof, new-context behavior, rows 7–8 |
| Mailbox | V2 store wrapper, TTL/no-delete, persistence/capacity, physical row 9 |
| Bridge | independent-link/control isolation, loop/queue crash safety, physical row 10 |
| Windows | Credential/durable foundation + native MSVC process/race evidence, row 11 |

### 19.3 Approval exit

This document may change to **APPROVED** only after all normative layouts/state rules receive independent review, shared vectors freeze, provider mappings pass, and the protocol owner records explicit approval. Approval alone still does not enable a carrier; per-profile physical activation remains separate.

---

## 20. Research basis (non-normative)

Raven borrows principles, not wire compatibility:

| Source | Principle used | Explicit limit |
|---|---|---|
| [RFC 9171 — Bundle Protocol v7](https://www.rfc-editor.org/rfc/rfc9171.html) | disruption-tolerant store/carry/forward, lifetime, hop count, distinct receipt/forward/delivery status | Raven does not adopt BPv7 wire or let hop status mean endpoint ACK |
| [RFC 9172 — BPSec](https://www.rfc-editor.org/rfc/rfc9172.html) | canonical security targets, integrity/confidentiality roles, fail-closed authenticated ciphertext | Carriers do not terminate Raven endpoint security |
| [Noise Protocol Framework](https://noiseprotocol.org/noise.html) | transcript-bound authenticated channels and separate handshake/transport state | Noise link authentication still requires Raven device/contact binding |
| [TLS 1.3, RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html) | transcript-bound negotiation and post-handshake exporter class | No early exporter/traffic-key substitute |
| [QUIC, RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html) | path validation and migration under a secure transport | Reachability is not identity, contact, or delivery |
| [libp2p Circuit Relay v2](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md) | bounded reservation/circuit resources and opaque switched connectivity | Relay vouchers/PeerIds do not authorize Raven endpoint semantics |
| [libp2p DCUtR](https://github.com/libp2p/specs/blob/master/relay/DCUtR.md) | direct upgrade coordinated over an existing relay connection | New authenticated connection means new Raven link context |
| [RFC 9458 — Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458.html) | privacy by separating source-facing relay and content-facing gateway | Ordinary Raven relay is not automatically oblivious/anonymizing |
| [RFC 9614 — Privacy Partitioning](https://www.rfc-editor.org/rfc/rfc9614.html) | explicit non-colluding role partition and leakage analysis | Optional future profile only |
| [Apple TN3151](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) | Network.framework data path and opt-in peer-to-peer Wi-Fi | Bonjour/peer-to-peer discovery is not trust |

---

## 21. Open items before vector freeze

1. Independently review RVCM1/RVLN1/RVLB1/RVLC1 offsets, lengths, roles, feature intersection, replay identity, and transcript construction.
2. Freeze the Noise exporter extension with a provider/API audit and byte vectors; absence keeps Object Sync disabled.
3. Decide and freeze a V2 carrier wrapper/fragment family for BLE, mailbox, and bridge without changing endpoint bytes.
4. Reconcile V1 expiry fields with authoritative Session V2/public-record validity evidence.
5. Freeze custody receipt bytes or remove custody-receipt capability from V1.
6. Specify the durable digest-collision quarantine record and repair authority.
7. Freeze per-carrier numeric defaults/hard maxima and machine-readable privacy manifests.
8. Align Object Sync Rev13 provider contexts with this document; any contradiction requires revision before vectors.
9. Audit every current `markDelivered`/`markForwarded`/custody callsite and storage schema.
10. Remove or permanently gate public-key-derived HopMAC authority claims.
11. Build vectors, 1,000-node simulation, fault injection, and physical operator gates.
12. Independent security review and protocol-owner approval.

---

## 22. Document history

| Revision | Date | Summary |
|---:|---|---|
| 2 | 2026-08-21 | Independent red-team amendments: numeric link classes; authenticated opaque-circuit/Object Sync consistency; unauthenticated-hop class; manifest scope; mandatory/optional/unknown-bit rules; explicit RVLN1 nonce exchange; strict RVCM/RVLN/RVLB/RVLC role/profile/nonce validation; collision-safe bridge seen state. |
| 3 | 2026-08-21 | Registered the production-disabled realtime-media boundary: immutable call-control objects may use carriers, while ICE/STUN/TURN/DTLS/SRTP/RTP/RTCP/SFrame packets remain ephemeral and cannot inherit endpoint-object, custody, delivery or trust semantics. |
| 4 | 2026-08-21 | Registered the sovereign-interoperability boundary: ActivityPub/Matrix/Nostr/MIMI translators are explicit semantic endpoint/gateway roles that may see plaintext and create new attributed objects; they cannot claim opaque-carrier status or rewrite/transplant carrier control. |
| 1 | 2026-08-21 | Initial unified conformance draft: exact object identity; link classes; logical API; capability anti-downgrade; RVCM1/RVLB1/RVLC1; exporter-provider boundary; custody/delivery separation; path scheduler; LAN/BLE/Internet/Relay/DCUtR/Mailbox/Bridge/Import profiles; metadata/resource/crash/failure/physical matrices; explicit V1 migration holds. |
