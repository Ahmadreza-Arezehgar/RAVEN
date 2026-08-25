# RAVEN Social Repository Authority V1

**Profile:** `raven/social-repository-authority/v1`
**Version:** 1
**Document revision:** 3
**Date:** 2026-08-21
**Status:** **REQUIRED / NOT YET APPROVED**
**Production:** **disabled** — this document authorizes no repository creation,
writer grant, retirement, public post, contact/circle post, source, Object Sync
eligibility, codec, database migration, live callsite, carrier, or Release flag
**Depends on:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md)
**Approved**; [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md)
**Approved**; [`RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md`](RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md),
[`RAVEN_SOCIAL_OBJECT_WIRE_V1.md`](RAVEN_SOCIAL_OBJECT_WIRE_V1.md), and
[`RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md`](RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md)
**NOT YET APPROVED**
**Revision-1 identity scope:** frozen Raven Identity V1 only. Continuity V2
values are reserved and reject until that companion and new vectors are approved.

This companion freezes the authority plane behind a Raven social repository:

- who owns one stable repository;
- which audience policy its records bind;
- which exact certified device may author which record kinds;
- how authority is explicitly retired without treating omission as revocation;
- how stale or equivocating sources fail without electing a server, relay,
  timestamp, digest ordering, mirror quorum, or blockchain.

It defines five exact byte families and one derivation-only genesis core:

| Family | Role |
|---|---|
| `RVSP1` | bounded schema/resource policy |
| `RVAP1` | exact current audience policy; its digest is `audience_commitment` |
| `RVSG1` | derivation-only immutable repository genesis core |
| `RVSD1` | identity-signed repository descriptor chain |
| `RVWG1` | identity-signed writer grant/policy event |
| `RVWR1` | identity-signed writer retirement/policy event |

> Raven's safety asymmetry is deliberate: **deny evidence applies eagerly;
> new authority activates slowly**. A valid retirement or Device Revocation
> blocks new admission as soon as it is verified. A new grant remains pending
> until an identity-signed descriptor activates a policy-chain head that includes
> it. A stale mirror can therefore delay publishing, but cannot silently reopen
> or invent publishing authority.

---

## 0. Normative boundary and non-goals

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**,
and **MAY** are interpreted as in BCP 14 when capitalized.

This document does not:

- create a global log, consensus protocol, blockchain, mandatory PDS, home
  server, relay quorum, moderator, or repository-completeness oracle;
- freeze source hints, head announcements, writer segments, repository drops,
  media, Continuity V2, or MLS/circle authority;
- use time, mirror count, source popularity, network arrival, follower count,
  handle, DNS name, relay peer ID, or carrier identity as authority;
- allow descriptor omission to revoke a writer or old-source omission to erase
  a locally pinned policy event;
- let a writer grant clear Device Revocation, local block, descriptor conflict,
  identity-continuity conflict, or a prior retirement;
- turn codec validity into social admission, reach, ranking, notification,
  delivery, or contact consent;
- amend Full Braid Slice 3 protected storage or any production hold.

Artifact classes are deliberately different:

- `RVSG1` is derivation-only and is never transported;
- `RVSP1` and `RVAP1` are referenced evidence blobs, not independently
  authoritative endpoint objects; a contact `RVAP1` exposes both participants
  and MUST NOT enter a public source, public inventory, public fetch, or carrier
  control plane;
- public-audience `RVSD1`/`RVWG1`/`RVWR1` are public-authenticated
  endpoint-record candidates only after the umbrella explicitly registers the
  families;
- contact-audience authority bytes are private evidence and may move only inside
  the approved contact/session sealing profile for the exact audience.

Until those registrations and profiles are approved, every family is lab/vector
bytes and MUST NOT enter carriers or public sources.

Two independent green bars are mandatory:

```text
RVRA_CODEC_CONFORMANT   # exact bytes/signature/digest are valid
RVRA_AUTHORITY_ADMITTED # local trust, chain, audience, revoke, policy and pins commit
```

The first never implies the second. A self-signed public repository owned by an
unknown identity may be cryptographically authentic while remaining outside all
subscriptions, contacts, feeds, rankings, notifications and Object Sync
eligibility. Contact-class authority is not even an unknown-public candidate: it
requires the existing local contact plus exact contact-space evidence before
admission. Neither outcome creates a contact, PairInit, follow or capability.

---

## 1. Common canonical rules

All five wire families use Raven Canonical Binary:

- unsigned integers are big-endian;
- every variable field has one explicit length/count;
- all arithmetic and global caps are checked before allocation;
- unknown schema, identity profile, audience class, flags, policy bits, reason,
  or trailing bytes reject;
- arrays with set semantics are bytewise sorted and unique;
- parsers preserve exact bytes and never regenerate authoritative objects from
  a normalized model;
- supplied digests are comparisons only; the Endpoint recomputes every digest;
- same digest/different exact bytes enters collision quarantine; no winner;
- exact replay is idempotent and cannot repeat a mutation or notification.

