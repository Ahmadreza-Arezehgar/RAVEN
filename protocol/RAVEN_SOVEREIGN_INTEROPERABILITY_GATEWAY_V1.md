# RAVEN Sovereign Interoperability Gateway V1

**Version:** 1 (architecture/security/privacy draft; wire and adapters not frozen)

**Document revision:** 1

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no ActivityPub actor,
inbox/outbox, Matrix Application Service, Nostr relay/client, MIMI provider,
foreign-account login, credential import, semantic translator, bot/device,
bridge membership, public mirror, background sync, database migration,
dependency, live callsite, network service or Release flag

**Approval prerequisites:**
[`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md)
must register and be re-approved for foreign-evidence, gateway-observation and
semantic-projection public record classes.
[`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md),
[`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md),
[`RAVEN_SOCIAL_OBJECT_WIRE_V1.md`](RAVEN_SOCIAL_OBJECT_WIRE_V1.md),
[`RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md`](RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md),
[`RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md`](RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md),
[`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md),
[`RAVEN_SOVEREIGN_COMMUNITIES_V1.md`](RAVEN_SOVEREIGN_COMMUNITIES_V1.md),
[`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md),
[`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md), and one
exact independently reviewed companion per enabled foreign network must be
**APPROVED**.

**Non-interference:** this companion is not
[`RAVEN_BRIDGE_V1.md`](RAVEN_BRIDGE_V1.md). The existing Raven Bridge forwards
unchanged opaque Raven ciphertext between carriers and cannot read endpoint
semantics. A sovereign interoperability gateway terminates one or more
application protocols, may see plaintext, and creates new explicitly attributed
objects. It is therefore an endpoint/bot/publisher under user policy, never an
opaque relay and never invisible infrastructure.

---

## 0. Constitutional decision

Raven interoperability separates six planes that conventional bridges often
collapse:

```text
Foreign exact evidence        What exact foreign bytes/event were observed?
Foreign authority             Which foreign key/server/room rules authenticate it?
Gateway observation           Which Raven gateway observed and validated it?
Semantic projection           What bounded meaning can be represented in Raven?
User authorization            What may be imported/exported, to whom and for how long?
Local trust and attention     What will this device retain, show, notify or amplify?
```

The governing rule is:

> Interoperability is translation with evidence, not signature laundering.
> Raven never pretends a foreign actor signed Raven bytes, never pretends a
> gateway is the original author, and never calls a downgraded bridge E2EE.

The same human may control a Raven identity, ActivityPub actor, Matrix user and
Nostr key, but those are separate authorities until an exact reviewed linkage
proves only the stated relationship. Similar names, avatars, domains, contacts,
followers or posts are not identity proof.

The key words MUST, MUST NOT, SHOULD and MAY are interpreted as in BCP 14 when
capitalized.

### 0.1 Why this is a Raven differentiator

Raven does not require users to abandon existing communities before adopting a
sovereign stack. A user may run the gateway locally, on a personally selected
node or through a replaceable disclosed operator. Every imported/exported item
retains inspectable origin and transformation evidence. The gateway can be
removed without changing the user's Raven identity, social graph, archive,
community governance or local Attention policy.

This is stronger than a conventional cross-post bot but more honest than a
claim of universal identity or universal E2EE:

- public posts can cross with exact origin and loss disclosure;
- private messages cross only when the gateway is an explicit authorized
  plaintext endpoint/member and the user accepts that boundary;
- foreign popularity/moderation/delivery never becomes Raven authority;
- no Raven-operated federation server is mandatory; and
- unsupported semantics remain visible rather than silently flattened.

### 0.2 Four translation outcomes

Every candidate operation has one outcome:

| Outcome | Meaning |
|---|---|
| `LOSSLESS_EXACT` | Exact foreign bytes and all enabled semantics survive under the frozen adapter |
| `LOSSY_DECLARED` | A permitted projection exists, with exact enumerated semantic/security/privacy loss |
| `UNSUPPORTED` | No approved mapping exists; preserve evidence locally if policy allows, emit nothing |
| `FORBIDDEN` | Mapping would violate audience, consent, identity, trust, loop, secret or downgrade policy |

An implementation MUST NOT silently turn `LOSSY_DECLARED`, `UNSUPPORTED` or
`FORBIDDEN` into success. “Delivered,” “encrypted,” “deleted,” “blocked,”
“verified,” “same author,” and “same room” are network-specific claims and are
never inferred from generic HTTP/WebSocket/relay success.

---

## 1. Goals and non-goals

### 1.1 Goals

