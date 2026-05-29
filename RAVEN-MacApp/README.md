# RAVEN — native macOS app (App Store edition)

Sibling target to:

- `../ios-native/RAVEN/` — the Mac Catalyst build distributed via DMG
  (Developer ID, no sandbox, full BLE peripheral mesh capability).
- `../` — the Flutter cross-platform build that runs on macOS, iOS,
  Android, Windows, Linux.

This target is the **Mac App Store** edition. It runs in the App
Sandbox, has no Bluetooth peripheral entitlement, and reaches the same
FastAPI backend as the iOS production app:

    https://raven-server-516053629173.europe-west1.run.app

The UI matches the Flutter desktop shell (X-on-desktop layout) and
uses the same brand tokens and assets as the iOS production app.

## Why two macOS builds?

| Capability                  | DMG (Catalyst) | App Store (this) |
|---|---|---|
| BLE peripheral advertising  | ✅            | ❌              |
| Background mesh listener    | ✅ (LaunchAgent) | ❌            |
| Sign in with Apple          | ✅            | ✅              |
| Direct + group chat (online)| ✅            | ✅              |
| Bridge mode (server-routed) | ✅            | ✅              |
| QR-code desktop login       | ✅            | ✅              |
| App Store distribution      | ❌            | ✅              |

The App Store build leans on the FastAPI server (and the same
`/api/messages/*` endpoints the iOS app uses) for everything. Real-time
delivery is handled by `RealtimeEngine`, which keeps a `wss:///ws/inbox`
connection open and falls back to `GET /api/messages/inbox?since=…`
polling at 30 s when the socket is reconnecting. `MeshBridgeReceiver`
drains `GET /api/mesh/pending-bridges` on every (re)connect so opaque
envelopes uplinked by mesh bridges (iPhones, Catalyst DMG, Windows
native) while we were offline are picked up before the 24-hour server
retention window expires.

## File layout

```
RAVEN-MacApp/RAVEN/
├── RAVENMacApp.swift          # @main + RootView (auth-gated)
├── Info.plist                 # bundle metadata
├── Models/Models.swift        # User, Post, Conversation, Message
├── Services/
│   ├── KeychainService.swift     # sandbox-private kSecClassGenericPassword
│   ├── NetworkService.swift      # actor-isolated URLSession wrapper
│   ├── AuthService.swift         # @MainActor ObservableObject
│   ├── RealtimeEngine.swift      # /ws/inbox + 30s polling fallback
│   ├── MeshBridgeReceiver.swift  # /api/mesh/pending-bridges drain
│   ├── AppleSignInCoordinator.swift
│   ├── GoogleSignInCoordinator.swift
│   └── VoiceRecorder.swift
├── Views/
│   ├── RavenTheme.swift       # brand colors + gradients (mirror iOS)
│   ├── AuthLandingView.swift  # auth screen (Apple / Email / QR)
│   ├── MacShellView.swift     # 3-column shell + ShellRouter
│   └── Components/
│       ├── RailView.swift          # left nav rail
│       ├── MainColumn.swift        # router-driven middle pane
│       ├── FeedView.swift          # Home tab feed
│       ├── PostCardView.swift      # floating post card + animations
│       ├── ChatListColumn.swift    # Messages tab list
│       ├── ChatThreadView.swift    # conversation thread (right pane)
│       ├── ProfileColumn.swift     # Profile tab
│       └── RightPane.swift         # widgets / chat detail
└── Resources/
    ├── RAVEN.entitlements     # sandbox + applesignin only
    └── Assets.xcassets/
        ├── AppIcon.appiconset/
        └── RavenLogo.imageset/RavenLogo.png
```

## Bringing this into Xcode

The `.xcodeproj` is intentionally not committed (Xcode project files are
binary-ish and conflict-prone). To open the project:

1. **Create a new Xcode project**
   - File ▸ New ▸ Project ▸ macOS ▸ App
   - Product Name: `RAVEN`
   - Bundle Identifier: `app.raven.macos`
   - Interface: **SwiftUI**, Language: **Swift**
   - Storage: None
   - Save inside `RAVEN-MacApp/` so the project sits alongside this README.

2. **Replace the boilerplate sources**
   - Delete the auto-generated `RAVENApp.swift`, `ContentView.swift`,
     `Assets.xcassets`, and `RAVEN.entitlements` Xcode added.
   - Add (drag) the entire `RAVEN/` folder from this directory into the
     project navigator. Make sure "Copy items if needed" is **off** so
     the files stay where they are on disk.
   - Confirm targeting `RAVEN` for every Swift file and the asset
     catalog.

3. **Set capabilities**
   - Signing & Capabilities ▸ App Sandbox: **on**, Network ▸ Outgoing
     Connections (Client): **on**.
   - Add capability: **Sign in with Apple**.
   - Hardened Runtime is on by default for App Store distribution.

4. **Set the deployment target** to **macOS 13** (Ventura). SwiftUI
   features used: `LinearGradient`, `.task`, `.refreshable`,
   `SignInWithAppleButton`.

5. **Run** — Cmd-R. The first run brings you to the auth landing; the
   reviewer credentials in your project's secret manager (`reviewer1` /
   the value of the `reviewer-password` secret) sign in successfully.

6. **Archive for App Store**
   - Product ▸ Archive
   - Window ▸ Organizer ▸ Distribute App ▸ App Store Connect
   - The archive ships with sandbox + hardened runtime; reviewers will
     not see Bluetooth claims.

## Backend contract

`NetworkService` calls only endpoints that already exist on the
FastAPI backend:

- `POST /api/auth/login`
- `POST /api/auth/qr-login/init`
- `GET  /api/auth/qr-login/poll/{session_id}?nonce=...`
- `GET  /api/users/me`
- `GET  /api/posts/feed`
- `GET  /api/messages/inbox`

The QR-login flow is the same one the Flutter desktop screen and the
Windows native screen use — the server endpoint is `qr_login.py` from
this repo's `server/routers/`.

## Out of scope (deliberate)

- Club, Vault, Echo concert mode — not in the iOS production app.
- Repost — same.
- BLE peripheral advertising / background mesh — incompatible with
  App Store sandboxing; that lives in the Catalyst build.

## Status

Everything in `RAVEN-MacApp/RAVEN/` builds when wired into a fresh Xcode
project as above. The skeleton is feature-complete enough for App
Review (auth, feed, chat list, profile); thread rendering, voice/media
upload, and group chat surfaces are stubs that will fill in as the
matching FastAPI endpoints get exercised.