For Revision 1:

```text
identity_profile = 1              # Frozen Identity V1
owner_address_len = 44
owner_address = canonical lowercase RavenAddressV1 ASCII
owner_identity_ed_pub = exact 32-byte key that derives owner_address
audience_class = 0 public | 1 contact
audience_class = 2 circle         # reserved and MUST reject
```

Every signature uses ordinary Ed25519 over the exact domain-separated input,
not Ed25519ph, JSON, CBOR, an in-memory struct, or a supplied digest.

---

## 2. Exact schema policy `RVSP1`

`RVSP1` is an unsigned exact policy object referenced by an identity-signed
audience policy/descriptor. It is exactly **96 bytes**.

```text
offset  size  field
0       5     magic = ASCII "RVSP1"
5       1     schema_rev = 1
6       2     flags_u16be = 0
8       4     total_len_u32be = 96
12      2     allowed_record_kind_bits_u16be
14      2     allowed_payload_profile_bits_u16be
16      4     max_record_len_u32be
20      4     max_text_len_u32be
24      2     max_repo_parent_count_u16be
26      2     max_relation_count_u16be
28      2     max_media_ref_count_u16be
30      2     reserved = 0
32      32    media_profile_digest or zero
64      32    extension_registry_digest or zero
```

Bit `n-1` in `allowed_record_kind_bits` corresponds to RVSR1 kind value `n`
for `1..11`; bits 11–15 are zero. Bit `n` in payload bits corresponds to
payload profile `n`; only bits 0–1 exist in this revision. A set bit never
approves an otherwise unapproved kind/profile.

Every limit is nonzero where its selected kinds require that resource, no larger
than Social Object Wire absolute limits, and no larger than the enclosing
endpoint/carrier profile. `max_text_len <= max_record_len`. A nonzero media or
extension digest requires an approved exact companion; otherwise it rejects.

Slice-A's only admissible fixture policy is:

```text
allowed_record_kind_bits  = 0x0007       # POST, REPLY, EDIT
allowed_payload_bits      = 0x0002       # RVTX1 only
max_record_len            = 262144
max_text_len              = 245760
max_repo_parent_count     = 16
max_relation_count        = 16
max_media_ref_count       = 0
media_profile_digest      = zero
extension_registry_digest= zero
```

```text
schema_policy_digest = SHA-256(exact RVSP1 bytes)
```

`RVSP1` is not independently authoritative, an endpoint object, a grant, or a
source request. It becomes relevant only through an admitted `RVAP1` digest in
an admitted descriptor.

---

## 3. Audience root and current audience policy

### 3.1 Derivation-only audience root `RVAG1`

The audience root is stable across policy-generation and schema-limit changes.
Its exact core is:

```text
offset  size  field
0       5     magic = ASCII "RVAG1"
5       1     schema_rev = 1
6       1     audience_class
7       1     identity_profile = 1
8       2     participant_count_u16be
10      2     reserved = 0
12      32    stable_space_id
44      44*n  sorted participant RavenAddressV1 bytes
```

```text
audience_root_digest = SHA-256(
    ASCII "raven/social/audience-root/v1"
 || u32be(len(RVAG1_core))
 || RVAG1_core
)
```

Rules:

| Class | `stable_space_id` | Participants |
|---|---|---|
| `public` | zero for an unscoped public repo, or a nonzero approved topic/space ID | exactly zero |
| `contact` | exact nonzero stable `contact_space_id` from approved contact evidence | exactly two distinct sorted canonical addresses, one equal to owner |
| `circle` | future exact circle ID | disabled in Revision 1 |

For Revision 1, public `stable_space_id = zero` is the only authority-admissible
form. A nonzero value is reserved for a later exact topic/space companion: a
strict codec may preserve it as bounded future evidence, but it MUST NOT reach
`RVRA_AUTHORITY_ADMITTED`, public fetch eligibility, grouping or ranking. This
prevents an unauthenticated arbitrary 32-byte label from masquerading as topic
membership or namespace ownership.

Changing class, stable space, or participant set creates a different audience
root and therefore a different repository. Session IDs, device IDs, ratchet
keys, routes, relays, mailbox tags, and carrier paths never enter the root.

### 3.2 Current audience policy `RVAP1`

`RVAP1` is unsigned exact policy bytes bound by an `RVSD1`. Its prefix is 90
bytes and its total length is `90 + 44 * participant_count`.

```text
offset  size  field
0       5     magic = ASCII "RVAP1"
5       1     schema_rev = 1
6       1     audience_class
7       1     identity_profile = 1
8       2     flags_u16be = 0
10      4     total_len_u32be
14      8     audience_generation_u64be
22      2     participant_count_u16be
24      2     reserved = 0
26      32    stable_space_id
58      32    schema_policy_digest
90      44*n  sorted participant RavenAddressV1 bytes
```

