# RAVEN Private Rendezvous V1

**Version:** 1 (architecture/privacy draft; wire not frozen)

**Document revision:** 3

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no rendezvous service,
presence beacon, DHT record, OHTTP deployment, public inbox, contact mutation,
route publication, realtime provider/path discovery, carrier dial, codec,
database migration, live callsite, or Release flag

**Approval prerequisites:**
[`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md)
must be revised and re-approved to register the private rendezvous record
families; [`RAVEN_ID_RESOLUTION_V1.md`](RAVEN_ID_RESOLUTION_V1.md),
[`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md),
[`ATSAM_HYBRID_RATCHET_V2.md`](ATSAM_HYBRID_RATCHET_V2.md), and Carrier
Conformance for every enabled path must be **APPROVED**.

**Non-interference:** this draft does not amend Full Braid, protected-anchor,
SQLCipher, current LAN, mailbox, NAT, bridge, or Object Sync work. It does not
authorize first contact from a bare Raven ID, background iPhone availability,
or any current production path.

---

## 0. Core decision and precedence

The key words MUST, MUST NOT, SHOULD, and MAY are interpreted as in BCP 14 when
capitalized.

Raven separates five questions that ordinary messaging products often collapse:

| Question | Sole owner |
|---|---|
| Who is this identity/device? | ID Resolution + certificates + revocation |
| Has the user accepted this messaging relationship? | Local contact store |
| Where might an already accepted device be reachable now? | **Private Rendezvous** |
| Is the peer/session cryptographically authentic? | Noise device bind + PairInit/Triple Ratchet |
| How are opaque bytes moved? | LAN/BLE/Internet/relay/mailbox carriers |

The product rule is:

> A rendezvous answer is an untrusted, short-lived path candidate. It is never
> identity, contact consent, presence truth, session authentication, delivery,
> or permission to notify.

No DHT, DNS, Bonjour/mDNS name, PeerId, relay reservation, AutoNAT observation,
mailbox store tag, source count, arrival order, or directory response can
replace contact/certificate/revocation admission. A companion cannot weaken
this separation.

### 0.1 Known-peer rendezvous is not stranger discovery

[`RAVEN_PRIVATE_DISCOVERY_V1.md`](RAVEN_PRIVATE_DISCOVERY_V1.md) discovers
unknown **public content candidates**. Private Rendezvous finds possible paths
for an exact accepted identity/device or an explicit one-time out-of-band
invite. Contact upload, “people you may know”, public buddy lookup, and global
online status belong to neither protocol and are forbidden.

### 0.2 Honest first-contact boundary

V1 supports only:

1. a mutually accepted contact whose exact current device certificates are
   already available; or
2. an explicit one-time rendezvous invite transferred by QR, NFC, file,
   another user-selected authenticated channel, or a fully verified Private
   Introduction acceptance after the receiver's contact commit.

A bare Raven ID can resolve a candidate and prekeys, but cannot magically give
both parties a private shared rendezvous capability. The separate,
production-disabled
[`RAVEN_PRIVATE_INTRODUCTION_V1.md`](RAVEN_PRIVATE_INTRODUCTION_V1.md)
defines an honestly weaker sealed-proposal path: it may produce two explicit
local contact commits, but never a route/session by itself. Strong
metadata-private ID-only initiation still requires an Alpenhorn-like/anytrust
construction. Raven MUST show “request pending” or “contact not mutually
reachable yet”, not silently publish a stable public inbox or downgrade to
ordinary libp2p rendezvous.

---

## 1. Goals, non-goals, and adversaries

### 1.1 Goals

| ID | Goal |
|---|---|
| PR1 | Let accepted contacts find current direct, relay, and mailbox paths without publishing Raven ID, contact graph, or stable device address |
| PR2 | Use pair-specific, provider-specific, rotating lookup capabilities |
| PR3 | Keep route discovery separate from peer/session authentication |
| PR4 | Support Terminal, iPhone foreground LAN, Internet relay, and offline mailbox with one authority model |
| PR5 | Preserve exact failure/privacy-mode choice across crash and retry |
| PR6 | Make unavoidable timing, IP, provider-collusion, device-compromise, and mobile-lifecycle leakage explicit |

