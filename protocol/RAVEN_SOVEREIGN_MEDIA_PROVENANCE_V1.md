# RAVEN Sovereign Media Provenance V1

**Version:** 1 (architecture/privacy draft; wire and library profile not frozen)

**Document revision:** 1

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no C2PA parser, claim
generator, trust list, CAWG assertion, capture attestation, consent/use record,
manifest repository, soft-binding resolver, watermark, AI detector, camera/
microphone integration, media transcoder, renderer badge, database migration,
live callsite, dependency, background task or Release flag

**Approval prerequisites:**
[`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md)
must be revised and re-approved for the media/provenance byte classes and public
record families. [`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md),
[`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md),
[`RAVEN_SOCIAL_OBJECT_WIRE_V1.md`](RAVEN_SOCIAL_OBJECT_WIRE_V1.md),
[`RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md`](RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md),
[`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md), and exact
media storage/chunk/render profiles must be **APPROVED**. Private-room use also
requires [`RAVEN_SOVEREIGN_COMMUNITIES_V1.md`](RAVEN_SOVEREIGN_COMMUNITIES_V1.md).

**Non-interference:** this draft does not reinterpret Raven author signatures,
social records, attachments, archive evidence, C2PA bytes, CAWG assertions,
watermarks or labels. It authorizes no mandatory global media registry, C2PA
certificate authority, Raven trust list, identity provider, AI model service or
truth oracle. Existing media remains `PROVENANCE_UNKNOWN` until a later exact
profile verifies positive evidence.

---

## 0. Constitutional decision

Raven separates five questions that centralized feeds routinely collapse:

```text
Asset integrity              Which exact bytes or rendition were inspected?
Publication authorship       Which Raven writer published this reference?
Workflow provenance          Which signer/tool claims capture/edit/AI history?
Participation/use consent    Which exact person granted which bounded use?
Local trust and attention    What will this device display, label or amplify?
```

The governing rule is:

> Provenance is verifiable evidence about signed claims and byte history. It is
> not proof that a depicted event is true, that everyone consented, that the
> publisher owns copyright, that an edit is harmless, or that media without
> provenance is fake.

A valid Raven signature proves the exact Raven device published an exact social
record. A valid C2PA Manifest proves only the validated claim/asset bindings and
credential statements in its profile. A consent record proves only that its
signer granted the exact enumerated scope. A moderation label remains a selected
labeler's assertion. No result silently widens another.

The key words MUST, MUST NOT, SHOULD and MAY are interpreted as in BCP 14 when
capitalized.

### 0.1 Why Raven needs an interoperable companion

C2PA 2.4 supplies interoperable Content Credentials, hard/soft content
bindings, ingredients, actions, AI Disclosure, redaction and live-video
structures. Raven does not invent a competing asset-manifest format. A later
pinned adapter consumes and optionally emits exact standard C2PA bytes.

Raven adds only the authority boundaries C2PA deliberately leaves to an
application:

- an exact binding between Raven publication evidence and one asset/manifest;
- Raven-local identity continuity and device-revocation interpretation;
- decentralized embedded/sidecar storage with no mandatory manifest operator;
- local attention and moderation behavior;
- separate scoped participation/use-consent records; and
- protected/private-room handling that does not leak provenance publicly.

### 0.2 Four honest UI outcomes

Every asset has one locally computed outcome, never one universal “real/fake”
bit:

| Outcome | Meaning |
|---|---|
| `VERIFIED_PROVENANCE` | Exact asset/manifest/signature/profile checks passed; show exactly which claims passed |
| `PROVENANCE_UNKNOWN` | No usable evidence was supplied/found; neither authentic nor fake is inferred |
| `PROVENANCE_INVALID` | Supplied evidence is malformed, mismatched, tampered or cryptographically invalid |
| `PROVENANCE_CONFLICT` | Two authenticated claims cannot coexist under the frozen identity/asset/slot rules |

`UNKNOWN` MUST NOT be demoted, hidden or called synthetic merely for lacking
Content Credentials. `VERIFIED` MUST NOT be called true, unedited, human-made,
consensual, copyright-cleared or safe unless a separate exact assertion proves
that narrower claim and the UI names its signer/scope.

---

## 1. Goals, non-goals and honest limits

### 1.1 Goals

