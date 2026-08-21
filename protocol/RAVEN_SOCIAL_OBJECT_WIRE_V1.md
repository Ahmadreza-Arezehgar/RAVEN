# RAVEN Social Object Wire V1

**Profile:** `raven/social-object-wire/v1`
**Version:** 1
**Document revision:** 6
**Date:** 2026-08-21
**Status:** **REQUIRED / NOT YET APPROVED**
**Production:** **disabled** — this document authorizes no public post, feed, follow, reply, reaction, profile, label, community capability, codec, database migration, Object Sync eligibility, public source, carrier activation, live callsite, or Release flag
**Approval prerequisites:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md) **Approved**; [`RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md`](RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md) **APPROVED** (not met); [`RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md`](RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md) **APPROVED** (not met); [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md) **APPROVED** (met); [`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md) **APPROVED** before any nonzero media reference; Identity/continuity, attention, Private Discovery, Object Sync, public-pull, and carrier companions as required by the selected audience/path
**Scope of Revision 6:** freeze the common social-record envelope and first text payload as review candidates; bind repository admission to the separate exact authority draft without treating that unapproved draft as executable authority; preserve independent attention/discovery outcomes; register the distinct sovereign-media provenance boundary without enabling media references

This companion turns Raven's semantic social architecture into exact bytes. It
does not turn a social record into a server row, a transport receipt, a contact,
or a ranking instruction.

> One signed social object has one immutable `social_digest`. Public replication,
> private per-device sealing, local ranking, and carrier delivery are separate
> operations and never redefine that identity.

The umbrella, Social Graph, Carrier Conformance, Object Sync, Public Repository
Sync, Attention Firewall, and Sovereign Communities invariants remain binding.
This companion cannot override them.

---

## 0. Normative language and authorization boundary

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**,
and **MAY** are interpreted as in BCP 14 when capitalized.

Revision 1 is a design/vector-freeze candidate for Slice A only. Before any
status change to **APPROVED**, the full family requires:

1. exact payload profiles for every enabled record kind;
2. exact repository descriptor/writer-policy/head/segment wires;
3. umbrella registration of every public authenticated endpoint-record family;
4. Python/Rust/Swift compute vectors and strict negative codecs;
5. durable repository/view/admission implementations and crash matrices;
6. public-pull/Object Sync eligibility and carrier conformance proofs;
7. Attention Firewall integration for any stranger-visible surface;
8. independent security/privacy review and explicit protocol-owner approval.

### 0.1 Non-goals

This revision does not:

- define a global ledger, blockchain, consensus, total order, global clock, or
  canonical server;
- use transport arrival, mirror count, follower count, relay count, or timestamp
  as authenticity or fork resolution;
- guarantee remote erasure of public bytes;
- publish a local follow graph, view/read state, dwell time, contacts, blocks,
  ranking recipe, or notification policy;
- allow a signature, recommendation, label, or community role to purchase
  attention on another device;
- define private group cryptography; private circles require an approved MLS
  profile under Sovereign Communities;
- reinterpret ActivityPub, AT Protocol, Nostr, Secure Scuttlebutt, JSON, CBOR,
  DAG-CBOR/DRISL, CAR, or any existing Raven V1 object as this wire;
- modify Full Braid Slice 3 Task 0B/0C or protected-anchor work;
- enable production.

---

## 1. Core decisions

### 1.1 Raven Canonical Binary, not general-purpose serialization

Signed/hash-addressed bytes use a Raven-owned fixed-prefix binary profile:

- unsigned fixed-width integers are big-endian;
- every variable field has one explicit length/count in the fixed prefix;
- checked arithmetic precedes allocation;
- arrays with set semantics have a frozen bytewise sort order and no duplicates;
- ordered media slots are contiguous and unique;
- unknown flags, kinds, audience classes, payload profiles, and critical
  extensions fail closed;
- trailing bytes, concatenated objects, alternate integer widths, null aliases,
  duplicate fields, and decode/re-encode normalization are forbidden;
- parsers preserve exact admitted bytes; they never regenerate authoritative
  bytes from an in-memory model.

JSON is presentation/debug only. Generic CBOR is not an alternate wire. A
future deterministic-CBOR family would need a new profile and independent
cross-language vectors; it cannot be accepted as `RVSR1`.

### 1.2 Four non-interchangeable identities

```text
social_digest = SHA-256(exact social_record_bytes)
payload_digest = SHA-256(exact kind_payload_bytes)
object_digest = SHA-256(exact endpoint_object_bytes)
media_root_digest = digest defined by an approved media profile
```

Rules:

1. Repository parents, relations, edits, tombstones, reactions, labels, and
   logical-view dedup use `social_digest`.
2. Carrier attempts, exact endpoint retry, endpoint ACKs, and Object Sync
   inventories use `object_digest`.
3. A public registered record has
   `endpoint_object_bytes == social_record_bytes`, so its two digests are equal.
4. A contact/circle record is plaintext inside a separately approved seal;
   resealing preserves `social_digest` but normally changes `object_digest`.
5. `payload_digest`, media roots, segment roots, wrapper hashes, and supplied
   digests never replace either authoritative identity.
6. Same digest with different exact bytes enters durable collision quarantine;
   implementations do not choose a winner.

### 1.3 Authentication is proof-carrying, not source-carrying

A valid record binds exact identity/device/repository evidence. The source that
delivered those bytes—author device, contact, cache, mirror, relay, mailbox,
import file, or public source—has no authority over their meaning. The Endpoint
recomputes every digest and verifies the exact evidence before trusted-view
mutation.

---

## 2. Common `RVSR1` social-record envelope

`RVSR1` is the canonical `social_record_bytes` envelope. It has a 280-byte fixed
prefix, a calculated variable header, an exact kind payload, an exact extension
area, and a trailing 64-byte Ed25519 signature.

### 2.1 Fixed prefix

```text
offset  size  field
0       5     magic = ASCII "RVSR1"
5       1     schema_rev = 1
6       1     record_kind
7       1     audience_class
8       1     author_identity_profile
9       1     payload_profile
10      2     flags_u16be
12      4     total_len_u32be
16      4     header_len_u32be
20      2     author_address_len_u16be
22      2     author_device_id_len_u16be
24      2     repo_parent_count_u16be
26      2     relation_count_u16be
28      2     media_ref_count_u16be
30      2     reserved = zero
32      32    repo_id
64      32    author_device_cert_digest
96      32    author_writer_grant_digest
128     32    audience_commitment
160     8     device_seq_u64be
168     8     created_at_ms_u64be (advisory only)
176     32    previous_device_social_digest or zero
208     4     payload_len_u32be
212     4     extensions_len_u32be
216     32    payload_digest = SHA-256(exact payload bytes)
248     32    extensions_digest = SHA-256(exact extension bytes)
```

Immediately after byte 280:

```text
author_address[author_address_len]
author_device_id[author_device_id_len]
repo_parent_social_digests[repo_parent_count][32]
relations[relation_count][36]
media_refs[media_ref_count][76]
kind_payload[payload_len]
extensions[extensions_len]
author_device_signature[64]
```

```text
header_len = 280
           + author_address_len
           + author_device_id_len
           + 32 * repo_parent_count
           + 36 * relation_count
           + 76 * media_ref_count

total_len = header_len + payload_len + extensions_len + 64
```

All multiplication/addition is checked before allocation. `header_len` and
`total_len` must equal the exact received layout; no trailing bytes exist.

### 2.2 Enumerations and flags

`record_kind`:

| Value | Kind | Revision-1 status |
|---:|---|---|
| 1 | `POST` | Slice A payload frozen by §5 |
| 2 | `REPLY` | Slice A payload frozen by §5 |
| 3 | `EDIT` | Slice A payload frozen by §5 |
| 4 | `TOMBSTONE` | payload subprofile required before vectors |
| 5 | `REACTION` | payload subprofile required before vectors |
| 6 | `PROFILE_ASSERTION` | payload subprofile required before vectors |
| 7 | `FOLLOW_STATEMENT` | payload subprofile required before vectors |
| 8 | `MODERATION_LABEL` | payload subprofile required before vectors |
| 9 | `CAPABILITY_GRANT` | separate capability wire required |
| 10 | `CAPABILITY_INVOCATION` | separate capability wire required |
| 11 | `MEMBERSHIP_HINT` | future approved community/MLS profile only |

`audience_class`: `0=PUBLIC`, `1=CONTACT`, `2=CIRCLE`; all other values reject.

`author_identity_profile`: `1=FROZEN_IDENTITY_V1`. Value 2 is reserved for an
approved Continuity V2 wire and MUST reject until that profile freezes the exact
address/control evidence. No V1 parser guesses a V2 address.

`payload_profile`: `0=EMPTY`, `1=RVTX1`. Other values reject until their exact
subprofile is approved.

`payload_profile=EMPTY` requires `payload_len=0` and
`payload_digest=SHA-256(empty)`. `RVTX1` requires a nonzero exact payload whose
own declared length equals `payload_len`. Kind-specific rules may require one
profile and forbid the other.

`flags_u16be`:

| Bit | Meaning |
|---:|---|
| 0 | `PREVIOUS_DEVICE_DIGEST_PRESENT` |
| 1–15 | reserved; MUST be zero |

When bit 0 is clear, bytes 176–207 are all zero. When set, the digest is nonzero.
Sequence 1 requires the bit clear; sequence greater than 1 requires it set.

### 2.3 Canonical address, device, and repository fields

For `FROZEN_IDENTITY_V1`:

- `author_address_len == 44`;
- address bytes are the exact lowercase canonical `RavenAddressV1` ASCII;
- decoding and re-encoding under the exact identity public key from the retained
  certificate/identity evidence must reproduce those 44 bytes.

`author_device_id` is the exact UTF-8 byte string from the bound certificate,
with byte length `1..64`, as frozen by Device Revocation V1. The RVSR1
authoring profile additionally rejects NUL and Unicode scalar values in
`U+0000..U+001F` or `U+007F..U+009F`. This is an explicit social-authoring
subset, not normalization: a certificate whose otherwise-valid opaque label
falls outside the subset remains a certificate but cannot author RVSR1 V1.
Accepted bytes are never normalized, suffixed, mapped to a display alias,
sorted, or lowercased.

`repo_id`, certificate digest, writer-grant digest, and audience commitment are
nonzero. Their exact derivations/evidence are supplied by approved repository and
audience profiles; a mere nonzero value is never authorization.

`device_seq_u64be` starts at 1 and must pass the per-certificate-lineage chain
rules. `created_at_ms` is author-supplied presentation evidence. It cannot close
a gap, choose a fork, prove pre-revocation minting, bypass expiry, or outrank a
locally verified sequence/digest.

### 2.4 Repository parents

Repository parents are a set of nonzero `social_digest` values:

- count `0..64` (default profile ceiling 16);
- strictly increasing lexicographic byte order;
- no duplicates and no self-reference to the record being decoded;
- each dependency remains untrusted/missing until independently admitted;
- every resolved parent must bind the same `repo_id`, audience class, and exact
  audience commitment as the child; a cross-repository or cross-audience parent
  is authenticated invalid content, not a repository merge;
- a missing parent is bounded incomplete evidence and cannot advance or replace
  the verified repository head until that same-repository binding is proved;
- omission never deletes a locally retained head.

Sequence chaining uses `previous_device_social_digest`, not this parent set.

### 2.5 Relations

Each 36-byte relation is:

```text
0       1     relation_kind
1       1     relation_flags
2       2     reserved = zero
4       32    target_social_digest (nonzero)
```

Relation kinds:

| Value | Relation |
|---:|---|
| 1 | `REPLY_TO` |
| 2 | `QUOTE` |
| 3 | `SUPERSEDES` |
| 4 | `TOMBSTONES` |
| 5 | `REACTS_TO` |
| 6 | `LABELS` |

`relation_flags` is zero in V1. Relations are strictly ordered by
`(relation_kind, target_social_digest)` and unique. Unknown kind/flags reject.
Kind-specific allow-lists in §6 are additionally binding. A target digest is a
content reference, not proof the target exists, is authentic, or should display.
After computing `social_digest`, every relation to that same digest rejects as a
self-reference.

### 2.6 Media references

Each ordered 76-byte media reference is:

```text
0       2     media_slot_u16be
2       2     flags = zero
4       32    media_root_digest
36      32    media_manifest_digest
68      8     declared_plaintext_length_u64be
```

Slots are exactly `0..media_ref_count-1`. Digests and declared length are
nonzero. Count is `0..256` (default 32). An approved media companion defines
root/manifest/chunk encryption, MIME/preview/alt-text binding, and size maxima.
[`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md)
separately defines exact-asset identity, C2PA workflow evidence, participation
grants and honest unknown/invalid/conflict outcomes. `media_root_digest`, an
exact asset digest, a C2PA Manifest Store digest and a Raven publication digest
are distinct identities; implementations MUST NOT silently map one field to
another. A rendition, transcode or edit has a new exact asset identity even
when it retains an ingredient relationship.
Until then `media_ref_count` MUST be zero in enabled Slice-A vectors. A renderer
never auto-fetches media from a social record; fetch is a separate local-policy,
SSRF-safe, budgeted action.

