// ChatThreadView — full-feature thread render for an opened conversation.
//
// `conversationId` is the *peer user id* for DMs (the server's
// `/api/messages/conversation/{other_user_id}` key) or the *group id* for
// groups (`/api/groups/{group_id}/messages`).
//
// Owns a `ChatStore` for state — messages, drafts, pinned, search, typing,
// reactions. The store wires to `RealtimeEngine` events at init so this
// view doesn't have to manage its own subscriptions. Layout:
//
//   ┌──────────────────────────────────────────────────┐
//   │ Header (avatar, name, presence, search, info)    │
//   ├──────────────────────────────────────────────────┤
//   │ Pinned bar (collapsible)                         │
//   ├──────────────────────────────────────────────────┤
//   │ Search overlay (toggleable)                      │
//   ├──────────────────────────────────────────────────┤
//   │ Messages (date headers, block grouping, bubbles, │
//   │ reactions, replies, edited/seen marks)           │
//   ├──────────────────────────────────────────────────┤
//   │ Typing indicator                                 │
//   │ Reply / edit preview                             │
//   │ Composer (text + voice + image + send)           │
//   └──────────────────────────────────────────────────┘

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatThreadView: View {
    let conversationId: String
    let isGroup: Bool
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var router: ShellRouter

    @StateObject private var store: ChatStore
    @StateObject private var recorder = VoiceRecorder()

    @State private var input: String = ""
    @State private var sending = false
    @State private var showSearch = false
    @State private var showPinnedSheet = false
    @State private var showSavedSheet = false
    @State private var showSharedMedia = false
    @State private var showInfoSheet = false
    @State private var showExpiryPicker = false
    @State private var showSchedulePicker = false
    /// Per-thread disappearing-messages mode — restored from UserDefaults
    /// on appear and persisted whenever the picker writes a new value.
    @State private var expiryMode: String? = nil
    @State private var showForwardSheet: Message?
    @State private var showMessageInfo: Message?
    @State private var atBottom = true
    @State private var presence: PresenceInfo?
    /// First unread message id captured ONCE on chat entry. Drives the
    /// "X unread messages" divider line and the initial scroll target.
    /// nil when the user opened the chat with zero unread.
    @State private var entryUnreadAnchor: String? = nil
    /// Frozen unread count for the divider label, captured at entry.
    @State private var entryUnreadCount: Int = 0
    @State private var didInitialScroll: Bool = false
    /// True while the user is dragging a file over the chat — drives the
    /// dashed-border drop hint overlay.
    @State private var isDropTargeted: Bool = false

    init(conversationId: String, isGroup: Bool) {
        self.conversationId = conversationId
        self.isGroup = isGroup
        _store = StateObject(wrappedValue: ChatStore(
            conversationId: conversationId,
            isGroup: isGroup,
            myUserId: KeychainService.shared.read(.userId),
            peerName: nil
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeader(
                conversation: conversationId,
                presence: presence,
                showSearch: $showSearch,
                onInfo: { showInfoSheet = true },
                onPinnedList: { showPinnedSheet = true },
                onSavedList: { showSavedSheet = true },
                onSharedMedia: { showSharedMedia = true },
                onDisappearing: isGroup ? nil : { showExpiryPicker = true }
            )
            .environmentObject(router)

            if showSearch {
                SearchOverlay(store: store, onJump: { msgId in
                    store.jumpToMessage(msgId)
                    showSearch = false
                })
            }

            if !store.pinned.isEmpty {
                PinnedBar(pinned: store.pinned) { msgId in
                    store.jumpToMessage(msgId)
                }
            }

            // 🆕 Disappearing-messages active banner — DM only, hidden
            // when the user hasn't enabled a TTL for this thread.
            if !isGroup, let mode = expiryMode {
                MacDisappearingActiveBanner(modeRaw: mode) {
                    showExpiryPicker = true
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ZStack(alignment: .bottomTrailing) {
                messagesList

                if !atBottom {
                    ScrollToBottomButton(action: {
                        // The proxy isn't available here directly — tap the
                        // store's highlight rather than a scroll proxy.
                        if let last = store.messages.last {
                            store.highlightedMessageId = last.id
                        }
                    }, unreadCount: scrollUnreadCount)
                    .padding(.trailing, 18)
                    .padding(.bottom, 90)
                    .transition(.opacity)
                }
            }

            if !store.typingUserIds.isEmpty {
                TypingIndicatorRow(names: typingNames)
            }

            // Message-request flow: receiver sees Block/Decline/Accept,
            // declined/blocked conversations show a hint, sender sees a
            // "X/3 messages left" counter above the composer until the
            // receiver accepts or the budget runs out.
            if isPendingRequest && isReceiver {
                MessageRequestReceiverBar(
                    peerName: router.selectedPeer?.username ?? "",
                    onAccept: { Task { await respondToRequest("accept") } },
                    onDecline: { Task { await respondToRequest("decline") } },
                    onBlock:   { Task { await respondToRequest("block") } }
                )
            } else if router.selectedRequestStatus == "declined"
                   || router.selectedRequestStatus == "blocked" {
                Text("You cannot reply to this conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(16)
            } else if isPendingRequest && !isReceiver
                   && (router.selectedPendingSentCount ?? 0) >= 3 {
                Text("Message request limit reached. Wait for \(router.selectedPeer?.username ?? "them") to accept your request.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .padding(16)
            } else {
                if isPendingRequest && !isReceiver {
                    let left = max(0, 3 - (router.selectedPendingSentCount ?? 0))
                    HStack {
                        Spacer()
                        Text("\(left)/3 messages left")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.orange.opacity(0.85), in: Capsule())
                    }
                    .padding(.horizontal, 16)
                }
                ComposerBar(
                    store: store,
                    input: $input,
                    sending: $sending,
                    recorder: recorder,
                    onSend: { Task { await send() } },
                    onSchedule: isGroup ? nil : { showSchedulePicker = true },
                    onPickImage: { Task { await pickAndSendImage() } },
                    onStartRecording: startRecording,
                    onCancelRecording: cancelRecording,
                    onStopAndSend: { Task { await stopAndSendVoice() } }
                )
            }
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                DropImageOverlay()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { droppedURL, _ in
                guard let droppedURL = droppedURL else { return }
                Task { @MainActor in
                    await handleDroppedFile(url: droppedURL)
                }
            }
            return true
        }
        .toast(message: store.toast)
        .chatKeyboardShortcuts(
            store: store,
            showSearch: $showSearch,
            onScrollToBottom: {
                if let last = store.messages.last {
                    store.highlightedMessageId = last.id
                }
            }
        )
        .confirmationDialog(
            "Disappearing messages",
            isPresented: $showExpiryPicker,
            titleVisibility: .visible
        ) {
            Button("Off")             { setExpiry(nil) }
            Button("After 24 hours")  { setExpiry("deleteAfter24h") }
            Button("After 7 days")    { setExpiry("deleteAfter7d") }
            Button("After read")      { setExpiry("deleteAfterRead") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New messages you send in this chat will follow this rule. Existing messages aren't affected.")
        }
        .task(id: conversationId) {
            input = store.draftText
            // Reset the unread-anchor state so the next chat-open
            // captures a fresh divider position rather than reusing the
            // last conversation's.
            didInitialScroll = false
            entryUnreadAnchor = nil
            entryUnreadCount = 0
            // Restore the per-thread disappearing mode from UserDefaults
            // so the active banner + outgoing-send wiring matches what
            // the user picked previously.
            expiryMode = isGroup ? nil : MacChatExpirySettings.mode(forConversation: conversationId)

            // Cross-thread hand-off: if the user picked "Reply privately"
            // on a group message, MacPendingReplyStore stashed the
            // original. Consume it here and seed the composer's reply
            // target so the user lands ready to type.
            if !isGroup,
               let pending = MacPendingReplyStore.shared.consume(forPeerId: conversationId) {
                store.replyTarget = pending
            }

            await store.reload()
            await fetchPresence()
        }
        .onChange(of: input) { newValue in
            store.draftText = newValue
            if !newValue.isEmpty {
                store.handleComposerChange()
            }
        }
        .sheet(isPresented: $showInfoSheet) {
            ChatDetailsView(
                conversationId: conversationId,
                isGroup: isGroup,
                peerName: router.selectedPeer?.username ?? router.selectedGroupName ?? "",
                onDeleted: {
                    showInfoSheet = false
                    router.selectedConversationId = nil
                }
            )
            .environmentObject(auth)
        }
        .sheet(isPresented: $showPinnedSheet) {
            PinnedMessagesSheet(
                conversationId: conversationId,
                isGroup: isGroup,
                onJump: { msgId in
                    showPinnedSheet = false
                    store.jumpToMessage(msgId)
                }
            )
        }
        .sheet(isPresented: $showSchedulePicker) {
            MacSchedulePickerSheet { date in
                let captured = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !captured.isEmpty else { return }
                input = ""
                Task { await store.sendScheduledText(captured, scheduledAt: date) }
            }
        }
        .sheet(isPresented: $showSavedSheet) {
            SavedMessagesSheet()
                .environmentObject(auth)
                .environmentObject(router)
        }
        .sheet(isPresented: $showSharedMedia) {
            SharedMediaSheet(messages: store.messages)
        }
        .sheet(item: $showForwardSheet) { msg in
            ForwardSheet(source: msg)
                .environmentObject(auth)
        }
        .sheet(item: $showMessageInfo) { msg in
            MessageInfoSheet(message: msg)
        }
    }

    // MARK: - Subviews

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if store.loading {
                        ProgressView().padding(40).frame(maxWidth: .infinity)
                    } else if let error = store.loadError {
                        Text(error)
                            .foregroundStyle(.red)
                            .padding(40)
                            .frame(maxWidth: .infinity)
                    } else if store.messages.isEmpty {
                        Text("Send the first message.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(40)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(decoratedMessages, id: \.message.id) { row in
                            if let header = row.dateHeader {
                                DateHeaderChip(text: header)
                                    .padding(.top, 12)
                            }
                            // 🆕 "X unread messages" divider — pinned to
                            // the first unread message captured at chat
                            // entry, stays put while the user scrolls.
                            if row.message.id == entryUnreadAnchor {
                                MacUnreadMessagesDivider(count: entryUnreadCount)
                                    .padding(.vertical, 8)
                            }
                            MessageBubble(
                                message: row.message,
                                isMine: row.message.senderId == auth.currentUser?.id,
                                position: row.position,
                                isHighlighted: store.highlightedMessageId == row.message.id,
                                reactions: store.reactionsByMessage[row.message.id] ?? [],
                                replyContextResolver: { id in store.messages.first(where: { $0.id == id }) },
                                myUserId: auth.currentUser?.id ?? "",
                                onReply: { store.replyTarget = row.message },
                                onEdit: {
                                    store.editTarget = row.message
                                    input = row.message.content ?? ""
                                },
                                onDelete: { Task { await store.deleteMessage(row.message) } },
                                onCopy: { copyToClipboard(row.message.displayContent) },
                                onPin: { Task { await store.togglePin(row.message) } },
                                onSave: { Task { await store.toggleSaved(row.message, saved: true) } },
                                onUnsave: { Task { await store.toggleSaved(row.message, saved: false) } },
                                onForward: { showForwardSheet = row.message },
                                onReactPicker: { emoji in
                                    Task { await store.toggleReaction(row.message, emoji: emoji) }
                                },
                                onShowInfo: { showMessageInfo = row.message },
                                onHideForMe: { store.hideForMe(row.message) },
                                groupId: isGroup ? conversationId : nil,
                                onReplyPrivately: isGroup ? {
                                    let peerId = row.message.senderId
                                    MacPendingReplyStore.shared.setPending(
                                        forPeerId: peerId, message: row.message
                                    )
                                    // Switch the right-pane router to a 1:1
                                    // with the message's sender. The newly-
                                    // opened ChatThreadView consumes the
                                    // pending reply on `.task(id:)` below.
                                    router.selectedConversationId = peerId
                                    router.selectedIsGroup = false
                                    router.selectedGroupName = nil
                                    router.selectedGroupAvatar = nil
                                    router.selectedPeer = ConversationPeer(
                                        userId: peerId,
                                        username: row.message.senderName ?? "User",
                                        firstName: nil,
                                        lastName: nil,
                                        avatarPath: row.message.senderAvatar,
                                        isVerified: false,
                                        isPremium: false
                                    )
                                } : nil
                            )
                            .id(row.message.id)
                            .padding(.horizontal, 14)
                        }
                    }
                }
                .padding(.vertical, 14)
                .background(
                    GeometryReader { _ in Color.clear }
                )
            }
            .onChange(of: store.messages.count) { newCount in
                // First-paint: capture the unread anchor + scroll there
                // instead of the bottom. Once we've done the initial
                // scroll we revert to the regular "follow new messages"
                // behavior (atBottom-driven) for subsequent ticks.
                if !didInitialScroll, newCount > 0 {
                    didInitialScroll = true
                    let myId = auth.currentUser?.id ?? ""
                    if let anchorMsg = store.messages.first(where: {
                        $0.readAt == nil && $0.senderId != myId
                    }) {
                        entryUnreadAnchor = anchorMsg.id
                        entryUnreadCount = store.messages
                            .filter { $0.readAt == nil && $0.senderId != myId }
                            .count
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                proxy.scrollTo(anchorMsg.id, anchor: .top)
                            }
                        }
                        return
                    } else if let last = store.messages.last {
                        // Zero unread → standard bottom-on-open behavior.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                        return
                    }
                }

                if let last = store.messages.last, atBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: store.highlightedMessageId) { newValue in
                guard let id = newValue else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Decorate the messages array with date-headers and block-position
    /// metadata so the view layer renders cleanly.
    private var decoratedMessages: [DecoratedRow] {
        var out: [DecoratedRow] = []
        let cal = Calendar.current
        var lastDay: DateComponents?
        for (idx, m) in store.messages.enumerated() {
            // Date header when day boundary changes.
            let day = cal.dateComponents([.year, .month, .day], from: m.timestamp)
            var header: String? = nil
            if day != lastDay {
                header = formattedDateHeader(m.timestamp)
                lastDay = day
            }
            // Block position: same sender within 2 minutes of previous?
            let prev = idx > 0 ? store.messages[idx - 1] : nil
            let next = idx + 1 < store.messages.count ? store.messages[idx + 1] : nil
            let position = blockPosition(prev: prev, msg: m, next: next, sameDay: day == lastDay)
            out.append(DecoratedRow(message: m, dateHeader: header, position: position))
        }
        return out
    }

    private func blockPosition(prev: Message?, msg: Message, next: Message?, sameDay: Bool) -> BlockPosition {
        let prevSame = prev?.senderId == msg.senderId
            && prev.map { msg.timestamp.timeIntervalSince($0.timestamp) < 120 } ?? false
        let nextSame = next?.senderId == msg.senderId
            && next.map { $0.timestamp.timeIntervalSince(msg.timestamp) < 120 } ?? false
        switch (prevSame, nextSame) {
        case (false, false): return .single
        case (false, true):  return .top
        case (true, true):   return .middle
        case (true, false):  return .bottom
        }
    }

    private func formattedDateHeader(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: d)
    }

    // MARK: - Message request helpers

    private var isPendingRequest: Bool {
        !isGroup && router.selectedRequestStatus == "pending"
    }

    private var isReceiver: Bool {
        router.selectedIsRequestSender == false
    }

    private func respondToRequest(_ action: String) async {
        guard let id = router.selectedRequestId ?? router.selectedConversationId else { return }
        do {
            switch action {
            case "accept":  try await NetworkService.shared.acceptMessageRequest(requestId: id)
            case "decline": try await NetworkService.shared.declineMessageRequest(requestId: id)
            case "block":   try await NetworkService.shared.blockMessageRequest(requestId: id)
            default: return
            }
            // Locally reflect the new status so the UI updates without a
            // round-trip to refetch conversations.
            await MainActor.run {
                if action == "accept" {
                    router.selectedRequestStatus = "accepted"
                } else if action == "decline" {
                    router.selectedRequestStatus = "declined"
                } else if action == "block" {
                    router.selectedRequestStatus = "blocked"
                }
            }
        } catch {
            #if DEBUG
            print("⚠️ [MessageRequest] \(action) failed: \(error)")
            #endif
        }
    }

    private var typingNames: [String] {
        // For DMs we know it's the peer; for groups we don't have names
        // here, so use "Someone".
        if !router.selectedIsGroup {
            return [router.selectedPeer?.username ?? "Someone"]
        }
        return Array(repeating: "Someone", count: store.typingUserIds.count)
    }

    @MainActor
    /// Live unread count for the floating scroll-to-bottom badge.
    /// Counts messages whose recipient is the current user and haven't
    /// been read yet — the count ticks down as the user catches up
    /// because `markRead` updates `readAt` on each visible message.
    private var scrollUnreadCount: Int {
        let myId = auth.currentUser?.id ?? ""
        return store.messages.filter {
            $0.readAt == nil && $0.senderId != myId
        }.count
    }

    /// Persist + reflect a new disappearing-messages mode for this thread.
    /// Passing nil clears it (back to "Off").
    private func setExpiry(_ raw: String?) {
        MacChatExpirySettings.setMode(raw, forConversation: conversationId)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            expiryMode = raw
        }
    }

    private func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        await store.sendText(trimmed)
        input = ""
        store.draftText = ""
    }

    /// Handle a file dropped onto the chat. Currently only image types
    /// are uploadable (the macOS app's chat doesn't yet support generic
    /// file messages); other drops surface a friendly toast.
    @MainActor
    private func handleDroppedFile(url: URL) async {
        let ext = url.pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"].contains(ext)
        guard isImage else {
            store.toast = "Drop an image to share. File messages aren't supported yet."
            return
        }
        sending = true
        defer { sending = false }
        do {
            let data = try Data(contentsOf: url)
            let mime = mimeType(for: url.lastPathComponent)
            let remoteUrl = try await NetworkService.shared.uploadImage(
                data: data,
                filename: url.lastPathComponent,
                mimeType: mime
            )
            await store.sendImage(url: remoteUrl)
        } catch {
            store.toast = "Couldn't send image."
        }
    }

    @MainActor
    private func pickAndSendImage() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png, .image, .heic]
        panel.message = "Send an image"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        sending = true
        defer { sending = false }
        do {
            let data = try Data(contentsOf: url)
            let mime = mimeType(for: url.lastPathComponent)
            let remoteUrl = try await NetworkService.shared.uploadImage(
                data: data,
                filename: url.lastPathComponent,
                mimeType: mime
            )
            await store.sendImage(url: remoteUrl)
        } catch {
            store.toast = "Couldn't send image."
        }
    }

    private func mimeType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".heic") || lower.hasSuffix(".heif") { return "image/heic" }
        return "image/jpeg"
    }

    private func startRecording() {
        do { try recorder.start() }
        catch { store.toast = "Couldn't start recording." }
    }

    private func cancelRecording() { recorder.cancel() }

    @MainActor
    private func stopAndSendVoice() async {
        let duration = Int(recorder.elapsed)
        guard let fileURL = recorder.stop() else { return }
        sending = true
        defer {
            sending = false
            try? FileManager.default.removeItem(at: fileURL)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let audioUrl = try await NetworkService.shared.uploadVoice(
                data: data, filename: fileURL.lastPathComponent, mimeType: "audio/m4a")
            await store.sendVoice(audioUrl: audioUrl, duration: duration)
        } catch {
            store.toast = "Couldn't send voice."
        }
    }

    @MainActor
    private func fetchPresence() async {
        guard !isGroup else { presence = nil; return }
        presence = try? await NetworkService.shared.presence(userId: conversationId)
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - Decoration types

private struct DecoratedRow {
    let message: Message
    let dateHeader: String?
    let position: BlockPosition
}

enum BlockPosition {
    case single, top, middle, bottom
}

// MARK: - Header

struct ChatHeader: View {
    let conversation: String
    let presence: PresenceInfo?
    @Binding var showSearch: Bool
    let onInfo: () -> Void
    let onPinnedList: () -> Void
    let onSavedList: () -> Void
    let onSharedMedia: () -> Void
    /// DM-only: opens the disappearing-messages picker. Hidden in groups.
    var onDisappearing: (() -> Void)? = nil
    @EnvironmentObject var router: ShellRouter

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                letter: String((titleRaw).prefix(1)).uppercased(),
                size: 36,
                urlString: avatarURL,
                showOnlineIndicator: !router.selectedIsGroup && (presence?.online == true)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 15, weight: .bold))
                HStack(spacing: 4) {
                    if !router.selectedIsGroup {
                        Circle()
                            .fill(presence?.online == true ? Color.green : Color.gray.opacity(0.5))
                            .frame(width: 6, height: 6)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(presence?.online == true ? .green : .secondary)
                }
            }
            Spacer()

            Button(action: { showSearch.toggle() }) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Search this conversation")

            Menu {
                Button("Pinned messages…", action: onPinnedList)
                Button("Saved messages…", action: onSavedList)
                Button("Shared media…", action: onSharedMedia)
                if let onDisappearing {
                    Divider()
                    Button("Disappearing messages…", action: onDisappearing)
                }
                Divider()
                Button(router.selectedIsGroup ? "Group info…" : "Conversation info…", action: onInfo)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        Divider().background(Color.white.opacity(0.05))
    }

    private var titleRaw: String {
        if router.selectedIsGroup { return router.selectedGroupName ?? "Group" }
        return router.selectedPeer?.username ?? "?"
    }

    private var displayTitle: String {
        if router.selectedIsGroup, let n = router.selectedGroupName, !n.isEmpty {
            return n
        }
        if let peer = router.selectedPeer {
            let composed = [peer.firstName ?? "", peer.lastName ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
            return composed.isEmpty ? peer.username : composed
        }
        return "Conversation"
    }

    private var avatarURL: String? {
        if router.selectedIsGroup { return router.selectedGroupAvatar }
        return router.selectedPeer?.avatarPath
    }

    private var subtitle: String {
        if router.selectedIsGroup { return "Group · End-to-end encrypted" }
        if let presence, presence.online { return "Online · End-to-end encrypted" }
        if let last = presence?.lastSeenAt {
            return "Last seen \(timeAgo(last)) · End-to-end encrypted"
        }
        return "End-to-end encrypted"
    }

    private func timeAgo(_ d: Date) -> String {
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins) min ago" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h ago" }
        let days = hrs / 24
        return "\(days)d ago"
    }
}

