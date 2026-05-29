// ChatStore — per-conversation state owned by ChatThreadView.
//
// Keeps the messages array, reactions cache, draft text, typing peers,
// pinned messages list, search results, and outgoing actions (edit /
// delete / pin / react / save) in one place so the view stays thin.
//
// Wiring:
//   • Subscribes to RealtimeEngine NotificationCenter events on init
//     (inbox arrivals, edits, deletes, reactions, pin updates, typing).
//   • Per-conversation drafts are persisted to UserDefaults.
//   • Read receipts: when the active conversation is open and a message
//     from the peer arrives or is loaded, we POST /api/messages/read
//     after a 600 ms idle so we don't burn the rate limit on scroll.
//   • Typing: sends `is_typing=true` on each keystroke (debounced to
//     3 s), and `is_typing=false` on send / blur.

import Foundation
import Combine
import SwiftUI

/// Shared ISO 8601 parser/writer that accepts fractional seconds. The
/// server stamps `edited_at` / `pinned_at` / `timestamp` with
/// microsecond precision (e.g. `2026-05-14T12:34:56.789Z`), which the
/// default `ISO8601DateFormatter()` (second precision only) silently
/// fails to parse — making `withEdited` and `onRemotePin` fall through
/// to "now", losing the real server time.
private let chatStoreISOParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Per-thread "hide for me" tombstones. When a user picks "Hide for
/// me" on a message, the row is removed from the local view but
/// stays on the server (and on every other participant's device) —
/// it's the privacy "I don't want to see this anymore" gesture, not
/// "Delete for everyone". Stored in UserDefaults keyed by
/// conversation id so a relaunch keeps the hide state.
enum MacHiddenMessageStore {
    private static func key(forConversation id: String) -> String {
        "raven_hidden_messages_\(id)"
    }

    static func ids(forConversation id: String) -> Set<String> {
        let raw = UserDefaults.standard.stringArray(forKey: key(forConversation: id)) ?? []
        return Set(raw)
    }

    static func hide(_ messageId: String, forConversation conversationId: String) {
        var s = ids(forConversation: conversationId)
        s.insert(messageId)
        UserDefaults.standard.set(Array(s), forKey: key(forConversation: conversationId))
    }
}

/// Per-thread disappearing-message default for the macOS chat. Mirrors
/// the iOS-side `ChatExpirySettings` — UserDefaults storage keyed by
/// conversation id. nil means the user hasn't enabled disappearing.
enum MacChatExpirySettings {
    private static func key(forConversation id: String) -> String {
        "raven_chat_expiry_\(id)"
    }

