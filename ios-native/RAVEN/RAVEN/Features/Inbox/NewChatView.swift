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
                } else if let error = errorMessage {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadFriends() }
                        }
                    }
                } else if friends.isEmpty {
                    ContentUnavailableView {
                        Label("No Friends", systemImage: "person.2.slash")
                    } description: {
                        Text("Add friends to start chatting with them.")
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
            }
            .searchable(text: $searchText, prompt: "Search friends")
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
        // 🟥 ROUND 40 (2026-05-17) — offline-first friend list.
        //
        // Always render cached friends FIRST so the user sees
        // something instantly, even on a cold launch.  Then refresh
        // from the network in the background only when online.
        // Cache lives in UserDefaults under `raven_friends_cache`
        // (see GroupService.fetchFriends:563).  RAVENApp launches
        // a pre-warm task (Round 40 in RAVENApp.swift) so the
        // cache is populated as soon as the app is online for
        // the first time, not just on first open of this picker.
        if let cached = GroupService.shared.getCachedFriends(), !cached.isEmpty {
            self.friends = cached
            self.isLoading = false
        } else {
            self.isLoading = true
        }

        self.errorMessage = nil

        // Skip network entirely if offline (whether cache is empty
        // or not).  When the cache is empty + offline, the user
        // sees the "no internet, no cached friends yet" message
        // instead of an infinite spinner.
        guard NetworkMonitor.shared.isOnline else {
            self.isLoading = false
            if self.friends.isEmpty {
                self.errorMessage = "You're offline and don't have a cached friends list yet. Open RAVEN once online so we can pre-warm the list, then it'll work offline."
            }
            return
        }

        do {
            let fetched = try await GroupService.shared.fetchFriends()
            withAnimation {
                self.friends = fetched
            }
        } catch {
            if self.friends.isEmpty {
                // Show user-friendly message instead of raw NSURLErrorDomain
                if (error as? URLError)?.code == .notConnectedToInternet {
                    self.errorMessage = "You're offline and don't have a cached friends list yet. Open RAVEN once online so we can pre-warm the list, then it'll work offline."
                } else {
                    self.errorMessage = "Couldn't load friends. Please try again."
                }
            }
            // If we DO have cached friends, silently keep showing them
            // — better than wiping the list on a transient network blip.
        }

        self.isLoading = false
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