---

## 3. Signature and digest construction

Let `unsigned_record_bytes` be exact bytes from offset 0 through the end of the
extension area, excluding only the trailing 64-byte signature.

```text
social_signature_input =
    ASCII "raven/social-record/signature/v1"
 || u32be(len(unsigned_record_bytes))
 || unsigned_record_bytes

author_device_signature =
    Ed25519.Sign(author_device_signing_key, social_signature_input)

social_record_bytes = unsigned_record_bytes || author_device_signature
social_digest       = SHA-256(social_record_bytes)
```

The domain is 32 ASCII bytes. Implementations pass explicit lengths and no C
string terminator. This profile uses ordinary Ed25519 over the exact input, not
Ed25519ph, a JSON representation, a struct dump, or a caller-provided digest.

Verification order is:

1. fixed-prefix and checked-length/cap validation;
2. strict canonical variable-header validation;
3. recompute payload/extension digests;
4. retrieve the locally bounded certificate/identity evidence named by the
   record; verify its identity/address binding, validity, and sticky device
   revocation/block gates;
5. verify Ed25519 signature under that exact certificate device key;
6. only for a signature-authentic candidate, verify the potentially larger
   descriptor/control-head, writer grant/retirement, audience, repository, and
   historical continuity evidence;
7. apply replay/gap/conflict/admission policy on a candidate;
8. durable commit before view/notification/ACK side effects.

