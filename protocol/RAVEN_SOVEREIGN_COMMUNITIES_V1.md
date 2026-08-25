# RAVEN Sovereign Communities V1

**Version:** 1

**Document revision:** 3

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no community/group codec, MLS library, cipher suite, KeyPackage publication, governance event, invitation, membership change, group send/receive, realtime live room, bot, discovery surface, database migration, carrier activation, live callsite, legacy migration, or Release flag

**Depends on:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md), [`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md), [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md), [`RAVEN_ID_RESOLUTION_V1.md`](RAVEN_ID_RESOLUTION_V1.md), [`RAVEN_OBJECT_SYNC_V1.md`](RAVEN_OBJECT_SYNC_V1.md), [`RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md`](RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md), [`RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md`](RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md), [`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md), [`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md), [`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md) for media attachments/recordings, RFC 9420 MLS and RFC 9750 MLS Architecture through a later pinned implementation profile

**Unblocks when APPROVED:** host-independent communities; private MLS rooms; cryptographically inspectable governance; provider/carrier migration without changing community identity; bounded offline/mesh delivery; explicit history sharing; role/capability-based moderation; fresh-device rejoin after identity recovery

> A Raven community is not an account on a server. Its identity, policy, membership authority, encryption state, delivery paths, archives, and attention policy are separate. A relay may carry the community; it never owns it.

---

## 0. Core decision and constitutional invariants

Raven communities have five non-interchangeable planes:

```text
Community identity + governance DAG     who may do what
               |
Room authorization state               who should be a participant
               |
MLS group instance + linear epochs      who can decrypt now
               |
Endpoint objects + Raven carriers       how exact bytes move
               |
Local attention/archive policy          what this device shows or retains
```

The following are constitutional:

1. **Stable community identity is independent of hosting.** Moving among direct LAN, mesh, relay, mailbox, public mirror, self-hosted node, or commercial object storage never changes `community_id`.
2. **Governance is not a server database.** Every authority-changing action is an exact signed/capability-proven event verified by members. A domain, relay, push service, app-store account, DNS record, or database row cannot grant membership or admin power.
3. **Private multi-party encryption uses reviewed MLS, not Raven-authored group crypto.** Existing per-group AES keys, DM ratchets, or one shared “group key” cannot be relabeled as this profile.
4. **MLS is not governance or consensus.** MLS establishes epoch secrets and authenticates members; Raven separately defines policy, authorization, commit sequencing, fork handling, durability, and carriers.
5. **Every MLS client is one device, not one user.** User-level participation and device-level MLS membership are explicitly synchronized and verified.
6. **One private room has one active MLS lineage.** Public feeds use Public Repository Sync; private rooms use MLS. They never share a privacy partition or key merely because the UI places them under one community.
7. **Membership and MLS state change atomically.** An Add/Remove/Ban/role-sensitive change is not active until the exact authorized control event and corresponding MLS transition are durably aligned.
8. **No application data on misaligned state.** If governance head, participant set, MLS instance, or epoch is unresolved, private sending pauses rather than leaking to a removed member or accepting an unauthorized device.
9. **No secret-state rollback.** Concurrent/conflicting MLS Commits do not cause ratchet-tree rollback or key reuse. The active room pauses; a separately authorized successor MLS instance resolves the fork.
10. **Carriers preserve exact bytes and remain replaceable.** No carrier chooses a canonical Commit, edits membership, interprets community roles, creates read receipts, or becomes required for authenticity.
11. **Admins govern scoped actions; they do not gain retrospective plaintext.** Granting a role does not reveal prior epochs/history. Removing an admin does not erase what that member already received.
12. **Private history sharing is explicit and separately authorized.** A Welcome or new membership does not automatically grant old messages.
13. **Local block and attention remain local powers.** Community governance cannot force display, notifications, media fetch, read receipts, or unblock a user on a recipient device.
14. **No token, blockchain, stake, proof-of-work, phone number, legal identity, mandatory server, or global moderator is required.**
15. **Production remains disabled** until exact MLS/profile bytes, governance wires, durability, three-language vectors, carrier conformance, simulations, independent review, and physical matrices pass.

---

## 1. Goals, non-goals, and product distinction

### 1.1 Goals

1. Private communities and group chats whose authority and identity survive provider failure or migration.
2. Scalable continuous group key agreement with forward secrecy and post-compromise recovery properties defined by the selected MLS profile.
3. Verifiable, attenuated governance instead of an opaque global `admin` boolean.
4. Honest multi-device membership tied to exact Raven identity/device/cert/revocation evidence.
5. Operation over LAN, Internet direct, relay, mailbox, mesh store-carry-forward, local file/QR, or future approved carriers without changing endpoint semantics.
6. Safe offline work: application messages may reorder within an epoch; governance/MLS transitions remain serialized and fail closed.
7. Public lobbies plus private rooms without leaking private content into public replication.
8. Explicit bot/bridge membership and least-authority roles rather than invisible server plaintext access.
9. Inspectable moderation provenance and local attention control.
10. Portable historical data through the User-Owned Archive without exporting MLS secrets.

### 1.2 Non-goals

V1 does not provide or authorize:

- a custom Raven group ratchet, Sender Keys clone, shared static AES group key, or DM-session fanout claimed as MLS;
- silent compatibility with the existing server-backed Raven group path;
- universal total-order messaging or instant consensus under partition;
- automatic winner selection for conflicting valid governance/MLS successors;
- guaranteed availability when the authorized commit coordinator or governance quorum is offline;
- metadata-hiding against all carriers, timing observers, member devices, or colluding endpoints;
- retroactive revocation of plaintext already decrypted by a former member;
- automatic history disclosure to a new member/device;
- a global community directory, follower/member graph, moderator, reputation score, or ban list;
- a permanent bearer invite link for private membership;
- anonymous administration, personhood, age, geography, or organization-membership claims without a separately approved credential profile;
- hidden bots, server-side plaintext search/moderation, or cloud AI with undeclared room membership;
- public/private room key reuse, public content encrypted once for “members,” or private content replicated as public social records;
- restoring MLS state from a backup/archive;
- treating transport delivery, server fanout, push notification, or read receipt as membership proof;
- claiming MLS alone prevents withholding, fork, traffic analysis, or denial of service.

### 1.3 Why this is different

