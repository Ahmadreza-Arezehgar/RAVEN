import SwiftUI
import AVFoundation
import AVKit
import os.log

// MARK: - Video Player Pool (limits concurrent players to save memory)
/// Shared singleton that manages active AVPlayers across the feed.
/// Only 2 videos play simultaneously — older ones are paused to save memory/battery.
@MainActor @Observable
final class VideoPlayerPool {
    static let shared = VideoPlayerPool()
    
    private var activePlayers: [(id: String, player: AVPlayer)] = []
    private let maxConcurrent = 2
    
    /// Global mute state — persists across all videos in the feed.
    /// Matches Instagram behavior: unmuting one video unmutes all.
    var isMuted = true
    
    private let logger = Logger(subsystem: "com.raven.app", category: "VideoPlayerPool")
    
    private init() {}
    
    /// Register a player as active. Pauses oldest if over limit.
    func activate(id: String, player: AVPlayer) {
        // Remove existing entry for this id
        activePlayers.removeAll { $0.id == id }
        
        // Pause oldest if at capacity
        while activePlayers.count >= maxConcurrent {
            let oldest = activePlayers.removeFirst()
            oldest.player.pause()
        }
        
        // Configure audio session for video playback — required for audio
        // to play when the hardware mute switch is on (silent mode).
        // .playback overrides the mute switch, matching Instagram/TikTok behavior.
        configureAudioSessionForPlayback()
        
        activePlayers.append((id: id, player: player))
        player.isMuted = isMuted
        player.play()
    }
    
    /// Deactivate a player (scrolled off screen)
    func deactivate(id: String) {
        if let idx = activePlayers.firstIndex(where: { $0.id == id }) {
            activePlayers[idx].player.pause()
            activePlayers.remove(at: idx)
        }
    }
    
    /// Update mute state for all active players
    func setMuted(_ muted: Bool) {
        isMuted = muted
        
        // When unmuting, ensure audio session is configured for playback
        // so sound is heard even if the device mute switch is on.
        if !muted {
            configureAudioSessionForPlayback()
        }
        
        for entry in activePlayers {
            entry.player.isMuted = muted
        }
    }
    
    /// Pause all (app backgrounded, etc.)
    func pauseAll() {
        for entry in activePlayers {
            entry.player.pause()
        }
    }
    
    // MARK: - Audio Session Configuration
    
    /// Configures AVAudioSession for video playback.
    /// Category `.playback` ensures audio plays even when the hardware mute switch is ON.
    /// Without this, AVPlayer respects the mute switch and produces no sound.
    /// `.mixWithOthers` allows background music apps to keep playing if the video is muted.
    private func configureAudioSessionForPlayback() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback: overrides mute switch
            // .duckOthers: lower volume of other apps when our video has sound
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            logger.warning("⚠️ Failed to configure AVAudioSession for video: \(error.localizedDescription)")
        }
    }
}


// MARK: - AVPlayer UIView Wrapper (no system controls)
/// Bare AVPlayerLayer — gives us full control over the UI (mute button, tap gesture).
/// SwiftUI's `VideoPlayer` forces system controls which we don't want in the feed.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    
    init(player: AVPlayer, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = gravity
        backgroundColor = .black
    }
    
    required init?(coder: NSCoder) { fatalError() }
}


