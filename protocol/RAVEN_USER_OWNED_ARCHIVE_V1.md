# RAVEN User-Owned Archive V1

**Version:** 1

**Document revision:** 2

**Date:** 2026-08-21

**Status:** **REQUIRED / NOT YET APPROVED**

**Production:** **disabled** — this document authorizes no archive codec, key export, backup upload, storage-provider adapter, restore path, database migration, live callsite, scheduled task, UI claim, or Release flag

**Depends on:** [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md), [`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md), [`RAVEN_DEVICE_REVOCATION_V1.md`](RAVEN_DEVICE_REVOCATION_V1.md), [`RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md`](RAVEN_SOVEREIGN_SOCIAL_GRAPH_V1.md), [`RAVEN_ATTENTION_FIREWALL_V1.md`](RAVEN_ATTENTION_FIREWALL_V1.md), and [`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md) for archived media provenance/grants

**Unblocks when APPROVED:** provider-independent encrypted personal archives; cross-platform selective restore; multi-device snapshot union; explicit local export; loss recovery for eligible user data without restoring live cryptographic state

> The archive belongs to the user, not to a Raven operator or storage provider. Possession of an archive recovery key permits decryption; it never proves identity authority, restores a live session, creates a contact, sends an ACK, or authorizes network activity.

---

## 0. Constitutional decisions

Raven separates three recovery problems that conventional applications often collapse:

| Problem | Authority | What it recovers |
|---|---|---|
| Identity continuity | `RavenIdentityContinuityV2` recovery quorum | Authority to continue a prepared V2 identity |
| Device/session establishment | Current device, cert, prekey, PairInit, revocation state | Fresh communicating state |
| User-owned archive | High-entropy archive recovery key | Eligible history, media, contacts, preferences, and exact historical evidence |

The keys and authority of these systems are independent. An identity guardian cannot read an archive. An archive recovery key cannot rotate an identity, issue a device certificate, clear a block/revocation, or reconstruct a ratchet. A storage provider cannot read or authenticate either.

The following rules are constitutional:

1. **Client-side confidentiality and integrity do not depend on the provider.** Providers store opaque immutable bytes and may withhold, delete, reorder, duplicate, roll back, fork, correlate, or corrupt them.
2. **No password, PIN, Apple/Google account, phone number, Raven handle, or identity private key is the sole archive key.** The baseline uses a uniformly random 256-bit archive recovery secret generated on the client.
3. **Archive recovery never restores live cryptographic state.** Session roots, ratchet heads, skipped message keys, prekey/OTP secrets, device private keys, recovery-delegate private keys, protected anti-rollback anchors, and platform protected-store blobs are forbidden archive content.
4. **Restore is quarantined and local before it is active.** Restored bytes cannot send, ACK, dial, publish, notify, fetch remote media, or mutate current trust until durable import and current trust/revocation checks complete.
5. **Integrity is not freshness.** A new device with only an archive and recovery key can verify internal authenticity but cannot prove that a malicious provider returned the newest or complete snapshot.
6. **No global convergent encryption or cross-user deduplication.** Deduplication is keyed and scoped to one archive. The provider never receives a raw plaintext hash or a stable cross-archive content identifier.
7. **Public deletion is not remote erasure.** Raven can stop creating new snapshots and request provider deletion, but cannot prove that prior ciphertext, replicas, screenshots, exports, or provider backups were erased.
8. **Multi-device history is a DAG, not last-writer-wins.** Concurrent valid device snapshots are preserved and unioned; time, provider order, lexicographic digest, or source count never silently discards a branch.
9. **Exact provenance survives restore.** Where the source has signed endpoint-object evidence, the archive retains exact bytes and admission evidence rather than rewriting authorship.
10. **Production remains disabled** until byte-exact wires, three-language vectors, durable stores, provider adapters, destructive-negative tests, crash/restart gates, and physical restore matrices pass.

---

## 1. Goals and non-goals

### 1.1 Goals

1. Let a user store an end-to-end encrypted archive in a local folder, removable medium, self-hosted service, or commercial object store without granting that provider plaintext or protocol authority.
2. Restore eligible Raven data across Apple and Terminal platforms without requiring the old device to remain online.
3. Preserve append-only history and exact security evidence while preventing stale archive state from weakening current security.
4. Support selective restore by class, conversation, repository, or time range without giving the provider searchable plaintext metadata.
5. Support bounded incremental snapshots and per-archive deduplication without deterministic cross-user ciphertext.
6. Support multiple independent storage providers without treating replica count as truth.
7. Make loss, rollback, partial availability, key compromise, deletion limits, and metadata leakage explicit to the user.
8. Keep the archive format portable and provider-neutral; adapters translate storage operations, never cryptographic or endpoint semantics.

### 1.2 Non-goals

V1 does not provide or authorize:

- recovery of an unprepared/lost Raven Identity V1 private key;
- restoration of live ATSAM sessions, Double/Triple Ratchet state, skipped keys, OTPs, prekeys, device credentials, or pending ACK/outbox work;
- server-side plaintext indexing, search, ranking, media processing, compression, or transcoding;
- global/cross-user deduplication, convergent encryption, proof-of-ownership protocols, or a dedup key server;
- a Raven-operated mandatory backup service or mandatory cloud account;
- proof that a provider returned the globally newest or complete archive;
- guaranteed deletion from a remote provider or from recipients' archives;
- backup of view-once content, already-expired disappearing content, secrets, diagnostic traces, or hidden local attention profiles by default;
- automatic merging of contradictory security state;
- restoration directly into production tables before full verification;
- remote execution, scripts, symlinks, hardlinks, special files, path traversal, or arbitrary filesystem metadata;
- using an archive as a social repository, carrier, mailbox, identity resolver, or public distribution channel;
- post-quantum authentication or confidentiality claims beyond the exact algorithms frozen by a later wire/crypto companion.

---

## 2. Threat model and honest limits

### 2.1 Adversaries

The design considers:

- a malicious or compromised storage provider that observes object names, sizes, timing, account/network metadata, reads, writes, deletes, withholds, forks, or rolls back bytes;
- colluding storage providers and network observers;
- a thief with copied archive ciphertext but no recovery key;
- a thief with the archive recovery key and some or all archive ciphertext;
- a compromised old device continuing to publish archive branches;
- two honest offline devices producing concurrent snapshots;
- a malicious archive file crafted to exploit parsers, decompressors, media decoders, databases, or filesystem extraction;
- chosen-plaintext attempts to detect whether a user archived a known file;
- corrupted, truncated, oversized, duplicated, reordered, or type-confused records;
- crash/power loss during snapshot creation, upload, head publication, restore, merge, deletion, or key rotation;
- stale local protected pins, loss of every local pin, and restore onto an empty device;
- compromise or loss of the recovery key;
- accidental inclusion of live secrets, disappearing content, trace logs, or private ranking behavior.

### 2.2 Provider-visible metadata

Client-side encryption does not hide all metadata. Depending on the adapter and network path, a provider may observe:

- archive account/bucket identity and client IP;
- object count, opaque object handles, ciphertext lengths, upload/download timing, and access frequency;
- that an immutable object was reused instead of uploaded again;
- retention/deletion requests and provider-to-provider replication timing;
- total archive growth and approximate snapshot cadence.

Padding, batching, OHTTP/Tor-style network profiles, multiple providers, and delayed scheduling may reduce selected signals, but V1 makes no general traffic-analysis or anonymity claim. The UI and provider profile MUST state which metadata remains observable.

### 2.3 Freshness and availability limit

Authenticated encryption proves that returned bytes were produced under an archive key. It cannot prove that a provider returned the newest branch or every branch.

Protected local head pins, comparison across independent providers/devices, and optional external head receipts improve rollback detection. If every trusted pin is lost, restore status is:

```text
INTEGRITY_VERIFIED / FRESHNESS_UNKNOWN / COMPLETENESS_UNKNOWN
```

The client MUST NOT relabel this as “latest backup restored.” A provider can always deny service by deleting or withholding enough ciphertext. Multi-provider replication improves availability; it does not create consensus or authority.

---

## 3. Archive identity, roles, and authority

### 3.1 Archive identity

Every archive begins with:

```text
archive_id[32]       = nonzero CSPRNG
archive_profile      = RavenUserOwnedArchiveV1
archive_generation   = 1
```

`archive_id` is random and independent of Raven address, continuity ID, phone number, user key, device ID, provider account, pathname, and content. It remains stable while the same archive root remains active. A full root rotation creates a new archive ID unless a later approved migration profile proves safe continuity.

The provider sees only an adapter-specific opaque repository locator. An adapter MUST NOT use a Raven address, handle, contact fingerprint, raw archive ID, plaintext digest, conversation ID, or device ID as an object name.

### 3.2 Roles

| Role | May do | MUST NOT become |
|---|---|---|
| Archive owner | Hold/export recovery material; choose providers and retention | Identity recovery authority merely by archive possession |
| Archive writer device | Produce a signed/MAC-authorized immutable snapshot branch | Raven identity/device authority |
| Restoring device | Verify and stage eligible content | Live sender before fresh identity/device/session setup |
| Storage adapter | Put/Get/List/Delete opaque records within explicit caps | Parser, key holder, latest-head oracle, merge authority |
| Storage provider | Store and return opaque bytes | Confidentiality, integrity, identity, contact, or completeness authority |
| Optional head witness | Retain an opaque authenticated head receipt | Decryption key holder or canonical head chooser |

### 3.3 Archive writer keys

Each writer device generates a dedicated archive-writer Ed25519 key. It MUST NOT reuse a Raven identity, device, namespace, recovery-delegate, or messaging key. The private writer key remains in the platform protected store and is never archived.

The archive contains an encrypted `ArchiveWriterGrant` authenticated under a dedicated archive membership key and binding:

```text
archive_id
writer_public_key
writer_id_random[32]
grant_sequence
validity ceiling
capability: snapshot-only
previous writer-policy digest
```

New devices holding the archive recovery secret may create a fresh writer grant only after restore completes and local owner confirmation. Old writer retirement is append-only evidence. Omission is not retirement. A writer signature authenticates archive provenance only; it cannot issue a Raven device certificate or authorize network traffic.

---

## 4. Key hierarchy and recovery material

### 4.1 Root secret

The client generates a uniformly random 32-byte `K_archive_root`. A later crypto companion MUST freeze exact algorithms, wire bytes, nonces, versioning, domain labels, and vectors. Semantically, domain-separated keys include at least:

```text
K_manifest       # snapshot/catalog authenticated encryption
K_chunk          # chunk authenticated encryption
K_index          # per-archive keyed content identifiers
K_head           # head/receipt authentication
K_membership     # archive-writer grants/retirements
K_export         # domain for selective-export derivation only
```

One derived key MUST NOT substitute for another. The archive root and all derived secret buffers are zeroized after use and never logged, serialized in plaintext, or passed to a provider adapter.

### 4.2 Recovery key

The baseline recovery material is a uniformly random 256-bit secret encoded with checksum and human transcription/error-detection rules frozen later. It wraps `K_archive_root`; it is not itself used directly as a chunk/manifest key.

The recovery secret:

- is generated on-device;
- is displayed/exported only through an explicit ceremony;
- is never uploaded to a Raven or storage-provider service;
- is different from Raven PIN, device passcode, identity recovery factors, provider password, and ATSAM keys;
- cannot be reset by support or inferred from the Raven ID;
- must be verified before the UI claims the archive is recoverable.

Losing every copy permanently loses decryption capability. Compromise gives the attacker access to every retained snapshot wrapped by that root. Changing only the wrapper protects future access only if all old wrappers/ciphertexts are unavailable to the attacker; it cannot revoke an already copied key.

The recovery secret is a decryption capability, not a global locator. Restore also requires at least one user-supplied provider locator/account or the offline archive folder/media. A portable recovery card MAY include a non-secret, explicitly disclosed locator capsule and opaque bootstrap handle, but never provider credentials. Losing every locator/provider copy loses availability even when the key survives; leaking a locator reveals storage/correlation metadata but not plaintext without the recovery secret.

### 4.3 Password convenience wrapper

A user MAY add a passphrase wrapper as a convenience layer using an approved Argon2id profile with unique salt and explicit device-tuned parameters. A low-entropy password/PIN is never the only baseline recovery factor because copied ciphertext permits offline guessing. The high-entropy recovery secret remains the authoritative path unless a separately reviewed, rate-limited recovery service profile is approved.

### 4.4 Root rotation

Rewrapping the same root is cheap but does not revoke a leaked root. Cryptographic root rotation requires a new root/archive generation and re-encryption of every retained reachable object. Until that copy-and-verify migration is complete, both roots may decrypt their respective generations. Old-provider deletion remains best-effort.

Identity recovery MUST NOT silently rotate or reveal the archive root. Archive rotation MUST NOT mutate identity continuity.

---

## 5. Immutable object graph

### 5.1 Object classes

The archive is an immutable authenticated object graph:

```text
archive bootstrap descriptor
archive writer policy objects
encrypted content chunks
encrypted item manifests
encrypted snapshot manifests
encrypted branch/head records
encrypted provider catalogs
optional encrypted head receipts
```

All records have canonical versioned framing, explicit type/length, archive ID/generation binding inside authenticated plaintext, random nonce, and an outer ciphertext digest. Unknown critical versions/types fail closed. Provider metadata is never inside an authenticity decision unless the exact adapter profile says so.

### 5.2 Storage handles

Each newly stored ciphertext receives a fresh random 256-bit opaque storage handle independent of plaintext and ciphertext digest. The encrypted catalog maps logical keyed identifiers to `(provider, handle, ciphertext_digest, ciphertext_length, object_class)`.

Handles are unguessable capabilities for location only, not decryption or integrity. A provider-returned object is accepted only after exact length bounds, ciphertext digest, authenticated decryption, inner type/profile/archive binding, and semantic validation.

The user-selected repository root contains one profile-fixed bootstrap slot or a recovery-card-supplied random bootstrap handle. That slot contains only an authenticated encrypted bootstrap/catalog hint and may be stale, missing, or rolled back. It is never the authoritative latest head. Recovery follows verified immutable records and bounded listings from that hint; a malicious provider can still withhold them.

### 5.3 Immutable writes

Adapters use create-if-absent semantics where available. If a provider can overwrite an object, Raven still treats handles as immutable: changed bytes under the same handle are corruption. Exact replay is idempotent. Same handle with different bytes is provider conflict and cannot be selected by last arrival.

Mutable “latest” files are hints only. Durable truth is the set of verified immutable head/snapshot records.

---

## 6. Chunking, padding, and deduplication privacy

### 6.1 Baseline chunking

V1 uses fixed-size, class-specific chunks and bounded final-chunk padding. A later wire companion freezes exact ceilings and padding buckets. Content-defined chunking is not baseline because boundary patterns and stable chunk reuse increase fingerprinting complexity.

Metadata, message text, and attacker-controlled content MUST NOT be compressed in the same compression context as secrets or hidden metadata. Any approved compression is deterministic within one object class, happens before padding/encryption, has strict expansion limits, and is never provider-executed.

### 6.2 Per-archive keyed deduplication

For an eligible padded plaintext chunk:

```text
chunk_id = HMAC(K_index,
                domain || archive_generation || class ||
                plaintext_length || padded_plaintext)
```

`chunk_id` exists only inside encrypted catalogs/manifests. On first occurrence, the client encrypts with a fresh nonce and stores under a fresh opaque handle. Later snapshots in the **same archive** may reference that existing authenticated ciphertext.

Consequences:

- equal plaintext in different archives produces unlinkable keyed IDs and independently randomized ciphertext;
- a provider cannot test a guessed plaintext by computing a public hash;
- an archive member with `K_index` can test content membership and therefore must be treated as a full archive secret holder;
- a provider may infer reuse from upload/access patterns within one archive;
- a copied recovery/root key exposes all content reachable under that generation.

### 6.3 Forbidden dedup modes

The following are forbidden in V1:

- raw SHA-256/BLAKE hashes of plaintext as provider-visible names;
- encryption keys derived only from plaintext;
- deterministic ciphertext shared across archives/users;
- provider-side proof that a client owns a guessed plaintext;
- global dedup, cross-account dedup, or dedup across independently keyed exports;
- treating a content ID as authorization to read or restore.

These rules intentionally trade storage efficiency for resistance to content-confirmation and cross-user correlation attacks.

---

## 7. Snapshot and branch model

### 7.1 Per-device chain

Each archive writer maintains an append-only chain:

```text
writer_id
snapshot_sequence_u64            # starts at 1, increments exactly
previous_snapshot_digest?        # absent only at sequence 1
parent_head_set[]                 # greatest verified heads observed
created_monotonic_evidence        # advisory/local; not global order
content_manifest_root
security_evidence_root
retention_policy_digest
writer_grant_digest
snapshot_nonce[32]
writer_signature
```

Equal `(writer_id, sequence)` with different exact bytes is authenticated writer conflict. Sequence gaps are incomplete, not implicitly filled. Exact replay is idempotent.

### 7.2 Concurrent devices

Two honest offline writers may create valid concurrent branches. Raven preserves both. Merge snapshots list every exact parent head and contain a deterministic union result plus conflict evidence; no branch disappears by timestamp, provider preference, source count, or lexicographic digest.

Class-specific merge rules apply:

| Class | Merge rule |
|---|---|
| Immutable chat/history item | Set union by archive item ID and exact provenance |
| Attachment chunk | Keyed dedup reference union |
| Block/revocation/conflict evidence | Monotonic union; never downgrade/delete by omission |
| Contact pin | Preserve concurrent values as `REQUIRES_REVALIDATION` conflict |
| Preference | Explicit user choice or deterministic local policy; never security authority |
| Deletion/retention tombstone | Monotonic within its exact archive scope; cannot claim provider erasure |
| Public repository object | Exact-byte union with original signatures/evidence |

### 7.3 Head publication

A snapshot becomes publishable only after every referenced immutable object is uploaded and read back/verified as required by the adapter profile. Then the client creates the immutable signed head record, uploads it, verifies it, and finally advances the protected local pin.

Uploading a head before all dependencies are durable is forbidden. A provider's mutable pointer may be updated afterward as an optimization. A crash yields either the old verified head or a fully reconstructible new immutable head; orphan ciphertext is GC-eligible only after the retention horizon and a complete reachability scan.

### 7.4 Protected local pins

The client durably protects at least:

```text
archive_id / generation
greatest verified writer heads
greatest writer-policy head
known terminal conflicts
provider catalog generations
last successful complete snapshot
restore/import barrier state
```

Protected pins are never archived as authoritative restore input. Archive copies may carry historical evidence, but an imported lower head cannot reduce a newer local pin.

---

## 8. Provider adapter contract

### 8.1 Minimal operations

A provider profile exposes bounded variants of:

```text
create(handle, exact_bytes) -> Created | ExactExisting | Conflict | Error
get(handle, max_bytes) -> exact_bytes | Missing | Error
list(namespace_cursor, page_cap) -> opaque handles + next_cursor
delete(handle) -> best_effort result
```

An adapter MAY add conditional-put or append-log operations, but correctness cannot assume them unless the selected profile requires and tests them. HTTP status, ETag, modification time, generation number, filesystem mtime, provider checksum, or TLS identity is not archive authenticity.

### 8.2 Provider neutrality

Candidate adapters include a local directory/removable drive, user-selected filesystem sync folder, WebDAV, S3-compatible object storage, or platform document storage. Naming an adapter does not approve it. Every adapter needs:

- exact path/key normalization and traversal rejection;
- bounded pagination/listing and duplicate/conflict rules;
- atomicity/crash semantics;
- credentials stored outside the archive;
- TLS/network policy where applicable;
- retry/idempotency behavior;
- metadata-leakage statement;
- deletion and lifecycle-policy statement;
- process/physical conformance tests.

Provider credentials authorize storage operations only. They cannot decrypt archives or authorize Raven identity/social/message operations.

### 8.3 Multiple providers

Replication copies exact ciphertext and immutable records; it does not decrypt/re-encrypt at the adapter. A branch seen from one provider is verified exactly like a branch seen from another. Valid branches union. Invalid bytes are rejected. Higher provider count does not outweigh a valid conflicting branch or prove completeness.

The client MUST NOT leak one provider's credentials, bucket name, URL, or opaque handle into another provider's archive plaintext.

---

## 9. Content eligibility

### 9.1 Included by explicit policy

Eligible archive classes MAY include:

- durable chat history plaintext already visible to this local user, with sender/direction/timestamps marked as historical UI metadata;
- media/attachments allowed by retention policy;
- exact signed endpoint objects and the exact certificate/revocation/admission evidence needed to explain historical verification;
- local contact labels and pinned public keys as **historical pins requiring current revalidation**;
- local block list and authenticated revocation/conflict evidence using monotonic union;
- local social follow/subscription state, private social records, community metadata, and public repository objects/references;
- user-authored drafts and local preferences that are not secrets;
- accessibility and UI settings chosen for export;
- redacted diagnostics only through a separate explicit support export, never by default.

### 9.2 Always excluded

The archive MUST NOT contain:

- ATSAM root keys, RK/CK/MK, Triple Ratchet/Braid secret state, skipped keys, session heads, or pending ratchet journals;
- unsealed outbound body stages, queued ciphertext whose delivery state can mutate, outstanding ACK state, pending ACK intents, nonce-replay state, or mailbox route keys;
- signed-prekey/OTP private material, ML-KEM/X25519 private keys, device signing/agreement private keys, identity operational private keys, V1 identity private keys, or recovery-delegate private keys;
- Keychain/Secret Service/CredMan items, SQLCipher keys/salts, protected-anchor seeds/records, hardware-bound keys, or raw protected-store serialization;
- provider credentials, APNs tokens, OAuth/session cookies, bridge tokens, or debug secrets;
- view-once plaintext, content whose disappearing deadline has passed, or content scheduled to disappear within the profile's exclusion horizon;
- raw local attention behavior such as dwell/read history, hidden interests, ranking weights, notification behavior, or unredacted “Why shown?” records by default;
- TRACE logs, crash dumps, environment variables, filesystem paths, or telemetry containing identifiers/secrets;
- arbitrary app caches, downloaded executables, scripts, symlinks, hardlinks, sockets, devices, or extended attributes.

### 9.3 Disappearing and deleted content

Archive inclusion is an explicit user policy, but disappearing/view-once semantics take precedence. The client excludes content before snapshot eligibility, not merely from the UI manifest.

A later local deletion creates an archive retention tombstone and prevents the bytes from appearing in new reachable snapshots after compaction. It cannot prove old provider snapshots, exports, recipients' copies, or malicious mirrors were erased. UI must say “removed from future Raven archive snapshots,” not “deleted everywhere.”

### 9.4 Conversation privacy

A participant may archive messages they received, just as they may otherwise retain or screenshot them. End-to-end encryption does not cryptographically prevent a recipient from backing up plaintext after receipt. Raven SHOULD expose an honest conversation-level indication that local archival is enabled without claiming enforceable remote deletion.

---

## 10. Snapshot creation and crash ordering

### 10.1 Local eligibility transaction

Archive creation reads only already durable application state. It MUST NOT advance inbox cursors, mark delivery/read, send ACKs, consume one-time keys, or alter live retention merely because a backup ran.

The local snapshot journal follows:

```text
capture immutable eligible read view
  -> classify/exclude secret and expiring classes
  -> chunk/pad/compress under caps
  -> encrypt new chunks/manifests
  -> persist exact pending snapshot intent locally
  -> upload immutable dependencies
  -> readback/verify per provider profile
  -> upload immutable snapshot/head
  -> verify head and dependency closure
  -> advance protected local head pin
  -> clear intent
  -> schedule bounded orphan GC after horizon
```

Network I/O occurs outside protected mutation leases. Exact pending bytes and handles make retries idempotent. Recovery always rolls forward or retains the old head; it never reuses a nonce/key under different plaintext, rolls back a protected generation, or releases a partially closed snapshot.

### 10.2 Capacity and resource policy

All counts, lengths, nesting, compression expansion, chunk totals, manifest fanout, provider pages, retries, branches, and concurrent uploads have explicit checked ceilings. Capacity is reserved before expensive work. Exhaustion fails closed without evicting protected security evidence or an active prior snapshot.

---

## 11. Restore pipeline

### 11.1 Restore phases

Restore is a staged import, never a database overwrite:

```text
1. enter recovery key locally
2. unwrap archive bootstrap and verify archive binding
3. enumerate bounded provider candidates
4. verify immutable heads/catalogs and build branch DAG
5. classify freshness/completeness from available pins/evidence
6. choose classes/ranges; estimate exact bounded resources
7. fetch into isolated quarantine
8. digest + AEAD + inner schema/provenance verification
9. build a read-only restore preview and conflict report
10. create a fresh Raven device lineage through current identity flow
11. durably import eligible data in one journaled local transaction family
12. refresh current cert/revocation/resolution/contact gates
13. enable only the explicitly accepted non-network state
14. re-pair fresh messaging sessions; never import old session state
```

If identity continuity recovery is also needed, it completes as its own ceremony. Neither process silently invokes the other.

### 11.2 Quarantine invariants

Before final import, restored content:

- is stored under a distinct encrypted quarantine key/database;
- cannot appear in production queues, feeds, notifications, media auto-download, or extension/widget stores;
- cannot issue network requests from embedded URLs or media references;
- cannot ACK, resend, mark delivered/read, publish, follow, contact, block/unblock, or mutate identity/session state;
- uses sandboxed decoding and bounded previews;
- is deleted or retained only through explicit journaled choice.

### 11.3 Safe filesystem/package extraction

If an export/container format is used, the importer accepts only allow-listed regular files with canonical relative names. It rejects absolute paths, `..`, alternate separators, NULs, Unicode-normalization collisions, case-fold collisions, symlinks, hardlinks, sparse/device/socket/FIFO files, nested archives unless explicitly profiled, undeclared files, duplicate names, and size/count/expansion violations.

