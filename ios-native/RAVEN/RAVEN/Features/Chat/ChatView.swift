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

/// Wraps the (userId, username) pair posted from a contact-card "Open
/// profile" tap so the same `.sheet(item:)` mechanism the location → map
/// flow uses can drive the profile slide-up.
struct PresentedContactUser: Identifiable {
    let userId: String
    let username: String
    var id: String { userId }
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
    @State private var showVaultSheet = false         // Droplet menu: Vault
    @State private var pendingVaultLock: VaultLock? = nil  // Vault lock to attach to next message
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
    /// Set when the user taps "Open profile" on a shared-contact card.
    /// Drives a `.sheet(item:)` that slides UserProfileView up from the
    /// bottom — same pattern as the location-tap → map sheet flow.
    @State private var presentedContactCardUser: PresentedContactUser? = nil
    
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
    /// Drives the per-peer E2EE safety-number sheet (lock-icon tap).
    @State private var showSafetyNumber: Bool = false
    
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
    /// Message IDs that should be preceded by a Today/Yesterday/date header.
    /// Recomputed alongside `blockPositions` whenever the message list changes.
    @State private var dateHeaderIds: Set<String> = []

    // 🆕 Reactions
    @State private var reactionStore = MessageReactionStore()
    /// While non-nil, the floating reaction picker is parked above this msg.
    @State private var reactionPickerTarget: ChatMessage? = nil

    // 🆕 Pinned messages
    @State private var pinStore = PinnedMessageStore()
    /// Index into `pinStore.pins` that the pinned bar is currently
    /// showcasing — taps cycle to the next pinned message.
    @State private var pinnedShowcaseIndex: Int = 0
    /// Pulse-highlight target after tapping a pinned-bar item.
    @State private var pinJumpTargetId: String? = nil
    /// Drives the full pinned-list sheet from the trailing-icon tap.
    @State private var showPinnedList: Bool = false

    // 🆕 Per-message saved set (so the context menu can show Save/Unsave)
    @State private var savedMessageIds: Set<String> = []

    // 🆕 Poll composer (groups only). Driven by the droplet menu's Poll entry.
    @State private var showPollComposer: Bool = false

    // 🆕 Schedule send (DM only) — long-press the send button to open the
    // SchedulePickerSheet, which fires `sendScheduledMessage(at:)` on
    // dismiss. Only meaningful in 1:1 since the server's send_mode flow
    // is DM-only.
    @State private var showSchedulePicker: Bool = false

    // 🆕 Disappearing-message default for this thread (DM only). Persisted
    // to UserDefaults via ChatExpirySettings so the choice survives app
    // restarts. nil = user hasn't enabled disappearing for this room.
    @State private var expiryMode: ExpiryMode? = nil
    @State private var showExpiryPicker: Bool = false

    // 🆕 Message-info popover (Sent/Delivered/Read timeline).
    @State private var selectedMessageForInfo: ChatMessage? = nil

    // 🆕 "Unread messages" divider anchor — captured ONCE on chat entry
    // from `liveConversation?.unreadCount` so the line stays put while
    // the user reads. nil when the user opened the chat with zero unread.
    @State private var entryUnreadAnchor: String? = nil
    /// Number of unread messages at chat-entry — drives the divider's
    /// "12 new messages" label. Frozen so it doesn't tick down to 0
    /// as the read receipts fire.
    @State private var entryUnreadCount: Int = 0

    // 🆕 "More" reaction sheet — opened from the React submenu's bottom
    // entry. Holds the *target* message id so the sheet's onPick reacts
    // to the right bubble rather than the most recently long-pressed one.
    @State private var reactionMoreTarget: ChatMessage? = nil

    // 🆕 Reactors sheet target — group-chat only. Long-press a chip to
    // see who reacted with that emoji.
    @State private var reactionReactorsTarget: ReactionReactorsTarget? = nil

    // 🆕 Per-message reaction count snapshot, used to detect when a
    // new reaction is added and trigger a brief "received" pulse on
    // the bubble — gives the visceral "emoji landed on the bubble"
    // feedback the chip transition alone can't carry.
    @State private var reactionCounts: [String: Int] = [:]
    /// Message id whose bubble is currently pulsing. nil when nothing
    /// is animating.
    @State private var pulsingReactionMessageId: String? = nil

    // 🆕 Custom long-press overlay (Instagram/Telegram style). Replaces
    // the system .contextMenu so we can:
    //   1. Heavily blur the chat behind (system menu only dims)
    //   2. Render capsule + bubble + menu as free-floating elements
    //      with no wrapping white card (the system menu's preview
    //      is always wrapped in a lifted white card we can't disable)
    //   3. Position the bubble exactly where it was on screen so the
    //      menu fans out from it instead of jumping to center
    @State private var bubbleActionContext: BubbleActionContext? = nil
    /// Map of message id → on-screen frame (global coordinate space).
    /// Each visible bubble writes its frame here via a PreferenceKey
    /// so on long-press we can place the overlay at the right spot.
    @State private var bubbleFrames: [String: CGRect] = [:]

    // 🆕 Typing indicator
    @State private var typingStore = TypingPresenceStore()
    /// Last time we posted `is_typing=true` to the server. Debounced to ~3s.
    @State private var lastTypingPostAt: Date = .distantPast

    // 🆕 In-thread search
    @State private var showSearchBar: Bool = false
    @State private var searchQuery: String = ""
    @State private var searchResults: [NetworkService.MessageSearchHit] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    /// Message id we want to scroll to and pulse-highlight (from a search hit).
    @State private var pulseMessageId: String? = nil
    
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

    // ✨ Foundation AI helpers — feed the smart-reply chips and the
    // on-device summary sheet.

    /// Most recent incoming (not-from-me) message text — what we suggest replies for.
    private var latestIncomingText: String? {
        return messageStore.messages.reversed().first { msg in
            !senderIsMe(msg.senderId) && (msg.text?.isEmpty == false) && msg.type == .text
        }?.text
    }

    /// A compact transcript of the last 6 plain-text messages, formatted as
    /// "Sender: text" lines. Used as context for both smart-replies and
    /// the conversation summary.
    private var aiTranscript: String {
        let recent = messageStore.messages.suffix(6)
        return recent.compactMap { msg -> String? in
            guard let text = msg.text, !text.isEmpty, msg.type == .text else { return nil }
            let who = senderIsMe(msg.senderId) ? "Me" : (msg.senderName.isEmpty ? "Them" : msg.senderName)
            return "\(who): \(text)"
        }.joined(separator: "\n")
    }

    @State private var showAISummary = false

    // MARK: - Header sub-views (extracted to keep `body` under the
    // SwiftUI type-checker budget)

