import SwiftUI

// MARK: - Droplet Transition (Top Right)
/// Custom transition for toast notifications - slides in/out from top-right
extension AnyTransition {
    /// Slide in from top-right, slide out to top-right
    static var dropletTopRight: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: DropletModifier(offsetX: 200, offsetY: -50, scale: 0.6, opacity: 0),
                identity: DropletModifier(offsetX: 0, offsetY: 0, scale: 1, opacity: 1)
            ),
            removal: .modifier(
                active: DropletModifier(offsetX: 200, offsetY: -50, scale: 0.6, opacity: 0),
                identity: DropletModifier(offsetX: 0, offsetY: 0, scale: 1, opacity: 1)
            )
        )
    }
    
    /// Droplet slide up from bottom
    static var dropletSlideUp: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }
}

// MARK: - Droplet Modifier
struct DropletModifier: ViewModifier {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let scale: CGFloat
    let opacity: Double
    
    func body(content: Content) -> some View {
        content
            .offset(x: offsetX, y: offsetY)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

// MARK: - Toast Host Overlay
/// Overlay view that displays toasts and quick reply sheet on top of any screen
struct ToastHostOverlay: View {
    // Use @ObservedObject for externally managed singleton
    @ObservedObject private var pipeline = NotificationPipeline.shared
    
    var body: some View {
        ZStack {
            // Base layer - ensures ZStack is always rendered (SwiftUI optimization workaround)
            Color.clear
                .allowsHitTesting(false)
            
            // MARK: - Current Toast
            if let item = pipeline.currentToast {
                VStack {
                    HStack {
                        Spacer()
                        
                        LiquidToastView(
                            item: item,
                            onTap: { pipeline.handleTap(item) },
                            onReply: { pipeline.openQuickReply(item) },
                            onAcceptFriendRequest: { toast in
                                pipeline.acceptFriendRequest(toast)
                            },
                            onDeclineFriendRequest: { toast in
                                pipeline.declineFriendRequest(toast)
                            },
                            onSendReply: { toast, text in
                                Task {
                                    await pipeline.sendInlineReply(toast: toast, text: text)
                                }
                            }
                        )
                        .frame(maxWidth: 380)
                        .padding(.trailing, 16)
                        .padding(.top, 50) // Below dynamic island / notch
                    }
                    
                    Spacer()
                }
                .transition(.dropletTopRight)
                .zIndex(9998)
            }
            
            // MARK: - Quick Reply Sheet
            if pipeline.quickReplyState != nil {
                // Dimmed background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        pipeline.closeQuickReply()
                    }
                    .transition(.opacity)
                    .zIndex(9998)
                
                // Reply sheet
                QuickReplySheet(pipeline: pipeline)
                    .transition(.dropletSlideUp)
                    .zIndex(9999)
            }
        }
        .onAppear {
            #if DEBUG
            print("🎯 ToastHostOverlay appeared")
            #endif
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: pipeline.currentToast?.id)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pipeline.quickReplyState != nil)
    }
}

// MARK: - Notification Bell Button
/// Bell icon button for the home screen showing notification count
struct NotificationBellButton: View {
    // Use @ObservedObject for proper observation of changes
    @ObservedObject private var pipeline = NotificationPipeline.shared
    var onTap: () -> Void
    
    @State private var isAnimatingBell = false
    
    var body: some View {
        Button(action: {
            Haptics.light()
            onTap()
        }) {
            ZStack(alignment: .topTrailing) {
                // Bell icon in glass capsule
                Image(systemName: pipeline.unreadCount > 0 ? "bell.badge.fill" : "bell.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(pipeline.unreadCount > 0 ? .orange : .primary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                    // Bell shake animation
                    .rotationEffect(.degrees(isAnimatingBell ? 15 : 0))
                    .animation(
                        isAnimatingBell
                            ? .easeInOut(duration: 0.1).repeatCount(5, autoreverses: true)
                            : .default,
                        value: isAnimatingBell
                    )
                
                // Badge count
                if pipeline.unreadCount > 0 {
                    Text(pipeline.unreadCount > 99 ? "99+" : "\(pipeline.unreadCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(.red)
                        )
                        .offset(x: 8, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .onChange(of: pipeline.unreadCount) { oldValue, newValue in
            if newValue > oldValue {
                // Animate bell when new notification arrives
                isAnimatingBell = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isAnimatingBell = false
                }
            }
        }
    }
}

// MARK: - View Extension for Toast Support
extension View {
    /// Adds toast overlay to the view hierarchy
    func withToastSupport() -> some View {
        self.overlay {
            ToastHostOverlay()
        }
    }
}

// MARK: - Preview
#Preview("Toast Overlay") {
    ZStack {
        // Background content
        LinearGradient(
            colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        
        VStack {
            Text("Main Content")
                .font(.largeTitle)
        }
    }
    .withToastSupport()
    .onAppear {
        // Simulate toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NotificationPipeline.shared.enqueue(
                .message(
                    senderName: "Sarah",
                    preview: "Hey! Check this out 🎉",
                    chatId: "123",
                    senderId: "456"
                )
            )
        }
    }
}

#Preview("Bell Button") {
    HStack {
        Spacer()
        NotificationBellButton(onTap: {})
            .padding()
    }
    .background(Color.gray.opacity(0.2))
}
