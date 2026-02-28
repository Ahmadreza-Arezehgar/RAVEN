import SwiftUI

// MARK: - Privacy Settings View
struct PrivacySettingsView: View {
    @AppStorage("showOnlineStatus") private var showOnlineStatus = true
    @AppStorage("whoCanMessage") private var whoCanMessage = "everyone"
    @AppStorage("whoCanSeeProfile") private var whoCanSeeProfile = "public"
    @AppStorage("readReceipts") private var readReceipts = true
    
    @State private var isSyncing = false
    @State private var syncTask: Task<Void, Never>?
    @State private var showPaywall = false
    @State private var showSyncError = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Online Status
                SettingsSection(title: "Activity") {
                    SettingsToggleRow(
                        title: "Show Online Status",
                        subtitle: "Let others see when you're online",
                        icon: "circle.fill",
                        iconColor: .green,
                        isOn: $showOnlineStatus
                    )
                    // ✅ Bug 7 fix: Pass the old value explicitly so rollback works
                    .onChange(of: showOnlineStatus) { oldValue, _ in
                        syncToServer(oldOnlineStatus: oldValue)
                    }
                    
                    SettingsToggleRow(
                        title: "Read Receipts",
                        subtitle: SubscriptionService.shared.isPremium ? "Show when you've read messages" : "Unlock Ghost Mode with RAVEN+",
                        icon: SubscriptionService.shared.isPremium ? "checkmark.circle.fill" : "eye.slash.fill",
                        iconColor: SubscriptionService.shared.isPremium ? .blue : .purple,
                        isOn: Binding(
                            get: { SubscriptionService.shared.isPremium ? readReceipts : true },
                            set: { newValue in
                                if !SubscriptionService.shared.isPremium {
                                    showPaywall = true
                                } else {
                                    let oldReadReceipts = readReceipts
                                    readReceipts = newValue
                                    syncToServer(oldReadReceipts: oldReadReceipts)
                                }
                            }
                        )
                    )
                }
                
                // Who Can Reach You
                SettingsSection(title: "Who Can Reach You") {
                    SettingsPickerRow(
                        title: "Who can message me",
                        icon: "message.fill",
                        iconColor: .purple,
                        selection: $whoCanMessage,
                        options: [
                            ("everyone", "Everyone"),
                            ("friends", "Friends Only")
                        ]
                    )
                    .onChange(of: whoCanMessage) { oldValue, _ in
                        syncToServer(oldWhoCanMessage: oldValue)
                    }
                    
                    SettingsPickerRow(
                        title: "Who can see my profile",
                        icon: "person.circle.fill",
                        iconColor: .orange,
                        selection: $whoCanSeeProfile,
                        options: [
                            ("public", "Public"),
                            ("friends", "Friends Only")
                        ]
                    )
                    .onChange(of: whoCanSeeProfile) { oldValue, _ in
                        syncToServer(oldWhoCanSeeProfile: oldValue)
                    }
                }
                
                // Blocked Users
                SettingsSection(title: "Blocked") {
                    NavigationLink {
                        BlockedUsersView()
                    } label: {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(Color.red.opacity(0.15))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Image(systemName: "hand.raised.fill")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(.red)
                                )
                            
                            Text("Blocked Users")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.primary)
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary.opacity(0.5))
                        }
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            RavenPlusPaywallView()
        }
        .alert("Sync Failed", isPresented: $showSyncError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your privacy settings could not be saved to the server. They have been reverted to their previous values.")
        }
    }
    
    /// Sync privacy settings to server (debounced)
    /// ✅ Bug 7 fix: Accept the specific old value that changed so rollback restores
    /// the actual previous state, not the already-toggled current state.
    private func syncToServer(
        oldOnlineStatus: Bool? = nil,
        oldReadReceipts: Bool? = nil,
        oldWhoCanMessage: String? = nil,
        oldWhoCanSeeProfile: String? = nil
    ) {
        // Cancel any pending sync to coalesce rapid changes
        syncTask?.cancel()
        
        // Snapshot: use the explicit old value for whichever field changed;
        // for the other fields the current value IS the old value (unchanged).
        let rollbackOnlineStatus = oldOnlineStatus ?? showOnlineStatus
        let rollbackReadReceipts = oldReadReceipts ?? readReceipts
        let rollbackWhoCanMessage = oldWhoCanMessage ?? whoCanMessage
        let rollbackWhoCanSeeProfile = oldWhoCanSeeProfile ?? whoCanSeeProfile
        
        syncTask = Task {
            // Debounce: wait 300ms for more changes
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            
            isSyncing = true
            defer { isSyncing = false }
            
            let payload = PrivacySettingsPayload(
                showOnlineStatus: showOnlineStatus,
                // Prevent Ghost Mode smuggling: force true if subscription expired
                readReceipts: SubscriptionService.shared.isPremium ? readReceipts : true,
                whoCanMessage: whoCanMessage,
                whoCanSeeProfile: whoCanSeeProfile
            )
            
            do {
                let _: PrivacyEmptyResponse = try await NetworkService.shared.patch(
                    path: "/api/users/privacy",
                    body: payload
                )
                #if DEBUG
                print("✅ Privacy settings synced to server")
                #endif
            } catch {
                #if DEBUG
                print("⚠️ Failed to sync privacy settings: \(error)")
                #endif
                // Rollback to old values so UI matches server state
                await MainActor.run {
                    showOnlineStatus = rollbackOnlineStatus
                    readReceipts = rollbackReadReceipts
                    whoCanMessage = rollbackWhoCanMessage
                    whoCanSeeProfile = rollbackWhoCanSeeProfile
                    showSyncError = true
                }
            }
        }
    }
}

