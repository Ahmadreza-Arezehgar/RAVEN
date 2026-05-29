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
        if !networkMonitor.serverReachable {
            return .serviceUnavailable
        }
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
                // 2. Error state (with retry)
                else if let error = conversationStore.error, conversationStore.conversations.isEmpty {
                    ErrorStateView(
                        message: errorMessageFor(error),
                        error: error,
                        onRetry: {
                            Task { await conversationStore.fetchConversations(forceFull: true) }
                        }
                    )
                }
                // 3. Empty state (no conversations, loading complete)
                else if conversationStore.conversations.isEmpty && !conversationStore.isLoading {
                    EmptyMessagesStateView(onNewChat: { showNewChat = true })
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
                        
                        // 🆕 Filter pill bar (All / Unread) — local-only,
                        // hidden when there's nothing to filter to keep
                        // the chrome quiet.
                        if conversationStore.filteredConversations.contains(where: { $0.unreadCount > 0 }) {
                            InboxFilterPills(selection: $unreadFilter)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                        }

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
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            // Note: .searchable removed to avoid duplicate search behind bottom bar
            // Search is handled via SearchPill in MainShellView
            .toolbar {
                // Left: New Group button
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        if conversationStore.isLoading {
                            ProgressView().scaleEffect(0.7)
                        }
                        GlassCapsuleButton(icon: "person.2.badge.plus", size: 38) {
                            showNewGroup = true
                        }

                        Menu {
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

                // Right: New Chat button
                ToolbarItem(placement: .topBarTrailing) {
                    GlassCapsuleButton(icon: "square.and.pencil", size: 38) {
                        showNewChat = true
                    }
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
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
    
    var body: some View {
        List {
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
                                        .font(.system(size: 15, weight: .semibold))
                                        .lineLimit(1)
                                    Text("Wants to message you")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Image(systemName: "envelope.badge")
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.orange.opacity(0.06))
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                } header: {
                    HStack {
                        Text("Message Requests")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text("\(pendingRequests.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
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
                    .listRowSeparator(.hidden)
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
                    // Display name - group name for groups, peer name for 1:1
                    Text(conversation.displayTitle)
                        .font(.headline)
                        .fontWeight(conversation.unreadCount > 0 ? .bold : .semibold)
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
                    
                    // Timestamp
                    if let lastMessage = conversation.lastMessage {
                        Text(lastMessage.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                HStack {
                    // Preview with delivery indicator. If the user has an
                    // unsent draft for this conversation we surface it
                    // ahead of the last message — matches Telegram's "Draft:
                    // …" hint and helps users find rooms where they left
                    // mid-thought.
                    HStack(spacing: 4) {
                        if let draft = inboxDraft(for: conversation.roomId) {
                            Text("Draft:")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(draft)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        } else if let lastMessage = conversation.lastMessage {
                            // Delivery indicator (subtle)
                            Circle()
                                .fill(lastMessage.deliveryAuthority == .mesh ? Color.purple.opacity(0.7) : Color.blue.opacity(0.7))
                                .frame(width: 5, height: 5)

                            Text(previewText)
                                .font(.subheadline)
                                .foregroundStyle(conversation.unreadCount > 0 ? .primary : .secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Unread badge
                    UnreadBadge(count: conversation.unreadCount, isMuted: conversation.isMuted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Liquid Glass material effect (iOS 15+)
        // ✅ Perf fix: Solid background instead of .regularMaterial — avoids GPU blur recalc on every scroll frame
        .background(Color(.secondarySystemGroupedBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: DS.radiusCard))
        .opacity(conversation.unreadCount > 0 ? 1.0 : 0.85)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
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
                    colors: [.blue.opacity(0.6), .purple.opacity(0.4)],
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
struct EmptyInboxView: View {
    let onNewChat: () -> Void
    
    var body: some View {
        ContentUnavailableView {
            Label("No Messages", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Start a conversation to see it here")
        } actions: {
            Button("New Message", action: onNewChat)
                .buttonStyle(.borderedProminent)
        }
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
                        .foregroundColor(selection == filter ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selection == filter ? Color.accentColor : Color.primary.opacity(0.06))
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
