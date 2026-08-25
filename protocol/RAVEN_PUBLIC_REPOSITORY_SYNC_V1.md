# RAVEN Public Repository Sync V1

**Version:** 1 (architecture/security draft; wire not frozen)

**Document revision:** 10

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no public-feed network service, stranger Object Sync, DHT publication, OHTTP deployment, cache/mirror role, codec, database migration, live callsite, or Release flag

**Approval prerequisites:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md) revision registering the public social endpoint-record families; [`RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md`](RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md) and [`RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md`](RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md) **APPROVED**; [`RAVEN_ID_RESOLUTION_V1.md`](RAVEN_ID_RESOLUTION_V1.md) **APPROVED** for short-ID discovery; [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md) **APPROVED** (met); [`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md) **APPROVED** for media-manifest retrieval; Carrier Conformance profile for every enabled path

**Relationship to Object Sync:** this is a deliberately **asymmetric public pull** profile. It MUST NOT silently reuse or reinterpret [`RAVEN_OBJECT_SYNC_V1.md`](RAVEN_OBJECT_SYNC_V1.md), which is session-local, identity/device-authenticated, and higher-layer inventory-eligible. Public Repository Sync reveals no subscriber inventory and creates no contact.

**Relationship to Private Discovery:**
[`RAVEN_PRIVATE_DISCOVERY_V1.md`](RAVEN_PRIVATE_DISCOVERY_V1.md) may produce
bounded untrusted candidates for an *unknown* repository/object. After the user
or local policy selects one candidate, this companion alone owns known-repo
descriptor/frontier/object fetching and admission. A discovery score, shard or
assertion never substitutes for a requested digest, repository authority or
local subscription. Direct QR/import/follow of an already known repository does
not require a discovery service.

**Non-interference:** this draft does not amend Full Braid Slice 3 Task 0B/0C, protected-anchor work, Session V2, Object Sync V1, or any current production hold.

---

## 0. Normative language and core decision

The key words MUST, MUST NOT, SHOULD, and MAY are interpreted as in BCP 14 when capitalized.

The core decision is:

```text
signed public repo head
  -> pull immutable manifests/objects by digest
  -> verify every byte locally
  -> union verified branches from every source
  -> materialize/rank locally
```

There is no required Raven server, global firehose, canonical relay, follower upload, symmetric stranger inventory, network-order winner, or remote ranking service.

### 0.1 Why this is separate from Object Sync V1

Object Sync V1 is designed for two already-authenticated, inventory-eligible endpoint devices. It deliberately binds reconciliation IDs, replay, abuse state, and controls to that exact authenticated session.

A public follower is not necessarily a contact and should not disclose its local object set. Public Repository Sync therefore uses an asymmetric content-addressed pull:

- the publisher/mirror exposes only public repository artifacts;
- the follower sends no local inventory and no private follow graph;
- the follower fetches signed head hints, missing manifests, and exact objects;
- content authenticity comes from Raven identity/device signatures and exact digests, never from the source;
- a source may withhold or disappear, but cannot forge accepted bytes.

No fallback may tunnel public strangers through Object Sync V1 merely because both protocols transfer objects.

---

## 1. Goals, non-goals, and adversaries

### 1.1 Goals

| ID | Goal |
|---|---|
| P1 | Follow a verified public Raven repository without creating a messaging contact |
| P2 | Bootstrap and update from any combination of author devices, personal nodes, community mirrors, volunteer caches, static drops, or approved DHT-like stores |
| P3 | Make content authenticity independent of every transport/source |
| P4 | Preserve multi-device concurrent branches; never impose last-source/last-timestamp wins |
| P5 | Avoid uploading the subscriber's follow list or local object inventory |
| P6 | Support efficient cold bootstrap and incremental catch-up without a global firehose |
| P7 | Provide direct, OHTTP-assisted, LAN, and offline/drop deployment profiles with honest privacy labels |
| P8 | Enforce caps before allocation/network amplification and remain useful under malicious mirrors |
| P9 | Keep public fetch, contact messaging, community capability, and ranking authority separate |

### 1.2 Non-goals

- Confidentiality of public social records.
- Hiding all timing, size, IP, or interest metadata on every path.
- Proving a malicious author or all mirrors disclosed every valid record.
- Remote deletion of replicated public bytes.
- A universal total order or consensus ledger.
- A cryptocurrency, token economy, proof-of-work network, or mandatory global DHT.
- Replacing private contact/circle distribution or MLS.
- Letting mirrors moderate by rewriting author bytes.
- Defining social-record, media-chunk, OHTTP, or carrier wire bytes in this architecture revision.

### 1.3 Adversaries

| Adversary | Capabilities |
|---|---|
| Malicious source/mirror | Withhold, replay, reorder, duplicate, truncate, equivocate about availability, inject unrelated bytes, amplify responses |
| Network observer | Observe endpoints, timing, sizes; block or correlate paths |
| OHTTP relay | Observe client network identity and padded traffic, not plaintext request when correctly deployed |
| OHTTP gateway | Observe requested repo/object and response, not client network identity under the non-collusion model |
| Malicious public author/device | Sign conflicting writer slots or misleading head hints until locally revoked |
| Resolver/DHT | Return stale, conflicting, or attacker-selected descriptors/source hints |
| Sybil requester | Open many connections/requests to exhaust public mirrors |
| Curious source | Infer that a direct requester is interested in one repository |

### 1.4 Honest limits

Raven can verify bytes that it receives. It cannot prove that a source returned every object, that an offline author device published its newest branch, or that independently operated OHTTP roles do not collude. Product UI and protocol diagnostics MUST distinguish **verified**, **stale**, **partially available**, **source withheld**, and **unknown completeness**.

---

## 2. Roles and authority boundaries

| Role | May do | MUST NOT become |
|---|---|---|
| Author identity | Authorize repository descriptor chain and writer policy | Hosting requirement |
| Author device | Sign public social records, writer-chain segments, and bounded head announcements under a valid cert | Identity root after cert/revoke failure |
| Source | Store/serve exact public artifacts under local quotas | Contact authority, canonical head chooser, ranking authority |
| Follower | Keep local subscription, fetch/verify/admit/rank | Required to disclose follow graph or Raven identity |
| Resolver | Return content-addressed descriptor/source candidates | Repository owner or completeness oracle |
| Optional OHTTP relay | Forward encrypted HTTP messages | Request plaintext observer |
| Optional OHTTP gateway/source | Process plaintext public fetch request | Client network-identity observer under the claimed profile |
| Carrier | Move exact records/control under its approved profile | Social parser or trust mutator |

Authority is always reconstructed locally:

```text
RavenAddress / identity key
  -> exact repo descriptor chain
  -> exact device certificate + sticky revocation state
  -> author-device signature
  -> exact artifact digest / causal relation
```

Source TLS keys, libp2p peer IDs, DNS names, relay popularity, cache count, and proximity are availability/security signals only. They do not enter repository authenticity.

### 2.1 Umbrella byte classes and endpoint role

Public Repository Sync preserves the umbrella's byte separation:

| Bytes | Classification |
|---|---|
| Exact approved repo descriptor, writer segment, head announcement, or public social record | `endpoint_object_bytes` only after an umbrella revision registers that exact signed family; `object_digest = SHA-256(exact bytes)` |
| Live Get/response-status/paging/retry protocol message | Transient public-fetch **application-protocol bytes** at the source/gateway endpoint above an opaque carrier; never `carrier_control_bytes`, social content, or durable repository identity |
| HTTP/OHTTP/Noise/libp2p framing, cache metadata, redirect, or batch wrapper | Transport/`carrier_record_bytes` as defined by its carrier profile; never the endpoint digest root |
| Public repo drop/container | Import container only; each enclosed artifact regains its own exact class after strict extraction/verification |

A public mirror/cache that answers Get operations is an **application endpoint above a carrier**, not an opaque relay/mailbox hop. It may index only the explicitly public fields needed by the public-source profile. An opaque carrier still MUST NOT parse, translate, mint, or apply repository/social semantics. A node cannot claim relay opacity and source functionality for the same termination boundary.

---

## 3. Public repository artifacts

This section freezes sync semantics only. The production-disabled Social
Repository Authority draft now proposes exact descriptor/grant/retirement and
audience-policy bytes, but they remain unapproved and have no production
registration. Segment, announcement, public-fetch and drop wires remain open.

### 3.1 Repository descriptor

`RavenSocialRepoDescriptorV1` is defined by the Social Graph companion. For Public Repository Sync:

- `audience_class` MUST be `public`;
- its immutable `audience_partition_commitment` MUST match every repository record;
- `repo_id` is a domain-separated digest of exact repo/identity profile, stable owner authority, public audience partition, and a 32-byte nonzero CSPRNG genesis nonce; V1 binds address/key, while a distinct V2 profile binds stable continuity address/ID rather than its mutable operational key;
- the sequence-1 descriptor has both genesis/previous descriptor digests absent; every later descriptor binds the exact sequence-1 digest and exact immediately previous digest, with no gaps;
- descriptors carry bounded validity/expiry policy, while the subscriber durably pins the greatest verified descriptor sequence/digest and never rolls it back merely because a stale source responds;
- source hints are bounded mutable hints and MUST NOT be inputs to `repo_id` or writer authorization;
- changing owner/root creates a new repository and requires explicit re-subscription;
- omission of a previously used source or writer is not a delete/revoke.

Writer-policy/source fields are excluded from `repo_id`; otherwise a writer grant that binds `repo_id` would create a circular derivation. RNG failure, all-zero nonce, or detected owner-local nonce collision refuses creation. Time, handle, device ID, source address, sequence, or hash of a mutable descriptor is not a nonce substitute.

For a Continuity V2 owner, every descriptor, grant, segment, announcement, and record carries exact continuity generation/control-head/operational-key evidence as required by [`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md). Recovery can rotate authority without changing a V2 repo ID, but old devices/keys become ineligible for new admission. Historical objects remain verifiable only through their retained control-state evidence. Frozen V1 repos gain none of these semantics.

