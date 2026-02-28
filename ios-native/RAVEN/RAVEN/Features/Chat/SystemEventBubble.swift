import SwiftUI

// MARK: - System Event Chip (Minimal, Centered, Text-Only)

/// Ultra-minimal system event chip for chat timeline.
/// Used for screenshot alerts, user joins/leaves, and other system notifications.
///
/// Design spec (strict):
///   - Text only — NO emoji, NO icons
///   - Centered in chat, maxWidth 300pt
///   - Single-line preferred: "Name took a screenshot · 10:43 PM"
///   - Footnote/caption font, secondary color
///   - Barely-visible capsule background (≈0.22 opacity)
///   - No shadow, no bubble tail, no status ticks
struct SystemEventChip: View {
    let title: String
    let time: String?
    
    init(title: String, timestamp: Date) {
        self.title = title
        self.time = timestamp.formatted(date: .omitted, time: .shortened)
    }
    
    init(title: String, time: String? = nil) {
        self.title = title
        self.time = time
    }
    
    /// Single-line display string: "Name took a screenshot · 10:43 PM"
    private var displayText: String {
        if let time {
            return "\(title) · \(time)"
        }
        return title
    }
    
    var body: some View {
        Text(displayText)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
            )
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

// MARK: - Legacy Alias (backward compatibility)
/// Alias so any existing references to `SystemEventBubble` continue to compile.
struct SystemEventBubble: View {
    let text: String
    let timestamp: Date
    
    var body: some View {
        SystemEventChip(title: text, timestamp: timestamp)
    }
}

#Preview {
    ZStack {
        Color(red: 0.11, green: 0.11, blue: 0.12)
            .ignoresSafeArea()
        
        VStack(spacing: 20) {
            SystemEventChip(
                title: "Ahmadreza Arezehgar took a screenshot",
                timestamp: Date()
            )
            
            SystemEventChip(
                title: "3 screenshots taken",
                timestamp: Date()
            )
            
            SystemEventChip(
                title: "User joined the conversation",
                time: nil
            )
        }
    }
}