### 1.2 Non-goals

- Public user search, content discovery, recommendations, follower discovery,
  or contact matching.
- Uploading raw, hashed, encrypted, Bloom-filtered, or PSI-encoded address books
  without a separately approved protocol and threat model.
- A universal “online” bit, last-seen timestamp, typing state, activity status,
  or global presence API.
- Authenticating a user, device, relay, route, or message from reachability.
- Hiding timing/volume from a global passive adversary.
- Claiming iOS can listen continuously in the background.
- Designing a new PIR, anonymous-credential, mixnet, onion-routing, or anytrust
  cryptosystem inside this companion.
- Treating libp2p Rendezvous `/rendezvous/1.0.0` as private presence.

### 1.3 Adversaries

The design considers malicious rendezvous providers, relays, mailbox stores,
DHT peers, LAN observers, contacts, Sybil clients, and carriers; colluding
OHTTP relay/gateway roles; stale or rolled-back app state; compromised old
device keys; selective omission/equivocation; token probing; route flooding;
and timing/intersection analysis across epochs and providers.

### 1.4 Honest limits

- A provider sees opaque lookup/write tokens, request timing, sizes, and its
  client network endpoint unless an approved OHTTP/onion path is used.
- OHTTP partitions network identity from request plaintext only under explicit
  relay/gateway non-collusion and padding assumptions.
- A contact that knows the pairwise secret can test that pair's rendezvous lane
  and may cause denial; signatures and generation checks prevent authority
  forgery, not withholding.
- Static-device bootstrap has no forward secrecy against later compromise of
  either device X25519 private key. It is metadata bootstrap only; established
  sessions replace it with the session route lane.
- Repeated publication/query timing, uncommon provider sets, IP addresses,
  direct dials, and relay circuits may still link endpoints.
- Offline longer than the mailbox/rendezvous TTL loses availability, not
  cryptographic integrity.

---

## 2. Admission and authority

Every rendezvous operation begins with a local immutable `RendezvousAdmission`
snapshot containing:

```text
local_identity_address
local_device_certificate_bytes + digest
local_device_x25519_private_reference
remote_identity_address
remote_device_certificate_bytes + digest
contact_commit_digest
device_set_generation
revocation_union_head_digest
block_generation
selected_privacy_mode
selected_provider_set_digest
now_ms
```

The host, before any lookup, publication, beacon, or dial, MUST:

1. load an exact durable local contact;
2. verify both identities and device certificates, including current validity;
3. apply sticky local block plus the union of accepted RVDR1 claims;
4. reject missing/revoked/reused device lineage;
5. bind the operation to the exact contact and DeviceSet generations;
6. reserve bounded work/storage before public-key, AEAD, OHTTP, network, or
   route parsing; and
7. freeze the privacy mode. Failure MUST NOT retry in a more revealing mode.

Sessions do not substitute for contacts. Deleting or blocking a contact closes
publication, lookup, dial, PairInit, message, ACK, and notification admission
even if cached route/session material remains.

---

## 3. Three separate capability lanes

No raw capability appears in logs, analytics, crash reports, labels, URLs, QR
previews, or carrier metadata.

### 3.1 Mutual-contact bootstrap lane

For two accepted, non-revoked device certificates with X25519 keys:

```text
Z_contact = X25519(local_device_x_private, remote_device_x_public)
```

All-zero/non-contributory output rejects. A later vector freeze defines an
HKDF-SHA256 extraction binding:

- both full canonical identity addresses;
- both exact device-certificate digests in role-canonical order;
- protocol/version;
- provider identifier;
- epoch; and
- direction/publisher device.

This produces distinct keys for lookup tag, write authorization, route-record
AEAD, LAN beacon, and local persistence. No output is a message/session/root
key. Device rotation creates a new lane; the old lane remains only for a
bounded authenticated overlap and is never chosen after revocation.

### 3.2 Established-session lane