    static func mode(forConversation id: String) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: key(forConversation: id)),
              !raw.isEmpty else { return nil }
        return raw
    }

    static func setMode(_ mode: String?, forConversation id: String) {
        let k = key(forConversation: id)
        if let mode, !mode.isEmpty, mode != "none" {
            UserDefaults.standard.set(mode, forKey: k)
        } else {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}

@MainActor
final class ChatStore: ObservableObject {
    // MARK: - Inputs
    let conversationId: String
    let isGroup: Bool
    let myUserId: String?
    let peerName: String?

    // MARK: - State
    @Published var messages: [Message] = []
    @Published var loading = false
    @Published var loadError: String?
    /// Per-message reactions, keyed by message id.
    @Published var reactionsByMessage: [String: [MessageReactionRow]] = [:]
    @Published var pinned: [PinnedMessage] = []
    /// User ids currently typing in the open conversation (excludes self).
    @Published var typingUserIds: Set<String> = []
    /// Active reply target. When set, the composer shows a reply preview.
    @Published var replyTarget: Message?
    /// Active edit target. When set, the composer is in edit mode.
    @Published var editTarget: Message?
    /// Set to a string to surface a transient toast / error.
    @Published var toast: String?
    /// Search state.
    @Published var searchQuery: String = ""
    @Published var searchResults: [SearchMatch] = []
    @Published var searchInFlight = false
    /// Highlight a single message id (used for jump-to-result).
    @Published var highlightedMessageId: String?

    // MARK: - Drafts
    private var draftKey: String { "raven_draft_\(conversationId)" }
    var draftText: String {
        get { UserDefaults.standard.string(forKey: draftKey) ?? "" }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: draftKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: draftKey)
            }
        }
    }

    // MARK: - Internal
    private var observers: [AnyCancellable] = []
    private var typingDebounceTask: Task<Void, Never>?
    private var lastSentTypingState: Bool = false
    private var typingClearTimer: Timer?
    private var readReceiptTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    // MARK: - Init / lifecycle

    init(conversationId: String, isGroup: Bool, myUserId: String?, peerName: String?) {
        self.conversationId = conversationId
        self.isGroup = isGroup
        self.myUserId = myUserId
        self.peerName = peerName
        wireRealtime()
    }

    // No deinit: ChatStore is owned by SwiftUI's StateObject and dies
    // when the chat thread view goes away. Timers are paused implicitly
    // because no one's `Task` retains them once the store is gone, and
    // touching MainActor-isolated state from a nonisolated deinit
    // produces a Swift 6 warning anyway.

    // MARK: - Loading

    func reload() async {
        loading = true
        defer { loading = false }
        loadError = nil
        do {
            let fetched: [Message]
            if isGroup {
                fetched = try await NetworkService.shared.groupMessages(groupId: conversationId)
            } else {
                fetched = try await NetworkService.shared.conversation(with: conversationId)
            }
            let ordered = isGroup ? fetched : Array(fetched.reversed())
            // Server returns DM threads newest-first; reverse to chronological
            // for natural top-down rendering. Then drop locally-hidden rows
            // ("Hide for me" tombstones) so they don't reappear after reload.
            let hidden = MacHiddenMessageStore.ids(forConversation: conversationId)
            messages = hidden.isEmpty ? ordered : ordered.filter { !hidden.contains($0.id) }
            await loadPinned()
            scheduleReadReceipt()
        } catch {
            loadError = "Couldn't load conversation."
            #if DEBUG
            print("[chat] reload failed: \(error)")
            #endif
        }
    }

    /// "Hide for me" — remove `message` from the local view and remember
    /// the tombstone so a reload doesn't bring it back. Server-side
    /// row is untouched (use `deleteMessage` for delete-for-everyone).
    func hideForMe(_ message: Message) {
        MacHiddenMessageStore.hide(message.id, forConversation: conversationId)
        messages.removeAll { $0.id == message.id }
        reactionsByMessage[message.id] = nil
    }

    private func loadPinned() async {
        do {
            pinned = try await (
                isGroup
                    ? NetworkService.shared.pinnedGroup(groupId: conversationId)
                    : NetworkService.shared.pinnedDM(peerId: conversationId)
            )
        } catch {
            // Pinned list is non-critical; fall through silently.
            pinned = []
        }
    }

    // MARK: - Sending

    func sendText(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Edit branch — PATCH the existing message, replace in place.
        if let target = editTarget {
            do {
                let resp = try await NetworkService.shared.editMessage(
                    messageId: target.id,
                    content: trimmed
                )
                applyEdit(messageId: resp.id, content: resp.content, editedAt: resp.editedAt)
                editTarget = nil
            } catch {
                toast = "Couldn't edit message."
                #if DEBUG
                print("[chat] edit failed: \(error)")
                #endif
            }
            return
        }

        // Reply branch — capture target before clearing so the user sees
        // the preview disappear immediately.
        let reply = replyTarget
        replyTarget = nil

        await stopTyping()

        // 1:1 only: forward the user's per-thread disappearing-message
        // default through to the server so it can stamp expires_at.
        // Groups have their own time-bomb path; not surfaced here.
        let expiry = isGroup ? nil : MacChatExpirySettings.mode(forConversation: conversationId)

        // Generate a single client message id used as both:
        //   1) the row id of the optimistic local bubble inserted below,
        //   2) the `message_id` we forward to the server (it adopts it
        //      as the canonical row id and uses it for idempotency).
        // When `reload()` runs after the round-trip, the canonical row
        // collapses on top of the optimistic one — same id, no flicker.
        let clientMessageId = UUID().uuidString

        // Fire-and-forget BLE mesh broadcast for DMs. The server send
        // below remains the canonical path; mesh adds offline delivery
        // when the recipient is in BLE range. Both paths converge on
        // the recipient via dedup-by-clientMessageId.
        if !isGroup, let myId = myUserId {
            let envelope = MeshEnvelope.makeTextDM(
                senderId: myId,
                senderName: peerName ?? "",
                recipientId: conversationId,
                text: trimmed,
                replyToMessageId: reply?.id,
                replyToTextPreview: reply.flatMap(replyPreview),
                replyToSenderName: reply?.senderName
            )
            Task {
                _ = await BLEMeshEngine.shared.broadcastChat(envelope)
            }
        }

        // Optimistic insert (DM only) — the user sees their bubble
        // appear immediately instead of waiting for the round-trip +
        // reload(). Group messages skip this because they need
        // server-side fields (sender display name, group context) we
        // can't materialize locally.
        if !isGroup, let myId = myUserId {
            let pending = Message.localPending(
                id: clientMessageId,
                senderId: myId,
                recipientId: conversationId,
                content: trimmed,
                replyToMessageId: reply?.id,
                replyToTextPreview: reply.flatMap(replyPreview),
                replyToSenderName: reply?.senderName,
                replyToType: reply?.messageType ?? "text"
            )
            messages.append(pending)
        }

        do {
            if isGroup {
                _ = try await NetworkService.shared.sendGroupMessage(
                    groupId: conversationId, content: trimmed)
            } else {
                _ = try await NetworkService.shared.sendMessage(
                    recipientId: conversationId,
                    content: trimmed,
                    messageId: clientMessageId,
                    replyToMessageId: reply?.id,
                    replyToTextPreview: reply.flatMap(replyPreview),
                    replyToSenderName: reply?.senderName,
                    replyToType: reply?.messageType ?? "text",
                    expiryMode: expiry
                )
            }
            await reload()
        } catch APIError.authExpired {
            // Refresh-rotate already tried + failed — token genuinely
            // dead. Drop the optimistic bubble and bounce the user back
            // to the auth landing rather than leaving them clicking
            // send forever against a stale session.
            messages.removeAll { $0.id == clientMessageId }
            AuthService.shared.signOut()
        } catch {
            // Roll back the optimistic insert so the user doesn't think
            // the message persisted when it didn't.
            messages.removeAll { $0.id == clientMessageId }
            toast = "Couldn't send."
            #if DEBUG
            print("[chat] send failed: \(error)")
            #endif
        }
    }

    /// Schedule a text message for delivery at `scheduledAt`. The server
    /// stores it with `send_mode = "scheduled"` and the background worker
    /// flips it to instant + pushes to the recipient when the time
    /// arrives. Mirrors the iOS `MessageStore.sendScheduledText`.
    func sendScheduledText(_ raw: String, scheduledAt: Date) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isGroup else {
            toast = "Group scheduling isn't supported yet."
            return
        }
        do {
            _ = try await NetworkService.shared.sendMessage(
                recipientId: conversationId,
                content: trimmed,
                messageId: UUID().uuidString,
                sendMode: "scheduled",
                scheduledAtUtc: scheduledAt
            )
            let formatted = scheduledAt.formatted(date: .abbreviated, time: .shortened)
            toast = "Scheduled for \(formatted)"
        } catch APIError.authExpired {
            AuthService.shared.signOut()
        } catch {
            toast = "Couldn't schedule message."
            #if DEBUG
            print("[chat] schedule failed: \(error)")
            #endif
        }
    }

    private func replyPreview(_ m: Message) -> String? {
        let s = m.displayContent
        return String(s.prefix(120))
    }

    func sendVoice(audioUrl: String, duration: Int) async {
        do {
            if isGroup {
                _ = try await NetworkService.shared.sendGroupVoiceMessage(
                    groupId: conversationId, audioUrl: audioUrl, durationSeconds: duration)
            } else {
                _ = try await NetworkService.shared.sendVoiceMessage(
                    recipientId: conversationId, audioUrl: audioUrl, durationSeconds: duration)
            }
            await reload()
        } catch {
            toast = "Couldn't send voice."
        }
    }

    func sendImage(url: String) async {
        do {
            if isGroup {
                _ = try await NetworkService.shared.sendGroupImageMessage(
                    groupId: conversationId, imageUrl: url)
            } else {
                _ = try await NetworkService.shared.sendImageMessage(
                    recipientId: conversationId, imageUrl: url)
            }
            await reload()
        } catch {
            toast = "Couldn't send image."
        }
    }

    // MARK: - Message actions

    func deleteMessage(_ message: Message) async {
        do {
            try await NetworkService.shared.deleteMessage(messageId: message.id)
            messages.removeAll { $0.id == message.id }
            reactionsByMessage[message.id] = nil
            pinned.removeAll { $0.id == message.id }
        } catch {
            toast = "Couldn't delete."
        }
    }

    func toggleReaction(_ message: Message, emoji: String) async {
        do {
            let resp = try await NetworkService.shared.toggleReaction(
                messageId: message.id,
                emoji: emoji,
                isGroup: isGroup
            )
            reactionsByMessage[message.id] = resp.reactions
        } catch {
            toast = "Couldn't react."
        }
    }

    func togglePin(_ message: Message) async {
        let nowPinned = !(message.pinnedAt != nil)
        do {
            let resp = try await NetworkService.shared.togglePin(
                messageId: message.id,
                pinned: nowPinned,
                isGroup: isGroup
            )
            // Reflect in the local row so the bubble flips immediately.
            if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                let m = messages[idx]
                let updated = m.withPinState(
                    pinnedAt: resp.pinned ? (resp.pinnedAt ?? Date()) : nil,
                    pinnedByUserId: resp.pinnedByUserId
                )
                messages[idx] = updated
            }
            await loadPinned()
        } catch {
            toast = "Couldn't pin."
        }
    }

    func toggleSaved(_ message: Message, saved: Bool) async {
        do {
            if saved {
                _ = try await NetworkService.shared.saveMessage(
                    messageId: message.id, isGroup: isGroup)
            } else {
                try await NetworkService.shared.unsaveMessage(
                    messageId: message.id, isGroup: isGroup)
            }
        } catch {
            toast = "Couldn't update bookmark."
        }
    }

    /// Apply an `EditedMessage` payload to the local thread.
    private func applyEdit(messageId: String, content: String, editedAt: Date) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[idx] = messages[idx].withEdited(content: content, editedAt: editedAt)
    }

    // MARK: - Typing indicator

    /// Called from the composer's onChange. Sends `is_typing: true` lazily
    /// (only when the state flips) and arms a 3 s timer to flip it back
    /// to `false` if the user stops typing.
    func handleComposerChange() {
        if !lastSentTypingState {
            lastSentTypingState = true
            Task { try? await NetworkService.shared.sendTyping(
                peerId: conversationId, isTyping: true, isGroup: isGroup) }
        }
        typingClearTimer?.invalidate()
        typingClearTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.stopTyping() }
        }
    }

    func stopTyping() async {
        typingClearTimer?.invalidate()
        typingClearTimer = nil
        guard lastSentTypingState else { return }
        lastSentTypingState = false
        try? await NetworkService.shared.sendTyping(
            peerId: conversationId, isTyping: false, isGroup: isGroup)
    }

    // MARK: - Read receipts

    /// Mark visible messages as read after a short idle so scrolling doesn't
    /// hammer the endpoint. Group threads use a different read-receipt
    /// endpoint per server, but the iOS app never marks group reads from
    /// the same path — skip for groups for now.
    func scheduleReadReceipt() {
        guard !isGroup else { return }
        readReceiptTask?.cancel()
        readReceiptTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            try? await NetworkService.shared.markRead(peerId: conversationId, messageIds: nil)
        }
    }

    // MARK: - Search

    func runSearch(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = []
            searchInFlight = false
            return
        }
        // 1:1 only — server endpoint requires peer_id.
        guard !isGroup else {
            searchResults = []
            return
        }
        searchInFlight = true
        searchTask = Task {
            // 250 ms debounce.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let hits = try await NetworkService.shared.searchMessages(
                    peerId: conversationId, query: q)
                if !Task.isCancelled {
                    searchResults = hits
                    searchInFlight = false
                }
            } catch {
                searchResults = []
                searchInFlight = false
            }
        }
    }

    func jumpToMessage(_ id: String) {
        highlightedMessageId = id
        // Auto-clear the highlight after a moment so it doesn't linger.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                if highlightedMessageId == id { highlightedMessageId = nil }
            }
        }
    }

    // MARK: - Realtime wiring

    private func wireRealtime() {
        let nc = NotificationCenter.default

        observers.append(
            nc.publisher(for: .ravenInboxMessagesReceived)
                .sink { [weak self] note in
                    Task { @MainActor in await self?.onInboxBatch(note) }
                }
        )
        observers.append(
            nc.publisher(for: .ravenMessageEdited)
                .sink { [weak self] note in
                    Task { @MainActor in self?.onRemoteEdit(note) }
                }
        )
        observers.append(
            nc.publisher(for: .ravenMessageDeleted)
                .sink { [weak self] note in
                    Task { @MainActor in self?.onRemoteDelete(note) }
                }
        )
        observers.append(
            nc.publisher(for: .ravenMessageReaction)
                .sink { [weak self] note in
                    Task { @MainActor in self?.onRemoteReaction(note) }
                }
        )
        observers.append(
            nc.publisher(for: .ravenMessagePinned)
                .sink { [weak self] note in
                    Task { @MainActor in await self?.onRemotePin(note) }
                }
        )
        observers.append(
            nc.publisher(for: .ravenTyping)
                .sink { [weak self] note in
                    Task { @MainActor in self?.onRemoteTyping(note) }
                }
        )
        observers.append(
            nc.publisher(for: .ravenMessageSeen)
                .sink { [weak self] note in
                    Task { @MainActor in self?.onRemoteSeen(note) }
                }
        )
    }

    private func onInboxBatch(_ note: Notification) async {
        guard let batch = note.userInfo?["messages"] as? [Message] else { return }
        let touched = batch.contains { isInThisThread($0) }
        if touched { await reload() }
    }

    private func isInThisThread(_ m: Message) -> Bool {
        if isGroup {
            // Server inbox payload doesn't include group_id reliably; if
            // the message has no recipient (i.e. it's a group msg), assume
            // it might be ours and reload.
            return m.recipientId == nil
        }
        if m.senderId == conversationId { return true }
        if m.recipientId == conversationId, m.senderId == myUserId { return true }
        return false
    }

    private func onRemoteEdit(_ note: Notification) {
        guard let info = note.userInfo,
              let id = info["message_id"] as? String,
              let content = info["content"] as? String
        else { return }
        let editedAt: Date = {
            if let s = info["edited_at"] as? String,
               let d = chatStoreISOParser.date(from: s) { return d }
            return Date()
        }()
        applyEdit(messageId: id, content: content, editedAt: editedAt)
    }

    private func onRemoteDelete(_ note: Notification) {
        guard let info = note.userInfo,
              let id = info["message_id"] as? String
        else { return }
        messages.removeAll { $0.id == id }
        reactionsByMessage[id] = nil
        pinned.removeAll { $0.id == id }
    }

    private func onRemoteReaction(_ note: Notification) {
        guard let info = note.userInfo,
              let id = info["message_id"] as? String
        else { return }
        if let raw = info["reactions"] as? [[String: Any]] {
            // Re-encode and decode through our row decoder so dates and
            // CodingKeys are honored consistently.
            if let data = try? JSONSerialization.data(withJSONObject: raw),
               let decoded = try? JSONDecoder.snake.decode([MessageReactionRow].self, from: data) {
                reactionsByMessage[id] = decoded
            }
        }
    }

    private func onRemotePin(_ note: Notification) async {
        guard let info = note.userInfo,
              let id = info["message_id"] as? String
        else { return }
        let pinnedFlag = (info["pinned"] as? Bool) ?? false
        let pinnedAt: Date? = {
            if let s = info["pinned_at"] as? String,
               let d = chatStoreISOParser.date(from: s) { return d }
            return pinnedFlag ? Date() : nil
        }()
        let pinnedBy = info["pinned_by_user_id"] as? String
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx] = messages[idx].withPinState(
                pinnedAt: pinnedFlag ? pinnedAt : nil,
                pinnedByUserId: pinnedBy
            )
        }
        await loadPinned()
    }

    private func onRemoteTyping(_ note: Notification) {
        guard let info = note.userInfo,
              let by = info["by_user_id"] as? String,
              let isTyping = info["is_typing"] as? Bool
        else { return }
        let roomId = info["room_id"] as? String ?? ""
        let isGroupEvt = (info["is_group"] as? Bool) ?? false
        // For DMs the server sets room_id to the actor's id (peer is us).
        // We only care about typing FROM the current peer or, for groups,
        // FROM members of the current group.
        if isGroupEvt {
            guard isGroup, roomId == conversationId, by != myUserId else { return }
        } else {
            guard !isGroup, by == conversationId else { return }
        }
        if isTyping {
            typingUserIds.insert(by)
            // Auto-clear after 5 s if no follow-up event arrives.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run { _ = self?.typingUserIds.remove(by) }
            }
        } else {
            typingUserIds.remove(by)
        }
    }

    private func onRemoteSeen(_ note: Notification) {
        // Read receipts in 1:1 are surfaced via the message's own read_at,
        // which gets refreshed on the next reload. For now we just kick a
        // light reload to update the "seen" check on the latest bubble.
        Task { await reload() }
    }
}

