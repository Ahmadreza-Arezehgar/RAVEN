# RAVEN Attention Firewall V1

**Version:** 1

**Document revision:** 10

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no public discovery service, stranger-introduction request surface, incoming-call/ringing/capture path, anonymous credential issuer, labeler, report intake, ranking engine, notification path, codec, database migration, live callsite, or Release flag

**Depends on:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md), [`RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md`](RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md), [`RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md`](RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md), [`RAVEN_ID_RESOLUTION_V1.md`](RAVEN_ID_RESOLUTION_V1.md), [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md); [`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md) only when bounded media-provenance evidence is a selected local input

**Unblocks when APPROVED:** local attention lanes; explainable device-owned ranking; bounded public-candidate admission; user-selected labeler/curator subscriptions; the resource/ranking boundary required by [`RAVEN_PRIVATE_DISCOVERY_V1.md`](RAVEN_PRIVATE_DISCOVERY_V1.md); optional privacy-preserving write-rate profiles

> Raven separates the right to speak, the cost of distribution, and the decision to show. A valid signature proves authorship. It does not purchase reach, create a contact, bypass a block, or consume the user's attention without local permission.

---

## 0. Purpose and constitutional invariants

Decentralized publication without an attention boundary merely replaces one platform algorithm with an unbounded spam network. Centralized spam prevention, on the other hand, recreates an operator that can silently decide who may speak. Raven therefore defines a **local attention firewall** between verified social bytes and every user-visible feed, alert, storage-expansion decision, or forwarding action.

The following are constitutional invariants:

1. **Authenticity, eligibility, storage, reach, ranking, and notification are distinct decisions.** No result in one plane silently authorizes another.
2. **The receiving device owns attention policy.** A remote author, mirror, relay, labeler, curator, credential issuer, or feed service cannot require placement or rank.
3. **No global follower graph or behavior profile is required.** Raven does not upload a user's follows, blocks, contacts, reading history, dwell time, or ranking weights to construct a feed.
4. **Unknown public content starts in a bounded stranger lane.** It cannot evict contacts, followed repositories, protected state, or authenticated conflict evidence.
5. **Every displayed recommendation can produce a local explanation.** The explanation identifies locally selected inputs and rules without leaking private graph state to the network.
6. **Rate evidence controls only a scoped operation.** It never authenticates content, proves personhood, creates contact trust, clears revocation, or becomes ranking authority.
7. **No single mandatory issuer, labeler, curator, search service, relay, blockchain, stake, proof-of-work market, phone number, or hardware attester is a Raven trust root.**
8. **Offline and partitioned operation remains useful.** Missing moderation/rate services reduces availability or discoverability under explicit policy; it does not invalidate already authenticated local bytes.
9. **No silent privacy downgrade.** If a selected OHTTP or anonymous-rate mode is unavailable, the operation fails or requires an explicit frozen user/policy decision before a more linkable mode is used.
10. **Production remains disabled** until byte-exact companions, three-language vectors, durability, simulations, carrier conformance, and physical matrices pass.

---

## 1. Non-goals

V1 does not define or authorize:

- a Raven-operated global timeline, trending list, firehose, follower counter, or recommendation API;
- a universal reputation score, social-credit score, proof-of-personhood registry, or global ban list;
- payment, stake, token, NFT, proof-of-work, or wealth-weighted routing;
- server-side personalization from private graph/behavior uploads;
- remote execution of ranking code, labeler code, embedded scripts, or downloaded models;
- instant global moderation/revocation under partition;
- remote deletion of public replicas;
- a cryptographic claim that one device can see every abusive copy or every current revoke;
- replacing local law/safety policy at a volunteer cache or relay;
- treating an anonymous credential as identity, humanity, good behavior, or content quality;
- enabling stranger messaging, PairInit, private Object Sync, or notifications through a public-follow action.

---

## 2. Threat model

The design considers:

- a Sybil operator creating many identities, repositories, mirrors, labels, recommendations, or credential requests;
- a malicious but correctly signed author publishing high-volume or harmful content;
- a compromised labeler or curator issuing biased, contradictory, targeted, or tracking annotations;
- a discovery source that withholds, reorders, duplicates, floods, selectively serves, or ranks candidates;
- an issuer/attester that tags clients through metadata, keys, timing, issuance denial, or tiny anonymity sets;
- relay/gateway collusion in OHTTP; network observers correlating timing and sizes;
- forged rate proofs, double redemption, epoch replay, issuer-key rollback, or challenge substitution;
- notification and media-preview abuse after a valid record is admitted;
- malicious ranking recipes attempting excessive CPU/memory, hidden network access, private-state export, or remote code execution;
- local protected-state corruption, rollback, cross-account confusion, crash windows, and quota exhaustion;
- mesh peers exploiting store-carry-forward to amplify public spam or infer subscriptions;
- user-selected policies that are incomplete, biased, or mutually contradictory.

The design cannot guarantee global Sybil resistance without an authority or scarce resource. It instead guarantees bounded local harm, explicit provenance, replaceable authorities, and honest privacy/availability labels.

---

## 3. Seven-plane separation

Every candidate passes seven separate semantic planes. Passing an earlier plane
is necessary but not sufficient for any later one. A cheap syntactic/capacity
preflight and conservative resource reservation occur **before** expensive
cryptography; this reservation is not semantic admission and releases/charges
through the crash-safe budget ledger.

| Plane | Question | Authoritative input | Must never decide |
|---|---|---|---|
| **Cryptographic verification** | Are these exact bytes authentic under the claimed lineage/profile? | Exact object bytes, signature, cert/grant/revocation evidence | Storage, forwarding, rank, notification |
| **Eligibility** | Is this object allowed in this audience/repository/lane? | Contact, public subscription, capability, schema, block policy | Truth, quality, popularity |
| **Resource admission** | May this device spend bytes/CPU/dials now, and what actual charge commits? | Preflight reservation, local quotas, replay state, optional scoped rate evidence | Authenticity, contact, rank or durable custody |
| **Custody/storage** | May exact admitted bytes occupy durable local space, for how long, and under which eviction class? | Separate local retention policy and committed byte quota | Feed placement, forwarding, notification or authenticity |
| **Dissemination** | May this device send/forward the exact object to a named destination/path now? | Explicit publish/reply/forward/subscription action plus carrier policy | Rank, notification, contact creation or global reach claims |
| **Attention selection** | Should this verified object appear, where, and why? | Local recipe, chosen labels/curators, user action, lane | Storage expansion, network forwarding or remote deletion |
| **Notification** | May this event interrupt the user? | Explicit local notification policy | Authenticity or durable admission |

The processing order is therefore:

```text
cheap bounds → reserve → cryptographic verification → eligibility
             → commit actual resource charge
             → independent custody decision
             → independent dissemination decision (only when requested)
             → attention selection
             → notification
```

Custody and dissemination are not automatic stages that every candidate must
pass: either may return `none`. Displaying an already retained object does not
forward it; forwarding does not place it in a feed; ranking does not retain or
fetch media; notification does not emit a view/read/reaction. An implementation
that combines these decisions into one opaque server response, one Boolean
`accepted`, or one remote score is non-conformant.

---

## 4. Attention lanes

Every admitted candidate has exactly one lane before ranking. Lane selection occurs locally from already verified evidence.

| Lane | Entry evidence | Default attention | Network effect |
|---|---|---|---|
| `DIRECT_CONTACT` | Existing local contact + valid endpoint/session admission | User-configurable; bounded notifications allowed | Contact messaging only |
| `FOLLOWED_PUBLIC` | Explicit local repository subscription + verified public bytes | Appears in Following view | Bounded pulls for that exact repo |
| `DELEGATED_COMMUNITY` | Verified attenuated capability/membership evidence under [`RAVEN_SOVEREIGN_COMMUNITIES_V1.md`](RAVEN_SOVEREIGN_COMMUNITIES_V1.md) once APPROVED | Community-local policy plus local user override | Only the proof's exact resource/ability; never MLS/admin authority from a carrier |
| `CURATOR_CANDIDATE` | Verified assertion from a curator chosen locally | Candidate queue; no notification | May schedule bounded exact-object fetch |
| `STRANGER_DISCOVERY` | Verified public candidate without prior local relation | Quarantine/preview budget; no notification | Lowest dial/store/CPU priority |
| `STRANGER_INTRODUCTION` | Fully verified, recipient-bound inert proposal under Private Introduction | Quiet Requests queue; no sound/vibration/badge by default | No dial, media fetch, PairInit, reply or contact until explicit local action |
| `LOCAL_IMPORT` | User-selected QR/file/NFC/backup import | Explicit confirmation path | No implicit publication/follow/contact |

Rules:

1. A lane is not encoded by an untrusted source and cannot be widened by replay.
2. Contact deletion immediately prevents new `DIRECT_CONTACT` admission. A stale session cannot preserve the lane.
3. Unfollow prevents new `FOLLOWED_PUBLIC` pulls while retaining minimum anti-rollback/conflict evidence.
4. A recommendation, label, rate credential, relay count, or repeated copy cannot move an object into a stronger lane.
5. `STRANGER_DISCOVERY` never produces sound/vibration/badge notifications by default.
6. A user may manually open a locally retained bounded **inert** preview only after schema/rendering-sandbox checks; this does not mutate contact or subscription state and cannot trigger remote URL/media fetch automatically.
7. `STRANGER_INTRODUCTION` is distinct from public-content discovery. A valid
   sender signature proves authorship only after recipient-bound decrypt; it
   does not upgrade the lane. Accept/decline/block are local explicit actions,
   and only Accept may schedule the separate contact-commit transition defined
   by Private Introduction.
8. Realtime offers under
   [`RAVEN_PRIVATE_REALTIME_MEDIA_V1.md`](RAVEN_PRIVATE_REALTIME_MEDIA_V1.md)
   can enter only through `DIRECT_CONTACT` or an already-authorized
   `DELEGATED_COMMUNITY` room. Attention separately decides quiet display,
   ring, vibration, badge or suppression. No remote urgency bit, repeat count,
   moderator role, payment, follower count, provider success or route
   availability can force ringing, ICE release, microphone/camera capture or
   background wake.

---

## 5. Local attention budgets

### 5.1 Budget dimensions

The device maintains bounded, protected counters for at least:

```text
bytes_fetched
objects_parsed
signature_verifications
media_bytes
cpu_millis
network_dials
concurrent_sources
stored_candidate_bytes
feed_slots
notification_slots
forwarded_bytes
```

Budgets are scoped by `(local_account_scope_id, lane, source_class, time_bucket)` and MAY be tightened by repo, curator, labeler, topic, carrier, or abuse class. Contact and protected-state quotas are physically separate from stranger/public-candidate quotas. Exhausting a weak lane cannot evict or block stronger-lane safety state.

### 5.2 Local monotonic accounting

Budget refill and expiry use checked local monotonic/runtime inputs plus protected persisted epochs where crash continuity matters. Remote timestamps, source clocks, post creation time, digest order, or repeated reconnects cannot refill a bucket.

Reservation is two-phase:

```text
preflight bounds
  -> reserve exact maximum cost under one local mutation lease
  -> perform bounded fetch/verify outside the lease
  -> commit actual charge or release unused reservation
```

A crash leaves either the conservative reservation or the committed charge. It never creates free work through rollback. Oversize/corrupt input is rejected before expensive allocation when its outer bounds permit.

### 5.3 No transmitted attention budget

The user's budget, lane weights, notification thresholds, hidden/muted topics, and reading behavior are local-only. They MUST NOT appear in endpoint objects, carrier control, public sync requests, anonymous credentials, diagnostic uploads, or exported ranking recipes.

---

## 6. Explainable local ranking

### 6.1 Declarative recipe boundary

A `RavenLocalRankingRecipeV1` is a local configuration, not an endpoint object and not remote authority. A later implementation profile may define a bounded declarative DSL with:

- an allow-listed versioned operator set;
- an exact `operator_registry_digest` and deterministic interpreter-profile
  digest; the same recipe ID cannot silently acquire new operator semantics;
- total input/output and instruction budgets;
- no network, filesystem, clock, entropy, microphone, camera, contact-book, Keychain, or process access;
- no dynamic code download or native/JavaScript/Wasm execution in V1;
- deterministic behavior over an explicit snapshot;
- checked arithmetic and the protected local-PRF tie-break below;
- schema and language preferences that do not alter authenticity.

Recipe import displays requested signals and permissions before activation. Import never includes or requests private user data, never becomes a capability, and never executes remote code.

Equal-score ordering MUST NOT use bare `social_digest`, author-selected nonce,
timestamp, arrival order, relay count or source rank: authors could grind or
race those values. The default tie-break is a local PRF over
`(recipe_digest, snapshot_generation, social_digest)` under a protected
device-local attention-order key. It is deterministic on that device and opaque
to remote authors. Cross-device order may differ honestly; UI/export must not
claim a global canonical ranking. A user who explicitly chooses a portable
public tie-break accepts its grindability as a separately labeled mode.

Media provenance may be one bounded, inspectable local input, never a remote
rank command. A valid Content Credential does not make content true, safe,
consensual or worthy of reach; absent credentials mean `UNKNOWN`, not fake or
ineligible speech. Hardware capture or an approved claim generator MUST NOT be
a pay-to-speak gate. A user may choose to prioritize, warn on, or ignore exact
provenance outcomes, and “Why shown?” names that local rule without presenting
it as global truth.

### 6.2 Local decision record

For every feed inclusion, suppression, warning, or notification decision, the client can materialize a bounded local-only `RavenLocalAttentionDecisionV1`:

```text
decision_schema
local_account_scope_id_hash
subject_social_digest
lane
recipe_digest
operator_registry_digest
interpreter_profile_digest
verified_input_snapshot_digest
applied_label_digests[]
applied_curator_assertion_digests[]
local_policy_reason_codes[]
budget_class_and_charge
decision                 # include | warn | suppress | notify | no-notify
local_monotonic_event
```

This record answers “Why am I seeing this?” without claiming that the reason is globally true. It is encrypted at rest, never synced by Object Sync, never exposed to the author/source, and excluded from telemetry. A user-initiated diagnostic export redacts `local_account_scope_id_hash`, private graph edges, contacts, hidden topics, precise timing, and source network addresses by default.

Before a feed row or notification is released, the implementation either
persists this bounded decision record plus the exact retained input snapshot, or
proves deterministic recomputation from still-pinned inputs. A snapshot digest
without retained/reconstructable inputs is not an explanation. Opening “Why
shown?” performs no network request and cannot refresh labels, media, source
scores or policy behind the user's back.

### 6.3 Ranking precedence

```text
local block / legal safety policy
  > sticky device revocation and invalid authority
  > audience/schema eligibility
  > explicit local per-subject action (show | warn | suppress)
  > user-selected label actions
  > local ranking recipe
  > protected local-PRF tie-break
```

`pin` and `mute` are not two concurrently true flags; they compile to one exact
local per-subject action with explicit replacement history. Remotely supplied
labels cannot outrank that user action. A separately disclosed local legal or
device-owner safety rule may remain non-overridable, but it is not disguised as
a curator/labeler result.

Ranking never repairs invalid authority. A lower score is not a revoke. A valid object may be retained yet suppressed. A blocked object may retain minimum conflict/revocation evidence without entering a view.

---

## 7. Recommendation and curator provenance

### 7.1 Recommendation assertion

A later wire companion MAY freeze `RavenRecommendationAssertionV1`, an immutable signed social record binding at least:

```text
assertion_version
curator_repo_id
curator_device_lineage_and_grant_digest
subject_repo_id
subject_social_digest?          # exact object recommendation
subject_descriptor_digest?      # exact repository recommendation
relation_code                   # recommend | contextualize | oppose | topic-assert
bounded_reason_codes[]
policy_namespace
created_at_ms                   # advisory
expires_at_ms
supersedes_assertion_digest?
curator_signature
```

Exactly one subject form is present. Signatures authenticate the curator's assertion, not the subject's truth, quality, safety, or popularity. The subject bytes and authority are verified independently.

The assertion is already an immutable Social Graph record in one exact per-device writer slot. It therefore does not define a second global curator sequence or last-writer-wins register. If a later assertion supersedes or retracts another, it names the exact prior `social_digest`; concurrent assertions remain visible provenance rather than being selected by timestamp.

### 7.2 Curator subscriptions

Curators are followed explicitly and locally, like public repositories. A curator cannot:

- enumerate subscribers;
- receive reading/dwell/click receipts;
- cause automatic contact acceptance;
- inject remote ranking code;
- require all of the user's follows or blocks;
- hide disagreement or replace the user's local block;
- turn repeated assertions into quorum authority.

User-configured combinations such as “warn when any selected child-safety labeler flags” or “show when two of my three chosen curators recommend” are local recipes. The threshold is not network consensus and is never authenticity proof.

### 7.3 Discovery without a global query authority

Candidates may arrive through signed replies/reposts/quotes, followed curators, contact gossip, community indexes, local mesh, QR/file imports, or optional remote search. Remote search returns bounded untrusted digests/assertions only. It cannot observe the full local query history unless the user explicitly chooses that leakage mode, and it cannot return hydrated trusted views.

There is no normative `ListAllUsers`, `ListAllRepositories`, global `since`, follower lookup, trending, or personalized-feed endpoint.

---

## 8. Moderation labels and reports

### 8.1 Label authority

The Social Graph companion defines signed moderation labels. The later wire MUST additionally bind:

- exact labeler identity/device/writer grant;
- exact label policy namespace and policy-definition digest;
- exact subject form and version/digest;
- exact labeler per-device writer slot and optional exact `supersedes_label_digest`/`negates_label_digest`;
- issuance and maximum validity;
- replacement/negation semantics that do not rely on wall-clock ordering;
- optional evidence digest without embedding private report bytes.

Exact replay is idempotent. Equal unique per-device writer slot with different bytes is authenticated conflict. Labeler devices may publish concurrent branches; arrival time and advisory timestamps never create a labeler-global sequence. Omission is no-op, not negation. A later valid negation targets one exact prior label digest and changes only that label authority's current assertion under local policy; it cannot erase historical evidence, another labeler lineage, or the subject.

### 8.2 Label application

Label validity and label action are separate:

```text
verify label bytes and authority
  -> retain within bounded label quota
  -> match local labeler subscription + policy digest
  -> map value to local action (ignore | inform | warn | suppress)
```

No built-in label string grants special global power. A user may choose mandatory local safety defaults, but a downloaded labeler definition cannot make itself non-configurable.

### 8.3 Private reports

A report is not a public social record by default. If a future report profile is approved, it uses a separately sealed endpoint object to the selected labeler/community intake, with exact subject digest, bounded reason code, optional encrypted evidence, replay ID, retention request, and consent UX. The transport provides no delivery/read receipt to the reported author.

Anonymous reporting MAY use an approved scoped anonymous-rate credential, but the credential does not prove the report true or authorize a moderation outcome. Publicly publishing report contents requires a separate explicit social-record action.

---

## 9. Anti-spam hierarchy

Raven applies the least-authoritative mechanism that bounds harm:

1. strict parsing, object-digest replay rejection, and pre-allocation caps;
2. separate per-lane resource budgets;
3. contact/subscription/capability admission where already available;
4. per-source connection/request quotas and circuit breakers;
5. user-selected label/curator policy;
6. optional approved anonymous-rate credentials for specific public write/intake operations;
7. local refusal/block.

Content signatures alone never buy bandwidth. Conversely, failure to possess an optional rate credential cannot invalidate already authenticated content obtained through another permitted path.

### 9.1 No universal proof tax

Raven core does not require proof-of-work, stake, payment, blockchain membership, phone number, device attestation, government ID, or global proof of personhood. These mechanisms create exclusion, centralization, wealth/hardware bias, metadata, or availability dependencies that are incompatible with a universal serverless baseline.

Volunteer sources may have local admission policy. They must advertise it honestly and cannot relabel a local service rule as Raven authenticity.

---

## 10. Optional anonymous-rate profile

This section defines architecture constraints only. No credential wire is approved by V1.

### 10.1 Allowed use

An approved profile may authorize a bounded operation such as:

```text
submit one report to labeler X
submit one recommendation candidate to community Y
publish at most q small discovery assertions to source Z in epoch E
request one expensive public-search page
```

The redeemed proof binds the exact operation class, origin/source scope, credential-suite/config digest, coarse epoch, and replay/nullifier domain. It MUST NOT bind the user's Raven address, contact graph, repository follows, content subject, fine-grained topic, precise time, or stable cross-origin identifier unless that disclosure is explicitly part of a separately reviewed mode.

### 10.2 Trust and privacy limits

- Issuance and redemption are distinct roles when the privacy claim requires non-collusion.
- Issuer key/config consistency and rollback state are protected like other trust roots.
- Issuance metadata and issuer selection are minimized because both can partition anonymity sets.
- A token/credential is one-purpose and origin-scoped; cross-origin replay and scope widening fail.
- Double redemption/rate excess refuses only the scoped operation and does not become identity evidence.
- Issuance denial is not proof of abuse and cannot create a global ban.
- OHTTP may hide the client address from an origin only under explicit relay/gateway non-collusion, padding, timing, and fallback assumptions.
- A small anonymity set or co-operated issuer/attester/origin is labeled honestly.

### 10.3 Multiple issuers without fake consensus

A source may accept a bounded allow-list of independently operated issuer configurations selected by its policy. Raven MUST NOT require one universal issuer. Acceptance by multiple issuers is not a vote about content or identity; it merely provides alternative ways to satisfy that source's scoped rate rule.

Issuer popularity, token count, issuer metadata, or credential price cannot enter content rank by default.

### 10.4 Research profiles, not production dependencies

The following may inform later profiles but are not approved here:

- IETF Privacy Pass and Anonymous Rate-Limited Credentials;
- RLN-style rate nullifiers for anonymous publish lanes;
- privacy-preserving community membership credentials.

An RLN profile must not silently inherit a blockchain, stake, global membership contract, slashing, synchronized-clock, or public-network dependency. Any such dependency requires a new threat model, explicit product decision, and companion approval.

---

## 11. Carrier, mesh, and offline behavior

### 11.1 Carrier opacity

Opaque relays/mailboxes transport exact endpoint objects and enforce local byte/time quotas. They do not parse social subjects, ranking recipes, labels, curator relations, or attention lanes. A public repository source or report intake is an application endpoint above a carrier and cannot claim relay opacity for the same termination boundary.

Attention/rate/report semantics are never smuggled into
`carrier_control_bytes`. Carrier control remains limited to the umbrella's
link/session/custody functions. A future anonymous-rate exchange must use the
sealed Endpoint or an approved public-fetch/intake application profile, and the
carrier stays oblivious to its operation class and result.

Likewise, ICE/STUN/TURN/DTLS/SRTP/RTP/RTCP/SFrame packets are realtime-media
transport bytes, not attention or carrier-control records. Their arrival cannot
select a lane, ring a device, create notification authority, or bypass the
committed call-control and local-permission gates.

### 11.2 Mesh discovery

Local mesh may carry bounded public candidate assertions or exact already-eligible public objects under a separately approved carrier profile. It MUST NOT broadcast:

- the user's follow/labeler/curator lists;
- contact identities or private repo digests;
- local ranking decisions or notification policy;
- raw queries or hidden topics;
- anonymous credential secrets.

Unknown mesh content is `STRANGER_DISCOVERY`, not proximity trust. RSSI, repeated encounters, peer count, or local popularity cannot authenticate or automatically amplify it.

### 11.3 Offline convergence

Exact duplicate objects converge by digest. Signed conflicting assertions remain conflict evidence. Missing labelers, curators, issuers, or sources do not change content authenticity. The device may apply its last verified unexpired local policy within frozen staleness rules, or pause the dependent action. It never invents freshness.

---

## 12. Protected local state and crash ordering

Protected state includes:

- attention budget epochs/counters and outstanding reservations;
- recipe/policy digests and local overrides;
- labeler/curator subscriptions and greatest verified policy heads;
- credential issuer/config pins, redemption/nullifier replay state, and conflicts;
- local blocks and minimum anti-rollback evidence;
- explanation records subject to retention policy;
- source circuit-breaker and abuse state;
- notification cooldown state.

It excludes raw contacts, plaintext private objects, session roots, or long-term anonymous credential secrets from public diagnostic/export indexes.

Any state-mutating admission follows the endpoint durability discipline:

```text
reserve under mutation lease
  -> candidate verify/evaluate outside lease where safe
  -> protected journal with exact before/after binding
  -> SQL/local index commit
  -> protected head/anchor finalize
  -> clear journal
  -> release feed/notification/forwarding output
```

The final line represents separate domain intents, not one combined side effect:

- custody commits an exact retained-object/retention-class row;
- dissemination commits an exact destination/object outbox row and only its
  worker may touch a carrier;
- attention commits a local view decision/recipe snapshot;
- notification commits a stable local notification intent.

One domain may be absent or fail without fabricating success in another.
Network I/O, OS notification APIs and media fetches occur outside the mutation
lease. A feed row never creates a dissemination intent; a notification never
creates an ACK, read receipt, reaction, media fetch or source request.

Recovery rolls forward idempotently. It never refunds work by rollback, reuses a one-shot redemption, emits a notification twice, or releases output before commit. Corruption disables the affected lane/profile and preserves stronger-lane state.

The default [`RAVEN_USER_OWNED_ARCHIVE_V1.md`](RAVEN_USER_OWNED_ARCHIVE_V1.md) policy excludes dwell/read history, hidden interests, local attention weights, notification behavior, credential redemption secrets, and unredacted explanation records. A user may separately export a bounded redacted diagnostic explanation, but restoring it cannot alter ranking, lane selection, budgets, labels, subscriptions, or notifications. An archive import remains `LOCAL_IMPORT` until explicit local admission and has no network effect.

---

## 13. Failure semantics

| Event | Required result |
|---|---|
| Valid signature from unknown author | Authentic public candidate only; stranger lane; no contact/notification |
| Invalid signature/cert/grant/audience | Reject before trusted-view mutation |
| Sticky device revoke/local block | Deny per policy; label/rate evidence cannot clear |
| Same unique label/assertion slot, different bytes | Preserve bounded conflict evidence; quarantine that authority slot |
| Stranger quota full | Refuse/defer weak lane; never evict contact/protected safety state |
| Budget journal crash | Conservative reservation or committed charge; no free retry |
| Recipe invalid/oversize/unsupported | Refuse recipe; retain previous approved local policy |
| Operator registry/interpreter digest changes | New explicit recipe migration/re-evaluation; never silently reuse old decision meaning |
| Recipe evaluation over budget | Abort result; no partial feed/notification release |
| Author grinds digest/timestamp/arrival for equal score | Protected local-PRF tie-break prevents predictable global ordering advantage |
| Labeler unavailable | Apply frozen local staleness policy; no invented clean result |
| Curator omits prior recommendation | No deletion/revoke; locally retained evidence remains |
| Anonymous credential invalid/replayed | Refuse scoped operation only; no identity/global-ban claim |
| Issuer config rollback/conflict | Quarantine that issuer profile; preserve unrelated lanes |
| OHTTP unavailable | Fail private mode; no silent direct fallback |
| Source returns popular/trending score | Treat as advisory untrusted metadata or reject; never authenticity |
| Feed inclusion or “Why shown?” opened | No forwarding, media fetch, receipt, reaction, ACK or policy refresh side effect |
| Mesh peer floods repeated objects | Digest dedup + source/lane quotas; no trust from proximity |
| Notification commit then crash | Stable notification ID + journal prevent duplicate Raven enqueue; OS replacement/display semantics are platform-tested and described honestly, never generalized as universal exactly-once |
| Local state corrupt | Fail closed for affected automated lane; explicit repair, no silent reset |

---

## 14. Byte classes and future wire families

This architecture freezes no bytes. A later companion and umbrella revision must classify each exact family:

| Candidate family | Intended class |
|---|---|
| Signed recommendation assertion | Public authenticated `endpoint_object_bytes`, if registered |
| Signed moderation label/policy definition | Public authenticated `endpoint_object_bytes`, if registered |
| Private report | Plaintext inside a separately sealed endpoint object; never public by default |
| Rate challenge/redemption/status | Future application-protocol request/response bytes inside a sealed endpoint object or an explicitly approved public-fetch/intake profile; **never** `carrier_control_bytes` merely because they are control-like |
| Anonymous credential secret/state | Protected local state; never carrier or endpoint content |
| Local recipe/decision/budget | Local-only protected state; never Object Sync eligible |
| OHTTP/Noise/HTTP wrapper | Carrier/application transport wrapper; never digest root |

Every wire family needs a new magic/version, exact lengths, domain separation, canonical encoding, signature/MAC coverage, error mapping, replay identity, caps, and Python/Rust/Swift vectors. No existing V1 object is reinterpreted.

---

## 15. Required vectors and negative matrix

Before approval, shared fixtures must compute in Python, Rust, and Swift:

- lane classification for contact/followed/community/curator/stranger/import;
- no-escalation from label, recommendation, rate credential, repeated source, or proximity;
- independent custody/dissemination/attention/notification outcomes, including
  display-without-forward and forward-without-feed cases;
- exact recommendation and label authority/sequence/conflict/negation rules;
- recipe determinism, protected local-PRF tie-break, digest-grinding resistance,
  operator-registry/interpreter binding, cost caps, migration and malicious import;
- local explanation digest and redacted export;
- budget reservation/commit/recovery and cross-lane isolation;
- source/curator/labeler block, unfollow, re-follow, and account isolation;
- credential challenge/scope/epoch/config binding, replay/nullifier, key rollback, metadata limits, and origin separation for any proposed anonymous-rate suite;
- OHTTP direct-fallback refusal and role-collusion labeling;
- notification journal/stable-ID recovery, including platform-specific replacement/display behavior;
- “Why shown?” offline recomputation with no network/media/policy side effect;
- mesh candidate privacy and stranger-lane classification;
- protected-store corruption/rollback and explicit repair.

Negative fixtures must include truncated/oversize/non-canonical encodings, unknown critical fields, wrong domain/profile, cross-account/session/repo replay, all-zero/invalid keys, conflicting exact slots, remote-time manipulation, quota overflow, integer overflow, and fault injection at every journal boundary.

---

## 16. Simulations and physical gates

### 16.1 Deterministic simulations

At minimum:

| Simulation | Required evidence |
|---|---|
| 1,000-node Sybil flood | Stranger CPU/memory/dial/store remains bounded; contact/followed progress continues |
| Curator/labeler capture | One or many compromised authorities cannot forge subject bytes, clear block/revoke, or become mandatory |
| Source eclipse/withholding | Availability degrades honestly; greatest pins and retained heads never roll back |
| Anonymous-rate abuse | Valid quota enforced; invalid/replay bounded; issuer outage does not corrupt unrelated lanes |
| Metadata privacy | No full follow graph, ranking weights, read history, hidden topics, or contact list leaves device |
| Mesh partition/rejoin | Exact objects dedup; conflicts preserved; no proximity-based trust |
| Crash matrix | No free budget, duplicate notification, released-before-commit result, or replay-state loss |
| Recipe adversary | Bounded time/memory, deterministic result, no I/O or secret access; author digest/timestamp grinding does not win equal-score order |
| Plane-confusion attack | Custody, forwarding, feed and notification remain independent under retries, crashes and malicious remote scores |

Simulation is not proof of anonymity, global availability, human safety, or legal compliance.

### 16.2 Physical rows

Each enabled carrier/profile must pass on its real platforms:

- iPhone foreground/background/lock/relaunch under Data Protection;
- macOS/Linux/Windows protected-state durability and corruption;
- direct LAN, Internet direct, relay, mailbox, and mesh where claimed;
- airplane-mode/offline import and partition/rejoin;
- OHTTP or anonymous-rate deployment with the actual independent roles and keys claimed;
- user-visible “Why shown?”, privacy-mode, block, quota, and no-notification behavior;
- packet/log/disk inspection proving absence of private graph/ranking/attention secrets.

Passing a simulator or in-process test cannot substitute for a required physical row.

---

## 17. Production holds

Production/Release enablement is forbidden until all of:

1. this architecture is independently reviewed and **APPROVED**;
2. umbrella byte-class amendments and the exact wire companion are APPROVED;
3. Social Graph, Public Repository Sync, ID Resolution, Device Revocation, Object Sync/Carrier Conformance dependencies are APPROVED for each used path;
4. every implemented language computes the same vectors and negatives;
5. protected durability and crash/recovery pass on Apple/Linux/Windows;
6. attention lanes and quotas prove that stranger floods cannot starve contacts/followed repos/safety evidence;
7. local ranking/decision exports prove no network/secret/private-graph access;
8. labeler/curator conflict, compromise, staleness, and replacement matrices pass;
9. any anonymous-rate suite pins an exact reviewed standard/draft revision, crypto suite, issuer/config consistency profile, deployment roles, metadata limit, and fallback UX;
10. privacy claims match real issuer/attester/origin and OHTTP relay/gateway operations;
11. 1,000-node simulations and required physical carrier rows pass;
12. no live callsite, notification path, public source, report intake, or credential issuer exists outside an explicit production gate;
13. external security/privacy review or a protocol-owner waiver with documented residual risks is recorded.

Approval of this document alone does not enable production.

---

## 18. Open decisions

1. Exact declarative ranking operator set and cost model.
2. Exact recommendation/label/policy wire families and sequence scopes.
3. Whether anonymous reporting is needed in V1 product UX.
4. Whether an IETF ARC profile is mature enough after its exact revision receives cryptographic/privacy review.
5. Whether any RLN-like community lane can meet Raven's no-blockchain/no-global-issuer baseline without inventing a new high-risk primitive.
6. Label-policy migration, expiry, conflict repair, and historical evidence retention.
7. Coarse attention-budget defaults that remain usable for low-resource devices and accessibility needs.
8. Notification policy and emergency/contact overrides without remote escalation.
9. Safe export/import format for recipes and explanations.
10. Jurisdictional policy for volunteer public sources/report intakes without turning policy into authenticity.

---

## 19. Research foundations (informative only)

Raven claims no wire compatibility with these systems:

- [AT Protocol Labels](https://atproto.com/specs/label) — independently signed annotations and composable moderation; Raven additionally requires domain separation, local-only action, sequence-bound replacement, and no mandatory hydrator.
- [AT Protocol moderation](https://atproto.com/guides/moderation) and [official custom-feed architecture](https://docs.bsky.app/docs/starter-templates/custom-feeds) — separation of speech/reach and user-selectable algorithms; the latter is explicitly a network service that receives a request and returns post URIs, whereas Raven keeps ranking inputs/execution local by default rather than disclosing a user's interest context to a feed service.
- [RFC 9576 — Privacy Pass Architecture](https://www.rfc-editor.org/rfc/rfc9576.html) — privacy-preserving authorization roles plus explicit issuer/metadata/anonymity-set centralization risks.
- [IETF Anonymous Rate-Limited Credentials](https://datatracker.ietf.org/doc/draft-ietf-privacypass-arc-crypto/) — promising work-in-progress for scoped rate limits; not a frozen production dependency.
- [Waku RLN network profile](https://rfc.vac.dev/waku/standards/core/64/network/) — rate-nullifier spam control and its deployment assumptions; Raven does not inherit its chain membership, public-network, clock, or routing choices.
- [RFC 9458 — Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458.html) — optional relay/gateway request separation with explicit collusion and traffic-analysis limits.
- [Willow Confidential Sync](https://willowprotocol.org/specs/confidential-sync/index.html) — private interest overlap and resource negotiation; not a substitute for Raven's local attention decision.

---

## 20. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial research architecture: five-plane separation; six local attention lanes; protected multi-dimensional budgets; deterministic explainable ranking; signed recommendation/curator provenance; label/report hardening; least-authoritative anti-spam hierarchy; optional non-authoritative anonymous-rate profile; mesh/offline privacy; byte classes; vectors, simulations, physical gates, and production holds |
| 2 | 2026-08-21 | Adversarial hardening: reserve-before-crypto processing; inert previews; per-device label/curator concurrency without fake global sequence; exact assertion supersession; platform-honest notification recovery instead of universal exactly-once claims |
| 3 | 2026-08-21 | User-owned archive privacy boundary: behavioral attention state and credential secrets are excluded by default; redacted diagnostic exports carry no restore authority; archive imports remain inert local candidates |
| 4 | 2026-08-21 | Sovereign-community integration: the community lane now requires exact governance/membership evidence and remains subject to local attention override; carriers cannot assign community authority |
| 5 | 2026-08-21 | Seven-plane hardening: split custody and dissemination from resource/ranking/notification; forbade application rate semantics in carrier control; bound recipes to operator/interpreter digests; replaced grindable public tie-breaks with a protected local PRF; made explanations offline/reproducible and each output domain independently durable. Production remains disabled. |
| 6 | 2026-08-21 | Research reconciliation: replaced the generic feed-code reference with the official network feed-generator architecture and made the privacy distinction explicit—Raven ranking remains local by default and does not disclose interest context merely to obtain ordering. No normative wire or production state changed. |
| 7 | 2026-08-21 | Private-discovery boundary: declared that APPROVED local Attention is a prerequisite for bounded unknown-candidate discovery; discovery may consume a committed local decision but cannot become a reverse dependency or remote ranking authority. |
| 8 | 2026-08-21 | Private-introduction lane: added a separate quiet, inert, recipient-bound stranger-request class; signatures/provider delivery cannot grant contact, PairInit, reply, media-fetch or notification authority, and only an explicit local Accept can schedule contact commit. |
| 9 | 2026-08-21 | Private-realtime boundary: only a direct contact or authorized community may create a local call candidate; Attention alone controls ringing/quiet display, while transport packets, provider success and remote urgency can never authorize ICE release, capture, wake or notification. |
| 10 | 2026-08-21 | Sovereign-media boundary: provenance can be a bounded transparent local input but never remote ranking authority; valid credentials are not truth/consent, missing credentials are not fake, and hardware or claim-generator participation cannot become a mandatory speech or reach gate. |
