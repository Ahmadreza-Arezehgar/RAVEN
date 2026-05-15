import SwiftUI

// MARK: - Forward Sheet

struct ForwardSheet: View {
    let message: ChatMessage
    var onForward: ((Conversation) -> Void)? // full conversation for channel info
    
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    
    // Access shared store directly (it uses @Observable)
    private var conversationStore: ConversationStore { ConversationStore.shared }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    
                    TextField("Search conversations", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                // Conversation list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredConversations) { conversation in
                            ForwardConversationRow(conversation: conversation) {
                                let impact = UIImpactFeedbackGenerator(style: .medium)
                                impact.impactOccurred()
                                onForward?(conversation)
                                dismiss()
                            }
                            
                            Divider()
                                .padding(.leading, 72)
                        }
                    }
                }
            }
            .navigationTitle("Forward To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    private var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversationStore.conversations
        }
        return conversationStore.conversations.filter {
            $0.peer.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.peer.username.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Conversation Row

struct ForwardConversationRow: View {
    let conversation: Conversation
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Avatar
                AsyncImage(url: avatarURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color(.systemGray5))
                        .overlay {
                            Text(conversation.peer.displayName.prefix(1).uppercased())
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.peer.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    
                    Text("@\(conversation.peer.username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var avatarURL: URL? {
        guard let path = conversation.peer.avatarPath else { return nil }
        return URL(string: path)
    }
}
