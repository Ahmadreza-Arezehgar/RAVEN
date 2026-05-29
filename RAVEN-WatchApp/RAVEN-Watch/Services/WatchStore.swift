// WatchStore.swift
//
// Observable in-memory cache for everything the Watch renders.
//
// Source of truth flow:
//
//   iPhone state (SQLCipher DB)
//        │
//        │  PhoneSync (iOS side) projects to slim models
//        ▼
//   WCSession.updateApplicationContext({snapshot})
//        │
//        ▼
//   PhoneBridge → WatchStore.applyApplicationContext
//        │
//        ▼
//   @Published → SwiftUI views
//
// The Watch never writes to the snapshot directly. UI actions (send,
// react, like, comment) optimistically mutate local fields for
// responsiveness, then ask `PhoneBridge` to fire the intent over to the
// phone. The next snapshot from the phone overwrites optimistic state
// — if the phone's authoritative copy disagrees, the user sees the
// correction immediately.
//
// Persistence: a single JSON blob written to the App Group container
// after every apply. On cold start we read it back so the first frame
// already shows the last-known list instead of an empty screen.

import Foundation
import Combine

@MainActor
final class WatchStore: ObservableObject {
    static let shared = WatchStore()

    @Published private(set) var snapshot: WatchSnapshot = .empty
    @Published private(set) var threads: [String: [MessagePreview]] = [:]
    @Published private(set) var incomingHaptic: IncomingHaptic?

    /// Banner shown on the inbox when the phone says "I sent it but
    /// over mesh — recipient may not have it yet". The phone updates
    /// this in the next snapshot once it gets a delivery receipt.
    @Published private(set) var pendingMeshSends: Set<String> = []

    struct IncomingHaptic: Equatable, Identifiable {
        let senderName: String
        let preview: String
        let messageId: String
        let at: Date
        /// True when the phone marked this message as Vault / sensitive
        /// content. UI hides `preview` and shows a generic label.
        ///
        /// 🔴 hacker-audit 2026-05-19 — Vault-marked DMs were being
        /// rendered in plaintext on the wrist sheet (RootView.swift:96
        /// → `Text(haptic.preview)`). Anyone passing by can see them.
        /// Phone-side now sends `sensitive: true` for Vault content; if
        /// the field is absent the watch defaults to NOT sensitive so
        /// non-Vault messages still preview as before.
        let sensitive: Bool
        /// `messageId` is unique enough for the sheet's `item` binding —
        /// only one DM haptic is on screen at a time.
        var id: String { messageId }
    }

    private let groupId = "group.app.raven.shared"
    private let snapshotFile = "watch_snapshot.json"

    private init() {
        loadFromDisk()
        #if DEBUG
        if snapshot.conversations.isEmpty && snapshot.feed.isEmpty {
            seedDemoData()
        }
        #endif
    }