Steps 4 and 6 never perform an ambient network fetch. Missing evidence is a
bounded incomplete/refused outcome; it is not permission to synchronously query
an attacker-selected URL, mirror, relay, DHT key, or carrier while holding the
social mutation lease.

No supplied `social_digest`, source TLS identity, mirror signature, carrier
receipt, or outer endpoint authentication replaces step 5. Private records also
require successful outer Session V2/MLS authentication before step 1 is exposed
to the social actor.

---

## 4. Extension area `RVXT1`

An empty extension area is permitted and has
`extensions_digest = SHA-256(empty)`. A nonempty area is a sequence of exact
TLVs, not a nested self-describing document:

```text
0       2     tag_u16be
2       2     flags_u16be
4       4     value_len_u32be
8       n     value
```

Rules:

- tags are strictly increasing and unique;
- flag bit 0 means `CRITICAL`; bits 1–15 are zero;
- an unknown critical tag rejects the entire record;
- an unknown noncritical tag is preserved byte-for-byte, included in signature
  and digest, ignored for semantics, and never grants authority;
- zero-length values require an explicitly registered tag that permits them;
- nested extensions, alternate encodings, padding TLVs, and duplicate aliases
  are forbidden;
- extension bytes count toward all record/attention/crypto budgets.

Revision 1 registers no extension tags. Therefore enabled Slice-A vectors use
an empty extension area; any nonempty area remains parse-test-only until a tag
registry revision is approved.

---

## 5. `RVTX1` bounded text payload

`POST`, `REPLY`, and `EDIT` use exact payload profile 1:

```text
offset  size  field
0       5     magic = ASCII "RVTX1"
5       1     schema_rev = 1
6       1     body_format: plain=0, restricted_markdown=1
7       1     flags: bit0=CONTENT_WARNING_PRESENT; other bits zero
8       4     total_len_u32be
12      4     text_len_u32be
16      2     content_warning_len_u16be
18      1     language_tag_len_u8
19      1     reserved = zero
20      l     language_tag_ascii
20+l    c     content_warning_utf8
20+l+c  t     text_utf8
```

`total_len = 20 + l + c + t` and equals `RVSR1.payload_len`. Rules:

- text length `1..245760` (240 KiB) by default and never above a later approved absolute
  maximum of 1 MiB;
- content warning length `0..512`; flag presence equals nonzero length;
- language tag length `0..35`; when present it is lowercase ASCII alphanumeric
  subtags separated by single hyphens, with no leading/trailing/consecutive
  hyphen; it is advisory, not authority;
- all text is strict UTF-8 and is then checked by Unicode scalar value: reject
  `U+0000..U+001F` and `U+007F..U+009F` except tab `U+0009`, LF `U+000A`, and
  CR `U+000D`; preserve every admitted byte exactly without Unicode
  normalization or line-ending conversion;
- UI renders untrusted text under bidi isolation and platform-safe shaping;
- restricted Markdown permits only a later frozen inert formatting subset: no
  raw HTML, script, embedded data URI, automatic remote image, form, iframe,
  executable attachment, or implicit network fetch;
- URLs inside text are inert until an explicit local-policy open/fetch action.

The exact enclosing effective record cap also applies, so legal individual
field maxima never imply that their sum is admissible. Until the
restricted-Markdown grammar, parser, renderer, and vectors are frozen,
`body_format=restricted_markdown` rejects; enabled vectors use `plain` only.

---

## 6. Kind-specific structural rules

These rules are checked after the common codec but before signature-authorized
view mutation:

| Kind | Required relations | Forbidden relations | Payload |
|---|---|---|---|
| `POST` | `QUOTE` count `0..1` | `REPLY_TO`, `SUPERSEDES`, `TOMBSTONES`, `REACTS_TO`, `LABELS` | exactly one `RVTX1` |
| `REPLY` | exactly one `REPLY_TO`; `QUOTE` count `0..1` | `SUPERSEDES`, `TOMBSTONES`, `REACTS_TO`, `LABELS` | exactly one `RVTX1` |
| `EDIT` | exactly one same-repo `SUPERSEDES` | `REPLY_TO`, `QUOTE`, `TOMBSTONES`, `REACTS_TO`, `LABELS` | exactly one `RVTX1`; structural relations inherit from the admitted target and cannot be changed by the edit |
| `TOMBSTONE` | exactly one same-author/scope `TOMBSTONES` | all others | future exact payload; no remote-erasure claim |
| `REACTION` | exactly one `REACTS_TO` | all others | future exact add/clear payload |
| `PROFILE_ASSERTION` | profile-specific supersession only | reply/reaction/label/tombstone | future exact profile payload |
| `FOLLOW_STATEMENT` | none | all digest relations unless a future profile registers one | future exact identity/repo target payload |
| `MODERATION_LABEL` | exactly one `LABELS` | all others | future exact label/sequence/evidence payload |
| capability/membership kinds | proof-specific only | all unregistered relations | disabled until their separate profile |

An `EDIT` or `TOMBSTONE` is a new immutable record. It cannot rewrite, replace,
or prove deletion of target bytes. A `FOLLOW_STATEMENT` is explicit public
speech; local follow/unfollow remains private local state by default.

Revision 1 can produce conformance vectors for `POST`, `REPLY`, and `EDIT` only.
All other kinds remain decoder-negative/production-disabled until their exact
payload companion is approved.

---

## 7. Audience and endpoint-object mapping

### 7.1 Public

A public record may be admitted as a public authenticated
`endpoint_object_bytes` only after the umbrella registers the exact `RVSR1`
family and the record kind/payload profile is approved:

```text
endpoint_object_bytes = social_record_bytes
object_digest         = social_digest
```

The public audience commitment is `SHA-256(exact RVAP1 bytes)` and therefore
binds public class, generation, stable space/topic field, zero participants,
and exact schema-policy digest. The descriptor binds that RVAP1 digest. A source
cannot widen it. Valid public bytes:

- do not create a contact or PairInit eligibility;
- do not expose private/contact Object Sync inventory;
- do not create a follow, notification, ranking placement, or media fetch;
- enter the Attention Firewall before any stranger-visible surface;
- remain subject to local block and sticky device revocation.

### 7.2 Contact

`social_record_bytes` is plaintext inside a Session V2 endpoint object. The
inner audience commitment is `SHA-256(exact contact RVAP1 bytes)` and binds the
two sorted canonical participant identities, stable `contact_space_id`,
audience generation, and exact schema-policy digest. The outer endpoint object
binds exact sending/receiving devices, Session V2, direction, message counters,
and seal.

The same exact inner record may be sealed independently to several authorized
recipient devices. Each seal has separate `object_digest`, outbox, ACK,
delivery, expiry, and retry state. A verified ACK for one seal never marks the
other device seals delivered. Social admission deduplicates by `social_digest`
only after every outer endpoint authentication succeeds independently.

### 7.3 Circle