    @ViewBuilder
    private var identityChangeBannerHeader: some View {
        if !conversation.isGroup && !conversation.isChannel {
            PeerIdentityChangeBanner(
                peerUserId: conversation.peer.userId,
                peerName: conversation.displayTitle
            ) {
                showSafetyNumber = true
            }
        }
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
                        // 🔐 Identity-change banner. Extracted to a
                        // computed property — keeping it inline
                        // pushes ChatView's body past the SwiftUI
                        // type-check budget.
                        identityChangeBannerHeader

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
                            let isFromMe = senderIsMe(message.senderId)

                            // Replace idx > 0 with first-message check (no index needed)
                            let isVeryFirstMessage = message.id == msgs.first?.id
                            let topPad: CGFloat = conversation.isGroup
                                ? (pos.isFirst && !isVeryFirstMessage ? 14 : (!isVeryFirstMessage ? 3 : 0))
                                : 2

                            if dateHeaderIds.contains(message.id) {
                                ChatDateSeparator(date: message.timestamp)
                                    .padding(.top, isVeryFirstMessage ? 4 : 16)
                                    .padding(.bottom, 4)
                            }

                            // 🆕 "X unread messages" divider rendered just
                            // above the first unread message we captured
                            // on chat entry. Stays in place as the user
                            // reads — same behavior as Telegram/WhatsApp.
                            if message.id == entryUnreadAnchor {
                                UnreadMessagesDivider(count: entryUnreadCount)
                                    .padding(.vertical, 8)
                            }

                            // System messages render as minimal centered chips,
                            // NOT wrapped in MessageBubbleView (avoids bubble styling)
                            Group {
                                if message.type == .system {
                                    SystemEventChip(
                                        title: message.text ?? "Notification",
                                        timestamp: message.timestamp
                                    )
                                } else {
                                    VStack(spacing: 2) {
                                        messageBubble(for: message, isFirstInBlock: pos.isFirst, isLastInBlock: pos.isLast)
                                            .padding(.top, topPad)
                                            // 🆕 Custom long-press: triggers our overlay
                                            // instead of the system contextMenu (which
                                            // wraps content in a white lifted card we
                                            // can't disable). The frame is reported from
                                            // INSIDE MessageBubbleView so we get the
                                            // actual bubble's bounds, not the full row.
                                            //
                                            // 🐛 BUG FIX (2026-05-11) "haptic touch dorost
                                            // kar nemikone": switched from the
                                            // `.onLongPressGesture(minimumDuration:)`
                                            // shortcut (which uses a strict 10pt
                                            // maxDistance — finger drifts cancel it
                                            // immediately) to the explicit
                                            // `LongPressGesture(maximumDistance: 50)` form
                                            // so subtle finger movement during the 400ms
                                            // hold doesn't kill the gesture. Same pattern
                                            // iMessage / Instagram use.
                                            .gesture(
                                                LongPressGesture(minimumDuration: 0.4, maximumDistance: 50)
                                                    .onEnded { _ in
                                                        guard message.type != .system else { return }
                                                        let frame = bubbleFrames[message.id] ?? .zero
                                                        guard frame.width > 0 else { return }
                                                        let isFromMe = senderIsMe(message.senderId)
                                                        Haptics.medium()
                                                        bubbleActionContext = BubbleActionContext(
                                                            message: message,
                                                            isFromMe: isFromMe,
                                                            bubbleFrame: frame
                                                        )
                                                    }
                                            )
                                            // Pulse highlight when this message is the target of a
                                            // search hit or a reply-jump.
                                            .background(
                                                pulseMessageId == message.id
                                                    ? Color.accentColor.opacity(0.18)
                                                    : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            )
                                            .animation(.easeInOut(duration: 0.6), value: pulseMessageId)
                                            // 🆕 Brief scale + shadow pulse the moment a reaction
                                            // lands on this bubble — paired with the chip's
                                            // scale-in transition to deliver "the emoji landed
                                            // here" signal Instagram / Telegram both telegraph.
                                            .scaleEffect(pulsingReactionMessageId == serverIdOrLocal(message) ? 1.04 : 1.0)
                                            .shadow(
                                                color: Color.accentColor.opacity(
                                                    pulsingReactionMessageId == serverIdOrLocal(message) ? 0.45 : 0
                                                ),
                                                radius: pulsingReactionMessageId == serverIdOrLocal(message) ? 16 : 0
                                            )
                                            .animation(.spring(response: 0.28, dampingFraction: 0.45), value: pulsingReactionMessageId)

                                        // Reaction chips (below the bubble, before the read-receipts)
                                        let groups = reactionStore.grouped(
                                            for: serverIdOrLocal(message),
                                            currentUserId: AuthService.shared.currentUser?.id ?? ""
                                        )
                                        if !groups.isEmpty {
                                            ReactionChipsRow(
                                                groups: groups,
                                                isFromMe: isFromMe,
                                                onTap: { emoji in
                                                    Task {
                                                        await reactionStore.toggle(
                                                            messageId: serverIdOrLocal(message),
                                                            emoji: emoji,
                                                            currentUserId: AuthService.shared.currentUser?.id ?? ""
                                                        )
                                                    }
                                                },
                                                onLongPress: conversation.isGroup ? { group in
                                                    reactionReactorsTarget = ReactionReactorsTarget(
                                                        emoji: group.emoji,
                                                        userIds: group.userIds
                                                    )
                                                } : nil
                                            )
                                            .padding(.horizontal, 8)
                                        }

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
                                    .id(message.id)
                                }
                            }
                            // ✨ Smoother new-message entry — slides up + fades from
                            // the side (own / peer), with a snappier spring.
                            // Old transition was a generic scale that produced an
                            // awkward "pop" mid-list.
                            .transition(.asymmetric(
                                insertion: .move(edge: isFromMe ? .trailing : .leading)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.96, anchor: isFromMe ? .bottomTrailing : .bottomLeading)),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            ))
                        }

                        // 🆕 Typing indicator parked below the last message,
                        // aligned with the peer's column for incoming messages.
                        if let label = typingStore.presenceLabel {
                            HStack {
                                TypingIndicatorCapsule(presenceLabel: label)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                            .id("typing-indicator")
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.interpolatingSpring(stiffness: 320, damping: 28), value: messageStore.messages.count)
                    .animation(.spring(response: 0.32, dampingFraction: 0.8), value: typingStore.presenceLabel)
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
                    ZStack(alignment: .topTrailing) {
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
                        // 🆕 Long-press the scroll-button for jump options:
                        //   • First unread (pulses to that bubble)
                        //   • Top of thread (oldest message)
                        // Tap still goes to bottom — same as before.
                        .contextMenu {
                            if entryUnreadAnchor != nil {
                                Button {
                                    if let anchor = entryUnreadAnchor {
                                        Haptics.light()
                                        withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                            proxy.scrollTo(anchor, anchor: .top)
                                        }
                                    }
                                } label: {
                                    Label("Jump to first unread", systemImage: "arrow.up.to.line")
                                }
                            }
                            if let firstId = messageStore.messages.first?.id {
                                Button {
                                    Haptics.light()
                                    withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                        proxy.scrollTo(firstId, anchor: .top)
                                    }
                                } label: {
                                    Label("Jump to top", systemImage: "arrow.up.circle")
                                }
                            }
                        }
                        // 🆕 Unread count badge — only renders when there
                        // ARE unread messages from someone else and the
                        // user is scrolled away from them. Tapping the
                        // button still scrolls to bottom; the badge is a
                        // visual cue, not a separate target.
                        if scrollUnreadCount > 0 {
                            Text(scrollUnreadCount > 99 ? "99+" : "\(scrollUnreadCount)")
                                .font(.system(size: 11, weight: .heavy).monospacedDigit())
                                .foregroundColor(.white)
                                .padding(.horizontal, scrollUnreadCount > 9 ? 5 : 0)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(Color.accentColor))
                                .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                                .offset(x: 4, y: -2)
                                .transition(.scale.combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 90)
                    // 🔴 Bug fix (2026-05-09): when the user has just
                    // sent a message we should NOT hover the button
                    // over their latest bubble. The geometry modifier
                    // alone can mis-fire while the keyboard slides in
                    // and contentSize/offset transiently disagree —
                    // overlapping `Hjghj 71↓` on top of the most-recent
                    // sent bubble. Layer two extra gates on top of the
                    // distance-from-bottom signal:
                    //   • If there are no real unread peer messages
                    //     (per server-capped count), the user is by
                    //     definition caught up — no button.
                    //   • If the most-recent message in the thread is
                    //     ours (we just sent), the user is at the
                    //     bottom by definition — no button.
                    .opacity(shouldShowScrollButton ? 1 : 0)
                    .scaleEffect(shouldShowScrollButton ? 1 : 0.001)
                    .allowsHitTesting(shouldShowScrollButton)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shouldShowScrollButton)
                    .animation(.spring(response: 0.32, dampingFraction: 0.85), value: scrollUnreadCount)
                }
                // ✅ Bug 5 fix: .onScrollGeometryChange is iOS 18+ only.
                // On iOS 17, the scroll-to-bottom button stays hidden (safe fallback).
                .modifier(ScrollGeometryChangeModifier(showScrollToBottom: $showScrollToBottom))
                // ✅ Bug 5 fix: Auto-scroll for ALL new messages (sent AND received)
                .onChange(of: messageStore.messages.count) { oldCount, newCount in
                    blockPositions = precomputeBlockPositions(messages: messageStore.messages)
                    dateHeaderIds = precomputeDateHeaders(messages: messageStore.messages)
                    guard newCount > oldCount else { return }
                    
                    let isMyMessage = senderIsMe(messageStore.messages.last?.senderId)
                    
                    // Fix: initial load (0→N) should NOT be treated as pagination
                    let isInitialLoad = oldCount == 0 && newCount > 0
                    let isPagination = (newCount > oldCount + 1) && !isInitialLoad
                    
                    if isInitialLoad {
                        // First-paint scroll — re-resolve the unread
                        // anchor if it wasn't computable on .onAppear
                        // (messages still loading there) and jump there
                        // instead of the bottom when one exists.
                        let unread = liveConversation?.unreadCount ?? 0
                        if entryUnreadAnchor == nil, unread > 0,
                           messageStore.messages.count > unread {
                            let idx = messageStore.messages.count - unread
                            entryUnreadAnchor = messageStore.messages[idx].id
                            entryUnreadCount = unread
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            if let anchor = entryUnreadAnchor {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                    proxy.scrollTo(anchor, anchor: .top)
                                }
                            } else {
                                scrollToBottom(proxy: proxy)
                            }
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
                // 🆕 Watch the reaction map — when a message's reaction
                // count goes up (someone reacted, including ourselves
                // optimistically), trigger a brief bubble pulse so the
                // user gets a visceral "the emoji landed on the bubble"
                // signal beyond the chip's own scale-in transition.
                .onChange(of: reactionStore.reactions) { _, newMap in
                    var newCounts: [String: Int] = [:]
                    for (mid, list) in newMap { newCounts[mid] = list.count }
                    var pulsedId: String? = nil
                    for (mid, count) in newCounts {
                        if count > (reactionCounts[mid] ?? 0) {
                            pulsedId = mid
                            break
                        }
                    }
                    reactionCounts = newCounts
                    if let pulsedId {
                        pulsingReactionMessageId = pulsedId
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            if pulsingReactionMessageId == pulsedId {
                                pulsingReactionMessageId = nil
                            }
                        }
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
                    dateHeaderIds = precomputeDateHeaders(messages: messageStore.messages)

                    // 🆕 Capture the "first unread" anchor for the divider
                    // line. Frozen on entry so the marker stays put while
                    // the user reads through their unread.
                    let unread = liveConversation?.unreadCount ?? 0
                    if unread > 0 && messageStore.messages.count > unread {
                        let idx = messageStore.messages.count - unread
                        entryUnreadAnchor = messageStore.messages[idx].id
                        entryUnreadCount = unread
                    } else {
                        entryUnreadAnchor = nil
                        entryUnreadCount = 0
                    }

                    // Manual scroll on enter — jump to the first unread
                    // when there is one, otherwise to the bottom.
                    if !messageStore.messages.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            if let anchor = entryUnreadAnchor {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.85)) {
                                    proxy.scrollTo(anchor, anchor: .top)
                                }
                            } else {
                                scrollToBottom(proxy: proxy)
                            }
                        }
                    }
                    // Load draft
                    if let savedDraft = UserDefaults.standard.string(forKey: "draft_\(conversation.roomId)") {
                        inputText = savedDraft
                    }
                    Task { await fetchPresence() }
                }
                // 🆕 Server send error toast — fired by MessageStore when
                // the send endpoint returns a user-actionable 4xx with a
                // detail body (e.g. message-request quota, privacy gate).
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ChatSendErrorToast"))) { note in
                    if let msg = note.userInfo?["message"] as? String {
                        errorMessage = msg
                        showErrorAlert = true
                    }
                }
                // 🆕 Search-hit / reply-jump scrolling. Posted by jumpToMessage
                // so the ScrollViewReader's `proxy` can scroll to the target.
                .onReceive(NotificationCenter.default.publisher(for: .chatScrollToMessage)) { note in
                    guard let messageId = note.userInfo?["messageId"] as? String else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        proxy.scrollTo(messageId, anchor: .center)
                    }
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
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    
                    // ✨ On-device AI smart-reply chips (iOS 26 Foundation Models).
                    // Hidden when user is typing OR AI unavailable.
                    SmartReplyChips(
                        incomingText: latestIncomingText,
                        transcript: aiTranscript,
                        inputText: $inputText,
                        userIsTyping: !inputText.isEmpty || isInputFocused
                    )

                    disappearingBanner

                    // Input bar
                    ChatInputBar(
                        text: $inputText,
                        isRecordingVoice: isRecordingVoice,
                        onSend: sendMessage,
                        onSchedule: conversation.isGroup ? nil : {
                            isInputFocused = false
                            showSchedulePicker = true
                        },
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
            
            
            .onChange(of: inputText) { oldValue, newValue in
                if conversation.isGroup {
                    mentionTracker.processTextChange(newValue)
                }

                // 🆕 Typing indicator — debounce so we don't spam the server
                // every keystroke. We post `is_typing=true` once every 3 s
                // while there's text, and `is_typing=false` the moment the
                // composer empties (covers the "they cleared their text"
                // case, the send case is handled separately).
                if !newValue.isEmpty {
                    let now = Date()
                    if now.timeIntervalSince(lastTypingPostAt) > 3 {
                        lastTypingPostAt = now
                        let roomId = conversation.roomId
                        let isGroup = conversation.isGroup
                        Task {
                            await NetworkService.shared.postTyping(
                                peerId: roomId, isTyping: true, isGroup: isGroup
                            )
                        }
                    }
                } else if !oldValue.isEmpty {
                    lastTypingPostAt = .distantPast
                    let roomId = conversation.roomId
                    let isGroup = conversation.isGroup
                    Task {
                        await NetworkService.shared.postTyping(
                            peerId: roomId, isTyping: false, isGroup: isGroup
                        )
                    }
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
            
            
            // ✅ Liquid Glass attachment sheet (Telegram-style bottom sheet)
            if showAttachmentPicker {
                LiquidGlassAttachmentSheet(
                    isPresented: $showAttachmentPicker,
                    onSendImage: { image in
                        sendImage(image)
                    },
                    onSendFile: { url in
                        sendFile(url)
                    },
                    onOpenFiles: {
                        showDocumentPicker = true
                    },
                    onSendLocation: { location in
                        sendCurrentLocation(location)
                    },
                    onStartLiveLocation: {
                        showLocationSheet = true
                    },
                    onSendVoice: { url, duration in
                        sendVoice(url, duration: duration)
                    },
                    onShareFriend: { friend in
                        shareFriend(friend)
                    }
                )
                .zIndex(999)
                .transition(.opacity)
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

                            // 🔐 E2EE indicator — green filled lock when
                            // identity is verified, blue lock otherwise.
                            // Tap opens the safety-number sheet.
                            EncryptionStatusBadge(
                                peerUserId: conversation.peer.userId,
                                peerDisplayName: conversation.displayTitle,
                                isGroupOrChannel: conversation.isGroup || conversation.isChannel
                            ) {
                                showSafetyNumber = true
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
                            // Dynamic presence status with a green dot when
                            // the peer is online and a gray dot otherwise.
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(peerIsOnline ? Color.green : Color.gray.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                Text(presenceStatusText)
                                    .font(.caption2)
                                    .foregroundStyle(peerIsOnline ? .green : .secondary)
                                    .lineLimit(1)
                            }
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
                        // Only render the dot when the peer is actually
                        // online — never on group/channel avatars and
                        // never when offline.
                        showOnlineIndicator: !conversation.isGroup && !conversation.isChannel && peerIsOnline
                    )
                }
                .buttonStyle(.plain)
            }

            // ✨ On-device summary (iOS 26+ Foundation Models). Shown only
            // when the user has at least 4 messages worth summarising AND
            // the on-device stack is actually ready to generate (Apple
            // Intelligence enabled, safety model installed). Hiding the
            // entry point here is what saves the user from the wall-of-
            // NSError dump that used to pop up on simulator / first-boot
            // devices when generation failed mid-request.
            if FoundationAIService.shared.isReadyToGenerate && messageStore.messages.count >= 4 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Haptics.light()
                        showAISummary = true
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                }
            }

            // 🆕 In-thread search — only meaningful for DMs (server endpoint
            // is /api/messages/search?peer_id=, not implemented for groups).
            if !conversation.isGroup && !conversation.isChannel {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Haptics.light()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            showSearchBar.toggle()
                            if !showSearchBar {
                                searchQuery = ""
                                searchResults = []
                                searchTask?.cancel()
                            }
                        }
                    } label: {
                        Image(systemName: showSearchBar ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if !pinStore.pins.isEmpty {
                    PinnedBarView(
                        pins: pinStore.pins,
                        showcaseIndex: $pinnedShowcaseIndex,
                        onJump: { mid in
                            pinJumpTargetId = mid
                            // Reuse the same pulse-target the search bar uses.
                            pulseMessageId = mid
                            NotificationCenter.default.post(
                                name: Notification.Name("ChatScrollToMessage"),
                                object: nil,
                                userInfo: ["messageId": mid]
                            )
                        },
                        onShowList: { showPinnedList = true }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if showSearchBar {
                    InThreadSearchBar(
                        query: $searchQuery,
                        isSearching: isSearching,
                        resultLabel: searchResultLabel,
                        onSubmit: { runSearch(force: true) },
                        onClear: {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                                showSearchBar = false
                                searchQuery = ""
                                searchResults = []
                            }
                        }
                    )
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: pinStore.pins.count)
        }
        .onChange(of: searchQuery) { _, newValue in
            // Debounced server search. We schedule a 300 ms task per
            // keystroke; if a newer keystroke fires before it runs, the
            // older Task is cancelled and a fresh one replaces it.
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                searchResults = []
                isSearching = false
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await runSearchInline(query: trimmed)
            }
        }
        .sheet(isPresented: $showAISummary) {
            ChatSummarySheet(transcript: aiTranscript)
        }
        .sheet(isPresented: $showSafetyNumber) {
            // 🔐 Per-peer identity verification (60-digit safety number).
            // Lock badge in the nav bar drives this; the banner-side
            // "Verify Now" button uses the same hook.
            NavigationStack {
                SafetyNumberView(
                    peerUserId: conversation.peer.userId,
                    peerDisplayName: conversation.displayTitle
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showSafetyNumber = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showPinnedList) {
            PinnedListSheet(
                pins: pinStore.pins,
                isGroup: conversation.isGroup,
                onJump: { mid in
                    pulseMessageId = mid
                    NotificationCenter.default.post(
                        name: Notification.Name("ChatScrollToMessage"),
                        object: nil,
                        userInfo: ["messageId": mid]
                    )
                },
                onUnpin: { mid in
                    Task {
                        await pinStore.togglePin(messageId: mid, pinned: false, snapshot: nil)
                    }
                }
            )
        }
        .sheet(isPresented: $showPollComposer) {
            PollComposerSheet(groupId: conversation.roomId) {
                // Trigger an immediate refresh so the poll-announcement
                // bubble shows up without waiting for the next poll cycle.
                Task { await messageStore.fetchMessages() }
            }
        }
        .sheet(item: $selectedMessageForInfo) { msg in
            MessageInfoSheet(message: msg)
        }
        .sheet(isPresented: $showSchedulePicker) {
            SchedulePickerSheet { date in
                let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let captured = trimmed
                inputText = ""
                Task {
                    await messageStore.sendScheduledText(captured, scheduledAt: date)
                }
            }
        }
        .sheet(item: $reactionReactorsTarget) { target in
            ReactionReactorsSheet(
                emoji: target.emoji,
                userIds: target.userIds,
                members: groupMembers
            )
        }
        .sheet(item: $reactionMoreTarget) { target in
            EmojiReactionPickerSheet { emoji in
                let mid = serverIdOrLocal(target)
                Task {
                    await reactionStore.toggle(
                        messageId: mid,
                        emoji: emoji,
                        currentUserId: AuthService.shared.currentUser?.id ?? ""
                    )
                }
            }
        }
        .modifier(
            ExpiryPickerDialogModifier(
                isPresented: $showExpiryPicker,
                roomId: conversation.roomId,
                onPick: { newMode in
                    expiryMode = newMode
                    ChatExpirySettings.setMode(newMode, forRoom: conversation.roomId)
                    Haptics.light()
                }
            )
        )
        // 🆕 Collect every visible bubble's frame so the long-press
        // overlay can position the capsule + menu around the original
        // bubble. Reduce uses last-write-wins per message id.
        .onPreferenceChange(BubbleFramePreferenceKey.self) { frames in
            bubbleFrames = frames
        }
        // 🆕 Heavy gaussian blur on the chat body when the overlay is
        // up. Applied here BEFORE the .overlay below so the overlay
        // itself is NOT blurred. Mirrors the Instagram pattern.
        .blur(radius: bubbleActionContext != nil ? 18 : 0)
        .animation(.easeInOut(duration: 0.22), value: bubbleActionContext != nil)
        .overlay {
            if let ctx = bubbleActionContext {
                bubbleActionOverlay(for: ctx)
                    .transition(.opacity)
            }
        }
        // All sheets/alerts/dialogs extracted to helper (fixes type-checker timeout)
        .chatKeyboardShortcuts(
            messages: messageStore.messages,
            showSearchBar: $showSearchBar,
            replyingTo: $replyingTo,
            editingMessage: $editingMessage,
            inputText: $inputText,
            myUserId: AuthService.shared.currentUser?.id ?? "",
            onScrollToBottom: {
                // Post a scroll-to-message notification with the last
                // message id; the ScrollViewReader's existing handler
                // picks this up. Avoids needing the proxy at this scope.
                if let lastId = messageStore.messages.last?.id {
                    NotificationCenter.default.post(
                        name: .chatScrollToMessage,
                        object: nil,
                        userInfo: ["messageId": lastId]
                    )
                }
            }
        )
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
        .sheet(isPresented: $showVaultSheet) {
            VaultLockSheet(vaultLock: $pendingVaultLock)
        }
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

            // Reactions + typing + pin observers — all feed off /ws/inbox
            // events dispatched by RealtimeEngine.
            let myId = AuthService.shared.currentUser?.id ?? ""
            reactionStore.setupObservers(roomId: conversation.roomId, isGroup: conversation.isGroup)
            typingStore.setupObservers(
                roomId: conversation.roomId,
                isGroup: conversation.isGroup,
                currentUserId: myId
            )
            pinStore.setupObservers(
                roomId: conversation.roomId,
                isGroup: conversation.isGroup,
                peerId: conversation.peer.userId
            )

            await messageStore.loadFromDB()
            await messageStore.fetchMessages()

            // Clean unified seen — replaces old inline logic
            markVisibleMessagesAsRead()

            if conversation.isGroup {
                let messageIds = messageStore.messages.map { $0.id }
                await readReceiptStore.loadForMessages(messageIds: messageIds)
            }

            // Initial reaction + pin + saved-set load for visible messages.
            let reactionIds = messageStore.messages.compactMap { $0.serverId ?? $0.id }
            await reactionStore.load(messageIds: reactionIds)
            await pinStore.load()
            await loadSavedSet()

            // Restore the disappearing-messages default the user picked
            // last time they were in this room (DM only). nil → off.
            if !conversation.isGroup {
                expiryMode = ChatExpirySettings.mode(forRoom: conversation.roomId)
            }

            // 🆕 Cross-chat hand-off: if the user picked "Reply privately"
            // on a group message, the source ChatView stashed the original
            // in PendingReplyStore. Consume it on appear and seed the
            // composer's reply state so the user lands ready to type.
            if !conversation.isGroup,
               let pending = PendingReplyStore.shared.consume(forPeerId: conversation.peer.userId) {
                replyingTo = pending
                isInputFocused = true
            }

            await MainActor.run {
                messageStore.startPolling()
            }
        }
        .onDisappear {
            reactionStore.removeObservers()
            typingStore.removeObservers()
            pinStore.removeObservers()
            // Make sure peers see us stop typing when we navigate away.
            if !inputText.isEmpty {
                Task {
                    await NetworkService.shared.postTyping(
                        peerId: conversation.roomId,
                        isTyping: false,
                        isGroup: conversation.isGroup
                    )
                }
            }
        }
        // ✅ Removed .ignoresSafeArea(.keyboard) - safeAreaInset now handles keyboard properly
        .toolbar(.hidden, for: .tabBar)
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
        // Contact-card "Open profile" tap → slide UserProfileView up from
        // the bottom (same pattern the location-tap → map sheet uses).
        .onReceive(NotificationCenter.default.publisher(for: .ravenContactCardOpenTapped)) { note in
            guard let info = note.userInfo,
                  let userId = info["userId"] as? String,
                  let username = info["username"] as? String else { return }
            presentedContactCardUser = PresentedContactUser(userId: userId, username: username)
        }
        .sheet(item: $presentedContactCardUser) { user in
            UserProfileView(userId: user.userId)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
                // FIX: Block must call BOTH the /block endpoint (updates MessageRequest.status)
                // AND BlockService (creates the Block record + hides content).
                // Previously only BlockService was called, leaving MessageRequest as "pending".
                Button {
                    Task { await handleRequestAction("block") }
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 10, y: -5)
    }
    
    private func handleRequestAction(_ action: String) async {
        // FIX: Use requestId (the actual UUID) as the primary key.
        // Fall back to roomId (peer's userId) only when requestId is nil —
        // the server's _resolve_request() helper handles the fallback lookup by sender_id.
        let targetId = conversation.requestId ?? conversation.roomId
        do {
            struct EmptyBody: Encodable {}
            struct EmptyResp: Decodable {}
            let _: EmptyResp = try await NetworkService.shared.post(
                path: "/api/message-requests/\(targetId)/\(action)", body: EmptyBody()
            )
            await ConversationStore.shared.fetchConversations(forceFull: true)
            // Dismiss for all terminal actions (decline, block), stay open for accept
            if action == "decline" || action == "block" {
                await MainActor.run { dismiss() }
            }
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
    
    // Single-expression body, so the @ViewBuilder annotation buys nothing
    // and Swift warns about the explicit `return` disabling it.
    private func messageBubble(for message: ChatMessage, isFirstInBlock: Bool = true, isLastInBlock: Bool = true) -> some View {
        let isFromMe = senderIsMe(message.senderId)
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
                // Double-tap = thumbs-up reaction (the most common one).
                // Goes through the new server-backed reaction store; falls
                // back to a haptic if the user is already double-tapping
                // their own bubble before the server ack lands.
                Haptics.medium()
                Task {
                    await reactionStore.toggle(
                        messageId: serverIdOrLocal(message),
                        emoji: "👍",
                        currentUserId: AuthService.shared.currentUser?.id ?? ""
                    )
                }
            },
            onEdit: {
                editingMessage = message
                inputText = message.text ?? ""
            },
            onReact: { emoji in
                Task {
                    await reactionStore.toggle(
                        messageId: serverIdOrLocal(message),
                        emoji: emoji,
                        currentUserId: AuthService.shared.currentUser?.id ?? ""
                    )
                }
            },
            onReactMore: {
                reactionMoreTarget = message
            },
            onReplyPrivately: {
                let peerId = message.senderId
                PendingReplyStore.shared.setPending(forPeerId: peerId, message: message)
                DeepLinkRouter.shared.route(to: .newChat(userId: peerId))
            },
            onJumpToReply: { serverMessageId in
                jumpToMessage(serverId: serverMessageId)
            },
            isGroupChat: conversation.isGroup,
            isChannel: conversation.isChannel,
            isPrivateChannel: conversation.channelType == "private",
            onPublish: { visibility in
                Task { await publishMessageToFeed(message, visibility: visibility) }
            },
            onTogglePin: {
                let mid = serverIdOrLocal(message)
                let nowPinned = pinStore.isPinned(messageId: mid)
                let snap = PinnedMessageStore.Pin(
                    id: mid,
                    senderUsername: nil,
                    senderName: message.senderName,
                    content: message.text,
                    messageType: message.type.rawValue,
                    pinnedAt: Date(),
                    pinnedByUserId: AuthService.shared.currentUser?.id ?? ""
                )
                Task {
                    await pinStore.togglePin(messageId: mid, pinned: !nowPinned, snapshot: nowPinned ? nil : snap)
                }
            },
            onToggleSave: {
                let mid = serverIdOrLocal(message)
                let isGroup = conversation.isGroup
                let alreadySaved = savedMessageIds.contains(mid)
                Task {
                    do {
                        if alreadySaved {
                            _ = try await NetworkService.shared.unsaveMessage(messageId: mid, isGroup: isGroup)
                            savedMessageIds.remove(mid)
                        } else {
                            _ = try await NetworkService.shared.saveMessage(messageId: mid, isGroup: isGroup)
                            savedMessageIds.insert(mid)
                        }
                    } catch {
                        #if DEBUG
                        print("⭐ [Save] toggle failed: \(error)")
                        #endif
                    }
                }
            },
            onShowInfo: {
                selectedMessageForInfo = message
            },
            isPinned: pinStore.isPinned(messageId: serverIdOrLocal(message)),
            isSaved: savedMessageIds.contains(serverIdOrLocal(message)),
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
    
    /// Reactions/edit/search address messages by their server-side id; for
    /// in-flight messages that haven't been ACKed yet we fall back to the
    /// client id so the chips at least track locally.
    /// Build the custom action overlay for a long-pressed message. The
    /// callbacks here mirror the ones the system .contextMenu used to
    /// invoke — same state mutations, same task launches.
    @ViewBuilder
    private func bubbleActionOverlay(for ctx: BubbleActionContext) -> some View {
        let message = ctx.message
        let mid = serverIdOrLocal(message)
        let isFromMe = ctx.isFromMe
        let isPinned = pinStore.isPinned(messageId: mid)
        let isSaved = savedMessageIds.contains(mid)
        let myId = AuthService.shared.currentUser?.id ?? ""
        let active = Set(reactionStore.reactions[mid]?
            .filter { $0.userId == myId }
            .map { $0.emoji } ?? [])

        BubbleActionOverlay(
            context: ctx,
            actions: BubbleOverlayActions(
                onReply: { replyingTo = message },
                onForward: { selectedMessageForForward = message },
                onPin: {
                    let nowPinned = pinStore.isPinned(messageId: mid)
                    let snap = PinnedMessageStore.Pin(
                        id: mid,
                        senderUsername: nil,
                        senderName: message.senderName,
                        content: message.text,
                        messageType: message.type.rawValue,
                        pinnedAt: Date(),
                        pinnedByUserId: myId
                    )
                    Task {
                        await pinStore.togglePin(messageId: mid, pinned: !nowPinned, snapshot: nowPinned ? nil : snap)
                    }
                },
                onSave: {
                    let alreadySaved = savedMessageIds.contains(mid)
                    Task {
                        do {
                            if alreadySaved {
                                _ = try await NetworkService.shared.unsaveMessage(messageId: mid, isGroup: conversation.isGroup)
                                savedMessageIds.remove(mid)
                            } else {
                                _ = try await NetworkService.shared.saveMessage(messageId: mid, isGroup: conversation.isGroup)
                                savedMessageIds.insert(mid)
                            }
                        } catch { }
                    }
                },
                onShowInfo: { selectedMessageForInfo = message },
                onCopy: (message.text?.isEmpty == false) ? {
                    UIPasteboard.general.string = message.text
                    Haptics.success()
                } : nil,
                onEdit: (isFromMe && message.type == .text) ? {
                    editingMessage = message
                    inputText = message.text ?? ""
                } : nil,
                onDelete: isFromMe ? {
                    Task { await messageStore.deleteMessage(message.id) }
                } : nil,
                onReact: { emoji in
                    Task {
                        await reactionStore.toggle(messageId: mid, emoji: emoji, currentUserId: myId)
                    }
                },
                onReactMore: {
                    reactionMoreTarget = message
                },
                onReplyPrivately: (conversation.isGroup && !isFromMe) ? {
                    let peerId = message.senderId
                    PendingReplyStore.shared.setPending(forPeerId: peerId, message: message)
                    DeepLinkRouter.shared.route(to: .newChat(userId: peerId))
                } : nil
            ),
            activeReactionEmojis: active,
            isPinned: isPinned,
            isSaved: isSaved,
            onDismiss: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    bubbleActionContext = nil
                }
            }
        )
    }

    /// Live unread count for the floating scroll-to-bottom button's
    /// badge.
    ///
    /// History — and why we cap against the server count
    /// ──────────────────────────────────────────────────
    /// The previous version walked `messageStore.messages` and counted
    /// every peer message with `readAt == nil`. That worked for the
    /// happy path, but `readAt` is *only* set when a message actually
    /// renders on screen and the read-receipt pipeline runs. Old
    /// messages that arrived while the app was killed, or messages
    /// from before this client persisted readAt at all, never got
    /// the field flipped — so the local scan slowly accumulated to
    /// numbers like "71" while the server said "1 unread".
    ///
    /// The fix: trust the server's `unreadCount` as the upper bound.
    /// If the server says "you have 1 unread", we never display more
    /// than 1 in the badge, regardless of how many `readAt == nil`
    /// rows live in the local cache. We still compute the local count
    /// so the badge can tick down as the user catches up *during this
    /// session* (the server count refreshes on next conversation-list
    /// fetch, not in real time).
    ///
    /// Empty-myId guard remains: `AuthService.shared.currentUser?.id`
    /// is briefly nil during cold launch / token refresh — return 0
    /// in that window so the badge doesn't flash with a wrong number.
    private var scrollUnreadCount: Int {
        guard let myId = AuthService.shared.currentUser?.id, !myId.isEmpty else {
            return 0
        }
        let local = messageStore.messages.filter { msg in
            msg.readAt == nil &&
            !msg.senderId.isEmpty &&
            !userIdsMatch(msg.senderId, myId)
        }.count

        // Server is authoritative. If the server says 0, display 0
        // even if local readAt bookkeeping is stale; if the server
        // says N, never display more than N. This tames the "stale
        // readAt accumulator" bug end users see as a "71" badge on
        // a quiet conversation.
        if let serverUnread = liveConversation?.unreadCount {
            return min(local, serverUnread)
        }
        return local
    }

    /// Composite gate for the floating scroll-to-bottom button.
    /// `showScrollToBottom` (driven by `onScrollGeometryChange`) is
    /// the geometric signal — the user is more than 200pt from the
    /// bottom of the scroll view. We additionally suppress the button
    /// when:
    ///   • there are no peer unread messages (the user is caught up —
    ///     we already saw the bottom, the geometry just hasn't ticked),
    ///   • the most recent message in the thread is ours (we just
    ///     sent — by definition the bottom is in view).
    /// These two gates fix the screenshot regression where `71↓` was
    /// floating on top of the user's just-sent bubble.
    private var shouldShowScrollButton: Bool {
        guard showScrollToBottom else { return false }
        // Caught up — server says no unread peer messages.
        if (liveConversation?.unreadCount ?? 0) == 0 && scrollUnreadCount == 0 {
            return false
        }
        // Last message is ours — we're at the bottom even if the
        // geometry observer hasn't caught up yet.
        if let last = messageStore.messages.last,
           let myId = AuthService.shared.currentUser?.id, !myId.isEmpty,
           userIdsMatch(last.senderId, myId) {
            return false
        }
        return true
    }

    /// The active-banner above the composer for the disappearing-message
    /// default. Pulled into a computed view to keep the input-bar VStack
    /// shallow enough for SwiftUI's @ViewBuilder type-checker.
    @ViewBuilder
    private var disappearingBanner: some View {
        if !conversation.isGroup, let mode = expiryMode, mode != .none {
            DisappearingActiveBanner(mode: mode) {
                showExpiryPicker = true
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Best-effort populate `savedMessageIds` so the context menu shows
    /// "Remove from Saved" vs "Save" for currently-visible bubbles. We
    /// fetch the user's whole saved list (server caps at 200) and project
    /// the message ids that belong to the open thread.
    private func loadSavedSet() async {
        do {
            let all = try await NetworkService.shared.listSavedMessages()
            let visibleIds: Set<String> = Set(messageStore.messages.compactMap { $0.serverId ?? $0.id })
            self.savedMessageIds = Set(all.compactMap { row in
                visibleIds.contains(row.messageId) ? row.messageId : nil
            })
        } catch {
            #if DEBUG
            print("⭐ [Save] initial load failed: \(error)")
            #endif
        }
    }

    private func serverIdOrLocal(_ msg: ChatMessage) -> String {
        msg.serverId ?? msg.id
    }

    // MARK: - In-thread search helpers

    private var searchResultLabel: String? {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isSearching { return "Searching…" }
        switch searchResults.count {
        case 0: return "No matches"
        case 1: return "1 match"
        default: return "\(searchResults.count) matches"
        }
    }

    private func runSearch(force: Bool) {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await runSearchInline(query: trimmed) }
    }

    private func runSearchInline(query: String) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let hits = try await NetworkService.shared.searchThread(
                peerId: conversation.peer.userId, query: query
            )
            searchResults = hits
            // Auto-jump to the most recent (first) hit so the user sees the
            // result immediately without an extra tap. They can keep typing
            // to refine.
            if let top = hits.first {
                jumpToMessage(serverId: top.id)
            }
        } catch {
            #if DEBUG
            print("❌ [Search] failed: \(error)")
            #endif
            searchResults = []
        }
    }

    /// Resolve a server message id to the local client id, scroll to the
    /// matching bubble, and pulse-highlight it for ~0.9 s. Used by both
    /// in-thread search hits and reply preview taps.
    func jumpToMessage(serverId: String) {
        let localId = messageStore.messages.first(where: { $0.serverId == serverId || $0.id == serverId })?.id
        guard let localId else { return }
        Haptics.selection()
        pulseMessageId = localId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if pulseMessageId == localId { pulseMessageId = nil }
        }
        // The ScrollViewReader's proxy lives inside the body; use the
        // pulseMessageId observation in the message ForEach to drive the
        // visible scroll. We post via an internal NotificationCenter so the
        // proxy can act on it.
        NotificationCenter.default.post(
            name: .chatScrollToMessage,
            object: nil,
            userInfo: ["messageId": localId]
        )
    }

    /// Returns the set of message IDs that should be preceded by a date
    /// separator (a "Today" / "Yesterday" / formatted-date chip). The first
    /// message always gets one; subsequent ones get one whenever the calendar
    /// day rolls over from the previous message.
    private func precomputeDateHeaders(messages: [ChatMessage]) -> Set<String> {
        guard !messages.isEmpty else { return [] }
        var result = Set<String>()
        result.reserveCapacity(messages.count / 4)
        let calendar = Calendar.current
        var lastDay: Date?
        for msg in messages {
            let day = calendar.startOfDay(for: msg.timestamp)
            if lastDay == nil || day != lastDay {
                result.insert(msg.id)
                lastDay = day
            }
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
                unseenByMe = messageStore.messages
                    .filter { !senderIsMe($0.senderId) && $0.status != .read && $0.type != .ephemeralPhoto }
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

    // MARK: - Share Friend

    /// Share a Raven friend's profile as a postcard message — avatar +
    /// display name + @username + QR deep link to the profile, rendered by
    /// `ContactCardMessageView` on the recipient side. Routed through
    /// `MessageRouter` (server first, mesh fallback) like every other
    /// attachment type.
    private func shareFriend(_ friend: GroupFriendInfo) {
        // Honor the local "allow others to share my contact" preference if
        // the friend being shared IS the current user (rare — sharing your
        // own card is fine and always allowed). For other users, the server
        // is the trust boundary: it rejects the send if the *target* friend
        // has opted out. We don't pre-flight that here because the client
        // doesn't have the target's preference cached.
        let recipientId = conversation.isGroup ? conversation.roomId : conversation.peer.userId
        let isGroup = conversation.isGroup
        Task {
            do {
                try await MessageService.shared.sendContactShare(
                    friend: friend,
                    to: recipientId,
                    isGroup: isGroup
                )
            } catch {
                #if DEBUG
                print("⚠️ Failed to share contact: \(error)")
                #endif
                await MainActor.run {
                    self.errorMessage = "Couldn't share contact: \(error.localizedDescription)"
                    self.showErrorAlert = true
                    Haptics.error()
                }
            }
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
    var onReact: ((String) -> Void)? = nil // React with emoji (from contextMenu submenu)
    var onReactMore: (() -> Void)? = nil  // Open full emoji grid sheet for custom reactions
    var onReplyPrivately: (() -> Void)? = nil // Group only: open 1:1 with sender, pre-fill quote
    var onJumpToReply: ((String) -> Void)? = nil // Tap reply preview → scroll to original
    var isGroupChat: Bool = false       // Whether this is a group chat
    var isChannel: Bool = false         // Whether this is a channel
    var isPrivateChannel: Bool = false
    var onPublish: ((String) -> Void)? = nil // Publish to feed
    var onTogglePin: (() -> Void)? = nil   // Pin/unpin (visible to all participants)
    var onToggleSave: (() -> Void)? = nil  // Save/unsave to private bookmarks
    var onShowInfo: (() -> Void)? = nil    // Sent/Delivered/Read timeline popover (own msg only)
    var isPinned: Bool = false             // Render the pin glyph in metadata row + show Unpin in menu
    var isSaved: Bool = false              // Toggle Save vs. Unsave label in menu
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
                        isFromMe: isFromMe,
                        onTap: message.replyToMessageId.map { id in
                            { onJumpToReply?(id) }
                        }
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
                    expiryBadge
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
                // 🆕 Capture the inner bubble's screen frame so the
                // long-press overlay can clone + position around the
                // actual visible bubble (not the full row width).
                .modifier(BubbleFrameReporter(messageId: message.id))
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

    /// "edited" italic label rendered in the bubble metadata row when the
    /// sender has edited a non-media message.
    @ViewBuilder
    private var editedLabel: some View {
        if message.editedAt != nil && !isMediaType {
            Text("edited")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.7))
                .italic()
        }
    }

    /// Countdown chip for disappearing messages whose server-side
    /// `expires_at` is in the future. Hidden for media types (which have
    /// their own metadata footers) and for regular messages.
    @ViewBuilder
    private var expiryBadge: some View {
        if let expires = message.expiresAt, !isMediaType {
            ExpiryCountdownBadge(expiresAt: expires)
        }
    }

    // Detect mistyped postShare / contactCard messages stored as .text
    // (older clients that didn't know the type, or DB rows whose
    // `MessageType.from(name:)` mapping fell back to text — that bug was
    // the original "postcard renders as raw JSON" repro.)
    private var effectiveType: MessageType {
        if message.type == .text,
           let text = message.text {
            if text.contains("\"postId\""),
               text.contains("\"authorUsername\""),
               PostSharePayload.decode(from: text) != nil {
                return .postShare
            }
            if text.contains("\"userId\""),
               text.contains("\"username\""),
               text.contains("\"displayName\""),
               ContactSharePayload.decode(from: text) != nil {
                return .contactCard
            }
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

        case .contactCard:
            ContactCardMessageView(message: message, isFromMe: isFromMe)

        case .poll:
            // Poll bubble — fetches its own live tally; the chat just
            // hands over the (groupId, pollId) pair. Falls back to the
            // text announcement bubble if the message is missing pollId
            // (e.g. an old client persisted only the text "📊 X created…").
            if let groupId = groupId, let pid = message.pollId {
                PollBubbleView(groupId: groupId, pollId: pid)
            } else {
                mentionHighlightedText
            }

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
        message.type == .voice || message.type == .video || message.type == .videoNote || message.type == .ephemeralPhoto || message.type == .postShare || message.type == .contactCard
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

        // Route badge (server / direct mesh / mesh bridge) — shown alongside
        // the delivery checkmarks so the user can tell HOW the message landed.
        let routeBadge = Image(systemName: message.routeIcon)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(baseColor.opacity(0.85))
            .accessibilityLabel(message.uiRouteLabel)

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
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle").foregroundStyle(baseColor)
                routeBadge
            }
        case .sent:
            HStack(spacing: 3) {
                Image(systemName: "checkmark").foregroundStyle(baseColor)
                routeBadge
            }
        case .delivered:
            HStack(spacing: 3) {
                Image(systemName: "checkmark").foregroundStyle(doneColor)
                routeBadge
            }
        case .read:
            HStack(spacing: 3) {
                HStack(spacing: -4) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .foregroundStyle(readColor)
                routeBadge
            }
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
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            Haptics.light()
            onTap?()
        } label: {
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
        .buttonStyle(.plain)
        .disabled(onTap == nil)
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
        case .contactCard: return "👤 Shared contact"
        case .poll: return "📊 Poll"
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
        case .contactCard: return "person.crop.rectangle.stack.fill"
        case .poll: return "chart.bar.doc.horizontal.fill"
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
        // Mistyped contact-card stored as text — recognise the JSON shape
        // so the reply composer doesn't show a `{"displayName":...}` blob.
        if ContactSharePayload.looksLikeContactCard(text) {
            return "Shared contact"
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
        case .contactCard: return "Shared contact"
        case .poll: return "Poll"
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
    /// Optional long-press handler that opens the schedule picker.
    /// Hidden when nil so the menu stays empty in unsupported chat types.
    var onSchedule: (() -> Void)? = nil
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
                    // Send button — tap sends now, long-press opens the
                    // schedule picker so the user can defer delivery to
                    // a future time.
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
                    .contextMenu {
                        if let onSchedule {
                            Button {
                                onSchedule()
                            } label: {
                                Label("Schedule…", systemImage: "clock")
                            }
                        }
                    }
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
    /// Optional ATSAM security badge shown beneath the status row.
    /// Defaults to `nil` so existing call sites render identically
    /// to the pre-ATSAM layout. Caller sets this once the
    /// per-conversation security mode is wired up.
    var securityMode: SecurityBadgeMode? = nil

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

                if let securityMode {
                    SecurityBadge(mode: securityMode, compact: true)
                        .padding(.top, 2)
                        .transition(.opacity)
                }
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
                        // ⚡ Perf fix (2026-05-14): CachedAsyncImage uses
                        // ImageCache + ImageIO downsampling + auth-header
                        // injection, so the image survives scroll and isn't
                        // re-downloaded/re-decoded on the main thread.
                        // The previous AsyncImage variant flashed the
                        // placeholder every time the cell recycled.
                        CachedAsyncImage(url: imageURL) { image in
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
                        } placeholder: {
                            placeholderView(icon: "photo", showProgress: message.syncState == .uploading)
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

    /// True when THIS bubble is the message currently playing in the
    /// global AudioPlaybackStore (so the speed pill only shows up on
    /// the active voice — same UX rule as the live progress fill).
    private var isActivePlayback: Bool {
        let mid = message.serverId ?? message.id
        return audioStore.currentItem?.id == mid
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
                
                // Modern waveform visualization — smooth rounded bars.
                // Tappable + draggable: while this message is the active item
                // in the shared AudioPlaybackStore, you can scrub the play
                // head by tapping or dragging across the bars.
                GeometryReader { geo in
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
                    .frame(width: geo.size.width, height: 22, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard audioStore.currentItem?.id == message.id else { return }
                                let fraction = max(0, min(1, value.location.x / max(1, geo.size.width)))
                                audioStore.seek(to: Double(fraction))
                                localProgress = Double(fraction)
                                localCurrentTime = Double(fraction) * Double(duration)
                            }
                    )
                }
                .frame(height: 22)

                // Duration — current time while playing, total length while paused.
                Text(localIsPlaying || localProgress > 0 ? formatTime(localCurrentTime) : formattedDuration)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                // 🆕 Playback-speed pill — only renders when this voice
                // message is the active one in the global player (so we
                // don't clutter every paused bubble with a 1× chip). Tap
                // cycles 1× → 1.5× → 2× → 1× via AudioPlaybackStore.
                if isActivePlayback {
                    PlaybackSpeedPill(rate: audioStore.playbackRate, tint: accentColor) {
                        Haptics.light()
                        audioStore.cycleRate()
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isActivePlayback)
            
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
        // Pull `repairedUrl` (a SwiftUI @State property, MainActor-isolated)
        // off the actor BEFORE entering the detached task so we don't read it
        // from the wrong context.
        let repairedSnapshot = repairedUrl
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
            if let url = AppConfig.mediaURL(from: repairedSnapshot) {
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
                    // Uses CachedAsyncImage so link previews don't re-fetch
                    // every time the message bubble enters the viewport.
                    if let thumbUrl = payload.thumbUrl, let url = URL(string: thumbUrl) {
                        CachedAsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: 200)
                                .clipped()
                        } placeholder: {
                            Rectangle()
                                .fill(Color.primary.opacity(0.04))
                                .frame(height: 100)
                                .overlay {
                                    ProgressView()
                                        .tint(.secondary.opacity(0.5))
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
                // ⚡ Tap = open the shared post in the feed. If the payload
                // didn't decode (encrypted / not yet received), fall back
                // to the previous expand-card behaviour.
                if let postId = payload?.postId, !postId.isEmpty {
                    DeepLinkRouter.shared.route(to: .post(postId: postId))
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        isExpanded.toggle()
                    }
                }
            }
            .onLongPressGesture {
                // Long-press still toggles the expanded preview without leaving the chat
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
            // Intercept ALL link taps inside the chat tree. SwiftUI's
            // `Text(String)` auto-detects URLs and, by default, opens
            // them via `UIApplication.shared.open(_:)` — which jumps
            // out to system Safari. We want every link (inline text,
            // mention sheet, link-preview card, reply bubble, etc.) to
            // present the same in-app `SafariSheet` the feed uses, so
            // the user stays inside the chat surface. Audio-room raven
            // deep-links keep their existing routing path; everything
            // else becomes `selectedLinkURL` which drives the sheet
            // below.
            .environment(\.openURL, OpenURLAction { url in
                let components = url.pathComponents.filter { $0 != "/" }
                if (url.host == "raven.app" || url.host == "www.raven.app"),
                   components.count >= 2,
                   components[0] == "room" {
                    DeepLinkRouter.shared.route(to: .audioRoom(slug: components[1]))
                    return .handled
                }
                if url.scheme == "raven", url.host == "room", let slug = components.first {
                    DeepLinkRouter.shared.route(to: .audioRoom(slug: slug))
                    return .handled
                }
                // The keyboard auto-dismisses when the SafariSheet
                // takes over the screen, so we don't need to fiddle
                // with FocusState from inside this modifier struct.
                selectedLinkURL = url
                return .handled
            })
            .sheet(item: $selectedLinkURL) { url in
                // SFSafariViewController — fast cold-start. The
                // .presentationDetents() modifier is dropped: SFSafari
                // owns its own presentation chrome, partial-sheet
                // detents don't apply to system view controllers.
                SafariSheet(url: url)
                    .ignoresSafeArea()
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

// MARK: - Date Separator

/// Centred chip shown above the first message of each calendar day.
/// "Today" / "Yesterday" for the recent past, weekday for the last week,
/// medium-style date otherwise.
struct ChatDateSeparator: View {
    let date: Date

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE"
        return f
    }()

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day,
           days < 7 {
            return Self.weekdayFormatter.string(from: date)
        }
        return Self.mediumFormatter.string(from: date)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(label)
    }
}

// ===== from MessageReactionStore.swift =====
// MARK: - Message Reaction Store
// Per-conversation cache of message reactions. Mirrors the `ReadReceiptStore`
// pattern: an @Observable holding a `[messageId: [Reaction]]` map, fed
// (a) from the network on first paint, and (b) live from the inbox
// WebSocket event `message_reaction` so reactions land on every device the
// moment they're toggled.

@MainActor
@Observable
final class MessageReactionStore {

    /// Single reaction record. Stored client-side as we receive them.
    struct Reaction: Identifiable, Hashable {
        let id: String
        let userId: String
        let emoji: String
        let createdAt: Date
    }

    /// Map of `messageId → reactions`. The view layer reads from here.
    var reactions: [String: [Reaction]] = [:]

    private var roomId: String = ""
    private var isGroup: Bool = false
    private var observer: NSObjectProtocol?

    // MARK: - Loading

    /// Best-effort load for a batch of message IDs. We don't have a server
    /// batch endpoint, so we fan out small requests in parallel; misses are
    /// silent (just no chips for that message).
    func load(messageIds: [String]) async {
        guard !messageIds.isEmpty else { return }
        let isGroup = self.isGroup
        await withTaskGroup(of: (String, [NetworkService.MessageReactionDTO])?.self) { group in
            for id in messageIds {
                group.addTask {
                    do {
                        let dtos = try await NetworkService.shared.messageReactions(
                            messageId: id, isGroup: isGroup
                        )
                        return (id, dtos)
                    } catch {
                        return nil
                    }
                }
            }
            for await result in group {
                guard let (msgId, dtos) = result else { continue }
                self.reactions[msgId] = dtos.map {
                    Reaction(id: $0.id, userId: $0.userId, emoji: $0.emoji, createdAt: $0.createdAt)
                }
            }
        }
    }

    // MARK: - Toggling

    /// Each user can have up to this many distinct reactions per message.
    /// Mirrors Instagram. Server enforces the same cap and authoritatively
    /// evicts the oldest when the user adds a 4th.
    static let maxReactionsPerUser = 3

    /// Optimistically flip the reaction locally, then ask the server to
    /// reconcile. The server response is the authoritative list; on failure
    /// we revert.
    func toggle(messageId: String, emoji: String, currentUserId: String) async {
        let before = reactions[messageId] ?? []

        // Optimistic flip
        if let idx = before.firstIndex(where: { $0.userId == currentUserId && $0.emoji == emoji }) {
            var copy = before
            copy.remove(at: idx)
            reactions[messageId] = copy
        } else {
            var copy = before
            // Cap: if the user already has 3 reactions on this message,
            // evict the OLDEST so the new emoji takes its place. Matches
            // the server-side cap so the optimistic count stays correct.
            let mine = copy
                .enumerated()
                .filter { $0.element.userId == currentUserId }
                .sorted { $0.element.createdAt < $1.element.createdAt }
            if mine.count >= Self.maxReactionsPerUser, let oldest = mine.first {
                copy.remove(at: oldest.offset)
            }
            copy.append(Reaction(
                id: "local-\(UUID().uuidString)",
                userId: currentUserId,
                emoji: emoji,
                createdAt: Date()
            ))
            reactions[messageId] = copy
        }

        do {
            let resp = try await NetworkService.shared.toggleMessageReaction(
                messageId: messageId, emoji: emoji, isGroup: isGroup
            )
            reactions[messageId] = resp.reactions.map {
                Reaction(id: $0.id, userId: $0.userId, emoji: $0.emoji, createdAt: $0.createdAt)
            }
        } catch {
            // Revert on failure
            reactions[messageId] = before
            #if DEBUG
            print("❌ [Reactions] toggle failed: \(error)")
            #endif
        }
    }

    // MARK: - Real-time updates from /ws/inbox

    func setupObservers(roomId: String, isGroup: Bool) {
        self.roomId = roomId
        self.isGroup = isGroup
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: .messageReactionUpdated,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let messageId = info["messageId"] as? String,
                  let raw = info["reactions"] as? [[String: Any]] else { return }
            let updated: [Reaction] = raw.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let userId = dict["user_id"] as? String,
                      let emoji = dict["emoji"] as? String else { return nil }
                let createdRaw = dict["created_at"] as? String
                let created = createdRaw.flatMap { PerformanceConstants.iso8601Fractional.date(from: $0) }
                            ?? createdRaw.flatMap { PerformanceConstants.iso8601.date(from: $0) }
                            ?? Date()
                return Reaction(id: id, userId: userId, emoji: emoji, createdAt: created)
            }
            Task { @MainActor in
                self.reactions[messageId] = updated
            }
        }
    }

    func removeObservers() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
    }

    // MARK: - View helpers

    /// Reactions for a message, grouped + sorted with mine first then by count.
    func grouped(for messageId: String, currentUserId: String) -> [GroupedReaction] {
        let all = reactions[messageId] ?? []
        guard !all.isEmpty else { return [] }
        var bins: [String: [Reaction]] = [:]
        for r in all { bins[r.emoji, default: []].append(r) }
        return bins.map { emoji, list in
            GroupedReaction(
                emoji: emoji,
                count: list.count,
                userIds: list.map(\.userId),
                mine: list.contains(where: { $0.userId == currentUserId })
            )
        }
        .sorted { lhs, rhs in
            if lhs.mine != rhs.mine { return lhs.mine && !rhs.mine }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.emoji < rhs.emoji
        }
    }
}

struct GroupedReaction: Hashable, Identifiable {
    let emoji: String
    let count: Int
    let userIds: [String]
    let mine: Bool
    var id: String { emoji }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by RealtimeEngine when the server sends a `message_reaction`
    /// event. UserInfo: `["messageId": String, "reactions": [[String:Any]]]`.
    static let messageReactionUpdated = Notification.Name("MessageReactionUpdated")

    /// Posted by RealtimeEngine when the server sends a `message_edited`
    /// event. UserInfo: `["messageId": String, "content": String, "editedAt": Date]`.
    static let messageEditedRemote = Notification.Name("MessageEditedRemote")

    /// Posted by RealtimeEngine when the server sends a `typing` event.
    /// UserInfo: `["roomId": String, "byUserId": String, "byUsername": String,
    ///            "isTyping": Bool, "isGroup": Bool]`.
    static let chatTypingUpdated = Notification.Name("ChatTypingUpdated")

    /// Posted by ChatView when a search hit / reply preview wants the
    /// thread scrolled to a specific message. UserInfo: `["messageId": String]`.
    static let chatScrollToMessage = Notification.Name("ChatScrollToMessage")
}

// ===== from ReactionPickerCapsule.swift =====
// MARK: - Reaction Picker Capsule
// A horizontal Liquid Glass capsule with the six default emojis. Each emoji
// is a circular tap target inside the capsule; the capsule itself uses
// `.ultraThinMaterial` (so it adapts to light/dark) and is sized to the
// content. Designed to be parked above a message bubble on long-press.

struct ReactionPickerCapsule: View {
    let onPick: (String) -> Void
    var onPickMore: (() -> Void)? = nil
    /// Set so the picker can render the user's existing reaction with an
    /// active tint, mirroring iMessage / Messenger conventions.
    var activeEmojis: Set<String> = []

    @Environment(\.colorScheme) private var colorScheme

    /// Default reaction set — same six emojis Apple Messages uses, plus a
    /// "+" to open the full picker.
    static let defaultEmojis: [String] = ["❤️", "👍", "😂", "😮", "😢", "🙏"]

    @State private var appeared = false
    /// 🎨 UX FIX (2026-05-11): drag-to-pick. Index of the emoji the
    /// user is currently hovering over with their finger. Set during
    /// `DragGesture.onChanged`, scales that tile up 1.4× as a preview;
    /// committed on `onEnded`. Mirrors Instagram / iMessage / WhatsApp
    /// where the long-press gesture flows directly into the pick
    /// without a separate tap. Selection-tick haptic on hover changes.
    @State private var hoveredIndex: Int? = nil
    /// Captured tile width so the drag math doesn't depend on
    /// GeometryReader inside this view.
    private static let tileWidth: CGFloat = 44 + 6   // tile + spacing

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(Self.defaultEmojis.enumerated()), id: \.offset) { idx, emoji in
                EmojiTile(
                    emoji: emoji,
                    isActive: activeEmojis.contains(emoji),
                    delay: Double(idx) * 0.025,
                    appeared: appeared,
                    isHovered: hoveredIndex == idx
                ) {
                    Haptics.light()
                    onPick(emoji)
                }
            }
            if let onPickMore {
                MoreTile(delay: Double(Self.defaultEmojis.count) * 0.025, appeared: appeared) {
                    Haptics.light()
                    onPickMore()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // 🎨 UX FIX (2026-05-11): swap `.ultraThinMaterial` →
        // `.regularMaterial` and add a subtle contrast tint underneath.
        // The previous capsule was almost invisible against light
        // bubbles. We also bump the shadow (radius 18 → 24, opacity
        // 0.10 → 0.16 in light mode) so the picker feels properly
        // floating.
        .background(
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.04))
        )
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.16), radius: 24, y: 10)
        .scaleEffect(appeared ? 1 : 0.85, anchor: .bottom)
        .opacity(appeared ? 1 : 0)
        // 🎨 UX FIX (2026-05-11) revised: drag-to-pick gesture that
        // ONLY activates after 8pt of movement. Quick taps fall
        // through to the existing EmojiTile / MoreTile Buttons
        // (preserves the `+` → onPickMore path AND avoids double-
        // firing the haptic). When the user actually drags, hover
        // preview + release-to-pick mirrors Instagram / iMessage.
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    // 10pt of capsule horizontal padding offsets the
                    // first tile's left edge from the capsule edge.
                    let xInTiles = value.location.x - 10
                    let raw = Int(xInTiles / Self.tileWidth)
                    let inRange = raw >= 0 && raw < Self.defaultEmojis.count
                    let new: Int? = inRange ? raw : nil
                    if new != hoveredIndex {
                        if new != nil { Haptics.selection() }
                        withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) {
                            hoveredIndex = new
                        }
                    }
                }
                .onEnded { _ in
                    if let idx = hoveredIndex {
                        Haptics.light()
                        onPick(Self.defaultEmojis[idx])
                    }
                    hoveredIndex = nil
                }
        )
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) {
                appeared = true
            }
        }
    }
}