| Goal | Required property |
|---|---|
| MP1 | Preserve interoperable capture/edit/ingredient/AI provenance across decentralized Raven publication |
| MP2 | Keep Raven authorship, C2PA claim-generator identity and named-actor identity visibly separate |
| MP3 | Make exact-byte and derived-rendition relationships inspectable without one platform database |
| MP4 | Let vulnerable creators redact sensitive metadata while preserving explicit redaction evidence where the profile permits |
| MP5 | Express participant/use grants as scoped evidence without biometric surveillance or false ownership claims |
| MP6 | Preserve private-media provenance inside the recipient/room confidentiality boundary |
| MP7 | Keep media without credentials eligible for speech, journalism and human-rights evidence |
| MP8 | Make AI generation, AI-assisted edits, translation, dubbing and composition machine-readable when disclosed |
| MP9 | Keep rendering, ranking, moderation, fetch and forwarding as distinct local decisions |
| MP10 | Support embedded, sidecar, offline, user-owned mirror and multi-source distribution without a mandatory Raven operator |

### 1.2 Non-goals

This companion does not:

- detect whether pixels/audio/video are AI-generated;
- prove an event happened, a quote is correct or context is complete;
- prevent screenshots, re-recording, metadata stripping or malicious editing;
- establish copyright ownership, license validity or legal consent;
- require a camera vendor, certificate authority, government ID, blockchain,
  biometric database, watermark vendor or global manifest repository;
- deanonymize a journalist/witness to earn feed reach;
- make a C2PA signer, Raven author, publisher, editor or depicted person the
  same identity automatically;
- infer depicted-person identity with face/voice recognition;
- guarantee deletion/revocation of copies already obtained;
- auto-fetch remote manifests, ingredients, models, thumbnails or links;
- treat a watermark/perceptual hash as a cryptographic hard binding;
- approve server-side plaintext transcoding or moderation; or
- define a detector score as authenticity, rank or moderation authority.

### 1.3 Adversaries

The model includes malicious publishers, editors, claim generators, C2PA
signers, certificate issuers/trust lists, timestamp authorities, manifest
repositories, mirrors, bridges, transcoders, AI services, labelers, storage
providers and recipients. Attacks include manifest stripping/copying, stolen
signing keys, dishonest pre-signing claims, ingredient omission, title/location
leaks, soft-binding collision, stale revocation/trust lists, redaction recovery,
URI/SSRF, parser/JUMBF/CBOR/media exploits, decompression bombs, metadata floods,
fake consent, consent replay/transplant, identity homoglyphs, re-encoding,
cropping, dubbing, context removal and discriminatory “credential required”
ranking.

### 1.4 Unavoidable limits

- A genuine device can faithfully sign a staged scene or a false statement.
- A compromised claim generator can create valid misleading provenance until
  its credential/reputation is revoked or distrusted.
- An authorized participant can copy, screen-record or externally record media.
- Metadata and signatures can be stripped. Soft-binding recovery can improve
  discovery but introduces repository, collision, tracking and privacy risks.
- A withdrawal cannot erase copies or undo lawful/unlawful uses already made.
- A signature from a person says only what the signed scope says; it does not
  imply ownership, employment, endorsement or unlimited consent.
- Public provenance can expose identity, tool, time, location, workflow and
  association data. Privacy-preserving omission may be safer than a badge.

---

## 2. Media and provenance identities

### 2.1 Four non-interchangeable digests

```text
asset_digest            = profile hash of exact asset bytes
manifest_store_digest   = hash of exact C2PA Manifest Store/sidecar bytes
media_root_digest       = approved Raven chunk/verified-stream root
publication_digest      = SHA-256(exact Raven social/public endpoint record)
```

These digests are not aliases. A media root provides bounded chunk integrity,
not asset-format semantics or provenance. A C2PA hard binding uses its own exact
profile, not Raven's social digest. A Raven publication signature binds the
reference, not every unreferenced claim in an external repository.

The later `RavenMediaProvenanceReferenceV1` freezes the exact tuple and profile
IDs; until then Social Object Wire media count remains zero in enabled vectors.

### 2.2 Derived assets and renditions

Cropping, compositing, retouching, translation, dubbing, subtitle burn-in,
frame insertion/removal, generative fill and editorial changes create a derived
asset with a new exact asset digest and new active provenance. Prior assets are
ingredients by exact validated reference, not “the same file.”

Lossless container metadata insertion or a non-editorial rendition may still
change exact bytes. The pinned C2PA content-binding/action profile determines
the relationship; Raven never guesses equivalence from filenames, dimensions,
timestamps or perceptual similarity.

### 2.3 No global perceptual identity

