import SwiftUI
import AVFoundation
import AVKit
import CoreLocation
import MapKit

// MARK: - Trust Level, TrustIndicator, TrustCalculator
// Canonical definitions are in TrustIndicator.swift



// 🚨 FIX: Identifiable Wrappers for hoisted sheets
struct IdentifiableLocationPayload: Identifiable {
    let payload: LocationPayload
    var id: String {
        // Estefade az sessionId (baraaye live location) ya timestamp/mokhtasat baraaye sabet mondane ID
        payload.sessionId ?? "\(payload.lat)_\(payload.lng)_\(payload.timestamp.timeIntervalSince1970)"
    }
}

struct IdentifiableSeenByWrapper: Identifiable {
    let users: [SeenByUser]
    var id: String {
        // Sakhte yek ID sabet bar asase id user ha
        let joined = users.map { $0.id }.joined(separator: "_")
        return joined.isEmpty ? "empty" : joined
    }
}

// MARK: - Chat View (Full implementation)
struct ChatView: View {
    let conversation: Conversation
    
    @State private var messageStore: MessageStore
    @State private var inputText = ""
    @State private var replyingTo: ChatMessage?
    @State private var editingMessage: ChatMessage? = nil
    @State private var showScrollToBottom = false
    @State private var showAttachmentPicker = false
    @State private var showImagePicker = false       // Droplet menu: Photo/Video
    @State private var showDocumentPicker = false    // Droplet menu: PDF/File
    @State private var showLocationSheet = false     // Droplet menu: Location
    @State private var showSharedMedia = false
    @State private var showPaywall = false
    @State private var imageForEditor: UIImage? = nil // Media Editor integration
    @State private var showMediaEditor = false
    @State private var attachmentFlowState: AttachmentFlowState = .idle
    
    // Voice recording states (shared VoiceRecordingBar)
    @State private var isRecordingVoice = false
    @State private var recordedVoiceURL: URL? = nil
    @State private var voicePreviewDuration: TimeInterval = 0
    
    
    
    // In-app viewer states
    @State private var selectedImageURL: URL?
    @State private var selectedDocument: DocumentPreviewItem?
    
    // 🚨 FIX: New global sheet states
    @State private var selectedLocationPayload: LocationPayload? = nil
    @State private var selectedSeenBy: [SeenByUser]? = nil
    
    // Ephemeral photo (snap) — REMOVED
    @State private var draftSaveTask: Task<Void, Never>? = nil

    @State private var selectedLinkURL: URL?
    
    // Group settings
    @State private var showGroupSettings = false
    @State private var groupMembers: [GroupMember] = []
    
    // Mention picker
    @State private var mentionTracker = MentionTracker()
    
    // Read receipts (group chats)
    @State private var readReceiptStore = ReadReceiptStore()
    

    // Presence (Online / Last seen)
    @State private var peerIsOnline = false
    @State private var peerLastSeenAt: Date? = nil
    @State private var peerTrustLevel: TrustLevel = .unknown
    
    // Live location observer (cleaned up on disappear)
    // ✅ Bug 1 & 4 fix: liveLocationObserver removed — managed by LiveLocationSyncService singleton
    
    // Selection mode for multi-delete
    @State private var isSelectionMode = false
    @State private var selectedMessageIds = Set<String>()
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var selectedMessageForForward: ChatMessage? = nil
    
    // Report & Block
    @State private var reportTargetMessage: ChatMessage?
    @State private var showBlockConfirm = false
    
    // Cached block positions (avoids O(N) recompute on every keystroke)
    @State private var blockPositions: [String: (isFirst: Bool, isLast: Bool)] = [:]
    
    // Screenshot deduplication (merge within 30s)
    @State private var lastScreenshotTime: Date?
    @State private var screenshotCount: Int = 0
    @State private var screenshotDebounceTask: Task<Void, Never>?
    
    // Error alert for file/image send failures
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    
    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var appSettings = AppSettings.shared
    @Namespace private var avatarNamespace
    
    private var isChannel: Bool {
        conversation.isChannel
    }
    
    private var canPostInChannel: Bool {
        if !conversation.isChannel { return true }
        let myId = AuthService.shared.currentUser?.id ?? ""
        if let member = groupMembers.first(where: { $0.userId == myId }) {
            return member.isAdmin || member.role == "owner" || member.role == "moderator"
        }
        return false
    }


    
    init(conversation: Conversation) {
        self.conversation = conversation
        // ✨ Channels also use WebSocket and SQLite like groups
        self._messageStore = State(initialValue: MessageStore(roomId: conversation.roomId, isGroup: conversation.isGroup || conversation.isChannel))
        #if DEBUG
        print("🏠 [ChatView] Opening chat - roomId: \(conversation.roomId.prefix(8)), peerId: \(conversation.peer.userId.prefix(8)), isGroup: \(conversation.isGroup)")
        #endif
    }
    
