import SwiftUI

// MARK: - New Chat View (1:1 Chat Picker)

/// Simple user picker for starting 1:1 conversations
struct NewChatView: View {
    @Environment(\.dismiss) private var dismiss
    
    var onSelect: (Conversation) -> Void
    
    @State private var friends: [GroupFriendInfo] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showScanner = false
    @State private var showMyQR = false
    
    private var filteredFriends: [GroupFriendInfo] {
        if searchText.isEmpty {
            return friends
        }
        return friends.filter { $0.safeDisplayName.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if friends.isEmpty {
                    ContentUnavailableView {
                        Label("No contacts yet", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text(errorMessage ?? "Add a contact by scanning their QR code — chats work over mesh, no account needed.")
                    } actions: {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            showMyQR = true
                        } label: {
                            Label("Show My QR Code", systemImage: "qrcode")
                        }
                    }
                } else {
                    friendsList
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showScanner = true
                        } label: {
                            Label("Scan a Contact's QR", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            showMyQR = true
                        } label: {
                            Label("My QR Code", systemImage: "qrcode")
                        }
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search contacts")
            .sheet(isPresented: $showScanner, onDismiss: { Task { await loadFriends() } }) {
                ScanQRCodeView()
            }
            .sheet(isPresented: $showMyQR) {
                MyQRCodeView()
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded { hideKeyboard() })
        .task {
            await loadFriends()
        }
    }
    
    private var friendsList: some View {
        List {
            ForEach(filteredFriends) { friend in
                Button {
                    selectFriend(friend)
                } label: {
                    HStack(spacing: 12) {
                        // Avatar
                        AsyncImage(url: friend.avatarUrl.flatMap { URL(string: $0) }) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle()
                                .fill(.gray.opacity(0.3))
                                .overlay {
                                    Text(String(friend.safeDisplayName.prefix(1)).uppercased())
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.safeDisplayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            
                            Text("@\(friend.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
    }
    
    // MARK: - Actions
    
    private func loadFriends() async {
        // 🔑 SERVERLESS-FIRST contacts. The primary source is now the local
        // contact store (FriendDeviceRepository) — peers added out-of-band via
        // QR scan / mesh, with their keys pinned. These ALWAYS show, with or
        // without a server, so a scanned contact is immediately chattable. The
        // legacy server friends list + cache are merged in when available.
        let local = await localContacts()

        var combined = local
        if let cached = GroupService.shared.getCachedFriends(), !cached.isEmpty {
            combined = Self.mergeFriends(local, cached)
        }
        self.friends = combined
        self.isLoading = combined.isEmpty
        self.errorMessage = nil

        // Try the (legacy) server friends list only if online. In the
        // serverless build this fast-fails with .unauthorized — that's fine,
        // we keep the local contacts and don't surface a scary error.
        guard NetworkMonitor.shared.isOnline else {
            self.isLoading = false
            if self.friends.isEmpty { self.errorMessage = Self.noContactsMessage }
            return
        }

        do {
            let fetched = try await GroupService.shared.fetchFriends()
            withAnimation { self.friends = Self.mergeFriends(local, fetched) }
        } catch {
            // Keep local + cached; only message when there's truly nothing.
            if self.friends.isEmpty { self.errorMessage = Self.noContactsMessage }
        }

        self.isLoading = false
    }

    private static let noContactsMessage =
        "No contacts yet. Scan a contact's QR code (Settings → Find Friends, or their profile) to add them — chats work over mesh, no account needed."

    /// Locally-known contacts: every distinct peer we hold a trusted device
    /// for, surfaced as a pickable friend keyed by userId. The display name
    /// comes from the device label captured at QR-scan / mesh time.
    private func localContacts() async -> [GroupFriendInfo] {
        let devices = await FriendDeviceRepository.shared.getAllTrustedDevices()
        let myId = AuthService.shared.currentUser?.id
        var byUser: [String: GroupFriendInfo] = [:]
        for d in devices where d.friendUserId != myId && !d.friendUserId.isEmpty {
            if byUser[d.friendUserId] == nil {
                let name = d.deviceName ?? ""
                byUser[d.friendUserId] = GroupFriendInfo(
                    id: d.friendUserId,
                    username: name,
                    displayName: name.isEmpty ? nil : name,
                    avatarUrl: nil
                )
            }
        }
        return Array(byUser.values).sorted { $0.safeDisplayName < $1.safeDisplayName }
    }

    private static func mergeFriends(_ a: [GroupFriendInfo], _ b: [GroupFriendInfo]) -> [GroupFriendInfo] {
        var byId: [String: GroupFriendInfo] = [:]
        for f in a + b where byId[f.id] == nil { byId[f.id] = f }
        return Array(byId.values).sorted { $0.safeDisplayName < $1.safeDisplayName }
    }
    
    private func selectFriend(_ friend: GroupFriendInfo) {
        var fName: String? = nil
        var lName: String? = nil
        if let display = friend.displayName, !display.isEmpty {
            let parts = display.split(separator: " ", maxSplits: 1).map(String.init)
            fName = parts.first
            if parts.count > 1 { lName = parts.last }
        }

        // Create conversation object for this friend
        let peer = Conversation.Peer(
            userId: friend.id,
            username: friend.username,
            firstName: fName,
            lastName: lName,
            avatarPath: friend.avatarUrl
        )
        
        let conversation = Conversation(
            roomId: friend.id,  // 1:1 chats use peer ID as room ID
            peer: peer,
            lastMessage: nil,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            updatedAt: Date()
        )

        // ⚡ AUDIT FIX: Persist the conversation BEFORE handing it to the chat
        // view. Previously the row only existed in `tempConversation` state
        // and was lost when the user backgrounded the app or restarted —
        // making "new 1:1 chat offline" silently disappear. Persisting here
        // means a draft / first-message conversation always survives a relaunch
        // and gets reconciled the next time the inbox loads from DB.
        Task.detached(priority: .userInitiated) {
            try? await ConversationRepository.shared.upsert(conversation)
            await MainActor.run { ConversationStore.shared.addLocally(conversation) }
        }

        onSelect(conversation)
        // BUG FIX: Removed `dismiss()` to prevent a double-dismissal crash.
        // The parent view naturally dismisses this sheet when changing the state variable.
    }
}

#Preview {
    NewChatView { _ in }
}