// MARK: - Helpers

extension Message {
    func withEdited(content: String, editedAt: Date) -> Message {
        var dict: [String: Any] = [
            "id": id,
            "sender_id": senderId,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "content": content,
            "edited_at": ISO8601DateFormatter().string(from: editedAt),
        ]
        if let recipientId { dict["recipient_id"] = recipientId }
        if let messageType { dict["message_type"] = messageType }
        if let audioUrl { dict["audio_url"] = audioUrl }
        if let audioDurationSeconds { dict["audio_duration_seconds"] = audioDurationSeconds }
        if let fileName { dict["file_name"] = fileName }
        if let fileSize { dict["file_size"] = fileSize }
        if let mimeType { dict["mime_type"] = mimeType }
        if let senderName { dict["sender_name"] = senderName }
        if let senderAvatar { dict["sender_avatar"] = senderAvatar }
        if let replyToMessageId { dict["reply_to_message_id"] = replyToMessageId }
        if let replyToTextPreview { dict["reply_to_text_preview"] = replyToTextPreview }
        if let replyToSenderName { dict["reply_to_sender_name"] = replyToSenderName }
        if let replyToType { dict["reply_to_type"] = replyToType }
        if let readAt { dict["read_at"] = ISO8601DateFormatter().string(from: readAt) }
        if let deliveredAt { dict["delivered_at"] = ISO8601DateFormatter().string(from: deliveredAt) }
        if let pinnedAt { dict["pinned_at"] = ISO8601DateFormatter().string(from: pinnedAt) }
        if let pinnedByUserId { dict["pinned_by_user_id"] = pinnedByUserId }
        if let expiryMode { dict["expiry_mode"] = expiryMode }
        if let expiresAt { dict["expires_at"] = ISO8601DateFormatter().string(from: expiresAt) }
        if let allowForward { dict["allow_forward"] = allowForward }
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict),
            let decoded = try? JSONDecoder.snake.decode(Message.self, from: data)
        else { return self }
        return decoded
    }

    func withPinState(pinnedAt: Date?, pinnedByUserId: String?) -> Message {
        var dict: [String: Any] = [
            "id": id,
            "sender_id": senderId,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
        ]
        if let recipientId { dict["recipient_id"] = recipientId }
        if let content { dict["content"] = content }
        if let messageType { dict["message_type"] = messageType }
        if let audioUrl { dict["audio_url"] = audioUrl }
        if let audioDurationSeconds { dict["audio_duration_seconds"] = audioDurationSeconds }
        if let fileName { dict["file_name"] = fileName }
        if let fileSize { dict["file_size"] = fileSize }
        if let mimeType { dict["mime_type"] = mimeType }
        if let senderName { dict["sender_name"] = senderName }
        if let senderAvatar { dict["sender_avatar"] = senderAvatar }
        if let replyToMessageId { dict["reply_to_message_id"] = replyToMessageId }
        if let replyToTextPreview { dict["reply_to_text_preview"] = replyToTextPreview }
        if let replyToSenderName { dict["reply_to_sender_name"] = replyToSenderName }
        if let replyToType { dict["reply_to_type"] = replyToType }
        if let editedAt { dict["edited_at"] = ISO8601DateFormatter().string(from: editedAt) }
        if let readAt { dict["read_at"] = ISO8601DateFormatter().string(from: readAt) }
        if let deliveredAt { dict["delivered_at"] = ISO8601DateFormatter().string(from: deliveredAt) }
        if let pinnedAt { dict["pinned_at"] = ISO8601DateFormatter().string(from: pinnedAt) }
        if let pinnedByUserId { dict["pinned_by_user_id"] = pinnedByUserId }
        if let expiryMode { dict["expiry_mode"] = expiryMode }
        if let expiresAt { dict["expires_at"] = ISO8601DateFormatter().string(from: expiresAt) }
        if let allowForward { dict["allow_forward"] = allowForward }
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict),
            let decoded = try? JSONDecoder.snake.decode(Message.self, from: data)
        else { return self }
        return decoded
    }
}