// MARK: - Pinned bar

struct PinnedBar: View {
    let pinned: [PinnedMessage]
    let onTap: (String) -> Void
    @State private var idx: Int = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(RavenColors.logoStart)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pinned message")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(currentPreview)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            Spacer()
            if pinned.count > 1 {
                Text("\(idx + 1)/\(pinned.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !pinned.isEmpty else { return }
            onTap(pinned[idx].id)
            idx = (idx + 1) % pinned.count
        }
    }

    private var currentPreview: String {
        guard !pinned.isEmpty else { return "" }
        let p = pinned[min(idx, pinned.count - 1)]
        if let c = p.content, !c.isEmpty {
            // Same encrypted-leak guard as the message bubble: if the
            // server failed to decrypt this row, surface a placeholder
            // instead of leaking ciphertext into the pinned banner.
            if Message.looksEncrypted(c) { return "🔒 Encrypted message" }
            if Message.looksLikeContactCardJSON(c) { return "👤 Shared contact" }
            return c
        }
        switch p.messageType {
        case "voice": return "🎤 Voice message"
        case "image": return "🖼️ Image"
        case "contact_card": return "👤 Shared contact"
        default: return p.messageType.capitalized
        }
    }
}

// MARK: - Search overlay

struct SearchOverlay: View {
    @ObservedObject var store: ChatStore
    let onJump: (String) -> Void
    @State private var query: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this conversation", text: $query)
                    .textFieldStyle(.plain)
                if store.searchInFlight { ProgressView().scaleEffect(0.6) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05))
            .clipShape(Capsule())
            .padding(10)

            if !store.searchResults.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.searchResults) { hit in
                            Button(action: { onJump(hit.id) }) {
                                HStack {
                                    Text(hit.content)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(timeFormatted(hit.timestamp))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.02))
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .background(Color.black.opacity(0.3))
        .onChange(of: query) { newValue in
            store.runSearch(newValue)
        }
    }

    private func timeFormatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Date header chip

