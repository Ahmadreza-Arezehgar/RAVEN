import SwiftUI
import AVFoundation
import CoreMedia

/// Lightweight Identifiable wrapper so `fullScreenCover(item:)` can drive
/// the video-jump sheet. Shared by PostCard + PostDetailView. Pure value
/// type — equality on `seconds` so re-presenting at the same offset
/// doesn't accidentally toggle the sheet.
struct TimestampJumpToken: Identifiable, Equatable {
    let seconds: Double
    var id: Double { seconds }
}

/// Twitter-style Post Card
struct PostCard: View {
    let post: Post
    let feedStore: FeedStore
    let currentUserId: String  // NEW: To check ownership
    var onOpenComments: (() -> Void)? = nil
    var onForward: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil  // NEW: Callback after delete
    var onAvatarTap: (() -> Void)? = nil  // NEW: Direct avatar → profile
    
    @State private var isLikeAnimating = false
    @State private var isRepostAnimating = false

    // Optimistic local state for likes
    @State private var localIsLiked: Bool? = nil
    @State private var localLikesCount: Int? = nil
    // Optimistic local state for reposts
    @State private var localIsReposted: Bool? = nil
    @State private var localRepostCount: Int? = nil
    /// Bumped after every Bookmark toggle so the body re-evaluates
    /// `feedStore.isBookmarked(...)` (UserDefaults-backed, not @Published).
    @State private var bookmarkBumper: Int = 0
    
    // Local view count (prevents whole-feed re-render on view record)
    @State private var localViewCount: Int? = nil
    private var currentViewCount: Int { localViewCount ?? post.viewCount }

    private var currentIsLiked: Bool { localIsLiked ?? post.isLiked }
    private var currentLikesCount: Int { localLikesCount ?? post.likes }
    private var currentIsReposted: Bool { localIsReposted ?? post.isReposted }
    private var currentRepostCount: Int { localRepostCount ?? post.reposts }
    var onHashtagTap: ((String) -> Void)? = nil
    var onMentionTap: ((String) -> Void)? = nil
    @State private var showReportSheet = false
    @State private var showDeleteConfirmation = false  // Delete alert
    @State private var isDeleting = false  // Deletion in progress
    @State private var showFullScreenMedia = false  // Multi-image slider
    @State private var selectedMediaIndex = 0  // Index used for full-screen present
    /// Live index of the inline carousel — drives the page-indicator
    /// highlight AND lets taps on the "1 / 2 / 3" capsules scroll the
    /// carousel to that media item. Two-way bound to PeekCarouselView.
    @State private var carouselIndex = 0
    @State private var showLinkBrowser = false  // In-app browser for link preview
    @State private var detectedURL: URL? = nil  // Detected URL from post content
    @State private var showBlockConfirm = false  // Block user confirmation
    @State private var showAvatarPreview = false  // Avatar long-press preview
    /// 🆕 When the viewer taps a `v0:21` chip in the description, this holds
    /// the seconds offset to jump to. Drives the full-screen video sheet.
    @State private var videoTimestampJump: Double? = nil
    
    /// Check if current user owns this post
    private var isOwner: Bool {
        post.authorId == currentUserId
    }

    /// Does this post have at least one video the timestamp chips could
    /// possibly jump into? Drives whether `v0:21` tokens render as
    /// tappable Liquid Glass chips or as plain text.
    private var hasVideoMedia: Bool {
        post.allMedia.contains(where: { $0.isVideo })
    }

