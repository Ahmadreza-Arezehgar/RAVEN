import SwiftUI

// MARK: - Public Profile View
/// Unified profile view for viewing any user's profile.
/// Used from MainShellView, FeedView, AccountsCarousel.
struct PublicProfileView: View {
    let userId: String
    
    @Environment(\.dismiss) private var dismiss
    @State private var authService = AuthService.shared
    @State private var user: User?
    @State private var userPosts: [Post] = []
    @State private var isLoading = true
    @State private var isLoadingPosts = false
    @State private var scrollOffset: CGFloat = 0
    @State private var showEditProfile = false
    @State private var currentUserId: String = ""
    
    // More menu state
    @State private var showMoreMenu = false
    @State private var showReportSheet = false
    @State private var showBlockAlert = false
    @State private var isBlocked = false
    @State private var copiedLink = false
    @State private var selectedHashtag: String? = nil
    @State private var selectedPostForComments: Post?
    @State private var selectedPostForForward: Post?
    
    // Tabbed content
    @State private var selectedTab: ProfileTab = .posts
    @State private var likedPosts: [Post] = []
    @State private var repliedPosts: [Post] = []
    @State private var isLoadingLikes = false
    @State private var isLoadingReplies = false
    
    struct PublicProfilePostNavigationItem: Identifiable, Hashable {
        let id: String
    }
    @State private var selectedPostItem: PublicProfilePostNavigationItem?
    
    // Friend request state (derived from User.friendship on load)
    @State private var friendState: FriendState = .none
    @State private var showMessageUnavailableAlert = false
    
    private var isOwnProfile: Bool {
        userId == authService.currentUser?.id
    }
    
    // Collapse progress: 0 = fully expanded, 1 = fully collapsed
    private var collapseProgress: CGFloat {
        let start: CGFloat = 0
        let end: CGFloat = -120
        return min(1, max(0, (start - scrollOffset) / (start - end)))
    }
    
    private var expandProgress: CGFloat { 1 - collapseProgress }
    