Parsing never writes to final paths. Decompression and media parsing occur under strict memory/CPU/output caps. Any signature/MAC/digest/schema failure occurs before application-state mutation.

### 11.4 Message-history semantics

Restored messages are historical local records. They retain exact archived message/object IDs, body, direction, and provenance where available, but:

- do not recreate an outstanding row;
- do not emit Delivered/Read receipts;
- do not enter the send queue;
- do not advance a ratchet or dedup nonce map;
- do not imply that a current device has verified the sender's current key;
- display an archive/restored marker until local import policy chooses otherwise.

Duplicate history merge is scoped by exact peer/history lineage/direction/message-object identity, not body text alone.

### 11.5 Media provenance and participation grants

For eligible media, an archive preserves the exact asset bytes, exact C2PA
Manifest Store/sidecar bytes, Raven publication evidence and participation/use
grants as distinct encrypted records with their original identities. It does
not recompute a green provenance badge from a filename, preview, soft-binding
hit or archive writer signature.

Restore verifies each class independently and retains honest `UNKNOWN`,
`INVALID` and `CONFLICT` evidence. Restored provenance is read-only/quarantined:
it cannot publish, register a soft binding, refresh trust/revocation, grant
consent, fetch ingredients, notify a participant, or make a historical use
grant current. Republishing or deriving media is a new explicit operation under
[`RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md`](RAVEN_SOVEREIGN_MEDIA_PROVENANCE_V1.md).

### 11.6 Contact and safety-state semantics

Restored contact records are `HISTORICAL_PIN / REVALIDATION_REQUIRED`. Before PairInit or send, Raven verifies the current identity/continuity head, exact device certificate, revocation store, local block state, and current contact confirmation policy.

Blocks, revocation denies, and terminal conflict evidence union with current state and cannot be cleared by an older archive. Unblock/repair remains an explicit current-device operation under its own profile.

---

## 12. Replay, rollback, fork, and repair

### 12.1 Replay

Exact immutable-object replay is idempotent. Same identity/handle/sequence with different bytes is conflict. The provider's newest timestamp or ETag cannot choose a winner.

### 12.2 Rollback

With an existing protected local pin, a lower writer/policy/catalog/head generation is stale and cannot replace it. It may supply missing historical dependencies only after exact verification.

Without any protected pin, the client reports freshness unknown and offers multi-provider/device comparison. It MUST NOT initialize a new “greatest pin” while hiding a verified conflict or gap.

### 12.3 Writer compromise

A compromised archive writer may create valid future snapshots within its unretired grant. It cannot decrypt solely from the signing key, alter prior immutable objects undetectably, authorize Raven operations, or clear another branch. Writer retirement prevents new automatic admission after the exact retirement is known; knowledge is eventual under partition.

### 12.4 Repair

Repair consumes exact verified objects through a protected journal. It may reconstruct a missing catalog/index from authenticated manifests, replicate healthy ciphertext, or preserve a branch conflict. It cannot invent missing plaintext, reset to first trust, weaken a local pin, reinterpret corrupt bytes, or declare completeness.

---

## 13. Selective export and sharing

Selective export creates a new independent archive package with:

- a new random export ID;
- a new random export root/recovery secret;
- only explicitly selected eligible objects;
- freshly randomized ciphertext and handles;
- no provider credentials, archive root, K_index, hidden catalog, unselected graph edges, or live state;
- a human-readable disclosure summary before creation.

The source archive root is never shared. Dedup references are materialized/re-encrypted into the export; cross-archive linkability is not preserved. Export recipients receive historical data, not Raven identity/contact/session authority.

---

## 14. Retention, deletion, and compromise UX

The product exposes at least these distinct actions:

| Action | Honest effect |
|---|---|
| Stop future backups | Stops new snapshots; existing provider ciphertext remains |
| Remove from future snapshots | New reachable manifests omit/tombstone data after compaction |
| Request provider deletion | Best-effort request; no proof of remote erasure |
| Rewrap recovery key | Changes wrapper; does not revoke copied old root/key |
| Rotate archive root | Re-encrypts retained data into a new archive generation; old copies may remain |
| Export selected data | Creates a separately keyed copy |
| Destroy local archive keys | Makes local access unavailable; remote ciphertext may persist |

If the recovery key is suspected compromised, UI says the attacker may read every obtained snapshot under that root. Raven does not claim that password change or provider deletion retroactively protects copied ciphertext.

---

## 15. Architecture ceilings

Exact lower limits are frozen by a wire companion; implementations MAY tighten them. The architecture imposes finite ceilings for at least:

```text
providers per archive
writer grants and active writers
concurrent branch heads
snapshot parents
objects/chunks per snapshot
chunk plaintext/ciphertext size
manifest fanout/depth
archive item size
attachment size
total restore bytes
provider page size/pages
compression expansion ratio/output
quarantine rows/bytes
conflict evidence
retry attempts/backoff horizon
opaque handle and metadata lengths
```

No untrusted length controls allocation before checked bounds. Arithmetic uses checked operations. Limit exhaustion preserves old durable state and returns a stable redacted error.

---

## 16. Failure matrix

