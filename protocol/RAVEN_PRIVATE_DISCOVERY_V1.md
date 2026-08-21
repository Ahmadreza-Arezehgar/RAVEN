# RAVEN Private Discovery V1

**Version:** 1 (architecture/privacy draft; wire not frozen)
**Document revision:** 2
**Date:** 2026-08-21
**Status:** **REQUIRED / NOT YET APPROVED**
**Production:** **disabled** — this document authorizes no public-search
service, discovery shard, topic index, OHTTP gateway, PIR deployment, mesh
broadcast, recommendation engine, codec, database migration, live callsite, or
Release flag

**Approval prerequisites:**
[`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md)
revision registering every public discovery endpoint-record family;
[`RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md`](RAVEN_SOCIAL_REPOSITORY_AUTHORITY_V1.md),
[`RAVEN_SOCIAL_OBJECT_WIRE_V1.md`](RAVEN_SOCIAL_OBJECT_WIRE_V1.md),
[`RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md`](RAVEN_PUBLIC_REPOSITORY_SYNC_V1.md), and
[`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md) **APPROVED**;
[`RAVEN_ID_RESOLUTION_V1.md`](RAVEN_ID_RESOLUTION_V1.md) **APPROVED** for
identity lookup; Carrier Conformance for every enabled path

**Non-interference:** this draft does not amend Full Braid, protected-anchor or
SQLCipher work; it does not authorize stranger Object Sync, contact discovery,
remote ranking, or any current production path.

---

## 0. Normative language and core decision

The key words MUST, MUST NOT, SHOULD, and MAY are interpreted as in BCP 14 when
capitalized.

Raven discovery is a **local query planner over independently verifiable public
candidates**, not a global database and not a trust service:

```text
private local intent
  -> choose one explicitly labeled privacy mode
  -> obtain bounded untrusted candidate assertions/digests
  -> verify exact owner/repository/object authority locally
  -> apply local Attention admission and ranking
  -> optional explicit local follow/contact action
```

No source, gateway, relay, shard publisher, curator, peer count, result order,
or search score becomes identity, repository, content, contact, or ranking
authority.

### 0.1 Four different questions

| Question | Owning companion | Discovery MUST NOT replace it |
|---|---|---|
| “What full identity does this exact handle/code name?” | ID Resolution | Handles remain location hints; full canonical identity evidence authenticates |
| “How do I fetch updates for this already chosen public repository?” | Public Repository Sync | Known-repo pull, frontier durability and object verification remain there |
| “Which unknown public candidates might match my present local interest?” | **This companion** | Output remains bounded untrusted candidate evidence |
| “Where might this exact accepted contact/device be reachable now?” | Private Rendezvous | Pairwise path capabilities, route descriptors and presence evidence remain there |

Phone/address-book matching, “people you may know”, background contact upload,
and private buddy-list discovery are not content discovery. Known-contact path
lookup is defined by
[`RAVEN_PRIVATE_RENDEZVOUS_V1.md`](RAVEN_PRIVATE_RENDEZVOUS_V1.md); private
first-contact/presence beyond that profile requires a separately reviewed
construction. All are forbidden here.

---

## 1. Goals, non-goals, and adversaries

### 1.1 Goals

| ID | Goal |
|---|---|
| D1 | Search already retained verified content entirely on-device |
| D2 | Discover public repositories/objects without one Raven-operated index or mandatory global firehose |
| D3 | Avoid uploading the user's contact graph, follow graph, local inventory, ranking recipe, behavior history, or stable Raven identity |
| D4 | Offer privacy modes whose actual leakage is explicit and independently testable |
| D5 | Make discovery-source replacement possible without changing candidate authenticity |
| D6 | Support offline drops, LAN/mesh bulk shards, volunteer mirrors, direct sources, and optional OHTTP without silent downgrade |
| D7 | Keep remote result order/score outside local rank and attention authority |
| D8 | Bound parsing, storage, query work, response amplification and unknown-author admission before allocation |
| D9 | Leave a rigorously defined future gate for keyword PIR without claiming that ordinary encrypted search is PIR |

### 1.2 Non-goals

- Hiding all timing, size, network path, coarse shard, language, or availability
  metadata in every mode.
