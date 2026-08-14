import SwiftUI

// MARK: - Select Members View (Step 1)

/// Member picker for group creation - allows selecting 2+ friends
struct SelectMembersView: View {
    @Binding var selectedMembers: [GroupFriendInfo]
    var onNext: () -> Void
    
    @State private var friends: [GroupFriendInfo] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    private var filteredFriends: [GroupFriendInfo] {
        let availableFriends = friends.filter { friend in
            !selectedMembers.contains(where: { $0.id == friend.id })
        }
        
        if searchText.isEmpty {
            return availableFriends
        }
        return availableFriends.filter { $0.safeDisplayName.localizedCaseInsensitiveContains(searchText) }
    }
    
    private var canProceed: Bool {
        selectedMembers.count >= 2
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Selected members chips
            if !selectedMembers.isEmpty {
                selectedMembersSection
            }
            
            // Search bar
            searchBarSection
            
            // Friends list or states
            Group {
                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let error = errorMessage {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadFriends() }
                        }
                    }
                } else if friends.isEmpty {
                    ContentUnavailableView {
                        Label("No Contacts Yet", systemImage: "person.2.slash")
                    } description: {
                        Text("Scan a QR code to add someone, then come back to start a group.")
                    }
                } else if filteredFriends.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    friendsList
                }
            }
            
            // Next button
            nextButton
        }
        .onTapGesture { hideKeyboard() }
        .task {
            await loadFriends()
        }
    }
    
    // MARK: - Subviews
    
    private var selectedMembersSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedMembers) { member in
                    memberChip(member)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }
    
    private func memberChip(_ member: GroupFriendInfo) -> some View {
        HStack(spacing: 6) {
            // Avatar
            AsyncImage(url: member.avatarUrl.flatMap { URL(string: $0) }) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(.gray.opacity(0.3))
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())
            
            Text(member.safeDisplayName)
                .font(.subheadline)
                .lineLimit(1)
            
            Button {
                withAnimation(.spring(response: 0.3)) {
                    selectedMembers.removeAll { $0.id == member.id }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
    
    private var searchBarSection: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            
            TextField("Search friends", text: $searchText)
                .textFieldStyle(.plain)
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var friendsList: some View {
        List {
            ForEach(filteredFriends) { friend in
                Button {
                    selectFriend(friend)
                } label: {
                    HStack(spacing: 12) {
                        // Avatar
                        AsyncImage(url: friend.avatarUrl.flatMap { URL(string: $0) }) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle()
                                .fill(.gray.opacity(0.3))
                                .overlay {
                                    Text(String(friend.safeDisplayName.prefix(1)).uppercased())
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.safeDisplayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            
                            Text("@\(friend.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "plus.circle")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
    }
    
    private var nextButton: some View {
        VStack(spacing: 8) {
            if selectedMembers.count < 2 {
                Text("Select at least 2 members")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Button {
                onNext()
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canProceed ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canProceed)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Actions
    
    private func loadFriends() async {
        // 🔑 SERVERLESS-FIRST contacts (mirrors NewChatView). The primary source
        // is the local contact store (FriendDeviceRepository) — peers added
        // out-of-band via QR scan / mesh, with their keys pinned. These ALWAYS
        // show, with or without a server, so a scanned contact is immediately
        // selectable for a group. The legacy server friends list + cache are
        // merged in only when available, and a server failure never surfaces an
        // error while local contacts exist.
        let local = await localContacts()

        var combined = local
        if let cached = GroupService.shared.getCachedFriends(), !cached.isEmpty {
            combined = Self.mergeFriends(local, cached)
        }
        self.friends = combined
        self.isLoading = combined.isEmpty
        self.errorMessage = nil

        // Try the (legacy) server friends list only if online. In the
        // serverless build this fast-fails with .unauthorized — that's fine,
        // we keep the local contacts and don't surface a scary error.
        guard NetworkMonitor.shared.isOnline else {
            self.isLoading = false
            if self.friends.isEmpty {
                self.errorMessage = "No contacts yet. Scan a QR code to add someone."
            }
            return
        }

        do {
            let fetched = try await GroupService.shared.fetchFriends()
            withAnimation { self.friends = Self.mergeFriends(local, fetched) }
        } catch {
            // Keep local + cached; only message when there's truly nothing.
            if self.friends.isEmpty {
                self.errorMessage = "No contacts yet. Scan a QR code to add someone."
            }
        }

        self.isLoading = false
    }

    /// Locally-known contacts: every distinct peer we hold a trusted device
    /// for, surfaced as a pickable friend keyed by userId. The display name
    /// comes from the device label captured at QR-scan / mesh time.
    private func localContacts() async -> [GroupFriendInfo] {
        let devices = await FriendDeviceRepository.shared.getAllTrustedDevices()
        let myId = AuthService.shared.currentUser?.id
        var byUser: [String: GroupFriendInfo] = [:]
        for d in devices where d.friendUserId != myId && !d.friendUserId.isEmpty {
            if byUser[d.friendUserId] == nil {
                let name = d.deviceName ?? ""
                byUser[d.friendUserId] = GroupFriendInfo(
                    id: d.friendUserId,
                    username: name,
                    displayName: name.isEmpty ? nil : name,
                    avatarUrl: nil
                )
            }
        }
        return Array(byUser.values).sorted { $0.safeDisplayName < $1.safeDisplayName }
    }

    private static func mergeFriends(_ a: [GroupFriendInfo], _ b: [GroupFriendInfo]) -> [GroupFriendInfo] {
        var byId: [String: GroupFriendInfo] = [:]
        for f in a + b where byId[f.id] == nil { byId[f.id] = f }
        return Array(byId.values).sorted { $0.safeDisplayName < $1.safeDisplayName }
    }
    
    private func selectFriend(_ friend: GroupFriendInfo) {
        withAnimation(.spring(response: 0.3)) {
            selectedMembers.append(friend)
            // Clear the query so the picker doesn't appear to "lose" it; the
            // filtered list resets to all remaining contacts after selection.
            searchText = ""
        }

        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }
}

#Preview {
    NavigationStack {
        SelectMembersView(selectedMembers: .constant([]), onNext: {})
            .navigationTitle("Select Members")
    }
}
