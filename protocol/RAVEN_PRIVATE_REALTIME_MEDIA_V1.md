# RAVEN Private Realtime Media V1

**Version:** 1 (architecture/privacy draft; wire and implementation profile not frozen)

**Document revision:** 2

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no call/live-room
codec, WebRTC library, SDP parser, ICE/STUN/TURN service, SFU, SFrame/MLS key
profile, CallKit/APNs wake, microphone/camera capture, recording, database
migration, live callsite, background task, or Release flag

**Approval prerequisites:**
[`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md)
must be revised and re-approved to register realtime control and media-plane
classes. One-to-one calling additionally requires
[`RAVEN_ID_RESOLUTION_V1.md`](RAVEN_ID_RESOLUTION_V1.md),
[`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md),
[`ATSAM_HYBRID_RATCHET_V2.md`](ATSAM_HYBRID_RATCHET_V2.md),
[`RAVEN_PRIVATE_RENDEZVOUS_V1.md`](RAVEN_PRIVATE_RENDEZVOUS_V1.md),
[`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md), and exact
NAT/TURN/carrier profiles to be **APPROVED**. Group live rooms additionally
require [`RAVEN_SOVEREIGN_COMMUNITIES_V1.md`](RAVEN_SOVEREIGN_COMMUNITIES_V1.md)
and its pinned RFC 9420 MLS profile to be **APPROVED**. Recording/export
additionally requires
[`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md)
to be **APPROVED**.

**Non-interference:** this draft does not amend current DM/group message
ratchets, Full Braid, Object Sync, LAN, mailbox, NAT, bridge, protected-anchor,
or existing iOS media UI. It does not authorize a centralized Raven signaling,
TURN, or SFU service. No current voice attachment is a realtime call.

---

## 0. Core decision

Raven separates realtime communication into six non-interchangeable planes:

```text
Identity/contact/community authority       who may invite or join
Call-control endpoint objects              what exact action was proposed/accepted
Rendezvous + ICE consent                    where packets may flow now
DTLS-SRTP transport security                hop/peer media-channel protection
SFrame + MLS for multiparty SFU             endpoint-to-endpoint media confidentiality
Attention + OS capture policy               whether to ring/capture/display locally
```

The product rule is:

> A call is not “secure” because a socket connected, ICE succeeded, DTLS
> completed, or an SFU forwarded packets. Raven releases media only after the
> exact call-control transcript, Raven device identity, contact/community
> authority, DTLS fingerprint, topology, privacy mode, and current revocation
> state all agree.

The key words MUST, MUST NOT, SHOULD, and MAY are interpreted as in BCP 14 when
capitalized.

### 0.1 Byte and state separation

Call signaling records are immutable `endpoint_object_bytes` and retain the
umbrella's exact-digest, durable-commit, replay, and ACK rules. Standard ICE,
STUN, TURN, DTLS, SRTP, RTCP, SCTP, RTP, and SFrame packets are **ephemeral
realtime transport bytes**, not endpoint objects, carrier control, Object Sync,
chat messages, or durable ACK evidence.

The approved umbrella currently has no realtime media-plane class. Production
is therefore impossible until it is revised to define this separation without
weakening immutable endpoint-object semantics. Media packets are not inserted
into chat history, deduplicated by `object_digest`, retried through offline
mailbox, or marked Delivered/Read.

### 0.2 Provider independence

Raven may use direct peer-to-peer paths, LAN, user-selected TURN providers, or
user-selected SFUs. Provider URL, DNS name, account, relay allocation, ICE
priority, region, RTT, packet count, or successful forwarding is never identity,
contact, community membership, call acceptance, moderator authority, or media
key authority.

Self-hosting and provider migration are supported by keeping call identity and
authorization outside providers. “Decentralized” does not mean “no relay ever”:
some NATs and group topologies require relays/SFUs. Raven's stronger claim is
that no mandatory global Raven operator owns signaling identity, contacts,
group membership, or E2E media keys.

---

## 1. Goals, non-goals, and honest limits

### 1.1 Goals

| ID | Goal |
|---|---|
| RM1 | One-to-one voice/video calls authenticated by existing Raven contact/device/session state |
| RM2 | Private community live rooms whose device membership and media keys follow the exact MLS epoch |
| RM3 | No mandatory signaling server; control records move over approved Raven endpoint carriers |
| RM4 | User-visible direct-IP versus relay-only privacy choice with no silent downgrade |
| RM5 | E2EE media through TURN, and E2EE payloads through an untrusted SFU using SFrame |
| RM6 | Bind SDP/ICE credentials/DTLS fingerprints/topology/codecs to authenticated Raven control bytes |
| RM7 | Prevent ringing, IP disclosure, capture, and high-bandwidth media before explicit local consent |
| RM8 | Crash/retry-safe call control without pretending ephemeral media is durable/exactly-once |
| RM9 | Multi-device, revoke/remove, topology migration, congestion and abuse behavior with finite budgets |
| RM10 | Make relay/SFU/OS/network metadata leakage and recording limits visible and testable |