struct DateHeaderChip: View {
    let text: String
    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.05))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Typing indicator

struct TypingIndicatorRow: View {
    let names: [String]
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(phase == i ? 0.9 : 0.3))
                        .frame(width: 5, height: 5)
                }
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }

    private var label: String {
        if names.count == 1 { return "\(names[0]) is typing…" }
        return "Several people are typing…"
    }
}

// MARK: - Composer

struct ComposerBar: View {
    @ObservedObject var store: ChatStore
    @Binding var input: String
    @Binding var sending: Bool
    @ObservedObject var recorder: VoiceRecorder
    let onSend: () -> Void
    /// DM-only: right-click / long-press the send button to open the
    /// schedule picker. Hidden in groups (server scheduling is DM-only).
    var onSchedule: (() -> Void)? = nil
    let onPickImage: () -> Void
    let onStartRecording: () -> Void
    let onCancelRecording: () -> Void
    let onStopAndSend: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Reply / edit preview pill above the composer.
            if let target = store.replyTarget {
                ComposerPreviewPill(
                    icon: "arrowshape.turn.up.left.fill",
                    title: "Replying to \(target.senderName ?? "message")",
                    subtitle: target.displayContent,
                    onClear: { store.replyTarget = nil }
                )
            } else if let target = store.editTarget {
                ComposerPreviewPill(
                    icon: "pencil",
                    title: "Editing message",
                    subtitle: target.displayContent,
                    onClear: {
                        store.editTarget = nil
                        input = ""
                    }
                )
            }

