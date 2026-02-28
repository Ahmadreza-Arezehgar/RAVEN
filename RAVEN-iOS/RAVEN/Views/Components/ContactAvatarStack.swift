// RAVEN - Contact Avatar Stack
// Overlapping circular avatar chips for post action rows

import SwiftUI

/// Displays up to 3 overlapping circular avatar images of contacts.
/// Used next to like/comment counts to show which contacts interacted.
struct ContactAvatarStack: View {
    let avatars: [ContactAffinityStore.ContactAvatar]
    var size: CGFloat = 17
    var onTap: (() -> Void)?
    
    private let overlapOffset: CGFloat = -7  // ~40% overlap for 17pt circles
    
    var body: some View {
        if avatars.isEmpty {
            EmptyView()
        } else {
            Button {
                onTap?()
            } label: {
                HStack(spacing: overlapOffset) {
                    ForEach(Array(avatars.prefix(3).enumerated()), id: \.element.id) { index, avatar in
                        miniAvatar(url: avatar.avatarUrl, name: avatar.name)
                            .zIndex(Double(3 - index))  // First avatar on top
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
    
    @ViewBuilder
    private func miniAvatar(url: String?, name: String) -> some View {
        Group {
            if let urlString = url, let imageUrl = URL(string: urlString) {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        initialsFallback(name: name)
                    case .empty:
                        glassPlaceholder
                    @unknown default:
                        initialsFallback(name: name)
                    }
                }
            } else {
                initialsFallback(name: name)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(.ultraThinMaterial, lineWidth: 1)
        )
    }
    
    private func initialsFallback(name: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [.ravenPrimary.opacity(0.7), .ravenSecondary.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Text(name.initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundColor(.white)
        }
    }
    
    private var glassPlaceholder: some View {
        Circle()
            .fill(.ultraThinMaterial)
    }
}
