# RAVEN application era (2026 iOS / macOS app + FastAPI server) — historical

> **Status: historical.** This text is the pre-pivot application README, kept
> for architecture history only. It describes the iOS/Mac Catalyst app, the
> Apple Watch companion, the FastAPI/WebSocket backend, audio rooms, the Echo
> Wall feed, RavenShot and Vault Mode. None of that is the current product.
> The current product is the serverless terminal node in [`node/`](../../node/);
> its authoritative status lives in [`node/SERVERLESS_MODEL.md`](../../node/SERVERLESS_MODEL.md),
> [`node/FINAL_SERVERLESS_PROOF.md`](../../node/FINAL_SERVERLESS_PROOF.md) and
> [`protocol/RAVEN_MESSAGING_PRODUCT_BOUNDARY_V1.md`](../../protocol/RAVEN_MESSAGING_PRODUCT_BOUNDARY_V1.md),
> which forbids public-social features. Nothing below is a security claim for
> the terminal product.

---

## ✨ What's new in v1.7 — ATSAM protocol

Raven v1.7 introduces **ATSAM**, Raven's own layered security protocol for online and offline messaging. ATSAM is not a single encryption algorithm; it is a stack of five protections, each with a precise job:

1. **Post-quantum hybrid pairing** — classical X25519 plus ML-KEM-768 (NIST FIPS 203). An attacker must defeat both halves to recover the root.
2. **Private peer discovery** — paired devices recognise each other in radio range without broadcasting names, phone numbers, or stable public keys. Beacons look like uniform random bytes to strangers.
3. **Live device confirmation** — a fresh challenge prevents recorded old beacons from being replayed to falsely show presence.
4. **Encrypted mesh routing** — per-message rotating recipient tags so mesh relays cannot link successive envelopes to the same recipient.
5. **Optional Vault Mode** — one-time-pad content protection for selected high-sensitivity text messages, with information-theoretic secrecy under strict pad conditions.

The public security documentation, threat model, per-layer claims, and trust roadmap live in a dedicated companion repository:

➡️ **[`Raven-offline-messenger/raven-security`](https://github.com/Raven-offline-messenger/raven-security)**

That companion repository also retains application-era material. It must not
be used by itself as evidence for the current terminal/serverless product;
current implementation boundaries and remaining gates are authoritative in
[`node/SERVERLESS_MODEL.md`](../../node/SERVERLESS_MODEL.md) and
[`node/FINAL_SERVERLESS_PROOF.md`](../../node/FINAL_SERVERLESS_PROOF.md). The full
ATSAM overview is also available as a PDF on the website:
<https://raven-messager.com/atsam>.

---

## ✨ What's new in v1.5

- 🖥️ **Mac Catalyst app** — full BLE-mesh parity with iOS, distributed as a signed DMG outside the Mac App Store. NavigationSplitView shell, capsule sidebar, ⌘-shortcuts.
- 🎧 **Audio rooms** — live voice rooms with low-latency SFU routing. Concert mode auto-discovers nearby attendees.
- 📰 **Echo Wall feed** — algorithm-free social feed that syncs over the mesh: posts, comments, mentions all replicate offline and reconcile when peers reconnect.
- 📍 **RavenShot** — geo-pinned photos and short clips on a private, expiring map.
- 🗝️ **Vault** — Face ID-locked chats and media, double-encrypted with a key that never touches the network.
- 🧠 **On-device intelligence** — smart-reply suggestions and Apple Translation run entirely on the device using Foundation Models. No transcripts ever leave the phone.
- 🌍 **Multi-language** — English, Spanish, German, Persian (RTL), Chinese, Arabic.

---

## 🔐 Security architecture

```
┌─────────────────────────────────────────────────────────┐
│                       RAVEN App                          │
├──────────────────┬──────────────────────────────────────┤
│   Crypto         │  X25519 ECDH · AES-256-GCM           │
│                  │  Ed25519 signatures · HMAC-SHA-256   │
│                  │  HKDF per-conversation session keys  │
├──────────────────┼──────────────────────────────────────┤
│   Key storage    │  iOS Keychain · Secure Enclave       │
│                  │  Vault: Face ID-gated second layer   │
├──────────────────┼──────────────────────────────────────┤
│   Local DB       │  SQLite + SQLCipher (AES-256)        │
│                  │  Encrypted at rest, key in Keychain  │
├──────────────────┼──────────────────────────────────────┤
│   Mesh           │  BLE 5.0 · CoreBluetooth             │
│                  │  Spray-and-Wait · TTL 5 hops         │
│                  │  SHA-256 dedup · anti-replay nonce   │
├──────────────────┼──────────────────────────────────────┤
│   Transport      │  WebSocket (online) → BLE (mesh) →   │
│                  │  Multi-hop bridge (store-and-fwd)    │
└──────────────────┴──────────────────────────────────────┘
```

---

## 🌐 Three transports, one envelope

Every message — DM, post, reaction, audio-room control — is wrapped in a single signed `MeshEnvelope`. The on-device router picks the cheapest path that's actually working:

| Mode | When | How |
|------|------|-----|
| **Online** | Internet reachable | WebSocket to FastAPI + APNs fallback |
| **Direct mesh** | Recipient in BLE range | Peer-to-peer GATT writes |
| **Bridge** | Multi-hop relay needed | Store-and-forward across nearby nodes |

Failover is automatic and silent. A WebSocket drop instantly switches the next message to mesh; a peer regaining the internet flushes its bridge queue to the server.

→ Read the [technical deep dive](https://raven-messager.com/technology.html) for the full spec.

---

## ⌚ Apple Watch — companion, not a peer

RAVEN ships a native watchOS app under [`RAVEN-WatchApp/`](../../RAVEN-WatchApp/). It lets you read and reply to DMs, react, browse the Echo Wall feed, and join audio rooms from the wrist. The Watch app is embedded in the iOS build, so installing RAVEN from the App Store auto-installs it on a paired Apple Watch — no separate download.

**The Watch is a companion surface, not an independent mesh node.** It cannot advertise itself, accept GATT writes, or relay envelopes — `CBPeripheralManager` is `API_UNAVAILABLE(watchos)` and `MultipeerConnectivity` / `WiFiAware` aren't exposed on watchOS either. Every Watch-originated message rides one of two paths:

1. **Companion via WCSession** → the paired iPhone wraps it into a `MeshEnvelope` and runs it through the same mesh / server / bridge router as a phone-side compose. Mac, Windows, and Android receivers can't tell the keystroke came from a wrist.
2. **Standalone LTE** (Series 4+ cellular) → the Watch hits the FastAPI server directly when the iPhone is unreachable. **Online-only** — no BLE mesh from this path.

The honest positioning: *RAVEN follows you to the wrist*, not *mesh on the wrist*. This is a watchOS platform limit (Apple DTS confirmed), not a roadmap item.

---

## 📂 What's in this repository

The **security-critical core** lives here for public audit. Brand marks and UI artwork stay under [`TRADEMARK.md`](../../TRADEMARK.md) / [`ASSET_LICENSE.md`](../../ASSET_LICENSE.md); source is AGPL-3.0.

### Open-source audit surface (essential)

| Path | Purpose |
|------|---------|
| `protocol/` | Normative RVN1 / ATSAM specs, errata, interoperability notes |
| `protocol/reference/` | Python reference codecs + parity tests |
| `shared-vectors/rvn1/` | Deterministic cross-language test vectors |
| `node/` (`raven-core`, `raven-node`, `ash`, `raven-swarm`) | Serverless node, terminal, crypto, transport |
| `agent_team/` (`rdap`, `team_agents`) | Experimental A2A agent delegation and Raven carrier integration |
| `ios-native/RAVEN/RAVEN/Core/Protocol/` | iOS envelope / PairInit / LAN path |
| `ios-native/RAVEN/RAVEN/Core/Security/` | Mesh crypto, ATSAM, Noise, sealers |
| `ios-native/RAVEN/RAVEN/Core/Mesh/` | BLE mesh engine + routing |

**Not claimed production-complete for serverless DMs.** Production builds keep experimental friendship / indexed-session paths **fail-closed**. Lab unlock (debug only): set `RAVEN_LAB_TEST_A=1`. Release binaries ignore that env and stay closed until documented gates pass. See `protocol/SECURITY_ERRATA_RVN1_2026-08-13.md` and `CONTRIBUTING.md`.

**Excluded from publish (local / private):** `.env` files, keychains, `identity.seed`, `~/.raven-ash` contacts/history, `node/target/`, proof-run artifacts, deploy keys, personal debug logs.

### 🛡️ Encryption & key handling
| File | Purpose |
|------|---------|
| `ios-native/RAVEN/RAVEN/Core/Security/MeshCryptoService.swift` | E2E encryption, Ed25519 signing, HMAC |
| `ios-native/RAVEN/RAVEN/Core/Security/DeviceIdentityService.swift` | Identity key generation + storage |
| `ios-native/RAVEN/RAVEN/Core/Storage/KeychainService.swift` | iOS Keychain integration |
| `ios-native/RAVEN/RAVEN/Core/Storage/DatabaseService.swift` | SQLCipher-encrypted local DB |
| `server/encryption.py` | Server-side crypto utilities |

### 📡 Mesh networking
| File | Purpose |
|------|---------|
| `ios-native/RAVEN/RAVEN/Core/Mesh/BLEMeshEngine.swift` | BLE central + peripheral engine |
| `ios-native/RAVEN/RAVEN/Core/Mesh/MeshEnvelope.swift` | Universal message envelope |
| `ios-native/RAVEN/RAVEN/Core/Mesh/MessageRouter.swift` | Hybrid routing decision engine |
| `ios-native/RAVEN/RAVEN/Core/Mesh/BackgroundMeshManager.swift` | Background BLE on iOS |
| `ios-native/RAVEN/RAVEN/Core/Mesh/MPCTransportService.swift` | Multipeer Connectivity fallback |

### 🔒 Privacy declarations
| File | Purpose |
|------|---------|
| `ios-native/RAVEN/RAVEN/PrivacyInfo.xcprivacy` | Apple Privacy Manifest — declared data uses |
| `ios-native/RAVEN/RAVEN/RAVEN.entitlements` | iOS capabilities (BLE, push, mesh) |
| `ios-native/RAVEN/RAVEN/RAVEN-Catalyst.entitlements` | Mac Catalyst capabilities (sandbox-off, BLE peripheral) |

### 🖥️ Legacy application server
| Path | Purpose |
|------|---------|
| `server/main.py` | FastAPI entry point (legacy app features; not the serverless DM path) |
| `server/routers/` | API endpoints (auth, messages, posts, rooms) |
| `server/models.py` | Database schema |
| `server/auth.py` | Token issuance + validation |
| `server/middleware/` | Rate limiting + auth guards |

### 🦀 Serverless node (build)

```bash
cd node
cargo test --locked -p raven-core -p raven-node -p ash -p raven-swarm
cargo run --locked -p ash -- --help
```

Platform notes: `node/INSTALL_macOS.md`, `node/INSTALL_Linux.md`, `node/INSTALL_Windows.md`.

---

## 🎯 Legacy application threat model (historical)

The section below describes the previous application/server architecture. It
is retained for history and is **not** a security claim for the current
terminal product. Current boundaries live in `node/SERVERLESS_MODEL.md` and
`node/FINAL_SERVERLESS_PROOF.md`.

What Raven defends against:

- **Network-level adversary** (ISPs, Wi-Fi snoops, passive observers) — sees only TLS-wrapped ciphertext.
- **Compromised relay node** — can drop or delay envelopes but can't read or impersonate. Ed25519 + HMAC validation.
- **Server compromise** — the database stores opaque ciphertext blobs only. No plaintext, no encryption keys, no contact metadata.
- **Lost / stolen device** — local DB needs device unlock; Vault content needs an additional Face ID prompt.

Out of scope: a sophisticated attacker with persistent access to an unlocked device, or one capable of compromising Apple's Secure Enclave. We document the boundary honestly.

---

## 🛠️ Building the legacy applications from source

### iOS

1. Open `ios-native/RAVEN/RAVEN.xcodeproj` in Xcode 15.4+
2. Configure your own signing & capabilities (no Apple Developer team is hard-coded)
3. ⌘B to build, ⌘R to run on device or simulator

### Mac (Catalyst)

```bash
cd ios-native/RAVEN
./scripts/build-mac-dmg.sh    # Auto-detects best signing identity, packages a DMG
```

The script falls back to ad-hoc signing if no Apple Developer cert is present, so the DMG runs locally without any setup. For public distribution it switches to Developer ID + notarisation.

### Server

```bash
cd server
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env          # configure your secrets locally
uvicorn main:app --reload
```

The server is stateless and scales to zero on Cloud Run with `min-instances 0` — see `deploy.sh` for the production Cloud Run configuration.

---

## 📊 Historical application-era comparison

|  | Raven | Signal | WhatsApp | Briar |
|---|---|---|---|---|
| End-to-end encryption | ✅ | ✅ | ✅ | ✅ |
| Works fully offline (mesh) | ✅ | ❌ | ❌ | ✅ |
| Works online (server) | ✅ | ✅ | ✅ | ❌ |
| Hybrid auto-failover | ✅ | ❌ | ❌ | ❌ |
| Live audio rooms | ✅ | limited | ✅ | ❌ |
| Decentralised social feed | ✅ | ❌ | ❌ | forums |
| No phone number required | ✅ | ❌ | ❌ | ✅ |
| Native iOS &amp; macOS | ✅ | ✅ | ✅ | ❌ |
| Open source | ✅ | ✅ | ❌ | ✅ |

---
