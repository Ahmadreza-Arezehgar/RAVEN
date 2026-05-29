# RAVEN — Mac Build & DMG Distribution

This document covers the **Mac Catalyst build path** for RAVEN, distributed
as a signed + notarized DMG (NOT via the Mac App Store). This setup unlocks
**100% mesh-equivalent performance on macOS** by removing the App Sandbox
restrictions that block Bluetooth peripheral broadcasting.

---

## Why DMG instead of Mac App Store?

| Capability | Mac App Store (sandboxed) | DMG (Developer ID, no sandbox) |
|---|---|---|
| BLE peripheral advertising | ❌ killed in background | ✅ runs while app is alive |
| Background mesh listener | ❌ no LaunchAgent allowed | ✅ via LaunchAgent companion |
| MultipeerConnectivity | ⚠️ limited entitlements | ✅ full server+client |
| Direct disk access | ❌ user-selected only | ✅ ~/Library, /tmp, etc. |
| Auto-updates | ✅ free, automatic | ⚠️ build it yourself (Sparkle) |
| Distribution reach | ⚠️ App Store filter | ✅ download link anywhere |
| Privacy review | ✅ Apple checks | ✅ same notarization scan |

**Verdict for RAVEN**: mesh-first messenger MUST have BLE peripheral +
background continuity. App Sandbox kills both. DMG is the only path that
gets us iOS-equivalent mesh on Mac.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  ~/Applications/RAVEN.app  (Mac Catalyst, no sandbox)           │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │ RAVEN — main window  │    │ RAVEN — --mesh-daemon mode   │   │
│  │ (chat, feed, rooms)  │    │ (no window, BLE + WS only)   │   │
│  │                      │    │                              │   │
│  │ User opens it        │    │ Auto-launched at login by    │   │
│  │ Closes window  →     │    │ ~/Library/LaunchAgents/      │   │
│  │ Daemon takes over    │    │ app.raven.mesh.daemon.plist  │   │
│  └──────────────────────┘    └──────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
   Foreground BLE              Background BLE
   peripheral mode             central scan + bridge
   (advertise + scan)          (relay messages to server)
```

The same `RAVEN.app` binary runs both foreground (with windows) and
background (`--mesh-daemon` arg). The LaunchAgent ensures the background
copy is always alive while the user is logged in.

**Result**: even with the RAVEN window closed, your Mac continues to:
- Discover nearby BLE peers
- Relay friends' offline messages to the server
- Receive and queue your own messages until you reopen

---

## One-time setup (per developer)

### 1. Apple Developer ID Application certificate

1. Go to <https://developer.apple.com/account/resources/certificates/list>
2. Click **+** → **Developer ID Application** → Continue
3. Generate CSR via Keychain Access → Certificate Assistant → Request from CA
4. Upload the CSR, download the `.cer`, double-click to install

Verify it's installed:
```bash
security find-identity -p codesigning -v | grep "Developer ID Application"
# Expect: Developer ID Application: AHMADREZA AREZEHGAR (72QQ5Q324C)
```

### 2. App-specific password for notarization

1. <https://appleid.apple.com/account/manage>
2. Sign-In and Security → App-Specific Passwords → Generate
3. Label: `RAVEN notary`
4. Copy the password (format: `xxxx-xxxx-xxxx-xxxx`)

### 3. Store credentials in keychain (one-time)

```bash
xcrun notarytool store-credentials "raven-notary" \
    --apple-id "your.email@apple-id.com" \
    --team-id 72QQ5Q324C \
    --password "xxxx-xxxx-xxxx-xxxx"
```

### 4. (Optional but recommended) Install `create-dmg`

Without it, the DMG works but has a plain layout. With it, drag-to-Applications:

```bash
brew install create-dmg
brew install xcbeautify   # nicer xcodebuild output
```

---

## Build a release DMG

```bash
cd /Users/ahmd/hybrid_messenger/ios-native/RAVEN
./scripts/build-mac-dmg.sh
```

The script:

1. Reads version from `project.pbxproj` (currently 1.5)
2. Builds Mac Catalyst Release with `RAVEN-Catalyst.entitlements`
3. Re-signs with hardened runtime (notarization requirement)
4. Packages a DMG with drag-to-Applications layout
5. Submits to Apple notary, waits for response (~1–10 min)
6. Staples the notarization ticket so Gatekeeper passes offline
7. Outputs `build/RAVEN-1.5.dmg`

---

## Distribution

Once notarized, the DMG can be uploaded anywhere:

- Your website: `https://raven.app/download` → static link
- GitHub Releases: drag the .dmg into a new release
- CDN: any HTTPS URL works

End user flow:

1. Download the `.dmg`
2. Double-click → drag RAVEN to Applications
3. First launch: macOS prompts about Bluetooth + Notifications + Location
4. Settings → Background Mesh → Enable
   - This calls a built-in helper that copies
     `Resources/agents/app.raven.mesh.daemon.plist` to
     `~/Library/LaunchAgents/` and runs `launchctl bootstrap`