Descriptor expiry is an authorization ceiling, not global-freshness evidence. If the greatest pinned descriptor expires, the subscriber pauses new automatic admission until it verifies a valid successor or explicit repair; it never falls back to an older descriptor. Already admitted immutable records retain their exact historical admission evidence. No source timestamp, mirror count, relay preference, or signed but lower descriptor may reset this pin.

Writer authorization is exact evidence, not a descriptor-list side effect. The
authority draft proposes identity-signed `RVWG1` and `RVWR1` records with this
non-circular relationship:

```text
writer grant = repo_id + repo_genesis_core_digest + audience partition
             + device_id + cert_digest
             + grant_sequence + validity + previous_writer_policy_digest
             + identity_signature

writer retirement = exact grant/lineage + repo_genesis_core_digest
                  + retirement_sequence
                  + previous_writer_policy_digest + identity_signature
```

`repo_genesis_core_digest = SHA-256(exact RVSG1 bytes)`. It is not the
sequence-1 descriptor digest: grant 1 is computed first, and descriptor 1 may
then activate that grant by naming its policy digest without a cycle.

Public pull may cache `RVRA_CODEC_CONFORMANT` bytes under unknown-source quotas,
but repository/source/object eligibility requires `RVRA_AUTHORITY_ADMITTED`
under an explicit local subscription or Attention-approved discovery lane.
Neither state creates a contact. Contact-class authority is never requested from
or served by this public profile.