Perceptual hashes, acoustic fingerprints and invisible watermarks are optional
soft-binding hints only under a separate reviewed profile. They MUST NOT become
globally published stable user/media identifiers, dedup keys, moderation facts,
copyright decisions, contact links or proof of origin. Collision or lookup
success yields a bounded candidate that still requires hard validation.

---

## 3. Interoperability and trust planes

### 3.1 Exact C2PA profile

The first implementation candidate is C2PA Content Credentials 2.4, but this
architecture does not freeze it. Approval requires exact:

- specification/version/features and forward-compatibility behavior;
- C2PA SDK/library source, commit/package hash, license and reproducible build;
- supported formats, JUMBF/CBOR/COSE/X.509 algorithms and size limits;
- hard-binding, ingredient, action, redaction, timestamp, certificate-status,
  AI Disclosure and live-video subsets;
- unknown/deprecated/unsupported assertion behavior;
- external manifest/cloud data/URI policy;
- trust-list/revocation freshness and offline state labels; and
- Python/Rust/Swift byte/result vectors against an independent validator.

Raven wraps or references exact C2PA bytes. It MUST NOT parse them into a Raven
JSON dialect, reorder them, silently discard validation failures or call a
non-conformant subset “C2PA compatible.”

### 3.2 Three identities shown separately

| Evidence | What it can authenticate |
|---|---|
| Raven social signature | Raven address/device that published the exact reference |
| C2PA claim signature | C2PA claim generator/signer under selected X.509 trust policy |
| CAWG/Raven named-actor assertion | Exact actor's signed relationship to specified assertions/asset |

The C2PA claim generator is commonly software/hardware or its operator, not
necessarily the photographer, editor, subject or Raven publisher. UI displays
these scopes separately.

CAWG Identity Assertion 1.1 is an interoperability candidate. A future Raven
adapter may prove control of a Raven identity inside a CAWG assertion only
after exact signature, address, continuity, device/cert/revocation, assertion
hashlinks and asset binding freeze. It MUST NOT invent a DID mapping, reuse a
Raven device key in an incompatible signature domain or trust a display name.

### 3.3 User-selected trust, no universal CA

C2PA X.509 validation and Raven identity validation remain separate. A client
may ship a transparent baseline C2PA trust list and let users choose additional
lists/anchors, but:

- trust-list membership is not Raven verification, truth, consent or rank;
- list version/freshness/source and revocation availability are visible;
- stale/offline/unavailable revocation produces a bounded freshness state;
- one Raven operator cannot silently add/remove global trusted speech; and
- content without a trusted C2PA chain remains publishable as `UNKNOWN`.

Local trust-list changes affect local interpretation only. They never rewrite
the asset, publication record or globally authoritative state.

---

## 4. Provenance lifecycle

### 4.1 Capture/original

A capture claim may bind exact bytes, device/tool signer, actions and optional
time/location/sensor claims. It proves those signed claims under the selected
trust profile; it does not prove the lens saw an unstaged real event.

Capture defaults minimize metadata. Precise location, device serial, owner
name, account, local path and persistent hardware identifier are opt-in and
individually previewed before public export. Private capture may retain richer
encrypted local evidence without publishing it.

### 4.2 Edit and ingredients

Every significant export either:

1. preserves and validates ingredients/action history in a new standard
   Manifest; or
2. explicitly records that provenance/ingredients were unavailable, invalid,
   acknowledged with warnings or intentionally redacted.

An editor cannot inherit trust merely by importing a valid ingredient. The new
claim generator signs its own actions and validation result. Omitted ingredients
and failed validations are not normalized into a clean chain.

### 4.3 AI generation and assistance

The pinned profile distinguishes at least:

- trained-algorithmic media created from a model;
- human-authored media with AI-assisted/composite edits;
- translation, dubbing, voice conversion, generative fill and synthetic
  persons/voices where representable;
- model/tool assertions and human-oversight claims; and
- unknown/undisclosed processing.

C2PA 2.4 `digitalSourceType`, actions/ingredients and `c2pa.ai-disclosure` are
the interoperability baseline. Raven does not make model name, prompt, training
data, user identity or proprietary workflow mandatory public metadata. A valid
AI disclosure proves the signer made that disclosure; it does not prove the
model description is complete or that the output is harmless.

Detector output is an optional signed moderation/analysis assertion with model
version, calibration scope and uncertainty. It never overwrites provenance or
becomes a universal synthetic-content fact.

### 4.4 Transcode and delivery rendition

Client-side thumbnailing, format conversion and streaming renditions create
bounded derivative evidence that names the exact source asset/manifest and
non-editorial transformation. A storage/CDN/carrier cannot claim the original
publisher performed a transcode unless the new chain proves it.

