import SwiftUI

// MARK: - Forward Sheet
/// Bottom sheet for selecting a conversation to forward a post to
struct ForwardPostSheet: View {
    let post: Post
    
    @Environment(\.dismiss) private var dismiss
    @State private var conversationStore = ConversationStore.shared
    @State private var searchQuery = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    
    // For friend-only posts filtering
    @State private var validFriendIds: Set<String>? = nil
    @State private var isCheckingFriends = false
    
    private var filteredConversations: [Conversation] {
        var available = conversationStore.conversations
        
        // 1. If post is friends-only, ensure recipient is mutual friend
        if post.visibility == "friends" {
            if let validIds = validFriendIds {
                available = available.filter { conv in
                    if conv.isGroup { return false } // Groups cannot be guaranteed to have only mutuals
                    let peerId = conv.peer.userId
                    return peerId == post.authorId || validIds.contains(peerId)
                }
            } else {
                return [] // Still checking permissions from server
            }
        }
        
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return available }
        
        return available.filter { c in
            c.peer.displayName.lowercased().contains(q)
            || c.peer.username.lowercased().contains(q)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: - Post Preview
                postPreviewCard
                    .padding()
                
                Divider()
                
                // MARK: - Search Bar
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    
                    TextField("Search conversations...", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.horizontal)
                .padding(.vertical, 12)
                
                // MARK: - Conversation List
                if isCheckingFriends {
                    Spacer()
                    ProgressView("Checking permissions...")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else if conversationStore.conversations.isEmpty {
                    emptyState
                } else if filteredConversations.isEmpty {
                    noResultsState
                } else {
                    conversationList
                }
            }
            .navigationTitle("Forward Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                // 1. Fix the initial lag: only load from DB if it's completely empty
                if conversationStore.conversations.isEmpty {
                    await conversationStore.loadFromDB()
                }
                
                // 2. Mutual friend check for friends-only posts
                if post.visibility == "friends" {
                    isCheckingFriends = true
                    do {
                        struct FriendItem: Decodable { let id: String }
                        struct FriendsResp: Decodable { let friends: [FriendItem] }
                        
                        // Get author's friends to verify mutual connection
                        let response: FriendsResp = try await NetworkService.shared.get(
                            path: "/api/users/\(post.authorId)/friends",
                            queryItems: [URLQueryItem(name: "limit", value: "500")] // Fetch all
                        )
                        let ids = Set(response.friends.map { $0.id })
                        
                        await MainActor.run {
                            self.validFriendIds = ids
                            self.isCheckingFriends = false
                        }
                    } catch {
                        #if DEBUG
                        print("Failed to fetch author friends: \(error)")
                        #endif
                        await MainActor.run {
                            self.validFriendIds = [] // Fail securely: deny forwarding to anyone
                            self.isCheckingFriends = false
                        }
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
    
    // MARK: - Post Preview Card
    private var postPreviewCard: some View {
        HStack(alignment: .top, spacing: 12) {
            // Author avatar
            AsyncImage(url: AppConfig.mediaURL(from: post.authorAvatar)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        Text(String(post.authorUsername.prefix(1)).uppercased())
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(post.authorUsername)")
                    .font(.subheadline.weight(.medium))
                
                Text(post.content)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()
            
            // Thumbnail if available
            if let firstMediaUrl = post.allMediaUrls.first, let url = AppConfig.mediaURL(from: firstMediaUrl) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.2))
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }
    
    // MARK: - Conversation List
    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredConversations) { conversation in
                    Button {
                        forwardTo(conversation: conversation)
                    } label: {
                        conversationRow(conversation)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    
                    if conversation.id != filteredConversations.last?.id {
                        Divider()
                            .padding(.leading, 70)
                    }
                }
            }
        }
    }
    
    // MARK: - Conversation Row
    private func conversationRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 14) {
            // Avatar
            GlassAvatar(
                name: conversation.peer.displayName,
                path: conversation.peer.avatarPath,
                size: 50,
                showGlow: false
            )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.peer.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                
                Text("@\(conversation.peer.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if isSending {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    
    // MARK: - Empty States
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(.secondary)
            Text("No conversations yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Start a chat to forward posts")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
    
    private var noResultsState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: post.visibility == "friends" && searchQuery.isEmpty ? "lock.slash" : "magnifyingglass")
                .font(.system(size: 50, weight: .thin))
                .foregroundColor(.secondary)
            Text(post.visibility == "friends" && searchQuery.isEmpty ? "No eligible recipients" : "No results found")
                .font(.headline)
                .foregroundStyle(.secondary)
                
            if post.visibility == "friends" && searchQuery.isEmpty {
                Text("This is a friends-only post. You can only forward it to mutual friends of the author.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }
    
    // MARK: - Forward Action
    private func forwardTo(conversation: Conversation) {
        guard !isSending else { return }
        isSending = true
        
        Task {
            do {
                try await MessageService.shared.sendPostShare(
                    post: post,
                    to: conversation.isGroup ? conversation.roomId : conversation.peer.userId,
                    isGroup: conversation.isGroup
                )
                
                await MainActor.run {
                    Haptics.success()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    Haptics.error()
                    errorMessage = "Failed to forward: \(error.localizedDescription)"
                    isSending = false
                }
            }
        }
    }
}
