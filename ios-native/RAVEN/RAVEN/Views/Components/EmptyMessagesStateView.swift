import SwiftUI

// MARK: - Empty Messages State View
/// Minimal, clean empty state for Messages screen
/// Apple-style design: just icon + text, no animations, no CTAs
struct EmptyMessagesStateView: View {
    // NOTE: Keeping this parameter for backwards compatibility,
    // even though we don't use it anymore (interaction moved to navigation bar)
    let onNewChat: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            
            Text("No messages yet")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No messages yet")
    }
}

// MARK: - Preview
#Preview("Empty Messages State") {
    EmptyMessagesStateView(onNewChat: {})
}