// MARK: - Feed Video Player (UIViewRepresentable)
/// Inline auto-play muted video player for the feed.
/// Behavior matches Instagram/Twitter:
/// - Auto-plays muted when visible
/// - Mute toggle (top-right speaker icon)
/// - Tap → opens fullscreen from current position
/// - Loops continuously
/// - Pauses when scrolled off screen
struct FeedVideoPlayer: UIViewRepresentable {
    let videoURL: URL
    let thumbnailURL: URL?
    let mediaId: String
    @Binding var currentTime: CMTime
    @Binding var isFullscreen: Bool
    /// Fired the first time the AVPlayer's `timeControlStatus`
    /// transitions to `.playing`. The owning `FeedVideoCard` uses
    /// this to fade out the thumbnail overlay, so the user sees the
    /// real video the instant playback starts. Driven by KVO instead
    /// of the periodic time observer because the time observer's
    /// `parent` binding chain proved fragile across SwiftUI re-renders.
    var onFirstPlaying: (() -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerView {
        // Same fast-start asset config as the fullscreen player —
        // see `setupPlayer()` for the why.
        let asset = AVURLAsset(
            url: videoURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        let player = AVPlayer(playerItem: item)
        player.isMuted = VideoPlayerPool.shared.isMuted
        player.automaticallyWaitsToMinimizeStalling = false

        let view = PlayerLayerView(player: player)
        context.coordinator.player = player
        context.coordinator.setupLooping(player: player)
        context.coordinator.setupTimeObserver(player: player)
        context.coordinator.observePlayingStatus(player: player)

        // Register with pool — auto-plays muted
        VideoPlayerPool.shared.activate(id: mediaId, player: player)

        // Watchdog: if `play()` from `activate` didn't kick the
        // player into `.playing` within 1.5s (e.g. the audio session
        // configuration raced and play() was a no-op), retry it.
        // Cheap + idempotent — calling `play()` on an already-playing
        // player is harmless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak player] in
            guard let p = player, p.timeControlStatus != .playing else { return }
            #if DEBUG
            print("🎬 [FeedVideoPlayer] watchdog retry play() for \(self.mediaId.prefix(6)) status=\(p.timeControlStatus.rawValue)")
            #endif
            p.play()
        }

        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        // Sync mute state
        uiView.playerLayer.player?.isMuted = VideoPlayerPool.shared.isMuted
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject {
        let parent: FeedVideoPlayer
        var player: AVPlayer?
        private var loopObserver: Any?
        private var timeObserver: Any?
        private var playingStatusObserver: NSKeyValueObservation?
        private var firstPlayingFired = false

        init(parent: FeedVideoPlayer) {
            self.parent = parent
        }

        func setupLooping(player: AVPlayer) {
            // Loop: seek to beginning when video ends
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }

        func setupTimeObserver(player: AVPlayer) {
            // Update current time for fullscreen handoff
            let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                self?.parent.currentTime = time
            }
        }

        /// KVO-based first-frame detection. AVPlayer's
        /// `timeControlStatus` flips from `.paused` /
        /// `.waitingToPlayAtSpecifiedRate` to `.playing` the moment
        /// frames start being produced — this is the most reliable
        /// signal that "the video is actually showing". Far more
        /// dependable than waiting for the periodic time observer
        /// to fire with a positive seconds value.
        func observePlayingStatus(player: AVPlayer) {
            playingStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, change in
                guard let self else { return }
                guard !self.firstPlayingFired else { return }
                if change.newValue == .playing {
                    self.firstPlayingFired = true
                    DispatchQueue.main.async {
                        self.parent.onFirstPlaying?()
                    }
                }
            }
        }

        deinit {
            if let obs = loopObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            if let obs = timeObserver, let player = player {
                player.removeTimeObserver(obs)
            }
            playingStatusObserver?.invalidate()
            playingStatusObserver = nil
            player?.pause()
            // Dispatch to MainActor since deinit may run off-main
            let mediaId = parent.mediaId
            Task { @MainActor in
                VideoPlayerPool.shared.deactivate(id: mediaId)
            }
        }
    }
}


// MARK: - Feed Video Card
/// Complete video card for the feed with mute toggle and fullscreen tap.
/// Drop-in replacement for static thumbnail in PeekCarouselView.
struct FeedVideoCard: View {
    let media: PostMedia
    let allMedia: [PostMedia]
    let startIndex: Int
    /// Optional owning post — when present the fullscreen player gets
    /// the bottom action bar (comment / like / forward / bookmark /
    /// share) and the full options menu (Go to Post, Add to Offline,
    /// Not Interested, Report). Without it those rows are hidden.
    let post: Post?

    @State private var currentTime: CMTime = .zero
    @State private var showFullscreen = false
    /// Hides the thumbnail once the player is observably playing
    /// (currentTime advances past 0). The black gap between
    /// `makeUIView` and the first decoded frame felt like "video
    /// didn't auto-play" to users. The thumbnail covers that gap.
    @State private var hasFirstFrame = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Video player — handles its own lifecycle via coordinator.
            // `onFirstPlaying` is driven by KVO on AVPlayer.timeControlStatus
            // (set in the Coordinator) — far more reliable than the
            // periodic-time-observer chain the previous implementation
            // used to flip the thumbnail off.
            if let videoURL = URL(string: media.url) {
                FeedVideoPlayer(
                    videoURL: videoURL,
                    thumbnailURL: media.thumbnailUrl.flatMap { URL(string: $0) },
                    mediaId: media.id,
                    currentTime: $currentTime,
                    isFullscreen: $showFullscreen,
                    onFirstPlaying: {
                        guard !hasFirstFrame else { return }
                        withAnimation(.easeOut(duration: 0.18)) { hasFirstFrame = true }
                    }
                )
            }

