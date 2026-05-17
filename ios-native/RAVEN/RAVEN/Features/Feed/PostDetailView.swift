import SwiftUI
import AVFoundation
import CoreMedia

// MARK: - Post Detail View (Liquid Glass Redesign)
/// Full post detail with hero layout, threaded comments, sort controls, rich composer, and glass aesthetic.
struct PostDetailView: View {
    let postId: String
    
    private var realPostId: String {
        postId.components(separatedBy: "-loop-")[0]
    }
    
    @ObservedObject private var feedStore = FeedStore.shared
    @State private var post: Post?
    @State private var comments: [Comment] = []
    @State private var isLoading = true
    @State private var commentText = ""
    @State private var isSubmitting = false
    @State private var replyTarget: Comment? = nil
    @State private var sortOrder: CommentSort = .top
    @State private var currentUserId: String = ""
    
    // More / Report / Block / Delete
    @State private var showMoreSheet = false
    @State private var showReportPostSheet = false
    @State private var showReportUserSheet = false
    @State private var showBlockConfirm = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    
    // Media
    @State private var showFullScreenMedia = false
    @State private var selectedMediaIndex = 0
    @State private var selectedHashtag: String? = nil
    @State private var showLinkBrowser = false
    @State private var detectedURL: URL? = nil
    /// 🆕 Seconds offset from a tapped `v0:21` chip in the description.
    /// Drives the full-screen video sheet with chapter markers.
    @State private var videoTimestampJump: Double? = nil
    
    // Like
    @State private var isLikeAnimating = false
    @State private var isRepostAnimating = false
    /// Bumped after every Bookmark toggle so the body re-evaluates
    /// `feedStore.isBookmarked(...)` (UserDefaults-backed, not @Published).
    @State private var bookmarkBumper: Int = 0
    
    // Profile navigation
    @State private var navigateToProfile = false
    @State private var navigateToMentionUserId: String? = nil
    
    // Forward
    @State private var showForwardSheet = false
    
    // Voice comment recording
    @State private var voiceRecorder: AudioRecorderService?
    @State private var showVoiceSheet = false
    @State private var hasVoiceComment = false
    @State private var voiceCommentURL: URL?
    @State private var voiceCommentDuration: TimeInterval = 0
    @State private var voiceCommentError: String?
    @State private var showVoiceError = false
    
    @Environment(\.dismiss) private var dismiss
    
    private let networkService = NetworkService.shared
    
    enum CommentSort: String, CaseIterable {
        case top = "Top"
        case newest = "New"
        
        var apiValue: String {
            switch self {
            case .top: return "top"
            case .newest: return "newest"
            }
        }
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // 1) Scrollable content
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Spacer for glass header
                    Color.clear.frame(height: DS.navBarHeight)
                    
                    if isLoading && post == nil {
                        // Skeleton loading
                        VStack(spacing: 16) {
                            ForEach(0..<3, id: \.self) { i in
                                SkeletonBlock(delay: Double(i) * 0.1)
                            }
                        }
                        .padding(.top, DS.space32)
                        .padding(.horizontal, DS.space16)
                    } else if let post = post {
                        // Post loaded successfully
                        // MARK: — Hero Post Section (expanded, not reusing PostCard)
                        heroPostSection(post)
                        
                        // MARK: Gradient divider
                        gradientDivider
                        
                        // MARK: Comments Toolbar
                        commentsToolbar
                        
                        // MARK: Comments
                        if isLoading && comments.isEmpty {
                            skeletonCommentsView
                        } else if comments.isEmpty {
                            emptyCommentsCard
                        } else {
                            commentsListView
                        }
                    }
                    
                    // ✅ FIX Bug 11: Error state with retry (was blank/black screen)
                    if !isLoading && post == nil {
                        VStack(spacing: 16) {
                            Image(systemName: "network.slash")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Failed to load post")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Check your connection and try again")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Button {
                                Task { await loadData() }
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 80)
                        .frame(maxWidth: .infinity)
                    }
                    
