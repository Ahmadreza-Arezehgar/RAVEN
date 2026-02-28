import SwiftUI

// MARK: - Seen By Sheet (Full list with Liquid Glass design)

/// Presents the full list of users who have seen a specific message.
/// Uses the Raven Liquid Glass design language with blur effects and capsule styling.
struct SeenBySheet: View {
    let seenBy: [SeenByUser]
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Glass background
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(seenBy) { user in
                            seenByRow(user)
                            
                            if user.id != seenBy.last?.id {
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Seen by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(seenBy.count) \(seenBy.count == 1 ? "person" : "people")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    @ViewBuilder
    private func seenByRow(_ user: SeenByUser) -> some View {
        HStack(spacing: 12) {
            GlassAvatar(
                name: user.displayName,
                path: user.avatarUrl,
                size: 40,
                showGlow: false
            )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                
                Text("@\(user.username)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Seen time
            Text(user.seenAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