Conventional group products usually bind at least three powers to one operator: the namespace, membership database, and delivery service. Raven binds none of them to a provider. A member can verify why a device is present, which exact policy authorized an action, which MLS epoch protects a message, and which carrier merely delivered it.

This permits a community to change hosting, use several carriers at once, operate locally during an outage, preserve public content in user-selected mirrors, and keep private rooms encrypted without turning one Raven service into the institution that owns the community.

---

## 2. Threat model and unavoidable limits

### 2.1 Adversaries

The design considers:

- a malicious/compromised delivery service, relay, mailbox, mirror, push provider, DNS host, or community node;
- a compromised founder, steward, moderator, ordinary member, bot, bridge, or old member;
- compromised/lost/revoked member devices and stale KeyPackages;
- a malicious inviter substituting role, room, policy, history, or device bindings;
- concurrent valid membership/policy/MLS changes during partitions;
- selective delivery of Commit/Proposal/Welcome/application messages to fork members;
- replay, suppression, reordering, duplication, equivocation, sequence gaps, epoch rollback, and stale GroupInfo;
- Sybil joins, invite theft, join floods, media bombs, ACK storms, and bot amplification;
- a coordinator who disappears, censors proposals, signs two successors, or attempts self-escalation;
- traffic analysis of group IDs, epochs, ciphertext lengths, delivery fanout, mailbox polling, and timing;
- local state corruption, rollback, capacity exhaustion, crash windows, and archive restore;
- two legitimate governance quorums authorizing conflicting successors.

### 2.2 Honest security limits

- A current member can read plaintext delivered in epochs in which its device is a member and can copy it outside Raven.
- Removal protects future epochs only after a valid Remove Commit is applied. Therefore Raven pauses application sending between an authoritative removal and aligned MLS rekey.
- MLS headers and delivery behavior can reveal group/epoch/message-frequency information depending on the Delivery Service profile.
- A malicious carrier can withhold or partition. Cryptography proves received bytes, not missing bytes.
- If the governance threshold colludes, it can perform every action granted to that threshold. UI must show controller concentration.
- No partitioned node can prove it has the globally latest policy or Commit without additional evidence. Protected pins and multi-path comparison detect some rollback/forks, not universal freshness.
- A removed member cannot decrypt future compliant epochs, but Raven cannot erase prior plaintext, screenshots, exports, archives, or malicious device copies.
- A room fork may require explicit repair and fresh MLS state; availability is sacrificed rather than rolling back secret state.

---

## 3. Community, room, and MLS identities

### 3.1 Community genesis

A later wire companion freezes a canonical `RavenCommunityGenesisV1` containing at least:

```text
profile/version
genesis_nonce[32]                       # nonzero CSPRNG
founder RavenAddress/continuity authority
founder control-head evidence
initial governance-policy core digest
initial steward-set commitment
initial privacy partitions
created_at_ms                           # advisory only
community_id
founder authorization
```

`community_id` is a domain-separated digest of the canonical genesis core and random nonce. It excludes mutable name, avatar, topic, provider URL, relay, mailbox, DNS name, member list, MLS group ID, and human handle. A different governance genesis creates a different community.

For Identity V1, founder authority remains key-bound. For Continuity V2, it binds stable `continuity_id` plus exact genesis/current control evidence. Key rotation does not change `community_id`; authority acceptance follows the greatest verified continuity state.

### 3.2 Room identity

Every room has a random stable `room_id` bound to `(community_id, room_genesis_nonce, privacy_class, room_policy_digest)`. Mutable title/avatar/topic do not enter the ID. A community may contain:

| Room class | Distribution |
|---|---|
| `PUBLIC_FEED` | Exact public social/repository records; no MLS confidentiality claim |
| `MEMBER_PRIVATE` | MLS; every active participant device may read |
| `ROLE_PRIVATE` | Separate MLS instance limited to authorized role participants |
| `EPHEMERAL_PRIVATE` | Separate MLS instance with bounded lifetime/retention |
| `LOCAL_DRAFT` | Device-local only; no group/distribution authority |

Changing privacy class creates a new room. Public→private or private→public never reinterprets old bytes or keys.

### 3.3 MLS instance identity

A persistent private room may have several sequential MLS **instances** over its lifetime:

```text
community_id (stable)
  -> room_id (stable)
       -> mls_instance_id_1 (epochs 0..N)
       -> successor mls_instance_id_2 (epochs 0..M)
```

`mls_instance_id` is random/opaque and binds exact room/control genesis plus a successor nonce. An instance successor is required after terminal fork, incompatible profile migration, catastrophic state loss, or cryptographic-suite migration. It never reuses an epoch secret, ratchet tree, KeyPackage, Welcome, GroupInfo, generation counter, or application nonce from the predecessor.

Room identity continuity across instances is governance evidence, not key continuity. Members unable to verify the exact successor event remain on the old historical room state and cannot silently follow a provider pointer.

---

## 4. Four authoritative planes, not one

### 4.1 Governance control plane

Governance answers: who may create rooms, invite/remove/ban participants, appoint/retire roles, approve history sharing, add bots, change policy, coordinate MLS transitions, or resolve a fork?

It uses canonical signed events and attenuated capability proof chains. It does not encrypt room application data.

### 4.2 MLS cryptographic plane

MLS answers: which exact device clients share the current epoch secret and can authenticate/decrypt current private room messages?

It does not decide whether a Raven identity is a moderator, whether an invite is socially authorized, whether a provider is canonical, or which concurrent Commit the community accepts.

### 4.3 Endpoint/carrier plane

Raven endpoint objects bind exact MLS/control bytes, object IDs, route-independent replay identity, and durable commit semantics. Carriers perform bounded delivery/custody only. LAN, relay, mailbox, and mesh copies of the same endpoint object deduplicate by exact object digest.

An implementation that lets a delivery server edit MLS bytes, synthesize governance, choose role state, or convert a private room into server fanout plaintext is non-conformant.

### 4.4 Realtime media plane

Realtime voice/video is not an MLS application message or ordinary Raven
carrier payload. Once
[`RAVEN_PRIVATE_REALTIME_MEDIA_V1.md`](RAVEN_PRIVATE_REALTIME_MEDIA_V1.md) is
APPROVED, this document supplies exact room/device membership, governance,
policy and MLS epoch authority for a live room. The realtime companion alone
defines call-control records, ICE/TURN/SFU topology, DTLS-SRTP, SFrame framing,
media counters and capture/recording gates.

