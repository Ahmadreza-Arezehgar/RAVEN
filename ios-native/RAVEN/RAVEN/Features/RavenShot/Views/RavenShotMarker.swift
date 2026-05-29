//
//  RavenShotMarker.swift
//  RAVEN
//
//  Custom map annotation view for Raven Shot items.
//  Displays user profile photos with type badges and glass effects.
//

import SwiftUI

// MARK: - Raven Shot Map Marker

struct RavenShotMarker: View {
    let item: RavenShotItem
    let isSelected: Bool
    
    @State private var isPulsing = false
    @State private var appeared = false
    
    private let markerSize: CGFloat = 48
    private let badgeSize: CGFloat = 18
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Main avatar/content bubble
            avatarBubble
            
            // Type badge indicator
            typeBadge
        }
        .scaleEffect(isSelected ? 1.2 : (appeared ? 1.0 : 0.3))
        .opacity(appeared ? 1.0 : 0.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: isSelected)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(Double.random(in: 0...0.3))) {
                appeared = true
            }
            if item.isRecent {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
        }
    }
    
    // MARK: - Avatar Bubble
    
    private var avatarBubble: some View {
        Group {
            if let avatarPath = item.authorAvatar,
               let url = AppConfig.mediaURL(from: avatarPath) {
                // Profile photo from server
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        initialsView
                    default:
                        shimmerView
                    }
                }
            } else {
                initialsView
            }
        }
        .frame(width: markerSize, height: markerSize)
        .clipShape(Circle())
        // Border ring
        .overlay(
            Circle()
                .stroke(
                    isSelected
                        ? LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                          )
                        : LinearGradient(
                            colors: [.white.opacity(0.9), .white.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                          ),
                    lineWidth: isSelected ? 3 : 2
                )
        )
        // Glass specular highlight
        .overlay(
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .padding(2)
        )
        // Shadow
        .shadow(
            color: isSelected
                ? Color.blue.opacity(0.45)
                : Color.black.opacity(0.2),
            radius: isSelected ? 10 : 5,
            y: isSelected ? 4 : 2
        )
        // Pin pointer triangle below the avatar
        .overlay(alignment: .bottom) {
            MapPinPointer()
                .fill(isSelected ? Color.blue : Color.white.opacity(0.9))
                .frame(width: 14, height: 8)
                .offset(y: 7)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
        // Pulse ring — tighter + brighter when LIVE (<5 min), softer for the
        // <1h "recent" window. Two pulse rings for live items make them pop.
        .background {
            if item.isLive {
                ZStack {
                    Circle()
                        .stroke(typeColor.opacity(0.55), lineWidth: 2)
                        .frame(width: markerSize + 14, height: markerSize + 14)
                        .scaleEffect(isPulsing ? 1.6 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.9)
                    Circle()
                        .fill(typeColor.opacity(0.18))
                        .frame(width: markerSize + 22, height: markerSize + 22)
                        .scaleEffect(isPulsing ? 1.3 : 1.0)
                        .opacity(isPulsing ? 0.0 : 0.6)
                }
            } else if item.isRecent {
                Circle()
                    .fill(typeColor.opacity(0.12))
                    .frame(width: markerSize + 16, height: markerSize + 16)
                    .scaleEffect(isPulsing ? 1.4 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.5)
            }
        }
        // LIVE label badge — short, high-contrast capsule above the marker
        .overlay(alignment: .top) {
            if item.isLive {
                Text("LIVE")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [Color.red, Color.orange],
                            startPoint: .leading, endPoint: .trailing
                        ))
                    )
                    .overlay(Capsule().stroke(.white.opacity(0.6), lineWidth: 0.5))
                    .shadow(color: .red.opacity(0.4), radius: 4, y: 1)
                    .offset(y: -markerSize / 2 - 6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
    
    // MARK: - Initials View (Fallback)
    
    private var initialsView: some View {
        ZStack {
            // Background gradient based on content type
            LinearGradient(
                colors: typeGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Text(initials)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
    
    // MARK: - Shimmer Loading
    
    private var shimmerView: some View {
        ZStack {
            Color.gray.opacity(0.15)
            ProgressView()
                .tint(.secondary)
                .scaleEffect(0.7)
        }
    }
    
    // MARK: - Type Badge
    
    private var typeBadge: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: typeGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: badgeSize, height: badgeSize)
            
            Image(systemName: item.contentType.icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .overlay(
            Circle()
                .stroke(Color.white, lineWidth: 1.5)
        )
        .shadow(color: typeColor.opacity(0.4), radius: 3, y: 1)
        .offset(x: 3, y: 3)
    }
    
    // MARK: - Helpers
    
    private var initials: String {
        let name = item.authorName
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return "\(components[0].prefix(1))\(components[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
    
    private var typeColor: Color {
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

// MARK: - Pin Pointer Shape

private struct MapPinPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 30) {
        RavenShotMarker(
            item: .init(
                id: "1",
                contentType: .post,
                coordinate: .init(latitude: 0, longitude: 0),
                authorName: "Ahmed",
                authorUsername: "ahmed",
                authorAvatar: nil,
                contentPreview: "Hello world",
                timestamp: Date(),
                visibility: "public",
                mediaPreviewUrl: nil,
                sourceId: "1"
            ),
            isSelected: false
        )
        
        RavenShotMarker(
            item: .init(
                id: "2",
                contentType: .echo,
                coordinate: .init(latitude: 0, longitude: 0),
                authorName: "a1b2c3d4",
                authorUsername: nil,
                authorAvatar: nil,
                contentPreview: "What's the best café nearby?",
                timestamp: Date().addingTimeInterval(-1800),
                visibility: "public",
                mediaPreviewUrl: nil,
                sourceId: "2"
            ),
            isSelected: true
        )
        
        RavenShotMarker(
            item: .init(
                id: "3",
                contentType: .club,
                coordinate: .init(latitude: 0, longitude: 0),
                authorName: "Music Fest",
                authorUsername: nil,
                authorAvatar: nil,
                contentPreview: "Festival Group",
                timestamp: Date().addingTimeInterval(-7200),
                visibility: "public",
                mediaPreviewUrl: nil,
                sourceId: "3"
            ),
            isSelected: false
        )
    }
    .padding(40)
}