    var body: some View {
        ZStack(alignment: .top) {
            // Main scrollable content
            ScrollView {
                VStack(spacing: DS.space16) {
                    // Invisible scroll tracker
                    GeometryReader { geo in
                        Color.clear
                            .preference(
                                key: ProfileScrollOffsetKey.self,
                                value: geo.frame(in: .named("profileScroll")).minY
                            )
                    }
                    .frame(height: 0)
                    
                    // Full expanded content (fades out on scroll)
                    if isLoading && user == nil {
                        ProfileHeaderShimmer()
                            .padding(.top, DS.space12)
                    } else if let user = user {
                        VStack(spacing: 0) {
                            // ───── 1/4 Hero Header ─────
                            VStack(spacing: DS.space12) {
                                // Centered Avatar
                                let avatarSize: CGFloat = 96 * (1.0 - collapseProgress * 0.4)
                                ProfileAvatarView(
                                    avatarPath: user.avatarPath,
                                    initials: user.initials,
                                    size: avatarSize
                                )
                                .shadow(color: DS.accentBlue.opacity(0.15), radius: 12, y: 4)
                                
                                // Name + Badges
                                HStack(spacing: 5) {
                                    Text(user.displayName)
                                        .font(.system(size: 22, weight: .bold))
                                        .lineLimit(1)
                                    
                                    let showVerified = user.isVerified || (isOwnProfile && AuthService.shared.currentUser?.isVerified == true)
                                    let showPremium = user.isPremium || (isOwnProfile && SubscriptionService.shared.isPremium)
                                    
                                    if showVerified {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(DS.accentBlue)
                                    }
                                    
                                    if showPremium {
                                        Image(systemName: "crown.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                                    }
                                }
                                
                                // Username
                                Text("@\(user.username ?? "username")")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.secondary)
                                
                                // Bio
                                if let bio = user.bio, !bio.isEmpty {
                                    Text(bio)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.primary.opacity(0.8))
                                        .lineLimit(3)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, DS.space32)
                                }
                                
                                // Tags
                                if let tags = user.tags, !tags.isEmpty {
                                    FlowingTagsView(tags: tags)
                                }
                                
                                // Info chips (joined date)
                                if let createdAt = user.createdAt {
                                    HStack(spacing: 4) {
                                        Image(systemName: "calendar")
                                            .font(.system(size: 10))
                                        Text("Joined \(formatJoinedDate(createdAt))")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.ultraThinMaterial, in: Capsule())
                                }
                                
                                // Stats capsule
                                statsRow(user)
                                
                                // Action Buttons
                                actionButtons(user)
                            }
                            .opacity(expandProgress)
                            .allowsHitTesting(expandProgress > 0.3)
                            .padding(.top, DS.space12)
                            .padding(.bottom, DS.space16)
                            
                            // ───── Divider ─────
                            Rectangle()
                                .fill(Color.primary.opacity(0.06))
                                .frame(height: 0.5)
                            
                            // ───── Segmented Capsule Tab Picker ─────
                            publicProfileTabPicker()
                                .padding(.top, DS.space12)
                                .padding(.bottom, DS.space8)
                            
                            // ───── 3/4 Tabbed Content ─────
                            publicTabbedContent()
                        }
                    }
                }
                .padding(.horizontal, DS.space16)
                .padding(.top, 80) // Space for sticky header overlay
                .padding(.bottom, DS.bottomTabClearance)
            }
            .coordinateSpace(name: "profileScroll")
            .onPreferenceChange(ProfileScrollOffsetKey.self) { value in
                scrollOffset = value
            }
            
            // Sticky overlay header (appears on scroll)
            StickyProfileHeader(user: user, progress: collapseProgress)
                .opacity(collapseProgress > 0.1 ? 1 : 0)
                .allowsHitTesting(collapseProgress > 0.7)
                .padding(.horizontal, DS.space16)
                .padding(.top, 10)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // ••• More menu (only for other users)
            if !isOwnProfile, user != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
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
                targetName: user?.displayName ?? "User",
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
        .alert("Message unavailable", isPresented: $showMessageUnavailableAlert) {
            if friendState == .none {
                Button("Send Friend Request") {
                    Task { await sendFriendRequest() }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("You cannot send a message to @\(user?.username ?? "user") because you are not in each other's friend list. Upgrade to RAVEN+ to send message requests.")
        }
        .background(Color(.systemBackground))
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
        .sheet(isPresented: $showEditProfile) {
            EditProfileView()
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
    }
    

    
    // MARK: - Stats Row
    private func statsRow(_ u: User) -> some View {
        HStack(spacing: 0) {
            // Posts
            VStack(spacing: 3) {
                Text("\(userPosts.count)")
                    .font(.system(size: 20, weight: .bold))
                Text("Posts")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            
            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 0.5, height: 32)
            
            // Friends (placeholder — the API returns count separately on full-profile endpoint)
            VStack(spacing: 3) {
                Text("—")
                    .font(.system(size: 20, weight: .bold))
                Text("Friends")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, DS.space12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
    }
    
    // MARK: - Action Buttons
    @ViewBuilder
    private func actionButtons(_ u: User) -> some View {
        if isOwnProfile {
            // Own profile — Edit button
            Button {
                Haptics.light()
                showEditProfile = true
            } label: {
                Text("Edit Profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: DS.shadowColor, radius: DS.shadowRadius / 2, y: DS.shadowY / 2)
            }
            .buttonStyle(.plain)
        } else {
            // Other user — state-driven CTAs
            HStack(spacing: DS.space12) {
                switch friendState {
                case .friends:
                    // Primary: Message
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
                    
                    // Secondary: Friends ✓
                    Label("Friends", systemImage: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(height: 44)
                        .padding(.horizontal, 20)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    
                case .pending:
                    // Primary: Pending (disabled)
                    Label("Pending", systemImage: "clock")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.orange.opacity(0.12), in: Capsule())
                    // Message hidden for pending state
                    
                case .none:
                    // Primary: Add Friend
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
                    
                    // Secondary: Message (RAVEN+ only)
                    Button {
                        Haptics.light()
                        if PremiumLimits.isPremium {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                DeepLinkRouter.shared.navigate(to: .chat(roomId: userId))
                            }
                        } else {
                            showMessageUnavailableAlert = true
                        }
                    } label: {
                        Label("Message", systemImage: "bubble.left.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - Segmented Capsule Tab Picker (Public Profile)
    @Namespace private var pubTabAnimation
    
    private func publicProfileTabPicker() -> some View {
        let tabs: [ProfileTab] = [.posts, .replies, .likes]
        
        return HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                    Task { await loadPublicTabData(tab) }
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
                                .matchedGeometryEffect(id: "pubTabIndicator", in: pubTabAnimation)
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
    
    // MARK: - Tabbed Content
    @ViewBuilder
    private func publicTabbedContent() -> some View {
        switch selectedTab {
        case .posts:
            publicPostsList()
        case .replies:
            publicRepliesList()
        case .likes:
            publicLikesList()
        }
    }
    
    @ViewBuilder
    private func publicPostsList() -> some View {
        if isLoadingPosts && userPosts.isEmpty {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    PostSkeletonView()
                    Divider()
                }
            }
        } else if userPosts.isEmpty {
            publicTabEmptyState(
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
                        onHashtagTap: { tag in selectedHashtag = tag }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPostItem = PublicProfilePostNavigationItem(id: post.id)
                    }
                    
                    Divider()
                }
            }
        }
    }
    
    @ViewBuilder
    private func publicRepliesList() -> some View {
        if isLoadingReplies && repliedPosts.isEmpty {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    PostSkeletonView()
                    Divider()
                }
            }
        } else if repliedPosts.isEmpty {
            publicTabEmptyState(
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
                        onHashtagTap: { tag in selectedHashtag = tag }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPostItem = PublicProfilePostNavigationItem(id: post.id)
                    }
                    
                    Divider()
                }
            }
        }
    }
    
    @ViewBuilder
    private func publicLikesList() -> some View {
        if isLoadingLikes && likedPosts.isEmpty {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    PostSkeletonView()
                    Divider()
                }
            }
        } else if likedPosts.isEmpty {
            publicTabEmptyState(
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
                        onHashtagTap: { tag in selectedHashtag = tag }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedPostItem = PublicProfilePostNavigationItem(id: post.id)
                    }
                    
                    Divider()
                }
            }
        }
    }
    
