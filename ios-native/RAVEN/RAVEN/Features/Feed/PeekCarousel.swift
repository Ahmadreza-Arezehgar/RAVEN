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
/// Shows images in horizontal carousel with peek of next image
struct PeekCarouselView: View {
    let media: [PostMedia]
    var onTap: (Int) -> Void
    
    @State private var currentIndex: Int = 0
    
    var body: some View {
        GeometryReader { geo in
            let itemWidth = geo.size.width * 0.92 // 92% width = 8% peek
            let spacing: CGFloat = 10
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(media.indices, id: \.self) { idx in
                        let item = media[idx]
                        let displayUrl = (item.mediaType == "video" ? item.thumbnailUrl : nil) ?? item.url
                        
                        if let url = URL(string: displayUrl) {
                            ZStack {
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
                                
                                // Video play overlay
                                if item.mediaType == "video" {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 44))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .shadow(color: .black.opacity(0.4), radius: 6)
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
                .padding(.horizontal, (geo.size.width - itemWidth) / 2)
            }
            .scrollTargetBehaviorIfAvailable()
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
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            // Media slider
            TabView(selection: $currentIndex) {
                ForEach(media.indices, id: \.self) { i in
                    let item = media[i]
                    
                    if item.mediaType == "video" {
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
            
            // Top bar with close and counter
            VStack {
                HStack {
                    // Close button
                    Button {
                        Haptics.light()
                        videoPlayer?.pause()
                        videoPlayer = nil
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
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
                .padding(.horizontal, 16)
                .padding(.top, 12)
                
                Spacer()
                
                // Top comments for current media (Liquid Glass panel)
                if currentIndex < media.count,
                   let comments = media[currentIndex].topComments,
                   !comments.isEmpty {
                    topCommentsPanel(comments: comments)
                }
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
    @ViewBuilder
    private func videoSlide(item: PostMedia, index: Int) -> some View {
        ZStack {
            if isPlayingVideo && currentIndex == index, let player = videoPlayer {
                // Show AVPlayer
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear {
                        player.pause()
                    }
            } else {
                // Show thumbnail with play button
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
                
                // Tap to play
                Button {
                    Haptics.light()
                    guard let videoURL = URL(string: item.url) else { return }
                    let player = AVPlayer(url: videoURL)
                    self.videoPlayer = player
                    self.isPlayingVideo = true
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.5), radius: 8)
                }
            }
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

// MARK: - Helper Extension for iOS 17 scroll behavior
extension View {
    @ViewBuilder
    func scrollTargetBehaviorIfAvailable() -> some View {
        if #available(iOS 17.0, *) {
            self.scrollTargetBehavior(.paging)
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
