# RAVEN Object Sync V1

**Version:** 1

**Document revision:** **13** (immutable snapshots remain valid across live-store churn; no pre-certificate generation livelock)

**Record family:** `carrier_control_bytes` only (`RVOS*`)

**Status:** **REQUIRED / NOT YET APPROVED** — design draft under [`RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md`](RAVEN_UNIFIED_SERVERLESS_ARCHITECTURE_V2.md)

**Production:** **disabled** — this companion MUST NOT enable any production/Release flag; no live carrier may ship Object Sync until this document is **APPROVED** and [`RAVEN_CARRIER_CONFORMANCE_V1.md`](RAVEN_CARRIER_CONFORMANCE_V1.md) gates pass

**Approval prerequisites:** Umbrella **Approved** (met)
**Unblocks:** Carrier Conformance; later Social Object DAG / Mailbox inventory efficiency (not this revision’s scope)

This document freezes **set reconciliation for peer-eligible endpoint objects** over an already authenticated carrier link. It uses a **Rateless IBLT** construction in the spirit of *Practical Rateless Set Reconciliation* (Yang, Gilad, Alizadeh; ACM SIGCOMM 2024; [arXiv:2402.02668](https://arxiv.org/abs/2402.02668)) adapted to Raven’s three-layer object model.

**Umbrella invariants remain binding.** Companions cannot override them.

**Rev13 changelog (normative):**
1. Removes live store-generation drift as a round-abort condition at every phase. Once Open/Accept retain byte-exact immutable snapshots/maps, later arrivals, admissions, expiry, or deletion change only the live generation; they cannot rewrite/invalidate the frozen reconciliation transcript.
2. Preserves fail-closed safety: trust/contact/revocation or eligibility-policy drift, snapshot evidence loss/corruption, binding mismatch, and owner fetch-time unavailability still abort/refuse as specified. New objects wait for a later round; deleted/expired objects become indistinguishably unavailable at exact fetch.
3. Recasts `generation_u64be` as durable provenance captured at freeze—not a live lock/version predicate—eliminating sync livelock on busy devices without weakening exact admission.

Revision changelogs are historical summaries. If an earlier summary conflicts with the current normative body, the highest document revision governs; in particular, Rev13 supersedes the Rev3/Rev6 pre-certificate generation-drift abort rule.

**Rev12 changelog (normative):**
1. Generalizes the deterministic retry schedule to request/response barriers: Open→Accept/Reject, emitted Symbol prefix→DecodeStatus, PageOffer→PageAck, Offer→recorded Request selection, and Request→existing exact-delivery/unavailable outcome.
2. An exact duplicate Open reuses the cached exact Open response; while Reconciling it may also replay retained initial/current prefix bytes. A duplicate prefix after the initiator has emitted a status replays that exact status, closing lost Certified/PagedFallback/NeedMore windows.
3. Freezes one common retry interval and three retransmissions for every retryable barrier. All retries use retained exact bytes, explicit monotonic ticks, fresh atomic control/work reservations, no logical-state rollback, and no refund.

**Rev11 changelog (normative):**
1. Freezes PageOffer/PageAck as a stop-and-wait state machine: one page in flight, next page only after exact Ack, duplicate PageOffer replays exact Ack, and future/out-of-order Ack is rejected.
2. Derives a deterministic retry interval from accepted `round_ttl_ms`, permits three exact retransmissions per page, and aborts/fails closed on expiry, retry, work, or directional control-byte exhaustion.
3. Requires the sender to retain/regenerate exact PageOffer bytes and the receiver to retain exact PageAck outcomes; retries never mutate page-manifest state or admit objects.

**Rev10 changelog (normative):**
1. Freezes a deterministic initial rateless prefix and doubling schedule. `NeedMore` either requests the one exact next prefix or replays the current target to recover loss; arbitrary jumps are forbidden.
2. Defines exact replay output: a valid current-target `NeedMore` reuses the retained byte-identical Symbol frames for that prefix. It never advances encoder/decoder state, but every actual resend consumes control-send bytes.
3. Adds negotiated directional `max_control_bytes_i2r` and `max_control_bytes_r2i` to `RavenObjectSyncCapsV1`, expanding it from 64 to 80 bytes. Every in-round frame—including duplicates and replayed outputs—reserves/debits its exact wire length; exhaustion stops amplification before enqueue/body read. Pre-accept Open/Reject traffic has a separate fixed authenticated-link supervisor.
4. Recomputes OpenRound to 273 bytes and AcceptRound to 394 bytes. Other Rev8 frame sizes and the 4352-byte absolute maximum remain unchanged.
5. Adds a bounded non-evicting per-authenticated-session seen set for round/snapshot IDs, preventing an expired same-session Open replay from becoming a fresh round. At 1024 rounds the sync feature requires re-authentication; ordinary exact delivery is unaffected.

**Rev9 changelog (normative):**
1. Extends rateless completion certification to reconstruct the full responder inventory from the initiator snapshot plus polarized differences, then byte-check `eligible_count` and `page_manifest_digest` against the accepted responder descriptor. An algebraically self-consistent stream for another set can no longer cross the `CertifiedTransfer` barrier.
2. Requires each local descriptor to be recomputed from its immutable local snapshot before Open/Accept and freezes descriptor/count/page cross-field checks before allocation.
3. Adds adversarial fixtures for a zero-residual/re-encoding-valid prefix whose reconstructed remote set conflicts with the accepted responder count or manifest.
4. Freezes the persistent abuse-record key encoding so all languages/reconnect paths identify the same authenticated identity/device, while clarifying that raw network/relay addresses—not the authenticated Raven identity key—are excluded from records.

**Rev8 changelog (normative):**
1. Adds the current nonzero `link_context_digest = SHA-256(exact RVLX1)` to the common header of **every** `RVOS1` frame. Strict demux checks it before round lookup, snapshot freeze, reservation, allocation, or mutation, so exact control bytes from another authenticated session—including `OpenRound`—cannot be transplanted.
2. Expands the common header from 60 to 92 bytes and recomputes every exact frame size while retaining the 4352-byte absolute frame cap; maximum `PageOffer` becomes 4296 bytes.
3. Freezes deterministic `DecodeStatus` progression and replay rules: monotonic `NeedMore`, mutually exclusive `Certified`/`PagedFallback`, terminal `Done`, exact replay idempotency, and conflict handling.
4. Corrects attempt namespaces: offers are monotonic by `(round_id, owner_role)` while requests are monotonic by `(round_id, requester_role, owner_role)`.
5. Clarifies that passive/relay cross-session transplant is rejected byte-for-byte; a malicious authenticated endpoint may always originate fresh current-session control, but remains bounded and cannot create false durable admission.

**Rev7 changelog (normative):**
1. Resolves the prior contradiction between “link-local control” and relay-carried authenticated sessions. `RVOS*` MAY traverse an opaque Circuit Relay only as ciphertext inside one unchanged end-to-end authenticated carrier session; the relay never terminates, parses, persists, demultiplexes, translates, or re-emits Object Sync control.
2. Separates an opaque circuit relay from a terminating bridge. A bridge that terminates two authenticated sessions has two independent Object Sync links, exporter contexts, keys, rounds, replay stores, and supervisors; it MUST NOT transplant control bytes or reconciliation state between them.
3. Freezes BLE and mailbox behavior: hop-by-hop mesh nodes cannot forward Object Sync control, and mailbox/store nodes cannot persist it. Adjacent authenticated hops may run independent rounds, while an approved end-to-end encrypted stream may use transient bounded transport buffering without turning control into a stored object.
4. Adds carrier-boundary conformance negatives for cross-session transplant, plaintext/control visibility at relays, bridge translation, BLE hop forwarding, mailbox persistence, and exporter reuse.
5. Normalizes the KDF call to the defined `RavenAuthenticatedLinkExporterV1` interface and freezes cumulative exact-byte debit as once per newly accepted attempt: exact replay reuses the outcome without a second enqueue/debit, while a failed attempt is never refunded.

**Rev6 changelog (normative):**
1. Historically separated `Reconciling` from `CertifiedTransfer`. Its pre-certificate live-generation abort rule is superseded by Rev13; policy/contact/revocation drift and snapshot-evidence failure still abort, while exact admissions never rewrite the immutable initial snapshot.
2. Freezes replay/conflict identity for every control frame, not only symbols and offer/request attempts.
3. Requires an immutable original difference-cell prefix beside the mutable candidate decoder so completion re-encoding cannot accidentally compare against already peeled state; both copies debit retained-byte budgets.
4. Freezes cap cross-field invariants and clarifies that global retained bytes include snapshots, maps, cells, replay bytes, candidates, pages, and pending exact-transfer metadata.

**Rev5 changelog (normative):**
1. Removes the approval dependency cycle: this document freezes the byte-exact `RVLX1` post-handshake exporter context and subkey schedule. Carrier Conformance later maps each approved handshake to the abstract exporter and must prove provider vectors; it cannot redefine Object Sync KDF bytes.
2. Chooses a Raven-owned, MIT-notice-preserving strict port of the pinned Rateless IBLT artifact. The port separates placement and purity keys and uses an exact integer inverse-CDF mapping—never ambient floating point—while the pinned artifact remains a non-normative research oracle.
3. Freezes `RavenRibltCellV1` as 40 bytes (`id_xor[16] || check_xor[16] || count_i64be`) and freezes polarity, mapping, purity, prefix, and completion-certificate bytes.
4. Freezes byte-exact `RVOS1` frame layouts, snapshot/cap layouts, frame lengths, attempt rules, and strict parse-before-allocation behavior.
5. Freezes concrete per-link/device/process supervisors, deterministic work-unit accounting, and bounded persistent abuse-state semantics. Peer values may only tighten these limits.

**Rev4 changelog (normative):**
1. One round has exactly one decoder. `RemoteOnly` uses opaque request; `LocalOnly` uses bounded opaque offer followed by receiver-controlled request. A role-reversed second round is an equivalent alternative.
2. Rateless symbols form one contiguous prefix beginning at index zero. Reorder is tolerated only inside a bounded window and cells enter the decoder strictly in generation order.
3. Decode success requires a zero-residual, unique-polarity, local-membership, byte-exact re-encoding certificate. Partial peel never emits an offer or request.
4. `K_os_master`, `K_os_id`, `K_os_map`, and `K_os_check` are independent domains. Mapping and purity checks are session-keyed; coded-symbol caches never cross links.
5. Offers and requests carry monotonic attempt numbers. Exact duplicates are idempotent; conflicting reuse aborts; explicit new attempts consume budgets again.
6. Carrier Conformance must freeze a post-handshake exporter context binding protocol, carrier, transcript, both role-canonical identity/device certificate digests, and a fresh session nonce. No early exporter or traffic-key fallback is allowed.
7. Round validity uses a negotiated duration and local monotonic deadlines rather than a peer absolute wall clock.
8. Work accounting covers snapshot construction, encoding, reordering, decode certification, fallback, and exact-fetch parsing, with per-link, per-device, and process-global limits.

**Rev3 changelog (retained):**
1. Every reconciliation round binds **both** immutable snapshots in one role-canonical `round_binding_digest`. Rev13 supersedes the old live-generation abort rule; binding, policy, trust, and retained-evidence mismatch still abort at every phase.
2. `OpenRound` / `AcceptRound` establish initiator and responder snapshot descriptors before any symbol is accepted.
3. Every symbol, page, status, request, and abort is bound to the established round; cross-snapshot mixing is fail-closed.
4. Exact fetch has independent object-count, single-object, cumulative-byte, and in-flight-byte budgets; explicit new retry attempts consume budget again while byte-identical transport duplicates are idempotent.
5. Abuse backoff is keyed by authenticated `(identity, device)` and survives reconnect, process restart, address changes, and new session nonces.
6. Privacy honesty now states that an authenticated peer can test membership for an endpoint object whose exact bytes it already knows.

**Rev2 changelog (retained):**
1. Opaque fetch: `RequestByInventoryId` — missing peer never inverts HMAC; owner resolves and `send_exact`s.
2. Polarized IBLT output: `LocalOnly` vs `RemoteOnly` candidates; no “verified difference” before exact fetch.
3. Paged fallback bound to immutable snapshot (`snapshot_id` / generation + page-manifest digest).
4. Same `symbol_index` with different bytes → conflict fail-closed; exact duplicate → no-op.
5. Object Sync key is a **bidirectional**, session-unique, domain-separated subkey (not directional).
6. Estimates use checked arithmetic + local clamp; deterministic **work-unit** budget alongside wall time.
7. Exact fetch re-checks contact / revocation / eligibility per object.
8. Object Sync frames are **authenticated-session-local**: only the two authenticated session endpoints may parse or act on them. Rev7 permits opaque ciphertext carriage by a Circuit Relay, but forbids relay termination, cross-session forwarding, and store-and-forward custody of `RVOS*`.

---

## 0. Normative language

The key words MUST, MUST NOT, SHOULD, MAY are as in RFC 2119.

---

## 1. Purpose and exit criterion

### 1.1 Purpose

Two devices that already share an **authenticated** carrier session need to discover which peer-eligible endpoint objects the other is missing, using bandwidth proportional to the **set difference**, not the full inventory size — especially on BLE and constrained LAN.

### 1.2 Exit criterion (done when)

One round has exactly one **decoder**: the initiator. After a successful round:

1. The initiator has a fully certified polarized decode result for difference sizes in `{0, 1, 100, 10_000}`:
   - `LocalOnly(inventory_id)` resolved against the **local** preimage map;
   - `RemoteOnly(inventory_id)` held only as **bounded untrusted candidates**.
2. For each wanted `RemoteOnly`, the initiator emits `RequestByInventoryId`; the responder maps ID→digest and performs `send_exact(object_digest)`.
3. For each `LocalOnly` the initiator is willing to disclose, it emits `OfferByInventoryId`; the responder treats the ID only as a bounded candidate and MAY answer with `RequestByInventoryId` bound to the initiator snapshot. A second role-reversed round MAY replace this offer path.
4. After exact `carrier_record_bytes` arrive, the receiver recomputes `object_digest` and `inventory_id` and only then MAY admit under store rules.
5. No local store mutation, admission, or deletion occurs from symbols, pages, offers, or requests alone.
6. A partial, false, or uncertified decode MUST emit no offer/request and leave durable inventory state unchanged.
7. Both accepted snapshot descriptors and their frozen evidence remain byte-identical through the final exact-fetch decision. Live-store generation may advance at any phase without rewriting or invalidating them; trust/policy drift and evidence loss remain fail-closed.

### 1.3 Non-goals (V1)

- Replacing endpoint E2EE, PairInit, or Session V2.
- Syncing strangers / unauthenticated discovery ads.
- Global mesh flood of inventories.
- Custody receipts, Key Transparency, Social DAG event semantics (later companions).
- Implementing Rateless IBLT as a production library in this design revision (vectors + lab only until APPROVED).
- Production implementation and carrier activation. Revision 13 is the current candidate for shared-vector review, but no implementation is authorized until the vector plan and independent review pass.
- Proving that an authenticated malicious peer disclosed its complete true set. V1 provides exact-admission safety and bounded work, not Byzantine completeness.

---

## 2. Threat model

### 2.1 Goals

| Goal | Meaning |
|------|---------|
| Difference-sized cost | Communication scales with set difference under honest peers |
| Link privacy | Wire inventory MUST NOT carry raw `object_digest` |
| Opaque fetch | Peers missing an object never need its digest to request it |
| Opacity | Sync frames are `carrier_control_bytes` only; endpoint objects stay opaque |
| Fail-closed decode | Malicious / truncated / conflicting symbols MUST NOT mutate inventory |
| Bounded resources | Hard caps on symbols, CPU work-units, memory, and decode attempts |
| Explicit fallback | When rateless path is unsafe or exhausted → snapshot-bound paged inventory |
| Session locality | Control semantics and exact frame bytes remain inside one end-to-end authenticated session; only its two endpoints parse or act on them |

### 2.2 Non-goals

- Hiding inventory **cardinality** or timing from the authenticated peer.
- Hiding object sizes once exact records are transferred.
- Hiding membership of a guessed/known endpoint object from the authenticated peer; that peer knows `K_os_id` and can derive its link-local ID from known exact bytes.
- Byzantine agreement on “who has what” across the whole mesh.
- Treating inventory ACK as Delivered / endpoint ACK (umbrella §7).

### 2.3 Adversaries

Network drop / reorder / duplicate / inject on the carrier; compromised peer that already passed link auth; malicious symbol streams (DoS or forged IDs); same-index conflicting symbols; mid-round inventory mutation; relay/bridge/mailbox operators attempting to terminate, inspect, transplant, or persist Object Sync control.

V1 distinguishes two adversaries:

| Adversary | Guarantee |
|-----------|-----------|
| Untrusted object author without the authenticated session key | Session-keyed mapping and purity checks are intended to make targeted algebraic cancellation computationally infeasible. |
| Malicious authenticated peer that knows the session key | Can omit real items, lie about its set, force fallback, or terminate a round. Raven promises no completeness against it; exact fetch prevents false durable admission and caps/backoff bound resource use. |

---

## 3. Placement in the Raven object model

| Layer | Role in Object Sync |
|-------|---------------------|
| `endpoint_object_bytes` | **Untouched.** Never opened for endpoint semantics or rewritten by sync; hashed only for exact digest/ID verification after fetch (§9). |
| `carrier_record_bytes` | Delivered only via owner `send_exact` after `RequestByInventoryId`. |
| `carrier_control_bytes` | **Only** layer for Object Sync frames (symbols, pages, requests). |

Sync MUST NOT admit control frames as endpoint objects. Sync MUST NOT key endpoint dedup on wrapper digests.

Logical carrier API (umbrella §5) remains for local/host use:

```text
offer_inventory(authenticated_peer) -> digests          # local view
request_missing(object_digests) -> Result               # host-internal after ID resolve
send_exact(object_digest) -> Result
```

Wire inventory uses **link-scoped IDs** (§5). Wire fetch uses **`RequestByInventoryId`** (§9). Local APIs may still speak `object_digest`; the mapping is hop-local and never written into `endpoint_object_bytes`.

---

## 4. Prerequisites

Object Sync V1 MAY run only when **all** hold:

1. Carrier session is **authenticated** (Noise / device-bound session as required by the carrier companion).
2. Peer is **inventory-eligible** (contact / capability policy already decided by higher layers).
3. Local store can enumerate a **bounded**, peer-eligible digest set into an **immutable round snapshot** (§7).
4. Production / Release Object Sync flag is **off** until this companion is APPROVED.
5. Both peers support exactly the frozen Object Sync version and algebra profile in §8. `OpenRound` proposes one profile and `AcceptRound` repeats that exact profile; a mismatch rejects the round. There is no legacy/raw-digest negotiation fallback.
6. The carrier exposes `RavenAuthenticatedLinkExporterV1` only after the authenticated handshake is complete and supplies the role-canonical inputs required by §5.2. Missing, early, ambiguous, or reused exporter context disables Object Sync.

Unauthenticated links MUST NOT emit or accept Object Sync frames.

Both peers MUST be able to freeze their local eligible set. A carrier that can freeze only the offering side MUST NOT run Rateless Object Sync; it MAY use an independently approved bounded fallback that does not claim symmetric-difference reconciliation.

---

## 5. Link-scoped inventory identifiers and sync key

### 5.1 Why not raw digests

Raw `object_digest = SHA-256(endpoint_object_bytes)` on inventory wires would let any authenticated peer correlate the same object across unrelated links. V1 binds membership tokens to the **current authenticated link**.

### 5.2 Bidirectional Object Sync key schedule

Directional traffic keys MUST NOT be used for reconciliation: both peers must derive the **same** `inventory_id` for the same `object_digest`.

Object Sync freezes the carrier-independent exporter call. Carrier Conformance MUST map each approved authenticated handshake to this interface without changing any byte below:

```text
RavenAuthenticatedLinkExporterV1(label_ascii, exact_context, output_len)

RVLX1 ObjectSyncExporterContextV1:
  offset  size  field
  0       5     magic = ASCII "RVLX1"
  5       1     schema_rev = 1
  6       2     object_sync_profile_u16be = 1
  8       2     total_len_u16be
  10      1     carrier_profile_len (1..63)
  11      1     handshake_profile_len (1..63)
  12      4     reserved = zero
  16      32    authenticated_handshake_transcript_digest
  48      32    initiator_identity_device_certificate_digest
  80      32    responder_identity_device_certificate_digest
  112     32    session_unique_nonce
  144     c     carrier_profile ASCII bytes
  144+c   h     handshake_profile ASCII bytes

total_len = 144 + c + h, therefore 146..270 bytes. Printable ASCII is
0x21..0x7e; NUL, slash-normalization, Unicode, aliases, and trailing bytes
are forbidden. Initiator/responder are handshake roles, never local/remote.

K_os_master = RavenAuthenticatedLinkExporterV1(
  label   = "EXPORTER-raven-object-sync-v1",
  context = exact RVLX1 bytes,
  length  = 32
)

context_digest = SHA-256(exact RVLX1 bytes)
K_os_prk   = HKDF-Extract-SHA256(salt = 32 zero bytes, ikm = K_os_master)
K_os_id    = HKDF-Expand-SHA256(K_os_prk,
                 u16be(26) || "rvn1/object-sync/id-key/v1" || context_digest, 32)
K_os_map   = HKDF-Expand-SHA256(K_os_prk,
                 u16be(27) || "rvn1/object-sync/map-key/v1" || context_digest, 32)
K_os_check = HKDF-Expand-SHA256(K_os_prk,
                 u16be(29) || "rvn1/object-sync/check-key/v1" || context_digest, 32)
```

The label lengths above count the exact ASCII bytes and are independently checked by vector generation. An implementation MUST NOT use a C-string terminator or infer a label length. Any future correction requires a new profile identifier, never reinterpretation.

Carrier Conformance later freezes how Noise LAN, libp2p Noise, TLS 1.3/QUIC, relay-carried sessions, and any future handshake provide `RavenAuthenticatedLinkExporterV1`, `transcript_digest`, profile strings, certificates, and the session nonce. That provider proof is required before enabling Object Sync on that carrier, but Object Sync approval no longer waits for a carrier document to redefine its KDF. TLS/QUIC MUST use the regular post-handshake exporter master secret; early/0-RTT exporters, generic traffic keys, directional message keys, resumption PSKs, and unauthenticated `link_id` values are forbidden substitutes.

| Rule | Normative |
|------|-----------|
| Direction | All four keys are **shared bidirectional** — identical at both ends for the session |
| Uniqueness | `session_unique_nonce` is 32 bytes, MUST be handshake-bound, MUST change per authenticated session, and MUST NOT reuse across links or resumptions |
| Context | Role, certificate, transcript, carrier, version, and nonce changes MUST produce a different `K_os_master` |
| Lifetime | Wipe all four keys when the link closes; never persist across re-auth without a new nonce |
| Non-use | These keys MUST NOT encrypt endpoint objects and MUST NOT be replaced with a Noise/TLS directional traffic key |
| Cache | Encoders, coded cells, mapping state, and purity checks keyed by these values MUST NOT be reused on another link/session |

`K_os_master`, the PRK, and all three subkeys are secret ephemeral state and MUST be zeroized on abort/close. Shared vectors freeze the exporter-independent KDF from supplied `K_os_master` and `RVLX1`; per-carrier vectors freeze the provider call.

### 5.3 `inventory_id` definition

```text
inventory_id = HMAC-SHA256(
  K_os_id,
  "rvn1/object-sync/id/v1" || object_digest
)[:16]
```

| Rule | Normative |
|------|-----------|
| Length | 16 bytes on the wire |
| Invertibility | **Not invertible.** A peer without `object_digest` cannot recover it from `inventory_id` |
| Scope | Valid only for this `K_os_id` |
| Collision | Ambiguous in both IBLT and pages because both use the same 16-byte ID; abort the entire round fail-closed — paged fallback is forbidden for that snapshot |
| Zero value | An all-zero 16-byte result is reserved for algebra empty state; a local snapshot containing it aborts before Open/Accept, and a recovered zero ID fails certification |
| Export | MUST NOT appear in ads, Bonjour TXT, or stranger BLE payloads |

### 5.4 Local maps (owner side)

Each peer maintains, for the **active round snapshot** only:

```text
inventory_id -> object_digest     # only for digests in this peer's snapshot
object_digest -> inventory_id
```

Maps MUST be derived from the frozen snapshot (§7). Maps MUST be wiped when the round ends or the link closes. Maps MUST NOT be treated as global identity.

Before emitting its snapshot descriptor (`OpenRound` for the initiator, `AcceptRound` for the responder), each side MUST detect whether two distinct local digests truncate to the same `inventory_id`. Any such ambiguity aborts the whole snapshot before symbols/pages are sent.

**Critical:** A peer that does **not** hold an object has **no** local preimage for that object’s `inventory_id`. Fetch MUST use §9, not local inversion.

### 5.5 Algebra key separation

The frozen Rateless IBLT profile MUST derive every placement/tap decision from `K_os_map` and every purity/checksum value from `K_os_check`. It MUST NOT reuse `K_os_id` for either purpose. Public, process-global, snapshot-global, or cross-session mapping/checksum seeds are forbidden.

The same immutable inventory may therefore be encoded differently on every authenticated session. Implementations MUST NOT cache a universal coded-symbol stream. A pinned artifact may be used as an oracle only after Raven supplies the session-keyed mapping/checksum contract through a strict bounded wrapper or audited port.

---

## 6. Rateless IBLT profile (design)

### 6.1 Conceptual model

Each peer freezes eligible set `S` of `inventory_id` values into a round snapshot. One **initiator/decoder** opens a pull-oriented round and one **responder/encoder** streams the deterministic coded-symbol prefix until the initiator certifies a complete decode, fails closed, or falls back to pages. One stream has one decoder; symmetric object transfer is completed through receiver-controlled offers/requests or a second role-reversed round.

V1 does **not** copy Ethereum wiring from the paper. It freezes Raven-specific:

- element type = `inventory_id` (16 B);
- rateless symbol stream with deterministic contiguous index `u32`, beginning at zero;
- peel decoder with bounded iterations and work-units;
- **polarized** peel outputs (§6.5);
- explicit failure → snapshot-bound paged fallback.

The role-canonical signed difference is:

```text
DifferenceCell[i] = Encode(ResponderSnapshot)[i] - Encode(InitiatorSnapshot)[i]
```

Under the frozen XOR/signed-count cell algebra, positive polarity is `RemoteOnly` from the initiator/decoder's view (responder only) and negative polarity is `LocalOnly` (initiator only). Neither endpoint may reinterpret polarity using local/remote naming at runtime.

#### 6.1.1 Implementation and source pin

The normative profile is a small Raven-owned strict port derived from the MIT-licensed research artifact at commit [`4afa6bc06cb2237d9ea273a51d97a7e05b3f573b`](https://github.com/yangl1996/riblt/tree/4afa6bc06cb2237d9ea273a51d97a7e05b3f573b). Raven MUST retain its copyright/license notice and a source-to-source audit map for `symbol.go`, `mapping.go`, `encoder.go`, and `decoder.go`.

The Go artifact is a **non-normative oracle**, not a dependency and never a parser for carrier bytes. Its README limits the deployment claim to trusted workloads, its mapping uses ambient binary64 `sqrt`, and one `Hash` value drives both placement and purity. Raven therefore freezes the same rateless construction with three intentional, reviewable hardenings:

1. strict parse/reorder/cap admission before the port;
2. independent `K_os_map` and `K_os_check` taps; and
3. an exact integer form of the artifact's inverse-CDF skip equation.

There is no algorithm fallback. A different RIBLT library, float implementation, public checksum, or classic fixed-size IBLT requires a new algebra profile ID.

#### 6.1.2 Source element and keyed taps

```text
map_seed_u64 = u64be(HMAC-SHA256(
  K_os_map,
  "rvn1/object-sync/map/v1" || inventory_id
)[0..8])

check_tag = HMAC-SHA256(
  K_os_check,
  "rvn1/object-sync/check/v1" || inventory_id
)[0..16]
```

`map_seed_u64` and `check_tag` are recomputed from the immutable snapshot map; they are never accepted from the peer. A 16-byte check tag is used instead of the artifact's 64-bit checksum. This does not promise completeness against a malicious authenticated peer that knows the link keys; it prevents unauthenticated/public precomputation and makes accidental/forged purity acceptance negligible before exact fetch.

#### 6.1.3 Exact mapping sequence (no floating point)

Each source element maps first to cell zero. Its per-element state is `(prng_u64=map_seed_u64, last_index_u64=0)`. After applying the element to `last_index`, compute the next index exactly:

```text
M = 0xda942042e4dd58b5
prng = (prng * M) mod 2^64
q = u128(prng) + 1                         # 1..2^64
A = 2 * u128(last_index) + 3
T = (A * A) << 64
target = ceil_div(T, q)
x = ceil_sqrt_u128(target)                 # smallest x with x*x >= target
delta = max(1, ceil_div(max(x - A, 0), 2))
last_index = checked_add(last_index, delta)
```

`ceil_div` and `ceil_sqrt_u128` are integer operations with checked intermediates. Mapping stops once `last_index >= effective_symbol_cap`; a value above `u32::MAX`, arithmetic failure, or non-increasing index is a typed algebra failure with no candidate output. This equation is the exact real-number form approximated by the pinned artifact; the `max(1, …)` removes its rare binary64 zero-step edge. Python/Rust and Swift-through-Rust FFI MUST compute the same mapping bytes on portable, x86_64, and arm64 vectors.

#### 6.1.4 Coded cell

`RavenRibltCellV1` is exactly 40 bytes:

```text
offset  size  field
0       16    id_xor
16      16    check_xor
32      8     count_i64be
```

Adding a responder/remote symbol XORs `inventory_id` into `id_xor`, XORs `check_tag` into `check_xor`, and checked-adds `+1`. Subtracting the initiator/local symbol applies the same XORs and checked-adds `-1`. Encoder output is therefore `ResponderSnapshot - InitiatorSnapshot`.

A cell is peelable only when:

```text
count == +1 or -1: check_xor == check_tag(id_xor)
count == 0:        id_xor == 0^16 and check_xor == 0^16
otherwise:         not peelable
```

All comparison is constant-time where it handles keyed check bytes. Signed-count overflow, a recovered all-zero `inventory_id`, duplicate recovery, or the same ID in both polarities is fail-closed. The decoder never exposes a candidate until the full §6.6 certificate succeeds.

### 6.2 Round state machine

```text
Idle
  → initiator freezes InitiatorSnapshot
  → OpenRound(round_id, InitiatorSnapshot, round_ttl_ms, caps, profile_id)
  → responder freezes ResponderSnapshot
  → AcceptRound(round_id, InitiatorSnapshot, ResponderSnapshot,
                round_binding_digest, effective_caps)
  → StreamSymbols (ordered prefix 0..m)
  → DecodeAttempt on contiguous prefix [0, m) (bounded)
      → PolarizedCandidates
           LocalOnly  → must resolve in local snapshot map (else fail-closed)
           RemoteOnly → untrusted candidates only
      → DecodeCertificate (§6.6)
      → CertifiedTransfer barrier (freeze exact candidate lists/transcript)
      → RequestByInventoryId* (for wanted RemoteOnly)
      → OfferByInventoryId* → responder-selected RequestByInventoryId*
      → ExactFetchVerify → Idle
      → NeedMoreSymbols → StreamSymbols (if under caps)
      → FailClosed / FallbackPaged
```

| Rule | Normative |
|------|-----------|
| `round_id` | 16 nonzero bytes from the platform CSPRNG per round; binds all symbols and requests; MUST NOT repeat on the authenticated session. RNG failure or a detected collision refuses the round before Open—no deterministic/time fallback |
| Snapshot pair | The initiator and responder descriptors in §7.1 are both immutable and role-canonical; `local` / `remote` ordering MUST NOT be used in their encoding |
| Acceptance barrier | No symbol/page/request is accepted before both peers have verified the same `round_binding_digest` |
| Round duration | `round_ttl_ms` is negotiated and bound into the round; each endpoint starts a local monotonic deadline. Peer wall clocks are not consulted for round validity |
| No cross-round/snapshot mix | A frame with another `round_id` or `round_binding_digest` MUST be ignored; a frame with the active identifiers but inconsistent snapshot fields is a conflict and aborts the round |
| Live-store churn while Reconciling | Admissions, arrivals, expiry, or deletion MAY advance the live generation but MUST NOT rewrite/refresh/invalidate the retained encoder, decoder, map, descriptor, or manifest. New objects wait for a later round; missing snapshot objects may still certify algebraically but become unavailable at exact fetch |
| Trust/policy/evidence drift | Contact, revocation, capability/eligibility-policy drift, loss/corruption of immutable snapshot evidence, or binding mismatch aborts at every phase. A live generation number change alone is never evidence of any of these conditions |
| CertifiedTransfer barrier | Certification freezes the exact polarity-tagged candidate lists, prefix/manifest evidence, maps, and attempt state for transfer. Rateless certification includes reconstruction of the responder set and exact comparison to its accepted descriptor (§6.6). The barrier controls candidate release, not snapshot lifetime; the snapshot was already immutable from Open/Accept |
| Live-store churn while transferring | Live generation advancement does not abort. Owner-side fetch still requires the exact object in the frozen owner snapshot and a current authorized/available record. Missing/deleted/expired/ineligible objects return the indistinguishable unavailable outcome |
| No mutation on Open/Stream/Decode | Local inventory durable state unchanged |
| Language ban | MUST NOT call decode output a **“verified difference”** before exact-fetch verification |
| After certificate | Only a certified result may produce `OfferByInventoryId` / `RequestByInventoryId`; only exact verification admits objects |

Each authenticated session retains every accepted/emitted `round_id` and both role-canonical `snapshot_id` values until that session closes:

```text
OBJECT_SYNC_MAX_ROUNDS_PER_AUTH_SESSION = 1024
```

The seen set is non-evicting and counts toward retained-byte/global supervisors. A repeated round/snapshot ID is a severe replay conflict before snapshot freeze. At 1024 rounds, Object Sync refuses further Open/Accept on that session until a fresh authenticated session with a new RVLX1 context is established; ordinary endpoint-object delivery remains available. Round-expiry tombstones may discard bulky replay evidence, but this compact ID seen set persists for the full authenticated-session lifetime.

Implementations retain both (a) immutable original remote cells and their local-subtracted difference prefix and (b) a separate mutable candidate decoder. `TryDecode`/peeling mutates only the candidate. `NeedMore` may promote bounded candidate decoder progress inside the ephemeral round, but it releases no IDs. The §6.6 re-encoder compares against the immutable original difference prefix, never the already peeled cells. Both representations and every recovered candidate count against per-round and process-global retained-byte caps.

### 6.3 Caps, estimates, and work-units (hard)

Implementations MUST enforce **all** of the following per round (defaults; carriers MAY tighten, MUST NOT loosen past absolute maxima):

| Cap | Default | Absolute max |
|-----|---------|--------------|
| Symbols received | `checked_mul_add(expected_diff_estimate, 2, 64)` then clamp; if unknown → 4096 | 65_536 |
| Symbols retained in memory | same as received | 65_536 |
| Decode attempts | 8 | 32 |
| Peel iterations per attempt | 100_000 | 1_000_000 |
| **Work-units** per round | carrier default (e.g. 2×10^7 peel-cell ops) | finite, mandatory |
| Control bytes initiator→responder | 8 MiB | 64 MiB per round |
| Control bytes responder→initiator | 8 MiB | 64 MiB per round |
| Wall-time budget | carrier policy | MUST be finite |
| Eligible set size in snapshot | 10_000 | 100_000 |
| RemoteOnly candidates retained | 10_000 | 100_000 |
| Opaque fetch IDs requested | 64 | 10_000 per round; ≤64 per control frame |
| Single exact endpoint object | carrier policy | ≤24 MiB and never above that carrier's approved endpoint-object ceiling |
| Cumulative exact bytes attempted | 8 MiB | 64 MiB per round |
| Concurrent exact bytes buffered/in flight | 1 MiB | 24 MiB per link; carrier MAY require a smaller single-object ceiling |
| Concurrent rounds per link | 1 | 1 |
| Negotiated round TTL | 120_000 ms | 600_000 ms |
| Reorder window | 64 symbols | 1_024 symbols and never above remaining symbol cap |
| Per-device concurrent rounds across links | 1 | 2 |
| Process-global active rounds | 16 | 64 |
| Process-global retained coded cells | 65_536 | 262_144 |
| Process-global retained Object Sync bytes | 16 MiB | 64 MiB |
| Process-global live work-units | 20_000_000 | 100_000_000 |

| Estimate rule | Normative |
|---------------|-----------|
| Checked arithmetic | All estimate→cap transforms MUST use checked add/mul; on overflow → treat estimate as unknown and use the unknown default, then clamp |
| Local clamp | After transform, clamp into `[0, absolute_max]` locally; never trust peer-supplied caps above local policy |
| Work-units | Snapshot enumeration, ID derivation, collision detection, sorting/manifest creation, encoder construction, coded-symbol generation, local subtraction, parsing, reorder insertion, peel/hash operations, completion re-encoding, page assembly, exact-fetch parsing, and failed opens MUST debit deterministic work units. Exhaustion in any phase is a cap hit |
| Exact-byte debit | The owner MUST know the exact carrier-record length and reserve object-count, cumulative-attempt, and in-flight budgets **before** enqueue. Checked-add overflow is a cap hit. The first acceptance of attempt zero and each exact `last+1` `fetch_attempt` debit the planned record bytes exactly once. A byte-identical replay/transport retry of that same attempt reuses its recorded outcome and MUST NOT enqueue or debit again. A later exact-next attempt debits again. Successful or failed completion releases only the in-flight reservation; the cumulative debit is never refunded. |
| Peer offer | Peer-advertised budgets may only tighten local limits. Missing, malformed, or larger values never enlarge local policy. |
| Scope | Limits apply per round and per link; authenticated-device and process-global supervisors additionally bound concurrent rounds, retained cells/candidates, exact-fetch bytes, and work across reconnects/carriers |

If any cap would be exceeded: **stop streaming**, discard polarized candidates for that round, and either open **paged fallback** or abort with a typed control error.

The 80-byte `RavenObjectSyncCapsV1` wire record contains only negotiable per-round limits, in this exact order:

```text
max_symbols_u32
max_retained_symbols_u32
max_decode_attempts_u32
max_peel_iterations_per_attempt_u32
max_work_units_u64
max_control_bytes_i2r_u64
max_control_bytes_r2i_u64
max_eligible_items_u32
max_candidates_u32
max_fetch_ids_total_u32
max_fetch_ids_per_frame_u16
max_page_ids_u16
max_single_object_bytes_u32
max_cumulative_exact_bytes_u64
max_inflight_exact_bytes_u32
round_ttl_ms_u32
reorder_window_u32
```

All values are big-endian and nonzero. `AcceptRound.effective_caps` is the component-wise minimum of both endpoints' local offers, carrier limits, defaults/policy, and the absolute maxima above. For a limit where a smaller value is stricter, `AcceptRound` MUST NOT contain a value larger than `OpenRound`. Both endpoints reject unless all cross-field invariants hold:

```text
max_retained_symbols <= max_symbols
max_fetch_ids_per_frame <= 64
max_fetch_ids_per_frame <= max_fetch_ids_total
max_page_ids <= 256
max_single_object_bytes <= max_inflight_exact_bytes
max_inflight_exact_bytes <= max_cumulative_exact_bytes
reorder_window < max_symbols
max_control_bytes_i2r >= 549   # OpenRound + one DecodeStatus + one min Offer/Request
max_control_bytes_r2i >= 530   # AcceptRound + one Symbol
round_ttl_ms >= 5_000
OpenRound.initiator_descriptor.eligible_count <= proposed_caps.max_eligible_items
AcceptRound.initiator_descriptor.eligible_count <= effective_caps.max_eligible_items
AcceptRound.responder_descriptor.eligible_count <= effective_caps.max_eligible_items
```

The accepted initiator descriptor in `AcceptRound` must be byte-identical to `OpenRound`. Each local endpoint MUST recompute its own descriptor—including `eligible_count` and `page_manifest_digest`—from the retained immutable sorted ID snapshot before emitting Open/Accept and before any encoder/page allocation. A descriptor/count/cap mismatch fails the round before allocation; a peer descriptor is never used as a trusted allocation size.

Directional control-byte accounting is role-canonical, never local/remote. The initiator's Open proposal supplies its local I2R-send and R2I-receive ceilings. The responder computes effective I2R as the minimum of the initiator proposal, responder receive policy, carrier policy, default/policy, and absolute maximum; effective R2I analogously combines initiator receive and responder send policy. Both exact Open and Accept bytes count toward the accepted round's directional counters. Before an Accept exists, Open/Reject traffic is bounded per authenticated session by:

```text
OBJECT_SYNC_PREACCEPT_MAX_CONTROL_BYTES  = 65_536
OBJECT_SYNC_PREACCEPT_MAX_CONTROL_FRAMES = 64
```

The receiver reserves the declared `frame_len` after the fixed 12-byte prefix and before reading the remainder. The sender reserves the exact frame length before enqueue. A failed send/read never refunds the corresponding control-byte/frame debit. Exceeding the pre-accept supervisor disables Object Sync on that session and charges abuse accounting; it does not close ordinary endpoint delivery unless the carrier independently requires it.

For an accepted round, every actual send and every received frame—including exact duplicates, stale frames, rejects inside an active round, and replayed Symbol outputs—debits the applicable directional control-byte counter. Sending or receiving bytes beyond the effective directional cap aborts/fails closed before enqueue or remaining-body read. Control-byte debit is separate from retained-memory, deterministic-work, and exact-object-byte supervisors; no one budget substitutes for another.

The process-global retained-byte supervisor includes canonical snapshot IDs/digests, preimage maps, encoder queues, immutable original/difference cell prefixes, reorder buffers, mutable candidate decoder state, recovered candidates, exact replay control bytes, page assembly, pending attempt outcomes, and exact-transfer binding metadata. It excludes endpoint-record bytes already charged to the separate in-flight exact-byte supervisor. Container capacity is reserved from checked worst-case serialized/allocation estimates before insertion; runtime allocator overhead may only tighten policy.

Deterministic work-unit debits are frozen so implementations cannot hide expensive retries behind a wall-clock-only limit:

| Event | Units |
|---|---:|
| Parse/control bytes | `ceil(frame_len / 64)` |
| Emit/replay control bytes | `ceil(frame_len / 64)` per actual frame enqueue attempt, including exact replay |
| Enumerate and authorize one eligible object | 8 |
| Derive one inventory ID + map/check taps | 8 |
| One snapshot sort comparison | 1 |
| Apply one source symbol to one coded cell | 1 |
| Insert/drain one retained reorder cell | 2 |
| Test or peel one decoder cell | 1 |
| Apply one recovered symbol during peel | 1 per affected cell |
| Re-encode one source-to-cell application | 1 |
| Certificate compare | `ceil(compared_bytes / 32)` |
| Page ID encoded/parsed | 2 |
| Exact record verification | `8 + ceil(record_len / 1024)` |

Each phase reserves its checked worst-case units before allocating or mutating candidate decoder state, then returns unused reservation locally. A peer-supplied estimate never reserves beyond the effective cap. Wall-time cancellation remains mandatory as a second bound, but elapsed time never changes deterministic vector outcomes.

### 6.4 Loss / reorder / duplicate / conflict

Symbols are identified by `(round_id, symbol_index)`, but decoder semantics are defined only for a contiguous prefix.

All retryable control barriers use one deterministic schedule:

```text
CONTROL_MAX_RETRANSMISSIONS_PER_IDENTITY = 3   # after first output
control_retry_interval_ms = clamp(
  floor(bound_round_ttl_ms / 8),
  500,
  10_000
)
```

For the initial Open barrier, `bound_round_ttl_ms` is the valid proposed TTL; after Accept it is the effective TTL. Retry counters include both timer-driven retransmission and peer-triggered exact replay of the same output identity, so duplicate input cannot bypass the limit. Each identity permits the first output plus at most three byte-identical output replays. Every replay atomically reserves the whole output set's directional control bytes and deterministic work before enqueue; failed reservation or output never refunds, partially enqueues, or advances state.

Output replay counters are keyed role-canonically and exactly as:

```text
(round_id, "open")
(round_id, "open_response")
(round_id, "symbol_prefix", prefix_len_u32)
(round_id, "decode_status", status_u8, prefix_len_u32)
(round_id, "page_offer", offering_role_u8, snapshot_id, page_index_u32)
(round_id, "page_ack", offering_role_u8, snapshot_id, page_index_u32)
(round_id, "offer", owner_role_u8, offer_attempt_u32)
(round_id, "request", requester_role_u8, owner_role_u8, fetch_attempt_u32)
```

These counters and exact output evidence are bounded round state, count toward retained memory, never use local/remote naming, and are wiped at round/session close under the existing compact seen-ID rule. Small outputs retain exact bytes; Symbol/Page outputs may retain the exact deterministic regeneration evidence permitted by §8.5 plus `(frame_len, SHA-256(exact frame))`. Same bytes reached through two causes (timer plus duplicate input) consume the same counter.

The retryable barriers are:

| Barrier | Deterministic replay behavior |
|---|---|
| Open → Accept/Reject | Initiator retains exact Open and retries it while no response exists. Responder retains exact Accept or Reject in bounded round state before first output. Exact duplicate Open replays that response; if it is an Accept and the round is still Reconciling, the same atomic replay MUST include the exact current Symbol prefix and consumes both response/prefix replay counters. The complete response+prefix set is reserved before any enqueue; failure emits none. After terminalization it replays only the cached response. |
| Symbol prefix → DecodeStatus | Both roles derive the same current target. If initiator lacks the complete contiguous target at the retry deadline, it emits/replays same-target NeedMore. After first output or extension, responder waits for a state-valid DecodeStatus and timer-replays the exact current prefix if needed. Once initiator has emitted NeedMore/Certified/PagedFallback for target `p`, receiving an exact duplicate of Symbol index `p-1` replays that exact status (subject to its replay counter), closing lost-status windows without another decode/state advance. |
| PageOffer → PageAck | Uses the stop-and-wait rules in §7.2 with the same common interval/counter. |
| OfferByInventoryId → RequestByInventoryId | Initiator retains/retries the exact Offer while no matching selection exists. If responder already recorded a selection, an exact duplicate Offer replays the exact same Request; it MUST NOT choose again, widen IDs, or debit a new fetch attempt. |
| RequestByInventoryId → exact-delivery outcome | Requester retains/retries the exact Request while no matching record/outcome exists. Owner exact-duplicate handling reuses the recorded unavailable result or existing exact carrier-delivery job and MUST NOT enqueue/debit the endpoint object again. Carrier-record retransmission remains the exact-object job's responsibility and does not mint Object Sync success. |

On the fourth requested retransmission, barrier deadline, round deadline, or cap exhaustion, the barrier terminates/falls back exactly as its state permits. An exact late response accepted before terminalization cancels the timer. All clocks are explicit local monotonic inputs; ambient wall time is forbidden.

| Arrival | Rule |
|---------|------|
| Exact duplicate (same index, **identical** bytes) | No-op |
| Same `symbol_index`, **different** bytes | **Conflict** → fail-closed: abort round; MUST NOT decode further; MUST NOT mutate |
| Next contiguous index | Feed exactly once to the decoder, then drain consecutive buffered cells in increasing index order |
| Gap / bounded reorder | Retain only when `symbol_index <= next_contiguous_index + effective_reorder_window`; wait for the missing prefix cell or fallback |
| Sparse / high index | Reject before allocation when `symbol_index >= effective_symbol_cap` or outside the reorder window; debit parse/byte/abuse budgets |
| Unknown `round_id` | Ignore |
| Inventory commit by arrival order | Forbidden |

Every received frame, including exact duplicates and frames rejected before retention, debits link byte/parse/abuse accounting. Only a first valid cell at an allowed index debits retained-symbol count. Decode attempts consume only `[0, next_contiguous_index)`; a sparse set is never treated as a rateless prefix.

### 6.5 Polarized decode output (P0)

IBLT peel MUST emit **signed / polarized** membership deltas, not a flat ID set:

```text
LocalOnly(inventory_id)    # in local snapshot S, absent from peer set
RemoteOnly(inventory_id)   # claimed in peer set, absent from local snapshot S
```

| Class | Normative handling |
|-------|--------------------|
| `LocalOnly` | MUST resolve in the **local** snapshot preimage map. Failure → fail-closed. After §6.6 certification, a bounded subset MAY be disclosed through `OfferByInventoryId` |
| `RemoteOnly` | **Cannot** exist in the local preimage map by definition. Retain as a **bounded untrusted candidate** only. MUST NOT be called verified. MUST NOT trigger local digest lookup. Fetch only via §9 |
| Unknown polarity / ambiguous | Fail-closed |

Rev1’s rule that “IDs not in the local preimage map are malicious” is **superseded** for `RemoteOnly`. Malicious handling still applies to: checksum failure, peel inconsistency, `LocalOnly` without preimage, symbol conflicts, and RemoteOnly counts above caps.

### 6.6 Decode completion certificate

A peel is successful only when **all** of the following hold:

1. symbol zero and every coded cell in the accepted contiguous prefix are fully reduced;
2. each residual cell has exact zero signed count, zero symbol sum, and zero keyed checksum under the frozen cell layout;
3. recovered inventory IDs are unique and no ID appears in both polarities;
4. every `LocalOnly` resolves to exactly one digest in the initiator's immutable map;
5. every `RemoteOnly` is absent from that local map;
6. the implementation reconstructs the complete responder inventory exactly as
   `ResponderIDs = (InitiatorSnapshotIDs - LocalOnly) union RemoteOnly`, using checked bounded set operations; the result is sorted/unique, has exactly `responder_descriptor.eligible_count` entries, and recomputes the exact accepted `responder_descriptor.page_manifest_digest` from §7.1;
7. the implementation re-encodes the recovered **signed** difference for the same prefix with `K_os_map` / `K_os_check` and byte-compares every computed remote-minus-local coded cell;
8. all reconstruction, manifest, verification, and re-encoding work is successfully debited from the round and supervisor budgets.

Partial peel, a nonzero residual, or a failed re-encode comparison is not success and MUST emit no offer/request. This certificate proves internal transcript consistency only; it does not prove that a malicious authenticated responder disclosed its complete true set.

After all eight checks, the initiator computes:

```text
difference_cells_digest = SHA-256(concat(exact RavenRibltCellV1 prefix))

decode_certificate_digest = SHA-256(
  "rvn1/object-sync/decode-certificate/v1"
  || round_binding_digest
  || u32be(prefix_len)
  || u32be(local_only_count)
  || concat(sort_lex(local_only_inventory_ids))
  || u32be(remote_only_count)
  || concat(sort_lex(remote_only_inventory_ids))
  || difference_cells_digest
)
```

The digest is carried only in `DecodeStatus(Certified)`. It lets the responder bind a stop/replay decision to the exact accepted prefix; it is not an endpoint signature, authorization, or completeness proof.

### 6.7 Malicious / failed decode

On decode failure, conflict, checksum mismatch, `LocalOnly` without preimage, work-unit exhaustion, or exact-fetch budget exhaustion:

1. MUST NOT mutate durable inventory;
2. MUST NOT emit `OfferByInventoryId` or `RequestByInventoryId` for candidates from the failed attempt;
3. MUST end the rateless round;
4. SHOULD fall back to paged inventory at most once per authenticated-peer backoff window; reconnect MUST NOT reset peer-level DoS accounting.

### 6.8 Authenticated-peer abuse accounting

The backoff key is the canonical authenticated tuple encoded exactly as:

```text
canonical_identity_device_key =
  u16be(len(canonical_remote_raven_address_ascii))
  || canonical_remote_raven_address_ascii
  || u16be(len(remote_device_id_utf8))
  || remote_device_id_utf8
```

The Raven address MUST already pass its defining canonical lowercase ASCII codec. `remote_device_id_utf8` is the exact validated certificate/revocation device ID, 1..64 bytes, with no Unicode normalization or alternate spelling. Length overflow, noncanonical address bytes, invalid UTF-8, empty device ID, or conflicting certificate binding denies Object Sync before abuse-record lookup. Local/remote role labels, IP/port, relay peer/address, carrier, and session nonce are not part of this key.

It MUST NOT be keyed only by IP address, relay address, `link_id`, `round_id`, or session nonce. A new transport path or re-authentication by the same device therefore cannot reset accounting.

The host persists, with atomic replace and a dedicated non-reentrant cross-process lease, at least `window_start_ms`, `last_observed_ms`, failure counters by class, and `next_allowed_ms`. This store MUST have a frozen maximum record count, checked/saturating counters, and a legal eviction policy that never evicts an active penalty to admit a new peer. Capacity exhaustion denies new Object Sync rounds. It MUST NOT share the endpoint-ratchet mutation lease.

Backward wall-clock movement MUST NOT shorten a backoff (`effective_now = max(now_ms, last_observed_ms)`). Corruption or unavailable accounting storage disables Object Sync for that peer until explicit repair; it MUST NOT disable ordinary exact message delivery.

The V1 policy is fixed:

```text
ABUSE_MAX_RECORDS                 = 4096
ABUSE_WINDOW_MS                   = 600_000
ABUSE_BLOCK_THRESHOLD             = 8
ABUSE_BASE_BLOCK_MS               = 900_000
ABUSE_MAX_BLOCK_MS                = 86_400_000
ABUSE_SUCCESS_DECAY_INTERVAL_MS   = 3_600_000
```

Weights are 4 for same-identity conflict, checksum/certificate failure, cross-snapshot mixing, or a wrong `link_context_digest` from an authenticated peer; 2 for parse/cap/work exhaustion; and 1 for an ordinary unsuccessful/fallback round. At score ≥8, increment a saturating `block_level` and set `next_allowed_ms = max(previous_next_allowed, effective_now + min(ABUSE_MAX_BLOCK_MS, ABUSE_BASE_BLOCK_MS << min(block_level-1, 6)))` with checked arithmetic. A fully certified round whose exact-fetch transcript has no binding failure MAY subtract one point, at most once per decay interval; it never clears the record.

The store holds at most 4096 records. Active penalties and records referenced by live rounds are non-evictable. To admit a new record, the implementation may evict only an unreferenced record with `next_allowed_ms <= effective_now` and zero score, choosing the smallest `(last_observed_ms, canonical_identity_device_key)`; otherwise the new peer is denied Object Sync. Control bytes, cryptographic keys, inventory IDs, network/socket/relay addresses, and object digests are not stored in abuse records. The canonical authenticated Raven identity/device key is retained because it is the required durable abuse principal.

---

## 7. Snapshot-bound paged inventory fallback

When Rateless IBLT is unavailable, unsafe, or exhausted, peers MAY page one side of the **same immutable snapshot pair** accepted for the round. A fallback MUST NOT freeze a replacement snapshot under the old `round_id`.

### 7.1 Snapshot

Each side freezes a role-canonical descriptor:

```text
RoundSnapshotDescriptorV1 = (
  role_u8,                    # initiator=0, responder=1
  snapshot_id[16],            # fresh nonzero CSPRNG value; not a reusable store identifier
  generation_u64be,           # monotonic eligible-store generation
  eligibility_policy_digest[32],
  eligible_count_u32be,
  page_manifest_digest[32]
)

page_manifest_digest = SHA-256(
  "rvn1/object-sync/page-manifest/v1"
  || role_u8 || snapshot_id || u64be(generation)
  || eligibility_policy_digest || u32be(eligible_count)
  || concat(sorted inventory_id bytes)
)

round_binding_digest = the byte-exact §8.4 construction over the retained
OpenRound, both exact descriptors, effective caps, and profile identifiers
```

`eligibility_policy_digest` binds the exact object-class/contact/capability filter used to construct that snapshot; it is not an authorization token. `effective_caps` is the canonical component-wise minimum of both peers' offers and local protocol maxima. `round_ttl_ms` is a duration bounded by both peers' local policies. Each endpoint records its own monotonic deadline when `AcceptRound` succeeds; synchronized wall clocks are neither assumed nor transmitted as validity authority.

`generation_u64be` comes from the durable eligible-object store, is monotonic without wrap, and survives restart. Missing/corrupt generation evidence, rollback below the last locally accepted generation, or attempted increment at `u64::MAX` disables Object Sync until explicit repair; it never silently resets to zero. Generation is snapshot metadata, not a trust token and not a globally comparable clock between peers.

`snapshot_id` MUST NOT repeat anywhere in the authenticated session, including across roles. RNG failure, all-zero output, or a detected collision refuses snapshot creation before Open/Accept. Time, generation, object digest, device ID, or process counters MUST NOT substitute for CSPRNG bytes. Shared vectors supply explicit fixture IDs and never exercise ambient randomness.

After Open/Accept, the retained snapshot bytes/maps—not the changing live store—are authoritative for reconciliation. A live generation change from admissions, arrivals, expiry, or deletion never aborts rateless or paged reconciliation and never refreshes that snapshot in place. A peer always aborts on policy/contact/revocation drift, a mismatched `round_binding_digest`, loss/corruption of frozen snapshot evidence, or page IDs that do not match the descriptor's manifest. Current owner availability/authorization is rechecked only at exact fetch.

### 7.2 Page frames

The byte-exact `PageOffer` and `PageAck` layouts are frozen in §8.2–§8.3.

| Rule | Normative |
|------|-----------|
| `k` | Exact `effective_caps.max_page_ids`; carrier policy defaults to 64 on BLE and may use up to the absolute 256 on LAN/Internet |
| Completeness | All pages for one snapshot MUST cover exactly `eligible_count` IDs with no duplicates |
| Truncation | Forbidden: the accepted snapshot completes exactly or aborts; requester MUST NOT infer an empty difference from missing pages |
| Same ID scope | Same `inventory_id` / `K_os_id` as IBLT |
| Mutation | Still none until exact fetch verifies |
| Role | `offering_role` selects exactly one of the two accepted descriptors; local/remote reinterpretation is forbidden |
| Mid-round change | Live generation churn never rewrites/aborts the frozen page snapshot; policy/contact/revocation drift or snapshot-evidence loss aborts at every phase; current object availability is deferred to exact fetch |

Paged transfer is strict stop-and-wait with one PageOffer in flight. The responder emits page zero, retains/regenerates its exact bytes, and emits page `i+1` only after accepting the exact `PageAck(i)`. The initiator validates and stores a page before emitting its exact Ack. An exact duplicate PageOffer reuses the recorded Ack without inserting IDs twice. An exact duplicate already-accepted PageAck is a no-op; a future Ack, an Ack for a different snapshot/role, or same-identity different bytes is a conflict. A never-accepted lower/stale Ack is ignored with accounting.

Page retry timing and replay count use the common §6.4 barrier schedule:

```text
OBJECT_SYNC_MIN_ROUND_TTL_MS = 5_000
page_retry_interval_ms       = control_retry_interval_ms
page_retransmissions_max     = CONTROL_MAX_RETRANSMISSIONS_PER_IDENTITY
```

The host supplies local monotonic `now_ms` explicitly to the state transition; no wall clock or ambient timer enters vector computation. If the current page remains unacked at the next retry deadline, the responder atomically reserves work and exact R2I control bytes for the whole PageOffer and re-enqueues the byte-identical frame without page-index/manifest mutation. After three retransmissions, round deadline, immutable-evidence/trust/policy failure, or any reservation failure, the page path aborts fail-closed; live generation churn alone does not. A late exact Ack accepted before terminalization cancels the pending timer; after terminalization it is a no-op. Every first send, retransmission, duplicate receive, and Ack consumes its normal directional control/work budget. Retry failure never refunds.

---

## 8. Wire framing (control only, authenticated-session-local)

All frames are `carrier_control_bytes` on the **current end-to-end authenticated session only**. A direct connection and a Circuit-Relay-carried connection are equivalent only when the same two endpoint devices terminate the same authenticated cryptographic session and derive the same byte-exact `RVLX1` context. Transport intermediaries are not Object Sync peers.

```text
RVOS1 common header (92 bytes):
  offset  size  field
  0       5     magic = ASCII "RVOS1"
  5       1     schema_rev = 1
  6       1     frame_type (1..10)
  7       1     flags = 0
  8       4     frame_len_u32be (exact entire frame)
  12      16    round_id (not all zero)
  28      32    link_context_digest = SHA-256(exact current-session RVLX1)
  60      32    round_binding_digest
```

`frame_len` is checked against the authenticated carrier record length with checked arithmetic before body allocation. For a byte stream, the receiver reads only the 12-byte prefix, rejects lengths outside `116..4352`, then reads exactly the remaining bytes under a deadline. After reading the fixed 92-byte header—and before round lookup, snapshot freeze, reservation, variable-body allocation, or mutation—the receiver constant-time compares `link_context_digest` with its current session's `context_digest` from §5.2. A mismatch is a cross-session conflict with no round state. Trailing bytes, concatenated frames, unknown types/flags, nonzero reserved fields, and type/length mismatches are `PARSE` failures. The frame maximum is:

```text
RVOS_MAX_CONTROL_FRAME_BYTES = 4352
```

Every frame carries the exact nonzero current `link_context_digest`. `OpenRound` and its direct `RejectRound` carry an all-zero **round** binding. Every other type carries the exact accepted nonzero round binding. All multi-byte integers are big-endian.

### 8.1 Fixed records

`RoundSnapshotDescriptorV1` is exactly 93 bytes:

```text
role_u8                    # initiator=0, responder=1
snapshot_id[16]
generation_u64be
eligibility_policy_digest[32]
eligible_count_u32be
page_manifest_digest[32]
```

`RavenObjectSyncCapsV1` is exactly 80 bytes in the order frozen by §6.3.

### 8.2 Frame bodies and exact sizes

| Type | Code | Exact body after byte 92 | Exact total length |
|---|---:|---|---:|
| `OpenRound` | 1 | `profile_u16=1 || algebra_u16=1 || expected_diff_u32 (0xffffffff=unknown) || initiator_descriptor[93] || proposed_caps[80]` | 273 |
| `AcceptRound` | 2 | `profile_u16=1 || algebra_u16=1 || open_round_digest[32] || initiator_descriptor[93] || responder_descriptor[93] || effective_caps[80]` | 394 |
| `RejectRound` | 3 | `open_round_digest[32] || reason_u16 || reserved_u16=0` | 128 |
| `Symbol` | 4 | `symbol_index_u32 || RavenRibltCellV1[40]` | 136 |
| `DecodeStatus` | 5 | `status_u8 || reserved_u8=0 || fail_code_u16 || prefix_len_u32 || remote_only_count_u32 || local_only_count_u32 || certificate_digest[32]` | 140 |
| `OfferByInventoryId` | 6 | `offer_attempt_u32 || owner_role_u8 || reserved[3]=0 || owner_snapshot_id[16] || id_count_u16 || reserved_u16=0 || inventory_id[16]*n` | `120 + 16*n`, `1<=n<=64` |
| `RequestByInventoryId` | 7 | `fetch_attempt_u32 || requester_role_u8 || owner_role_u8 || reserved_u16=0 || owner_snapshot_id[16] || id_count_u16 || reserved_u16=0 || inventory_id[16]*n` | `120 + 16*n`, `1<=n<=64` |
| `PageOffer` | 8 | exact §8.3 page body | `200 + 16*n`, `1<=n<=256` |
| `PageAck` | 9 | `offering_role_u8 || reserved[3]=0 || snapshot_id[16] || page_index_u32` | 116 |
| `Abort` | 10 | `reason_u16 || phase_u8 || reserved_u8=0 || evidence_digest[32]` | 128 |

Every ID array is strictly lexicographically increasing, contains no all-zero ID, and has no duplicate. Role fields are checked against the accepted initiator/responder descriptors before retaining bytes. A frame that is syntactically valid but impossible for the sender's authenticated role is a conflict, not an ignorable hint.

| Type | Allowed authenticated sender |
|---|---|
| OpenRound | initiator |
| AcceptRound / RejectRound / Symbol | responder |
| DecodeStatus | initiator |
| OfferByInventoryId | initiator, offering certified LocalOnly IDs it owns |
| RequestByInventoryId | the exact `requester_role`; either initiator requesting responder-owned RemoteOnly IDs or responder selecting initiator-owned offered IDs |
| PageOffer | responder in the current pull round |
| PageAck | initiator |
| Abort | either role |

`DecodeStatus.status` is `1=NeedMore`, `2=Certified`, `3=PagedFallback`, or `4=Done`. After Accept, the responder deterministically sends the initial contiguous Symbol prefix `[0, initial_prefix_len)`, where:

```text
estimate_target =
  if expected_diff_u32 == 0xffffffff or checked_mul_add(expected_diff, 2, 64) fails:
      4096
  else:
      checked_mul_add(expected_diff, 2, 64)

wire_symbol_capacity = floor(
  (effective_caps.max_control_bytes_r2i - 394) / 136
)

initial_prefix_len = min(
  effective_caps.max_symbols,
  estimate_target,
  wire_symbol_capacity
)
```

All three inputs are positive under the accepted cap invariants; an `initial_prefix_len` of zero rejects Accept. Before enqueueing Accept, the responder atomically reserves the exact Accept+initial-prefix control bytes, full generation work, retained replay evidence, and candidate encoder capacity. Reservation failure emits only a bounded pre-accept Reject/silence and no Accept/partial prefix. After reservation, an ordinary transport failure may deliver only a prefix; the initiator recovers it through the replay rule below. The responder retains/regenerates the byte-exact Symbol frames for this target under normal retained/work caps.

`NeedMore` has zero counts/digest/fail code and `prefix_len` identifies the exclusive end of a requested contiguous prefix `[0, prefix_len)`. It has exactly two valid forms:

1. **Loss replay:** `prefix_len == current_sent_prefix_len`. The responder re-enqueues the exact retained/regenerated Symbol bytes `[0, prefix_len)` without advancing encoder/round state. An exact duplicate NeedMore reuses this same output set. Every actual replayed frame debits R2I control bytes and work; insufficient remaining budget aborts/falls back without partial enqueue.
2. **Extension:** `prefix_len == min(effective_caps.max_symbols, checked_mul(current_sent_prefix_len, 2))` and is strictly greater than the current target. The responder emits only the exact new suffix `[current_sent_prefix_len, prefix_len)` and then advances the target. If doubling overflows, does not increase, or cannot fit the remaining control/work/retained caps, extension is refused and the initiator selects PagedFallback/Abort.

Any other target—including a lower prefix, arbitrary jump, or value above `max_symbols`—is a conflict/cap violation with no encoder mutation or output. `Certified` has nonzero certificate digest, exact counts, zero fail code, and the accepted prefix length. `PagedFallback` has zero counts/digest, a nonzero generic fail code, and `prefix_len` equal to the final attempted contiguous prefix. `Done` has zero fields and is only an idempotent stream-stop hint; it is never delivery or admission evidence.

The status lattice is deterministic:

```text
zero or more deterministic NeedMore extensions
  -> exactly one of Certified | PagedFallback
  -> optional Done
```

Loss-replay NeedMore frames may repeat the current target between extensions; they do not add a state-lattice edge. While the round remains `Reconciling`, an exact replay of any previously accepted NeedMore identity may also requeue that identity's exact recorded prefix after a later extension, under fresh atomic control/work reservations and without state mutation. A lower prefix that was never an accepted identity is ignored and debits parse/abuse accounting. `Certified` and `PagedFallback` are mutually exclusive. After either is accepted, a replay of an older NeedMore is a non-mutating no-op with no Symbol output; a **new** NeedMore or the other branch is a conflict. After `Done`, every non-identical status is a conflict. A byte-identical replay of an accepted status is idempotent; while that status remains actionable it reuses its recorded outcome. The same replay identity with different bytes is a conflict.

`RejectRound.reason` and `Abort.reason` are generic protocol classes: `1=unsupported_profile`, `2=capacity`, `3=conflict`, `4=snapshot_evidence_or_policy_drift`, `5=decode_failed`, `6=certificate_failed`, `7=inventory_collision`, `8=expired`, `9=abuse_backoff`, `10=internal`. Reason 4 requires actual immutable-evidence loss/corruption or trust/eligibility-policy drift; a bare live generation change MUST NOT produce it. Unknown values are parse failures. `DecodeStatus(PagedFallback).fail_code` is restricted to `2=capacity`, `5=decode_failed`, or `6=certificate_failed`; every other nonzero value is a parse/state conflict, not a new fallback class. `phase` is `0=pre_accept`, `1=symbols`, `2=certificate`, `3=paged`, `4=fetch`.

`Abort.evidence_digest` is either all-zero or `SHA-256("rvn1/object-sync/abort-evidence/v1" || exact conflicting carrier-control frame)`. It never hashes endpoint bytes, an object digest, a preimage map, or a secret key, and it is diagnostic only.

### 8.3 Page body

`PageOffer` body is:

```text
offering_role_u8
reserved[3] = 0
snapshot_id[16]
generation_u64be
eligibility_policy_digest[32]
eligible_count_u32be
page_index_u32be
page_count_u32be
page_manifest_digest[32]
id_count_u16be
reserved_u16 = 0
inventory_id[16] * id_count
```

The fixed body is 108 bytes. Before page-buffer allocation, `eligible_count` must equal the accepted descriptor count and be at most `effective_caps.max_eligible_items`; `id_count` must be at most `effective_caps.max_page_ids`; and checked arithmetic must prove `page_count = ceil_div(eligible_count, effective_caps.max_page_ids)`, `page_index < page_count`, and the exact expected count for that page. Pages cover the lexicographically sorted ID array in exact order. For an empty snapshot, page count is zero and no `PageOffer` exists: the initiator immediately recomputes the exact empty §7.1 manifest from the accepted descriptor and either certifies the empty page set or aborts on mismatch—waiting for a page is forbidden. All non-final pages have exactly `effective_caps.max_page_ids`; the final page has the exact remainder. Truncated pages, duplicates, gaps, extra IDs, inconsistent descriptors, arithmetic failure, or a manifest mismatch abort; V1 has no “truncated success”.

### 8.4 Binding digests

```text
open_round_digest = SHA-256(
  "rvn1/object-sync/open/v1" || exact OpenRound bytes
)

round_binding_digest = SHA-256(
  "rvn1/object-sync/round-binding/v1"
  || open_round_digest
  || exact initiator_descriptor[93]
  || exact responder_descriptor[93]
  || exact effective_caps[80]
  || u16be(profile=1)
  || u16be(algebra=1)
)
```

The `AcceptRound` header carries that digest and its body repeats the exact open digest and initiator descriptor. The initiator compares both to its retained exact `OpenRound`; a responder cannot substitute an equivalent re-encoding. The responder retains exact Open/Accept bytes for idempotent replay until local monotonic expiry.

### 8.5 Replay and conflict identities

Within one authenticated link, every retained control operation has one identity:

| Type | Identity after `round_id` |
|---|---|
| OpenRound | `open` |
| AcceptRound or RejectRound | shared identity `open_response` (they are mutually exclusive) |
| Symbol | `symbol_index` |
| DecodeStatus NeedMore | `(status=1, prefix_len)` |
| DecodeStatus Certified / PagedFallback / Done | `status` (at most one of each) |
| OfferByInventoryId | `(owner_role, offer_attempt)` |
| RequestByInventoryId | `(requester_role, owner_role, fetch_attempt)` |
| PageOffer | `(offering_role, snapshot_id, page_index)` |
| PageAck | `(offering_role, snapshot_id, page_index)` |
| Abort | `terminal_abort` |

The first syntactically and state-valid exact frame bytes and recorded outcome win. A byte-identical replay is idempotent and reuses that outcome. The same identity with different bytes, Accept after Reject (or reverse), `Certified` after `PagedFallback` (or reverse), or a different Abort after terminalization is a conflict and increments severe abuse accounting. Stale lower attempts follow §9.4; stale lower `NeedMore` follows the explicit status lattice above. They never mutate decoder or transfer state.

For small operation frames the exact bytes are retained. Symbol bytes already live in the immutable prefix/reorder evidence. Page bytes are regenerated deterministically from the immutable snapshot, while `(frame_len, SHA-256(exact frame))` is retained for conflict detection. All replay evidence counts toward retained-byte caps and is wiped at the local round deadline or authenticated-link close, whichever occurs first. A terminal round keeps only a compact per-link tombstone until that same deadline; after link close, old frames cannot enter a new session because RVLX1 keys and demux are different.

### 8.6 Authenticated-session locality and carrier composition

| Carrier role | Normative |
|--------------|-----------|
| Direct authenticated session | Only its two authenticated endpoint devices MAY parse, generate, retain replay evidence for, or act on `RVOS*`. |
| Opaque Circuit Relay | MAY transport the encrypted byte stream of one unchanged end-to-end authenticated session and MAY apply bounded transient flow-control buffering under the carrier's approved stream caps/deadlines. It MUST NOT terminate that session, derive `K_os_*`, identify or demultiplex `RVOS*`, persist it as an object, generate a response, translate frames, or re-emit the plaintext/control bytes into another session. |
| Terminating bridge/gateway | A bridge that terminates two authenticated sessions creates **two independent links**. If it is separately authenticated and inventory-eligible on each link, it MAY act as an Object Sync endpoint on each. It MUST derive distinct exporter contexts/keys and use independent round IDs, snapshots, replay stores, and resource supervisors. It MUST NOT copy/transplant `RVOS*`, `K_os_*`, inventory IDs, cells, candidates, or round state across the two sessions. Endpoint objects may cross only through the umbrella carrier API as unchanged `endpoint_object_bytes`, never by forwarding Object Sync control. |
| BLE mesh | Discovery advertisements and unauthenticated/stranger hops MUST NOT carry `RVOS*`. An approved end-to-end authenticated encrypted stream over BLE MAY carry Object Sync between its two endpoints. Otherwise adjacent authenticated devices MAY run separate independent rounds, but a mesh hop MUST NOT forward or transplant control bytes into its next link. |
| Mailbox/store | MUST NOT persist `RVOS*` as `endpoint_object_bytes`, `carrier_record_bytes`, mailbox records, custody objects, or offline work. Object Sync requires a live authenticated session; disconnected synchronization uses endpoint-object storage plus a later fresh round. |
| Session demux | The endpoint carrier demuxes control only on the exact session that authenticated `K_os_master`. Control bytes received outside that session, or transplanted from another session, fail before round lookup/mutation. |
| Round binding | Except the initial `OpenRound` and its direct `RejectRound`, every control frame MUST carry the exact accepted `round_binding_digest`. |

“No persistence” above does not forbid the ordinary bounded socket/QUIC/libp2p buffers required to carry an **active encrypted session**. Such buffering is transient transport state, expires under approved deadlines, is not addressable as an Object Sync or mailbox object, and MUST NOT survive as replayable control after the session closes.

A path change within one authenticated session is valid only when Carrier Conformance proves that the cryptographic session and its exporter context remain unchanged (for example, a transport-preserving upgrade). Re-authentication, reconnection, bridge termination, or session resumption creates a new `session_unique_nonce`, `RVLX1`, `K_os_*`, round namespace, and replay scope; old `RVOS*` bytes MUST NOT be accepted there.

Frame types MUST be distinguishable from endpoint / `carrier_record_bytes` magics. Carriers MUST reject Object Sync magics on endpoint admission paths.

`OpenRound`/`AcceptRound` are the only V1 profile negotiation. A peer that does not support `(profile=1, algebra=1)` returns `RejectRound(unsupported_profile)` or remains silent. Paged fallback is part of that same accepted profile and snapshot pair; it is not a downgrade. There is no fallback to a legacy raw-digest inventory or any unauthenticated profile.

**BLE budget:** total control bytes per sync attempt SHOULD fit carrier BLE budgeting; simulations MUST record bytes used vs budget.

---

## 9. Opaque offer and exact fetch

### 9.1 Why

A peer missing an object also lacks `object_digest` and **cannot** invert `inventory_id`. Rev1’s “map locally then `request_missing(digest)`” is impossible for `RemoteOnly` IDs. Likewise, a responder does not receive a decoded `LocalOnly` result merely because it encoded the stream; the initiator must either offer those certified IDs opaquely or start a role-reversed round.

### 9.2 Certified opaque offer

```text
OfferByInventoryId(
  round_id,
  round_binding_digest,
  offer_attempt_u32,
  owner_role,                    # initiator in the one-round offer path
  owner_snapshot_id,
  inventory_id[]
)
```

Only `LocalOnly` IDs from a successful §6.6 certificate may be offered. The responder MUST treat an offer as a bounded untrusted availability candidate, not as proof of absence or authorization. It MAY select wanted IDs by emitting its own `RequestByInventoryId`, after which the initiator performs the owner checks below. The responder MAY ignore any or all offered IDs.

An implementation MAY omit `OfferByInventoryId` and obtain symmetric convergence through a second role-reversed round. It MUST NOT claim that one one-way coded stream gave the responder a decoded difference.

### 9.3 Request control operation

```text
RequestByInventoryId(
  round_id,
  round_binding_digest,
  fetch_attempt_u32,
  requester_role,
  owner_role,
  owner_snapshot_id,
  inventory_id[]
)
```

| Step | Actor | Rule |
|------|-------|------|
| 1 | Requester | Emits a bounded control frame only for `RemoteOnly` candidates certified locally, or IDs selected from a valid peer `OfferByInventoryId`, under this exact live round binding and descriptor |
| 2 | Owner | Requires exact active `(round_id, round_binding_digest, owner_role, owner_snapshot_id)` binding, then looks up each `inventory_id` in **its** immutable round map → `object_digest` |
| 3 | Owner | Re-checks **contact / revocation / eligibility** for that object **now** (§9.5) |
| 4 | Owner | Computes the exact record length and atomically reserves all §6.3 count/byte budgets before enqueue |
| 5 | Owner | On success: `send_exact(object_digest)` with exact `carrier_record_bytes` on the same link; attempt zero and each exact-next explicit attempt consume cumulative-attempt bytes, while a byte-identical duplicate attempt reuses the recorded outcome |
| 6 | Owner | On miss / ambiguous / expired / ineligible / over-budget: one indistinguishable unavailable result or silent omit per policy (MUST NOT reveal a digest/reason or send a wrong object) |
| 7 | Requester | On receive: compute `object_digest = SHA-256(endpoint_object_bytes)`; recompute `inventory_id` with `K_os_id`; MUST match the exact attempt/request; else discard |
| 8 | Requester | Only then MAY durable admission run under carrier/store rules |

Owner resolution is **internal**. The wire never needs the requester to know the digest.

### 9.4 Attempt idempotency and exact-transfer binding

`offer_attempt_u32` is monotonic per `(round_id, owner_role, frame_type=OfferByInventoryId)`. `fetch_attempt_u32` is monotonic per `(round_id, requester_role, owner_role, frame_type=RequestByInventoryId)`. Each namespace starts at zero. After the first accepted attempt, the only new valid value is `checked_add(last_accepted_attempt, 1)`; gaps, overflow, and wrap are rejected without enqueue or debit.

| Arrival | Rule |
|---------|------|
| Same attempt and byte-identical control frame | Idempotent replay: return/reuse the recorded outcome. It MUST NOT enqueue another exact object or debit cumulative-attempt bytes twice |
| Same attempt and different bytes | Conflict: abort the round fail-closed |
| Exactly `last+1` | Explicit retry/new operation; it consumes control, count, cumulative-attempt-byte, and work budgets again |
| Greater than `last+1`, overflow, or wrap | Refuse without enqueue/debit/mutation; account as a protocol violation |
| Lower non-identical/stale attempt | Ignore/refuse under the frozen profile; never enqueue |

Per-round attempt outcomes and exact control bytes are retained ephemerally until round close or local monotonic expiry. Hop-local transfer metadata MUST bind each exact record to `(round_id, round_binding_digest, requester_role, owner_role, owner_snapshot_id, fetch_attempt_u32, inventory_id)` without modifying `endpoint_object_bytes`. A record that does not match the active request tuple is discarded before endpoint admission.

### 9.5 Re-check at fetch time

Before `send_exact`, the owner MUST re-evaluate:

- peer still a contact / inventory-eligible for this object class;
- no covering revocation for the object’s authoring device when policy requires it;
- object still resolves through the exact frozen owner snapshot and its current record still hashes to that snapshot's `object_digest`; live generation advancement at any round phase is not itself an abort;
- local quotas / expiry still allow send.
- the exact object-count, cumulative-attempt-byte, and in-flight-byte reservations in §6.3 succeed with checked arithmetic.

Stale decode candidates MUST NOT bypass these checks.

### 9.6 Prohibitions

- MUST NOT send raw `object_digest` in `RequestByInventoryId`.
- MUST NOT mint endpoint ACK or Delivered from request/response alone.
- MUST NOT treat owner map hit as proof the requester is allowed the object without §9.5.
- MUST NOT refund cumulative-attempt bytes because a carrier send failed. A transport retry or byte-identical replay of the same attempt reuses its existing debit/outcome; only the exact next explicit attempt debits again.
- MUST NOT enqueue an exact record twice for an exact duplicate attempt.
- MUST NOT treat an `OfferByInventoryId` as a remote difference certificate, authorization, or endpoint admission.

---

## 10. Privacy and honesty

| Honest claim | Limit |
|--------------|-------|
| No raw digest in inventory symbols/pages/requests | Yes (V1) |
| Hides object content in control frames | Yes |
| Hides cardinality from authenticated peer | **No** |
| Cross-link correlation of inventory IDs | Mitigated by session-unique `K_os_id` |
| Membership probing by the authenticated peer | **Not hidden** for an object whose exact `endpoint_object_bytes` (and therefore digest) the peer already knows; the peer also knows `K_os_id` and can compute the link-local ID |
| Completeness against malicious authenticated peer | **Not provided.** The peer can omit its objects or stop the round; Raven limits work and verifies exact admissions |
| Universal coded-symbol cache | Forbidden; session-keyed mapping/checksum deliberately produce link-specific streams |
| Stranger / ad inventory | Forbidden |
| Relay visibility of control | An opaque circuit relay may observe encrypted stream sizes/timing but MUST NOT see or parse plaintext `RVOS*`; a terminating bridge sees only the independent session it terminates and MUST NOT transplant its control into another session |

---

## 11. Testing and shared vectors

### 11.1 Functional matrix

| Case | Requirement |
|------|-------------|
| Diff 0 | Polarized empty; zero requests; no mutation |
| Empty paged snapshot | `eligible_count=0` emits no PageOffer; initiator immediately verifies the empty manifest and completes or aborts—never waits |
| Page loss/Ack loss | Stop-and-wait sends one page; dropping PageOffer or PageAck triggers byte-identical bounded replay; duplicate insertion is impossible; retry 3 is allowed, retry 4/expiry aborts; explicit monotonic ticks compute identically in all languages |
| Diff 1 | One `RemoteOnly` / `LocalOnly` as seeded; opaque fetch verifies |
| Diff 100 | Complete under caps |
| Diff 10_000 | Completes under absolute maxima **or** clean snapshot-bound page fallback |
| One decoder, two-way convergence | Initiator `RemoteOnly` request plus certified `LocalOnly` offer/request converges both stores after exact admission |
| Role-reversed equivalence | Two role-reversed rounds converge to the same exact object sets as the offer/request path |
| Loss / bounded reorder / exact duplicate | Deterministic initial prefix and doubling schedule are identical in all languages; a missing Symbol triggers same-target NeedMore and byte-exact bounded prefix replay; extension emits only the exact suffix; ordered contiguous decode produces the same certificate with no false IDs |
| Open/Accept/status loss | Lost Open replays exact Open; duplicate Open atomically replays exact cached Accept/Reject plus current prefix while Reconciling; duplicate final Symbol replays exact emitted status; first output + retries 1..3 succeed and retry 4 terminates under one explicit monotonic schedule |
| Prefix negatives | Missing index zero, sparse high index, gap beyond reorder window, `u32` wrap, and out-of-cap index fail without allocation/mutation |
| Conflicting same-index symbols | Fail-closed; no mutation |
| Partial peel | Emits no offer/request; full zero-residual + re-encode certificate does |
| Rateless snapshot mismatch | A zero-residual and byte-reencoding-valid difference that reconstructs a responder count/manifest different from the accepted descriptor emits no certificate/offer/request and causes zero durable mutation |
| Local inventory-ID collision | Entire round fails; paged fallback with the same IDs is forbidden |
| Malicious symbols | Cap/conflict abort; zero durable mutations; no fetch for forged LocalOnly |
| False decode | Injected success MUST NOT mutate |
| Pre-certificate live churn | Repeated arrivals, admissions, expiry, and deletion advance live generation while rateless/page certification completes against immutable snapshots; no refresh, self-abort, or newly arrived object leaks into the round |
| Trust/policy drift at every phase | Contact deletion, covering revocation, capability/eligibility-policy change, or immutable-evidence loss aborts before further candidate/output use; a generation number change alone does not simulate this evidence |
| Multiple exact admissions | Transfers advance live generation yet all certified requests complete from the immutable initial transcript; no self-abort after the first object |
| Unrelated new object | It is excluded from this frozen round and appears only in a later round, regardless of arrival phase |
| Deletion/expiry versus revocation | Deleted/expired snapshot object returns indistinguishable unavailable at fetch; covering revocation/trust-policy drift aborts; neither sends stale/wrong bytes |
| Cross-snapshot mix | Valid symbol/page/request under another descriptor or binding is ignored or conflicts as §6.2 specifies; zero mutation |
| Cross-session exact replay | Exact old `OpenRound`, `RejectRound`, and bound non-Open frames carry the old `link_context_digest` and are rejected before round lookup/snapshot freeze/allocation/mutation on the new session |
| Same-session expired replay | After bulky tombstone expiry, compact non-evicting round/snapshot seen IDs still reject old Open/Accept; round 1024 succeeds at the boundary and the next round refuses Object Sync until re-authentication |
| Fetch re-check | Revoked/ineligible object refused at send_exact |
| Offer/request idempotency | Exact duplicate attempt is a no-op; same-attempt conflict aborts; next attempt debits budgets again |
| Offer/request loss | Lost Offer/Request exact-retries at most three times under the common barrier counter; duplicate Offer replays the same recorded Request selection; duplicate Request reuses one unavailable/exact-delivery outcome and never enqueues/debits an object twice |
| DecodeStatus lattice | Same-target loss replay or the exact deterministic doubled target succeeds while Reconciling; arbitrary/lower targets do not mutate; same-identity conflict aborts; Certified/PagedFallback are mutually exclusive; Done blocks later non-identical statuses |
| Control amplification | I2R/R2I and pre-accept byte/frame caps are hit at boundary and boundary+1; every actual duplicate/replay send/receive debits bytes/work; a whole replay/extension output set is reserved atomically and never partially enqueued |
| Exact-fetch amplification | Single-object, cumulative-attempt, and in-flight byte caps are independently hit at boundary and boundary+1; attempt zero and each exact-next attempt consume budget once, skipped/wrapped attempts are refused, same-attempt exact replay consumes no second debit, and failure never refunds |
| Reconnect abuse | Same authenticated identity/device over new IP, relay, link ID, and session nonce retains backoff across process restart |
| Backward clock | Persisted `last_observed_ms` prevents a clock rollback from shortening backoff |
| Round clock skew | ±wall-clock skew does not affect local monotonic round deadlines; negotiated TTL is identical in the binding |
| Exporter context | Noise LAN, libp2p Noise/QUIC, and relay-carried sessions derive matching keys at both ends; role/cert/transcript/carrier/version/nonce changes alter the result |
| Direct versus opaque circuit relay | The same approved end-to-end session transcript produces byte-identical endpoint `RVOS*` behavior whether packets take a direct or opaque relayed path; the relay receives only encrypted carrier-stream bytes and has no Object Sync parser/state |
| Relay termination negative | A relay that terminates/re-authenticates, resumes, changes the session nonce, or attempts to demux plaintext control derives a different exporter context; old `RVOS*` is rejected before round mutation |
| Bridge cross-session transplant | Two bridge-terminated sessions use distinct `RVLX1`/`K_os_*`/round/replay namespaces; copying an exact control frame, inventory ID, candidate, or replay result across them is rejected |
| BLE hop boundary | An unauthenticated advertisement/mesh hop carrying `RVOS*` is rejected; adjacent authenticated hop sessions reconcile independently and cannot transplant control state |
| Mailbox/store boundary | No `RVOS*` magic is admitted to endpoint, carrier-record, mailbox, custody, offline-work, or persistent bridge stores; only transient bounded encrypted-stream buffering exists while the live session is active |
| Key separation | `K_os_id`, `K_os_map`, and `K_os_check` are distinct; cross-session encodings differ and no coded cache is reused |
| Linear-cancellation fixture | Unsafe unkeyed/reused mapping profile demonstrates the known attack class; approved session-keyed profile resists an author lacking the link key |
| Malicious authenticated peer | Can force bounded abort/omission but cannot create a false durable admission; all work remains capped |
| Global cap races | Concurrent links/reconnects for one device and process-global rounds/cells/work cannot exceed supervisors |
| BLE budget | Recorded bytes ≤ scenario budget |
| 1_000-node sim | Deterministic sim records convergence, false-decode count, bytes, CPU work, peak memory, page-fallback rate, abuse state, and fetch amplification; control remains authenticated-session-local, opaque relays never terminate it, bridges use independent links, and exact fetch stays endpoint-oracle gated |

### 11.2 Tri-language vectors

Before APPROVED:

| Surface | Evidence |
|---------|----------|
| Python reference | Keyed symbols/prefix, completion certificate, polarity, opaque offer/fetch transcript, page snapshot, negatives |
| Rust `raven-core` | Same vectors; sim hooks |
| Swift | Lab/XCTest vector replay (Debug/lab gate; no Release link) |
| Shared JSON | `shared-vectors/rvn1/object-sync/` |

### 11.3 Non-claims

Passing vectors does **not** approve production flags. Formal verification deferred.

---

## 12. Explicit prohibitions

Implementations conforming to this design MUST NOT:

1. Place Object Sync payloads in `endpoint_object_bytes` or treat them as `object_digest` keys;
2. Send raw `object_digest` in inventory / IBLT / page / request bodies;
3. Require a missing peer to invert `inventory_id` locally;
4. Call polarized decode output a verified difference before exact-fetch verification;
5. Mutate durable inventory on symbol/page decode alone;
6. Mark Delivered / mint endpoint ACK from inventory or sync completion;
7. Run Object Sync on unauthenticated or stranger discovery links;
8. Parse, terminate, persist, translate, or transplant `RVOS*` at a relay/mailbox/mesh hop, or forward plaintext/control bytes across authenticated-session boundaries. An opaque Circuit Relay MAY carry the encrypted stream of one unchanged end-to-end session exactly as §8.6 permits;
9. Use directional traffic keys as `K_os_master`, or reuse one Object Sync subkey for ID, mapping, and purity checks;
10. Disable caps or work-unit budgets “to finish faster”;
11. Reset abuse accounting because the same authenticated device changed address, relay, link, or session nonce;
12. Send an exact object before reserving count and byte budgets, or refund attempted bytes on retry;
13. Enable a Release / App Store / production Object Sync path while status is not **APPROVED**;
14. Start production or lab **implementation** of codecs before wire layout, IBLT polarity, and opaque-fetch transcripts are frozen in shared vectors.
15. Feed sparse or out-of-order cells directly to the decoder, or accept a partial peel without the §6.6 certificate;
16. Reuse coded symbols, mapping seeds, or checksum state across authenticated sessions;
17. Treat an exact duplicate offer/request attempt as a new enqueue, or reuse an attempt number with different bytes;
18. Claim completeness against a malicious authenticated peer;
19. Fall back to raw-digest, legacy, early-exporter, unauthenticated, or traffic-key-derived inventory behavior.
20. Cross the `CertifiedTransfer` barrier from rateless algebra without reconstructing the responder set and matching its exact accepted count and page-manifest digest.
21. Accept an arbitrary NeedMore prefix jump, advance encoder state on a same-target loss replay, or partially enqueue a prefix replay/extension whose complete output set was not atomically reserved.
22. Treat deterministic work, retained memory, or exact-object byte caps as substitutes for the independent pre-accept and directional control-byte supervisors.
23. Send multiple PageOffers concurrently, advance the page index before exact Ack, rebuild different retry bytes, use ambient wall time in the page state machine, or retry beyond the frozen count/deadline/caps.
24. Abort or refresh an immutable active snapshot merely because the live eligible-store generation advanced; generation is provenance, while trust/policy/evidence failures require their own concrete checks.

---

## 13. Relationship to later companions

| Later work | Depends on Object Sync how |
|------------|----------------------------|
| Custody Receipts | MAY advertise custody rows via inventory IDs; receipts remain hop-local |
| Social Object DAG | Syncs object sets; DAG verification stays endpoint-side |
| Mailbox / Mesh | Efficiency of “what are you missing?” only on a live approved authenticated session; mailbox persistence and hop-to-hop control forwarding remain forbidden |
| Carrier Conformance | MUST map its authenticated handshake to frozen `RavenAuthenticatedLinkExporterV1`, prove provider vectors, and cite RVOS1 session demux/caps. It must classify each path as direct endpoint session, opaque circuit carriage of that same session, or a newly terminated independent session; it cannot change RVLX1 or the Object Sync KDF |

Drafting order (human roadmap): Object Sync **Rev13 freeze candidate** → Full Braid Slice 3 foundations → Object Sync shared-vector freeze + lab implementation → Carrier Conformance provider mappings.

---

## 14. Open items before APPROVED

1. Independent byte/state/carrier-boundary audit of every Rev13 size, offset, label length, mapping edge, count polarity, remote-set reconstruction, manifest check, immutable-snapshot/live-generation separation, Open/prefix/status/page retry barriers, directional control-byte accounting, phase transition, replay identity, cap formula, `link_context_digest` check, and §8.6 path classification; any correction produces Rev14 before vectors.
2. Shared KDF/algebra/wire/state-machine fixtures generated independently, then byte-computed by Python, Rust, and Swift-through-length-explicit Rust FFI. JSON-only checking is insufficient.
3. Per-carrier `RavenAuthenticatedLinkExporterV1` provider vectors for Noise LAN, libp2p Noise, TLS 1.3/QUIC, and relay-carried end-to-end sessions. They MUST prove that opaque circuit carriage preserves the endpoint session while relay termination/re-authentication creates a new context; provider absence keeps that carrier disabled without blocking the core profile freeze.
4. Deterministic 1,000-node and adversarial simulations covering diff sizes, loss/reorder/duplicates, linear cancellation, global races, fallback, abuse persistence, and exact-fetch amplification.
5. Native platform resource/fault tests and CI proving strict pre-parser boundaries, zero mutation on failure, no relay parsing/termination, no cross-session control transplant, no mailbox/BLE-hop persistence, and exact production holds.
6. Independent security review of the Raven port and protocol, followed by human/protocol-owner approval.

---

## 15. Document history

| Rev | Date | Change |
|-----|------|--------|
| 1 | 2026-08-17 | Initial design: rateless inventory control, link-scoped IDs, caps, paged fallback; production off |
| 2 | 2026-08-18 | P0: `RequestByInventoryId` opaque fetch; polarized LocalOnly/RemoteOnly; ban “verified difference” pre-fetch. P1: snapshot-bound pages; symbol-index conflict; bidirectional `K_os`; checked estimates + work-units; fetch-time eligibility; link-local no relay/store/forward |
| 3 | 2026-08-18 | P0: bind initiator+responder immutable snapshots in one round digest and abort on either-side drift. P1: exact-fetch byte/in-flight budgets and durable identity+device backoff. P2: disclose known-object membership probing by an authenticated peer. |
| 4 | 2026-08-18 | Independent-review P0: one-decoder symmetric offer/request flow; contiguous-prefix decoder; zero-residual re-encode certificate; session-keyed ID/map/check domains; idempotent attempt numbers; role/cert/transcript-bound post-handshake exporter. P1: full work supervision, strict artifact wrapper, monotonic round TTL, bounded abuse storage, and downgrade-safe profile negotiation. |
| 5 | 2026-08-18 | Freeze candidate: exact RVLX1 exporter contract and KDF; Raven-owned deterministic integer RIBLT port with split map/check taps; 40-byte cell and completion digest; byte-exact RVOS1 frames; concrete work/global/abuse bounds; carrier-provider dependency cycle removed. Production remains off pending vectors/review. |
| 6 | 2026-08-18 | First-try reliability correction: reconcile/certified-transfer phase barrier prevents self-abort after the first admitted object; immutable original prefix is separated from mutable peel state; all control replay identities and cap cross-field invariants are frozen. |
| 7 | 2026-08-18 | Carrier-boundary correction: authenticated-session locality replaces the contradictory blanket relay ban. Opaque Circuit Relay carriage of one end-to-end encrypted session is allowed; relay termination/parsing/storage, bridge cross-session transplant, BLE hop forwarding, and mailbox persistence remain forbidden and gain explicit conformance negatives. The exporter function name and per-attempt cumulative-byte debit/idempotency are normalized before vectors. |
| 8 | 2026-08-18 | Pre-freeze replay correction: every RVOS1 frame now carries the current RVLX1 context digest, expanding the common header to 92 bytes and binding even Open/Reject to one authenticated session before state allocation. Exact frame sizes are recomputed; DecodeStatus progression and offer/request attempt namespaces are frozen. |
| 9 | 2026-08-18 | Snapshot-certification correction: rateless success now reconstructs the full responder set and matches its count/page-manifest commitment before CertifiedTransfer. Descriptor/cap/page cross-field checks are explicit before allocation. |
| 10 | 2026-08-18 | Loss/amplification correction: deterministic initial/doubling prefixes and same-target exact replay make dropped Symbols recoverable; role-directional control-byte caps and pre-accept frame/byte supervision bound every actual control send/receive. Caps expand to 80 bytes; Open/Accept totals become 273/394. |
| 11 | 2026-08-18 | Paged-loss correction: PageOffer/PageAck is frozen as one-page stop-and-wait with exact duplicate outcomes, deterministic monotonic retry timing, three retransmissions, and atomic control/work reservations. Empty snapshots complete without waiting. |
| 12 | 2026-08-18 | Control-loss correction: one bounded retry schedule closes Open→Accept/Reject, Symbol-prefix→DecodeStatus, Page→Ack, Offer→selection, and Request→delivery-outcome loss windows. Duplicate outputs remain exact/single-shot under shared replay caps and atomic byte/work reservations. |
| 13 | 2026-08-18 | Busy-store reliability correction: live generation churn no longer aborts pre-certificate reconciliation. Immutable snapshots remain authoritative from Open/Accept through fetch; new/deleted/expired objects are deferred/unavailable, while concrete trust/policy/evidence drift still fails closed. |