| ID | Goal |
|---|---|
| IG1 | Let a user adopt Raven without abandoning selected existing public identities and communities |
| IG2 | Preserve exact foreign evidence and display the real foreign authority separately from Raven authority |
| IG3 | Make every gateway local, self-hostable or replaceable; no mandatory Raven federation operator |
| IG4 | Support bounded public post/profile/reply/reaction import/export before private bridging |
| IG5 | Permit private bridging only with explicit visible endpoint membership and honest E2EE downgrade language |
| IG6 | Prevent loops, amplification, duplicate cross-posts and signature/identity laundering across multiple gateways |
| IG7 | Keep foreign follows, contacts, room membership, moderation, delivery and popularity from mutating Raven authority silently |
| IG8 | Preserve media provenance, audience, consent/use grants, edits/deletes and semantic loss as independent evidence |
| IG9 | Provide deterministic vectors, simulations, crash recovery and physical multi-network conformance before activation |

### 1.2 Non-goals

This revision does not:

- define a universal social object accepted natively by every network;
- claim one globally portable identity across URL-, domain-, homeserver- and
  key-based systems;
- reuse Raven Ed25519/device/ATSAM/MLS keys as ActivityPub HTTP, Matrix, Nostr
  secp256k1 or foreign provider keys;
- make a gateway unable to read plaintext when a foreign protocol requires it;
- promise remote deletion, follow consistency, moderation consistency,
  exactly-once delivery, ordering or availability;
- map all private messages, disappearing messages, reactions, edits, threads,
  mentions, polls, communities, media, receipts or calls in V1;
- enable ActivityPub, Matrix, Nostr or MIMI code; or
- make a current Internet-Draft a frozen production dependency.

---

## 2. Roles and authority boundaries

### 2.1 Roles

| Role | May | Must not |
|---|---|---|
| Raven user/device | Authorize mappings, sign Raven-native objects, revoke gateway device | Impersonate foreign actor without exact foreign proof |
| Foreign actor/account/key | Authorize exact actions under its network | Become Raven identity/contact/capability automatically |
| Gateway endpoint | Validate, project and publish under a bounded grant | Sign projected content as the original foreign author |
| Opaque Raven bridge/carrier | Forward unchanged Raven ciphertext | Parse or translate foreign/Raven application semantics |
| Foreign server/relay/homeserver | Serve/route according to its protocol | Become Raven trust, delivery, moderation or identity authority |
| Local Attention/archive | Retain/show/rank/archive under local policy | Export private graph/behavior or rewrite foreign evidence |

### 2.2 Gateway is an explicit endpoint

A semantic gateway has its own Raven device certificate, capability profile,
revocation state and visible operator/deployment statement. For a private Raven
room it is an explicit MLS leaf/bot if it sees plaintext. For a direct Raven
conversation it is an explicit endpoint participant under a later multi-device/
bot profile. It cannot borrow a user's device credential or hide behind an
opaque Bridge capability.

The UI displays at least:

```text
Origin: ActivityPub / Matrix / Nostr / MIMI / other approved adapter
Foreign actor and authority evidence
Gateway device/operator and where it runs
Who can read plaintext on each side
Translation outcome and semantic losses
Last successful validation/freshness state
```

### 2.3 Replaceability is not invisibility

Users may select:

- local on-device/desktop gateway;
- self-hosted always-on Raven node;
- community-governed gateway endpoint; or
- disclosed third-party operator with narrow revocable authority.

Migration exports public configuration, exact evidence, mapping rules and
watermarks/loop state under the user-owned archive profile. It does not export
live foreign bearer tokens, Raven private keys, ATSAM/MLS state or protected
anti-rollback anchors. A new gateway reauthorizes foreign accounts and Raven
capabilities explicitly.

Foreign identifiers may remain tied to a domain, homeserver, relay/key or hub.
Raven shows that limitation and never labels gateway replacement as foreign-
identity migration unless the foreign protocol itself proves it.

---

## 3. Exact evidence and non-laundering objects

### 3.1 Separate identities

Future wire profiles freeze at least:

```text
foreign_network_profile_id
foreign_authority_id
foreign_object_id                 network-defined identifier, if any
foreign_wire_digest               hash(profile || exact received bytes)
foreign_semantic_digest           optional profile-defined canonical meaning
gateway_observation_digest        Raven signed observation record
projection_digest                 new Raven social/message object identity
transformation_chain_digest       ordered prior hops/projections/losses
```

These are not aliases. A Nostr event ID, ActivityPub object URL, Matrix event
ID, MIMI room/event ID and Raven `social_digest` have different authority and
collision/replaceability semantics.

### 3.2 `RavenForeignObservationV1` semantics

A future public authenticated endpoint record states:

```text
gateway Raven identity/device/cert/revocation binding
foreign network + exact adapter/profile/build digest
foreign source/authority identifier
exact foreign_wire_digest and immutable byte locator/inline bytes
foreign validation result + freshness/evidence snapshot
received/observed window as advisory evidence
requested operation/audience
semantic support/loss vector
transformation lineage and loop token
signature
```

This record means “gateway G observed and validated bytes B under adapter P.”
It does not mean the foreign author signed Raven bytes or endorsed the gateway.

### 3.3 Projection is new authorship evidence

If policy permits a Raven-native projection, the new object visibly attributes:

```text
projected/published by gateway G for user/community policy Q
foreign attributed actor A under foreign evidence E
content derived from exact foreign object B
loss vector L
```

The original author's display name/avatar is quoted foreign metadata, not a
Raven profile. UI never renders the projection as a native Raven signature by
that actor. A foreign actor who separately proves a Raven identity may add a
linked-account assertion, but the projection still retains both authorities.

### 3.4 Exact-byte preservation versus canonical meaning

Adapters preserve exact received bytes whenever the foreign format has an
exact signed representation. JSON/JSON-LD parsers must not reserialize and call
the result original evidence. Where servers legitimately return semantically
equivalent but byte-different representations, the adapter stores:

- exact HTTP/WebSocket payload and relevant authenticated transport metadata;
- exact profile-defined canonical/verification input, if one exists;
- validation/parser build and context/document digests; and
- the immutable projection generated from that evidence.

Remote JSON-LD contexts, linked documents, attachments and referenced objects
are not fetched during pure parse. Approved contexts are pinned or fetched
through a separately bounded SSRF-safe evidence operation.

---

## 4. Linkage, account control and contacts

### 4.1 Linked-account assertion

A linked account is an optional signed relationship, not identity collapse.
The strongest baseline requires both authorities to sign one exact challenge:

```text
Raven continuity/address + current control head
foreign network/profile + exact actor/account/key
gateway-independent random challenge
purpose = DISPLAY_LINK | IMPORT | EXPORT | BIDIRECTIONAL
scope, audience, expiry and revocation handles
```

If the foreign network cannot sign arbitrary challenges, a pinned network-
native proof may publish a nonce/reference and the Raven side countersigns the
exact immutable foreign object. Server-admin statements, DNS, profile text,
matching names, WebFinger lookup, gateway possession of a bearer token or
cross-posted content are not equivalent unless an approved profile says so.

### 4.2 No contact or follow transitivity

- ActivityPub Follow does not create a Raven follow/contact.
- Matrix room co-membership does not create a Raven contact/community member.
- Nostr `p` tags/contact lists do not create Raven graph edges.
- Raven contact/follow/block does not mutate a foreign account automatically.

Users can explicitly create a separate mapping rule after preview. Each action
is journaled and individually revocable. Unlinking removes future gateway
authority; it does not delete historical signed evidence.

### 4.3 Blocks, revocation and compromise

Raven device revocation immediately stops new gateway actions under that
device. Local block immediately stops local import/display/notification and may
stop configured exports. It does not claim a foreign server applied a Block.

Foreign account compromise/revocation is interpreted only through the exact
adapter. A compromised foreign key cannot revoke Raven identity. A compromised
Raven gateway cannot rotate the foreign account or clear foreign evidence.
Authenticated conflicts are retained; “newest timestamp wins” is forbidden.

---

## 5. Semantic support lattice

Every adapter freezes a per-operation table with:

```text
foreign operation/version/kind/type
Raven target operation
authority requirements on both sides
audience mapping
thread/reply/edit/delete/reaction semantics
media/provenance mapping
delivery/receipt mapping
loss vector
reverse mapping and loop behavior
```

### 5.1 Public baseline

The first eligible slice may support only:

- public profile display snapshot;
- public text post/note;
- public reply with one exact parent mapping;
- public reshare/announce with explicit attribution;
- a narrowly defined public reaction subset; and
- public media references only after Sovereign Media Provenance approval.

Private/direct messages, private audiences, groups, polls, live video,
disappearing content, edits/deletes and moderation remain unsupported until
their exact loss/authority profiles pass independently.

### 5.2 Audience monotonicity

A gateway may map only to an equal-or-narrower audience unless the user creates
a new explicit publication intent after a full preview. In particular:

- private/unlisted/followers/room/direct content never becomes Raven public;
- Raven private/MLS content never becomes a public foreign post;
- a foreign server's “unlisted” is not assumed equivalent to Raven private;
- BCC/hidden-recipient information is neither displayed nor leaked;
- unsupported audience semantics yield `UNSUPPORTED` or `FORBIDDEN`.

### 5.3 Edits, deletes and mutable objects

Foreign Update/Edit/Delete/Undo/tombstone semantics become new immutable Raven
evidence referencing the exact prior mapping. They do not rewrite or erase
previous bytes. Raven edits/deletes likewise cannot promise remote erasure.

