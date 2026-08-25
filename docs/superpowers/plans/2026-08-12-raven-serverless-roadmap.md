# RAVEN Serverless Network — Master Roadmap

> **This is the umbrella document.** It maps the serverless-network mission (the 122-section
> engineering directive, 2026-08-12) onto the audited codebase and slices it into
> independently executable plans. Each phase gets its own plan in this directory, written
> only after its predecessor locks the decisions it depends on.
>
> Grounding: [docs/AUDIT_SERVERLESS_PIVOT_2026-08-12.md](../../AUDIT_SERVERLESS_PIVOT_2026-08-12.md)

**Goal:** A Raven text message can be created, authenticated, encrypted, routed, stored,
forwarded, acknowledged and decrypted with no trusted central Raven server, across
Windows/macOS/Linux/iOS, over internet and BLE, with `ash` as the terminal entry point.

**Architecture:** One canonical Rust implementation (`raven-core` protocol + `raven-node`
daemon + `ash` CLI) becomes the source of truth for formats that today exist as 4-way
hand-synced Swift/C#/Kotlin/Go copies. Swift/C#/Kotlin become UI + platform-transport
drivers (BLE stays native) over the same frozen wire formats, gated by shared vectors.

**Tech stack:** Rust (tokio, rust-libp2p, SQLite via rusqlite+SQLCipher), existing Swift
ATSAM/Noise/BLE as interop peers, Python vector generator (existing `shared-vectors`
mechanism), gomobile Go bridge retained on iOS until the Rust FFI replaces it.

---

## Standing policy (mission step 02)

**Freeze central-server changes unrelated to this project.** The FastAPI server gets
security fixes only. New feature work happens on the serverless path. The 13 unmounted
routers are dead code — do not mount them.

**Working-tree hazard (from the audit):** `Libp2pBridge/rendezvous.go` and both bridge
test files are untracked, and `bridge.go`/`go.mod` carry uncommitted modifications. The
first act of Phase A execution is committing that work to `feat/messenger-pivot`.

---

## Phase map

Mission development-order steps → phases. ✅ = already done per audit, ◐ = partial.

| Phase | Mission steps | Deliverable | Status / gate |
|---|---|---|---|
| **A. Protocol freeze** | 03–08 | THREAT_MODEL.md, 8 × `protocol/RAVEN_*_V1.md`, real `rvn1` test vectors | **Closed** 2026-08-12 — closeout: `../specs/2026-08-12-phase-a-closeout-design.md`; mapping: `protocol/ATSAM_PRIMITIVE_MAPPING_V1.md`. Open binding: ATSAM KATs placeholders, userId→address migration, MeshEnvelope until Phase G |
| **B. Rust core, two nodes** | 09–11 | `raven-core` crate: identity, envelope codec, seal (ATSAM-compatible), persistent encrypted queue, two-process direct messaging w/ static addresses, ACK, restart persistence | **In progress** under `node/`. Gate: all `rvn1` vectors pass in Rust |
| **C. Daemon + `ash` CLI** | 12–15 | `raven-node` (launchd/systemd/Windows service, authenticated local IPC) + `ash` (Messages / Send / Contacts, direct command mode) | Gate: mission §119 steps 1–7 on Linux+macOS |
| **D. Discovery** | 16–18 | Kademlia DHT, bootstrap config, signed alias records, `ash send @alias` | ◐ DHT client mode exists in Go bridge; alias layer is new |
| **E. NAT traversal** | 19–21 | AutoNAT, Circuit Relay v2, DCUtR in the Rust node | ◐ Production-disabled Rust client profile composes bounded AutoNAT v2, Relay v2 and DCUtR with TCP/QUIC; real multi-NAT/CGNAT, relay policy, stable identity, and soak gates remain |
| **F. Offline delivery** | 22–24 | Mailbox rendezvous tags, encrypted store nodes, replication ×3, TTL | ◐ Separate mailbox tags, strict opaque store, and gated libp2p PUT/GET survive sender disconnect + store restart; multi-store discovery/replication ×3 and live session-derived polling remain |
| **G. BLE convergence** | 25 | BLE carries RavenEnvelopeV1; fix chunk-key (`Data.hashValue` → deterministic hash); retire premium-gated wire params | Gate: mission tests 6–8 (BLE, bridge both directions) |
| **H. iOS interop** | 26–27 | iOS speaks RavenEnvelopeV1 end-to-end (Rust FFI or vector-gated Swift twin); Linux↔iPhone both ways | Gate: mission §119 full demo |
| **I. Decentralized by default** | 28–31 | Adversarial tests, 1k-node simulation (build fresh — `simulation/` is a bot farm, not a simulator), external review, then central route demoted to legacy fallback | Gate: mission §118 security gate |

Do not reorder: C before D is deliberate (CLI against static-address nodes proves the
core before discovery adds failure modes), matching mission §101–103.

## Decisions locked by the audit (Phase A encodes these normatively)

1. **Identity**: keep per-device Ed25519+X25519; add a user-identity Ed25519 key above it
   with device certificates. The device-key → libp2p PeerID derivation is already shipped
   and validated — it stays. ATSAM's userId-keyed state gets a migration to canonical IDs.
2. **Crypto**: no new primitives. ATSAM RVNA1 v2 (hybrid pairing, chain ratchet) is the
   pairwise seal; stateless Noise IK (RVNH1) is first contact. The unwired X3DH/DR stack
   stays isolated. PCS (DH ratchet) is a tracked later phase, not V1.
3. **Envelope**: new binary `RavenEnvelopeV1` (sealed-sender by construction, routing tags,
   no plaintext identities), carrying the existing sealed content frames as payload.
   Mesh v1 JSON remains legacy-interop input until Phase G.
4. **Vectors**: extend the existing `shared-vectors` mechanism with a new `rvn1` tree;
   Python generator first (matches tooling), Rust must reproduce byte-for-byte in Phase B;
   the placeholder `raven-security/test-vectors` get real values from the same generator.
5. **Transports**: rust-libp2p QUIC+TCP, Noise, Kademlia, AutoNAT, Relay v2, DCUtR —
   mirroring what the Go bridge already proved. Go bridge stays on iOS until Phase H.
6. **No blockchain, no payments, no groups, text only** (mission §109–115).

## Cross-phase invariants (every plan inherits these)

- Security → Correctness → Interoperability → Reliability → Performance, in that order.
- Every wire format versioned; every canonical form length-prefixed (no unescaped
  pipe-joining — audit risk #3); every claim vector-backed or threat-model-scoped.
- No plaintext messages, keys, or contact lists in logs — including debug builds.
- Persistent outgoing queue before any socket write; delivery states per mission §26
  (never claim Delivered on relay accept — the Go bridge currently does; Phase B fixes).
- TDD per task; commits per task; `shared-vectors` regeneration must be a no-op diff.