The descriptor's `writer_policy_digest` commits the append-only grant/retirement evidence. Every social record, writer segment, and head announcement binds the exact grant digest used. Exact replay is idempotent; equal policy sequence with different exact bytes is authenticated conflict; omission is no-op; only explicit verified retirement or Device Revocation denies future admission. A retired grant never becomes live again by replay/omission. A later higher-sequence grant may re-authorize a still-non-revoked certificate, but its existing writer lineage must continue at the next sequence. A sticky Device Revocation always wins. Retirement/revocation knowledge is eventual under partition and MUST NOT be described as instant global removal.

### 3.2 Social record

Exact public `social_record_bytes` may become exact `endpoint_object_bytes` only after the umbrella explicitly registers its wire family. Then:

```text
social_digest = SHA-256(social_record_bytes)
object_digest = SHA-256(endpoint_object_bytes)
endpoint_object_bytes == social_record_bytes
object_digest == social_digest
```

The public record includes the exact repo, author address, device/cert lineage, per-device writer sequence, previous writer digest, repo-parent digests, audience partition, payload/content references, and author-device signature required by the Social Graph companion.

It also binds the exact `author_writer_grant_digest`. A valid device certificate without the matching identity-signed repository grant cannot mint into that repo. A source-provided grant is parsed and verified as independent exact evidence; source colocation does not authorize it.

### 3.3 Writer segment manifest

A `RavenRepoWriterSegmentV1` is an immutable, author-device-signed index over one contiguous section of one exact writer lineage:

```text
segment_version
repo_id
descriptor_digest
author_address
author_device_id
author_device_cert_digest
author_writer_grant_digest
first_device_seq_u64
last_device_seq_u64
previous_segment_digest?          # absent only for first segment
ordered_entries[]                 # (device_seq_u64, social_digest)
entries_merkle_root
created_at_ms                     # advisory
author_device_signature
```

Rules:

1. A segment covers one lineage and a checked non-empty contiguous range.
2. Entries are strictly increasing by one and unique.
3. Every listed record must independently verify and bind the same slot/digest.
4. Exact replay is idempotent. Same `(lineage, first, last)` with different exact bytes is conflict evidence.
5. Adjacent segments bind by exact previous segment digest. Gaps remain missing; they are never filled by source claims.
6. A segment proves only that the signing device asserted this ordered list. It does not prove global repository completeness.
7. A subscriber MAY fetch individual records without a segment. A segment accelerates bootstrap but never replaces record verification.

Default segment target is 256 records; the later wire may tighten it but MUST preserve bounded proof and contiguous semantics.

### 3.4 Head announcement

`RavenRepoHeadAnnouncementV1` is an immutable author-device-signed hint carrying:

- exact repo/descriptor/owner/device/cert lineage;
- exact writer-grant digest and greatest writer-policy evidence known to the announcer;
- per-announcer `announcement_seq_u64` and previous announcement digest;
- a bounded union of known repository head `social_digest` values;
- a bounded writer-frontier list `(lineage, greatest device_seq, record digest, latest segment digest?)`;
- source hints, creation time, and expiry;
- exact author-device signature.

Announcements never delete retained heads or establish completeness. A newer announcement that omits an old branch is not a tombstone. Subscribers recompute actual heads from verified records and successor relations.

### 3.5 Source hint

A source hint is a bounded locator plus transport profile and expiry. It MAY be carried in an identity resolve record, repo descriptor update, head announcement, QR bundle, contact gossip, or local configuration.

Before dialing/fetching, a client MUST enforce:

- scheme/profile allow-list;
- strict length/canonicalization and no credentials in URLs;
- local policy for loopback, private, link-local, onion, or LAN addresses;
- DNS rebinding defense by validating every resolved address at connect time;
- redirect limits and same-profile constraints;
- no automatic launch of arbitrary app/file/custom schemes;
- per-repo/source/global dial and byte budgets.

Even an identity-signed source hint is permission to **try a location**, not permission to trust its response or bypass SSRF policy.

### 3.6 Optional repository drop

A `RavenPublicRepoDropV1` is a bounded offline bundle/container containing exact descriptors, announcements, segments, records, and optional media chunks. USB, AirDrop, QR-adjacent file transfer, removable media, mailbox-like public caches, or static HTTP may carry the same drop bytes.

The container is not an endpoint object, signature, head, or completeness proof. Every contained artifact is independently parsed, hashed, verified, and admitted. Extra/unlinked artifacts are ignored within strict total caps; conflicting authenticated evidence is retained.

---

## 4. Subscription state and privacy boundary

### 4.1 Local subscription

Selecting **Follow** creates a local record:

```text
PublicRepoSubscription {
  local_account_scope_id,           # local storage namespace only; never sent
  owner_address,
  repo_id,
  accepted_descriptor_digest,
  greatest_descriptor_sequence,
  greatest_writer_policy_digest,
  local_policy_digest,
  verified_writer_frontiers,
  verified_head_set,
  source_hints,
  poll_backoff,
  last_success_monotonic_event,
  conflict/staleness evidence
}
```

It MUST NOT contain Session V2 roots, contact acceptance, PairInit authority, a remote capability, or a publicly visible follow edge. At-rest storage follows the platform's approved protected-state profile. Corruption or rollback disables automatic sync for that subscription until repair; it does not create a new contact or silently reset verified frontiers.

### 4.2 No read receipts by default

Fetching, caching, verifying, displaying, scrolling, or ranking a public record MUST NOT emit an endpoint ACK, social reaction, follow statement, view event, or author notification. HTTP success/custody response proves only a transfer attempt between the requester and that source.

An explicit reply/reaction/follow publication is a new separately signed social record with its own audience and user intent.

### 4.3 Follow privacy

Raven MUST NOT upload a subscriber's full follow list to construct a feed. Each subscription is polled independently or through a locally chosen padded scheduler. Local batching MUST NOT put multiple repository IDs into one request merely for convenience unless the UI/profile honestly discloses that the receiving gateway learns that correlation.