`audience_generation` starts at 1. If exact RVAP1 bytes change within one
repository, generation increments by exactly one. If bytes do not change,
generation does not change. Its class/root inputs must reproduce the repository's
immutable `audience_root_digest`.

```text
audience_commitment = SHA-256(exact RVAP1 bytes)
```

This is the exact 32-byte commitment carried by RVSR1 and RVWG1. A new
generation does not by itself change `repo_id`, but old grants cannot mint new
records under the new commitment. Existing exact historical records retain the
audience evidence under which they were admitted. For contact repos, changing
the two participants or `contact_space_id` is not a generation update; it is a
new audience root/repository.

---

## 4. Repository genesis and `repo_id`

### 4.1 Derivation-only `RVSG1`

`RVSG1` is not transmitted as an endpoint object. For V1 it is exactly 152
bytes:

```text
offset  size  field
0       5     magic = ASCII "RVSG1"
5       1     schema_rev = 1
6       1     identity_profile = 1
7       1     audience_class
8       2     owner_address_len_u16be = 44
10      2     reserved = 0
12      32    genesis_nonce
44      32    audience_root_digest
76      32    owner_identity_ed_pub
108     44    owner_address
```

```text
repo_id = SHA-256(
    ASCII "raven/social/repo-id/v1"
 || u32be(152)
 || exact RVSG1 bytes
)

repo_genesis_core_digest = SHA-256(exact RVSG1 bytes)
```

`genesis_nonce` is nonzero CSPRNG output. RNG failure, an all-zero nonce, or a
detected owner-local nonce collision refuses creation. Time, handle, device ID,
certificate, source, policy digest, descriptor sequence, mutable operational
locator, or server URL is not a nonce substitute.

Writer policy, current audience generation/schema, source hints, and descriptor
validity are excluded from `repo_id`; otherwise rotation would change the repo
or create circular derivations. Owner identity/address, immutable audience root,
profile, and nonce substitution must change `repo_id` in vectors.

`repo_genesis_core_digest` is the non-circular genesis binding carried by writer
policy events. It is deliberately distinct from the sequence-1 descriptor
digest: descriptor 1 may name writer-policy event 1, so making that policy event
name descriptor 1 would create an impossible digest cycle. A verifier
reconstructs exact `RVSG1`, checks both the core digest and `repo_id`, and never
accepts one as a substitute for the other.

---

## 5. Repository descriptor `RVSD1`

### 5.1 Exact layout

`RVSD1` has a 330-byte prefix followed by the V1 owner address and signature.
Revision-1 total length is exactly **438 bytes**.

```text
offset  size  field
0       5     magic = ASCII "RVSD1"
5       1     schema_rev = 1
6       1     identity_profile = 1
7       1     audience_class
8       2     flags_u16be
10      4     total_len_u32be = 438
14      8     descriptor_seq_u64be
22      8     not_before_ms_u64be
30      8     not_after_ms_u64be
38      2     owner_address_len_u16be = 44
40      2     reserved = 0
42      32    repo_id
74      32    genesis_nonce
106     32    genesis_descriptor_digest or zero
138     32    previous_descriptor_digest or zero
170     32    audience_root_digest
202     32    audience_policy_digest
234     32    writer_policy_head_digest or zero
266     32    continuity_control_digest = zero in V1
298     32    owner_identity_ed_pub
330     44    owner_address
374     64    owner_identity_signature
```

Flag bit 0 is `WRITER_POLICY_HEAD_PRESENT`; bits 1–15 are zero. Presence must
match a nonzero head digest; absence requires zero.

### 5.2 Signature and digest

Let `unsigned_descriptor` be bytes 0–373:

```text
descriptor_signature_input =
    ASCII "raven/social/repo-descriptor/signature/v1"
 || u32be(len(unsigned_descriptor))
 || unsigned_descriptor

descriptor_digest = SHA-256(exact RVSD1 bytes)
```

The signature verifies under `owner_identity_ed_pub`, whose canonical V1 address
must reproduce `owner_address`. Source signatures do not substitute.

### 5.3 Genesis and successor rules

For descriptor sequence 1:

- `genesis_descriptor_digest` and `previous_descriptor_digest` are zero;
- exact `RVSG1` reconstruction reproduces `repo_id`;
- `audience_policy_digest` resolves to RVAP1 with generation 1 and matching root;
- writer head may be absent, in which case no social writer is active.

If descriptor 1 names writer grant 1, verification is one candidate bundle—not
two independently activated mutations:

1. verify RVSP1/RVAP1/RVSG1, grant 1 and descriptor 1 exact bytes/signatures;
2. require grant 1 to bind the reconstructed `repo_genesis_core_digest`, repo,
   audience commitment, owner, certificate and a validity window contained by
   candidate descriptor 1;
3. require descriptor 1's head to equal grant 1's exact digest;
4. classify replay/conflict/capacity for both artifacts without promotion;
5. commit descriptor pin, policy slot 1 and derived grant activation atomically.

