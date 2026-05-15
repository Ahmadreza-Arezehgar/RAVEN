import SwiftUI

// MARK: - Navigation Item
struct InboxChatNavigationItem: Identifiable, Hashable {
    let id: String
}

// MARK: - Inbox View (Conversations List)
struct InboxView: View {
    @State private var conversationStore = ConversationStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var bleEngine = BLEMeshEngine.shared
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showStatusSheet = false
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
                        
                        // Split pending message requests from active conversations
                        let pendingRequests = conversationStore.filteredConversations.filter {
                            $0.requestStatus == "pending" && $0.isRequestSender == false
                        }
                        let activeConversations = conversationStore.filteredConversations.filter {
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
            // Load from DB first (instant)
            await conversationStore.loadFromDB()
            
            // 🚀 رندر فوری چت‌های قبلی روی صفحه
            await Task.yield()
            
            // Then fetch from server in background
            Task {
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
    
    var body: some View {
        List {
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
}

// MARK: - Conversation Row View
struct ConversationRowView: View {
    let conversation: Conversation
    
    @State private var isPressed = false
    
    var body: some View {
        HStack(spacing: 14) {
            // Avatar (right side visual weight)
            GlassAvatar(
                name: conversation.displayTitle,
                path: conversation.displayAvatarUrl,
                size: 50,
                showGlow: false
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
                    // Preview with delivery indicator
                    HStack(spacing: 4) {
                        if let lastMessage = conversation.lastMessage {
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
        // Apple Native Liquid Glass Effect (iOS 26+)
        // ✅ Perf fix: Solid background instead of .regularMaterial — avoids GPU blur recalc on every scroll frame
        .background(Color(.secondarySystemGroupedBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: DS.radiusCard))
        .opacity(conversation.unreadCount > 0 ? 1.0 : 0.85)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
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
                .buttonStyle(.glassProminent)
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

#Preview {
    InboxView()
}