Circle records remain disabled until Sovereign Communities freezes the exact
MLS credential, epoch, application-data, padding, history, and audience
commitment profile. A direct-message shared key, static group key, carrier
encryption, or community capability cannot substitute.

### 7.4 No cross-audience transplant

The record's audience class, commitment, repository genesis/descriptor, writer
grant, and selected enclosing endpoint profile must agree. Public-to-contact,
contact-to-public, contact-to-circle, circle-to-public, or another contact-space
transplant rejects without trusted-view mutation. Legitimate widening/narrowing
creates new signed bytes and a new `social_digest`.

Relations follow a visibility lattice; they do not smuggle authority or fetch
eligibility across it:

- a private contact/circle record may refer to an independently admitted public
  record without making the public record private or creating a subscription;
- a contact relation may refer to another contact record only when the exact
  `contact_space_id`, participant commitment, and permitted audience generation
  match; a circle relation requires the approved same-community/MLS scope rule;
- a public record never makes a known contact/circle digest public, fetchable,
  inventory-eligible, quotable, or renderable merely by naming it;
- an unresolved relation is inert and consumes a bounded missing-dependency
  budget. Public resolution may use only public-source eligibility; it never
  probes contact/circle stores, Object Sync inventory, mailbox tags, or peers;
- when resolution proves that a relation violates this lattice, admission of
  its relation semantics fails without mutating the target or widening its
  audience. A user who intentionally republishes material authors a new public
  record and bears a new signature/digest; Raven never treats that as consent or
  proof of lawful disclosure.

---

## 8. Repository and writer evidence boundary

`RVSR1` deliberately contains digests of repository authority rather than
embedding a recursive certificate/policy bundle. Admission requires exact
separately verified evidence:

1. identity profile and canonical address;
2. device certificate and retained historical identity/control proof;
3. non-circular repository genesis/current descriptor chain;
4. exact identity-authorized writer grant and append-only retirement chain;
5. greatest locally verified device revocation union;
6. audience-partition evidence;
7. per-device writer predecessor or bounded gap state.

The separate production-disabled
[`RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md`](RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md)
now drafts exact bytes for the first three reserved families. They remain
`NOT YET APPROVED`, are not registered carrier objects, and cannot authorize an
RVSR1 merely because their codecs eventually become green:

| Candidate magic | Artifact | Required role |
|---|---|---|
| `RVSD1` | repository descriptor | non-circular repo identity, owner/audience/policy chain |
| `RVWG1` | writer grant | identity authorizes exact certificate lineage/repo/partition |
| `RVWR1` | writer retirement | append-only explicit end of writer authority |
| `RVHA1` | head announcement | bounded signed availability hint, never completeness |
| `RVSM1` | writer segment | contiguous signed writer-index acceleration |
| `RVPD1` | public repository drop | import container only; not an endpoint object/signature |

`RVWG1`/`RVWR1` bind the non-circular
`repo_genesis_core_digest = SHA-256(exact RVSG1 bytes)`, while RVSD1 binds the
writer-policy head. They never bind descriptor 1 back into grant 1. The three
magics are still not admissible wire registrations. RVHA1/RVSM1/RVPD1 bytes,
Continuity-V2 control evidence, segment proofs, import safety, vectors,
durability, and approval remain open before public replication is possible.

An RVSR1 admission consumes only authority evidence that reached
`RVRA_AUTHORITY_ADMITTED`. `RVRA_CODEC_CONFORMANT` alone—even for a valid
self-signed unknown public repository—cannot make its RVSR1 feed-visible,
contact-visible, inventory-eligible, followed or notified. The separate RVSR1
codec/admission bars remain independently required as well.

### 8.1 Writer-chain admission

For one exact `(repo_id, author_device_id, cert_digest)` lineage:

- sequence 1 has no predecessor;
- sequence `n>1` binds the exact admitted digest at `n-1`;
- exact same slot/bytes is idempotent;
- same slot/different bytes is authenticated conflict evidence and terminalizes
  that writer slot pending an approved repair;
- a gap is incomplete evidence and may be buffered within caps, but does not
  advance the verified frontier;
- independent certified devices may have concurrent sequences/heads;
- arrival time, author timestamp, digest ordering, source count, or mirror
  preference never chooses one concurrent branch.

### 8.2 Evidence retention

Historical admission retains the exact descriptor, certificate, grant,
retirement/revocation/control-state digests needed to verify why bytes were
accepted. Learning a later revoke denies new admission; presentation of already
admitted history follows explicit local policy. Advisory `created_at_ms` cannot
prove that a record predates compromise.

---

## 9. Admission and local-view transaction

### 9.1 Public/contact common pipeline

```text
class demux + fixed-prefix cap
  -> reserve bytes/work/queue slot
  -> read exact declared record
  -> strict RVSR1/RVTX1 canonical parse
  -> recompute payload/extension/social digest
  -> verify bounded identity/cert/address/validity/revoke/block evidence
  -> verify exact device signature
  -> verify descriptor/grant/retirement/audience/continuity evidence
  -> classify replay/gap/conflict/relations on candidate state
  -> durable exact record + admission evidence + writer/head update
  -> commit local view candidate
  -> only then expose to search/ranking/notification eligibility
```

For contact/circle, successful outer endpoint decrypt/authentication and endpoint
receipt transaction precede inner social admission. A failure of social
semantics does not roll back/reuse an already committed endpoint ratchet key; it
records a bounded authenticated invalid-content outcome and emits no social side
effect.

### 9.2 No network side effect from viewing