            HStack(spacing: 12) {
                Button(action: onPickImage) {
                    Image(systemName: sending ? "photo.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(RavenColors.logoStart)
                }
                .buttonStyle(.plain)
                .disabled(sending || recorder.isRecording)

                if recorder.isRecording {
                    HStack(spacing: 10) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(formatDuration(recorder.elapsed))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Spacer()
                        Button(action: onCancelRecording) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    TextField(placeholder, text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .lineLimit(1...4)
                        .disabled(sending)
                        .onSubmit(onSend)
                }

                if recorder.isRecording {
                    sendButton(action: onStopAndSend)
                } else if input.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: onStartRecording) {
                        Image(systemName: "mic.fill")
                            .padding(10)
                            .background(Circle().fill(LinearGradient.ravenBrand))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(sending)
                } else {
                    sendButton(action: onSend)
                        .contextMenu {
                            if let onSchedule {
                                Button {
                                    onSchedule()
                                } label: {
                                    Label("Schedule…", systemImage: "clock")
                                }
                            }
                        }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
    }

    private var placeholder: String {
        if store.editTarget != nil { return "Edit message…" }
        if store.replyTarget != nil { return "Reply…" }
        return "Message…"
    }

    private func sendButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sending ? "ellipsis" : (store.editTarget != nil ? "checkmark" : "paperplane.fill"))
                .padding(10)
                .background(Circle().fill(LinearGradient.ravenBrand))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(sending)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ComposerPreviewPill: View {
    let icon: String
    let title: String
    let subtitle: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(RavenColors.logoStart)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }
}

// MARK: - Scroll-to-bottom

struct ScrollToBottomButton: View {
    let action: () -> Void
    /// Number of unread messages not yet read by the local user. Drives
    /// the floating badge — count of 0 hides it. Mirrors the iOS variant.
    var unreadCount: Int = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) {
                Image(systemName: "chevron.down")
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.18)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if unreadCount > 0 {
                Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                    .font(.system(size: 11, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, unreadCount > 9 ? 5 : 0)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(RavenColors.logoStart))
                    .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                    .offset(x: 4, y: -2)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: unreadCount)
    }
}