An MLS member is not automatically in a live room, permitted to ring devices,
or authorized to start camera/microphone capture. Conversely, SFU admission,
active-speaker selection, media forwarding or a valid transport connection
cannot add a community member, advance MLS, grant a role, or decide governance.
If an SFU terminates DTLS-SRTP, private-room payload confidentiality additionally
requires the exact approved SFrame/MLS-exporter profile; server-readable media
is never a silent fallback.

---

## 5. Governance model

### 5.1 Policy and roles

The genesis policy defines named roles as explicit allow-listed capabilities, never one unbounded numeric “power level.” Baseline abilities include:

```text
community/describe
room/create
room/describe
room/send
member/invite
member/approve
member/remove
member/ban
role/grant
role/retire
policy/propose
policy/approve
mls/propose
mls/commit
mls/coordinator-replace
fork/resolve
history/share
bot/add
bot/remove
mirror/announce-public
```

Every delegation binds exact community/room resource, subject identity/device or role, ability subset, validity ceiling, parent proof digest, policy generation, and delegation nonce. Delegation can only narrow authority. V1 has no wildcard/top capability in normal UI or wire acceptance.

### 5.2 Critical thresholds

The policy declares an explicit steward set and M-of-N threshold for critical operations. At least these are critical:

- changing role definitions or critical thresholds;
- granting/retiring steward authority;
- changing a room privacy/history/bot policy;
- replacing the MLS commit coordinator outside ordinary rotation;
- resolving control/MLS forks;
- authorizing an MLS instance successor;
- transferring/deactivating community ownership/continuity.

Small communities MAY select 1-of-1, but UI permanently labels them `SINGLE_CONTROLLER` and explains that one key can capture/delete/reconfigure future governance. Raven never markets that policy as decentralized control.

### 5.3 Control chain and conflicts

Authority-changing events bind:

```text
community_id
control_generation_u64
exact previous control-head digest/set
policy digest
action core
proposal nonce
canonical authorization block
```

Routine serialized mutations increment exactly by one. Exact replay is idempotent. Same generation/slot with different exact valid bytes is authenticated control conflict. Raven does not choose by arrival time, provider, signature count above threshold, digest order, or popularity.

Non-authority content remains a causal DAG and can merge. Conflicting authority successors enter `CONTROL_FORK`, block affected private-room mutations/sends, and require an explicit threshold `ForkResolution` referencing the full bounded conflict set and the exact successor state. If no quorum is available, the community remains safely paused or members create a visibly new community; no server override exists.

### 5.4 Coordinator is a scoped capability

Each private room/control generation authorizes exactly one current device capability for `mls/commit` at a given Commit slot. That coordinator:

- can package already authorized proposals into one MLS Commit;
- cannot invent membership/role/policy changes;
- cannot grant itself capabilities;
- cannot select a stale control head;
- cannot produce two valid different Commits for one slot without terminal equivocation evidence;
- is replaceable by the policy's explicit failover rule/quorum.

This is not a permanent server or owner. Policies SHOULD rotate the coordinator among eligible steward/member devices. A coordinator outage pauses epoch changes but MAY allow application messages in the already aligned epoch when no pending removal/security barrier exists.

---

## 6. User membership versus device membership

### 6.1 Participant state

Community participation is identity-level:

```text
participant RavenAddress/continuity_id
current continuity/control evidence
role set
join generation
status: invited | active | leaving | removed | banned
active device-client set
```

MLS membership is client/device-level. Each LeafNode credential binds at least:

```text
community_id / room_id / mls_instance_id
Raven identity or continuity ID
identity generation/control head
device_id
device certificate digest
device Ed public key
MLS KeyPackage/LeafNode public material
capability/profile set
credential validity ceiling
```

Raven's Authentication Service is local verification of exact identity, device certificate, DeviceSet/continuity, contact/community admission, and sticky revocation evidence. A provider assertion or TLS certificate cannot replace it.

### 6.2 Device add

Adding a user and adding another device for an existing user are different authorized actions. Every new device supplies a fresh bounded one-use KeyPackage whose credential passes current identity/device/revocation checks. A participant cannot silently add an unlimited device merely because one device is already a member; room policy defines who approves additional devices and an explicit cap.

Stale/replayed/claimed KeyPackages, same package under different device identity, unsupported suites/extensions, expired certs, or all-zero/invalid keys reject before MLS mutation. Successful claim is atomic and never reused across groups where the selected MLS profile forbids it.

### 6.3 User removal and device revocation

A user-level Remove/Ban enumerates and removes every currently admitted device leaf for that participant in the same aligned membership transition. During the interval after the removal control action is verified but before the Remove Commit is active, the room enters `REKEY_REQUIRED` and sends no new application plaintext.

A sticky Device Revocation immediately makes that leaf ineligible for new processing. The room schedules an authorized removal Commit and pauses according to risk policy. Omitting a device from a source response is never a revoke.

Identity Continuity V2 recovery retires prior device lineages. The stable participant may remain authorized at identity level if room policy permits, but every old MLS leaf becomes ineligible and a fresh recovered device joins through a new authorized transition. No MLS state is recovered from the identity ceremony.

---

## 7. MLS profile and state alignment

### 7.1 Exact profile required later

A byte/crypto companion must freeze:

- MLS protocol version and cipher suite;
- credential type and Raven credential binding;
- required extensions, capabilities, proposal types, and external-sender policy;
- KeyPackage lifetime/claim/destruction rules;
- GroupContext extensions for exact Raven room/control binding;
- private versus public handshake-message policy;
- application AAD/content framing;
- GroupInfo, Welcome, ratchet-tree distribution, external join, resumption, reinit, exporter, and padding rules;
- library, version/commit, platform bindings, test vectors, and supply-chain evidence.

No code may assume defaults or accept an unpinned suite. MLS exports MUST NOT be used as ATSAM DM/session/archive keys.

### 7.2 Alignment invariant

The only sendable private-room state is:

```text
ACTIVE_ALIGNED(
  community_control_head,
  room_policy_digest,
  participant_set_digest,
  mls_instance_id,
  mls_epoch,
  mls_epoch_authenticator,
  coordinator_slot
)
```

