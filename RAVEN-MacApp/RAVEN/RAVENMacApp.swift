// RAVEN — native macOS app, App Store distribution.
//
// Sibling target to the Mac Catalyst build under
// `../ios-native/RAVEN/`. The Catalyst build ships outside the App Store
// (Developer ID + DMG) so it can keep BLE peripheral mode and a background
// LaunchAgent — see `MAC_BUILD.md` over there. THIS target lives inside
// the App Sandbox and is intended for the Mac App Store.
//
// What's in scope here (matches what the iOS production app exposes):
//   • Auth (Sign in with Apple, Email, QR-code desktop login)
//   • Feed (For you / Friends / Local) with floating post cards
//   • Direct + group chat — `RealtimeEngine` keeps a `wss:///ws/inbox`
//     socket open so messages from iPhone / Catalyst peers arrive
//     instantly, and falls back to `/api/messages/inbox` polling when
//     the socket is reconnecting.
//   • Mesh bridge reception — `MeshBridgeReceiver` drains
//     `/api/mesh/pending-bridges` on every (re)connect so opaque
//     envelopes uplinked by mesh devices while we were offline don't
//     expire unread.
//   • Account / settings
//
// Deliberately out of scope (per user direction):
//   Club, Vault, Echo concert mode, Repost. BLE peripheral / mesh
//   bridging — incompatible with App Sandbox; lives in the Catalyst build.

import SwiftUI

@main
struct RAVENMacApp: App {
    @StateObject private var auth = AuthService.shared
    /// AppKit-side bootstrap. SwiftUI's `App` doesn't give us a hook for
    /// "the AppKit shell is ready" without an AppDelegate adapter, so
    /// we use one to apply the saved background-mode preference + spin
    /// up the status item before the first window appears.
    @NSApplicationDelegateAdaptor(RAVENAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About RAVEN") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .newItem) {} // we don't open arbitrary docs
        }
    }
}

/// AppDelegate adapter — applies the saved "Run in background" policy
/// before SwiftUI mounts its first window, and keeps the process alive
/// after the last window closes (so BLE peripheral mesh keeps running).
@MainActor
final class RAVENAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BackgroundModeService.shared.applyActivationPolicy()
        if BackgroundModeService.shared.isEnabled {
            MenuBarController.shared.show()
        }
        BackgroundModeService.shared.refreshLaunchAtLoginState()

        // Wire the default crypto handler for bridge envelopes drained
        // by `MeshBridgeReceiver`. We must `await initialize()` first so
        // the agreement private key is in cache when the first envelope
        // drains right after WS connect — otherwise the handler races
        // the keychain load, `deriveSharedSecret` returns nil, and the
        // envelope drops silently. Same race that bit MPC start before
        // the BLEMeshEngine fix, applied here at the bridge layer.
        Task { @MainActor in
            try? await DeviceIdentityService.shared.initialize()
            await MeshBridgeReceiver.shared.attachDefaultDecryptHandler()
        }
    }

    /// When the user closes the last window we usually want the app to
    /// keep running — the whole point of background mode is that BLE
    /// stays advertising. Returning `false` keeps the process alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !BackgroundModeService.shared.isEnabled
    }
}

/// Decides whether to render the auth landing screen or the main shell,
/// driven by `AuthService.isAuthenticated`. Equivalent to the SwiftUI
/// pattern in `ios-native/RAVEN/RAVEN/Views/AuthGateView.swift`.
struct RootView: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        Group {
            if auth.isAuthenticated {
                MacShellView()
                    .transition(.opacity)
            } else {
                AuthLandingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.isAuthenticated)
        .task { await auth.bootstrapFromKeychain() }
    }
}