- Proving that any source returned complete, neutral, fresh, diverse, or
  non-censored results.
- A global trending list, follower count, engagement score, reputation score,
  canonical taxonomy, or universal search rank.
- Server-side personalization, contact upload, cross-service behavior profiles,
  remote embeddings, or mandatory analytics.
- Treating a source TLS key, DHT provider, search score, mirror count, or signed
  discovery assertion as content authority.
- Inventing custom PIR, PSI, OHTTP, anonymous-credential, or metadata-private
  messaging cryptography.
- Production activation or a wire freeze in this revision.

### 1.3 Adversaries

| Adversary | Capabilities |
|---|---|
| Malicious discovery source | Omit, reorder, bias, duplicate, flood, fingerprint queries, lie about scores/completeness, return attacker candidates |
| Relay/gateway pair | Separately observe client network metadata or plaintext query; collude; inject timing/size identifiers |
| Malicious shard publisher | Misclassify topics, equivocate, overfill buckets, grind names/digests, advertise unavailable objects |
| Network observer | Correlate timing, size, destination, retries, mobility and cover schedule |
| Sybil publisher/requester | Fill weak discovery lanes or exhaust volunteer source work |
| Malicious public author | Sign authentic but abusive/misleading content and self-assert arbitrary topics |
| Compromised device/source cache | Replay stale descriptors/assertions and attempt rollback/eclipsing |
| Curious peer/contact | Infer hidden interests from raw query, selective inventory or fine-grained shard fetch |

### 1.4 Honest limit

Discovery can prove candidate provenance and exact bytes; it cannot prove
completeness, impartiality, “the best result”, truth, popularity, or absence.
OHTTP partitions IP address from plaintext query only under its exact
relay/gateway and traffic-analysis assumptions. PIR protects a query only under
the frozen scheme/database/threat model; it does not automatically hide timing,
response size, client software, subsequent object fetches, or local compromise.

---

## 2. Local-first discovery model

### 2.1 Local intent is not a network object

A local `RavenDiscoveryIntentV1` is private ephemeral state containing only the
user-selected query form and local execution preferences. It is:

- not `endpoint_object_bytes`, `carrier_record_bytes`, or
  `carrier_control_bytes`;
- never signed/published merely because a query runs;
- never Object Sync eligible;
- excluded from telemetry, default archive, diagnostics, crash reports and
  recommendation assertions;
- retained only if the user explicitly saves a local search/subscription.

Free text, selected topic, language, local filters, hidden words, excluded
authors, current viewport and query embeddings remain local in the default
mode.

### 2.2 Local index

The primary search engine indexes only already admitted local objects and exact
retained public shard evidence. It MAY provide lexical, structural or local
semantic search under these rules:

- content authorization was completed before indexing;
- index corruption can only disable/rebuild the view, never reset authority;
- a local model/operator has an exact version/digest and finite resource cap;
- no downloaded model, native code, JavaScript or Wasm executes implicitly;
- embeddings and queries remain encrypted at rest and local-only;
- search output enters the Attention Firewall; index score is not
  authenticity, follow, contact, or notification authority.

Local-only search sends **zero query bytes** and is the default privacy mode.
Its unavoidable limit is corpus coverage.

### 2.3 Candidate, not result truth

A discovery response contains bounded candidate references and provenance
evidence. Before display beyond an inert preview, Raven separately verifies:

```text
strict candidate/assertion syntax
  -> discovery issuer/device/writer evidence (if signed)
  -> exact subject repository/descriptor/object authority
  -> current local block/revocation/schema policy
  -> Attention resource + stranger/discovery lane admission
  -> local ranking/explanation
```

A valid discovery signature proves only “this publisher asserted this
candidate under this policy”. It does not prove the subject true, safe, popular,
available or worthy of attention.

---

## 3. Privacy modes

Every network-capable discovery action selects exactly one mode. UI, logs and
tests report that mode; failure never silently falls through to a more revealing
mode.

### 3.1 Mode L0 — local-only

Search the on-device admitted corpus and cached public shard pages. No network
request, wake-up, DNS lookup, media fetch, source refresh or label hydration is
allowed during query evaluation.