// MARK: - Bubble

struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    let position: BlockPosition
    let isHighlighted: Bool
    let reactions: [MessageReactionRow]
    let replyContextResolver: (String) -> Message?
    let myUserId: String
    let onReply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onSave: () -> Void
    let onUnsave: () -> Void
    let onForward: () -> Void
    let onReactPicker: (String) -> Void
    let onShowInfo: () -> Void
    /// "Hide for me" — drop the row from this device's view without
    /// touching the server. Use `onDelete` for delete-for-everyone.
    let onHideForMe: () -> Void
    /// Group id when this bubble belongs to a group thread; nil for DMs.
    /// Required by the poll bubble path so it can call the group-scoped
    /// /api/groups/{group_id}/polls/{poll_id} endpoint.
    var groupId: String? = nil
    /// Group only: opens a 1:1 with this message's sender and pre-fills
    /// the composer with the original quote. Wired only for incoming
    /// (non-self) group messages — the bubble hides the entry otherwise.
    var onReplyPrivately: (() -> Void)? = nil

    @State private var hover = false
    @State private var showReactionPicker = false

    private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine { Spacer(minLength: 60) }

            // Group sender avatar — only renders for incoming bubbles in
            // group threads, and only at the top of each sender's block.
            // For middle/last bubbles in a block we leave a 28-wide
            // spacer so all bubbles in the block stay vertically aligned.
            if !isMine, groupId != nil {
                senderAvatarView
                    .frame(width: 28, height: 28)
                    .padding(.top, 2)
            }

            ZStack(alignment: isMine ? .topTrailing : .topLeading) {
                bubbleBody
                if hover {
                    actionRow
                        .offset(x: isMine ? -12 : 12, y: -22)
                        .transition(.opacity)
                }
            }
            .background(
                isHighlighted
                    ? RoundedRectangle(cornerRadius: 18).fill(RavenColors.logoStart.opacity(0.2))
                    : nil
            )

            if !isMine { Spacer(minLength: 60) }
        }
        .padding(.vertical, paddingForPosition)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.15)) { hover = h }
        }
        .contextMenu { contextMenu }
        .popover(isPresented: $showReactionPicker, arrowEdge: .top) {
            ReactionPickerPopover { emoji in
                onReactPicker(emoji)
                showReactionPicker = false
            }
        }
    }

    /// Avatar circle for the incoming-group sender. Only the first bubble
    /// in a sender's block (`.top` or `.single`) renders the actual image —
    /// continuation bubbles render an empty placeholder so the chat keeps
    /// the avatar column aligned without repeating the face.
    @ViewBuilder
    private var senderAvatarView: some View {
        if position == .top || position == .single {
            ZStack {
                if let path = message.senderAvatar,
                   let url = URL(string: path) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            avatarFallback
                        }
                    }
                } else {
                    avatarFallback
                }
            }
            .clipShape(Circle())
            .overlay(
                Circle().stroke(RavenColors.logoStart.opacity(0.30), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        } else {
            Color.clear
        }
    }

    private var avatarFallback: some View {
        ZStack {
            LinearGradient.ravenLogo
            Text(senderInitial)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.white)
        }
    }

    private var senderInitial: String {
        let raw = message.senderName ?? "?"
        return String(raw.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var bubbleBody: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            // Sender name for incoming group messages (only on first
            // bubble in a block).
            if !isMine, position == .top || position == .single,
               let name = message.senderName, !name.isEmpty {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RavenColors.logoStart)
                    .padding(.horizontal, 14)
            }

            // Reply quote, if any.
            if let replyId = message.replyToMessageId {
                ReplyQuoteView(
                    senderName: message.replyToSenderName,
                    preview: message.replyToTextPreview,
                    type: message.replyToType,
                    onTap: { _ = replyContextResolver(replyId) }
                )
                .padding(.horizontal, 14)
            }

            messageContent

            // Footer: time, edited mark, read receipt for own, and a
            // live disappearing-message countdown when expires_at is set.
            HStack(spacing: 4) {
                if message.isEdited {
                    Text("edited")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let expires = message.expiresAt {
                    MacExpiryCountdownBadge(expiresAt: expires)
                }
                Text(timeFormatted(message.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if isMine {
                    Image(systemName: message.readAt != nil ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(message.readAt != nil ? .blue : .secondary)
                }
            }
            .padding(.horizontal, 14)

            if !reactions.isEmpty {
                ReactionChipsRow(reactions: reactions, myUserId: myUserId, onTap: onReactPicker)
                    .padding(.horizontal, 14)
            }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.messageType == "contact_card",
           let payload = MacContactCardPayload.decode(from: message.content) {
            MacContactCardBubble(payload: payload)
                .padding(.horizontal, 14)
        } else if message.messageType == nil || message.messageType == "text",
                  let raw = message.content,
                  let payload = MacContactCardPayload.decode(from: raw) {
            // Defensive: if the type column wasn't set (older Mac client
            // didn't know about contact_card and stored it as `text`),
            // recognise the JSON shape and render the bubble anyway —
            // same trick the iOS effectiveType check uses.
            MacContactCardBubble(payload: payload)
                .padding(.horizontal, 14)
        } else if message.messageType == "poll", let groupId, let pollId = message.pollId {
            MacPollBubble(groupId: groupId, pollId: pollId)
                .padding(.horizontal, 14)
        } else if message.isImage, let url = message.audioUrl, let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty:
                    ZStack { Color.white.opacity(0.06); ProgressView().tint(.white) }
                case .failure:
                    ZStack {
                        Color.white.opacity(0.06)
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                @unknown default:
                    Color.white.opacity(0.06)
                }
            }
            .frame(maxWidth: 240, maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius))
        } else if message.isVoice, let url = message.audioUrl, !url.isEmpty {
            VoicePlayerRow(url: url)
                .frame(width: 220)
                .padding(.horizontal, 14)
        } else if message.isSystem {
            Text(message.displayContent)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        } else {
            Text(message.displayContent)
                .font(.system(size: 14))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: bubbleCornerRadius))
        }
    }

    /// Floating quick-reaction + reply row that appears above the bubble
    /// on hover. Matches the iOS reaction-picker capsule: ultraThin
    /// material, capsule shape, soft shadow, scale + bounce on emoji
    /// press so the reaction feels responsive.
    private var actionRow: some View {
        HStack(spacing: 6) {
            ForEach(quickEmojis, id: \.self) { emoji in
                EmojiReactButton(emoji: emoji) { onReactPicker(emoji) }
            }
            Button(action: { showReactionPicker = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            Divider().frame(height: 16)
            Button(action: onReply) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Reply", action: onReply)
        if !isMine, groupId != nil, let onReplyPrivately {
            Button("Reply privately", action: onReplyPrivately)
        }
        if isMine, message.isText {
            Button("Edit", action: onEdit)
        }
        Button("Forward", action: onForward)
        Divider()
        Button("Copy", action: onCopy)
        Button(message.isPinned ? "Unpin" : "Pin", action: onPin)
        Menu("React") {
            ForEach(quickEmojis, id: \.self) { emoji in
                Button(emoji) { onReactPicker(emoji) }
            }
        }
        Button("Save for later", action: onSave)
        Divider()
        Button("Message info", action: onShowInfo)
        Button("Hide for me", action: onHideForMe)
        if isMine {
            Button(role: .destructive, action: onDelete) {
                Text("Delete for everyone")
            }
        }
    }

    private var bubbleBackground: some View {
        Group {
            if isMine {
                LinearGradient.ravenBrand
            } else {
                Color.white.opacity(0.08)
            }
        }
    }

    /// Slightly different corner radius depending on block position so a
    /// stack of bubbles from the same sender flows together.
    private var bubbleCornerRadius: CGFloat {
        switch position {
        case .single, .top, .bottom: return 14
        case .middle: return 8
        }
    }

    private var paddingForPosition: CGFloat {
        switch position {
        case .top, .middle: return 1
        case .bottom, .single: return 4
        }
    }

    private func timeFormatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Reply quote

struct ReplyQuoteView: View {
    let senderName: String?
    let preview: String?
    let type: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(RavenColors.logoStart)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(senderName ?? "Reply")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(RavenColors.logoStart)
                    Text(typeIcon + " " + (preview ?? ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var typeIcon: String {
        switch type {
        case "voice": return "🎤"
        case "image": return "🖼️"
        case "video": return "🎬"
        case "file": return "📎"
        case "location": return "📍"
        default: return ""
        }
    }
}

// MARK: - Reactions chips

struct ReactionChipsRow: View {
    let reactions: [MessageReactionRow]
    let myUserId: String
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(grouped, id: \.emoji) { group in
                Button(action: { onTap(group.emoji) }) {
                    HStack(spacing: 3) {
                        Text(group.emoji)
                            .font(.system(size: 12))
                        Text("\(group.count)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(group.byMe ? RavenColors.logoStart.opacity(0.2) : Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private struct Group {
        let emoji: String
        let count: Int
        let byMe: Bool
    }

    private var grouped: [Group] {
        var counts: [String: Int] = [:]
        var byMeSet: Set<String> = []
        for r in reactions {
            counts[r.emoji, default: 0] += 1
            if r.userId == myUserId { byMeSet.insert(r.emoji) }
        }
        return counts.map { Group(emoji: $0.key, count: $0.value, byMe: byMeSet.contains($0.key)) }
            .sorted { $0.count > $1.count }
    }
}

// MARK: - Reaction picker popover

struct ReactionPickerPopover: View {
    let onPick: (String) -> Void
    private let emojis: [String] = [
        "😀","😂","😍","🥰","😎","🤔","😢","😭","😡","🤯",
        "👍","👎","👏","🙏","🙌","💪","🔥","✨","🎉","💯",
        "❤️","💔","🧡","💛","💚","💙","💜","🖤","🤍","🤎",
        "🐶","🐱","🦊","🐻","🐼","🐯","🦁","🐸","🐵","🙈",
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8), spacing: 4) {
                ForEach(emojis, id: \.self) { e in
                    Button(action: { onPick(e) }) {
                        Text(e).font(.system(size: 22))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 320, height: 220)
    }
}

// MARK: - Toast modifier

extension View {
    /// Lightweight transient banner — draws the toast in an overlay so it
    /// doesn't shift layout. Displays for 2.4 s then auto-clears via the
    /// caller's @Published binding.
    func toast(message: String?) -> some View {
        overlay(alignment: .top) {
            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: message)
    }
}


// MARK: - Unread Messages Divider (macOS)
//
// Liquid Glass capsule pinned just above the first unread message at
// chat entry. Mirrors the iOS UnreadMessagesDivider so cross-platform
// chats look like the same product.

struct MacUnreadMessagesDivider: View {
    let count: Int

    private var label: String {
        count == 1 ? "1 unread message" : "\(count) unread messages"
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(RavenColors.logoStart.opacity(0.30))
                .frame(height: 0.5)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RavenColors.logoStart)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(RavenColors.logoStart.opacity(0.35), lineWidth: 0.6)
                        )
                )
            Rectangle()
                .fill(RavenColors.logoStart.opacity(0.30))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .accessibilityLabel(label)
    }
}


// MARK: - Drop Image Overlay
//
// Liquid Glass full-thread overlay that appears while a file is being
// dragged over the chat. Visual cue only — the actual drop handler is
// attached to the parent ChatThreadView.

struct DropImageOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.ravenLogo.opacity(0.25))
                        .frame(width: 96, height: 96)
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 38))
                        .foregroundStyle(LinearGradient.ravenLogo)
                }
                Text("Drop to send")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                Text("Image will be uploaded and sent to this chat.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(
                                LinearGradient.ravenLogo,
                                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                            )
                    )
            )
        }
    }
}


