import SwiftUI

// MARK: - Account View
struct AccountView: View {

    @State private var authService = AuthService.shared
    @State private var feedStateManager = FeedStateManager.shared
    @State private var scrollY: CGFloat = 0  // Direct scroll position
    @State private var lastScrollY: CGFloat = 0  // For direction detection
    
    // Chrome hide/show settings
    private let threshold: CGFloat = 14
    private let debounce: TimeInterval = 0.12
    
    // Avatar photo picker states
    @State private var showImagePicker = false
    @State private var selectedImage: UIImage?
    @State private var showAvatarPreview = false
    @State private var isUploadingAvatar = false
    @State private var showEditProfile = false  // Edit Profile sheet
    
    // Profile stats & content
    @State private var profileStats: FullProfileResponse?
    @State private var myPosts: [Post] = []
    @State private var myLikedPosts: [Post] = []
    @State private var myRepliedPosts: [Post] = []
    @State private var selectedProfileTab: ProfileTab = .posts
    @State private var isLoadingStats = false
    @State private var isLoadingMyPosts = false
    @State private var isLoadingMyLikes = false
    @State private var isLoadingMyReplies = false
    @State private var showFollowersList = false
    @State private var showFollowingList = false
    @State private var showFriendsList = false
    @State private var showSettingsSheet = false
    @State private var hasAppearedOnce = false

    // Expanded header height
    private let expandedHeight: CGFloat = 260
    private let collapsedHeight: CGFloat = 84
    private let collapseDistance: CGFloat = 160

    // 0 = expanded, 1 = collapsed
    private var progress: CGFloat {
        // scrollY starts at ~0 and goes NEGATIVE when scrolling up
        // We want progress 0->1 as user scrolls up
        let p = min(1, max(0, -scrollY / collapseDistance))
        return p
    }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top

            ZStack(alignment: .top) {

                // Background - adaptive for light/dark mode
                Color(.systemBackground)
                    .ignoresSafeArea()

                // ✅ Scroll Content
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {

                        // Offset tracker at TOP of scroll content
                        GeometryReader { proxy in
                            let offsetY = proxy.frame(in: .named("accountScroll")).minY
                            Color.clear
                                .onChange(of: offsetY) { _, newValue in
                                    scrollY = newValue
                                    handleScrollDirection(offset: newValue)
                                }
                                .onAppear {
                                    scrollY = offsetY
                                }
                        }
                        .frame(height: 1)

                        // Spacer for header
                        Color.clear
                            .frame(height: expandedHeight + safeTop + 12)

                        // Settings is reachable via the gear button in the
                        // header (always visible, expanded or collapsed).
                        // No duplicate pill row here.

                        // Content
                        if let stats = profileStats {
                            accountStatsRow(stats)
                                .padding(.horizontal, 16)

                            accountTabPicker()
                                .padding(.horizontal, 16)
                                .padding(.top, 8)

                            accountTabbedContent()
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                        }

                        // Trailing breathing room above bottom tab bar
                        Color.clear.frame(height: 120)
                    }
                }
                .coordinateSpace(name: "accountScroll")

