import SwiftUI
import AVKit

// MARK: - Peek Preview for New Post (stacked cards)
/// Shows up to 4 images stacked with offset to show "peek" effect
struct PeekPreview: View {
    let images: [UIImage]
    
    var body: some View {
        let count = min(images.count, 4)
        
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            VStack(spacing: 8) {
                // Stacked images - draw from back to front
                ZStack(alignment: .leading) {
                    // Draw in correct z-order: last image first (at back), first image last (on top)
                    ForEach((0..<count).reversed(), id: \.self) { idx in
                        SingleImageCard(
                            image: images[idx],
                            width: w * 0.85,
                            height: h * 0.75,
                            xOffset: CGFloat(idx) * (w * 0.035)
                        )
                    }
                }
                .frame(width: w, height: h * 0.8, alignment: .leading)
                
                // Page indicator 1 2 3 4
                if count > 1 {
                    HStack(spacing: 6) {
                        ForEach(1...count, id: \.self) { i in
                            Text("\(i)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 9)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false) // Don't block touch on TextEditor above
    }
}


// Single image card for stacked preview
private struct SingleImageCard: View {
    let image: UIImage
    let width: CGFloat
    let height: CGFloat
    let xOffset: CGFloat
    
    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .offset(x: xOffset)
    }
}

// MARK: - Peek Preview for New Post (mixed media: images + videos)
/// Shows up to 4 media items stacked with offset to show "peek" effect
struct PeekMediaPreview: View {
    let media: [PostMediaItem]
    
    var body: some View {
        let count = min(media.count, 4)
        
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            
            VStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    ForEach((0..<count).reversed(), id: \.self) { idx in
                        ZStack {
                            Image(uiImage: media[idx].thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: w * 0.85, height: h * 0.75)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                            
                            if media[idx].isVideo {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.4), radius: 4)
                            }
                        }
                        .offset(x: CGFloat(idx) * (w * 0.035))
                    }
                }
                .frame(width: w, height: h * 0.8, alignment: .leading)
                
                if count > 1 {
                    HStack(spacing: 6) {
                        ForEach(1...count, id: \.self) { i in
                            Text("\(i)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 9)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
    }
}


// MARK: - Peek Carousel for Feed (horizontal scroll with peek)
/// Shows images/videos in horizontal carousel with peek of next image.
/// Videos auto-play muted inline (Instagram/Twitter style).
///
/// Optional `currentIndex` binding lets the parent drive the carousel
/// programmatically (e.g. user taps the "1 / 2 / 3" page indicator). The
/// binding is two-way: scrolling the carousel updates the binding via
/// `.scrollPosition`, and writing to the binding scrolls the carousel.
struct PeekCarouselView: View {
    let media: [PostMedia]
    var currentIndex: Binding<Int>?  // optional — caller decides if it cares
    /// Optional owning post — passed through to inline `FeedVideoCard`s
    /// so the fullscreen video player can render its action bar +
    /// options menu (which are post-aware).
    var post: Post?
    var onTap: (Int) -> Void

    @State private var localIndex: Int = 0

    init(
        media: [PostMedia],
        currentIndex: Binding<Int>? = nil,
        post: Post? = nil,
        onTap: @escaping (Int) -> Void
    ) {
        self.media = media
        self.currentIndex = currentIndex
        self.post = post
        self.onTap = onTap
    }

    /// Backing index for `.scrollPosition` — iOS 17 wants `Binding<Int?>`.
    /// We bridge to either the parent's binding or our local @State so the
    /// view works whether or not the caller provides one.
    private var scrollIndexBinding: Binding<Int?> {
        Binding<Int?>(
            get: { currentIndex?.wrappedValue ?? localIndex },
            set: { newValue in
                let v = newValue ?? 0
                if let parent = currentIndex {
                    if parent.wrappedValue != v { parent.wrappedValue = v }
                } else if localIndex != v {
                    localIndex = v
                }
            }
        )
    }

    var body: some View {
        GeometryReader { geo in
            let itemWidth = geo.size.width * 0.92 // 92% width = 8% peek
            let spacing: CGFloat = 10

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(media.indices, id: \.self) { idx in
                        let item = media[idx]
                        
                        let _ = {
                            #if DEBUG
                            print("🎬🖼️ [PeekCarousel] idx=\(idx) isVideo=\(item.isVideo) mediaType='\(item.mediaType ?? "nil")' url=\(item.url.suffix(30))")
                            #endif
                        }()
                        
                        if item.isVideo {
                            // Video: inline auto-play muted player
                            FeedVideoCard(
                                media: item,
                                allMedia: media,
                                startIndex: idx,
                                post: post
                            )
                            .frame(width: itemWidth, height: geo.size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                        } else {
                            // Image: standard AsyncImage
                            let displayUrl = item.url
                            if let url = URL(string: displayUrl) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    case .failure:
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.3))
                                            .overlay(
                                                Image(systemName: "photo")
                                                    .foregroundColor(.gray)
                                            )
                                    case .empty:
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.2))
                                            .overlay(ProgressView())
                                    @unknown default:
                                        Rectangle().fill(Color.gray.opacity(0.2))
                                    }
                                }
                                .frame(width: itemWidth, height: geo.size.height)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Haptics.light()
                                    onTap(idx)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, (geo.size.width - itemWidth) / 2)
                // .scrollTargetLayout() pairs with .scrollPosition below so
                // each child becomes a scroll target. Required for the
                // binding-driven page indicator to work.
                .scrollTargetLayoutIfAvailable()
            }
            .scrollTargetBehaviorIfAvailable()
            // 🔗 Two-way bind to the page index — taps on the "1 2 3"
            // indicator scroll the carousel; user swipes update the
            // indicator highlight. Without this the indicator was purely
            // decorative.
            .scrollPositionIfAvailable(id: scrollIndexBinding)
            // 🚧 Claim the gesture while the carousel is being panned so the
            // root TabPager does NOT also switch tabs (Home ↔ Messages) when
            // the user is actually swiping between media within a single post.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) * 1.2 {
                            NestedSwipeCoordinator.shared.isHandlingSwipe = true
                        }
                    }
                    .onEnded { _ in
                        NestedSwipeCoordinator.shared.isHandlingSwipe = false
                    }
            )
        }
    }
}

