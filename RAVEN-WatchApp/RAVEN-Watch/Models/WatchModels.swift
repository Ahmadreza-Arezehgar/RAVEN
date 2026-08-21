// WatchModels.swift
//
// Slimmed Codable mirrors of the iPhone-side conversation models.
// These are intentionally *not* a copy of `ChatMessage` — they hold only
// the fields a 41–49mm watch screen can
// actually render. The phone projects its full models down into these
// shapes before sending over WCSession, which keeps every payload below
// the ~64KB WCSession limit even for accounts with thousands of chats.
//
// Wire keys are short to keep `transferUserInfo` payloads small. Field
// names mirror MeshEnvelope's compact convention where possible.

import Foundation

// MARK: - Conversation list (Inbox tab)

struct ConversationSummary: Codable, Identifiable, Hashable {
    let id: String              // roomId on the phone
    let title: String           // peer display name or group name
    let lastPreview: String     // up to ~80 chars; phone truncates
    let lastAt: TimeInterval    // unix seconds
    let unread: Int
    let isGroup: Bool
    let avatarInitial: String   // single character — phone resolves avatar URL,
                                // watch falls back to initial in a circle

    enum CodingKeys: String, CodingKey {
        case id, title = "t", lastPreview = "lp", lastAt = "la"
        case unread = "u", isGroup = "g", avatarInitial = "ai"
    }
}

// MARK: - Single thread (Chat view)

struct MessagePreview: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, image, voice, file, system, post }

    let id: String              // clientMessageId
    let senderId: String
    let senderName: String
    let text: String?           // already decrypted on the phone
    let kind: Kind
    let timestamp: TimeInterval
    let outgoing: Bool
    let durationSeconds: Int?   // for .voice
    /// Per-message reaction counts. emoji → count. Computed by the phone
    /// after collapsing all relay receipts; the watch just displays.
    let reactions: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case id, senderId = "sid", senderName = "sn", text = "txt"
        case kind = "k", timestamp = "ts", outgoing = "o"
        case durationSeconds = "ds", reactions = "rx"
    }
}

// MARK: - Notifications (Notifications tab)

struct NotificationItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case mention            // @you in a group chat
        case reaction           // someone reacted to your message
        // Legacy decode-only cases. Filtered before entering the UI.
        case comment
        case follow
        case bridgeArrived      // a bridged DM finally arrived from an offline peer
    }

    let id: String
    let kind: Kind
    let actorName: String
    let actorInitial: String
    let summary: String
    let timestamp: TimeInterval
    /// Deep-link target on the phone — when the user taps the row the
    /// watch echoes this back as `"open"` and the phone opens the
    /// corresponding screen. Watch never renders the target itself.
    let target: String

    enum CodingKeys: String, CodingKey {
        case id, kind = "k", actorName = "an", actorInitial = "ai"
        case summary = "s", timestamp = "ts", target = "tg"
    }

    var isMessagingProductEvent: Bool {
        switch kind {
        case .mention, .reaction, .bridgeArrived:
            return target.hasPrefix("chat:")
        case .comment, .follow:
            return false
        }
    }
}

// MARK: - Top-level snapshot the phone sends on every change

/// The phone overwrites this whole snapshot via
/// `updateApplicationContext` whenever any tab's state changes. WCSession
/// only keeps the most recent context, so the Watch never sees stale
/// snapshots after a sleep/wake cycle.
struct WatchSnapshot: Codable {
    var conversations: [ConversationSummary]
    var notifications: [NotificationItem]
    var generatedAt: TimeInterval

    static let empty = WatchSnapshot(
        conversations: [], notifications: [],
        generatedAt: 0
    )

    enum CodingKeys: String, CodingKey {
        case conversations = "c", notifications = "n", generatedAt = "ts"
    }
}
