// BackgroundModeService — keeps the Mac app alive after the user closes
// the window so the BLE peripheral mesh keeps running.
//
// The trick:
//   1. App Sandbox forbids background scanning / advertising while the
//      app is *suspended*.
//   2. But macOS suspends apps only when they're hidden / quit. As long
//      as the process is alive and frontmost-or-accessory, BLE keeps
//      working.
//   3. So we offer "Run in background" mode. Enabling it:
//      • Calls `NSApp.setActivationPolicy(.accessory)` so the app no
//        longer needs an open window to stay alive — closing the last
//        window doesn't terminate the process, it just hides the dock
//        icon. The app keeps running, which means CoreBluetooth keeps
//        advertising and scanning.
//      • Optionally registers the app as a Login Item via SMAppService
//        so it relaunches itself on every boot. The user opts in
//        explicitly — this is App Store-friendly (no helper binaries,
//        no LaunchAgent plist hacking).
//      • Surfaces an `NSStatusItem` (menu bar icon) with mesh status,
//        a "Show RAVEN" command, and a toggle to disable bg mode.
//
// Disabling reverts to `.regular` activation policy, removes the login
// item, and tears down the menu bar icon. Default is OFF — first-run
// users see the normal dock icon and Cmd-Q quits the app.
//
// `UserDefaults` persists the user's choice across launches, so a Mac
// reboot honors the preference.

import Foundation
import AppKit
import ServiceManagement
import Combine

@MainActor
final class BackgroundModeService: ObservableObject {
    static let shared = BackgroundModeService()

    /// User preference. Mirrored in UserDefaults so the next launch can
    /// re-apply it before the first window opens.
    @Published private(set) var isEnabled: Bool

    /// Whether the launch-on-login service registration is active. We
    /// surface this separately because it can fail (SMAppService refuses
    /// to register without a valid signing identity, for instance).
    @Published private(set) var launchAtLoginEnabled: Bool

    private static let isEnabledKey = "raven_background_mode_enabled"
    private static let launchAtLoginKey = "raven_background_launch_at_login"

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledKey)
        self.launchAtLoginEnabled = UserDefaults.standard.bool(forKey: Self.launchAtLoginKey)
    }

    // MARK: - Activation policy

    /// Apply the saved preference once the AppKit shell is ready. Called
    /// from `RAVENMacApp` at launch and from the Account screen toggle.
    func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = isEnabled ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
        if isEnabled {
            // Even in accessory mode we want to surface the main window
            // when the user re-clicks the menu-bar icon.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.isEnabledKey)
        applyActivationPolicy()
        if enabled {
            MenuBarController.shared.show()
        } else {
            MenuBarController.shared.hide()
        }
    }

    // MARK: - Login item (SMAppService)

    /// Register / unregister this build as a login item via
    /// `SMAppService.mainApp`. SMAppService is App Store-compatible and
    /// doesn't require a separate helper binary — it just adds the app
    /// itself to the Login Items list, the same as the user could do
    /// from System Settings.
    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginEnabled = enabled
                UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginKey)
            } catch {
                #if DEBUG
                print("[bg-mode] SMAppService failed: \(error)")
                #endif
                // Reflect the actual state back so the toggle doesn't lie.
                launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
                UserDefaults.standard.set(launchAtLoginEnabled, forKey: Self.launchAtLoginKey)
            }
        }
    }

    /// Reconcile the toggle's published state with the real registration
    /// state — the user can change Login Items in System Settings outside
    /// the app, so we re-check on launch and on every settings sheet
    /// open.
    func refreshLaunchAtLoginState() {
        if #available(macOS 13.0, *) {
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
            UserDefaults.standard.set(launchAtLoginEnabled, forKey: Self.launchAtLoginKey)
        }
    }
}
