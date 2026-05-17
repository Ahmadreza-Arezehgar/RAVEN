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
    let showLikedPosts: Bool?
    let showReplies: Bool?
    
    // ===== Follow system fields =====
    var followersCount: Int?
    var followingCount: Int?
    var mutualFriendsCount: Int?
    var followStatus: String?    // "none", "following", "requested", "mutual", "self"
    var isFollowingYou: Bool?
    
    // Computed helpers — coalesce all server naming variants
    var verifiedStatus: Bool {
        isVerified == true || verified == true || badgeType == "verified" || badgeType == "brand" || badgeType == "org"
    }
    
    var premiumStatus: Bool {
        isPremium == true || premium == true || subscriptionTier == "premium" || subscriptionTier == "raven_plus" || subscriptionTier == "raven+"
    }
    
    /// Resolved follow status with fallback to legacy requestStatus
    var resolvedFollowStatus: String {
        if let fs = followStatus, fs != "none" { return fs }
        // Fallback: map legacy requestStatus
        switch requestStatus {
        case "accepted": return "mutual"
        case "pending": return "requested"
        default: return "none"
        }
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

// MARK: - Profile Cache (in-memory, survives across navigation)
private final class ProfileCache {
    static let shared = ProfileCache()
    private var cache: [String: (profile: FullProfileResponse, posts: [Post], timestamp: Date)] = [:]
    private let maxAge: TimeInterval = 120 // 2 minutes
    
    func get(_ userId: String) -> (profile: FullProfileResponse, posts: [Post])? {
        guard let entry = cache[userId],
              Date().timeIntervalSince(entry.timestamp) < maxAge else {
            return nil
        }
        return (entry.profile, entry.posts)
    }
    
    func set(_ userId: String, profile: FullProfileResponse, posts: [Post]) {
        cache[userId] = (profile, posts, Date())
    }
}

// MARK: - Profile Tab Enum
enum ProfileTab: String, CaseIterable, Hashable {
    case posts
    case replies
    case likes
    
    var title: String {
        switch self {
        case .posts: return "Posts"
        case .replies: return "Replies"
        case .likes: return "Likes"
        }
    }
    
    var icon: String {
        switch self {
        case .posts: return "square.grid.2x2"
        case .replies: return "arrowshape.turn.up.left"
        case .likes: return "heart"
        }
    }
}

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
    @State private var followStatus: String = "none"
    @State private var currentUserId: String = ""
    @State private var showFollowersList = false
    @State private var showFollowingList = false
    @State private var selectedHashtag: String? = nil
    @State private var selectedPostForComments: Post?
    @State private var selectedPostForForward: Post?
    
    // Tabbed content
    @State private var selectedTab: ProfileTab = .posts
    @State private var likedPosts: [Post] = []
    @State private var repliedPosts: [Post] = []
    @State private var isLoadingLikes = false
    @State private var isLoadingReplies = false
    
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
    
    // Bell notifications
    @State private var showBellSheet = false
    @State private var isBellActive = false
    
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
                // 🔔 Bell notification icon
                ToolbarItem(placement: .navigationBarTrailing) {
                    if profile != nil && !isOwnProfile {
                        Button { showBellSheet = true } label: {
                            Image(systemName: isBellActive ? "bell.fill" : "bell")
                                .font(.system(size: 15, weight: .semibold))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(isBellActive ? .yellow : .primary)
                                .animation(.spring(response: 0.3), value: isBellActive)
                        }
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
                // Load bell subscription state
                if !isOwnProfile {
                    await loadBellState()
                }
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
            .sheet(isPresented: $showFollowersList) {
                FollowListSheet(
                    userId: userId,
                    listType: .followers,
                    isPrivate: profile?.isPrivate ?? false,
                    isFriend: profile?.isFriend ?? false,
                    isOwnProfile: isOwnProfile
                )
            }
            .sheet(isPresented: $showFollowingList) {
                FollowListSheet(
                    userId: userId,
                    listType: .following,
                    isPrivate: profile?.isPrivate ?? false,
                    isFriend: profile?.isFriend ?? false,
                    isOwnProfile: isOwnProfile
                )
        }
            .sheet(isPresented: $showBellSheet) {
                ProfileBellSettingsSheet(
                    userId: userId,
                    displayName: profile?.displayName ?? profile?.username ?? "User",
                    avatarUrl: profile?.avatarUrl,
                    onDismiss: {
                        Task { await loadBellState() }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
            }
    }
    
    // MARK: - Profile Content (1/4 Hero + 3/4 Tabbed)
    @ViewBuilder
    private func profileContent(_ p: FullProfileResponse) -> some View {
        VStack(spacing: 0) {
            // ───── 1/4 Hero Header ─────
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
                    
                    if p.showBirthday, let birthday = p.birthday {
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
                
                // Stats capsule
                statsRow(p)
                
                // Action Buttons
                actionButtons(p)
            }
            .padding(.top, 60)
            .padding(.bottom, DS.space16)
            .opacity(1.0 - collapseProgress * 0.4)
            
            // ───── Divider ─────
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
            
            // ───── Segmented Capsule Tab Picker ─────
            profileTabPicker(p)
                .padding(.top, DS.space12)
                .padding(.bottom, DS.space8)
            
            // ───── 3/4 Tabbed Content ─────
            tabbedContentSection(p)
        }
        .padding(.bottom, DS.bottomTabClearance)
    }
    

    
    // MARK: - Stats Row (3-column: Posts | Following | Friends)
    private func statsRow(_ p: FullProfileResponse) -> some View {
        let isLocked = p.isPrivate && !p.isFriend && !isOwnProfile
        
        return HStack(spacing: 0) {
            // Posts
            statItem(value: p.postsCount, label: "Posts")
            
            statDivider
            
            // Following
            Button { if !isLocked { showFollowingList = true } } label: {
                statItem(value: p.followingCount ?? 0, label: "Following", locked: isLocked)
            }
            .buttonStyle(.plain)
            
            statDivider
            
            // Friends (mutual)
            Button { if !isLocked { showFriendsList = true } } label: {
                statItem(value: p.mutualFriendsCount ?? p.friendsCount, label: "Friends", locked: isLocked)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, DS.space12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space16)
    }
    
    private var statDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 0.5, height: 32)
    }
    
    private func statItem(value: Int, label: String, locked: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold))
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Action Buttons (Follow State Machine)
    private func actionButtons(_ p: FullProfileResponse) -> some View {
        Group {
        if isOwnProfile {
            EmptyView()
        } else {
            VStack(spacing: DS.space8) {
                // "Follows you" badge
                if p.isFollowingYou == true && followStatus != "mutual" {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill.checkmark")
                            .font(.system(size: 11))
                        Text("Follows you")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                
                HStack(spacing: DS.space12) {
                    switch followStatus {
                    case "mutual":
                        // Mutual = Friends → Primary = Message, Secondary = Friends ✓
                        if canMessage {
                            messageButton(filled: true)
                        }
                        
                        Button {
                            Haptics.light()
                            Task { await unfollowUser() }
                        } label: {
                            Label("Friends", systemImage: "person.2.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.green)
                                .frame(maxWidth: canMessage ? nil : .infinity)
                                .frame(height: 44)
                                .padding(.horizontal, canMessage ? 20 : 0)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        
                    case "following":
                        // Following (not mutual) → Primary = Following ✓, Secondary = Message
                        Button {
                            Haptics.light()
                            Task { await unfollowUser() }
                        } label: {
                            Label("Following", systemImage: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.green.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(Color.green.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        
                        if canMessage {
                            messageButton(filled: false)
                        }
                        
                    case "requested":
                        // Requested → tap to cancel
                        Button {
                            Haptics.light()
                            Task { await unfollowUser() }
                        } label: {
                            Label("Requested", systemImage: "clock")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        
                        if canMessage {
                            messageButton(filled: false)
                        }
                        
                    default:
                        // Not following → Follow button
                        Button {
                            Haptics.light()
                            Task { await followUser() }
                        } label: {
                            Label("Follow", systemImage: "person.badge.plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(DS.accentBlue, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        
                        if canMessage {
                            messageButton(filled: false)
                        }
                    }
                }
            }
        }
        } // Group
        .padding(.horizontal, DS.space16)
    }
    
    /// Reusable message button
    private func messageButton(filled: Bool) -> some View {
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
    
    // MARK: - Segmented Capsule Tab Picker
    @Namespace private var tabAnimation
    
    private func profileTabPicker(_ p: FullProfileResponse) -> some View {
        let tabs = availableTabs(for: p)
        
        return HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                    // Load tab data on first tap
                    Task { await loadTabData(tab) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 14, weight: selectedTab == tab ? .bold : .medium))
                    }
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if selectedTab == tab {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    Capsule()
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color.primary.opacity(0.15), Color.primary.opacity(0.05)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 0.5
                                        )
                                )
                                .shadow(color: DS.shadowColor, radius: 4, y: 2)
                                .matchedGeometryEffect(id: "tabIndicator", in: tabAnimation)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(Color(.systemGray6).opacity(0.6))
        )
        .padding(.horizontal, DS.space16)
    }
    
    private func availableTabs(for p: FullProfileResponse) -> [ProfileTab] {
        var tabs: [ProfileTab] = [.posts]
        
        // Show Replies tab if: own profile OR showReplies is true
        if isOwnProfile || (p.showReplies ?? true) {
            tabs.append(.replies)
        }
        
        // Show Likes tab if: own profile OR showLikedPosts is true
        if isOwnProfile || (p.showLikedPosts ?? true) {
            tabs.append(.likes)
        }
        
        return tabs
    }
    
    // MARK: - Tabbed Content Section
    @ViewBuilder
    private func tabbedContentSection(_ p: FullProfileResponse) -> some View {
        if p.isPrivate && !p.isFriend && !isOwnProfile {
            privateLockCard()
        } else {
            switch selectedTab {
            case .posts:
                postsList()
            case .replies:
                repliesList()
            case .likes:
                likesList()
            }
        }
    }
    
    // MARK: - Posts List
    @ViewBuilder
    private func postsList() -> some View {
        if isLoadingPosts && userPosts.isEmpty {
            postsShimmer()
        } else if userPosts.isEmpty {
            tabEmptyState(
                icon: "square.and.pencil",
                title: "No posts yet",
                subtitle: isOwnProfile ? "Share your first post with the world." : "This user hasn't posted yet."
            )
        } else {
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
    
    // MARK: - Replies List
    @ViewBuilder
    private func repliesList() -> some View {
        if isLoadingReplies && repliedPosts.isEmpty {
            postsShimmer()
        } else if repliedPosts.isEmpty {
            tabEmptyState(
                icon: "arrowshape.turn.up.left",
                title: "No replies yet",
                subtitle: isOwnProfile ? "Posts you reply to will appear here." : "This user hasn't replied to any posts yet."
            )
        } else {
            LazyVStack(spacing: 0) {
                ForEach(repliedPosts) { post in
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
    
    // MARK: - Likes List
    @ViewBuilder
    private func likesList() -> some View {
        if isLoadingLikes && likedPosts.isEmpty {
            postsShimmer()
        } else if likedPosts.isEmpty {
            tabEmptyState(
                icon: "heart",
                title: "No liked posts",
                subtitle: isOwnProfile ? "Posts you like will appear here." : "This user hasn't liked any posts yet."
            )
        } else {
            LazyVStack(spacing: 0) {
                ForEach(likedPosts) { post in
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
    
    // MARK: - Tab Empty State (Liquid Glass)
    private func tabEmptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: DS.space12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))
            
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space32)
        .padding(.horizontal, DS.space16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space16)
        .padding(.top, DS.space8)
    }
    
    // MARK: - Network
    private func loadProfile() async {
        // 🚀 FAST PATH: Show cached profile instantly while refreshing in background
        if let cached = ProfileCache.shared.get(userId) {
            self.profile = cached.profile
            self.requestStatus = cached.profile.requestStatus
            self.followStatus = cached.profile.resolvedFollowStatus
            self.isBlocked = cached.profile.isBlocked ?? false
            self.userPosts = cached.posts
            self.isLoading = false
            self.isLoadingPosts = false
            // Background refresh (non-blocking)
            Task { await refreshProfileFromServer() }
            return
        }
        
        await refreshProfileFromServer()
    }
    
    /// Fetches profile and posts in PARALLEL (was sequential before)
    private func refreshProfileFromServer() async {
        do {
            // 🚀 PARALLEL: Fire profile + posts requests simultaneously
            // Previously these were sequential (profile → wait → posts), doubling latency.
            let canLoadPosts: Bool
            let profileResponse: FullProfileResponse = try await NetworkService.shared.get(
                path: "/api/users/\(userId)/profile"
            )
            canLoadPosts = !profileResponse.isPrivate || profileResponse.isFriend
            
            // Update profile UI immediately
            await MainActor.run {
                self.profile = profileResponse
                self.requestStatus = profileResponse.requestStatus
                self.followStatus = profileResponse.resolvedFollowStatus
                self.isBlocked = profileResponse.isBlocked ?? false
                self.isLoading = false
            }
            
            // Load posts in parallel (if allowed)
            if canLoadPosts {
                await loadPosts()
            }
            
            // Cache for instant re-visits
            ProfileCache.shared.set(userId, profile: profileResponse, posts: self.userPosts)
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
    
    private func loadTabData(_ tab: ProfileTab) async {
        switch tab {
        case .posts:
            if userPosts.isEmpty { await loadPosts() }
        case .replies:
            if repliedPosts.isEmpty { await loadRepliedPosts() }
        case .likes:
            if likedPosts.isEmpty { await loadLikedPosts() }
        }
    }
    
    private func loadLikedPosts() async {
        await MainActor.run { isLoadingLikes = true }
        do {
            let posts: [Post] = try await NetworkService.shared.get(
                path: "/api/posts/user/\(userId)/likes"
            )
            await MainActor.run {
                self.likedPosts = posts.filter { !$0.content.looksEncrypted }
                self.isLoadingLikes = false
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load liked posts: \(error)")
            #endif
            await MainActor.run { isLoadingLikes = false }
        }
    }
    
    private func loadRepliedPosts() async {
        await MainActor.run { isLoadingReplies = true }
        do {
            let posts: [Post] = try await NetworkService.shared.get(
                path: "/api/posts/user/\(userId)/replies"
            )
            await MainActor.run {
                self.repliedPosts = posts.filter { !$0.content.looksEncrypted }
                self.isLoadingReplies = false
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load replied posts: \(error)")
            #endif
            await MainActor.run { isLoadingReplies = false }
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
            
            Text("Follow this account to see their posts.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if followStatus == "none" {
                Button {
                    Haptics.light()
                    Task { await followUser() }
                } label: {
                    Label("Follow", systemImage: "person.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.accentBlue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            } else if followStatus == "requested" {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                    Text("Follow Request Sent")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space32)
        .padding(.horizontal, DS.space16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space16)
        .padding(.top, DS.space8)
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
    private func followUser() async {
        do {
            struct FollowResponse: Decodable {
                let status: String
                let message: String?
            }
            let response: FollowResponse = try await NetworkService.shared.post(
                path: "/api/users/follow/\(userId)",
                body: Empty()
            )
            Haptics.success()
            await MainActor.run {
                followStatus = response.status  // "following", "requested", or "mutual"
                if response.status == "following" || response.status == "mutual" {
                    requestStatus = "accepted"
                } else if response.status == "requested" {
                    requestStatus = "pending"
                }
            }
        } catch {
            #if DEBUG
            print("❌ Failed to follow user: \(error)")
            #endif
            Haptics.error()
        }
    }
    
    private func unfollowUser() async {
        do {
            struct UnfollowResponse: Decodable {
                let status: String
                let message: String?
            }
            let _: UnfollowResponse = try await NetworkService.shared.delete(
                path: "/api/users/follow/\(userId)"
            )
            Haptics.success()
            await MainActor.run {
                followStatus = "none"
                requestStatus = "none"
            }
        } catch {
            #if DEBUG
            print("❌ Failed to unfollow user: \(error)")
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
    
    // MARK: - Bell Subscription
    private func loadBellState() async {
        do {
            let sub: BellSubscription = try await NetworkService.shared.get(
                path: "/api/notifications/subscriptions/\(userId)"
            )
            await MainActor.run {
                isBellActive = sub.subscribed && (sub.notifyPosts || sub.notifyAudioRooms)
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load bell state: \(error)")
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
            
            // Stats shimmer
            HStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { i in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 30, height: 20)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
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
struct FriendsListSheet: View {
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
