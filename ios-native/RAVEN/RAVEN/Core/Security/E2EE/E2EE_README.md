# RAVEN E2EE Module

End-to-end encryption for RAVEN, designed so that **even server
operators with full DB access cannot read user messages**.

---

## What this module gives you (Phase 1 — implemented)

| File | Role |
|------|------|
| `RatchetCrypto.swift` | KDF_RK, KDF_CK, AEAD primitives over Apple CryptoKit. |
| `RatchetHeader.swift` | Per-message header (DH key, msg num, prev chain len). |
| `RatchetState.swift` | Mutable session state (root key, chains, skipped keys). |
| `DoubleRatchet.swift` | `encrypt` / `decrypt` with DH ratchet steps + skipped-key cache. |
| `PreKeyBundle.swift` | X3DH bundle types (signed pre-key, one-time pre-keys). |
| `X3DH.swift` | Initial async key agreement (4-DH combinator). |
| `RatchetSessionStore.swift` | SQLite (SQLCipher-encrypted) persistence. |
| `E2EEService.swift` | Public façade — `encrypt(toPeer:)` / `decrypt(fromPeer:)`. |
| `DeviceIdentity+E2EE.swift` | Bridge to existing X25519 keychain key. |

### Properties guaranteed

* **Forward secrecy** — past messages stay decrypted even if today's
  state leaks (each chain key is overwritten as it advances).
* **Post-compromise security** — once a fresh DH ratchet step lands,
  an attacker who stole the prior state can't read new traffic.
* **Out-of-order delivery** — up to 1000 skipped message keys cached
  per session; relevant for lossy mesh.
* **Header binding** — header fields are AEAD Associated Data, so
  MITM rewrites invalidate the GCM tag.
* **Transport agnostic** — same code path works for server-routed
  *and* mesh-routed messages. The ratchet doesn't know about transport.

### What it does NOT do yet

* No production wiring into `MessageStore` / `MeshTransport`.
  Drop-in points are documented inline in `E2EEService.swift`.