Every authoritative membership/policy Commit cryptographically binds the exact control action digest and resulting participant-set digest through the selected MLS extension/AAD/profile. Every recipient recomputes both before promoting the MLS candidate.

MLS success with governance mismatch, or governance success without exact MLS transition, is not partial success. It is retained pending evidence or terminal conflict; application output stays blocked.

The binding is deliberately non-circular:

1. a canonical authorized `CommunityControlAction` commits to the desired state transition, exact previous heads, MLS instance/epoch/slot, and resulting participant/policy intent, but not to a yet-unconstructed Commit digest;
2. the exact MLS Commit binds the control-action/action-set digest in the approved MLS extension/AAD;
3. after candidate processing, a canonical `RoomEpochAlignmentReceipt` binds `(control_action_digest, exact_mls_commit_digest, resulting_control_head, resulting_participant_set_digest, resulting_mls_epoch, epoch_authenticator)` and is authenticated by the coordinator device;
4. the joint durable transition installs the action, MLS state, and receipt together.

The receipt adds no new governance authority and cannot widen the authorized action. A different Commit, action, result, coordinator, instance, or epoch requires different evidence and cannot transplant.

### 7.3 Atomic control + MLS transition

The mutation order is:

```text
trust/revocation/capability admission
  -> exact control-event candidate
  -> exact MLS candidate (Proposal/Commit/Welcome effects)
  -> verify resulting participant/tree/context binding
  -> construct exact RoomEpochAlignmentReceipt
  -> persist protected joint journal with exact before/after/output bytes
  -> commit public indexes/inbox/outbox/control metadata + receipt
  -> finalize protected governance + MLS heads
  -> clear journal
  -> release exact endpoint outputs to carriers
```

Network I/O is outside the mutation lease. Crash recovery always rolls forward idempotently. It never rolls back an MLS epoch, reuses a secret/nonce, or releases Welcome/Commit/application bytes before the matching durable state exists.

### 7.4 Concurrent Commits and forks

RFC 9420 requires the application to resolve competing Commits for one epoch. Raven's baseline prevents ordinary competition through the exact coordinator slot. If different valid Commits for one slot/epoch appear, coordinator equivocation or control conflict is proven.

Raven then:

1. retains bounded exact conflict evidence;
2. stops application send and affected membership mutations;
3. does not roll an already promoted secret state backward;
4. does not continue independently on a hidden “winning” branch;
5. uses threshold `ForkResolution` to choose an exact participant/policy state and create a **fresh successor MLS instance**;
6. gives Welcome/new state only to the resolved participant devices;
7. marks the predecessor terminal and zeroizes obsolete secrets after the bounded evidence/recovery procedure.

This costs availability but avoids indefinite split-brain rooms, provider-selected history, secret reuse, or weak tie-breaking masquerading as consensus.

### 7.5 Stale and future epochs

Application messages may arrive out of order within the configured MLS generation window. Duplicate exact bytes are idempotent. Replay/tamper/authentication failure does not advance state. Handshake messages follow exact epoch/slot ordering. Unknown future epochs trigger bounded dependency retrieval, not blind state skipping. Old epochs beyond the frozen window are refused and never resurrected from archives.

---

## 8. Invitations, joins, leaves, and history

### 8.1 Private invitation capability

A private invite is recipient-bound and contains/commits to:

```text
community_id / room_id
current control head and policy
inviter identity/device/capability proof
invitee identity/continuity commitment
maximum initial role
history policy (default none)
one-shot invite nonce
not-before/not-after ceilings
required MLS profile/capabilities
optional transport hints (non-authoritative)
```

Copying the invite to another identity/device, widening its role, replaying after acceptance/revoke/expiry, or substituting a stale room/control head rejects. Accepting an invite does not create a DM contact unless the user separately chooses it.

### 8.2 Public/open joins

A public community descriptor may advertise a public lobby and an **admission policy**, not private membership or a reusable Welcome. MLS External Join is allowed only in a later exact profile when the governance policy explicitly authorizes it, the GroupInfo is fresh/exact, identity/device/anti-spam admission succeeds, and the resulting external Commit passes the same control/MLS atomic transition.

Generic links may open a public preview or a bounded join request. They are never permanent bearer admin/member credentials. Private room membership requires an exact accepted capability/control transition.

### 8.3 Leave/remove/ban

Self-leave, removal, and ban are separate events. Ban carries a bounded explicit subject/room/community scope and blocks re-admission until an authorized unban event; omission or invite replay cannot clear it. Local block is independent and may remain after community unban.

Application send pauses across any pending removal until aligned MLS rekey. A former member retains past plaintext/epochs already possessed but receives no new Welcome or future epoch secret.

### 8.4 History sharing

New members/devices receive no history by default. A `HistoryGrant` is a separate authorized operation binding exact room, recipient identity/device, bounded message/snapshot range, provenance policy, retention/expiry, and grantor capability.

The `HistoryGrant` itself may be announced as an MLS application object to bind group authorization. The historical package is then freshly sealed **per admitted recipient device** through an approved current direct ATSAM session or a separately reviewed device-bound HPKE profile; the shared MLS room key is not used for selective one-recipient confidentiality. Raven never sends old MLS epoch secrets, ratchet trees, sender secrets, replay state, ACK state, or protected heads. Imported history is marked historical and cannot emit receipts or enter send queues.

“Automatically share all history” is forbidden in baseline private rooms. A future policy may permit bounded automatic history only after explicit UI/security review and exact vector freeze.

---

## 9. Private application objects and receipts

### 9.1 Application framing

A later wire companion freezes a canonical private-room application object inside MLS `PrivateMessage` containing at least:

```text
community_id / room_id / mls_instance_id
control_head_digest / policy_digest
sender Raven identity + device credential digest
message_id[16 or 32]
content class + exact body/attachment references
reply/thread references
advisory created_at_ms
expiry/disappearing policy
receipt policy
schema/capability bits
```

The exact MLS ciphertext object is wrapped as immutable Raven `endpoint_object_bytes`; `object_digest = SHA-256(exact endpoint bytes)`. Carrier wrappers/hops never enter the endpoint identity. Same exact object delivered through several paths deduplicates once.

### 9.2 Durable receive

The receiver processes:

```text
current contact/community/device/revocation/control admission
  -> endpoint/object replay preflight
  -> MLS candidate decrypt/authenticate
  -> inner sender/room/control/epoch/schema checks
  -> one SQL transaction: receipt + inbox + replay + receipt-intent
  -> protected MLS head finalize
  -> journal clear
  -> only then UI/receipt work
```

Tamper, wrong room/sender/device/control head, removed membership, stale/future epoch beyond policy, replay conflict, oversize, or durable failure produces no inbox row, receipt, notification, or MLS head advance.

### 9.3 Custody, delivery, and read evidence

Carrier custody is not member delivery. Group delivery/read receipts are optional room-policy application messages, not MLS/transport side effects.

Baseline private-room policy:

- read receipts default `FORBIDDEN`;
- delivery receipts default `OPTIONAL_LOCAL_USER_CHOICE` for small rooms and `FORBIDDEN` above a frozen threshold;
- receipts are encrypted inside MLS and bind exact acknowledged object digest, sender device, status, nonce, and epoch;
- devices batch/bound receipts to prevent ACK storms and attention leakage;
- no provider generates or aggregates authoritative receipts;
- a sender UI distinguishes `queued`, `carrier custody`, `delivered by N devices`, `read by consenting members`, and `unknown`.

The room cannot force a local user to disclose reading behavior merely by policy. A policy marked “required read receipts” is non-conformant in V1.

### 9.4 Attachments

Attachments are independently padded/encrypted with per-object keys derived/exported through the approved MLS application profile, stored as opaque bounded chunks, and referenced from the authenticated application object. The storage provider sees only the adapter's documented metadata. Removal from MLS does not erase already obtained attachment keys/plaintext.

Remote URLs, previews, codecs, and decompression remain inert until local resource/attention policy admits them. No server-side transcoding receives plaintext by default.

---

## 10. Public/private community composition

A sovereign community may combine:

```text
public descriptor + public feed/repositories
  + private member room(s)
  + role-private steward/moderator room
  + local attention recipes/labels
```

These are separate audience partitions:

- Public records use Social Graph/Public Repository Sync and are expected to replicate.
- Private rooms use separate MLS instances and never become public cache input.
- Following a public community does not join a private room, create contact trust, fetch private membership, or receive a KeyPackage/Welcome.
- Leaving a private room does not force unfollowing public records.
- A public mirror or labeler has no private-room authority.
- Public and private records never share encryption keys, dedup identity, head authority, or deletion claims.

This composition lets Raven offer a public forum/channel, private member chat, and steward workspace without routing all three through one server database or pretending they have one privacy model.

---

## 11. Moderation, capabilities, bots, and bridges

### 11.1 Local block versus community action

Local block immediately controls local display, notification, DM/contact admission, and optional local message processing. It does not cryptographically remove a member for everyone.

Community Remove/Ban requires exact capability/threshold evidence plus aligned MLS transition. Labels/reports are evidence inputs, never automatic authority unless an explicit policy delegates a narrow action to a named verifier.

### 11.2 Moderation transparency

Governance events record the exact actor capability chain, action class, subject, scope, policy/control head, and bounded reason/evidence digest. Private-community governance evidence is encrypted to current authorized participants/steward partitions as policy specifies; public-community governance may publish an explicit public subset.

Raven does not expose private reporter identity/evidence to the reported member by default. A report intake is a selected encrypted endpoint, not a global Raven service.

### 11.3 Bots and automated agents

Every bot/bridge is an explicit participant with:

- distinct bot identity/device credential and MLS leaf;
- visible bot label and operator/provenance statement;
- narrow role/capabilities and room scope;
- data retention/network/tool disclosure;
- rate/resource budget;
- exact add/remove governance evidence.

A cloud bot that is an MLS member can read messages available to its leaf. UI must say so. There is no “cryptographically blind AI moderator” claim unless a separately reviewed construction proves it. Webhooks and server integrations cannot silently receive plaintext.

### 11.4 Bridges

A bridge to Matrix/ActivityPub/email/legacy Raven is a declared endpoint participant or public-record publisher. Crossing the bridge changes the privacy/security boundary and creates a new object/provenance class. The bridge cannot preserve a claim stronger than the weakest connected side, cannot impersonate native Raven senders, and cannot import remote admin authority.

### 11.5 Media attachments and participation grants

Private-room media assets, workflow provenance and participation/use grants
remain encrypted inside the room's authorized confidentiality boundary. A
community policy may require disclosed provenance for an official channel, but
cannot make one C2PA trust list, capture device, soft-binding registry or public
manifest repository the authority to speak. A valid provenance chain does not
grant room membership, posting capability, consent or Attention rank.

Publishing a private attachment outside the room, recording a live room, or
transcoding through a bridge is a new explicit artifact/provenance operation.
It must apply the audience/grant policy, disclose lost assertions and never
silently publish private manifest metadata or participant identities.

---

## 12. Carrier, mesh, mailbox, and offline behavior

### 12.1 Exact multi-path delivery

The same signed/sealed endpoint object may travel over approved:

- direct local TCP/QUIC/Noise;
- Internet direct/relay/DCUtR;
- offline mailbox;
- BLE/local mesh store-carry-forward;
- QR/file/cable for Welcome/control recovery where profiled.

Each path preserves exact endpoint bytes. Carriers know only the minimum routing/custody metadata in their profile. They cannot expand a recipient set, perform MLS fanout based on plaintext membership, or fabricate group delivery.

### 12.2 Fanout modes

Small rooms MAY use client fanout to opaque per-device mailbox tags. Larger rooms MAY use an approved broadcast/store service for one ciphertext object when that service need not learn the plaintext member list. Every mode has explicit metadata, amplification, size, member-count, retry, and expiry ceilings.

If a server requires a plaintext member list to fan out, that is an explicit weaker-metadata delivery profile and must be disclosed/approved; it cannot be the silent default.

### 12.3 Offline application messages

Within one aligned epoch, application messages can be delivered/loss-recovered out of order under MLS generation limits. Handshake/control messages receive priority and bounded persistent dependency tracking. A node missing a Commit cannot decrypt later epochs and requests exact missing authenticated dependencies from several eligible peers/carriers.

Offline mode does not manufacture global order. If a removal/revocation/Commit fork is pending, security-sensitive rooms pause sending until alignment.

### 12.4 Mesh privacy and abuse

