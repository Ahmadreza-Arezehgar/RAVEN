import Foundation
import Combine
import SwiftUI

// Helper for empty POST body
private struct EmptyBody: Encodable {}

private extension String {
    /// Returns nil instead of an empty string. Lets `??` chain
    /// gracefully through optional fallbacks.
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Notification Pipeline
/// Central service for managing toast notifications with queue and merge logic
@MainActor
final class NotificationPipeline: ObservableObject {
    
    // MARK: - Singleton
    static let shared = NotificationPipeline()
    
    // MARK: - Published State
    @Published var currentToast: ToastItem?

    /// Sliding-window dedupe to suppress same-message-multiple-channel
    /// duplicates (WebSocket + APNS typically arrive within ~50–200ms of
    /// each other). Key → time-of-first-show.
    private var recentlyShown: [String: Date] = [:]
    @Published var quickReplyState: QuickReplyState?
    @Published var unreadCount: Int = 0
    
    // MARK: - Private
    private var queue: [ToastItem] = []
    private var dismissTask: Task<Void, Never>?
    private var isPaused: Bool = false
    
    /// Toast display duration in seconds
    private let displayDuration: UInt64 = 3_000_000_000 // 3 seconds
    
    /// Time window for merging similar notifications (seconds)
    private let mergeWindow: TimeInterval = 5.0
    
    private init() {}
    
    // MARK: - Public API
    
    /// Enqueue a new toast notification
    func enqueue(_ item: ToastItem) {
        // 🔴 Bug fix (2026-05-09): if both title and body come in
        // empty (race between push payload arrival and conversation
        // metadata resolution, or a malformed mesh frame), the toast
        // capsule rendered as a nearly-empty box with just the type
        // dot — looked broken to the user. Sanitize at the boundary
        // so we ALWAYS show something meaningful instead.
        var item = item
        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody  = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            item.title = item.senderName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? defaultTitle(for: item.type)
        }
        if trimmedBody.isEmpty {
            item.body = defaultBody(for: item.type)
        }

        #if DEBUG
        print("🍞🍞 [NotificationPipeline] enqueue called for: \(item.type) - \(item.title)")
        #endif

        // ⚡ DEDUPE: WebSocket and APNS often deliver the same message within
        // milliseconds — without dedupe, the user gets two in-app toasts for
        // ONE message. We keep a 5-second sliding window of recently-shown
        // toast keys and drop exact duplicates. The key is type + chatId +
        // sender + first 60 chars of body, which uniquely identifies a
        // single notification across delivery channels.
        let dedupeKey = "\(item.type.rawValue)|\(item.chatId ?? "")|\(item.senderId ?? "")|\(item.body.prefix(60))"
        let now = Date()
        recentlyShown = recentlyShown.filter { $0.value.timeIntervalSince(now) > -5 }
        if recentlyShown[dedupeKey] != nil {
            #if DEBUG
            print("🍞🍞 [NotificationPipeline] 🔁 Duplicate suppressed: \(dedupeKey.prefix(50))")
            #endif
            return
        }
        recentlyShown[dedupeKey] = now

        // Check for merge with existing queue items
        if let lastIndex = queue.lastIndex(where: { shouldMerge($0, item) }) {
            queue[lastIndex] = merged(queue[lastIndex], item)
            #if DEBUG
            print("🍞🍞 [NotificationPipeline] Merged with queue item")
            #endif
            return
        }
        
        // Check for merge with current toast
        if let current = currentToast, shouldMerge(current, item) {
            currentToast = merged(current, item)
            // Reset timer for merged notification
            scheduleDismiss()
            #if DEBUG
            print("🍞🍞 [NotificationPipeline] Merged with current toast")
            #endif
            return
        }
        
        queue.append(item)
        unreadCount += 1
        #if DEBUG
        print("🍞🍞 [NotificationPipeline] Added to queue, calling showNextIfNeeded. Queue size: \(queue.count)")
        #endif
        showNextIfNeeded()
    }
    
    /// Show a toast immediately (skips queue)
    func showImmediate(_ item: ToastItem) {
        dismissTask?.cancel()
        currentToast = item
        unreadCount += 1
        scheduleDismiss()
    }
    
    /// Pause auto-dismiss (when user interacts)
    func pauseDismiss() {
        isPaused = true
        dismissTask?.cancel()
    }
    
