# ATSAM ↔ Primitive Mapping V1

**Version:** 1 (normative mapping for serverless Phase B+)  
**Status:** Binding. Does **not** change `RavenEnvelopeV1` wire layout.  
**Sources of truth (shipping):** `ios-native/RAVEN/RAVEN/Core/Security/ATSAM/*`, `MessageContentSealer.swift`, `NoiseSession*.swift`  
**Public overview (non-wire):** `raven-security/ATSAM_PUBLIC_OVERVIEW.md`  
**Outer envelope:** [`RAVEN_ENVELOPE_V1.md`](RAVEN_ENVELOPE_V1.md)  
**Closeout:** [`docs/superpowers/specs/2026-08-12-phase-a-closeout-design.md`](../docs/superpowers/specs/2026-08-12-phase-a-closeout-design.md)

This document maps each ATSAM / sealed-content component to: primitive → purpose → threat → test-vector path → implementation path. Where vectors are still placeholders, that is stated explicitly.

---

## 1. Layering model

```
┌─────────────────────────────────────────────────────────────┐
│  RavenEnvelopeV1  magic RVN1 (4 B) — transport object       │
│  auth: Ed25519 sender_authentication over signing_bytes     │
│  body: opaque message_ciphertext + ratchet_header_ciphertext│
└───────────────────────────┬─────────────────────────────────┘
                            │ carries (does not redefine)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Sealed content frame (8 B magic + AEAD / handshake bytes)  │
│    RVNA1 — ATSAM ChaCha20-Poly1305 (prefer emit v2)         │
│    RVNS1 — Noise transport ciphertext                       │
│    RVNH1 — Noise handshake / 1-RTT                          │
│    RVNP1 — explicit plaintext (legacy / degrade; avoid)     │
└───────────────────────────┬─────────────────────────────────┘
                            │ keys from
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Session key material                                       │
│    ATSAM: hybrid root (X25519 ‖ ML-KEM-768) + chain ratchet │
│    Noise: Noise IK session keys                             │
└─────────────────────────────────────────────────────────────┘
```

**Rule:** Relays and bridges forward `RavenEnvelopeV1` bytes unchanged. They MUST NOT parse or rewrite sealed-content magics inside `message_ciphertext`.

---

## 2. Component map

