# RAVEN Serverless Pivot — Protocol/Crypto/Mesh Audit

**Date:** 2026-08-12
**Scope:** Development-order step 01 of the serverless-network mission: audit the existing
protocol, crypto, mesh, storage, server, and client code before freezing the V1 protocol.
**Method:** 12 parallel subsystem audits (full structured results archived in the session
workflow journal; this document is the synthesis).

---

## 1. Headline: the mission document underestimates the codebase

Several mission steps are already partially or fully done:

| Mission assumption | Audited reality |
|---|---|
| "Remove the concept of a central message server" is future work | The mesh→server uplink is already a documented no-op; `ConversationRepository` already declares "RAVEN is a serverless, no-account app"; the E2E envelope is already opaque to the server |
| libp2p is a recommendation | A **working gomobile go-libp2p v0.48.0 bridge exists** (`ios-native/RAVEN/Libp2pBridge/bridge.go`): DHT discovery, Circuit Relay v2, DCUtR hole punching, `/raven/bridge/1.0.0` streams, plus a complete serverless contact-add rendezvous (`/raven/rdv/1.0.0`) with ephemeral identities. Milestones 1–4 of `LIBP2P_BRIDGE_PLAN.md` are done, with an E2E relay-circuit test |
| Identity must be designed | Per-device Ed25519 + X25519 identity in Keychain is shipped, and the Ed25519 device key **already deterministically derives the libp2p PeerID** (validated Swift↔Go vectors, `MeshProtocols.swift:158-200`) |
| Cryptography must be chosen | ATSAM is shipped and default-on: X25519 + ML-KEM-768 hybrid pairing root, HKDF sub-key tree, per-direction chain ratchet (forward secrecy, no PCS), ChaCha20-Poly1305 sealed frames (`RVNA1` v2), stateless 1-RTT Noise IK (`RVNH1`) purpose-built for serverless QR-only first contact |
| Test vectors must be created | `shared-vectors/v1` holds 30 real, frozen, deterministic cross-platform vectors with a Python generator and a clean-room SwiftPM reference implementation (`RAVEN-iOS/MeshV1`) — but the **ATSAM vectors in `raven-security/test-vectors/` are 100% "TODO" placeholders** |
| Store-and-forward must be designed | The server's `bridge_envelopes` park is already zero-knowledge (opaque blob, idempotency key, no recipient column, 24 h GC), and the unmounted `routers/ghost_route.py` is exactly the tag-keyed mailbox primitive the decentralized store needs |

**The pivot is therefore not a rewrite — it is a consolidation**: one canonical Rust
implementation of formats that today exist as 4-way hand-synced Swift/C#/Kotlin/Go copies.

## 2. Subsystem status

### iOS crypto core (`ios-native/RAVEN/RAVEN/Core/Security/`) — REUSE core, strip server entanglement
Three coexisting E2E stacks: **ATSAM** (shipped, default-on), hand-rolled
**Noise_IK_25519_ChaChaPoly_SHA256** with a stateless 1-RTT mode, and an unwired
X3DH/Double-Ratchet module (`E2EE/`, flag-off, server-prekey-dependent — isolate).
Message bodies framed by magics `RVNA1`/`RVNS1`/`RVNH1`/`RVNP1` with SHA-256 AADs binding
(sender, recipient, msgId). **Blockers to carry into the plan:**
- The entire ATSAM key schedule (roots, chain seeds, transcripts, AADs) is keyed by
  **server-issued userIds** — the serverless identity must be canonicalized and a migration defined.
- Acknowledged `RVNP1` plaintext-downgrade gap in `MessageContentSealer` (dispatch on wire magic).
- Peer key pins live in **plaintext UserDefaults** (`PeerKeyDirectory`) — move to Keychain.
- No post-compromise security on any shipped path (symmetric-only ratchet; DH ratchet flag-off).