            // Thumbnail fallback — sits on top of the player layer
            // ONLY until the first frame is being rendered, then
            // fades out. We also gate on having a real thumbnail
            // URL so we don't create an opaque overlay where the
            // player would otherwise show "loading shimmer".
            if !hasFirstFrame, let thumb = media.thumbnailUrl.flatMap({ URL(string: $0) }) {
                AsyncImage(url: thumb) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    } else {
                        Color.black
                    }
                }
                .clipped()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            
            // Mute toggle button (top-right, glass capsule)
            Button {
                Haptics.light()
                VideoPlayerPool.shared.setMuted(!VideoPlayerPool.shared.isMuted)
            } label: {
                Image(systemName: VideoPlayerPool.shared.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }
            .padding(10)
            
            // "VIDEO" label (bottom-left)
            VStack {
                Spacer()
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("VIDEO")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 4)
                    .padding(10)
                    
                    Spacer()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            showFullscreen = true
        }
        .onChange(of: currentTime) { _, new in
            // First time the periodic time observer fires with a
            // positive playback position, the player is actually
            // rendering — fade the thumbnail out.
            if !hasFirstFrame, new.seconds > 0 {
                withAnimation(.easeOut(duration: 0.18)) { hasFirstFrame = true }
            }
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            FullScreenVideoPlayer(
                media: allMedia,
                startIndex: startIndex,
                startTime: currentTime,
                chapters: post.map { VideoTimestampParser.extract(from: $0.content) } ?? [],
                post: post
            )
        }
    }
}


// MARK: - Full Screen Video Player
/// Twitter/X-style fullscreen viewer with capsule-glass scrub bar
/// (lifted above the home indicator), bottom action bar (comment /
/// repost / like / bookmark / share), and a top "..." menu (speed /
/// quality / Add to Offline / Not interested / Report).
struct FullScreenVideoPlayer: View {
    let media: [PostMedia]
    let startIndex: Int
    let startTime: CMTime
    /// Author-supplied `vM:SS` chapter markers extracted from the
    /// post body. Rendered above the scrub bar in `FullscreenVideoItem`.
    let chapters: [VideoTimestamp]
    /// The owning post — drives the bottom action bar (comment /
    /// like / repost / bookmark / share). When `nil` the bar is
    /// hidden (e.g. timestamp-jump path before stats are loaded).
    let post: Post?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var feedStore = FeedStore.shared
    @State private var currentIndex: Int

    // Swipe-down dismiss
    @State private var dragOffsetY: CGFloat = 0
    @State private var isDragging = false
    private let dismissThreshold: CGFloat = 120

    // Chrome auto-hide
    @State private var showChrome = true
    @State private var chromeHideTask: Task<Void, Never>?

    // Sheet drivers
    @State private var showShareSheet = false
    @State private var showForwardSheet = false
    @State private var showReportSheet = false
    @State private var showOptionsSheet = false
    /// Comments sheet presented OVER the fullscreen player.
    /// Uses a `.medium` detent so the video stays visible at the
    /// top of the screen — TikTok / Twitter pattern. Tapping the
    /// comment button used to `dismiss()` the fullscreen first
    /// then push to PostDetailView (jarring); now the video keeps
    /// playing and the comments slide up from the bottom.
    @State private var showCommentsSheet = false
    @State private var sheetPlaybackRate: Float = 1.0
    @State private var autoAdvance: Bool = UserDefaults.standard.object(forKey: "raven.video.autoAdvance") as? Bool ?? true
    @State private var toastText: String? = nil
    @State private var toastTask: Task<Void, Never>? = nil
    @State private var savedStateBumper: Int = 0

    @StateObject private var airPlayHolder = AirPlayRouteHolder()

    init(
        media: [PostMedia],
        startIndex: Int,
        startTime: CMTime,
        chapters: [VideoTimestamp] = [],
        post: Post? = nil
    ) {
        self.media = media
        self.startIndex = startIndex
        self.startTime = startTime
        self.chapters = chapters
        self.post = post
        self._currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        let dragProgress = min(1, abs(dragOffsetY) / 320)
        let cornerRadius = dragProgress * 28
        let contentScale = 1 - dragProgress * 0.12
        let bgOpacity = 1 - dragProgress * 0.6

        ZStack {
            Color.black.opacity(bgOpacity).ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(media.indices, id: \.self) { i in
                    pageContent(for: i)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragOffsetY)
            .scaleEffect(contentScale)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // 🔴 Bug fix (2026-05-09): swipe-down dismiss felt stiff.
            // Two changes: (a) rubber-band the drag so the further
            // the user pulls, the slower it tracks (Apple's photo
            // viewer pattern — a sqrt-style resistance kicks in past
            // a comfortable threshold so the user can keep pulling
            // without overshooting), and (b) replace the hard
            // `interpolatingSpring(320, 32)` snap-back with a softer
            // `spring(response: 0.45, dampingFraction: 0.78)` that
            // settles with a gentle bounce instead of a crisp click.
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        isDragging = true
                        let raw = value.translation.height
                        if raw > 0 {
                            // Rubber-band: linear up to 200pt, then
                            // sqrt-decayed past that so the drag
                            // feels resistive without ever locking.
                            let comfortable: CGFloat = 200
                            if raw <= comfortable {
                                dragOffsetY = raw
                            } else {
                                let extra = raw - comfortable
                                dragOffsetY = comfortable + sqrt(extra) * 8
                            }
                        } else {
                            dragOffsetY = raw * 0.4   // upward = damped
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        let velocity = value.predictedEndTranslation.height - value.translation.height
                        if value.translation.height > dismissThreshold || velocity > 400 {
                            Haptics.light()
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                                dragOffsetY = 0
                            }
                        }
                    }
            )

