//
//  ClubProfileView.swift
//  RAVEN
//
//  Club Profile — rich info page showing club details, anonymous creator
//  contact methods, member carousel, and navigation to ClubMapView.
//  Creator identity is hidden; only the club name is displayed.
//

import SwiftUI
import MapKit

// MARK: - Club Profile View

struct ClubProfileView: View {
    @State private var store = ClubStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showLeaveAlert = false
    @State private var showCopiedToast = false
    @State private var isCreatingGroup = false
    @State private var mapPosition: MapCameraPosition = .automatic
    
    private var club: Club? { store.activeClub }
    
    private var isCreator: Bool {
        guard let club = club else { return false }
        return club.creatorId == (AuthService.shared.currentUser?.id ?? "")
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header Card
                headerSection
                
                // About Section
                if let desc = club?.clubDescription, !desc.isEmpty {
                    aboutSection(desc)
                }
                
                // Contact Creator (anonymous)
                contactSection
                
                // Members
                membersSection
                
                // Mini Map Preview
                mapPreviewSection
                
                // Creator Actions
                if isCreator {
                    creatorActionsSection
                }
                
                // Main Actions
                actionsSection
                
                Spacer(minLength: DS.bottomTabClearance + 20)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationTitle(club?.name ?? "Club")
        .navigationBarTitleDisplayMode(.large)
        .alert("Leave Club?", isPresented: $showLeaveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                Task {
                    await store.leaveClub()
                    dismiss()
                }
            }
        } message: {
            Text("You will stop receiving location updates from this group.")
        }
        .overlay(alignment: .bottom) {
            if showCopiedToast {
                copiedToastView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, DS.bottomTabClearance + 16)
            }
        }
        .task {
            await ClubService.shared.refreshMembers()
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            // Club avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.orange, .red],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
                
                Image(systemName: "person.3.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .orange.opacity(0.3), radius: 16, y: 6)
            
            // Club name + members
            VStack(spacing: 4) {
                Text(club?.name ?? "Club")
                    .font(.title2.bold())
                
                Text("\(store.members.count) member\(store.members.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            // Status chips
            HStack(spacing: 10) {
                // Time remaining
                if let club = club {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                        Text(club.timeRemaining)
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12), in: Capsule())
                }
                
                // Invite code
                if let club = club {
                    Button {
                        UIPasteboard.general.string = club.inviteCode
                        showCopied()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                            Text(club.inviteCode)
                                .font(.caption.weight(.bold).monospaced())
                        }
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.blue.opacity(0.12), in: Capsule())
                    }
                }
                
                // Location precision badge
                if let club = club {
                    HStack(spacing: 4) {
                        Image(systemName: club.locationPrecision.icon)
                            .font(.caption2)
                        Text(club.locationPrecision.label)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.12), in: Capsule())
                }
                
                // Location source badge
                if let club = club {
                    HStack(spacing: 4) {
                        Image(systemName: club.locationSource.icon)
                            .font(.caption2)
                        Text(club.locationSource.label)
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    
    // MARK: - About Section
    
    private func aboutSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("About", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    
    // MARK: - Contact Section (Anonymous)
    
    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Contact", systemImage: "envelope.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            // Message on RAVEN
            if let creatorId = club?.creatorId, !isCreator {
                NavigationLink {
                    // Navigate to DM with club creator — show club name to maintain anonymity
                    ChatView(conversation: Conversation(
                        roomId: creatorId, // Will be resolved by ChatView
                        peer: Conversation.Peer(
                            userId: creatorId,
                            username: club?.name ?? "Club Creator"
                        )
                    ))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "message.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.blue.gradient, in: Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Message on RAVEN")
                                .font(.subheadline.weight(.semibold))
                            Text("Send a message to the club organizer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // Email
            if let email = club?.contactEmail, !email.isEmpty {
                Button {
                    if let url = URL(string: "mailto:\(email)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.purple.gradient, in: Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Email")
                                .font(.subheadline.weight(.semibold))
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // External link
            if let link = club?.externalLink, !link.isEmpty {
                Button {
                    var urlString = link
                    if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
                        urlString = "https://\(urlString)"
                    }
                    if let url = URL(string: urlString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.teal.gradient, in: Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("External Link")
                                .font(.subheadline.weight(.semibold))
                            Text(link)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // Show something if no contact info at all
            if club?.contactEmail == nil && club?.externalLink == nil && isCreator {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("No contact info added. Members can only reach you via RAVEN message.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    
    // MARK: - Members Section
    
    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Members", systemImage: "person.2.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(store.members.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }
            
            // Horizontal member carousel
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(store.members) { member in
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(memberColor(member).opacity(0.15))
                                    .frame(width: 52, height: 52)
                                
                                Text(String(member.displayName.prefix(1)).uppercased())
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(memberColor(member))
                                
                                // Status indicator
                                Circle()
                                    .fill(memberColor(member))
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                    .offset(x: 18, y: 18)
                            }
                            
                            Text(member.isMe ? "You" : String(member.displayName.prefix(8)))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            
                            Text(member.status.rawValue)
                                .font(.system(size: 8))
                                .foregroundStyle(memberColor(member))
                        }
                        .frame(width: 64)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    
    // MARK: - Map Preview Section
    
    private var mapPreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location", systemImage: "map.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            
            // Mini map preview
            Map(position: $mapPosition) {
                ForEach(store.members) { member in
                    if let coord = memberCoordinate(member) {
                        Annotation(member.displayName, coordinate: coord) {
                            Circle()
                                .fill(memberColor(member))
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .allowsHitTesting(false) // Preview only
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    
    // MARK: - Creator Actions
    
    private var creatorActionsSection: some View {
        VStack(spacing: 12) {
            Label("Organizer Tools", systemImage: "crown.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Create RAVEN Group button
            if club?.ravenGroupId == nil {
                Button {
                    Task { await createRavenGroup() }
                } label: {
                    HStack(spacing: 10) {
                        if isCreatingGroup {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "person.3.sequence.fill")
                                .font(.subheadline)
                        }
                        Text("Create RAVEN Group Chat")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .disabled(isCreatingGroup)
            } else {
                // Group already created — show link
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("RAVEN Group created")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(12)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            // View Map
            NavigationLink {
                ClubMapView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "map.fill")
                        .font(.subheadline)
                    Text("View Live Map")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            
            // Leave Club
            Button(role: .destructive) {
                showLeaveAlert = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline)
                    Text("Leave Club")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
    
    // MARK: - Toast
    
    private var copiedToastView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text("Invite code copied!")
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.green.gradient, in: Capsule())
        .shadow(color: .green.opacity(0.3), radius: 10, y: 4)
    }
    
    // MARK: - Helpers
    
    private func showCopied() {
        Haptics.light()
        withAnimation(.spring(response: 0.3)) { showCopiedToast = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.0))
            withAnimation { showCopiedToast = false }
        }
    }
    
    private func memberColor(_ member: ClubMember) -> Color {
        switch member.status {
        case .active:  return .memberActive
        case .stale:   return .memberStale
        case .dropped: return .memberDropped
        }
    }
    
    /// Compute the best available coordinate for a member.
    /// - Exact mode: use precise GPS coords if available
    /// - Approximate mode: use H3 cell center + deterministic jitter (~500m)
    private func memberCoordinate(_ member: ClubMember) -> CLLocationCoordinate2D? {
        let isExact = club?.locationPrecision == .exact
        
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
        
        return CLLocationCoordinate2D(latitude: center.lat, longitude: center.lng)
    }
    
    // MARK: - Create RAVEN Group
    
    private func createRavenGroup() async {
        guard let club = club else { return }
        isCreatingGroup = true
        defer { isCreatingGroup = false }
        
        // Collect all member user IDs (excluding self — GroupService adds creator automatically)
        let memberIds = store.members
            .filter { !$0.isMe }
            .map { $0.userId }
        
        // GroupService requires at least 2 members
        guard memberIds.count >= 2 else {
            #if DEBUG
            print("🐦 [Club] Need at least 2 other members to create a group")
            #endif
            return
        }
        
        do {
            let group = try await GroupService.shared.createGroup(
                name: club.name,
                memberIds: memberIds,
                description: club.clubDescription
            )
            
            // Save the group ID to the club
            var updatedClub = club
            updatedClub.ravenGroupId = group.id
            try? await ClubRepository.shared.upsertClub(updatedClub)
            
            // Refresh store to pick up the change
            await store.loadClubs()
            
            Haptics.medium()
        } catch {
            #if DEBUG
            print("🐦 [Club] Failed to create RAVEN group: \(error)")
            #endif
        }
    }
}

#Preview {
    NavigationStack {
        ClubProfileView()
    }
}