| Failure | Required result |
|---|---|
| Wrong recovery key / corrupt wrapper | Generic authentication failure; no oracle about archive contents |
| Provider returns missing/truncated/tampered bytes | Reject before semantic mutation; retain evidence and try explicit alternate source if policy permits |
| Same handle, different bytes | Provider conflict; never last-write-wins |
| Missing dependency under a valid head | `INCOMPLETE`; head not importable |
| Lower head than protected pin | `ROLLBACK_DETECTED`; no pin downgrade |
| No prior pin on new device | Integrity may pass; freshness/completeness remain unknown |
| Two valid concurrent heads | Preserve/union; no timestamp winner |
| Same writer sequence, different bytes | Terminal writer conflict evidence |
| Crash before immutable dependency upload | Old head remains; retry exact pending intent |
| Crash after dependencies, before head | Orphans retained until safe GC horizon |
| Crash after head, before local pin | Verify exact pending head, roll forward pin |
| Crash during restore import | Quarantine/final journal rolls forward; no partial live state |
| Archive contains forbidden secret class | Reject snapshot/import and emit local redacted security finding |
| Contact present only in archive | Historical pin; fresh revalidation required before send |
| Old archive lacks a current block/revoke | Current monotonic safety state wins |
| Old archive contains a now-revoked device | Historical verification only; never authorize current activity |
| Compression bomb / traversal / link / extra file | Reject package before final writes |
| Provider list omits valid branch | Cannot prove omission; show partial/unknown state |
| Recovery key lost | Archive permanently unreadable; no support reset |
| Recovery key compromised | Assume retained archive confidentiality lost; rotate by full migration |
| Provider delete reports success | Report requested/deleted-at-provider only; no global erasure claim |

---

## 17. Required vectors and adversarial tests

Before approval, Python/Rust/Swift compute byte-exact fixtures for:

1. key derivation/domain labels and wrapper success/failure;
2. archive bootstrap and archive-ID binding;
3. writer grant/retirement and cross-archive/key substitution;
4. fixed chunking, padding buckets, keyed per-archive IDs, and randomized first encryption;
5. equal content within one archive dedups; equal content across archives does not correlate;
6. chunk/item/snapshot/head/catalog codecs and ciphertext digest checks;
7. two writer chains, concurrent heads, merge, exact replay, gap, fork, and retirement;
8. provider overwrite/rollback/withholding/partial listing/mixed-replica behavior;
9. protected local pin rollback and empty-device freshness-unknown state;
10. snapshot crash points before/after dependency/head/pin;
11. restore quarantine, selective class/range import, crash/restart, and idempotency;
12. history restore without ACK/outstanding/outbox/ratchet mutation;
13. contact restore requiring revalidation and monotonic block/revocation union;
14. exclusion of all secret classes and expiring/view-once content;
15. traversal, symlink, hardlink, special file, duplicate/casefold/Unicode collision, extra file, and decompression-bomb negatives;
16. rewrap versus full root rotation and honest old-copy exposure;
17. selective export with new key/ID/ciphertext and no source-root linkage;
18. zeroization, redacted errors/Debug, and no secret/plaintext in logs or provider requests.

Fixtures that merely echo expected JSON are insufficient. Each language performs real derivation, authenticated encryption/decryption, canonical codec, branch merge, and state transition computations.

---

## 18. Simulations and physical gates

### 18.1 Deterministic simulations

The approval suite includes at least:

- 1,000 users with mixed archive sizes and no cross-archive content-link identifier;
- multi-device offline snapshots, branch unions, writer compromise, retirement, and reconnection;
- two or more malicious providers performing rollback, selective withholding, forked listings, corruption, and deletion;
- provider outage/partition with bounded retry and no protected-state eviction;
- known-file/chosen-plaintext probes demonstrating that provider-visible names/ciphertext do not confirm cross-archive membership;
- capacity attacks against chunks, manifests, branches, provider pages, quarantine, compression, and media;
- archive-root compromise/rotation and old-copy residual-risk reporting;
- restore with no local pin, one local pin, multiple providers, and conflicting valid heads.

Simulation models are evidence about bounded behavior, not proof of Internet anonymity or provider deletion.

### 18.2 Process and physical matrix

Required rows include:

| Scenario | Platforms |
|---|---|
| Create → kill at every write boundary → resume | iPhone, macOS Terminal, GNU/Linux, Windows |
| Archive to local folder/removable medium → fresh-device restore | Each supported platform pair |
| Cross-platform restore | iPhone↔macOS/Linux/Windows where product support is claimed |
| Provider adapter create/get/list/delete/conflict/rollback | Every approved adapter |
| Device lock/BFU/protected-key behavior | Physical iPhone |
| Lost old device; continuity recovery then archive restore | Physical device + Terminal harness |
| Restore history then establish fresh PairInit/session | Physical two-endpoint path; no old-session reuse |
| No ACK/resend/network effect during restore | Packet/log/queue audit |
| Disappearing/view-once exclusion and post-delete compaction | Physical/process restart |
| Secret/plaintext leakage scan | DB/WAL/SHM/temp/log/crash/export/provider objects |
| Malicious container extraction | All supported import platforms |
| Recovery-key loss/incorrect entry/compromise warning | Real UX/accessibility flow |

One provider, one simulator, one successful restore, or source inspection alone cannot satisfy the production matrix.

---

## 19. Production holds

