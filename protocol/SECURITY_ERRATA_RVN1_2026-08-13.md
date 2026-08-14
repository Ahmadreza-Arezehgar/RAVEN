# RAVEN RVN1 Security Errata and Production Hold

**Published:** 2026-08-13  
**Applies to:** every RVN1 implementation and all prior Phase A/Phase B proof
claims  
**Status:** normative security errata; the codec vectors remain frozen, but
RVN1 messaging is **not approved for production**

This errata exists because an implementation audit found gaps between the
frozen protocol's security promises and executable endpoint behavior. It
overrides conflicting processing or release claims in the RVN1 document
family. It does not silently change the frozen bytes. A future forwarding
wrapper or incompatible handshake change requires a new version and vectors.

## Immediate rules

1. **No public-material cipher.** `STUB_PROTO=0x7f`, `RavenInterimSeal`, and
   any key derived only from public Ed25519 identities are laboratory fixtures,
   not encryption. A passive observer can derive the same key. Production
   builds MUST reject them before history, outbox, network, or ACK mutation.
2. **An authenticated session is mandatory.** A sender without a persisted,
   authenticated ATSAM/Noise session MUST return `ATSAM_SESSION_REQUIRED` and
   emit no envelope. Synthetic "opaque ATSAM" bytes are not ciphertext and
   MUST NOT be originated.
3. **ACK content is encrypted.** A conforming `env_type=2` body is a sealed
   session payload. Relays MUST NOT parse `acked_message_id` or status. The
   opened 101-byte record is
   `acked_message_id(16) || status(1) || ack_nonce(12) || created_at(8) ||
   Ed25519_signature(64)` and its inner signature covers the exact
   domain-separated bytes in `RAVEN_ACK_V1.md`.
4. **Only an endpoint advances delivery.** Before a local delivery-state
   transition, one endpoint actor MUST validate the envelope, resolve the
   expected non-revoked device, verify outer authentication, open the ACK AEAD,
   verify the inner signature, require status `1` or `2`, enforce freshness and
   replay policy, and match an outstanding message bound to that same recipient
   device. A relay, transport write, or unverified ID can never mark delivery.
5. **No ACK before authenticated durable acceptance.** Message processing is:

   `size -> strict decode -> TTL -> local route/session -> device/cert + outer
   auth -> ratchet/AEAD open -> atomic commit -> ACK outbox`

   The atomic commit contains the authenticated dedup receipt, receive-ratchet
   state or recovery journal, inbox row, and ACK-outbox intent. Missing keys,
   unknown sessions, `STUB_PROTO`, opaque ATSAM, invalid AEAD, invalid outer
   authentication, or persistence failure produces no visible message and no
   ACK. A previously committed duplicate may requeue its existing ACK.
6. **Pre-authentication dedup never writes attacker-chosen IDs.** An endpoint
   may perform a read-only lookup early, but inserts dedup state only in the
   successful commit above. An opaque relay uses a bounded, expiring replay
   cache keyed by `SHA-256(domain || envelope_signing_bytes || outer_signature)`
   and records it only after resource/queue admission. It MUST NOT durably
   suppress solely on unverified `message_id`.
7. **Ratchet persistence is fail-closed.** A receive-chain Keychain/database
   write failure means the plaintext is not accepted and no ACK is emitted.
   Delete-then-add storage that can erase the last durable ratchet state is not
   an acceptable update strategy. Crash recovery must never permit message-key
   reuse or receive-chain rollback.
8. **V1 hop fields are not an authenticated multi-hop bound.** RVN1 excludes
   `dest_device_hint`, `hop_limit`, and `replication_budget` from the sender
   signature. A malicious relay can raise them. Until a versioned custody/
   forwarding wrapper authenticates an immutable sender ceiling and monotonic
   per-hop remainder, production security claims are limited to direct or
   locally policy-bounded forwarding. A relay can always copy ciphertext; hop
   budgets constrain cooperative nodes, not Byzantine retransmission.
9. **Offline mailboxes are not envelope-tag hashes.** A per-envelope routing
   tag is unknowable to an offline recipient until it receives that envelope,
   so `SHA-256(routing_tag)` (including passing a route tag to
   `opaque_store_tag`) is not a polling address. Store publication and polling
   require separately derived rotating
   mailbox tags. Store Object V1 deletion is TTL-only: sealed ACK arrival
   cannot reveal the acknowledged ID or authorize custody deletion. Early
   deletion requires a future versioned, object-bound deletion token.

## Required session boundary

Low-level X25519, ML-KEM-768, HKDF, and ChaCha20-Poly1305 helpers do not by
themselves form a secure asynchronous session. Production enablement requires:

- the recoverable endpoint acceptance/ACK transaction in
  [`ATSAM_ENDPOINT_TRANSACTION_V1.md`](ATSAM_ENDPOINT_TRANSACTION_V1.md),
  implemented with the same crash and failure semantics on Rust and Swift;
- the canonical signed PairInit/response wire format in
  [`RAVEN_PAIR_INIT_V1.md`](RAVEN_PAIR_INIT_V1.md), including cross-language
  transcript vectors and all of its still-open carrier/state activation gates;
- user and device identities, certificate/revocation state, both X25519 keys,
  both ML-KEM contributions, suite/version, and roles bound into the transcript;
- address-keyed secure session storage with directional `K_msg`, `K_ack`, and
  `K_route` subkeys derived with distinct fixed labels;
- monotonic one-time prekey consumption and rotation;
- atomic send-chain advance plus immutable ciphertext enqueue;
- atomic receive-chain/skipped-key update plus inbox/dedup/ACK-outbox commit;
- a bounded skipped-key window with identical Swift and Rust behavior;
- key zeroization and platform-specific protected storage behavior;
- Swift/Rust vectors for first message, reply, relaunch, loss, reordering,
  tampering, wrong root, replay, and persistence failure.

Recomputing every historic message key from a retained root is not forward
secrecy. The current low-level known-root RVNA1 helper is useful for interop
tests, but it is not a persisted Double Ratchet session.

The additive
[`ATSAM_INDEXED_SESSION_PROFILE_V1.md`](ATSAM_INDEXED_SESSION_PROFILE_V1.md)
freezes candidate directional KDF, route-allocation, UUID/AAD, and sealed-ACK
bytes under RVNA1 protocol byte `0x03`. It is test-vector evidence only and is
intentionally absent from live classifiers. PairInit plus production-disabled
Rust and Swift endpoint actors now transcript-bind exact trust records and
exercise recoverable message/ACK acceptance. They remain held pending a
confidential carrier, protected prekey lifecycle, concrete Swift storage/queue
adapters, a transactionally bound send/ACK worker, live interop, and external
review.

## Release gate

Production serverless messaging remains disabled until all of these are true:

- Default and release artifacts cannot link the demo sealer. A lab-only Cargo
  feature must be off by default and forbidden with release optimization.
- Swift release builds cannot call interim plaintext/contact-request sealers.
- Captured message and ACK wires contain neither plaintext content nor the
  acknowledged message ID/status.
- Forged, zero-signature, wrong-device, revoked-device, stale, replayed,
  wrong-recipient, unknown-message, tampered, undecryptable, and persistence-
  failure cases cause zero delivery transitions and zero ACKs.
- A valid message commits exactly once; a crash after commit but before network
  send resumes the committed ACK outbox after restart.
- A valid ACK causes one conditional state transition and one UI event under
  concurrent duplicate ingestion.
- Rust and Swift exchange the same sealed-message and sealed-ACK fixtures.
- Real-device tests cover separate NATs, relay loss, BLE background
  restrictions, restart, offline storage, duplicate paths, and out-of-order
  delivery.
- An external protocol/security review signs off on the session transcript,
  state machine, persistence boundary, and versioned forwarding design.

## Platform and availability honesty

Serverless means no trusted mandatory application server; it does not mean no
listening process or community infrastructure. Circuit Relay is a live byte
relay, not an offline mailbox. iOS cannot be a dependable always-on DHT, relay,
store, or BLE scanner: background scans are constrained and force-quit prevents
Bluetooth relaunch. Raven may provide eventual delivery opportunities, but it
MUST NOT promise timely background delivery without an OS-approved wake source.

Design references: [Bundle Protocol v7 (RFC 9171)](https://www.rfc-editor.org/rfc/rfc9171.html),
[Double Ratchet revision 4](https://signal.org/docs/specifications/doubleratchet/),
[libp2p Circuit Relay v2](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md),
[libp2p DCUtR](https://github.com/libp2p/specs/blob/master/relay/DCUtR.md), and
[Apple Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

## Current implementation posture

The Rust default build now refuses the public-key-derived demo sealer, refuses
synthetic/opaque terminal delivery and plaintext ACK delivery transitions, and
uses bounded immutable-object relay dedup. Disabled Rust and Swift actors pass
forgery/replay/out-of-order/crash tests, but expose no production send or ACK
materializer and have no live networking callsites. These are containment and
reference-implementation results, not a release claim. The existing iOS and
terminal interfaces remain subject to this hold until every entry path uses
the concrete endpoint transaction and the centralized default route is removed
only after the real serverless release gates pass.