// MARK: - Schedule Picker Sheet (macOS)
//
// Liquid Glass sheet for picking a future delivery time for the
// currently-composed message. Mirrors the iOS `SchedulePickerSheet`
// API: caller supplies `onPick`; the sheet hands the chosen Date back
// and dismisses. Default lands +5 minutes so the picker shows a valid
// future timestamp on first paint.

struct MacSchedulePickerSheet: View {
    var onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date().addingTimeInterval(5 * 60)

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Schedule message").font(.system(size: 18, weight: .heavy))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Send at", systemImage: "clock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RavenColors.logoStart)
                DatePicker(
                    "",
                    selection: $date,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.graphical)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("The recipient won't see this message until \(date.formatted(date: .abbreviated, time: .shortened)).")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("Schedule") {
                    onPick(date)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(date <= Date())
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(width: 460, height: 540)
        .background(.ultraThinMaterial)
    }
}


// MARK: - Pending Reply Store (cross-thread reply hand-off)
//
// When the user picks "Reply privately" on a group message, we stash the
// message keyed by the destination peer's userId. The destination DM
// ChatThreadView consumes it on appear and seeds `store.replyTarget`.
// Cleared after consume so it never bleeds across navigations.

@MainActor
final class MacPendingReplyStore {
    static let shared = MacPendingReplyStore()
    private var pending: [String: Message] = [:]
    private init() {}

