// WatchSnapshotProjector.swift
//
// Projects the iPhone's full chat / feed / room / notification state
// down into the slim `WatchSnapshot` shape the paired Apple Watch
// renders. This is the iPhone half of the sync model documented in
// `RAVEN-WatchApp/README.md` (§ "Wiring the iPhone side"):
//
//   ConversationStore  ┐
//   FeedStore          ├─► [observe + debounce 250 ms]
//   RoomService        ┤            │
//   AudioRoomManager   ┘            ▼
//                              build dict
//                                    │
//                                    ▼
//             WatchBridgeService.pushApplicationContext
//                                    │
//                                    ▼
//                          Watch ‹ updateApplicationContext
//
// The projector also drives:
//
//   • Thread snapshots — when the Watch sends `subscribe-thread`, we
//     read the last 50 messages for that room from MessageRepository
//     and push them as a `thread-snapshot` payload.
//   • Thread appends — when an inbound message arrives for a thread
//     the Watch is subscribed to, we push a `thread-append`.
//   • Auth-token sync — on every successful sign-in, the iPhone calls
//     `WatchSnapshotProjector.shared.publishAuthToken(_:)` which writes
//     to the shared App Group container so the Watch's RemoteAPI
//     fallback (cellular Series 4+) can hit `/api/messages/send`
//     directly when the iPhone is unreachable.
//
// One unresolved seam: there is no central NotificationStore on the
// iPhone yet (the iOS app builds `NotificationsListView` from a query
// each time), so the projector emits an empty `[NotificationItem]`.
// When a store lands, plug it into `buildNotifications()` and the
// Alerts tab on the Watch starts populating automatically.

import Foundation
import Combine

@MainActor
final class WatchSnapshotProjector {
    static let shared = WatchSnapshotProjector()

    private let groupId = "group.app.raven.shared"
    private let authFile = "auth.json"

    private var cancellables = Set<AnyCancellable>()
    private var pushTask: Task<Void, Never>?
    private var subscribedRoomIds: Set<String> = []
    private var didStart = false

    private init() {}

    // MARK: - Lifecycle

    /// Call once from `RAVENApp.init` (or wherever
    /// `BLEMeshEngine.start()` runs). Idempotent.
    func start() {
        guard !didStart else { return }
        didStart = true

        observeConversationStore()
        observeWatchIntents()
        observeIncomingMessages()

        // First push so the Watch has something to render even if no
        // store has changed yet.
        schedulePush(delay: 50_000_000)
    }

    // MARK: - Auth token publishing (for standalone Watch LTE)