    /// First video item in the post — the target of every `vM:SS` chip.
    /// (Multi-video posts pick the earliest one; if you need per-chip
    /// targeting you'd encode the index in the token, e.g. `v2/0:21`.)
    private var primaryVideoIndex: Int? {
        post.allMedia.firstIndex(where: { $0.isVideo })
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // MARK: - Avatar (with long-press preview)
            // ✅ FIX Bug 6: Use Button(.plain) instead of .onTapGesture to isolate
            // the hit target from the parent NavigationLink, preventing both
            // destinations from firing simultaneously.
            Button {
                Haptics.light()
                onAvatarTap?()
            } label: {
                CachedAsyncImage(url: AppConfig.mediaURL(from: post.authorAvatar)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay {
                            Text(String(post.authorUsername.prefix(1)).uppercased())
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            }
            .buttonStyle(.borderless)
            .onLongPressGesture(minimumDuration: 0.3) {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                showAvatarPreview = true
            }
            
            // MARK: - Content
            VStack(alignment: .leading, spacing: 4) {
                // Header: Name + Username + Time
                HStack(spacing: 4) {
                    Text(post.authorUsername)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    
                    let isCurrentUser = post.authorId == currentUserId
                    let showVerified = post.verifiedStatus || (isCurrentUser && AuthService.shared.currentUser?.isVerified == true)
                    let showPremium = post.premiumStatus || (isCurrentUser && SubscriptionService.shared.isPremium)

                    if showVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.accentBlue)
                    }
                    
                    if showPremium {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                    }
                    
                    Text("@\(post.authorUsername)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Text("·")
                        .foregroundColor(.secondary)
                    
                    Text(post.timestamp.timeAgoString)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    
                    // Mesh / initial-send badges
                    if post.initialSend == "mesh" {
                        initialMeshBadge()
                    } else if let meshStatus = post.meshStatus {
                        meshBadge(for: meshStatus)
                    }
                    
                    // Voice post badge
                    if post.isVoicePost {
                        HStack(spacing: 3) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 10))
                            Text("Voice Post")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    
                    Spacer()
                    
                    // Edited indicator
                    if post.editedAt != nil {
                        Text("(edited)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                
                // Post content with clickable hashtags, @mentions, and
                // (when the post has a video) `v0:21`-style jump chips.
                InteractiveHashtagText(
                    text: post.content,
                    onHashtagTap: { tag in
                        Haptics.light()
                        onHashtagTap?(tag)
                    },
                    onMentionTap: { username in
                        Haptics.light()
                        onMentionTap?(username)
                    },
                    onVideoTimestampTap: hasVideoMedia ? { seconds in
                        Haptics.selection()
                        videoTimestampJump = seconds
                    } : nil
                )
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                
                // MARK: - Link Preview (if URL detected)
                if let url = post.content.firstURL {
                    LinkPreviewCard(url: url) {
                        detectedURL = url
                        showLinkBrowser = true
                    }
                    .padding(.top, 6)
                }
                
                // Voice Post Player (can coexist with media)
                if let voiceUrl = post.voiceUrl {
                    VoicePostPlayer(
                        voiceUrl: voiceUrl,
                        duration: post.voiceDuration ?? 0,
                        waveform: post.waveform,
                        contentId: post.id,
                        senderName: post.authorUsername,
                        senderAvatar: post.authorAvatar
                    )
                    .padding(.top, 8)
                }
                
                // Co-authors byline (for chain publish posts)
                if let coAuthors = post.coAuthorUsernames, !coAuthors.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11))
                        Text("Created by \(coAuthors.joined(separator: ", "))")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                
                // Media (slideshow up to 4 items)
                let media = post.allMedia
                if !media.isEmpty {
                    // Always use peek carousel for consistent styling.
                    // Bind `carouselIndex` so the indicator below stays in
                    // sync with manual swipes AND can be driven by tap.
                    PeekCarouselView(
                        media: media,
                        currentIndex: $carouselIndex,
                        post: post
                    ) { index in
                        Haptics.light()
                        selectedMediaIndex = index
                        showFullScreenMedia = true
                    }
                    // Feed media height — bumped from 280 → 420 (~1.5×)
                    // so photos and videos read as the primary content
                    // of the post rather than a thumbnail beside it.
                    .frame(height: 420)
                    .padding(.top, 8)

                    // Page indicator: 1 2 3 4 — fully interactive.
                    // Tap a number → carousel animates to that media.
                    // Active capsule is highlighted (filled + lifted shadow).
                    if media.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(0..<media.count, id: \.self) { i in
                                let isActive = (i == carouselIndex)
                                Button {
                                    Haptics.light()
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        carouselIndex = i
                                    }
                                } label: {
                                    Text("\(i + 1)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(isActive ? .white : .white.opacity(0.65))
                                        .padding(.vertical, 5)
                                        .padding(.horizontal, 10)
                                        .background(
                                            // Active = accent gradient capsule.
                                            // Inactive = darker translucent capsule.
                                            Group {
                                                if isActive {
                                                    LinearGradient(
                                                        colors: [.accentColor, .accentColor.opacity(0.75)],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                } else {
                                                    Color(.systemGray4).opacity(0.55)
                                                }
                                            }
                                        )
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule().strokeBorder(
                                                isActive ? Color.white.opacity(0.35) : Color.white.opacity(0.10),
                                                lineWidth: isActive ? 1 : 0.5
                                            )
                                        )
                                        .shadow(color: isActive ? .accentColor.opacity(0.40) : .clear,
                                                radius: 6, y: 2)
                                        .scaleEffect(isActive ? 1.08 : 1.0)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Show media \(i + 1) of \(media.count)")
                            }
                        }
                        .padding(.top, 6)
                        .animation(.easeOut(duration: 0.2), value: carouselIndex)
                    }
                }
                
                // MARK: - Action Bar
                actionBar
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isDeleting ? 0.5 : 1.0)
        // Viewport detection for view tracking + single-use consumption
        // ✅ FIX: Use .task{} instead of .onAppear+Task{} so the sleep is
        // auto-cancelled when the card scrolls off-screen, preventing
        // Thundering Herd (hundreds of orphaned tasks firing after 500ms).
        // ✅ FIX Bug 1: Properly handle cancellation to prevent DDoS.
        // Previously try? swallowed CancellationError, causing recordView to fire
        // for every card the user scrolled past.
        .task {
            do {
                try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                guard !Task.isCancelled else { return }
                // 🟢 Only update this card's local state, not the entire feed
                if let newCount = await feedStore.recordView(postId: post.id) {
                    localViewCount = newCount
                }
                // ⚡ PERF: Prefetch comments while the card is visible — eliminates loading delay
                // when user taps the comment button. Skips if already cached or in-flight.
                if post.comments > 0 {
                    feedStore.prefetchComments(for: post.id)
                }
            } catch {
                // Task cancelled (user scrolled away) — skip network call
            }
        }

        .sheet(isPresented: $showReportSheet) {
            ReportView(
                targetType: .post,
                targetId: post.id,
                targetName: "Post by @\(post.authorUsername)",
                reportedUserId: post.authorId
            )
        }
        .alert("Delete Post?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await deletePost()
                }
            }
        } message: {
            Text("This post will be permanently deleted. This action cannot be undone.")
        }
        // Full-screen media presentation. Routes by content type:
        //  • Selected media is a video → FullScreenVideoPlayer (the
        //    redesigned Twitter-style player with top "..." menu,
        //    bottom action bar, CC button, share sheet, etc.)
        //  • Otherwise (image / mixed) → FullScreenMediaSlider, which
        //    swipe-pages images in the standard photo viewer.
        .fullScreenCover(isPresented: $showFullScreenMedia) {
            // ✅ FIX Bug 7: Clamp index to valid range to prevent crash if
            // allMedia shrinks between tap and presentation (e.g. WebSocket update).
            let safeIndex = min(selectedMediaIndex, max(0, post.allMedia.count - 1))
            let selectedItem = post.allMedia.indices.contains(safeIndex)
                ? post.allMedia[safeIndex]
                : nil
            if let item = selectedItem, item.isVideo {
                FullScreenVideoPlayer(
                    media: post.allMedia,
                    startIndex: safeIndex,
                    startTime: .zero,
                    chapters: VideoTimestampParser.extract(from: post.content),
                    post: post
                )
            } else {
                FullScreenMediaSlider(
                    media: post.allMedia,
                    startIndex: safeIndex
                )
            }
        }
        // 🆕 Full-screen video opened via a `v0:21` chip in the description.
        // Uses the custom-chrome FullScreenVideoPlayer (not the AVKit-based
        // FullScreenMediaSlider) so we get chapter markers on the scrub bar.
        .fullScreenCover(item: Binding(
            get: { videoTimestampJump.map { TimestampJumpToken(seconds: $0) } },
            set: { videoTimestampJump = $0?.seconds }
        )) { jump in
            if let videoIndex = primaryVideoIndex {
                FullScreenVideoPlayer(
                    media: post.allMedia,
                    startIndex: videoIndex,
                    startTime: CMTime(seconds: jump.seconds, preferredTimescale: 600),
                    chapters: VideoTimestampParser.extract(from: post.content),
                    post: post
                )
            }
        }
        // In-app browser for link preview — SFSafariViewController, not
        // our custom WKWebView wrapper. Cold-start is ~5x faster because
        // Safari's content process is OS-pre-warmed, and the user gets
        // free Reader Mode / share / open-in-Safari without us
        // maintaining that UI ourselves.
        .sheet(isPresented: $showLinkBrowser) {
            if let url = detectedURL {
                SafariSheet(url: url)
                    .ignoresSafeArea()
            }
        }
        .contextMenu {
            // Owner: Delete option
            if isOwner {
                Button(role: .destructive) {
                    Haptics.warning()
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Post", systemImage: "trash")
                }
            }
            
            // Non-owner: Report option
            if !isOwner {
                Button {
                    Haptics.light()
                    showReportSheet = true
                } label: {
                    Label("Report Post", systemImage: "exclamationmark.triangle")
                }
                
                Button(role: .destructive) {
                    Haptics.warning()
                    showBlockConfirm = true
                } label: {
                    Label("Block @\(post.authorUsername)", systemImage: "person.fill.xmark")
                }
            }
        }
        .alert("Block @\(post.authorUsername)?", isPresented: $showBlockConfirm) {
            Button("Block", role: .destructive) {
                Task {
                    _ = try? await BlockService.shared.blockUser(userId: post.authorId)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their posts, stories, or messages. They can't message you.")
        }
        // Avatar long-press preview popup
        .fullScreenCover(isPresented: $showAvatarPreview) {
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            showAvatarPreview = false
                        }
                    }
                UserPreviewCard(
                    userId: post.authorId,
                    username: post.authorUsername,
                    displayName: nil,
                    avatarPath: post.authorAvatar,
                    bio: nil,
                    createdAt: nil,
                    isVerified: post.verifiedStatus || (post.authorId == currentUserId && AuthService.shared.currentUser?.isVerified == true),
                    isPremium: post.premiumStatus || (post.authorId == currentUserId && SubscriptionService.shared.isPremium),
                    onViewProfile: {
                        showAvatarPreview = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onAvatarTap?()
                        }
                    }
                )
            }
            .background(ClearBackgroundView())
        }
        .onChange(of: post.isReposted) { _, _ in
            localIsReposted = nil
            localRepostCount = nil
        }
        .onChange(of: post.reposts) { _, _ in
            localRepostCount = nil
        }
        .onChange(of: post.isLiked) { _, _ in
            localIsLiked = nil
            localLikesCount = nil
        }
    }
    
    // MARK: - Delete Post
    private func deletePost() async {
        isDeleting = true
        let success = await feedStore.deletePost(postId: post.id)
        isDeleting = false
        
        if success {
            Haptics.success()
            onDelete?()
        } else {
            Haptics.error()
        }
    }
    
    // MARK: - Mesh Status Badge
    @ViewBuilder
    private func meshBadge(for status: String) -> some View {
        switch status {
        case "queued_mesh", "broadcasting":
            HStack(spacing: 3) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .medium))
                Text("Mesh")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15))
            .clipShape(Capsule())
        case "synced":
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                Text("Synced")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.15))
            .clipShape(Capsule())
        default:
            EmptyView()
        }
    }
    
    // MARK: - Initial Mesh Badge (Liquid Glass)
    @ViewBuilder
    private func initialMeshBadge() -> some View {
        HStack(spacing: 3) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .bold))
            Text("post via mesh")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(
            LinearGradient(
                colors: [.purple, .blue, .cyan],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color(.systemGray5).opacity(0.9))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.purple.opacity(0.6), .cyan.opacity(0.4), .purple.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
        )
        .shadow(color: .purple.opacity(0.25), radius: 4, x: 0, y: 1)
    }
    
    // MARK: - Action Bar (Premium Design)
    private var actionBar: some View {
        // Reading the bumper here forces SwiftUI to re-evaluate the
        // bookmark icon after a tap (UserDefaults isn't @Published).
        let _ = bookmarkBumper
        let isBookmarked = feedStore.isBookmarked(postId: post.id)
        return HStack(spacing: 14) {
            // Comment
            statPill(
                icon: "bubble.left.fill",
                count: post.comments,
                activeColor: .blue,
                isActive: false
            ) {
                Haptics.light()
                onOpenComments?()
            }

            // Repost — real repost (not forward to chat). Long-press
            // still opens the forward-to-chat sheet so the existing
            // workflow is preserved.
            statPill(
                icon: "arrow.2.squarepath",
                count: currentRepostCount,
                activeColor: .green,
                isActive: currentIsReposted
            ) {
                tapRepost()
            }
            .scaleEffect(isRepostAnimating ? 1.15 : 1.0)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in
                        Haptics.selection()
                        onForward?()
                    }
            )

            // Like
            statPill(
                icon: currentIsLiked ? "heart.fill" : "heart",
                count: currentLikesCount,
                activeColor: .pink,
                isActive: currentIsLiked
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    isLikeAnimating = true

                    // Optimistic local UI update
                    let wasLiked = currentIsLiked
                    localIsLiked = !wasLiked
                    localLikesCount = max(0, currentLikesCount + (wasLiked ? -1 : 1))
                }
                Task {
                    await feedStore.toggleLike(postId: post.id)
                    isLikeAnimating = false
                }
            }
            .scaleEffect(isLikeAnimating ? 1.15 : 1.0)

            // Bookmark — UserDefaults-backed for now (no server endpoint
            // yet). Yellow when active.
            Button {
                Haptics.light()
                let nowSaved = feedStore.toggleBookmark(postId: post.id)
                bookmarkBumper &+= 1
                #if DEBUG
                print("🔖 [PostCard] Bookmark \(nowSaved ? "added" : "removed") for \(post.serverId.prefix(8))")
                #endif
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isBookmarked ? Color.yellow : .secondary)
                    .padding(8)
                    .background(
                        Color(isBookmarked ? .yellow : .secondaryLabel)
                            .opacity(isBookmarked ? 0.12 : 0.08)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.borderless)

            Spacer()

            // View count - subtle right-aligned
            HStack(spacing: 4) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                Text(formatCount(currentViewCount))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Repost handler
    //
    // Optimistic flip + FeedStore.toggleRepost (internet path) + mesh
    // fan-out via MeshRepostService (offline survives reconnect).
    private func tapRepost() {
        let wasReposted = currentIsReposted
        let nowReposted = !wasReposted
        withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) {
            isRepostAnimating = true
            localIsReposted = nowReposted
            localRepostCount = max(0, currentRepostCount + (wasReposted ? -1 : 1))
        }
        Haptics.selection()
        Task {
            await feedStore.toggleRepost(postId: post.id)
            await MainActor.run {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isRepostAnimating = false
                }
            }
        }
        // Fire-and-forget BLE fan-out + offline retry queue.
        // TODO(mesh-repost): MeshRepostService is not yet ported to this
        // codebase — restore the broadcastRepost call here once the
        // service lands. Until then the repost still works via the
        // server path; mesh fan-out is a no-op.
        _ = (post.serverId, post.authorId, nowReposted)
    }
    
    // MARK: - Stat Pill Button
    private func statPill(
        icon: String,
        count: Int,
        activeColor: Color,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isActive ? activeColor : .secondary)
                
                Text("\(count)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isActive ? activeColor : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isActive ? activeColor.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isActive ? activeColor.opacity(0.2) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.borderless)
    }
    
    // MARK: - Action Button
    private func actionButton(
        icon: String,
        count: Int?,
        color: Color,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .light))
                
                if let count = count, count > 0 {
                    Text(formatCount(count))
                        .font(.system(size: 13))
                }
            }
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Format Count (1.2K, 3.4M)
    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Date Extension
