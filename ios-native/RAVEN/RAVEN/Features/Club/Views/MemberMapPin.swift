//
//  MemberMapPin.swift
//  RAVEN
//
//  Snapchat-style avatar pin for Club map.
//  Shows initial + status ring + status dot.
//

import SwiftUI

struct MemberMapPin: View {
    let member: ClubMember
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Status ring
                Circle()
                    .stroke(statusColor, lineWidth: 3)
                    .frame(width: 48, height: 48)
                
                // Avatar image (or initial fallback)
                if let urlStr = member.avatarURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                        default:
                            initialCircle
                        }
                    }
                } else {
                    initialCircle
                }
                
                // Status dot (bottom-right)
                Circle()
                    .fill(statusColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: 16, y: 16)
            }
            .shadow(color: statusColor.opacity(0.4), radius: isSelected ? 10 : 5, y: 2)
            .scaleEffect(isSelected ? 1.15 : (member.isMe ? 1.05 : 1.0))
            .animation(RavenAnimation.snappy, value: isSelected)
            
            // Name label
            Text(member.isMe ? "You" : member.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .liquidCapsule()
                .opacity(isSelected ? 1 : 0.8)
        }
    }
    
    private var initialCircle: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: avatarGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 40, height: 40)
            .overlay(
                Text(String(member.displayName.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
    
    private var statusColor: Color {
        switch member.status {
        case .active:  return .memberActive
        case .stale:   return .memberStale
        case .dropped: return .memberDropped
        }
    }
    
    private var avatarGradient: [Color] {
        if member.isMe {
            return [.blue, .cyan]
        }
        // Generate consistent gradient from userId hash
        let hash = member.userId.hashValue
        let hue1 = Double(abs(hash) % 360) / 360.0
        let hue2 = (hue1 + 0.1).truncatingRemainder(dividingBy: 1.0)
        return [Color(hue: hue1, saturation: 0.7, brightness: 0.8),
                Color(hue: hue2, saturation: 0.6, brightness: 0.9)]
    }
}
