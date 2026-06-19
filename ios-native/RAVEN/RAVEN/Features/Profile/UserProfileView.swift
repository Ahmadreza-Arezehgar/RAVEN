import SwiftUI

// MARK: - Full Profile Response
/// Lightweight identity card for another user. The social graph (posts,
/// followers, friends) was removed in the messenger pivot — this only carries
/// the fields needed to render an identity + decide whether we can message them.
struct FullProfileResponse: Codable {
    let id: String
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let bio: String?
    let joinedAt: String?
    let birthday: String?
    var showBirthday: Bool?
    var isVerified: Bool?
    var isPremium: Bool?
    var verified: Bool?      // Server fallback key
    var premium: Bool?       // Server fallback key
    var badgeType: String?
    var subscriptionTier: String?
    var canMessage: Bool?
    var isBlocked: Bool?

    // Computed helpers — coalesce all server naming variants
    var verifiedStatus: Bool {
        isVerified == true || verified == true || badgeType == "verified" || badgeType == "brand" || badgeType == "org"
    }

    var premiumStatus: Bool {
        isPremium == true || premium == true || subscriptionTier == "premium" || subscriptionTier == "raven_plus" || subscriptionTier == "raven+"
    }
}

private struct ProfileEmptyBody: Codable {}

// MARK: - Profile Cache (in-memory, survives across navigation)
private final class ProfileCache {
    static let shared = ProfileCache()
    private var cache: [String: (profile: FullProfileResponse, timestamp: Date)] = [:]
    private let maxAge: TimeInterval = 120 // 2 minutes

    func get(_ userId: String) -> FullProfileResponse? {
        guard let entry = cache[userId],
              Date().timeIntervalSince(entry.timestamp) < maxAge else {
            return nil
        }
        return entry.profile
    }

    func set(_ userId: String, profile: FullProfileResponse) {
        cache[userId] = (profile, Date())
    }
}

// MARK: - User Profile View
struct UserProfileView: View {
    let userId: String

    @Environment(\.dismiss) private var dismiss

    // Data
    @State private var profile: FullProfileResponse?
    @State private var isLoading = true
    @State private var error: Error?
    @State private var scrollOffset: CGFloat = 0
    @State private var currentUserId: String = ""

    // More menu
    @State private var showMoreMenu = false
    @State private var showReportSheet = false
    @State private var showBlockAlert = false
    @State private var isBlocked = false
    @State private var copiedLink = false

    // Collapse: 0 = full header, 1 = collapsed
    private var collapseProgress: CGFloat {
        min(1, max(0, scrollOffset / 180))
    }

    /// Whether the Message button should be visible (server-driven)
    private var canMessage: Bool {
        profile?.canMessage ?? true
    }