    // MARK: - Message Request State (live from ConversationStore)
    private var liveConversation: Conversation? {
        ConversationStore.shared.conversations.first(where: { $0.roomId == conversation.roomId })
    }
    private var requestStatus: String? {
        liveConversation?.requestStatus ?? conversation.requestStatus
    }
    private var isRequestSender: Bool {
        liveConversation?.isRequestSender ?? conversation.isRequestSender ?? false
    }
    private var pendingSentCount: Int {
        liveConversation?.pendingSentCount ?? conversation.pendingSentCount ?? 0
    }
    private var isRequestPending: Bool {
        !conversation.isGroup && requestStatus == "pending"
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Background extends under container safe areas only (NOT keyboard)
            chatBackground
                .ignoresSafeArea(.container)
            
            // ✅ Floating composer layout — input bar overlays chat, no dark bottom panel
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Bug 8: Load more messages when user scrolls to top
                        if messageStore.hasOlderMessages {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .onAppear {
                                    Task { await messageStore.loadMore() }
                                }
                        }
                        
                        // ✅ Perf fix: block positions are cached in @State,
                        // recomputed only when message count changes (not on every keystroke).
                        let msgs = messageStore.messages
                        
                        // ✅ Perf fix: ForEach(msgs) avoids O(N) Array copy on every keystroke
                        ForEach(msgs) { message in
                            let pos = blockPositions[message.id] ?? (isFirst: true, isLast: true)
                            let isFromMe = message.senderId == AuthService.shared.currentUser?.id
                            
                            // Replace idx > 0 with first-message check (no index needed)
                            let isVeryFirstMessage = message.id == msgs.first?.id
                            let topPad: CGFloat = conversation.isGroup
                                ? (pos.isFirst && !isVeryFirstMessage ? 14 : (!isVeryFirstMessage ? 3 : 0))
                                : 2
                            
                            // System messages render as minimal centered chips,
                            // NOT wrapped in MessageBubbleView (avoids bubble styling)
                            if message.type == .system {
                                SystemEventChip(
                                    title: message.text ?? "Notification",
                                    timestamp: message.timestamp
                                )
                            } else {
                                VStack(spacing: 2) {
                                    messageBubble(for: message, isFirstInBlock: pos.isFirst, isLastInBlock: pos.isLast)
                                        .padding(.top, topPad)
                                    
                                    // Read receipts (group chats only, below each sent message)
                                    if conversation.isGroup && isFromMe {
                                        SeenByAvatarsView(
                                            seenBy: readReceiptStore.seenBy(for: message.id),
                                            isFromMe: isFromMe,
                                            onTap: {
                                                isInputFocused = false
                                                selectedSeenBy = readReceiptStore.seenBy(for: message.id)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                // ✅ Bottom content margin so last messages aren't hidden under floating composer
                .contentMargins(.bottom, 100, for: .scrollContent)
                // REMOVED: .defaultScrollAnchor(.bottom) causes infinite layout loops in iOS 17+
                .scrollDismissesKeyboard(.interactively)
                // ✅ Scroll-to-bottom floating button
                // 🔴 FIX 2: Use opacity instead of if to prevent infinite layout loop in iOS 17/18
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        Haptics.light()
                        scrollToBottom(proxy: proxy)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 90)
                    .opacity(showScrollToBottom ? 1 : 0)
                    .scaleEffect(showScrollToBottom ? 1 : 0.001)
                    .allowsHitTesting(showScrollToBottom)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showScrollToBottom)
                }
                // ✅ Bug 5 fix: .onScrollGeometryChange is iOS 18+ only.
                // On iOS 17, the scroll-to-bottom button stays hidden (safe fallback).
                .modifier(ScrollGeometryChangeModifier(showScrollToBottom: $showScrollToBottom))
                // ✅ Bug 5 fix: Auto-scroll for ALL new messages (sent AND received)
                .onChange(of: messageStore.messages.count) { oldCount, newCount in
                    blockPositions = precomputeBlockPositions(messages: messageStore.messages)
                    guard newCount > oldCount else { return }
                    
                    let isMyMessage = messageStore.messages.last?.senderId == AuthService.shared.currentUser?.id
                    
                    // Fix: initial load (0→N) should NOT be treated as pagination
                    let isInitialLoad = oldCount == 0 && newCount > 0
                    let isPagination = (newCount > oldCount + 1) && !isInitialLoad
                    
                    if isInitialLoad {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            scrollToBottom(proxy: proxy)
                        }
                    } else if !isPagination {
                        if isMyMessage || !showScrollToBottom {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToBottom(proxy: proxy)
                            }
                        }
                    }
                    
                    markVisibleMessagesAsRead()
                }
                // FIX: Mark messages as read when app returns from background
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        markVisibleMessagesAsRead()
                    }
                }
                // FIX: Auto-clear unread badge if it gets set while we are actively viewing the chat
                .onChange(of: liveConversation?.unreadCount) { _, newCount in
                    if let count = newCount, count > 0, scenePhase == .active {
                        markVisibleMessagesAsRead()
                    }
                }
                // ✅ Bug 5 fix: Mention picker as overlay — doesn't push layout
                .overlay(alignment: .bottom) {
                    if mentionTracker.isShowingPicker && conversation.isGroup {
                        MentionPickerView(
                            members: groupMembers.map { member in
                                MentionCandidate(
                                    id: member.userId,
                                    username: member.username,
                                    displayName: member.displayName,
                                    avatarUrl: member.avatarUrl
                                )
                            },
                            searchText: mentionTracker.mentionSearchText,
                            onSelect: { candidate in
                                inputText = mentionTracker.insertMention(into: inputText, candidate: candidate)
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 110) // ✅ Above floating composer
                    }
                }
                .onChange(of: isInputFocused) { _, isFocused in
                    if isFocused {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
                .onAppear {
                    blockPositions = precomputeBlockPositions(messages: messageStore.messages)
                    // Manual scroll-to-bottom replaces removed defaultScrollAnchor
                    if !messageStore.messages.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                    // Load draft
                    if let savedDraft = UserDefaults.standard.string(forKey: "draft_\(conversation.roomId)") {
                        inputText = savedDraft
                    }
                    Task { await fetchPresence() }
                }
            }
            
            // ✅ Message Request: Sender banner (pending status)
            if isRequestPending && isRequestSender {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.fill").foregroundColor(.orange)
                        Text("Message request sent. \(conversation.peer.displayName) can accept or decline.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
                    .padding(.top, 8)
                    Spacer()
                }
                .zIndex(10)
            }
            
            // ✅ Floating Liquid Glass Composer
            VStack(spacing: 8) {
                // Edit preview
                if let editing = editingMessage {
                    EditPreviewView(message: editing) {
                        editingMessage = nil
                        inputText = ""
                    }
                }
                
                // Reply preview
                if let reply = replyingTo {
                    ReplyPreviewView(message: reply) {
                        replyingTo = nil
                    }
                }
                
                // Voice recording bar (identical to Voice Comment)
                if isRecordingVoice || recordedVoiceURL != nil {
                    VoiceRecordingBar(
                        isRecording: $isRecordingVoice,
                        recordedAudioURL: $recordedVoiceURL,
                        previewDuration: $voicePreviewDuration,
                        maxDuration: PremiumLimits.voiceMessageMaxDuration,
                        onSend: { url, duration in
                            sendVoice(url, duration: Int(duration))
                        },
                        onCancel: {
                            // State is already reset by VoiceRecordingBar
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // ✅ Message Request: Conditional input bar
                if isRequestPending && !isRequestSender {
                    // Receiver: Accept / Decline / Block controls
                    receiverRequestControls
                } else if isRequestPending && isRequestSender && pendingSentCount >= 3 {
                    // Sender: limit reached
                    Text("Message request limit reached. Wait for \(conversation.peer.displayName) to accept your request.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else if requestStatus == "declined" || requestStatus == "blocked" {
                    // Declined/blocked
                    Text("You cannot reply to this conversation.")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.vertical, 12).frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: Capsule())
                } else if conversation.isChannel && !canPostInChannel {
                    // ✨ Telegram-style: Mute/Unmute button for regular channel members
                    Button {
                        Haptics.light()
                        Task { await ConversationStore.shared.toggleMute(roomId: conversation.roomId) }
                    } label: {
                        Text(conversation.isMuted ? "UNMUTE" : "MUTE")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(conversation.isMuted ? .secondary : .blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    // Normal state (or sender with messages left)
                    if isRequestPending && isRequestSender {
                        let left = max(0, 3 - pendingSentCount)
                        HStack {
                            Spacer()
                            Text("\(left)/3 messages left")
                                .font(.caption.bold()).foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.orange.opacity(0.8), in: Capsule())
                        }
                    }
                    
                    // Input bar
                    ChatInputBar(
                        text: $inputText,
                        isRecordingVoice: isRecordingVoice,
                        onSend: sendMessage,
                        onAttachment: {
                            isInputFocused = false
                            withAnimation(.spring(duration: 0.3)) {
                                showAttachmentPicker.toggle()
                            }
                        },
                        onCaptureTap: {
                            isInputFocused = false
                            isRecordingVoice = true
                        }
                    )
                    .focused($isInputFocused)
                    .opacity(isRecordingVoice ? 0.3 : 1.0)
                    .disabled(isRecordingVoice)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8) // ✅ Small gap above safe area — no hardcoded 34pt dark panel
            
            
            .onChange(of: inputText) { _, newValue in
                if conversation.isGroup {
                    mentionTracker.processTextChange(newValue)
                }
                
                // ⚡ Perf fix: debounce draft saves (500ms) to avoid disk I/O on every keystroke
                draftSaveTask?.cancel()
                draftSaveTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        UserDefaults.standard.removeObject(forKey: "draft_\(conversation.roomId)")
                    } else {
                        UserDefaults.standard.set(newValue, forKey: "draft_\(conversation.roomId)")
                    }
                }
            }
            
            
            // ✅ Droplet attachment menu (overlay on top of everything)
            if showAttachmentPicker {
                DropletAttachmentMenu(isOpen: $showAttachmentPicker) {
                    // Photo/Video - show image picker
                    attachmentFlowState = .picking
                    showImagePicker = true
                } onFile: {
                    // PDF/File - show document picker
                    showDocumentPicker = true
                } onLocation: {
                    // Location - show location sheet
                    showLocationSheet = true
                }
                .zIndex(999)  // ✅ Above everything
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
            }
            
            // ✅ Loading overlay while preparing editor (prevents black screen)
            if attachmentFlowState == .loadingAsset {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                        Text("Preparing editor…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(28)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .zIndex(1000)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
            

            // Selection mode toolbar overlay
            if isSelectionMode {
                VStack {
                    // Top bar
                    HStack {
                        Button {
                            withAnimation(.spring(response: 0.25)) {
                                isSelectionMode = false
                                selectedMessageIds.removeAll()
                            }
                        } label: {
                            Text("Cancel")
                                .foregroundStyle(.blue)
                        }
                        
                        Spacer()
                        
                        Text("\(selectedMessageIds.count) selected")
                            .font(.headline)
                        
                        Spacer()
                        
                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(selectedMessageIds.isEmpty ? .secondary : .red)
                        }
                        .disabled(selectedMessageIds.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    
                    Spacer()
                }
            }
            
        } // End ZStack
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // Center: Name + Status (tappable for groups/channels)
            ToolbarItem(placement: .principal) {
                Button {
                    if conversation.isGroup || conversation.isChannel {
                        Haptics.light()
                        showGroupSettings = true
                    }
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(conversation.displayTitle)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            
                            if conversation.peer.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.accentBlue)
                            }
                            
                            // ✅ Trust Indicator (subtle)
                            if !conversation.isGroup && !conversation.isChannel {
                                TrustIndicator(level: peerTrustLevel, size: 11)
                            }
                        }
                        
                        if conversation.isChannel {
                            Text(conversation.channelUsername != nil ? "@\(conversation.channelUsername!)" : "Channel")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if conversation.isGroup {
                            Text("\(groupMembers.count) members")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            // Dynamic presence status
                            Text(presenceStatusText)
                                .font(.caption2)
                                .foregroundStyle(peerIsOnline ? .green : .secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!conversation.isGroup && !conversation.isChannel)
            }
            
            // Right: Avatar (tappable -> Shared Media / Group Settings)
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Haptics.light()
                    if conversation.isGroup {
                        showGroupSettings = true
                    } else {
                        showSharedMedia = true
                    }
                } label: {
                    GlassAvatar(
                        name: conversation.displayTitle,
                        path: conversation.displayAvatarUrl,
                        size: 32,
                        showGlow: false,
                        showOnlineIndicator: !conversation.isGroup
                    )
                }
                .buttonStyle(.plain)
            }
        }
        // All sheets/alerts/dialogs extracted to helper (fixes type-checker timeout)
        .modifier(ChatSheetsModifier(
            showSharedMedia: $showSharedMedia,
            showGroupSettings: $showGroupSettings,
            selectedImageURL: $selectedImageURL,
            selectedDocument: $selectedDocument,
            selectedLinkURL: $selectedLinkURL,
            selectedLocationPayload: $selectedLocationPayload,
            selectedSeenBy: $selectedSeenBy,
            reportTargetMessage: $reportTargetMessage,
            showBlockConfirm: $showBlockConfirm,
            showImagePicker: $showImagePicker,
            showMediaEditor: $showMediaEditor,
            attachmentFlowState: $attachmentFlowState,
            imageForEditor: $imageForEditor,
            showDocumentPicker: $showDocumentPicker,
            showLocationSheet: $showLocationSheet,
            showPaywall: $showPaywall,
            showDeleteConfirmation: $showDeleteConfirmation,
            selectedMessageForForward: $selectedMessageForForward,
            selectedMessageIds: selectedMessageIds,
            conversation: conversation,
            groupMembers: groupMembers,
            onDismiss: { dismiss() },
            onSendImage: { sendImage($0) },
            onSendFile: { sendFile($0) },
            onSendLocation: { sendCurrentLocation($0) },
            onStartLive: { dur, loc in startLiveLocation(duration: dur, initialLocation: loc) },
            onDeleteMessages: { forEveryone in deleteSelectedMessages(forEveryone: forEveryone) }
        ))
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
        .task {
            DeepLinkRouter.shared.enterChat(roomId: conversation.roomId)
            messageStore.setupObservers()
            
            if conversation.isGroup || conversation.isChannel {
                readReceiptStore.setupObservers(roomId: conversation.roomId)
                await loadGroupMembers()
            }
            
            await messageStore.loadFromDB()
            await messageStore.fetchMessages()
            
            // Clean unified seen — replaces old inline logic
            markVisibleMessagesAsRead()
            
            if conversation.isGroup {
                let messageIds = messageStore.messages.map { $0.id }
                await readReceiptStore.loadForMessages(messageIds: messageIds)
            }
            
            await MainActor.run {
                messageStore.startPolling()
            }
        }
        // ✅ Removed .ignoresSafeArea(.keyboard) - safeAreaInset now handles keyboard properly
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar(.visible, for: .navigationBar)
        // ✅ Immediate reload when AttachmentService inserts a new local message (video/snap)
        .onReceive(NotificationCenter.default.publisher(for: AttachmentService.messageInserted)) { _ in
            Task {
                await messageStore.loadFromDB()
            }
        }
        .onDisappear {
            // Clear current chat tracking
            DeepLinkRouter.shared.exitChat()
            
            // Bug 4 fix: Remove observers on disappear (prevents memory leak)
            messageStore.removeObservers()
            
            // Remove read receipt observers
            readReceiptStore.removeObservers()
            
            
            Task { @MainActor in
                messageStore.stopPolling()
            }
            
            // ✅ Bug 4 fix: Live location is now managed by LiveLocationSyncService singleton
            // No observer cleanup needed here — session survives navigation
        }
        // 📸 Allow screenshots in chat but send alert message (deduplicated)
        .allowScreenshots()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            let now = Date()
            
            // Within 30s window? Increment counter, reset debounce
            if let last = lastScreenshotTime, now.timeIntervalSince(last) < 30 {
                screenshotCount += 1
            } else {
                screenshotCount = 1
            }
            lastScreenshotTime = now
            
            // Cancel previous debounce
            screenshotDebounceTask?.cancel()
            
            // Wait 2s before sending — allows merging rapid screenshots
            screenshotDebounceTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                
                let count = screenshotCount
                let username = AuthService.shared.currentUser?.displayName ?? "User"
                let text = count > 1
                    ? "\(count) screenshots taken"
                    : "\(username) took a screenshot"
                
                try? await messageStore.sendSystemMessage(text)
                Haptics.light()
                
                // Reset
                screenshotCount = 0
            }
        }
        // RAVEN+ upsell: show paywall when voice recording hits free-tier limit
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowPaywall"))) { _ in
            Haptics.warning()
            showPaywall = true
        }
    }
    
    private func publishMessageToFeed(_ message: ChatMessage, visibility: String) async {
        let text = message.text ?? ""
        let clientPostId = UUID().uuidString
        let draft = LocalPostDraft(
            clientPostId: clientPostId,
            authorId: AuthService.shared.currentUser?.id ?? "",
            authorUsername: AuthService.shared.currentUser?.username ?? "",
            authorAvatar: AuthService.shared.currentUser?.avatarPath,
            content: text,
            imageUrl: message.attachmentUrl,
            imageUrls: message.attachmentUrl != nil ? [message.attachmentUrl!] : nil,
            visibility: visibility,
            latitude: nil,
            longitude: nil,
            status: .posted,
            timestamp: Date(),
            initialSend: "internet",
            voiceUrl: message.type == .voice ? message.attachmentUrl : nil,
            voiceDuration: message.audioDurationSeconds,
            waveform: nil
        )
        await FeedStore.shared.insertDraft(draft)
        do {
            struct CreatePostBody: Encodable {
                let content: String
                let visibility: String
                let imageUrl: String?
                let voiceUrl: String?
                let voiceDuration: Int?
            }
            let _: Post = try await NetworkService.shared.post(
                path: "/api/posts/create",
                body: CreatePostBody(
                    content: text,
                    visibility: visibility,
                    imageUrl: message.attachmentUrl,
                    voiceUrl: message.type == .voice ? message.attachmentUrl : nil,
                    voiceDuration: message.audioDurationSeconds
                )
            )
            Haptics.success()
        } catch {
            Haptics.error()
        }
    }

    // ✅ Chat Background (extends under safe areas - adaptive for light/dark)
    private var chatBackground: some View {
        RavenChatWallpaper()
    }
    
    // MARK: - Message Request Receiver Controls
    private var receiverRequestControls: some View {
        VStack(spacing: 16) {
            Text("\(conversation.peer.displayName) wants to message you.")
                .font(.subheadline)
                .foregroundColor(.primary)
            
            HStack(spacing: 12) {
                Button {
                    Task {
                        _ = try? await BlockService.shared.blockUser(userId: conversation.peer.userId)
                        dismiss()
                    }
                } label: {
                    Text("Block").fontWeight(.semibold).frame(maxWidth: .infinity)
                        .padding(.vertical, 12).background(Color.red.opacity(0.15)).foregroundColor(.red)
                        .clipShape(Capsule())
                }.buttonStyle(.plain)
                
                Button {
                    Task { await handleRequestAction("decline") }
                } label: {
                    Text("Decline").fontWeight(.semibold).frame(maxWidth: .infinity)
                        .padding(.vertical, 12).background(.ultraThinMaterial).foregroundColor(.primary)
                        .clipShape(Capsule()).overlay(Capsule().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
                }.buttonStyle(.plain)
                
                Button {
                    Task { await handleRequestAction("accept") }
                } label: {
                    Text("Accept").fontWeight(.semibold).frame(maxWidth: .infinity)
                        .padding(.vertical, 12).background(Color.blue).foregroundColor(.white)
                        .clipShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, y: -5)
    }
    
    private func handleRequestAction(_ action: String) async {
        let targetId = conversation.requestId ?? conversation.roomId
        do {
            struct EmptyBody: Encodable {}
            struct EmptyResp: Decodable {}
            let _: EmptyResp = try await NetworkService.shared.post(
                path: "/api/message-requests/\(targetId)/\(action)", body: EmptyBody()
            )
            await ConversationStore.shared.fetchConversations(forceFull: true)
            if action == "decline" { await MainActor.run { dismiss() } }
        } catch {
            #if DEBUG
            print("❌ [MessageRequest] Failed to \(action): \(error)")
            #endif
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard !messageStore.messages.isEmpty else { return }
        if let lastMessage = messageStore.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
    
    @ViewBuilder
    private func messageBubble(for message: ChatMessage, isFirstInBlock: Bool = true, isLastInBlock: Bool = true) -> some View {
        let isFromMe = message.senderId == AuthService.shared.currentUser?.id
        let avatarUrl: String? = conversation.isGroup
            ? groupMembers.first(where: { $0.userId == message.senderId })?.avatarUrl
            : nil
        
        return MessageBubbleView(
            message: message,
            isFromMe: isFromMe,
            onReply: { replyingTo = message },
            onRetry: {
                Task { try? await messageStore.retryMessage(message) }
            },
            onForward: {
                selectedMessageForForward = message
            },
            onImageTap: { url in
                isInputFocused = false // ⚡️ Dismiss keyboard before image viewer
                selectedImageURL = url
            },
            onFileTap: { url, name in
                isInputFocused = false // ⚡️ Dismiss keyboard before file preview
                selectedDocument = DocumentPreviewItem(url: url, fileName: name)
            },
            onLinkTap: { url in
                isInputFocused = false // ⚡️ Dismiss keyboard before link
                let components = url.pathComponents.filter { $0 != "/" }
                if (url.host == "raven.app" || url.host == "www.raven.app") && components.count >= 2 && components[0] == "room" {
                    let slug = components[1]
                    DeepLinkRouter.shared.route(to: .audioRoom(slug: slug))
                } else if url.scheme == "raven" && url.host == "room", let slug = components.first {
                    DeepLinkRouter.shared.route(to: .audioRoom(slug: slug))
                } else {
                    selectedLinkURL = url 
                }
            },
            onLocationTap: { payload in
                isInputFocused = false
                selectedLocationPayload = payload
            },
            onDelete: {
                Task { await messageStore.deleteMessage(message.id) }
            },
            onSelect: {
                toggleSelection(for: message.id)
            },
            onReport: {
                reportTargetMessage = message
            },
            onBlock: {
                showBlockConfirm = true
            },
            onQuickLike: {
                // TODO: Call reaction API when available
                Haptics.medium()
            },
            onEdit: {
                editingMessage = message
                inputText = message.text ?? ""
            },
            isGroupChat: conversation.isGroup,
            isChannel: conversation.isChannel,
            isPrivateChannel: conversation.channelType == "private",
            onPublish: { visibility in
                Task { await publishMessageToFeed(message, visibility: visibility) }
            },
            isFirstInBlock: isFirstInBlock,
            isLastInBlock: isLastInBlock,
            senderAvatarUrl: avatarUrl,
            avatarNamespace: avatarNamespace,
            isSelectionMode: isSelectionMode,
            isSelected: selectedMessageIds.contains(message.id),
            groupId: conversation.isGroup ? conversation.roomId : nil
        )
    }
    
    // MARK: - Block Position Helper
    
    /// Determines if a message is first/last in a "sender block" (same sender, ≤2min gap, no system msgs)
    /// Pre-compute block positions for ALL messages in one O(N) pass.
    /// Returns a dictionary keyed by message.id → (isFirst, isLast).
    private func precomputeBlockPositions(messages: [ChatMessage]) -> [String: (isFirst: Bool, isLast: Bool)] {
        guard !messages.isEmpty else { return [:] }
        let maxGap: TimeInterval = 120
        var result: [String: (isFirst: Bool, isLast: Bool)] = [:]
        result.reserveCapacity(messages.count)
        
        for i in messages.indices {
            let msg = messages[i]
            guard msg.type != .system else {
                result[msg.id] = (true, true)
                continue
            }
            
            var isFirst = true
            if i > 0 {
                let prev = messages[i - 1]
                if prev.senderId == msg.senderId,
                   prev.type != .system,
                   msg.timestamp.timeIntervalSince(prev.timestamp) <= maxGap {
                    isFirst = false
                }
            }
            
            var isLast = true
            if i < messages.count - 1 {
                let next = messages[i + 1]
                if next.senderId == msg.senderId,
                   next.type != .system,
                   next.timestamp.timeIntervalSince(msg.timestamp) <= maxGap {
                    isLast = false
                }
            }
            
            result[msg.id] = (isFirst, isLast)
        }
        return result
    }
    
    private func blockPosition(for index: Int, in messages: [ChatMessage]) -> (isFirst: Bool, isLast: Bool) {
        // Bug 3 fix: Bounds guard prevents crash when SwiftUI evaluates stale indices during delete animation
        guard index >= 0 && index < messages.count else { return (true, true) }
        let msg = messages[index]
        
        // System messages always standalone
        guard msg.type != .system else { return (true, true) }
        
        let maxGap: TimeInterval = 120 // 2 minutes
        
        // Check previous message
        var isFirst = true
        if index > 0 {
            let prev = messages[index - 1]
            if prev.senderId == msg.senderId,
               prev.type != .system,
               msg.timestamp.timeIntervalSince(prev.timestamp) <= maxGap {
                isFirst = false
            }
        }
        
        // Check next message
        var isLast = true
        if index < messages.count - 1 {
            let next = messages[index + 1]
            if next.senderId == msg.senderId,
               next.type != .system,
               next.timestamp.timeIntervalSince(msg.timestamp) <= maxGap {
                isLast = false
            }
        }
        
        return (isFirst, isLast)
    }
    
    // MARK: - Instant Seen Helper (Unified for 1:1 and Group)
    
    /// Mark all visible messages as read — called on initial load, new messages arriving, and scene activation.
    private func markVisibleMessagesAsRead() {
        Task {
            // ✅ Bug 5 fix: Capture unseen IDs BEFORE marking all as read.
            // markAllAsRead() changes all statuses to .read in memory,
            // so filtering after it always returns an empty array — breaking blue ticks in groups.
            var unseenByMe: [String] = []
            if conversation.isGroup {
                let myId = AuthService.shared.currentUser?.id ?? ""
                unseenByMe = messageStore.messages
                    .filter { $0.senderId != myId && $0.status != .read && $0.type != .ephemeralPhoto }
                    .map { $0.id }
            }
            
            await messageStore.markAllAsRead()
            
            if conversation.isGroup && !unseenByMe.isEmpty {
                await ReadReceiptService.shared.sendSeenBatch(messageIds: unseenByMe, chatId: conversation.roomId)
            }
        }
    }
    
    private func toggleSelection(for messageId: String) {
        withAnimation(.spring(response: 0.25)) {
            if !isSelectionMode {
                isSelectionMode = true
            }
            if selectedMessageIds.contains(messageId) {
                selectedMessageIds.remove(messageId)
            } else {
                selectedMessageIds.insert(messageId)
            }
        }
    }
    
    private func deleteSelectedMessages(forEveryone: Bool) {
        // Capture a safe copy of selected IDs before entering async Task
        let selection = selectedMessageIds
        
        Task {
            let messagesToDelete = messageStore.messages.filter { selection.contains($0.id) }
            
            // ✅ Bug 6 fix: Move file I/O to background thread to avoid Watchdog kill (0x8badf00d)
            // ✅ Bug 3 fix: Reconstruct current sandbox path from filename (absolute paths go stale after app updates)
            await Task.detached(priority: .background) {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                for msg in messagesToDelete {
                    if let path = msg.localPath {
                        let fileName = URL(fileURLWithPath: path).lastPathComponent
                        let currentURL = docs.appendingPathComponent("attachments").appendingPathComponent(fileName)
                        try? FileManager.default.removeItem(at: currentURL)
                    }
                }
            }.value
            
            if forEveryone {
                let myId = AuthService.shared.currentUser?.id ?? ""
                let myMessageIds = messagesToDelete.filter { $0.senderId == myId }.map { $0.id }
                let theirMessageIds = messagesToDelete.filter { $0.senderId != myId }.map { $0.id }
                
                try? await MessageRepository.shared.deleteForEveryone(messageIds: myMessageIds)
                
                // ✅ Bug 10 fix: Others' messages can't be deleted for everyone,
                // so delete them locally to avoid leaving them orphaned on screen
                if !theirMessageIds.isEmpty {
                    try? await MessageRepository.shared.deleteForMe(messageIds: theirMessageIds)
                }
                
                for messageId in myMessageIds {
                    do {
                        try await NetworkService.shared.delete(path: "/api/messages/\(messageId)")
                    } catch {
                        #if DEBUG
                        print("  [ChatView] Failed to delete message on server: \(error)")
                        #endif
                    }
                }
            } else {
                try? await MessageRepository.shared.deleteForMe(messageIds: Array(selection))
            }
            await messageStore.loadFromDB()
            await MainActor.run {
                withAnimation {
                    isSelectionMode = false
                    selectedMessageIds.removeAll()
                }
            }
        }
    }
    
    private func loadGroupMembers() async {
        // First try to fetch from server (ensures all members see latest data)
        do {
            let group = try await GroupService.shared.fetchGroupDetails(groupId: conversation.roomId)
            await MainActor.run {
                groupMembers = group.members ?? []
                #if DEBUG
                print("👥 [ChatView] Fetched \(groupMembers.count) group members from server")
                #endif
            }
            return
        } catch {
            #if DEBUG
            print("⚠️ [ChatView] Server fetch failed, trying local cache: \(error)")
            #endif
        }
        
        // Fallback to local cache if server fails
        let repo = GroupRepository()
        do {
            if let group = try await repo.get(groupId: conversation.roomId) {
                await MainActor.run {
                    groupMembers = group.members ?? []
                    #if DEBUG
                    print("👥 [ChatView] Loaded \(groupMembers.count) group members from cache")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            print("❌ [ChatView] Failed to load group members: \(error)")
            #endif
        }
    }
    
    // MARK: - Presence Status
    
    private var presenceStatusText: String {
        if peerIsOnline {
            return "online"
        } else if let lastSeen = peerLastSeenAt {
            return "last seen \(lastSeen.formatted(.relative(presentation: .named)))"
        } else {
            return "offline"
        }
    }
    
    private func fetchPresence() async {
        // Don't fetch for groups
        guard !conversation.isGroup else { return }
        
        let presence = await PresenceService.shared.checkPresence(conversation.peer.userId)
        
        await MainActor.run {
            peerIsOnline = presence.online
            
            // Parse lastSeenAt from ISO8601 string
            if let lastSeenString = presence.lastSeenAt {
                peerLastSeenAt = PerformanceConstants.iso8601.date(from: lastSeenString)
            }
            
            // Calculate trust level (local only)
            let mutualRooms = presence.mutualRoomCount ?? 0
            peerTrustLevel = TrustCalculator.calculate(
                isInContacts: false,
                mutualRoomCount: mutualRooms
            )
        }
    }
    
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        // Clear draft
        UserDefaults.standard.removeObject(forKey: "draft_\(conversation.roomId)")
        
        // Handle edit mode
        if let editing = editingMessage {
            editingMessage = nil
            inputText = ""
            Task {
                await messageStore.editMessage(id: editing.id, newText: text)
            }
            return
        }
        
        let reply = replyingTo
        let entities = mentionTracker.entities.isEmpty ? nil : mentionTracker.entities
        inputText = ""
        replyingTo = nil
        mentionTracker.reset()
        
        Task {
            try? await messageStore.sendText(text, replyTo: reply, entities: entities)
        }
    }
    
    private func sendImage(_ image: UIImage) {
        let reply = replyingTo
        replyingTo = nil
        
        // ✅ Bug 4 fix: Await the detached task so loadFromDB runs AFTER the image
        // is compressed and inserted into the DB (not after an arbitrary 100ms guess)
        Task {
            let roomId = conversation.roomId
            let recipientId = conversation.peer.userId
            let isGroup = conversation.isGroup
            
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await AttachmentService.shared.sendImage(
                        image,
                        roomId: roomId,
                        recipientId: recipientId,
                        isGroup: isGroup,
                        replyTo: reply
                    )
                }.value
            } catch let error as PremiumLimitError {
                // FIXED: MainActor.run to update UI on Main Thread
                await MainActor.run {
                    if PremiumLimits.isPremium {
                        self.errorMessage = error.localizedDescription
                        self.showErrorAlert = true
                        Haptics.error()
                    } else {
                        self.showPaywall = true
                        Haptics.warning()
                    }
                }
            } catch {
                #if DEBUG
                print("❌ [ChatView] Image send failed: \(error)")
                #endif
                
                // FIXED: Show error to user on Main Thread
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showErrorAlert = true
                }
            }
            
            // Now we can safely refresh — the DB record is guaranteed to exist
            await messageStore.loadFromDB()
        }
    }
    
    private func sendVoice(_ url: URL, duration: Int) {
        let reply = replyingTo
        replyingTo = nil
        
        Task {
            let roomId = conversation.roomId
            let recipientId = conversation.peer.userId
            let isGroup = conversation.isGroup
            
            do {
                try await AttachmentService.shared.sendVoice(
                    audioURL: url,
                    duration: duration,
                    roomId: roomId,
                    recipientId: recipientId,
                    isGroup: isGroup,
                    replyTo: reply
                )
            } catch let error as PremiumLimitError {
                // FIXED: MainActor.run to update UI on Main Thread
                await MainActor.run {
                    if PremiumLimits.isPremium {
                        self.errorMessage = error.localizedDescription
                        self.showErrorAlert = true
                        Haptics.error()
                    } else {
                        self.showPaywall = true
                        Haptics.warning()
                    }
                }
            } catch {
                #if DEBUG
                print("❌ [ChatView] Voice send failed: \(error)")
                #endif
                
                // FIXED: Show error to user on Main Thread
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showErrorAlert = true
                }
            }
            
            await messageStore.loadFromDB()
        }
    }
    
    // MARK: - Voice Recording
    // Voice recording is now handled by the shared VoiceRecordingBar component.
    // The bar manages its own recording state, gestures, preview, and cleanup.
    // It calls sendVoice(url, duration:) when the user swipes to send or taps send in preview.
    
    private func sendFile(_ url: URL) {
        let reply = replyingTo
        replyingTo = nil
        
        Task {
            do {
                try await AttachmentService.shared.sendFile(
                    fileURL: url,
                    roomId: conversation.roomId,
                    recipientId: conversation.peer.userId,
                    isGroup: conversation.isGroup,
                    replyTo: reply
                )
            } catch let error as PremiumLimitError {
                await MainActor.run {
                    if PremiumLimits.isPremium {
                        // Premium user hit hard limit — show error, not paywall
                        errorMessage = error.localizedDescription
                        showErrorAlert = true
                        Haptics.error()
                    } else {
                        // Free user — show purchase screen
                        showPaywall = true
                        Haptics.warning()
                    }
                }
            } catch {
                #if DEBUG
                print("❌ [ChatView] File send failed: \(error)")
                #endif
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
            await messageStore.loadFromDB()
        }
    }
    
    // MARK: - Send Location
    
    private func sendCurrentLocation(_ location: CLLocation) {
        let payload = LocationPayload.current(from: location, label: nil)
        
        Task {
            try? await messageStore.sendLocation(payload)
            await messageStore.loadFromDB()
        }
    }
    
    private func startLiveLocation(duration: TimeInterval, initialLocation: CLLocation) {
        // ✅ Bug 1 & 4 fix: Delegate to singleton service
        // - Sends ONE anchor message, updates it in-place (no spam)
        // - Survives navigation (no lifecycle leak)
        Task {
            await LiveLocationSyncService.shared.start(
                duration: duration,
                initialLocation: initialLocation,
                messageStore: messageStore
            )
        }
    }
    
    
    // MARK: - Quick Reaction (from context menu)
    
}

// MARK: - Message Bubble View
struct MessageBubbleView: View {
    let message: ChatMessage
    let isFromMe: Bool
    let onReply: () -> Void
    let onRetry: () -> Void
    var onForward: (() -> Void)? = nil
    var onImageTap: ((URL) -> Void)? = nil
    var onFileTap: ((URL, String?) -> Void)? = nil
    var onLinkTap: ((URL) -> Void)? = nil
    var onLocationTap: ((LocationPayload) -> Void)? = nil // Expand map
    var onDelete: (() -> Void)? = nil  // Delete message
    var onSelect: (() -> Void)? = nil  // Enter selection mode
    var onReport: (() -> Void)? = nil  // Report message
    var onBlock: (() -> Void)? = nil   // Block user
    var onQuickLike: (() -> Void)? = nil  // Double-tap quick like
    var onEdit: (() -> Void)? = nil       // Edit message
    var isGroupChat: Bool = false       // Whether this is a group chat
    var isChannel: Bool = false         // Whether this is a channel
    var isPrivateChannel: Bool = false
    var onPublish: ((String) -> Void)? = nil // Publish to feed
    var isFirstInBlock: Bool = true      // First message from this sender in block
    var isLastInBlock: Bool = true       // Last message from this sender in block
    var senderAvatarUrl: String? = nil   // Avatar URL for group sender
    var avatarNamespace: Namespace.ID? = nil  // For spring animation between blocks
    
    // Selection mode
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var groupId: String? = nil             // Group ID for group chats (used by transcription)
    
    // 🔴 FIX 4: Computed property instead of @State to avoid 500+ state wrappers for singleton
    private var appSettings: AppSettings { AppSettings.shared }
    
    // bubbleSize removed — was unused and caused layout thrashing via GeometryReader
    // ✅ Bug 3 fix: @GestureState auto-resets to 0 when gesture is cancelled by ScrollView
    @GestureState private var dragOffset: CGFloat = 0
    private let swipeThreshold: CGFloat = 60
    
    var body: some View {
        ZStack(alignment: isFromMe ? .trailing : .leading) {
            // Reply icon (appears when swiping)
            if abs(dragOffset) > 20 {
                HStack {
                    if isFromMe { Spacer() }
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.blue)
                        .opacity(min(1, abs(dragOffset) / swipeThreshold))
                        .scaleEffect(min(1, abs(dragOffset) / swipeThreshold))
                    if !isFromMe { Spacer() }
                }
                .padding(.horizontal, 24)
            }
            
            HStack(alignment: .bottom, spacing: 8) {
                // Selection checkbox (left side)
                if isSelectionMode {
                    Button {
                        onSelect?()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(isSelected ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            
            if isFromMe && !isSelectionMode { Spacer(minLength: 40) }
            
            // Group avatar (left of bubble, only for others' messages)
            // Pinned to LAST message in block (WhatsApp/Telegram style)
            if isGroupChat && !isChannel && !isFromMe {
                if isLastInBlock {
                    groupAvatarView
                } else {
                    // Invisible spacer to keep indent
                    Color.clear.frame(width: 28, height: 28)
                }
            }
            
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
                // Group sender name (only first message in block, others only)
                if isGroupChat && !isChannel && !isFromMe && isFirstInBlock {
                    Text(message.senderName.isEmpty ? "User" : message.senderName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(senderNameColor)
                        .padding(.leading, 4)
                }
                
                // Forwarded from Channel header
                if let forwardedChannelName = message.forwardedFromChannelName {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.right.fill")
                            .font(.system(size: 10))
                        Text("Forwarded from \(forwardedChannelName)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .padding(.bottom, 2)
                    .padding(.leading, isFromMe ? 0 : 4)
                    .padding(.trailing, isFromMe ? 4 : 0)
                }

                // Reply preview if exists
                if let replyPreview = message.safeDisplaySnippetForReply {
                    ReplyBubbleView(
                        senderName: message.replyToSenderName ?? "",
                        preview: replyPreview,
                        type: message.replyToType ?? .text,
                        isFromMe: isFromMe
                    )
                }
                
                // Main bubble
                HStack(alignment: .bottom, spacing: 4) {
                    // "edited" label
                    if message.editedAt != nil && !isMediaType {
                        Text("edited")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.7))
                            .italic()
                    }
                    // Content
                    contentView
                    
                    // Timestamp + delivery indicator (hidden for media types — they render their own)
                    if !isMediaType {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(message.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(timestampColor)
                            
                            // Status (only for my messages)
                            if isFromMe {
                                HStack(spacing: 2) {
                                    // Delivery authority dot
                                    Circle()
                                        .fill(deliveryColor)
                                        .frame(width: 4, height: 4)
                                    
                                    statusIcon
                                }
                                .font(.caption2)
                            }
                            
                            // ✅ Smart Expiry icon (glass style)
                            if let mode = message.expiryMode, mode != .none {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.7))
                            }
                        }
                    }
                }
                .padding(.horizontal, isMediaType ? 0 : 12)
                .padding(.vertical, isMediaType ? 0 : 8)
                .background(bubbleBackground)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: isMediaType ? 0 : ((!isFromMe && !isFirstInBlock) ? 4 : appSettings.messageCornerRadius),
                        bottomLeadingRadius: isMediaType ? 0 : ((!isFromMe && !isLastInBlock) ? 4 : appSettings.messageCornerRadius),
                        bottomTrailingRadius: isMediaType ? 0 : ((isFromMe && !isLastInBlock) ? 4 : appSettings.messageCornerRadius),
                        topTrailingRadius: isMediaType ? 0 : ((isFromMe && !isFirstInBlock) ? 4 : appSettings.messageCornerRadius),
                        style: .continuous
                    )
                )
                // Bug 4 fix: Removed unused bubbleSize GeometryReader that caused layout thrashing
                
                // Mesh delivery badge (only for mesh messages)
                MeshDeliveryBadge(message: message, isFromMe: isFromMe)
            }
            .onTapGesture(count: 2) {
                if !isFromMe {
                    Haptics.medium()
                    onQuickLike?()
                }
            }
            .contextMenu {
                Section {
                    Button {
                        onReply()
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    
                    // ✅ Only show Forward if message allows it (not deleteIfForwarded)
                    if message.allowForward {
                        if !isChannel || !isPrivateChannel {
                            Button {
                                onForward?()
                            } label: {
                                Label("Forward", systemImage: "arrowshape.turn.up.right")
                            }
                            
                            if isChannel {
                                Button {
                                    onPublish?("local")
                                } label: {
                                    Label("Publish to Local", systemImage: "globe")
                                }
                                Button {
                                    onPublish?("friends")
                                } label: {
                                    Label("Publish to Friends", systemImage: "person.2")
                                }
                            }
                        } else {
                            // Private channel: Forward/Publish disabled entirely
                            Text("Forwarding disabled in private channels")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    
                    Button {
                        onSelect?()
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    
                    if message.status == .failed {
                        Button {
                            onRetry()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                    }
                    
                    // Edit button (only for sender's own text messages)
                    if isFromMe && message.type == .text {
                        Button {
                            onEdit?()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                    
                    // Delete button (only show for sender's own messages)
                    if isFromMe {
                        Button(role: .destructive) {
                            onDelete?()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    
                    // Report & Block (only for other user's messages)
                    if !isFromMe {
                        Section {
                            Button {
                                Haptics.light()
                                onReport?()
                            } label: {
                                Label("Report Message", systemImage: "exclamationmark.triangle")
                            }
                            
                            if !isGroupChat {
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    onBlock?()
                                } label: {
                                    Label("Block User", systemImage: "person.fill.xmark")
                                }
                            }
                        }
                    }
                }
            } preview: {
                // Preview: show just the bubble
                contentView
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: (!isFromMe && !isFirstInBlock) ? 4 : appSettings.messageCornerRadius,
                            bottomLeadingRadius: (!isFromMe && !isLastInBlock) ? 4 : appSettings.messageCornerRadius,
                            bottomTrailingRadius: (isFromMe && !isLastInBlock) ? 4 : appSettings.messageCornerRadius,
                            topTrailingRadius: (isFromMe && !isFirstInBlock) ? 4 : appSettings.messageCornerRadius,
                            style: .continuous
                        )
                    )
                    .padding(12)
            }
            
            if !isFromMe { Spacer(minLength: isGroupChat ? 40 : 60) }
        }
        // ✅ Bug 3+4 fix: offset & gesture on HStack only (not ZStack), using @GestureState
        .offset(x: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 20)
                .updating($dragOffset) { value, state, _ in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    // Fix: only activate on horizontal swipe (abs(dx) > abs(dy)) to avoid scroll jitter
                    if abs(dx) > abs(dy) && dx < 0 && !isSelectionMode {
                        state = max(dx, -(swipeThreshold + 20))
                    }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) > abs(dy) && dx <= -swipeThreshold {
                        Haptics.light()
                        onReply()
                    }
                }
        )
        } // Close ZStack
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
    }
    
    // MARK: - Content
    
    // Detect mistyped postShare messages stored as .text
    private var effectiveType: MessageType {
        if message.type == .text,
           let text = message.text,
           text.contains("\"postId\""),
           text.contains("\"authorUsername\""),
           PostSharePayload.decode(from: text) != nil {
            return .postShare
        }
        return message.type
    }
    
    @ViewBuilder
    var contentView: some View {
        switch effectiveType {
        case .text:
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 6) {
                // Message text - with mention highlighting
                mentionHighlightedText
                
                // Link preview if URL detected (only if text is readable)
                if !displayableText.starts(with: "[") && displayableText.count > 0,
                   let url = message.text?.firstURL {
                    LinkPreviewCard(url: url) {
                        onLinkTap?(url)
                    }
                }
            }
            
        case .image:
            ImageMessageView(message: message, onTap: onImageTap)
            
        case .voice:
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 6) {
                VoiceMessageView(
                    message: message,
                    isFromMe: isFromMe,
                    deliveryAuthority: message.deliveryAuthority,
                    statusIcon: isFromMe ? statusIcon : nil
                )
                
                // Transcription chip — glass style below capsule
                if let serverId = message.serverId ?? (message.id.count > 8 ? message.id : nil) {
                    TranscriptPill(
                        contentId: serverId,
                        contentType: .message(isGroup: isGroupChat, groupId: groupId)
                    )
                }
            }
            
        case .file:
            FileMessageView(message: message, isFromMe: isFromMe, onFileTap: onFileTap)
            
        case .video, .videoNote, .ephemeralPhoto:
            // These features have been removed — hide old messages
            EmptyView()
            
        case .location:
            LocationMessageView(message: message, isFromMe: isFromMe, onTap: onLocationTap)
            
        case .postShare:
            PostShareMessageView(message: message, isFromMe: isFromMe)
            
        case .system:
            // System notification — luxury glass capsule, text-only
            SystemEventBubble(
                text: message.text ?? "Notification",
                timestamp: message.timestamp
            )
        }
    }
    // MARK: - Styling
    
    /// Whether this message is a media type that renders its own glass card (no outer bubble)
    private var isMediaType: Bool {
        message.type == .voice || message.type == .video || message.type == .videoNote || message.type == .ephemeralPhoto || message.type == .postShare
    }
    
    var bubbleBackground: some ShapeStyle {
        // Media & image & location messages get clear background (styled separately)
        if message.type == .image || message.type == .location || message.type == .ephemeralPhoto || isMediaType {
            return AnyShapeStyle(Color.clear)
        }
        
        // Scheduled messages show as transparent ghost bubbles
        let isScheduled = message.status == .scheduled
        let opacity = isScheduled ? 0.4 : 1.0
        
        if isFromMe {
            // Dynamic color based on delivery authority
            // 🔵 Blue = Server, 🟣 Purple = Mesh, ⚪ Gray = Unknown/Pending
            let baseColor: Color = switch message.deliveryAuthority {
            case .server: .blue
            case .mesh: .purple
            case .unknown: .gray
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [baseColor, baseColor.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).opacity(opacity)
            )
        } else {
            // Received message: gray background
            return AnyShapeStyle(
                Color(.systemGray6).opacity(opacity)
            )
        }
    }
    
    private var isClearBackground: Bool {
        message.type == .image || message.type == .location || isMediaType
    }

    private var timestampColor: Color {
        if isFromMe {
            return isClearBackground ? .secondary : .white.opacity(0.7)
        } else {
            return .secondary
        }
    }

    // MARK: - Delivery Color (🔵 Server, 🟣 Mesh, ⚪ Unknown)
    
    var deliveryColor: Color {
        if isFromMe && isClearBackground {
            return message.deliveryAuthority == .mesh ? .purple.opacity(0.8) : .blue.opacity(0.8)
        } else {
            switch message.deliveryAuthority {
            case .unknown: return .gray
            case .server: return .blue
            case .mesh: return .purple
            }
        }
    }
    
    // MARK: - Group Avatar
    
    @ViewBuilder
    private var groupAvatarView: some View {
        Group {
            if let url = AppConfig.mediaURL(from: senderAvatarUrl) {
                // ⚡ Perf fix: CachedAsyncImage has RAM cache; AsyncImage re-downloads on every scroll
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    senderInitialsCircle
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            } else {
                senderInitialsCircle
            }
        }
        // Glass styling: thin border + soft shadow
        .overlay {
            Circle()
                .strokeBorder(senderNameColor.opacity(0.3), lineWidth: 1)
                .frame(width: 28, height: 28)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
    
    private var senderInitialsCircle: some View {
        Circle()
            .fill(senderNameColor.opacity(0.2))
            .frame(width: 28, height: 28)
            .overlay {
                Text(String(message.senderName.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(senderNameColor)
            }
    }
    
    // MARK: - Sender Name Color (deterministic from senderId)
    
    private var senderNameColor: Color {
        let colors: [Color] = [
            .blue, .purple, .orange, .pink,
            .teal, .green, .indigo, .red
        ]
        let hash = message.senderId.hashValue
        return colors[abs(hash % colors.count)]
    }
    
    // MARK: - Scheduled Badge
    
    var isScheduled: Bool {
        message.status == .scheduled
    }
    
    // MARK: - Status Icon
    
    @ViewBuilder
    var statusIcon: some View {
        let baseColor = isClearBackground ? Color.secondary : Color.white.opacity(0.7)
        let doneColor = isClearBackground ? Color.primary : Color.white
        let readColor = isClearBackground ? Color.blue : Color.white
        
        switch message.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(baseColor)
        case .sending:
            ProgressView()
                .scaleEffect(0.6)
                .tint(baseColor)
        case .forwarding:
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch")
                ProgressView()
                    .scaleEffect(0.5)
                    .tint(.purple)
            }
            .foregroundStyle(.purple)
        case .accepted:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(baseColor)
        case .sent:
            Image(systemName: "checkmark")
                .foregroundStyle(baseColor)
        case .delivered:
            Image(systemName: "checkmark")
                .foregroundStyle(doneColor)
        case .read:
            HStack(spacing: -4) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .foregroundStyle(readColor)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .scheduled:
            HStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                if let scheduledAt = message.scheduledAtUtc {
                    Text("at \(scheduledAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.orange)
        }
    }
    
    // MARK: - Displayable Text (filters encrypted content)
    var displayableText: String {
        guard let text = message.text, !text.isEmpty else {
            return ""
        }
        // Filter out encrypted/base64 content
        if text.hasPrefix("gAAAA") || text.hasPrefix("eyJ") {
            return "[Encrypted]"
        }
        return text
    }
    
    // MARK: - Mention-Highlighted Text
    
    @ViewBuilder
    var mentionHighlightedText: some View {
        let text = displayableText
        
        if let entities = message.entities, !entities.isEmpty, !text.isEmpty {
            // Build attributed string with mention highlights
            Text(buildMentionAttributedString(text: text, entities: entities))
                .font(.subheadline)
        } else {
            // Plain text (no mentions)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(isFromMe ? .white : .primary)
        }
    }
    
    private func buildMentionAttributedString(text: String, entities: [MentionEntity]) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = isFromMe ? .white : .primary
        
        // Sort entities by rangeStart (descending to preserve indices)
        let sorted = entities.sorted { $0.rangeStart > $1.rangeStart }
        
        for entity in sorted {
            let start = entity.rangeStart
            let length = entity.rangeLength
            
            // ✅ Bug 6 fix: Server sends UTF-16 offsets, but Swift's String.Index counts
            // Character clusters. Emojis (e.g. 👨‍👩‍👧‍👦) are 1 Character but multiple UTF-16 units,
            // causing offsetBy to overshoot and crash with "String index is out of bounds".
            let utf16 = text.utf16
            guard start >= 0, start + length <= utf16.count else { continue }
            guard let utf16Start = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
                  let utf16End = utf16.index(utf16Start, offsetBy: length, limitedBy: utf16.endIndex),
                  let startIdx = String.Index(utf16Start, within: text),
                  let endIdx = String.Index(utf16End, within: text) else { continue }
            
            // Find the corresponding range in AttributedString
            guard let attrStart = AttributedString.Index(startIdx, within: attributed),
                  let attrEnd = AttributedString.Index(endIdx, within: attributed) else {
                continue
            }
            
            // Style the mention
            attributed[attrStart..<attrEnd].foregroundColor = isFromMe ? .cyan : .blue
            attributed[attrStart..<attrEnd].font = .subheadline.bold()
        }
        
        return attributed
    }
}

// MARK: - Bubble Shape
struct BubbleShape: Shape {
    let isFromMe: Bool
    var cornerRadius: CGFloat = AppSettings.shared.messageCornerRadius
    
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = cornerRadius
        let tailSize: CGFloat = 6
        
        var path = Path()
        
        if isFromMe {
            path.addRoundedRect(
                in: CGRect(x: 0, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
        } else {
            path.addRoundedRect(
                in: CGRect(x: tailSize, y: 0, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
        }
        
        return path
    }
}

// MARK: - Reply Bubble (inside message)
struct ReplyBubbleView: View {
    let senderName: String
    let preview: String
    let type: MessageType
    var isFromMe: Bool = false
    
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(isFromMe ? Color.white.opacity(0.6) : .blue)
                .frame(width: 3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(senderName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(isFromMe ? .white : .blue)
                
                Text(safePreviewText)
                    .font(.caption)
                    .foregroundStyle(isFromMe ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(isFromMe ? Color.white.opacity(0.2) : Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    /// Safe preview text with DEFENSE-IN-DEPTH encryption filtering
    private var safePreviewText: String {
        let text = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // DEBUG: Log what we receive
        #if DEBUG
        print("🔍 [REPLY_BUBBLE] Received preview: '\(text.prefix(40))...' (len=\(text.count), type=\(type.rawValue))")
        #endif
        
        // Defense-in-Depth: Filter encrypted content even if upstream missed it
        if text.hasPrefix("gAAAA") || text.hasPrefix("eyJ") {
            let fallback = typeFallback
            #if DEBUG
            print("🔍 [REPLY_BUBBLE] ⚠️ ENCRYPTED DETECTED! Using fallback: \(fallback)")
            #endif
            return fallback
        }
        
        // Long blob without spaces
        if !text.contains(" ") && text.count > 100 {
            let fallback = typeFallback
            #if DEBUG
            print("🔍 [REPLY_BUBBLE] ⚠️ BLOB DETECTED! Using fallback: \(fallback)")
            #endif
            return fallback
        }
        
        // Normal text - just truncate
        return String(text.prefix(50))
    }
    
    private var typeFallback: String {
        switch type {
        case .voice: return "🎤 Voice message"
        case .image: return "📷 Photo"
        case .video: return "🎬 Video"
        case .videoNote: return "🎥 Video note"
        case .ephemeralPhoto: return "📸 RaveShot"
        case .file: return "📎 File"
        case .location: return "📍 Location"
        case .postShare: return "📬 Shared post"
        case .text: return "Message"
        case .system: return "📢 Notification"
        }
    }
}

// MARK: - Reply Preview (Compact Liquid Glass Capsule above input)
struct ReplyPreviewView: View {
    let message: ChatMessage
    let onCancel: () -> Void
    
    /// Smart height: 52pt default, 72pt for long text, max 84pt
    private var targetHeight: CGFloat {
        // Voice/File = always compact
        if message.type == .voice || message.type == .file || message.type == .image {
            return 52
        }
        // Long text = slightly taller
        if replyPreviewText.count > 60 {
            return 72
        }
        return 52
    }
    
    /// Type icon for message
    private var typeIcon: String {
        switch message.type {
        case .voice: return "mic.fill"
        case .image: return "photo.fill"
        case .video: return "video.fill"
        case .videoNote: return "video.circle.fill"
        case .ephemeralPhoto: return "camera.fill"
        case .file: return "doc.fill"
        case .location: return "location.fill"
        case .postShare: return "square.and.arrow.up.fill"
        case .text: return "text.bubble.fill"
        case .system: return "bell.fill"
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Reply arrow icon
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            
            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Sender name
                Text(safeSenderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue.opacity(0.95))
                    .lineLimit(1)
                
                // Type icon + preview text
                HStack(spacing: 6) {
                    Image(systemName: typeIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    Text(replyPreviewText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(targetHeight > 60 ? 2 : 1)
                        .truncationMode(.tail)
                }
            }
            
            Spacer()
            
            // Close button
            Button {
                Haptics.light()
                onCancel()
            } label: {
                ZStack {
                    Circle()
                        .fill(.primary.opacity(0.08))
                        .frame(width: 28, height: 28)
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: targetHeight)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(.primary.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: targetHeight)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity),
            removal: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
        ))
    }
    
    // MARK: - Safe Preview Text
    
    private var replyPreviewText: String {
        let text = message.safeReplySnippet
        
        // Filter encrypted content
        if text.hasPrefix("gAAAA") || text.hasPrefix("eyJ") {
            return typeFallback(for: message.type)
        }
        if !text.contains(" ") && text.count > 100 {
            return typeFallback(for: message.type)
        }
        
        return text
    }
    
    private func typeFallback(for type: MessageType) -> String {
        switch type {
        case .voice: return "Voice message"
        case .image: return "Photo"
        case .video: return "Video"
        case .videoNote: return "Video note"
        case .ephemeralPhoto: return "RaveShot"
        case .file: return "File"
        case .location: return "Location"
        case .postShare: return "Shared post"
        case .text: return "Message"
        case .system: return "Notification"
        }
    }
    
    private var safeSenderName: String {
        let name = message.senderName
        if name.hasPrefix("gAAAA") || name.hasPrefix("eyJ") { return "User" }
        if !name.contains(" ") && name.count > 50 { return "User" }
        return name
    }
}

// MARK: - Edit Preview View (banner above input when editing)
struct EditPreviewView: View {
    let message: ChatMessage
    let onCancel: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Edit icon
            Image(systemName: "pencil")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
            
            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text("Editing Message")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.95))
                    .lineLimit(1)
                
                Text(message.text ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            Spacer()
            
            // Close button
            Button {
                Haptics.light()
                onCancel()
            } label: {
                ZStack {
                    Circle()
                        .fill(.primary.opacity(0.08))
                        .frame(width: 28, height: 28)
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(.orange.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)
        .padding(.horizontal, 16)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity),
            removal: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity)
        ))
    }
}

// MARK: - Chat Input Bar (Floating Liquid Glass)
struct ChatInputBar: View {
    @Binding var text: String
    var isRecordingVoice: Bool = false
    let onSend: () -> Void
    let onAttachment: () -> Void
    var onCaptureTap: (() -> Void)? = nil

    var scheduledAt: Date? = nil
    var onCancelSchedule: (() -> Void)? = nil
    

    
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var isRecording: Bool {
        isRecordingVoice
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Scheduled message banner
            if let scheduled = scheduledAt {
                ScheduledMessageBanner(
                    scheduledAt: scheduled,
                    onEdit: { },
                    onCancel: { onCancelSchedule?() }
                )
            }
            
            // ✅ Clean Liquid Glass Composer: + | TextField | Capture/Send
            HStack(spacing: 10) {
                
                // LEFT: Attachment button (+ icon) - Glass circle
                Button {
                    Haptics.light()
                    onAttachment()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.8))
                
                // CENTER: Glass TextField Capsule
                HStack(spacing: 8) {
                    TextField("Write a message…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .textInputAutocapitalization(.sentences)
                    
                    // Optional: clear button (only when typing)
                    if canSend {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.8))
                
                // RIGHT: Send (when text) or unified Capture button (when empty)
                if canSend {
                    // Send button
                    Button {
                        Haptics.medium()
                        onSend()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.blue.gradient))
                    }
                    .buttonStyle(.plain)
                } else {
                    // ✅ Unified Capture button (Voice / Video)
                    // Double-tap = switch mode, Single-tap = activate
                    captureButton
                }
            }
            .animation(.spring(response: 0.3), value: canSend)
        }
    }
    
    // MARK: - Voice Capture Button
    
    private var captureButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(
                Circle().stroke(
                    Color.primary.opacity(0.10),
                    lineWidth: 0.8
                )
            )
            .onTapGesture(count: 1) {
                Haptics.medium()
                onCaptureTap?()
            }
    }
}

// MARK: - Scheduled Message Banner
struct ScheduledMessageBanner: View {
    let scheduledAt: Date
    let onEdit: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.purple)
            
            Text("Scheduled • \(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Button("Edit") { onEdit() }
                .font(.caption)
                .foregroundStyle(.blue)
            
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.6))
        .clipShape(Capsule())
    }
}

