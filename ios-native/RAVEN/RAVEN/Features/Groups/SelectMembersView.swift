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
                        Label("No Friends", systemImage: "person.2.slash")
                    } description: {
                        Text("Add friends first to create a group.")
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
        if let cached = GroupService.shared.getCachedFriends(), !cached.isEmpty {
            self.friends = cached
            self.isLoading = false
        } else {
            self.isLoading = true
        }
        
        self.errorMessage = nil
        
        // Skip network call entirely if offline and we already have cached data
        guard NetworkMonitor.shared.isOnline || self.friends.isEmpty else {
            self.isLoading = false
            return
        }
        
        do {
            let fetched = try await GroupService.shared.fetchFriends()
            withAnimation {
                self.friends = fetched
            }
        } catch {
            if self.friends.isEmpty {
                if (error as? URLError)?.code == .notConnectedToInternet {
                    self.errorMessage = "You're offline. Connect to the internet to load your friends list."
                } else {
                    self.errorMessage = "Couldn't load friends. Please try again."
                }
            }
        }
        
        self.isLoading = false
    }
    
    private func selectFriend(_ friend: GroupFriendInfo) {
        withAnimation(.spring(response: 0.3)) {
            selectedMembers.append(friend)
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
