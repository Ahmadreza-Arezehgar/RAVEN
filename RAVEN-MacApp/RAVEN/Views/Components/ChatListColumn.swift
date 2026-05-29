// ChatListColumn — middle pane on the Messages tab.
//
// Shows the inbox / DM list. Group chats and DMs both surface here.
// Selecting a row sets `router.selectedConversationId`, which the right
// pane (`RightPane`) listens to and renders the actual thread.

import SwiftUI

struct ChatListColumn: View {
    @EnvironmentObject var router: ShellRouter
    @State private var conversations: [ConversationSummary] = []
    /// "All" vs "Unread" filter — purely client-side. Hidden when there
    /// are no unread conversations so the chrome stays quiet.
    @State private var unreadFilter: MacInboxFilter = .all

    enum MacInboxFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        var id: String { rawValue }
    }
    @State private var loading = true
    @State private var search: String = ""
    @State private var showSaved = false
    @State private var showNewChat = false
    @State private var muteState: [String: Bool] = [:]    // peerId → muted
    @State private var pendingDelete: ConversationSummary?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Messages")
                    .font(.system(size: 22, weight: .heavy))
                Spacer()
                Menu {
                    Button("Saved messages…") { showSaved = true }
                    Button("Mark all as read") {
                        Task { try? await NetworkService.shared.markAllRead() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                Button(action: { showNewChat = true }) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New chat")
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Direct Messages", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
            .clipShape(Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if hasUnreadConversations {
                MacInboxFilterPills(selection: $unreadFilter)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if loading {
                Spacer()
                ProgressView().tint(RavenColors.logoStart)
                Spacer()
            } else if conversations.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundStyle(RavenColors.logoStart)
                    Text("No conversations yet")
                        .font(.system(size: 16, weight: .bold))
                    Text("Add a friend to start chatting.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { c in
                            ChatRow(
                                conversation: c,
                                isMuted: muteState[c.peerId] ?? c.isMuted,
                                selected: selectedKey(for: c) == router.selectedConversationId
                            ) {
                                // For 1:1 chats route by peer id (matches the
                                // `/api/messages/conversation/{other_user_id}`
                                // endpoint). For groups route by `roomId`,
                                // which is the group id and what
                                // `/api/groups/{group_id}/messages` expects.
                                router.selectedConversationId = selectedKey(for: c)
                                router.selectedPeer = c.peer
                                router.selectedIsGroup = c.isGroup
                                router.selectedGroupName = c.groupName
                                router.selectedGroupAvatar = c.groupAvatarUrl
                                router.selectedRequestStatus = c.requestStatus
                                router.selectedIsRequestSender = c.isRequestSender
                                router.selectedRequestId = c.requestId
                                router.selectedPendingSentCount = c.pendingSentCount
                            }
                            .contextMenu {
                                Button(action: { Task { await markRead(c) } }) {
                                    Label("Mark as read", systemImage: "envelope.open")
                                }
                                Button(action: { toggleMute(c) }) {
                                    let muted = muteState[c.peerId] ?? c.isMuted
                                    Label(
                                        muted ? "Unmute" : "Mute",
                                        systemImage: muted ? "bell" : "bell.slash"
                                    )
                                }
                                if !c.isGroup {
                                    Divider()
                                    Button(role: .destructive, action: {
                                        pendingDelete = c
                                    }) {
                                        Label("Delete conversation", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showSaved) {
            SavedMessagesSheet()
                .environmentObject(router)
        }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet { user in
                // Switch the router into a fresh 1:1 with the chosen user.
                // ChatListColumn's loader will surface the conversation
                // row on the next inbox refresh, so the right pane lights
                // up immediately even if no Conversation row exists yet.
                router.selectedConversationId = user.id
                router.selectedIsGroup = false
                router.selectedGroupName = nil
                router.selectedGroupAvatar = nil
                router.selectedPeer = ConversationPeer(
                    userId: user.id,
                    username: user.username,
                    firstName: user.firstName,
                    lastName: user.lastName,
                    avatarPath: user.avatarPath,
                    isVerified: false,
                    isPremium: false
                )
            }
        }
        .alert(item: $pendingDelete) { c in
            Alert(
                title: Text("Delete conversation?"),
                message: Text("This deletes the conversation for you only. \(c.peer.username) keeps it."),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await deleteConversation(c) }
                },
                secondaryButton: .cancel()
            )
        }
        // Refetch the conversation list whenever the realtime engine
        // posts something new — covers WS-pushed DMs, polling-fallback
        // batches, and bridge-envelope drains. Cheap because the server
        // returns a small JSON list, and it keeps the inbox row's
        // `lastMessage` / `unreadCount` in sync without manual refresh.
        .onReceive(NotificationCenter.default.publisher(
            for: .ravenInboxMessagesReceived
        )) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .ravenMeshBridgesDrained
        )) { _ in
            Task { await load() }
        }
    }

    /// Routing key for a conversation — peer id for DMs, room (group) id
    /// for group chats. ChatThreadView keys its endpoint dispatch off
    /// this and the `selectedIsGroup` flag.
    private func selectedKey(for c: ConversationSummary) -> String {
        c.isGroup ? c.roomId : c.peerId
    }

    /// Local filter — combines the search-bar text (display name / last
    /// message preview) AND the All/Unread pill state. Both filters apply
    /// in series; "Unread" with text search returns the intersection.
    private var filtered: [ConversationSummary] {
        var out = conversations
        if unreadFilter == .unread {
            out = out.filter { $0.unreadCount > 0 }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return out }
        return out.filter { c in
            if c.peer.username.lowercased().contains(q) { return true }
            if let n = c.groupName?.lowercased(), n.contains(q) { return true }
            if let lm = c.lastMessage?.content?.lowercased(), lm.contains(q) { return true }
            return false
        }
    }

    /// True when at least one conversation has an unread badge — drives
    /// whether the All/Unread pill bar appears at all.
    private var hasUnreadConversations: Bool {
        conversations.contains(where: { $0.unreadCount > 0 })
    }

    @MainActor
    private func load() async {
        loading = true
        do {
            conversations = try await NetworkService.shared.inbox()
            updateDockBadge()
        } catch {
            // Empty state below; surface a banner once we have the
            // toast component wired into the macOS shell.
        }
        loading = false
    }

    /// Push the total unread count to the macOS dock badge (the red
    /// circle on the app icon). Cleared when zero so the dock stays
    /// quiet. Standard desktop messenger convention.
    @MainActor
    private func updateDockBadge() {
        let total = conversations.reduce(0) { $0 + $1.unreadCount }
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    @MainActor
    private func markRead(_ c: ConversationSummary) async {
        guard !c.isGroup else { return }
        try? await NetworkService.shared.markRead(peerId: c.peerId, messageIds: nil)
        await load()
    }

    @MainActor
    private func toggleMute(_ c: ConversationSummary) {
        let cur = muteState[c.peerId] ?? c.isMuted
        let next = !cur
        muteState[c.peerId] = next
        Task {
            try? await NetworkService.shared.muteConversation(peerId: c.peerId, muted: next)
        }
    }

    @MainActor
    private func deleteConversation(_ c: ConversationSummary) async {
        guard !c.isGroup else { return }
        try? await NetworkService.shared.deleteConversation(peerId: c.peerId)
        if router.selectedConversationId == c.peerId {
            router.selectedConversationId = nil
        }
        await load()
    }
}

private struct ChatRow: View {
    let conversation: ConversationSummary
    let isMuted: Bool
    let selected: Bool
    let onTap: () -> Void
    @State private var hover = false
    @State private var peerIsOnline = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AvatarView(
                    letter: String(displayName.prefix(1)).uppercased(),
                    size: 44,
                    urlString: conversation.isGroup ? conversation.groupAvatarUrl : conversation.peer.avatarPath,
                    showOnlineIndicator: !conversation.isGroup && peerIsOnline
                )
                .task(id: conversation.peerId) {
                    guard !conversation.isGroup else { return }
                    // Lazy peer-presence fetch so the inbox doesn't need
                    // a bulk presence call on initial load.
                    if let p = try? await NetworkService.shared.presence(userId: conversation.peerId) {
                        await MainActor.run { peerIsOnline = p.online }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(displayName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isMuted {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let stamp = lastMessageStamp {
                            Text(stamp)
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(conversation.unreadCount > 0
                                                 ? RavenColors.logoStart
                                                 : .secondary)
                        }
                    }
                    HStack {
                        Text(preview)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if conversation.unreadCount > 0 {
                            Text("\(conversation.unreadCount)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(LinearGradient.ravenBrand)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(rowBg)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var displayName: String {
        if conversation.isGroup, let n = conversation.groupName, !n.isEmpty { return n }
        return conversation.peerUsername
    }

    /// Compact relative timestamp for the chat row, mirrors the WhatsApp /
    /// Telegram convention. Returns nil when there's no last message
    /// (newly-created group with no activity yet).
    private var lastMessageStamp: String? {
        guard let ts = conversation.lastMessage?.timestamp else { return nil }
        let now = Date()
        let diff = now.timeIntervalSince(ts)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        let cal = Calendar.current
        if cal.isDateInToday(ts) {
            let f = DateFormatter()
            f.timeStyle = .short
            return f.string(from: ts)
        }
        if cal.isDateInYesterday(ts) { return "Yesterday" }
        if diff < 7 * 86_400 {
            let f = DateFormatter()
            f.dateFormat = "EEE"
            return f.string(from: ts)
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: ts)
    }

    private var preview: String {
        if let last = conversation.lastMessage {
            // Typed messages first — server still sends `messageType` even
            // when the body is plaintext, so handle the structured types
            // before treating content as a literal string. The contact-card
            // payload travels as a JSON blob in the text field, which would
            // otherwise leak as raw JSON in the inbox row.
            switch last.messageType {
            case "contact_card":
                return "👤 Shared contact"
            case "post_share":
                return "📬 Shared a post"
            case "location":
                return "📍 Location"
            case "voice":
                return "🎤 Voice message"
            case "image":
                return "🖼️ Image"
            case "file":
                return "📎 File"
            case "video":
                return "🎬 Video"
            case "poll":
                return "📊 Poll"
            default:
                break
            }

            if let c = last.content, !c.isEmpty {
                if Message.looksEncrypted(c) { return "🔒 Encrypted message" }
                // Defensive: even when the server fails to set
                // `messageType`, recognise the contact-card JSON shape so
                // the inbox doesn't show a wall of `{"displayName":...}`.
                if Message.looksLikeContactCardJSON(c) {
                    return "👤 Shared contact"
                }
                return c
            }
            return "[Couldn't decrypt]"
        }
        return conversation.isGroup ? "New group" : "@\(conversation.peerUsername)"
    }

    private var rowBg: Color {
        if selected { return RavenColors.primary.opacity(0.12) }
        if hover { return Color.white.opacity(0.04) }
        return .clear
    }
}


// MARK: - New Chat Sheet
//
// Liquid Glass user-search sheet. Type a username, see a live result
// list, click one to start a 1:1 with that user. The caller (ChatList­Column)
// flips the ShellRouter to that user; the right pane re-renders the DM.

struct NewChatSheet: View {
    var onSelect: (User) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var results: [User] = []
    @State private var searching: Bool = false
    @State private var error: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New chat").font(.system(size: 18, weight: .heavy))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(20)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search by @username", text: $query)
                    .textFieldStyle(.plain)
                if searching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .onChange(of: query) { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                searchTask?.cancel()
                guard !trimmed.isEmpty else {
                    results = []
                    searching = false
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await runSearch(trimmed)
                }
            }

            Divider().background(Color.white.opacity(0.05))

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 13))
                    .padding(20)
            } else if results.isEmpty && !query.isEmpty && !searching {
                Text("No users found")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                    .padding(20)
            } else if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Type a username to find someone.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { user in
                            Button(action: {
                                onSelect(user)
                                dismiss()
                            }) {
                                HStack(spacing: 10) {
                                    AvatarView(
                                        letter: user.initials,
                                        size: 36,
                                        urlString: user.avatarPath
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(user.username)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                        if let bio = user.bio, !bio.isEmpty {
                                            Text(bio)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }

            Spacer()
        }
        .frame(width: 420, height: 460)
        .background(.ultraThinMaterial)
    }

    private func runSearch(_ q: String) async {
        searching = true
        defer { searching = false }
        do {
            let users = try await NetworkService.shared.searchUsers(query: q)
            // Drop self from results — starting a chat with yourself would
            // route to a thread that doesn't exist server-side.
            let myId = AuthService.shared.currentUser?.id
            results = users.filter { $0.id != myId }
            error = nil
        } catch {
            results = []
            self.error = "Search failed."
        }
    }
}


// MARK: - Mac Inbox Filter Pills (Liquid Glass capsule)
//
// Two-segment selector that filters the conversation list to All or
// Unread. Mirrors the iOS `InboxFilterPills` for cross-platform UX.

struct MacInboxFilterPills: View {
    @Binding var selection: ChatListColumn.MacInboxFilter

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ChatListColumn.MacInboxFilter.allCases) { filter in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        selection = filter
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == filter ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selection == filter
                                      ? RavenColors.logoStart
                                      : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
