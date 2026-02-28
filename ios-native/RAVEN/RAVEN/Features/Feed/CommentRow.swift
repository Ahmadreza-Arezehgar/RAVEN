import SwiftUI
import AVFoundation
import Combine

// MARK: - Comment Audio Manager (single-playback for voice comments)

/// Manages audio playback for voice comments — ensures only one plays at a time
@MainActor
class CommentAudioManager: ObservableObject {
    static let shared = CommentAudioManager()
    
    @Published var currentlyPlayingId: String?
    @Published var progress: Double = 0
    @Published var isPlaying: Bool = false
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {}
    
    func play(url: URL, commentId: String) {
        stop()
        
        // Avoid clobbering voiceChat if user is in a room
        if RoomService.shared.isInRoom {
            try? AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .voiceChat,
                options: [.mixWithOthers, .defaultToSpeaker]
            )
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        }
        // ⚡ FIX: setActive is blocking (0.5-3s with Bluetooth) — run on background (fire-and-forget)
        Task.detached(priority: .userInitiated) {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        currentlyPlayingId = commentId
        isPlaying = true
        progress = 0
        
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let duration = self.player?.currentItem?.duration,
                  duration.seconds > 0, !duration.seconds.isNaN else { return }
            
            Task { @MainActor in
                self.progress = time.seconds / duration.seconds
            }
        }
        
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.stop()
            }
            .store(in: &cancellables)
        
        player?.play()
    }
    
    func togglePlayback(url: URL, commentId: String) {
        if currentlyPlayingId == commentId && isPlaying {
            pause()
        } else if currentlyPlayingId == commentId && !isPlaying {
            resume()
        } else {
            play(url: url, commentId: commentId)
        }
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    func resume() {
        player?.play()
        isPlaying = true
    }
    
    func stop() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        currentlyPlayingId = nil
        isPlaying = false
        progress = 0
        cancellables.removeAll()
        // Only deactivate session if user is not in an active audio room
        if !RoomService.shared.isInRoom {
            // ⚡ FIX: setActive(false) is blocking — run on background (fire-and-forget)
            Task.detached(priority: .background) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

struct CommentRow: View {
    let comment: Comment
    var depth: Int = 0
    var onReply: ((Comment) -> Void)? = nil
    var onVote: ((String, Int) -> Void)? = nil  // (commentId, vote: +1/-1)
    
    @State private var showReplies = true
    @State private var upvoteScale: CGFloat = 1.0
    @State private var downvoteScale: CGFloat = 1.0
    @State private var showFullScreenImage = false
    @StateObject private var audioManager = CommentAudioManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // Indent for nested replies
                if depth > 0 {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 2)
                        .padding(.leading, CGFloat(depth * 16))
                }
                
                // Avatar
                AsyncImage(url: avatarURL(for: comment.authorAvatar)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .overlay {
                            Text(String(comment.authorName.prefix(1)).uppercased())
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .overlay {
                    if comment.isAiGenerated {
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    // Header
                    HStack(spacing: 4) {
                        Text(comment.authorName)
                            .font(.system(size: 14, weight: .semibold))
                        
                        if comment.isAiGenerated {
                            Text("AI")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    LinearGradient(
                                        colors: [.purple, .blue],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        
                        let isCurrentUser = comment.authorId == AuthService.shared.currentUser?.id
                        let showVerified = comment.verifiedStatus || (isCurrentUser && AuthService.shared.currentUser?.isVerified == true)
                        let showPremium = comment.premiumStatus || (isCurrentUser && SubscriptionService.shared.isPremium)
                        
                        if showVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.accentBlue)
                        }
                        
                        if showPremium {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                        }
                        
                        Text("·")
                            .foregroundColor(.secondary)
                        
                        Text(comment.timestamp.timeAgoString)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    
                    // Content with @mention highlighting
                    commentContent
                    
                    // Actions
                    HStack(spacing: 16) {
                        // Score
                        HStack(spacing: 4) {
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    upvoteScale = 1.3
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                        upvoteScale = 1.0
                                    }
                                }
                                onVote?(comment.id, 1)
                            } label: {
                                Image(systemName: comment.myVote == 1 ? "arrow.up.circle.fill" : "arrow.up.circle")
                                    .font(.system(size: 16, weight: .light))
                                    .foregroundColor(comment.myVote == 1 ? .orange : .secondary)
                            }
                            .scaleEffect(upvoteScale)
                            
                            Text("\(comment.score)")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            
                            Button {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    downvoteScale = 1.3
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                        downvoteScale = 1.0
                                    }
                                }
                                onVote?(comment.id, -1)
                            } label: {
                                Image(systemName: comment.myVote == -1 ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .font(.system(size: 16, weight: .light))
                                    .foregroundColor(comment.myVote == -1 ? .blue : .secondary)
                            }
                            .scaleEffect(downvoteScale)
                        }
                        
                        // Reply
                        Button {
                            onReply?(comment)  // ✅ Call reply callback
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrowshape.turn.up.left")
                                    .font(.system(size: 13, weight: .light))
                                Text("Reply")
                            }
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            
            // Nested Replies
            if !comment.replies.isEmpty {
                if showReplies {
                    ForEach(comment.replies) { reply in
                        CommentRow(
                            comment: reply,
                            depth: depth + 1,
                            onReply: onReply,
                            onVote: onVote
                        )
                    }
                } else {
                    Button {
                        withAnimation(.spring(response: 0.3)) { showReplies = true }
                    } label: {
                        Text("Show \(comment.replies.count) replies")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.accentColor)
                            .padding(.leading, CGFloat((depth + 1) * 16) + 42)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showFullScreenImage) {
            fullScreenImageView
        }
    }
    
    // MARK: - Content View (branched by type)
    
    @ViewBuilder
    private var commentContent: some View {
        let type = comment.commentType ?? "text"
        
        let _ = {
            if type == "voice" {
                #if DEBUG
                print("🔵 [VOICE-DEBUG] CommentRow rendering: id=\(comment.id), type=\(type), mediaUrl=\(comment.mediaUrl ?? "nil"), duration=\(comment.durationSec ?? -1)")
                #endif
            }
        }()
        
        switch type {
        case "voice":
            voiceCommentBubble
        case "image":
            imageCommentBubble
        default:
            // Text comment (existing behavior)
            MentionTextView(text: comment.content)
                .font(.system(size: 15))
        }
    }
    
    // MARK: - Voice Comment Bubble
    
    private var voiceCommentBubble: some View {
        let isThisPlaying = audioManager.currentlyPlayingId == comment.id
        
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Play/Pause
                Button {
                    guard let urlString = comment.mediaUrl,
                          let url = AppConfig.mediaURL(from: urlString) else { return }
                    audioManager.togglePlayback(url: url, commentId: comment.id)
                } label: {
                    Image(systemName: isThisPlaying && audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                }
                
                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 4)
                        
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * (isThisPlaying ? audioManager.progress : 0), height: 4)
                            .animation(.linear(duration: 0.1), value: audioManager.progress)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 20)
                
                // Duration
                Text(formatDuration(comment.durationSec ?? 0))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner))
            
            // Voice comment transcription
            TranscriptPill(contentId: comment.id, contentType: .comment)
        }
    }
    
    // MARK: - Image Comment Bubble
    
    private var imageCommentBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail
            if let urlString = comment.mediaUrl, let url = AppConfig.mediaURL(from: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: 220, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner))
                            .onTapGesture {
                                showFullScreenImage = true
                            }
                    case .failure(_):
                        RoundedRectangle(cornerRadius: DS.radiusInner)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 180, height: 120)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundColor(.secondary)
                            }
                    case .empty:
                        RoundedRectangle(cornerRadius: DS.radiusInner)
                            .fill(Color.gray.opacity(0.1))
                            .frame(width: 180, height: 120)
                            .overlay { ProgressView() }
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            
            // Caption (if present)
            if !comment.content.isEmpty {
                MentionTextView(text: comment.content)
                    .font(.system(size: 15))
            }
        }
    }
    
    // MARK: - Full Screen Image Viewer
    
    private var fullScreenImageView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let urlString = comment.mediaUrl, let url = AppConfig.mediaURL(from: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .ignoresSafeArea()
                    default:
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            
            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        showFullScreenImage = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .white.opacity(0.3))
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
    
    // MARK: - Helpers
    
    private func avatarURL(for path: String?) -> URL? {
        AppConfig.mediaURL(from: path)
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Mention Text View (highlights @mentions)
struct MentionTextView: View {
    let text: String
    
    // ✅ Static regex — compiled once, reused for every MentionTextView instance
    private static let mentionRegex = try? NSRegularExpression(pattern: "@\\w+")
    
    var body: some View {
        Text(attributedText)
    }
    
    private var attributedText: AttributedString {
        var result = AttributedString(text)
        
        // Find @mentions and style them
        if let regex = Self.mentionRegex {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: nsRange) {
                if let range = Range(match.range, in: text),
                   let attributedRange = Range(range, in: result) {
                    result[attributedRange].foregroundColor = .accentColor
                    result[attributedRange].font = .system(size: 15, weight: .medium)
                }
            }
        }
        
        return result
    }
}
