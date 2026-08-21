import SwiftUI

// MARK: - Navigation Item
struct InboxChatNavigationItem: Identifiable, Hashable {
    let id: String
}

// MARK: - Inbox View (Conversations List)
struct InboxView: View {
    // BUG FIX (2026-05-10): `@State` on an `@Observable` singleton is
    // the wrong wrapper. The Observation runtime auto-tracks property
    // reads inside `body` for any reference exposed via plain `let` —
    // wrapping it in `@State` adds value-storage semantics this class
    // doesn't need (and on some iOS versions can suppress observation).
    private let conversationStore = ConversationStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var bleEngine = BLEMeshEngine.shared
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showStatusSheet = false
    @State private var showSavedMessages = false
    /// "All" vs "Unread" filter for the conversation list — purely client
    /// side, no server roundtrip. Defaults to All on app open.
    @State private var unreadFilter: InboxFilter = .all

    enum InboxFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        var id: String { rawValue }
    }
    @State private var selectedRoomItem: InboxChatNavigationItem? = nil
    @State private var tempConversation: Conversation? = nil
    
    /// Computed connection status for the status pill. Returns nil when everything is OK.
    private var connectionStatus: ConnectionStatus? {
        // Priority: BT denied > offline > BT off
        if bleEngine.bluetoothState == .unauthorized {
            return .bluetoothDenied
        }
        if !networkMonitor.isOnline {
            return .offline
        }
        // OBSIDIAN CLEANUP (2026-08): `.serviceUnavailable` ("Service issue ·
        // Try again") removed — server reachability is meaningless in the
        // serverless build and the banner was pure noise.
        if bleEngine.bluetoothState == .poweredOff {
            return .bluetoothOff
        }
        return nil
    }
    
    var body: some View {
        Group { // FIXED: Removed nested NavigationStack
            Group {
                // 1. Loading state (initial load only)
                if conversationStore.isLoading && conversationStore.conversations.isEmpty {
                    GlassShimmerLoadingView()
                }
                // 2. Error state (with retry) — but NOT for the serverless
                // build's expected "no reachable server" errors, which would
                // otherwise show a bogus "Session expired - please log in
                // again" on a fresh local identity. Those fall through to the
                // empty inbox below.
                else if let error = conversationStore.error,
                        conversationStore.conversations.isEmpty,
                        !isExpectedServerlessError(error) {
                    ErrorStateView(
                        message: errorMessageFor(error),
                        error: error,
                        onRetry: {
                            Task { await conversationStore.fetchConversations(forceFull: true) }
                        }
                    )
                }
                // 3. Empty state (no conversations, loading complete).
                // Use the local `EmptyInboxView`, which surfaces a visible
                // CTA wired to the SAME New Chat flow the toolbar compose
                // button uses (`showNewChat = true` → `NewChatView` sheet).
                // A brand-new no-account user needs a way forward here, so
                // we do NOT fall back to the CTA-less `EmptyMessagesStateView`.
                else if conversationStore.conversations.isEmpty && !conversationStore.isLoading {
                    EmptyInboxView(onNewChat: { showNewChat = true })
                }
                // 4. Normal state (has conversations)
                else {
                    VStack(spacing: 0) {
                        // Connection status pill (replaces old full-width banners)
                        if let status = connectionStatus {
                            ConnectionStatusPill(
                                status: status,
                                onTapPill: { showStatusSheet = true },
                                onCTA: {
                                    if status.opensSettings {
                                        if let url = URL(string: UIApplication.openSettingsURLString) {
                                            UIApplication.shared.open(url)
                                        }
                                    }
                                }
                            )
                            .padding(.vertical, 6)
                            .padding(.horizontal, 24)
                        }
                        
                        // OBSIDIAN CLEANUP (2026-08): All/Unread filter pills
                        // removed — user wants minimal chrome; the filter enum
                        // stays at .all so list behavior is unchanged.

                        // Split pending message requests from active conversations
                        let baseList: [Conversation] = {
                            switch unreadFilter {
                            case .all:
                                return conversationStore.filteredConversations
                            case .unread:
                                // Anything with an unread badge OR a
                                // pending incoming friend request stays
                                // visible in Unread mode.
                                return conversationStore.filteredConversations.filter {
                                    $0.unreadCount > 0 ||
                                    ($0.requestStatus == "pending" && $0.isRequestSender == false)
                                }
                            }
                        }()
                        let pendingRequests = baseList.filter {
                            $0.requestStatus == "pending" && $0.isRequestSender == false
                        }
                        let activeConversations = baseList.filter {
                            !($0.requestStatus == "pending" && $0.isRequestSender == false)
                        }
                        
                        ConversationListView(
                            conversations: activeConversations,
                            pendingRequests: pendingRequests,
                            onMarkAsRead: { roomId in
                                Task { await conversationStore.markAsRead(roomId: roomId) }
                            },
                            onPin: { roomId in
                                Task { await conversationStore.togglePin(roomId: roomId) }
                            },
                            onMute: { roomId in
                                Task { await conversationStore.toggleMute(roomId: roomId) }
                            },
                            onDelete: { roomId in
                                Task { await conversationStore.deleteConversation(roomId: roomId) }
                            },
                            onArchive: { roomId in
                                Task { await conversationStore.toggleArchive(roomId: roomId) }
                            }
                        )
                    }
                    .sheet(isPresented: $showStatusSheet) {
                        if let status = connectionStatus {
                            ConnectionStatusSheet(status: status)
                        }
                    }
                }
            }
            // Obsidian redesign (2026-08): the "Chats" large title + search
            // bar now live inline in the scrollable list content (see
            // `ConversationListView`'s title/search header below) —
            // WhatsApp style, scrolls away with the rows instead of
            // pinning to the nav bar. Keep the nav bar title empty so
            // SwiftUI doesn't render a duplicate one; toolbar buttons
            // (new group / new chat) stay put.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // Note: .searchable removed to avoid duplicate search behind bottom bar
            .toolbar {
                // OBSIDIAN CLEANUP (2026-08): the old three-button cluster
                // (new-group + plus-menu + compose) collapsed into ONE
                // trailing compose menu — the big in-list title carries the
                // screen identity, so the bar stays nearly empty.
                ToolbarItem(placement: .topBarLeading) {
                    if conversationStore.isLoading {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showNewChat = true
                        } label: {
                            Label("New Chat", systemImage: "square.and.pencil")
                        }
                        Button {
                            showNewGroup = true
                        } label: {
                            Label("New Group", systemImage: "person.3")
                        }
                        Button {
                            showSavedMessages = true
                        } label: {
                            Label("Saved Messages", systemImage: "bookmark")
                        }
                    } label: {
                        GlassCapsuleButton(icon: "plus", size: 38) {}
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .refreshable {
                await conversationStore.fetchConversations(forceFull: true)
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView { conversation in
                    // Defer ALL state changes to the next run loop to avoid
                    // mutating state while still inside the sheet's call stack.
                    DispatchQueue.main.async {
                        showNewChat = false
                        tempConversation = conversation
                        // Additional delay to let sheet dismiss animation complete
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            selectedRoomItem = InboxChatNavigationItem(id: conversation.roomId)
                        }
                    }
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView()
            }
            .sheet(isPresented: $showSavedMessages) {
                SavedMessagesSheet()
            }

            .navigationDestination(item: $selectedRoomItem) { item in
                let roomId = item.id
                if let conversation = conversationStore.conversations.first(where: { $0.roomId == roomId }) {
                    ChatView(conversation: conversation)
                        .id(roomId)
                } else if let temp = tempConversation, temp.roomId == roomId {
                    ChatView(conversation: temp)
                        .id(roomId)
                } else {
                    //   Deep Link fallback: conversation not cached locally - resolve from server
                    RoutedChatView(chatId: roomId, isGroup: false)
                        .id(roomId)
                }
            }
            // (2026-05-15 — round 7) Quick Action: New Message → open
            // the existing New Chat composer the same way the inbox
            // toolbar's `+` button does.
            .onReceive(NotificationCenter.default.publisher(for: .ravenShortcutNewMessage)) { _ in
                showNewChat = true
            }
            // Deep link handling: navigate to chat when notification is tapped
            .onReceive(NotificationCenter.default.publisher(for: .deepLinkReceived)) { notification in
                guard let destination = notification.object as? DeepLinkRouter.Destination else { return }
                
                let targetRoomId: String
                if case .chat(let roomId) = destination {
                    targetRoomId = roomId
                } else if case .newChat(let userId) = destination {
                    targetRoomId = userId
                } else {
                    return
                }
                
                if !conversationStore.conversations.contains(where: { $0.roomId == targetRoomId }) {
                    // Create temporary placeholder for unknown sender (new contact deep link)
                    let tempPeer = Conversation.Peer(userId: targetRoomId, username: "Loading...", firstName: nil, lastName: nil, avatarPath: nil)
                    tempConversation = Conversation(roomId: targetRoomId, peer: tempPeer, lastMessage: nil, unreadCount: 0, isPinned: false, isMuted: false, updatedAt: Date(), isGroup: false)
                }
                
                // Prevent NavigationStack freeze when switching between chats
                if selectedRoomItem != nil && selectedRoomItem?.id != targetRoomId {
                    selectedRoomItem = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        selectedRoomItem = InboxChatNavigationItem(id: targetRoomId)
                    }
                } else {
                    selectedRoomItem = InboxChatNavigationItem(id: targetRoomId)
                }
                DeepLinkRouter.shared.pendingDestination = nil
            }
        }
        .task {
            // Load from DB first (instant — cached conversations appear immediately)
            await conversationStore.loadFromDB()
            
            // 🚀 Let SwiftUI render cached chats on screen
            await Task.yield()
            
            // Then fetch from server after a brief delay to let Feed get priority bandwidth
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s delay
                await conversationStore.fetchConversations()
            }
        }
    }
    
    // MARK: - Helper
    private func errorMessageFor(_ error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized: return "Session expired - please log in again"
            case .serverError: return "Server error - try again later"
            case .notFound: return "Messages not found"
            default: return "Network error: \(apiError.localizedDescription)"
            }
        }
        return "Couldn't load messages"
    }

    /// In the serverless build there is no server session, so an
    /// unauthorized / unreachable-server failure on the conversation load is
    /// the EXPECTED state — not something to surface as "session expired".
    /// The inbox is driven by local storage + mesh; show the empty state
    /// instead of a scary error the user can do nothing about.
    private func isExpectedServerlessError(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return true } // network / unreachable
        switch apiError {
        case .unauthorized, .serverError: return true
        default: return false
        }
    }
}

