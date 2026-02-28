// RAVEN - Messages View (Inbox)
// Converted from Flutter messages_page.dart

import SwiftUI

struct MessagesView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var showNewChat = false
    
    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return appState.conversations
        }
        return appState.conversations.filter {
            $0.recipientName.localizedCaseInsensitiveContains(searchText) ||
            $0.recipientUsername.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Bar
                SearchBar(text: $searchText, placeholder: "Search messages...")
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                
                if appState.isLoadingConversations {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredConversations.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Messages" : "No Results",
                        systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "Start a conversation!" : "No matches for '\(searchText)'")
                    )
                } else {
                    List {
                        ForEach(filteredConversations) { conversation in
                            NavigationLink {
                                ChatView(
                                    recipientId: conversation.recipientId,
                                    recipientName: conversation.recipientName
                                )
                            } label: {
                                ConversationRow(conversation: conversation)
                            }
                        }
                        .onDelete(perform: deleteConversation)
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await appState.loadConversations()
                    }
                }
            }
            .navigationTitle("Messages")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView()
            }
        }
    }
    
    func deleteConversation(at offsets: IndexSet) {
        // Delete conversation
    }
}

// MARK: - Conversation Row
struct ConversationRow: View {
    let conversation: Conversation
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar with online indicator
            ZStack(alignment: .bottomTrailing) {
                AvatarView(url: conversation.recipientAvatarUrl, name: conversation.recipientName, size: 50)
                
                if conversation.isOnline {
                    Circle()
                        .fill(.green)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .stroke(Color(UIColor.systemBackground), lineWidth: 2)
                        )
                        .offset(x: 2, y: 2)
                }
            }
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.recipientName)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(conversation.lastMessageTime.chatTimestamp)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    // Last message with type icon
                    HStack(spacing: 4) {
                        if conversation.lastMessageType != .text {
                            Image(systemName: conversation.lastMessageType.icon)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text(lastMessagePreview)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // Unread badge
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.ravenPrimary)
                            .clipShape(Capsule())
                    }
                    
                    // Muted icon
                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    
    var lastMessagePreview: String {
        switch conversation.lastMessageType {
        case .image: return "📷 Photo"
        case .voice: return "🎤 Voice message"
        case .file: return "📎 File"
        case .location: return "📍 Location"
        default: return conversation.lastMessage
        }
    }
}

// MARK: - Search Bar
struct SearchBar: View {
    @Binding var text: String
    var placeholder: String = "Search"
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocapitalization(.none)
            
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .glassBackground(cornerRadius: 10)
    }
}

// MARK: - New Chat View
struct NewChatView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var searchResults: [User] = []
    @State private var isSearching = false
    
    var body: some View {
        NavigationStack {
            VStack {
                SearchBar(text: $searchText, placeholder: "Search by username...")
                    .padding()
                    .onChange(of: searchText) { _, newValue in
                        performSearch(newValue)
                    }
                
                if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView("No Users Found", systemImage: "person.slash", description: Text("Try a different username"))
                } else if !searchResults.isEmpty {
                    List(searchResults) { user in
                        Button {
                            dismiss()
                            // Navigate to chat
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: user.avatarUrl, name: user.displayName, size: 44)
                                
                                VStack(alignment: .leading) {
                                    Text(user.displayName)
                                        .font(.headline)
                                    Text("@\(user.username)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                            }
                        }
                        .foregroundColor(.primary)
                    }
                    .listStyle(.plain)
                } else {
                    // Recent contacts
                    if !appState.contacts.isEmpty {
                        List {
                            Section("Recent Contacts") {
                                ForEach(appState.contacts.prefix(10)) { contact in
                                    Button {
                                        dismiss()
                                        // Navigate to chat
                                    } label: {
                                        HStack(spacing: 12) {
                                            AvatarView(url: contact.avatarUrl, name: contact.displayName, size: 40)
                                            Text(contact.effectiveName)
                                            Spacer()
                                        }
                                    }
                                    .foregroundColor(.primary)
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    } else {
                        ContentUnavailableView("Search for Users", systemImage: "magnifyingglass", description: Text("Find friends by their username"))
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    func performSearch(_ query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        
        Task {
            searchResults = await appState.searchUsers(query)
            isSearching = false
        }
    }
}

#Preview {
    MessagesView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