After a verified PairInit/PairResponse, a distinct `K_rendezvous[d]` is derived
from `K_route_master` with a new frozen domain. It MUST NOT reuse route,
mailbox, ACK, message, or object-sync keys. The session lane has forward
evolution/closure semantics defined by Hybrid Ratchet V2 and supersedes the
bootstrap lane for that exact device pair.

Daily mailbox tags in Hybrid Ratchet V2 remain the authoritative offline
message polling lane. Private Rendezvous may advertise mailbox **policy and
provider candidates**, but never publishes raw `K_route_master`,
`mailbox_tag`, `store_tag`, or per-message `routing_tag` inside a route record.
Each endpoint derives its own store tags locally.

### 3.3 One-time invite lane

`RavenRendezvousInviteV1` contains a random 32-byte capability,
exact inviter identity/device/certificate binding, provider set, expiry,
single-use identifier, and inviter signature. It is separate from
`RavenContactCredentialV1`, which intentionally contains no stable network
address or mailbox tag.

The invite is transferred either out of band or inside the exact encrypted
`RavenIntroductionAcceptanceV1` that expresses the inviter's contact commit.
In the latter case it additionally binds the original proposal and acceptance
digests and remains unusable until the accepting sender performs its own local
contact commit.

The invite:

- is not a contact and cannot authorize messaging by itself;
- is consumed only after explicit user review/acceptance;
- never yields a reusable public inbox;
- has a short checked expiry and one-use durable claim;
- cannot be imported by an extension/preview without main-app confirmation;
- is invalid after inviter device revoke/block; and
- cannot be upgraded into the mutual/session lane without a complete contact
  commit and normal PairInit trust gates.

---

## 4. Private route descriptor

The exact wire remains open until vector freeze. The semantic
`RavenPrivateRouteDescriptorV1` contains:

```text
version
publisher_identity_address
publisher_device_cert_digest
intended_peer_identity_address
intended_peer_device_cert_digest
lane_kind                    # bootstrap | session | invite
provider_domain
epoch_u64
generation_u64
issued_at_ms
expires_at_ms
route_candidates[]           # bounded typed candidates
mailbox_policy_digest?
carrier_capability_bits
anti_replay_nonce
previous_descriptor_digest?
signature_by_publisher_device
```

The canonical signed bytes are then sealed with the lane's route-record AEAD.
The store sees only a fixed-version opaque blob under a rotating lookup tag.

### 4.1 Route candidate types

| Type | Meaning | Authority |
|---|---|---|
| `ExistingConnection` | already device-authenticated live connection handle | local process only; never serialized |
| `Direct` | bounded TCP/QUIC multiaddr + expiry | untrusted dial hint |
| `RelayCircuit` | canonical relay peer/address + reservation expiry | untrusted dial hint |
| `LocalForeground` | explicit LAN listener/service parameters | untrusted dial hint |
| `MailboxProvider` | operator/provider identity and policy digest | store candidate only; tags derived locally |
| `OnionService` | optional exact onion endpoint under separately approved carrier | untrusted dial hint |
| `RealtimeProvider` | reserved semantic STUN/TURN/SFU provider/path descriptor | forbidden until Private Realtime Media and its exact provider profile are APPROVED |

Every address is parsed with scheme-specific caps before allocation. DNS names,
IP literals, multiaddrs, onion endpoints, and relay paths use separate SSRF and
private-network policy. A route candidate never carries a plaintext Raven ID,
contact name, conversation ID, or message ID.

### 4.2 Descriptor admission

After AEAD open, the endpoint MUST verify exact intended pair/device bindings,
publisher device signature, certificate and revocation state, epoch, checked
time window, provider domain, monotonic generation, previous digest, candidate
count/bytes, and no trailing/unknown mandatory fields. Equal generation with
different bytes is authenticated equivocation. A lower generation is stale,
not a rollback instruction. No candidate is dialed before full verification.

Provider order, candidate order, RTT, success count, and source repetition do
not grant authenticity. They feed only a local bounded path scheduler after
admission.

