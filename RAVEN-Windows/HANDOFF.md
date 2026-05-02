# RAVEN for Windows — Continuation Handoff

> **You are reading this because the previous Claude session ran on macOS
> and pushed everything here, but the WinUI/WinRT code can only be compiled
> and tested on a Windows machine. This document tells you (the next Claude
> instance, running on Windows) exactly where things stand and what to do
> next.**

Last verified state: commit `2f44b7e` on `main`, pushed to
`https://github.com/Raven-offline-messenger/RAVEN` (private).

---

## TL;DR

- Repo is **private**.
- iOS / macOS Catalyst app is shipping (v1.5).
- Server (FastAPI on Cloud Run) is live; new `/api/mesh/bridge-envelope`
  endpoint is in `server/routers/mesh.py` but **not yet deployed**.
- Windows app (`RAVEN-Windows/`) is **code-complete on macOS** (all logic,
  all UI, all crypto), with **15/15 unit tests passing** under `dotnet test`
  on macOS. **It has never been compiled on Windows.** Expect 1-3 small
  build issues on first try.
- The single source of truth for the wire protocol is
  [`docs/MESH_PROTOCOL.md`](../docs/MESH_PROTOCOL.md). Don't deviate from
  it without bumping `MeshConstants.ProtocolVersion` to 2 and updating iOS
  in lockstep.

---

## Where we are

### Already done

| Component | Status | Files |
|---|---|---|
| Protocol spec | ✅ Complete | `docs/MESH_PROTOCOL.md` (590 lines) |
| Crypto layer | ✅ Tested | `src/Crypto/MeshCrypto.cs` |
| Wire envelope types | ✅ Tested | `src/Mesh/MeshEnvelope.cs` |
| BLE fragmentation | ✅ Tested | `src/Mesh/ChunkFramer.cs` |
| BLE engine (WinRT GATT) | 🟡 Untested on Windows | `src/Mesh/BleEngine.cs` |
| Hybrid router | ✅ Logic complete | `src/Mesh/MessageRouter.cs` |
| Group chat support | ✅ | `src/Mesh/GroupChat.cs` |
| Storage (SQLCipher + DPAPI keys) | ✅ | `src/Storage/*.cs` |
| Network (REST + WebSocket) | ✅ | `src/Network/*.cs` |
| WinUI 3 shell + 3 views | 🟡 Untested on Windows | `src/Ui/*.xaml(.cs)` |
| Tray service | 🟡 Untested on Windows | `src/Ui/TrayService.cs` |
| iOS test vector twins | 📝 Reference only | `ios-native/RAVEN/RAVENTests/MeshInteropVectorsTests.swift` |
| Server bridge endpoint | ✅ Code, ❌ Not deployed | `server/routers/mesh.py` |

### NOT done (you'll need these)

1. **Login screen** — App.xaml.cs opens directly to MainWindow. No auth flow.
2. **Recipient picker UI** — MessagesView compose box can't actually send to a real peer yet.
3. **Group chat UI** — backend code exists; create-group / pick-members / send-to-group screens don't.
4. **Server `/api/mesh/bridge-envelope` deployment** — code is in `server/routers/mesh.py`; needs a `cd server && ./deploy.sh` once you've reviewed it.
5. **Custom tray icon** — currently `SystemIcons.Application` (generic). Need a raven `.ico` resource.

---

## Likely first-build issues (in order of likelihood)

You're running this on Windows for the first time. Here's what I'd bet money on hitting:

### 1. UserControl namespace not found

`MainWindow.xaml` references `local:MessagesView`, `local:FeedView`, `local:AccountView`, `local:SidebarRow`. The `xmlns:local="using:RAVEN.Windows.Ui"` line IS present, so it SHOULD work. But if XAML compiler complains "type X not found", check that:
- Each UserControl `.xaml.cs` has the `RAVEN.Windows.Ui` namespace (it does).
- The `.xaml` and `.xaml.cs` files are paired correctly (matching `x:Class`).

### 2. DI bootstrap deadlock

`App.xaml.cs` does:
```csharp
services.AddSingleton<BleEngine>(sp =>
{
    var keys = sp.GetRequiredService<KeyStore>().LoadOrCreateAsync().GetAwaiter().GetResult();
    return new BleEngine(...);
});
```

`.GetAwaiter().GetResult()` on the UI thread can deadlock during `OnLaunched`. If the app hangs on launch, refactor BleEngine registration to lazy initialization or use `Task.Run(() => ...).GetAwaiter().GetResult()`.

### 3. ItemsRepeater data-binding glitches