    private func publicTabEmptyState(icon: String, title: String, subtitle: String) -> some View {
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
        .padding(.top, DS.space8)
    }
    
    private func loadPublicTabData(_ tab: ProfileTab) async {
        switch tab {
        case .posts:
            if userPosts.isEmpty { await loadPublicPosts() }
        case .replies:
            if repliedPosts.isEmpty { await loadPublicRepliedPosts() }
        case .likes:
            if likedPosts.isEmpty { await loadPublicLikedPosts() }
        }
    }
    
    private func loadPublicPosts() async {
        isLoadingPosts = true
        do {
            let posts: [Post] = try await NetworkService.shared.get(path: "/api/posts/user/\(userId)")
            userPosts = posts.filter { !$0.content.looksEncrypted }
        } catch {
            #if DEBUG
            print("Failed to load posts: \(error)")
            #endif
        }
        isLoadingPosts = false
    }
    
    private func loadPublicLikedPosts() async {
        isLoadingLikes = true
        do {
            let posts: [Post] = try await NetworkService.shared.get(
                path: "/api/posts/user/\(userId)/likes"
            )
            likedPosts = posts.filter { !$0.content.looksEncrypted }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load liked posts: \(error)")
            #endif
        }
        isLoadingLikes = false
    }
    
    private func loadPublicRepliedPosts() async {
        isLoadingReplies = true
        do {
            let posts: [Post] = try await NetworkService.shared.get(
                path: "/api/posts/user/\(userId)/replies"
            )
            repliedPosts = posts.filter { !$0.content.looksEncrypted }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load replied posts: \(error)")
            #endif
        }
        isLoadingReplies = false
    }
    

