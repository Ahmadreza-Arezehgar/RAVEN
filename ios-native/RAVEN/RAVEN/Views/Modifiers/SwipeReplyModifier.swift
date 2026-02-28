import SwiftUI

// MARK: - Swipe Reply Modifier

struct SwipeReplyModifier: ViewModifier {
    let onReply: () -> Void
    @State private var offsetX: CGFloat = 0
    @State private var showReplyIndicator = false
    
    private let threshold: CGFloat = -55
    private let maxOffset: CGFloat = -70
    
    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
                .offset(x: offsetX)
            
            // Reply indicator
            if showReplyIndicator {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.blue))
                    .opacity(replyIndicatorOpacity)
                    .scaleEffect(replyIndicatorScale)
                    .offset(x: offsetX + 50)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    let x = value.translation.width
                    // Only allow swipe left
                    if x < 0 {
                        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.8)) {
                            offsetX = max(x, maxOffset)
                            showReplyIndicator = true
                        }
                    }
                }
                .onEnded { value in
                    if offsetX <= threshold {
                        // Trigger reply
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        onReply()
                    }
                    
                    // Reset
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        offsetX = 0
                        showReplyIndicator = false
                    }
                }
        )
    }
    
    private var replyIndicatorOpacity: Double {
        let progress = abs(offsetX) / abs(threshold)
        return min(progress, 1.0)
    }
    
    private var replyIndicatorScale: CGFloat {
        let progress = abs(offsetX) / abs(threshold)
        return 0.5 + (min(progress, 1.0) * 0.5)
    }
}

// MARK: - View Extension

extension View {
    func swipeToReply(onReply: @escaping () -> Void) -> some View {
        modifier(SwipeReplyModifier(onReply: onReply))
    }
}