private struct EmojiTile: View {
    let emoji: String
    let isActive: Bool
    let delay: Double
    let appeared: Bool
    /// 🎨 UX FIX (2026-05-11): drives the drag-hover preview scale.
    /// Set externally by `ReactionPickerCapsule`'s drag gesture.
    /// Defaults to false so existing tap-only call sites still work.
    var isHovered: Bool = false
    let action: () -> Void

    @State private var bounced = false

    var body: some View {
        Button(action: {
            // Punchy "pick" animation — scale up much further so the user
            // visually sees the emoji "leaping toward" the bubble before
            // the chip lands. The action then triggers the toggle.
            withAnimation(.spring(response: 0.20, dampingFraction: 0.45)) { bounced = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) { bounced = false }
            }
            action()
        }) {
            Text(emoji)
                // 🎨 UX FIX (2026-05-11): size up to match Instagram/
                // iMessage. 22pt was a touch too small given the new
                // capsule prominence; 28pt + 44pt frame also satisfies
                // Apple's 44×44pt minimum tap-target HIG.
                .font(.system(size: 28))
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(
                            isActive ? Color.accentColor.opacity(0.5) : Color.clear,
                            lineWidth: 1
                        )
                )
                // Hover preview (drag-to-pick) scales the tile under
                // the user's finger, then the bounce takes over on
                // release. Pick MAX so the bounce wins if both are
                // active in the same frame.
                .scaleEffect(max(bounced ? 1.6 : 1.0, isHovered ? 1.4 : 1.0))
                .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isHovered)
        }
        .buttonStyle(.plain)
        .scaleEffect(appeared ? 1 : 0.4)
        .opacity(appeared ? 1 : 0)
        .animation(
            .spring(response: 0.36, dampingFraction: 0.7).delay(delay),
            value: appeared
        )
    }
}