            topChrome
                .opacity(isDragging ? 0 : (showChrome ? 1 : 0))
                .allowsHitTesting(showChrome && !isDragging)

            if let toast = toastText {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color(white: 0.15).opacity(0.95))
                                .overlay(
                                    Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                                )
                        )
                        .padding(.bottom, 240)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
            }

            AirPlayPickerView(holder: airPlayHolder)
                .frame(width: 0.001, height: 0.001)
                .opacity(0.001)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.2), value: toastText)
        .animation(.easeInOut(duration: 0.2), value: showChrome)
        .onAppear {
            showChrome = true
            scheduleChromeHide()
        }
        .onDisappear { chromeHideTask?.cancel() }
        .statusBarHidden(true)
        .sheet(isPresented: $showShareSheet) {
            if let post = post {
                ShareSheet(items: [shareLink(for: post)])
            }
        }
        .sheet(isPresented: $showForwardSheet) {
            if let post = post {
                ForwardPostSheet(post: post)
            }
        }
        .sheet(isPresented: $showReportSheet) {
            if let post = post {
                ReportView(
                    targetType: .post,
                    targetId: post.id,
                    targetName: "Post by @\(post.authorUsername)",
                    reportedUserId: post.authorId
                )
            }
        }
        // Comments sheet — half-height so the video keeps playing
        // in the top half of the screen during the conversation.
        .sheet(isPresented: $showCommentsSheet) {
            if let post = post {
                CommentsSheetView(post: post, feedStore: feedStore)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .sheet(isPresented: $showOptionsSheet) {
            VideoPlayerOptionsSheet(
                playbackRate: $sheetPlaybackRate,
                autoAdvance: $autoAdvance,
                post: post,
                onAirPlay: { airPlayHolder.present() },
                onGoToPost: {
                    guard let post = post else { return }
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        DeepLinkRouter.shared.navigate(to: .post(postId: post.serverId))
                    }
                },
                onAddToOffline: {
                    guard let post = post else { return }
                    let nowSaved = feedStore.toggleSaveOffline(postId: post.serverId)
                    showToast(nowSaved ? "Saved for offline" : "Removed from offline")
                    savedStateBumper &+= 1
                },
                onNotInterested: {
                    guard let post = post else { return }
                    feedStore.markNotInterested(postId: post.serverId)
                    showToast("We'll show fewer like this")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
                },
                onReport: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showReportSheet = true
                    }
                }
            )
        }
        .onChange(of: autoAdvance) { _, new in
            UserDefaults.standard.set(new, forKey: "raven.video.autoAdvance")
        }
    }

    // MARK: - Action handlers

    private func openComments() {
        guard post != nil else { return }
        Haptics.light()
        // 🔴 Bug fix (2026-05-09): the previous implementation called
        // `dismiss()` and then push-navigated to PostDetailView — the
        // user lost the fullscreen + the video stopped playing. The
        // expected pattern (TikTok / Twitter) is the comments slide
        // up from the bottom OVER the fullscreen and the video keeps
        // playing in the visible top half. We use a `.medium` sheet
        // detent so the video stays visible during commenting.
        showCommentsSheet = true
    }

    private func tapLike() {
        guard let post else { return }
        Haptics.light()
        Task { await feedStore.toggleLike(postId: post.serverId) }
    }

    private func tapBookmark() {
        guard let post else { return }
        Haptics.light()
        let nowSaved = feedStore.toggleBookmark(postId: post.serverId)
        showToast(nowSaved ? "Bookmarked" : "Bookmark removed")
        savedStateBumper &+= 1
    }

    /// Real repost (not forward to chat). Optimistic + server sync via
    /// `FeedStore.toggleRepost`. When offline, also broadcasts a
    /// `MeshRepostEnvelope` via BLE so peers can see the repost
    /// without internet — when the server comes back the synced state
    /// supersedes the mesh-only count.
    private func tapRepost() {
        guard let post else { return }
        Haptics.selection()
        let willRepost = !(feedStore.livePost(byId: post.serverId)?.isReposted ?? post.isReposted)
        Task { await feedStore.toggleRepost(postId: post.serverId) }
        if willRepost {
            showToast("Reposted")
        } else {
            showToast("Repost removed")
        }
        // Mesh fan-out — fire-and-forget. Safe to run regardless of
        // online state (mesh peers see the repost immediately, the
        // server-side path resolves the truth when reachable).
        // TODO(mesh-repost): MeshRepostService is not yet ported to
        // this codebase — when the service lands, restore the
        // broadcastRepost call here. Until then the repost still
        // works via the server path; mesh fan-out is a no-op.
        _ = (post.serverId, post.authorId, willRepost)
    }

    // MARK: - Toast helper

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { toastText = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.22)) { toastText = nil }
            }
        }
    }

    // The bottom action bar lives inside FullscreenVideoItem now —
    // the action row, scrubber, and controls all share one Liquid
    // Glass panel.

    private func shareLink(for post: Post) -> String {
        let url = "raven://post/\(post.serverId)"
        let preview = post.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty { return url }
        let snippet = preview.prefix(120)
        return "\(snippet)\n\n\(url)"
    }

    // MARK: - Top chrome

    private var topChrome: some View {
        VStack {
            HStack(spacing: 10) {
                glassCircleButton(icon: "chevron.backward") {
                    Haptics.light()
                    dismiss()
                }

                Spacer()

                if media.count > 1 {
                    Text("\(currentIndex + 1) / \(media.count)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .glassSurface(in: Capsule())
                }

                Button {
                    Haptics.light()
                    sheetPlaybackRate = 1.0
                    showOptionsSheet = true
                    scheduleChromeHide()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .glassSurface(in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()
        }
    }

    @ViewBuilder
    private func pageContent(for i: Int) -> some View {
        if media[i].isVideo, let url = URL(string: media[i].url) {
            videoPage(url: url, index: i)
        } else {
            fullscreenImageView(url: media[i].url)
        }
    }

    @ViewBuilder
    private func videoPage(url: URL, index i: Int) -> some View {
        let livePost: Post? = resolveLivePost()
        let _ = savedStateBumper
        let isBkmrk: Bool = {
            guard let lp = livePost else { return false }
            return feedStore.isBookmarked(postId: lp.serverId)
        }()
        FullscreenVideoItem(
            url: url,
            isActive: i == currentIndex,
            resumeTime: i == startIndex ? startTime : .zero,
            chapters: i == startIndex ? chapters : [],
            showChrome: $showChrome,
            onUserInteraction: scheduleChromeHide,
            post: livePost,
            isBookmarked: isBkmrk,
            onComment: openComments,
            onRepost: tapRepost,
            onRepostLongPress: { showForwardSheet = true },
            onLike: tapLike,
            onBookmark: tapBookmark,
            onShare: { showShareSheet = true }
        )
    }

    private func resolveLivePost() -> Post? {
        guard let p = post else { return nil }
        return feedStore.livePost(byId: p.serverId) ?? p
    }

    private func glassCircleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .glassSurface(in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        showChrome = true
        chromeHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) { showChrome = false }
            }
        }
    }

    @ViewBuilder
    private func fullscreenImageView(url: String) -> some View {
        if let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Rectangle().fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        )
                case .empty:
                    ProgressView().tint(.white).scaleEffect(1.3)
                @unknown default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


// MARK: - Fullscreen Video Item (custom layer + unified bottom panel)
//
// Renders the video and the merged bottom panel: action row
// (comment / repost / like / bookmark / share) on top, divider,
// scrubber line, then the controls row (play / time / CC / speed /
// mute) — all inside a single Liquid Glass rounded-rectangle. The
// previous design split them into two separate capsules with a gap;
// this version merges them.
private struct FullscreenVideoItem: View {
    let url: URL
    let isActive: Bool
    let resumeTime: CMTime
    let chapters: [VideoTimestamp]
    @Binding var showChrome: Bool
    let onUserInteraction: () -> Void

    /// Owning post — when present the action row is rendered atop
    /// the scrub bar. `nil` collapses the action row.
    let post: Post?
    let isBookmarked: Bool
    let onComment: () -> Void
    let onRepost: () -> Void
    let onRepostLongPress: () -> Void
    let onLike: () -> Void
    let onBookmark: () -> Void
    let onShare: () -> Void

    @State private var holder = VideoHolder()
    @State private var isReady = false
    @State private var isPlaying = true
    @State private var currentSeconds: Double = 0
    @State private var durationSeconds: Double = 0
    @State private var isScrubbing = false
    @State private var pendingSeek: Double?
    @State private var hintIcon: String? = nil
    @State private var playbackRate: Float = 1.0
    @State private var captionsOn: Bool = false
    @State private var currentCue: VideoCaptionCue? = nil
    @ObservedObject private var subtitleService = VideoSubtitleService.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = holder.player {
                PlayerLayerRepresentable(player: player, gravity: .resizeAspect)
                    .ignoresSafeArea()
            }

            if !isReady {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            // Center play/pause control.
            //
            // Two distinct visuals share this slot:
            //   • A brief flash (when `hintIcon` is set by togglePlayPause)
            //     to give visual feedback for the toggle.
            //   • A persistent big tappable button while chrome is
            //     visible — the user explicitly asked for this as the
            //     primary on-screen pause control. Tapping the body of
            //     the video no longer pauses; you have to hit either
            //     this center button or the small one in the bottom
            //     panel.
            if let icon = hintIcon {
                Image(systemName: icon)
                    .font(.system(size: 50, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 96, height: 96)
                    .glassSurface(in: Circle())
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .allowsHitTesting(false)
            } else if showChrome && isReady {
                Button {
                    togglePlayPause()
                    onUserInteraction()  // refresh chrome auto-hide timer
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 96, height: 96)
                        .glassSurface(in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            // Caption overlay
            if captionsOn, let cue = currentCue, !cue.text.isEmpty {
                VStack {
                    Spacer()
                    Text(cue.text)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.55))
                        )
                        .padding(.horizontal, 24)
                    Spacer().frame(height: showChrome ? 130 : 60)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: cue.text)
            }

            // Unified bottom panel (action row + scrubber + controls)
            VStack {
                Spacer()
                if showChrome && isReady {
                    mergedBottomPanel
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color(white: 0.13).opacity(0.92))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.30), radius: 14, y: 6)
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showChrome)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: hintIcon)
        .contentShape(Rectangle())
        // 🔴 Bug fix (2026-05-09): tapping anywhere on the video used
        // to toggle play/pause when chrome was visible. Users reported
        // this as accidental — they tap to dismiss chrome (or just
        // adjust the phone) and the video stops. Pause now happens
        // ONLY through the explicit controls:
        //   • the center play/pause hint zone, OR
        //   • the play/pause button in the bottom merged panel.
        // A tap on the body of the video toggles chrome visibility
        // and nothing else.
        .onTapGesture {
            if !showChrome {
                onUserInteraction()      // surface chrome
            } else {
                showChrome = false       // hide chrome — no playback change
            }
        }
        .onAppear { setupPlayer() }
        .onDisappear { holder.tearDown() }
        .onChange(of: isActive) { _, active in
            guard let player = holder.player else { return }
            if active {
                player.play()
                if abs(playbackRate - 1.0) > 0.01 { player.rate = playbackRate }
                isPlaying = true
            } else {
                player.pause()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ravenVideoSetPlaybackRate)) { note in
            guard isActive else { return }
            guard let rate = note.userInfo?["rate"] as? Float else { return }
            playbackRate = rate
            if isPlaying { holder.player?.rate = rate }
        }
    }

    // MARK: Merged bottom panel

    /// Action row + divider + scrubber + controls — all in one panel.
    private var mergedBottomPanel: some View {
        VStack(spacing: 12) {
            if let post = post {
                actionRow(for: post)
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 0.5)
            }
            scrubberLine
                .frame(height: chapters.isEmpty ? 14 : 42)
            HStack(spacing: 18) {
                Button { togglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)

                Text(timeRemainingLabel)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(.white)

                Spacer(minLength: 8)

                Button {
                    Haptics.light()
                    Task { await toggleCaptions() }
                } label: {
                    ZStack {
                        Image(systemName: captionsOn ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(captionsOn ? Color.accentColor : .white)
                        if subtitleService.isWorking(on: url.absoluteString) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.55)
                                .offset(x: 14, y: -10)
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            setPlaybackRate(Float(rate))
                        } label: {
                            HStack {
                                Text(rateLabel(Float(rate)))
                                if abs(Float(rate) - playbackRate) < 0.01 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(rateLabel(playbackRate))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5)
                        )
                }

                Button {
                    Haptics.light()
                    VideoPlayerPool.shared.setMuted(!VideoPlayerPool.shared.isMuted)
                    holder.player?.isMuted = VideoPlayerPool.shared.isMuted
                    onUserInteraction()
                } label: {
                    Image(systemName: VideoPlayerPool.shared.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Action row (top of merged panel)

    /// Twitter-style action row: comment / repost / like / spacer /
    /// bookmark / share. Tap repost = real repost (FeedStore). Long
    /// press repost = forward to chat conversation.
    private func actionRow(for post: Post) -> some View {
        HStack(spacing: 22) {
            actionStatPill(icon: "bubble.left", count: post.comments) {
                onComment()
            }

            Button {
                onRepost()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 18, weight: .semibold))
                    Text(post.reposts > 0 ? actionFormatCount(post.reposts) : "0")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                }
                .foregroundColor(post.isReposted ? .green : .white)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in onRepostLongPress() }
            )

            actionStatPill(
                icon: post.isLiked ? "heart.fill" : "heart",
                count: post.likes,
                tint: post.isLiked ? .pink : .white
            ) {
                onLike()
            }

            Spacer(minLength: 0)

            Button {
                onBookmark()
            } label: {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isBookmarked ? .yellow : .white)
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)

            Button {
                onShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
        }
    }

    private func actionStatPill(
        icon: String, count: Int, tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(count > 0 ? actionFormatCount(count) : "0")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
            }
            .foregroundColor(tint)
        }
        .buttonStyle(.plain)
    }

    private func actionFormatCount(_ n: Int) -> String {
        switch n {
        case 0..<1_000: return "\(n)"
        case 1_000..<1_000_000:
            return String(format: "%.1fK", Double(n) / 1_000)
                .replacingOccurrences(of: ".0K", with: "K")
        default:
            return String(format: "%.1fM", Double(n) / 1_000_000)
                .replacingOccurrences(of: ".0M", with: "M")
        }
    }

    private var scrubberLine: some View {
        GeometryReader { geo in
            let progress: CGFloat = durationSeconds > 0
                ? CGFloat(max(0, min(1, currentSeconds / durationSeconds)))
                : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: 2.5)
                Capsule()
                    .fill(.white)
                    .frame(width: geo.size.width * progress, height: 2.5)
                if durationSeconds > 0 && !chapters.isEmpty {
                    ForEach(chapters, id: \.self) { ts in
                        let pct = CGFloat(min(1, max(0, ts.seconds / durationSeconds)))
                        let isPassed = currentSeconds >= ts.seconds - 0.4
                        let isActiveCh = activeChapter?.token == ts.token
                        ChapterMarker(label: ts.label, isPassed: isPassed, isActive: isActiveCh)
                            .position(x: geo.size.width * pct, y: -14)
                            .onTapGesture {
                                Haptics.selection()
                                let cm = CMTime(seconds: ts.seconds, preferredTimescale: 600)
                                holder.player?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
                                currentSeconds = ts.seconds
                                onUserInteraction()
                            }
                    }
                }
                Circle()
                    .fill(.white)
                    .frame(width: isScrubbing ? 12 : 9, height: isScrubbing ? 12 : 9)
                    .offset(x: geo.size.width * progress - (isScrubbing ? 6 : 4.5))
                    .animation(.easeOut(duration: 0.12), value: isScrubbing)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        let pct = max(0, min(1, value.location.x / geo.size.width))
                        currentSeconds = pct * durationSeconds
                        pendingSeek = currentSeconds
                        onUserInteraction()
                    }
                    .onEnded { _ in
                        if let target = pendingSeek {
                            let cm = CMTime(seconds: target, preferredTimescale: 600)
                            holder.player?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
                            pendingSeek = nil
                        }
                        isScrubbing = false
                        onUserInteraction()
                    }
            )
        }
    }

    // MARK: - Captions

    private func toggleCaptions() async {
        captionsOn.toggle()
        guard captionsOn else {
            currentCue = nil
            return
        }
        let status = await VideoSubtitleService.requestAuthorisation()
        guard status == .authorized else {
            captionsOn = false
            return
        }
        VideoSubtitleService.shared.generateIfNeeded(for: url)
        currentCue = VideoSubtitleService.shared.cue(
            for: url.absoluteString,
            atSecond: currentSeconds
        )
        onUserInteraction()
    }

    // MARK: - Rate / time helpers

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { holder.player?.rate = rate }
        Haptics.selection()
        onUserInteraction()
    }

    private func rateLabel(_ rate: Float) -> String {
        if rate == floor(rate) { return "\(Int(rate))×" }
        let formatted = String(format: "%.2f", rate)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        return "\(formatted)×"
    }

    private var timeRemainingLabel: String {
        guard durationSeconds > 0 else { return formatTime(currentSeconds) }
        let remaining = max(0, durationSeconds - currentSeconds)
        return "-" + formatTime(remaining)
    }

    private var activeChapter: VideoTimestamp? {
        chapters
            .filter { $0.seconds <= currentSeconds + 0.4 }
            .max(by: { $0.seconds < $1.seconds })
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Player setup

    private func setupPlayer() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("⚠️ [FullScreenVideo] AVAudioSession config failed: \(error)")
            #endif
        }

        // 🔴 Bug fix (2026-05-09): videos took ~3-5s to start playing.
        //
        // Two compounding causes:
        //   1. `AVPlayerItem(url:)` with the default `AVURLAsset` asks
        //      iOS to compute *precise* duration + per-track metadata
        //      synchronously before the player can render — that's a
        //      full HTTP range read on the moov atom even for short
        //      clips, often eating a network round-trip on cold cache.
        //   2. `automaticallyWaitsToMinimizeStalling = true` (default)
        //      tells AVPlayer to buffer "comfortably" before showing
        //      the first frame — usually 3+ seconds. Great for long-
        //      form streams; awful for an Instagram-style feed.
        //
        // The fix on both: use AVURLAsset with the
        // PreferPreciseDurationAndTiming flag *off* (we don't need
        // ms-accurate duration for a 30-second clip — we update from
        // the periodic time observer anyway), and turn the
        // wait-to-minimize-stalling off so the very first decoded
        // frame surfaces immediately. A small `preferredForwardBuffer`
        // keeps the network from spiking.
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        let player = AVPlayer(playerItem: item)
        player.isMuted = VideoPlayerPool.shared.isMuted
        player.automaticallyWaitsToMinimizeStalling = false

        if resumeTime != .zero { player.seek(to: resumeTime) }

        let loopToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        let timeToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            if !isScrubbing, time.seconds.isFinite {
                currentSeconds = time.seconds
                if captionsOn {
                    currentCue = VideoSubtitleService.shared.cue(
                        for: url.absoluteString,
                        atSecond: time.seconds
                    )
                }
            }
            if !isReady, item.status == .readyToPlay {
                isReady = true
                let total = item.duration.seconds
                durationSeconds = total.isFinite ? total : 0
            }
        }

        holder.player = player
        holder.loopToken = loopToken
        holder.timeToken = timeToken

        if isActive {
            player.play()
            if abs(playbackRate - 1.0) > 0.01 {
                player.rate = playbackRate
            }
        }
    }

    private func togglePlayPause() {
        guard let player = holder.player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            hintIcon = "pause.fill"
        } else {
            player.play()
            if abs(playbackRate - 1.0) > 0.01 { player.rate = playbackRate }
            isPlaying = true
            hintIcon = "play.fill"
        }
        Haptics.light()
        onUserInteraction()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { hintIcon = nil }
        }
    }
}