`x:Bind` paths in `MessagesView.xaml` and `FeedView.xaml` use the default OneTime binding mode (which is actually what we want for our static VMs). If anything fails to render, switch the `x:Bind` to `Mode=OneWay` for fields that change post-construction.

### 4. WinRT BLE permission

Windows 11 will show a permission prompt the first time the app uses Bluetooth. Settings → Privacy & security → Bluetooth must allow apps to access BT.

### 5. SQLCipher native library not found

`SQLitePCLRaw.bundle_e_sqlcipher` should bring along the native library, but on first launch SQLite might complain. If so, ensure your csproj has `<RuntimeIdentifiers>win10-x64;win10-arm64</RuntimeIdentifiers>` (it does).

### 6. NotifyIcon needs WinForms host

We added `<UseWindowsForms>true</UseWindowsForms>` to the csproj. If the app crashes early with "WinForms application context not initialized," call `System.Windows.Forms.Application.EnableVisualStyles()` once before `TrayService.Install()` in `App.xaml.cs`.

---

## Next milestones (in order)

Do these in order. Don't skip ahead.

### M1 — First successful build (target: 1 hour)

```powershell
cd RAVEN-Windows
dotnet restore
dotnet build RAVEN.Windows.sln -c Debug
```

Fix whatever the compiler complains about. Likely candidates listed above. If you fix something that touches the wire protocol, **STOP** and update `docs/MESH_PROTOCOL.md` + the iOS test vector file simultaneously.

Run the unit tests to make sure nothing was regressed:
```powershell
cd tests
dotnet test
```
Should report **15/15 passed**.

### M2 — App launches and shows shell (target: 1 hour)

```powershell
cd src
dotnet run -c Debug
# OR open RAVEN.Windows.sln in Visual Studio 2022 and F5
```

Expected: window opens, sidebar visible (Feed / Messages / Account), mesh status pill shows "Mesh idle." Click each sidebar item, see the right pane swap.

### M3 — BLE peer discovery (target: 2 hours, **requires iPhone with v1.5 nearby**)

Open RAVEN on the iPhone, leave it on the AuthGateView for now (no need to log in). Open the Windows app. Within 30s:
- Windows: Account view's "Peers nearby" counter goes 0 → 1.
- iPhone: peer should appear in mesh-debug log (Settings → Mesh → Diagnostics).

**Likely blocker:** iOS's `extractFingerprintFromAd` parser only reads `LocalName`, but Windows publishes the fingerprint in ServiceData. **Fix on iOS side:**

```swift
// File: ios-native/RAVEN/RAVEN/Core/Mesh/BLEMeshEngine.swift
// Around line 2447, in the advertisement parser:

if let localName = peripheral.name, localName.hasPrefix("RAVEN-") {
    fingerprint = String(localName.dropFirst("RAVEN-".count))
}
// ADD THIS — read fingerprint from manufacturer / service data slot:
else if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
        let raw = serviceData[serviceUUID],
        let s = String(data: raw, encoding: .utf8) {
    fingerprint = s
}
```

Push that to iOS, ship a v1.5.1, install on the test iPhone, then re-test.

### M4 — Mesh DM round-trip (target: 4 hours)

You'll need to add a basic "send to peer" UI to MessagesView since there's no recipient picker today. Suggestion:

1. Add a TextBox above the compose bar for "Recipient X25519 pubkey (base64)".
2. On send, call `_router.SendDmAsync(envelope, recipientPubBase64)`.
3. On the iPhone, receive + decrypt → message should appear in chat.

If decryption fails, **the most likely cause is a 1-byte drift in `SecureMeshEnvelope.SigningData()`**. Run the iOS XCTest twin (`MeshInteropVectorsTests.swift`) and the Windows xUnit twin (`InteropVectorsTests.cs`) — both must produce **identical bytes**. Diff them character by character if needed.

### M5 — Login flow + server bridge (target: 1 day)

Right now Windows can do mesh-only. To add server features:
1. Build a simple `LoginView.xaml` — email + password fields + login button.
2. Hook it to `ApiClient.LoginAsync(email, password)`.
3. On success, route to MainWindow.
4. Deploy the new server endpoint: `cd server && ./deploy.sh`.
5. Test bridge: take iPhone offline (airplane mode), send DM iPhone → Windows via mesh, verify Windows uplinks it to server, verify (with Mac online) Mac picks it up via WebSocket.

### M6 — Group chat UI + polish (target: 2 days)

Backend is ready; need UI for create-group, member picker, group settings.

### M7 — Custom installer + signing (target: 1 day)