Failure or crash before that commit leaves neither artifact ACTIVE. A node may
retain bounded authentic pending bytes for later evidence completion, but it
cannot expose a half-activated repository or writer.

For sequence `n>1`:

- sequence is prior sequence plus one, without wrap;
- `genesis_descriptor_digest` equals exact sequence-1 descriptor digest;
- `previous_descriptor_digest` equals exact digest at `n-1`;
- owner/profile/repo/genesis nonce/audience class/root never change;
- audience policy is exact replay or generation increments by one;
- writer-policy head is exact replay or a verified descendant of the prior head;
  after a nonzero head, it never returns to zero.

`not_before_ms < not_after_ms`; verification uses `[not_before, not_after)`.
Default duration is at most 90 days and absolute duration at most 366 days.
Expiry is an authorization ceiling, not proof that a source is globally fresh.
After greatest pinned descriptor expiry, new admission pauses; it never falls
back to an older descriptor. A refresh may keep the same policy digests.

Exact replay is idempotent. Same descriptor sequence/different exact bytes is
authenticated conflict. A gap is buffered within caps but does not advance the
pin. A later branch does not choose a winner by digest/time/source count; the
repo pauses new grants and new automatic social admission beyond the common
prefix until an approved repair/re-trust profile resolves the conflict.

---

## 6. Writer grant `RVWG1`

### 6.1 Exact layout

`RVWG1` has a 366-byte prefix, owner address, device ID, and signature:

```text
offset  size  field
0       5     magic = ASCII "RVWG1"
5       1     schema_rev = 1
6       1     identity_profile = 1
7       1     audience_class
8       2     flags_u16be = 0
10      4     total_len_u32be = 474 + device_id_len
14      8     policy_seq_u64be
22      8     not_before_ms_u64be
30      8     not_after_ms_u64be
38      2     owner_address_len_u16be = 44
40      2     device_id_len_u16be
42      2     allowed_record_kind_bits_u16be
44      2     reserved = 0
46      32    repo_id
78      32    repo_genesis_core_digest
110     32    previous_writer_policy_digest or zero
142     32    audience_root_digest
174     32    audience_policy_digest
206     32    device_cert_digest
238     32    device_ed_pub
270     32    device_x_pub
302     32    continuity_control_digest = zero in V1
334     32    owner_identity_ed_pub
366     44    owner_address
410     d     device_id UTF-8 bytes (1..64)
410+d   64    owner_identity_signature
```

The total is `474+d` and therefore `475..538` bytes. Device-ID byte validity and
exact comparison follow Device Revocation V1. No normalization, case mapping,
display alias, or suffix is permitted.

### 6.2 Signature and policy digest

Let `unsigned_grant` end immediately before its signature:

```text
grant_signature_input =
    ASCII "raven/social/writer-grant/signature/v1"
 || u32be(len(unsigned_grant))
 || unsigned_grant

writer_grant_digest = SHA-256(exact RVWG1 bytes)
writer_policy_digest = writer_grant_digest
```

The identity signature, canonical owner address, exact device certificate
digest, device ID, Ed25519 key, X25519 key, audience root/policy, repo and
repository genesis core must all agree. `allowed_record_kind_bits` is nonzero and a
subset of the resolved RVSP1 kinds. It cannot authorize a disabled payload,
media/extension profile, capability, or community role.

If any allowed bit authorizes an RVSR1 social kind, `device_id` MUST also satisfy
the Social Object Wire authoring subset: exact certificate UTF-8 bytes of length
1..64, valid UTF-8, and no Unicode scalar with General Category `Cc` or `Cf`.
This prevents an identity-valid but permanently unusable social grant. It does
not normalize or rewrite the certificate field.

The validity window is nonempty, within both device-certificate and activated
descriptor ceilings, and at most 366 days. A grant may be reissued before expiry
through a higher policy event; old omission is not retirement.

---

## 7. Writer retirement `RVWR1`

### 7.1 Exact layout

`RVWR1` has a 390-byte prefix, owner address, device ID, and signature:

```text
offset  size  field
0       5     magic = ASCII "RVWR1"
5       1     schema_rev = 1
6       1     identity_profile = 1
7       1     audience_class
8       2     flags_u16be = 0
10      4     total_len_u32be = 498 + device_id_len
14      8     policy_seq_u64be
22      8     issued_at_ms_u64be (advisory)
30      2     owner_address_len_u16be = 44
32      2     device_id_len_u16be
34      2     reason_code_u16be
36      2     reserved = 0
38      32    repo_id
70      32    repo_genesis_core_digest
102     32    previous_writer_policy_digest
134     32    target_writer_grant_digest
166     32    audience_root_digest
198     32    target_audience_policy_digest
230     32    device_cert_digest
262     32    device_ed_pub
294     32    device_x_pub
326     32    continuity_control_digest = zero in V1
358     32    owner_identity_ed_pub
390     44    owner_address
434     d     device_id UTF-8 bytes (1..64)
434+d   64    owner_identity_signature
```

