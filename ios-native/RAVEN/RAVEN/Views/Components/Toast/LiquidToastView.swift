import SwiftUI

// MARK: - Capsule Liquid Toast View
/// Premium Liquid Glass capsule-style toast notification
/// - Slides in from top, slides out to top (matches PostUploadToast)
/// - Compact capsule design with avatar and preview
/// - Swipe DOWN to expand for quick reply (message/voice)
/// - Swipe LEFT to dismiss
struct LiquidToastView: View {
    let item: ToastItem
    var onTap: () -> Void
    var onReply: () -> Void
    var onAcceptFriendRequest: ((ToastItem) -> Void)?
    var onDeclineFriendRequest: ((ToastItem) -> Void)?
    var onSendReply: ((ToastItem, String) -> Void)?
    
    @State private var isPressed = false
    @State private var isExpanded = false // Expanded for reply
    @State private var replyText = ""
    @State private var isSending = false
    @State private var dragOffset: CGSize = .zero
    @FocusState private var isReplyFocused: Bool
    
    // Threshold for swipe gestures
    private let swipeDownThreshold: CGFloat = 60
    private let swipeLeftThreshold: CGFloat = -80
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Compact Capsule Toast
            mainCapsule
            
            // MARK: - Expanded Reply Field
            if isExpanded && item.canReply {
                replyField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Unified liquid-glass surface (one design language across the app).
        // Type-color tint is applied as an additional outer-glow shadow only,
        // so the base material/stroke/highlight stay consistent with every
        // other glass surface (tab bar, cards, sheets, etc.).
        .modifier(ToastGlassSurface(isExpanded: isExpanded))
        .shadow(color: typeColor.opacity(0.22), radius: 16, x: 0, y: 4) // type-color glow
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .offset(dragOffset)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPressed)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only allow vertical when not expanded, or horizontal to dismiss
                    if !isExpanded {
                        // Swipe down expands (for reply-capable items)
                        if value.translation.height > 0 && item.canReply {
                            dragOffset = CGSize(width: 0, height: min(value.translation.height * 0.5, 40))
                        }
                        // Swipe left dismisses
                        else if value.translation.width < 0 {
                            dragOffset = CGSize(width: max(value.translation.width, -100), height: 0)
                        }
                    }
                }
                .onEnded { value in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = .zero
                        
                        // Swipe down: expand for reply
                        if value.translation.height > swipeDownThreshold && item.canReply {
                            isExpanded = true
                            isReplyFocused = true
                            NotificationPipeline.shared.pauseDismiss()
                            Haptics.medium()
                        }
                        // Swipe left: dismiss
                        else if value.translation.width < swipeLeftThreshold {
                            NotificationPipeline.shared.dismissCurrent()
                            Haptics.light()
                        }
                    }
                }
        )
        .onTapGesture {
            if !isExpanded {
                onTap()
            }
        }
    }
    
    // MARK: - Main Capsule Content (R76 rewrite — full context + Liquid Glass)
    //
    // 🟢 ROUND 76 (2026-05-24) — banner UI overhaul.
    //
    // PRE-FIX: a single HStack with a tiny avatar, a 14pt title row,
    // and a 13pt body row that collapsed to nothing when `body` was
    // short or empty. On a black chat background the toast looked
    // like only "Ahmadreza" floating with no preview, no group
    // context, no timestamp, no transport indicator — basically a
    // useless poke. Screenshot from user (2026-05-24) confirms.
    //
    // NEW LAYOUT (Apple-class):
    //
    //   ┌────────────────────────────────────────────────────────┐
    //   │ [44pt avatar●]  Ahmadreza · DM        🔒  now      ⌃ │
    //   │                 💬 Hey, are you free tonight?          │
    //   └────────────────────────────────────────────────────────┘
    //
    // ROW 1 (top): type-icon + sender + " · " + context-label.
    //   - context-label = group name for groups, "DM" for 1:1,
    //     "Friend Request" / "Like" / "Comment" etc. for non-chat.
    // ROW 2 (bottom): full message preview, NEVER collapsed.
    //   - safe-fallback: if `item.body` is empty/whitespace,
    //     synthesize a verb-style "Sent a message" so the row is
    //     ALWAYS visible (never zero-height).
    // RIGHT META: transport indicator (E2E lock) + time chip + chevron.
    private var mainCapsule: some View {
        HStack(alignment: .center, spacing: 12) {
            // Avatar (bumped to 44pt for proper visibility)
            avatarView

            // Two-row content column
            VStack(alignment: .leading, spacing: 3) {
                // ROW 1 — sender + chat context
                HStack(spacing: 5) {
                    Image(systemName: item.type.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(typeColor)
                        .frame(width: 14)

                    Text(item.title.isEmpty ? "RAVEN" : item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !contextLabel.isEmpty {
                        Text("·")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.tertiary)
                        Text(contextLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // ROW 2 — preview (always rendered, with fallback)
                Text(displayBody)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            // RIGHT META column — transport, time, action
            if !isExpanded {
                rightMetaColumn
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Context label that appears next to the sender name on the top
    /// row. For 1:1 chats it's "DM"; for groups it's the group name;
    /// for non-chat (likes, comments, …) it describes the action.
    private var contextLabel: String {
        switch item.type {
        case .message:
            if item.isGroup, let g = item.groupName, !g.isEmpty {
                return g
            }
            return "Direct"
        case .voice:
            if item.isGroup, let g = item.groupName, !g.isEmpty {
                return g
            }
            return "Direct"
        case .friendRequest:
            return "Friend Request"
        case .like:
            return "liked your post"
        case .comment:
            return "commented"
        case .groupInvite:
            return item.groupName ?? "Group invite"
        case .meshPeerNearby:
            return "Nearby on mesh"
        case .audioRoomMention:
            return item.groupName ?? "Live room"
        case .vaultAccess:
            return "Vault"
        case .backupDone:
            return "Backup"
        case .twoFactorRequest:
            return "2FA"
        case .disasterMode:
            return "Disaster mode"
        case .appUpdate:
            return "Update"
        case .security:
            return "Security"
        }
    }

    /// Message preview with safety fallback so the row is never empty.
    private var displayBody: String {
        let trimmed = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch item.type {
        case .message: return "Sent you a message"
        case .voice: return "Sent a voice message"
        case .friendRequest: return "wants to connect"
        case .like: return "tapped ♥ on your post"
        case .comment: return "left a comment"
        case .groupInvite: return "Invited you to a group"
        case .meshPeerNearby: return "Just appeared on the mesh"
        case .audioRoomMention: return "Mentioned you in a live room"
        case .vaultAccess: return "Vault attachment opened"
        case .backupDone: return "Encrypted backup finished"
        case .twoFactorRequest: return "Sign-in approval needed"
        case .disasterMode: return "Disaster mode is active"
        case .appUpdate: return "A new version is available"
        case .security: return "Security update"
        }
    }

    // MARK: - Right Meta Column (R76)
    @ViewBuilder
    private var rightMetaColumn: some View {
        // Friend-request and group-invite items show inline accept /
        // decline; everything else shows transport + time + chevron.
        if item.type == .friendRequest || item.type == .groupInvite {
            quickActionButtons
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                // Transport pill — E2E lock for messages so the user
                // sees that the body in the preview is encrypted on
                // the wire. Tiny + non-interactive.
                if item.type == .message {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(typeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(typeColor.opacity(0.15))
                        )
                }
                // Time chip — "now" by default, age-aware after a few
                // seconds so the toast pile-up reads sensibly.
                Text(relativeTimeLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            // Chevron to the right of the meta column hints at tappability.
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
    }

    /// Age-aware time label.
    private var relativeTimeLabel: String {
        let secs = Int(Date().timeIntervalSince(item.receivedAt))
        if secs < 5 { return "now" }
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// Legacy convenience kept for callers/styling that still reference
    /// the old combined-title format.
    private var composedTitle: String {
        if item.isGroup, let groupName = item.groupName, !groupName.isEmpty,
           !item.title.isEmpty, item.title != groupName {
            return "\(item.title) · \(groupName)"
        }
        return item.title
    }
    
    // MARK: - Quick Action Buttons
    @ViewBuilder
    private var quickActionButtons: some View {
        if item.type == .friendRequest || item.type == .groupInvite {
            // Accept/Decline for friend requests
            HStack(spacing: 6) {
                Button {
                    Haptics.success()
                    onAcceptFriendRequest?(item)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.green)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                
                Button {
                    Haptics.light()
                    onDeclineFriendRequest?(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.8))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        } else {
            // Time indicator
            Text("now")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
    
    // MARK: - Reply Field (Expanded)
    private var replyField: some View {
        HStack(spacing: 8) {
            TextField("Reply...", text: $replyText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .focused($isReplyFocused)
                .onSubmit { sendReply() }
            
            // Send Button
            Button { sendReply() } label: {
                Group {
                    if isSending {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.caption.weight(.bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(replyText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : typeColor)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
            
            // Close Button
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    isExpanded = false
                    isReplyFocused = false
                    replyText = ""
                }
                NotificationPipeline.shared.resumeDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
    
    // MARK: - Send Reply
    private func sendReply() {
        guard !replyText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        isSending = true
        Haptics.light()
        
        if let onSendReply = onSendReply {
            onSendReply(item, replyText)
        } else {
            Task {
                NotificationPipeline.shared.updateReplyText(replyText)
                await NotificationPipeline.shared.sendQuickReply()
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationPipeline.shared.resumeDismiss()
            NotificationPipeline.shared.dismissCurrent()
        }
    }
    
    // MARK: - Avatar View
    private var avatarView: some View {
        Group {
            if let url = item.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        initialsAvatar
                    }
                }
            } else {
                initialsAvatar
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
        .overlay(alignment: .bottomTrailing) {
            // Type indicator dot
            Circle()
                .fill(typeColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                .offset(x: 2, y: 2)
        }
    }
    
    // MARK: - Initials Avatar
    private var initialsAvatar: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [typeColor.opacity(0.7), typeColor.opacity(0.4)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Group {
                    if let name = item.senderName, !name.isEmpty {
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: item.type.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                    }
                }
            )
    }
    
    // toastBackground replaced by `ToastGlassSurface` modifier below — the
    // gradient highlight is now handled by the shared LiquidGlass tokens.

    // MARK: - Type Color
    private var typeColor: Color {
        switch item.type.accentColor {
        case "blue": return .blue
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "pink": return .pink
        case "cyan": return .cyan
        case "indigo": return .indigo
        case "mint": return .mint
        default: return .blue
        }
    }
}

// MARK: - Preview
#Preview("Capsule Toast") {
    ZStack {
        Color.black.opacity(0.3).ignoresSafeArea()
        
        VStack(spacing: 16) {
            // Message
            LiquidToastView(
                item: .message(
                    senderName: "Sarah",
                    preview: "Hey! Are you coming tonight?",
                    chatId: "123",
                    senderId: "456"
                ),
                onTap: {},
                onReply: {}
            )
            .frame(maxWidth: 320)
            
            // Voice
            LiquidToastView(
                item: .voice(
                    senderName: "Mike",
                    duration: 12,
                    chatId: "789",
                    senderId: "012"
                ),
                onTap: {},
                onReply: {}
            )
            .frame(maxWidth: 320)
            
            // Friend Request
            LiquidToastView(
                item: .friendRequest(
                    fromName: "John Doe",
                    senderId: "345",
                    requestId: "req-123"
                ),
                onTap: {},
                onReply: {}
            )
            .frame(maxWidth: 320)
        }
        .padding()
    }
}

// MARK: - Toast Glass Surface (delegates to unified LiquidGlass tokens)
/// Picks the right shape (Capsule when collapsed, RoundedRectangle when expanded)
/// and applies the shared `liquidGlass(in:)` modifier, so toasts share the same
/// material / stroke / specular / drop shadow as every other glass surface.
private struct ToastGlassSurface: ViewModifier {
    let isExpanded: Bool

    func body(content: Content) -> some View {
        if isExpanded {
            content
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            content
                .clipShape(Capsule())
                .glassSurface(in: Capsule())
        }
    }
}