Direct fetch reveals at least the requester network address and requested repo/object to the source. This is the baseline mode and MUST be labeled accordingly.

### 4.4 Optional OHTTP-assisted fetch

An APPROVED OHTTP profile MAY separate network identity from request plaintext:

```text
client --encrypted OHTTP request--> relay --opaque--> gateway/source
```

The relay sees client network metadata and padded message size/timing; the gateway sees repo/object requests and response, while the privacy claim assumes they do not collude. OHTTP does not hide access timing/volume, prevent endpoint compromise, prove source completeness, or make public content private.

The profile MUST freeze:

- exact RFC 9458 suite/configuration and key-consistency policy;
- relay/gateway independence assumptions;
- request/response padding buckets and maximum overhead;
- retry policy that does not create a distinctive per-repo fingerprint;
- configuration rotation, expiry, and fail-closed behavior;
- whether direct fallback is forbidden or requires an explicit user decision.

### 4.5 Optional anonymous rate credentials

Privacy Pass MAY be evaluated later for unlinkable public-source quotas. It is not required for V1 and cannot become identity/contact trust. Any profile must freeze issuer/attester/origin roles, key consistency, challenge scope, token partitioning, hoarding/Sybil limits, and non-collusion assumptions. Failure MUST degrade only optional public fetching, never private messaging or local access to retained records.

### 4.6 Unfollow, block, and re-follow

Unfollow is a local transaction: cancel pending public polls, remove the active subscription/view under local retention policy, and emit no remote event. It does not retract a separately published `FollowStatement` and makes no remote-erasure claim.

A local block immediately stops automatic dialing/fetch/admission/display for that owner/repo according to block policy. It preserves the block, sticky revoke, authenticated conflict, and minimum anti-rollback evidence required to prevent replay from reopening the repo. Unblock does not clear revocation, writer retirement, descriptor conflicts, or source-abuse state.

Re-follow uses the greatest retained verified descriptor/writer-policy safety pin. If the user explicitly erased all local safety evidence, the UI must treat re-follow as first trust and disclose that prior rollback/conflict detection was lost. Subscription state is isolated by `local_account_scope_id`; one local account's follow/block/source hints never authorize or leak into another account.

---

## 5. Asymmetric pull protocol (semantic)

### 5.1 Operations

A future byte-exact public-fetch wire may expose only bounded forms of:

| Operation | Request | Response |
|---|---|---|
| `GetDescriptor` | repo ID or exact descriptor digest | exact descriptor bytes/chain fragment |
| `GetAnnouncements` | repo ID + bounded known announcement/frontier hints | exact signed announcement bytes |
| `GetSegment` | exact segment digest or lineage/range bounded by verified announcement | exact segment bytes |
| `GetObject` | exact `object_digest` | exact `endpoint_object_bytes` |
| `GetObjects` | bounded sorted unique exact digests | independently length-delimited exact objects |
| `GetDrop` | exact signed drop/manifest locator | bounded opaque drop bytes |
| `GetMediaManifest` | exact approved Manifest Store/sidecar digest | exact bounded manifest bytes under the media profile |
| `GetMediaChunk` | exact approved media root/chunk proof | verified-stream chunk (future media profile) |

The server MAY return a generic unavailable result or silence. It MUST NOT be required to reveal whether an object is blocked, expired, absent, rate-limited, or withheld.