The total is `498+d`, hence `499..562` bytes. Reason codes:

| Value | Meaning |
|---:|---|
| 1 | owner-requested retirement |
| 2 | certificate renewal/replacement |
| 3 | suspected compromise |
| 4 | audience/policy migration |

Unknown or zero reason rejects. It is explanatory and does not change safety.

### 7.2 Signature and digest

```text
retirement_signature_input =
    ASCII "raven/social/writer-retirement/signature/v1"
 || u32be(len(unsigned_retirement))
 || unsigned_retirement

writer_retirement_digest = SHA-256(exact RVWR1 bytes)
writer_policy_digest = writer_retirement_digest
```

A retirement requires policy sequence at least 2, nonzero previous/target
digests, and the owner's identity signature. When target grant evidence is
available, all repo/audience/device/certificate/key fields must match it exactly.
Without target bytes, the exact target-grant digest is still a sticky deny for
records that present that digest, while lineage-wide effects remain pending
until the grant/certificate binding is verified.

`issued_at_ms` never proves that a record was minted before retirement. Learning
a valid retirement denies every **new** admission under the target grant,
regardless of advisory record time. Already admitted history retains exact
evidence and follows local display/warning policy.

---

## 8. One global writer-policy chain

RVWG1 and RVWR1 share one append-only sequence per repository:

```text
policy_slot = (repo_id, policy_seq_u64)
policy_digest = SHA-256(exact RVWG1 or RVWR1 bytes)
```

Rules:

1. Sequence starts at 1 with RVWG1 and zero previous digest.
2. Every later event increments by exactly one and binds the immediately prior
   exact policy digest; no wrap.
3. Exact slot/bytes is replay. Same slot/different authenticated bytes is policy
   conflict; no digest/time/source-count winner.
4. A gap is bounded incomplete evidence and cannot activate later grants.
5. Omission is no-op. Only RVWR1 or Device Revocation removes future authority.
6. A retired but non-device-revoked certificate may receive a later RVWG1 with
   a new grant digest. Its RVSR1 device lineage continues at its next sequence;
   it never restarts at 1.
7. Device Revocation wins over every descriptor, grant, re-grant, timestamp, or
   source replay and cannot be cleared by this policy chain.
8. A local block may deny admission/display/dial independently and is not
   serialized into public policy.

### 8.1 Grant activation barrier

A cryptographically valid RVWG1 first enters `VERIFIED_PENDING_ACTIVATION`.
It becomes `ACTIVE` only after an admitted nonexpired RVSD1 in the same
descriptor chain names a `writer_policy_head_digest` equal to that grant or a
verified descendant. A stale or malicious source cannot activate it by merely
serving the grant.

### 8.2 Eager deny barrier

A valid RVWR1 or RVDR1 enters durable deny state before any descriptor catch-up.
This asymmetry is monotonic: stale descriptor omission cannot reopen the target.
If subsequent evidence proves an authenticated policy conflict, the affected
policy suffix remains paused/quarantined; deny evidence is retained rather than
rolled back.

### 8.3 Descriptor/policy relationship

Every nonzero descriptor writer head must resolve through one valid contiguous
policy chain. A newer descriptor cannot point behind the greatest locally pinned
head. A source may omit intermediate events from one response, but admission
waits for them. A descriptor update that changes audience policy requires new
grants bound to the new commitment before devices can mint new RVSR1 records.

The first nonzero policy head is non-circular: grant 1 binds
`repo_genesis_core_digest`, then descriptor 1 or a later descriptor binds grant
1's digest. No RVWG1/RVWR1 ever binds `genesis_descriptor_digest`.

---

## 9. Admission state machine

### 9.1 Artifact verification

```text
host admission lane + byte/count/cost reservation
  -> strict canonical parse + digest recomputation
  -> owner address/public-key self-consistency
  -> exact owner identity signature over supplied bytes
  -> RVRA_CODEC_CONFORMANT
  -> local contact/subscription/block/Attention eligibility
  -> bounded locally available certificate/revocation/control/policy evidence
  -> chain predecessor/genesis/audience/schema binding
  -> candidate replay/gap/conflict classification
  -> one durable artifact/evidence/pin/derived-state transaction
  -> RVRA_AUTHORITY_ADMITTED
```

Signature verification happens before parsing or loading any larger referenced
certificate/policy bundle. Before that work, unknown public owners consume a
separate Attention Firewall byte/signature budget; a contact artifact requires
the already accepted local contact. No step performs an ambient network lookup
under the mutation lease. Missing predecessors/evidence become bounded fetch
needs outside the lease, eligible only under the public/contact privacy policy
that already authorized that class. A request produced from missing contact
evidence must never reveal the contact space, participants, repo or digest to a
public source.

### 9.2 Repository state

At minimum, durable state retains:

- exact sequence-1 descriptor and greatest verified descriptor pin;
- every bounded descriptor/policy conflict branch and common prefix;
- exact audience/schema policies referenced by admitted records;
- greatest contiguous policy head and pending grants;
- sticky retirements and Device Revocation union;
- per-grant activation state and validity ceiling;
- historical descriptor/grant/cert/control digests for admitted RVSR1 records;
- missing/gap/collision abuse budgets and local block state separately.

### 9.3 Applying an RVSR1 record

An RVSR1 reaches `RVSR1_ADMISSION_AUTHORIZED` only when:

1. `repo_id`, audience class/root/current commitment, descriptor genesis and
   owner match the greatest nonconflicting descriptor evidence;
2. `author_writer_grant_digest` resolves to an ACTIVE RVWG1;
3. grant lineage, certificate, kind bit, audience policy and validity agree;
4. neither target grant nor device lineage is retired/revoked/blocked;
5. writer predecessor/gap/conflict and record signature rules pass;
6. exact record/admission evidence commits before any view eligibility.

Public transfer, cache storage, signature validity, codec conformance, mirror
count, or a writer grant alone never reaches this state.

---

## 10. Rollback, conflicts, partitions, and repair

### 10.1 Anti-rollback pins

The following never decrease silently:

- greatest verified descriptor sequence/digest;
- greatest contiguous writer-policy sequence/digest;
- audience generation for the same audience root;
- sticky target-grant retirement set;
- Device Revocation union;
- per-writer RVSR1 lineage frontier and authenticated conflict evidence.

Restoring older app data, replaying a stale source response, uninstalling a
mirror, re-following, or changing carrier cannot lower these pins. The durable
storage companion must bind them to protected-anchor/SQLCipher rollback evidence.

### 10.2 Honest concurrency versus equivocation

Independent certified social writers may create concurrent RVSR1 branches.
That is normal DAG concurrency. Descriptor sequence and global writer-policy
sequence are identity-authority slots; two different valid bytes in one exact
slot are equivocation/conflict. Raven retains evidence and pauses the affected
authority suffix rather than applying last-write-wins.

### 10.3 No false global freshness

Revocation, retirement, descriptor successor, and audience-policy knowledge are
eventual under partition. Raven can prove what exact greatest evidence a device
has pinned, not that the entire network has seen the latest event. UI must not
claim instant global unpublish, writer removal, recovery, or audience update.

### 10.4 Repair boundary

Revision 1 does not invent automatic conflict repair. Repair requires a later
exact identity-authorized artifact that names every conflicting digest/common
prefix, proves current identity-continuity authority, and is accepted under an
explicit re-trust policy. Deleting one branch, choosing lexicographic digest,
newest timestamp, most mirrors, or first arrival is forbidden.

Certificate-Transparency-style Merkle consistency proofs may accelerate a
future batched public policy log, but Raven does not require or trust a global
log in V1. Comparing signed pins exposes split views only after peers exchange
them; absence of a conflict report is not proof none exists.

---

## 11. Resource ceilings

Later profiles may tighten but never exceed:

| Resource | Default | Absolute |
|---|---:|---:|
| RVSP1 | 96 bytes | 96 bytes |
| RVAP1 participants | public 0 / contact 2 | 2 in V1 |
| RVSD1 | 438 bytes | 438 bytes in V1 |
| RVWG1 | 475..538 bytes | 538 bytes |
| RVWR1 | 499..562 bytes | 562 bytes |
| Descriptor validity | 90 days | 366 days |
| Grant validity | 90 days | 366 days and enclosing cert/descriptor ceiling |
| Buffered descriptor gaps/repo | 8 | 64 |
| Buffered policy gaps/repo | 32 | 256 |
| Conflict branches/slot | 2 | 8, then identity-level quarantine |
| Pending unactivated grants/repo | 32 | 256 |
| Retained active/retired grants/repo | 64 | 1024 under global protected-store cap |
| Unknown-owner authority bytes/day | 16 KiB | 256 KiB under Attention policy |

Capacity exhaustion refuses new authority without evicting active grants,
retirements, revocations, descriptor/policy pins, conflicts, or historical
evidence required by admitted records. Unknown sources never evict trusted work.

---

## 12. Failure and downgrade matrix

