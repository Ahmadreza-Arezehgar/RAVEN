import SwiftUI

// MARK: - Message Search Result
struct MessageSearchResult: Identifiable {
    let id: String
    let roomId: String
    let senderId: String
    let senderName: String
    let text: String?
    let fileName: String?
    let type: MessageType
    let timestamp: Date
    let peerName: String
    let peerAvatarPath: String?
}

// MARK: - Conversation Search Sheet
/// Search sheet for filtering conversations in Messages tab
/// Opens from the morphing glass search FAB
struct ConversationSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var conversationStore = ConversationStore.shared
    @State private var messageResults: [MessageSearchResult] = []
    @State private var isSearching = false
    @FocusState private var isSearchFocused: Bool
    
    var filteredConversations: [Conversation] {
        guard !searchText.isEmpty else { return [] }
        return conversationStore.conversations.filter { conversation in
            conversation.peer.displayName.localizedCaseInsensitiveContains(searchText) ||
            conversation.peer.username.localizedCaseInsensitiveContains(searchText) ||
            (conversation.lastMessage?.content?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    var hasAnyResults: Bool {
        !filteredConversations.isEmpty || !messageResults.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    
                    TextField("Search messages, files, photos...", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                    
                    if isSearching {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            messageResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)
                .padding(.top, 8)
                
                // Results
                if searchText.isEmpty {
                    // Placeholder state
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Search everything")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Messages, files, photos, videos")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { hideKeyboard() }
                } else if !hasAnyResults {
                    // No results
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("No results for \"\(searchText)\"")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { hideKeyboard() }
                } else {
                    // Results list with sections
                    List {
                        // Conversations Section
                        if !filteredConversations.isEmpty {
                            Section("Conversations") {
                                ForEach(filteredConversations) { conversation in
                                    Button {
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            DeepLinkRouter.shared.route(to: .chat(roomId: conversation.roomId))
                                        }
                                    } label: {
                                        ConversationSearchRow(
                                            conversation: conversation,
                                            searchText: searchText
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        // Messages Section
                        if !messageResults.isEmpty {
                            Section("Messages") {
                                ForEach(messageResults) { result in
                                    Button {
                                        navigateToMessage(result)
                                    } label: {
                                        MessageSearchRow(
                                            result: result,
                                            searchText: searchText
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            hideKeyboard()
                        }
                    )
                }
            }
            .onTapGesture { hideKeyboard() }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            // navigationDestination removed — conversations now route via DeepLinkRouter after dismissing the sheet
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isSearchFocused = true
            }
        }
        .onChange(of: searchText) { _, newValue in
            searchMessages(query: newValue)
        }
    }
    
    // MARK: - Search Messages from SQLite
    private func searchMessages(query: String) {
        guard query.count >= 2 else {
            messageResults = []
            return
        }
        
        isSearching = true
        
        Task {
            do {
                let results = try await searchMessagesInDatabase(query: query)
                await MainActor.run {
                    messageResults = results
                    isSearching = false
                }
            } catch {
                #if DEBUG
                print("❌ Search error: \(error)")
                #endif
                await MainActor.run {
                    messageResults = []
                    isSearching = false
                }
            }
        }
    }
    
    private func searchMessagesInDatabase(query: String) async throws -> [MessageSearchResult] {
        // ⚡ FTS5-backed search — instant even at 100k+ messages.
        // We pass a prefix-tokenized form of the user query (`word*`) so
        // typing "ban" matches "banana" interactively. Each token is
        // wrapped in double-quotes to escape FTS5 special characters
        // (e.g. - " * ' :).
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ftsQuery = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { token -> String in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")

        // Try FTS first — fall back to LIKE if the virtual table doesn't
        // exist yet (e.g. fresh install before migration ran on this DB
        // file, or older app versions that haven't seen migration 34).
        let ftsSQL = """
            SELECT m.client_message_id, m.room_id, m.sender_id, m.sender_name,
                   m.text, m.file_name, m.type, m.timestamp,
                   c.peer_first_name, c.peer_last_name, c.peer_username, c.peer_avatar_path
            FROM messages_fts
            JOIN messages m ON m.rowid = messages_fts.rowid
            LEFT JOIN conversations c ON m.room_id = c.room_id
            WHERE messages_fts MATCH ?
            ORDER BY m.timestamp DESC
            LIMIT 50
        """
        let rows: [[String: Any]]
        do {
            rows = try await DatabaseService.shared.query(ftsSQL, params: [ftsQuery])
        } catch {
            // Fallback: legacy LIKE path — slower but correct.
            let likeSQL = """
                SELECT m.client_message_id, m.room_id, m.sender_id, m.sender_name,
                       m.text, m.file_name, m.type, m.timestamp,
                       c.peer_first_name, c.peer_last_name, c.peer_username, c.peer_avatar_path
                FROM messages m
                LEFT JOIN conversations c ON m.room_id = c.room_id
                WHERE m.text LIKE ?
                   OR m.file_name LIKE ?
                   OR m.sender_name LIKE ?
                ORDER BY m.timestamp DESC
                LIMIT 50
            """
            let pattern = "%\(trimmed)%"
            rows = try await DatabaseService.shared.query(likeSQL, params: [pattern, pattern, pattern])
        }
        
        return rows.compactMap { row -> MessageSearchResult? in
            guard let id = row["client_message_id"] as? String,
                  let roomId = row["room_id"] as? String,
                  let timestampStr = row["timestamp"] as? String else {
                return nil
            }
            
            let senderId = row["sender_id"] as? String ?? ""
            let senderName = row["sender_name"] as? String ?? "Unknown"
            let text = row["text"] as? String
            let fileName = row["file_name"] as? String
            let typeStr = row["type"] as? String ?? "text"
            let type = MessageType.from(name: typeStr)
            
            // Parse timestamp
            let timestamp = PerformanceConstants.iso8601Fractional.date(from: timestampStr) ?? Date()
            
            // Build peer name
            let firstName = row["peer_first_name"] as? String ?? ""
            let lastName = row["peer_last_name"] as? String ?? ""
            let username = row["peer_username"] as? String ?? ""
            let peerName = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            let displayName = peerName.isEmpty ? username : peerName
            let peerAvatarPath = row["peer_avatar_path"] as? String
            
            return MessageSearchResult(
                id: id,
                roomId: roomId,
                senderId: senderId,
                senderName: senderName,
                text: text,
                fileName: fileName,
                type: type,
                timestamp: timestamp,
                peerName: displayName,
                peerAvatarPath: peerAvatarPath
            )
        }
    }
    
    private func navigateToMessage(_ result: MessageSearchResult) {
        // Navigate to chat room containing this message
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            DeepLinkRouter.shared.route(to: .chat(roomId: result.roomId))
        }
    }
}

// MARK: - Message Search Row
struct MessageSearchRow: View {
    let result: MessageSearchResult
    let searchText: String
    
    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: iconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                // Peer name / sender
                HStack {
                    Text(result.peerName.isEmpty ? result.senderName : result.peerName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text(result.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                
                // Content preview (with encryption guard)
                if let fileName = result.fileName, !fileName.isEmpty, !fileName.looksEncrypted {
                    Text(highlightedText(fileName, search: searchText))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let text = result.text, !text.isEmpty, !text.looksEncrypted {
                    Text(highlightedText(text, search: searchText))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(typeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var iconName: String {
        switch result.type {
        case .text: return "text.bubble"
        case .image: return "photo"
        case .video: return "video"
        case .videoNote: return "video.circle"
        case .file: return "doc"
        case .voice: return "waveform"
        case .location: return "location"
        case .postShare: return "square.and.arrow.up"
        case .contactCard: return "person.crop.rectangle.stack.fill"
        case .poll: return "chart.bar.doc.horizontal"
        case .ephemeralPhoto: return "camera.viewfinder"
        case .system: return "bell"
        }
    }

    private var iconColor: Color {
        switch result.type {
        case .text: return .blue
        case .image: return .green
        case .video: return .indigo
        case .videoNote: return .blue
        case .file: return .orange
        case .voice: return .purple
        case .location: return .red
        case .postShare: return .cyan
        case .contactCard: return .orange
        case .poll: return .orange
        case .ephemeralPhoto: return .pink
        case .system: return .gray
        }
    }

    private var typeLabel: String {
        switch result.type {
        case .text: return "Message"
        case .image: return "Photo"
        case .video: return "Video"
        case .videoNote: return "Video note"
        case .file: return "File"
        case .voice: return "Voice message"
        case .location: return "Location"
        case .postShare: return "Shared post"
        case .contactCard: return "Shared contact"
        case .poll: return "Poll"
        case .ephemeralPhoto: return "Snap Photo"
        case .system: return "Notification"
        }
    }
    
    private func highlightedText(_ text: String, search: String) -> AttributedString {
        var attributedString = AttributedString(text)
        if let range = attributedString.range(of: search, options: .caseInsensitive) {
            attributedString[range].backgroundColor = .yellow.opacity(0.3)
            attributedString[range].foregroundColor = .primary
        }
        return attributedString
    }
    
}


// MARK: - Conversation Search Row
struct ConversationSearchRow: View {
    let conversation: Conversation
    let searchText: String
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            GlassAvatar(
                name: conversation.peer.displayName,
                path: conversation.peer.avatarPath,
                size: 44,
                showGlow: false
            )
            
            VStack(alignment: .leading, spacing: 4) {
                // Name (highlighted)
                Text(highlightedText(conversation.peer.displayName, search: searchText))
                    .font(.body.weight(.medium))
                
                // Last message preview (with encryption guard)
                if let content = conversation.lastMessage?.content,
                   !content.looksEncrypted {
                    Text(highlightedText(content, search: searchText))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if let timestamp = conversation.lastMessage?.timestamp {
                Text(timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }
    
    private func highlightedText(_ text: String, search: String) -> AttributedString {
        var attributedString = AttributedString(text)
        if let range = attributedString.range(of: search, options: .caseInsensitive) {
            attributedString[range].backgroundColor = .yellow.opacity(0.3)
            attributedString[range].foregroundColor = .primary
        }
        return attributedString
    }
    
}


#Preview {
    ConversationSearchSheet()
}