// MARK: - Conversation List View
struct ConversationListView: View {
    let conversations: [Conversation]
    var pendingRequests: [Conversation] = []
    let onMarkAsRead: (String) -> Void
    let onPin: (String) -> Void
    let onMute: (String) -> Void
    let onDelete: (String) -> Void
    let onArchive: (String) -> Void

    /// Live count of archived chats — drives the folder pill at the
    /// top of the inbox. Recomputed on every list change.
    @State private var archivedCount: Int = 0

    /// WhatsApp-style search entry point. The floating search FAB was
    /// removed from `MainShellView` in the Obsidian redesign, so the
    /// inbox now owns its own search affordance — a glass field under
    /// the big "Chats" title that opens the same `ConversationSearchSheet`
    /// the old FAB used.
    @State private var showSearchSheet = false

    var body: some View {
        List {
            // "Chats" large title + glass search bar — first content in
            // the list so both scroll away with the rows (WhatsApp-style),
            // rather than living in the nav bar.
            titleSearchHeader

            // 📥 Archived folder pill — Telegram-style entry point
            // for the archive bucket. Auto-hidden when empty so it
            // doesn't clutter inboxes that never archive anything.
            if archivedCount > 0 {
                Section {
                    NavigationLink {
                        ArchivedConversationsView()
                    } label: {
                        ArchivedFolderRow(count: archivedCount, onTap: {})
                            .allowsHitTesting(false)  // tap handled by NavigationLink
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }
            }

            // Message Requests section (Instagram-style)
            if !pendingRequests.isEmpty {
                Section {
                    ForEach(pendingRequests) { conversation in
                        NavigationLink(value: conversation.roomId) {
                            HStack(spacing: 14) {
                                GlassAvatar(
                                    name: conversation.displayTitle,
                                    path: conversation.displayAvatarUrl,
                                    size: 44,
                                    showGlow: false
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conversation.displayTitle)
                                        .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                        .lineLimit(1)
                                    Text("wants to message you")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(DS.amber)
                                }
                                Spacer()
                                Image(systemName: "envelope.badge")
                                    .foregroundStyle(DS.amber)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.orange.opacity(0.06))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("pending requests")
                            .font(.system(.caption2, design: .monospaced, weight: .semibold))
                            .foregroundStyle(DS.amber)
                            .textCase(.uppercase)
                        Text("[\(pendingRequests.count)]")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(DS.ink)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 2).fill(DS.amber))
                    }
                }
            }
            
            // Active conversations
            Section {
                ForEach(conversations) { conversation in
                    NavigationLink(value: conversation.roomId) {
                        ConversationRowView(conversation: conversation)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            let roomId = conversation.roomId
                            Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                onDelete(roomId)
                            }
                        } label: {
                            if conversation.isGroup {
                                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            } else {
                                Label("Delete", systemImage: "trash")
                            }
                        }

                        // Telegram-style Archive — first action revealed
                        // by a half-swipe. Hard-swipe shoots the chat
                        // into the archive folder, where it can be
                        // unarchived (or fully deleted).
                        Button {
                            let roomId = conversation.roomId
                            Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                onArchive(roomId)
                            }
                        } label: {
                            Label("Archive", systemImage: "archivebox.fill")
                        }
                        .tint(.indigo)

                        Button {
                            let roomId = conversation.roomId
                            Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                onMute(roomId)
                            }
                        } label: {
                            Label(
                                conversation.isMuted ? "Unmute" : "Mute",
                                systemImage: conversation.isMuted ? "bell" : "bell.slash"
                            )
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            let roomId = conversation.roomId
                            Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                onMarkAsRead(roomId)
                            }
                        } label: {
                            Label("Read", systemImage: "envelope.open")
                        }
                        .tint(.blue)
                        
                        Button {
                            let roomId = conversation.roomId
                            Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                onPin(roomId)
                            }
                        } label: {
                            Label(
                                conversation.isPinned ? "Unpin" : "Pin",
                                systemImage: conversation.isPinned ? "pin.slash" : "pin"
                            )
                        }
                        .tint(.purple)
                    }
                    .listRowBackground(Color.clear)
                    // Obsidian discipline: flat black rows, hairline
                    // separators instead of the old per-row glass card.
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(Color.white.opacity(0.08))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // NOTE: No .animation on List — causes NSIndexPath crashes during rapid updates
        .safeAreaPadding(.bottom, 100) // Content exists behind glass, not cut off
        .task { await refreshArchivedCount() }
        .onChange(of: conversations) { _, _ in
            // The active list shrinks/grows when chats are
            // archived/unarchived — recompute the pill count.
            Task { await refreshArchivedCount() }
        }
        .navigationDestination(for: String.self) { roomId in
            if let conversation = ConversationStore.shared.conversations.first(where: { $0.roomId == roomId }) {
                ChatView(conversation: conversation)
                    .id(roomId)
            } else {
                RoutedChatView(chatId: roomId, isGroup: false)
                    .id(roomId)
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            ConversationSearchSheet()
        }
    }

    /// WhatsApp-style header: leading-aligned "Chats" large title with a
    /// glass search field beneath it. Both are plain list rows so they
    /// scroll away with the conversations instead of pinning to the nav
    /// bar (the nav bar title is emptied out in `InboxView`).
    private var titleSearchHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            // TERMINAL REDESIGN: path-style title with a live cursor.
            HStack(alignment: .center, spacing: 8) {
                Text("raven:~/chats")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.mist)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                BlinkingCursor(height: 20)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            }

            Button {
                showSearchSheet = true
            } label: {
                HStack(spacing: 8) {
                    Text("$")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(DS.phosphor)
                    Text("grep -i \"search\"")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                        .fill(DS.inkElevated.opacity(0.9))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                        .strokeBorder(DS.hairline, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    private func refreshArchivedCount() async {
        let count = await ConversationStore.shared.archivedCount()
        await MainActor.run { self.archivedCount = count }
    }
}

// MARK: - Conversation Row View
struct ConversationRowView: View {
    let conversation: Conversation

    @State private var isPressed = false
    @State private var peerIsOnline = false

    var body: some View {
        HStack(spacing: 14) {
            // Avatar (right side visual weight). GlassAvatar renders
            // its own presence dot when `showOnlineIndicator` is true;
            // we lazily fetch peer presence so the inbox doesn't need
            // a bulk presence call on initial load.
            GlassAvatar(
                name: conversation.displayTitle,
                path: conversation.displayAvatarUrl,
                size: 50,
                showGlow: false,
                showOnlineIndicator: !conversation.isGroup && !conversation.isChannel && peerIsOnline
            )
            // Aurora signature: mesh-ring avatar. The ring color reports
            // how the last message actually got here — violet for a
            // direct mesh hop, path-blue for the internet/server path.
            // No known authority yet (or none) → no ring, avoid noise.
            .overlay {
                if let ringColor = deliveryRingColor {
                    Circle().stroke(ringColor, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if conversation.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Circle())
                        .offset(x: 4, y: -4)
                }
            }
            .task(id: conversation.peer.userId) {
                guard !conversation.isGroup, !conversation.isChannel else { return }
                let presence = await PresenceService.shared.checkPresence(conversation.peer.userId)
                await MainActor.run { peerIsOnline = presence.online }
            }
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // Soft Unique Tags: petname-first when serverless flag ON.
                    let tagTitle = RavenTagDisplay.inboxTitle(
                        displayName: conversation.displayTitle,
                        username: conversation.isGroup ? nil : conversation.peer.username
                    )
                    Text(tagTitle.title)
                        .font(.system(.headline, design: .monospaced))
                        .fontWeight(conversation.unreadCount > 0 ? .bold : .semibold)
                        .foregroundStyle(conversation.unreadCount > 0 ? DS.mist : DS.mist.opacity(0.8))
                        .lineLimit(1)
                    
                    // Verified badge for 1:1 chats
                    if !conversation.isGroup && conversation.peer.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.accentBlue)
                    }
                    
                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                if let sub = RavenTagDisplay.inboxTitle(
                    displayName: conversation.displayTitle,
                    username: conversation.isGroup ? nil : conversation.peer.username
                ).subtitle {
                    Text(sub)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    // Preview with delivery indicator. If the user has an
                    // unsent draft for this conversation we surface it
                    // ahead of the last message — matches Telegram's "Draft:
                    // …" hint and helps users find rooms where they left
                    // mid-thought.
                    HStack(spacing: 4) {
                        if let draft = inboxDraft(for: conversation.roomId) {
                            Text("$ draft:")
                                .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                .foregroundStyle(DS.amber)
                            Text(draft)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(DS.mist)
                                .lineLimit(1)
                        } else if let lastMessage = conversation.lastMessage {
                            // Delivery-path prefix: only the mesh hop gets
                            // called out explicitly (the avatar ring already
                            // carries the server/mesh signal at a glance).
                            if lastMessage.deliveryAuthority == .mesh {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption2)
                                    .foregroundStyle(DS.phosphorSoft)
                                Text("via mesh · ")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(DS.phosphor.opacity(0.75))
                            }

                            Text(previewText)
                                .font(
                                    previewText.hasPrefix("rvn1")
                                        ? .system(.subheadline, design: .monospaced)
                                        : .system(.footnote, design: .monospaced)
                                )
                                .foregroundStyle(conversation.unreadCount > 0 ? DS.mist : .secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Timestamp — console log style.
                    if let lastMessage = conversation.lastMessage {
                        Text(lastMessage.timestamp, style: .relative)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    // Unread badge — inverse phosphor block.
                    InboxUnreadBadge(count: conversation.unreadCount, isMuted: conversation.isMuted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Obsidian discipline: flat black row, no per-row glass card — the
        // hairline separator (set on the List row in ConversationListView)
        // carries the visual rhythm instead.
        .background(Color.clear)
        .opacity(conversation.unreadCount > 0 ? 1.0 : 0.85)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
    }

    /// Mesh-ring avatar color, driven by how the last message actually
    /// got here. `nil` means "don't draw a ring" (no last message yet, or
    /// authority not yet resolved).
    private var deliveryRingColor: Color? {
        switch conversation.lastMessage?.deliveryAuthority {
        case .mesh: return DS.violet
        case .server: return DS.pathBlue
        case .unknown, .none: return nil
        }
    }

    /// Returns a non-empty draft string for this conversation, if the user
    /// left one in ChatView's input (persisted there to UserDefaults).
    /// We strip whitespace so a stray space doesn't show "Draft: ".
    private func inboxDraft(for roomId: String) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: "draft_\(roomId)") else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var previewText: String {
        guard let lastMessage = conversation.lastMessage else {
            return ""
        }
        
        switch lastMessage.messageType {
        case .text:
            // Guard against encrypted/base64 content
            if let content = lastMessage.content {
                if content.looksEncrypted { return "Message" }
                // Mistyped contact-card stored as text — see Conversation.preview.
                if ContactSharePayload.looksLikeContactCard(content) {
                    return "👤 Shared a contact"
                }
                return content
            }
            return ""
        case .image:
            return "📷 Photo"
        case .video:
            return "🎬 Video"
        case .videoNote:
            return "🎥 Video note"
        case .ephemeralPhoto:
            return "📸 Snap Photo"
        case .voice:
            return "🎤 Voice message"
        case .file:
            return "📎 File"
        case .location:
            return "📍 Location"
        case .postShare:
            return "📬 Shared a post"
        case .contactCard:
            return "👤 Shared a contact"
        case .poll:
            return "📊 Poll"
        case .system:
            return "📢 Notification"
        }
    }
}

// MARK: - Inbox Unread Badge (Obsidian)
/// Inbox-local unread badge. The shared `UnreadBadge` in
/// `Views/Components/LiquidGlassComponents.swift` still serves other
/// screens with its legacy gold/gray styling — this one is scoped to
/// the Chats list restyle so it never had to touch that shared file:
/// violet capsule fill, always-white text, no red/green.
struct InboxUnreadBadge: View {
    let count: Int
    var isMuted: Bool = false

    var body: some View {
        if count > 0 {
            // TERMINAL REDESIGN: inverse phosphor block counter.
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(DS.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusPill, style: .continuous)
                        .fill(isMuted ? DS.phosphor.opacity(0.45) : DS.phosphor)
                        .shadow(color: DS.phosphor.opacity(0.4), radius: 5, y: 0)
                )
                .accessibilityLabel("\(count) unread")
        }
    }
}

// MARK: - Avatar View
struct AvatarView: View {
    let name: String
    let path: String?
    let size: CGFloat
    
    var body: some View {
        if let path = path, !path.isEmpty {
            AsyncImage(url: AppConfig.mediaURL(from: path)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                initialsView
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            initialsView
        }
    }
    
    var initialsView: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [DS.cyanDeep.opacity(0.85), DS.teal.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - Empty Inbox View
/// Empty state for a fresh inbox. Unlike the bare `EmptyMessagesStateView`,
/// this gives a brand-new (no-account) user an explicit way forward: the
/// CTA opens the New Chat composer — the same `NewChatView` sheet reached
/// by the toolbar compose button — where they can start a chat or add a
/// contact by QR.
struct EmptyInboxView: View {
    let onNewChat: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            // TERMINAL REDESIGN: console panel instead of glowing circle.
            VStack(spacing: 12) {
                TerminalWindowBar(title: "raven — /var/spool/inbox", trailing: "0 msgs")
                Image(systemName: "bird.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(DS.phosphor)
                    .symbolRenderingMode(.hierarchical)
                    .padding(.vertical, 22)

                BootLogLine(status: .ok, text: "mesh daemon online")
                BootLogLine(status: .pending, text: "awaiting first peer")
            }
            .frame(width: 300)
            .overlay(TerminalCornerTicks(radius: DS.radiusCard))

            VStack(spacing: 8) {
                Text("no messages yet")
                    .font(.system(.title3, design: .monospaced, weight: .bold))
                    .foregroundStyle(DS.mist)
                Text("messaging beyond connectivity — add a contact, then send over Wi‑Fi or Bluetooth.")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Button("$ start a chat", action: onNewChat)
                .buttonStyle(.ravenPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Loading View
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading conversations...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Inbox Filter Pills (Liquid Glass capsule)
//
// Compact horizontal selector above the conversation list with two
// segments: All / Unread. Tap a pill to flip the filter; the active
// segment is rendered with the accent fill, inactive segments stay
// neutral on the ultraThinMaterial background.

struct InboxFilterPills: View {
    @Binding var selection: InboxView.InboxFilter

    var body: some View {
        HStack(spacing: 6) {
            ForEach(InboxView.InboxFilter.allCases) { filter in
                Button {
                    Haptics.light()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        selection = filter
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(selection == filter ? DS.ink : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selection == filter ? AnyShapeStyle(DS.signalGradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    InboxView()
}