A future `RealtimeProvider` descriptor is never an ICE candidate, call Answer,
contact, ringing permission, media key or proof that a peer is online. Under
[`RAVEN_PRIVATE_REALTIME_MEDIA_V1.md`](RAVEN_PRIVATE_REALTIME_MEDIA_V1.md), it
may become an untrusted short-lived input only after exact call acceptance and
privacy-mode commitment. Generic rendezvous lookup MUST NOT release host or
server-reflexive ICE candidates, TURN credentials, SFU admission tokens, or
direct peer addresses before that boundary.

---

## 5. Privacy modes

The user/device selects one mode per operation. There is **no automatic
cross-mode fallback**: a failed OHTTP operation does not become direct, a
failed pairwise lookup does not become public rendezvous, and a failed local
scan does not publish to a directory. A separately committed user policy may
schedule another mode as a new intent after showing its disclosure. Path
fallback among already admitted candidates inside one mode is distinct.

### 5.1 `R0_EXISTING_OR_CACHED`

Use an already device-authenticated connection or an unexpired locally cached
descriptor. No network directory query occurs. Cache use still repeats
contact/cert/revocation checks and Noise/device binding on a new connection.

### 5.2 `R1_OOB_INVITE`

Resolve a one-time user-imported invite. The import UI shows inviter identity,
device fingerprint, expiry, provider disclosure, and whether the next action
will contact a network service. No background fetch occurs while merely
previewing a QR/file/NFC payload.

### 5.3 `R2_LOCAL_PAIRWISE_FOREGROUND`

When the user opens a specific accepted contact/chat, the app may advertise or
scan a fixed-size rotating beacon derived for that exact device pair. The
beacon contains no Raven ID, PeerId, certificate, service name, stable address,
contact count, or generic “Raven user nearby” marker.

- Pairwise beacons are foreground and short-lived by default.
- Advertising all contacts simultaneously is forbidden in V1.
- Bonjour/mDNS may transport an opaque service instance only after a reviewed
  fixed-size profile proves that service/type/TXT/name fields are unlinkable;
  raw current Raven LAN advertisements are not silently reused.
- A beacon match only permits a bounded Noise dial; Noise static/device cert
  binding and contact/revocation gates still decide acceptance.

### 5.4 `R3_PAIRWISE_DIRECTORY`

For each provider, epoch, direction, and device pair, derive independent:

```text
lookup_tag
write_authorization
record_aead_key
```

The publisher uploads one bounded opaque descriptor. The contact queries only
the tags it can derive. The provider:

- indexes opaque tags only;
- cannot list “all contacts for user X” because no Raven ID is supplied;
- cannot authenticate or mutate contacts/sessions;
- may withhold, replay, correlate, rate-limit, or equivocate;
- enforces fixed TTL, row, byte, request, and per-capability limits;
- returns every bounded collision for endpoint verification rather than
  selecting a winner; and
- never returns an unbounded namespace listing.

Ordinary libp2p Rendezvous is not this mode: it registers signed PeerIds and
addresses in queryable namespaces and even permits namespace-wide discovery.

Directory publication and lookup are **application protocols above an opaque
carrier**, not `carrier_control_bytes`. OHTTP MAY hide either client's network
address from the gateway under an exact RFC 9458 profile. Direct mode is
source-visible. Failure never silently switches OHTTP to direct.

### 5.5 `R4_SESSION_MAILBOX`

For an established session, the sender can PUT exact immutable endpoint objects
under receiver-predictable daily mailbox tags and the receiver can poll the
full TTL horizon as required by Hybrid Ratchet V2. This provides asynchronous
delivery, not general presence.

Mailbox stores do not learn route keys or plaintext, but observe source
PeerIds/network addresses, timing, sizes, and tag reuse. Store success is
custody evidence only; sealed endpoint ACK after durable receive commit is the
delivery transition. No mailbox response means “offline” or “not a contact”.

### 5.6 `R5_FUTURE_PRIVATE_PRESENCE`

A DP5/Alpenhorn-style profile may later permit batch private presence or
strong-metadata-privacy initiation. The weaker sealed-proposal modes defined
by Private Introduction do not claim this property. R5 requires a separate approved construction
pinning servers/anytrust roles, key evolution, forward-secrecy claim, cover
traffic, epochs, database snapshots, malicious-server behavior, availability,
mobile bandwidth, and recovery. Ordinary hashed lookup, PSI marketing claims,
Bloom filters, OHTTP alone, or encrypted contact upload do not qualify.

