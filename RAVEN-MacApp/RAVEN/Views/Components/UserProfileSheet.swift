// UserProfileSheet — opened when the user taps a user row anywhere in
// the app (feed avatars, Explore results, post authors). Shows the
// target user's profile header + their posts.

import SwiftUI

struct UserProfileSheet: View {
    let userId: String

    @Environment(\.dismiss) private var dismiss

    @State private var user: User?
    @State private var posts: [Post] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Profile").font(.title3.weight(.bold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()

            ScrollView {
                if loading {
                    ProgressView()
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(40)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        if let user {
                            ProfileHeader(user: user)
                        }
                        Divider().opacity(0.3)
                        if posts.isEmpty {
                            Text("No posts yet.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 30)
                                .frame(maxWidth: .infinity)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(Array(posts.enumerated()), id: \.element.id) { idx, post in
                                    PostCardView(post: post, index: idx)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
        }
        .frame(width: 560, height: 640)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        async let userResult = (try? await NetworkService.shared.userProfile(userId: userId))
        async let postsResult = (try? await NetworkService.shared.postsByUser(userId: userId)) ?? []
        let u = await userResult
        let p = await postsResult
        if let u { user = u } else { error = "Couldn't load profile." }
        posts = p
        loading = false
    }
}

private struct ProfileHeader: View {
    let user: User
    @EnvironmentObject var auth: AuthService
    @State private var isFollowing = false
    @State private var followBusy = false
    /// Drives the bell-settings sheet so users can configure per-user
    /// push notifications (posts + audio rooms). Same plumbing the
    /// iOS app's `ProfileBellSettingsSheet` uses.
    @State private var showBellSettings = false

    /// Hide the Follow + Bell buttons on the user's own profile.
    private var isOwnProfile: Bool { auth.currentUser?.id == user.id }

    /// Display name used in the bell sheet copy — first+last when
    /// present, falling back to `@username`.
    private var displayName: String {
        if let first = user.firstName, !first.isEmpty {
            return "\(first)\(user.lastName.map { " \($0)" } ?? "")"
        }
        return "@\(user.username)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                AvatarView(letter: user.initials, size: 72, urlString: user.avatarPath)
                VStack(alignment: .leading, spacing: 4) {
                    if let first = user.firstName, !first.isEmpty {
                        Text("\(first)\(user.lastName.map { " \($0)" } ?? "")")
                            .font(.system(size: 18, weight: .heavy))
                    } else {
                        Text(user.username)
                            .font(.system(size: 18, weight: .heavy))
                    }
                    Text("@\(user.username)")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 14))
                            .padding(.top, 4)
                    }
                }
                Spacer()
                if !isOwnProfile {
                    HStack(spacing: 10) {
                        // Bell — per-user notification preferences (posts /
                        // audio rooms). The sheet handles both load + save.
                        Button {
                            showBellSettings = true
                        } label: {
                            Image(systemName: "bell")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.08))
                                .foregroundStyle(.white)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Notification settings for \(displayName)")

                        Button {
                            Task { await toggleFollow() }
                        } label: {
                            Text(followBusy ? "…" : (isFollowing ? "Following" : "Follow"))
                                .font(.system(size: 13, weight: .heavy))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    isFollowing
                                        ? AnyShapeStyle(Color.white.opacity(0.08))
                                        : AnyShapeStyle(LinearGradient.ravenBrand)
                                )
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(followBusy)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showBellSettings) {
            BellSettingsSheet(userId: user.id, displayName: displayName)
        }
    }

    @MainActor
    private func toggleFollow() async {
        followBusy = true
        defer { followBusy = false }
        let target = !isFollowing
        do {
            if target {
                try await NetworkService.shared.followUser(userId: user.id)
            } else {
                try await NetworkService.shared.unfollowUser(userId: user.id)
            }
            isFollowing = target
        } catch {
            // Server may return 400 if already following / not following —
            // in that case toggle locally anyway so the UI matches reality.
            if let api = error as? APIError, case .http(400, _) = api {
                isFollowing = target
            } else {
                print("👤 [follow] toggle failed: \(error)")
            }
        }
    }
}
