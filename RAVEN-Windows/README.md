# RAVEN for Windows

A native Windows port of the RAVEN mesh messenger. Built with **.NET 8 + WinUI 3**.
Speaks the **same** wire protocol as the iOS / macOS Catalyst apps — see
[`docs/MESH_PROTOCOL.md`](../docs/MESH_PROTOCOL.md) for the spec.

> **Goal:** an iPhone, a Mac, and a Windows laptop in the same room form one
> mesh. Bridge + relay + direct-mesh modes all work cross-platform.

---

## Scope

The Windows app is intentionally a **lightweight client + full mesh node**.
On the user-facing side it ships only what makes sense on a desktop:

| Feature | Windows | iOS | Mac |
|---|---|---|---|
| **Feed** (Echo Wall posts) | ✅ | ✅ | ✅ |
| **DMs** | ✅ | ✅ | ✅ |
| **Group chats** | ✅ | ✅ | ✅ |
| Audio rooms | ❌ | ✅ | ✅ |
| RavenShot (geo-pinned posts) | ❌ | ✅ | ❌ |
| Vault (Face ID-locked content) | ❌ | ✅ | ❌ |

But the **mesh layer is at full parity** — the Windows app participates as a
true BLE peer with iPhone and Mac:

- ✅ BLE central + peripheral (advertise + accept connections)
- ✅ Direct mesh delivery to/from iPhone & Mac peers
- ✅ Multi-hop **relay** (forward encrypted envelopes the device can't read)
- ✅ Online **bridge** (when Windows has internet, uplink mesh-only envelopes
  to the server so offline recipients get them on their next online connect)

This way an iPhone in a low-signal building can use a Windows laptop on Wi-Fi
as a bridge to deliver messages — and the Windows laptop never sees plaintext.

---

## Status

This is a **work-in-progress port**. What's done vs. left:

| Component | Status |
|---|---|
| Protocol spec doc (`MESH_PROTOCOL.md`) | ✅ Complete, derived from iOS source |
| `MeshConstants` (UUIDs, sizes, defaults) | ✅ |
| `MeshCrypto` (X25519 / Ed25519 / AES-GCM / HKDF / fingerprint) | ✅ Implemented + unit tests |
| `MeshEnvelope` types + canonical signing data | ✅ Implemented + unit tests |
| `ChunkFramer` (BLE fragmentation) | ✅ Implemented + unit tests |
| `BleEngine` (WinRT GATT central + peripheral) | 🟡 Skeleton — hardware needed |
| `MessageRouter` (online/mesh/bridge dispatch) | ⏳ Not yet |
| `KeyStore` (Credential Manager / DPAPI wrapping) | ⏳ Not yet |
| `EncryptedDb` (SQLCipher) | ⏳ Not yet |
| WinUI 3 chat shell | ⏳ Not yet |
| Tray-resident background service | ⏳ Not yet |

The deterministic, hardware-independent code is implemented and unit-tested
on macOS / Linux. The BLE engine is a complete skeleton with `TODO[WIN-IMPL]`
markers showing exactly which WinRT calls go where — that part needs to be
finished and tested on a Windows 10/11 machine with a BLE-capable adapter.

---

## Build prerequisites

On a Windows machine:

- **Windows 11** (Windows 10 1909+ should also work for everything except some BLE quirks)
- **Visual Studio 2022** 17.10+ with the *.NET desktop development* and *Windows App SDK* workloads
- **.NET 8 SDK**
- **Windows App SDK 1.5+**
- A Bluetooth 5.0+ adapter (built-in is fine on most laptops)

On macOS / Linux you can run only the unit tests (`tests/`), since the main
project is `net8.0-windows10.0.19041.0` and references WinRT.

---

## Build

```powershell
# From the repo root, on Windows:
cd RAVEN-Windows
dotnet build RAVEN.Windows.sln -c Release
```

Run unit tests (works on any OS):

```bash
cd RAVEN-Windows/tests
dotnet test
```

Run the app (Windows only):

```powershell
cd RAVEN-Windows/src
dotnet run -c Debug
```

---

## Project layout

```
RAVEN-Windows/
├── RAVEN.Windows.sln
├── README.md                ← this file
├── src/
│   ├── RAVEN.Windows.csproj
│   ├── app.manifest
│   ├── Mesh/
│   │   ├── MeshConstants.cs          UUIDs, sizes, tier defaults
│   │   ├── MeshEnvelope.cs           Wire-format types + canonical signing
│   │   ├── ChunkFramer.cs            BLE fragmentation encode/reassemble
│   │   └── BleEngine.cs              WinRT GATT central + peripheral
│   ├── Crypto/
│   │   └── MeshCrypto.cs             X25519, Ed25519, AES-GCM, HKDF, fingerprint
│   ├── Storage/                      (TODO) SQLCipher, key store
│   ├── Network/                      (TODO) HTTP + WebSocket clients
│   └── Ui/                           (TODO) WinUI 3 shell
└── tests/
    ├── RAVEN.Windows.Tests.csproj
    └── InteropVectorsTests.cs        Cross-platform protocol vectors
```

---

## Implementation notes

### BLE peripheral mode on Windows

Windows 10 1607+ supports GATT peripheral mode via `Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider`.
Unlike iOS, advertising the BLE LocalName from a per-app GATT publisher is
**not** as straightforward — Windows tends to use the system Bluetooth name
for the LocalName. We may need to encode the device's short fingerprint in
ServiceData instead of the LocalName so iOS / Mac can parse it from
`CBAdvertisementDataLocalNameKey` analogues. This trade-off is documented
inline in `BleEngine.StartPeripheralAsync` (`TODO[WIN-IMPL]`).

### Background mode

Windows does NOT have an iOS-style background BLE API. To act as a relay
when the window is closed, the app must:

1. Run as a **system tray** application (minimize-to-tray, not exit-on-close).
2. Optionally register itself for **Run at startup** via `RegisterStartupTask`.
3. Survive sleep/wake — the BLE adapter is reset on resume; we re-init on the
   `SystemEvents.PowerModeChanged` event.

A future version may ship a separate Windows Service for true always-on
relay, but we want to keep the install simple at first.

### Why .NET 8 + WinUI 3, not Tauri/Rust?

Two reasons:

1. **WinRT BLE peripheral mode is first-class only from C# / C++/WinRT.**
   Rust bindings (`windows-rs`) work but the GATT server APIs are awkward and
   under-tested. C# is the path of least resistance.
2. **Windows 11 native look-and-feel out of the box** via WinUI 3 — Mica,
   acrylic, capsule controls — matches the design language we used for the
   Mac Catalyst (Liquid Glass) build.

A Rust-core option remains attractive for long-term cross-platform code
sharing (one crypto/protocol library across iOS/Mac/Windows/Android) but
that's a v2 question.

---

## Cross-platform interop test plan

The "iOS + Mac + Windows in the same room form one mesh" claim only holds
if the wire protocol stays in lock-step. Plan:

### Layer 1 — Deterministic vectors (no hardware)

Run `tests/InteropVectorsTests.cs` here AND a parallel
`ios-native/RAVEN/RAVENTests/InteropVectorsTests.swift` (TODO) on iOS. Both
must produce identical:

- Ed25519 signatures over a fixed input
- Fingerprints from a fixed Ed25519 public key
- AES-GCM combined blobs from fixed key + nonce + plaintext
- HKDF-derived keys from a fixed shared secret
- Pipe-format signing-bytes for `SecureMeshEnvelope`, `MeshPostEnvelope`,
  `MeshACKEnvelope`, `StopCommand`

### Layer 2 — Single-machine cross-process

Run the Windows app + the iOS Simulator (proxied BLE via macOS host)
side-by-side. Check that:

- Each sees the other in BLE scan (`OnPeerDiscovered`)
- A test DM round-trips end-to-end (signed → decrypted plaintext matches)
- An ACK round-trips
- A multi-hop bridge round-trips (manually take the Mac offline, send Windows
  → iPhone via Mac as relay)

### Layer 3 — Real-room test

Three real devices: iPhone, Mac, Windows laptop. Wi-Fi off, mesh-only.

| Scenario | Expected |
|---|---|
| iPhone DMs Mac directly | delivered via direct mesh, ACK comes back |
| iPhone DMs Windows (Mac in middle, all online) | server route picked first |
| iPhone DMs Windows, all offline, Mac in BLE range of both | bridges via Mac's mesh |
| Windows posts an Echo Wall post | iPhone + Mac receive it via mesh post envelope |
| Windows leaves room mid-relay | other peers continue without Windows |

### Layer 4 — Adversarial

- Mutate fields outside the signed set on a captured envelope; receiver should still verify.
- Mutate fields inside the signed set; receiver MUST drop.
- Replay a 30-day-old envelope; receiver MUST drop (after security fixes from
  the audit are applied — see `docs/MESH_PROTOCOL.md` §I).

---

## Current limitations / known gaps

These are inherited from the protocol (see `docs/MESH_PROTOCOL.md` §I):

1. **No forward secrecy** — same X25519 key forever, constant HKDF salt.
2. **Bridge bypass** — `isBridged=true` skips signature checks of the inner sender.
3. **Relay TOFU** — first claim of an unknown identity gets locked in.
4. **Replay window is size-bounded only** — a 30-day-old envelope still verifies.
5. **`gkv` (group-key version) is dropped on the wire** — group decryption may fail across rotations.

The Windows implementation reproduces the protocol AS-IS for interop. Fixing
these requires a coordinated v2 protocol bump on iOS + Mac + Windows.

---

## Contact

- Spec questions / contributions: info@raven-messenger.com
- This project is part of the RAVEN open-source security-critical core.