### 1.2 Non-goals

- Designing a Raven media codec, RTP, congestion controller, ICE, STUN, TURN,
  DTLS, SRTP, SFrame, MLS, or SFU cryptosystem.
- Calling a non-contact or unknown Private Introduction sender. Stranger
  proposals never ring.
- A global online/last-seen/callable directory.
- Guaranteed connectivity without TURN, guaranteed low latency, or reliable
  background ringing on every mobile platform.
- Hiding traffic from a global passive adversary.
- Hiding participant network address from the selected TURN/SFU provider.
- Claiming SFrame hides RTP metadata, KID, packet timing, size, loss, bitrate,
  active-speaker inference, or membership from the SFU.
- Server-side recording, transcription, moderation, AI processing, captions,
  or bots without explicit participant membership/disclosure and separate
  policy.
- Preventing a recipient from recording with another device or OS capture.
- Sending large media streams over BLE mesh or offline mailbox.
- Treating a stored voice note as a call.

### 1.3 Adversaries

The model includes malicious signaling carriers, TURN servers, SFUs, STUN
servers, resolvers, peers, contacts, community members, removed/revoked devices,
Sybil callers, network observers, compromised old devices, candidate injection,
SDP/fingerprint substitution, ICE amplification, call floods, malformed
RTP/SFrame, key-ID collisions, MLS/SFrame epoch skew, selective forwarding,
traffic analysis, crash/rollback, and hostile media/codec input.

### 1.4 Honest leakage

- A direct peer-to-peer call normally reveals public IP addresses to both
  peers. Host/server-reflexive ICE candidates may reveal local/network topology.
- A TURN server sees both network endpoints, allocation identity/policy, timing,
  sizes, bitrate, duration, and destinations, but DTLS-SRTP prevents media
  plaintext access when endpoint verification is correct.
- An SFU sees participant transport connections, RTP/RTCP metadata needed for
  forwarding, KIDs, timing, sizes, loss, bitrate and stream activity. SFrame
  protects media payloads, not all metadata.
- STUN/TURN/SFU DNS, TLS, account, region and payment choices can be identifying.
- Call control carriers observe their normal source/destination/timing leakage.
- Push providers and mobile OSes may learn that Raven received a wake/call
  event; an exact CallKit/APNs profile is required before any stronger claim.
- A contact already knows the caller's Raven identity. Relay-only hides the
  peer's direct IP from the other peer, not from the relay.

---

## 2. Admission snapshots

Every call-control transition consumes one immutable host-produced admission
snapshot. The realtime engine does not query contacts, governance, Keychain,
network, clocks, or UI itself.

### 2.1 One-to-one snapshot

```text
local_identity_address
local_device_certificate_bytes + digest
remote_identity_address
remote_device_certificate_bytes + digest
contact_commit_digest
atsam_session_id + confirmed_transcript_digest
session_generation
revocation_union_head_digest
block_generation
selected_call_privacy_mode
selected_provider_policy_digest
media_permission_snapshot
now_ms
```

The host requires an exact durable contact, current device certificate/session,
no local block/revocation, and a confirmed ATSAM session before an offer, ring,
answer, ICE release, media start, renegotiation, or resume. Deleting/blocking the
contact closes all new transitions even if WebRTC remains connected.

### 2.2 Community live-room snapshot

```text
community_id + governance_head_digest
room_id + room_policy_digest
mls_group_id + mls_instance_id + mls_epoch
participant_set_digest
local_mls_leaf/device_certificate binding
authorized action/capability digest
revocation_union_head_digest
local block/attention policy
selected topology/provider policy
media permission snapshot
now_ms
```

The exact device must be an active authorized MLS leaf at that epoch. Community
role names, server admin flags, SFU admission tokens, invite URLs, display names,
or old MLS membership do not authorize joining/publishing media. Governance and
MLS alignment rules remain owned by Sovereign Communities.

### 2.3 Admission before network and capture

The host reserves bounded control/media work and verifies the snapshot before:

- generating SDP, DTLS certificates, ICE credentials or candidates;
- contacting STUN/TURN/SFU/DNS;
- ringing, CallKit reporting, push acknowledgment, or foreground UI release;
- requesting microphone/camera/screen permissions;
- starting codecs, media decoders or network receive queues; or
- exposing local/related/public IP addresses.

An incoming offer may be durably admitted and shown as a quiet/ringing intent
without ICE gathering. No direct candidate is released before the user accepts.

---

## 3. Call-control endpoint records