| Component | Primitive(s) | Purpose | Threat addressed | Test vector path | Implementation path |
|---|---|---|---|---|---|
| **Hybrid pairing** | X25519 ECDH + ML-KEM-768 (FIPS 203) + SHA-256 transcript | Establish shared `K_root` from OOB/QR (or online prekey) without trusting a message server | Passive PQ break of classical ECDH alone; transcript confusion / cross-protocol replay | `raven-security/test-vectors/pairing_root_vectors.json` — **PLACEHOLDER** (`TODO` hex) | `ATSAMHybridPairing.swift`, `ATSAMMLKem.swift`, `ATSAMTranscript.swift`, `ATSAMRootKey.swift` |
| **Root derivation** | HKDF-SHA256 | `K_root = HKDF(ikm=Z_X‖Z_PQ, salt=transcript, info="ATSAM/v1/pair-init"‖transcript, L=32)` | Binding pairing context into root; PRG expansion | Same pairing file — **PLACEHOLDER** | `ATSAMRootKey.swift` / `ATSAMRootDerivation` |
| **Key tree** | HKDF-SHA256 per typed label | Domain-separated sub-keys: BBE, Ghost Handshake, Ghost Route, PV-Stealth, PV seed, msg-seal seed | Cross-layer key reuse | No committed KATs yet | `ATSAMKeyTree.swift`, labels in `ATSAMConstants.swift` |
| **Chain ratchet (v2)** | HKDF-SHA256 one-way chain | Per-direction FS: advance `CK`, derive `K_msg`, destroy predecessor; bounded skipped-key cache | Device compromise decrypting past traffic | No `rvn1` KATs yet; iOS unit tests `ATSAMChainRatchetTests.swift` | `ATSAMChainRatchet.swift`, persistence in `ATSAMRootStorage.swift` |
| **Message seal RVNA1** | ChaCha20-Poly1305 (suite=1) | Confidentiality + integrity of text body; AAD binds sender/recipient/msgId (/index for v2) | Eavesdrop; ciphertext reroute; (v2) past-message recovery after compromise | Envelope fixtures use **ASCII placeholders**, not real AEAD; real KATs **PLACEHOLDER** | `ATSAMMessageSealer.swift` |
| **Noise seal RVNS1** | Noise transport AEAD (existing session) | Fallback when no ATSAM root | Same content threats under classical Noise | Placeholder body in `rvn1/envelope/message_alice_to_bob.json` | `MessageContentSealer.swift` |
| **Noise handshake RVNH1** | Noise IK | First contact / QR bootstrap before ATSAM pair | Unauthenticated first message path | None in `rvn1/` | `NoiseSession.swift`, `MessageContentSealer.swift` |
| **Explicit plaintext RVNP1** | none (cleartext) | Legacy degrade path | **Does not address** confidentiality — receivers must treat carefully | N/A | `MessageContentSealer.swift` |
| **Ghost Route / K_route** | HMAC-SHA256 | Unlinkable recipient tags (pair-scoped) | Relay linkability of same recipient | `raven-security/test-vectors/routing_tag_vectors.json` — **PLACEHOLDER**; protocol routing tags use separate `rvn1/route` vectors | `ATSAMConstants` GhostRoute labels; protocol tags: `routing_tag.py` + `shared-vectors/rvn1/routing/` |
| **Protocol routing tag** | HMAC-SHA256(`K_route`, `"rvn1/route"‖epoch‖counter`)[:16] | Envelope `routing_tag` field (mailbox rendezvous) | Same class; **distinct domain** from ATSAM GhostRoute labels | `shared-vectors/rvn1/routing/*.json` — **REAL** | `protocol/reference/raven_protocol/routing_tag.py` |
| **Envelope auth** | Ed25519 | Authorship of immutable envelope fields + ciphertext hashes | Forgery / relay re-authoring | `shared-vectors/rvn1/envelope/`, negatives — **REAL** | `envelope.py`; device key per Identity V1 |
| **Identity / address** | Ed25519 → SHA-256[:20] → Bech32m HRP `rvn` | Self-sovereign addressing | Server-issued ID dependency | `shared-vectors/rvn1/address/`, `identities/` — **REAL** | `address.py`, `bech32m.py` |
| **BBE / Ghost Handshake / PV** | HMAC / (planned) Wegman-Carter | Discovery, live confirm, vault — **higher layers**, not required for Phase B DM | See public overview | Placeholder vectors under `raven-security/test-vectors/` | Mostly Stage-1 labels only; full layers incomplete |

---

## 3. Sealed content wire layouts (normative for implementers)

### 3.1 Magics (8 bytes, NUL-padded)

| Magic ASCII | Bytes (hex) | Role |
|---|---|---|
| `RVNA1\0\0\0` | `52 56 4E 41 31 00 00 00` | ATSAM sealed body |
| `RVNS1\0\0\0` | `52 56 4E 53 31 00 00 00` | Noise sealed body |
| `RVNH1\0\0\0` | `52 56 4E 48 31 00 00 00` | Noise handshake |
| `RVNP1\0\0\0` | `52 56 4E 50 31 00 00 00` | Explicit plaintext |

Outer envelope magic is **4-byte** `RVN1` = `52 56 4E 31` — different length and purpose.

### 3.2 RVNA1 v1 (accept only; do not emit)

```
magic(8) || proto=0x01 || suite=0x01 || nonce(12) || ciphertext || tag(16)
```

Key: deterministic HKDF from long-lived root + sender‖recipient‖msgId — **no forward secrecy**.

### 3.3 RVNA1 v2 (emit)

```
magic(8) || proto=0x02 || suite=0x01 || index_be32(4) || nonce(12) || ciphertext || tag(16)
```

- AEAD: ChaCha20-Poly1305, max wire 256 KiB.
- Chain:
  - `CK₀ = HKDF(K_root, info="ATSAM/v2/chain-init"‖0‖S‖0‖R)`
  - `K_msg = HKDF(CK_i, salt="ATSAM/v2/msg-seal/salt", info="ATSAM/v2/msg-key"‖0‖S‖0‖R)` — **msgId is NOT in K_msg** (skipped-key cache cannot know future ids; Swift `ATSAMChainRatchet.messageKey` binds identity only; msgId is in AAD)
  - `CK_{i+1} = HKDF(CK_i, info="ATSAM/v2/chain-advance")`
