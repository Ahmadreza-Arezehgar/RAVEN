//
//  RavenShotDetailCard.swift
//  RAVEN
//
//  Bottom sheet detail card for selected Raven Shot map items.
//  Liquid Glass design with content preview and navigation.
//

import SwiftUI

// MARK: - Raven Shot Detail Card (Bottom Sheet)

struct RavenShotDetailCard: View {
    let item: RavenShotItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
            
            VStack(spacing: 16) {
                // Author Row
                authorRow
                
                // Content Preview
                contentPreview
                
                // Media Preview (if available)
                if let mediaUrl = item.mediaPreviewUrl, let url = URL(string: mediaUrl) {
                    mediaPreview(url: url)
                }
                
                // Action Row
                actionRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Author Row
    
    private var authorRow: some View {
        HStack(spacing: 12) {
            // Avatar
            Group {
                if let avatarUrl = item.authorAvatar, let url = URL(string: avatarUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            avatarFallback
                        }
                    }
                } else {
                    avatarFallback
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            
            // Name + info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.authorName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    if let username = item.authorUsername {
                        Text("@\(username)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                
                HStack(spacing: 6) {
                    // Content type badge
                    HStack(spacing: 4) {
                        Image(systemName: item.contentType.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(item.contentType.label)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(typeBadgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(typeBadgeColor.opacity(0.12))
                    .clipShape(Capsule())
                    
                    // Timestamp
                    Text(item.relativeTime)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    
                    // Visibility
                    if let vis = item.visibility {
                        Image(systemName: vis == "public" ? "globe" : "person.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            
            Spacer()
        }
    }
    
    // MARK: - Avatar Fallback
    
    private var avatarFallback: some View {
        ZStack {
            LinearGradient(
                colors: typeGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Text(String(item.authorName.prefix(2)).uppercased())
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
    
    // MARK: - Content Preview
    
    private var contentPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.contentPreview)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
    
    // MARK: - Media Preview
    
    private func mediaPreview(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            default:
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .frame(height: 120)
                    .overlay {
                        ProgressView()
                            .tint(.secondary)
                    }
            }
        }
    }
    
    // MARK: - Action Row
    
    private var actionRow: some View {
        HStack(spacing: 12) {
            // View/Open Button
            Button {
                Haptics.light()
                navigateToContent()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                    Text("View \(item.contentType.label)")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: typeGradient,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .shadow(color: typeBadgeColor.opacity(0.3), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            
            // Dismiss button
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Navigation
    
    private func navigateToContent() {
        switch item.contentType {
        case .post:
            // Navigate to post detail
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                FeedStateManager.shared.deepLinkPostId = item.sourceId
            }
        case .echo:
            // Echo detail handled by EchoStore
            dismiss()
        case .club:
            // Club detail handled by ClubStore
            dismiss()
        }
    }
    
    // MARK: - Helpers
    
    private var typeBadgeColor: Color {
        switch item.contentType {
        case .post: return .blue
        case .echo: return .purple
        case .club: return .green
        }
    }
    
    private var typeGradient: [Color] {
        switch item.contentType {
        case .post: return [.blue, .cyan]
        case .echo: return [.purple, .indigo]
        case .club: return [.green, .mint]
        }
    }
}

// MARK: - Preview

#Preview {
    RavenShotDetailCard(
        item: .init(
            id: "1",
            contentType: .post,
            coordinate: .init(latitude: 40.7128, longitude: -74.0060),
            authorName: "Ahmed",
            authorUsername: "ahmed",
            authorAvatar: nil,
            contentPreview: "Beautiful sunset over the city skyline tonight! 🌅 The colors were absolutely incredible from the rooftop.",
            timestamp: Date().addingTimeInterval(-3600),
            visibility: "public",
            mediaPreviewUrl: nil,
            sourceId: "abc123"
        )
    )
    .presentationDetents([.medium])
    .presentationBackground(.ultraThinMaterial)
}
