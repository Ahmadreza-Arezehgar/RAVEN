//
//  ClubListView.swift
//  RAVEN
//
//  List of clubs with join-by-code and create actions.
//

import SwiftUI

// MARK: - Club List View

struct ClubListView: View {
    @State private var store = ClubStore.shared
    @State private var showCreateSheet = false
    @State private var showJoinSheet = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Active Session Banner
                if let club = store.activeClub {
                    NavigationLink {
                        ClubProfileView()
                    } label: {
                        activeClubBanner(club)
                    }
                    .buttonStyle(.plain)
                }
                
                // Action Buttons
                HStack(spacing: 12) {
                    NavigationLink {
                        CreateClubView()
                    } label: {
                        actionButton(
                            icon: "plus.circle.fill",
                            title: "Create Club",
                            gradient: [.orange, .red]
                        )
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        showJoinSheet = true
                    } label: {
                        actionButton(
                            icon: "person.badge.plus",
                            title: "Join",
                            gradient: [.blue, .purple]
                        )
                    }
                }
                .padding(.horizontal, 16)
                
                // Info Section
                VStack(alignment: .leading, spacing: 12) {
                    infoCard(
                        icon: "location.fill",
                        title: "Location Tracking",
                        description: "See your group's position using H3 cells (~150m)"
                    )
                    infoCard(
                        icon: "bell.badge.fill",
                        title: "Drop Alert",
                        description: "Get notified immediately if someone drifts away from the group"
                    )
                    infoCard(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Fully Mesh",
                        description: "Works without internet — Bluetooth only"
                    )
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 16)
            .padding(.bottom, DS.bottomTabClearance + 20)
        }
        .navigationTitle("Club")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showJoinSheet) {
            joinClubSheet
        }
        .alert("⚠️ Member Dropped!", isPresented: $store.showDropAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(store.droppedMemberName) has had no signal for over 60 seconds")
        }
        .task {
            await store.loadClubs()
        }
    }
    
    // MARK: - Active Club Banner
    
    private func activeClubBanner(_ club: Club) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.white)
                Text(club.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(club.timeRemaining)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.2), in: Capsule())
            }
            
            HStack {
                Text("\(store.members.count) members")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                
                if !store.droppedMembers.isEmpty {
                    Text("• \(store.droppedMembers.count) dropped")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                
                Spacer()
                
                Text("View Map →")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .padding(.horizontal, 16)
    }
    
    // MARK: - Action Button
    
    private func actionButton(icon: String, title: String, gradient: [Color]) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
    
    // MARK: - Info Card
    
    private func infoCard(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 36)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    // MARK: - Join Sheet
    
    private var joinClubSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                
                Text("Enter the 6-character invite code")
                    .font(.headline)
                
                TextField("e.g. ABC123", text: $store.joinCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .frame(maxWidth: 200)
                
                if let error = store.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Button {
                    Task {
                        let success = await store.joinClub()
                        if success { showJoinSheet = false }
                    }
                } label: {
                    Text("Join")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(store.joinCode.count != 6)
                
                Spacer()
            }
            .padding(24)
            .navigationTitle("Join Club")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showJoinSheet = false }
                }
            }
        }
    }
}

#Preview {
    ClubListView()
}
