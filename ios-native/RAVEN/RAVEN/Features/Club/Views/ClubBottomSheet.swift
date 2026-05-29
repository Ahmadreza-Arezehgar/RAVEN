//
//  ClubBottomSheet.swift
//  RAVEN
//
//  Draggable Liquid Glass bottom sheet for Club map.
//  Shows active/dropped counts + horizontal member carousel.
//

import SwiftUI

struct ClubBottomSheet: View {
    let club: Club?
    let members: [ClubMember]
    @Binding var expanded: Bool
    @Binding var selectedMember: ClubMember?
    
    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(.tertiary)
                .frame(width: 40, height: 5)
                .padding(.vertical, 10)
            
            // Header chips
            HStack(spacing: 8) {
                StatChip(
                    icon: "person.fill",
                    text: "\(activeCount) active",
                    color: .memberActive
                )
                
                if droppedCount > 0 {
                    StatChip(
                        icon: "exclamationmark.triangle.fill",
                        text: "\(droppedCount) dropped",
                        color: .memberDropped
                    )
                }
                
                Spacer()
                
                if let club = club {
                    Text(club.timeRemaining)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .liquidCapsule()
                }
                
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            
            // Member carousel
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(members) { member in
                        MemberChip(member: member, isSelected: selectedMember?.id == member.id)
                            .onTapGesture {
                                withAnimation(RavenAnimation.snappy) {
                                    selectedMember = member
                                }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, expanded ? 8 : 28)
            
            // Expanded: full member list
            if expanded {
                Divider()
                    .padding(.horizontal, 16)
                
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(members) { member in
                            MemberRow(member: member)
                                .onTapGesture {
                                    withAnimation(RavenAnimation.snappy) {
                                        selectedMember = member
                                    }
                                }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, DS.bottomTabClearance + 8)
        .liquidTopBar()
        .gesture(
            DragGesture()
                .onEnded { value in
                    withAnimation(RavenAnimation.spring) {
                        if value.translation.height < -50 {
                            expanded = true
                        } else if value.translation.height > 50 {
                            expanded = false
                        }
                    }
                }
        )
    }
    
    private var activeCount: Int {
        members.filter { $0.status == .active }.count
    }
    
    private var droppedCount: Int {
        members.filter { $0.status == .dropped && !$0.isMe }.count
    }
}

// MARK: - Stat Chip

struct StatChip: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidCapsule()
    }
}

// MARK: - Member Chip

struct MemberChip: View {
    let member: ClubMember
    let isSelected: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Text(String(member.displayName.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor)
                
                Circle()
                    .stroke(isSelected ? statusColor : .clear, lineWidth: 2)
                    .frame(width: 44, height: 44)
            }
            
            Text(member.isMe ? "You" : String(member.displayName.prefix(6)))
                .font(.system(size: 10))
                .foregroundStyle(member.status == .dropped ? .red : .primary)
                .lineLimit(1)
        }
        .frame(width: 56)
    }
    
    private var statusColor: Color {
        switch member.status {
        case .active:  return .memberActive
        case .stale:   return .memberStale
        case .dropped: return .memberDropped
        }
    }
}

// MARK: - Member Row (Expanded List)

struct MemberRow: View {
    let member: ClubMember
    
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            
            Text(member.isMe ? "You" : member.displayName)
                .font(.subheadline.weight(.medium))
            
            Spacer()
            
            Text(member.status.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.12), in: Capsule())
            
            if member.status == .dropped {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    private var statusColor: Color {
        switch member.status {
        case .active:  return .memberActive
        case .stale:   return .memberStale
        case .dropped: return .memberDropped
        }
    }
}