// MARK: - Privacy Settings Payload
private struct PrivacySettingsPayload: Encodable {
    let showOnlineStatus: Bool
    let readReceipts: Bool
    let whoCanMessage: String
    let whoCanSeeProfile: String
    
    enum CodingKeys: String, CodingKey {
        case showOnlineStatus = "show_online_status"
        case readReceipts = "read_receipts"
        case whoCanMessage = "who_can_message"
        case whoCanSeeProfile = "who_can_see_profile"
    }
}

private struct PrivacyEmptyResponse: Decodable {}

// MARK: - Settings Picker Row
struct SettingsPickerRow: View {
    let title: String
    let icon: String
    let iconColor: Color
    @Binding var selection: String
    let options: [(String, String)] // (value, label)
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(iconColor)
                    )
                
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                
                Spacer()
            }
            .padding(14)
            
            // Segmented Picker
            HStack(spacing: 4) {
                ForEach(options, id: \.0) { option in
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.3)) {
                            selection = option.0
                        }
                    } label: {
                        Text(option.1)
                            .font(.system(size: 13, weight: selection == option.0 ? .semibold : .medium))
                            .foregroundColor(selection == option.0 ? .primary : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selection == option.0 ? Color.white.opacity(0.18) : Color.clear)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(.systemGray5).opacity(0.5))
            .clipShape(Capsule())
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }
}

// MARK: - Blocked User Model
struct BlockedUser: Identifiable, Codable {
    let id: String
    let username: String
    let avatarUrl: String?
    let blockedAt: Date?
    
    enum CodingKeys: String, CodingKey {
        case id
        case username
        case avatarUrl = "avatar_url"
        case blockedAt = "blocked_at"
    }
}

// MARK: - Blocked Users View
struct BlockedUsersView: View {
    @State private var blockedUsers: [BlockedUser] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var userToUnblock: BlockedUser?
    @State private var showUnblockAlert = false
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if blockedUsers.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "hand.raised.slash")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)
                    
                    Text("No Blocked Users")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Text("When you block someone, they'll appear here")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(blockedUsers) { user in
                            BlockedUserRow(user: user) {
                                userToUnblock = user
                                showUnblockAlert = true
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Blocked Users")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await fetchBlockedUsers()
        }
        .refreshable {
            await fetchBlockedUsers()
        }
        .alert("Unblock User", isPresented: $showUnblockAlert, presenting: userToUnblock) { user in
            Button("Cancel", role: .cancel) {}
            Button("Unblock", role: .destructive) {
                Task {
                    await unblockUser(user)
                }
            }
        } message: { user in
            Text("Are you sure you want to unblock @\(user.username)?")
        }
    }
    
    private func fetchBlockedUsers() async {
        isLoading = true
        errorMessage = nil
        
        do {
            blockedUsers = try await NetworkService.shared.get(path: "/api/users/blocked")
            #if DEBUG
            print("📥 Fetched \(blockedUsers.count) blocked users")
            #endif
        } catch {
            errorMessage = error.localizedDescription
            #if DEBUG
            print("❌ Failed to fetch blocked users: \(error)")
            #endif
        }
        
        isLoading = false
    }
    
    private func unblockUser(_ user: BlockedUser) async {
        do {
            try await BlockService.shared.unblockUser(userId: user.id)
            
            // Remove from local list
            await MainActor.run {
                blockedUsers.removeAll { $0.id == user.id }
                Haptics.success()
            }
            
            #if DEBUG
            print("✅ Unblocked user: \(user.username)")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to unblock user: \(error)")
            #endif
            await MainActor.run {
                Haptics.error()
            }
        }
    }
}

// MARK: - Blocked User Row
struct BlockedUserRow: View {
    let user: BlockedUser
    let onUnblock: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            AsyncImage(url: URL(string: user.avatarUrl ?? "")) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                @unknown default:
                    Color.gray
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            
            // Username
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(user.username)")
                    .font(.system(size: 16, weight: .medium))
                
                if let blockedAt = user.blockedAt {
                    Text("Blocked \(blockedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Unblock Button
            Button {
                Haptics.light()
                onUnblock()
            } label: {
                Text("Unblock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        PrivacySettingsView()
    }
}