// MARK: - Chat Header (Name Center, Avatar Right)
struct ChatHeaderView: View {
    let peer: Conversation.Peer
    var onAvatarTap: (() -> Void)? = nil
    var isOnline: Bool = false
    var lastSeen: Date? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            // Spacer for balance
            Spacer()
                .frame(width: 36)
            
            Spacer()
            
            // Center: Name + Status
            VStack(spacing: 2) {
                Text(peer.displayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(isOnline ? .green : .secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Right: Avatar (Tappable -> Shared Media)
            Button {
                Haptics.light()
                onAvatarTap?()
            } label: {
                GlassAvatar(
                    name: peer.displayName,
                    path: peer.avatarPath,
                    size: 36,
                    showGlow: false,
                    showOnlineIndicator: isOnline
                )
            }
            .buttonStyle(.plain)
        }
    }
    
    private var statusText: String {
        if isOnline {
            return "online"
        } else if let lastSeen = lastSeen {
            return "last seen \(lastSeen.formatted(.relative(presentation: .named)))"
        } else {
            return "offline"
        }
    }
}

// MARK: - Placeholder Media Views

struct ImageMessageView: View {
    let message: ChatMessage
    var onTap: ((URL) -> Void)? = nil
    
    // ⚡ Perf fix: resolve URL asynchronously to avoid sync FileManager.fileExists on main thread
    @State private var resolvedImageURL: URL?
    @State private var isResolved = false
    