* No header encryption (Signal's "Header Encryption" variant). Adds
  metadata privacy at the cost of a bit more state. Easy follow-up.
* No multi-device sender keys for groups. Pairwise sessions are fine
  for small groups; for >50-member groups switch to MLS (RFC 9420).

---

## Phase 2 — OPAQUE Password Authentication

**Goal:** server never learns the user's password — not at signup,
not at login, not even in a leaked DB. An attacker with full DB
access can only attempt **one online guess at a time**, never an
offline dictionary attack.

### Why OPAQUE over current bcrypt

Today, in `auth.py`:
```
register()  → bcrypt(password, salt) → password_hash
login()     → bcrypt verify → JWT
```
If the DB is exfiltrated:
* Attacker has every `password_hash`.
* GPU farms run ~10⁹ guesses/s against bcrypt.
* Common passwords fall in seconds.

With OPAQUE:
* Server stores an `envelope` per user. The envelope is a private-key
  blob *encrypted under a key the server cannot derive without the
  password*.
* No offline guessing — every attempt requires a fresh server round
  trip (which can be rate-limited / locked out).

### Protocol summary

```
Registration:
  1. user → blinded(password) → server
  2. server → OPRF eval → user
  3. user computes RW = HKDF(unblind(eval) ‖ password)
  4. user encrypts (long-term keypair, salt) under RW → envelope
  5. user → envelope → server   ← server stores opaque blob

Login (Authenticated Key Exchange):
  1. user → blinded(password) → server
  2. server → OPRF eval + envelope + ephemeral DH → user
  3. user derives RW (same as registration), decrypts envelope
  4. mutual DH-AKE → session key (used to wrap the JWT)

If the password was wrong, the envelope decryption fails — the user
detects this *locally* and aborts. The server never learns whether
the guess was correct.
```

### Implementation plan

| Layer | Library | Effort |
|-------|---------|--------|
| Swift client | `libopaque` (https://github.com/stef/libopaque) via Swift→C bridge | 1–2 days |
| Python server | `opaque-python` or `opaque-ke` via PyO3 | 1 day |
| Endpoints | `/api/auth/opaque/register/{init,finish}`, `/api/auth/opaque/login/{init,finish}` | 1 day |
| DB | New `opaque_envelopes` table; deprecate `password_hash` once migrated | 0.5 day |
| Migration | Dual-mode login: try OPAQUE first, fall through to bcrypt; rotate on next successful bcrypt login | 2 days |

**Migration is the hard part** — every existing user has a bcrypt
password we can't convert to OPAQUE without their plaintext password
(which we don't have). Solution: opportunistic migration on
successful login. The user types their password, we run OPAQUE
registration once with it, store the envelope, drop the bcrypt hash.
After 90 days of dual-mode, force-migrate or require password reset.

### Why we deferred to Phase 2

* Server-side coordination is required (Python lib, endpoint design,
  migration script).
* Touching the auth flow has high blast radius — needs its own
  feature flag, staged rollout, and rollback plan.
* Phase 1 (E2EE messages) is independent and ships value alone.

---

## Phase 3 — Sealed Sender + Cover Traffic

After Phase 1 + 2 ship, metadata privacy is the next frontier.

* **Sealed Sender:** wrap message envelope so the server only sees
  the receiver, never the sender. Receiver verifies sender by the
  inner Ed25519 signature.
* **Cover traffic:** every device emits a small noise packet at a
  random interval to a random peer, indistinguishable from real
  traffic. Defeats traffic-pattern analysis.

Easy on top of the Phase 1 `E2EEWirePacket` — just add an outer
sealed wrapper before transport.

---

## Phase 4 — Post-Quantum Hybrid

Add Kyber768 alongside X25519 in X3DH and the DH ratchet. Required
by the "harvest now, decrypt later" threat model: anyone recording
ciphertext today can decrypt it once large quantum computers exist.

Apple ships `Kyber768` in iOS 18+ via `KEM` types. Wire the second
KEM in parallel — the combinator is `HKDF(X25519_DH ‖ Kyber_SS)`.

---

## How to wire Phase 1 into MessageStore (when ready)

```swift
// Outgoing
let plaintextBody = try JSONEncoder().encode(messageBody)
let wirePacket = try await E2EEService.shared.encrypt(
    toPeer: PeerAddress(userId: peerUserId, deviceId: peerDeviceId),
    plaintext: plaintextBody,
    associatedData: Data(message.id.utf8)
)
let wireData = try JSONEncoder().encode(wirePacket)
// → send wireData via existing transport (server REST OR MeshEnvelope.body)

// Incoming
let wirePacket = try JSONDecoder().decode(E2EEWirePacket.self, from: wireData)
let plaintextBody = try await E2EEService.shared.decrypt(
    fromPeer: PeerAddress(userId: senderUserId, deviceId: senderDeviceId),
    wirePacket: wirePacket,
    associatedData: Data(message.id.utf8)
)
let messageBody = try JSONDecoder().decode(MessageBody.self, from: plaintextBody)
```

The same two lines also work over BLE — wrap the wireData inside
`MeshEnvelope.body` and the ratchet doesn't care.

---

## Audit checklist before production

- [ ] Run encrypt → wire-encode → wire-decode → decrypt round-trip
      against fixed Signal Double Ratchet test vectors.
- [ ] Verify skipped-key cache is bounded under flooding (artificial
      `n = 10⁹` envelopes should hit `skippedKeyLimitExceeded`, not OOM).
- [ ] Verify session blob round-trips through SQLite without losing
      skipped keys.
- [ ] Replace deterministic AEAD nonce with random nonce if the
      message-key uniqueness guarantee is ever weakened.
- [ ] Get a paid crypto review (Trail of Bits, NCC, Cure53). Rolling
      our own ratchet is fine for an MVP but **must be reviewed**
      before production.
- [ ] Plan key-rotation cadence: signed pre-key weekly; one-time pool
      replenished when count < 10.
- [ ] Plan emergency reset: user-initiated session wipe + fresh X3DH.
