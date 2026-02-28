import SwiftUI

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
    
    // Optimistic local state for likes
    @State private var localIsLiked: Bool? = nil
    @State private var localLikesCount: Int? = nil
    
    // Local view count (prevents whole-feed re-render on view record)
    @State private var localViewCount: Int? = nil
    private var currentViewCount: Int { localViewCount ?? post.viewCount }

    private var currentIsLiked: Bool { localIsLiked ?? post.isLiked }
    private var currentLikesCount: Int { localLikesCount ?? post.likes }
    var onHashtagTap: ((String) -> Void)? = nil
    @State private var showReportSheet = false
    @State private var showDeleteConfirmation = false  // Delete alert
    @State private var isDeleting = false  // Deletion in progress
    @State private var showFullScreenMedia = false  // Multi-image slider
    @State private var selectedMediaIndex = 0  // Current media index
    @State private var showLinkBrowser = false  // In-app browser for link preview
    @State private var detectedURL: URL? = nil  // Detected URL from post content
    @State private var showBlockConfirm = false  // Block user confirmation
    @State private var showAvatarPreview = false  // Avatar long-press preview
    
    /// Check if current user owns this post
    private var isOwner: Bool {
        post.authorId == currentUserId
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
                
                // Post content with clickable hashtags
                InteractiveHashtagText(
                    text: post.content,
                    onHashtagTap: { tag in
                        Haptics.light()
                        onHashtagTap?(tag)
                    }
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
                    // Always use peek carousel for consistent styling
                    PeekCarouselView(media: media) { index in
                        Haptics.light()
                        selectedMediaIndex = index
                        showFullScreenMedia = true
                    }
                    .frame(height: 280)
                    .padding(.top, 8)
                    
                    // Page indicator: 1 2 3 4
                    if media.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(0..<media.count, id: \.self) { i in
                                Text("\(i + 1)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 10)
                                    .background(Color(.systemGray4).opacity(0.85))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                                    )
                            }
                        }
                        .padding(.top, 6)
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
        // Full-screen media slider with per-media comments
        .fullScreenCover(isPresented: $showFullScreenMedia) {
            // ✅ FIX Bug 7: Clamp index to valid range to prevent crash if
            // allMedia shrinks between tap and presentation (e.g. WebSocket update).
            FullScreenMediaSlider(
                media: post.allMedia,
                startIndex: min(selectedMediaIndex, max(0, post.allMedia.count - 1))
            )
        }
        // In-app browser for link preview
        .sheet(isPresented: $showLinkBrowser) {
            if let url = detectedURL {
                InAppBrowserSheet(url: url)
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
        HStack(spacing: 4) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .bold))
            Text("INITIALLY POST VIA MESH")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .kerning(0.3)
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
        HStack(spacing: 16) {
            // Comment - Pill style
            statPill(
                icon: "bubble.left.fill",
                count: post.comments,
                activeColor: .blue,
                isActive: false
            ) {
                Haptics.light()
                onOpenComments?()
            }
            
            // Like - Pill style with animation
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
            
            // Forward
            Button {
                Haptics.selection()
                onForward?()
            } label: {
                Image(systemName: "arrowshape.turn.up.forward.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
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
        let interval = Date().timeIntervalSince(self)
        
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
            .frame(height: 240)
            
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
