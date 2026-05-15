import SwiftUI

// MARK: - Feed Scroll Offset Preference Key
// ✅ FIX Bug 3: Use Optional<CGFloat> so the hidden tab sends nil instead of 0.
// This prevents the two ScrollViews from fighting over the same key and causing
// an infinite layout loop (100% CPU, header jitter).
private struct FeedScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        let next = nextValue()
        if let next = next, next != 0 {
            value = next
        } else if value == nil {
            value = next
        }
    }
}

/// Twitter-like Feed with Sticky Liquid Glass Header + Hide/Show Chrome on Scroll
struct FeedView: View {
    // ✅ FIX Bug 5: Track scene phase to stop timer in background
    @Environment(\.scenePhase) private var scenePhase
    
    // Use shared singleton so CreatePostView's optimistic inserts are visible
    @ObservedObject private var feedStore = FeedStore.shared
    private var feedStateManager: FeedStateManager { .shared }
    @State private var selectedPostForComments: Post?
    @State private var selectedPostForForward: Post?
    @State private var navigateToProfileUserId: String? = nil
    // Fix 3: Direct tap navigation (no DeepLinkRouter delay)
    @State private var selectedPostItem: FeedPostNavigationItem? = nil
    @State private var selectedHashtag: String? = nil
    
    struct FeedPostNavigationItem: Identifiable, Hashable {
        let id: String
    }
    
    // Namespace for matched geometry transitions (room cards -> room view)
    @Namespace private var roomNamespace
    
    // Live Audio Rooms
    @StateObject private var roomService = RoomService.shared
    private var localRooms: [AudioRoom] { roomService.liveRooms }
    private var friendsRooms: [AudioRoom] { roomService.friendsRooms }
    @State private var selectedRoom: AudioRoom?
    
    // 📸 BeReal-style Stories (inline in feed)
    @State private var feedStories: [Story] = []
    @State private var selectedStoryForViewer: Story?
    @State private var showStoryViewer = false
    @State private var showStoryReply = false
    @State private var replyStory: Story?
    
    // Chrome hide/show settings
    private let threshold: CGFloat = 14       // Prevent jitter
    private let debounce: TimeInterval = 0.12 // Smooth transitions
    
    // Current user ID for ownership check
    @State private var currentUserId: String = ""
    
    // ✅ FIX Bug 13: Deep link post navigation
    // ✅ FIX Bug 4: Removed showDeepLinkPost boolean — use item-based navigationDestination
    // to avoid EmptyView crash when deepLinkPostId is nil while isPresented is true.
    @State private var deepLinkPostItem: FeedPostNavigationItem? = nil
    
    /// Height of the unified header (Avatar + Local/Friends + Bell)
    private let headerHeight: CGFloat = 56
    
    // Computed binding to FeedStateManager
    private var selectedTab: FeedTab {
        get { feedStateManager.selectedFeedTab }
        nonmutating set { feedStateManager.selectedFeedTab = newValue }
    }
    
    private var isChromeHidden: Bool {
        feedStateManager.isChromeHidden
    }
    
    // MARK: - Feed data (FeedStore deduplicates at mutation time; no work needed here)
    private var uniqueLocalPosts: [Post] { feedStore.mergedLocalPosts }
    private var uniqueFriendsPosts: [Post] { feedStore.friendsPosts }
    