---

## 6. Publish, lookup, and dial state machines

### 6.1 Publication

```text
IDLE
  -> ADMISSION_SNAPSHOT
  -> CAPACITY_RESERVED
  -> CANDIDATE_DESCRIPTOR_BUILT
  -> SIGNED_AND_SEALED
  -> PUBLISH_INTENT_DURABLE
  -> PROVIDER_WRITE
  -> EXACT_READBACK_VERIFIED
  -> PUBLICATION_COMMITTED
```

Network I/O occurs outside the protected mutation lease. Exact bytes and
provider/epoch/generation are staged before send. Retry uses the same bytes;
it never generates a new generation merely because a response was lost.
Provider acceptance cannot advance contact/session state.

### 6.2 Lookup

```text
IDLE
  -> ADMISSION_SNAPSHOT
  -> PRIVACY_MODE_FROZEN
  -> CAPACITY_RESERVED
  -> LOOKUP_INTENT_DURABLE
  -> QUERY_CURRENT_AND_BOUNDED_OVERLAP_EPOCHS
  -> VERIFY_ALL_BOUNDED_CANDIDATES
  -> CACHE_EXACT_DESCRIPTOR
  -> LOOKUP_COMMITTED
```

Partial pages, provider failure, malformed rows, or crash do not advance an
epoch cursor. A successful empty response is `NoCandidateObserved`, not
offline, blocked, unregistered, or absent. Multi-provider union is availability
only; source count is not quorum.

### 6.3 Dial and path order

After descriptor admission, the local scheduler follows the umbrella order:

1. existing authenticated connection;
2. explicit foreground local/direct candidate;
3. Internet direct candidate;
4. Circuit Relay connection;
5. DCUtR upgrade attempt;
6. remain on authenticated relay if upgrade fails;
7. asynchronous mailbox.

Each dial has finite address, parallelism, time, byte, and retry budgets.
Direct/relay success is not peer authenticity: Noise/device bind, contact,
certificate, revocation, then PairInit/session envelope verification remain
mandatory. A failed path may select another admitted path; it cannot weaken
cryptography or privacy mode.

---

## 7. Multi-device, rotation, revoke, and deletion

1. Rendezvous state is per exact local-device/remote-device pair, not merely
   per user identity.
2. DeviceSet growth is bounded before creating lanes. A sender does not form a
   Cartesian product beyond the frozen device-pair cap.
3. A new device/certificate requires a new bootstrap lane and PairInit.
4. Certificate expiry, RVDR1, local block, or contact deletion immediately
   prevents new publish/query/dial and quarantines cached descriptors.
5. Servers may retain opaque expired records until TTL; Raven does not claim
   remote secure deletion.
6. Old-lane overlap is allowed only after authenticated DeviceSet continuity
   evidence and never for a revoked lineage.
7. Session close destroys session rendezvous keys after durable close state;
   bootstrap keys remain only while the mutual contact and device certs remain
   valid.
8. “Unblock” never clears revocation. Re-adding a contact starts from current
   certificates and new generations, not old cached routes.

---

## 8. Presence and attention contract

Private Rendezvous never emits a universal presence object. Local UI may show:

| Label | Evidence |
|---|---|
| **Connected now** | current device-authenticated live connection |
| **Route available until …** | admitted unexpired descriptor; not proof peer is online |
| **Mailbox configured** | local session/provider policy; not proof of recent activity |
| **No route observed** | bounded lookup returned none/failed; no statement about peer |

Last-seen, activity, typing, read receipts, and notifications require separate
endpoint objects and user policy. Directory timing never creates notification
permission or an Attention lane. “Why connected?” is answered from committed
local evidence without a network refresh.

Call offers, ringing, ICE release and microphone/camera capture are additionally
governed by Private Realtime Media. Route availability never authorizes a ring;
ring/Accept never upgrades provider data to identity; and direct ICE gathering
or candidate release before committed call acceptance is forbidden.

---

## 9. Resource and abuse model

Exact numbers freeze with vectors, but the architecture requires finite caps
for:

- local and remote devices per identity and device pairs per contact;
- providers per pair and overlap epochs queried per wake;
- descriptor candidates/bytes, directory rows/pages, beacon bytes, and cached
  generations;
- concurrent publishes, queries, dials, relay reservations, mailbox polls, and
  cryptographic verifications;
- retry attempts, deadlines, TTL, clock skew, future timestamps, and offline
  catch-up work;
- unknown invite attempts in a separate weaker lane; and
- total protected state, conflict evidence, quarantines, and audit events.

Capacity is reserved before expensive work. Unknown invites cannot evict
contacts, sessions, revocations, pending endpoint commits, or accepted route
state. Provider exhaustion is a path failure; Raven does not evict another
contact or reveal another tag to make room.

Rate limiting never becomes a universal identity credential. Privacy Pass or
anonymous tokens, if used, need a separate exact issuance/redemption privacy
profile; raw Raven identity is forbidden as a directory quota key.

---

## 10. Protected state and crash ordering

Protected/durable state includes:

```text
pair/device admission generation and cert digests
bootstrap/session/invite key references
privacy mode + provider-set digest
publish/lookup intents and exact request/record digests
descriptor generation + previous digest
epoch/page cursors and overlap horizon
accepted descriptors and equivocation evidence
invite one-use claims
blocked/revoked/closed tombstones
retry/release work
```

Keys live only in platform-protected storage; SQLCipher stores bounded metadata
and sealed bytes. No plaintext/UserDefaults/file fallback is allowed.

Every mutation uses a two-phase protected journal plus SQL transaction with
roll-forward recovery. The generic ordering is:

```text
reserve/admission snapshot
  -> protected pending intent
  -> SQL rows/staged exact bytes
  -> protected finalized head
  -> clear pending
  -> release network/UI work
```

Rollback or crash MUST NOT reuse an invite, generation, nonce, write token, or
route-record key. Recovery repeats the exact privacy mode and exact staged
bytes. It cannot turn an OHTTP request into direct, a mailbox poll into public
rendezvous, or a contact lookup into stranger discovery.

---

## 11. Failure and downgrade matrix

| Condition | Required result |
|---|---|
| Missing local contact | refuse before key derivation/network |
| Contact exists only on caller, not publisher | no candidate observed; no public fallback |
| Block/revoke/cert expiry before or during operation | cancel/quarantine; no dial or release |
| X25519 all-zero/non-contributory | reject lane |
| Same generation, different descriptor | preserve bounded evidence; fail closed |
| Provider replay/lower generation | stale/no mutation |
| Provider omission/empty | unknown availability, never “offline” |
| OHTTP failure | retain exact intent; no direct fallback |
| Descriptor AEAD/signature/binding failure | discard candidate; no dial |
| Relay/direct candidate lies | path failure; no authentication downgrade |
| Mailbox accepts PUT then disappears | custody uncertain/retry exact bytes; no Delivered |
| DeviceSet rotation | new lane only after verified update; bounded old overlap |
| Contact delete/block while pending | durable cancel/quarantine before output |
| Capacity exhaustion | refuse before crypto/network; no trusted-state eviction |
| Crash at any phase | old or new complete state, or retained roll-forward intent |
| Unsupported privacy mode/version | explicit refusal; no automatic weaker mode |

---

## 12. UX contract

### 12.1 Terminal

Target UX after approval:

```text
ash contact add --credential <file-or-stdin>
ash rendezvous status <accepted-contact>
ash rendezvous find <accepted-contact> --privacy local|ohttp|direct|mailbox
ash send <accepted-contact> <message>
```

`ash send @bare-alias ...` remains forbidden. The status command reports local
evidence and leakage, never a fabricated online bit. Direct mode requires an
explicit source-visible warning. Secrets/tags/addresses do not appear in normal
logs or shell history.

### 12.2 Apple

- Opening a chat may perform foreground pairwise LAN discovery only after the
  user has enabled it for that contact.
- Background modes must match real iOS lifecycle capabilities; no always-on
  listener or continuous polling claim is permitted.
- The UI distinguishes “connected”, “route cached”, “mailbox available”, and
  “no route observed”.