Mesh forwarders are not presumed members. They forward opaque bounded objects under Attention Firewall quotas. Route/mailbox tags must not be raw `community_id`, `room_id`, member identity, or MLS group ID. Repeated forwarding does not create membership, delivery proof, popularity, or rank.

Traffic analysis may still correlate packet size/timing/proximity. Padding and delay profiles reduce but do not eliminate this.

---

## 13. Durability and protected state

Protected per-private-room state includes:

```text
community genesis/control pins and conflicts
room policy and participant-set pins
writer/coordinator capability heads
MLS instance/epoch/tree/key-schedule/client state
KeyPackage claim/destruction state
pending control+MLS joint journal
endpoint replay/dedup and application generation state
pending receipt/outbox exact bytes
terminal fork/successor evidence
local block/attention barriers
```

Public SQL/indexes contain only bounded non-secret metadata/digests necessary for lookup. MLS secrets, Leaf private keys, KeyPackage private init keys, Welcome secrets, exporter secrets, archive keys, and private member lists never enter public logs/indexes.

Every state-mutating path uses one non-reentrant mutation lease and the same roll-forward ordering as §7.3. Protected state is zeroized on terminalization/retirement after required bounded recovery evidence persists. Missing/corrupt/rolled-back protected state fails closed; it never reinitializes an existing room as a new first epoch.

Carrier network I/O, media decoding, notifications, and UI release occur outside the lease and only after commit.

---

## 14. Identity recovery, archive, and device replacement

### 14.1 Identity recovery

An activated Continuity V2 recovery preserves the stable identity but retires all old device lineages. Community peers verify the exact continuity event and apply room policy:

- identity-level participation may remain pending;
- every old MLS device leaf is removed/ineligible;
- the new device publishes a fresh KeyPackage and joins through an authorized current-state transition;
- no old MLS state, Welcome, session, or KeyPackage is restored.

Frozen Identity V1 has no post-loss continuity. A replacement V1 key is a new participant unless the community explicitly adds it.

### 14.2 User-Owned Archive

The archive may restore eligible historical group messages, exact governance evidence, public records, local community labels/preferences, and attachment plaintext selected by policy. It MUST NOT restore MLS/KeyPackage/device/session/protected-head state.

Restored community history is read-only/quarantined until exact provenance verifies. It emits no ACK/read receipt, does not rejoin a room, and cannot grant membership. A fresh current device re-acquires membership/MLS state separately.

### 14.3 Device replacement without identity recovery

An existing authorized device can approve a new device through the normal device-add and MLS Add flow. Transferring raw MLS state between devices is forbidden in V1. Optional bounded history sharing follows §8.4.

---

## 15. Metadata and privacy

### 15.1 Potentially observable

Depending on carrier/profile, outsiders may observe:

- opaque group/room/instance tags;
- MLS epoch and content type, ciphertext lengths, frequency, and timing;
- KeyPackage/GroupInfo/Welcome retrieval and delivery;
- client fanout count or broadcast access patterns;
- relay/mailbox/push account and network identifiers;
- joins/leaves inferred from traffic or public governance;
- public community descriptors/records and mirror access.

Members see at least the membership/credential/tree information required by the chosen MLS/profile. A private room is not anonymity among members.

### 15.2 Minimization

Profiles SHOULD use:

- PrivateMessage for handshake content where compatible with discovery/recovery needs;
- opaque random instance/route/mailbox identifiers;
- padding buckets and bounded batching;
- recipient-private KeyPackage/Welcome delivery;
- separate identifiers/keys across privacy partitions;
- user-selected multi-path/OHTTP/Tor-like modes where approved;
- local-only follows, blocks, ranking, and reading behavior;
- no plaintext member list at generic relays/mailboxes.

No UI may say “server cannot see membership” unless the exact active carrier/fanout/KeyPackage/GroupInfo profile and traffic metadata support that claim.

---

## 16. Resource and abuse ceilings

Exact values are frozen later. Finite checked ceilings exist for at least:

```text
communities and rooms per local account
participants/users per community and devices per participant
MLS leaves/tree depth/epoch/application generations
KeyPackages, proposals, pending Commits, Welcome recipients
governance roles, capabilities, proof depth, threshold N/M
control conflicts/fork evidence/successor instances
message/body/attachment/chunk/padding sizes
offline queue/mailbox/mesh forwarding bytes and TTL
receipt batch size/frequency
history grant/range/bytes
bot/bridge count and rate
provider/carrier retries, pages, connections, CPU and memory
quarantine/inbox/outbox/skipped-generation state
```

Unknown public join requests, bots, media, and stranger-generated content use weaker isolated Attention Firewall quotas and cannot evict contact/member security state. Limits are enforced before allocation/expensive cryptography where outer framing permits. Capacity failure preserves existing heads and returns a stable redacted error.

---

## 17. Failure matrix

| Event | Required result |
|---|---|
| Legacy server AES/group object presented as MLS | Reject profile/type; never reinterpret |
| Provider claims user is admin/member | Ignore unless exact governance/MLS evidence verifies |
| Valid governance Add without MLS Commit | Pending/misaligned; no application send or membership activation |
| Valid MLS Add without governance authorization | Reject candidate; no state promotion |
| Verified Remove before MLS rekey | Enter `REKEY_REQUIRED`; pause application send |
| Same coordinator slot/epoch, two valid Commits | Terminal instance conflict; no rollback; successor ceremony |
| Concurrent non-authority messages | Dedup/causal union under normal message rules |
| Concurrent authority successors | Preserve conflict; no timestamp/digest/provider winner |
| Missing Proposal referenced by Commit | Bounded exact dependency fetch; no blind apply |
| Stale/future Commit | Reject or bounded pending per exact epoch policy; no skip/reinit |
| Tampered MLS/application/AAD/control binding | Reject without MLS/control/inbox mutation |
| Revoked/expired device KeyPackage | Reject before claim/Add |
| Duplicate exact application object | Idempotent; return/requeue exact committed receipt if policy allows |
| Same message/slot identity, different bytes | Conflict/replay refusal; no mutation |
| Coordinator offline | Existing aligned epoch may continue only absent security barrier; epoch changes pause/failover per policy |
| Delivery service withholds/forks | Multi-path may recover; otherwise partial/paused; no fake completeness |
| New member requests history | None by default; require exact HistoryGrant and fresh export |
| Archive contains MLS state | Reject archive/import as forbidden secret class |
| Identity recovery | Remove old leaves; fresh device join; no state restore |
| Local block conflicts with community allow | Local block wins local attention/DM policy |
| Community unban versus sticky device revoke | Device revoke wins |
| Bot added without visible exact policy/capability | Reject; no plaintext/tool access |
| Crash before joint journal | Canonical state unchanged; no output |
| Crash after journal/partial public commit | Roll forward exact candidate/output; never rollback/reuse |
| Protected MLS/control state missing/corrupt | Fail closed; no first-epoch reset |
| Oversize/tree/proof/media/history bomb | Reject before expensive allocation; preserve state |