    /// Resume auto-dismiss
    func resumeDismiss() {
        isPaused = false
        scheduleDismiss()
    }
    
    /// Dismiss current toast
    func dismissCurrent() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            currentToast = nil
        }
        
        // Delay to let the dismiss animation complete before showing next toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.showNextIfNeeded()
        }
    }
    
    /// Clear all notifications
    func clearAll() {
        dismissTask?.cancel()
        queue.removeAll()
        currentToast = nil
        unreadCount = 0
    }
    
    /// Mark all as read
    func markAllRead() {
        unreadCount = 0
    }
    
    // MARK: - Actions
    
    /// Handle tap on toast - navigates to appropriate screen
    func handleTap(_ item: ToastItem) {
        Haptics.light()
        pauseDismiss()
        
        // Mark as read on server
        Task {
            try? await NotificationsService.shared.markAsRead(id: item.id)
        }
        
        switch item.type {
        case .message, .voice:
            if let chatId = item.chatId {
                DeepLinkRouter.shared.navigate(to: .chat(roomId: chatId))
            }
            
        case .friendRequest:
            DeepLinkRouter.shared.navigate(to: .friendRequests)
            
        case .security:
            DeepLinkRouter.shared.navigate(to: .security)
            
        case .like, .comment:
            // FIX: Navigate to the post (postId stored in chatId)
            if let postId = item.chatId {
                DeepLinkRouter.shared.navigate(to: .post(postId: postId))
            }
            
        case .groupInvite:
            // Navigate to group chat when accepted
            if let groupId = item.chatId {
                DeepLinkRouter.shared.navigate(to: .chat(roomId: groupId))
            }
            
        case .appUpdate:
            // Could open app store or changelog
            break
        }
        
        // Resume dismiss timer so subsequent toasts auto-dismiss properly
        resumeDismiss()
        dismissCurrent()
    }
    
    /// Open quick reply sheet
    func openQuickReply(_ item: ToastItem) {
        Haptics.medium()
        pauseDismiss()
        
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            quickReplyState = QuickReplyState(toastItem: item)
        }
    }
    
    /// Send quick reply
    func sendQuickReply() async {
        guard var state = quickReplyState,
              let chatId = state.toastItem.chatId,
              let senderId = state.toastItem.senderId,
              !state.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        state.isSending = true
        quickReplyState = state
        
        do {
            // Use MessageService to send (respects server/mesh routing)
            // For groups, send to chatId (group ID); for 1:1, send to senderId
            let destinationId = state.toastItem.isGroup ? chatId : senderId
            try await MessageService.shared.sendText(
                to: destinationId,
                text: state.replyText.trimmingCharacters(in: .whitespacesAndNewlines),
                isGroup: state.toastItem.isGroup
            )
            
            Haptics.success()
            closeQuickReply()
            dismissCurrent()
            
        } catch {
            Haptics.error()
            state.isSending = false
            quickReplyState = state
        }
    }
    
    /// Close quick reply sheet
    func closeQuickReply() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            quickReplyState = nil
        }
        resumeDismiss()
    }
    
    /// Update reply text
    func updateReplyText(_ text: String) {
        quickReplyState?.replyText = text
    }
    
    // MARK: - Friend Request Actions
    
    /// Accept friend request from toast
    func acceptFriendRequest(_ toast: ToastItem) {
        Task {
            // chatId holds the request_id for friend requests
            guard let requestId = toast.chatId else {
                #if DEBUG
                print("❌ Friend request accept failed: no requestId")
                #endif
                return
            }
            
            do {
                // Call friend request accept API with request_id
                let _: Empty = try await NetworkService.shared.post(
                    path: "/api/users/friend-request/\(requestId)/accept",
                    body: EmptyBody()
                )
                
                Haptics.success()
                #if DEBUG
                print("✅ Friend request accepted from \(toast.senderName ?? "unknown")")
                #endif
                
                // Dismiss toast
                dismissCurrent()
                
            } catch {
                Haptics.error()
                #if DEBUG
                print("❌ Failed to accept friend request: \(error)")
                #endif
            }
        }
    }
    
    /// Decline friend request from toast
    func declineFriendRequest(_ toast: ToastItem) {
        Task {
            // chatId holds the request_id for friend requests
            guard let requestId = toast.chatId else {
                #if DEBUG
                print("❌ Friend request decline failed: no requestId")
                #endif
                return
            }
            
            do {
                // Call friend request decline API with request_id
                let _: Empty = try await NetworkService.shared.post(
                    path: "/api/users/friend-request/\(requestId)/decline",
                    body: EmptyBody()
                )
                
                Haptics.light()
                #if DEBUG
                print("🚫 Friend request declined from \(toast.senderName ?? "unknown")")
                #endif
                
                // Dismiss toast
                dismissCurrent()
                
            } catch {
                Haptics.error()
                #if DEBUG
                print("❌ Failed to decline friend request: \(error)")
                #endif
            }
        }
    }
    
    // MARK: - Inline Reply
    
    /// Send inline reply from toast (without opening sheet)
    func sendInlineReply(toast: ToastItem, text: String) async {
        guard let senderId = toast.senderId,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        do {
            // For groups, send to chatId (group ID); for 1:1, send to senderId
            let destinationId = toast.isGroup ? (toast.chatId ?? senderId) : senderId
            try await MessageService.shared.sendText(
                to: destinationId,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                isGroup: toast.isGroup
            )
            
            Haptics.success()
            #if DEBUG
            print("✅ Inline reply sent to \(toast.senderName ?? senderId)")
            #endif
            
        } catch {
            Haptics.error()
            #if DEBUG
            print("❌ Failed to send inline reply: \(error)")
            #endif
        }
    }
    
    // MARK: - Private Methods
    
    private func showNextIfNeeded() {
        guard currentToast == nil, !queue.isEmpty else {
            #if DEBUG
            print("🍞🍞 [NotificationPipeline] showNextIfNeeded: currentToast=\(currentToast != nil ? "exists" : "nil"), queue.isEmpty=\(queue.isEmpty)")
            #endif
            return
        }
        
        #if DEBUG
        print("🍞🍞 [NotificationPipeline] SHOWING TOAST! Next from queue...")
        #endif
        
        // Notify SwiftUI BEFORE changing the value
        objectWillChange.send()
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            currentToast = queue.isEmpty ? nil : queue.removeFirst()
        }
        #if DEBUG
        print("🍞🍞 [NotificationPipeline] currentToast is now: \(currentToast?.title ?? "nil")")
        #endif
        scheduleDismiss()
    }
    
    private func scheduleDismiss() {
        dismissTask?.cancel()
        
        guard !isPaused else { return }
        
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.displayDuration ?? 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissCurrent()
        }
    }
    
    // MARK: - Merge Logic
    
    /// Check if two notifications should be merged
    private func shouldMerge(_ a: ToastItem, _ b: ToastItem) -> Bool {
        // Must be same type
        guard a.type == b.type else { return false }
        
        // Must be from same chat (for messages/voice)
        if a.type == .message || a.type == .voice {
            guard a.chatId != nil, a.chatId == b.chatId else { return false }
        }
        
        // Must be within time window
        return abs(a.receivedAt.timeIntervalSince(b.receivedAt)) < mergeWindow
    }
    
    // MARK: - Empty toast fallbacks

    private func defaultTitle(for type: ToastType) -> String {
        switch type {
        case .message:        return "New message"
        case .voice:          return "Voice message"
        case .friendRequest:  return "Friend request"
        case .like:           return "New like"
        case .comment:        return "New comment"
        case .security:       return "Security alert"
        case .groupInvite:    return "Group invite"
        case .appUpdate:      return "Update"
        }
    }

    private func defaultBody(for type: ToastType) -> String {
        switch type {
        case .message, .voice: return "You have a new message"
        case .friendRequest:   return "Someone wants to connect"
        case .like:            return "Someone liked your post"
        case .comment:         return "Someone commented"
        case .security:        return "Account activity"
        case .groupInvite:     return "You were invited to a group"
        case .appUpdate:       return "RAVEN was updated"
        }
    }

    /// Merge two notifications
    private func merged(_ a: ToastItem, _ b: ToastItem) -> ToastItem {
        var merged = b
        merged.mergedCount = a.mergedCount + 1
        
        switch a.type {
        case .message:
            merged.body = "\(merged.mergedCount) new messages"
        case .voice:
            merged.body = "\(merged.mergedCount) voice messages"
        default:
            break
        }
        
        return merged
    }
}