Exact wire layouts remain open until vector freeze. Every record is immutable,
strictly length-bounded, signed/sealed under the exact ATSAM session or MLS
application protection, and bound to one call ID and participant/device roles.

### 3.1 Record family

| Record | Purpose | Durable effect after verification |
|---|---|---|
| `RavenCallOfferV1` | Propose media kinds, privacy/topology policy and negotiation commitment | Incoming offer + Attention intent; no ICE/media/capture |
| `RavenCallAnswerV1` | Explicit accept/reject and answer commitment | Freeze accepted policy; permit bounded ICE exchange |
| `RavenCallIceBatchV1` | Trickle bounded ICE candidates/credentials after accept | Candidate generation admission only |
| `RavenCallTransportBindV1` | Bind selected ICE pair class, SDP hashes and DTLS fingerprints | Permit DTLS/identity verification |
| `RavenCallMediaReadyV1` | Confirm exact negotiated transcript and media-protection mode | Permit capture/media release |
| `RavenCallUpdateV1` | Hold/resume, media-kind/topology/ICE restart proposal | Candidate transition; requires peer/room acceptance as specified |
| `RavenCallLeaveV1` | Signed device leaves/stops sending | Local participant/send-state update |
| `RavenCallEndV1` | Authorized terminal call end | Durable closed tombstone; no media restart under old ID |

Control ACK means the exact record was durably committed. It never means the
call rang, was answered, media flowed, a frame was rendered, or the human was
present. A late/offline offer may become a bounded missed-call event after
verification but never rings after expiry.

### 3.2 Common bindings

Every record binds at least:

```text
profile/version
call_id_256                         # random + domain-separated identity
call_generation_u64
record_kind + record_sequence_u64
sender identity/device/cert digest
recipient identity/device or community/room/MLS epoch
parent_control_digest(s)
offer/answer/transcript digest
privacy_mode + topology_mode
provider_policy_digest
media kinds and direction policy
created_at_ms / expires_at_ms
anti_replay_nonce
sender device signature or MLS sender authentication
```

Same record identity with identical exact bytes is idempotent. Same identity
with different authenticated bytes is a terminal control conflict and cannot
be resolved by arrival time, provider, call server, sequence race, or “latest”.

### 3.3 Offer and answer privacy

The initial offer contains no direct host/server-reflexive ICE candidate,
related address, STUN result, live microphone/camera sample, or online-presence
probe. It may carry only bounded provider/topology commitments needed for the
recipient to decide whether answering would expose a peer IP or involve a
relay/SFU.

The answer records explicit user acceptance and the exact privacy/topology
policy. Only then may either side generate/release candidates allowed by that
policy. Reject/ignore sends no network response by default unless local user
policy chooses an authenticated reject; silence does not reveal online state.

### 3.4 SDP and DTLS fingerprint binding

Raven does not trust an SDP signaling service. Each endpoint computes a
canonical negotiation digest over the exact offer/answer SDP (or a frozen
semantic replacement), ICE generation, DTLS certificate fingerprint, media
sections, codecs, RTP header extensions, SFrame parameters, SCTP policy,
topology and privacy mode. The digest is carried in authenticated call-control
records.

Before DTLS-SRTP or data channels are accepted, the peer's observed DTLS
fingerprint must equal the authenticated transcript binding. A successful DTLS
handshake with an unbound fingerprint is an unauthenticated media channel and
is closed. Each call uses a fresh DTLS keypair unless a separately reviewed
continuity profile says otherwise.

### 3.5 Candidate rules

- Candidate count, line length, extensions, address families, ports, components,
  generations and total bytes are bounded before parse/allocation.
- Remote candidates are accepted only after CallAnswer and matching call/ICE
  generation; old-generation trickle is stale.
- Candidate addresses are not written to logs, analytics, crash reports,
  notifications, shell history, chat DB, or archive.
- Relay-only mode permits only TURN relay candidates and forbids related address
  disclosure to the peer/application where the platform supports it.
- Direct modes apply SSRF/local-network policy and never probe arbitrary
  application-supplied addresses outside verified ICE semantics.
- ICE success is reachability/consent evidence, not Raven identity.

---

## 4. Media-protection profiles

### 4.1 One-to-one endpoint or TURN path

For a two-device call, WebRTC ICE establishes consent and DTLS-SRTP derives SRTP
keys. When the DTLS fingerprint is bound to the authenticated Raven call
transcript, media is endpoint-to-endpoint encrypted even when packets transit a
TURN relay; TURN never terminates DTLS-SRTP.

Plain RTP/RTCP, SDES keying, NULL encryption, externally supplied SRTP keys,
unverified fingerprints, and media-before-DTLS are forbidden. SCTP data
channels, if enabled, are DTLS protected and remain separately authorized;
they are not a bypass around Raven message/object rules.

### 4.2 Multiparty SFU path