// MARK: - Holder for AVPlayer + observers (so cleanup is reliable)
@MainActor
private final class VideoHolder {
    var player: AVPlayer?
    var loopToken: NSObjectProtocol?
    var timeToken: Any?

    func tearDown() {
        if let loopToken {
            NotificationCenter.default.removeObserver(loopToken)
        }
        if let timeToken, let player {
            player.removeTimeObserver(timeToken)
        }
        player?.pause()
        player = nil
        loopToken = nil
        timeToken = nil
    }
}

// MARK: - Player layer wrapper (no system controls)
private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerLayerView {
        PlayerLayerView(player: player, gravity: gravity)
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
    }
}


// MARK: - Chapter Marker (Liquid Glass capsule)
//
// One pill per `vM:SS` token in the post body. Pinned above the scrub bar
// at its seconds-fraction position. The marker plays out three states:
//   • Inactive — translucent white-on-glass
//   • Passed   — filled white (we've already seen this point)
//   • Active   — accent tint with a soft glow ring (we're on this chapter)
private struct ChapterMarker: View {
    let label: String
    let isPassed: Bool
    let isActive: Bool

    private var foreground: Color {
        if isActive || isPassed { return .white }
        return .white.opacity(0.85)
    }

    private var tintFill: Color {
        if isActive { return Color.accentColor.opacity(0.55) }
        if isPassed { return Color.white.opacity(0.10) }
        return .clear
    }

