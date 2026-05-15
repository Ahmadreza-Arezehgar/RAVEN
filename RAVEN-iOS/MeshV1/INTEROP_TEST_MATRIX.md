# RAVEN cross-platform mesh interop test matrix (Phase 4)

> **Audience**: QA/test-lab engineer setting up real-device cross-platform mesh testing.
> **Goal**: enumerate every scenario that must pass before iOS ↔ Android mesh DM can ship.
> **Status**: matrix defined; some rows already validated by unit tests on shared-vectors fixtures, others need live BLE devices.

The shared-vectors validation in [`shared-vectors/v1/`](../../shared-vectors/v1/) already proves byte-level wire equivalence between iOS (`MeshV1`) and Android (`raven-android/modules/mesh`). What remains is **live BLE behavior** — connection lifecycle, MTU negotiation, advertise/scan cadence, restoration, power management. That can only be tested on actual hardware.

## Unit-test coverage (already green)

| Capability | iOS test | Android test |
|---|---|---|
| Ed25519 sign produces fixture-byte signature (or, on iOS, verifies the fixture) | `SharedVectorsSignatureTests.test_crypto_ed25519_*` | `SharedVectorsSignatureTest.crypto-level ed25519_*` |
| DM pipe canonicalization byte-exact | `SharedVectorsTests.test_dm_pipe_001/002` | `SharedVectorsTest.dm_pipe_001/002` |
| Post / ACK / Stop pipe byte-exact | same suite | same suite |
| Frame JSON-canonical byte-exact | `SharedVectorsTests.test_frame_json_001` | covered via canonicalization fixture (parsing only) |
| Chunking encode + reassembly byte-exact | `test_single_chunk_001` + `multi_chunk*` | `single_chunk_001` + `multi_chunk*` |
| Dedup key strings | `test_dedup_keys_001` | `dedup_keys_001` |
| Spray-and-Wait transitions | `test_spray_transition_*` | `spray_transition_*` |
| Pairing code derivation | `test_pairing_code_001_alice_bob` | `pairing_code_001 — Alice times Bob` |
| Fingerprint format | `test_fingerprint_001_alice` | `fingerprint_001 — Alice…` |
| Envelope Codable round-trip (every field survives encode→decode→encode) | `CodableRoundTripTests.*` (9 cases) | rely on kotlinx.serialization shape match |

## Live-BLE matrix (needs hardware)

Each row needs at least one iOS device + one Android device. "Mixed" rows need at least one of each.

| # | Scenario | Send | Receive | Pass criteria |
|---|---|---|---|---|
| L1 | iOS → iOS DM, both foreground, airplane mode | iPhone A | iPhone B | Bubble shows "Delivered via Mesh" within 5s |
| L2 | Android → Android DM, both foreground, airplane mode | Pixel A | Pixel B | same |
| L3 | iOS → Android DM, mixed, both foreground, airplane mode | iPhone | Pixel | same |
| L4 | Android → iOS DM, mixed, both foreground, airplane mode | Pixel | iPhone | same |
| L5 | iOS → Android, three-device room with one relay | iPhone | Pixel B via Pixel A relay | Delivered; `routePath` includes relay device id |
| L6 | Android → iOS, three-device room with one relay | Pixel | iPhone B via iPhone A relay | same |
| L7 | Encrypted DM cross-platform | iPhone | Pixel | Decrypts to original plaintext; signature verifies |
| L8 | ACK cross-platform | Pixel | iPhone receives | ACK envelope verified; receipt UI updates within 5s |
| L9 | Stop command cross-platform | iPhone | Pixel | Pixel suppresses any pending forward of the named message |
| L10 | Post fan-out via mesh | iPhone author | Pixel + iPhone B | Post appears within 10s on both consumers |
| L11 | Dedup — relay drops second copy of same frame | iPhone author, two paths to Pixel | Pixel | Pixel renders exactly one message |
| L12 | Reassembly — payload bigger than MTU | iPhone | Pixel | Long-text DM reassembled correctly |
| L13 | Reassembly — out-of-order chunk arrival | iPhone | Pixel | same |
| L14 | TOFU sighting — first contact | iPhone | Pixel | Pixel records `unverified` state; pairing-code UI offered |
| L15 | Pairing-code match → verified | iPhone | Pixel | Pixel friend-device row transitions to `verified` |
| L16 | Battery — 30 min idle mesh-on | both | both | < 3% / hour drain |
| L17 | Foreground service survives process death (Android) | Pixel | Pixel B | Mesh resumes after `adb kill` of Raven |
| L18 | iOS state restoration after foreground | iPhone | iPhone B | Mesh resumes after backgrounding then foregrounding |
| L19 | MTU negotiation — Samsung BLE stack | Samsung | iPhone | Connection completes; chunks the right size |
| L20 | Mesh ↔ server bridge | One device with internet | The other airplane mode | Internet-connected device uploads queued mesh DM via `POST /api/messages/send`; recipient gets it via push |

## Setting up the test rig

1. **Two iPhones** (iOS 16+), **two Android phones** (one Pixel, one Samsung or Xiaomi for stack diversity). Mark each so they're easy to keep track of.
2. **Common signed test build** on both platforms, on the same protocol-version branch. Real installer (TestFlight + side-load), not a debugger build, to make sure release-mode crypto and Proguard rules are exercised.
3. **Airplane mode + BLE on** is the canonical mesh test state. Flip Wi-Fi/cellular for bridge tests.
4. **One observer** (laptop or third phone) running `adb logcat -s BleMeshEngine MeshFgService MessageRouter` for Android and `idevicesyslog | grep -i mesh` for iOS, with timestamps synchronized.
5. **Fix the test users**: import Alice/Bob/Carol/Dave from `shared-vectors/v1/identities.json` into each device. Same fingerprints across runs makes log triage trivial.

## What to do when a row fails

1. Capture logs from both sides for the time window. Note the wall-clock.
2. Diff the inbound JSON against the corresponding `shared-vectors/v1/envelopes/*.json` expected byte string. Most "didn't deliver" turns out to be an unexpected `CodingKey` rename or a missing optional that one side included.
3. If the bytes match but verification fails: check the signature path. Apple uses randomized Ed25519; deterministic-signature byte-comparison will fail. Verify with the public key, don't compare bytes.
4. If chunking is wrong: inspect the first byte (0x00 vs 0x01) and the message-hash bytes. Wrong endianness produces a chunk-group-key mismatch and the receiver silently drops everything.
5. If service-discovery fails entirely: the service UUID is the most common bug. Confirm both sides advertise/scan for `12345678-1234-1234-1234-123456789ABC`.

## Done criteria

Phase 4 ships when rows L1–L13 pass, plus L17 + L18. L14–L20 are stretch goals; L20 is Phase 5 (bridge). Battery (L16) gets re-measured before the public launch, not Phase 4 sign-off.