    var body: some View {
        Group {
            if isResolved {
                if let imageURL = resolvedImageURL {
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onTap?(imageURL)
                    } label: {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: 260, maxHeight: 320)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                    )
                                
                            case .failure:
                                placeholderView(icon: "photo.badge.exclamationmark")
                                
                            case .empty:
                                placeholderView(icon: "photo", showProgress: message.syncState == .uploading)
                                
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .background(Color.clear)
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    placeholderView(icon: "photo", showProgress: message.syncState == .uploading)
                }
            } else {
                placeholderView(icon: "photo", showProgress: true)
            }
        }
        .task(id: message.id) {
            // ⚡ Resolve URL on a background thread to avoid blocking scroll
            guard !isResolved else { return }
            resolvedImageURL = await resolveURL()
            withAnimation { isResolved = true }
        }
    }
    
    private func resolveURL() async -> URL? {
        return await Task.detached(priority: .userInitiated) {
            // Offline-first: prefer local cache
            if let localPath = message.localPath, !localPath.isEmpty {
                let fileName = URL(fileURLWithPath: localPath).lastPathComponent
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let currentLocalURL = docs.appendingPathComponent("attachments").appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: currentLocalURL.path) {
                    return currentLocalURL
                }
            }
            // Fallback: remote server
            return AppConfig.mediaURL(from: message.attachmentUrl)
        }.value
    }
    
    @ViewBuilder
    private func placeholderView(icon: String, showProgress: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color(.systemGray5))
            .frame(width: 200, height: 200)
            .overlay {
                if showProgress {
                    ProgressView()
                        .tint(.secondary)
                } else {
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
    }
}