- Replace generic icon with raven `.ico`
- Build MSIX or plain `.exe` installer
- Code-sign with EV cert (Apple Developer doesn't help here; need a separate Windows signing cert)

---

## How to verify mesh interop with iOS / Mac

The whole point of this work. Here's the test rig:

1. **3 devices in the same room:** iPhone (v1.5+), Mac (v1.5 DMG installed), Windows (this app, post-M2).
2. **Phase A — discovery:**
   - Each device should see the other two in BLE scan.
   - Account view counter on Windows = 2.
3. **Phase B — direct mesh DM:**
   - iPhone → Mac (Wi-Fi off): delivered via direct mesh.
   - iPhone → Windows: delivered via direct mesh.
4. **Phase C — bridge:**
   - Windows online (Wi-Fi on), iPhone & Mac offline.
   - Mac → iPhone via Windows as relay → Windows uplinks to server → server stores.
   - Mac comes back online → server pushes the queued message.
5. **Phase D — multi-hop:**
   - Position so iPhone can't see Mac directly, but both can see Windows.
   - iPhone → Mac with Windows as the only path.
   - Windows forwards encrypted envelope (zero-knowledge — never decrypts).

If any of these fails, **the diagnostic order is:**
1. Was the BLE peer discovered? (Account view counter)
2. Did the GATT connection establish? (logs)
3. Was the envelope received? (`OnInboundPacket` event)
4. Did signature verification pass? (`MeshCrypto.Ed25519Verify` returns true?)
5. Did decryption succeed? (`MeshCrypto.AesGcmOpenCombined` doesn't throw?)

The single most likely fault is **#4 — signature verification failing** because of a canonical-form drift between iOS's `signingData()` and Windows's `SigningData()`. Run both test suites; pin the byte values.

---

## Project anatomy reference

```
RAVEN-Windows/
├── HANDOFF.md                    ← you are here
├── README.md                     overview + scope
├── RAVEN.Windows.sln             VS solution
├── src/
│   ├── App.xaml(.cs)             entry point + DI
│   ├── app.manifest              dpiAware + Win10/11 compat
│   ├── RAVEN.Windows.csproj      .NET 8 + WinUI 3
│   ├── Crypto/
│   │   └── MeshCrypto.cs         X25519, Ed25519, AES-GCM, HKDF, fingerprint
│   ├── Mesh/
│   │   ├── BleEngine.cs          WinRT GATT + non-Windows stub
│   │   ├── ChunkFramer.cs        BLE 0x00/0x01-flag fragmentation
│   │   ├── GroupChat.cs          AES-256 group key handling
│   │   ├── MeshConstants.cs      UUIDs, sizes, defaults
│   │   ├── MeshEnvelope.cs       Wire format types + canonical signing
│   │   └── MessageRouter.cs      Online/mesh/bridge dispatcher
│   ├── Network/
│   │   ├── ApiClient.cs          REST + token refresh
│   │   ├── RealtimeWebSocket.cs  WS to /ws/inbox
│   │   └── TokenStore.cs         DPAPI-protected
│   ├── Storage/
│   │   ├── DedupRepository.cs    SQLite + LRU
│   │   ├── EncryptedDb.cs        SQLCipher
│   │   ├── KeyStore.cs           DPAPI-protected identity keys
│   │   └── TrustStore.cs         FriendDevice equivalent
│   └── Ui/
│       ├── AccountView.xaml(.cs)  identity + mesh diagnostics
│       ├── FeedView.xaml(.cs)     Echo Wall posts
│       ├── MainWindow.xaml(.cs)   shell + sidebar
│       ├── MessagesView.xaml(.cs) DM/group chat list + detail
│       ├── SidebarRow.xaml(.cs)   capsule sidebar item
│       └── TrayService.cs         System tray (Win-only)
└── tests/
    ├── InteropVectorsTests.cs    15/15 cross-platform vectors
    └── RAVEN.Windows.Tests.csproj
```

---

## When you change anything in the wire protocol

The protocol is a CONTRACT between three implementations. Any change here means **all three** need a coordinated update:

1. Bump `MeshConstants.ProtocolVersion` to `2`.
2. Update `docs/MESH_PROTOCOL.md` accordingly.
3. Update the C# implementation.
4. Update `iOS-native/RAVEN/RAVEN/Core/Mesh/MeshEnvelope.swift` + `MeshCryptoService.swift` to match.
5. Run BOTH test suites. They must produce identical bytes.
6. Add a v1↔v2 negotiation handshake (out of scope for now — assume same-version peers).

If you cannot do all six steps, do not change the protocol.
