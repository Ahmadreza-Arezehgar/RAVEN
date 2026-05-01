# 🐦‍⬛ RAVEN — Messaging Beyond Connectivity

**RAVEN** is a privacy-first mesh messenger for **iOS and macOS**. Encrypted chat, group conversations, live audio rooms, and a decentralised social feed — all running over a hybrid transport that stays online when the network's there, and keeps working when it isn't.

🌐 **Website:** [raven-messager.com](https://raven-messager.com/)
📱 **App Store:** [Download for iOS](https://apps.apple.com/us/app/raven-messenger/id6758585289)
🖥️ **Mac:** Signed DMG — see [Releases](https://github.com/Raven-offline-messenger/RAVEN/releases)

> **Why open source?** Transparency is the foundation of trust. The security-critical code is published so anyone can audit it.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![iOS](https://img.shields.io/badge/iOS-17%2B-black.svg)](https://apps.apple.com)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://github.com/Raven-offline-messenger/RAVEN/releases)
[![Version](https://img.shields.io/badge/version-1.5-purple.svg)](https://github.com/Raven-offline-messenger/RAVEN/releases)

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

## 📂 What's in this repository

The **security-critical core** lives here. Anything that touches your data is auditable.

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

### 🖥️ Server
| Path | Purpose |
|------|---------|
| `server/main.py` | FastAPI entry point |
| `server/routers/` | All API endpoints (auth, messages, posts, rooms) |
| `server/models.py` | Database schema |
| `server/auth.py` | Token issuance + validation |
| `server/middleware/` | Rate limiting + auth guards |

---

## 🎯 Threat model

What Raven defends against:

- **Network-level adversary** (ISPs, Wi-Fi snoops, passive observers) — sees only TLS-wrapped ciphertext.
- **Compromised relay node** — can drop or delay envelopes but can't read or impersonate. Ed25519 + HMAC validation.
- **Server compromise** — the database stores opaque ciphertext blobs only. No plaintext, no encryption keys, no contact metadata.
- **Lost / stolen device** — local DB needs device unlock; Vault content needs an additional Face ID prompt.

Out of scope: a sophisticated attacker with persistent access to an unlocked device, or one capable of compromising Apple's Secure Enclave. We document the boundary honestly.

---

## 🛠️ Building from source

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

## 📊 How Raven compares

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

## 📄 License

Licensed under the **GNU Affero General Public License v3.0** (AGPL-3.0) — the same license used by [Signal](https://signal.org).

- ✅ View, audit, and verify the code
- ✅ Fork and modify for personal use
- ✅ Any modifications redistributed to users must also be open-sourced under AGPL-3.0
- ❌ The "RAVEN" name, logo, and brand are proprietary

See [LICENSE](LICENSE) for the full text.

---

## 🔒 Security disclosure

Found a vulnerability? Please see [SECURITY.md](SECURITY.md) for responsible disclosure.

**Do NOT open public issues for security vulnerabilities.**

---

## 🤝 Contributing

PRs and audits welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## 📞 Contact

- **Support / general** — info@raven-messenger.com
- **Security** — info@raven-messenger.com
- **Press** — info@raven-messenger.com

---

<p align="center">
  <b>RAVEN</b> — Messaging beyond connectivity.<br>
  © 2026 Ash Robotic Industry. All rights reserved.
</p>