    // MARK: - Network
    private func loadProfile() async {
        isLoading = true
        
        // Fetch user
        if isOwnProfile {
            user = authService.currentUser
        } else {
            do {
                user = try await NetworkService.shared.get(path: "/api/users/\(userId)")
            } catch {
                #if DEBUG
                print("Failed to load user: \(error)")
                #endif
            }
        }
        
        // Derive friend state
        if let friendship = user?.friendship {
            if friendship.alreadyFriends {
                friendState = .friends
            } else if friendship.alreadySent {
                friendState = .pending
            } else {
                friendState = .none
            }
        }
        
        isLoading = false
        
        // Fetch posts
        isLoadingPosts = true
        do {
            let posts: [Post] = try await NetworkService.shared.get(path: "/api/posts/user/\(userId)")
            userPosts = posts.filter { !$0.content.looksEncrypted }
        } catch {
            #if DEBUG
            print("Failed to load posts: \(error)")
            #endif
        }
        isLoadingPosts = false
    }
    
    private func sendFriendRequest() async {
        guard let userId = user?.id else { return }

        // 🔴 ROUND 26 — unified user-action telemetry (haptic + bg server log).
        UserActionTelemetry.shared.record(
            .friendRequestSend,
            targetId: userId,
            targetType: .user
        )

        // ⚡ Optimistic: instantly show Pending
        let previousState = friendState
        friendState = .pending
        Haptics.success()
        
        do {
            let _: FriendRequestResp = try await NetworkService.shared.post(
                path: "/api/users/friend-request?recipient_id=\(userId)",
                body: FriendRequestBody()
            )
            // Server confirmed — keep .pending state
        } catch {
            // Rollback on failure
            friendState = previousState
            Haptics.error()
            #if DEBUG
            print("❌ Failed to send friend request: \(error)")
            #endif
        }
    }
    
    private func toggleBlock() async {
        // ⚡ Delegate to BlockService which already has optimistic+rollback
        do {
            if isBlocked {
                try await BlockService.shared.unblockUser(userId: userId)
            } else {
                _ = try await BlockService.shared.blockUser(userId: userId)
            }
            await MainActor.run {
                isBlocked = BlockService.shared.isBlocked(userId)
            }
        } catch {
            // BlockService already handles rollback and haptics
            #if DEBUG
            print("❌ Failed to toggle block: \(error)")
            #endif
        }
    }
    
    // MARK: - Helpers
    private func formatJoinedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en"
        
        switch languageCode {
        case "fa":
            formatter.calendar = Calendar(identifier: .persian)
            formatter.dateFormat = "yyyy/MM/dd"
        case "es":
            formatter.dateFormat = "dd/MM/yyyy"
        default:
            formatter.dateFormat = "MMM d, yyyy"
        }
        
        return formatter.string(from: date)
    }
}

// MARK: - Friend State
private enum FriendState {
    case none, pending, friends
}

// MARK: - API Helpers
private struct FriendRequestBody: Encodable {}
private struct FriendRequestResp: Decodable {}
private struct BlockReq: Encodable { let blocked_id: String }
private struct BlockResp: Decodable {
    let success: Bool?
    let message: String?
}

// MARK: - Profile Scroll Offset Key
struct ProfileScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Profile Header Shimmer
private struct ProfileHeaderShimmer: View {
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
            
            // CTA shimmer
            HStack(spacing: DS.space12) {
                Capsule()
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 44)
                Capsule()
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 44)
            }
        }
        .redacted(reason: .placeholder)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }
}

// MARK: - Sticky Profile Header
struct StickyProfileHeader: View {
    let user: User?
    let progress: CGFloat
    
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
    
    var body: some View {
        let avatarSize = lerp(60, 36, progress)
        let barHeight = lerp(70, 52, progress)
        let nameFontSize = lerp(18, 15, progress)
        
        HStack(spacing: 12) {
            ProfileAvatarView(
                avatarPath: user?.avatarPath,
                initials: user?.initials ?? "?",
                size: avatarSize
            )
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(user?.displayName ?? "User")
                        .font(.system(size: nameFontSize, weight: .semibold))
                        .lineLimit(1)
                    
                    if user?.isVerified == true {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: nameFontSize * 0.8))
                            .foregroundStyle(DS.accentBlue)
                    }
                    
                    if user?.isPremium == true || SubscriptionService.shared.isPremium {
                        Image(systemName: "crown.fill")
                            .font(.system(size: nameFontSize * 0.7))
                            .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                    }
                }
                
                Text("@\(user?.username ?? "username")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: barHeight)
        // Liquid Glass material effect (iOS 15+)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: progress)
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        PublicProfileView(userId: "preview-user-id")
    }
}