                    // Bottom padding for composer
                    Color.clear.frame(height: 80)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            
            // 2) Glass header overlay
            GlassNavBar(
                title: post?.authorUsername ?? "Post",
                subtitle: "Post",
                onBack: { dismiss() }
            ) {
                Button {
                    Haptics.light()
                    showMoreSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            composerBar
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { FeedStateManager.shared.isDetailViewActive = true }
        .onDisappear { FeedStateManager.shared.isDetailViewActive = false }
        .task {
            currentUserId = await KeychainService.shared.getUserId() ?? ""
            await loadData()
        }
        // Profile navigation (author avatar tap)
        .navigationDestination(isPresented: $navigateToProfile) {
            if let post = post {
                UserProfileView(userId: post.authorId)
            }
        }
        // Mention profile navigation (@username tap)
        .navigationDestination(isPresented: Binding(
            get: { navigateToMentionUserId != nil },
            set: { if !$0 { navigateToMentionUserId = nil } }
        )) {
            if let userId = navigateToMentionUserId {
                UserProfileView(userId: userId)
            }
        }
        // Report Post
        .sheet(isPresented: $showReportPostSheet) {
            if let post = post {
                ReportView(
                    targetType: .post,
                    targetId: post.serverId,
                    targetName: "Post by @\(post.authorUsername)",
                    reportedUserId: post.authorId
                )
            }
        }
        // Report User
        .sheet(isPresented: $showReportUserSheet) {
            if let post = post {
                ReportView(
                    targetType: .user,
                    targetId: post.authorId,
                    targetName: "@\(post.authorUsername)",
                    reportedUserId: post.authorId
                )
            }
        }
        // Forward Post
        .sheet(isPresented: $showForwardSheet) {
            if let post = post {
                ForwardPostSheet(post: post)
            }
        }
        // Block User
        .alert("Block @\(post?.authorUsername ?? "user")?", isPresented: $showBlockConfirm) {
            Button("Block", role: .destructive) {
                guard let post = post else { return }
                Task {
                    _ = try? await BlockService.shared.blockUser(userId: post.authorId)
                    Haptics.success()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their posts, stories, or messages. They can't message you.")
        }
        // Full-screen media
        .fullScreenCover(isPresented: $showFullScreenMedia) {
            if let post = post {
                FullScreenMediaSlider(
                    media: post.allMedia,
                    startIndex: selectedMediaIndex
                )
            }
        }
        // 🆕 Open the video full-screen at a specific second when the
        // viewer taps a `v0:21` chip in the description.
        .fullScreenCover(item: Binding(
            get: { videoTimestampJump.map { TimestampJumpToken(seconds: $0) } },
            set: { videoTimestampJump = $0?.seconds }
        )) { jump in
            if let post = post,
               let videoIndex = post.allMedia.firstIndex(where: { $0.isVideo }) {
                FullScreenVideoPlayer(
                    media: post.allMedia,
                    startIndex: videoIndex,
                    startTime: CMTime(seconds: jump.seconds, preferredTimescale: 600),
                    chapters: VideoTimestampParser.extract(from: post.content),
                    post: post
                )
            }
        }
        // In-app browser for link preview — SFSafariViewController for
        // the faster cold start. See SafariSheet.swift for rationale.
        .sheet(isPresented: $showLinkBrowser) {
            if let url = detectedURL {
                SafariSheet(url: url)
                    .ignoresSafeArea()
            }
        }
        // Hashtag sheet
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
        // Delete confirmation
        .alert("Delete Post?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    isDeleting = true
                    let success = await FeedStore.shared.deletePost(postId: realPostId)
                    isDeleting = false
                    if success {
                        Haptics.success()
                        dismiss()
                    } else {
                        Haptics.error()
                    }
                }
            }
        } message: {
            Text("This post will be permanently deleted. This action cannot be undone.")
        }
        // More sheet (enhanced)
        .confirmationDialog("", isPresented: $showMoreSheet, titleVisibility: .hidden) {
            // Owner: Delete option
            if post?.authorId == currentUserId && !currentUserId.isEmpty {
                Button("Delete Post", role: .destructive) {
                    Haptics.warning()
                    showDeleteConfirmation = true
                }
            }
            Button("Report Post") { showReportPostSheet = true }
            Button("Report User") { showReportUserSheet = true }
            Button("Block @\(post?.authorUsername ?? "user")", role: .destructive) {
                showBlockConfirm = true
            }
            Button("Copy Link") {
                if let post = post {
                    UIPasteboard.general.string = "raven://post/\(post.serverId)"
                    Haptics.success()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    
    // MARK: - Hero Post Section
    /// Expanded inline post — not using PostCard; designed for detail context.
    @ViewBuilder
    private func heroPostSection(_ post: Post) -> some View {
        VStack(alignment: .leading, spacing: DS.space12) {
            // ── Author row ──
            HStack(spacing: DS.space12) {
                // Avatar → tap to profile
                Button {
                    Haptics.light()
                    navigateToProfile = true
                } label: {
                    AsyncImage(url: AppConfig.mediaURL(from: post.authorAvatar)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay {
                                Text(String(post.authorUsername.prefix(1)).uppercased())
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(post.authorUsername)
                            .font(.system(size: 16, weight: .bold))
                            .lineLimit(1)
                        
                        // Verification badge (blue tick)
                        if post.verifiedStatus || (post.authorId == AuthService.shared.currentUser?.id && AuthService.shared.currentUser?.isVerified == true) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(DS.accentBlue)
                        }
                        
                        // Premium badge (RAVEN+ crown)
                        if post.premiumStatus || (post.authorId == AuthService.shared.currentUser?.id && AuthService.shared.currentUser?.isPremium == true) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                        }
                        
                        Text("@\(post.authorUsername)")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 6) {
                        Text(post.timestamp.timeAgoString)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        
                        if post.initialSend == "mesh" {
                            initialMeshBadge()
                        } else if let meshStatus = post.meshStatus {
                            meshBadge(for: meshStatus)
                        }
                        
                        if post.editedAt != nil {
                            Text("· edited")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, DS.space16)
            .padding(.top, DS.space16)
            
            // ── Post text ──
            if !post.content.isEmpty {
                InteractiveHashtagText(
                    text: post.content,
                    onHashtagTap: { tag in
                        Haptics.light()
                        selectedHashtag = tag
                    },
                    onMentionTap: { username in
                        Haptics.light()
                        resolveMentionToProfile(username)
                    },
                    onVideoTimestampTap: post.allMedia.contains(where: { $0.isVideo }) ? { seconds in
                        Haptics.selection()
                        videoTimestampJump = seconds
                    } : nil
                )
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, DS.space16)
            }
            
            // ── Link preview ──
            if let url = post.content.firstURL {
                LinkPreviewCard(url: url) {
                    detectedURL = url
                    showLinkBrowser = true
                }
                .padding(.horizontal, DS.space16)
            }
            
            // ── Voice Post Player (in hero section, can coexist with media) ──
            if let voiceUrl = post.voiceUrl {
                VoicePostPlayer(
                    voiceUrl: voiceUrl,
                    duration: post.voiceDuration ?? 0,
                    waveform: post.waveform,
                    contentId: post.id,
                    senderName: post.authorUsername,
                    senderAvatar: post.authorAvatar
                )
                .padding(.horizontal, DS.space16)
            }
            
            // ── Hero media (full-width, taller) ──
            let media = post.allMedia
            if !media.isEmpty {
                PeekCarouselView(media: media, post: post) { index in
                    Haptics.light()
                    selectedMediaIndex = index
                    showFullScreenMedia = true
                }
                // Detail view media — bumped from 320 → 480 (~1.5×)
                // to stay larger than the feed equivalent (420), which
                // matches the visual hierarchy users expect when they
                // tap into a post.
                .frame(height: 480)
                .padding(.horizontal, DS.space8)
                
                // Glass page indicator
                if media.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<media.count, id: \.self) { i in
                            Text("\(i + 1)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 9)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                                )
                        }
                    }
                    .padding(.horizontal, DS.space16)
                }
            }
            
            // ── Action bar ──
            heroActionBar(post)
                .padding(.horizontal, DS.space16)
                .padding(.bottom, DS.space12)
        }
    }
    
    // MARK: - Hero Action Bar
    private func heroActionBar(_ post: Post) -> some View {
        // Reading the bumper here forces SwiftUI to re-evaluate the
        // bookmark icon after a tap (UserDefaults isn't @Published).
        let _ = bookmarkBumper
        let isBookmarked = feedStore.isBookmarked(postId: post.id)
        return HStack(spacing: DS.space12) {
            // Comment
            heroStatPill(
                icon: "bubble.left.fill",
                count: post.comments,
                activeColor: .blue,
                isActive: false
            ) { /* already on detail */ }

            // Repost — long-press opens forward-to-chat sheet.
            heroStatPill(
                icon: "arrow.2.squarepath",
                count: post.reposts,
                activeColor: .green,
                isActive: post.isReposted
            ) {
                tapRepost(post)
            }
            .scaleEffect(isRepostAnimating ? 1.15 : 1.0)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in
                        Haptics.selection()
                        showForwardSheet = true
                    }
            )

            // Like
            heroStatPill(
                icon: post.isLiked ? "heart.fill" : "heart",
                count: post.likes,
                activeColor: .pink,
                isActive: post.isLiked
            ) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    isLikeAnimating = true
                }
                Task {
                    await feedStore.toggleLike(postId: post.id)
                    // ✅ FIX Bug 4: Sync local state from store after toggle
                    if let updated = feedStore.mergedLocalPosts.first(where: { $0.id == post.id })
                        ?? feedStore.friendsPosts.first(where: { $0.id == post.id }) {
                        self.post = updated
                    }
                    isLikeAnimating = false
                }
            }
            .scaleEffect(isLikeAnimating ? 1.15 : 1.0)

            // Bookmark — UserDefaults-backed for now.
            Button {
                Haptics.light()
                _ = feedStore.toggleBookmark(postId: post.id)
                bookmarkBumper &+= 1
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
            .buttonStyle(.plain)

            // Forward (legacy share-arrow icon — kept for users who
            // want to send the post to a chat conversation).
            Button {
                Haptics.selection()
                showForwardSheet = true
            } label: {
                Image(systemName: "arrowshape.turn.up.forward.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // View count
            HStack(spacing: 4) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                Text(formatCount(post.viewCount))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Repost handler

    /// Real repost via FeedStore (server) + mesh fan-out via
    /// MeshRepostService. Optimistic UI update with rollback.
    private func tapRepost(_ post: Post) {
        let nowReposted = !post.isReposted
        withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) {
            isRepostAnimating = true
        }
        Haptics.selection()
        Task {
            await feedStore.toggleRepost(postId: post.id)
            // Sync local cached post so the icon flips.
            if let updated = feedStore.mergedLocalPosts.first(where: { $0.id == post.id })
                ?? feedStore.friendsPosts.first(where: { $0.id == post.id }) {
                self.post = updated
            }
            await MainActor.run {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isRepostAnimating = false
                }
            }
        }
        // TODO(mesh-repost): MeshRepostService is not yet ported to this
        // codebase — restore the broadcastRepost call here once the
        // service lands. Until then the repost still works via the
        // server path; mesh fan-out is a no-op.
        _ = (post.serverId, post.authorId, nowReposted)
    }
    
    // MARK: - Stat Pill
    private func heroStatPill(
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
        .buttonStyle(.plain)
    }
    
    // MARK: - Mesh Badge
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
                .fill(.ultraThinMaterial)
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
    
    // MARK: - Format Count
    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    
    // MARK: - Gradient Divider
    private var gradientDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, Color.primary.opacity(0.08), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, DS.space16)
    }
    
    // MARK: - Comments Toolbar
    private var commentsToolbar: some View {
        HStack {
            HStack(spacing: DS.space8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Comments")
                    .font(.system(size: 15, weight: .semibold))
                if let post = post, post.comments > 0 {
                    Text("(\(post.comments))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Sort picker
            HStack(spacing: 0) {
                ForEach(CommentSort.allCases, id: \.self) { sort in
                    Button {
                        Haptics.selection()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            sortOrder = sort
                        }
                        Task { await loadComments() }
                    } label: {
                        Text(sort.rawValue)
                            .font(.system(size: 12, weight: sortOrder == sort ? .semibold : .medium))
                            .foregroundStyle(sortOrder == sort ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                sortOrder == sort
                                    ? Color(.systemBackground).opacity(0.6)
                                    : Color.clear
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, DS.space16)
        .padding(.vertical, DS.space12)
    }
    
    // MARK: - Skeleton Comments
    private var skeletonCommentsView: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { i in
                SkeletonCommentRow(delay: Double(i) * 0.1)
            }
        }
        .padding(.horizontal, DS.space16)
        .padding(.top, DS.space4)
    }
    
    // MARK: - Empty State Card
    private var emptyCommentsCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.secondary)
            
            Text("No comments yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            
            Text("Be the first to share your thoughts")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space24)
        .padding(.horizontal, DS.space24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous))
        .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
        .padding(.horizontal, DS.space16)
        .padding(.top, DS.space4)
    }
    
    // MARK: - Comments List
    private var commentsListView: some View {
        VStack(spacing: 0) {
            ForEach(comments) { comment in
                CommentRow(
                    comment: comment,
                    onReply: { target in
                        replyTarget = target
                        Haptics.light()
                    },
                    onVote: { commentId, vote in
                        voteComment(commentId: commentId, vote: vote)
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
                
                if comment.id != comments.last?.id {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, 58)
                }
            }
        }
        .padding(.top, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: comments.count)
    }
    
    // MARK: - Composer Bar
    private var composerBar: some View {
        VStack(spacing: 0) {
            // Reply indicator
            if let target = replyTarget {
                HStack {
                    Text("Replying to @\(target.authorName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation { replyTarget = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            
            HStack(spacing: 8) {
                // Media buttons
                HStack(spacing: 2) {
                    Button {
                        Haptics.light()
                        if voiceRecorder == nil {
                            voiceRecorder = AudioRecorderService()
                        }
                        showVoiceSheet = true
                    } label: {
                        Image(systemName: hasVoiceComment ? "mic.fill" : "mic")
                            .font(.system(size: 15))
                            .foregroundStyle(hasVoiceComment ? .orange : .secondary)
                            .frame(width: 32, height: 32)
                    }
                }
                
                // Text field
                TextField(
                    replyTarget != nil ? "Reply…" : "Write a comment…",
                    text: $commentText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .padding(.vertical, 6)
                
                // Send button
                Button {
                    if hasVoiceComment {
                        Task { await submitVoiceComment() }
                    } else {
                        Task { await submitComment() }
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(
                            canSend ? Color.accentColor : Color.secondary.opacity(0.4)
                        )
                }
                .disabled(!canSend || isSubmitting)
            }
            .padding(.horizontal, DS.space12)
            .padding(.vertical, DS.space8)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
            )
            .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: -DS.shadowY)
            .padding(.horizontal, DS.space12)
            .padding(.vertical, DS.space8)
            
            // Voice preview bar (when recording attached)
            if hasVoiceComment {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.orange)
                    Text(String(format: "%d:%02d", Int(voiceCommentDuration) / 60, Int(voiceCommentDuration) % 60))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Spacer()
                    Button {
                        hasVoiceComment = false
                        voiceCommentURL = nil
                        voiceCommentDuration = 0
                        voiceRecorder?.deleteRecording()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .background(Color(.systemBackground).opacity(0.85))
        .sheet(isPresented: $showVoiceSheet) {
            if let recorder = voiceRecorder {
                VoiceRecordingSheet(
                    recorder: recorder,
                    onDone: {
                        if case .recorded(let url, let dur, _) = recorder.state {
                            voiceCommentURL = url
                            voiceCommentDuration = dur
                            hasVoiceComment = true
                        }
                        showVoiceSheet = false
                    },
                    onCancel: {
                        showVoiceSheet = false
                    }
                )
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
            }
        }
        .alert("Voice Comment Error", isPresented: $showVoiceError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(voiceCommentError ?? "Failed to send voice comment")
        }
    }
    
    private var canSend: Bool {
        hasVoiceComment || !commentText.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    // MARK: - Resolve @mention username → profile navigation
    private func resolveMentionToProfile(_ username: String) {
        Task {
            do {
                struct UserResult: Decodable {
                    let id: String
                    let username: String
                }
                let results: [UserResult] = try await networkService.get(
                    path: "/api/users/search?q=\(username)"
                )
                if let match = results.first(where: { $0.username.lowercased() == username.lowercased() }) {
                    await MainActor.run {
                        navigateToMentionUserId = match.id
                    }
                }
            } catch {
                #if DEBUG
                print("❌ [Mention] Failed to resolve @\(username): \(error)")
                #endif
            }
        }
    }
    
    // MARK: - Load Data
    private func loadData() async {
        isLoading = true
        
        // 🚀 Step 1: Instant display — check if post is already in memory from FeedStore
        // This makes "tap post → detail" feel instant (0ms) instead of waiting for server.
        let inMemory = feedStore.mergedLocalPosts.first(where: { $0.serverId == realPostId })
            ?? feedStore.friendsPosts.first(where: { $0.serverId == realPostId })
            ?? feedStore.recommendedPosts.first(where: { $0.serverId == realPostId })
        
        if let inMemory = inMemory {
            post = inMemory
            // Start loading comments immediately with cached post visible
            isLoading = false
            await loadComments()
        }
        
        // 🔄 Step 2: Background server fetch for fresh data (updated likes, comments count, etc.)
        // If Step 1 found the post, this silently refreshes it.
        // If Step 1 found nothing (e.g. deep link), this is the primary load.
        do {
            let freshPost: Post = try await networkService.get(
                path: "/api/posts/\(realPostId)"
            )
            post = freshPost
            
            // If we didn't get comments from Step 1, load them now
            if inMemory == nil {
                await loadComments()
            }
        } catch {
            #if DEBUG
            print("❌ Failed to load post from server: \(error)")
            #endif
            // If we already have the post from Step 1, that's fine — keep showing it.
            // Only set isLoading = false if we have NO post at all (true error state).
        }
        
        isLoading = false
    }
    
    // MARK: - Load Comments
    private func loadComments() async {
        // Check cache first
        if let cached = feedStore.getCachedComments(for: realPostId), !cached.isEmpty, comments.isEmpty {
            comments = cached
            isLoading = false
        }
        
        do {
            let fetched: [Comment] = try await networkService.get(
                path: "/api/comments/post/\(realPostId)",
                queryItems: [URLQueryItem(name: "sort", value: sortOrder.apiValue)]
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                comments = fetched
            }
            feedStore.setCachedComments(fetched, for: realPostId)
        } catch {
            #if DEBUG
            print("❌ Failed to load comments: \(error)")
            #endif
        }
        
        isLoading = false
    }
    
    // MARK: - Submit Comment
    private func submitComment() async {
        guard !commentText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        let textToSubmit = commentText.trimmingCharacters(in: .whitespaces)
        let parentId = replyTarget?.id
        isSubmitting = true
        
        // Optimistic insert
        let tempId = UUID().uuidString
        let currentUser = AuthService.shared.currentUser
        let optimisticComment = Comment(
            id: tempId,
            postId: realPostId,
            authorId: currentUser?.id ?? "",
            authorName: currentUser?.displayName ?? currentUser?.username ?? "me",
            authorAvatar: currentUser?.avatarPath,
            isVerified: currentUser?.isVerified ?? false,
            isPremium: currentUser?.isPremium,
            parentCommentId: parentId,
            content: textToSubmit,
            timestamp: Date(),
            score: 0,
            myVote: 0,
            isAiGenerated: false,
            replies: []
        )
        
        if parentId == nil {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                comments.insert(optimisticComment, at: 0)
            }
        }
        
        commentText = ""
        replyTarget = nil
        Haptics.light()
        
        do {
            struct CommentBody: Encodable {
                let postId: String
                let content: String
                let parentCommentId: String?
                
                enum CodingKeys: String, CodingKey {
                    case postId = "post_id"
                    case content
                    case parentCommentId = "parent_comment_id"
                }
            }
            
            let serverComment: Comment = try await networkService.post(
                path: "/api/comments/create",
                body: CommentBody(postId: realPostId, content: textToSubmit, parentCommentId: parentId)
            )
            
            if parentId == nil {
                if let index = comments.firstIndex(where: { $0.id == tempId }) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        comments[index] = serverComment
                    }
                }
            } else {
                await loadComments()
            }
            
            Haptics.success()
            
        } catch {
            #if DEBUG
            print("❌ Failed to post comment: \(error)")
            #endif
            withAnimation(.spring(response: 0.3)) {
                comments.removeAll { $0.id == tempId }
            }
            Haptics.error()
        }
        
        isSubmitting = false
    }
    
    // MARK: - Submit Voice Comment
    private func submitVoiceComment() async {
        #if DEBUG
        print("")
        print("🔵🔵🔵 [VOICE-DEBUG] ====== SUBMIT VOICE COMMENT START (PostDetailView) ======")
        print("🔵 [VOICE-DEBUG] Step 0: hasVoiceComment=\(hasVoiceComment), voiceCommentURL=\(String(describing: voiceCommentURL)), voiceCommentDuration=\(voiceCommentDuration)s")
        #endif
        
        guard hasVoiceComment, let fileURL = voiceCommentURL else {
            #if DEBUG
            print("🔴 [VOICE-DEBUG] Step 0 FAILED: Guard check failed!")
            print("🔴 [VOICE-DEBUG]   hasVoiceComment=\(hasVoiceComment)")
            print("🔴 [VOICE-DEBUG]   voiceCommentURL=\(String(describing: voiceCommentURL))")
            #endif
            return
        }
        
        // Check file exists on disk
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? -1
        #if DEBUG
        print("🔵 [VOICE-DEBUG] Step 1: File check — exists=\(fileExists), size=\(fileSize) bytes, path=\(fileURL.path)")
        #endif
        
        guard fileExists else {
            #if DEBUG
            print("🔴 [VOICE-DEBUG] Step 1 FAILED: File does not exist on disk!")
            #endif
            voiceCommentError = "Recording file not found"
            showVoiceError = true
            return
        }
        
        isSubmitting = true
        Haptics.light()
        
        do {
            // Step 2: Upload voice file
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 2: Uploading voice file...")
            #endif
            let uploadResult = try await VoiceUploadService.upload(fileURL: fileURL)
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 2 DONE: Upload succeeded — voiceUrl=\(uploadResult.voiceUrl)")
            #endif
            
            // Step 3: Build request body
            struct VoiceCommentBody: Encodable {
                let postId: String
                let content: String
                let commentType: String
                let mediaUrl: String
                let durationSec: Double
                let parentCommentId: String?
                
                enum CodingKeys: String, CodingKey {
                    case postId = "post_id"
                    case content
                    case commentType = "comment_type"
                    case mediaUrl = "media_url"
                    case durationSec = "duration_sec"
                    case parentCommentId = "parent_comment_id"
                }
            }
            
            let textCaption = commentText.trimmingCharacters(in: .whitespaces)
            let parentId = replyTarget?.id
            
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 3: API request body — postId=\(postId), content='\(textCaption)', commentType=voice, mediaUrl=\(uploadResult.voiceUrl), durationSec=\(voiceCommentDuration), parentCommentId=\(parentId ?? "nil")")
            #endif
            
            // Step 4: Call server API
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 4: Calling /api/comments/create...")
            #endif
            let serverComment: Comment = try await networkService.post(
                path: "/api/comments/create",
                body: VoiceCommentBody(
                    postId: realPostId,
                    content: textCaption,
                    commentType: "voice",
                    mediaUrl: uploadResult.voiceUrl,
                    durationSec: voiceCommentDuration,
                    parentCommentId: parentId
                )
            )
            
            // Step 5: Log response
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 5: Server response decoded successfully!")
            print("🔵 [VOICE-DEBUG]   id=\(serverComment.id)")
            print("🔵 [VOICE-DEBUG]   commentType=\(serverComment.commentType ?? "nil")")
            print("🔵 [VOICE-DEBUG]   mediaUrl=\(serverComment.mediaUrl ?? "nil")")
            print("🔵 [VOICE-DEBUG]   durationSec=\(serverComment.durationSec ?? -1)")
            print("🔵 [VOICE-DEBUG]   content='\(serverComment.content)'")
            print("🔵 [VOICE-DEBUG]   authorName=\(serverComment.authorName)")
            #endif
            
            // Step 6: Insert into comments list
            let countBefore = comments.count
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                comments.insert(serverComment, at: 0)
            }
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 6: Inserted into comments — before=\(countBefore), after=\(comments.count)")
            #endif
            
            // Step 7: Cleanup
            commentText = ""
            replyTarget = nil
            hasVoiceComment = false
            voiceCommentURL = nil
            voiceCommentDuration = 0
            voiceRecorder?.deleteRecording()
            #if DEBUG
            print("🔵 [VOICE-DEBUG] Step 7: Cleanup done")
            #endif
            
            Haptics.success()
            #if DEBUG
            print("🔵🔵🔵 [VOICE-DEBUG] ====== SUBMIT VOICE COMMENT SUCCESS ======")
            print("")
            #endif
            
        } catch let decodingError as DecodingError {
            #if DEBUG
            print("🔴🔴🔴 [VOICE-DEBUG] DECODING ERROR:")
            #endif
            switch decodingError {
            case .keyNotFound(let key, let context):
                #if DEBUG
                print("🔴 [VOICE-DEBUG]   Key not found: '\(key.stringValue)' at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .typeMismatch(let type, let context):
                #if DEBUG
                print("🔴 [VOICE-DEBUG]   Type mismatch: expected \(type) at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .valueNotFound(let type, let context):
                #if DEBUG
                print("🔴 [VOICE-DEBUG]   Value not found: \(type) at path: \(context.codingPath.map { $0.stringValue })")
                #endif
            case .dataCorrupted(let context):
                #if DEBUG
                print("🔴 [VOICE-DEBUG]   Data corrupted: \(context.debugDescription)")
                #endif
            @unknown default:
                #if DEBUG
                print("🔴 [VOICE-DEBUG]   Unknown: \(decodingError)")
                #endif
            }
            voiceCommentError = "Failed to decode server response"
            showVoiceError = true
            Haptics.error()
        } catch {
            #if DEBUG
            print("🔴🔴🔴 [VOICE-DEBUG] ERROR: \(error)")
            print("🔴 [VOICE-DEBUG] Error type: \(type(of: error))")
            print("🔴 [VOICE-DEBUG] Error description: \(error.localizedDescription)")
            #endif
            voiceCommentError = error.localizedDescription
            showVoiceError = true
            Haptics.error()
        }
        
        isSubmitting = false
    }
    
    // MARK: - Vote Comment
    private func voteComment(commentId: String, vote: Int) {
        updateVoteInTree(commentId: commentId, vote: vote)
        Haptics.light()
        
        Task {
            do {
                struct VoteBody: Encodable { let vote: Int }
                struct VoteResponse: Decodable {
                    let status: String
                    let action: String
                    let myVote: Int
                    let score: Int
                }
                
                let response: VoteResponse = try await networkService.post(
                    path: "/api/comments/\(commentId)/vote",
                    body: VoteBody(vote: vote)
                )
                
                updateCommentInTree(commentId: commentId) { c in
                    Comment(
                        id: c.id, postId: c.postId, authorId: c.authorId,
                        authorName: c.authorName, authorAvatar: c.authorAvatar,
                        isVerified: c.isVerified, isPremium: c.isPremium,
                        parentCommentId: c.parentCommentId,
                        content: c.content, timestamp: c.timestamp,
                        score: response.score, myVote: response.myVote,
                        isAiGenerated: c.isAiGenerated, replies: c.replies,
                        commentType: c.commentType, mediaUrl: c.mediaUrl,
                        durationSec: c.durationSec
                    )
                }
                feedStore.setCachedComments(comments, for: realPostId)
            } catch {
                #if DEBUG
                print("❌ Vote failed: \(error)")
                #endif
                updateVoteInTree(commentId: commentId, vote: 0)
            }
        }
    }
    
    private func updateVoteInTree(commentId: String, vote: Int) {
        updateCommentInTree(commentId: commentId) { c in
            let currentVote = c.myVote
            let newVote = (currentVote == vote) ? 0 : vote
            let scoreDelta = newVote - currentVote
            return Comment(
                id: c.id, postId: c.postId, authorId: c.authorId,
                authorName: c.authorName, authorAvatar: c.authorAvatar,
                isVerified: c.isVerified, isPremium: c.isPremium,
                parentCommentId: c.parentCommentId,
                content: c.content, timestamp: c.timestamp,
                score: c.score + scoreDelta, myVote: newVote,
                isAiGenerated: c.isAiGenerated, replies: c.replies,
                commentType: c.commentType, mediaUrl: c.mediaUrl,
                durationSec: c.durationSec
            )
        }
    }
    
    private func updateCommentInTree(commentId: String, transform: (Comment) -> Comment) {
        func update(in list: inout [Comment]) -> Bool {
            for i in list.indices {
                if list[i].id == commentId {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        list[i] = transform(list[i])
                    }
                    return true
                }
                if update(in: &list[i].replies) { return true }
            }
            return false
        }
        _ = update(in: &comments)
    }
}

// MARK: - Skeleton Block
private struct SkeletonBlock: View {
    let delay: Double
    @State private var shimmerOffset: CGFloat = -200
    
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.gray.opacity(0.12))
            .frame(height: 60)
            .shimmer(offset: shimmerOffset, delay: delay)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerOffset = 400
                }
            }
    }
}

// MARK: - Skeleton Comment Row (reused from CommentsSheetView)
private struct SkeletonCommentRow: View {
    let delay: Double
    @State private var shimmerOffset: CGFloat = -200
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 38, height: 38)
                .shimmer(offset: shimmerOffset, delay: delay)
            
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 100, height: 14)
                    .shimmer(offset: shimmerOffset, delay: delay)
                
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 12)
                    .shimmer(offset: shimmerOffset, delay: delay)
                
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 180, height: 12)
                    .shimmer(offset: shimmerOffset, delay: delay)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 400
            }
        }
    }
}

// MARK: - Comments Response
struct CommentsResponse: Codable {
    let comments: [Comment]
}

#Preview {
    NavigationStack {
        PostDetailView(postId: "test-id")
    }
}