A source serves exact bytes only. It cannot decide that a C2PA claim is true,
merge a Raven author with a claim generator or named actor, infer consent,
resolve a soft binding as global identity, or award a provenance/attention
badge. Those are separate bounded client-side validation and policy outcomes
under [`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md).

Requests and status messages are transient **public-fetch application-protocol
bytes**, not `carrier_control_bytes`. They run at the source/gateway application
endpoint above an opaque carrier and require an exact future request/response
profile; confidential forms travel inside a sealed Endpoint object or the
approved OHTTP/public-fetch profile. A successful response transports exact
independently length-delimited endpoint artifacts; batching or HTTP/OHTTP framing
does not become part of their `object_digest`. The receiving Endpoint admits
each artifact separately and MUST NOT trust a batch-level success code. Carriers
do not learn repo/query/rate/attention semantics from these messages.

V1 has no `ListAllRepositories`, global `since`, network-wide firehose, follower lookup/count, trending feed, remote ranking recipe, or arbitrary server-side social query. A deployment may offer discovery/search as a distinct untrusted candidate service, but its output re-enters the descriptor/record verification pipeline and carries no authority.

### 5.2 What the subscriber sends

The subscriber MUST NOT send:

- its Raven identity or device certificate merely to read public data;
- contacts, other followed repos, local object inventory, ranking recipes, blocks, or label subscriptions;
- raw Session V2 keys/tags or Object Sync V1 exporter material;
- a Bloom filter/IBLT of locally held public objects;
- read/display state.

For incremental catch-up, it MAY send only a bounded repo-scoped frontier already public in verified announcements: exact announcement digest, writer lineage plus greatest verified sequence, or exact segment digest. A source learns that this requester has at least that public frontier; OHTTP mode may reduce linkage to the subscriber's network identity.

### 5.3 Cold bootstrap

```text
1. obtain descriptor candidates from ID Resolution / QR / local import
2. verify owner address/key and complete descriptor chain
3. collect bounded signed head announcements from independent sources
4. union announcements; classify conflicts/staleness
5. fetch missing writer segments/frontiers from any source
6. fetch exact social objects by digest
7. verify each object's digest/signature/cert/revoke/audience/writer slot
8. atomically commit record + writer/frontier/head/admission evidence
9. materialize local view; emit no remote read receipt
```

### 5.4 Incremental catch-up

The subscriber polls or receives a non-authoritative wake-up hint, fetches newer exact announcements, and compares them with local verified frontiers. It requests only missing segment/object digests. A response from one source may be retried byte-identically or satisfied by another source.

No source can roll back local state. A lower sequence is stale; equal sequence with different bytes is conflict; gaps remain missing; omitted branches remain locally retained. A future-validity timestamp never overrides exact sequence/digest evidence.

### 5.5 Multi-source union

Multiple valid copies of exact bytes are duplicates. Different valid announcements/branches are unioned. Source count is not a vote:

```text
1 valid signed artifact from 1 source == authentic artifact
100 invalid/unsigned copies == no authority
99 sources omitting a retained branch != deletion
```

Source performance MAY influence the next fetch attempt, but MUST NOT influence signature validity, fork choice, local ranking, contact status, or conflict resolution.

### 5.6 Repair and migration

If a source becomes unavailable, subscribers try other bounded hints or user-selected sources. If the owner changes source endpoints, the descriptor/head chain carries new hints while old locations remain non-authoritative caches.

Repository owner/root change creates a new repo. The client displays the new fingerprint and requires explicit subscription migration. A handle mapping change never silently migrates a repo.

---

## 6. Admission and durable commit

For every fetched public artifact:

1. enforce transport and declared-length caps before allocation;
2. strict-parse exact bytes with no trailing data/unknown critical fields;
3. recompute the requested digest and reject mismatch;
4. verify owner address/key and exact descriptor chain;
5. verify author device certificate, exact identity-signed writer grant, lineage, signature, validity policy, explicit writer retirement state, sticky revocation union, and local block;
6. verify audience partition is exactly `public` and repo/writer slot/parents match;
7. check exact replay, writer conflict, gap, announcement conflict, and rollback state;
8. construct a candidate store/view mutation;
9. durably commit exact bytes plus descriptor/cert/revocation/source-independent admission evidence;
10. only then expose it to local views/search/ranking.

No public fetch response advances `DELIVERED_TO_DEVICE` or `READ`. Those states belong to exact sealed endpoint delivery, not public replication.

### 6.1 Revocation and history

Learning a valid device revoke denies new admissions from that lineage. Already admitted public records retain exact historical evidence and are displayed/hidden/warned according to explicit local policy; an advisory author timestamp cannot prove pre-compromise minting. A mirror cannot clear a revoke by replaying an old descriptor or certificate.

### 6.2 Tombstones

A verified tombstone affects the local materialized view according to the Social Graph companion. It does not require a mirror to physically erase old bytes and MUST NOT be interpreted as proof that all replicas complied.

### 6.3 Crash safety

Subscription frontier/head state MUST NOT advance before every exact record required for that advance and its admission evidence are durably committed. Recovery is roll-forward/idempotent:

- crash before commit: old frontier/view;
- crash after object commit but before frontier promotion: recovery promotes from exact retained evidence;
- crash after frontier promotion: exact replay is idempotent;
- corrupt/rolled-back protected frontier: automatic network sync disabled until repair; retained content is not silently re-trusted.

The greatest descriptor sequence/digest, writer-policy sequence/digest, and verified per-lineage frontier are anti-rollback state. Restoring any lower snapshot cannot silently reopen retired writers or replace a pinned repository root.

### 6.4 Authentic does not mean safe

A valid author signature proves provenance, not benign content. Before rendering, Raven applies a versioned schema allow-list, bounded UTF-8/media parsing, decompression limits, and platform sandboxing. Public records MUST NOT execute embedded script/native code, auto-open files, auto-follow redirects, or auto-fetch third-party URLs. Link previews and remote media are separate user/policy-governed fetches so an author cannot turn feed viewing into a tracking beacon.

---

## 7. Source behavior and resource safety

### 7.1 Source policy

Any person may operate a public source. A source MAY:

- retain only selected repositories, schemas, dates, or sizes;
- refuse any request;
- impose lawful content policy and quotas;
- serve cached exact bytes without understanding social semantics;
- publish its own signed service metadata as an availability hint.

It MUST NOT claim that serving or refusing bytes changes author authenticity, contact status, or the follower's local view policy.

### 7.2 Request amplification

Every request freezes a response-byte/work reservation before disk reads or allocation. Batch operations have strict item and total-byte ceilings. Redirects, retries, decompression, nested containers, and media proofs each debit cumulative budgets. Compression ratios are bounded and decompressed length is checked before allocation.

### 7.3 Abuse accounting

Because a public reader need not reveal a Raven identity, V1 cannot promise Sybil-resistant anonymous quotas. Sources use deployment-local controls (connection caps, IP/network quotas where visible, OHTTP relay quotas, proof-of-work only if a future approved optional profile explicitly chooses it, or generic refusal). These controls are not portable trust evidence.

A source MUST NOT demand contact acceptance, PairInit, address-book upload, or private capability merely to serve public bytes.

### 7.4 Cache poisoning and storage pressure

- bytes are indexed only after digest verification;
- authenticated conflicts retain bounded evidence but do not overwrite accepted bytes;
- unknown repositories cannot evict pinned subscriptions or active contact/session work;
- source-controlled freshness/timestamps never determine eviction alone;
- active pinned heads and their verification chain are non-evictable under the subscription's policy;
- capacity exhaustion refuses new stranger work before evicting trusted state.

---

## 8. Carrier/deployment profiles

| Profile | Allowed role | Required honesty |
|---|---|---|
| Direct HTTPS/QUIC | Client pulls from source | Source sees network identity + repo/object interest; TLS authenticates channel endpoint, not Raven content |
| Direct ephemeral Noise | Client pulls over reviewed public-read handshake | No contact/PairInit; source key is path identity only; exact Raven bytes still self-authenticate |
| OHTTP | Relay/gateway-separated HTTP fetch | Explicit non-collusion, padding, key-consistency, no silent direct fallback |
| LAN/Bonjour | User-approved or policy-bounded public source discovery/fetch | Bonjour name/proximity not authority; SSRF/private-address policy applies |
| BLE | Small bounded head/drop exchange only after carrier profile | Advertisements are hints; no unbounded stranger sync |
| Circuit relay | Opaque carriage of one public-read stream | Relay does not become source authority or social parser |
| Static file / USB / AirDrop | Public repo drop import | Container untrusted; every artifact verified independently |
| Mailbox/store | Only under a separately approved public-cache record family | MUST NOT reinterpret private StoreObject/mailbox semantics |

Every enabled profile requires its own Carrier Conformance rows for truncation, replay, redirect/transplant, caps, privacy labels, source failure, and physical testing.

---

## 9. Discovery and availability strategy

### 9.1 No mandatory global index

Raven public repositories remain usable through any one of:

- exact repo credential shared by QR/file/NFC;
- ID Resolution result with verified descriptor digest;
- source hints in a verified descriptor/head;
- direct author-device discovery;
- trusted contact gossip of untrusted candidate locations;
- user-selected community mirrors;
- static public-repository drops/mirrors;
- an optional approved DHT-like lookup keyed by a public repo locator.

No deployment is mandatory for authenticity. Availability improves by using several independent paths.

A private [`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md) repository is **not** a public source, drop, mirror, locator, or discovery path. Restoring exact public records from a personal archive creates a local historical copy only; it cannot announce heads, serve strangers, republish, or prove current completeness without an explicit separately authorized public-source action.

