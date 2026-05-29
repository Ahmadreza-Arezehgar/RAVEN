//
//  ChatChromePreferences.swift
//  RAVEN
//
//  (2026-05-15 — round 5) Per-chat client-side settings surfaced in
//  the new ChatDetailsView sections (disappearing messages timer,
//  always-vault toggle, wallpaper override, etc.). Each preference
//  is keyed by `roomId` so 1:1 and group rooms share the same store.
//
//  Why UserDefaults (not Keychain or SQLite):
//    • Settings are non-secret and tiny (handful of strings/ints
//      per chat). UserDefaults gives us atomic writes, instant reads,
//      and no schema migrations.
//    • Server-side persistence is a TODO (see comments on each
//      property) — when those endpoints land, this file becomes a
//      thin cache in front of the network calls; the section views
//      keep their existing API.
//
//  Threading: NotificationCenter posts a per-chat update notification
//  so SwiftUI views can refresh without polling. The store itself is
//  thread-safe because UserDefaults is.

import Foundation
import Combine

/// Disappearing-message timer choices. Mirrors WhatsApp / Signal so
/// users transferring between apps don't have to relearn the menu.
enum DisappearingTimer: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case thirtySeconds = 30
    case fiveMinutes = 300
    case oneHour = 3600
    case eightHours = 28_800
    case oneDay = 86_400
    case sevenDays = 604_800
    case thirtyDays = 2_592_000

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .thirtySeconds: return "30 seconds"
        case .fiveMinutes: return "5 minutes"
        case .oneHour: return "1 hour"
        case .eightHours: return "8 hours"
        case .oneDay: return "24 hours"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "timer"
        case .thirtySeconds, .fiveMinutes, .oneHour, .eightHours: return "clock.fill"
        case .oneDay, .sevenDays, .thirtyDays: return "clock.badge.checkmark.fill"
        }
    }
}

/// Wallpaper choice for a single chat. We ship a small built-in set
/// today; custom user images can be added later by extending this
/// enum with an associated value.
enum ChatWallpaper: String, CaseIterable, Identifiable, Codable {
    case `default`
    case midnight
    case forest
    case sunset
    case lavender
    case slate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .midnight: return "Midnight"
        case .forest: return "Forest"
        case .sunset: return "Sunset"
        case .lavender: return "Lavender"
        case .slate: return "Slate"
        }
    }

    /// Two-stop gradient used to render the chat background. Returns
    /// nil for `.default` so the surface keeps the system background.
    var gradientStops: [String]? {
        switch self {
        case .default: return nil
        case .midnight: return ["#0F172A", "#1E293B"]
        case .forest: return ["#064E3B", "#022C22"]
        case .sunset: return ["#7C2D12", "#9A3412"]
        case .lavender: return ["#581C87", "#6B21A8"]
        case .slate: return ["#1F2937", "#111827"]
        }
    }
}

/// Per-chat preferences singleton. Reads/writes are O(1) via
/// UserDefaults; observers can subscribe to `didChange` for live
/// updates (the SwiftUI sections do this automatically through
/// `@Published` mirror state on the view side).
final class ChatChromePreferences: @unchecked Sendable {
    static let shared = ChatChromePreferences()

    /// Notification posted when any per-chat key changes. `userInfo`
    /// includes `roomId: String` so listeners can scope updates.
    static let didChangeNotification = Notification.Name("raven.chatChrome.didChange")

    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - Disappearing messages
    //
    // 🔴 v1.8 — the per-conversation timer is now a SERVER setting
    // (GET/PUT /api/messages/conversation/{peer}/disappearing). The
    // value stored here is a local cache: `ChatChromeObservable`
    // hydrates it from the server on appear and writes through on
    // change. The server stamps `expires_at` + purges server-side;
    // the on-device copy is swept by
    // `MessageRepository.purgeExpiredMessages`.

    func disappearingTimer(roomId: String) -> DisappearingTimer {
        let raw = defaults.integer(forKey: Self.key("disappear", roomId))
        return DisappearingTimer(rawValue: raw) ?? .off
    }

    func setDisappearingTimer(_ value: DisappearingTimer, roomId: String) {
        defaults.set(value.rawValue, forKey: Self.key("disappear", roomId))
        post(roomId: roomId)
    }

    // MARK: - Always Vault