**Source learns:** nothing from this query.
**Limit:** only retained corpus is searchable.

### 3.2 Mode L1 — scheduled bulk shard pull

The device fetches bounded, immutable, content-addressed public discovery shard
pages. Fetch is scheduled by a coarse user-approved subscription or cover
schedule, not by every keystroke/result click. The same fetched page can satisfy
many future local queries.

The source may learn the coarse shard/bucket, client network metadata in direct
mode, timing and size. Padding and fetch cadence may reduce—but never erase—this
leakage. A rare topic, unique bucket combination or sparse language partition
can still identify interest.

### 3.3 Mode L2 — OHTTP query

An exact future profile MAY carry a padded query through RFC 9458 OHTTP:

- relay sees client network metadata and encrypted gateway payload;
- gateway/source sees plaintext query and response, but not client network
  address under non-collusion;
- both can observe timing/size and may collude;
- gateway key configuration is authenticated, anti-rollback pinned and not a
  tracking partition;
- retries are application-idempotent and follow OHTTP replay rules;
- cookies, Raven ID, stable per-client headers, contact/follow state and unique
  client fingerprints are absent.

If OHTTP is unavailable or configuration is stale, L2 refuses or asks the user
to choose another mode. It does not auto-fallback to direct.

### 3.4 Mode L3 — explicit direct query

The selected source sees the plaintext query, client network metadata, timing
and response linkage. This can be useful for self-hosted sources or deliberate
low-latency use, but UI labels it **source-visible search** before first use and
offers a per-source reset/delete action for local credentials.

The request still omits Raven identity, contacts, follow graph, local inventory,
behavior history and ranking recipe unless an independently reviewed operation
requires one exact disclosed field and the user consents.

### 3.5 Mode L4 — future keyword PIR

Keyword/index PIR is a **separate future profile**, not an implementation trick
inside L1/L2. Approval requires:

- exact database construction, keyword-to-index mapping and snapshot digest;
- exact single-server computational or multi-server anytrust assumption;
- query/response codec, parameter set, padding, batch and failure semantics;
- malicious-server correctness/equivocation checks;
- database update, rollback, omission and stale-snapshot behavior;
- CPU/memory/bandwidth ceilings on phone and source;
- query unlinkability and subsequent-fetch leakage analysis;
- independent cryptographic review and three-language vectors where applicable.

No Raven-authored ad-hoc PIR/PSI primitive is permitted. “Encrypted query” or
“hashed keyword” MUST NOT be marketed as PIR: small keyword spaces are
enumerable and access patterns remain visible.

### 3.6 Leakage matrix

| Mode | Source sees query | Source sees client IP | Relay sees query | Coarse interest leak | Coverage |
|---|---|---|---|---|---|
| L0 local | No source | No | N/A | Local device only | Retained corpus |
| L1 direct shard | Bucket/page | Yes | N/A | Yes | Shard publishers |
| L1 OHTTP shard | Gateway sees bucket/page | Gateway: no; relay: yes | No | Yes | Shard publishers |
| L2 OHTTP query | Gateway: yes | Gateway: no; relay: yes | No | Full query at gateway | Query source |
| L3 direct | Yes | Yes | N/A | Full | Query source |
| L4 PIR | Scheme-dependent server leakage | Transport-dependent | Scheme-dependent | Must be proven | Frozen PIR DB |

These are protocol-role claims, not guarantees against collusion, browser/device
fingerprinting, traffic analysis or a compromised Endpoint.

---

## 4. Public discovery evidence

This section freezes semantic roles only. All byte layouts, magics and endpoint
registrations remain open.

### 4.1 Candidate assertion

A future signed `RavenDiscoveryAssertionV1` may bind:

```text
assertion_profile
publisher_repo_id
publisher_device_lineage_and_writer_grant
assertion_sequence + exact predecessor/supersedes digest
subject_kind                   # repository | exact social object | curator list
subject_repo_id
subject_descriptor_digest
subject_social_digest?        # exactly one subject form
public taxonomy digest + bounded topic path(s)
bounded language/schema/content-kind hints
policy/evidence digest
validity ceiling
publisher signature
```