extension Date {
    // ✅ Static formatter — created once, reused forever (DateFormatter init is expensive)
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    
    var timeAgoString: String {
        // 🟡 BUG FIX (2026-05-10): clamp negative intervals to 0 so a
        // backward clock skew (NTP correction, time-zone change while
        // offline, manual time set) never produces "-12m" / "-3h".
        // The original `Date().timeIntervalSince(self)` could be
        // negative for posts that arrived from peers whose clocks
        // ran ahead of ours, falling into the `< 3600` branch and
        // rendering negative integers as text.
        let interval = max(0, Date().timeIntervalSince(self))

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d"
        } else {
            return Self.shortFormatter.string(from: self)
        }
    }
}

// MARK: - Multi-Image Carousel View (for Feed)

/// Carousel with peek effect (92% width, 8% peek of next image)
struct MultiImageCarouselView: View {
    let media: [PostMedia]
    let onTap: (Int) -> Void
    
    @State private var currentIndex = 0
    
    var body: some View {
        VStack(spacing: 8) {
            // Carousel with peek
            GeometryReader { geo in
                let itemWidth = geo.size.width * 0.92
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(media.enumerated()), id: \.element.id) { index, item in
                            CachedAsyncImage(url: URL(string: item.url)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.2))
                                    .overlay { ProgressView() }
                            }
                            .frame(width: itemWidth, height: geo.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner))
                            .onTapGesture {
                                Haptics.light()
                                onTap(index)
                            }
                        }
                    }
                    .padding(.horizontal, (geo.size.width - itemWidth) / 2)
                }
                .scrollTargetBehavior(.paging)
            }
            // Legacy carousel height — bumped from 240 → 360 (~1.5×)
            // to match the larger PeekCarouselView in the active feed.
            .frame(height: 360)
            
            // Page Indicator (numbered: 1 2 3 4)
            if media.count > 1 {
                HStack(spacing: 8) {
                    ForEach(0..<media.count, id: \.self) { index in
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: currentIndex == index ? .bold : .regular))
                            .foregroundStyle(currentIndex == index ? .primary : .secondary)
                            .frame(width: 20, height: 20)
                            .background(currentIndex == index ? Color.primary.opacity(0.12) : Color.clear)
                            .clipShape(Circle())
                    }
                }
            }
        }
    }
}

// Note: FullScreenMediaSlider, PeekCarouselView, and PeekPreview are in PeekCarousel.swift