For replaceable/mutable foreign records, the adapter freezes sequence/order/
conflict rules. Relay/server order or advisory timestamps cannot choose between
authenticated conflicts without protocol authority. Omission is never delete.

### 5.4 Reactions, counts and popularity

Individual verifiable foreign reactions may be imported as attributed evidence
under a later profile. Aggregate counts, “trending,” follower count, relay count
and server rank are untrusted presentation hints. They do not enter Raven
authenticity, contact, moderation, notification or default Attention rank.

### 5.5 Delivery and receipts

| Foreign event | Maximum Raven claim without a stronger profile |
|---|---|
| HTTP 2xx / Matrix transaction accepted / Nostr relay `OK` | Provider/relay accepted bytes |
| Foreign server fanout | Server attempted distribution |
| Gateway stored projection | Local gateway custody |
| Foreign application receipt | Exact foreign receipt evidence only |
| Raven Endpoint ACK | Exact Raven recipient endpoint state only |

A gateway MUST NOT mint Raven Delivered/Read ACKs because a foreign server,
relay, room or gateway accepted data. It may show separately labeled provider
status. Likewise Raven ACKs do not become foreign read receipts automatically.

---

## 6. Network-specific architecture profiles

### 6.1 ActivityPub candidate profile

ActivityPub is a W3C Recommendation with URL-identified actors, inbox/outbox
collections and client-to-server/server-to-server activity delivery. Raven's
candidate adapter is public-first and must freeze:

- ActivityPub/ActivityStreams/JSON-LD versions, approved contexts/extensions;
- actor/object/activity retrieval and authentication/signature mechanisms;
- exact Create/Update/Delete/Follow/Accept/Reject/Like/Announce/Undo subset;
- audience/collection forwarding and shared-inbox behavior;
- dereference/redirect/content/media/context SSRF and recursion limits;
- HTML sanitization, Unicode, attachments and remote-resource policy;
- actor-key rotation, HTTP signature/key ownership and stale cache behavior;
- federation spam, amplification, delivery retry and denial-of-service caps.

Core ActivityPub does not give Raven a universal cryptographic object signature
or portable actor independent of its URL/server. The adapter MUST state exactly
which signature/authentication extension it validates and preserve server/URL
dependence honestly. A local/self-hosted gateway may expose an actor under a
user-controlled domain; a Raven address alone is not an ActivityPub actor URL.

### 6.2 Matrix candidate profile

The Matrix Application Service API allows configured services to observe
events in registered namespaces and inject events into rooms in which they
participate. Registration tokens and namespace regexes are powerful server
capabilities; they are not Raven identity proof.

A Matrix adapter therefore freezes:

- homeserver/server-name, Application Service version/registration/namespace;
- exact room version, event authorization/state-resolution and event IDs;
- application-service identity/device and E2EE support;
- room membership/power level versus Raven governance/capability mapping;
- edits/redactions/reactions/threads/receipts and media repository behavior;
- transaction idempotency, `/sync`/pushing, backfill and historical visibility;
- cross-signing/device trust and encrypted-room key-sharing boundary.

If the gateway reads an encrypted Matrix room, it is an explicit Matrix device
and Raven endpoint/MLS participant as required. The UI says the gateway can
read plaintext. A Matrix homeserver or Application Service token cannot become
Raven community authority, and a Raven MLS room is not “still E2EE end-to-end”
to a foreign room unless every plaintext-capable endpoint is disclosed.

### 6.3 Nostr candidate profile

NIP-01 defines signed secp256k1 events whose IDs hash a specific serialized
array. Raven independently validates exact event ID and Schnorr signature; a
relay is a transport/store and cannot authenticate content beyond that proof.

The adapter freezes a minimal NIP set and exact repository commits because NIPs
are evolving drafts. It must define:

- event/kind/tag canonical parsing, ID recomputation and signature validation;
- relay authentication, query filters, limits, duplicate/conflict behavior;
- regular/replaceable/ephemeral/addressable kinds and tombstone semantics;
- profile/contact/reply/reaction/delete/DM/group NIPs enabled, if any;
- relay-list privacy, metadata exposure and multi-relay union;
- secp256k1 key storage/rotation and explicit non-reuse with Raven keys.

Relay `OK`, event count or widespread replication is not delivery, truth,
identity continuity or popularity authority. A Nostr public key may be portable
across relays but is not the same authority as a Raven continuity ID.

### 6.4 MIMI candidate profile

The IETF MIMI working group is actively drafting provider-to-provider room
interoperability using HTTPS and MLS. The current draft includes provider
servers, a room hub/followers, room policy, message forwarding and an MLS E2EE
context. It is promising for native secure messaging interoperability but is a
work in progress, not a production pin.