private struct MoreTile: View {
    let delay: Double
    let appeared: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // 🎨 UX FIX (2026-05-11): scaled to match the new 44pt
            // emoji frames and softened with `.secondary` so it reads
            // as "more" rather than competing visually with the emoji
            // tiles.
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(appeared ? 1 : 0.4)
        .opacity(appeared ? 1 : 0)
        .animation(
            .spring(response: 0.36, dampingFraction: 0.7).delay(delay),
            value: appeared
        )
    }
}

// ===== from ReactionChipsRow.swift =====
// MARK: - Reaction Chips Row
// Renders the grouped reactions for a single message as a row of small
// capsule chips. Each chip shows its emoji + count; tapping it toggles the
// current user's reaction. The user's own reaction is highlighted with a
// tinted fill and a thin tinted stroke.

struct ReactionChipsRow: View {
    let groups: [GroupedReaction]
    let isFromMe: Bool
    let onTap: (String) -> Void
    /// Long-press handler — used on group chats to show "who reacted"
    /// in a Liquid Glass sheet. Pass nil in DMs (the sender is obvious).
    var onLongPress: ((GroupedReaction) -> Void)? = nil

    var body: some View {
        if groups.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                ForEach(groups) { group in
                    ReactionChip(
                        group: group,
                        action: { onTap(group.emoji) },
                        onLongPress: onLongPress.map { handler in
                            { handler(group) }
                        }
                    )
                    // Punchy entrance: start tiny + slightly above the
                    // resting position, spring down with overshoot —
                    // mirrors the "emoji lands on the bubble" feel from
                    // Instagram / Telegram.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.15)
                            .combined(with: .opacity)
                            .combined(with: .offset(y: -8)),
                        removal: .scale(scale: 0.4).combined(with: .opacity)
                    ))
                }
            }
            .frame(maxWidth: .infinity, alignment: isFromMe ? .trailing : .leading)
            // More bounce: lower damping → noticeable overshoot when the
            // chip lands. The previous 0.78 damping was too quick to
            // settle for a "reaction" gesture.
            .animation(.spring(response: 0.42, dampingFraction: 0.55), value: groups)
        }
    }
}