| Input/event | Required outcome |
|---|---|
| Unknown magic/schema/profile/class/flag/bit/reason/trailing bytes | Reject before mutation |
| Length overflow/truncation/wrong exact total | Reject before allocation/signature |
| Noncanonical address/device/participant order | Reject; never normalize/re-sign |
| All-zero/reused genesis nonce | Refuse owner-local creation |
| Repo derivation or owner-address mismatch | Reject |
| Valid signature/codec but no local trust/subscription lane | Authentic bounded evidence only; no authority/feed/sync eligibility |
| Contact authority without existing exact local contact | Reject before evidence fetch; no public lookup |
| Public nonzero `stable_space_id` in Revision 1 | Preserve only as bounded future codec evidence; authority admission rejects |
| RVAP1 root mismatch or generation gap | Bounded incomplete/reject; no widen |
| Descriptor exact replay | Idempotent |
| Descriptor same sequence/different bytes | Authenticated conflict; pause suffix |
| Descriptor gap or expired greatest pin | Pause new admission; never fall back |
| Policy exact replay | Idempotent |
| Policy same sequence/different bytes | Authenticated conflict; pause suffix |
| Policy gap | Pending; no grant activation |
| Valid grant not activated by descriptor head | `VERIFIED_PENDING_ACTIVATION` only |
| Descriptor omits old grant | No retirement; retain evidence |
| Retirement learned before descriptor update | Eager sticky deny |
| Grant after retirement, higher sequence | May activate only as a new digest after descriptor activation and only if device not revoked |
| Device Revocation plus later grant | Revocation wins; deny |
| Grant ability wider than RVSP1 | Reject grant |
| Grant/audience policy mismatch | Reject grant/record |
| Record kind outside grant | Deny RVSR1 admission |
| Advisory time claims pre-retirement minting | No authority; new admission denied |
| Stale/malicious mirror/source | Availability failure only; cannot lower pins |
| Source serves valid signature without full chain | Authentic pending bytes only |
| Digest collision | Durable quarantine; no winner |
| Local block | Local deny; never serialized as public global authority |
| `RVRA_CODEC_CONFORMANT` but admission evidence missing | Never expose as authority/feed/Object-Sync eligible |

---

## 13. Durability and crash ordering

The later persistence companion must freeze exact journals. One authority
candidate transaction atomically writes the verified exact artifact, referenced
evidence, descriptor/policy/audience pins, conflict/deny sets, and every derived
grant activation/deactivation. View/feed/Object-Sync eligibility is released
only after that transaction and its required protected rollback anchor commit.
No crash-visible state may contain a new audience pin with an old grant still
authorizing new admission, or a new descriptor head without its contiguous
policy events.

At minimum, fault injection and real restart cover:

1. authority bytes staged before strict verification;
2. verified artifact stored before descriptor/policy pin promotion;
3. retirement/revocation deny stored before derived grant-state update;
4. grant stored before descriptor activation;
5. descriptor activation before pending RVSR1 release;
6. audience policy generation + descriptor pin + old-grant deactivation +
   new-grant activation as one SQL candidate transaction;
7. conflict quarantine before any competing branch release;
8. exact replay after every boundary;
9. protected-anchor write before SQL policy/frontier deletion/compaction;
10. app-data rollback with protected pin ahead.

Recovery is roll-forward and idempotent. If SQL committed but the protected pin
did not, exact journal evidence completes the anchor before release; if the
anchor is ahead, exact pending evidence must reconcile SQL without key/policy
reuse. Recovery never deletes deny/conflict evidence, reuses a policy sequence,
reactivates an omitted grant, lowers a descriptor pin, or publishes a draft.
Endpoint receipt/ACK durability remains a separate domain; an authority failure
does not roll back a consumed messaging ratchet key.

---

## 14. Shared vectors and three-language gates

Proposed namespace:

```text
shared-vectors/rvn1/social_repository_authority/
  schema_policy/
  audience_public/
  audience_contact/
  repo_genesis/
  descriptor_chain/
  writer_grant/
  writer_retirement/
  activation/
  conflicts/
  negatives/
```

Python, Rust, and Swift independently compute—not merely read JSON:

- all exact offsets/lengths and strict negative codecs;
- RVSP1/RVAP1/audience-root digests;
- RVSG1 and repo-ID derivation under every substituted input;
- explicit proof that descriptor1→grant1 activation has no digest cycle:
  RVWG1 binds `repo_genesis_core_digest`, while RVSD1 binds RVWG1;
- descriptor/grant/retirement signing inputs, signatures and digests;
- descriptor and shared policy replay/gap/conflict transitions;
- grant pending→active only through descriptor-head ancestry;
- eager retirement, omission-no-revoke, regrant, Device Revocation precedence;
- public/contact cross-audience and policy-generation negatives;
- exact record-to-grant kind/audience/cert binding;
- anti-rollback candidate/commit/restart outcomes.

Required deterministic scenarios include:

1. one public repo: descriptor1 + owner-device grant1 + three RVSR1 kinds;
2. descriptor refresh with unchanged policy;
3. policy generation change, old grant denied, regrant activated;
4. retirement arrives before descriptor successor and denies immediately;
5. same policy slot conflict from two offline owner signers;
6. two social writer devices create honest concurrent record branches;
7. stale source omits retirement and loses to local pin;
8. contact repo session replacement preserves repo/audience root while audience
   generation and per-device seals change;
9. V1 identity/key substitution changes repo ID; source/topic/schema changes obey
   their frozen inclusion/exclusion rules;
10. authentic unknown-owner bytes reach codec green but never authority/feed
    green; contact evidence never triggers a public fetch;