    /// Persist the current bearer token into the shared App Group
    /// container. The Watch reads it from `RemoteAPI` when WCSession
    /// reports the iPhone unreachable but the Watch has its own network
    /// path (cellular or saved Wi-Fi).
    ///
    /// Call from `AuthService` after every successful sign-in and again
    /// on token refresh. Call with `nil` on sign-out.
    func publishAuthToken(_ token: String?) {
        guard let url = authFileURL else { return }
        if let token {
            // 🔴 ROUND 26 (2026-05-16) — hacker-audit MESH-HIGH-3.
            // Earlier rounds fixed file-protection class but the file
            // body itself was still plaintext, so any process with
            // the App Group entitlement could read the bearer token
            // verbatim post-unlock. The right fix per the audit is a
            // per-pair symmetric key derived via WCSession; that
            // wiring lands in this round.
            //
            // We DUAL-WRITE during the rollout:
            //   • `raven.auth.token`     — legacy plaintext, kept
            //     so older RAVEN-Watch builds keep working. Will
            //     be removed in a flag-day round once the entire
            //     Watch fleet has the new RemoteAPI reader.
            //   • `raven.auth.token.enc` — ChaChaPoly.seal(token, key)
            //     where `key` is the per-install AES-256 wrap key
            //     stored in the iPhone Keychain (no access group,
            //     so other processes cannot read it). The Watch
            //     receives a copy of `key` over WCSession (see
            //     `WatchBridgeService.publishAuthWrapKey`) and
            //     caches it in its own Keychain.
            //
            // After the flag-day flip, the App Group file holds ONLY
            // the encrypted token; a backup-extracted file is a
            // tagged ciphertext blob.
            Task.detached(priority: .utility) {
                var payload: [String: Any] = ["raven.auth.token": token]
                if let enc = await WatchAuthKeyStore.shared.encryptToken(token) {
                    payload["raven.auth.token.enc"] = enc
                    payload["raven.auth.token.kid"] = "v1"
                }
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    // `.completeFileProtection` keeps the file
                    // unreadable while the device is locked. The
                    // encrypted-blob upgrade defends post-unlock.
                    try? data.write(to: url, options: [.atomic, .completeFileProtection])

                    // 🔴 ROUND 35 (2026-05-19) — iCloud-backup leak.
                    //
                    // PREVIOUSLY: the App Group container at
                    // `group.app.raven.shared/` was included in
                    // iCloud backup by default. Even though the
                    // auth-token bytes are now ChaChaPoly-sealed
                    // (round 30), the surrounding files in this
                    // container — and any future snapshot files
                    // the WatchSnapshotProjector caches here —
                    // would still ride into the user's iCloud
                    // backup. Apple-cooperative or compromised-
                    // Apple-ID adversaries could pull message
                    // previews / post text out of the backup.
                    //
                    // FIX: explicitly exclude every App Group
                    // file we write from iCloud backup. The Watch
                    // gets a fresh snapshot from the iPhone on
                    // pair / launch / reachability, so excluding
                    // these files costs us nothing in UX and
                    // closes the backup-extraction sidechannel.
                    var rv = URLResourceValues()
                    rv.isExcludedFromBackup = true
                    var mutableURL = url
                    try? mutableURL.setResourceValues(rv)
                }
                // Make sure the paired Watch has the wrap key — if
                // this is the first sign-in we may not have shipped
                // it yet. Idempotent on the Watch side.
                await MainActor.run {
                    WatchBridgeService.shared.publishAuthWrapKey()
                }
            }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var authFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupId)?
            .appendingPathComponent(authFile)
    }

    // MARK: - Observe store changes

    /// ConversationStore uses the Swift Observation framework
    /// (`@Observable`), so we observe it with `withObservationTracking`
    /// and self-re-arm on every fired change.
    private func observeConversationStore() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = withObservationTracking {
                _ = ConversationStore.shared.conversations
                _ = ConversationStore.shared.lastSyncTime
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.schedulePush()
                    self?.observeConversationStore()
                }
            }
        }
    }

    /// Watch → iPhone intents that reshape projector behavior.
    private func observeWatchIntents() {
        NotificationCenter.default.addObserver(
            forName: .ravenWatchRequestSnapshot, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pushNow() }
        }

        NotificationCenter.default.addObserver(
            forName: .ravenWatchSubscribeThread, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let roomId = note.userInfo?["roomId"] as? String else { return }
                self?.subscribedRoomIds.insert(roomId)
                await self?.pushThreadSnapshot(roomId: roomId)
            }
        }
    }

    /// When new messages land we want both:
    ///   • The inbox snapshot to refresh (last preview + unread count)
    ///   • A thread-append for any room the Watch is currently viewing
    private func observeIncomingMessages() {
        NotificationCenter.default.addObserver(
            forName: MessageStore.meshMessageReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.schedulePush()
                if let roomId = note.userInfo?["roomId"] as? String,
                   self?.subscribedRoomIds.contains(roomId) == true {
                    await self?.pushLatestAppend(roomId: roomId)
                }
            }
        }
    }

    // MARK: - Snapshot building

    private func schedulePush(delay: UInt64 = 250_000_000) {
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            self?.pushNow()
        }
    }

    private func pushNow() {
        let snapshot: [String: Any] = [
            "c": buildConversations(),
            "n": buildNotifications(),
            "ts": Date().timeIntervalSince1970,
        ]
        WatchBridgeService.shared.pushApplicationContext(snapshot)
    }

    private func buildConversations() -> [[String: Any]] {
        // Keep the slice small — Apple Watch screens render maybe 4-5
        // rows before scrolling. 30 is generous and leaves headroom for
        // unread-count counting.
        // `Conversation.isArchived` was removed in the Phase-4 revert
        // — show every conversation instead of filtering archived
        // ones until the field comes back.
        let recent = ConversationStore.shared.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(30)

        return recent.map { conv in
            let title = (conv.isGroup ? conv.groupName : nil) ?? conv.peer.displayName
            let preview = conv.lastMessage?.preview ?? ""
            let initial = String(title.prefix(1)).uppercased()
            return [
                "id": conv.roomId,
                "t":  title,
                "lp": String(preview.prefix(80)),
                "la": conv.updatedAt.timeIntervalSince1970,
                "u":  conv.unreadCount,
                "g":  conv.isGroup,
                "ai": initial,
            ]
        }
    }

    private func buildNotifications() -> [[String: Any]] {
        // No central NotificationStore yet — see file header. Wire here
        // when one lands, and the Watch's Alerts tab populates.
        return []
    }

    // MARK: - Thread snapshots / appends

    /// Push the last 50 messages of a thread to the Watch in response
    /// to a `subscribe-thread` intent.
    private func pushThreadSnapshot(roomId: String) async {
        let rows = (try? await MessageRepository.shared.getMessages(roomId: roomId, limit: 50)) ?? []
        let myId = await KeychainService.shared.getUserId() ?? ""
        let previews = rows.compactMap { row -> [String: Any]? in
            messageRowToPreviewDict(row, myUserId: myId)
        }
        WatchBridgeService.shared.pushThreadSnapshot(roomId: roomId, messages: previews)
    }

    /// After a `meshMessageReceivedNotification` we read the freshest
    /// message for the affected room and ship it as a thread-append.
    private func pushLatestAppend(roomId: String) async {
        let rows = (try? await MessageRepository.shared.getMessages(roomId: roomId, limit: 1)) ?? []
        guard let row = rows.first else { return }
        let myId = await KeychainService.shared.getUserId() ?? ""
        guard let preview = messageRowToPreviewDict(row, myUserId: myId) else { return }
        WatchBridgeService.shared.pushThreadAppend(roomId: roomId, message: preview)
    }

    /// Translate a raw SQLite row from MessageRepository into the slim
    /// shape `RAVEN-Watch/Models/WatchModels.swift::MessagePreview`
    /// decodes. Returns nil for rows we can't safely render (missing
    /// id / sender, etc) — the Watch renders the rest of the thread
    /// just fine without one bad row.
    private func messageRowToPreviewDict(_ row: [String: Any], myUserId: String) -> [String: Any]? {
        guard let id = row["client_message_id"] as? String,
              let senderId = row["sender_id"] as? String
        else { return nil }
        let senderName = (row["sender_name"] as? String) ?? ""
        let text = row["text"] as? String
        let typeIdx = (row["type"] as? Int) ?? (row["message_type"] as? Int) ?? 0
        let kind = mapTypeIndexToKind(typeIdx)
        let timestamp = parseTimestamp(row["timestamp"]) ?? Date().timeIntervalSince1970
        let outgoing = (senderId == myUserId)
        let duration = row["audio_duration_seconds"] as? Int

        var payload: [String: Any] = [
            "id":  id,
            "sid": senderId,
            "sn":  senderName,
            "k":   kind,
            "ts":  timestamp,
            "o":   outgoing,
        ]
        if let text { payload["txt"] = text }
        if let duration { payload["ds"] = duration }
        return payload
    }

    private func mapTypeIndexToKind(_ idx: Int) -> String {
        switch idx {
        case 0: return "text"
        case 1: return "image"
        case 2: return "file"
        case 3: return "voice"
        case 5: return "post"
        case 6: return "system"
        default: return "text"
        }
    }

    private func parseTimestamp(_ raw: Any?) -> TimeInterval? {
        if let s = raw as? String {
            return SharedDateFormatters.parseISO8601(s)?.timeIntervalSince1970
        }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return TimeInterval(i) }
        return nil
    }
}
