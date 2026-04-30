# 🐦‍⬛ RAVEN — The Unstoppable Mesh Messenger

**RAVEN** is the unstoppable mesh messenger. Send encrypted messages without internet using peer-to-peer mesh networking. RAVEN is a privacy-first messaging platform that combines cloud-based messaging with **offline mesh networking** via Bluetooth. Messages are **end-to-end encrypted** using military-grade cryptography, and can be delivered even without internet using multi-hop relay.

🌐 **Website:** [raven-messager.com](https://raven-messager.com/)

> **Why open source?** We believe transparency is the foundation of trust. By publishing our security-critical code, we invite the community to verify that RAVEN handles your data responsibly.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Platform](https://img.shields.io/badge/Platform-iOS-black.svg)](https://apps.apple.com)

---

## 🔐 What's in This Repository

This repository contains the **security-critical core** of RAVEN — the parts that matter most for user trust:

### 🛡️ Encryption & Security
| File | Description |
|------|-------------|
| `ios-native/RAVEN/RAVEN/Core/Security/MeshCryptoService.swift` | End-to-end encryption engine (AES-256, Ed25519, HMAC) |
| `ios-native/RAVEN/RAVEN/Core/Storage/KeychainService.swift` | iOS Keychain integration for secure key storage |
| `ios-native/RAVEN/RAVEN/Core/Storage/DatabaseService.swift` | Local encrypted database (at-rest encryption) |
| `server/encryption.py` | Server-side encryption utilities |
| `server/middleware/` | Security middleware (rate limiting, auth) |

### 📡 Mesh Networking Protocol
| File | Description |
|------|-------------|
| `ios-native/RAVEN/RAVEN/Core/Mesh/BLEMeshEngine.swift` | Bluetooth Low Energy mesh engine |
| `ios-native/RAVEN/RAVEN/Core/Mesh/MeshEnvelope.swift` | Message envelope format & routing |
| `ios-native/RAVEN/RAVEN/Core/Mesh/MeshProtocols.swift` | Mesh networking protocol definitions |
| `ios-native/RAVEN/RAVEN/Core/Mesh/MeshACKHandler.swift` | Delivery confirmation handling |
| `ios-native/RAVEN/RAVEN/Core/Mesh/MeshDedupRepository.swift` | Message deduplication |

### 🔒 Privacy Declarations
| File | Description |
|------|-------------|
| `ios-native/RAVEN/RAVEN/PrivacyInfo.xcprivacy` | Apple Privacy Manifest — what data we access and why |
| `ios-native/RAVEN/RAVEN/RAVEN.entitlements` | App capabilities & permissions |

### 🖥️ Server API (Backend)
| Directory | Description |
|-----------|-------------|
| `server/routers/` | All API endpoints (auth, messages, posts, etc.) |
| `server/services/` | Business logic services |
| `server/models.py` | Database models & schema |
| `server/auth.py` | Authentication logic |

---

## 🏗️ Security Architecture

```
┌──────────────────────────────────────────────────┐
│                    RAVEN App                      │
├──────────────┬───────────────────────────────────┤
│  Encryption  │  MeshCryptoService.swift          │
│  (AES-256)   │  • E2E message encryption         │
│              │  • Ed25519 message signing         │
│              │  • HMAC authentication             │
├──────────────┼───────────────────────────────────┤
│  Key Storage │  KeychainService.swift             │
│  (Keychain)  │  • Private keys never leave device │
│              │  • Biometric-protected access       │
├──────────────┼───────────────────────────────────┤
│  Mesh Layer  │  BLEMeshEngine.swift               │
│  (Bluetooth) │  • Serverless message delivery      │
│              │  • Multi-hop relay (DTN)            │
│              │  • No metadata logging              │
├──────────────┼───────────────────────────────────┤
│  Local DB    │  DatabaseService.swift              │
│  (Encrypted) │  • At-rest encryption               │
│              │  • Secure deletion support           │
└──────────────┴───────────────────────────────────┘
```

---

## 🚀 Key Features

- **End-to-End Encryption**: AES-256 + Ed25519 signing + HMAC
- **Offline Mesh Networking**: Send messages without internet via Bluetooth relay
- **Zero-Knowledge Architecture**: Server cannot read your messages
- **Privacy-First**: Minimal data collection, transparent privacy manifest
- **iCloud Backup**: Encrypted backup & restore
- **Multi-Language**: English, Spanish, German, Persian (RTL), Chinese

---

## 🛠️ Building from Source

### Server

```bash
cd server
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # Configure your environment
uvicorn main:app --reload
```

### iOS

1. Open `ios-native/RAVEN/RAVEN.xcodeproj` in Xcode
2. Configure signing & capabilities
3. Build and run

---

## 📄 License

This project is licensed under the **GNU Affero General Public License v3.0** (AGPL-3.0) — the same license used by [Signal](https://signal.org).

This means:
- ✅ You can view, audit, and verify the code
- ✅ You can fork and modify for personal use
- ✅ Any modifications must also be open-sourced under AGPL-3.0
- ❌ The "RAVEN" name and branding are proprietary

See [LICENSE](LICENSE) for details.

---

## 🔒 Security

Found a vulnerability? Please see our [Security Policy](SECURITY.md) for responsible disclosure guidelines.

**Do NOT open public issues for security vulnerabilities.**

---

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## 📞 Contact

- **Support**: support@hybridmessenger.com
- **Security**: security@hybridmessenger.com
- **Feature Requests**: feedback@hybridmessenger.com

---

<p align="center">
  <b>RAVEN</b> — Your messages. Your privacy. Your network.<br>
  © 2026 Ash Robotic Industry. All rights reserved.
</p>