private struct ReactionChip: View {
    let group: GroupedReaction
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    @State private var pressed = false

    var body: some View {
        Button(action: {
            Haptics.selection()
            withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { pressed = false }
            }
            action()
        }) {
            HStack(spacing: 3) {
                Text(group.emoji)
                    .font(.system(size: 13))
                if group.count > 1 {
                    Text("\(group.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(group.mine ? Color.accentColor : .secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, group.count > 1 ? 8 : 6)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(group.mine ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        group.mine ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.10),
                        lineWidth: 0.5
                    )
            )
            .scaleEffect(pressed ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.35) {
            Haptics.medium()
            onLongPress?()
        }
    }
}

// ===== from TypingIndicatorCapsule.swift =====
// MARK: - Typing Indicator Capsule
// Liquid Glass capsule with three softly-pulsing dots. Sized to nestle in
// the same column as incoming bubbles, so the visual rhythm doesn't break
// when the indicator appears between messages.

struct TypingIndicatorCapsule: View {
    /// "Alex" / "Alex and Sam" / "Alex and 2 others"
    var presenceLabel: String? = nil

    @State private var phase: Double = 0
    @State private var visible = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(scale(for: i))
                        .opacity(opacity(for: i))
                }
            }

            if let presenceLabel, !presenceLabel.isEmpty {
                Text(presenceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .scaleEffect(visible ? 1 : 0.85, anchor: .bottomLeading)
        .opacity(visible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { visible = true }
            // Drive the dot animation with a continuous phase so we don't
            // chain three independent withAnimation timers.
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .onDisappear {
            visible = false
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(presenceLabel ?? "Someone") is typing"))
    }

    private func scale(for i: Int) -> CGFloat {
        // Each dot's "wave" peaks 0.25 cycles after the previous one.
        let offset = Double(i) * 0.25
        let local = (phase - offset).truncatingRemainder(dividingBy: 1)
        let normalised = local < 0 ? local + 1 : local
        // sin pulse — 0..1..0 across the cycle; remap to 0.7..1.4.
        let s = sin(normalised * .pi)
        return 0.7 + CGFloat(max(0, s)) * 0.7
    }

    private func opacity(for i: Int) -> Double {
        let offset = Double(i) * 0.25
        let local = (phase - offset).truncatingRemainder(dividingBy: 1)
        let normalised = local < 0 ? local + 1 : local
        return 0.45 + max(0, sin(normalised * .pi)) * 0.55
    }
}

// ===== from TypingPresenceStore.swift =====
// MARK: - Typing Presence Store
// Tracks who in the current chat is typing right now, with auto-expiration
// (peers stop "typing" 5 s after their last `is_typing=true` event, in case
// we miss the false event). One store per open ChatView.

@MainActor
@Observable
final class TypingPresenceStore {

    /// Map of `userId → username`. When this is non-empty, render the
    /// indicator. We keep usernames so groups can show "Alex and Sam are
    /// typing…" without a separate lookup.
    private(set) var typingUsers: [String: String] = [:]

    /// Per-user expiry timers — each `is_typing=true` resets the 5-s clock.
    private var expirations: [String: Task<Void, Never>] = [:]

    private var roomId: String = ""
    private var isGroup: Bool = false
    private var currentUserId: String = ""
    private var observer: NSObjectProtocol?

    func setupObservers(roomId: String, isGroup: Bool, currentUserId: String) {
        self.roomId = roomId
        self.isGroup = isGroup
        self.currentUserId = currentUserId
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: .chatTypingUpdated,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let evtRoomId = info["roomId"] as? String,
                  let byUserId = info["byUserId"] as? String,
                  let byUsername = info["byUsername"] as? String,
                  let isTyping = info["isTyping"] as? Bool else { return }

            // Filter to events for this room. For DMs the server sends
            // `room_id = actor's user id` (matching the client's roomId
            // convention); for groups it's the group id. The store's own
            // identifying fields are MainActor-isolated, so do the filter
            // (and any state mutation) inside a MainActor hop.
            Task { @MainActor in
                guard evtRoomId == self.roomId, byUserId != self.currentUserId else { return }
                if isTyping {
                    self.typingUsers[byUserId] = byUsername
                    self.armExpiry(for: byUserId)
                } else {
                    self.typingUsers.removeValue(forKey: byUserId)
                    self.expirations[byUserId]?.cancel()
                    self.expirations.removeValue(forKey: byUserId)
                }
            }
        }
    }

    func removeObservers() {
        if let obs = observer {
            NotificationCenter.default.removeObserver(obs)
            observer = nil
        }
        for (_, task) in expirations { task.cancel() }
        expirations.removeAll()
        typingUsers.removeAll()
    }

    private func armExpiry(for userId: String) {
        expirations[userId]?.cancel()
        expirations[userId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.typingUsers.removeValue(forKey: userId)
                self.expirations.removeValue(forKey: userId)
            }
        }
    }

    /// Pretty label for the indicator. `nil` if nobody is typing.
    var presenceLabel: String? {
        let names = typingUsers.values.sorted()
        switch names.count {
        case 0: return nil
        case 1: return "\(names[0]) is typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "\(names[0]) and \(names.count - 1) others are typing…"
        }
    }
}