                // ✅ Pinned Header overlay - allows touches to pass through to content
                ProfileHeaderPinned(
                    user: authService.currentUser,
                    safeTop: safeTop,
                    expandedHeight: expandedHeight,
                    collapsedHeight: collapsedHeight,
                    progress: progress,
                    onCameraTap: {
                        Haptics.light()
                        showImagePicker = true
                    },
                    onEditTap: {
                        Haptics.light()
                        showEditProfile = true
                    },
                    onSettingsTap: {
                        Haptics.light()
                        showSettingsSheet = true
                    }
                )
                // Note: Hit testing enabled for camera button, edit button, and settings button
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showImagePicker, onDismiss: {
            if selectedImage != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showAvatarPreview = true
                }
            }
        }) {
            ImagePicker(image: $selectedImage)
        }
        .sheet(isPresented: $showAvatarPreview) {
            AvatarPreviewSheet(
                image: selectedImage,
                isUploading: $isUploadingAvatar,
                onConfirm: {
                    Task { await uploadAvatar() }
                },
                onCancel: {
                    selectedImage = nil
                    showAvatarPreview = false
                },
                onChangePhoto: {
                    showAvatarPreview = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showImagePicker = true
                    }
                }
            )
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileView()
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                AccountSettingsList()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSettingsSheet = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showFollowersList) {
            if let userId = authService.currentUser?.id {
                FollowListSheet(
                    userId: userId,
                    listType: .followers,
                    isPrivate: false,
                    isFriend: true,
                    isOwnProfile: true
                )
            }
        }
        .sheet(isPresented: $showFollowingList) {
            if let userId = authService.currentUser?.id {
                FollowListSheet(
                    userId: userId,
                    listType: .following,
                    isPrivate: false,
                    isFriend: true,
                    isOwnProfile: true
                )
            }
        }
        .sheet(isPresented: $showFriendsList) {
            if let userId = authService.currentUser?.id {
                FriendsListSheet(
                    userId: userId,
                    isPrivate: false,
                    isFriend: true
                )
            }
        }
        .onAppear {
            // Only load when the Account tab actually becomes visible
            // (TabPager creates all views at launch — this prevents request storms)
            if !hasAppearedOnce {
                hasAppearedOnce = true
                Task {
                    // Delay 2s on first launch to let Feed + Inbox get full bandwidth
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await loadAccountStats()
                }
            }
        }
    }
    
    private func uploadAvatar() async {
        guard let image = selectedImage else { return }

        isUploadingAvatar = true
        defer { isUploadingAvatar = false }

        do {
            // Step 1: hardened multipart upload (retries on transient errors —
            // the ad-hoc URLSession.shared call this used to do had no retry,
            // so a single radio hiccup on older iOS would surface as a hard
            // failure with no recovery).
            let imageUrl = try await AttachmentService.shared.uploadAvatarImage(image)

            // Step 2: tell the server this URL is the new avatar.
            struct ProfilePictureBody: Encodable { let imageUrl: String }
            let _: Empty = try await NetworkService.shared.post(
                path: "/api/users/profile-picture",
                body: ProfilePictureBody(imageUrl: imageUrl)
            )

            try await authService.fetchCurrentUser()

            await MainActor.run {
                Haptics.success()
                selectedImage = nil
                showAvatarPreview = false
            }

            #if DEBUG
            print("✅ Profile picture updated successfully")
            #endif
        } catch {
            #if DEBUG
            print("❌ Avatar upload failed: \(error)")
            #endif
            await MainActor.run { Haptics.error() }
        }
    }
    
    // MARK: - Handle Scroll Direction (Hide/Show Bottom Bar)
    private func handleScrollDirection(offset: CGFloat) {
        let delta = offset - lastScrollY
        lastScrollY = offset
        
        // Near top: always show chrome
        if offset > -10 {
            if feedStateManager.isChromeHidden {
                feedStateManager.isChromeHidden = false
            }
            return
        }
        
        // Debounce
        let now = Date()
        guard now.timeIntervalSince(feedStateManager.lastChromeChange) > debounce else { return }
        
        // Scroll up (content moves up, finger swipes up) → hide chrome
        if delta < -threshold {
            if !feedStateManager.isChromeHidden {
                feedStateManager.lastChromeChange = now
                feedStateManager.isChromeHidden = true
            }
        }
        // Scroll down (content moves down, finger swipes down) → show chrome
        else if delta > threshold {
            if feedStateManager.isChromeHidden {
                feedStateManager.lastChromeChange = now
                feedStateManager.isChromeHidden = false
            }
        }
    }
    
    // MARK: - Account Stats Row (Liquid Glass)
    private func accountStatsRow(_ p: FullProfileResponse) -> some View {
        HStack(spacing: 0) {
            accountStatItem(value: p.postsCount, label: "Posts")
            accountStatDivider
            
            Button { showFollowingList = true } label: {
                accountStatItem(value: p.followingCount ?? 0, label: "Following")
            }.buttonStyle(.plain)
            
            accountStatDivider
            
            Button { showFriendsList = true } label: {
                accountStatItem(value: p.mutualFriendsCount ?? p.friendsCount, label: "Friends")
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
    }
    
    private var accountStatDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 0.5, height: 32)
    }

    
    private func accountStatItem(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Account Tab Picker (Segmented Capsule)
    private func accountTabPicker() -> some View {
        HStack(spacing: 0) {
            ForEach(ProfileTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedProfileTab = tab
                    }
                    Task { await loadTabContent(tab) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(selectedProfileTab == tab ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        selectedProfileTab == tab
                            ? AnyShapeStyle(.ultraThinMaterial)
                            : AnyShapeStyle(Color.clear)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
    
    // MARK: - Account Tabbed Content
    @ViewBuilder
    private func accountTabbedContent() -> some View {
        switch selectedProfileTab {
        case .posts:
            if isLoadingMyPosts && myPosts.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if myPosts.isEmpty {
                accountEmptyTab(icon: "square.and.pencil", title: "No posts yet", subtitle: "Share your first post.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(myPosts) { post in
                        PostCard(
                            post: post,
                            feedStore: FeedStore.shared,
                            currentUserId: authService.currentUser?.id ?? ""
                        )
                        Divider()
                    }
                }
            }
        case .replies:
            if isLoadingMyReplies && myRepliedPosts.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if myRepliedPosts.isEmpty {
                accountEmptyTab(icon: "arrowshape.turn.up.left", title: "No replies yet", subtitle: "Posts you reply to will appear here.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(myRepliedPosts) { post in
                        PostCard(
                            post: post,
                            feedStore: FeedStore.shared,
                            currentUserId: authService.currentUser?.id ?? ""
                        )
                        Divider()
                    }
                }
            }
        case .likes:
            if isLoadingMyLikes && myLikedPosts.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if myLikedPosts.isEmpty {
                accountEmptyTab(icon: "heart", title: "No liked posts", subtitle: "Posts you like will appear here.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(myLikedPosts) { post in
                        PostCard(
                            post: post,
                            feedStore: FeedStore.shared,
                            currentUserId: authService.currentUser?.id ?? ""
                        )
                        Divider()
                    }
                }
            }
        }
    }
    
    private func accountEmptyTab(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
    }
    
    // MARK: - Data Loading
    private func loadAccountStats() async {
        guard let userId = authService.currentUser?.id else { return }
        isLoadingStats = true
        do {
            let response: FullProfileResponse = try await NetworkService.shared.get(
                path: "/api/users/\(userId)/profile"
            )
            #if DEBUG
            print("👤 [Account] Profile stats: posts=\(response.postsCount), following=\(response.followingCount ?? -1), friends=\(response.mutualFriendsCount ?? response.friendsCount)")
            #endif
            await MainActor.run {
                profileStats = response
                isLoadingStats = false
            }
            // Also load posts
            await loadTabContent(.posts)
        } catch {
            #if DEBUG
            print("❌ [Account] Failed to load profile stats: \(error)")
            #endif
            await MainActor.run { isLoadingStats = false }
        }
    }
    
    private func loadTabContent(_ tab: ProfileTab) async {
        guard let userId = authService.currentUser?.id else { return }
        switch tab {
        case .posts:
            guard myPosts.isEmpty else { return }
            await MainActor.run { isLoadingMyPosts = true }
            do {
                let posts: [Post] = try await NetworkService.shared.get(
                    path: "/api/posts/user/\(userId)"
                )
                #if DEBUG
                print("📋 [Account] Loaded \(posts.count) posts for user \(userId.prefix(8))")
                #endif
                await MainActor.run {
                    myPosts = posts.filter { !$0.content.looksEncrypted }
                    isLoadingMyPosts = false
                }
            } catch {
                #if DEBUG
                print("❌ [Account] Failed to load posts: \(error)")
                #endif
                await MainActor.run { isLoadingMyPosts = false }
            }
        case .replies:
            guard myRepliedPosts.isEmpty else { return }
            await MainActor.run { isLoadingMyReplies = true }
            do {
                let posts: [Post] = try await NetworkService.shared.get(
                    path: "/api/posts/user/\(userId)/replies"
                )
                #if DEBUG
                print("💬 [Account] Loaded \(posts.count) replies for user \(userId.prefix(8))")
                #endif
                await MainActor.run {
                    myRepliedPosts = posts.filter { !$0.content.looksEncrypted }
                    isLoadingMyReplies = false
                }
            } catch {
                #if DEBUG
                print("❌ [Account] Failed to load replies: \(error)")
                #endif
                await MainActor.run { isLoadingMyReplies = false }
            }
        case .likes:
            guard myLikedPosts.isEmpty else { return }
            await MainActor.run { isLoadingMyLikes = true }
            do {
                let posts: [Post] = try await NetworkService.shared.get(
                    path: "/api/posts/user/\(userId)/likes"
                )
                #if DEBUG
                print("❤️ [Account] Loaded \(posts.count) liked posts for user \(userId.prefix(8))")
                #endif
                await MainActor.run {
                    myLikedPosts = posts.filter { !$0.content.looksEncrypted }
                    isLoadingMyLikes = false
                }
            } catch {
                #if DEBUG
                print("❌ [Account] Failed to load likes: \(error)")
                #endif
                await MainActor.run { isLoadingMyLikes = false }
            }
        }
    }
}


// MARK: - Pinned Header (Liquid Glass + Proper Collapse)
private struct ProfileHeaderPinned: View {

    let user: User?
    let safeTop: CGFloat
    let expandedHeight: CGFloat
    let collapsedHeight: CGFloat
    let progress: CGFloat
    var onCameraTap: (() -> Void)? = nil
    var onEditTap: (() -> Void)? = nil
    var onSettingsTap: (() -> Void)? = nil

    // Sizes
    private let expandedAvatar: CGFloat = 110
    private let collapsedAvatar: CGFloat = 44

    private func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        a + (b - a) * progress
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cardW = w - 32

            let headerH = lerp(expandedHeight, collapsedHeight)

            // Avatar positions
            let avatarSize = lerp(expandedAvatar, collapsedAvatar)

            // Expanded: center
            let avatarXExpanded = cardW / 2
            let avatarYExpanded = 38 + expandedAvatar / 2

            // Collapsed: top-left inside card
            let avatarXCollapsed: CGFloat = 22 + collapsedAvatar / 2
            let avatarYCollapsed: CGFloat = collapsedHeight / 2

            let avatarX = lerp(avatarXExpanded, avatarXCollapsed)
            let avatarY = lerp(avatarYExpanded, avatarYCollapsed)

            // Text position: Y moves up, but X stays CENTER always
            let textYExpanded = 38 + expandedAvatar + 18 + 26
            let textYCollapsed = collapsedHeight / 2
            let textY = lerp(textYExpanded, textYCollapsed)
            
            // Text X: ALWAYS centered (no horizontal movement)
            let textX = cardW / 2

            // Glass card - positioned at top, sized exactly to header
            LiquidGlassCard(cornerRadius: 34) {
                ZStack {
                    // Avatar - moves to top-left on collapse
                    GlassAvatar(
                        name: user?.displayName ?? "?",
                        path: user?.avatarPath,
                        size: avatarSize,
                        showGlow: false
                    )
                    .position(x: avatarX, y: avatarY)

                    // Camera button with tap
                    CameraBadge()
                        .opacity(Double(1 - progress * 1.5))
                        .position(
                            x: avatarX + avatarSize * 0.32,
                            y: avatarY + avatarSize * 0.32
                        )
                        .onTapGesture {
                            if progress < 0.5 {
                                onCameraTap?()
                            }
                        }

                    // Name - stays CENTERED horizontally
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Text(user?.displayName ?? "User")
                                .font(.system(size: lerp(22, 17), weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            
                            if user?.isVerified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: lerp(16, 12)))
                                    .foregroundStyle(.blue)
                            }
                            
                            // Checking local SubscriptionService directly for the account tab
                            if user?.isPremium == true || SubscriptionService.shared.isPremium {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: lerp(14, 10)))
                                    .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                            }
                        }

                        Text("@\(user?.username ?? "username")")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .opacity(Double(1 - progress))

                        if let createdAt = user?.createdAt {
                            Text("Joined \(formatJoinedDate(createdAt))")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary.opacity(0.65))
                                .opacity(Double(1 - progress))
                        }
                    }
                    .frame(width: cardW - 80)
                    .multilineTextAlignment(.center)
                    .position(x: textX, y: textY)
                    
                    Button {
                        onEditTap?()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.9))
                            .frame(width: 36, height: 36)
                            .background(.primary.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(Double(progress))
                    .position(x: cardW - 30, y: collapsedHeight / 2)
                    .allowsHitTesting(progress > 0.5)

                    // Settings gear — visible when expanded AND when collapsed
                    // (sticky access while scrolling). In expanded state it sits
                    // top-right of the card; in collapsed state, just left of the edit button.
                    Button {
                        onSettingsTap?()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .glassSurface(in: Circle())
                    }
                    .buttonStyle(.plain)
                    .position(
                        x: progress > 0.5 ? cardW - 76 : cardW - 30,
                        y: progress > 0.5 ? collapsedHeight / 2 : 26
                    )
                    .allowsHitTesting(true)
                }
            }
            .frame(width: cardW, height: headerH)
            .padding(.horizontal, 16)
            .padding(.top, safeTop + 10)
        }
        // ✅ Key fix: frame to actual header height so it doesn't cover content
        .frame(height: expandedHeight + safeTop + 30)
        .ignoresSafeArea(edges: .top)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.88), value: progress)
    }

    private func formatJoinedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }
}