11. bundled grant1+descriptor1 failure/crash cannot expose either half ACTIVE;
12. public nonzero `stable_space_id` is codec-bounded but admission-rejected;
13. Continuity V2/profile 2 rejects in every V1 parser.

JSON contains explicit hex/annotations only. A test that compares expected JSON
without executing codec, digest, signature and state transitions is not parity.

---

## 15. Simulation and physical gates

At least 1,000 deterministic nodes exercise:

- offline owner-policy conflicts and later evidence exchange;
- two to eight writer devices, honest record forks and deterministic union;
- eclipse sources withholding grants, descriptors or retirements;
- audience generation changes during partitions;
- compromised/revoked writer replay through LAN, relay, mailbox and import;
- unknown-owner floods and capacity saturation;
- crash/rollback at every activation/deny boundary;
- local-only follow/block/attention behavior without follower disclosure.

Physical rows include Terminal/iPhone repository creation, second-device grant,
offline authoring, kill/relaunch, descriptor refresh, retirement-before-refresh,
stale source replay, device revoke, contact session replacement, carrier change,
and proof that an ACK/transfer success never implies social authorization.

Safety violations are reported independently from liveness/latency. A stale or
partitioned node may be unable to publish; it must not gain false authority.

---

## 16. Research basis (informative)

Raven borrows lessons, not wire compatibility:

- [UCAN specification](https://github.com/ucan-wg/spec) — delegation binds issuer,
  audience/holder, resource/ability and a proof chain; invocation replay needs a
  local uniqueness store. Raven's writer grants are identity-signed,
  certificate/holder-bound, non-bearer, non-subdelegable in V1, and descriptor
  activated.
- [RFC 9162 Certificate Transparency](https://www.rfc-editor.org/rfc/rfc9162.html)
  — append-only roots and consistency proofs expose split views when compared.
  Raven uses direct signed chains/pins in V1 rather than mandating one global log.
- [Secure Scuttlebutt protocol guide](https://ssbc.github.io/scuttlebutt-protocol-guide/)
  — one-writer sequence/previous-hash chains detect rewritten history. Raven
  separates identity-authority policy slots from concurrent certified social
  writer lineages.
- [AT Protocol repository](https://atproto.com/specs/repository) — signed
  content-addressed repository commits and the key-rotation ambiguity of old
  signatures. Raven retains exact historical identity/control evidence and does
  not resolve old signatures from only the latest mutable key document.

---

## 17. Open before approval

1. Independent byte/cryptographic/security review of all six exact constructions.
2. Decide whether public nonzero `stable_space_id` is frozen topic semantics or
   remains disabled in the first vectors.
3. Exact historical certificate/Identity V1 evidence bundle and Continuity V2
   successor profile.
4. Exact descriptor/policy conflict repair and explicit re-trust wire.
5. Exact protected-store/SQL persistence, journal and rollback pins.
6. Exact head announcement/segment/source request wires and public-read privacy.
7. Three-language vectors, crash tests, 1,000-node simulation and physical rows.
8. Umbrella registration, independent review, protocol-owner approval.

Until these close, every family is `NOT YET APPROVED`, production is disabled,
and no valid-looking byte sequence may enter a feed or carrier.

---

## 18. Recommended delivery sequence

```text
RA0. independent layout/domain/chain review
RA1. Python generator/checker + frozen exact vectors
RA2. Rust strict codecs/state machine behind lab feature
RA3. Swift strict codecs/state actor behind lab gate
RA4. RVSR1 admission integration using exact grant/descriptor evidence
RA5. durable SQL/protected-pin crash implementation
RA6. public head/segment/read privacy and Attention Firewall integration
RA7. simulation + physical carrier matrix
RA8. explicit human approval; production remains a separate authorization
```

No later step may weaken deny-fast/grant-slow, exact-byte identity, audience
privacy, conflict preservation, anti-rollback pins, or the two-green-bar boundary.

---

## 19. Document history

| Revision | Date | Summary |
|---:|---|---|
| 1 | 2026-08-21 | Initial exact authority-plane draft: RVSP1 schema policy, RVAP1 audience commitment, non-circular RVSG1/repo ID, RVSD1 descriptor chain, shared RVWG1/RVWR1 writer-policy chain, deny-fast/grant-slow activation, conflict/partition/rollback semantics, vectors/crash/simulation/physical gates. Production disabled. |
| 2 | 2026-08-21 | Removed the descriptor1↔grant1 digest cycle by binding every writer-policy event to `repo_genesis_core_digest = SHA-256(RVSG1)`; added the social-authoring device-ID subset, explicit first-head construction, and a no-cycle vector requirement. Production remains disabled. |
| 3 | 2026-08-21 | Split codec conformance from locally admitted authority; added unknown-owner Attention/contact privacy gates, zero-only public space admission for V1, atomic grant1+descriptor1 activation, and one crash-safe audience/descriptor/policy transaction. Production remains disabled. |