// ===== from InThreadSearchBar.swift =====
// MARK: - In-Thread Search Bar
// Capsule TextField with magnifier on the left and an X to clear / dismiss.
// Slides down from the chat header when the user taps the search icon.

struct InThreadSearchBar: View {
    @Binding var query: String
    let isSearching: Bool
    let resultLabel: String?
    let onSubmit: () -> Void
    let onClear: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search in this chat", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { onSubmit() }

            if isSearching {
                ProgressView()
                    .scaleEffect(0.7)
            }

            if !query.isEmpty {
                Button {
                    Haptics.light()
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            Button("Done") {
                Haptics.light()
                onClear()
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .overlay(alignment: .bottomLeading) {
            if let resultLabel {
                Text(resultLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
                    .padding(.bottom, -10)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: query.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: resultLabel)
        .onAppear { focused = true }
    }
}


// ===== from PinnedMessageStore.swift =====
// MARK: - Pinned Message Store
//
// Per-room cache of pinned-message snapshots, fed (a) by an initial GET
// against /api/messages/conversation/{peer}/pinned (or .../group/{id}/pinned),
// and (b) by the `MessagePinnedUpdated` notification posted by RealtimeEngine
// whenever a `message_pinned` WS frame lands. Optimistic toggle through
// `togglePin(messageId:pinned:)` flips the local state, calls the server,
// and falls back to a reload on failure.

@MainActor
@Observable
final class PinnedMessageStore {

    /// Snapshot of one pinned message — what the pinned-bar renders.
    struct Pin: Identifiable, Hashable {
        let id: String
        let senderUsername: String?
        let senderName: String?
        let content: String?
        let messageType: String
        let pinnedAt: Date
        let pinnedByUserId: String
    }

    /// Newest-pinned-first list. The view layer reads from here.
    var pins: [Pin] = []

    private var roomId: String = ""
    private var isGroup: Bool = false
    private var peerId: String = ""
    private var observer: NSObjectProtocol?

    // MARK: - Loading

    func load() async {
        do {
            let dtos: [NetworkService.PinnedMessageDTO]
            if isGroup {
                dtos = try await NetworkService.shared.pinnedMessagesGroup(groupId: roomId)
            } else {
                dtos = try await NetworkService.shared.pinnedMessagesDM(peerId: peerId)
            }
            self.pins = dtos.map { dto in
                Pin(
                    id: dto.id,
                    senderUsername: dto.senderUsername,
                    senderName: dto.senderName,
                    content: dto.content,
                    messageType: dto.messageType,
                    pinnedAt: dto.pinnedAt,
                    pinnedByUserId: dto.pinnedByUserId
                )
            }
        } catch {
            #if DEBUG
            print("📌 [Pin] load failed: \(error)")
            #endif
        }
    }

    // MARK: - Mutations

    func togglePin(messageId: String, pinned: Bool, snapshot: Pin?) async {
        let before = pins
        // Optimistic flip
        if pinned, let snap = snapshot {
            // Move/insert at top so the bar showcases the freshest pin.
            pins.removeAll { $0.id == messageId }
            pins.insert(snap, at: 0)
        } else if !pinned {
            pins.removeAll { $0.id == messageId }
        }

        do {
            _ = try await NetworkService.shared.toggleMessagePin(
                messageId: messageId, isGroup: isGroup, pinned: pinned
            )
            // Server is authoritative — reload to get the canonical
            // pinned_at timestamp + ordering.
            await load()
        } catch {
            pins = before
            #if DEBUG
            print("📌 [Pin] toggle failed: \(error)")
            #endif
        }
    }

    // MARK: - Real-time updates

    func setupObservers(roomId: String, isGroup: Bool, peerId: String) {
        self.roomId = roomId
        self.isGroup = isGroup
        self.peerId = peerId
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("MessagePinnedUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let mid = info["messageId"] as? String,
                  let evIsGroup = info["isGroup"] as? Bool,
                  evIsGroup == self.isGroup,
                  let pinned = info["pinned"] as? Bool else { return }
            // Best-effort delta apply. If we don't have a snapshot for an
            // incoming pin, pull the canonical list from the server.
            if !pinned {
                self.pins.removeAll { $0.id == mid }
            } else if !self.pins.contains(where: { $0.id == mid }) {
                Task { @MainActor [weak self] in await self?.load() }
            }
        }
    }

    func removeObservers() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // MARK: - Helpers

    func isPinned(messageId: String) -> Bool {
        pins.contains(where: { $0.id == messageId })
    }
}


// ===== from PinnedBarView.swift =====
// MARK: - Pinned Bar (Liquid Glass capsule, sticky-top of the chat)
//
// Renders a single capsule at the top of ChatView showing the current
// "showcase" pinned message. Tapping the capsule cycles through other
// pinned messages and emits a jump-to event for the chat scroller. The
// vertical accent bar mimics Apple's pin-card style.

struct PinnedBarView: View {
    let pins: [PinnedMessageStore.Pin]
    @Binding var showcaseIndex: Int
    /// Called when the user taps the capsule body — the chat should scroll
    /// the original message into view and pulse-highlight it.
    var onJump: (String) -> Void
    /// Called when the user taps the trailing pin-list icon — the chat
    /// presents the full pinned-list sheet.
    var onShowList: () -> Void

    private var current: PinnedMessageStore.Pin? {
        guard !pins.isEmpty else { return nil }
        return pins[showcaseIndex % pins.count]
    }

    var body: some View {
        if let pin = current {
            HStack(spacing: 10) {
                // Vertical accent bar — Apple's pin-card style.
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 3, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.accentColor)
                        Text(pinHeadline(pin))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.accentColor)
                        if pins.count > 1 {
                            Text("· \(pins.count) pinned")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(pinPreview(pin))
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                Button(action: onShowList) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(Color.primary.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .contentShape(Capsule())
            .onTapGesture {
                if pins.count > 1 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        showcaseIndex = (showcaseIndex + 1) % pins.count
                    }
                }
                onJump(pin.id)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(pin.id) // crossfade when the showcase index changes
        }
    }

    private func pinHeadline(_ pin: PinnedMessageStore.Pin) -> String {
        if let n = pin.senderName, !n.isEmpty { return n }
        if let u = pin.senderUsername, !u.isEmpty { return "@\(u)" }
        return "Pinned message"
    }

    private func pinPreview(_ pin: PinnedMessageStore.Pin) -> String {
        switch pin.messageType {
        case "voice": return "🎙 Voice message"
        case "image": return "🖼 Photo"
        case "file":  return "📎 File"
        default:      return pin.content?.replacingOccurrences(of: "\n", with: " ") ?? "Pinned message"
        }
    }
}


// ===== from PinnedListSheet.swift =====
// MARK: - Pinned List Sheet — full list of pinned messages in a thread.

struct PinnedListSheet: View {
    let pins: [PinnedMessageStore.Pin]
    let isGroup: Bool
    var onJump: (String) -> Void
    var onUnpin: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if pins.isEmpty {
                    Text("No pinned messages.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(pins) { pin in
                        Button {
                            dismiss()
                            onJump(pin.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.accentColor)
                                    Text(pinHeadline(pin))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text(pin.pinnedAt.formatted(.relative(presentation: .numeric)))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Text(pinPreview(pin))
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                onUnpin(pin.id)
                            } label: {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pinned")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func pinHeadline(_ pin: PinnedMessageStore.Pin) -> String {
        if let n = pin.senderName, !n.isEmpty { return n }
        if let u = pin.senderUsername, !u.isEmpty { return "@\(u)" }
        return "Pinned message"
    }

    private func pinPreview(_ pin: PinnedMessageStore.Pin) -> String {
        switch pin.messageType {
        case "voice": return "🎙 Voice message"
        case "image": return "🖼 Photo"
        case "file":  return "📎 File"
        default:      return pin.content?.replacingOccurrences(of: "\n", with: " ") ?? "Pinned message"
        }
    }
}


// ===== from SavedMessagesSheet.swift =====
// MARK: - Saved Messages — per-user bookmark sheet, opened from Profile.

@MainActor
struct SavedMessagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [NetworkService.SavedMessageDTO] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "bookmark.slash").font(.largeTitle).foregroundColor(.secondary)
                        Text(error).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bookmark").font(.largeTitle).foregroundColor(.secondary)
                        Text("No saved messages")
                            .font(.headline).foregroundColor(.primary)
                        Text("Long-press any message and tap Save to bookmark it here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "bookmark.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.accentColor)
                                    Text(headline(item))
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Text(item.savedAt.formatted(.relative(presentation: .numeric)))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Text(preview(item))
                                    .font(.system(size: 13))
                                    .lineLimit(3)
                                    .foregroundColor(.primary)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await unsave(item) }
                                } label: {
                                    Label("Remove", systemImage: "bookmark.slash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Saved")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await NetworkService.shared.listSavedMessages()
        } catch {
            self.error = "Couldn't load saved messages."
        }
    }

    private func unsave(_ item: NetworkService.SavedMessageDTO) async {
        try? await NetworkService.shared.unsaveMessage(messageId: item.messageId, isGroup: item.isGroup)
        items.removeAll { $0.id == item.id }
    }

    private func headline(_ item: NetworkService.SavedMessageDTO) -> String {
        if let n = item.senderName, !n.isEmpty { return n }
        if let u = item.senderUsername, !u.isEmpty { return "@\(u)" }
        return "Message"
    }

    private func preview(_ item: NetworkService.SavedMessageDTO) -> String {
        switch item.messageType {
        case "voice": return "🎙 Voice message"
        case "image": return "🖼 Photo"
        case "file":  return "📎 File"
        default:      return item.content ?? ""
        }
    }
}


// ===== from UnreadMessagesDivider.swift =====
// MARK: - Unread Messages Divider
//
// Liquid Glass capsule pinned above the first unread message in the
// thread on chat entry. Stays in place as the user reads — matches
// Telegram/WhatsApp's "Unread messages" line. The horizontal lines on
// either side are subtle so the capsule reads as the focal point.

struct UnreadMessagesDivider: View {
    let count: Int

    private var label: String {
        count == 1 ? "1 unread message" : "\(count) unread messages"
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.30))
                .frame(height: 0.5)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.6)
                        )
                )
            Rectangle()
                .fill(Color.accentColor.opacity(0.30))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 16)
        .accessibilityLabel(label)
    }
}


// ===== from ChatKeyboardShortcuts.swift =====
// MARK: - Chat keyboard shortcuts (iPad / external keyboards on iOS)
//
// Hardware keyboards on iOS (iPad Magic Keyboard, MFi keyboards on
// iPhone) deserve the same chat shortcuts as macOS. Implemented via an
// invisible 0×0 button stack so the keys fire without taking layout
// space. Matches the macOS chatKeyboardShortcuts API for code clarity.

struct ChatKeyboardShortcutsModifier: ViewModifier {
    /// Snapshot of messages — keeps the modifier value-typed so we don't
    /// have to fight the @Observable / @ObservedObject impedance mismatch.
    /// Re-evaluated on each ChatView render, which is fine because the
    /// shortcuts only fire on user keystrokes.
    let messages: [ChatMessage]
    @Binding var showSearchBar: Bool
    @Binding var replyingTo: ChatMessage?
    @Binding var editingMessage: ChatMessage?
    @Binding var inputText: String
    let myUserId: String
    var onScrollToBottom: () -> Void

    func body(content: Content) -> some View {
        content.background(
            VStack(spacing: 0) {
                Button("Find in chat") {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                        showSearchBar.toggle()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Reply to last message") {
                    if let target = messages.reversed().first(where: { $0.senderId != myUserId }) {
                        replyingTo = target
                        editingMessage = nil
                    }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Edit last message") {
                    if let target = messages.reversed().first(where: {
                        $0.senderId == myUserId && $0.type == .text
                    }) {
                        editingMessage = target
                        inputText = target.text ?? ""
                        replyingTo = nil
                    }
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("Scroll to latest") {
                    onScrollToBottom()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Cancel") {
                    if showSearchBar {
                        showSearchBar = false
                    } else if replyingTo != nil {
                        replyingTo = nil
                    } else if editingMessage != nil {
                        editingMessage = nil
                        inputText = ""
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
    }
}

extension View {
    /// Apply the iOS chat keyboard shortcuts. Same key set as macOS:
    /// ⌘F search, ⌘R reply-last, ⌘E edit-last, ⌘↓ scroll-bottom, Esc cancel.
    func chatKeyboardShortcuts(
        messages: [ChatMessage],
        showSearchBar: Binding<Bool>,
        replyingTo: Binding<ChatMessage?>,
        editingMessage: Binding<ChatMessage?>,
        inputText: Binding<String>,
        myUserId: String,
        onScrollToBottom: @escaping () -> Void
    ) -> some View {
        modifier(ChatKeyboardShortcutsModifier(
            messages: messages,
            showSearchBar: showSearchBar,
            replyingTo: replyingTo,
            editingMessage: editingMessage,
            inputText: inputText,
            myUserId: myUserId,
            onScrollToBottom: onScrollToBottom
        ))
    }
}


// ===== from SchedulePickerSheet.swift =====
// MARK: - Schedule Picker Sheet
//
// Liquid Glass sheet for picking a future delivery time for a message.
// Default lands +5 minutes from now to avoid the picker showing a past
// timestamp on first paint. The sheet hands the chosen Date back to the
// caller via `onPick`; the caller fires the actual scheduled send
// through `MessageStore.sendScheduledText`.

struct SchedulePickerSheet: View {
    var onPick: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date = Date().addingTimeInterval(5 * 60)

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Send at", systemImage: "clock")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                    DatePicker(
                        "",
                        selection: $date,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                        )
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("The recipient won't see this message until \(date.formatted(date: .abbreviated, time: .shortened)).")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)

                Spacer()
            }
            .padding(16)
            .navigationTitle("Schedule message")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        Haptics.success()
                        onPick(date)
                        dismiss()
                    }
                    .bold()
                    .disabled(date <= Date())
                }
            }
        }
    }
}


// ===== from PendingReplyStore.swift =====
// MARK: - Pending Reply Store (cross-chat reply hand-off)
//
// When the user picks "Reply privately" on a group message, we need to
// pre-fill the destination 1:1 chat's composer with a quoted reference to
// the original message. This singleton stashes the message keyed by the
// destination peer's userId; the destination ChatView consumes it on
// appear and seeds `replyingTo`. Cleared after consume so it never bleeds
// across navigations.

@MainActor
final class PendingReplyStore {
    static let shared = PendingReplyStore()
    private var pending: [String: ChatMessage] = [:]
    private init() {}

    func setPending(forPeerId peerId: String, message: ChatMessage) {
        pending[peerId] = message
    }

    func consume(forPeerId peerId: String) -> ChatMessage? {
        pending.removeValue(forKey: peerId)
    }
}


// ===== from BubbleActionOverlay.swift =====
// MARK: - Bubble Action Overlay (Instagram-style custom long-press)
//
// Replaces the system .contextMenu(menuItems:preview:) for chat
// bubbles. The system version has two visible quirks the design ask
// rules out:
//   • The preview is always wrapped in a lifted white card (we can
//     see this behind the capsule and bubble). Cannot be disabled.
//   • The chat behind is only dimmed, not blurred. Heavy gaussian blur
//     is the visual hallmark Instagram/Telegram use here.
//
// Anatomy of the custom overlay:
//
//   ┌──────────────────────────────────────┐
//   │  ░░ heavy gaussian blur on chat ░░   │
//   │                                      │
//   │           [reaction capsule]         │  positioned above bubble
//   │           [bubble at its origin]     │  ← clone at captured frame
//   │           [Reply | Forward | …]      │  ← floating menu list
//   │                                      │
//   └──────────────────────────────────────┘
//
// The bubble clone is positioned using the original on-screen frame
// captured via PreferenceKey, so the menu fans out from where the
// user pressed (no jump to center).

