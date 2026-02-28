import SwiftUI

// MARK: - Full Profile Response
struct FullProfileResponse: Codable {
    let id: String
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let bio: String?
    let joinedAt: String?
    let birthday: String?
    let isPrivate: Bool
    let showBirthday: Bool
    var isVerified: Bool?
    var isPremium: Bool?
    var verified: Bool?      // Server fallback key
    var premium: Bool?       // Server fallback key
    var badgeType: String?
    var subscriptionTier: String?
    let postsCount: Int
    let friendsCount: Int
    let isFriend: Bool
    let requestStatus: String
    let canMessage: Bool?
    let isBlocked: Bool?
    
    // Computed helpers — coalesce all server naming variants
    var verifiedStatus: Bool {
        isVerified == true || verified == true || badgeType == "verified" || badgeType == "brand" || badgeType == "org"
    }
    
    var premiumStatus: Bool {
        isPremium == true || premium == true || subscriptionTier == "premium" || subscriptionTier == "raven_plus" || subscriptionTier == "raven+"
    }
}

// MARK: - Friend Item Response
struct FriendItem: Codable, Identifiable {
    let id: String
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let bio: String?
    let isVerified: Bool
    let isPremium: Bool?
    let verified: Bool?      // Server fallback key
    let premium: Bool?       // Server fallback key
    
    // Computed helpers — coalesce all server naming variants
    var verifiedStatus: Bool {
        isVerified || verified == true
    }
    
    var premiumStatus: Bool {
        isPremium == true || premium == true
    }
}

struct FriendsResponse: Codable {
    let friends: [FriendItem]
    let total: Int
    let hasMore: Bool
}

private struct ProfileEmptyBody: Codable {}

// MARK: - User Profile View
struct UserProfileView: View {
    let userId: String
    
    @Environment(\.dismiss) private var dismiss
    
    // Data
    @State private var profile: FullProfileResponse?
    @State private var userPosts: [Post] = []
    @State private var isLoading = true
    @State private var isLoadingPosts = false
    @State private var error: Error?
    @State private var scrollOffset: CGFloat = 0
    @State private var showFriendsList = false
    @State private var requestStatus: String = "none"
    @State private var currentUserId: String = ""
    @State private var selectedHashtag: String? = nil
    @State private var selectedPostForComments: Post?
    @State private var selectedPostForForward: Post?
    
    struct ProfilePostNavigationItem: Identifiable, Hashable {
        let id: String
    }
    @State private var selectedPostItem: ProfilePostNavigationItem?
    
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                
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
            .navigationDestination(item: $selectedPostItem) { item in
                PostDetailView(postId: item.id)
            }
            .sheet(item: $selectedPostForComments) { post in
                CommentsSheetView(post: post, feedStore: FeedStore.shared)
                    .presentationDetents([.fraction(0.55), .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
            }
            .sheet(item: $selectedPostForForward) { post in
                ForwardPostSheet(post: post)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.ultraThinMaterial)
            }
            .task {
                currentUserId = await KeychainService.shared.getUserId() ?? ""
                await loadProfile()
            }
            .sheet(isPresented: Binding(
                get: { selectedHashtag != nil },
                set: { if !$0 { selectedHashtag = nil } }
            )) {
                if let tag = selectedHashtag {
                    NavigationStack {
                        HashtagView(hashtag: tag)
                    }
                }
            }
            .sheet(isPresented: $showFriendsList) {
                FriendsListSheet(
                    userId: userId,
                    isPrivate: profile?.isPrivate ?? false,
                    isFriend: profile?.isFriend ?? false
                )
        }
    }
    
