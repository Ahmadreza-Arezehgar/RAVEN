import SwiftUI

// MARK: - Routed Chat View (Deep Link Smart Wrapper)
/// Resolves chat metadata before navigating to ChatView.
/// Handles edge cases: user removed from group, deleted user, uncached conversation.
struct RoutedChatView: View {
    let chatId: String
    let isGroup: Bool
    
    @State private var resolvedConversation: Conversation?
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening chat...")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = errorMessage {
                ContentUnavailableView(
                    "Chat Unavailable",
                    systemImage: "exclamationmark.bubble",
                    description: Text(errorMessage)
                )
            } else if let conversation = resolvedConversation {
                ChatView(conversation: conversation)
            }
        }
        .task {
            await resolveChat()
        }
    }
    
    private func resolveChat() async {
        // 1. Check local ConversationStore first (instant)
        if let conv = await MainActor.run(body: {
            ConversationStore.shared.conversations.first(where: { $0.roomId == chatId })
        }) {
            self.resolvedConversation = conv
            self.isLoading = false
            return
        }
        
        // 2. Create a temporary conversation to navigate to
        // ChatView will fetch messages from server using roomId
        let tempPeer = Conversation.Peer(
            userId: chatId,
            username: "Loading...",
            firstName: nil,
            lastName: nil,
            avatarPath: nil
        )
        let tempConversation = Conversation(
            roomId: chatId,
            peer: tempPeer,
            lastMessage: nil,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            updatedAt: Date(),
            isGroup: isGroup
        )
        
        if isGroup {
            // 3. Groups: must verify membership — fetch from server
            await ConversationStore.shared.fetchConversations(forceFull: true)
            
            if let conv = await MainActor.run(body: {
                ConversationStore.shared.conversations.first(where: { $0.roomId == chatId })
            }) {
                self.resolvedConversation = conv
                self.isLoading = false
            } else {
                // Group not found after server fetch → user was likely removed
                self.errorMessage = "You are no longer in this group or it was deleted."
                self.isLoading = false
            }
        } else {
            // 🚀 DMs: open instantly with temp conversation — no loading spinner
            self.resolvedConversation = tempConversation
            self.isLoading = false
            
            // Fetch inbox in background so ConversationStore stays up-to-date
            Task.detached {
                await ConversationStore.shared.fetchConversations(forceFull: false)
            }
        }
    }
}