Assertions are author/curator claims, not subject endorsements, truth labels,
global tags or rank. Self-assertion and third-party assertion remain visibly
different. Omission is not negation; retraction names exact prior evidence.
Concurrent valid branches remain provenance and are not resolved by timestamp,
arrival, digest or source count.

### 4.2 Public discovery shard

A future `RavenDiscoveryShardV1` is an immutable, bounded, deterministic
container over exact assertion digests/bytes for one public taxonomy version,
coarse bucket and shard epoch. It binds at least:

- exact taxonomy/policy/profile digest;
- publisher identity/repository/device authority;
- bucket identifier and coarse epoch;
- sorted unique assertion digests;
- page/Merkle root, entry count and exact byte/work ceilings;
- previous shard/manifest evidence where continuity is claimed;
- signature.

Only artifacts already classified for **public** discovery may appear. Contact,
circle, private, local-draft, block/mute, follow/subscription, behavior,
notification, credential and private-capability identifiers are forbidden even
if encrypted or hashed; a small/private namespace remains enumerable and its
presence itself leaks membership or interest.

Shards are availability accelerators. A missing entry proves nothing; two
publishers need not agree; shard count is not popularity; a source cannot make
one shard canonical. Exact assertions/subjects are independently verified.

### 4.3 Taxonomy honesty

V1 has no universal Raven ontology. A taxonomy is a signed/versioned public
policy chosen locally by the user, community or curator. Topic strings are
public and enumerable. Hashing them does not make them secret.

Aliases, translations and hierarchy mappings are assertions with provenance.
They do not merge identities, rewrite subjects or become search truth. Local
free-text/semantic search may ignore every remote taxonomy.

### 4.4 No global popularity primitive

Discovery artifacts MUST NOT carry or authorize a Raven-global follower,
view, click, dwell, repost, mirror, search, download or engagement count. A
source may publish a signed statement about its own bounded observation, but
local policy treats it as one assertion and never as authenticity or mandatory
rank.

---

## 5. Source and carrier boundaries

### 5.1 Application endpoint, not opaque carrier

Search requests, shard requests, result pages, errors and optional rate
credential exchanges are **discovery application-protocol bytes** at a
source/gateway Endpoint above an opaque carrier. They are not
`carrier_control_bytes` merely because they control a query.

Carriers may process only their approved link/session/custody fields. They do
not parse topic, query, result, rank, follow, label, attention or credential
semantics.

### 5.2 Mesh and offline

Mesh may advertise or carry bounded public shard/manifest candidates under a
separately approved carrier profile. It MUST NOT broadcast raw queries, hidden
topics, contacts, follow lists, local inventory, rankings, notification policy,
credential secrets or private repo digests.

Offline QR/file/drop imports are inert containers. Strict extraction and
per-artifact verification occur before local candidate admission. Opening an
import does not follow, contact, fetch media, notify, forward or publish.

### 5.3 Multi-source union

Exact duplicate evidence converges. Distinct valid assertions/shards are unioned
within caps. Source count, latency and availability may schedule fetches but
cannot decide content authority, fork winner, local rank or contact status.

An eclipsed client may receive a biased subset. Raven reports source diversity
and unknown completeness; it does not claim consensus because several sources
agree.

---

## 6. Query execution and result admission

### 6.1 Local planner

The planner receives explicit inputs only:

```text
local intent + selected mode + source/profile pins + local budgets
  -> local index query
  -> optionally choose bounded shard/query operation
  -> reserve exact worst-case bytes/work/dials
  -> execute outside mutation lease
  -> strict response parse and supplied-digest comparison
  -> candidate evidence store
  -> authority verification
  -> Attention decision
```

No ambient clock, RNG, contacts, behavior telemetry or remote configuration may
silently change the selected privacy mode. Clock/entropy inputs needed by an
exact future wire are explicit and tested.

### 6.2 Remote order is discarded

A source may return an order or score as source-attributed evidence. The default
client discards it before feed placement. Local ordering follows the Attention
Firewall's pinned recipe/interpreter and protected local-PRF tie-break.

A user may explicitly subscribe to one curator's ordering policy, but the exact
policy and curator provenance become local recipe inputs. The curator still
does not see clicks/dwell or gain authenticity/contact authority.