// MARK: - Avatar Preview Sheet
private struct AvatarPreviewSheet: View {
    let image: UIImage?
    @Binding var isUploading: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onChangePhoto: () -> Void
    
    // Image positioning state
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    private let cropSize: CGFloat = 280
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                
                // Instruction text
                Text("Pinch to zoom, drag to position")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                // Cropping area
                if let image = image {
                    ZStack {
                        // The movable/zoomable image
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: cropSize * scale, height: cropSize * scale)
                            .offset(offset)
                            .gesture(
                                SimultaneousGesture(
                                    DragGesture()
                                        .onChanged { gesture in
                                            offset = CGSize(
                                                width: lastOffset.width + gesture.translation.width,
                                                height: lastOffset.height + gesture.translation.height
                                            )
                                        }
                                        .onEnded { _ in
                                            lastOffset = offset
                                        },
                                    MagnificationGesture()
                                        .onChanged { value in
                                            let newScale = lastScale * value
                                            scale = min(max(newScale, 1.0), 4.0) // Limit zoom 1x-4x
                                        }
                                        .onEnded { _ in
                                            lastScale = scale
                                        }
                                )
                            )
                            .simultaneousGesture(
                                TapGesture(count: 2)
                                    .onEnded {
                                        withAnimation(.spring(response: 0.3)) {
                                            scale = 1.0
                                            lastScale = 1.0
                                            offset = .zero
                                            lastOffset = .zero
                                        }
                                    }
                            )
                    }
                    .frame(width: cropSize, height: cropSize)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.3), lineWidth: 3)
                    )
                    .overlay(
                        // Grid overlay for positioning help
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            .padding(cropSize / 4)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 25, x: 0, y: 12)
                }
                
                Text("Double-tap to reset")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.7))
                
                Spacer()
                
                VStack(spacing: 14) {
                    Button {
                        onConfirm()
                    } label: {
                        HStack(spacing: 8) {
                            if isUploading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(isUploading ? "Uploading..." : "Use This Photo")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(isUploading)
                    
                    Button {
                        onChangePhoto()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                            Text("Choose Different Photo")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(isUploading)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("Profile Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .foregroundStyle(.secondary)
                        .disabled(isUploading)
                }
            }
        }
    }
}


// MARK: - Liquid Glass Card (local version for header)
private struct LiquidGlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.6)
                )
                .shadow(color: .primary.opacity(0.12), radius: 22, x: 0, y: 12)

            // subtle sheen
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.06),
                            Color.clear,
                            Color.primary.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.overlay)
                .opacity(0.9)

            content
        }
    }
}


// MARK: - Camera badge
private struct CameraBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(.primary.opacity(0.18), lineWidth: 0.6))
            Image(systemName: "camera.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .frame(width: 30, height: 30)
        .shadow(color: .primary.opacity(0.15), radius: 10, x: 0, y: 6)
    }
}

// MARK: - Public Avatar for reuse in other views
struct ProfileAvatarView: View {
    let avatarPath: String?
    let initials: String
    let size: CGFloat

    var body: some View {
        GlassAvatar(name: initials, path: avatarPath, size: size, showGlow: false)
    }
}