### iOS BLE mesh (`Core/Mesh/`) — ADAPT engine, REUSE policy + control frames
5,361-line CoreBluetooth engine: Binary Spray-and-Wait + PRoPHET + probabilistic gossip,
persistent SQLite relay queue, Bloom anti-entropy, signed ACK/STOP, chunked framing.
Two dialects: legacy v1 JSON (pv=16/17) and the **RUM v2 binary codec** (60-byte header,
byte-identical across iOS/Mac/Windows/Android *by convention only*). `BridgeTransport`
seam (`MeshProtocols.swift`) is purpose-built for the pivot. Issues: `Data.hashValue` as
chunk key (unstable), DTN fields relay-mutable by design, premium-gated wire parameters
(unenforceable serverlessly), sealed-sender v2 designed but gated.

### Go libp2p bridge — ADAPT into Rust node; **commit untracked work first**
Real and working; zero FastAPI dependencies. Gaps: offline mailbox (milestone 5) entirely
unimplemented (`drainPending` returns `[]`); bootstrap list empty by default (bridge inert
on fresh installs); 24 MiB pre-validation allocation per inbound frame (DoS window);
`cmd/relay` ships a hardcoded dev identity seed; bridge marks delivered on stream *write*
(no receiver ACK). ⚠️ `rendezvous.go` and both test files are **untracked**; `bridge.go`/
`go.mod` have uncommitted modifications — the working rendezvous feature exists only in
the working tree.

### MeshV1 package + shared-vectors — REUSE as the conformance mechanism
The strongest foundation in the repo: deterministic Python generator, frozen-v1 policy,
one-command sync, SwiftPM clean-room consumer. But **no app target imports MeshV1**, the
shipping app's signing form has drifted ahead of the frozen vectors (`sf:2` sealed-sender,
`msl` mediaSealed, `mc` mediaCipher), pipe canonicalization has **no field escaping**
(`|` in user-controlled fields shifts boundaries), and **two incompatible fingerprint
schemes** coexist (MeshV1 hex vs shipping-app base64-derived).

### raven-security — ADAPT docs; vectors are placeholders
Honest threat model, but pre-pivot: no coverage of Sybil, eclipse, DHT poisoning,
malicious store nodes, alias impersonation, or protocol downgrade. Trust Roadmap Stage 4
already names **Rust** as the reference-implementation language. Contains a personal CV
(PII + undisclosed protocol details) that should move out of a public security repo.

### FastAPI server — decoupling map
38-router monolith; ~two-thirds irrelevant to text messaging. Adapt the concepts of:
`mesh.py` bridge-envelope park (zero-knowledge store contract), `ghost_route.py` tag-keyed
mailbox, `atsam_prekey.py` bundle formats, fingerprint derivation. Replace: central
mailbox, WS fan-out, presence, auth plane, server-held group keys (**not E2E** — server
mints/stores AES group keys in plaintext). Server can decrypt any legacy body (Fernet
master key) and always sees full metadata, including up to 500 chars of quoted content in
reply previews. 13 routers are defined but never mounted (dead drift).

### Windows client — REUSE deterministic layer as conformance twin
Crypto primitives + envelope signing byte-compatible with iOS (xUnit interop vectors).
BLE engine is a hardware-untested skeleton; Noise DH throws `NotImplementedException`;
runtime speaks only v1 JSON. Drifted behind iOS: missing `mc` field, missing
`doubleRatchet` capability bit, still ships removed `mesh_post_v1`.

### Android — server-first; no mesh compiled
Own homegrown E2EE (simplified X3DH + chain ratchet) that is **NOT interoperable with iOS
yet shares the same `RVNS1` magic** — a live interop hazard. Byte-identical Kotlin RUM v2
codec + Noise IK exist in `legacy/mesh-protocol/` as dead code. Android is a consumer of
the future Rust core, not a source.

### iOS storage/realtime — REUSE the store, repoint the feeders
SQLCipher DB as source of truth; dual-channel outbox ("First Delivery Wins") with a
`bridge` job channel **already defined for libp2p**. `RealtimeEngine`/`PushNotificationService`
are 100% FastAPI-coupled (replace/isolate). Watch out: no schema version (37 migrations
re-run every launch with substring-matched error swallowing); DB deleted on key-validation
failure (silent history wipe); ISO-8601 *string* comparison for conversation ordering.

### Others
- **Mac**: verbatim iOS core copies that have already drifted (crash bug fixed on iOS
  2026-05-10 still present on Mac) — the copy-sync process demonstrably fails; strongest
  argument for the single canonical Rust core.