5. Done — RAVEN now keeps the mesh alive even when the window is closed

---

## Verify a built DMG before publishing

```bash
# 1. Inspect signature
codesign -dvv build/RAVEN-1.5.dmg

# 2. Confirm Gatekeeper accepts it
spctl --assess --type open --context context:primary-signature -vv build/RAVEN-1.5.dmg

# 3. Confirm notarization ticket is stapled
xcrun stapler validate build/RAVEN-1.5.dmg
```

All three should print "accepted" / "Notarization ticket attached".

---

## What's "100% mesh performance"?

Comparison vs other distribution paths:

| Mode | BLE central scan | BLE peripheral advertise | Background continuity | Effective mesh % |
|---|---|---|---|---|
| Mac App Store (sandbox) | ✅ foreground only | ❌ killed instantly | ❌ none | ~15% |
| Mac Catalyst no-sandbox + Foreground only | ✅ | ✅ while app open | ❌ closes when window closes | ~60% |
| **Mac Catalyst no-sandbox + LaunchAgent (this setup)** | ✅ | ✅ continuous | ✅ via daemon | **~95%** |
| Native macOS daemon (theoretical) | ✅ | ✅ continuous | ✅ even at boot | 100% |

We're at ~95%. The remaining 5% is the boot gap (daemon doesn't start
until the user logs in). Closing that requires a system-wide
LaunchDaemon — possible but requires the user to type their admin
password during install, which we judged not worth it.

---

## Background daemon mode (`--mesh-daemon` flag)

When `RAVEN` is launched with `--mesh-daemon`, the app:

1. Skips creating any window (`WindowGroup` is gated by absence of the flag)
2. Initializes only `BLEMeshEngine`, `MessageRouter`, `OutboxManager`,
   `NetworkService`, `WebSocketEngine`
3. Logs to `/tmp/raven-mesh-daemon.{out,err}.log`
4. Polls APNS / WS for incoming work
5. Relays mesh ↔ server bidirectionally
6. Exits cleanly on `SIGTERM` (when LaunchAgent stops it)

The flag handler lives in `RAVENApp.swift` (`init` checks
`CommandLine.arguments.contains("--mesh-daemon")`). On iOS this flag is
ignored (CommandLine args are empty for App Store apps).

---

## Code-signing entitlements file

**File**: `RAVEN/RAVEN-Catalyst.entitlements`

**Key entitlements that unlock 100% mesh**:

```xml
<key>com.apple.security.app-sandbox</key>          <false/>  <!-- bypass sandbox -->
<key>com.apple.security.device.bluetooth</key>     <true/>   <!-- BLE central + peripheral -->
<key>com.apple.security.network.server</key>       <true/>   <!-- accept connections -->
<key>com.apple.developer.networking.multicast</key> <true/>  <!-- multipeer -->
```

**File: `RAVEN/RAVEN.entitlements`** (the existing iOS file) is unchanged
and used for the App Store iOS build. The two entitlements files are
selected automatically by Xcode based on the destination platform.

---

## Troubleshooting

**"Developer ID Application" not found in keychain**

You haven't generated the certificate yet. See *Apple Developer ID
Application certificate* in *One-time setup* above.

**Notarization fails with "The signature does not include a secure timestamp"**

`build-mac-dmg.sh` already passes `--timestamp` to `codesign`. If you see
this anyway, it means the build's intermediate frameworks weren't signed.
The script's `codesign --force --deep` should handle it; if not, try
`codesign --force --deep --options runtime --timestamp --sign "<id>" path/to/inner/framework.framework`.

**"This bundle is invalid. Apps that target macOS may not provide an
embedded mobile provisioning profile"**

Ensure `PROVISIONING_PROFILE_SPECIFIER=""` is passed (the script does).
If it persists, delete `RAVEN/Resources/embedded.mobileprovision` if any.

**Mesh daemon won't start at login**

Check `launchctl list | grep app.raven`. If empty, the bootstrap step
never ran. Re-trigger from Settings → Background Mesh → Disable then
Enable, or manually:
```bash
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/app.raven.mesh.daemon.plist
launchctl kickstart -k gui/$UID/app.raven.mesh.daemon
```

Logs:
```bash
tail -f /tmp/raven-mesh-daemon.{out,err}.log
```

**App Store submission tries to use these entitlements**

Xcode picks entitlements based on the destination. iOS (`iphoneos`) uses
`RAVEN.entitlements`, Catalyst uses `RAVEN-Catalyst.entitlements`. If
your iOS App Store build pulls in the Catalyst file, check the build
setting `CODE_SIGN_ENTITLEMENTS` per-SDK in the target's Build Settings —
it should be `RAVEN/RAVEN.entitlements` for Any iOS, and the Catalyst
entitlements only get used by the DMG build script (which sets it
explicitly via the command line).
