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
    
    // MARK: - Main Capsule Content
    private var mainCapsule: some View {
        HStack(spacing: 10) {
            // Avatar (small)
            avatarView
            
            // Content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: item.type.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(typeColor)
                    
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                
                Text(item.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 4)
            
            // Quick Actions
            if !isExpanded {
                quickActionButtons
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