    private var strokeColor: Color {
        isActive ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.30)
    }

    private var strokeWidth: CGFloat { isActive ? 1.0 : 0.5 }

    private var shadowColor: Color {
        isActive ? Color.accentColor.opacity(0.55) : Color.black.opacity(0.35)
    }

    private var shadowRadius: CGFloat { isActive ? 6 : 3 }

    var body: some View {
        let capsuleShape = Capsule(style: .continuous)
        return Text(label)
            .font(.system(size: 10, weight: .heavy).monospacedDigit())
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(capsuleShape.fill(.ultraThinMaterial))
            .overlay(capsuleShape.fill(tintFill))
            .overlay(capsuleShape.stroke(strokeColor, lineWidth: strokeWidth))
            .shadow(color: shadowColor, radius: shadowRadius, y: 2)
            .scaleEffect(isActive ? 1.08 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
    }
}

// MARK: - Notification names used by the fullscreen video player
//
// Only the speed-picker hop survives — the sheet and the active
// `FullscreenVideoItem` live in different view hierarchies (the
// sheet is its own SwiftUI scene), so a NotificationCenter relay
// is the most direct way to bridge them. All other actions are
// invoked directly on `FeedStore` / local sheet state inside
// `FullScreenVideoPlayer`.

extension Notification.Name {
    /// Top-right "..." → Speed picker. userInfo: ["rate": Float]
    static let ravenVideoSetPlaybackRate = Notification.Name("ravenVideoSetPlaybackRate")
}

// MARK: - AirPlay route picker bridge
//
// `AVRoutePickerView` shows the AirPlay system sheet only when its
// internal button receives a `touchUpInside` action. We embed the
// picker off-screen and expose `present()` to programmatically tap
// that button from the options sheet's "Airplay & Bluetooth" row.

@MainActor
final class AirPlayRouteHolder: ObservableObject {
    fileprivate weak var pickerView: AVRoutePickerView?

    func present() {
        guard let pickerView else { return }
        for sub in pickerView.subviews {
            if let button = sub as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }
    }
}

private struct AirPlayPickerView: UIViewRepresentable {
    let holder: AirPlayRouteHolder

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .clear
        view.tintColor = .clear
        view.prioritizesVideoDevices = true
        DispatchQueue.main.async { holder.pickerView = view }
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