struct VoiceMessageView<StatusIcon: View>: View {
    let message: ChatMessage
    let isFromMe: Bool
    var deliveryAuthority: DeliveryAuthority = .server
    var statusIcon: StatusIcon?
    
    // ⚡ Perf fix: Use @State to prevent @Observable from triggering re-renders on ALL voice views
    @State private var audioStore = AudioPlaybackStore.shared
    @State private var waveformBars: [CGFloat] = (0..<20).map { _ in CGFloat.random(in: 0.15...1.0) }
    @State private var repairedUrl: String?
    @State private var isRepairAttempted = false
    
    // ⚡ Local playback state — only updated for the actively playing message
    @State private var localIsPlaying: Bool = false
    @State private var localProgress: Double = 0
    @State private var localCurrentTime: TimeInterval = 0
    @State private var progressTimer: Timer? = nil
    
    // ⚡ Async URL resolution (avoids sync FileManager.fileExists on main thread)
    @State private var voiceUrlString: String?
    @State private var isUrlResolved = false
    
    private var duration: Int {
        message.audioDurationSeconds ?? 0
    }
    
    private var formattedDuration: String {
        // Bug 1 fix: show "--:--" instead of downloading the file just to read duration
        guard duration > 0 else { return "--:--" }
        let mins = duration / 60
        let secs = duration % 60
        return mins > 0 ? "\(mins):\(String(format: "%02d", secs))" : "\(secs)s"
    }
    