- Bounds: `maxSkippedKeys = maxForwardJump = 256`.
- AAD (v2): `SHA-256("ATSAM/v1/msg-seal/aad" ‖ 0 ‖ proto ‖ suite ‖ index_be ‖ 0 ‖ sender ‖ 0 ‖ recipient ‖ 0 ‖ msgId)`.

### 3.4 Root (pairing)

```
ikm = Z_X || Z_PQ          # 32 ‖ 32
K_root = HKDF-SHA256(ikm, salt=transcript_hash,
                     info="ATSAM/v1/pair-init" || transcript_hash, L=32)
```

Transcript domain: `"ATSAM/v1/transcript"` prepended before SHA-256 (`ATSAMConstants.transcriptDomain`).

---

## 4. Binding: sealed frames ↔ RavenEnvelopeV1

**Normative binding (does not alter the 86-byte prefix):**

1. For `env_type = 1` (message), `message_ciphertext` MUST be a sealed content frame whose first 8 bytes are one of `RVNA1` / `RVNS1` / `RVNH1` (or, only for explicit degrade tests, `RVNP1`). Implementations MAY temporarily carry opaque test placeholders during codec vector tests; production sends MUST use a real sealer.
2. `ratchet_header_ciphertext` is opaque session metadata for the sealer (may be empty length `hdr_len=0` when the sealer encodes all needed state in the body, e.g. RVNA1 v2 index-in-body).
3. Base64 encoding of sealed frames is a **legacy MeshEnvelope / JSON** convenience. On the binary `RavenEnvelopeV1` wire, ciphertext fields are **raw bytes**.
4. Envelope pipeline stages 1–10 (`RAVEN_ENVELOPE_V1.md` §6) MUST succeed before any sealer decrypt. Signature verification does not imply plaintext recovery.
5. Flags bit0 (`hybridPQ`) SHOULD be set when the body is RVNA1 under a hybrid root; receivers MUST NOT treat the flag as authenticated proof of PQ (auth is the signature + sealer AAD).

**Migration note:** Until Phase G, iOS may still nest sealed frames inside `MeshEnvelope` JSON. Interop with `raven-node` requires packing the same frame bytes into `RavenEnvelopeV1`.

**Identity bind for serverless:** Phase B Rust SHOULD use `RavenAddressV1` (or raw 32-byte Ed25519 pub hex/bytes) in place of `userId` in AAD/chain-init, per Identity §4 constraints. Until real ATSAM KATs exist, a **vector-compatible authenticated stub sealer** (envelope + Ed25519 + AEAD with documented migration hooks) is acceptable for two-node DM — full hybrid+ratchet parity is the next crypto milestone.

**Interim stub (`proto=0x7F`):** Rust `raven-core::seal` and iOS `RavenInterimSeal` share pairwise demo KDF + ChaCha20-Poly1305 under RVNA1 magic. Shipping ATSAM remains `0x01` (accept) / `0x02` (emit). Terminal nodes **classify** ATSAM frames as opaque: verify outer envelope, parse RVNA1 header (reject truncated / bad suite), ACK/forward, do **not** claim plaintext recovery until the hybrid ratchet is ported.

**Portable without ML-KEM:** Rust `raven-core::atsam_kdf` + `atsam_aead` match iOS chain labels / AAD / ChaCha20-Poly1305 for **known** `K_root` — see `shared-vectors/rvn1/atsam/chain_kdf_001.json` and `rvna1_v2_aead_known_root_001.json`. Network path without a root still classifies shipping ATSAM as opaque.

**iOS LAN + BLE (flagged):** `FeatureFlag.ravenEnvelopeV1` + `RavenServerlessLanPath` / `RavenBleRvn1Carrier`. MeshEnvelope remains default when the flag is off.

---

## 5. Honesty table — vectors