    #if DEBUG
    /// Populate the store with realistic-looking content so the
    /// Watch UI renders something useful on the simulator (where no
    /// paired iPhone is pushing snapshots). Bypassed when real data
    /// is already on disk. Excluded from Release builds entirely.
    private func seedDemoData() {
        let now = Date().timeIntervalSince1970
        let conversations: [ConversationSummary] = [
            .init(id: "room-sara",   title: "Sara Ahmadi",   lastPreview: "Mersi 🙏 ye saat dige miam.",         lastAt: now - 60,       unread: 2, isGroup: false, avatarInitial: "S"),
            .init(id: "room-team",   title: "RAVEN Core",    lastPreview: "Ali: PR-241 ready for review",       lastAt: now - 420,      unread: 5, isGroup: true,  avatarInitial: "R"),
            .init(id: "room-yash",   title: "Yash Patel",    lastPreview: "Sent a voice message",               lastAt: now - 1_800,    unread: 0, isGroup: false, avatarInitial: "Y"),
            .init(id: "room-port",   title: "ASH Port Ops",  lastPreview: "Crane B online, AGV-04 docking",     lastAt: now - 3_600,    unread: 1, isGroup: true,  avatarInitial: "A"),
            .init(id: "room-mom",    title: "Maman",         lastPreview: "Khoob hasti azizam?",                 lastAt: now - 7_200,    unread: 0, isGroup: false, avatarInitial: "M"),
        ]
        let feed: [PostPreview] = [
            .init(id: "post-1", authorName: "ali_dev",  authorInitial: "A", text: "Just shipped post-quantum pairing in v1.7. The ATSAM stack is real 🐦‍⬛", createdAt: now - 900,   likeCount: 42, commentCount: 8,  likedByMe: true,  hasMedia: false),
            .init(id: "post-2", authorName: "sara_a",   authorInitial: "S", text: "Mesh held through the whole Metro tunnel today. Three relays. No drops.",    createdAt: now - 5_400, likeCount: 17, commentCount: 3,  likedByMe: false, hasMedia: true),
            .init(id: "post-3", authorName: "ports_io", authorInitial: "P", text: "ASH AGV-04 just did 14 hours under the gantry without a charge.",            createdAt: now - 9_800, likeCount: 88, commentCount: 21, likedByMe: false, hasMedia: true),
        ]
        let rooms: [RoomSummary] = [
            .init(id: "room-live-1", name: "Late-night offline messaging",    participantCount: 12, joinedByMe: false, activeSpeakerName: "ali_dev"),
            .init(id: "room-live-2", name: "ASH x port ops standup",          participantCount: 4,  joinedByMe: false, activeSpeakerName: nil),
        ]
        let notifications: [NotificationItem] = [
            .init(id: "n1", kind: .mention,        actorName: "Sara Ahmadi", actorInitial: "S", summary: "mentioned you in RAVEN Core",          timestamp: now - 180,   target: "chat:room-team"),
            .init(id: "n2", kind: .reaction,       actorName: "ali_dev",     actorInitial: "A", summary: "reacted 🔥 to your post",              timestamp: now - 1_200, target: "post:post-1"),
            .init(id: "n3", kind: .comment,        actorName: "yash_p",      actorInitial: "Y", summary: "commented: \"this is huge\"",         timestamp: now - 3_300, target: "post:post-2"),
            .init(id: "n4", kind: .bridgeArrived,  actorName: "Maman",       actorInitial: "M", summary: "message delivered via mesh bridge",    timestamp: now - 6_600, target: "chat:room-mom"),
        ]
        self.snapshot = WatchSnapshot(
            conversations: conversations,
            notifications: notifications,
            rooms: rooms,
            feed: feed,
            generatedAt: now
        )
        // Pre-seed one thread so tapping the top chat row shows messages.
        self.threads["room-sara"] = [
            .init(id: "m1", senderId: "sara",  senderName: "Sara Ahmadi", text: "Salam, mishe ye saat dige biay?",         kind: .text,  timestamp: now - 600, outgoing: false, durationSeconds: nil, reactions: nil),
            .init(id: "m2", senderId: "me",    senderName: "",            text: "Are, ta 30 daghighe dige miam",            kind: .text,  timestamp: now - 540, outgoing: true,  durationSeconds: nil, reactions: nil),
            .init(id: "m3", senderId: "sara",  senderName: "Sara Ahmadi", text: nil,                                        kind: .voice, timestamp: now - 480, outgoing: false, durationSeconds: 7,   reactions: nil),
            .init(id: "m4", senderId: "sara",  senderName: "Sara Ahmadi", text: "Mersi 🙏 ye saat dige miam.",              kind: .text,  timestamp: now - 60,  outgoing: false, durationSeconds: nil, reactions: ["❤️": 1]),
        ]
    }
    #endif

    // MARK: - Apply (called from PhoneBridge)