Fetch, verify, admit, render, scroll, search, rank, hide, read, or archive emits
no endpoint ACK beyond the already-required sealed-message ACK, and emits no
follow, reaction, view receipt, public read state, author notification, remote
ranking signal, or media fetch. Every such public/social action requires a new
explicit locally authorized record or request.

### 9.3 Candidate-before-commit

All replay/conflict/writer/head/view mutations occur on a candidate. Failure
before durable commit leaves canonical social state unchanged. The durable
profile must freeze journal ordering and exact replay bytes; in-memory tests do
not prove crash safety.

For a received contact record, endpoint ACK intent is committed according to
the endpoint profile, not held hostage to feed display, remote media, ranking,
or notification. A cryptographically authenticated but unsupported social kind
may be retained/quarantined under policy while its exact endpoint ACK still
acknowledges endpoint receipt—not semantic endorsement.

---

## 10. Local view, edits, tombstones, and moderation

### 10.1 Materialized views are derived

The authoritative store is the exact admitted record/evidence graph. Feed rows,
profiles, reaction counts, search indexes, thread summaries, notification rows,
and ranks are rebuildable local views. Corrupt view state is discarded and
rebuilt from admitted evidence; it cannot alter authenticity, writer frontiers,
blocks, revocations, or repository conflicts.

### 10.2 Edit/tombstone behavior

- edit creates a new signed record and view successor;
- tombstone requests local hiding under author/capability policy;
- target bytes remain immutable and may persist in caches, archives, hostile
  replicas, screenshots, quoted objects, or evidence stores;
- a tombstone cannot erase another author's record without separately approved
  governance capability, and even then changes local/community policy rather
  than proving global physical deletion;
- a missing/withheld tombstone does not make a source complete or honest.

### 10.3 Labels and attention

A future `MODERATION_LABEL` payload must bind labeler authority, subject digest,
namespace/value, sequence, previous assertion, validity ceiling, policy/evidence
digest, and signature. It annotates; it never rewrites the subject, clears a
local block/device revoke, creates community authority, or dictates display.

The Attention Firewall preserves seven non-interchangeable outcomes:
cryptographic verification, audience/repository eligibility, resource
admission, custody/storage, dissemination, attention selection, and
notification. Media fetch is separately charged resource work; feed placement
is an attention outcome; forwarding requires an explicit dissemination intent.
Success in one plane never fabricates success in another. Its local
recipe/decision bytes are not `RVSR1`, not public, and not Object Sync eligible.

---

## 11. Resource ceilings

Later profiles may tighten but never exceed:

| Resource | Default | Absolute |
|---|---:|---:|
| Exact `RVSR1` | 256 KiB | 24 MiB and enclosing endpoint ceiling |
| `RVTX1` text | 240 KiB | 1 MiB, always bounded by effective record cap |
| Repository parents | 16 | 64 |
| Relations | 16 | 64 |
| Media refs | 32 | 256 |
| Extension bytes | 0 in Slice A | 64 KiB after registry approval |
| Device ID | 1..64 bytes | 64 |
| Concurrent heads per repo | 32 | 256 |
| Writer lineages per repo | 16 | 64 |
| Buffered gaps per lineage | 64 | 1024 under global cap |
| Unknown-author durable intake/day | 8 | 64 |
| Process pending verify queue | 256 | 4096 |
| Signature/identity/repo proof work | profile budget | finite global budget |

The parser validates prefix lengths/counts and reserves worst-case retained
bytes/work before reading variable bodies or verifying signatures. Malicious
failures consume abuse budget. Unknown senders never evict trusted pending work,
collision evidence, revocation evidence, or active safety pins.

---

## 12. Failure and downgrade matrix

| Input/event | Required outcome |
|---|---|
| Unknown magic/schema/kind/audience/identity/payload profile | Reject before trusted mutation |
| Declared length arithmetic overflow, underflow, truncation, trailing bytes | Reject before allocation/body parse |
| Non-canonical address/device ID/array order/duplicate/reserved bits | Reject exact bytes; never normalize/re-sign |
| Payload/extension digest mismatch | Reject before evidence/signature work where possible |
| Supplied social/object digest mismatch | Reject; supplied digest is comparison only |
| Same social digest, different exact bytes | Durable collision quarantine; no winner |
| Exact replay | Reuse committed outcome; no second view mutation/notification |
| Same writer slot, different signed bytes | Authenticated conflict; retain bounded evidence; pause slot |
| Missing writer predecessor | Bounded gap; do not advance frontier |
| Two valid device branches | Concurrent heads; preserve both; no arrival-time winner |
| Missing/invalid/retired grant or revoked cert | Deny new admission |
| Valid signature from untrusted source | Authentic candidate only; source gains no authority |
| Public record appears on private/contact parser or reverse | Cross-class reject |
| Contact ciphertext transplant to another session/device | Outer endpoint authentication rejects |
| Public fetch/store/relay success | Transfer/custody only; no Delivered/Read/follow/rank |
| Edit/Tombstone received | Derived local-view action only; no byte rewrite/global-erasure claim |
| Unknown critical extension | Reject whole record |
| Unknown noncritical extension | Preserve signed bytes; ignore semantics; grants no authority |
| Remote URL/media reference | Inert until explicit local budget/policy fetch |
| Attention budget exhausted | Retain/drop/defer per lane policy; authenticity unchanged |
| Local view/index corrupt | Rebuild/disable view; never reset authority/frontier evidence |
| Legacy JSON/CBOR/Nostr/ActivityPub/Raven record presented as RVSR1 | Reject; explicit import/bridge only |