// MARK: - Full Screen Slider with Liquid Glass
struct FullScreenMediaSlider: View {
    let media: [PostMedia]
    let startIndex: Int
    
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var isPlayingVideo = false
    @State private var videoPlayer: AVPlayer?
    
    // Swipe-down dismiss state
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    
    /// Threshold in points — drag past this to dismiss
    private let dismissThreshold: CGFloat = 120
    
    var body: some View {
        let dragProgress = min(1, abs(dragOffset.height) / 300) // 0→1 as user drags
        
        ZStack {
            // Background — fades as user drags down
            Color.black
                .opacity(1 - dragProgress * 0.5)
                .ignoresSafeArea()
            
            // Media slider
            TabView(selection: $currentIndex) {
                ForEach(media.indices, id: \.self) { i in
                    let item = media[i]
                    
                    if item.isVideo {
                        // Video slide
                        videoSlide(item: item, index: i)
                            .tag(i)
                    } else {
                        // Image slide
                        imageSlide(url: item.url)
                            .tag(i)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onAppear { currentIndex = startIndex }
            .onChange(of: currentIndex) { _, _ in
                // Pause video when swiping away
                videoPlayer?.pause()
                videoPlayer = nil
                isPlayingVideo = false
            }
            // Apply drag offset + scale for interactive feel
            .offset(y: dragOffset.height)
            .scaleEffect(1 - dragProgress * 0.1)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Only respond to vertical drags (not horizontal page swipes)
                        if abs(value.translation.height) > abs(value.translation.width) {
                            isDragging = true
                            dragOffset = value.translation
                        }
                    }
                    .onEnded { value in
                        isDragging = false
                        if abs(value.translation.height) > dismissThreshold ||
                           abs(value.predictedEndTranslation.height) > dismissThreshold * 2 {
                            // Dismiss
                            Haptics.light()
                            videoPlayer?.pause()
                            videoPlayer = nil
                            dismiss()
                        } else {
                            // Snap back
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                dragOffset = .zero
                            }
                        }
                    }
            )
            
            // Top bar with close and counter — hidden during drag
            if !isDragging {
                VStack {
                    HStack {
                        // Close button
                        Button {
                            Haptics.light()
                            videoPlayer?.pause()
                            videoPlayer = nil
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay(
                                    Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                                )
                        }
                        
                        Spacer()
                        
                        // Page counter
                        if media.count > 1 {
                            Text("\(currentIndex + 1)/\(media.count)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 14)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                                )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    
                    Spacer()
                    
                    // Swipe hint (subtle)
                    VStack(spacing: 4) {
                        Image(systemName: "chevron.compact.down")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Swipe down to close")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    .padding(.bottom, 8)
                    
                    // Top comments for current media (Liquid Glass panel)
                    if currentIndex < media.count,
                       let comments = media[currentIndex].topComments,
                       !comments.isEmpty {
                        topCommentsPanel(comments: comments)
                    }
                }
                .transition(.opacity)
            }
        }
    }
    
    // MARK: - Image Slide
    @ViewBuilder
    private func imageSlide(url: String) -> some View {
        if let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        )
                case .empty:
                    ProgressView()
                        .scaleEffect(1.5)
                @unknown default:
                    EmptyView()
                }
            }
        }
    }
    