    /// Receive a full state snapshot. The iPhone overwrites this whole
    /// blob on every state change so we don't have to reconcile diffs.
    func applyApplicationContext(_ context: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: context),
              let snap = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        else { return }
        self.snapshot = snap
        persistToDisk()
    }

    /// Receive a one-off message — incoming-DM haptic prompt, full
    /// thread paging, etc.
    func applyMessage(_ message: [String: Any]) {
        guard let kind = message["kind"] as? String else { return }

        switch kind {
        case "incoming-dm":
            handleIncomingDM(message)
        case "thread-snapshot":
            handleThreadSnapshot(message)
        case "thread-append":
            handleThreadAppend(message)
        case "post-update":
            handlePostUpdate(message)
        case "delivery-receipt":
            if let mid = message["messageId"] as? String {
                pendingMeshSends.remove(mid)
            }
        default:
            break
        }
    }

    private func handleIncomingDM(_ message: [String: Any]) {
        guard let name = message["senderName"] as? String,
              let preview = message["preview"] as? String,
              let mid = message["messageId"] as? String
        else { return }
        // Phone signals Vault / sensitive content via this flag.
        let sensitive = (message["sensitive"] as? Bool) ?? false
        self.incomingHaptic = IncomingHaptic(
            senderName: name,
            preview: sensitive ? "New message" : preview,
            messageId: mid,
            at: Date(),
            sensitive: sensitive
        )
    }

    private func handleThreadSnapshot(_ message: [String: Any]) {
        guard let roomId = message["roomId"] as? String,
              let messagesArray = message["messages"] as? [[String: Any]]
        else { return }
        let decoded: [MessagePreview] = messagesArray.compactMap { raw in
            guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return try? JSONDecoder().decode(MessagePreview.self, from: data)
        }
        threads[roomId] = decoded
    }

    private func handleThreadAppend(_ message: [String: Any]) {
        guard let roomId = message["roomId"] as? String,
              let raw = message["message"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let preview = try? JSONDecoder().decode(MessagePreview.self, from: data)
        else { return }
        var existing = threads[roomId] ?? []
        if !existing.contains(where: { $0.id == preview.id }) {
            existing.append(preview)
            threads[roomId] = existing
        }
    }

    private func handlePostUpdate(_ message: [String: Any]) {
        guard let postId = message["postId"] as? String else { return }
        var feed = snapshot.feed
        guard let idx = feed.firstIndex(where: { $0.id == postId }) else { return }
        let old = feed[idx]
        feed[idx] = PostPreview(
            id: old.id,
            authorName: old.authorName,
            authorInitial: old.authorInitial,
            text: old.text,
            createdAt: old.createdAt,
            likeCount: (message["likeCount"] as? Int) ?? old.likeCount,
            commentCount: (message["commentCount"] as? Int) ?? old.commentCount,
            likedByMe: (message["likedByMe"] as? Bool) ?? old.likedByMe,
            hasMedia: old.hasMedia
        )
        snapshot.feed = feed
    }

    // MARK: - Optimistic mutations from UI

    /// Append a locally-composed message to the thread cache before the
    /// phone confirms. The next snapshot from the phone replaces this
    /// optimistic copy with the authoritative one (same id).
    func appendOptimisticMessage(_ msg: MessagePreview, roomId: String) {
        var existing = threads[roomId] ?? []
        existing.append(msg)
        threads[roomId] = existing
    }

    /// Used while waiting for the phone's delivery receipt. The inbox
    /// shows a faint mesh-routing badge on rows with pending sends.
    func markPendingMeshSend(_ messageId: String) {
        pendingMeshSends.insert(messageId)
    }

    /// Toggle the optimistic like state while the phone API call runs.
    /// If the phone disagrees, the next snapshot overrides this.
    func toggleLikeOptimistic(postId: String) {
        var feed = snapshot.feed
        guard let idx = feed.firstIndex(where: { $0.id == postId }) else { return }
        let p = feed[idx]
        let nowLiked = !p.likedByMe
        feed[idx] = PostPreview(
            id: p.id, authorName: p.authorName, authorInitial: p.authorInitial,
            text: p.text, createdAt: p.createdAt,
            likeCount: p.likeCount + (nowLiked ? 1 : -1),
            commentCount: p.commentCount, likedByMe: nowLiked,
            hasMedia: p.hasMedia
        )
        snapshot.feed = feed
    }

    func clearHaptic() { incomingHaptic = nil }

    // MARK: - Persistence

    private var storeURL: URL? {
        // App Group when available (real device / properly-signed sim).
        if let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupId) {
            return base.appendingPathComponent(snapshotFile)
        }
        // Fallback to Documents — simulator without signed entitlements
        // returns nil from the App Group lookup, and so does any future
        // build that drops the group capability. Persistence still
        // works locally; the auth-token mirror (which needs the group)
        // simply no-ops in that mode.
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        return docs.appendingPathComponent(snapshotFile)
    }

    private func persistToDisk() {
        guard let url = storeURL,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadFromDisk() {
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        else { return }
        self.snapshot = snap
    }
}