An SFU normally terminates each endpoint's DTLS-SRTP hop so it can route media.
Therefore private group rooms require two layers:

1. DTLS-SRTP/SRTCP hop protection between each endpoint and SFU; and
2. RFC 9605 SFrame E2EE on media payloads between authorized endpoints.

SFrame keys are derived from the exact active RFC 9420 MLS epoch using the
reviewed RFC 9605 MLS exporter profile, with unique sender/KID assignment and
no Raven-authored group key scheme. The profile freezes cipher suite, exporter
label/context, epoch encoding, sender/stream/KID mapping, ratchet/key limits,
replay window, counter exhaustion, key deletion and rejoin behavior.

The SFU can inspect only metadata required by the profile. It cannot decrypt
SFrame payload, mint MLS membership, assign Raven roles, choose governance,
add recording bots, or advance an epoch. A valid SFU admission token is network
authorization only.

If SFrame or exact MLS alignment is unavailable, a private room fails closed.
It never falls back to SFU-readable media. A room deliberately configured for
public broadcast/plaintext processing is a separate visibly public profile,
not a downgrade.

### 4.3 Epoch and membership changes

On MLS Add/Remove/Ban/revoke/instance change:

1. pause affected media send before the authoritative transition releases;
2. commit aligned governance + MLS state;
3. derive new SFrame sender material for the new epoch;
4. zero old live send keys after bounded receive overlap;
5. publish exact new MediaReady binding; and
6. resume only when local participant/topology state matches.

Removed/revoked leaves cannot decrypt future media after the new epoch, but
Raven makes no retroactive secrecy or remote-erasure claim. Packet loss and
epoch reorder use bounded receive windows; rollback to an old epoch is forbidden.

### 4.4 Recording, transcription, captions and bots

Local recording/transcription/captions require an explicit per-call local
action and visible indicator. Server/SFU recording, cloud transcription, AI
analysis or bot participation requires an exact visible participant/processor
identity authorized by one-to-one consent or community governance. If a bot or
service receives SFrame/MLS keys, it can read media and the UI must say so.

