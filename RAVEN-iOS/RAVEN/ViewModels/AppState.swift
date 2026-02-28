// RAVEN - App State (ViewModel)
// Converted from Flutter to Swift

import Foundation
import Combine
import SwiftUI

@MainActor
class AppState: ObservableObject {
    // MARK: - Current User
    @Published var currentUser: User?
    @Published var currentUserId: String?
    
    // MARK: - Conversations
    @Published var conversations: [Conversation] = []
    @Published var isLoadingConversations = false
    
    // MARK: - Current Chat
    @Published var currentChatId: String?
    @Published var currentChatMessages: [ChatMessage] = []
    @Published var isLoadingMessages = false
    
    // MARK: - Contacts
    @Published var contacts: [Contact] = []
    
    // MARK: - Feed
    @Published var feedPosts: [Post] = []
    @Published var isLoadingFeed = false
    
    // MARK: - Notifications
    @Published var notifications: [RAVENNotification] = []
    @Published var unreadNotificationCount = 0
    
    // MARK: - Network Status
    @Published var isOnline = true
    @Published var networkType: String = "wifi"
    
    // MARK: - Sync Status
    @Published var isSyncing = false
    @Published var lastSyncTime: Date?
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadLocalData()
        
        // Listen for incoming Mesh messages to update UI in real-time
        NotificationCenter.default.addObserver(forName: NSNotification.Name("NewIncomingMessage"), object: nil, queue: .main) { [weak self] notification in
            if let message = notification.object as? ChatMessage {
                self?.handleIncomingMessage(message)
            }
        }
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name("NewMeshPost"), object: nil, queue: .main) { [weak self] notification in
            if let post = notification.object as? Post {
                if !(self?.feedPosts.contains(where: { $0.id == post.id }) ?? false) {
                    withAnimation {
                        self?.feedPosts.insert(post, at: 0)
                    }
                }
            }
        }
    }
    
    private func handleIncomingMessage(_ message: ChatMessage) {
        let isGroup = message.roomId.hasPrefix("group_")
        let peerId = isGroup ? message.roomId : (message.senderId == currentUser?.id ? message.recipientId : message.senderId)

        // 1. Live update inside the open chat
        if currentChatId == peerId {
            if !currentChatMessages.contains(where: { $0.id == message.id }) {
                withAnimation {
                    currentChatMessages.append(message)
                    currentChatMessages.sort(by: { $0.timestamp < $1.timestamp })
                }
            }
        }
        
        // 2. Live update the Inbox conversation list
        updateConversationLive(with: message, isIncoming: true)
    }
    
    // MARK: - Data Loading
    
    func loadLocalData() {
        Task {
            // Load from local database
            let localConversations = await DatabaseService.shared.getAllConversations()
            let localContacts = await DatabaseService.shared.getAllContacts()
            
            await MainActor.run {
                self.conversations = localConversations
                self.contacts = localContacts
            }
        }
    }
    
    // MARK: - Conversations
    
    func loadConversations() async {
        isLoadingConversations = true
        defer { isLoadingConversations = false }
        
        do {
            // First load from local DB
            let local = await DatabaseService.shared.getAllConversations()
            self.conversations = local
            
            // Then try to sync from server
            if isOnline {
                let inbox = try await APIService.shared.getInbox()
                // Process inbox to create/update conversations
                await syncInbox(inbox)
            }
        } catch {
            print("❌ [AppState] Failed to load conversations: \(error)")
        }
    }
    
    private func syncInbox(_ messages: [MessageResponse]) async {
        // Group messages by conversation to create conversations
        var conversationMap: [String: Conversation] = [:]
        
        for msg in messages {
            let isGroup = msg.recipientId.hasPrefix("group_")
            // For group messages, the conversation key is the group ID
            // For PV messages, it's the other user's ID
            let peerId = isGroup ? msg.recipientId : (msg.senderId == AuthService.shared.currentUser?.id ? msg.recipientId : msg.senderId)
            
            if conversationMap[peerId] == nil {
                if isGroup {
                    // Group conversation — use group ID as recipient
                    conversationMap[peerId] = Conversation(
                        recipientId: peerId,
                        recipientName: "Group Chat",
                        recipientUsername: "",
                        lastMessage: msg.content,
                        lastMessageTime: ISO8601DateFormatter().date(from: msg.timestamp) ?? Date(),
                        isGroup: true
                    )
                } else {
                    // PV conversation — fetch user info for peer
                    if let user = try? await APIService.shared.getUserById(peerId) {
                        conversationMap[peerId] = Conversation(
                            recipientId: user.id,
                            recipientName: user.displayName,
                            recipientUsername: user.username,
                            recipientAvatarUrl: user.avatarUrl,
                            lastMessage: msg.content,
                            lastMessageTime: ISO8601DateFormatter().date(from: msg.timestamp) ?? Date()
                        )
                    }
                }
            }
        }
        
        // Save to DB and update state
        for conversation in conversationMap.values {
            await DatabaseService.shared.insertConversation(conversation)
        }
        
        let updated = await DatabaseService.shared.getAllConversations()
        self.conversations = updated
    }
    
    // MARK: - Messages
    
    func loadMessages(for chatId: String) async {
        currentChatId = chatId
        isLoadingMessages = true
        defer { isLoadingMessages = false }
        
        do {
            // Load from local DB first
            let local = await DatabaseService.shared.getMessages(roomId: chatId)
            self.currentChatMessages = local
            
            // Then fetch from server
            if isOnline {
                let serverMessages = try await APIService.shared.getMessages(with: chatId)
                
                // Convert and save
                for msg in serverMessages {
                    let chatMessage = ChatMessage(
                        id: msg.id,
                        roomId: chatId,
                        senderId: msg.senderId,
                        senderName: msg.senderName ?? "Unknown",
                        recipientId: msg.recipientId,
                        text: msg.content,
                        timestamp: ISO8601DateFormatter().date(from: msg.timestamp) ?? Date(),
                        via: "server",
                        status: .delivered,
                        type: MessageType(rawValue: Int(msg.messageType ?? "0") ?? 0) ?? .text,
                        audioUrl: msg.audioUrl,
                        fileName: msg.fileName,
                        mimeType: msg.mimeType
                    )
                    await DatabaseService.shared.insertMessage(chatMessage)
                }
                
                // Reload from DB
                let updated = await DatabaseService.shared.getMessages(roomId: chatId)
                self.currentChatMessages = updated
            }
        } catch {
            print("❌ [AppState] Failed to load messages: \(error)")
        }
    }
    
    // MARK: - Send Message
    
    func sendMessage(to recipientId: String, content: String, type: MessageType = .text, mediaUrl: String? = nil) async -> Bool {
        guard let user = AuthService.shared.currentUser else { return false }
        let userId = user.id
        
        // Create local message (Optimistic UI)
        let message = ChatMessage(
            id: UUID().uuidString,
            roomId: recipientId,
            senderId: userId,
            senderName: user.displayName,
            recipientId: recipientId,
            text: content,
            via: "unknown",
            status: .sending,
            type: type,
            audioUrl: mediaUrl,
            syncState: .queued
        )
        
        // Show immediately in UI
        currentChatMessages.append(message)
        
        // Live update the Inbox conversation list
        updateConversationLive(with: message, isIncoming: false)
        
        await DatabaseService.shared.insertMessage(message)
        
        var sentViaServer = false
        
        // Attempt 1: Send via Server / Bridge
        if NetworkMonitor.shared.isConnected {
            do {
                let success = try await APIService.shared.sendMessage(
                    recipientId: recipientId,
                    content: content,
                    messageId: message.id,
                    messageType: type == .text ? nil : type.icon,
                    mediaUrl: mediaUrl
                )
                
                if success {
                    sentViaServer = true
                    if let index = currentChatMessages.firstIndex(where: { $0.id == message.id }) {
                        var updated = currentChatMessages[index].copyWith(status: .sent, syncState: .synced)
                        updated.via = "server"
                        updated.deliveryAuthority = .server
                        currentChatMessages[index] = updated
                        await DatabaseService.shared.insertMessage(updated)
                    }
                    return true
                }
            } catch {
                print("📡 [AppState] Server send failed, falling back to Mesh: \(error)")
                // Don't stop — let execution continue to Mesh fallback
            }
        }
        
        // Attempt 2 (Fallback): Send via Mesh Network
        if !sentViaServer {
            if MeshService.shared.isEnabled {
                print("📡 [AppState] Switching to Mesh Network...")
                
                var meshMessage = message
                meshMessage.via = "mesh"
                MeshService.shared.sendMessage(meshMessage)
                
                if let index = currentChatMessages.firstIndex(where: { $0.id == message.id }) {
                    var updated = currentChatMessages[index].copyWith(status: .sent, syncState: .queued)
                    updated.via = "mesh"
                    updated.deliveryAuthority = .mesh
                    currentChatMessages[index] = updated
                    await DatabaseService.shared.insertMessage(updated)
                }
                return true
            } else {
                print("❌ [AppState] Message failed. Offline and Mesh disabled.")
                if let index = currentChatMessages.firstIndex(where: { $0.id == message.id }) {
                    var updated = currentChatMessages[index].copyWith(status: .failed, syncState: .failed, lastError: "No connection available")
                    updated.via = "none"
                    currentChatMessages[index] = updated
                    await DatabaseService.shared.insertMessage(updated)
                }
                return false
            }
        }
        
        return false
    }
    
    // MARK: - Feed
    
    func loadFeed() async {
        isLoadingFeed = true
        defer { isLoadingFeed = false }
        
        do {
            feedPosts = try await APIService.shared.getFeed()
        } catch {
            print("❌ [AppState] Failed to load feed: \(error)")
        }
    }
    
    func toggleLike(post: Post) async {
        guard let index = feedPosts.firstIndex(where: { $0.id == post.id }) else { return }
        
        // Optimistic update
        feedPosts[index].isLiked.toggle()
        feedPosts[index].likesCount += feedPosts[index].isLiked ? 1 : -1
        
        do {
            _ = try await APIService.shared.toggleLike(postId: post.id)
        } catch {
            // ✅ Re-find index safely — array may have mutated during await
            if let failIndex = feedPosts.firstIndex(where: { $0.id == post.id }) {
                feedPosts[failIndex].isLiked.toggle()
                feedPosts[failIndex].likesCount += feedPosts[failIndex].isLiked ? 1 : -1
            }
        }
    }
    
    // MARK: - Contacts
    
    // MARK: - Block System
    func toggleBlockStatus(userId: String, username: String, displayName: String, avatarUrl: String?, isCurrentlyBlocked: Bool) async {
        do {
            if isCurrentlyBlocked {
                _ = try await APIService.shared.unblockUser(userId: userId)
            } else {
                _ = try await APIService.shared.blockUser(userId: userId)
            }
            
            // 1. Update local database
            if var contact = contacts.first(where: { $0.userId == userId }) {
                contact.isBlocked = !isCurrentlyBlocked
                await DatabaseService.shared.insertContact(contact)
            } else {
                let newContact = Contact(userId: userId, username: username, displayName: displayName, avatarUrl: avatarUrl, isBlocked: !isCurrentlyBlocked)
                await DatabaseService.shared.insertContact(newContact)
            }
            
            await loadContacts()
            
            // 2. Live-remove posts & conversations (Instagram-style)
            if !isCurrentlyBlocked { // User was just blocked
                await MainActor.run {
                    withAnimation {
                        // Remove their posts from feed
                        self.feedPosts.removeAll(where: { $0.authorId == userId || $0.repostedBy == userId })
                        // Remove their conversations from inbox
                        self.conversations.removeAll(where: { $0.recipientId == userId })
                    }
                }
            } else {
                // Unblocked — refresh feed
                await loadFeed()
            }
        } catch {
            print("❌ [AppState] Failed to toggle block status: \(error)")
        }
    }
    
    func loadContacts() async {
        contacts = await DatabaseService.shared.getAllContacts()
    }
    
    func searchUsers(_ query: String) async -> [User] {
        do {
            return try await APIService.shared.searchUsers(query)
        } catch {
            return []
        }
    }
    
    // MARK: - Sync
    
    func syncAll() async {
        isSyncing = true
        defer { isSyncing = false }
        
        await loadConversations()
        await loadContacts()
        
        if currentChatId != nil {
            await loadMessages(for: currentChatId!)
        }
        
        lastSyncTime = Date()
    }
    
    // MARK: - Logout
    
    func clearAllData() async {
        currentUser = nil
        currentUserId = nil
        conversations = []
        currentChatMessages = []
        contacts = []
        feedPosts = []
        notifications = []
        
        await DatabaseService.shared.deleteAllData()
    }
    
    // MARK: - Notifications
    
    func loadNotifications() async {
        // TODO: Load from API when endpoint is available
        print("📢 [AppState] loadNotifications placeholder")
    }
    
    // MARK: - Live Conversation Update
    
    private func updateConversationLive(with message: ChatMessage, isIncoming: Bool) {
        let isGroup = message.recipientId.hasPrefix("group_")
        let peerId = isGroup ? message.recipientId : (isIncoming ? message.senderId : message.recipientId)
        
        var existingConv = conversations.first(where: { $0.recipientId == peerId })
        
        if existingConv != nil {
            existingConv!.lastMessage = message.type == .text ? message.text : "📸 Media"
            existingConv!.lastMessageType = message.type
            existingConv!.lastMessageTime = message.timestamp
            
            if isIncoming && currentChatId != peerId {
                existingConv!.unreadCount += 1
            }
        } else {
            let peerName = isGroup ? "Group Chat" : (isIncoming ? message.senderName : "User")
            existingConv = Conversation(
                id: peerId,
                recipientId: peerId,
                recipientName: peerName,
                recipientUsername: "",
                lastMessage: message.type == .text ? message.text : "📸 Media",
                lastMessageType: message.type,
                lastMessageTime: message.timestamp,
                unreadCount: (isIncoming && currentChatId != peerId) ? 1 : 0,
                isGroup: isGroup
            )
        }
        
        if let conv = existingConv {
            Task { await DatabaseService.shared.insertConversation(conv) }
            
            withAnimation {
                if let index = conversations.firstIndex(where: { $0.recipientId == peerId }) {
                    conversations[index] = conv
                } else {
                    conversations.append(conv)
                }
                conversations.sort(by: { $0.lastMessageTime > $1.lastMessageTime })
            }
        }
    }
}

// MARK: - ChatMessage Extension
extension ChatMessage {
    func copyWith(
        status: MessageStatus? = nil,
        syncState: SyncState? = nil,
        lastError: String? = nil
    ) -> ChatMessage {
        var copy = self
        if let s = status { copy.status = s }
        if let ss = syncState { copy.syncState = ss }
        if let le = lastError { copy.lastError = le }
        return copy
    }
}