| Claim | Reality |
|---|---|
| Outer envelope pack/sign/verify | **Proven** by `shared-vectors/rvn1/envelope/*` + negatives |
| Address / fingerprint / ack / alias / caps / device cert / route tag | **Proven** under `shared-vectors/rvn1/` |
| Interim pairwise demo key (`0x7F`) | **Proven** — `seal/interim_pairwise_001.json` (Rust + Swift) |
| ATSAM v2 chain HKDF labels (no AEAD) | **Proven** — `atsam/chain_kdf_001.json` (Rust `atsam_kdf` + Swift ratchet) |
| RVNA1 header layout classify | **Proven** — `atsam/rvna1_header_layouts_001.json` |
| RVNA1 v2 AEAD + AAD with **known** `K_root` | **Proven** — `atsam/rvna1_v2_aead_known_root_001.json` (Rust `atsam_aead`; no ML-KEM) |
| Envelope body bytes are real ATSAM ciphertext | **False today** for envelope fixtures (ASCII placeholders); live iOS emits real RVNA1 |
| Rust decrypt without known root / ML-KEM pairing | **Not implemented** — network path still opaque ACK; KATs assume supplied `K_root` |
| `raven-security/test-vectors/pairing_root_vectors.json` | **Placeholder** |
| `bbe_discovery`, `live_confirmation`, `routing_tag` (security tree), `vault_mode` | **Placeholder** |
| iOS ATSAM unit tests | Exist for ratchet/pairing agreement; chain KDF shared with Rust |

Phase B must not claim “ATSAM vectors green” until placeholder files are replaced with generator output matching Swift/`raven-core`.

---

## 6. KDF label catalog (stable strings)

Do not rename. Collision or rewrite invalidates sessions.

| Label | Use |
|---|---|
| `ATSAM/v1/pair-init` | Root HKDF info prefix |
| `ATSAM/v1/root` | Reserved second-stage root |
| `ATSAM/v1/BBE/discovery` | BBE discovery key |
| `ATSAM/v1/BBE/ratchet` | BBE epoch ratchet |
| `ATSAM/v1/BBE/pair-master` | Stable partition |
| `ATSAM/v1/BBE/slot` | Slot HMAC prefix |
| `ATSAM/v1/BBE/stable-partition-sort` | Sort HMAC prefix |
| `ATSAM/v1/GhostHandshake/live` | Live confirm key |
| `ATSAM/v1/GhostHandshake/response` | Response HMAC prefix |
| `ATSAM/v1/GhostRoute/recipient-tag` | Route tag key |
| `ATSAM/v1/GhostRoute/recipient` | Tag HMAC prefix |
| `ATSAM/v1/PV-Stealth/lookup` | Lookup tag key |
| `ATSAM/v1/ProximaVault/seed` | PV seed channel |
| `ATSAM/v1/msg-seal` | Msg-seal seed (v1 path) |
| `ATSAM/v1/msg-seal/aad` | AAD domain |
| `ATSAM/v2/chain-init` | Directional chain seed |
| `ATSAM/v2/msg-key` | Per-message key info |
| `ATSAM/v2/chain-advance` | One-way chain step |
| `ATSAM/v2/msg-seal/salt` | Msg-key HKDF salt |
| `ATSAM/v1/transcript` | Transcript domain separator |

Protocol (non-ATSAM) domains: `rvn1/ack`, `rvn1/alias`, `rvn1/devcert`, `rvn1/caps`, `rvn1/route`.

---

## 7. Phase B implementation guidance

1. Implement envelope/address/identity against `rvn1` first — gate for any network code.
2. For two-node DM before full ML-KEM port: AEAD-seal plaintext into an `RVNA1`-shaped or clearly versioned stub frame, document hooks to swap in hybrid root + chain ratchet without changing outer envelope.
3. Persist outgoing queue encrypted at rest; never log private keys.
4. Prefer address-keyed session dirs from day one (`root|<rvn1…>`), with a commented migration path from `userId`.

---

## See also

- [`SPEC.md`](SPEC.md)
- [`RAVEN_ENVELOPE_V1.md`](RAVEN_ENVELOPE_V1.md) §7 Binding
- [`RAVEN_IDENTITY_V1.md`](RAVEN_IDENTITY_V1.md) §4
- `docs/THREAT_MODEL.md`