### 9.2 Public locator

If a later wire defines a public lookup key, it must be domain-separated from Raven identity, Session V2, mailbox, route, and Object Sync keys. Because the repo is public, this locator does **not** hide which repo is queried and MUST NOT be marketed as private discovery.

### 9.3 Opportunistic replication

A user MAY opt in to cache bounded public repositories for others. The UI must show storage/network impact and permit removal. Caching does not publish the user's follow list; a cache policy can be independent of what the user follows.

No incentive/token layer is required. A future optional incentive system would be a separate threat model and MUST NOT alter content authenticity or routing priority by wealth.

### 9.4 Availability score is local only

Clients MAY rank source attempts by local success, latency, cost, metered status, and privacy mode. This score is never serialized as author truth and never ranks social content. A fast mirror does not become a more authentic mirror.

### 9.5 Decentralized discovery graph

Users can discover beyond repositories they already know without a mandatory global index:

- verified replies, reposts, quotes, mentions, and `FollowStatement` records link to other exact identities/repos/objects;
- user-selected labelers and curators publish signed collections or recommendations with explicit provenance;
- communities publish capability-bound indexes under their own signed policy;
- contacts may gossip candidate repo credentials/source hints without granting them trust;
- local full-text/search/ranking runs over already retained verified bytes;
- optional remote search returns bounded untrusted candidates, never an authoritative feed.

Opening a candidate displays its author/repo evidence and permits `PUBLIC_VIEW_ONLY`; following remains a separate local action. Popularity, repeated appearance, curator signature, community membership, or search rank MUST NOT create a contact, bypass block/revocation, or make an unverified object authentic. Raven's differentiator is that recommendation provenance is inspectable and replaceable while ranking stays user-owned.