No protocol can prevent an authorized recipient from external recording. Raven
must not display “cannot be recorded”. Archive excludes media keys and raw calls
by default; a user-selected recording is a new local artifact with separate
encryption/retention/export policy. If it is later shared or published, it
starts a new exact asset/provenance chain under
[`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md),
with the authorized capture/participants/use scope and any disclosure loss
represented honestly. DTLS-SRTP/SFrame/MLS E2EE proves neither capture/edit
provenance nor participant consent; conversely a valid C2PA chain proves
neither call membership nor transport E2EE.

---

## 5. Privacy and topology modes

The user/device freezes one mode before network candidate gathering. There is
no automatic fallback to a mode that exposes more addresses or plaintext.

| Mode | Topology | Disclosure and use |
|---|---|---|
| `M0_LOCAL_DIRECT` | LAN peer-to-peer | Peers learn local network path; no STUN/TURN; same contact/device/fingerprint gates |
| `M1_INTERNET_DIRECT` | ICE direct, TURN as policy-approved fallback | Best latency; peers may learn public/related addresses; STUN/provider leakage |
| `M2_RELAY_ONLY` | ICE policy relay through TURN for entire call | Peer does not receive direct candidate; TURN sees both endpoints/traffic metadata |
| `M3_GROUP_SFU_SFRAME` | MLS room through selected SFU | SFU sees participants/metadata, not SFrame payload; exact MLS epoch required |
| `M4_GROUP_MESH_SMALL` | Small bounded full-mesh WebRTC + MLS/SFrame policy | Every peer may learn other peer addresses; O(n²) links; strict participant cap |

Mode selection is local policy plus exact peer/room compatibility. `M2` failure
does not become `M1`; the user may start a new explicit attempt after seeing the
IP disclosure change. `M3` SFU failure does not become non-SFrame media. `M4`
does not expand beyond the frozen cap merely because an SFU is unavailable.

The UI shows before answer:

- whether the other peer will see the user's IP;
- which TURN/SFU operator may see connection metadata;
- whether media content is endpoint E2EE and why;
- whether a recording/transcription bot is an authorized participant; and
- whether a privacy-mode change requires a new consent action.

---

## 6. One-to-one state machine

### 6.1 Caller

```text
IDLE
  -> CONTACT_SESSION_ADMISSION
  -> CALL_ID_AND_FRESH_DTLS_IDENTITY_RESERVED
  -> OFFER_BYTES_BUILT
  -> OFFER_INTENT_DURABLE
  -> SEND_EXACT_OFFER
  -> AWAIT_ANSWER
  -> ANSWER_COMMITTED
  -> USER_MEDIA_PERMISSION
  -> ICE_GENERATION_AND_CANDIDATE_EXCHANGE
  -> DTLS_FINGERPRINT_VERIFIED
  -> MEDIA_READY_CONFIRM_COMMITTED
  -> ACTIVE
  -> ENDING
  -> CLOSED
```

Offer transport ACK is not Answer. Timeout/decline/expiry closes the call ID and
does not infer online/offline/read. An unanswered call never gathers/releases
direct candidates merely to reduce setup latency.

### 6.2 Callee

```text
RECEIVE_EXACT_OFFER
  -> CONTACT_CERT_REVOKE_SESSION_VERIFY
  -> DEDUP_AND_CAPACITY_RESERVE
  -> OFFER_COMMIT
  -> ATTENTION_RING_DECISION_COMMIT
  -> OPTIONAL_RING_UI
       -> IGNORE/DECLINE/CLOSE
       -> USER_ACCEPT
          -> ANSWER_INTENT_DURABLE
          -> SEND_EXACT_ANSWER
          -> USER_MEDIA_PERMISSION
          -> ICE/DTLS/MEDIA_READY
          -> ACTIVE
```

The receiving device never rings for a non-contact, blocked/revoked device,
Private Introduction proposal, public follower, resolver result, community
content author, or stale session. Attention policy may suppress ringing while
retaining a quiet incoming-call row; remote callers cannot override it.

### 6.3 Active call and updates

While active, each endpoint repeatedly checks ICE consent freshness and current
local block/revocation/contact policy. Media stops on consent loss, terminal
revocation/block/contact deletion, unbound DTLS change, counter exhaustion,
unresolved negotiation conflict, or policy-required MLS transition.

ICE restart, topology change, camera/screen-share addition, SFU migration,
recording bot addition, and direct-IP disclosure escalation are new authenticated
CallUpdate candidates. They become active only after the exact required peer or
room authorization commits. Retry preserves exact bytes; concurrent conflicting
updates pause rather than choose network-first.

---

## 7. Group live-room state machine

```text
ROOM_NOT_JOINED
  -> COMMUNITY/GOVERNANCE/MLS_ADMISSION
  -> USER_JOIN_INTENT
  -> TOPOLOGY/SFU_POLICY_FROZEN
  -> MLS_EPOCH_AND_SFRAME_PROFILE_BOUND
  -> SFU/FULL_MESH_TRANSPORT_ESTABLISHED
  -> DTLS_HOP_VERIFIED
  -> MEDIA_READY_COMMITTED
  -> ACTIVE_EPOCH_N
       -> AUTHORIZED_MEDIA_UPDATE
       -> MEMBERSHIP_CHANGE_PAUSE
          -> ALIGNED_MLS_EPOCH_N_PLUS_1
          -> NEW_SFRAME_KEYS_AND_READY
          -> ACTIVE_EPOCH_N_PLUS_1
  -> LEAVE/CLOSE
```

A delivery/SFU server does not decide who is in the call. A device may receive
packets before its local MLS/governance state aligns, but it drops them before
SFrame/media processing and does not advertise presence. Active-speaker layout,
subscription quality and bandwidth allocation are local/SFU performance hints,
not governance or Attention rank.

Room join/leave and speaking state are not public social objects by default.
Public live broadcasts require a separate audience/read policy and must not
reuse private-room membership or expose private participant lists.

---

## 8. Multi-device and invitation races

1. A one-to-one offer may target a bounded set of current contact devices under
   one logical `call_id` and per-device sealed copies.
2. The first exact valid Answer committed by the caller selects one device in
   baseline V1; other pending devices receive exact Cancel/End best effort.
3. Simultaneous answers are resolved by a frozen deterministic local rule before
   media release, not carrier arrival order. Losing devices never start capture.
4. A device revoke/expiry after offer but before Answer rejects that answer.
5. “Call all my devices” or device handoff is a separate explicit multi-device
   policy; it cannot silently add an unverified device.
6. Group rooms treat each device as a separate MLS leaf/SFrame sender.
7. Identity recovery authorizes fresh devices only through current contact or
   community admission; old call/MLS/media secret state is never restored.

---

## 9. Rendezvous, NAT, TURN and SFU providers

Private Rendezvous may return short-lived untrusted realtime provider/path
candidates only after this companion is APPROVED. A semantic candidate binds:

```text
provider identity/config digest
service kind = STUN | TURN | SFU
canonical endpoints and transports
credential/capability reference
issued/expires window
region/privacy policy digest
supported media profile digest
```

Credentials are short-lived and scoped to exact call/provider/purpose where the
underlying protocol permits. They are never embedded in public profile records,
logs, analytics or screenshots. Provider discovery and account issuance need a
separate policy that does not make one Raven operator mandatory.

The current libp2p NAT/DCUtR/Circuit Relay profile is not a WebRTC ICE/TURN/SFU
implementation. Circuit Relay cannot be relabeled TURN, and TURN success cannot
be relabeled Raven peer authentication. Each provider class has independent
conformance, abuse, capacity, privacy, failure and physical gates.

### 9.1 Network I/O rules

- No DNS/STUN/TURN/SFU request occurs while holding Raven mutation leases.
- Exact call-control bytes and privacy mode commit before network release.
- Provider credentials are protected; provider responses are untrusted input.
- TURN/SFU allocation success is network custody only.
- No media starts until DTLS/transcript/MediaReady gates succeed.
- A path may migrate within the committed privacy class after authenticated ICE
  restart; crossing classes requires explicit new consent.

---

## 10. Resource, abuse and media safety

Finite caps freeze for:

- incoming offers per contact/device/time bucket and concurrent ringing calls;
- target devices, call-control bytes, SDP/ICE candidates/generations and parses;
- STUN/TURN/SFU attempts, DNS names, addresses, ports and parallel sockets;
- audio/video/screen tracks, codecs, resolutions, frame rates and bitrates;
- RTP/SFrame packets, replay windows, KIDs, senders, epochs and skipped keys;
- group participants, mesh peer links, SFU subscriptions and active speakers;
- call duration, idle/consent deadlines, ICE restart/topology changes and retry;
- decoder memory, jitter buffers, encoded frame size, decompression and GPU/CPU;
- pending journals, conflict/tombstone evidence, missed-call rows and audit data.

Capacity is reserved before SDP/candidate parse, KEM/signature work, network,
codec initialization, frame allocation, notification, or capture. A call flood
cannot evict contacts, messages, sessions, revocations, MLS state, social repos,
archives or pending endpoint commits.

Media decoders operate in platform sandboxes where available. Codec negotiation
uses a pinned allowlist; remote SDP cannot enable arbitrary plugins, file paths,
URLs, devices or hardware features. Data channels default disabled unless an
exact application subprotocol is approved.

ICE consent freshness and bandwidth/congestion circuit breakers are mandatory.
The implementation stops sending promptly after consent loss; it never uses a
peer as an amplification target or continues bulk traffic because the UI still
shows Connected.

---

## 11. Protected state and crash semantics

Durable/protected state includes only what is necessary for control safety:

```text
call ID/generation and exact participant/device bindings
privacy/topology/provider policy digests
offer/answer/update/end exact bytes and object digests
control replay/conflict/tombstone state
DTLS fingerprint + SDP/ICE generation transcript digests
MLS epoch/SFrame profile/KID assignment digests (keys in protected MLS state)
pending notification/ring/capture/media-ready/release intents
quota reservations and recovery work
```

Raw media, SRTP/SFrame keys, ICE passwords, TURN credentials, direct addresses,
camera frames and microphone samples are not written to ordinary logs/history/
archives. Exact ephemeral credential persistence, if required for crash-safe
negotiation, uses platform-protected bounded storage and is destroyed on close.

Control mutations use the standard two-phase protected journal + SQL commit +
finalized anchor + clear + release ordering. Network, CallKit, notification,
capture and media operations occur outside the lease. Recovery rolls forward
exact control bytes and never reuses call ID, DTLS identity, ICE generation,
nonce, media key/counter or provider allocation after terminal uncertainty.

Raven does **not** attempt to resume an old live SRTP/SFrame transport after
process death by replaying secret packet state. It restores the durable call
control tombstone/pending intent, then performs an authenticated new ICE/DTLS/
MediaReady generation or ends the call. No old key/counter rollback is allowed.

An OS crash may make a remote peer temporarily believe media is active until
consent freshness expires. UI and protocol claims must account for this; there
is no universal exactly-once End event.

---

## 12. Failure and downgrade matrix

| Condition | Required result |
|---|---|
| Missing contact/session or room/MLS authority | Refuse before ring/ICE/capture/network |
| Private Introduction or public follower attempts call | Refuse; no ring or existence oracle |
| Offer ACK but no Answer | Pending/timeout only; no answered/online claim |
| User ignores/rejects | No direct candidate/media; silent by default |
| Direct-IP mode not accepted | No direct candidate release |
| Relay-only TURN fails | Call fails or new explicit consent; no silent direct fallback |
| SFU lacks SFrame/exact MLS epoch | Private group call fails closed |
| ICE succeeds, DTLS fingerprint mismatches | Close transport; no media |
| DTLS succeeds, Raven transcript mismatches | Close transport; no media |
| Same control identity/different bytes | Terminal conflict; preserve bounded evidence |
| Duplicate exact Offer/Answer/Update | Idempotent; no duplicate ring/capture/network release |
| Revoked/blocked/deleted contact mid-call | Stop new media/control; close according to committed policy |
| MLS member removed | Pause send; rekey/alignment before future media |
| SFU forwards old/unknown KID/epoch | Drop before media release; bounded evidence/counter |
| Candidate/SDP/media bomb | Reject within reserved weak-call budget |
| ICE consent freshness lost | Stop packets and close/restart under new authenticated generation |
| Crash after control commit before network | Retry exact control bytes; no media state rollback |
| Crash during active media | New authenticated generation or end; never restore packet counters backward |
| Provider withholds/records/drops packets | Availability/privacy event; no identity/governance mutation |
| Recording bot requested | Visible authorized participant/policy or reject; no invisible plaintext fork |

---

## 13. Attention, permissions and product language

Only `DIRECT_CONTACT` or an authorized community room can create an incoming
call candidate. Attention Firewall separately decides whether to ring, vibrate,
badge, show quietly, or suppress. Remote `urgent`, repeat-call, moderator, paid,
follower-count or provider fields cannot override local policy.

Microphone, camera, screen share and Bluetooth/audio-route permissions are
separate local actions. Accepting a call does not automatically authorize video,
screen share, recording, transcription, background capture or future calls.

User-visible states are evidence-limited:

| Label | Evidence |
|---|---|
| **Calling…** | Offer committed/sent; no remote activity claim |
| **Ringing on this device** | Local Attention released ring UI |
| **Accepted; connecting securely** | Exact Answer committed; media not ready |
| **Direct — peer can see your IP** | Committed mode + selected direct candidate |
| **Relayed — relay can see connection metadata** | Selected TURN path |
| **E2EE media verified** | DTLS/Raven binding and, for SFU, SFrame/MLS MediaReady committed |
| **Reconnecting securely** | New authenticated ICE/DTLS generation pending; old media paused |
| **Call ended locally** | Local close; remote display may lag |

The UI never says anonymous, serverless, untraceable, recorded-proof, online,
or end-to-end encrypted merely because an icon/library/provider says connected.
“Why secure?” is computed from committed local transcript/provider/topology/
MLS evidence without a network refresh.

---

## 14. Vectors, simulation and physical acceptance

Before `APPROVED`, Python, Rust and Swift must compute identical call-control
bytes/digests/state transitions for:

- 1:1 Offer/Answer/ICEBatch/TransportBind/MediaReady/Update/End;
- exact identity/contact/session/device/cert/revocation/transcript bindings;
- canonical SDP/semantic negotiation digest and DTLS fingerprint mismatch;
- mode/topology/provider no-downgrade and no-candidate-before-answer;
- duplicate/collision/reorder/expiry/generation/ICE-restart conflicts;
- MLS epoch/participant/SFrame exporter/KID assignments and removed-member
  negatives using an independently pinned RFC 9605/9420 oracle;
- two-phase control crash windows, notification/capture release and active-call
  process-death recovery; and
- strict SDP/ICE/media caps, unknown fields, parser/codec fuzz and resource
  reservation before expensive work.

A deterministic 1,000-node model covers contact call floods, NAT classes,
direct/relay success, provider partitions, TURN/SFU capacity, multi-device
answer races, group joins/removes/rekeys, SFU selective forwarding, packet
loss/reorder, topology migration, mobile suspension and adversarial media sizes.
It is model evidence, not live media proof.

Physical acceptance includes:

| Scenario | Required evidence |
|---|---|
| iPhone ↔ iPhone LAN | Audio then video; no STUN/TURN; exact Raven identity/fingerprint bind |
| iPhone ↔ iPhone Internet direct | IP-disclosure UI before answer; ICE/DTLS/media/restart/end |
| iPhone ↔ iPhone relay-only | TURN-only candidate audit; peer direct IP absent; relay metadata disclosure |
| Terminal/macOS ↔ iPhone | Bidirectional audio/video, direct and TURN, kill/relaunch/reconnect |
| Three-device private room | MLS membership + SFU SFrame; SFU plaintext inspection negative |
| Removed/revoked device | Rekey/pause; no future media decrypt/send |
| Provider migration | Exact authenticated topology update; no plaintext/downgrade |
| CallKit/background | Real device lock/suspend/wake with exact Apple leakage/reliability claims |
| Recording/bot | Visible authorization; unauthorized bot/SFU plaintext fails |

At least two physical iPhones are required for iPhone↔iPhone claims and at
least three physical endpoints for group/SFU claims. Simulator loopback cannot
substitute for camera/microphone, NAT, CallKit, background, radio or relay/SFU
evidence.

---

## 15. Production holds

Production remains disabled until:

1. the umbrella adds/re-approves realtime control/media-plane classes;
2. ATSAM V2, ID/contact/revocation, Private Rendezvous, Attention and exact
   NAT/TURN carrier profiles are APPROVED;
3. Sovereign Communities + pinned MLS are APPROVED for group rooms;
4. exact WebRTC/DTLS-SRTP/SFrame/MLS versions, cipher suites, codecs, SDP/ICE
   profile, KDF/exporter, caps and vectors freeze;
5. selected libraries have license, provenance, reproducible build, platform,
   sandbox, fuzz and update policy review;
6. self-host and multi-provider TURN/SFU conformance passes with no mandatory
   Raven operator or identity/contact/content logs;
7. durable control and active-media crash/restart matrices pass on every
   supported platform;
8. decoder/network/parser fuzzing and 1,000-node resource/abuse simulations
   have no open P0/P1;
9. the full physical matrix passes, including two iPhones and group endpoints;
10. UI/accessibility/privacy/permission/recording disclosures are independently
    reviewed; and
11. independent cryptography, WebRTC, privacy and systems review—or an explicit
    protocol-owner waiver—records no unresolved production blocker.

No lab feature may register CallKit, microphone/camera capture, STUN/TURN/SFU,
background task, push handler, live signaling, media decoder, or Release path.

---

## 16. Research foundations (informative only)

Raven claims no wire compatibility beyond a future explicitly pinned profile:

- [RFC 8825 — WebRTC overview](https://www.rfc-editor.org/rfc/rfc8825.html),
  [RFC 8835 — transports](https://www.rfc-editor.org/rfc/rfc8835.html), and
  [RFC 8827 — security architecture](https://www.rfc-editor.org/rfc/rfc8827.html)
  — ICE consent, DTLS-SRTP/SRTP, SCTP data channels, fingerprint identity
  binding, per-call keys and security UI.
- [RFC 8828 — WebRTC IP address handling](https://www.rfc-editor.org/rfc/rfc8828.html)
  — direct-connect performance versus local/public/VPN address disclosure and
  policy-controlled candidate modes.
- [RFC 8445 — ICE](https://www.rfc-editor.org/rfc/rfc8445.html),
  [RFC 8656 — TURN](https://www.rfc-editor.org/rfc/rfc8656.html), and
  [RFC 7675 — consent freshness](https://www.rfc-editor.org/rfc/rfc7675.html)
  — connectivity, relaying and continuing permission to send traffic.
- [RFC 9605 — SFrame](https://www.rfc-editor.org/rfc/rfc9605.html) — media-payload
  E2EE through SFUs, exposed KID/metadata limits, application profile duties and
  MLS exporter keying option.
- [RFC 9420 — MLS](https://www.rfc-editor.org/rfc/rfc9420.html) and
  [RFC 9750 — MLS Architecture](https://www.rfc-editor.org/rfc/rfc9750.html) —
  device membership/epoch key agreement and Delivery Service separation;
  governance and call policy remain Raven responsibilities.
- [W3C WebRTC](https://www.w3.org/TR/webrtc/) — API candidate exposure,
  relay-only policy and fingerprinting/privacy surface. Native Raven clients
  still require an exact pinned library/API profile.

---

## 17. Open decisions before vector freeze

1. Exact control record layouts, domains, call ID and generation semantics.
2. Exact WebRTC native library, version, license, provenance, platform slices
   and reproducible-build policy for Swift/Rust/Desktop.
3. Canonical SDP versus a constrained semantic negotiation format and parser.
4. DTLS/SRTP versions/suites/profiles and platform interoperability baseline.
5. ICE candidate/extension/address/port caps and direct/local network policy.
6. TURN credential issuance, privacy mode, provider discovery, quotas and
   self-host configuration without a mandatory central account.
7. SFU protocol/provider profile, routing metadata, SFrame framing and
   independent plaintext-negative test harness.
8. Exact RFC 9605 MLS exporter/KID/counter/epoch mapping and PQ migration.
9. Codec allowlist, hardware acceleration, decoder sandbox and accessibility.
10. Multi-device answer winner, handoff and simultaneous-call policy.
11. Group topology thresholds, mesh cap, SFU migration and active-speaker privacy.
12. CallKit/APNs/background wake payload, metadata, timing and reliability.
13. Recording/transcription/caption/bot policy and archive integration.
14. Quality telemetry that remains local/redacted and cannot reconstruct the
    social graph or provider/peer addresses.

---

## 18. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial research architecture: separates Raven authority/control, rendezvous/ICE, DTLS-SRTP, SFrame/MLS and Attention/capture; no signaling server; direct versus relay-only privacy modes; SFU payload E2EE; strict fingerprint/SDP binding; no ICE before Accept; one-to-one and group state machines; multi-device/revoke/topology/crash/resource/UX/vector/simulation/physical production holds |
| 2 | 2026-08-21 | Sovereign-media boundary: later sharing/publication of a user-authorized recording creates a new exact asset/provenance chain; E2EE is not capture/edit provenance or consent, and C2PA validation is not call membership or transport security. |