### 6.3 Inert preview boundary

Before full subject authority/admission, UI may show only a bounded inert
candidate preview derived from verified assertion fields. It cannot render
remote HTML/Markdown, resolve URLs, load media, execute code, send receipts,
increment remote counters or create notifications.

Selecting a candidate starts a separate Public Repository Sync or exact-public-
object fetch transaction under its own privacy/budget policy.

### 6.4 Explicit social mutations

Discovery never automatically:

- follows a repository or creates a messaging contact;
- initiates PairInit or grants private Object Sync eligibility;
- joins a community or invokes a capability;
- downloads media or opens external URLs;
- forwards/reposts/reacts/replies/reports;
- marks Delivered/Read/View;
- notifies the author or discovery publisher.

Every such action is a separate user-visible transaction with its own authority
and durability boundary.

---

## 7. Resource and abuse model

### 7.1 Reserve before work

The effective request profile freezes finite ceilings for query bytes, response
bytes, candidates, pages, shard entries, proof bytes, CPU, memory, concurrent
requests, retries and retained evidence. The client/source reserves checked
worst-case units before allocation, decompression, signature work, PIR work,
model inference or dialing.

Unknown/stranger work has a separate weaker lane and cannot evict contact,
session, revocation, authority-conflict or user-pinned work.

### 7.2 No universal proof tax

Raven requires no proof-of-work, stake, payment, blockchain, phone number,
government ID, device attestation or global proof of personhood for core local
discovery. Sources may apply transparent local quotas; those rules never become
Raven authenticity.

An optional future Privacy Pass/ARC profile may authorize one bounded query or
shard operation. It cannot identify a user, create a global ban, rank content,
prove a result true or become mandatory for access to locally retained data.

### 7.3 Amplification and errors

Responses are bounded by request-independent profile ceilings and, where
applicable, an authenticated request budget. Unknown/malformed requests fail
before expensive work. Error forms are coarse and padded where the selected
privacy mode requires it; they do not reveal whether a hidden object is blocked,
absent, expired, rate-limited or withheld.

---

## 8. Protected local state and crash ordering

Protected/encrypted local state may include:

- saved local discovery subscriptions and selected privacy mode;
- source/OHTTP/PIR configuration pins and anti-rollback generations;
- shard manifests/pages and exact provenance;
- query-budget reservations and abuse/circuit-breaker state;
- local index/model/operator versions;
- optional local query history when explicitly enabled.

Raw query history, hidden/excluded terms, embeddings, result clicks and inferred
interests are excluded from default archive/telemetry/diagnostic export.

Distinct durable intents remain separate:

```text
source/shard fetch intent
candidate-evidence custody intent
subject exact-fetch intent
Attention view decision
explicit follow/contact/user-action intent
```

No intent fabricates another. Network I/O occurs outside the mutation lease.
Recovery is roll-forward/idempotent; it does not reissue a query under a more
revealing mode, duplicate an explicit social action, or release uncommitted
candidate/view output.

Corrupt source/profile pins disable that network mode fail-closed while L0 local
search remains available over independently verified retained data.

---

## 9. Failure and downgrade matrix

| Event | Required outcome |
|---|---|
| Unknown/truncated/trailing/oversized discovery bytes | Reject before trusted mutation and bounded expensive work |
| Supplied digest mismatch | Reject; supplied digest is comparison only |
| Same assertion/shard slot, different authenticated bytes | Retain bounded conflict evidence; no arrival/time/digest winner |
| Source omits a retained valid branch | Keep local evidence; report unknown completeness |
| Many sources repeat one claim | One claim, not popularity or quorum |
| Remote score/order present | Preserve only as attributed optional evidence; default local rank ignores it |
| OHTTP config stale/corrupt/unavailable | Refuse L2; no silent direct fallback |
| Relay/gateway collusion or tiny anonymity set | Privacy claim downgraded honestly; content authority unchanged |
| PIR snapshot mismatch/rollback | Refuse result; no fallback marketed as PIR |
| Hashed/encrypted keyword without proven PIR | Label as source-visible/guessable, never private search |
| Query/shard quota exhausted | Refuse/defer that lane; do not evict stronger state |
| Valid unknown-author candidate | Authentic assertion candidate only; no feed/follow/contact/notification |
| Candidate selected | Separate exact fetch; no implicit media/external URL |
| Local index corrupt | Disable/rebuild view from admitted objects; preserve authority pins |
| Crash after network response before commit | Retry/reconcile exact intent; no view or social mutation claim |
| User clears query history | Remove scoped local history/derived index according to policy; no remote-erasure claim |