Server-side plaintext transcode is forbidden by default for private media. A
user-selected public-media service is a declared claim generator/provider and
receives only the authority its exact output profile states.

### 4.5 Redaction

Creators may remove sensitive optional assertions through the exact C2PA
redaction/update-manifest rules. Raven shows that redaction occurred and never
reconstructs/redelivers removed data automatically.

Redaction cannot guarantee erasure from prior assets, caches, recipients,
archives, external manifests or soft-binding repositories. A public soft-
binding repository that retains old sensitive manifests is incompatible with a
privacy-preserving claim unless the UI disclosed that retention before upload.

### 4.6 Stripped and legacy media

If embedded credentials disappear, Raven may validate an exact supplied
sidecar. Soft-binding lookup is disabled by default and requires explicit
source/privacy policy. No match or no sidecar is `PROVENANCE_UNKNOWN`.

An invalid embedded manifest is `INVALID`, not silently treated as absent. A
publisher may create a new Manifest acknowledging an unverified legacy
ingredient; it cannot manufacture the missing history.

---

## 5. Participation, consent and use grants

### 5.1 Consent is separate evidence

C2PA currently has only a draft placeholder for a general CAWG Consent
Assertion. Raven therefore defines semantic requirements here but freezes no
wire until that standard matures and is reviewed.

A future `RavenMediaParticipationGrantV1` is a signed statement by one exact
Raven identity/device binding:

```text
grant_id and previous/superseded grant digest
exact asset_digest OR bounded capture_session_commitment
grantor Raven address/device/certificate/continuity evidence
grantee/publisher identity or community/repository scope
allow-listed purpose bits
audience and territorial/context statement where legally meaningful
issued/expires window and optional review horizon
explicit exclusions
signature and schema/profile digests
```

Baseline purpose bits are separate and non-implying:

```text
PUBLICATION
PRIVATE_SHARE
COMMUNITY_DISPLAY
PROMOTION_OR_ADVERTISING
EDIT_OR_DERIVE
VOICE_OR_FACE_SYNTHESIS
AI_TRAINING_OR_DATA_MINING
TRANSCRIPTION_OR_TRANSLATION
ARCHIVE
```

Granting `PUBLICATION` does not grant advertising, synthesis, training,
translation or unlimited derivation. An absent grant is `CONSENT_UNKNOWN`, not
proof of refusal or wrongdoing. A publisher's statement “all participants
consented” is provenance about the publisher's claim, not individual consent.

### 5.2 No biometric identity oracle

Raven does not scan faces/voices to discover who should consent. A participant
may explicitly receive a local/OOB capture-session commitment and sign a grant.
The grant identifies the signer and exact scope, not every pixel/voice segment
automatically. Unidentified bystanders and documentary/public-interest cases
remain policy/legal questions, not cryptographic falsehoods.

### 5.3 Withdrawal and conflict

A withdrawal names the exact prior grant and can constrain future Raven-local
display/recommendation/republication according to the user's selected policy.
It cannot erase copies, retroactively make a past signature invalid, revoke a
lawful basis outside the grant, or prove the original use was illegal.

Same grant ID/sequence with different authenticated bytes is conflict evidence.
Omission is never withdrawal. A local block can suppress regardless of grant;
unblock never clears a withdrawal or device revocation.

### 5.4 Training/data-mining preference is not DRM

CAWG Training and Data Mining assertions are optional interoperability inputs.
Raven may expose a signed preference/use grant and let compliant tools respect
it. It cannot claim that metadata technically prevents scraping, training,
copying or legal exceptions after plaintext is public.

No crawler/provider may convert a public Raven post into affirmative consent
for AI training merely because a preference assertion is absent.

---

## 6. Publication and storage modes

### 6.1 Public social media

A public social record references:

```text
media_root_digest + media profile
asset_digest + asset profile
manifest_store_digest + C2PA profile (optional)
provenance policy/result expectation
optional exact participation/use-grant digests
```

The record, asset/chunks, Manifest Store and grants are separately immutable.
Sources/mirrors can serve exact bytes but cannot alter provenance. A public
Raven repository may distribute embedded or detached manifests alongside media
with no central catalog.

### 6.2 Private DM and community media

Private media assets, manifests and grants are encrypted/padded under the exact
ATSAM/MLS attachment profile. They are not uploaded to a public manifest
repository, soft-binding resolver, C2PA trust service or global dedup index.