    /// Accent color for played portion of waveform
    private var accentColor: Color {
        switch deliveryAuthority {
        case .server: return .blue
        case .mesh: return .purple
        case .unknown: return .gray
        }
    }
    
    var body: some View {
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
            // MARK: - Glass Capsule
            HStack(spacing: 10) {
                // Play/Pause button — glass circle
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: localIsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                
                // Modern waveform visualization — smooth rounded bars
                HStack(spacing: 2) {
                    ForEach(0..<waveformBars.count, id: \.self) { index in
                        let barHeight = waveformBars[index]
                        let isPlayed = CGFloat(index) / CGFloat(waveformBars.count) < CGFloat(localProgress)
                        
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isPlayed ? accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 2.5, height: 18 * barHeight)
                            .animation(.easeInOut(duration: 0.15), value: localProgress)
                    }
                }
                .frame(height: 22)
                
                // Duration
                Text(localIsPlaying ? formatTime(localCurrentTime) : formattedDuration)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            
            // MARK: - Timestamp + Status pill (below capsule)
            HStack(spacing: 4) {
                Text(message.timestamp, style: .time)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.7))
                
                if let statusIcon = statusIcon {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(accentColor.opacity(0.6))
                            .frame(width: 3, height: 3)
                        statusIcon
                            .font(.system(size: 10))
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .task(id: message.id) {
            // ⚡ Resolve voice URL on background thread
            if !isUrlResolved {
                voiceUrlString = await resolveVoiceURL()
                isUrlResolved = true
            }
            
            // On-demand repair: if voice message has no URL, fetch it from server
            if voiceUrlString == nil && !isRepairAttempted {
                isRepairAttempted = true
                #if DEBUG
                print("🔧 [VoiceMessageView] No URL for \(message.id.prefix(8)), attempting repair...")
                print("   message.attachmentUrl: \(message.attachmentUrl ?? "nil")")
                print("   message.text: \(message.text?.prefix(80) ?? "nil")")
                print("   message.localPath: \(message.localPath ?? "nil")")
                print("   message.serverId: \(message.serverId ?? "nil")")
                #endif
                
                guard NetworkMonitor.shared.isOnline else { return }
                let targetId = message.serverId ?? message.id
                let roomId = message.roomId ?? message.senderId
                
                // Step 1: Try direct message lookup (most efficient)
                do {
                    let msg: APIMessageResponse = try await NetworkService.shared.get(
                        path: "/api/messages/lookup/\(targetId)"
                    )
                    let url = msg.audioUrl ?? msg.mediaUrl ?? msg.fileUrl ?? msg.imageUrl ?? msg.voiceUrl
                    if let url = url {
                        try? await MessageRepository.shared.backfillRemoteUrl(serverId: targetId, remoteUrl: url, audioDuration: msg.audioDurationSeconds ?? msg.audioDuration)
                        repairedUrl = url
                        voiceUrlString = url
                        #if DEBUG
                        print("✅ [VoiceMessageView] Repair via lookup: \(url.prefix(60))")
                        #endif
                        return
                    } else {
                        #if DEBUG
                        print("⚠️ [VoiceMessageView] Lookup returned msg but audio_url nil")
                        #endif
                        // Also check content field for URL
                        if let content = msg.content, !content.isEmpty,
                           (content.hasPrefix("http") || content.hasPrefix("/uploads/") || content.hasPrefix("/api/uploads/")) {
                            try? await MessageRepository.shared.backfillRemoteUrl(serverId: targetId, remoteUrl: content, audioDuration: msg.audioDurationSeconds ?? msg.audioDuration)
                            repairedUrl = content
                            voiceUrlString = content
                            #if DEBUG
                            print("✅ [VoiceMessageView] Repair via content field: \(content.prefix(60))")
                            #endif
                            return
                        }
                    }
                } catch {
                    #if DEBUG
                    print("⚠️ [VoiceMessageView] Lookup failed (404?), trying conversation fetch: \(error)")
                    #endif
                }
                
                // Step 2: Fallback — fetch conversation messages
                do {
                    let apiMessages: [APIMessageResponse] = try await NetworkService.shared.get(
                        path: "/api/messages/conversation/\(roomId)",
                        queryItems: [URLQueryItem(name: "limit", value: "100")]
                    )
                    
                    if let msg = apiMessages.first(where: { $0.id == targetId }) {
                        let url = msg.audioUrl ?? msg.mediaUrl ?? msg.fileUrl ?? msg.imageUrl ?? msg.voiceUrl
                        if let url = url {
                            try? await MessageRepository.shared.backfillRemoteUrl(serverId: targetId, remoteUrl: url, audioDuration: msg.audioDurationSeconds ?? msg.audioDuration)
                            repairedUrl = url
                            voiceUrlString = url
                            #if DEBUG
                            print("✅ [VoiceMessageView] Repair via conversation: \(url.prefix(60))")
                            #endif
                        } else {
                            #if DEBUG
                            print("⚠️ [VoiceMessageView] Server returned msg but ALL url fields nil for \(targetId.prefix(8))")
                            #endif
                        }
                    } else {
                        #if DEBUG
                        print("⚠️ [VoiceMessageView] Voice msg \(targetId.prefix(8)) not found in \(apiMessages.count) conversation messages")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("❌ [VoiceMessageView] Repair fetch failed: \(error)")
                    #endif
                }
            }
        }
        // ⚡ Sync local state only when the active item changes
        .onChange(of: audioStore.currentItem?.id) { _, newId in
            let targetId = message.serverId ?? message.id
            let shouldPlay = (newId == targetId) && audioStore.isPlaying
            if shouldPlay != localIsPlaying { localIsPlaying = shouldPlay }
            if !shouldPlay { stopProgressTimer(); localProgress = 0; localCurrentTime = 0 }
            else { startProgressTimer() }
        }
        .onChange(of: audioStore.isPlaying) { _, playing in
            let targetId = message.serverId ?? message.id
            let shouldPlay = playing && audioStore.currentItem?.id == targetId
            if shouldPlay != localIsPlaying { localIsPlaying = shouldPlay }
            if shouldPlay { startProgressTimer() } else { stopProgressTimer() }
        }
        .onDisappear { stopProgressTimer() }
        // Bug 1 fix: NO preloadDuration() call — no downloads on appear
        // Bug 2 fix: NO .onDisappear { stopPlayback() } — audio continues while scrolling
    }
    
    // ⚡ Poll audioStore only for the actively playing message (10Hz)
    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                let targetId = message.serverId ?? message.id
                guard audioStore.currentItem?.id == targetId else {
                    stopProgressTimer(); return
                }
                localProgress = audioStore.progress
                localCurrentTime = audioStore.currentTime
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    private func resolveVoiceURL() async -> String? {
        return await Task.detached(priority: .userInitiated) {
            if let localPath = message.localPath, !localPath.isEmpty {
                let fileName = URL(fileURLWithPath: localPath).lastPathComponent
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let localURL = docs.appendingPathComponent("attachments").appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: localURL.path) { return localURL.absoluteString }
            }
            if let urlString = message.attachmentUrl, !urlString.isEmpty { return urlString }
            if let text = message.text, !text.isEmpty,
               (text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("/uploads/") || text.hasPrefix("/api/uploads/")) {
                return text
            }
            return nil
        }.value
    }
    