Production archive/export/restore remains disabled until all are met:

1. this architecture and its byte-exact wire/crypto/persistence/adapter companions are APPROVED;
2. the recovery-key ceremony, checksum/encoding, verification, accessibility, loss warning, and compromise flow pass human review;
3. every included/excluded data class has an audited source mapping and stable migration policy;
4. forbidden live secrets are proven absent across snapshots, exports, logs, temp files, crash reports, and provider requests;
5. key hierarchy, nonce generation, zeroization, platform protected storage, and root rotation pass independent cryptographic review;
6. per-archive dedup has no provider-visible plaintext/content hash and global/cross-user dedup is impossible in shipped configurations;
7. snapshot/head/catalog/pin and restore/import crash matrices pass on real durable stores;
8. multi-device fork/merge, stale writer, writer retirement, rollback, and empty-device freshness UX pass;
9. every approved provider adapter passes conformance and metadata/deletion disclosures;
10. filesystem/container/media/decompression adversarial suites pass with strict resource caps;
11. restore is demonstrated to have zero ACK, outbox, ratchet, PairInit, notification, publication, or hidden fetch side effects;
12. contacts require current revalidation and safety evidence only strengthens monotonically;
13. Python/Rust/Swift vectors and deterministic simulations pass from clean generated artifacts;
14. cross-platform and physical matrices in §18.2 pass for every advertised scenario;
15. logs/telemetry/analytics prove no recovery key, archive key, plaintext, contact graph, conversation ID, local ranking behavior, filesystem path, or provider credential leakage;
16. independent security/privacy review and explicit protocol-owner approval are recorded;
17. no runtime flag can bypass holds or silently fall back to plaintext/system backup.

Until then, implementations are lab-only, isolated, fail-closed, and have no live callsites.

---

## 20. Open decisions before vector freeze

1. Exact archive/recovery-key encoding and checksum.
2. Exact HKDF/AEAD/hash/signature suite and algorithm agility/migration rules.
3. Fixed chunk sizes and padding buckets by content class.
4. Snapshot/item/catalog/head/writer-policy byte layouts and magics.
5. Local provider adapter first slice and the minimal portable store API.
6. Optional encrypted head-witness receipt profile and its correlation cost.
7. Exact retention horizon for RVOR-like restore evidence, orphans, tombstones, and provider GC.
8. Multi-device writer-grant issuance/retirement ceremony.
9. Historical message/provenance schema and database import mapping.
10. Cross-platform media representation and unsupported-content behavior.
11. Conversation-level archival disclosure and disappearing-message exclusion horizon.
12. Whether an optional separately reviewed M-of-N **archive** recovery profile is needed; it MUST remain independent of identity recovery.
13. Optional passphrase wrapper parameters and low-memory-device policy.
14. Supported provider adapters, credential models, and exact metadata disclosures.

These decisions block vector freeze. They do not authorize implementation-by-assumption.

---

## 21. Research foundations (informative only)

These sources inform the threat model and design choices; none overrides Raven's normative invariants:

- [Signal Secure Backups](https://signal.org/blog/introducing-secure-backups/) — opt-in end-to-end encrypted archives, an on-device high-entropy recovery key unavailable to the service, explicit loss semantics, secondary media encryption, and padding. Raven generalizes storage ownership and keeps identity/session recovery separate.
- [restic repository design](https://restic.readthedocs.io/en/v0.18.1/design.html) — immutable content-addressed repository objects, independently authenticated encrypted blobs, encrypted indexes, and snapshot graphs. Raven avoids provider-visible plaintext IDs and global deduplication.
- [Tahoe-LAFS provider-independent security](https://tahoe-lafs.readthedocs.io/en/latest/about-tahoe.html) and [architecture](https://tahoe-lafs.readthedocs.io/en/tahoe-lafs-1.12.1/architecture.html) — client-side confidentiality/integrity independent of storage servers, capability boundaries, redundancy, and honest availability limits.
- [DupLESS](https://www.usenix.org/conference/usenixsecurity13/technical-sessions/presentation/bellare) — message-locked/convergent encryption enables deduplication but is inherently exposed to brute-force attacks on guessable content; Raven forbids cross-user/global convergent encryption.
- [RFC 9106](https://www.rfc-editor.org/info/rfc9106/) — Argon2id guidance for an optional password convenience wrapper; a password is not Raven's sole baseline recovery secret.
- [`RAVEN_IDENTITY_CONTINUITY_V2.md`](RAVEN_IDENTITY_CONTINUITY_V2.md) — stable identity recovery is deliberately distinct from archive/data recovery.

---

## 22. Revision history

- **Revision 1 (2026-08-21):** Initial architecture freeze. Defined independent archive/identity/session recovery; provider-independent encrypted immutable object graph; random recovery/root keys; per-archive keyed dedup; fixed chunking/padding; multi-device snapshot DAG; protected pins and honest freshness; provider adapter boundary; strict content inclusion/exclusion; quarantined selective restore; crash ordering; export, deletion, compromise, vectors, simulations, physical gates, and production holds.
- **Revision 2 (2026-08-21):** Sovereign-media boundary: archives preserve exact assets, C2PA stores, Raven publication evidence and participation grants as separate encrypted historical records; restore cannot republish, perform public lookup, refresh trust, infer consent, or recreate provenance authority.