- **Watch**: pure WCSession projection of the phone — defer. Its standalone-LTE path is
  FastAPI-only — isolate.
- **Flutter (`lib/`)**: legacy prototype. RSA-2048/AES-CBC with an effectively
  **predictable RNG** (Fortuna seeded from wall-clock ms), dead mesh MethodChannel,
  wire-incompatible envelopes that reuse the same BLE service UUID. Quarantine; treat any
  Flutter-era archived ciphertext as weakly protected.
- **simulation/**: a Gemini-driven synthetic-user bot farm against the central server —
  contributes nothing to the 1,000-node network simulation requirement; build that fresh.

## 3. Consolidated top risks (feed into THREAT_MODEL and the plan)

1. **Identity namespace**: ATSAM binds everything to server userIds; canonical serverless
   identity + migration is the single most load-bearing decision (Phase A).
2. **Plaintext downgrade** (`RVNP1`) and **legacy-plaintext feature flags** — a store node
   on the bridge path could downgrade content unless envelope-level policy forbids it.
3. **Unversioned/ambiguous canonical forms**: pipe-signing without escaping; envelopes
   unversioned except `EncryptedMeshPayload v:1`; three different signing rules.
4. **Metadata**: signed-only broadcasts leak sender/recipient; ACKs leak both parties +
   status; stable PeerID (= device key) links BLE identity, authorship, and internet
   transport identity with no rotation story.
5. **Trust storage**: pins in UserDefaults; TOFU first-claim lock-in; bridge-attestation
   exceptions that assume FastAPI semantics.
6. **Two cap systems** for DTN bounds (decode caps ≠ validate caps); premium-tier wire
   parameters leak account tier and are unenforceable.
7. **No serverless-adversary threat modeling** yet (Sybil/eclipse/DHT poisoning/malicious
   store nodes/downgrade).
8. **Working-tree-only code**: the rendezvous protocol and bridge modifications are
   uncommitted; a `git clean` would destroy the only copy.

## 4. What the canonical Rust node inherits (decision summary)

| Layer | Verdict | Source of truth to port |
|---|---|---|
| Device identity (Ed25519+X25519, Keychain, rotation attestation) | Reuse | `DeviceIdentityService.swift` |
| PeerID ⇄ identity-key mapping | Reuse | `MeshProtocols.swift` `Libp2pPeerID` + Go `peeridvec` |
| Pairing + sealing (ATSAM RVNA1 v2, transcripts, key tree, chain ratchet) | Reuse (port) | `ATSAM*` Swift + constants |
| First contact (stateless 1-RTT Noise IK, RVNH1) | Reuse (port) | `NoiseSession(Store).swift` |
| Envelope wire format | **New (RavenEnvelopeV1)** — informed by RUM v2 header + sealed-sender v2 design | `RUMProtocolV2.swift`, `sealed-sender-mesh-design.md` |
| Routing/mailbox tags | Adapt | ATSAM GhostRoute labels + `routers/ghost_route.py` |
| DTN policy (spray-and-wait, PRoPHET, dedup, relay queue) | Adapt (behavior-port) | `BLEMeshEngine.swift` + `MeshV1` routing math |
| Store contract (opaque, idempotent, TTL, GC) | Adapt | `routers/mesh.py` bridge-envelope park |
| Conformance vectors | Reuse mechanism, new `rvn1` tree | `shared-vectors/` + `generate_v1.py` |
| BLE GATT/chunking | Reuse (per-platform driver) | `MeshChunking.swift` (fix chunk key) |

## 5. Corrections this audit forces on the mission document

- "The present Raven repository still contains a substantial FastAPI server" — true, but
  the *messaging* path is already mostly decoupled; the real work is trust/identity
  re-keying and the offline mailbox, not envelope opacity.
- "Prefer Rust; avoid drift" — confirmed empirically: Mac carries a crash bug iOS fixed
  three months ago in a file that is contractually "byte-identical."
- "Do not rewrite everything at once" — reinforced: ATSAM, the BLE engine, the outbox
  state machine, and the vector mechanism are mature and survive review.
