//
//  MemberDetailSheet.swift
//  RAVEN
//
//  Detail sheet for a Club member — avatar, status, distance, actions.
//

import SwiftUI

struct MemberDetailSheet: View {
    let member: ClubMember
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    // Big avatar with status ring
                    ZStack {
                        Circle()
                            .stroke(statusColor, lineWidth: 4)
                            .frame(width: 88, height: 88)
                        
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 76, height: 76)
                            .overlay(
                                Text(String(member.displayName.prefix(1)).uppercased())
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                            )
                    }
                    
                    Text(member.displayName)
                        .font(.title2.bold())
                    
                    // Status badge
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(statusColor)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .liquidCapsule()
                }
                .padding(.top, 8)
                
                // Info cards
                VStack(spacing: 12) {
                    MemberInfoRow(icon: "clock.fill", label: "Last Active", value: lastSeenText)
                    MemberInfoRow(icon: "location.fill", label: "Location (H3)", value: locationText)
                    
                    if member.isMe {
                        MemberInfoRow(icon: "person.fill", label: "You", value: "Yourself")
                    }
                }
                .padding(16)
                .liquidGlass(cornerRadius: 20)
                .padding(.horizontal, 16)
                
                // Actions (for other members only)
                if !member.isMe {
                    VStack(spacing: 12) {
                        Button {
                            // TODO: Navigate to member on map
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "location.fill")
                                Text("Show on Map")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                
                Spacer(minLength: 20)
            }
        }
    }
    
    private var statusColor: Color {
        switch member.status {
        case .active:  return .memberActive
        case .stale:   return .memberStale
        case .dropped: return .memberDropped
        }
    }
    
    private var statusText: String {
        switch member.status {
        case .active:  return "Active"
        case .stale:   return "Weak Signal"
        case .dropped: return "Dropped"
        }
    }
    
    private var lastSeenText: String {
        let elapsed = Date().timeIntervalSince(member.lastSeenAt)
        if elapsed < 10 { return "Just now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        return "\(Int(elapsed / 3600))h ago"
    }
    
    private var locationText: String {
        guard let cell = member.h3Cell else { return "Unknown" }
        return String(format: "%llX", cell).prefix(8) + "..."
    }
}

// MARK: - Info Row

struct MemberInfoRow: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }
}