Candidate admission, curator/labeler subscription, stranger resource budgets, local ranking, and notifications are governed by [`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md). Exact pull of an already followed repository can be specified independently, but no discovery/amplification service may ship until that companion is APPROVED. Public Repository Sync never accepts a remote attention lane, budget, ranking score, or “trending” result as authority.

---

## 10. Failure matrix

| Failure | Required outcome |
|---|---|
| Descriptor owner/root mismatch | Reject; no subscription/contact mutation |
| Descriptor lower sequence | Stale; retain greatest verified chain |
| Equal descriptor sequence, different bytes | Authenticated conflict; quarantine update |
| Writer grant missing/wrong repo, partition, device, or cert | Reject before record/segment/head admission |
| Writer-policy equal sequence, different bytes | Authenticated conflict; quarantine affected policy chain |
| Descriptor omits prior writer grant | No revoke/retirement; retain prior verified evidence |
| Explicit writer retirement learned | Deny future admissions under retired grant; preserve historical evidence/policy |
| Source hint targets forbidden address/scheme | Refuse before dial |
| Redirect crosses profile/limit | Refuse |
| Head announcement bad signature/cert/revoke | Reject; no frontier change |
| Equal announcement sequence, different bytes | Retain conflict evidence; no arrival-order winner |
| Announcement omits retained head | Keep retained head; absence has no authority |
| Segment gap/overlap/wrong previous digest | Missing/conflict; no frontier advance |
| Segment lists wrong record digest/slot | Reject segment and offending object |
| Object digest mismatch/truncation/trailing bytes | Reject before social mutation |
| Same writer slot, different signed records | Authenticated conflict; terminalize that slot pending explicit repair |
| Mirror returns valid unrelated object | Ignore/refuse; requested digest binding fails |
| One source withholds | Try bounded alternatives; report partial/stale honestly |
| All sources unavailable | Retained local feed remains; no false unfollow/delete |
| OHTTP configuration stale/invalid | Fail private mode; direct fallback only by frozen explicit policy/user choice |
| Crash during object/frontier commit | Old or new complete state only; roll-forward exact evidence |
| Local subscription store rollback/corruption | Disable automatic sync; never reset trust/frontier silently |
| Contact/block changes | Public follow remains distinct; local block may suppress fetch/display without publishing edge |
| Unfollow during an in-flight fetch | Cancel/ignore candidate before admission barrier; emit no remote unfollow/read signal |
| Re-follow after retained safety pin | Resume from greatest verified descriptor/policy; stale source cannot reset |
| Re-follow after explicit safety-evidence erasure | First-trust UX; no claim of rollback/conflict continuity |
| Device revoked | Deny new admissions; historical display follows explicit policy |
| Source requests PairInit/contact | Refuse; public read never requires contact |

---

## 11. Architecture ceilings

Later wire/carrier profiles may only tighten these values.

| Resource | Default | Absolute maximum |
|---|---:|---:|
| Descriptor bytes | 16 KiB | 64 KiB |
| Descriptor chain records per fetch | 8 | 32 |
| Head announcement bytes | 16 KiB | 64 KiB |
| Heads/frontiers per announcement | 32 | 256 |
| Source hints per artifact | 8 | 32 |
| Segment records | 256 | 1024 |
| Segment bytes | 128 KiB | 1 MiB |
| Object digests per batch request | 32 | 256 |
| Single social endpoint object | Social companion default | Never above umbrella/carrier absolute maximum |
| Public drop bytes | 32 MiB | 256 MiB with explicit user import |
| Concurrent source connections per repo | 2 | 4 |
| Concurrent public reads process-global | 16 | 64 |
| Redirects per request | 1 | 2 |
| Retry sources per poll | 3 | 8 |
| Pinned subscriptions per local account | 1,000 | 10,000 under explicit storage policy |
| Unknown repo candidate cache | 64 entries / 15 min | 256 entries / 1 hour |

Checked arithmetic and cumulative byte/work budgets are mandatory. Unknown public work MUST NOT evict contact/session/revocation/protected-anchor state.

---

## 12. Shared vectors, simulations, and physical gates

### 12.1 Three-language vectors

Python, Rust, and Swift must compute rather than JSON-echo:

- self-certifying repo ID and descriptor chain/signatures;
- repo-ID non-circular genesis derivation, RNG/collision refusal, and changes under owner/audience/profile/nonce substitution;
- writer segment contiguous ranges, previous-segment chain, and Merkle root;
- writer grant/retirement chain, omission-no-revoke, exact record-to-grant binding, and policy rollback/conflict;
- head announcement sequence/previous digest/frontier binding;
- two device lineages at sequence 1 as concurrent valid branches;
- same writer slot/different bytes as conflict;
- source union with exact duplicates, stale hints, withholding, and unrelated injected objects;
- unfollow/block/re-follow isolation, in-flight cancellation, retained-pin rollback defense, and explicit-evidence-erasure first-trust behavior;
- object/social digest equality for approved public records;
- revocation/cert/audience-partition admission;
- exact OHTTP/plain request binding once that profile exists;
- every structural/cap failure in §10–§11.

### 12.2 Deterministic simulations

| Simulation | Required proof |
|---|---|
| 1,000 nodes / 100 repos / churn | Honest replicas converge to the same verified union; no source becomes authority |
| Multi-device partition | Two offline devices mint branches, distinct sources see subsets, later union retains both |
| Withholding | One mirror omits a lineage/tombstone; no local deletion or false completeness |
| Eclipse attempt | Attacker controls most source hints but cannot substitute owner/descriptor/object bytes |
| Follow privacy | No request contains another repo/follow list/local inventory; direct vs OHTTP leakage labels match traces |
| Spam | Unknown repo/source floods stay within memory/CPU/dial/store caps and cannot evict trusted state |
| Crash matrix | descriptor/object/frontier phases restart to old/new complete state only |
| Source migration | Author changes sources; repo ID/content authority remains stable |
| Censorship recovery | Static drop/contact gossip/alternate cache restores a withheld valid branch |

### 12.3 Process/physical matrix

- macOS/Linux/Windows Terminal source ↔ iPhone follower;
- iPhone foreground author/source ↔ Terminal follower on LAN;
- direct Internet, opaque relay, and OHTTP-separated fetch;
- AirDrop/file/drop import while offline;
- kill/relaunch during object/frontier commit;
- source disconnect mid-response and byte-identical retry from another source;
- block/revoke/descriptor conflict while polling;
- metered/low-power scheduling with no unbounded wakeups.

Automated localhost tests are necessary but not sufficient for carrier approval.

---

## 13. UX contract

UI must distinguish:

- **Following locally** — private local preference;
- **Public source available** — reachability only;
- **Verified repository** — owner/descriptor checks passed;
- **Partially synchronized** — some branches/ranges missing;
- **Conflicting writer evidence** — authenticated equivocation;
- **Stale** — no fresh verified announcement within policy;
- **Blocked locally** — local policy, not global deletion;
- **Tombstoned by author** — signed view request, not physical erasure.

The product must not show “delivered,” “read,” “complete network,” “deleted everywhere,” or “trusted contact” merely because public fetch succeeded.

Terminal concepts should remain explicit:

```text
raven public follow <verified-repo-credential>
raven public sources <repo>
raven public sync <repo> [--privacy direct|ohttp|offline]
raven public status <repo>
raven public export-drop <repo>
raven public import-drop <file>
```

These are design names only; this draft does not authorize CLI implementation.

---

## 14. Production holds

No public repository network path may be enabled until all of:

1. this companion is **APPROVED** by explicit human protocol-owner action;
2. the umbrella is revised/re-approved to register every public social endpoint-record family, while the exact public-fetch request/response application profile is approved without being misclassified as carrier control;
3. Social Graph V1, Social Repository Authority V1, ID Resolution V1, and the byte-exact social-object wire companion are APPROVED;
4. descriptor, segment, head, request/response, drop, error, cap, and domain bytes are frozen with three-language vectors;
5. Device Revocation integration and historical-admission evidence pass crash/rollback tests;
6. exact writer-grant/retirement evidence and anti-rollback policy state pass partition/crash vectors;
7. direct/OHTTP/LAN/BLE/relay/drop profiles each pass Carrier Conformance and physical rows before that profile is enabled;
8. OHTTP claims cite exact suite/configuration, key consistency, padding, role independence, and no-silent-fallback policy;
9. public follow/subscription state is proven never to create contact, PairInit, private Object Sync eligibility, capability, ACK/read receipt, or ranking authority;
10. multi-source withholding/eclipsing/spam and 1,000-node simulations pass bounded convergence criteria;
11. protected local subscription/frontier persistence passes kill/relaunch/corruption/rollback gates on Apple/Linux/Windows;
12. independent security/privacy review has no open P0/P1;
13. Attention Firewall V1 is APPROVED before any public discovery, curator/labeler, stranger admission, remote search, ranking, or notification surface ships;
14. Identity Continuity V2 is APPROVED before a V2-owned public repo accepts rotated/recovered operational authority under one stable `repo_id`;
15. no lab/test flag compiles into an enabled Release path;
16. Private Discovery V1 is APPROVED before any unknown-repository search,
    public shard or remote candidate-query surface is enabled; known-repository
    pull remains separately gated by this companion.

Passing unit tests or deploying one public mirror is not approval.

---

## 15. Open decisions before vector freeze

1. Independent approval/vectors/durability for drafted descriptor/grant/retirement wires; exact segment, announcement, request/response, and drop layouts.
2. Continuity-V2 repo-ID/control rotation and explicit conflict-repair policy; V1 repo-ID derivation is drafted but not yet approved.
3. Segment Merkle construction, proof format, target size, and frontier compaction.
4. Exact public-fetch transport handshake/exporter and replay model per carrier.
5. Direct-fetch padding, polling jitter, and metered/low-power schedule.
6. OHTTP RFC 9458 suite, key-discovery consistency, relay/gateway deployment, padding, and fallback UX.
7. Whether Privacy Pass is worth its issuer/attester complexity; V1 does not require it.
8. Public media verified-stream/chunk profile and cache retention.
9. Source service metadata, discovery, redirects, SSRF/private-network policy, and onion support.
10. Conflict repair and device-key compromise/repository recovery UX.
11. Public drop container format and zip/tar/path traversal defenses.
12. Legal/moderation behavior for volunteer caches without turning cache policy into authenticity.
13. Exact boundary between public-fetch source quotas and the local Attention Firewall budget ledger.

---

## 16. Research foundations (informative only)

These sources inform architecture; Raven claims no wire compatibility:

- [AT Protocol Repository](https://atproto.com/specs/repository) and [Sync](https://atproto.com/specs/sync) — signed content-addressed repository commits, exports/diffs, independently verifiable mirrored bytes, and explicit withholding limits.
- [Secure Scuttlebutt Protocol Guide](https://ssbc.github.io/scuttlebutt-protocol-guide/) — signed one-writer append-only feed sequences and previous-message chaining.
- [IPNS](https://docs.ipfs.tech/concepts/ipns/) — self-certifying signed mutable pointers to immutable content addresses.
- [Willow Data Model](https://willowprotocol.org/specs/data-model/) — namespaces/subspaces and deterministic store joins.
- [Willow Confidential Sync](https://willowprotocol.org/specs/confidential-sync/index.html) — partial sync, private-interest overlap, access control, resource negotiation, and transport independence; Raven does not reuse it for public follow V1.
- [Willow Transfer Protocol](https://willowprotocol.org/specs/wtp/index.html) — asymmetric request/response sync with explicit metadata leakage to the server.
- [RFC 9458 — Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458.html) — optional relay/gateway separation.
- [RFC 9576 — Privacy Pass Architecture](https://www.rfc-editor.org/rfc/rfc9576.html) — optional future unlinkable authorization/rate credentials and their deployment assumptions.

---

## 17. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial architecture draft: asymmetric content-addressed pull instead of stranger Object Sync; self-certifying repo/descriptor boundary; per-writer segment manifests; signed head hints; multi-source union without quorum authority; local-only follow state; direct/OHTTP privacy modes; no read receipts; source/SSRF/abuse caps; crash ordering; vectors/simulations/physical gates; explicit production holds |
| 2 | 2026-08-21 | Independent red-team hardening: exact identity-signed writer grants/retirements; omission-no-revoke; record/segment/head grant binding; greatest descriptor/writer-policy anti-rollback state; explicit public discovery graph; no global query API; authentic-content rendering safety; expanded failure/vector/production gates |
| 3 | 2026-08-21 | Repository/subscription hardening: non-circular nonce-derived repo identity; exact genesis/successor descriptor chain; expiry-as-ceiling and no-fallback freshness semantics; isolated unfollow/block/re-follow lifecycle; immutable RVOR-like safety evidence retention |
| 4 | 2026-08-21 | Attention-plane integration: exact followed-repo pull remains separate from stranger discovery/amplification; remote sources cannot assign lanes, budgets, rank, or notifications; public discovery now depends on the production-disabled Attention Firewall companion |
| 5 | 2026-08-21 | Identity-continuity integration: separate frozen-V1 and continuity-V2 repo derivations; V2 uses stable continuity authority while retaining exact operational control-head evidence; recovery rotates authority without silently changing repo identity or accepting retired lineages |
| 6 | 2026-08-21 | User-owned archive separation: replaced ambiguous static “backups” with public drops/mirrors and made private archive restore a local historical operation, never a public source, discovery path, republish, or completeness proof |
| 7 | 2026-08-21 | Repository-authority reconciliation: linked the exact but unapproved authority draft and froze the non-circular `RVSG1` core→writer grant→descriptor activation direction; retained all public-network and production holds. |
| 8 | 2026-08-21 | Attention/carrier boundary correction: public-fetch requests, status and rate semantics are application-protocol bytes above opaque carriers, never `carrier_control_bytes`; exact endpoint artifacts and object digests remain unchanged. |
| 9 | 2026-08-21 | Private-discovery boundary: unknown-content search yields candidate evidence only, then hands a selected exact repository/object to this known-repo pull profile; discovery order, score and shard evidence cannot replace authority, digest or subscription. |
| 10 | 2026-08-21 | Sovereign-media boundary: added a future exact-digest Manifest Store fetch operation; sources remain byte servers and cannot validate truth, infer consent, resolve soft bindings as identity, merge actors, or assign provenance/attention authority. |