---

## 10. Required vectors, simulations, and physical gates

### 10.1 Three-language architecture vectors

Before a wire freeze, Python/Rust/Swift compute—not merely parse expected
JSON—for:

- candidate/assertion/shard canonical bytes, signatures, digests and conflicts;
- taxonomy/bucket/page deterministic construction and caps;
- local intent/mode plan with no-silent-downgrade outcomes;
- source-order discard and local Attention re-ranking;
- OHTTP configuration/padding/replay bindings if L2 is proposed;
- PIR database/query/result transcript only after a chosen reviewed scheme;
- reserve/charge/release, exact replay and crash-recovery state machines;
- malformed, oversized, cross-mode, cross-source, rollback and substitution
  negatives.

### 10.2 Deterministic 1,000-node simulation

The model includes honest/biased/malicious shard publishers, source churn,
partitions/healing, Sybils, sparse topics/languages, OHTTP role collusion,
eclipse, withheld branches, conflicting assertions, link failure, budget
exhaustion and user mobility.

Report separately:

- safety violations (unauthorized view/contact/follow, privacy-mode downgrade,
  rank/source authority confusion, resource cap breach);
- availability/coverage/latency;
- privacy metadata by role/mode;
- source diversity and unknown completeness;
- battery/data/CPU cost on low-resource clients.

No aggregate “pass rate” may hide one safety violation.

### 10.3 Physical matrix

Rows include iPhone and Terminal on Apple/Linux/Windows for:

- L0 airplane-mode local search with zero sockets/DNS;
- L1 shard import/pull and local re-query without network;
- direct versus OHTTP capture proving the documented role visibility;
- kill/relaunch at each fetch/candidate/view boundary;
- no automatic direct fallback after OHTTP failure;
- malicious source order, media URL and oversized response;
- block/revoke/contact/follow non-escalation;
- LAN/mesh/offline path changes without raw query broadcast;
- metered/low-power caps and accessibility behavior.

Automated localhost tests do not replace cross-device/network captures.

---

## 11. UX contract

Every discovery surface displays the active mode and an honest short privacy
label:

| Label | Meaning |
|---|---|
| **On this device** | No network action for this query |
| **Bulk public index** | A coarse shard/page may reveal topic interest and path metadata |
| **Oblivious relay** | Gateway sees query; relay sees network identity; collusion/timing remain |
| **Source-visible** | Selected source sees query and network metadata |
| **Private retrieval (experimental)** | Only after exact PIR profile; show server/anytrust and snapshot assumptions |

UI distinguishes **asserted candidate**, **verified repository/object**,
**followed locally**, and **messaging contact**. It never presents “top”,
“trending”, “popular”, “trusted”, “complete” or “private” without the exact local
policy/evidence and mode explanation.

“Why this result?” is computed from retained local provenance and Attention
inputs without network access.

---

## 12. Production holds

No discovery network path may be enabled until all of:

1. this companion and every semantic prerequisite are **APPROVED**;
2. the umbrella registers exact public discovery endpoint artifacts;
3. candidate/assertion/shard and enabled request/response bytes have strict
   Python/Rust/Swift vectors and negatives;
4. authority verification and `RVRA_AUTHORITY_ADMITTED`/
   `RVSR1_ADMISSION_AUTHORIZED` gates are integrated without collapse;
5. Attention Firewall resource/admission/ranking/notification gates are durable;
6. each enabled L1/L2/L3/L4 mode has a separate Carrier Conformance and privacy
   review, no-silent-fallback negative and physical evidence;
7. OHTTP uses an exact RFC 9458 suite/config/key-consistency/padding/replay and
   role-independence profile;
