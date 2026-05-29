# 🐦‍⬛ RAVEN — Apple Watch companion

A native watchOS 10+ app for RAVEN. Pairs with the iPhone build under
`ios-native/RAVEN/` and gives the user the most-asked-for slice of the
phone experience on the wrist: reading and replying to DMs, reacting to
messages, browsing the Echo Wall feed, joining voice rooms, and seeing
mentions / reactions notifications — all without pulling the phone out.

---

## ⚠️ Positioning — read this first

**Apple Watch in RAVEN is a *companion / observer*, not an independent
mesh node.** Mesh participation goes through the paired iPhone; the
Watch never advertises, never relays, never accepts GATT writes.

This is a **hard ceiling imposed by watchOS**, not a project choice:

- `CBPeripheralManager.init(delegate:queue:options:)` is marked
  `API_UNAVAILABLE(watchos)` — a watchOS app can’t even compile a call
  to it. Verified May 2026 against watchOS 10–26 SDK headers.
- `MultipeerConnectivity` is not available on watchOS (Apple DTS,
  Forum #769043).
- `WiFiAware` (the iOS 26 peer-to-peer Wi-Fi framework) does not list
  watchOS in its `@available` annotations.
- `AccessorySetupKit` is iOS / iPadOS only.
- `NearbyInteraction` works on watchOS 8+ but is for ranging
  (distance + direction) only — no data channel.

Apple’s official guidance, repeated by DTS engineer Quinn:

> “Message sending between Apple Watch and paired iPhone is the only
> practical solution for watchOS support.”

What this means for the marketing pitch:

| Claim | True? |
|---|---|
| Watch users get RAVEN’s full social experience on the wrist | ✅ via companion |
| Watch participates in the BLE mesh as a peer | ❌ never |
| Watch can send / receive messages while iPhone is dead and offline | ❌ — only when LTE Watch has cellular and server is reachable |
| Watch composes messages that reach Mac / Windows / Android peers | ✅ — phone builds the envelope, every client decodes normally |
| Cross-platform interoperability needs no watch-specific code on Mac / Windows / Android | ✅ — same `MeshEnvelope` schema |

### The two transports the Watch actually has

1. **Companion via WCSession** (default) — Watch ↔ iPhone over Apple’s
   wrist-pairing protocol. iPhone does all mesh work. Range: ~10 m
   Bluetooth between wrist and pocket.
2. **Standalone LTE** (fallback) — Watch ↔ FastAPI server over its
   own cellular (Series 4+ LTE / Ultra). **Online only** — the BLE
   mesh is invisible from this path. Implemented in
   `RAVEN-Watch/Services/RemoteAPI.swift`.

A third future-optional mode — **passive observer** (CBCentralManager
scanning so the Watch can show “3 RAVEN peers nearby” when the iPhone
isn’t there) — is feasible (~1–2 h of work) but not implemented. It
would not provide send/receive. See `## 🔭 Limits & follow-ups`.

If you ever see the project pitch claim “mesh on the wrist,” fix the
pitch. The honest framing is **“RAVEN follows you to the wrist,”**
which is a real product win without overpromising.

---

The Watch never owns the mesh. It’s a **companion surface** that ferries
user intent to the phone, which then does the cross-platform routing
(BLE mesh, MPC, server bridge, WebSocket) that already works with the
Mac, Windows, and Android builds. Outbound messages from the Watch land
on the same `MeshEnvelope` wire format as every other client, so
cross-platform compatibility is automatic — the Watch never builds an
envelope itself.

> **Status:** end-to-end skeleton runs. The watchOS target compiles
> standalone; the iPhone-side bridge + state projector + auth-token
> mirror are all wired into the existing app (`BLEMeshEngine.start()`
> and `KeychainService.saveToken`). What’s still manual is documented
> in “Wiring on the iPhone side” below — a handful of one-line
> `NotificationCenter` observers for reactions, post likes, etc.

---

## 🎯 What the Watch can do

| Capability | Watch UI | Source of truth |
|---|---|---|
| **Read DMs** | `InboxView` (rows) → `ChatView` (thread) | iPhone `ChatStore` → snapshot |
| **Reply with text** | `ComposeReplyView` (dictation / scribble / emoji / smart replies) | `MessageRouter.send` on phone |
| **Reply with voice** | `VoiceReplyView` (record M4A) → `transferFile` | Phone uploads + sends as `type=.voice` |
| **React to a message** | Long-press → emoji palette | Phone reactions endpoint |
| **Browse Echo Wall** | `FeedView` (last 20 posts) | iPhone feed → snapshot |
| **Like a post** | Heart button (optimistic) | Phone `/api/posts/{id}/like` |
| **Comment on a post** | Dictation sheet | Phone `/api/posts/{id}/comment` |
| **Join a voice room** | `RoomsView` → `RoomDetailView` (PTT button) | Phone owns RTC; Watch sends ptt intents |
| **Mentions / reactions feed** | `NotificationsView` | iPhone notification store |
| **Mark-as-read sync** | Automatic on chat dismiss | Phone updates `seenAt` |
| **Standalone LTE send** | Fallback in `ComposeReplyView` | Watch hits REST directly when phone unreachable |

### How a Watch keystroke reaches Mac / Windows / Android

A Watch reply travels: **Watch → WCSession → iPhone → mesh / server**.
The iPhone wraps the text into a signed `MeshEnvelope` (Ed25519 +
X25519 + the ATSAM stack — identical to a phone-side compose), lets
`MessageRouter` pick the cheapest live transport (WebSocket → BLE mesh
→ MPC → server bridge), then reports the delivery receipt back to the
Watch so the inbox can drop the “mesh routing…” badge.

Receivers (Mac DMG, Windows native, Android, other iOS) decode the
envelope normally — they have no idea the original keystroke came from
a Watch. That’s the whole interop story.

---

## 🔌 WCSession protocol

All traffic between Watch and iPhone is dictionary payloads keyed on
`kind`. Both directions go through the same `WCSession.default`.

### Watch → iPhone

| `kind` | Payload | Phone-side handler |
|---|---|---|
| `compose-dm` | `recipientId`, `roomId`, `text`, `clientMessageId` | `WatchBridgeService.handleWatchCompose` → `MessageRouter.send` |
| `voice-reply` | (file metadata) `recipientId`, `roomId`, `clientMessageId` | `Notification.Name.ravenWatchVoiceReplyArrived` |
| `react` | `messageId`, `roomId`, `emoji` | `Notification.Name.ravenWatchReact` |
| `post-toggle-like` | `postId` | `Notification.Name.ravenWatchPostToggleLike` |
| `post-comment` | `postId`, `text` | `Notification.Name.ravenWatchPostComment` |
| `mark-read` | `roomId`, `upTo` (TimeInterval) | `Notification.Name.ravenWatchMarkRead` |
| `room-membership` | `roomId`, `joined` (Bool) | `Notification.Name.ravenWatchRoomMembership` |
| `room-ptt` | `roomId`, `talking` (Bool) | `Notification.Name.ravenWatchRoomPTT` |
| `subscribe-thread` | `roomId` | `Notification.Name.ravenWatchSubscribeThread` |
| `request-snapshot` | — | `Notification.Name.ravenWatchRequestSnapshot` |
| `open` | `target` (deep-link string) | `Notification.Name.ravenWatchOpen` |

### iPhone → Watch

| Method | Channel | `kind` |
|---|---|---|
| `pushApplicationContext({snapshot})` | `updateApplicationContext` | — (whole-blob `WatchSnapshot`) |
| `notifyWatchOfMessage(...)` | `sendMessage` → `transferUserInfo` | `incoming-dm` |
| `pushThreadSnapshot(roomId:, messages:)` | `sendMessage` → `transferUserInfo` | `thread-snapshot` |
| `pushThreadAppend(roomId:, message:)` | `sendMessage` → `transferUserInfo` | `thread-append` |
| `pushPostUpdate(...)` | `sendMessage` → `transferUserInfo` | `post-update` |
| `pushDeliveryReceipt(messageId:)` | `sendMessage` → `transferUserInfo` | `delivery-receipt` |

`updateApplicationContext` only retains the most recent blob, which is
exactly what we want for the inbox/feed/notifications snapshot —
older contexts are discarded by the OS so the Watch never sees stale
state after a sleep/wake cycle.

`sendMessage` requires both sides reachable; we always fall back to
`transferUserInfo` (queued, ordered, persistent) so notifications and
thread appends still land when the Watch is asleep.

---

## 🧩 Wiring on the iPhone side

Most of the wiring is done. The iPhone target ships:

- **`WatchBridgeService`** at `ios-native/RAVEN/RAVEN/Core/Mesh/WatchBridgeService.swift`
  — kicked off from `BLEMeshEngine.start()`. Handles every inbound
  `kind` from the Watch and exposes outbound `pushApplicationContext` /
  `pushThreadSnapshot` / `pushThreadAppend` / `pushPostUpdate` /
  `pushDeliveryReceipt` / `notifyWatchOfMessage`.

- **`WatchSnapshotProjector`** at `ios-native/RAVEN/RAVEN/Core/Mesh/WatchSnapshotProjector.swift`
  — kicked off alongside `WatchBridgeService` from `BLEMeshEngine.start()`.
  Observes `ConversationStore`, `FeedStore`, `RoomService`, and
  `AudioRoomManager`; debounces to 250 ms; rebuilds the `WatchSnapshot`
  dict and pushes via `updateApplicationContext`. Also handles
  `subscribe-thread` → reads from `MessageRepository` and pushes the
  thread; on `MessageStore.meshMessageReceivedNotification`, refreshes
  the inbox and (if the room is subscribed) pushes a `thread-append`.

- **Auth-token mirror** for the standalone-LTE fallback. Hooked into
  `KeychainService.saveToken` / `updateAccessToken` / `deleteAll`, so
  every sign-in / token rotation / sign-out updates
  `group.app.raven.shared/auth.json` automatically.

- **App Group** `group.app.raven.shared` added to the iPhone
  `RAVEN.entitlements` and the Watch entitlement.

### What's still manual

These hooks the projector exposes but the iPhone’s domain services
haven’t consumed yet. Wire them when convenient — the Watch UI already
fires the intents:

| Notification fired by Watch | Suggested handler |
|---|---|
| `.ravenWatchReact` | `ReactionsService.shared.toggle(emoji:, on:, in:)` |
| `.ravenWatchPostToggleLike` | `FeedStore.shared.toggleLike(postId:)` |
| `.ravenWatchPostComment` | `FeedStore.shared.comment(postId:, text:)` |
| `.ravenWatchMarkRead` | `ConversationStore.shared.markAsRead(roomId:)` |
| `.ravenWatchRoomMembership` | `RoomService.shared.join(roomId:)` / `leave()` |
| `.ravenWatchRoomPTT` | `AudioRoomManager.shared.setMic(enabled:)` |
| `.ravenWatchOpen` | Deep-link router (open chat / post / room) |
| `.ravenWatchVoiceReplyArrived` | `AttachmentService.uploadAudio(fileURL:)` → `MessageRouter.send(...)` as `type=.voice` |

The handler shape is consistent:

```swift
NotificationCenter.default.addObserver(
    forName: .ravenWatchReact, object: nil, queue: .main
) { note in
    guard let info = note.userInfo,
          let messageId = info["messageId"] as? String,
          let roomId = info["roomId"] as? String,
          let emoji = info["emoji"] as? String
    else { return }
    Task { await ReactionsService.shared.toggle(emoji, on: messageId, in: roomId) }
}
```

### Fanning out inbound DMs

When `RealtimeEngine` or `ConversationStore.handleIncomingMessage`
inserts a new DM, also call:

```swift
WatchBridgeService.shared.notifyWatchOfMessage(
    senderName: msg.senderName,
    preview: String(msg.text?.prefix(80) ?? ""),
    messageId: msg.id
)
```

The projector already picks up the new conversation row via
`ConversationStore`’s `@Observable` tracking and the
`MessageStore.meshMessageReceivedNotification`, so no
`pushThreadAppend` call is needed in the ingest path.

### Notifications tab

The iPhone has no central `NotificationStore` yet —
`NotificationsListView` queries on demand. Until that lands, the
Watch’s Alerts tab is empty. Wire `buildNotifications()` in the
projector once you have a published list of recent `AppNotification`s.

---

## 📲 Auto-install on the paired Watch

When a user installs RAVEN on their iPhone from the App Store, the
Watch app installs **automatically** on the paired Apple Watch — no
separate App Store search, no user action beyond opening the iPhone
app once. This is the standard Apple Watch app delivery flow and
requires three things, all in place:

1. **Watch target embedded inside the iOS app**. The Watch app sits
   in `Payload/RAVEN.app/Watch/RAVEN-Watch.app` of the shipped IPA.
   When the iPhone copy of RAVEN starts up, iOS sees the embedded
   Watch app and offers to install it on any paired Watch.
2. **Bundle id prefix**. The Watch app's bundle id must start with
   the iPhone's bundle id followed by a dot. Already enforced —
   iPhone is `app.raven.ios`, Watch is `app.raven.ios.watchkitapp`.
3. **Same Apple Developer Team** on both targets. The integration
   script sets `DEVELOPMENT_TEAM` to `72QQ5Q324C` to match the iPhone
   build.

### How the integration was done

The Watch app lives at `RAVEN-WatchApp/` as its own folder. To get it
*embedded* inside the iOS app's `RAVEN.xcodeproj`, run the integration
script once — it adds a `RAVEN-Watch` target and the "Embed Watch
Content" build phase to the existing iOS project, referencing the
sources at `../../RAVEN-WatchApp/RAVEN-Watch/`:

```bash
# from anywhere
RAVEN-WatchApp/scripts/integrate_with_ios_app.rb
```

The script is idempotent — re-running after edits is a no-op. It
backs the iOS pbxproj up to
`ios-native/RAVEN/RAVEN.xcodeproj/project.pbxproj.pre-watch-target-backup`
on first run; restore from that file to undo.

After the script runs, the iOS app can be built normally:

```bash
cd ios-native/RAVEN
xcodebuild -project RAVEN.xcodeproj -scheme RAVEN -destination ...
```

The IPA produced by archive-and-export contains the embedded Watch
app and is auto-install-ready on submission to App Store Connect.

### App Store Connect side

When you submit the build via Xcode Organizer / Transporter:

- App Store Connect sees the embedded Watch app and creates a Watch
  app entry automatically under the same record. No separate
  submission.
- The default "Make this app available to all eligible devices" leaves
  *Auto-install on Apple Watch* enabled, which is the user-facing
  default since iOS 14. Users can toggle it off in *Watch app on
  iPhone → My Watch → Available Apps* if they want.
- TestFlight installs follow the same flow — testers with paired
  Watches get the Watch app automatically.

## 🏗️ Local development (Watch-only)

For Watch-only iteration without rebuilding the whole iOS app, the
standalone xcodeproj in this folder is still useful:

```bash
# from RAVEN-WatchApp/
./scripts/generate.sh                 # regenerate the standalone xcodeproj
open RAVEN-Watch.xcodeproj            # Run on a paired Watch simulator
```

Both the standalone xcodeproj and the integrated target read the same
source files, so a change in either context is visible from the other.

### Requirements

- Xcode 15.0+
- watchOS 10.0+ (deployment target)
- Same Apple Developer Team ID as the iOS build (`86L46Z294A` for
  development, `72QQ5Q324C` for distribution)

### Bundle id pairing

The Watch app’s bundle id is `app.raven.watchos.watchkitapp` and its
`WKCompanionAppBundleIdentifier` points at the iPhone build’s
`app.raven.ios`. Both ids must exist in the same App Store Connect
record for WCSession to pair correctly.

---

## 🗂️ Layout

```
RAVEN-WatchApp/
├── project.yml                      # xcodegen spec (watchOS target)
├── README.md                        # this file
├── scripts/generate.sh              # regenerate xcodeproj from project.yml
└── RAVEN-Watch/
    ├── RAVENWatchApp.swift          # App entry — activates WCSession
    ├── Models/
    │   └── WatchModels.swift        # Slim Codable mirrors (Conv/Msg/Post/Room/Notif)
    ├── Services/
    │   ├── PhoneBridge.swift        # Watch side of WCSession (Inbound + Outbound)
    │   ├── WatchStore.swift         # ObservableObject snapshot cache + persistence
    │   ├── RemoteAPI.swift          # Standalone-LTE fallback (online-only)
    │   └── VoiceRecorder.swift      # M4A capture for voice replies
    ├── Views/
    │   ├── Root/RootView.swift      # Vertical-pager TabView shell
    │   ├── Inbox/InboxView.swift
    │   ├── Chat/ChatView.swift      # Thread + reactions long-press
    │   ├── Chat/ComposeReplyView.swift   # Dictation / Scribble / Emoji / Smart replies
    │   ├── Chat/VoiceReplyView.swift     # Record M4A → transferFile
    │   ├── Feed/FeedView.swift      # Echo Wall posts + like + comment
    │   ├── Rooms/RoomsView.swift    # Voice rooms list + PTT detail
    │   ├── Notifications/NotificationsView.swift
    │   └── Components/
    │       ├── AvatarCircle.swift   # Tinted-initial avatar (no image download)
    │       └── TimeFormatter.swift  # "2m", "3h", "Mon", "12 Jun"
    └── Resources/
        ├── Info.plist               # WKCompanionAppBundleIdentifier, mic, etc.
        ├── RAVEN-Watch.entitlements # App Groups + network.client
        └── Assets.xcassets/AppIcon.appiconset/
```

---

## 🔭 Limits & follow-ups

- **No mesh-peer role on the wrist.** Documented at the top — the
  Watch is companion / observer, never a peer. Not a follow-up; not
  fixable in software.
- **Passive observer mode (not implemented).** ~1–2 h to add. Use
  `CBCentralManager` to scan for RAVEN BLE advertisements and surface
  “3 RAVEN peers nearby” / “your iPhone is in range.” Does **not**
  enable send/receive over BLE — that requires
  `CBPeripheralManager`, which watchOS won’t expose. Worth doing if
  the product wants a “find my iPhone / who’s here” widget; skip
  otherwise.
- **No camera.** New posts are phone-only by design.
- **No SQLCipher on the Watch.** The Watch keeps an unencrypted
  `WatchSnapshot.json` in its App Group container — Apple’s Data
  Protection class `completeFileProtectionUntilFirstUserAuthentication`
  protects it at rest. Sensitive deep state stays on the phone.
- **PTT is shaped, not wired.** The `RoomDetailView` sends `room-ptt`
  intents; the phone-side RTC bridge that picks them up is a follow-up
  (depends on the existing `RoomsService` Watch hooks).
- **Smart-reply suggestions are static.** The three chips in
  `ComposeReplyView` are placeholders; wire to the existing on-device
  Foundation Models pipeline (the one feeding the iPhone composer’s
  Smart Reply bar) when the project pulls in the Watch target.
- **Standalone Mac/Windows pairing** is intentionally out of scope —
  Apple does not allow watchOS apps to communicate with non-Apple
  hosts directly. Cross-platform reach comes from the iPhone’s mesh.

---

## 📄 License

Same as the rest of the repo — AGPL v3.
