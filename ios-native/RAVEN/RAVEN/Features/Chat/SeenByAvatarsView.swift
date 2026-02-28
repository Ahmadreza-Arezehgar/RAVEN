import SwiftUI

// MARK: - Seen By Avatars View (Compact row below message bubble)

/// Shows up to 3 overlapping avatars of users who have seen the message,
/// plus a "+N" capsule badge if more than 3 users have seen it.
/// Tapping opens the full SeenBySheet.
struct SeenByAvatarsView: View {
    let seenBy: [SeenByUser]
    let isFromMe: Bool
    
    // 🚨 FIX: Removed internal sheet and use callback
    var onTap: (() -> Void)? = nil
    
    // Design constants
    private let avatarSize: CGFloat = 18
    private let maxVisible = 3
    private let overlap: CGFloat = -6
    
    var body: some View {
        if !seenBy.isEmpty {
            Button {
                Haptics.light()
                onTap?()
            } label: {
                HStack(spacing: 0) {
                    // Overlapping avatars
                    HStack(spacing: overlap) {
                        ForEach(Array(seenBy.prefix(maxVisible).enumerated()), id: \.element.id) { index, user in
                            GlassAvatar(
                                name: user.displayName,
                                path: user.avatarUrl,
                                size: avatarSize,
                                showGlow: false
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color(.systemBackground), lineWidth: 1.5)
                            )
                            .zIndex(Double(maxVisible - index))
                        }
                    }
                    
                    // "+N" badge
                    if seenBy.count > maxVisible {
                        Text("+\(seenBy.count - maxVisible)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: isFromMe ? .trailing : .leading)
            .padding(.horizontal, isFromMe ? 8 : 36) // Indent to match bubble alignment
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: seenBy.count)
        }
    }
}