struct BubbleActionContext: Identifiable {
    var id: String { message.id }
    let message: ChatMessage
    let isFromMe: Bool
    /// Frame in global screen coords at long-press time.
    let bubbleFrame: CGRect
}

struct BubbleFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// View modifier each bubble attaches so its frame propagates up to
/// ChatView. Background-only: doesn't affect layout.
struct BubbleFrameReporter: ViewModifier {
    let messageId: String
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: BubbleFramePreferenceKey.self,
                        value: [messageId: geo.frame(in: .global)]
                    )
            }
        )
    }
}

/// Action callbacks the overlay can invoke. Captured by ChatView at
/// overlay-render time so each button has access to the same state +
/// helpers the system contextMenu used to call.
struct BubbleOverlayActions {
    var onReply: () -> Void
    var onForward: () -> Void
    var onPin: () -> Void
    var onSave: () -> Void
    var onShowInfo: () -> Void
    var onCopy: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onReact: (String) -> Void
    var onReactMore: () -> Void
    var onReplyPrivately: (() -> Void)?
}

struct BubbleActionOverlay: View {
    let context: BubbleActionContext
    let actions: BubbleOverlayActions
    let activeReactionEmojis: Set<String>
    let isPinned: Bool
    let isSaved: Bool
    var onDismiss: () -> Void

    @State private var appeared = false
    // 2026-05-11 revision: dropped the separate `pickerAppeared` /
    // 80ms-delay sequencing — felt laggy in practice ("aval menu
    // miyad bad picker"). Single-phase entrance feels snappier.

    /// Anchor we lay out from. Use the bubble's original screen position
    /// so the capsule + menu fan out exactly where the user pressed.
    private var anchor: CGPoint {
        CGPoint(
            x: context.bubbleFrame.midX,
            y: context.bubbleFrame.midY
        )
    }

    var body: some View {
        GeometryReader { geo in
            // Translate global bubble frame into the overlay's local
            // coordinate space. Bubble frames are captured with
            // `.frame(in: .global)` (screen coords); the overlay's
            // GeometryReader may sit below the nav bar, so subtract its
            // own global origin to get the right local position.
            let overlayGlobal = geo.frame(in: .global)
            let bubbleW = context.bubbleFrame.width
            let bubbleH = context.bubbleFrame.height
            let bubbleX = context.bubbleFrame.minX - overlayGlobal.minX
            let bubbleY = context.bubbleFrame.minY - overlayGlobal.minY
            let screenH = geo.size.height
            let screenW = geo.size.width

            // 🐛 BUG FIX (2026-05-11): user-reported "متن خیلی میره بالا
            // وقتی long-press می‌کنم". The previous version assumed the
            // menu has 9 rows × 44pt = 412pt, regardless of the actual
            // visible row count. For a typical DM with 6-7 rows
            // (~280pt), that over-estimate forced the bubble to lift
            // ~120-200pt MORE than needed — a message in the lower
            // third of the screen jumped up almost 1/3 of the screen.
            //
            // New behaviour:
            //   1. Count actual rows from `actions` (Reply privately,
            //      Copy, Edit, Delete are conditional on closures).
            //   2. Use the REAL row height (12+12+text ~17 = 41pt) +
            //      0.5pt divider between rows. Add 4pt of inner padding.
            //   3. ALSO require the capsule (60pt above bubble + 8pt
            //      gap) to fit above. The previous code didn't consider
            //      the capsule when calculating overflow.
            //   4. Lift only the minimum amount needed to make the
            //      composition fit between top and bottom safe areas.
            let visibleRowCount: Int = {
                var n = 1                                      // Reply
                if actions.onReplyPrivately != nil { n += 1 }
                n += 1                                         // Forward
                if actions.onCopy != nil { n += 1 }
                n += 2                                         // Pin + Save
                if actions.onEdit != nil { n += 1 }
                n += 1                                         // Info
                if actions.onDelete != nil { n += 1 }
                return n
            }()
            let rowH: CGFloat = 41
            let dividerH: CGFloat = 0.5
            let menuPadding: CGFloat = 4
            let estMenuH: CGFloat = CGFloat(visibleRowCount) * rowH
                                  + CGFloat(max(0, visibleRowCount - 1)) * dividerH
                                  + menuPadding
            let capsuleAboveH: CGFloat = 60
            let menuGap: CGFloat = 12
            let bottomSafe: CGFloat = 40

            let bubbleBottom = bubbleY + bubbleH

            // Where the menu wants to sit at rest:
            let wantBottom = bubbleBottom + menuGap + estMenuH

            // How much shift is needed to fit between top/bottom safe
            // areas? Positive value = lift up; negative = push down.
            // If both ends overflow, lift takes priority (more important
            // not to push the bubble off the top with the capsule than
            // to cut the menu off the bottom — the menu will scroll
            // visually but the picker on top is the primary action).
            // Simplified: lift only enough so the menu's bottom edge
            // clears the bottom safe area. The capsule has its own
            // `max(…, 60)` floor below so it can't go off the top.
            // The previous "smart" branching could return 0 even when
            // overflow existed, leaving the menu/capsule cut off.
            let lift: CGFloat = max(0, wantBottom - (screenH - bottomSafe))
            // `wantTop` is intentionally unused in the simple formula;
            // the capsule's own `max(…, 60)` floor handles top overflow.
            let liftedBubbleY = bubbleY - lift
            let liftedBubbleBottom = bubbleBottom - lift

            ZStack(alignment: .topLeading) {
                // Tap-to-dismiss scrim.
                // 🎨 UX FIX (2026-05-11) FINAL: dropped my added
                // `.ultraThinMaterial` here — the chat behind already
                // applies a heavy `.blur(radius: 18)` (ChatView line
                // 1294) when this overlay is up. Stacking another
                // material on top was the cause of the user-reported
                // lag ("hess mikonm app lag dare"). Now we just dim
                // with a translucent black layer for tap-to-dismiss.
                Color.black
                    .opacity(appeared ? 0.18 : 0)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                // === Reaction capsule above the bubble ===
                // HStack with conditional Spacer aligns the capsule to
                // the bubble's edge (right for sent, left for received)
                // without needing to know the capsule's width up front.
                HStack(spacing: 0) {
                    if context.isFromMe { Spacer(minLength: 0) }
                    ReactionPickerCapsule(
                        onPick: { emoji in
                            actions.onReact(emoji)
                            onDismiss()
                        },
                        onPickMore: {
                            actions.onReactMore()
                            onDismiss()
                        },
                        activeEmojis: activeReactionEmojis
                    )
                    .fixedSize()
                    if !context.isFromMe { Spacer(minLength: 0) }
                }
                // 🐛 BUG FIX (2026-05-11): the previous version did
                // `.frame(width: screenW).padding(.horizontal, 12)`
                // which makes the LAYOUT 24pt wider than the screen
                // — the right-side menu (Reply / Forward / etc) was
                // sliding 12pt off the right edge. Subtract the
                // padding from the frame width so the inner Spacer +
                // menu actually fit inside the screen.
                .frame(width: screenW - 24)
                .padding(.horizontal, 12)
                .offset(y: max(liftedBubbleY - capsuleAboveH, 60))
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.7, anchor: .bottom)

                // === Bubble clone — positioned at the bubble's origin
                // (lifted if needed). Anchored top-left so the offset
                // values map directly to where the bubble was.
                // 🎨 UX FIX (2026-05-11) revised: keep the position
                // EXACTLY at (bubbleX, liftedBubbleY) — no animated
                // 6pt lift. The previous version animated the offset
                // via `.animation(value: appeared)` which combined the
                // initial position computation with the lift, making
                // the clone briefly render in the wrong place during
                // the first frame. Just a static shadow now — the
                // visual "selection" feel comes from the blur backdrop
                // and the lifted picker above, not from animating the
                // bubble itself.
                BubbleClone(message: context.message, isFromMe: context.isFromMe)
                    .frame(width: bubbleW, height: bubbleH, alignment: .topLeading)
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                    .offset(x: bubbleX, y: liftedBubbleY)

                // === Action menu below the bubble ===
                // Same HStack-with-Spacer trick to right/left-align the
                // menu to the bubble's edge. Top-anchored so the offset
                // is the menu's TOP y, not its center.
                HStack(spacing: 0) {
                    if context.isFromMe { Spacer(minLength: 0) }
                    BubbleActionMenu(
                        actions: actions,
                        isPinned: isPinned,
                        isSaved: isSaved,
                        isFromMe: context.isFromMe,
                        onAfterAction: onDismiss
                    )
                    .frame(width: 220)
                    if !context.isFromMe { Spacer(minLength: 0) }
                }
                // 🐛 BUG FIX (2026-05-11): same padding-vs-frame
                // overflow as the picker above — fixed.
                .frame(width: screenW - 24)
                .padding(.horizontal, 12)
                .offset(y: liftedBubbleBottom + 10)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.7, anchor: .top)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }
}

/// Lightweight "what the bubble looked like" clone — just the text or
/// type-specific preview, styled to match the original's bubble.
/// Voice / image / file render as small placeholders since their
/// real previews would re-fetch media.
struct BubbleClone: View {
    let message: ChatMessage
    let isFromMe: Bool