---

## 18. Legacy Raven group migration

The existing iOS server-backed group model, per-group AES claims, server membership/admin APIs, bridge group fanout, and legacy push/group notification paths are a distinct legacy product surface. They are **not** this profile and cannot be upgraded by flipping a flag or wrapping old ciphertext.

Migration requires:

1. explicit creation of a new sovereign `community_id` and room(s);
2. user-visible founder/governance policy ceremony;
3. current identity/device/cert/revocation verification for every invited participant;
4. fresh one-use MLS KeyPackages, GroupContext, Commit, Welcome, and protected state;
5. optional historical export imported only as historical archive data, never as current membership/MLS state;
6. no server admin role automatically becoming Raven steward authority without an explicit signed grant/acceptance;
7. no old invite link, server room ID, group AES key, membership row, read receipt, or push token reused as authority/crypto input;
8. an explicit rollback plan that leaves the new room disabled rather than silently returning private traffic to the legacy server path.

Existing UI/privacy copy must not claim MLS or sovereign group guarantees until the new path passes production gates and is actually active. A future migration companion owns exact UX/data transitions.

---

## 19. Required vectors and adversarial tests

Before approval, Python/Rust/Swift compute exact fixtures for:

1. community/room/MLS-instance genesis and non-circular identifiers;
2. role/capability grant, attenuation, invocation, expiry, retirement, replay, widening, and cross-room substitution;
3. M-of-N policy authorization, single-controller label, duplicate signers, wrong action/head, threshold conflict;
4. user membership versus multi-device MLS leaves;
5. Raven identity/device/cert/revocation credential validation;
6. KeyPackage generate/publish/claim/exact replay/collision/expiry/destruction;
7. MLS create, Add, Commit, Welcome, application send/receive, Remove, Update, external join if enabled, and instance successor;
8. exact governance-control digest embedded/bound in MLS transition;
9. Add/Remove atomic joint journal and every crash point;
10. coordinator rotation/failover/equivocation and competing Commit terminalization;
11. no MLS rollback/reuse and fresh successor instance convergence;
12. application loss/reorder/duplicate/tamper/wrong-room/wrong-epoch/wrong-control-head;
13. multi-path byte identity and object-digest dedup;
14. receipt batching, duplicate exact receipt, privacy policy, and no ACK storm;
15. history none-by-default, bounded HistoryGrant, recipient binding, no old epoch secrets/receipts;
16. public/private/role-private partition separation;
17. bot/bridge explicit-member and capability negatives;
18. archive restore with history only and zero MLS/network mutation;
19. legacy AES/server-group/type confusion refusal;
20. cap, allocation, decompression/media, proof-depth, tree, pending-Commit, and Sybil negatives;
21. redacted Debug/log/telemetry and secret zeroization.

MLS conformance vectors alone are insufficient. Tests must execute Raven governance, credential, durability, endpoint, carrier, attention, archive, and fork semantics around the pinned MLS implementation.

---

## 20. Simulations and physical gates

### 20.1 Deterministic simulations

Required simulations include:

- 1,000-node mixed communities with public/private rooms, multi-device users, offline periods, churn, and several carriers;
- small/medium/large MLS trees with proposal/application loss/reorder/duplicates;
- malicious coordinator, steward quorum, member, bot, delivery provider, mailbox, mirror, and mesh peer;
- simultaneous membership changes and competing Commit detection/instance recovery;
- provider partition/withholding/eclipsing without hidden provider authority;
- remove/revoke during offline partitions and proof that no post-barrier application send leaks to removed devices;
- KeyPackage exhaustion/replay/Sybil join floods under isolated quotas;
- carrier fanout/receipt/attachment amplification bounds;
- identity recovery/device churn without old MLS state reuse;
- archive history restore without room rejoin or receipts;
- public/private partition and metadata-correlation analysis.

Simulation does not prove global consistency, anonymity, or production durability.

### 20.2 Process and physical matrix

| Scenario | Required evidence |
|---|---|
| Create community + private room | Two physical iPhones and Terminal combinations; exact governance + MLS state |
| Add second device for one user | Explicit device membership; no implicit clone |
| Add/remove/ban/rejoin | Future secrecy behavior, aligned participant set, stale Welcome/KeyPackage refusal |
| Kill at every Add/Remove/Commit/receive/receipt boundary | Old or exact new valid state; no output-before-commit |
| Coordinator offline and authorized failover | No server override; exact capability transition |
| Competing Commits | Terminal pause + fresh successor instance; no rollback |
| LAN ↔ relay ↔ mailbox ↔ mesh | Exact endpoint bytes and no legacy fallback for each enabled path |
| Message → durable receive → optional batch receipt → next message | Both directions and multi-device |
| Identity recovery/device replacement | Old leaves retired; fresh join; history separate |
| Archive restore | Historical messages only; no MLS/ACK/outbox/network state |
| Public lobby + private room | No cross-partition key/content/member-list leakage |
| Bot/bridge | Visible member/capability/data boundary and removal |
| Packet/log/disk inspection | No plaintext, MLS secrets, member graph, keys, or identifiers beyond declared profile |
| Lock/BFU/relaunch/protected corruption | Physical iPhone + Apple/Terminal durable profiles |

Every advertised carrier/platform/room class needs its own physical row. Simulator or one in-process MLS test is not enough.

---

## 21. Production holds

No sovereign community/group Release path may enable until all are met:

1. this architecture, the umbrella MLS amendment, exact community/governance wire, MLS profile, persistence, and carrier-conformance companions are APPROVED;
2. a reviewed MLS library/version/supply-chain profile and every shipping platform binding are pinned with conformance/interoperability vectors;
3. current identity/device/cert/revocation/continuity integration passes all credential and recovery matrices;
4. governance roles/capabilities/thresholds, coordinator replacement, control conflicts, and instance successors have no open P0/P1;
5. Add/Remove/Ban/user-device membership and MLS tree state are atomically aligned under crash/restart;
6. competing Commit behavior never rolls back/reuses MLS state and fresh-instance repair passes partitions/physical tests;
7. no application data leaves while a remove/revoke/security rekey barrier is pending;
8. public/private/role-private partition separation passes storage/network/object-digest inspection;
9. history sharing is none-by-default, bounded, recipient-bound, and exports no epoch/session/receipt secrets;
10. every enabled carrier passes exact-byte multi-path, withholding, replay, fanout, privacy, abuse, and physical gates;
11. Attention Firewall is APPROVED for community discovery, notifications, reports, bots, and unknown joins;
12. User-Owned Archive is APPROVED before group-history archive/restore ships and proves zero MLS/network restoration;
13. Identity Continuity V2 is APPROVED before stable identity recovery is advertised in communities;
14. public community surfaces pass Social Graph/Public Repository Sync approval and do not create private membership;
15. legacy server/AES group paths cannot be selected, fallback-triggered, or advertised as sovereign/MLS;
16. all privacy/FAQ/UI copy matches the exact active path and metadata limits; stale claims are removed;
17. Python/Rust/Swift vectors, 1,000-node simulations, process tests, and every claimed physical row pass from clean artifacts;
18. protected storage/SQLCipher/Keychain/Secret Service/CredMan and zeroization pass platform security review;
19. independent cryptographic/security/privacy review or an explicit protocol-owner waiver records residual risks;
20. production flags remain false until human protocol-owner approval after all prior rows.

Automated green, one MLS demo, or one carrier smoke does not authorize production.

---

## 22. Open decisions before design approval/vector freeze

1. Exact MLS library, version/commit, licenses, crypto provider, and Apple/Windows/Linux bindings.
2. MLS version/cipher suite and required extension/proposal/credential set, including any PQ transition strategy.
3. Exact community/room/control/capability/invite/endpoint/receipt/history bytes and domain separation.
4. Critical-action threshold defaults and safe small-group policy.
5. Coordinator rotation/failover timing and quorum without pretending clocks are global order.
6. Exact fork-resolution/successor-instance ceremony and bounded old-state retention.
7. KeyPackage directory/distribution/claim policy over DM, ID Resolution, direct, mailbox, and offline flows.
8. Public/private handshake-message policy and ratchet-tree/GroupInfo distribution.
9. Application generation/skipped limits, message padding, receipt batching, and attachment exporter profile.
10. Public/open external-join anti-spam/admission profile.
11. History package encryption, provenance, size, retention, and recipient-consent UX.
12. Steward/bot/bridge identity, operator disclosure, and data-processing policy wires.
13. Member-count privacy and carrier fanout profile by room scale.
14. Community recovery/deactivation/inheritance and founder-loss policy.
15. Legacy Raven group sunset/migration and truthful product-copy plan.

No implementation fills these gaps by assumption.

---

## 23. Research foundations (informative only)

These sources inform architecture; none defines Raven wire bytes:

- [RFC 9420 — Messaging Layer Security](https://www.rfc-editor.org/rfc/rfc9420.html) — standardized continuous group AKE, epochs, tree/key schedule, KeyPackages, Proposals, Commits, Welcome, external joins, forward secrecy and post-compromise evolution; it requires applications to resolve competing Commits.
- [RFC 9750 — MLS Architecture](https://www.rfc-editor.org/rfc/rfc9750.html) — Authentication/Delivery Service separation, client/server/peer-to-peer deployments, delivery/fanout choices, commit-order/fork/withholding limits, and metadata exposure. Raven refuses to make one DS a permanent community authority.
- [MIMI protocol](https://datatracker.ietf.org/doc/draft-ietf-mimi-protocol/) and [room policy](https://datatracker.ietf.org/doc/draft-ietf-mimi-room-policy/) — separation of application, E2E security, transport, participant/client membership, room roles and synchronized policy. These are work-in-progress drafts and are not frozen Raven dependencies.
- [Matrix room authorization/state](https://spec.matrix.org/latest/rooms/) — explicit auth events, membership/power state, DAG/state-resolution lessons; Raven uses user/device signatures and capability/quorum conflict barriers rather than server-domain authority.
- [UCAN specification](https://github.com/ucan-wg/spec) — local-first attenuated delegation/invocation model; Raven requires its own canonical capability bytes, replay, revocation, and room bindings.
- [Signal Private Group System](https://signal.org/blog/pdfs/signal_private_group_system.pdf) — privacy-preserving server-assisted membership research and metadata goals; Raven does not inherit its centralized server/enclave/credential construction.
- [ActivityPub](https://www.w3.org/TR/activitypub/) — decentralized public actor inbox/outbox/collection distribution; Raven limits ActivityPub-like semantics to explicit bridge/public boundaries and never uses it as private MLS membership.

---

## 24. Revision history

- **Revision 2 (2026-08-21):** Added the explicit realtime-media plane boundary. Communities/MLS remain membership and epoch authority, while call control, ICE/TURN/SFU, DTLS-SRTP, SFrame, capture and recording belong to the production-disabled Private Realtime Media companion; transport or SFU state cannot mutate governance or membership.
- **Revision 3 (2026-08-21):** Sovereign-media boundary: private attachment provenance/grants stay inside MLS confidentiality; valid provenance grants no membership, capability, consent or rank; bridge transcode, room recording and external publication create explicit new artifact/provenance chains without mandatory registries.
- **Revision 1 (2026-08-21):** Initial architecture. Defined stable host-independent community/room/MLS-instance identities; governance/MLS/carrier separation; explicit roles, attenuated capabilities and M-of-N critical governance; one scoped rotating Commit coordinator; user-versus-device membership; Raven credential/revocation binding; atomic governance+MLS state; no secret rollback and fresh-instance fork recovery; private invitations/history; exact multi-path application objects and bounded receipts; public/private partition composition; explicit bots/bridges; offline/mesh behavior; archive/identity recovery separation; legacy group non-compatibility; failure, vector, simulation, physical, and production gates.
