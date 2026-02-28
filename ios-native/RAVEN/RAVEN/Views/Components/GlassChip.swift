import SwiftUI

// MARK: - Glass Chip (Capsule-styled tag)
struct GlassChip: View {
    let label: String
    
    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.6)
            )
    }
}

// MARK: - Flowing Tags Layout (Wrapping chips)
struct FlowingTagsView: View {
    let tags: [String]
    
    var body: some View {
        // Using a simple wrapping approach with ViewThatFits
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 60, maximum: 150), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(tags, id: \.self) { tag in
                GlassChip(label: tag)
            }
        }
    }
}

// MARK: - Preview
#Preview("Glass Chip") {
    VStack(spacing: 12) {
        GlassChip(label: "Developer")
        GlassChip(label: "Music Lover")
        GlassChip(label: "☕️ Coffee")
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}

#Preview("Flowing Tags") {
    FlowingTagsView(tags: ["Developer", "iOS", "SwiftUI", "Music", "Coffee", "Travel", "Photography"])
        .padding()
        .background(Color.gray.opacity(0.3))
}
