import SwiftUI

// MARK: - Follow List Type
enum FollowListType: String {
    case followers = "Followers"
    case following = "Following"
}

// MARK: - Follow List Item
struct FollowListItem: Codable, Identifiable {
    let id: String
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let isVerified: Bool?
    let isPremium: Bool?
    var isFollowing: Bool?
    
    var verifiedStatus: Bool {
        isVerified == true
    }
}

struct FollowListResponse: Codable {
    let users: [FollowListItem]
    let total: Int
    let hasMore: Bool
}

// MARK: - Unified Follow List Sheet
struct FollowListSheet: View {
    let userId: String
    let listType: FollowListType
    let isPrivate: Bool
    let isFriend: Bool
    let isOwnProfile: Bool
    
    @Environment(\.dismiss) private var dismiss
    @State private var users: [FollowListItem] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var total = 0
    
    var body: some View {
        NavigationStack {
            Group {
                if isPrivate && !isFriend && !isOwnProfile {
                    lockedState
                } else if isLoading {
                    ProgressView()
                        .padding(.top, 80)
                } else if users.isEmpty {
                    emptyState
                } else {
                    userList
                }
            }
            .searchable(text: $searchText, prompt: "Search \(listType.rawValue.lowercased())")
            .navigationTitle("\(listType.rawValue) (\(total))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadUsers() }
            .onChange(of: searchText) { _, newValue in
                Task { await loadUsers(search: newValue) }
            }
        }
    }
    
    // MARK: - User List
    private var userList: some View {
        List(users) { user in
            HStack(spacing: 12) {
                GlassAvatar(
                    name: user.displayName ?? user.username,
                    path: user.avatarUrl,
                    size: 44,
                    showGlow: false
                )
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(user.displayName ?? user.username)
                            .font(.system(size: 15, weight: .semibold))
                        if user.verifiedStatus {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.blue)
                        }
                    }
                    Text("@\(user.username)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Action button
                actionButton(for: user)
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
    }
    
    // MARK: - Action Button
    @ViewBuilder
    private func actionButton(for user: FollowListItem) -> some View {
        let isCurrentUser = user.id == AuthService.shared.currentUser?.id
        
        if isCurrentUser {
            // No action on self
            EmptyView()
        } else if listType == .followers && isOwnProfile {
            // Remove follower button (own profile only)
            Button {
                Haptics.light()
                Task { await removeFollower(user.id) }
            } label: {
                Text("Remove")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        } else if user.isFollowing == true {
            // Already following
            Button {
                Haptics.light()
                Task { await toggleFollow(userId: user.id, currentlyFollowing: true) }
            } label: {
                Text("Following")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            // Not following
            Button {
                Haptics.light()
                Task { await toggleFollow(userId: user.id, currentlyFollowing: false) }
            } label: {
                Text("Follow")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DS.accentBlue, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Empty / Locked States
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: listType == .followers ? "person.2" : "person.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("No \(listType.rawValue.lowercased()) yet")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 80)
    }
    
    private var lockedState: some View {
        VStack(spacing: DS.space16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("\(listType.rawValue) list is private")
                .font(.system(size: 16, weight: .medium))
            Text("Follow this account to see their \(listType.rawValue.lowercased())")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 80)
    }
    
    // MARK: - Network
    private func loadUsers(search: String? = nil) async {
        guard !isPrivate || isFriend || isOwnProfile else { return }
        await MainActor.run { isLoading = true }
        do {
            var path = "/api/users/\(userId)/\(listType == .followers ? "followers" : "following")"
            if let s = search, !s.isEmpty {
                path += "?search=\(s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)"
            }
            let response: FollowListResponse = try await NetworkService.shared.get(path: path)
            await MainActor.run {
                self.users = response.users
                self.total = response.total
                self.isLoading = false
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load \(listType.rawValue): \(error)")
            #endif
            await MainActor.run { self.isLoading = false }
        }
    }
    
    private func toggleFollow(userId targetId: String, currentlyFollowing: Bool) async {
        // 🔴 ROUND 26 — unified user-action telemetry (haptic + bg server log).
        UserActionTelemetry.shared.record(
            currentlyFollowing ? .unfollow : .follow,
            targetId: targetId,
            targetType: .user
        )

        do {
            if currentlyFollowing {
                struct UnfollowResp: Decodable { let status: String; let message: String? }
                let _: UnfollowResp = try await NetworkService.shared.delete(
                    path: "/api/users/follow/\(targetId)"
                )
            } else {
                struct FollowResp: Decodable { let status: String; let message: String? }
                let _: FollowResp = try await NetworkService.shared.post(
                    path: "/api/users/follow/\(targetId)",
                    body: Empty()
                )
            }
            Haptics.success()
            // Toggle local state
            await MainActor.run {
                if let idx = users.firstIndex(where: { $0.id == targetId }) {
                    users[idx].isFollowing = !currentlyFollowing
                }
            }
        } catch {
            #if DEBUG
            print("❌ Failed to toggle follow: \(error)")
            #endif
            Haptics.error()
        }
    }
    
    private func removeFollower(_ followerId: String) async {
        do {
            let _: EmptyResponse = try await NetworkService.shared.delete(
                path: "/api/users/followers/\(followerId)"
            )
            Haptics.success()
            await MainActor.run {
                users.removeAll { $0.id == followerId }
                total = max(0, total - 1)
            }
        } catch {
            #if DEBUG
            print("❌ Failed to remove follower: \(error)")
            #endif
            Haptics.error()
        }
    }
}