Receiving private media does not grant public reposting, training, archive or
bridge rights. A public repost is a new explicit publication/derivation event
and cannot expose private provenance metadata or participants silently.

### 6.3 Detached manifests and mirrors

Detached manifests may be carried by:

- the same Raven public repository as the asset;
- user-selected independent mirrors;
- offline drops/removable media; or
- a later explicit C2PA manifest-repository adapter.

No single source is completeness authority. Multi-source union preserves exact
conflicts and never treats copy count as truth. External URLs are hints only;
Raven validates scheme/host/private-network/redirect/size/content/profile before
fetch and never fetches merely because a feed row rendered.

### 6.4 User-owned archive

Archive stores exact eligible asset/manifest/grant bytes plus admission evidence
under archive encryption. Restore is historical/quarantined and performs no
republish, soft-binding lookup, trust-list refresh, media decode or Attention
mutation. Current revocation/trust/policy is re-evaluated before later display
or explicit publication.

---

## 7. Admission, validation and rendering

### 7.1 Pipeline

```text
reserve weak-lane bytes/items/work
  -> parse outer Raven media reference and exact lengths
  -> verify Raven publication identity/cert/revocation/audience
  -> verify media-root chunks before assembly/decode
  -> sandboxed exact asset/profile hash
  -> bounded C2PA parse + hard binding + claim/signature/profile validation
  -> validate ingredient/redaction/timestamp/revocation/AI subsets
  -> independently validate Raven/CAWG actor and consent/use evidence
  -> one transaction: validation result + provenance graph + render intent
  -> release only locally admitted render/Attention work
```

No remote manifest, thumbnail, ingredient, model URI, certificate URL, OCSP/CRL,
timestamp or media codec executes before the relevant explicit network/resource
policy. Validation result records include freshness/availability limitations;
offline validation cannot pretend current revocation.

### 7.2 Parser and renderer isolation

C2PA/JUMBF/CBOR/COSE, image/video/audio/document containers, metadata, fonts,
codecs and thumbnails are hostile input. Implementations use:

- exact format/version allow-lists;
- checked integer/offset arithmetic and no trailing ambiguity;
- manifest/assertion/ingredient/nesting/string/URI/certificate caps;
- cumulative decompression/decode pixel/frame/duration/audio-channel budgets;
- process/sandbox isolation where supported;
- no script, macro, active document, remote font or external helper execution;
- fuzz/corpus/differential validation; and
- zero network access in pure validator/render-preview tests.

### 7.3 Result is immutable evidence, not a badge cache

A validation result binds exact asset/manifest/profile/trust-list/revocation
snapshot and validator build digest. Trust-list/freshness changes create a new
local result; they do not rewrite historical bytes. UI never reuses a green
badge for a different rendition, thumbnail or post reference.

---

## 8. Product language and accessibility

Raven uses progressive disclosure:

| Level | Example |
|---|---|
| L0 | `Provenance available`, `No provenance supplied`, `Provenance warning` |
| L1 | `Posted by Raven user X`; `C2PA signed by tool/org Y`; `AI generation disclosed`; `Edited from N ingredients` |
| L2 | Exact actions, identities, grants, redactions, validation/freshness states and provider sources |
| L3 | Raw bytes/digests/profile/status codes/exportable diagnostic evidence |

Forbidden labels without narrower evidence include:

```text
real / fake
human-made
unedited / original truth
everyone consented
copyright cleared
safe / unbiased
official merely because a C2PA chain validates
```

Every icon has text, screen-reader state and a local “Why?” explanation. The
explanation performs no network request. Missing credentials never lower basic
accessibility, posting ability or default speech eligibility.

---

## 9. Attention, moderation and discovery

Provenance results are locally selected recipe inputs, not global rank. A user
may choose to prioritize specific trusted capture/news/editorial workflows, but
Raven defaults never bury `UNKNOWN` solely for lacking costly/new hardware or a
CA certificate.

Labels such as `suspected impersonation`, `AI disclosure missing`, `context
removed` or `consent disputed` are signed labeler assertions. They do not modify
the asset/manifest, impersonate a participant or become universal truth.

Discovery indexes may expose only explicitly public bounded provenance facets.
They MUST NOT expose private grants, participant identities, capture location,
device serial, trust-list choices, validation queries or soft-binding lookups.
Opening “Why shown?” performs no media/manifest fetch.

---

## 10. Communities, bridges and realtime capture

### 10.1 Communities