    // MARK: - Video Slide
    //
    // UX note: Twitter / X auto-starts the video the moment its
    // fullscreen view appears — the user shouldn't need to tap a
    // separate play button on top of the thumbnail. We mirror that
    // here by spinning up the AVPlayer in `.task` instead of in a
    // tap handler, so the video begins loading + playing as soon
    // as this slide becomes visible.
    @ViewBuilder
    private func videoSlide(item: PostMedia, index: Int) -> some View {
        ZStack {
            if let player = videoPlayer, currentIndex == index {
                // Show AVKit's stock video player — it provides the
                // native scrubber, time labels, AirPlay button,
                // playback-rate menu (1×/1.25×/etc.) and rotation
                // support for free.
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else {
                // Loading state — show poster while AVPlayer warms up.
                // Even on slow networks the user immediately sees the
                // thumbnail rather than the empty black box from
                // before.
                let thumbUrl = item.thumbnailUrl ?? item.url
                if let url = URL(string: thumbUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure, .empty:
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .overlay(ProgressView())
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
                ProgressView()
                    .scaleEffect(1.3)
                    .tint(.white.opacity(0.85))
            }
        }
        // Auto-spin the player when the slide is on-screen for the
        // first time. `.task` is bound to the (item.url, index) tuple
        // so swiping to a different video slide reinitialises the
        // player rather than reusing a stale one.
        .task(id: "\(item.url)|\(index)") {
            guard currentIndex == index else { return }
            guard videoPlayer == nil else { return }
            guard let videoURL = URL(string: item.url) else { return }

            // Allow audio in silent-mode like Twitter's player does.
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            } catch {
                #if DEBUG
                print("⚠️ [FullScreenSlider] AVAudioSession config failed: \(error)")
                #endif
            }

            let player = AVPlayer(url: videoURL)
            self.videoPlayer = player
            self.isPlayingVideo = true
        }
    }
    
    // MARK: - Top Comments Panel (Liquid Glass)
    private func topCommentsPanel(comments: [PostMedia.TopComment]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Comments")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            
            ForEach(comments.prefix(3)) { comment in
                HStack(alignment: .top, spacing: 10) {
                    // Avatar
                    if let avatar = comment.authorAvatar, let url = URL(string: avatar) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color.gray.opacity(0.3))
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(String(comment.authorName.prefix(1)).uppercased())
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(comment.authorName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text(comment.content)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(2)
                    }
                    
                    Spacer()
                    
                    // Likes
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                        Text("\(comment.likes)")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }
}

// MARK: - Helper Extensions for iOS 17 scroll behavior
extension View {
    @ViewBuilder
    func scrollTargetBehaviorIfAvailable() -> some View {
        if #available(iOS 17.0, *) {
            self.scrollTargetBehavior(.paging)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollTargetLayoutIfAvailable() -> some View {
        if #available(iOS 17.0, *) {
            self.scrollTargetLayout()
        } else {
            self
        }
    }

    /// Wraps `.scrollPosition(id:)` (iOS 17+) so the binding-driven page
    /// indicator works on supported devices and silently degrades to free
    /// scrolling on older OS (the deployment target IS 17 today, but this
    /// keeps the file robust if anyone bumps minTarget back).
    @ViewBuilder
    func scrollPositionIfAvailable(id: Binding<Int?>) -> some View {
        if #available(iOS 17.0, *) {
            self.scrollPosition(id: id)
        } else {
            self
        }
    }
}

#Preview {
    PeekPreview(images: [
        UIImage(systemName: "photo") ?? UIImage(),
        UIImage(systemName: "photo.fill") ?? UIImage()
    ])
    .frame(height: 260)
    .padding()
    .background(Color.black)
}