- Pasting/scanning an invite displays identity/fingerprint, expiry, provider,
  and network action before acceptance.
- Contact/block/revoke controls take effect before the next lookup/dial and
  surface persistence errors instead of showing false success.

---

## 13. Required vectors, simulations, and physical gates

### 13.1 Three-language vectors

Python, Rust, and Swift MUST independently compute:

- role-canonical static X25519 bootstrap and all-zero rejection;
- certificate/address/provider/epoch-bound HKDF lanes;
- distinct lookup/write/AEAD/beacon/session/mailbox domains;
- descriptor signing, sealing, exact open, generation/previous-digest rules;
- invite creation, one-use claim, expiry, replay and revoke;
- provider-domain separation and current/overlap epochs;
- exact no-silent-fallback state transitions;
- crash journals, exact-byte retry and cursor advancement; and
- malformed/capacity/equivocation/revocation negatives.

Existing route/mailbox vectors are not reinterpreted as private rendezvous.

### 13.2 Deterministic 1,000-node simulation

The simulator covers mixed Terminal/iPhone devices, NAT types, provider
partitions, relay failure, mailbox delay, device rotation, revoke/block,
contacts with asymmetric acceptance, malicious directories, Sybil rows,
clock skew, long offline periods, crashes, and bounded resources. It reports:

- unauthorized contact/session/dial/notification mutations (must be zero);
- privacy-mode downgrades (must be zero);
- stable-ID/contact-graph disclosure in rendezvous bytes/logs (must be zero);
- delivery/route success by mode without relabeling omission as offline;
- token/provider/epoch linkability assumptions;
- queue/CPU/memory/battery/catch-up maxima; and
- exact retry/duplicate/equivocation outcomes.

Simulation is not physical carrier evidence.

### 13.3 Physical matrix

Every claimed mode/path requires rows for:

- Terminal↔Terminal on macOS, GNU/Linux, and Windows;
- Terminal↔iPhone both directions;
- iPhone↔iPhone foreground LAN and Internet/relay/mailbox;
- same LAN, different NATs, CGNAT, relay-only, offline recipient, provider
  outage, airplane mode, app kill/relaunch, lock/unlock, device reboot;
- direct→relay→DCUtR→remain-relay→mailbox order;
- contact deletion, block, RVDR1, certificate expiry and device rotation;
- OHTTP/direct leakage labels and no-silent-fallback packet capture;
- duplicate/loss/tamper/equivocation and exact retry; and
- proof that no legacy raw/RVNP1/public rendezvous fallback occurs.

One iPhone can validate durability/lifecycle rows; two independent physical
devices are required before claiming iPhone↔iPhone radio/network
interoperability.

---

## 14. Production holds

This companion cannot be APPROVED, and no rendezvous/presence UX can be enabled,
until:

1. the approved umbrella is revised/re-approved for every new endpoint record;
2. exact wires, KDF domains, caps, errors, time rules and three-language vectors
   are frozen;
3. ID Resolution, Device Revocation, Session V2, protected persistence and
   endpoint transactions are APPROVED and integrated;
4. static bootstrap is independently reviewed and never used for message keys;
5. mutual-contact and one-time-invite state machines have complete trust,
   replay, crash, revoke, and capacity matrices;
6. every directory provider has an authenticated deployment/profile, finite
   abuse policy, equivocation behavior, privacy statement and retention rule;
7. every OHTTP mode pins RFC 9458 suite/key/config discovery, independent roles,
   padding/replay/fallback and collusion assumptions;
8. ordinary libp2p Rendezvous, DHT peer records, Bonjour names, PeerIds, stable
   addresses and public presence are absent from private-mode bytes;
9. LAN beacon and directory packet captures prove no Raven/contact/device IDs;
10. NAT/relay/mailbox Carrier Conformance and application ACK semantics pass;
11. Apple/Linux/Windows protected crash/rollback/corruption tests pass;
12. 1,000-node safety/privacy/resource simulation passes;
13. every claimed physical row passes, including two-device iPhone rows;
14. independent cryptography, privacy, systems and abuse reviews have no open
    P0/P1, with protocol-owner approval;