    /// Whether this is the current user's own profile
    private var isOwnProfile: Bool {
        userId == AuthService.shared.currentUser?.id
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                // Scroll tracker
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: ProfileScrollKey.self,
                            value: -geo.frame(in: .named("profileScroll")).minY
                        )
                }
                .frame(height: 0)

                if isLoading && profile == nil {
                    ProfileShimmer()
                } else if let profile = profile {
                    profileContent(profile)
                } else if error != nil {
                    errorState
                }
            }
            .coordinateSpace(name: "profileScroll")
            .onPreferenceChange(ProfileScrollKey.self) { scrollOffset = $0 }
            .refreshable { await loadProfile() }

            // Sticky overlay header (appears on scroll — independent of Toolbar)
            if let p = profile {
                HStack(spacing: 12) {
                    GlassAvatar(
                        name: p.displayName ?? p.username,
                        path: p.avatarUrl,
                        size: 28,
                        showGlow: false
                    )

                    Text(p.displayName ?? "@\(p.username)")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)

                    if p.verifiedStatus {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.accentBlue)
                    }

                    if p.premiumStatus {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
                .padding(.horizontal, DS.space16)
                .padding(.top, 4)
                .opacity(collapseProgress > 0.3 ? 1 : 0)
                .allowsHitTesting(collapseProgress > 0.7)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: collapseProgress > 0.3)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // ••• More menu
            ToolbarItem(placement: .navigationBarTrailing) {
                if profile != nil && !isOwnProfile {
                    Button { showMoreMenu = true } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .rotationEffect(.degrees(90))
                    }
                }
            }
        }
        .confirmationDialog("", isPresented: $showMoreMenu, titleVisibility: .hidden) {
            Button {
                showReportSheet = true
            } label: {
                Label("Report User", systemImage: "flag")
            }

            Button(isBlocked ? "Unblock User" : "Block User", role: isBlocked ? .none : .destructive) {
                showBlockAlert = true
            }

            Button {
                UIPasteboard.general.string = "raven://profile/\(userId)"
                Haptics.success()
                copiedLink = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedLink = false }
            } label: {
                Label("Copy Profile Link", systemImage: "link")
            }

            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showReportSheet) {
            ReportView(
                targetType: .user,
                targetId: userId,
                targetName: profile?.displayName ?? "User",
                reportedUserId: userId
            )
        }
        .alert(isBlocked ? "Unblock User?" : "Block User?", isPresented: $showBlockAlert) {
            Button("Cancel", role: .cancel) {}
            Button(isBlocked ? "Unblock" : "Block", role: isBlocked ? .none : .destructive) {
                Task { await toggleBlock() }
            }
        } message: {
            Text(isBlocked
                ? "This user will be able to see your profile and message you again."
                : "This user won't be able to see your profile or message you.")
        }
        .overlay(alignment: .bottom) {
            if copiedLink {
                Text("Link copied!")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.blue, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
        .animation(.spring(response: 0.3), value: copiedLink)
        .task {
            currentUserId = await KeychainService.shared.getUserId() ?? ""
            await loadProfile()
        }
    }

    // MARK: - Profile Content (identity hero + actions)
    @ViewBuilder
    private func profileContent(_ p: FullProfileResponse) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: DS.space12) {
                // Centered Avatar
                let avatarSize: CGFloat = 96 * (1.0 - collapseProgress * 0.4)
                GlassAvatar(
                    name: p.displayName ?? p.username,
                    path: p.avatarUrl,
                    size: avatarSize,
                    showGlow: true
                )
                .shadow(color: DS.accentBlue.opacity(0.15), radius: 12, y: 4)

                // Name + Badges
                HStack(spacing: 5) {
                    Text(p.displayName ?? p.username)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)

                    if p.verifiedStatus {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(DS.accentBlue)
                    }

                    if p.premiumStatus {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                    }
                }

                // Username
                Text("@\(p.username)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)

                // Bio
                if let bio = p.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.space32)
                }

                // Info chips (joined + birthday)
                HStack(spacing: 10) {
                    if let joinedAt = p.joinedAt {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10))
                            Text(formatDate(joinedAt))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    }

                    if (p.showBirthday ?? false), let birthday = p.birthday {
                        HStack(spacing: 4) {
                            Image(systemName: "gift.fill")
                                .font(.system(size: 10))
                            Text(formatDate(birthday))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }

                // Action Buttons
                actionButtons(p)
            }
            .padding(.top, 60)
            .padding(.bottom, DS.space16)
            .opacity(1.0 - collapseProgress * 0.4)
        }
        .padding(.bottom, DS.bottomTabClearance)
    }

    // MARK: - Action Buttons (Message)
    @ViewBuilder
    private func actionButtons(_ p: FullProfileResponse) -> some View {
        if !isOwnProfile && canMessage {
            messageButton(filled: true)
                .padding(.horizontal, DS.space16)
        }
    }

    /// Reusable message button
    private func messageButton(filled: Bool) -> some View {
        Button {
            Haptics.light()
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                DeepLinkRouter.shared.navigate(to: .chat(roomId: userId))
            }
        } label: {
            Label("Message", systemImage: "bubble.left.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(filled ? .white : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    Group {
                        if filled {
                            Capsule().fill(DS.accentBlue)
                        } else {
                            Capsule().fill(.ultraThinMaterial)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Network
    private func loadProfile() async {
        // 🚀 FAST PATH: Show cached profile instantly while refreshing in background
        if let cached = ProfileCache.shared.get(userId) {
            self.profile = cached
            self.isBlocked = cached.isBlocked ?? false
            self.isLoading = false
            // Background refresh (non-blocking)
            Task { await refreshProfileFromServer() }
            return
        }

        await refreshProfileFromServer()
    }

    private func refreshProfileFromServer() async {
        do {
            let profileResponse: FullProfileResponse = try await NetworkService.shared.get(
                path: "/api/users/\(userId)/profile"
            )

            await MainActor.run {
                self.profile = profileResponse
                self.isBlocked = profileResponse.isBlocked ?? false
                self.isLoading = false
            }

            ProfileCache.shared.set(userId, profile: profileResponse)
        } catch {
            // Only show error if we have no cached data
            if self.profile == nil {
                await MainActor.run {
                    self.error = error
                    self.isLoading = false
                }
            }
        }
    }

    private func toggleBlock() async {
        do {
            if isBlocked {
                try await BlockService.shared.unblockUser(userId: userId)
                await MainActor.run {
                    isBlocked = false
                }
            } else {
                let _ = try await BlockService.shared.blockUser(userId: userId)
                await MainActor.run {
                    isBlocked = true
                }
            }
        } catch {
            #if DEBUG
            print("❌ Failed to toggle block: \(error)")
            #endif
        }
    }

    // MARK: - Helpers
    private func formatDate(_ iso: String) -> String {
        let date = PerformanceConstants.iso8601Fractional.date(from: iso)
                ?? PerformanceConstants.iso8601.date(from: iso)

        guard let d = date else { return iso }
        let df = DateFormatter()
        df.dateFormat = "MMMM yyyy"
        return df.string(from: d)
    }

    // MARK: - Error State
    private var errorState: some View {
        VStack(spacing: DS.space16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Failed to load profile")
                .font(.system(size: 16, weight: .medium))
            Button("Try Again") { Task { await loadProfile() } }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.accentBlue)
        }
        .padding(.top, 100)
    }
}

// MARK: - Profile Shimmer (Liquid Glass style)
private struct ProfileShimmer: View {
    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        VStack(spacing: DS.space16) {
            // Hero card shimmer
            HStack(alignment: .top, spacing: 14) {
                Circle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 140, height: 20)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 100, height: 16)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 180, height: 14)
                }
                Spacer()
            }
            .padding(DS.space16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .padding(.horizontal, DS.space16)

            // CTA shimmer
            HStack(spacing: DS.space12) {
                Capsule()
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 44)
            }
            .padding(.horizontal, DS.space16)
        }
        .padding(.top, 80)
        .redacted(reason: .placeholder)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }
}

// MARK: - Scroll Key
private struct ProfileScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Preview
#Preview {
    UserProfileView(userId: "preview-user")
}