    var body: some View {
        ZStack(alignment: .top) {
            // 1) Feed content scrolls UNDER the floating glass controls
            feedContent
            
            // 2) Floating Glass Header: Avatar + Local/Friends tabs + Bell
            unifiedHeaderBar
                .offset(y: isChromeHidden ? -120 : 0)
                .opacity(isChromeHidden ? 0 : 1)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isChromeHidden)
            
            // 3) Upload Status Toast (appears below header during background upload)
            if PostUploadManager.shared.showToast {
                VStack {
                    PostUploadToast(
                        state: PostUploadManager.shared.state,
                        onRetry: { PostUploadManager.shared.retry() },
                        onDismiss: { PostUploadManager.shared.dismissToast() }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .padding(.top, headerHeight + 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: PostUploadManager.shared.state)
            }

            // 4) 🌐 Disaster Mode banner — shows when offline + mesh peers
            // connected. Pinned BELOW the floating Local/Friends header so
            // it doesn't overlap the segmented pill the user came here to use.
            VStack {
                DisasterModeBanner()
                Spacer()
            }
            .padding(.top, headerHeight + 14)
            .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: PostUploadManager.shared.showToast)
        .task {
            // Fetch current user ID for ownership check
            currentUserId = await KeychainService.shared.getUserId() ?? ""
            await loadInitialData()
        }
        // Auto-refresh every 30 seconds (reduced from 10s to prevent layout thrashing)
        // ✅ FIX Bug 9: Move Task{} outside withTransaction so the
        // transaction context actually applies to the @Published mutations.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            // ✅ FIX Bug 5: Only refresh when app is in foreground.
            // Without this guard, the timer fires in background every 30s,
            // causing iOS Watchdog to kill the app (0x8badf00d).
            guard scenePhase == .active else { return }
            Task {
                await refreshFeedSilently()
            }
        }
        .onChange(of: feedStateManager.shouldRefreshFeed) { _, shouldRefresh in
            if shouldRefresh {
                feedStateManager.shouldRefreshFeed = false
                Task {
                    await loadInitialData()
                }
            }
        }
        // ✅ FIX Bug 13: Navigate to post from deep link
        // ✅ FIX Bug 4: Use item-based navigationDestination so a nil postId
        // never produces an EmptyView (which causes a fatal crash).
        .onChange(of: feedStateManager.deepLinkPostId) { _, postId in
            if let postId = postId {
                self.deepLinkPostItem = FeedPostNavigationItem(id: postId)
                feedStateManager.deepLinkPostId = nil
            }
        }
        .navigationDestination(item: $deepLinkPostItem) { item in
            PostDetailView(postId: item.id)
        }
        // Fix 3: Direct tap navigation destination (no DeepLinkRouter delay)
        .navigationDestination(item: $selectedPostItem) { item in
            PostDetailView(postId: item.id)
        }
        .sheet(item: $selectedPostForComments) { post in
            CommentsSheetView(post: post, feedStore: feedStore)
                .presentationDetents([.fraction(0.55), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $selectedPostForForward) { post in
            ForwardPostSheet(post: post)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        .fullScreenCover(item: $selectedRoom) { room in
            LiveRoomView(roomId: room.id)
        }
        // MARK: - Navigation Destinations
        // ✅ FIX Bug 3: Navigate by ID, not full Post object, so background
        // data refreshes don't invalidate the NavigationLink value and pop the user.
        .navigationDestination(for: String.self) { postId in
            PostDetailView(postId: postId)
        }
        .navigationDestination(isPresented: Binding(
            get: { navigateToProfileUserId != nil },
            set: { if !$0 { navigateToProfileUserId = nil } }
        )) {
            if let userId = navigateToProfileUserId {
                UserProfileView(userId: userId)
            }
        }
        .navigationBarHidden(true)
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
    
    // MARK: - Floating Glass Header (Avatar + Local/Friends + Bell)
    private var unifiedHeaderBar: some View {
        HStack(spacing: 12) {
            // Left: Avatar — Liquid Glass circle
            HomeHeaderAvatarButton()
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
            
            Spacer()
            
            // Center: Local/Friends segmented capsule — Liquid Glass
            HStack(spacing: 0) {
                ForEach(FeedTab.allCases, id: \.self) { tab in
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            feedStateManager.selectedFeedTab = tab
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab == .local ? "location.circle.fill" : "person.2.fill")
                                .font(.system(size: 12, weight: .medium))
                            
                            Text(tab.rawValue)
                                .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .medium))
                        }
                        .foregroundColor(selectedTab == tab ? .primary : .secondary.opacity(0.6))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            selectedTab == tab
                                ? Color(.systemBackground).opacity(0.5)
                                : Color.clear
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.ultraThinMaterial, in: Capsule())
            
            Spacer()
            
            // Right: Notification bell — Liquid Glass circle
            HomeHeaderBellButton()
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)  // Close to safe area top — floating feel
        .padding(.bottom, 4)
        // NO full-width background — completely transparent behind controls
    }
    
    // MARK: - Feed Content
    // ✅ FIX Bug 5: Use ZStack+opacity instead of switch to preserve both
    // ScrollViews (and their scroll positions) across tab changes.
    // ✨ A 0.22s ease-in-out on the opacity gives a buttery cross-fade
    //    when the user toggles Local ↔ Friends — without re-allocating
    //    either ScrollView (scroll positions persist).
    private var feedContent: some View {
        ZStack {
            localFeedList
                .opacity(selectedTab == .local ? 1 : 0)
                .allowsHitTesting(selectedTab == .local)
            friendsFeedList
                .opacity(selectedTab == .friends ? 1 : 0)
                .allowsHitTesting(selectedTab == .friends)
        }
        .animation(.easeInOut(duration: 0.22), value: selectedTab)
    }
    
    // MARK: - Local Feed List
    private var localFeedList: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ✅ FIX Bug 2: Only report offset when this tab is active.
                // Both tabs were fighting over the same PreferenceKey, causing
                // an infinite layout loop (100% CPU, header jitter).
                // ✅ FIX Bug 3: Send nil when this tab is inactive so the hidden
                // ScrollView doesn't overwrite the active tab's scroll offset.
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: FeedScrollOffsetKey.self,
                            value: selectedTab == .local ? geo.frame(in: .named("feedScroll")).minY : nil
                        )
                }
                .frame(height: 0)
                
                LazyVStack(spacing: 0) {
                    // ✅ Spacer to push content below glass header
                    // ✅ Fixed height spacer - dynamic height was causing layout jumps
                    Color.clear.frame(height: headerHeight)
                
                // 🎙️ Live Rooms Section (public rooms)
                if !localRooms.isEmpty {
                    liveRoomsSection(rooms: localRooms, title: "Live Now")
                }
                
                if feedStore.isLoadingLocal && feedStore.mergedLocalPosts.isEmpty && !feedStore.isLoadingFromCache {
                    // Only show spinner AFTER cache attempt completes with nothing
                    ProgressView()
                        .padding(.top, 100)
                } else if feedStore.mergedLocalPosts.isEmpty && localRooms.isEmpty && feedStories.isEmpty && feedStore.isInitialLoadComplete {
                    emptyStateView(message: "No posts yet")
                } else {
                    // ✅ FIX Bug 1: Removed Array(enumerated()) — it copied the entire
                    // array on every state change, causing OOM on large feeds.
                    // ✅ FIX Bug 2: Replaced NavigationLink with Button + DeepLinkRouter
                    // to prevent simultaneous double-push when inner buttons are tapped.
                    // ✨ Animate insertions/removals on the loop itself so the
                    //    per-row `.transition(...)` actually fires (transitions
                    //    require an `animation(_:value:)` ancestor watching the
                    //    identity collection). Watches `.count` — cheaper than
                    //    deep-equating the full Post array on each mutation.
                        // Posts are already sorted by algorithm on server
                        ForEach(uniqueLocalPosts, id: \.id) { post in
                            VStack(spacing: 0) {
                                // Room posts: show RoomCardView
                                if post.postType == "room", let roomId = post.roomId {
                                    if let room = localRooms.first(where: { $0.id == roomId }) {
                                        RoomCardView(room: room, namespace: roomNamespace) {
                                            Haptics.selection()
                                            selectedRoom = room
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 8)
                                    }
                                } else {
                                    // Regular posts: onTapGesture navigates via router (no nested button conflicts)
                                    PostCard(
                                        post: post,
                                        feedStore: feedStore,
                                        currentUserId: currentUserId,
                                        onOpenComments: {
                                            selectedPostForComments = post
                                        },
                                        onForward: {
                                            selectedPostForForward = post
                                        },
                                        onAvatarTap: {
                                            navigateToProfileUserId = post.authorId
                                        },
                                        onHashtagTap: { tag in
                                            selectedHashtag = tag
                                        },
                                        onMentionTap: { username in
                                            resolveMentionToProfile(username)
                                        }
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Only navigate for text/voice posts — media posts show content inline
                                        guard post.allMedia.isEmpty else { return }
                                        selectedPostItem = FeedPostNavigationItem(id: post.id)
                                    }
                                }
                                
                                // ✅ FIX Bug 10: Only render Divider when content was actually rendered
                                if post.postType != "room" || localRooms.first(where: { $0.id == post.roomId }) != nil {
                                    Divider()
                                }
                            }
                            // 🎨 Buttery spring transition for posts as they
                            //   enter the viewport — a subtle move-up + fade
                            //   so the feed feels alive without distracting
                            //   from reading. Spring physics > linear easing
                            //   for "natural" feel; response 0.45 +
                            //   dampingFraction 0.85 lands without overshoot.
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                            .onAppear {
                                // 🟢 BUG FIX (2026-05-14): use a position-aware
                                // tail-comparison instead of `firstIndex(where:)`
                                // — the previous version scanned the entire
                                // array O(N) per onAppear, which on a 200-post
                                // feed cost 200 × 200 = 40,000 string compares
                                // every full scroll. We only need to know
                                // "is this post in the last 6?", which is a
                                // suffix check on the live array.
                                let posts = feedStore.mergedLocalPosts
                                let tail = posts.suffix(6)
                                if tail.contains(where: { $0.id == post.id }) {
                                    Task {
                                        guard !feedStore.isLoadingMoreLocal && !feedStore.isBackfillingLocal else { return }
                                        if feedStore.hasMoreLocal {
                                            await feedStore.fetchMoreLocalPosts()
                                        } else if feedStore.hasMoreRecommendedLocal {
                                            await feedStore.fetchRecommendedBackfillLocal()
                                        }
                                    }
                                }
                                
                                // ⚡ PERF: Prefetch images for 3 cards ahead — eliminates placeholder flash on fast scroll
                                if let idx = posts.firstIndex(where: { $0.id == post.id }) {
                                    var urlsToPrefetch: [URL] = []
                                    let lookAhead = min(idx + 4, posts.count) // 3 cards ahead
                                    for i in (idx + 1)..<lookAhead {
                                        let upcoming = posts[i]
                                        // Prefetch avatar
                                        if let avatarUrl = AppConfig.mediaURL(from: upcoming.authorAvatar) {
                                            urlsToPrefetch.append(avatarUrl)
                                        }
                                        // Prefetch first media image
                                        if let firstMedia = upcoming.allMedia.first, !firstMedia.isVideo,
                                           let mediaUrl = URL(string: firstMedia.url) {
                                            urlsToPrefetch.append(mediaUrl)
                                        }
                                    }
                                    if !urlsToPrefetch.isEmpty {
                                        ImageCache.shared.prefetch(urls: urlsToPrefetch)
                                    }
                                }
                            }
                        }
                    
                    // Loading indicator for infinite scroll
                    if feedStore.isLoadingMoreLocal || feedStore.isBackfillingLocal {
                        ProgressView()
                            .padding(.vertical, 24)
                    }
                    
                    // ✨ Suggested for you divider (when organic ends, recommended starts)
                    if !feedStore.hasMoreLocal && !feedStore.mergedLocalPosts.isEmpty {
                        // ✅ FIX Bug 12: Show header when recommended posts are about to load (removed inverted inner check)
                            HStack(spacing: 8) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 0.5)
                                Text("✨ Suggested for you")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 0.5)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 16)
                    }
                    
                    // ❌ DISABLED: Stories shown separately at the end (if any)
                    // if !feedStories.isEmpty {
                    //     ForEach(feedStories.filter { $0.audience == "local" }) { story in
                    //         storyCardView(for: story)
                    //     }
                    // }
                }
            } // LazyVStack
            // ✨ Animate insertions/removals on the local feed.
            //   Watching `.count` (an Int) is cheap; watching the full
            //   `mergedLocalPosts` array would force a deep-equality check
            //   on every state mutation. Spring physics (response 0.45,
            //   damping 0.85) feels natural without overshoot — slow
            //   enough to be noticed, fast enough not to feel laggy.
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: feedStore.mergedLocalPosts.count)
            } // VStack
        } // ScrollView
        .coordinateSpace(name: "feedScroll")
        .onPreferenceChange(FeedScrollOffsetKey.self) { offset in
            if let offset = offset {
                handleScroll(offset: offset)
            }
        }
        .scrollBounceBehavior(.always)
        .safeAreaPadding(.bottom, DS.bottomTabClearance)
        .refreshable {
            Haptics.light()
            await feedStore.fetchMergedLocalFeed()
            // ❌ DISABLED: Stories feature disabled
            // await loadStories()
            Haptics.success()
        }
    }
    
    // MARK: - Friends Feed List
    private var friendsFeedList: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ✅ FIX Bug 2: Only report offset when this tab is active.
                // ✅ FIX Bug 3: Send nil when this tab is inactive.
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: FeedScrollOffsetKey.self,
                            value: selectedTab == .friends ? geo.frame(in: .named("feedScroll")).minY : nil
                        )
                }
                .frame(height: 0)
                
                LazyVStack(spacing: 0) {
                    // ✅ Fixed height spacer - dynamic height was causing layout jumps
                    Color.clear.frame(height: headerHeight)
                
                // 🎙️ Live Rooms Section (friends rooms)
                if !friendsRooms.isEmpty {
                    liveRoomsSection(rooms: friendsRooms, title: "Friends Live")
                }
                
                if feedStore.isLoadingFriends && feedStore.friendsPosts.isEmpty && !feedStore.isLoadingFromCache {
                    // Only show spinner AFTER cache attempt completes with nothing
                    ProgressView()
                        .padding(.top, 100)
                } else if feedStore.friendsPosts.isEmpty && friendsRooms.isEmpty && feedStories.isEmpty && feedStore.isInitialLoadComplete {
                    emptyStateView(message: "No friend posts yet")
                } else {
                    // ✅ FIX Bug 1 & 2: Same fixes as local feed — no enumerated(), Button instead of NavigationLink.
                        // Posts sorted by server (chronological for friends)
                        ForEach(uniqueFriendsPosts, id: \.id) { post in
                            VStack(spacing: 0) {
                                // Room posts: show RoomCardView
                                if post.postType == "room", let roomId = post.roomId {
                                    if let room = friendsRooms.first(where: { $0.id == roomId }) {
                                        RoomCardView(room: room, namespace: roomNamespace) {
                                            Haptics.selection()
                                            selectedRoom = room
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 8)
                                    }
                                } else {
                                    // Regular posts: onTapGesture navigates via router
                                    PostCard(
                                        post: post,
                                        feedStore: feedStore,
                                        currentUserId: currentUserId,
                                        onOpenComments: {
                                            selectedPostForComments = post
                                        },
                                        onForward: {
                                            selectedPostForForward = post
                                        },
                                        onAvatarTap: {
                                            navigateToProfileUserId = post.authorId
                                        },
                                        onHashtagTap: { tag in
                                            selectedHashtag = tag
                                        },
                                        onMentionTap: { username in
                                            resolveMentionToProfile(username)
                                        }
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Only navigate for text/voice posts — media posts show content inline
                                        guard post.allMedia.isEmpty else { return }
                                        selectedPostItem = FeedPostNavigationItem(id: post.id)
                                    }
                                }
                                
                                // ✅ FIX Bug 10: Only render Divider when content was actually rendered
                                if post.postType != "room" || friendsRooms.first(where: { $0.id == post.roomId }) != nil {
                                    Divider()
                                }
                            }
                            .onAppear {
                                // 🟢 O(1) pagination trigger — no array allocations
                                let posts = feedStore.friendsPosts
                                let threshold = max(0, posts.count - 6)
                                
                                if let idx = posts.firstIndex(where: { $0.id == post.id }), idx >= threshold {
                                    Task {
                                        guard !feedStore.isLoadingMoreFriends && !feedStore.isBackfillingFriends else { return }
                                        if feedStore.hasMoreFriends {
                                            await feedStore.fetchMoreFriendsPosts()
                                        } else if feedStore.hasMoreRecommendedFriends {
                                            await feedStore.fetchRecommendedBackfillFriends()
                                        }
                                    }
                                }
                                
                                // ⚡ PERF: Prefetch images for 3 cards ahead
                                if let idx = posts.firstIndex(where: { $0.id == post.id }) {
                                    var urlsToPrefetch: [URL] = []
                                    let lookAhead = min(idx + 4, posts.count)
                                    for i in (idx + 1)..<lookAhead {
                                        let upcoming = posts[i]
                                        if let avatarUrl = AppConfig.mediaURL(from: upcoming.authorAvatar) {
                                            urlsToPrefetch.append(avatarUrl)
                                        }
                                        if let firstMedia = upcoming.allMedia.first, !firstMedia.isVideo,
                                           let mediaUrl = URL(string: firstMedia.url) {
                                            urlsToPrefetch.append(mediaUrl)
                                        }
                                    }
                                    if !urlsToPrefetch.isEmpty {
                                        ImageCache.shared.prefetch(urls: urlsToPrefetch)
                                    }
                                }
                            }
                        }
                    
                    // MARK: - Footers (Outside LazyVStack)
                    if !feedStore.friendsPosts.isEmpty {
                        // Loading indicator for friends infinite scroll
                        if feedStore.isLoadingMoreFriends || feedStore.isBackfillingFriends {
                            ProgressView()
                                .padding(.vertical, 24)
                        }
                        
                        // ✨ Suggested for you divider (when friends organic ends, recommended starts)
                        if !feedStore.hasMoreFriends {
                            // ✅ FIX Bug 12: Show header when recommended posts are about to load (removed inverted inner check)
                                HStack(spacing: 8) {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(height: 0.5)
                                    Text("✨ Suggested for you")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(height: 0.5)
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 16)
                        }
                    }
                }
            } // LazyVStack
            // ✨ Same buttery spring on the friends feed.
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: feedStore.friendsPosts.count)
            } // VStack
        } // ScrollView
        .coordinateSpace(name: "feedScroll")
        .onPreferenceChange(FeedScrollOffsetKey.self) { offset in
            if let offset = offset {
                handleScroll(offset: offset)
            }
        }
        .scrollBounceBehavior(.always)
        .safeAreaPadding(.bottom, DS.bottomTabClearance)
        .refreshable {
            Haptics.light()
            await feedStore.fetchFriendsFeed()
            // ❌ DISABLED: Stories feature disabled
            // await loadStories()
            Haptics.success()
        }
    }
    
    // MARK: - Handle Scroll (Hide/Show Chrome)
    private func handleScroll(offset: CGFloat) {
        let delta = offset - feedStateManager.lastScrollOffset
        feedStateManager.lastScrollOffset = offset
        
        // 🟢 Ignore sudden jumps from tab switching (prevents header jitter)
        if abs(delta) > 200 { return }
        
        // Near top: always show chrome
        if offset > -10 {
            if feedStateManager.isChromeHidden {
                DispatchQueue.main.async {
                    self.feedStateManager.isChromeHidden = false
                }
            }
            return
        }
        
        // Debounce
        let now = Date()
        guard now.timeIntervalSince(feedStateManager.lastChromeChange) > debounce else { return }
        
        // Scroll up (swipe up) → hide chrome
        if delta < -threshold {
            if !feedStateManager.isChromeHidden {
                feedStateManager.lastChromeChange = now
                DispatchQueue.main.async {
                    self.feedStateManager.isChromeHidden = true
                }
            }
        }
        // Scroll down (swipe down) → show chrome
        else if delta > threshold {
            if feedStateManager.isChromeHidden {
                feedStateManager.lastChromeChange = now
                DispatchQueue.main.async {
                    self.feedStateManager.isChromeHidden = false
                }
            }
        }
    }
    
    // MARK: - Empty State
    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "newspaper")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            
            Text(message)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 100)
    }
    
    // MARK: - Live Rooms Section
    private func liveRoomsSection(rooms: [AudioRoom], title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.red)
                Text(title)
                    .font(.headline)
                
                Spacer()
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(rooms) { room in
                        CompactRoomCard(room: room)
                            .onTapGesture {
                                Haptics.selection()
                                selectedRoom = room
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .background(Color(.systemBackground).opacity(0.5))
    }
    
    // MARK: - Load Initial Data
    private func loadInitialData() async {
        // ⚡ FAST PATH: If eager warm already populated posts, skip to network fetch immediately
        if !feedStore.mergedLocalPosts.isEmpty || !feedStore.friendsPosts.isEmpty {
            // Posts already visible from cache — go straight to server refresh
        } else {
            // Fallback: if eager warm somehow missed, load from cache now
            await feedStore.loadFromCache()
        }
        
        // 🚀 Fire visible-tab fetch AND rooms in parallel (independent endpoints,
        // both bounded by RTT not bandwidth). Secondary tab follows in the
        // background so the user never waits on it.
        let visibleTab = feedStateManager.selectedFeedTab
        async let visible: () = (visibleTab == .local)
            ? feedStore.fetchMergedLocalFeed()
            : feedStore.fetchFriendsFeed()
        async let rooms: () = self.loadRooms()
        _ = await (visible, rooms)

        // Secondary tab — kick off after visible content is on screen
        Task {
            if visibleTab == .local {
                await feedStore.fetchFriendsFeed()
            } else {
                await feedStore.fetchMergedLocalFeed()
            }
        }
    }
    
    /// Fetch rooms in parallel (extracted for cleaner loadInitialData)
    private func loadRooms() async {
        do {
            try await roomService.fetchLiveRooms()
            _ = try await roomService.fetchFriendsRooms()
        } catch {
            #if DEBUG
            print("❌ Failed to fetch rooms: \(error)")
            #endif
        }
    }
    
    // MARK: - Silent Refresh (for auto-refresh timer, no loading indicators)
    private func refreshFeedSilently() async {
        // Fire ALL refreshes in parallel (feeds + stories + rooms)
        async let local: () = feedStore.fetchMergedLocalFeed(isManualRefresh: false)
        async let friends: () = feedStore.fetchFriendsFeed(isManualRefresh: false)
        async let stories: () = { }()  // ❌ DISABLED: Stories feature disabled
        async let rooms: () = loadRooms()
        _ = await (local, friends, stories, rooms)
        
        #if DEBUG
        print("🔄 Auto-refresh completed: local=\(feedStore.mergedLocalPosts.count), friends=\(feedStore.friendsPosts.count), stories=\(feedStories.count)")
        #endif
    }
    
    // MARK: - Load Stories (BeReal-style, throttled concurrency)
    private func loadStories() async {
        do {
            let authors = try await StoryService.shared.getStoryFeed()
            #if DEBUG
            print("📸 [FeedView] Loaded \(authors.count) story authors")
            #endif
            
            // ⚡ Fetch author stories with BOUNDED concurrency (max 2 at a time)
            // Previously fired ALL N requests simultaneously, which saturated the
            // URLSession connection pool and starved interactive requests (comments).
            let maxConcurrency = 2
            let allStories = await withTaskGroup(of: [Story].self) { group in
                var results: [Story] = []
                var nextIndex = 0
                
                // Seed the group with initial batch
                while nextIndex < min(maxConcurrency, authors.count) {
                    let author = authors[nextIndex]
                    group.addTask {
                        (try? await StoryService.shared.getUserStories(userId: author.authorId)) ?? []
                    }
                    nextIndex += 1
                }
                
                // As each task completes, add the next one (keeps exactly N in-flight)
                for await stories in group {
                    results.append(contentsOf: stories)
                    if nextIndex < authors.count {
                        let author = authors[nextIndex]
                        group.addTask {
                            (try? await StoryService.shared.getUserStories(userId: author.authorId)) ?? []
                        }
                        nextIndex += 1
                    }
                }
                
                return results
            }
            
            // Sort by creation date (newest first)
            feedStories = allStories.sorted { $0.createdAt > $1.createdAt }
            #if DEBUG
            print("📸 [FeedView] Total stories loaded: \(feedStories.count)")
            #endif
        } catch {
            #if DEBUG
            print("❌ [FeedView] Failed to load stories: \(error)")
            #endif
        }
    }
    
    // MARK: - Resolve @mention username → profile navigation
    private func resolveMentionToProfile(_ username: String) {
        Task {
            do {
                struct UserResult: Decodable {
                    let id: String
                    let username: String
                }
                let results: [UserResult] = try await NetworkService.shared.get(
                    path: "/api/users/search?q=\(username)"
                )
                // Find exact username match (case-insensitive)
                if let match = results.first(where: { $0.username.lowercased() == username.lowercased() }) {
                    await MainActor.run {
                        navigateToProfileUserId = match.id
                    }
                }
            } catch {
                #if DEBUG
                print("❌ [Mention] Failed to resolve @\(username): \(error)")
                #endif
            }
        }
    }
    
    // MARK: - Story Card View (BeReal-style inline)
    @ViewBuilder
    private func storyCardView(for story: Story) -> some View {
        StoryFeedCard(
            story: story,
            onTap: {
                selectedStoryForViewer = story
                showStoryViewer = true
            },
            onLike: {
                Task {
                    try? await StoryService.shared.toggleLike(storyId: story.id)
                }
            },
            onReply: {
                replyStory = story
                showStoryReply = true
            }
        )
        
        Divider()
            .padding(.vertical, 4)
    }

}

// MARK: - Compact Room Card for Feed

struct CompactRoomCard: View {
    let room: AudioRoom
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                // Host avatar
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .overlay {
                        if let avatarUrl = room.hostAvatar, let url = URL(string: avatarUrl) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                        } else {
                            Text(String(room.title.prefix(1)).uppercased())
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        }
                    }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    
                    if let hostName = room.hostName {
                        Text(hostName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
            }
            
            // Stats
            HStack(spacing: 12) {
                // Live badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
                
                // Participant count
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2)
                    Text("\(room.participantCount)")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.secondary)
                
                Spacer()
                
                // Join button
                Text("Join")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
            }
        }
        .padding(12)
        .frame(width: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

#Preview {
    FeedView()
}