8. any PIR mode pins a reviewed scheme/implementation/parameters/database
   snapshot and passes phone/source performance plus malicious-server tests;
9. local query/behavior/graph data is absent from endpoint/carrier/telemetry/
   archive paths by default;
10. no remote result order, score, count, shard publisher or source becomes
    authenticity/ranking/contact authority;
11. crash/corruption/rollback tests pass on Apple/Linux/Windows protected state;
12. 1,000-node safety, privacy and resource matrices pass;
13. physical rows pass for every claimed device/carrier/privacy mode;
14. independent security/privacy review has no open P0/P1 and protocol-owner
    approval is recorded;
15. no lab/test flag compiles into an enabled Release path.

Passing one search demo, deploying one gateway or hiding an IP address is not
approval.

---

## 13. Open decisions before vector freeze

1. Exact candidate assertion and discovery-shard artifact families and whether
   each belongs in Social Object Wire or a separate allowed-record companion.
2. Public taxonomy/profile representation, shard construction and page proofs.
3. Fixed padding buckets and cover-fetch schedule that remain usable on mobile.
4. OHTTP key discovery/consistency, relay/gateway selection and failure UX.
5. Whether any keyword-PIR construction is mature and performant enough for a
   separate lab slice; V1 does not require PIR.
6. Local lexical/semantic index formats, model/operator pins and accessibility.
7. Discovery source metadata and SSRF/private-network/onion policy.
8. Curator/recommendation assertion wire, retraction and conflict behavior.
9. Exact relation between saved local discovery subscription and public repo
   follow without leaking interest.
10. Retention/GC of public shards, provenance, query history and conflicts.

---

## 14. Research foundations (informative only)

Raven claims no wire compatibility with these systems:

- [RFC 9614 — Partitioning as an Architecture for Privacy](https://www.rfc-editor.org/rfc/rfc9614.html)
  — separates “who” from “what” while warning that identifiers, collusion and
  side channels can undo the partition.
- [RFC 9458 — Oblivious HTTP](https://www.rfc-editor.org/rfc/rfc9458.html) —
  relay/gateway request partitioning with explicit replay, padding, differential
  treatment and traffic-analysis limits.
- [RFC 9230 — Oblivious DNS over HTTPS](https://www.rfc-editor.org/rfc/rfc9230.html)
  — a narrower example of query/network-identity separation.
- [Private Information Retrieval by Keywords](https://eprint.iacr.org/1998/003)
  — keyword-to-address mapping is a separate problem from index PIR; Raven does
  not call hashed-keyword lookup private.
- [Talek: Private Group Messaging with Hidden Access Patterns](https://arxiv.org/abs/2001.08250)
  and [Pung](https://www.usenix.org/conference/osdi16/technical-sessions/presentation/angel)
  — strong access-pattern privacy requires explicit PIR/anytrust/cover and
  availability assumptions, not ordinary encrypted retrieval.
- [DP5: A Private Presence Service](https://discovery.ucl.ac.uk/id/eprint/1469539/)
  and [Alpenhorn](https://www.usenix.org/conference/osdi16/technical-sessions/presentation/lazar)
  — buddy-list and connection-establishment metadata deserve separate protocols;
  they do not justify contact upload in content discovery.
- [Bluesky custom feeds](https://docs.bsky.app/docs/starter-templates/custom-feeds)
  — user-selectable network feed services are valuable but reveal requests to a
  service; Raven defaults to local ranking over candidate bytes.

---

## 15. Revision history

| Revision | Date | Change |
|---|---|---|
| 1 | 2026-08-21 | Initial private/decentralized discovery architecture: separated known-ID resolution, known-repository sync and unknown-content discovery; local-first index plus explicitly labeled bulk-shard/OHTTP/direct/future-PIR modes; candidate-only authority; public shard semantics; no global popularity/firehose/contact upload; carrier/application boundary; local rank; resource/crash/failure/vector/simulation/physical gates; all production paths disabled. |
| 2 | 2026-08-21 | Private-rendezvous separation: added the fourth distinct question for locating an exact accepted contact/device; content discovery cannot perform pairwise route lookup, buddy presence, public rendezvous fallback, or first-contact initiation. |
