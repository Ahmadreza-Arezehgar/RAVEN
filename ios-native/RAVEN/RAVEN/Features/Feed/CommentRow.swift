import SwiftUI
import AVFoundation
import Combine
// Conditional import — Apple's Translation framework only exists on iOS 17.4+.
// `#if canImport(Translation)` keeps the build clean if anyone bumps the
// deployment target down in the future.
#if canImport(Translation)
import Translation
#endif

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
            // The observer queue is .main, so we are already on MainActor.
            // assumeIsolated lets us read `player`/`progress` without each
            // access tripping a "MainActor-isolated property in a Sendable
            // closure" warning.
            MainActor.assumeIsolated {
                guard let self = self,
                      let duration = self.player?.currentItem?.duration,
                      duration.seconds > 0, !duration.seconds.isNaN else { return }
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
    /// The post author's user-id. Used to gate the "Pin / Unpin" menu items
    /// (only the post owner can pin). ALSO used to badge the post author's
    /// own comments with an "Author" pill (Discord-style).
    var postAuthorId: String? = nil
    /// 🥇 If true, this row renders the "Top comment" highlight (subtle
    /// gradient ring + badge). Caller computes which comment qualifies
    /// (typically: highest-score in the post AND score >= threshold).
    var isTopComment: Bool = false
    var onReply: ((Comment) -> Void)? = nil
    var onVote: ((String, Int) -> Void)? = nil  // (commentId, vote: +1/-1)
    /// Save edited content + entities. Caller is expected to fire
    /// `PATCH /api/comments/{id}` and then refresh the comment list.
    var onEdit: ((_ commentId: String, _ newText: String) -> Void)? = nil
    /// Toggle pin state. Caller posts /pin or /unpin and refreshes.
    var onTogglePin: ((_ commentId: String, _ shouldPin: Bool) -> Void)? = nil
    /// Delete the comment (post-author can also delete, server enforces).
    var onDelete: ((_ commentId: String) -> Void)? = nil
    /// Report the comment (opens the existing report sheet at the parent).
    var onReport: ((Comment) -> Void)? = nil

    @State private var showReplies = true
    @State private var upvoteScale: CGFloat = 1.0
    @State private var downvoteScale: CGFloat = 1.0
    @State private var showFullScreenImage = false
    @StateObject private var audioManager = CommentAudioManager.shared

    // ✏️ Edit-mode state — when non-nil, the comment renders an inline
    // editor instead of the static text. We keep the in-progress text in
    // local state so cancel reverts cleanly without an extra round-trip.
    @State private var editingText: String? = nil
    @State private var showDeleteConfirm = false

    // 🌐 Translate state — uses Apple's Translation framework on iOS 17.4+.
    // The `.translationPresentation(isPresented:text:)` modifier shows
    // Apple's native translation sheet (free, on-device when possible).
    @State private var showTranslateSheet = false

    /// Helpers to know who's looking at this row.
    private var isOwner: Bool {
        comment.authorId == AuthService.shared.currentUser?.id
    }
    private var isPostOwner: Bool {
        postAuthorId != nil && AuthService.shared.currentUser?.id == postAuthorId
    }
    private var canEdit: Bool {
        guard isOwner, (comment.commentType ?? "text") == "text" else { return false }
        // Match server's 24-hour edit window so the menu doesn't surface
        // an option the API will reject anyway.
        return Date().timeIntervalSince(comment.timestamp) < 24 * 3600
    }
    
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
                    // 📌 PINNED banner — appears above header when post owner pinned this comment.
                    // Visible to everyone; visually distinct so people know
                    // it's been promoted (not just upvoted).
                    if comment.isPinned == true {
                        HStack(spacing: 4) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(45))
                            Text("Pinned")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.bottom, 2)
                    }

                    // 🥇 TOP COMMENT badge — shown for the highest-scoring
                    // comment on the post (auto-computed by the parent).
                    // Skipped if also pinned (would be visual overload).
                    if isTopComment && comment.isPinned != true {
                        HStack(spacing: 4) {
                            Image(systemName: "trophy.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Top comment")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                        .padding(.bottom, 2)
                    }

                    // Header
                    HStack(spacing: 4) {
                        Text(comment.authorName)
                            .font(.system(size: 14, weight: .semibold))

                        // 👤 AUTHOR badge — when this commenter IS the post author
                        // (Discord/Reddit OP convention). Helps readers spot the
                        // creator in long threads.
                        if let postAuthorId, comment.authorId == postAuthorId {
                            Text("Author")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
                        }

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

                        // ✏️ "edited" hint — only when server sent a non-null editedAt.
                        // `.help()` surfaces a tooltip on long-press / hover
                        // (Mac Catalyst, iPad with pointer) showing the exact
                        // edit time. Plain users still see the "edited" word
                        // and can long-press for "Edited 5 minutes ago".
                        if let editedAt = comment.editedAt {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text("edited")
                                .font(.system(size: 12))
                                .italic()
                                .foregroundColor(.secondary)
                                .help("Edited \(editedAt.timeAgoString)")
                                .accessibilityLabel("Edited \(editedAt.timeAgoString)")
                        }

                        Spacer()

                        // Kebab menu — surfaces edit / pin / delete / report / copy.
                        // Each item conditionally appears based on who's looking.
                        kebabMenu
                    }

                    // Content with @mention highlighting (or edit composer)
                    if let draft = editingText {
                        editComposer(draft: draft)
                    } else {
                        commentContent
                    }
                    
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
            
            // Nested Replies — now with a polished pill badge that always
            // shows the count + collapse/expand chevron. Replaces the
            // text-only "Show X replies" button.
            if !comment.replies.isEmpty {
                let totalReplies = countReplies(comment)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showReplies.toggle()
                    }
                    Haptics.light()
                } label: {
                    HStack(spacing: 6) {
                        // Visual leading line — connects to the avatar above
                        Rectangle()
                            .fill(Color.gray.opacity(0.35))
                            .frame(width: 18, height: 1)
                        Image(systemName: showReplies ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(showReplies
                             ? "Hide \(totalReplies) \(totalReplies == 1 ? "reply" : "replies")"
                             : "Show \(totalReplies) \(totalReplies == 1 ? "reply" : "replies")")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(Capsule())
                    .padding(.leading, CGFloat((depth + 1) * 16) + 42)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                if showReplies {
                    ForEach(comment.replies) { reply in
                        CommentRow(
                            comment: reply,
                            depth: depth + 1,
                            postAuthorId: postAuthorId,
                            // Replies don't get their own "Top" badge (only root)
                            isTopComment: false,
                            onReply: onReply,
                            onVote: onVote,
                            onEdit: onEdit,
                            onTogglePin: onTogglePin,
                            onDelete: onDelete,
                            onReport: onReport
                        )
                    }
                }
            }
        }
        // 🥇 Subtle gradient ring on top-comment cards — pure visual cue,
        // no extra height. Skipped on replies (depth>0) to keep nesting clean.
        .background(
            isTopComment && depth == 0
            ? LinearGradient(colors: [Color(red: 0.85, green: 0.70, blue: 0.35).opacity(0.06), .clear],
                             startPoint: .top, endPoint: .bottom)
            : nil
        )
        .fullScreenCover(isPresented: $showFullScreenImage) {
            fullScreenImageView
        }
        // 🌐 Apple Translation sheet — iOS 17.4+. The modifier itself is
        // gated by availability; on older OS the menu item never appears,
        // so the sheet binding is harmless.
        .modifier(TranslationSheetModifier(
            isPresented: $showTranslateSheet,
            text: comment.content
        ))
    }

    /// Recursively count this comment's descendant replies (any depth).
    /// Used by the reply-count pill so a deeply-nested thread reports
    /// the real number, not just the immediate children.
    private func countReplies(_ c: Comment) -> Int {
        c.replies.reduce(c.replies.count) { acc, r in acc + countReplies(r) }
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

    // MARK: - Kebab Menu (edit / pin / delete / copy / report)

    /// SwiftUI Menu attached to the header. Items appear conditionally
    /// based on whether the viewer is the comment author, the post author,
    /// or just a reader. Always at least "Copy" is available.
    @ViewBuilder
    private var kebabMenu: some View {
        Menu {
            // ✏️ Edit — only the comment author, only text comments,
            // only within the 24h window.
            if canEdit {
                Button {
                    Haptics.light()
                    editingText = comment.content
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }

            // 📌 Pin / Unpin — only the post author can pin a comment.
            if isPostOwner && (comment.commentType ?? "text") != "voice" {
                if comment.isPinned == true {
                    Button {
                        Haptics.light()
                        onTogglePin?(comment.id, false)
                    } label: {
                        Label("Unpin", systemImage: "pin.slash")
                    }
                } else {
                    Button {
                        Haptics.light()
                        onTogglePin?(comment.id, true)
                    } label: {
                        Label("Pin to top", systemImage: "pin.fill")
                    }
                }
            }

            // 📋 Copy — always available for text comments.
            if (comment.commentType ?? "text") == "text" && !comment.content.isEmpty {
                Button {
                    UIPasteboard.general.string = comment.content
                    Haptics.light()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            // 🌐 Translate — uses Apple's native Translation framework
            // (iOS 17.4+, on-device when possible). Free, no server hop.
            // Hidden on iOS < 17.4 since the API doesn't exist there.
            if #available(iOS 17.4, *),
               (comment.commentType ?? "text") == "text",
               !comment.content.isEmpty {
                Button {
                    Haptics.light()
                    showTranslateSheet = true
                } label: {
                    Label("Translate", systemImage: "translate")
                }
            }

            Divider()

            // 🚩 Report — anyone except the author.
            if !isOwner {
                Button {
                    Haptics.light()
                    onReport?(comment)
                } label: {
                    Label("Report", systemImage: "flag")
                }
            }

            // 🗑️ Delete — comment author OR post author.
            if isOwner || isPostOwner {
                Button(role: .destructive) {
                    Haptics.warning()
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .alert("Delete comment?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete?(comment.id)
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Edit Composer (inline)

    /// Drop-in editor that replaces the comment text when the user taps
    /// "Edit". Save fires the parent's `onEdit` callback (which calls
    /// `PATCH /api/comments/{id}`). Cancel discards local changes.
    @ViewBuilder
    private func editComposer(draft: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Edit your comment…", text: Binding(
                get: { editingText ?? draft },
                set: { editingText = $0 }
            ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Spacer()
                Button {
                    editingText = nil
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Button {
                    let newText = (editingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !newText.isEmpty, newText != comment.content else {
                        editingText = nil
                        return
                    }
                    Haptics.light()
                    onEdit?(comment.id, newText)
                    editingText = nil
                } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                }
                .disabled(((editingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty)
            }
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

// MARK: - 🌐 Translation Sheet Modifier (iOS 17.4+, no Catalyst)
//
// Wraps Apple's `.translationPresentation(isPresented:text:)` modifier
// behind an availability check so the file still compiles + runs on
// iOS 17.0–17.3 (where the API doesn't exist).
//
// IMPORTANT: `.translationPresentation` is **not available** on Mac
// Catalyst at all (Apple ships the Translation framework on Mac but
// has not bridged the SwiftUI presentation modifier yet). On Catalyst
// the modifier is a passthrough — Catalyst users get the original
// text without an inline translation sheet.
private struct TranslationSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
        #endif
    }
}


// MARK: - Mention Text View (tappable @mentions → user profile)
//
// Was previously read-only — mentions were colored but tapping did nothing.
// Now uses an AttributedString with `link` attributes pointing to a custom
// `raven://user/{username}` scheme. The view's `OpenURLAction` intercepts
// those URLs and opens the user's profile via a sheet (does the username→
// userId resolution on the fly via /api/users/search).
struct MentionTextView: View {
    let text: String

    // ✅ Static regex — compiled once, reused for every MentionTextView instance
    private static let mentionRegex = try? NSRegularExpression(pattern: "@\\w+")

    @State private var profileTarget: ProfileSheetTarget? = nil

    private struct ProfileSheetTarget: Identifiable {
        let id: String              // username (also the lookup key)
        let username: String
    }

    var body: some View {
        Text(attributedText)
            // Intercept raven://user/<username> link taps. Real http(s)/mailto
            // URLs fall through to the system handler (.systemAction).
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "raven", url.host == "user" {
                    let username = url.lastPathComponent
                    if !username.isEmpty {
                        profileTarget = ProfileSheetTarget(id: username, username: username)
                        Haptics.light()
                        return .handled
                    }
                }
                return .systemAction
            })
            .sheet(item: $profileTarget) { target in
                MentionedUserProfileSheet(username: target.username)
            }
    }

    private var attributedText: AttributedString {
        var result = AttributedString(text)
        guard let regex = Self.mentionRegex else { return result }

        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text),
                  let attributedRange = Range(range, in: result) else { continue }
            // Strip the leading "@" for the link target so `raven://user/foo`
            // matches what /api/users/search expects.
            let token = String(text[range])
            let username = token.hasPrefix("@") ? String(token.dropFirst()) : token

            result[attributedRange].foregroundColor = .accentColor
            result[attributedRange].font = .system(size: 15, weight: .medium)
            // Setting `.link` makes Text render this segment as a tappable
            // SwiftUI link — handled by the OpenURLAction above.
            if let url = URL(string: "raven://user/\(username)") {
                result[attributedRange].link = url
            }
        }

        return result
    }
}


/// Tiny sheet that resolves a `@username` to a userId then presents the
/// existing `UserProfileView`. We do the lookup here (not in the picker)
/// so the cost is paid only when the user actually taps a mention.
private struct MentionedUserProfileSheet: View {
    let username: String
    @State private var resolvedUserId: String? = nil
    @State private var loadFailed = false
    @Environment(\.dismiss) private var dismiss

    private struct UserHit: Decodable { let id: String; let username: String }

    var body: some View {
        Group {
            if let uid = resolvedUserId {
                NavigationStack {
                    UserProfileView(userId: uid)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Close") { dismiss() }
                            }
                        }
                }
            } else if loadFailed {
                VStack(spacing: 12) {
                    Image(systemName: "person.fill.questionmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Could not find @\(username)")
                        .font(.headline)
                    Button("Close") { dismiss() }
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            } else {
                ProgressView("Loading @\(username)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemBackground))
            }
        }
        .task {
            do {
                let q = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
                let hits: [UserHit] = try await NetworkService.shared.get(path: "/api/users/search?q=\(q)")
                // Prefer EXACT case-insensitive match; fall back to first hit
                if let exact = hits.first(where: { $0.username.lowercased() == username.lowercased() }) {
                    resolvedUserId = exact.id
                } else if let first = hits.first {
                    resolvedUserId = first.id
                } else {
                    loadFailed = true
                }
            } catch {
                loadFailed = true
            }
        }
    }
}
