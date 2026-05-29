// PostCardView — floating post card.
//
// Each post is its own raised card with a soft shadow + hover-lift, so
// the desktop feed reads as discrete objects rather than a tightly-packed
// list. Animation: fade + slide-up on first appearance, with a small
// stagger driven by `index`. Repost is intentionally absent.

import SwiftUI
import AVKit

struct PostCardView: View {
    let post: Post
    let index: Int
    var onLikeChanged: (Int, Bool) -> Void = { _, _ in }
    /// Optional callback fired after the post is successfully deleted on
    /// the server, so the surrounding feed can drop it from its array
    /// without a full refetch.
    var onDeleted: () -> Void = { }
    /// Fired with the new content after the user edits their own post.
    var onEdited: (String) -> Void = { _ in }

    @EnvironmentObject var router: ShellRouter
    @EnvironmentObject var auth: AuthService

    @State private var hover = false
    @State private var appeared = false
    @State private var liking = false
    @State private var showComments = false
    @State private var deleting = false
    @State private var showEdit = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: { router.presentedProfileUserId = post.authorId }) {
                AvatarView(
                    letter: String(post.authorUsername.prefix(1)).uppercased(),
                    size: 44,
                    urlString: post.authorAvatar
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button(action: { router.presentedProfileUserId = post.authorId }) {
                        HStack(spacing: 6) {
                            Text(post.authorUsername)
                                .font(.system(size: 15, weight: .bold))
                            Text("@\(post.authorUsername)")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(relativeTime(post.timestamp))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        if post.authorId == auth.currentUser?.id {
                            Button {
                                showEdit = true
                            } label: {
                                Label("Edit post", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                Task { await deletePost() }
                            } label: {
                                Label("Delete post", systemImage: "trash")
                            }
                        }
                        Button {
                            #if canImport(AppKit)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(post.content, forType: .string)
                            #endif
                        } label: {
                            Label("Copy text", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: deleting ? "ellipsis.circle.fill" : "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if !post.content.isEmpty {
                    Text(post.content)
                        .font(.system(size: 15))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Image / video media. Renders inline so the user sees the
                // actual content of image-typed posts (`post_type == "image"`)
                // and voice posts get a play affordance.
                let media = post.displayableMedia
                if !media.isEmpty {
                    PostMediaGrid(items: media)
                        .padding(.top, 4)
                }
                if post.postType == "voice", let voiceURL = post.voiceUrl, !voiceURL.isEmpty {
                    VoicePlayerRow(url: voiceURL)
                        .padding(.top, 4)
                }

                HStack(spacing: 28) {
                    PostAction(icon: "bubble.left", count: post.comments,
                               hover: RavenColors.primary,
                               action: { showComments = true })
                    PostAction(icon: post.isLiked ? "heart.fill" : "heart",
                               count: post.likes,
                               active: post.isLiked,
                               hover: RavenColors.accent,
                               action: { Task { await toggleLike() } })
                    PostAction(icon: "eye", count: post.viewCount,
                               hover: RavenColors.logoStart,
                               action: {})
                    Spacer()
                    Image(systemName: "bookmark")
                        .foregroundStyle(.secondary)
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .sheet(isPresented: $showComments) {
            CommentsSheet(post: post)
        }
        .sheet(isPresented: $showEdit) {
            EditPostSheet(postId: post.id, originalContent: post.content) { newContent in
                onEdited(newContent)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.085))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(hover ? 0.55 : 0.35),
                        radius: hover ? 18 : 10,
                        x: 0,
                        y: hover ? 8 : 4)
        )
        .offset(y: hover ? -2 : 0)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
        .animation(.easeOut(duration: 0.16), value: hover)
        .onHover { hover = $0 }
        .task {
            try? await Task.sleep(nanoseconds: UInt64(min(index, 12)) * 30_000_000)
            withAnimation(.easeOut(duration: 0.32)) { appeared = true }
        }
    }

    private func relativeTime(_ t: Date) -> String {
        let diff = Date().timeIntervalSince(t)
        if diff < 60 { return "\(Int(diff))s" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        if diff < 604800 { return "\(Int(diff / 86400))d" }
        let f = DateFormatter()
        f.dateStyle = .short
        return f.string(from: t)
    }

    @MainActor
    private func deletePost() async {
        deleting = true
        defer { deleting = false }
        do {
            try await NetworkService.shared.deletePost(postId: post.id)
            onDeleted()
        } catch {
            print("🗑️ [post] delete failed: \(error)")
        }
    }

    @MainActor
    private func toggleLike() async {
        guard !liking else { return }
        liking = true
        defer { liking = false }
        do {
            let resp = try await NetworkService.shared.toggleLike(postId: post.id)
            onLikeChanged(resp.likes, resp.isLiked)
        } catch {
            print("❤️ [post] like failed: \(error)")
        }
    }
}

private struct PostAction: View {
    let icon: String
    let count: Int
    var active: Bool = false
    let hover: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(active || isHovering ? hover : .secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 13))
                        .foregroundStyle(active || isHovering ? hover : .secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Comments sheet

struct CommentsSheet: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthService
    @State private var comments: [CommentDTO] = []
    @State private var loading = true
    @State private var input = ""
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Comments").font(.title3.weight(.bold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if loading {
                        ProgressView().padding(40)
                    } else if comments.isEmpty {
                        Text("No comments yet. Be the first.")
                            .foregroundStyle(.secondary)
                            .padding(40)
                    } else {
                        ForEach(comments) { c in
                            CommentRow(
                                comment: c,
                                canDelete: canDelete(c),
                                onDeleted: {
                                    comments.removeAll { $0.id == c.id }
                                }
                            )
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)

            Divider()

            VStack(spacing: 8) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    TextField("Write a comment…", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(posting)
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(posting ? "…" : "Send")
                            .font(.system(size: 13, weight: .heavy))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(LinearGradient.ravenBrand)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(posting || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .task { await load() }
    }

    /// A comment is deletable by its author OR the owner of the post.
    private func canDelete(_ c: CommentDTO) -> Bool {
        guard let me = auth.currentUser?.id else { return false }
        return c.authorId == me || post.authorId == me
    }

    @MainActor
    private func load() async {
        loading = true
        do {
            comments = try await NetworkService.shared.comments(forPost: post.id)
        } catch {
            print("💬 [comments] load failed: \(error)")
        }
        loading = false
    }

    @MainActor
    private func submit() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        posting = true
        error = nil
        do {
            let new = try await NetworkService.shared.createComment(
                postId: post.id, content: trimmed)
            comments.insert(new, at: 0)
            input = ""
        } catch {
            self.error = "Couldn't post comment."
            print("💬 [comments] send failed: \(error)")
        }
        posting = false
    }
}

private struct CommentRow: View {
    @State var comment: CommentDTO
    let canDelete: Bool
    let onDeleted: () -> Void
    @State private var voting = false
    @State private var deleting = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(
                letter: String(comment.authorName.prefix(1)).uppercased(),
                size: 32,
                urlString: comment.authorAvatar
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    if canDelete {
                        Menu {
                            Button(role: .destructive) {
                                Task { await deleteComment() }
                            } label: {
                                Label("Delete comment", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: deleting ? "ellipsis.circle.fill" : "ellipsis")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(deleting)
                    }
                }
                Text(comment.content)
                    .font(.system(size: 13))

                // Vote row: up / down arrows with score in between.
                HStack(spacing: 12) {
                    Button(action: { Task { await vote(+1) } }) {
                        Image(systemName: comment.myVote == 1 ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .foregroundStyle(comment.myVote == 1 ? RavenColors.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(voting)

                    Text("\(comment.score)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20)

                    Button(action: { Task { await vote(-1) } }) {
                        Image(systemName: comment.myVote == -1 ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(comment.myVote == -1 ? RavenColors.primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(voting)
                }
                .font(.system(size: 14))
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @MainActor
    private func vote(_ direction: Int) async {
        guard !voting else { return }
        // Toggle: tapping the same direction clears your vote.
        let target = comment.myVote == direction ? 0 : direction
        voting = true
        defer { voting = false }
        do {
            let resp = try await NetworkService.shared.voteComment(
                commentId: comment.id, vote: target)
            comment = comment.with(score: resp.score, myVote: resp.myVote)
        } catch {
            print("💬 [comment] vote failed: \(error)")
        }
    }

    @MainActor
    private func deleteComment() async {
        guard !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await NetworkService.shared.deleteComment(commentId: comment.id)
            onDeleted()
        } catch {
            print("💬 [comment] delete failed: \(error)")
        }
    }
}

private extension CommentDTO {
    /// Build a copy with a new `score` + `my_vote` after a vote returns.
    /// Cleaner than synthesizing a Codable round-trip just to flip two
    /// fields.
    func with(score newScore: Int, myVote newVote: Int) -> CommentDTO {
        CommentDTO(
            id: id,
            postId: postId,
            authorId: authorId,
            authorName: authorName,
            authorAvatar: authorAvatar,
            content: content,
            timestamp: timestamp,
            score: newScore,
            myVote: newVote
        )
    }
}

// MARK: - Post media

/// Inline media grid for post cards. Single image fills the card width,
/// 2 items show side-by-side, 3+ items lay out in a 2-column grid. Videos
/// show their thumbnail with a play overlay (taps eventually open a
/// player; for now they're a static preview).
struct PostMediaGrid: View {
    let items: [PostMedia]

    var body: some View {
        Group {
            switch items.count {
            case 0:
                EmptyView()
            case 1:
                MediaCell(item: items[0])
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 320)
            case 2:
                HStack(spacing: 4) {
                    MediaCell(item: items[0])
                    MediaCell(item: items[1])
                }
                .frame(height: 220)
            default:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 4),
                                    GridItem(.flexible(), spacing: 4)],
                          spacing: 4) {
                    ForEach(items.prefix(4)) { item in
                        MediaCell(item: item)
                            .frame(height: 150)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct MediaCell: View {
    let item: PostMedia
    @State private var showLightbox = false

    var body: some View {
        Button {
            // Videos open elsewhere later — for now always lightbox.
            showLightbox = true
        } label: {
            ZStack {
                let imageURL = URL(string: item.thumbnailUrl ?? item.url)
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ZStack {
                            Color.white.opacity(0.04)
                            ProgressView().tint(.white.opacity(0.5))
                        }
                    case .failure:
                        ZStack {
                            Color.white.opacity(0.04)
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    @unknown default:
                        Color.white.opacity(0.04)
                    }
                }

                if item.mediaType == "video" {
                    ZStack {
                        Circle().fill(.black.opacity(0.55)).frame(width: 56, height: 56)
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showLightbox) {
            ImageLightbox(url: item.url)
        }
    }
}

/// Voice-post player row. Thin player UI with a play/pause toggle backed
/// by a simple AVPlayer. No timeline scrubber yet — keep it minimal.
struct VoicePlayerRow: View {
    let url: String

    @State private var isPlaying = false
    @State private var player: AVPlayer?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(LinearGradient.ravenBrand))
            }
            .buttonStyle(.plain)

            // Static waveform-ish placeholder bars — purely decorative.
            HStack(spacing: 2) {
                ForEach(0..<28, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 2, height: barHeight(i))
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func barHeight(_ idx: Int) -> CGFloat {
        let pattern: [CGFloat] = [10, 18, 24, 14, 8, 22, 28, 16, 10]
        return pattern[idx % pattern.count]
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        if player == nil, let u = URL(string: url) {
            player = AVPlayer(url: u)
        }
        player?.play()
        isPlaying = true
    }
}

// MARK: - Edit post

struct EditPostSheet: View {
    let postId: String
    let originalContent: String
    let onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var saving = false
    @State private var error: String?

    init(postId: String, originalContent: String,
         onSaved: @escaping (String) -> Void) {
        self.postId = postId
        self.originalContent = originalContent
        self.onSaved = onSaved
        _draft = State(initialValue: originalContent)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit post").font(.title3.weight(.bold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()

            TextEditor(text: $draft)
                .font(.system(size: 14))
                .padding(12)
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.04))

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    Text(saving ? "Saving…" : "Save")
                        .font(.system(size: 13, weight: .heavy))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(LinearGradient.ravenBrand)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(saving || trimmed.isEmpty || trimmed == originalContent)
            }
            .padding(20)
        }
        .frame(width: 520, height: 320)
    }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            _ = try await NetworkService.shared.editPost(
                postId: postId, content: trimmed)
            onSaved(trimmed)
            dismiss()
        } catch {
            self.error = "Couldn't save edits."
            print("✏️ [post] edit failed: \(error)")
        }
    }
}