    var body: some View {
        Group {
            switch message.type {
            case .text:
                Text(message.text ?? "")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        bubbleFill,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            case .voice:
                Label("Voice", systemImage: "waveform")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(bubbleFill, in: Capsule())
                    .foregroundColor(.white)
            case .image:
                Label("Photo", systemImage: "photo.fill")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(bubbleFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundColor(.white)
            default:
                Text(message.text ?? "")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(bubbleFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundColor(.white)
            }
        }
    }

    private var bubbleFill: some ShapeStyle {
        if isFromMe {
            return AnyShapeStyle(LinearGradient(
                colors: [Color.blue, Color.blue.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        } else {
            return AnyShapeStyle(Color(UIColor.secondarySystemFill))
        }
    }
}

/// Floating action menu — vertical list of buttons rendered inside an
/// ultraThinMaterial card with no wrapping system chrome.
struct BubbleActionMenu: View {
    let actions: BubbleOverlayActions
    let isPinned: Bool
    let isSaved: Bool
    let isFromMe: Bool
    var onAfterAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Reply", system: "arrowshape.turn.up.left", action: actions.onReply)
            divider
            if let onReplyPrivately = actions.onReplyPrivately {
                row("Reply privately", system: "arrowshape.turn.up.left.2.fill",
                    action: onReplyPrivately)
                divider
            }
            row("Forward", system: "arrowshape.turn.up.right", action: actions.onForward)
            divider
            if let onCopy = actions.onCopy {
                row("Copy", system: "doc.on.doc", action: onCopy)
                divider
            }
            row(isPinned ? "Unpin" : "Pin",
                system: isPinned ? "pin.slash" : "pin",
                action: actions.onPin)
            divider
            row(isSaved ? "Remove from Saved" : "Save",
                system: isSaved ? "bookmark.slash" : "bookmark",
                action: actions.onSave)
            divider
            if let onEdit = actions.onEdit {
                row("Edit", system: "pencil", action: onEdit)
                divider
            }
            row("Info", system: "info.circle", action: actions.onShowInfo)
            if let onDelete = actions.onDelete {
                divider
                row("Delete", system: "trash", action: onDelete, destructive: true)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    @ViewBuilder
    private func row(_ title: String, system: String,
                     action: @escaping () -> Void,
                     destructive: Bool = false) -> some View {
        Button {
            action()
            onAfterAction()
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(destructive ? .red : .primary)
                Spacer()
                Image(systemName: system)
                    .font(.system(size: 14))
                    .foregroundColor(destructive ? .red : .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
    }
}


// ===== from ReactionReactorsSheet.swift =====
// MARK: - Reaction Reactors Sheet
//
// Group-chat sheet that lists the members who reacted with a specific
// emoji. Surfaced via long-press on a reaction chip. The sheet resolves
// each user id against the group member list passed in by the chat;
// unknown ids fall back to a short id suffix so we never render an
// empty row.

struct ReactionReactorsTarget: Identifiable, Equatable {
    var id: String { emoji }
    let emoji: String
    let userIds: [String]
}

struct ReactionReactorsSheet: View {
    let emoji: String
    let userIds: [String]
    let members: [GroupMember]
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable, Equatable {
        let id: String
        let displayName: String
        let username: String?
        let avatarUrl: String?
    }

    private var rows: [Row] {
        userIds.map { uid in
            if let m = members.first(where: { $0.userId == uid }) {
                return Row(
                    id: uid,
                    displayName: m.displayName,
                    username: m.username,
                    avatarUrl: m.avatarUrl
                )
            }
            // Unknown member (left the group, stale cache) — show a short
            // id suffix so the row is still meaningful.
            return Row(
                id: uid,
                displayName: "Member \(String(uid.prefix(4)))",
                username: nil,
                avatarUrl: nil
            )
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Text(emoji).font(.system(size: 36))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(userIds.count) reaction\(userIds.count == 1 ? "" : "s")")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Long-press the chip to see who reacted.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    ForEach(rows) { row in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.18))
                                    .frame(width: 36, height: 36)
                                if let url = row.avatarUrl, let u = URL(string: url) {
                                    // Avatar row — CachedAsyncImage so the
                                    // member list scrolls without re-fetching
                                    // every avatar on each velocity change.
                                    CachedAsyncImage(url: u) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.clear
                                    }
                                    .frame(width: 36, height: 36)
                                    .clipShape(Circle())
                                } else {
                                    Text(String(row.displayName.prefix(1)).uppercased())
                                        .font(.system(size: 14, weight: .heavy))
                                        .foregroundColor(.white)
                                }
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                if let u = row.username {
                                    Text("@\(u)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Reactions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}


// ===== from EmojiReactionPickerSheet.swift =====
// MARK: - Emoji Reaction Picker (Liquid Glass grid)
//
// Surfaces a wider emoji palette than the six-tile React submenu in the
// context menu. Opened from the "More…" item in that submenu. Tapping a
// tile reacts via the same MessageReactionStore.toggle path as the
// quick-pick capsule, so the server reconciles either way.

struct EmojiReactionPickerSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Curated palette: faces + hearts + hand gestures + "everyday" reactions.
    /// Picked to cover ~95% of real-world chat reactions without showing a
    /// full Unicode emoji keyboard.
    static let palette: [(String, [String])] = [
        ("Smileys", ["😀","😂","🥹","😅","🤣","😊","😇","🙂","😉","😍","🥰","😘","😋","😎","🤩","🤔","🫡","😴","🥳","🤯","😱","😭","😤","🤬","🥺","🤗","🤡"]),
        ("Hearts",  ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💗","💖","💘","💝","💞","💕","❣️","💔"]),
        ("Hands",   ["👍","👎","👏","🙌","👐","🤝","🙏","👋","✌️","🤞","🤟","🤘","🤙","💪","🫶","🤌"]),
        ("Other",   ["🔥","✨","⭐️","🎉","🎊","🎁","💯","💢","💥","💫","💦","💨","☕️","🍻","🍕","🌹","💐","🥂"])
    ]

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.palette, id: \.0) { (sectionTitle, emojis) in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(sectionTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 4)
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(emojis, id: \.self) { emoji in
                                    Button {
                                        Haptics.light()
                                        onPick(emoji)
                                        dismiss()
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 28))
                                            .frame(width: 40, height: 40)
                                            .background(
                                                Circle()
                                                    .fill(.ultraThinMaterial)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial.opacity(0.4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
                                )
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("Pick a reaction")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}


// ===== from MessageInfoSheet.swift =====
// MARK: - Message Info Sheet (Liquid Glass timeline)
//
// Long-press an outgoing message and pick "Info" to see when each
// delivery milestone happened. Renders a vertical capsule timeline:
//
//   ●  Sent at 10:42 AM
//   ●  Delivered at 10:42 AM
//   ●  Read at 10:43 AM   ← only when readAt is set
//
// Pending steps render as a dashed dot + "Pending" label so the user
// always sees the full pipeline. For group chats this is supplemented by
// the existing SeenBySheet (shown via the seen-by indicator) — this
// sheet stays focused on the timestamp story.

struct MessageInfoSheet: View {
    let message: ChatMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard

                    VStack(spacing: 0) {
                        InfoTimelineRow(
                            icon: "paperplane.fill",
                            title: "Sent",
                            subtitle: format(message.timestamp),
                            isFilled: true,
                            isLast: false
                        )
                        InfoTimelineRow(
                            icon: "checkmark.circle.fill",
                            title: "Delivered",
                            subtitle: message.deliveredAt.map(format) ?? "Pending",
                            isFilled: message.deliveredAt != nil,
                            isLast: false
                        )
                        InfoTimelineRow(
                            icon: "eye.fill",
                            title: "Read",
                            subtitle: message.readAt.map(format) ?? "Not yet",
                            isFilled: message.readAt != nil,
                            isLast: true
                        )
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                            )
                    )

                    if let edited = message.editedAt {
                        HStack(spacing: 6) {
                            Image(systemName: "pencil")
                            Text("Edited at \(format(edited))")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    if let expires = message.expiresAt {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                            Text("Expires at \(format(expires))")
                        }
                        .font(.caption)
                        .foregroundColor(.indigo)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Message info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: glyphForType)
                    .foregroundColor(.accentColor)
                Text(typeLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
            }
            if let preview = previewText, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private var glyphForType: String {
        switch message.type {
        case .voice:    return "mic.fill"
        case .image:    return "photo.fill"
        case .video:    return "video.fill"
        case .file:     return "doc.fill"
        case .location: return "location.fill"
        case .poll:     return "chart.bar.doc.horizontal.fill"
        default:        return "text.bubble.fill"
        }
    }

    private var typeLabel: String {
        switch message.type {
        case .voice:    return "Voice"
        case .image:    return "Photo"
        case .video:    return "Video"
        case .file:     return "File"
        case .location: return "Location"
        case .poll:     return "Poll"
        default:        return "Message"
        }
    }

    private var previewText: String? {
        switch message.type {
        case .text:     return message.text
        case .file:     return message.fileName
        case .voice:
            let s = message.audioDurationSeconds ?? 0
            return "\(s)s voice message"
        default:        return nil
        }
    }

    /// 🟡 BUG FIX (2026-05-10): hoisted to a static `let` so the
    /// formatter (~ms-scale init) is allocated once per type, not
    /// per row.
    private static let mediumDateShortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func format(_ date: Date) -> String {
        return Self.mediumDateShortTime.string(from: date)
    }
}

private struct InfoTimelineRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isFilled: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(isFilled ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(isFilled ? .accentColor : .secondary.opacity(0.7))
                }
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1.5, height: 26)
                        .padding(.top, 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isFilled ? .primary : .secondary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, isLast ? 4 : 2)
    }
}


// ===== from PlaybackSpeedPill.swift =====
// MARK: - Playback Speed Pill (Liquid Glass capsule)
//
// Compact "1×" / "1.5×" / "2×" capsule rendered inside the active voice
// bubble. Mirrors the visual weight of the timestamp/duration text so it
// reads as part of the same row, not a separate control. Tapping cycles
// the AudioPlaybackStore through 1.0 → 1.5 → 2.0 → 1.0.

struct PlaybackSpeedPill: View {
    let rate: Float
    let tint: Color
    var onTap: () -> Void

    private var label: String {
        switch rate {
        case 0.99...1.01: return "1×"
        case 1.49...1.51: return "1.5×"
        case 1.99...2.01: return "2×"
        default:          return String(format: "%.1f×", rate)
        }
    }

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(rate > 1.01 ? tint : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(rate > 1.01 ? tint.opacity(0.15) : Color.primary.opacity(0.06))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(rate > 1.01 ? tint.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback speed: \(label). Tap to change.")
    }
}


// ===== from DisappearingMessages.swift =====
// MARK: - Disappearing-message picker choices + banner
//
// `ExpiryPickerChoice` is the user-facing axis the confirmation dialog
// drives. We deliberately surface only the time-based modes here — the
// screenshot/forwarding flags are message-level overrides handled
// elsewhere. Picking "Off" wipes the per-thread default; everything else
// stamps an ExpiryMode that the composer attaches to outgoing sends.

/// Confirmation-dialog wrapper for the disappearing-messages picker.
/// Extracted to a ViewModifier so the main ChatView body stays under the
/// SwiftUI type-checker's complexity limit — inlining the dialog directly
/// pushed compile-time inference past the threshold.
struct ExpiryPickerDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let roomId: String
    var onPick: (ExpiryMode?) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Disappearing messages",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            ForEach(ExpiryPickerChoice.allCases) { choice in
                Button(choice.label) { onPick(choice.mode) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Future messages you send in this chat will follow this rule. Existing messages aren't affected.")
        }
    }
}

enum ExpiryPickerChoice: String, CaseIterable, Identifiable {
    case off
    case afterRead
    case after24h
    case after7d

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:        return "Off"
        case .afterRead:  return "After read"
        case .after24h:   return "After 24 hours"
        case .after7d:    return "After 7 days"
        }
    }

    var mode: ExpiryMode? {
        switch self {
        case .off:        return nil
        case .afterRead:  return .deleteAfterRead
        case .after24h:   return .deleteAfter24h
        case .after7d:    return .deleteAfter7d
        }
    }
}

/// Tappable banner that surfaces the active disappearing-message TTL just
/// above the composer. Tapping re-opens the picker so the user can change
/// the rule or turn it off again. Hidden when the per-thread mode is nil
/// or .none — we don't want to clutter the input area when it's off.
struct DisappearingActiveBanner: View {
    let mode: ExpiryMode
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: mode.icon.isEmpty ? "clock.arrow.circlepath" : mode.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.indigo)
                Text(mode.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.indigo.opacity(0.35), lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .accessibilityLabel("Disappearing messages: \(mode.label). Tap to change.")
    }
}


// ===== from ExpiryCountdownBadge.swift =====
// MARK: - Countdown badge on bubbles whose expires_at is in the future
//
// Shows a tiny ⌛/timer chip in the bubble metadata row when the message
// has a server-side expiry. Self-rebuilds every 10 s via a TimelineView
// so the relative-time string stays fresh without a per-second timer
// thrash.

struct ExpiryCountdownBadge: View {
    let expiresAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            if remaining <= 0 {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                        .font(.system(size: 9, weight: .semibold))
                    Text(format(remaining))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundColor(.indigo.opacity(0.85))
            }
        }
    }

    private func format(_ secs: TimeInterval) -> String {
        if secs < 60      { return "\(Int(secs))s" }
        if secs < 3600    { return "\(Int(secs / 60))m" }
        if secs < 86_400  { return "\(Int(secs / 3600))h" }
        return "\(Int(secs / 86_400))d"
    }
}


// ===== from PollComposerSheet.swift =====
// MARK: - Poll Composer (Liquid Glass)
//
// Group-only sheet for creating a poll: question + 2-10 options + flags
// (multiple-choice, anonymous, optional auto-close after N minutes).
// Submits to /api/groups/{group_id}/polls; on success the server creates
// both the poll AND a system "📊 username created a poll" message of
// type=poll, so the chat thread auto-shows the new poll bubble after
// the next message poll cycle.

struct PollComposerSheet: View {
    let groupId: String
    var onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var question: String = ""
    @State private var options: [String] = ["", ""]
    @State private var allowMultiple: Bool = false
    @State private var isAnonymous: Bool = false
    @State private var expirySelection: ExpiryChoice = .never
    @State private var creating: Bool = false
    @State private var errorMessage: String? = nil
    @FocusState private var focusedOption: Int?

    enum ExpiryChoice: String, CaseIterable, Identifiable {
        case never = "No limit"
        case fifteen = "15 min"
        case oneHour = "1 hour"
        case oneDay = "1 day"
        case oneWeek = "1 week"

        var id: String { rawValue }
        var minutes: Int? {
            switch self {
            case .never: return nil
            case .fifteen: return 15
            case .oneHour: return 60
            case .oneDay: return 60 * 24
            case .oneWeek: return 60 * 24 * 7
            }
        }
    }

    private var trimmedOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    private var canSubmit: Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return !q.isEmpty && trimmedOptions.count >= 2 && !creating
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    sectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Question", systemImage: "questionmark.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.accentColor)
                            TextField("Ask the group…", text: $question, axis: .vertical)
                                .lineLimit(1...3)
                                .textInputAutocapitalization(.sentences)
                        }
                    }

                    sectionCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Options", systemImage: "checklist")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.accentColor)
                            ForEach(options.indices, id: \.self) { idx in
                                HStack(spacing: 8) {
                                    Image(systemName: "circle.dotted")
                                        .foregroundColor(.secondary)
                                    TextField("Option \(idx + 1)", text: optionBinding(idx))
                                        .focused($focusedOption, equals: idx)
                                        .submitLabel(.next)
                                        .onSubmit {
                                            if idx < options.count - 1 {
                                                focusedOption = idx + 1
                                            } else if options.count < 10 {
                                                addOption()
                                            }
                                        }
                                    if options.count > 2 {
                                        Button {
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                                _ = options.remove(at: idx)
                                            }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                                .transition(.scale.combined(with: .opacity))
                            }
                            if options.count < 10 {
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                        addOption()
                                    }
                                } label: {
                                    Label("Add option", systemImage: "plus.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                            }
                        }
                    }

                    sectionCard {
                        VStack(spacing: 10) {
                            Toggle(isOn: $allowMultiple) {
                                Label("Allow multiple answers", systemImage: "rectangle.stack")
                            }
                            Divider().opacity(0.3)
                            Toggle(isOn: $isAnonymous) {
                                Label("Anonymous voting", systemImage: "person.fill.questionmark")
                            }
                            Divider().opacity(0.3)
                            HStack {
                                Label("Auto-close", systemImage: "clock")
                                Spacer()
                                Picker("", selection: $expirySelection) {
                                    ForEach(ExpiryChoice.allCases) { c in
                                        Text(c.rawValue).tag(c)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }
            .navigationTitle("New Poll")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if creating {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("Create").bold()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .onAppear { focusedOption = 0 }
        }
    }

    private func optionBinding(_ idx: Int) -> Binding<String> {
        Binding(
            get: { idx < options.count ? options[idx] : "" },
            set: { newValue in
                guard idx < options.count else { return }
                options[idx] = newValue
            }
        )
    }

    private func addOption() {
        options.append("")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedOption = options.count - 1
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
            )
    }

    private func submit() async {
        creating = true
        errorMessage = nil
        defer { creating = false }
        do {
            _ = try await NetworkService.shared.createPoll(
                groupId: groupId,
                question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                options: trimmedOptions,
                allowMultiple: allowMultiple,
                isAnonymous: isAnonymous,
                expiresInMinutes: expirySelection.minutes
            )
            Haptics.success()
            onCreated()
            dismiss()
        } catch {
            Haptics.error()
            errorMessage = "Couldn't create poll — \(error.localizedDescription)"
        }
    }
}


// ===== from PollBubbleView.swift =====
// MARK: - Poll Bubble — renders a live poll inside a chat message bubble
//
// Loads the poll once on appear, then re-fetches every time the user
// votes to get the canonical tally back. Each option is a Liquid Glass
// capsule with an animated progress fill, vote count, and a checkmark
// when the user has selected it. Creators get a "Close poll" affordance.

struct PollBubbleView: View {
    let groupId: String
    let pollId: String
    var onTap: (() -> Void)? = nil

    @State private var poll: NetworkService.PollDTO? = nil
    @State private var loading: Bool = true
    @State private var voting: String? = nil
    @State private var observerToken: NSObjectProtocol? = nil

    private var isCreator: Bool {
        guard let poll, let me = AuthService.shared.currentUser?.id else { return false }
        return poll.creatorId == me
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(headerText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                if let poll, poll.isClosed {
                    Text("Closed")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundColor(.secondary)
                }
            }
            if let poll {
                Text(poll.question)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(poll.options) { opt in
                        PollOptionRow(
                            option: opt,
                            isMyChoice: poll.myVotes.contains(opt.id),
                            totalVotes: poll.totalVotes,
                            isClosed: poll.isClosed,
                            voting: voting == opt.id,
                            onTap: { Task { await vote(optionId: opt.id) } }
                        )
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: poll.isAnonymous ? "person.fill.questionmark" : "person.2.fill")
                    Text("\(poll.totalVotes) vote\(poll.totalVotes == 1 ? "" : "s")")
                    if poll.allowMultiple {
                        Text("· Multi-select").foregroundColor(.secondary)
                    }
                    Spacer()
                    if isCreator && !poll.isClosed {
                        Button("Close poll") {
                            Task { await close() }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            } else if loading {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading poll…").font(.system(size: 13)).foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                Text("Couldn't load poll")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.15), lineWidth: 0.6)
                )
        )
        .frame(maxWidth: 320, alignment: .leading)
        .onTapGesture { onTap?() }
        .task { await load() }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: poll)
    }

    private var headerText: String {
        if poll?.isClosed == true { return "Final Results" }
        return "Poll"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            poll = try await NetworkService.shared.getPoll(groupId: groupId, pollId: pollId)
        } catch {
            poll = nil
        }
    }

    private func vote(optionId: String) async {
        guard let poll, !poll.isClosed else { return }
        Haptics.light()
        voting = optionId
        defer { voting = nil }
        do {
            self.poll = try await NetworkService.shared.votePoll(groupId: groupId, pollId: pollId, optionId: optionId)
        } catch {
            Haptics.error()
            #if DEBUG
            print("📊 [Poll] vote failed: \(error)")
            #endif
        }
    }

    private func close() async {
        Haptics.medium()
        do {
            self.poll = try await NetworkService.shared.closePoll(groupId: groupId, pollId: pollId)
        } catch {
            Haptics.error()
        }
    }
}

private struct PollOptionRow: View {
    let option: NetworkService.PollOptionDTO
    let isMyChoice: Bool
    let totalVotes: Int
    let isClosed: Bool
    let voting: Bool
    var onTap: () -> Void

    private var pct: Double {
        guard totalVotes > 0 else { return 0 }
        return Double(option.voteCount) / Double(totalVotes)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                // Progress fill
                GeometryReader { geo in
                    Capsule(style: .continuous)
                        .fill(isMyChoice ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                        .frame(width: max(20, geo.size.width * CGFloat(pct)))
                        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: pct)
                }
                .frame(height: 36)

                HStack(spacing: 8) {
                    Image(systemName: isMyChoice ? "checkmark.circle.fill" : (isClosed ? "circle" : "circle.dashed"))
                        .foregroundColor(isMyChoice ? .accentColor : .secondary)
                        .font(.system(size: 14, weight: .semibold))
                    Text(option.text)
                        .font(.system(size: 14, weight: isMyChoice ? .semibold : .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if voting {
                        ProgressView().scaleEffect(0.65)
                    } else {
                        Text("\(option.voteCount)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
            }
            .background(
                Capsule(style: .continuous)
                    .stroke(isMyChoice ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 0.6)
            )
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isClosed || voting)
    }
}