Raven MUST NOT call a semantic gateway “MIMI” or “MLS interoperable” until an
exact adopted version, content/room-policy/identifier suite, provider role,
credential mapping, hub/follower authority, discovery, metadata, delivery and
MLS extension profile passes. Raven's host-independent community governance is
not silently replaced by a MIMI hub server. A future native adapter may be
stronger than a plaintext bot bridge, but it remains a separate companion.

---

## 7. Private messaging and community boundary

### 7.1 Explicit plaintext boundary

Private interop is disabled by default. It may be enabled only when all
participants can see:

- gateway identity/operator/location;
- exact Raven and foreign room/account scopes;
- whether gateway, homeserver, relay, hub, bot or cloud can read plaintext;
- what attachments/history/receipts/typing/presence cross;
- retention, moderation, model/tool and archive behavior; and
- how to remove/revoke the gateway.

No protocol can make a plaintext-translating gateway cryptographically blind.
If one side lacks compatible E2EE, the UI says so before add/send. Failure never
falls back from native E2EE to gateway-readable plaintext silently.

### 7.2 Membership and governance

Foreign room membership and Raven community membership are separate state
machines. A mapping rule may request corresponding operations, but each side
must authorize and commit independently. Partial success is visible; rollback
does not resurrect keys or pretend atomic global membership.

A foreign admin/power level/relay owner does not become a Raven steward. A
Raven steward cannot impersonate a foreign room admin. Gateway removal pauses
future translation and rotates/revokes affected keys according to each network;
it cannot erase historical plaintext already received.

### 7.3 Presence, typing and receipts

Presence, typing, read receipts and activity status leak sensitive graph and
timing data. They are off by default and require separate per-room/direction
grants with rate/expiry controls. “Online” is never inferred from relay/server/
gateway connectivity.

---

## 8. Loop prevention and transformation lineage

### 8.1 Stable lineage

Every export/projection binds an ordered transformation lineage containing:

```text
origin network/profile/object identity
each gateway identity + mapping profile + output identity
audience and semantic-loss digest at each hop
```

Before publishing, a gateway checks a protected bounded seen set keyed by the
exact origin plus destination network/account/room and mapping profile. It
stores enough exact evidence to distinguish idempotent replay from same-key/
different-bytes conflict.

### 8.2 No echo amplification

A gateway refuses:

- export back into any origin already represented by the lineage;
- two gateways bouncing projections under new timestamps/IDs;
- quote/reshare/reaction expansion beyond frozen hop/depth/fanout caps;
- stripped lineage presented as original native authorship; and
- a transformation whose lineage exceeds the bounded profile.

Foreign protocols that cannot carry Raven lineage use local protected mapping
records and optional human-visible attribution. Lack of an on-wire extension
does not authorize probabilistic first-match loop suppression or content-hash-
only global dedup.

---

## 9. Media, provenance and consent