Community governance may require a provenance policy for official channels,
but cannot require every member to deanonymize or buy trusted hardware to
speak. Private-room media remains MLS-encrypted. Moderator provenance policy is
separate from membership, message authenticity and local Attention.

### 10.2 Bridges

A Matrix/ActivityPub/web/email bridge is a declared claim generator/publisher.
If it strips or cannot preserve C2PA bytes, Raven displays provenance loss. If
it transcodes, it creates a new derived asset/manifest and must not sign as the
original creator. A bridge cannot fabricate participant consent.

### 10.3 Realtime and recordings

Private calls under
[`RAVEN_PRIVATE_REALTIME_MEDIA_V1.md`](RAVEN_PRIVATE_REALTIME_MEDIA_V1.md)
never create public provenance automatically. An explicitly authorized local
recording is a new asset with visible recording consent/policy evidence and a
fresh provenance chain. SFrame/DTLS transport security is not capture
provenance, and C2PA live-video provenance is not call membership/consent/E2EE.

A future public live-broadcast profile may use C2PA 2.4 live-video structures,
but requires separate segment/timestamp/drop/reorder/replay/privacy vectors and
cannot reuse private call signaling.

---

## 11. Privacy and human-rights safeguards

1. Provenance collection is opt-in and previewed before capture/export.
2. Sensitive identity/location/device/tool/account fields default absent.
3. Private manifests never enter public repositories/soft-binding lookup.
4. Anonymous/pseudonymous publishing remains valid; Raven may prove stable
   pseudonymous continuity without exposing civil identity.
5. Identity assertions bind only exact claims; they do not expose a complete
   credential wallet or unrelated identifiers.
6. Redaction/UI warns that prior external copies may retain data.
7. Validation queries, trust-list choices and viewed-media fingerprints remain
   local; a remote verifier cannot become a reading-history oracle.
8. No mandatory C2PA badge for journalism, protest footage, whistleblowing,
   accessibility, legacy hardware or low-resource creators.
9. Child/intimate/medical/location/survivor media needs a later specialized
   policy; this V1 does not claim legal consent handling.
10. Public graph/social/recommendation systems never infer relationships from
    shared ingredients, tools, locations, claim signers or grantors.

---

## 12. Resource and abuse ceilings

Exact values freeze with vectors. Separate finite ceilings cover:

- asset/chunk/manifest/sidecar/grant bytes and retained versions;
- Manifests per Store, assertions per Manifest, ingredients/depth/graph nodes;
- CBOR/JUMBF boxes, strings, URIs, certificates/chains, timestamps/status rows;
- image pixels/frames, video duration/resolution/tracks, audio duration/channels;
- decompressed bytes, metadata entries, thumbnails and alternative renditions;
- validation CPU/memory/deadline/concurrency and trust/revocation network work;
- detached-manifest sources, redirects, collisions and soft-binding candidates;
- grants/withdrawals/conflicts per asset/identity; and
- cache/archive/public-repository retention and garbage-collection work.

Budgets reserve before parse/hash/crypto/decode/network. A provenance bomb
cannot evict messages, contacts, revocations, identity conflict, session heads,
accepted social state or protected anchors. Capacity failure is explicit and
does not reclassify invalid/unknown evidence as valid.

---

## 13. Failure and downgrade matrix

| Event | Required outcome |
|---|---|
| No manifest/sidecar | `PROVENANCE_UNKNOWN`; content remains eligible under ordinary policy |
| Embedded manifest stripped | Unknown or explicit stripped evidence if a trusted exact reference exists; no fake verdict |
| Partial/tampered manifest | `PROVENANCE_INVALID`; no fallback to absent/green |
| Valid manifest, untrusted signer | Structurally/cryptographically valid with untrusted-signer state; not verified identity |
| Valid manifest, false scene/claim | Provenance remains valid evidence about signer claim; no truth label |
| Stolen/revoked claim key | Current freshness/revocation policy warns/refuses affected trust claim; bytes remain historical evidence |
| Stale/unavailable trust/revocation | Exact bounded stale/unknown state; no silent fresh/invalid choice |
| Raven publisher differs from C2PA actor | Display both; no automatic merge or impersonation |
| Derived bytes reuse old manifest | Hard-binding failure; reject old badge |
| Transcoder strips chain | Show provenance loss; never preserve old green badge by filename |
| Soft-binding collision/many candidates | Bounded candidates; hard validate; conflict/unknown, never first-match |
| External URI/redirect/private address | Refuse under SSRF/profile policy; no auto-fetch |
| AI disclosure present | Show signer-scoped disclosure, not detector truth/completeness |
| AI disclosure absent | Unknown; no claim human-made |
| Individual grant absent | `CONSENT_UNKNOWN`; publisher assertion cannot substitute |
| Grant scope mismatch/expired/revoked device | Refuse that grant for requested use; no widening |
| Withdrawal received after copies exist | Apply future local policy and disclose limit; no deletion guarantee |
| Labeler disagrees | Preserve signed labels/provenance; local policy decides display |
| Parser/decoder/capacity failure | No view/rank/fetch mutation; bounded error evidence only |
| Crash after reference commit before fetch | Retry explicit fetch intent only; no badge/result fabrication |
| Archive restore | Quarantined historical bytes; no republish/lookup/validation side effect |