---

## 13. Shared vectors and implementation gates

### 13.1 Proposed namespace

```text
shared-vectors/rvn1/social_object_wire/
  common_record/
  text_payload/
  post_reply_edit/
  audience_mapping/
  writer_chain/
  public_private_fanout/
  extensions/
  negatives/
```

### 13.2 Required Python/Rust/Swift computation

All three implementations must independently compute:

- exact RVSR1 prefix/header/variable offsets and total length;
- exact RVTX1 bytes and strict UTF-8/control/language validation;
- payload and extension digests;
- signature input, Ed25519 signature verification, and `social_digest`;
- parent/relation/media canonical ordering and duplicate rejection;
- sequence/predecessor replay/gap/conflict outcomes;
- public equality and private per-device seal inequality between social/object
  digests;
- candidate-before-commit and exact replay outcomes;
- cross-audience, cross-repo, wrong-grant, revoked-device, unknown-critical,
  truncation, overflow, trailing, collision, and resource negatives.

JSON fixtures carry hex and human annotations only. Passing by comparing fixture
JSON without performing codec/digest/signature/state computation is not parity.

### 13.3 Crash and durability matrix

Fault injection and real restart tests cover:

1. exact record stage before repository/head/view promotion;
2. record commit before writer-frontier promotion;
3. frontier promotion before derived view update;
4. contact endpoint receipt/ratchet commit before social admission;
5. social admission before local notification materialization;
6. conflict/collision quarantine before any competing candidate release;
7. public-fetch response before subscription frontier advancement;
8. block/revoke learned during every boundary.

Recovery is roll-forward/idempotent. It never rolls back a consumed endpoint key,
reuses a writer sequence, silently drops conflict evidence, or publishes a local
draft.

### 13.4 Simulation and physical gates

At least 1,000 deterministic virtual nodes exercise multi-device offline forks,
partitions/healing, malicious sources, withheld branches, duplicates, label wars,
spam, revocation, follow privacy, view rebuild, carrier churn, and attention
budgets. Safety violations are reported separately from availability/latency.

Physical rows include Terminal/iPhone public author/follower, independently
sealed contact fan-out, kill/relaunch exact retry, multi-source public pull,
offline import, block/revoke, no view/read leak, no auto-media fetch, and path
changes across LAN/relay/mailbox while social identity remains stable.

### 13.5 Two independent green bars

Raven MUST report codec conformance and social authorization as different
results. A syntactically perfect signature is not an authorized post.

| Gate | What green proves | What it does **not** prove |
|---|---|---|
| `RVSR1_CODEC_CONFORMANT` | exact layout, bounds, canonical arrays, payload/extension digests, device signature, social digest, strict negatives | repository ownership, writer authority, audience permission, revocation freshness, feed eligibility |
| `RVSR1_ADMISSION_AUTHORIZED` | exact descriptor/genesis, writer grant/retirement, cert/revocation, audience, predecessor, collision and local-policy evidence all commit | delivery to another device, global truth, ranking, notification, remote erasure |

UI, logs, CI, importers, mirrors, and public sources MUST NOT collapse these
states into one `valid` boolean. Before the admission gate exists, codec KATs
operate only on explicitly labeled non-authorizing fixture digests and no feed,
public source, Object Sync eligibility, or carrier route may consume them.

---

## 14. Migration and interoperability

Existing server posts, Group models, REST moderation decisions, ActivityPub
activities, Nostr events, AT records, and legacy Raven feed rows are not RVSR1.
An explicit import/bridge may map understood fields into a **newly authored** or
clearly attributed imported-candidate record under a separate approved profile;
it must preserve original provenance, disclose semantic loss, and never forge the
original author's Raven device signature.

Raven does not claim generic federation merely because concepts such as Post,
Reply, Like, Follow, or Delete have similar names. External delivery semantics,
server authority, identifiers, signatures, privacy, and deletion behavior remain
distinct.

Current iOS feed/group/moderation services are server-shaped product code and
cannot be switched to this profile until codecs, storage, admission, attention,
repository sync, and physical gates are approved. No compatibility shim may
silently emit plaintext or unsigned RVSR1-like bytes.

---

## 15. Research basis (informative)

Raven borrows lessons, not wire compatibility:

- [RFC 8949 deterministic CBOR](https://www.rfc-editor.org/rfc/rfc8949.html) —
  authenticated data needs one deterministic encoding; Raven chooses a smaller
  fixed binary profile to reduce three-language configuration drift.
- [AT Protocol data model](https://atproto.com/specs/data-model) and
  [repository](https://atproto.com/specs/repository) — content-addressed signed
  public records, deterministic repository structures, independent mirrors, and
  the warning that strict normalized CBOR writing/verification needs special
  configuration/implementation.
- [Secure Scuttlebutt protocol guide](https://ssbc.github.io/scuttlebutt-protocol-guide/) —
  one-writer sequence/previous-hash chains and peer replication; Raven makes each
  certified device an independent writer lineage under identity authorization.
- [Nostr NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) —
  content-addressed signed events over user-selected relays; Raven avoids JSON
  signature serialization and separates relay reach from attention/trust.
- [Merkle Search Trees](https://doi.org/10.1109/SRDS47363.2019.00032) —
  deterministic ordered CRDT representation and efficient open-network
  reconciliation; Raven's current public-repository design does not inherit the
  AT/PDS authority model or freeze an MST in Slice A.
- [ActivityPub](https://www.w3.org/TR/activitypub/) — useful public activity and
  inbox/outbox vocabulary; Raven does not make a hosting server the social
  identity, private-room key authority, or endpoint-delivery oracle.
- [RFC 9420 MLS](https://www.rfc-editor.org/rfc/rfc9420.html) — the required
  future private multi-party security basis; custom group keys are forbidden.

---

## 16. Open items and delivery sequence

### 16.1 Open before Slice-A vector freeze

1. Independent audit of all RVSR1/RVTX1 offsets, size equations, signature-domain
   length, count maxima, canonical ordering, and UTF-8/control policy.
2. Decide whether plain text remains the only V1 body format or freeze one inert
   restricted-Markdown grammar with renderer vectors.
3. Freeze exact public/contact audience commitment bytes and repo/genesis binding.
4. Confirm certificate/device-ID historical evidence interface for V1 and V2.
5. Freeze collision/gap/conflict durable record and repair authority.

### 16.2 Open before full companion approval

1. Exact payloads for tombstone, reaction, profile, follow, moderation label,
   capability, and membership hint.
2. Approval and three-language admission parity for drafted
   RVSD1/RVWG1/RVWR1, plus exact RVHA1/RVSM1/RVPD1 families.
3. Continuity-V2 author/control evidence and V1→V2 repository migration.
4. Media manifest/chunk/encryption/cache profile.
5. Public-read request/response and source privacy/OHTTP vectors.
6. Contact fan-out/ACK aggregation UI semantics without false global delivery.
7. Attention label/appeal/conflict and capability revocation wires.
8. Three-language vectors, persistent crash tests, simulations, physical matrix,
   independent review, and human approval.

### 16.3 Recommended implementation order

```text
A0. RVSR1 + RVTX1 syntax/signature/digest KATs (lab-only, non-authorizing)
B.  repository descriptor + writer grant/retirement + audience wires
A1. three-language admission vectors using the exact B evidence
C.  durable writer/head/admission store and restart tests
D.  head announcement + segment + asymmetric public pull
E.  public Post/Reply/Edit local feed behind Attention Firewall
F.  remaining payload kinds, media, Continuity V2, and MLS communities
G.  carrier/physical activation one profile at a time
```

No later step may weaken or bypass an earlier trust, exact-byte, durability,
privacy, or production hold.

---

## 17. Production holds

No social Release path may enable until:

1. this companion and its semantic prerequisites are **APPROVED**;
2. every enabled kind/payload/repository evidence family has exact vectors;
3. the umbrella registers public endpoint-record families;
4. public and private audience mappings pass cross-class negatives;
5. durable writer/head/view/conflict/revocation crash matrices pass;
6. Object Sync/public pull/carrier profiles are approved for each path;
7. Attention Firewall is approved for stranger discovery/feed/notification;
8. ID Resolution is approved for short-ID/handle discovery;
9. Continuity V2 is approved before stable recovered repository claims;
10. MLS/community profiles are approved before private circles;
11. no RVNP1, unsigned, JSON/CBOR reinterpretation, server-authority, remote
    ranking, auto-media, read-telemetry, or delivery-from-write fallback exists;
12. independent security/privacy review and protocol-owner approval are recorded;
13. automated, simulation, and physical gates pass without known flaky/hanging
    tests being counted as success.

---

## 18. Document history

| Revision | Date | Summary |
|---:|---|---|
| 1 | 2026-08-21 | Initial wire design: Raven Canonical Binary decision; exact 280-byte RVSR1 prefix, variable-header arrays, signature/digest domains, extension TLV, RVTX1 text payload, Post/Reply/Edit structural rules, audience/object mapping, repository-evidence boundary, admission/view/crash/resource/failure/vector gates, migration and research rationale. Production remains disabled; repository and remaining payload wires remain explicitly open. |
| 2 | 2026-08-21 | Red-team revision: made RVSR1's stricter device-ID authoring subset explicit; moved device-signature verification ahead of larger repository proof work and prohibited ambient evidence fetches under the actor lease; froze Post/Reply quote cardinality and Edit structural inheritance; defined text controls by Unicode scalar and exact byte preservation; bound DAG parents to one repository/audience and relations to a one-way visibility lattice; reconciled endpoint ACK receipt with separate social admission; split codec conformance from authorization so green syntax can never masquerade as a valid/feed-eligible post. |
| 3 | 2026-08-21 | Linked the exact but unapproved Social Repository Authority draft; froze the non-circular RVSG1-core→writer-policy→descriptor direction and exact `audience_commitment = SHA-256(RVAP1)` mapping; retained carrier/production holds and separate codec/admission green bars. |
| 4 | 2026-08-21 | Attention-plane reconciliation: replaced the ambiguous storage/feed/rank/forward bundle with seven independent verification, eligibility, resource, custody, dissemination, attention, and notification outcomes; media fetch and forwarding now require their own charged/intended paths. |
| 5 | 2026-08-21 | Private-discovery boundary: an RVSR1 may become a bounded candidate only through the separate discovery/Attention gates; discovery evidence, order or score never authorizes the object, creates a graph edge, or substitutes for RVSR1 admission. |
| 6 | 2026-08-21 | Sovereign-media boundary: registered the production-disabled provenance companion for any future nonzero media reference; kept asset, media-root, C2PA-manifest and social-publication digests separate; required new identities for renditions/edits and retained the zero-media Slice-A hold. |