    private func togglePlayback() {
        Haptics.light()
        
        guard let urlString = voiceUrlString else {
            #if DEBUG
            print("❌ No audio URL for voice message \(message.id.prefix(8))")
            #endif
            return
        }
        
        // Create AudioItem and delegate to centralized store
        // AudioPlaybackStore.play() automatically stops any previous playback
        let item = AudioItem(
            id: message.id,
            voiceUrl: urlString,
            duration: duration,
            waveform: nil,
            senderName: message.senderName.looksEncrypted ? "Voice Message" : message.senderName,
            senderAvatar: nil,
            contentId: message.serverId ?? message.id,
            contentType: "dm"
        )
        audioStore.play(item: item)
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}

struct FileMessageView: View {
    let message: ChatMessage
    let isFromMe: Bool
    var onFileTap: ((URL, String?) -> Void)? = nil
    
    @State private var repairedUrl: String?
    @State private var isRepairAttempted = false
    
    private var isPDF: Bool {
        // Check MIME type first
        if message.mimeType?.lowercased() == "application/pdf" {
            return true
        }
        // Check filename
        if message.fileName?.lowercased().hasSuffix(".pdf") == true {
            return true
        }
        // Fallback: check attachment URL for .pdf extension
        if let urlString = (message.attachmentUrl ?? repairedUrl)?.lowercased(),
           urlString.contains(".pdf") {
            return true
        }
        return false
    }
    
    // ⚡ Perf fix: resolve file URL asynchronously to avoid sync FileManager.fileExists on main thread
    @State private var resolvedFileURL: URL?
    @State private var isFileUrlResolved = false
    
    private func resolveFileURL() async -> URL? {
        return await Task.detached(priority: .userInitiated) {
            // 1. Local cache (works offline, faster)
            if let localPath = message.localPath, !localPath.isEmpty {
                let fileName = URL(fileURLWithPath: localPath).lastPathComponent
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let localURL = docs.appendingPathComponent("attachments").appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: localURL.path) {
                    return localURL
                }
            }
            // 2. Remote URL from message
            if let url = AppConfig.mediaURL(from: message.attachmentUrl) {
                return url
            }
            // 3. Repaired URL (fetched on-demand from server)
            if let url = AppConfig.mediaURL(from: repairedUrl) {
                return url
            }
            return nil
        }.value
    }
    
    private var displayFileName: String {
        // Try to get filename from message
        if let fileName = message.fileName, !fileName.isEmpty, !looksLikeUUID(fileName) {
            if isPDF && !fileName.lowercased().hasSuffix(".pdf") {
                return fileName + ".pdf"
            }
            return fileName
        }
        // Fallback: extract from URL (but filter UUIDs)
        if let urlString = message.attachmentUrl ?? repairedUrl,
           let url = URL(string: urlString) {
            let lastComponent = url.lastPathComponent
            if !lastComponent.isEmpty && lastComponent != "/" && !looksLikeUUID(lastComponent) {
                if isPDF && !lastComponent.lowercased().hasSuffix(".pdf") {
                    return lastComponent + ".pdf"
                }
                return lastComponent
            }
        }
        return isPDF ? "Document.pdf" : "Document"
    }
    
    /// Check if string looks like a UUID (e.g., "6a6a9b00-7f52-4e13-913...")
    private func looksLikeUUID(_ str: String) -> Bool {
        // UUID pattern: 8-4-4-4-12 hex chars with dashes, or partial UUID
        let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}"
        return str.range(of: uuidPattern, options: .regularExpression) != nil
    }
    
    var body: some View {
        Button {
            guard let url = resolvedFileURL else {
                #if DEBUG
                print("⚠️ [FileMessageView] No valid attachment URL: \(message.attachmentUrl ?? "nil"), localPath: \(message.localPath ?? "nil"), repaired: \(repairedUrl ?? "nil")")
                #endif
                return
            }
            
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            
            // QuickLook supports all document types (PDF, Office, images, video, zip, etc.)
            #if DEBUG
            print("📄 [FileMessageView] Opening document: \(url)")
            #endif
            onFileTap?(url, displayFileName)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isPDF ? "doc.richtext.fill" : "doc.fill")
                    .font(.title2)
                    .foregroundStyle(isFromMe ? .white : (isPDF ? .red : .blue))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayFileName)
                        .font(.subheadline)
                        .foregroundStyle(isFromMe ? .white : .primary)
                        .lineLimit(1)
                    
                    if let size = message.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(isFromMe ? .white.opacity(0.7) : .secondary)
                    } else if isPDF {
                        Text("Tap to view")
                            .font(.caption)
                            .foregroundStyle(isFromMe ? .white.opacity(0.7) : .secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: message.id) {
            // ⚡ Resolve file URL on background thread
            if !isFileUrlResolved {
                resolvedFileURL = await resolveFileURL()
                isFileUrlResolved = true
            }
            
            // On-demand repair: if file message has no URL, fetch from server
            if resolvedFileURL == nil && !isRepairAttempted {
                isRepairAttempted = true
                #if DEBUG
                print("🔧 [FileMessageView] No URL for file msg \(message.id.prefix(8)), attempting repair...")
                print("   attachmentUrl: \(message.attachmentUrl ?? "nil")")
                print("   localPath: \(message.localPath ?? "nil")")
                print("   serverId: \(message.serverId ?? "nil")")
                print("   roomId: \(message.roomId ?? "nil")")
                print("   senderId: \(message.senderId)")
                print("   recipientId: \(message.recipientId)")
                #endif
                
                guard NetworkMonitor.shared.isOnline else {
                    #if DEBUG
                    print("⚠️ [FileMessageView] Offline — skipping repair")
                    #endif
                    return
                }
                let targetId = message.serverId ?? message.id
                let roomId = message.roomId ?? message.senderId
                
                // Detect group vs 1:1: group messages have roomId ≠ senderId AND roomId ≠ recipientId
                let isGroup = message.roomId != nil
                    && message.roomId != message.senderId
                    && message.roomId != message.recipientId
                
                do {
                    var repairedUrlValue: String?
                    
                    if isGroup {
                        // Group messages: fetch from /api/groups/{groupId}/messages
                        #if DEBUG
                        print("🔧 [FileMessageView] Using GROUP repair endpoint for roomId: \(roomId.prefix(8))")
                        #endif
                        let groupMessages: [GroupMessageResponse] = try await NetworkService.shared.get(
                            path: "/api/groups/\(roomId)/messages",
                            queryItems: [URLQueryItem(name: "limit", value: "50")]
                        )
                        if let gm = groupMessages.first(where: { $0.id == targetId }) {
                            repairedUrlValue = gm.audioUrl ?? gm.mediaUrl ?? gm.fileUrl ?? gm.imageUrl ?? gm.voiceUrl
                        } else {
                            #if DEBUG
                            print("⚠️ [FileMessageView] File msg \(targetId.prefix(8)) not found in \(groupMessages.count) group messages")
                            #endif
                        }
                    } else {
                        // 1:1 messages: fetch from /api/messages/conversation/{peerId}
                        #if DEBUG
                        print("🔧 [FileMessageView] Using 1:1 repair endpoint for roomId: \(roomId.prefix(8))")
                        #endif
                        let apiMessages: [APIMessageResponse] = try await NetworkService.shared.get(
                            path: "/api/messages/conversation/\(roomId)",
                            queryItems: [URLQueryItem(name: "limit", value: "50")]
                        )
                        if let msg = apiMessages.first(where: { $0.id == targetId }) {
                            repairedUrlValue = msg.fileUrl ?? msg.mediaUrl ?? msg.audioUrl ?? msg.imageUrl ?? msg.voiceUrl
                        } else {
                            #if DEBUG
                            print("⚠️ [FileMessageView] File msg \(targetId.prefix(8)) not found in \(apiMessages.count) conversation messages")
                            #endif
                        }
                    }
                    
                    if let url = repairedUrlValue {
                        try? await MessageRepository.shared.backfillRemoteUrl(serverId: targetId, remoteUrl: url)
                        repairedUrl = url
                        #if DEBUG
                        print("✅ [FileMessageView] Repair succeeded: \(url.prefix(60))")
                        #endif
                    } else if repairedUrlValue == nil {
                        #if DEBUG
                        print("⚠️ [FileMessageView] Server returned msg but ALL url fields nil")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("❌ [FileMessageView] Repair fetch failed: \(error)")
                    #endif
                }
            }
        }
    }
}





struct LocationMessageView: View {
    let message: ChatMessage
    let isFromMe: Bool
    var onTap: ((LocationPayload) -> Void)? = nil
    
    private var payload: LocationPayload? {
        guard let text = message.text else { return nil }
        return LocationPayload.from(text)
    }
    
    var body: some View {
        if let payload = payload {
            LocationMessageCard(payload: payload, isFromMe: isFromMe, onTap: {
                onTap?(payload)
            })
        } else {
            // Fallback for corrupted/invalid location
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                
                Text("Location unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, height: 80)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Post Share Message View (Liquid Glass Capsule Card)
struct PostShareMessageView: View {
    let message: ChatMessage
    let isFromMe: Bool
    
    @State private var isExpanded = false
    
    private var payload: PostSharePayload? {
        guard let text = message.text else { return nil }
        // Filter out raw encrypted / failed-decrypt content
        if text.hasPrefix("gAAAA") || text.hasPrefix("eyJ") || text.contains("DECRYPT_FAILED") {
            return nil
        }
        return PostSharePayload.decode(from: text)
    }
    
    /// Delivery-based accent color
    private var accentColor: Color {
        switch message.deliveryAuthority {
        case .mesh: return .purple
        case .server: return .blue
        case .unknown: return .gray
        }
    }
    
    /// Status icon (sent messages only)
    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
        case .sent, .accepted:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accentColor.opacity(0.7))
        case .delivered:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accentColor)
        case .read:
            HStack(spacing: -3) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
            }
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(accentColor)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
    
    var body: some View {
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 4) {
            // ── Card ──
            VStack(alignment: .leading, spacing: 0) {
                // Header: "↪ Shared Post"
                HStack(spacing: 5) {
                    Image(systemName: "arrowshape.turn.up.forward.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Shared Post")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
                
                if let payload = payload {
                    // ── Author row ──
                    HStack(spacing: 8) {
                        // Avatar circle with gradient
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            accentColor.opacity(0.5),
                                            accentColor.opacity(0.25)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Text(String(payload.authorUsername.prefix(1)).uppercased())
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 26, height: 26)
                        
                        Text("@\(payload.authorUsername)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accentColor)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    
                    // ── Post content (full, no truncation) ──
                    if !payload.textPreview.isEmpty {
                        Text(payload.textPreview)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.bottom, payload.thumbUrl != nil ? 8 : 10)
                    }
                    
                    // ── Thumbnail (adaptive, rounded mask) ──
                    if let thumbUrl = payload.thumbUrl, let url = URL(string: thumbUrl) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: .infinity)
                                    .frame(maxHeight: 200)
                                    .clipped()
                            case .failure:
                                Rectangle()
                                    .fill(.ultraThinMaterial)
                                    .frame(height: 80)
                                    .overlay {
                                        Image(systemName: "photo")
                                            .font(.title3)
                                            .foregroundStyle(.secondary.opacity(0.5))
                                    }
                            default:
                                Rectangle()
                                    .fill(Color.primary.opacity(0.04))
                                    .frame(height: 100)
                                    .overlay {
                                        ProgressView()
                                            .tint(.secondary.opacity(0.5))
                                    }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                } else {
                    // ── Decrypt / decode failure fallback ──
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 36, height: 36)
                            Image(systemName: "lock.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unable to decrypt this post")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Content unavailable")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary.opacity(0.6))
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                
                // ── Bottom row: timestamp + status ──
                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                    
                    if isFromMe {
                        statusIcon
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: 280)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.2),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onTapGesture {
                Haptics.light()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(conversation: Conversation(
            roomId: "test_123",
            peer: .init(userId: "123", username: "testuser", firstName: "Test", lastName: "User", avatarPath: nil),
            lastMessage: nil,
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            updatedAt: Date()
        ))
    }
}




// MARK: - Droplet Attachment Menu (Liquid Glass)
struct DropletAttachmentMenu: View {
    @Binding var isOpen: Bool
    
    let onPhotoVideo: () -> Void
    let onFile: () -> Void
    let onLocation: () -> Void
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Backdrop to dismiss
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        isOpen = false
                    }
                }
            