---

## 14. Durability and crash ordering

Protected/durable local state includes:

```text
exact media-reference admission
asset/manifest/grant bytes or immutable locators
validation profile/build/trust/revocation snapshot digests
provenance graph and conflict evidence
fetch/validate/render/attention intents
redaction/withdrawal/local-policy state
resource reservations and GC horizons
```

Every mutation uses one non-reentrant lease and roll-forward order:

```text
reserve
  -> stage exact input/result bytes
  -> protected journal
  -> one SQL transaction for evidence + next intent
  -> protected anchor finalize
  -> clear journal
  -> release render/network/UI outside lease
```

Crashes never regenerate a claim/grant/signature, convert unknown to verified,
reuse a result for other asset bytes, forget conflict/withdrawal, or mark remote
fetch as complete. Network validation/fetch is never held inside the lease.

---

## 15. Required vectors, simulation and physical gates

### 15.1 Shared vectors

Python, Rust and Swift independently compute/verify:

- exact asset/manifest/media-root/publication digest separation;
- embedded/detached C2PA 2.4 hard-binding and claim validation;
- action/ingredient/redaction/timestamp/certificate/AI Disclosure subsets;
- Raven publication and optional CAWG/Raven identity binding;
- valid/untrusted/stale/revoked/unknown/invalid/conflict result lattice;
- original/derived/rendition/composed assets and transplant negatives;
- grants, purpose non-implication, withdrawals, conflict and device revoke;
- strict parser/cap/URI/SSRF/decompression/trailing/unknown-field negatives;
- exact validation-result snapshot and crash-journal ordering; and
- bridge/transcode/provenance-loss behavior.

At least one independent C2PA validator and official conformance corpus must
agree on the selected standard subset. JSON-only fixture comparison is not
compute parity.

### 15.2 Deterministic simulation

A 1,000-node model covers old/new clients, signed/unsigned media, embedded/
detached/stripped manifests, malicious repositories, transcoders, bridges,
stale trust/revocation, creator redaction, consent withdrawal, Sybil labelers,
media/provenance bombs, archive restore and partitions. Metrics prove:

- unknown media is not systematically censored;
- valid credentials do not bypass local safety/attention;
- stripping/tamper cannot retain verified UI;
- provenance/soft-binding queries do not become a reading graph;
- no mandatory source becomes availability/trust authority; and
- weak-lane floods do not evict protected/social/contact evidence.

### 15.3 Process and physical matrix

| Row | Required evidence |
|---|---|
| iPhone capture → Mac/Terminal | Embedded/sidecar exact validation; privacy preview; offline verify |
| Mac/Terminal edit → iPhone | Ingredient/action chain and new asset identity |
| AI generation/AI edit | Machine-readable disclosure and unknown/invalid negatives |
| Two independent C2PA tools | Export/import byte/semantic interop without Raven dialect |
| Metadata stripping/transcode | Unknown/loss/invalid UI; never stale green badge |
| Detached/offline mirror | Multi-source exact bytes; no central repository requirement |
| Private DM/MLS room | Encrypted provenance; no public lookup or metadata leak |
| Archive/reinstall | Historical exact evidence; no automatic republish |
| Participant grant/withdrawal | Purpose-scoped UI and honest non-erasure limit |
| Malicious corpus | Sandbox/fuzz/cap/SSRF/decompression safety on every platform |

Device/simulator tests cannot replace real camera export, third-party tool,
metadata stripping, offline, bridge and cross-platform evidence.

---

## 16. Production holds

Production remains disabled until:

1. the umbrella registers/re-approves asset, C2PA and Raven provenance/grant
   byte classes without weakening endpoint-object invariants;
2. exact C2PA/CAWG versions, libraries, trust/revocation policies and format
   subsets freeze with license/provenance/reproducible-build review;