    // MARK: - Profile Content
    @ViewBuilder
    private func profileContent(_ p: FullProfileResponse) -> some View {
        VStack(spacing: DS.space16) {
            // 1) Hero Card
            heroCard(p)
            
            // 2) Stats Row
            statsRow(p)
            
            // 3) Action Buttons (2 max)
            actionButtons(p)
            
            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, DS.space16)
            
            // 4) Posts / Empty / Private
            postsSection(p)
        }
        .padding(.top, 60)
        .padding(.bottom, DS.bottomTabClearance)
    }
    
    // MARK: - Hero Card
    private func heroCard(_ p: FullProfileResponse) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Avatar (left)
            let avatarSize: CGFloat = 80 * (1.0 - collapseProgress * 0.3)
            GlassAvatar(
                name: p.displayName ?? p.username,
                path: p.avatarUrl,
                size: avatarSize,
                showGlow: true
            )
            
            // Info (right)
            VStack(alignment: .leading, spacing: 5) {
                // Name + Verified
                HStack(spacing: 5) {
                    Text(p.displayName ?? p.username)
                        .font(.system(size: 20, weight: .bold))
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
                
                // Bio (2 lines max)
                if let bio = p.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                
                // Info chips
                HStack(spacing: 12) {
                    if let joinedAt = p.joinedAt {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10))
                            Text(formatDate(joinedAt))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.tertiary)
                    }
                    
                    if p.showBirthday, let birthday = p.birthday {
                        HStack(spacing: 4) {
                            Image(systemName: "gift.fill")
                                .font(.system(size: 10))
                            Text(formatDate(birthday))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
            
            Spacer(minLength: 0)
        }
        .padding(DS.space16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space16)
        .opacity(1.0 - collapseProgress * 0.4)
    }
    
    // MARK: - Stats Row
    private func statsRow(_ p: FullProfileResponse) -> some View {
        HStack(spacing: 0) {
            // Posts
            statItem(value: p.postsCount, label: "Posts")
            
            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 0.5, height: 32)
            
            // Friends
            Button { showFriendsList = true } label: {
                statItem(
                    value: p.friendsCount,
                    label: "Friends",
                    locked: p.isPrivate && !p.isFriend
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, DS.space12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space16)
    }
    
    private func statItem(value: Int, label: String, locked: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 20, weight: .bold))
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Action Buttons (2 CTAs max)
    private func actionButtons(_ p: FullProfileResponse) -> some View {
        Group {
        if isOwnProfile {
            EmptyView()
        } else {
        HStack(spacing: DS.space12) {
            switch requestStatus {
            case "accepted":
                // Friends → Primary = Message, Secondary = Friends ✓
                if canMessage {
                    Button {
                        Haptics.light()
                        #if DEBUG
                        print("📩 [Profile] Message tapped → navigating to DM with \(userId)")
                        #endif
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            DeepLinkRouter.shared.navigate(to: .chat(roomId: userId))
                        }
                    } label: {
                        Label("Message", systemImage: "bubble.left.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(DS.accentBlue, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                
                // Friends ✓ badge
                Label("Friends", systemImage: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: canMessage ? nil : .infinity)
                    .frame(height: 44)
                    .padding(.horizontal, canMessage ? 20 : 0)
                    .background(Color.green.opacity(0.12), in: Capsule())
                
            case "pending":
                // Pending → Primary = Pending (disabled), Secondary = Message
                Label("Pending", systemImage: "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                
                if canMessage {
                    Button {
                        Haptics.light()
                        #if DEBUG
                        print("📩 [Profile] Message tapped → navigating to DM with \(userId)")
                        #endif
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            DeepLinkRouter.shared.navigate(to: .chat(roomId: userId))
                        }
                    } label: {
                        Label("Message", systemImage: "bubble.left.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                
            default:
                // Not friend → Primary = Add Friend, Secondary = Message
                Button {
                    Haptics.light()
                    Task { await sendFriendRequest() }
                } label: {
                    Label("Add Friend", systemImage: "person.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(DS.accentBlue, in: Capsule())
                }
                .buttonStyle(.plain)
                
                if canMessage {
                    Button {
                        Haptics.light()
                        #if DEBUG
                        print("📩 [Profile] Message tapped → navigating to DM with \(userId)")
                        #endif
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            DeepLinkRouter.shared.navigate(to: .chat(roomId: userId))
                        }
                    } label: {
                        Label("Message", systemImage: "bubble.left.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        } // else
        } // Group
        .padding(.horizontal, DS.space16)
    }
    
    // MARK: - Posts Section
    @ViewBuilder
    private func postsSection(_ p: FullProfileResponse) -> some View {
        if p.isPrivate && !p.isFriend {
            // Private lock card
            privateLockCard()
        } else if isLoadingPosts && userPosts.isEmpty {
            // List shimmer
            postsShimmer()
        } else if userPosts.isEmpty {
            // Glass empty state
            emptyPostsCard()
        } else {
            // Posts header + list
            VStack(spacing: 0) {
                HStack {
                    Text("Posts")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, DS.space16)
                .padding(.bottom, DS.space8)
                
                LazyVStack(spacing: 0) {
                    ForEach(userPosts) { post in
                        PostCard(
                            post: post,
                            feedStore: FeedStore.shared,
                            currentUserId: currentUserId,
                            onOpenComments: {
                                selectedPostForComments = post
                            },
                            onForward: {
                                selectedPostForForward = post
                            },
                            onHashtagTap: { tag in
                                selectedHashtag = tag
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedPostItem = ProfilePostNavigationItem(id: post.id)
                        }
                        
                        Divider()
                    }
                }
            }
        }
    }
    
    // MARK: - Private Lock Card
    private func privateLockCard() -> some View {
        VStack(spacing: DS.space12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.6))
            
            Text("This profile is private")
                .font(.system(size: 17, weight: .semibold))
            
            Text("Add as friend to see their posts.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if requestStatus == "none" {
                Button {
                    Haptics.light()
                    Task { await sendFriendRequest() }
                } label: {
                    Text("Send Friend Request")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.accentBlue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            } else if requestStatus == "pending" {
                Text("Friend Request Sent")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space32)
        .padding(.horizontal, DS.space16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space16)
    }
    
    // MARK: - Empty Posts Card
    private func emptyPostsCard() -> some View {
        VStack(spacing: DS.space12) {
            Image(systemName: "camera")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))
            
            Text("No posts yet")
                .font(.system(size: 17, weight: .semibold))
            
            Text("Be the first to start a conversation.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            // Contextual CTA
            if canMessage {
                Button {
                    Haptics.light()
                    #if DEBUG
                    print("📩 [Profile] Message tapped → navigating to DM with \(userId)")
                    #endif
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        DeepLinkRouter.shared.navigate(to: .chat(roomId: userId))
                    }
                } label: {
                    Label("Send a message", systemImage: "bubble.left.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.accentBlue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            } else if requestStatus == "none" {
                Button {
                    Haptics.light()
                    Task { await sendFriendRequest() }
                } label: {
                    Label("Add Friend", systemImage: "person.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.accentBlue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space32)
        .padding(.horizontal, DS.space16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space16)
    }
    
    // MARK: - Posts Shimmer
    private func postsShimmer() -> some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                PostSkeletonView()
                Divider()
            }
        }
    }
    
    // MARK: - Network
    private func loadProfile() async {
        do {
            let response: FullProfileResponse = try await NetworkService.shared.get(
                path: "/api/users/\(userId)/profile"
            )
            await MainActor.run {
                self.profile = response
                self.requestStatus = response.requestStatus
                self.isBlocked = response.isBlocked ?? false
                self.isLoading = false
            }
            // Load posts if allowed
            if !response.isPrivate || response.isFriend {
                await loadPosts()
            }
        } catch {
            await MainActor.run {
                self.error = error
                self.isLoading = false
            }
        }
    }
    

    private func loadPosts() async {
        await MainActor.run { isLoadingPosts = true }
        do {
            let posts: [Post] = try await NetworkService.shared.get(
                path: "/api/posts/user/\(userId)"
            )
            await MainActor.run {
                self.userPosts = posts.filter { !$0.content.looksEncrypted }
                self.isLoadingPosts = false
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load user posts: \(error)")
            #endif
            await MainActor.run { isLoadingPosts = false }
        }
    }
    
    private func sendFriendRequest() async {
        do {
            let _: EmptyResponse = try await NetworkService.shared.post(
                path: "/api/users/friend-request",
                body: Empty(),
                queryItems: [URLQueryItem(name: "recipient_id", value: userId)]
            )
            Haptics.success()
            await MainActor.run { requestStatus = "pending" }
        } catch {
            #if DEBUG
            print("❌ Failed to send friend request: \(error)")
            #endif
            Haptics.error()
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

// MARK: - API Helpers
private struct BlockToggleRequest: Encodable {
    let blocked_id: String
}

private struct BlockToggleResponse: Decodable {
    let success: Bool?
    let message: String?
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
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 140, height: 20)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: 100, height: 16)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 180, height: 14)
                }
                Spacer()
            }
            .padding(DS.space16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .padding(.horizontal, DS.space16)
            
            // Stats shimmer
            HStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { i in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 30, height: 20)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 50, height: 13)
                    }
                    .frame(maxWidth: .infinity)
                    if i == 0 {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 0.5, height: 32)
                    }
                }
            }
            .padding(.vertical, DS.space12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
            .padding(.horizontal, DS.space16)
            
            // CTA shimmer
            HStack(spacing: DS.space12) {
                Capsule()
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 44)
                Capsule()
                    .fill(Color.gray.opacity(0.1))
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

// MARK: - Friends List Sheet
private struct FriendsListSheet: View {
    let userId: String
    let isPrivate: Bool
    let isFriend: Bool
    
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [FriendItem] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var total = 0
    
    var body: some View {
        NavigationStack {
            Group {
                if isPrivate && !isFriend {
                    VStack(spacing: DS.space16) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("Friends list is private")
                            .font(.system(size: 16, weight: .medium))
                        Text("You need to be friends to see this list")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 80)
                } else if isLoading {
                    ProgressView()
                        .padding(.top, 80)
                } else if friends.isEmpty {
                    Text("No friends yet")
                        .foregroundStyle(.secondary)
                        .padding(.top, 80)
                } else {
                    List(friends) { friend in
                        HStack(spacing: 12) {
                            GlassAvatar(
                                name: friend.displayName ?? friend.username,
                                path: friend.avatarUrl,
                                size: 44,
                                showGlow: false
                            )
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(friend.displayName ?? friend.username)
                                        .font(.system(size: 15, weight: .semibold))
                                    if friend.verifiedStatus {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.blue)
                                    }
                                }
                                Text("@\(friend.username)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: "Search friends")
            .navigationTitle("Friends (\(total))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadFriends() }
            .onChange(of: searchText) { _, newValue in
                Task { await loadFriends(search: newValue) }
            }
        }
    }
    
    private func loadFriends(search: String? = nil) async {
        guard !isPrivate || isFriend else { return }
        await MainActor.run { isLoading = true }
        do {
            var path = "/api/users/\(userId)/friends"
            if let s = search, !s.isEmpty {
                path += "?search=\(s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)"
            }
            let response: FriendsResponse = try await NetworkService.shared.get(path: path)
            await MainActor.run {
                self.friends = response.friends
                self.total = response.total
                self.isLoading = false
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load friends: \(error)")
            #endif
            await MainActor.run { isLoading = false }
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