            // Buttons stack (aligned to bottom-left)
            VStack(alignment: .leading, spacing: 14) {
                // Location button (top - furthest from input)
                dropletButton(
                    icon: "location.fill",
                    title: "Location",
                    tint: .cyan,
                    delay: 0.07,
                    action: onLocation
                )
                
                // PDF/File button (middle)
                dropletButton(
                    icon: "doc.fill",
                    title: "File",
                    tint: .blue,
                    delay: 0.035,
                    action: onFile
                )
                
                // Photo/Video button (bottom - closest to input)
                dropletButton(
                    icon: "photo.on.rectangle.angled",
                    title: "Photo",
                    tint: .green,
                    delay: 0.0,
                    action: onPhotoVideo
                )
            }
            .padding(.leading, 16)
            .padding(.bottom, 80)  // Above input bar
        }
    }
    
    @ViewBuilder
    private func dropletButton(
        icon: String,
        title: String,
        tint: Color,
        delay: Double,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            action()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                isOpen = false
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    // Glass circle with gradient highlight
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.primary.opacity(0.25), .clear],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [.primary.opacity(0.3), .primary.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.8
                                )
                        )
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)
                        .shadow(color: tint.opacity(0.2), radius: 8, x: 0, y: 4)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 52, height: 52)
                
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.trailing, 8)
        }
        .buttonStyle(.plain)
        // Droplet animation
        .scaleEffect(isOpen ? 1 : 0.3, anchor: .bottomLeading)
        .opacity(isOpen ? 1 : 0)
        .animation(
            .spring(response: 0.38, dampingFraction: 0.78)
            .delay(isOpen ? delay : 0),
            value: isOpen
        )
    }
}

// MARK: - Mesh Delivery Badge
/// Minimal badge showing mesh delivery path - only displayed for mesh messages
private struct MeshDeliveryBadge: View {
    let message: ChatMessage
    let isFromMe: Bool
    
    /// Delivery path determination based on message metadata
    private var deliveryPath: DeliveryPath {
        switch message.deliveryAuthority {
        case .server:
            return .internet
        case .mesh where message.hopCount == 0:
            return .directMesh
        case .mesh:
            return .bridgeMesh
        case .unknown:
            return .internet  // Default to internet (no badge)
        }
    }
    
    var body: some View {
        // Only show for mesh messages
        if deliveryPath != .internet {
            HStack(spacing: 4) {
                Image(systemName: deliveryPath.icon)
                    .font(.system(size: 9, weight: .medium))
                Text(deliveryPath.label(isFromMe: isFromMe))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
    
    // MARK: - Delivery Path Enum
    
    private enum DeliveryPath {
        case internet
        case directMesh
        case bridgeMesh
        
        func label(isFromMe: Bool) -> String {
            switch self {
            case .internet:
                return ""
            case .directMesh:
                return isFromMe ? "Sent via Direct Mesh" : "Received via Direct Mesh"
            case .bridgeMesh:
                return isFromMe ? "Sent via Bridge" : "Received via Bridge"
            }
        }
        
        var icon: String {
            switch self {
            case .internet:
                return ""
            case .directMesh:
                return "dot.radiowaves.left.and.right"
            case .bridgeMesh:
                return "point.3.filled.connected.trianglepath.dotted"
            }
        }
    }
}

// MARK: - Chat Sheets Modifier (all sheets/alerts/dialogs extracted from body to fix type-checker timeout)

struct ChatSheetsModifier: ViewModifier {
    @Binding var showSharedMedia: Bool
    @Binding var showGroupSettings: Bool
    @Binding var selectedImageURL: URL?
    @Binding var selectedDocument: DocumentPreviewItem?
    @Binding var selectedLinkURL: URL?
    @Binding var selectedLocationPayload: LocationPayload?
    @Binding var selectedSeenBy: [SeenByUser]?
    @Binding var reportTargetMessage: ChatMessage?
    @Binding var showBlockConfirm: Bool
    @Binding var showImagePicker: Bool
    @Binding var showMediaEditor: Bool
    @Binding var attachmentFlowState: AttachmentFlowState
    @Binding var imageForEditor: UIImage?
    @Binding var showDocumentPicker: Bool
    @Binding var showLocationSheet: Bool
    @Binding var showPaywall: Bool
    @Binding var showDeleteConfirmation: Bool
    @Binding var selectedMessageForForward: ChatMessage?
    let selectedMessageIds: Set<String>
    let conversation: Conversation
    let groupMembers: [GroupMember]
    let onDismiss: () -> Void
    let onSendImage: (UIImage) -> Void
    let onSendFile: (URL) -> Void
    let onSendLocation: (CLLocation) -> Void
    let onStartLive: (TimeInterval, CLLocation) -> Void
    let onDeleteMessages: (Bool) -> Void
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showSharedMedia) {
                ChatDetailsView(
                    roomId: conversation.roomId,
                    peer: conversation.peer
                )
            }
            .sheet(isPresented: $showGroupSettings) {
                groupSettingsContent
            }
            .fullScreenCover(item: $selectedImageURL) { url in
                FullScreenImageViewer(imageURL: url)
            }
            .sheet(item: $selectedDocument) { doc in
                DocumentPreviewView(url: doc.url, fileName: doc.fileName)
            }
            .sheet(item: $selectedLinkURL) { url in
                InAppBrowserSheet(url: url)
                    .presentationDetents([.fraction(0.75), .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: Binding(
                get: { selectedLocationPayload != nil ? IdentifiableLocationPayload(payload: selectedLocationPayload!) : nil },
                set: { if $0 == nil { selectedLocationPayload = nil } }
            )) { wrapper in
                LocationMapSheet(payload: wrapper.payload)
            }
            .sheet(item: Binding(
                get: { selectedSeenBy?.isEmpty == false ? IdentifiableSeenByWrapper(users: selectedSeenBy!) : nil },
                set: { if $0 == nil { selectedSeenBy = nil } }
            )) { wrapper in
                SeenBySheet(seenBy: wrapper.users)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
            }
            .sheet(item: $reportTargetMessage) { msg in
                ReportView(
                    targetType: .message,
                    targetId: msg.id,
                    targetName: "Message in chat",
                    reportedUserId: msg.senderId,
                    context: [
                        "conversation_id": conversation.roomId,
                        "sender_id": msg.senderId
                    ]
                )
            }
            .alert("Block \(conversation.displayTitle)?", isPresented: $showBlockConfirm) {
                Button("Block", role: .destructive) {
                    Task {
                        _ = try? await BlockService.shared.blockUser(userId: conversation.peer.userId)
                        await MainActor.run { onDismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You won't see their posts, stories, or messages. They can't message you.")
            }
            .sheet(isPresented: $showImagePicker) {
                ImagePickerView { image in
                    print("📸 [ImagePicker] Image received — size: \(image.size)")
                    imageForEditor = image
                    showImagePicker = false
                }
            }
            // FIX: Delay presentation of MediaEditorView until ImagePicker sheet is fully dismissed.
            // Failing to wait causes "Presentation is already in progress" and the screen freezes.
            .onChange(of: showImagePicker) { oldValue, newValue in
                if oldValue == true && newValue == false {
                    if imageForEditor != nil {
                        attachmentFlowState = .loadingAsset
                        // Wait 0.45s for the ImagePicker sheet to completely slide down
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            attachmentFlowState = .editing
                            showMediaEditor = true
                        }
                    } else {
                        attachmentFlowState = .idle
                    }
                }
            }
            .fullScreenCover(isPresented: $showMediaEditor, onDismiss: {
                imageForEditor = nil
                attachmentFlowState = .idle
            }) {
                editorView
            }
            .sheet(isPresented: $showDocumentPicker) {
                FilePickerView { url in
                    showDocumentPicker = false
                    onSendFile(url)
                }
            }
            .sheet(isPresented: $showLocationSheet) {
                LocationAttachSheet(
                    onSendCurrent: { location in onSendLocation(location) },
                    onStartLive: { duration, location in onStartLive(duration, location) }
                )
            }
            .sheet(isPresented: $showPaywall) {
                RavenPlusPaywallView()
            }
            .sheet(item: $selectedMessageForForward) { msg in
                ForwardSheet(message: msg) { conv in
                    let targetId = (conv.isGroup || conv.isChannel) ? conv.roomId : conv.peer.userId
                    let isGrp = conv.isGroup || conv.isChannel
                    let fwdId: String? = conversation.isChannel ? conversation.channelUsername : nil
                    let fwdName: String? = conversation.isChannel ? conversation.displayTitle : nil
                    Task {
                        try? await MessageService.shared.forwardMessage(
                            msg,
                            to: targetId,
                            isGroup: isGrp,
                            forwardedFromChannelId: fwdId,
                            forwardedFromChannelName: fwdName
                        )
                    }
                }
            }
            .confirmationDialog(
                "Delete \(selectedMessageIds.count) message\(selectedMessageIds.count == 1 ? "" : "s")?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete for Me", role: .destructive) { onDeleteMessages(false) }
                Button("Delete for Everyone", role: .destructive) { onDeleteMessages(true) }
                Button("Cancel", role: .cancel) { }
            }
    }
    
    @ViewBuilder
    private var groupSettingsContent: some View {
        if conversation.isGroup {
            GroupSettingsView(
                groupId: conversation.roomId,
                initialGroupName: conversation.groupName ?? conversation.displayTitle,
                initialGroupAvatarUrl: conversation.groupAvatarUrl,
                initialMembers: groupMembers,
                onLeave: { onDismiss() }
            )
        }
    }
    
    @ViewBuilder
    private var editorView: some View {
        if let img = imageForEditor {
            MediaEditorView(
                image: img,
                onSend: { editedImage in
                    attachmentFlowState = .sending
                    onSendImage(editedImage)
                    showMediaEditor = false
                },
                onCancel: {
                    showMediaEditor = false
                }
            )
        } else {
            // ✅ Fallback — prevents black screen if imageForEditor is nil
            Color(hex: "1C1C1E").ignoresSafeArea()
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Unable to load image")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Button("Close") {
                            showMediaEditor = false
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }
        }
    }
}

// MARK: - Attachment Flow State Machine

enum AttachmentFlowState {
    case idle        // No attachment action in progress
    case picking     // PHPicker is open
    case loadingAsset // Image selected, waiting to present editor
    case editing     // Media editor is active
    case sending     // Exporting & uploading
}

// MARK: - Snap API Response Types

private struct EmptyBody: Encodable {}

struct SnapOpenResponse: Decodable {
    let mediaUrl: String
    let openedAt: String
    let expiresIn: Int
    
    enum CodingKeys: String, CodingKey {
        case mediaUrl = "media_url"
        case openedAt = "opened_at"
        case expiresIn = "expires_in"
    }
}

struct SnapViewedResponse: Decodable {
    let status: String
    let message: String
}

struct SnapScreenshotResponse: Decodable {
    let status: String
    let message: String
}

// MARK: - Document Preview Item (for .sheet(item:))
struct DocumentPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String?
}

// ✅ Bug 5 fix: ViewModifier that conditionally applies .onScrollGeometryChange
// only on iOS 18+, preventing crashes on iOS 17 where the API doesn't exist.
struct ScrollGeometryChangeModifier: ViewModifier {
    @Binding var showScrollToBottom: Bool
    
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geo in
                    guard geo.contentSize.height > geo.containerSize.height else { return false }
                    let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                    return distanceFromBottom > 200
                } action: { _, isFarFromBottom in
                    if showScrollToBottom != isFarFromBottom {
                        DispatchQueue.main.async {
                            showScrollToBottom = isFarFromBottom
                        }
                    }
                }
        } else {
            // iOS 17 fallback: scroll-to-bottom button stays hidden (safe default)
            content
        }
    }
}