3. Social Object Wire and media chunk/verified-stream profiles are APPROVED;
4. Raven publication, C2PA claim-generator, named actor, consent and labeler
   identities remain visibly/provably separate;
5. no-metadata=unknown and valid-manifest-not-truth UX passes independent harms,
   accessibility, journalism and human-rights review;
6. private DM/community/archive provenance has no public manifest/soft-binding/
   validation-query leakage;
7. exact AI disclosure/ingredient/redaction/transcode and participant-use-grant
   vectors pass all three languages and independent validator interop;
8. trust-list/revocation freshness, key compromise, parser/sandbox/fuzz/SSRF/
   decompression/resource matrices have no open P0/P1;
9. multi-source/offline/user-owned mirror behavior needs no mandatory Raven,
   C2PA, CA, cloud or blockchain operator;
10. 1,000-node and full process/physical matrices pass; and
11. independent cryptography, media-forensics, privacy, accessibility, legal-
    product and systems review—or explicit protocol-owner waivers—records no
    unresolved production blocker.

No lab feature may auto-enable capture signing, trust-list network updates,
manifest upload/lookup, soft-binding fingerprinting, AI analysis, consent
collection, media decode, public badge or Release path.

---

## 17. Research foundations (informative only)

- [C2PA Content Credentials 2.4](https://spec.c2pa.org/specifications/specifications/2.4/specs/C2PA_Specification.html)
  — interoperable manifests, hard/soft bindings, ingredients/actions,
  redaction, X.509 trust, AI Disclosure and live-video structures. It explicitly
  treats assertions as trust signals rather than value judgments of truth.
- [C2PA Security Considerations 2.4](https://spec.c2pa.org/specifications/specifications/2.4/security/Security_Considerations.html)
  — stripping, stolen keys, claim-generator misuse, soft-binding collisions,
  stale trust/revocation, malicious metadata and privacy threats.
- [C2PA Harms Modelling 2.4](https://spec.c2pa.org/specifications/specifications/2.4/security/Harms_Modelling.html)
  — valid provenance does not make content true; absent credentials do not make
  it untrustworthy; surveillance, sensitive metadata and unequal-access risks.
- [CAWG Identity Assertion 1.1](https://cawg.io/identity/1.1/) — separates a
  named actor's signed relationship from the C2PA claim generator, and does not
  itself convey ownership or unlimited rights.
- [CAWG Consent Assertion 1.0 draft](https://cawg.io/consent/1.0-draft/) — as of
  2026-08-21 it is only an initial placeholder; Raven cannot claim a frozen
  interoperable consent wire from it.
- [NIST AI 100-4](https://doi.org/10.6028/NIST.AI.100-4) — provenance,
  watermarking and detection are complementary synthetic-content transparency
  techniques with distinct limitations, testing and harm considerations.

These sources do not define Raven authority, storage, consent, social ranking
or wire bytes.

---

## 18. Open decisions before vector freeze

1. Exact C2PA 2.4 subset/profile, SDK implementation and independent validator.
2. Supported asset/container/live-video formats and hard-binding algorithms.
3. Raven media root/chunk/verified-stream format and asset assembly boundary.
4. Embedded versus detached Manifest Store and public/private source policy.
5. C2PA trust-list/TSA/revocation update, cache, offline and user-choice model.
6. CAWG Identity to Raven continuity/device binding without key/domain reuse.
7. Consent/use-grant wire after CAWG Consent matures; jurisdiction/product UX.
8. Redaction and previous-copy/soft-binding repository retention disclosure.
9. AI Disclosure/tool/model/privacy fields and detector-assertion policy.
10. Client-side transcode/rendition chain, streaming and thumbnail profile.
11. Soft binding/watermark/fingerprint profile—or explicit V1 prohibition.
12. Sandbox/process/library/update/fuzz strategy for every Apple/Terminal target.
13. Public mirror/drop/manifest-repository adapter and privacy manifest.
14. C2PA live-video versus public Raven broadcast boundary.
15. Moderation/Attention defaults that avoid both green-badge trust and
    credential-based exclusion.

---

## 19. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial sovereign-media architecture: separates exact asset integrity, Raven publication authorship, C2PA workflow provenance, scoped participation/use grants and local Attention; adopts C2PA 2.4 as an interoperability candidate rather than a Raven dialect; forbids real/fake inference, credential-required speech and mandatory registries; defines capture/edit/AI/transcode/redaction/stripping, public/private/archive, trust-list, parser/resource, UX, failure, durability, vector, simulation and physical production holds |