    func setPending(forPeerId peerId: String, message: Message) {
        pending[peerId] = message
    }

    func consume(forPeerId peerId: String) -> Message? {
        pending.removeValue(forKey: peerId)
    }
}


// MARK: - Chat keyboard shortcuts (macOS)
//
// Mac-only productivity layer. Wraps the chat view in an invisible stack
// of zero-size buttons whose `.keyboardShortcut` modifiers route the
// usual desktop keys (⌘F, ⌘R, ⌘E, ⌘↓, Esc) to chat actions. Buttons
// stay focusable but render at 0×0 so they don't take any layout space.

struct ChatKeyboardShortcutsModifier: ViewModifier {
    @ObservedObject var store: ChatStore
    @Binding var showSearch: Bool
    var onScrollToBottom: () -> Void

    func body(content: Content) -> some View {
        content.background(
            VStack(spacing: 0) {
                // ⌘F — toggle in-thread search.
                Button("Find in chat") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSearch.toggle()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)

                // ⌘R — reply to the most recent message from someone else.
                Button("Reply to last message") {
                    let myId = store.myUserId
                    if let target = store.messages.reversed().first(where: { $0.senderId != myId }) {
                        store.replyTarget = target
                        store.editTarget = nil
                    }
                }
                .keyboardShortcut("r", modifiers: .command)

                // ⌘E — edit the most recent text message I sent.
                Button("Edit last message") {
                    let myId = store.myUserId
                    if let target = store.messages.reversed().first(where: {
                        $0.senderId == myId && ($0.messageType ?? "text") == "text"
                    }) {
                        store.editTarget = target
                        store.replyTarget = nil
                    }
                }
                .keyboardShortcut("e", modifiers: .command)

                // ⌘↓ — scroll to the latest message.
                Button("Scroll to latest") {
                    onScrollToBottom()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                // Esc — back out of any composer mode (search → reply → edit).
                Button("Cancel") {
                    if showSearch {
                        showSearch = false
                    } else if store.replyTarget != nil {
                        store.replyTarget = nil
                    } else if store.editTarget != nil {
                        store.editTarget = nil
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
    }
}

extension View {
    /// Apply the macOS chat keyboard shortcuts. The `onScrollToBottom`
    /// closure is called by ⌘↓ — the caller wires it up to whatever
    /// scroll-proxy mechanism the surrounding view uses.
    func chatKeyboardShortcuts(
        store: ChatStore,
        showSearch: Binding<Bool>,
        onScrollToBottom: @escaping () -> Void
    ) -> some View {
        modifier(ChatKeyboardShortcutsModifier(
            store: store,
            showSearch: showSearch,
            onScrollToBottom: onScrollToBottom
        ))
    }
}


// MARK: - Disappearing-messages active banner + countdown badge
//
// Active banner — sits above the composer when the user has set a TTL on
// this DM. Tap re-opens the picker. Hidden when expiryMode is nil.

struct MacDisappearingActiveBanner: View {
    /// Server raw expiry-mode string (`deleteAfter24h`, `deleteAfter7d`, …)
    let modeRaw: String
    var onTap: () -> Void

    private var label: String {
        switch modeRaw {
        case "deleteAfterRead":   return "Disappearing · After read"
        case "deleteAfter24h":    return "Disappearing · After 24h"
        case "deleteAfter7d":     return "Disappearing · After 7 days"
        default:                  return "Disappearing on"
        }
    }

    private var glyph: String {
        switch modeRaw {
        case "deleteAfterRead": return "eye.slash"
        default:                return "timer"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.indigo)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.indigo.opacity(0.40), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityLabel("Disappearing messages: \(label). Tap to change.")
    }
}

// Live countdown chip rendered in the bubble metadata row when the
// server-side expires_at is in the future. Uses TimelineView so the
// remaining-time string updates without a per-second timer thrash.

struct MacExpiryCountdownBadge: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            if remaining <= 0 {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.7))
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 8, weight: .semibold))
                    Text(format(remaining))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.indigo.opacity(0.85))
            }
        }
    }

    private func format(_ secs: TimeInterval) -> String {
        if secs < 60      { return "\(Int(secs))s" }
        if secs < 3600    { return "\(Int(secs / 60))m" }
        if secs < 86_400  { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86_400))d"
    }
}


// MARK: - Mac Poll Bubble
//
// Renders a live group poll inside a chat bubble. Loads once on appear,
// refreshes after each vote so the tally + my-votes stays canonical.
// Mirrors the iOS PollBubbleView's progress-fill aesthetic so the two
// platforms look like the same product.

struct MacPollBubble: View {
    let groupId: String
    let pollId: String

    @EnvironmentObject var auth: AuthService
    @State private var poll: PollDTO? = nil
    @State private var loading: Bool = true
    @State private var voting: String? = nil

    private var isCreator: Bool {
        guard let poll, let me = auth.currentUser?.id else { return false }
        return poll.creatorId == me
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RavenColors.logoStart)
                Text(headerText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                if let poll, poll.isClosed {
                    Text("Closed")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundStyle(.secondary)
                }
            }

