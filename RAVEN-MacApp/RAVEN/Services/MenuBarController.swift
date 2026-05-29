// MenuBarController — the NSStatusItem that surfaces RAVEN's mesh
// status and reopens the main window when clicked.
//
// Lives only when "Run in background" is enabled. Shows:
//   • A raven icon (template image) tinted by mesh state
//   • "X peers" subtitle when one or more BLE peers are connected
//   • "Open RAVEN" / "Quit" / "Run in background" toggle
//
// We deliberately keep this minimal — no inline chat preview or unread
// count yet. The point is to give the user proof the app is alive (so
// they trust the background-mode trade-off) and a one-click route back
// into the main window.

import AppKit
import Combine

@MainActor
final class MenuBarController {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var meshObserver: Any?
    private var lastPeerCount: Int = 0
    private var lastAdvertising: Bool = false

    private init() {}

    // MARK: - Public API

    func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            // SF Symbol shipped on macOS 11+ — works on our deployment
            // target (13.0). Template image so it tints with menu bar.
            let img = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                              accessibilityDescription: "RAVEN mesh status")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageOnly
        }
        rebuildMenu()
        meshObserver = NotificationCenter.default.addObserver(
            forName: .ravenMeshStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                let count = note.userInfo?["connectedPeerCount"] as? Int ?? 0
                let advertising = note.userInfo?["advertising"] as? Bool ?? false
                self.lastPeerCount = count
                self.lastAdvertising = advertising
                self.rebuildMenu()
                self.updateBadge()
            }
        }
    }

    func hide() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        if let obs = meshObserver {
            NotificationCenter.default.removeObserver(obs)
            meshObserver = nil
        }
    }

    // MARK: - Build menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "RAVEN", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = NSAttributedString(
            string: "RAVEN",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let statusLabel = lastAdvertising
            ? "Mesh active · \(lastPeerCount) peer\(lastPeerCount == 1 ? "" : "s")"
            : "Mesh idle"
        let statusRow = NSMenuItem(title: statusLabel, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Open RAVEN",
            action: #selector(MenuBarBridge.openMain),
            keyEquivalent: "o"
        )
        openItem.target = MenuBarBridge.shared
        menu.addItem(openItem)

        let bgItem = NSMenuItem(
            title: "Run in background",
            action: #selector(MenuBarBridge.toggleBackground),
            keyEquivalent: ""
        )
        bgItem.state = BackgroundModeService.shared.isEnabled ? .on : .off
        bgItem.target = MenuBarBridge.shared
        menu.addItem(bgItem)

        let loginItem = NSMenuItem(
            title: "Launch at login",
            action: #selector(MenuBarBridge.toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.state = BackgroundModeService.shared.launchAtLoginEnabled ? .on : .off
        loginItem.target = MenuBarBridge.shared
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit RAVEN",
            action: #selector(MenuBarBridge.quit),
            keyEquivalent: "q"
        )
        quitItem.target = MenuBarBridge.shared
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func updateBadge() {
        guard let button = statusItem?.button else { return }
        // Tiny dot tint in the menu-bar icon: green = connected, dim = idle.
        let symbolName = lastPeerCount > 0
            ? "antenna.radiowaves.left.and.right.circle.fill"
            : "antenna.radiowaves.left.and.right"
        if let img = NSImage(systemSymbolName: symbolName,
                             accessibilityDescription: "RAVEN mesh status") {
            img.isTemplate = true
            button.image = img
        }
    }
}

// MARK: - Objective-C target bridge

/// AppKit's NSMenuItem.target requires an @objc-compatible class.
/// Bridge methods route the action through to our MainActor services.
@MainActor
final class MenuBarBridge: NSObject {
    static let shared = MenuBarBridge()

    @objc func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        // Find an existing window or open a new one. SwiftUI windows
        // attach to the WindowGroup at scene start; if the user closed
        // them all, ordering the first available NSWindow forward is
        // enough. As a fallback we toggle the activation policy briefly
        // to force the dock to surface a window.
        if let win = NSApp.windows.first(where: { !$0.isVisible || !$0.isMiniaturized }) {
            win.makeKeyAndOrderFront(nil)
            win.deminiaturize(nil)
        } else if let any = NSApp.windows.first {
            any.makeKeyAndOrderFront(nil)
        }
    }

    @objc func toggleBackground() {
        let cur = BackgroundModeService.shared.isEnabled
        BackgroundModeService.shared.setEnabled(!cur)
    }

    @objc func toggleLaunchAtLogin() {
        let cur = BackgroundModeService.shared.launchAtLoginEnabled
        BackgroundModeService.shared.setLaunchAtLogin(!cur)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
