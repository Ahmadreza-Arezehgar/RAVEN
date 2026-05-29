//
//  ClubMapView.swift
//  RAVEN
//
//  Snapchat-style full-screen map for Club Mode.
//  Avatar pins with status rings, H3 cell radius circles,
//  Liquid Glass bottom sheet + member detail.
//

import SwiftUI
import MapKit

// MARK: - Club Map View

struct ClubMapView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = ClubStore.shared
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedMember: ClubMember?
    @State private var bottomSheetExpanded = false
    @State private var showLeaveAlert = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-screen map
            Map(position: $position) {
                ForEach(store.members) { member in
                    // Use precise GPS coords if available (exact mode),
                    // otherwise fall back to H3 cell center (approximate mode)
                    if let coord = memberCoordinate(member) {
                        // H3 cell radius circle
                        MapCircle(center: coord, radius: member.preciseLat != nil ? 20 : 150)
                            .foregroundStyle(memberColor(member).opacity(0.08))
                            .stroke(memberColor(member).opacity(0.25), lineWidth: 1)
                        
                        // Avatar pin
                        Annotation(
                            member.displayName,
                            coordinate: coord
                        ) {
                            MemberMapPin(
                                member: member,
                                isSelected: selectedMember?.id == member.id
                            )
                            .onTapGesture {
                                withAnimation(RavenAnimation.snappy) {
                                    selectedMember = member
                                }
                            }
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .ignoresSafeArea()
            
            // Bottom sheet
            ClubBottomSheet(
                club: store.activeClub,
                members: store.members,
                expanded: $bottomSheetExpanded,
                selectedMember: $selectedMember
            )
        }
        .overlay(alignment: .top) {
            // Top bar
            clubTopBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        .sheet(item: $selectedMember) { member in
            MemberDetailSheet(member: member)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationDragIndicator(.visible)
        }
        .alert("Leave Club?", isPresented: $showLeaveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                Task {
                    await store.leaveClub()
                    dismiss()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await ClubService.shared.refreshMembers()
        }
    }
    
    // MARK: - Top Bar
    
    private var clubTopBar: some View {
        HStack(spacing: 10) {
            // Back button
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(8)
                    .liquidCapsule()
            }
            
            // Club name
            VStack(alignment: .leading, spacing: 2) {
                Text(store.activeClub?.name ?? "Club")
                    .font(.headline)
                Text("\(store.members.count) members")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Copy invite code
            if let club = store.activeClub {
                Button {
                    UIPasteboard.general.string = club.inviteCode
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                        Text(club.inviteCode)
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .liquidCapsule()
                }
            }
            
            // Leave
            Button {
                showLeaveAlert = true
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(8)
                    .liquidCapsule()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 20)
    }
    
    private func memberColor(_ member: ClubMember) -> Color {
        switch member.status {
        case .active:  return .memberActive
        case .stale:   return .memberStale
        case .dropped: return .memberDropped
        }
    }
    
    /// Compute the best available coordinate for a member.
    /// - Exact mode: use precise GPS coords if available (real lat/lng)
    /// - Approximate mode: use H3 cell center + deterministic jitter (~500m)
    /// - Returns nil if no location data exists
    private func memberCoordinate(_ member: ClubMember) -> CLLocationCoordinate2D? {
        let isExact = store.activeClub?.locationPrecision == .exact
        
        // Exact mode: prefer precise GPS coordinates
        if isExact, let lat = member.preciseLat, let lng = member.preciseLng {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        
        // Fall back to H3 cell center
        guard let cell = member.h3Cell else { return nil }
        let center = H3Lite.cellToLatLng(cell)
        
        // Approximate mode: apply deterministic jitter
        if !isExact {
            let hash = member.userId.hashValue
            let latOffset = Double(hash & 0xFFFF) / 65535.0 * 0.009 - 0.0045
            let lngOffset = Double((hash >> 16) & 0xFFFF) / 65535.0 * 0.009 - 0.0045
            return CLLocationCoordinate2D(latitude: center.lat + latOffset, longitude: center.lng + lngOffset)
        }
        
        // Exact mode but no precise coords yet — use H3 center as-is
        return CLLocationCoordinate2D(latitude: center.lat, longitude: center.lng)
    }
}