    /// When true, every attachment sent in this room is encrypted via
    /// `VaultFileCrypto` regardless of the per-send vault toggle.
    /// Read by `AttachmentService` before falling back to the
    /// per-send flag.
    func alwaysVault(roomId: String) -> Bool {
        defaults.bool(forKey: Self.key("alwaysVault", roomId))
    }

    func setAlwaysVault(_ value: Bool, roomId: String) {
        defaults.set(value, forKey: Self.key("alwaysVault", roomId))
        post(roomId: roomId)
    }

    // MARK: - Wallpaper

    func wallpaper(roomId: String) -> ChatWallpaper {
        let raw = defaults.string(forKey: Self.key("wallpaper", roomId)) ?? ChatWallpaper.default.rawValue
        return ChatWallpaper(rawValue: raw) ?? .default
    }

    func setWallpaper(_ value: ChatWallpaper, roomId: String) {
        defaults.set(value.rawValue, forKey: Self.key("wallpaper", roomId))
        post(roomId: roomId)
    }

    // MARK: - Helpers

    private static func key(_ kind: String, _ roomId: String) -> String {
        return "raven.chatChrome.\(kind).\(roomId)"
    }

    private func post(roomId: String) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: ["roomId": roomId]
        )
    }
}

// MARK: - SwiftUI live observer
//
// Tiny wrapper that re-publishes the prefs as observable so each
// section view can `@StateObject` it without dealing with
// NotificationCenter directly. Per-room scoped to avoid waking views
// on irrelevant changes.

import SwiftUI

@MainActor
final class ChatChromeObservable: ObservableObject {
    let roomId: String

    @Published private(set) var disappearingTimer: DisappearingTimer
    @Published private(set) var alwaysVault: Bool
    @Published private(set) var wallpaper: ChatWallpaper

    private var token: NSObjectProtocol?

    init(roomId: String) {
        self.roomId = roomId
        let store = ChatChromePreferences.shared
        self.disappearingTimer = store.disappearingTimer(roomId: roomId)
        self.alwaysVault = store.alwaysVault(roomId: roomId)
        self.wallpaper = store.wallpaper(roomId: roomId)

        token = NotificationCenter.default.addObserver(
            forName: ChatChromePreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let changedRoom = note.userInfo?["roomId"] as? String,
                  changedRoom == self.roomId else { return }
            self.disappearingTimer = store.disappearingTimer(roomId: self.roomId)
            self.alwaysVault = store.alwaysVault(roomId: self.roomId)
            self.wallpaper = store.wallpaper(roomId: self.roomId)
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    func setDisappearingTimer(_ value: DisappearingTimer) {
        let previous = disappearingTimer
        // Optimistic local update so the picker feels instant.
        disappearingTimer = value
        ChatChromePreferences.shared.setDisappearingTimer(value, roomId: roomId)
        // The timer is a SHARED conversation setting — push it to the
        // server, which enforces expiry for both participants. Roll
        // the local value back if the server rejects it.
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await NetworkService.shared.setConversationDisappearing(
                    peerId: self.roomId, seconds: value.rawValue)
            } catch {
                self.disappearingTimer = previous
                ChatChromePreferences.shared.setDisappearingTimer(previous, roomId: self.roomId)
                #if DEBUG
                print("⚠️ [Disappearing] server update failed: \(error)")
                #endif
            }
        }
    }

    /// Pull the authoritative disappearing-messages timer from the
    /// server (a shared per-conversation setting) and refresh the
    /// local cache. Safe to call on view appear; keeps the cached
    /// value on failure (offline, etc.).
    func hydrateDisappearingFromServer() async {
        do {
            let dto = try await NetworkService.shared.conversationDisappearing(peerId: roomId)
            let timer = DisappearingTimer(rawValue: dto.disappearingSeconds) ?? .off
            disappearingTimer = timer
            ChatChromePreferences.shared.setDisappearingTimer(timer, roomId: roomId)
        } catch {
            #if DEBUG
            print("⚠️ [Disappearing] hydrate failed: \(error)")
            #endif
        }
    }

    func setAlwaysVault(_ value: Bool) {
        ChatChromePreferences.shared.setAlwaysVault(value, roomId: roomId)
    }

    func setWallpaper(_ value: ChatWallpaper) {
        ChatChromePreferences.shared.setWallpaper(value, roomId: roomId)
    }
}