Imported media follows
[`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md):

- exact foreign asset and Manifest Store bytes remain separate from Raven
  media-root/publication digests;
- a gateway transcode creates a new asset/provenance chain and discloses loss;
- foreign alt text/captions/content warnings are attributed semantic evidence,
  not trusted executable markup;
- absent Content Credentials are `UNKNOWN`, not fake or ineligible;
- foreign licenses/training preferences/consent statements never widen Raven
  participation/use grants automatically;
- private-room media/provenance never enters a public repository or soft-
  binding service silently.

A gateway cannot claim copyright ownership, consent, safety or truth merely
because foreign metadata, a C2PA claim or a server label exists.

---

## 10. Attention, moderation and discovery

### 10.1 Separate external lane

Imported candidates begin in a bounded `EXTERNAL_INTEROP` Attention lane unless
the exact linked account/repository/community policy grants a narrower trusted
path. Foreign signatures, follower counts, room roles, relay count, boosts,
likes, trending lists or gateway operator do not assign Raven rank or notify.

“Why shown?” identifies the mapping rule, foreign evidence, gateway and local
recipe without making a network request.

### 10.2 Moderation evidence

Foreign blocks, mutes, labels, reports, server suspensions and room moderation
are imported only as attributed network-specific assertions. They do not clear
or create Raven block/revocation, community capability or global truth.

A user may configure a local rule such as “also suppress items this selected
foreign account blocked,” but that is local policy. Exporting a Raven report or
block requires a separate preview and supported foreign action; it never leaks
the Raven contact/follow graph by default.

### 10.3 Discovery and identifier privacy

Foreign account lookup is separate from Raven ID Resolution/Private Discovery.
WebFinger, homeserver directory, Nostr relay query or MIMI directory results are
untrusted candidates and reveal network metadata. The gateway never uploads a
Raven contact list to discover mappings and never scans foreign address books
without an explicit bounded import action.

---

## 11. Secrets, storage, logs and archives

### 11.1 Secret separation

Foreign bearer/access/refresh tokens, Application Service tokens, Nostr private
keys, Matrix device keys and provider credentials use separate platform-
protected namespaces and lifecycle records. They are never derived from Raven
identity/session/archive keys, never stored in public SQL/logs and never sent to
opaque bridges/carriers.

Scopes are least privilege, account/room/direction bounded and visibly
revocable. A third-party gateway's secret custody/privacy policy is displayed
before authorization.

### 11.2 Durable evidence

Durable state includes:

```text
exact mapping authorization and expiry
foreign evidence/validation/profile digests
projection/transformation/loop records
per-side pending operations and independent outcomes
conflict, block, revoke and semantic-loss evidence
resource reservations and GC horizons
```

Public immutable evidence may use approved Raven repositories. Private exact
foreign bytes and mapping state remain encrypted locally/inside the authorized
room. Provider/server caches are not completeness or rollback authority.

### 11.3 User-owned archive

Archive may retain eligible exact public/private evidence and mapping history
under archive encryption, but excludes live bearer tokens, private keys,
sessions, MLS state and protected anchors. Restore is quarantined: it cannot
log in, reconnect a gateway, fetch remote content, publish, follow, join, react,
receipt, notify or register a mapping. Accounts and capabilities are reauthorized
against current block/revocation/policy.

### 11.4 Logging and diagnostics

Production logs omit content, foreign/Raven IDs, room/contact graph, tokens,
URLs with secrets, filesystem paths, exact event IDs, relay sets and mapping
rules. Bounded redacted counters cannot reconstruct user behavior. Debug traces
are explicit local-only features and forbidden in Release.

---

## 12. Admission, parsing and resource safety

Before work, the host reserves finite per-network/account/gateway/lane budgets
for:

- HTTP/WebSocket connections, redirects, DNS/private-network checks and bytes;
- JSON/JSON-LD/CBOR/event depth, keys, strings, arrays, tags and contexts;
- signatures, certificates, keys, state/auth chains and validation CPU;
- inbox/outbox/sync/relay pages, events, backfill, retries and fanout;
- media/attachments/decompression/HTML/Unicode/rendering;
- rooms/members/devices/reactions/threads/mapping/lineage depth;
- durable queue/conflict/seen/tombstone/archive bytes; and
- concurrent gateways, foreign accounts and pending authorization prompts.

Pure parsers have no network, clock, entropy, filesystem, credential or UI
access. Unknown fields/types/kinds are preserved only under an exact bounded
forward-compatibility profile and never executed/rendered as trusted markup.

ActivityPub/JSON-LD remote contexts and URLs, Matrix media/aliases, Nostr relay
URLs and MIMI directories pass strict scheme, DNS rebinding, private/link-local/
loopback, redirect, port, size and content-type policy. User-selected local/
self-hosted endpoints require explicit local-network authorization; SSRF
protection cannot silently make all private addresses globally trusted.

HTML/script/macro/active content is sanitized or rendered as inert text under a
pinned parser/sandbox. Unsupported content emits no network fetch merely by
appearing in a feed or room.

---

## 13. Crash ordering and side effects

Each mapping mutation uses one non-reentrant lease:

```text
verify current user/gateway/foreign authorization
  -> reserve work
  -> stage exact source and deterministic projection/output
  -> protected journal with before/after/output digests
  -> one SQL transaction: mapping/evidence + per-side outbox intent
  -> protected anchor finalize
  -> clear journal
  -> release each network side effect outside lease
```

Foreign and Raven sides commit independently. Crash recovery retries exact
bytes/operation IDs when the foreign profile supports idempotency; otherwise it
records uncertainty and requires reconcile/query or explicit user action.
It never signs a fresh semantically equivalent object under an old intent,
reuses nonce/key/counter, rewrites origin evidence, or marks both sides success
because one side accepted.

If one side succeeds and the other fails, the state is `PARTIAL_VISIBLE`, not
rolled back fiction. Compensating Delete/Undo is a new operation and may fail.

---

## 14. Failure and downgrade matrix

| Event | Required outcome |
|---|---|
| Foreign signature/object ID invalid | Reject before projection/state mutation |
| Foreign evidence valid but actor not linked | Show foreign identity; no Raven impersonation/contact |
| Gateway signature valid | Authenticates gateway observation only |
| Unsupported audience/type/room semantic | `UNSUPPORTED`; emit nothing |
| Mapping widens audience | `FORBIDDEN` absent a new explicit publication intent |
| Foreign server/relay accepts | Provider acceptance only; no Raven Delivered/Read |
| Gateway sees private plaintext | Visible endpoint/member downgrade; otherwise refuse |
| E2EE capability missing | No silent plaintext fallback |
| Edit/Delete/Undo arrives | New immutable evidence; no historical rewrite/erasure promise |
| Same foreign ID, conflicting authenticated bytes | Retain/quarantine conflict; no timestamp winner |
| Gateway revoked/blocked/unlinked | Stop new actions; retain safety/history; rotate/remove per side |
| Foreign account compromised | Stop/freshness warning under adapter; no Raven identity revoke |
| Loop/echo detected | Idempotent drop or conflict quarantine; no new projection |
| Lineage stripped | Refuse native-author claim; bounded unattributed candidate at most |
| Transcode strips provenance | New derived asset + explicit provenance loss |
| Remote context/media URL is private/oversize/recursive | SSRF/cap refusal; no partial render |
| One side succeeds, one fails | `PARTIAL_VISIBLE`; exact retry/reconcile, no fake atomicity |
| Crash before journal | No external output; candidate discarded |
| Crash after durable intent | Roll forward exact operation or record uncertainty |
| Gateway unavailable | Raven-native data remains usable; no mandatory operator |
| Adapter version changes | Old evidence remains under old profile; migration is explicit |

---

## 15. Required vectors, simulation and physical gates

### 15.1 Shared vectors

Python, Rust and Swift independently compute/verify:

- foreign-wire, observation, projection, transformation and loop digests;
- strict adapter parsing and foreign signature/ID verification;
- dual-authority linked-account challenge and unlink/revoke negatives;
- public post/reply/reshare/reaction semantic support/loss tables;
- audience monotonicity and private-to-public refusal;
- edit/delete/replaceable/conflict/timestamp behavior;
- no signature laundering and separate UI attribution;
- provider acceptance versus endpoint delivery/receipt lattice;
- media/provenance/transcode/alt-text/content-warning mapping;
- loop/echo/dual-gateway/lineage-strip/id-collision matrix;
- crash/partial-success/retry/reconcile ordering; and
- parser/SSRF/HTML/Unicode/context/media/decompression/cap negatives.

Each network uses official conformance tests/corpora and at least one
independent implementation where available. JSON fixture comparison alone is
not compute parity.

### 15.2 Deterministic 1,000-node simulation

The model includes Raven-only users, local/self-hosted/cloud gateways, multiple
ActivityPub servers, Matrix homeservers/rooms, Nostr relays, candidate MIMI
providers, partitions, malicious relays/servers/gateways, key compromise,
deletes, loops and floods. It proves:

- no gateway becomes Raven identity/graph/governance authority;
- no loop amplification or timestamp re-origin storm;
- one unavailable operator cannot disable Raven-native use;
- foreign popularity does not dominate local Attention;
- private audience/room data never enters public projections;
- provider acceptance never fabricates endpoint receipt;
- weak external floods cannot evict contacts/revocation/identity/session/
  protected-anchor evidence; and
- archive/restore and migration create no network side effects.

Simulation is model evidence, not live federation proof.

### 15.3 Physical/process matrix

| Row | Required evidence |
|---|---|
| Raven iPhone ↔ two independent ActivityPub implementations | Public post/reply/reshare, media, edit/delete, server move/failure |
| Raven Terminal ↔ Matrix reference homeserver/client | Public baseline; explicit encrypted-room gateway plaintext boundary |
| Raven iPhone/Terminal ↔ two Nostr clients + three relays | Signature/ID, replaceable/delete, relay disagreement/offline union |
| Local gateway ↔ self-hosted gateway migration | Raven identity/graph unchanged; foreign limitation disclosed |
| Two gateways configured for same pair | No echo/duplicate/amplification; conflict evidence retained |
| Private room bridge | Explicit participant/device, removal/rekey, no hidden plaintext endpoint |
| Media transcode/strip | New provenance chain and visible loss |
| Block/revoke/unlink | New actions stop; historical evidence retained; no remote overclaim |
| Crash at every durable/network boundary | Exact retry or visible uncertainty; no double authorship/receipt |
| Malicious corpus/network | SSRF/parser/render/decompression/resource isolation |

Simulator, mock servers, one local implementation or source inspection cannot
close a physical interoperability claim.

---

## 16. Production holds

Production remains disabled until:

1. the umbrella registers/re-approves foreign evidence, observations,
   projections, linkage and transformation byte classes;
2. each enabled adapter pins exact standard/NIP/draft versions, extensions,
   libraries, signatures, trust, parser, storage and compatibility policy;
3. no Raven/foreign key-domain reuse, identity collapse or signature laundering
   exists;
4. the public semantic-support/loss lattice passes three-language and
   independent-implementation vectors;
5. private interop proves visible gateway membership/plaintext boundaries and
   no E2EE downgrade fallback;
6. follows, contacts, blocks, moderation, governance, delivery, receipts and
   Attention remain non-transitive unless explicitly authorized;
7. loop/lineage/dual-gateway/conflict/idempotency and crash/partial-success
   matrices have no open P0/P1;
8. secrets use platform-protected stores and no credential/content/graph/path
   leaks through logs, archives, opaque bridges or provider diagnostics;
9. parser/SSRF/remote-context/HTML/media/decompression/resource adversarial
   suites pass every supported platform;
10. no mandatory Raven gateway, domain, homeserver, relay, MIMI provider,
    identity service or cloud operator is required;
11. 1,000-node and full physical multi-implementation matrices pass; and
12. independent protocol, cryptography, federation, privacy, abuse, accessibility
    and systems review—or explicit protocol-owner waiver—records no unresolved
    production blocker.

No lab feature may auto-create foreign actors/accounts, import credentials,
join rooms, publish, follow, send messages, fetch contexts/media, register an
Application Service, contact relays/providers or enable a Release path.

---

## 17. Primary research foundations (informative only)

- [W3C ActivityPub Recommendation](https://www.w3.org/TR/activitypub/) —
  client/server and server/server decentralized social protocol with URL actors,
  inbox/outbox, activities and explicit SSRF, recursive-object, spam,
  federation-DoS and content-sanitization considerations.
- [Matrix Application Service API](https://spec.matrix.org/latest/application-service-api/)
  — configured namespaces, event observation/injection and powerful bridge
  tokens/device operations; an Application Service is an explicit trusted
  homeserver integration, not an opaque carrier.
- [Nostr NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) —
  secp256k1-signed event ID/serialization, event kinds/tags and relay flow;
  NIPs are evolving and require exact commit/profile pins.
- [IETF MIMI architecture work](https://datatracker.ietf.org/doc/draft-ietf-mimi-arch/)
  and [MIMI HTTPS+MLS protocol](https://datatracker.ietf.org/doc/draft-ietf-mimi-protocol/)
  — active work on provider-to-provider rooms, policy, forwarding and MLS E2EE;
  still Internet-Drafts rather than frozen Raven production dependencies.
- [RFC 9420 — Messaging Layer Security](https://www.rfc-editor.org/rfc/rfc9420.html)
  — E2EE group epochs/member authentication; it does not make a plaintext
  semantic gateway invisible or unify application authorization.
- [RFC 7033 — WebFinger](https://www.rfc-editor.org/rfc/rfc7033.html) —
  account-resource discovery; lookup results are candidates, not Raven identity
  authority.

These sources do not define Raven identity, contacts, social graph, Attention,
archive, consent, gateway authorization or wire bytes.

---

## 18. Open decisions before vector freeze

1. First adapter and exact public operation subset; recommended ActivityPub
   public text profile before any private gateway.
2. Exact ActivityPub authentication/signature, JSON-LD context and extension
   profile beyond the W3C core.
3. Foreign exact-byte/canonical-evidence container and HTTP/WebSocket metadata.
4. Linked-account challenge wire and foreign proof mechanisms per network.
5. Gateway observation/projection/transformation/loop record wires.
6. Audience/support/loss taxonomy shared versus adapter-specific fields.
7. ActivityPub actor hosting/domain migration and user-selected gateway model.
8. Matrix Application Service registration/device/E2EE/room-version subset.
9. Nostr NIP set/commit, key custody, relay union and replaceable/delete rules.
10. MIMI version/adoption checkpoint and whether Raven is client/provider/hub/
    follower under a future native adapter.
11. Private-message/room mapping or explicit prohibition in V1.
12. Exact receipt/provider status UI vocabulary and accessibility.
13. Secret namespaces/scopes, operator manifest and gateway migration archive.
14. Remote context/media/HTML sandbox and network policy on each platform.
15. Media provenance/transcode/alt-text/content-warning adapter profiles.
16. Physical reference implementations, test accounts and reproducible CI.

---

## 19. Revision history

| Revision | Date | Change |
|---:|---|---|
| 1 | 2026-08-21 | Initial sovereign-interoperability architecture: separates opaque Raven carrier bridges from semantic endpoint gateways; freezes non-laundering evidence/projection principles, six authority planes, support/loss lattice, replaceable gateway model, linked-account non-collapse, public-first baseline, audience monotonicity, delivery/receipt separation, ActivityPub/Matrix/Nostr/MIMI boundaries, explicit private plaintext membership, loop lineage, media provenance, local Attention/moderation, protected secrets, archive/crash/resource/failure/vector/simulation/physical production holds. |
