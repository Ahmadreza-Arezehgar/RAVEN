# RAVEN Private Introduction V1

**Version:** 1 (architecture/privacy draft; wire not frozen)

**Document revision:** 1

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no introduction
provider, public inbox, OHTTP deployment, anonymous-rate issuer, push wake,
contact mutation, PairInit, message enqueue, codec, database migration, live
callsite, or Release flag

**Approval prerequisites:**
[`RAVEN_ID_RESOLUTION_V1.md`](RAVEN_ID_RESOLUTION_V1.md),
[`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md),
[`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md), and the
exact carrier/provider profiles used by a deployment must be **APPROVED**.
[`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md)
must be revised and re-approved before these endpoint-record families can
become normative.

**Non-interference:** this draft does not reinterpret
[`RAVEN_CONTACT_REQUEST_V1.md`](RAVEN_CONTACT_REQUEST_V1.md), PairInit V1/V2,
prekey OTPs, current LAN, mailbox, NAT, bridge, Object Sync, Full Braid, or
protected-anchor work. It does not authorize stranger messaging or public
presence. Existing rootless contact-request and introduction entry points
remain fail-closed.

---

## 0. Core decision

Raven defines **Private Introduction** as a separate pre-contact protocol:

> An introduction is a bounded, inert, end-to-end encrypted proposal asking
> an exact identity to consider a contact relationship. It is not a contact,
> message, session, route, presence record, delivery receipt, or notification
> permission.

The key words MUST, MUST NOT, SHOULD, and MAY are interpreted as in BCP 14 when
capitalized.

### 0.1 Authority separation

| Question | Sole owner |
|---|---|
| Which exact identity/device is this Raven ID? | ID Resolution + DeviceSet + certificates + revocation |
| Can an unknown party deposit one bounded proposal? | **Private Introduction** |
| Has either user accepted the relationship? | That user's local contact store |
| Where can mutually accepted devices connect? | Private Rendezvous |
| Is a live peer/session authentic? | Noise bind + PairInit/Triple Ratchet |
| May an event interrupt the user? | Local Attention Firewall |
| How do opaque bytes move? | Approved carriers/providers |

No resolver result, provider receipt, write capability, signature, repeated
request, source count, popularity score, push event, or successful decrypt can
create a contact or authorize PairInit. A contact exists on a device only after
an explicit local `CONTACT_COMMIT`.

### 0.2 Why the existing ContactRequestV1 cannot be reused

The frozen ContactRequestV1 requires an already authenticated ATSAM session
root. That is correct for a request sent **inside an existing relationship**,
but circular for first contact: a stranger cannot honestly possess the session
that the request requires. Private Introduction therefore uses distinct keys,
records, quotas, stores, and state machines. It never derives or claims a
PairInit root.

### 0.3 Honest privacy claim

V1 can hide proposal contents and the sender's Raven identity from a storage
provider. Depending on the selected mode, it may also separate sender network
address from the inbox provider. It does **not** claim to hide timing, size,
provider membership, or sender/recipient correlation from a global observer or
colluding relay/gateway. Strong metadata-private first contact remains a future
Alpenhorn-like/anytrust profile.

---

## 1. Goals, non-goals, and threat model

### 1.1 Goals

| ID | Goal |
|---|---|
| PI1 | Let a user enter an exact Raven ID and send one bounded contact proposal without first creating a contact/session |
| PI2 | Encrypt to an exact recipient device and authenticate the sender only inside the sealed proposal |
| PI3 | Give providers only opaque, rotating write capabilities and fixed-size records |
| PI4 | Make direct, OHTTP, OOB, and future-anytrust leakage visibly different; never auto-downgrade |
| PI5 | Give the recipient local control: ignore, accept, decline, or block without remote notification by default |
| PI6 | Make retries byte-identical, dedup exact, and crash recovery roll-forward |
| PI7 | Keep stranger CPU/storage/attention physically bounded away from contacts and protected state |
| PI8 | Support a one-time acceptance response without inventing public presence or assuming mutual rendezvous |

### 1.2 Non-goals

- Sending an ordinary chat message, attachment, call, group invite, reaction,
  profile feed, remote URL, executable preview, or typing/read state.
- Proving that a recipient is registered, online, polling, interested, or has
  read the proposal.
- Uploading contacts, publishing a social graph, recommending people, or
  exposing “people nearby”.
- Treating a public key, Raven ID, prekey, provider token, or successful
  provider PUT as consent.
- Reusing PairInit signed/one-time prekeys or consuming PairInit OTP claims.
- A universal sender reputation, proof-of-personhood, mandatory proof-of-work,
  blockchain, or global moderation authority.
- Hiding traffic from a global passive adversary.
- Background iPhone polling or APNs privacy claims without a separately
  approved wake profile.
- Letting anonymous mesh traffic create stranger proposals. First contact over
  local mesh requires a user-transferred one-time invite in V1.

### 1.3 Adversaries

The design considers malicious introduction providers, OHTTP relays/gateways,
resolvers, senders, Sybil identities, replaying carriers, compromised old
device keys, malicious linked devices, local database rollback, crash between
every durable step, quota exhaustion, ciphertext bombs, KEM/AEAD oracle abuse,
equivocating DeviceSets, traffic analysis, and provider collusion.

### 1.4 Unavoidable leakage

- A direct provider sees sender IP, opaque inbox capability, time, size, and
  retry behavior.
- Under OHTTP, the relay sees sender IP and gateway; the gateway/provider sees
  the opaque inbox capability and request. Collusion links both views.
- The resolver that returns a device's signed introduction descriptor knows
  that the descriptor belongs to that identity. If it also operates the inbox
  provider, it can link identity to provider capability.
- The recipient learns the verified sender identity after successful decrypt.
- Publishing a writable stranger lane creates spam and availability risk even
  when contents and sender identity remain hidden from the store.
- Fixed-size padding reduces size leakage but not timing/intersection leakage.

---

## 2. Inputs and signed recipient capability

### 2.1 Resolution output

Private Introduction begins only from a verified immutable resolution snapshot:

```text
recipient_identity_address
recipient_identity_public_key
recipient_device_set_bytes + digest + generation
recipient_device_certificate_bytes + digest
recipient_introduction_descriptor_bytes + digest
recipient_introduction_prekey_bytes + digest
revocation_union_head_digest
local_block_generation
selected_write_privacy_mode
selected_provider_set_digest
now_ms
```

The host verifies canonical address, identity, DeviceSet, device certificate,
descriptor, prekey, validity, revocation, local block, caps, and exact provider
policy before any KEM, signature, storage, OHTTP, or network work.

### 2.2 Distinct introduction prekey

`RavenIntroductionPrekeyV1` is a short-lived, signed, device-bound encryption
prekey used only for proposals. Its semantic fields include:

```text
profile = "RAVEN/private-introduction/v1"
recipient_identity_address
recipient_device_certificate_digest
introduction_prekey_id
x25519_public
mlkem768_public
not_before_ms
expires_at_ms
maximum_ciphertext_bytes
descriptor_digest
signature_by_recipient_device
```

It is domain-separated from signed PairInit prekeys, PairInit OTPs, message
ratchets, rendezvous, mailbox, route, ACK, and Object Sync keys. Decrypting a
proposal cannot yield `SK_ec`, `SK_scka`, `K_route_master`, an ATSAM root, or a
contact capability.

The exact hybrid KEM/KDF/AEAD freezes only with three-language vectors and
independent cryptographic review. Static identity Ed25519 keys are never used
as encryption secrets. X25519 all-zero/non-contributory output rejects.

### 2.3 Write-only introduction descriptor

`RavenIntroductionDescriptorV1`, signed by the recipient device and referenced
from the verified DeviceSet, contains:

```text
profile/version
recipient_device_certificate_digest
introduction_prekey_digest
provider_set[]
provider_policy_digest
epoch_u64
opaque_write_capability_per_provider
fixed_record_size
per_capability_write_limit
issued_at_ms / expires_at_ms
previous_descriptor_digest?
signature_by_recipient_device
```

The public descriptor contains write capability only. The read capability and
provider-account secret remain protected on the recipient device and are never
returned by ID Resolution. A provider sees an opaque capability, not a Raven
ID, but the deployment must not claim identity unlinkability when resolver and
provider roles collude or share logs.

The recipient creates/registers the capability pair without supplying Raven
identity. Registration and later polling still expose the recipient network
address to a direct provider. The recipient therefore freezes an independent
local `read_privacy_mode` (direct or an exact approved OHTTP profile); a
sender's write mode does not silently choose or strengthen the recipient's
read mode. Provider registration, sender PUT, and recipient poll are three
separate leakage events.

The recipient rotates descriptors/prekeys on expiry, revoke, local policy
change, or provider compromise. Equal generation with different valid bytes is
equivocation and is preserved as bounded evidence.

---

## 3. Proposal and reply records

The exact byte layouts remain open until vector freeze. Unknown mandatory
fields and trailing bytes reject.

### 3.1 `RavenIntroductionProposalV1`

The proposal plaintext sealed to one exact recipient device contains:

```text
profile/version
proposal_id_128
created_at_ms / expires_at_ms
sender_identity_address
sender_identity_public_key
sender_device_certificate_bytes + digest
sender_device_set_snapshot_bytes + digest
recipient_identity_address
recipient_device_certificate_digest
recipient_introduction_prekey_id + digest
optional_display_name                 # bounded, inert text
optional_note                         # bounded UTF-8, no markup/media/URL fetch
reply_descriptor_bytes + digest
anti_replay_nonce
signature_by_sender_identity
signature_by_sender_device
```

The endpoint `object_digest` is SHA-256 of the exact immutable proposal object
bytes defined by the umbrella. Provider/carrier wrapping has a distinct digest.
The outer provider record contains only version, opaque capability routing,
fixed-size padded ciphertext, checked expiry bucket, and provider authorization
material. Sender identity/certificate never appears outside the sealed body.

The bounded DeviceSet snapshot is included so the recipient can verify sender
lineage offline without a request-triggered resolver fetch that leaks which
proposal is being opened. Fresh online evidence may tighten admission when
available, but it cannot replace or weaken the exact signed snapshot binding.

### 3.2 One-time reply lane

Before sending, the sender creates a short-lived
`RavenIntroductionReplyDescriptorV1` with:

- random one-time write capability;
- sender exact identity/device/prekey binding;
- provider set and privacy mode;
- fixed-size policy and one-write maximum;
- expiry and anti-replay identifier; and
- sender-device signature.

Only the read secret is retained locally. The descriptor is inside the sealed
proposal, so the recipient alone learns it. It is not a rendezvous route and
accepts only a response bound to the original proposal digest.

### 3.3 `RavenIntroductionAcceptanceV1`

After an explicit recipient action, an acceptance sealed to the reply prekey
contains:

```text
profile/version
acceptance_id_128
original_proposal_digest
accepted_sender_identity_address
accepting_identity_address
accepting_identity_public_key
accepting_device_certificate_bytes + digest
accepting_device_set_snapshot_bytes + digest
contact_credential_bytes + digest
one_time_rendezvous_invite_bytes + digest
created_at_ms / expires_at_ms
anti_replay_nonce
signature_by_accepting_identity
signature_by_accepting_device
```

An acceptance does not carry a message, reusable route descriptor, session
root, or PairInit. The bounded one-time invite is generated by the accepting
device, bound to the original proposal and usable only **after** the original
sender's local contact commit under Private Rendezvous admission. It closes the
otherwise circular gap between mutual acceptance and first route lookup. It
allows the original sender to verify the exact acceptance, perform its own
local contact commit, and then consume one bootstrap path. Decline is silent by
default; no response is necessary to avoid revealing recipient activity or
confirming registration.

### 3.4 Multi-device fan-out

A proposal is one logical identity request with one `proposal_id`, sealed
separately to a bounded set of current recipient devices. Each copy binds its
exact recipient certificate/prekey. The sender reserves the total device count
and bytes before crypto. A device-level accept references the common proposal
digest and exact accepter device; recipient device synchronization is separate
and cannot cause multiple user-visible requests or multiple contacts.

---

## 4. Privacy modes

The selected mode is frozen in the durable intent. Failure never silently
changes to a more revealing mode.

| Mode | Delivery | Honest disclosure |
|---|---|---|
| `I0_OOB_INVITE` | QR/NFC/file/user-selected authenticated channel | No introduction provider; transfer channel may identify both users |
| `I1_DIRECT_SEALED` | Direct PUT to opaque provider capability | Provider sees sender IP, capability, timing, size |
| `I2_OHTTP_SEALED` | RFC 9458 relay → gateway/provider | Relay sees the caller IP; gateway sees capability; write and read operations select this independently; non-collusion required |
| `I3_MULTI_PROVIDER_SEALED` | Same exact ciphertext to a bounded provider set | Availability only; uncommon sets and timing may increase linkability |
| `I4_FUTURE_ANYTRUST` | Alpenhorn-like metadata-private introduction | Separate protocol, cover traffic, server set, epochs, mobile cost, review required |

There is no public stable inbox keyed by Raven ID, no libp2p Rendezvous
namespace, no DHT `RavenID -> PeerId/address`, and no direct fallback from I2 to
I1. Multi-provider copies do not create authenticity quorum.

OHTTP provides relay/gateway separation, not global anonymity. Padding,
connection reuse, relay behavior, differential treatment, and collusion
assumptions must be pinned by the exact carrier profile.

The UI/privacy record states both sides separately when known: sender write
path and recipient registration/poll path. “Sent with OHTTP” never implies that
the recipient registered or polled anonymously.

---

## 5. End-to-end state machines

### 5.1 Sender: Raven ID to pending request

```text
INPUT_RAVEN_ID
  -> RESOLUTION_VERIFIED
  -> USER_REVIEWS_EXACT_IDENTITY_AND_DISCLOSURE
  -> USER_REQUESTS_CONTACT
  -> CAPACITY_AND_PRIVACY_MODE_RESERVED
  -> REPLY_LANE_CREATED
  -> PROPOSAL_BYTES_BUILT_AND_SIGNED
  -> PER_DEVICE_CANDIDATE_SEAL
  -> OUTBOUND_INTENT_DURABLE
  -> PROVIDER_PUT_EXACT_BYTES
  -> OPTIONAL_EXACT_READBACK_OR_CUSTODY_RECEIPT
  -> OUTGOING_PENDING
```

`OUTGOING_PENDING` is not a contact, chat thread, session, or delivered state.
Provider success proves at most bounded custody. Retry sends identical bytes and
does not regenerate proposal ID, keys, expiry, capability, or ciphertext.

### 5.2 Recipient polling and admission

```text
FOREGROUND_OR_APPROVED_WAKE
  -> POLL_INTENT_DURABLE
  -> FETCH_FIXED_BOUNDED_RECORDS
  -> RESERVE_STRANGER_CAPACITY
  -> STORE_EXACT_CIPHERTEXT
  -> DECRYPT_CANDIDATE
  -> STRICT_PARSE_AND_VERIFY_ALL_BINDINGS
  -> BLOCK_REVOCATION_AND_DEDUP
  -> PROPOSAL_COMMIT
  -> ATTENTION_DECISION_COMMIT
  -> OPTIONAL_INERT_REQUEST_ROW
```

No profile media, URL, rich preview, external font, attachment, call, or remote
fetch occurs. The default Attention outcome is a quiet bounded Requests queue,
not sound/vibration/badge. A user may opt into a stronger local notification
policy, but the sender/provider cannot request it.

Malformed, expired, over-capacity, bad-signature, wrong-recipient, revoked, or
blocked proposals are discarded/quarantined without response. KEM/AEAD errors
are externally indistinguishable.

### 5.3 Recipient action

| Action | Local result | Network result |
|---|---|---|
| Ignore | Keep or expire bounded inert row | None |
| Decline | Durable local tombstone | None by default |
| Block | Sticky local identity/device denial + tombstone | None; unblock never clears revocation |
| Accept | Verify again, durable local `CONTACT_COMMIT` | Stage exact Acceptance on one-time reply lane |

If acceptance delivery fails, the recipient remains one-sided contact and the
UI says “accepted here; waiting for peer”. It retries the same acceptance bytes
until expiry. It must not publish a route or initiate normal messaging merely
because local acceptance succeeded.

### 5.4 Sender receives acceptance

```text
POLL_ONE_TIME_REPLY
  -> FETCH_AND_RESERVE
  -> DECRYPT_CANDIDATE
  -> VERIFY_ORIGINAL_PROPOSAL_AND_ACCEPTANCE_BINDINGS
  -> APPLY_BLOCK_REVOCATION_AND_CURRENT_DEVICESET
  -> DEDUP_EXACT_ACCEPTANCE
  -> CONTACT_COMMIT
  -> CLOSE_REPLY_CAPABILITY
  -> VERIFY_AND_CLAIM_ONE_TIME_RENDEZVOUS_INVITE
  -> PRIVATE_RENDEZVOUS_OR_PAIRINIT_MAY_BE_SCHEDULED
```

Only after this commit may normal PairInit/rendezvous/message work begin on the
sender. Each side owns its own contact decision; network success cannot merge
or forge them. The accepting device may stage/publish only the exact
acceptance-bound one-time invite before learning whether the response arrived;
it must not publish a reusable mutual/session route until normal Private
Rendezvous admission is satisfied.

---

## 6. Abuse, capacity, and attention

Private introduction is deliberately weaker than contact messaging and uses a
physically separate quota class. Exact numbers freeze with vectors, but V1
requires caps for:

- descriptors, providers, recipient devices, proposal bytes, padding and TTL;
- writes per capability/epoch and read pages/records;
- outstanding outgoing and incoming proposals per identity/device/epoch;
- KEM decapsulations, signature checks, decrypt failures, and concurrent work;
- reply capabilities, retries, tombstones, conflict evidence, and protected
  state; and
- total stranger bytes/CPU/notifications independently of contacts, sessions,
  revocations, accepted social repositories, and pending endpoint commits.

Capacity is reserved before public-key or AEAD work. A full stranger lane
returns a generic bounded failure; it never evicts stronger state or increases
provider disclosure to make room.

### 6.1 Provider abuse controls

A provider may enforce fixed byte/TTL/write counts bound to an opaque
capability. It cannot require raw Raven identity, contact graph, message
content, or stable sender account. Rate state is not authenticity or trust.

Optional Privacy Pass/anonymous-rate tokens require a separate approved
issuance/redemption profile. The issuer, attester, origin, relay, metadata,
anonymity set, caching, and collusion assumptions must be explicit. A token can
authorize one bounded write; it cannot create a contact, identify a human, or
grant notification priority.

### 6.2 Recipient controls

The recipient may disable the public introduction descriptor, rotate it,
restrict providers, require OOB-only mode, or set quiet/manual-pull policy.
Blocking a verified sender prevents local admission but cannot stop a Sybil
from resolving the public descriptor; provider and local resource caps remain
necessary. Raven must not advertise “spam free”.

---

## 7. Revocation, expiry, deletion, and conflicts

1. Every operation re-verifies current certificate, prekey, descriptor, block,
   and revocation state before release.
2. Device revoke or descriptor/prekey expiry prevents new proposals and
   quarantines unopened records for that binding.
3. A valid sender signature from a revoked sender device is denied.
4. Equal descriptor generation with different exact bytes is preserved as
   bounded equivocation evidence and disables that lane.
5. Provider deletion is best effort; Raven claims only local secret/tombstone
   destruction and remote TTL expiry, not remote secure erase.
6. Exact duplicate proposal/acceptance bytes are idempotent. Same identifier
   with different authenticated bytes is a terminal conflict, never “latest”.
7. A lower DeviceSet/descriptor generation never rolls local state back.
8. Unblock does not clear accepted RVDR1 state.

---

## 8. Protected state and crash ordering

Protected/durable state includes:

```text
introduction read secrets and prekey private references
descriptor/prekey generation and exact digests
selected mode/provider-set digest
outbound proposal and acceptance exact bytes/digests
reply-lane secret and one-use claim
incoming sealed bytes and verified proposal metadata
contact-commit transition binding
provider page/write cursors and custody evidence
dedup/conflict/tombstone/revocation evidence
quota reservations and retry/release work
```

Secret keys live only in platform-protected storage. SQLCipher stores bounded
metadata and sealed exact bytes. No plaintext file, UserDefaults, generic
Keychain fallback, or provider-log fallback is permitted.

Every mutation uses protected journal + SQL transaction + finalized anchor:

```text
admission snapshot + reserve
  -> protected pending intent
  -> SQL exact bytes/metadata/dedup/quota/contact row as applicable
  -> protected finalized head
  -> clear pending
  -> release provider/UI/PairInit work
```

Network and OS notification calls occur outside mutation leases. Recovery is
idempotent roll-forward and retains exact bytes. It never reuses a prekey,
reply capability, nonce, quota redemption, proposal ID, or acceptance ID, and
never converts a failed introduction into contact/session/message state.

Contact commit and acceptance staging are distinct durable transitions. A
crash after local contact commit but before provider PUT resumes the same
acceptance bytes; a crash after acceptance verification but before sender
contact commit resumes that exact commit and never executes PairInit first.

---

## 9. Carrier and mobile lifecycle

Introduction records are `endpoint_object_bytes`. Provider PUT/GET/page/error
records are application protocols above an opaque carrier; they are not
`carrier_control_bytes` and cannot inspect endpoint semantics.

Terminal may poll providers under an approved service lifecycle. iPhone V1 is
foreground/manual-pull by default. APNs/background wake requires a separate
profile stating what Apple, the provider, and network observers learn; no
silent background-reliability claim is allowed.

Local BLE/mesh does not carry stranger proposals in V1. After an OOB invite or
mutual contact, existing approved Private Rendezvous/carrier rules apply. An
Internet provider is not a mandatory Raven server: users may select compatible
providers, run their own, or use OOB-only mode, but each enabled provider must
pass the same conformance and privacy gates.

---

## 10. User experience and commands

The product flow must say what has and has not happened:

```text
ash resolve <RavenID>
  -> show exact identity/device evidence and privacy choices

ash contact request <RavenID> --privacy=ohttp
  -> "Request queued; this person is not yet a contact"

ash contact pending
  -> outgoing pending / incoming quiet requests / expired
```

`ash send <RavenID>` remains forbidden without a committed contact and valid
session. A request cannot create a normal chat row with a fake “sent” message.
The UI distinguishes:

- `Request stored for delivery` (provider custody only);
- `Request accepted here; waiting for peer` (one-sided contact);
- `Mutual contact established` (both verified commits); and
- `Secure session ready` (PairInit/response confirmed).

No UI text says online, delivered, read, anonymous, spam-free, or mutually
connected without the corresponding evidence.

---

## 11. Failure and downgrade matrix

| Condition | Required result |
|---|---|
| Resolution unavailable/ambiguous/stale/split-view | No proposal, provider write, or contact mutation |
| Descriptor/prekey missing | Explain “this identity does not accept network requests”; offer OOB only |
| Direct mode fails | No silent OHTTP/public/DHT fallback |
| OHTTP relay/gateway fails | No direct fallback without a new explicit user intent |
| Provider returns success then loses bytes | Outgoing remains pending; no delivered claim |
| Wrong recipient/prekey/cert/device generation | Reject without response |
| KEM/AEAD/signature failure | No parse/state/contact side effects; generic error |
| Same proposal ID, same bytes | Idempotent; one local row |
| Same proposal ID, different authenticated bytes | Preserve bounded conflict; terminal deny |
| Request flood/capacity exhausted | Reject weak lane; protected/contact state unaffected |
| Recipient accepts; acceptance lost | Local one-sided contact + exact retry; no PairInit |
| Acceptance forged/replayed/wrong proposal | No contact commit or reply-capability advance |
| Contact deleted/block/revoke during pending | Cancel/quarantine; no session or route release |
| App crash at any durable boundary | Roll-forward exact mode/bytes; no reuse/downgrade |

---

## 12. Vectors, simulation, and physical acceptance

Before `APPROVED`, shared vectors must make Python, Rust, and Swift compute—not
merely parse—the same:

- descriptor/prekey signatures, binding digests, hybrid seal/open, padding;
- proposal/acceptance exact bytes, outer provider records, object/carrier
  digests, one-time reply derivation and all-zero rejection;
- strict lengths, unknown fields, trailing bytes, invalid UTF-8/time/caps;
- DeviceSet/cert/prekey/revoke/block/recipient binding negatives;
- duplicate, ID collision, provider equivocation, reply replay and expiry;
- privacy-mode no-downgrade and direct/OHTTP disclosure classification;
- reserve-before-crypto and stranger-quota non-interference;
- every protected-journal/SQL/finalize/clear/release crash boundary; and
- one-sided accept, lost acceptance, exact retry, mutual commit, then PairInit
  scheduling without early session work.

A deterministic 1,000-node model includes Sybil floods, popular-recipient hot
spots, provider partitions/collusion labels, descriptor rotation, multi-device
fan-out, mobile offline periods, reply loss, duplicate carriers, quota
exhaustion, and strong-state starvation attempts. A model is not live-network
evidence.

Physical acceptance requires at least:

| Scenario | Required evidence |
|---|---|
| Terminal A → Terminal B | Raven ID resolve → request → quiet inbox → accept → acceptance → mutual contact → PairInit/message/ACK |
| Terminal → iPhone | Direct and OHTTP modes separately; foreground/manual pull; kill/relaunch exact retry |
| iPhone → Terminal | Same, including one-sided acceptance state |
| iPhone A → iPhone B | **Two physical iPhones**; request/accept/loss/retry/block/revoke; no simulator substitution |
| OOB-only | QR/file one-time invite with all provider traffic absent |
| Negative privacy | Packet/provider/log/disk audit proving no Raven ID/sender identity in provider record and no forbidden fallback |

One physical iPhone can validate Terminal↔iPhone and local protected-state
paths. It cannot close iPhone↔iPhone claims.

---

## 13. Production holds and approval

Production remains disabled until all of the following are independently
reviewed and passed:

1. umbrella registration and re-approval of exact record classes;
2. approved ID Resolution, DeviceSet/certificate/revocation and Attention;
3. cryptographic wire/KDF/vector freeze in all three languages;
4. exact provider, direct, OHTTP and optional anonymous-rate profiles;
5. durable SQLCipher/protected-state crash matrix on supported platforms;
6. provider implementation/conformance with no identity/contact/content logs;
7. 1,000-node resource/abuse simulation and adversarial review;
8. physical matrix, including two iPhones for iPhone↔iPhone claims;
9. UI/accessibility review of privacy disclosure, quiet requests, block and
   one-sided acceptance; and
10. independent security/privacy review or a recorded protocol-owner waiver.

No companion may override the umbrella's byte classes, immutable endpoint
objects, ACK-after-commit rule, contact authority, carrier opacity, or
production holds.

---

## 14. Research foundations (informative only)

Raven claims no wire compatibility with these systems:

- [Signal sealed sender](https://signal.org/blog/sealed-sender/) — separates
  recipient delivery from sender identity using certificates and delivery
  tokens, while explicitly leaving IP/timing correlation as future work.
- [Signal message requests](https://signal.org/blog/message-requests/) and
  [spam controls](https://signal.org/blog/keeping-spam-off-signal/) — unknown
  senders require a distinct user-consent and abuse lane; signatures/E2EE alone
  do not solve attention abuse.
- [Alpenhorn](https://www.usenix.org/conference/osdi16/technical-sessions/presentation/lazar)
  — metadata-private bootstrapping with stronger server/traffic assumptions;
  inspiration for future I4, not a V1 claim.
- [RFC 9458 — Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458.html) —
  relay/gateway separation with explicit non-collusion, differential-treatment,
  padding, replay and traffic-analysis limits.
- [RFC 9576 — Privacy Pass Architecture](https://www.rfc-editor.org/rfc/rfc9576.html)
  — privacy-preserving authorization roles and the need to state issuance,
  redemption, metadata and collusion assumptions.

---

## 15. Open decisions before vector freeze

1. Exact descriptor, prekey, proposal, reply, acceptance and provider-record
   encodings.
2. Exact hybrid KEM/KDF/AEAD and whether the introduction prekey is single-use,
   count-bounded, or time-bounded under each provider mode.
3. Fixed padded record sizes that remain practical on BLE, relay and mobile
   providers without creating a size fingerprint.
4. Provider write/read capability construction, registration, rotation,
   readback, page and collision semantics.
5. OHTTP key distribution, relay/gateway selection, padding and collusion UI.
6. Whether any Privacy Pass/ARC profile is mature and sufficiently decentralized.
7. Recipient device fan-out cap and cross-device dedup/accept synchronization.
8. Default proposal TTL, note length, stranger quotas, quiet notification
   policy and accessibility behavior.
9. Background iOS wake privacy and reliability; V1 defaults to foreground.
10. Provider portability, self-host configuration and multi-provider leakage.

---

## 16. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial research architecture: separates ID resolution, inert private proposal, local contact commits, private rendezvous and sessions; adds distinct introduction prekeys, write-only recipient descriptors, one-time sealed acceptance lane, honest direct/OHTTP/anytrust privacy tiers, quiet Attention admission, crash/resource rules, three-language vectors, simulation and physical production holds |