            if let poll {
                Text(poll.question)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 6) {
                    ForEach(poll.options) { opt in
                        MacPollOptionRow(
                            option: opt,
                            isMyChoice: poll.myVotes.contains(opt.id),
                            totalVotes: poll.totalVotes,
                            isClosed: poll.isClosed,
                            voting: voting == opt.id,
                            onTap: { Task { await vote(optionId: opt.id) } }
                        )
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: poll.isAnonymous ? "person.fill.questionmark" : "person.2.fill")
                    Text("\(poll.totalVotes) vote\(poll.totalVotes == 1 ? "" : "s")")
                    if poll.allowMultiple {
                        Text("· Multi-select").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isCreator && !poll.isClosed {
                        Button("Close poll") {
                            Task { await close() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } else if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading poll…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Text("Couldn't load poll")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(RavenColors.logoStart.opacity(0.18), lineWidth: 0.6)
                )
        )
        .task { await load() }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: poll)
    }

    private var headerText: String {
        if poll?.isClosed == true { return "Final Results" }
        return "Poll"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            poll = try await NetworkService.shared.getPoll(groupId: groupId, pollId: pollId)
        } catch {
            poll = nil
        }
    }

    private func vote(optionId: String) async {
        guard let poll, !poll.isClosed else { return }
        voting = optionId
        defer { voting = nil }
        do {
            self.poll = try await NetworkService.shared.votePoll(
                groupId: groupId, pollId: pollId, optionId: optionId
            )
        } catch {
            // Best-effort: keep the previous tally; failures are
            // surfaced via the inline `Couldn't load poll` state on
            // a full reload, not on a transient vote retry.
        }
    }

    private func close() async {
        do {
            self.poll = try await NetworkService.shared.closePoll(groupId: groupId, pollId: pollId)
        } catch {
            // Same best-effort policy as `vote(_:)`.
        }
    }
}

struct MacPollOptionRow: View {
    let option: PollOptionDTO
    let isMyChoice: Bool
    let totalVotes: Int
    let isClosed: Bool
    let voting: Bool
    var onTap: () -> Void

    private var pct: Double {
        guard totalVotes > 0 else { return 0 }
        return Double(option.voteCount) / Double(totalVotes)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    Capsule(style: .continuous)
                        .fill(isMyChoice ? RavenColors.logoStart.opacity(0.30) : Color.white.opacity(0.06))
                        .frame(width: max(22, geo.size.width * CGFloat(pct)))
                        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: pct)
                }
                .frame(height: 30)

                HStack(spacing: 8) {
                    Image(systemName: isMyChoice ? "checkmark.circle.fill" : (isClosed ? "circle" : "circle.dashed"))
                        .foregroundStyle(isMyChoice ? RavenColors.logoStart : .secondary)
                        .font(.system(size: 12, weight: .semibold))
                    Text(option.text)
                        .font(.system(size: 13, weight: isMyChoice ? .semibold : .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if voting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("\(option.voteCount)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
            }
            .background(
                Capsule(style: .continuous)
                    .stroke(isMyChoice ? RavenColors.logoStart.opacity(0.45) : Color.white.opacity(0.10), lineWidth: 0.6)
            )
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isClosed || voting)
    }
}

// MARK: - Mac Contact-Card Bubble

/// Compact glass postcard for `messageType == "contact_card"`. Mirrors
/// the iOS `ContactCardMessageView` layout (avatar + name + @username +
/// QR icon + arrow) so a card sent from iOS / Catalyst lands on Mac
/// looking identical instead of as raw JSON.
struct MacContactCardPayload: Codable {
    let userId: String
    let username: String
    let displayName: String
    let avatarUrl: String?

    var profileURL: URL? {
        URL(string: "https://raven-messager.com/u/\(username)")
    }

    /// Return a payload only when the string parses cleanly as a
    /// contact-card JSON blob. Returning nil lets the caller fall back
    /// to the normal text bubble path.
    static func decode(from raw: String?) -> MacContactCardPayload? {
        guard let raw, !raw.isEmpty,
              raw.hasPrefix("{"),
              raw.contains("\"displayName\""),
              raw.contains("\"username\""),
              let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MacContactCardPayload.self, from: data)
        else { return nil }
        return payload
    }
}

struct MacContactCardBubble: View {
    let payload: MacContactCardPayload

    @State private var showQR = false

    var body: some View {
        HStack(spacing: 12) {
            avatar
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(payload.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("@\(payload.username)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button { showQR = true } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
        .sheet(isPresented: $showQR) {
            MacContactQRSheet(payload: payload)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let path = payload.avatarUrl,
           !path.isEmpty,
           let url = URL(string: path) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: initials
                }
            }
            .clipShape(Circle())
        } else {
            initials
        }
    }

    private var initials: some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: [Color.orange.opacity(0.55), Color.orange.opacity(0.25)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            Text(payload.displayName.split(separator: " ").compactMap { $0.first }.prefix(2).map(String.init).joined().uppercased())
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

private struct MacContactQRSheet: View {
    let payload: MacContactCardPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(payload.displayName)
                    .font(.system(size: 22, weight: .semibold))
                Text("@\(payload.username)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)

            if let url = payload.profileURL,
               let qrImage = MacContactCardBubble.qrImage(for: url) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                    )
            }

            Text("Scan with another device to open this profile.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.orange))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .frame(width: 360, height: 480)
    }
}

extension MacContactCardBubble {
    /// CIFilter-based QR generation for AppKit. Same primitive as the
    /// iOS sibling, but returns an NSImage so SwiftUI on macOS can render
    /// it with `Image(nsImage:)` (UIImage isn't available here).
    static func qrImage(for url: URL) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

import CoreImage
import AppKit

// MARK: - Emoji react button with bounce animation

/// Quick-react emoji tile with an iOS-matching bounce animation. Press
/// the emoji → it scales up to ~1.6× briefly, then springs back. Gives
/// the reaction a tactile feel even though Mac uses click-to-react.
private struct EmojiReactButton: View {
    let emoji: String
    let action: () -> Void
    @State private var bounced = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.45)) { bounced = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) { bounced = false }
            }
            action()
        } label: {
            Text(emoji)
                .font(.system(size: 16))
                .frame(width: 26, height: 26)
                .scaleEffect(bounced ? 1.6 : 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message-request receiver bar

/// Three-button receiver UI shown above the composer when a non-friend
/// has sent the user a message request. Block (red), Decline (subtle),
/// Accept (brand). Mirrors the iOS layout 1:1 so the design language
/// is consistent across platforms.
struct MessageRequestReceiverBar: View {
    let peerName: String
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onBlock: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("\(peerName) wants to message you.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Button(action: onBlock) {
                    Text("Block")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.18))
                        .foregroundStyle(Color.red)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onDecline) {
                    Text("Decline")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .foregroundStyle(.primary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                Button(action: onAccept) {
                    Text("Accept")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, y: -4)
        .padding(16)
    }
}