15. no production flag, background service, directory endpoint, telemetry,
    contact upload or fallback path activates from a lab/test build; and
16. UI terminology is limited to evidence actually observed.

Passing a localhost dial, resolving a Raven ID, receiving a rendezvous row, or
connecting through one relay is not approval.

---

## 15. Open decisions before vector freeze

1. Exact semantic/wire split among invite, route descriptor, directory request,
   provider receipt and local state.
2. Static bootstrap KDF salts/domains, canonical role order, direction, epoch
   length and overlap.
3. Directory write-conflict model, provider authentication, pagination,
   receipts, padding buckets, quotas and multi-provider schedule.
4. Fixed-size foreground LAN beacon transport and whether Bonjour can meet the
   no-stable-name/TXT requirement on every Apple platform.
5. Route candidate schema and SSRF/private-network/onion policy.
6. Device-pair cap and DeviceSet rotation overlap.
7. Invite UX/claim/expiry and exact handoff from an APPROVED Private
   Introduction acceptance into mutual-contact rendezvous.
8. OHTTP key consistency, relay/gateway selection and explicit fallback UX.
9. Whether a reviewed DP5/Alpenhorn successor is deployable on mobile without
   unacceptable bandwidth/latency/central-role assumptions.
10. Provider discovery without turning provider lists into a central Raven
    service or leaking a rare per-user provider fingerprint.

---

## 16. Research foundations (informative only)

Raven claims no wire compatibility with these systems:

- [DP5: A Private Presence Service](https://discovery.ucl.ac.uk/id/eprint/1469539/)
  — shows that buddy-list queries and high-integrity rendezvous status need a
  dedicated privacy protocol; its infrastructure and cryptography are not
  silently imported.
- [Alpenhorn](https://www.usenix.org/conference/osdi16/technical-sessions/presentation/lazar)
  — demonstrates metadata-private contact initiation with anytrust servers and
  evolving pairwise secrets; Raven does not claim equivalent privacy without a
  pinned construction and deployment.
- [libp2p Rendezvous specification](https://github.com/libp2p/specs/blob/master/rendezvous/README.md)
  — useful generalized peer discovery, but namespace registration/discovery of
  signed PeerIds/addresses is not private contact presence and its spam model
  is explicitly incomplete.
- [RFC 9458 — Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458.html) and
  [RFC 9614 — Privacy Partitioning](https://www.rfc-editor.org/rfc/rfc9614.html)
  — support explicit relay/gateway separation while retaining collusion,
  identifier, timing and side-channel limits.
- [Tor Onion Service rendezvous specification](https://spec.torproject.org/rend-spec-v3)
  — separates introduction and rendezvous and avoids exposing a service IP;
  Raven may carry an onion candidate only through a separately approved
  carrier and does not recreate Tor.
- [`RAVEN_NAT_CONNECTIVITY_V1.md`](RAVEN_NAT_CONNECTIVITY_V1.md) and
  [`RAVEN_MAILBOX_TRANSPORT_V1.md`](RAVEN_MAILBOX_TRANSPORT_V1.md) — existing
  production-disabled carriers that deliberately do not solve peer discovery
  or contact trust.

---

## 17. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial private known-peer rendezvous architecture: strict identity/contact/session/carrier separation; static-contact, session and OOB-invite lanes; private route descriptor; foreground pairwise LAN, pairwise directory/OHTTP and session-mailbox modes; no public presence or ordinary libp2p rendezvous fallback; multi-device/revoke/crash/resource/UX/vector/simulation/physical gates; all production paths disabled |
| 2 | 2026-08-21 | Private-introduction boundary: an ID-only sealed proposal remains a separate weaker pre-contact protocol; rendezvous begins only after explicit local contact commits and never interprets provider custody, request acceptance, or a public write capability as route/session authority |
| 3 | 2026-08-21 | Private-realtime boundary: reserved semantic realtime-provider descriptors but forbade their use until the dedicated companion/provider profile is approved; generic lookup cannot release ICE candidates, TURN/SFU credentials, peer addresses, ringing or capture authority before exact call acceptance and privacy-mode commitment |