extension JSONDecoder {
    /// Cached decoder configured with the same date strategy
    /// `RealtimeEngine` uses, so re-encoding then decoding `Message`
    /// stays consistent with what the server emits.
    static let snake: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let secs = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: secs)
            }
            let raw = try c.decode(String.self)
            var s = raw
            if let dot = s.firstIndex(of: ".") {
                var idx = s.index(after: dot)
                while idx < s.endIndex, s[idx].isNumber { idx = s.index(after: idx) }
                let digits = s.distance(from: s.index(after: dot), to: idx)
                if digits > 3 {
                    let keep = s.index(s.index(after: dot), offsetBy: 3)
                    s = String(s[..<keep]) + String(s[idx...])
                }
            }
            if s.contains(" ") && !s.contains("T") {
                s = s.replacingOccurrences(of: " ", with: "T")
            }
            let isoFractional = ISO8601DateFormatter()
            isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let v = isoFractional.date(from: s) { return v }
            if let v = iso.date(from: s) { return v }
            // Fall back to "standard" without offset.
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
            if let v = f.date(from: s) { return v }
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let v = f.date(from: s) { return v }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date: \(raw)")
        }
        return d
    }()
}

// MARK: - NotificationCenter additions

extension Notification.Name {
    /// Server `message_pinned` event — emitted by `RealtimeEngine` for any
    /// open chat to refresh its pinned bar.
    static let ravenMessagePinned = Notification.Name("RavenMessagePinned")
}
