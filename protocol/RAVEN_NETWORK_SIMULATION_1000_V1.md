# RAVEN deterministic 1,000-node network simulation V1

**Status:** bounded model evidence; not a production transport or security proof
**Updated:** 2026-08-13

## Purpose

`node/crates/raven-core/tests/network_sim_1000.rs` is a deterministic, offline,
virtual-time simulation of one opaque authenticated RavenEnvelopeV1 object and
its delivery ACK moving through exactly 1,000 store-carry-forward nodes. It
exercises delay-tolerant routing invariants cheaply enough for ordinary CI.

This test is evidence for transport-policy behavior only. It does **not** claim
to exercise live libp2p, QUIC, TCP, NAT traversal, relay reservations, BLE/GATT,
iOS background execution, protected storage, ATSAM ratchets, real radios, real
clocks, external operators, or an external security review.

## Deterministic model

- A SplitMix64-derived PRNG drives a seeded ring, fixed long links, seeded
  chords, edge transport classes, contact loss, packet loss, latency jitter,
  and event ordering. No wall clock, network socket, thread scheduler, or OS
  entropy affects a report.
- The simulation contains exactly 1,000 nodes. Every node has at most 8 queued
  objects and 32 unexpired object-digest entries.
- Simulation objects are capped at 4 KiB (inside the protocol's stricter
  1 MiB network ceiling). A global binary-heap event queue is capped at 10,000
  entries and a run is capped at 50,000 processed events. Stored and in-flight
  logical bytes are accounted independently. A contact considers at most 4
  objects and adversarial duplication is capped at 4 copies per object/contact.
- Routing is late-bound: an online contact chooses eligible queued replicas at
  contact execution time. Per-copy hop and cooperative replication budgets,
  virtual TTL, exponential retry backoff, and bounded admission apply.
- Relay deduplication keys only `SHA-256(exact_object_bytes)`. The public
  RavenEnvelopeV1 `message_id` is never a relay dedup key. Mutation cases retain
  the same public `message_id` but receive a different object digest.
- Persist/restart reconstructs new byte buffers plus bounded metadata, then
  recomputes and checks every object digest. This is a model of persisted-state
  reconstruction, not a test of Raven's platform storage backends.

## Endpoint-oracle boundary

The logical message fixture is a real, strictly decodable RavenEnvelopeV1 with
a deterministic Ed25519 outer signature. Every hop checks byte identity for the
known original. A recipient-side oracle requires exact fixture bytes, strict
decoding, the expected routing tag, and a valid outer signature before modeling
the ATSAM decrypt/authenticate/durable-commit transaction.

The ACK is materialized only after that modeled endpoint commit. It is another
strict, signed, immutable RavenEnvelopeV1 object and is accepted at the sender
only when its exact bytes, type, message binding, and recipient signature match
the outstanding object. The opaque ACK payload is a simulation fixture; this
test does not replace the indexed-session sealed-ACK vectors or endpoint actor
tests. Relay storage or forwarding can never create an ACK. The malicious-relay
case also injects an otherwise strict, recipient-signed ACK candidate before
commit; the sender rejects it without changing delivery state, then accepts
only the exact ACK materialized after commit.

## Scenario matrix and assertions

The integration test covers:

1. connected baseline;
2. seeded contact and packet loss, latency, reordering, retry, and backoff;
3. exactly 50% node loss plus seeded replacement churn while a valid temporal
   path remains;
4. partition followed by healing;
5. sender and recipient that are never simultaneously online;
6. duplicate multipath storm;
7. explicitly out-of-order arrivals;
8. restart and persisted-state reconstruction;
9. malicious relays that drop, replay, delay, duplicate, and mutate;
10. TTL expiry and complete bounded-state cleanup;
11. queue-pressure/spam rejection at the hard node limit; and
12. an exact-byte bridge path spanning Internet and local-radio classes.

For every scenario with a scheduled valid temporal path, the test requires one
authenticated endpoint commit, exactly one UI delivery, exactly one sender ACK
state transition, no ACK before commit, no incorrect ACK transition, and exact
immutable bytes. Duplicate ACKs are idempotent. A changed byte is never accepted
as the original object. Every run checks event accounting and hard queue, seen,
event, object-size, and logical-buffer ceilings. The TTL-only scenario has no
valid recipient path and instead requires eventual removal of every queue and
dedup entry without a false delivery or ACK.

The same loss scenario is run twice with one seed and its entire deterministic
report must match. Three additional fixed seeds must independently retain all
delivery, ACK, identity, and resource invariants.

The non-simultaneous-online case additionally records that endpoint commit
occurred while the sender was offline and ACK acceptance occurred while the
recipient was offline. The churn case records 600 availability transitions
(500 initial losses, 50 returns, and 50 deterministic replacements) while never
exceeding 500 simultaneously offline nodes.

## Reproduce

From `node/`:

```sh
cargo test -p raven-core --test network_sim_1000 -- --nocapture
cargo test --release -p raven-core --test network_sim_1000 -- --nocapture
cargo clippy -p raven-core --test network_sim_1000 -- -D warnings
cargo fmt --all -- --check
```

The `--nocapture` output contains deterministic per-scenario event, contact,
transfer, loss, delivery, rejection, restart, and peak-resource counts. Runtime
itself is intentionally not part of the report because it depends on the CI
host; the model contains no real-time deadline or sleep.

## CI recommendation

Add the first command as an ordinary required Rust job and the release command
to the existing release-evidence job. Keep this simulation alongside—not in
place of—live localhost transport tests, real multi-NAT/CGNAT trials, physical
BLE/iOS trials, adversarial cryptographic tests, and independent review.
