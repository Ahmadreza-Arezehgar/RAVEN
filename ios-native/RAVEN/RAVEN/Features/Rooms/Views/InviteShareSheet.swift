import SwiftUI

/// Liquid Glass share sheet for invite-only rooms
/// Shows after room creation when privacy = invite
struct InviteShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let room: AudioRoom
    @State private var copied = false
    @State private var showForwardSheet = false
    
    private var webLink: String {
        "https://raven.app/room/\(room.shareSlug ?? room.id)"
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Room Info
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.linearGradient(
                                colors: [.purple, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }
                    
                    Text(room.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Only people with link can join")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                
                // Link Preview
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.blue)
                    
                    Text(webLink)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                // Actions
                VStack(spacing: 12) {
                    // Forward in Raven (NEW)
                    Button {
                        showForwardSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text("Forward to Friends")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Copy Link
                    Button {
                        UIPasteboard.general.string = webLink
                        copied = true
                        
                        // Reset after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied!" : "Copy Link")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.blue)
                    }
                    
                    // Share Sheet
                    if let shareURL = URL(string: webLink) {
                        ShareLink(item: shareURL, message: Text("Join my Audio Room on RAVEN: \(room.title)")) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("More Options")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal)
            .navigationTitle("Invite Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showForwardSheet) {
                ForwardRoomLinkSheet(roomTitle: room.title, webLink: webLink)
            }
        }
        .presentationDetents([.fraction(0.7), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }
}

// MARK: - Forward Room Link Sheet
struct ForwardRoomLinkSheet: View {
    let roomTitle: String
    let webLink: String
    
    @Environment(\.dismiss) private var dismiss
    @State private var conversationStore = ConversationStore.shared
    @State private var searchQuery = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    
    private var filteredConversations: [Conversation] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return conversationStore.conversations }
        
        return conversationStore.conversations.filter { c in
            c.peer.displayName.lowercased().contains(q) ||
            (c.peer.username.lowercased().contains(q))
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Link Preview
                VStack(alignment: .leading, spacing: 4) {
                    Text("Forwarding Link:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Join my Audio Room: \(roomTitle)\n\(webLink)")
                        .font(.subheadline)
                        .lineLimit(2)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
                
                Divider()
                
                // Search
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search friends...", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding()
                
                // List
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredConversations) { conv in
                            Button {
                                forwardTo(conversation: conv)
                            } label: {
                                conversationRow(conv)
                            }
                            .buttonStyle(.plain)
                            .disabled(isSending)
                            
                            Divider().padding(.leading, 70)
                        }
                    }
                }
            }
            .navigationTitle("Forward to Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await conversationStore.loadFromDB()
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }
    
    private func conversationRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 14) {
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
                ProgressView().scaleEffect(0.8)
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(8)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    
    private func forwardTo(conversation: Conversation) {
        guard !isSending else { return }
        isSending = true
        
        Task {
            do {
                let messageText = "Join my Audio Room \"\(roomTitle)\" here: \n\(webLink)"
                try await MessageService.shared.sendText(to: conversation.peer.userId, text: messageText)
                await MainActor.run {
                    Haptics.success()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    Haptics.error()
                    errorMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }
}

#Preview {
    InviteShareSheet(room: AudioRoom(
        id: "preview-id",
        title: "Tech Talk",
        description: nil,
        hostUserId: "user1",
        hostName: "John",
        hostAvatar: nil,
        roomImageUrl: nil,
        privacy: .invite,
        allowAnonymous: true,
        allowRaiseHand: true,
        isLocked: false,
        isLive: true,
        participantCount: 1,
        maxParticipants: 100,
        createdAt: Date(),
        shareSlug: "abc12345"
    ))
}
