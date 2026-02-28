import SwiftUI

// MARK: - Story Feed Card (BeReal-style)
/// Full-width story card that appears mixed in with posts in the feed
struct StoryFeedCard: View {
    let story: Story
    let onTap: () -> Void
    let onLike: () -> Void
    let onReply: () -> Void
    
    @State private var isLiked: Bool
    @State private var isLikeAnimating = false
    
    init(story: Story, onTap: @escaping () -> Void, onLike: @escaping () -> Void, onReply: @escaping () -> Void) {
        self.story = story
        self.onTap = onTap
        self.onLike = onLike
        self.onReply = onReply
        self._isLiked = State(initialValue: story.isLiked)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Header
            HStack(spacing: 12) {
                // Avatar
                AsyncImage(url: URL(string: story.authorAvatar ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.purple.opacity(0.5), .blue.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Text(String(story.authorUsername.prefix(1)).uppercased())
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                        )
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.purple, .pink, .orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                )
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(story.authorUsername)
                            .font(.system(size: 15, weight: .semibold))
                        
                        // Story badge
                        Text("Story")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                LinearGradient(
                                    colors: [.purple, .blue],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: Capsule()
                            )
                        
                        // Scope Badge (Friend/Local) - Liquid Glass
                        ScopeBadge(scope: story.audience, isSingleView: story.isSingleView)
                    }
                    
                    Text(story.createdAt.timeAgoString)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Expires indicator
                expiresIndicator
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // MARK: - Story Image (Full Width)
            Button {
                Haptics.light()
                onTap()
            } label: {
                GeometryReader { geo in
                    AsyncImage(url: URL(string: story.mediaUrl)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        case .failure:
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .overlay {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.secondary)
                                }
                        case .empty:
                            Rectangle()
                                .fill(Color.gray.opacity(0.1))
                                .overlay {
                                    ProgressView()
                                }
                        @unknown default:
                            Rectangle().fill(Color.gray.opacity(0.1))
                        }
                    }
                }
                .frame(height: 400)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            
            // MARK: - Action Bar
            HStack(spacing: 20) {
                // Like
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                        isLikeAnimating = true
                        isLiked.toggle()
                    }
                    Haptics.light()
                    onLike()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isLikeAnimating = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(isLiked ? .pink : .primary)
                            .scaleEffect(isLikeAnimating ? 1.3 : 1.0)
                    }
                }
                .buttonStyle(.plain)
                
                // Reply
                Button {
                    Haptics.light()
                    onReply()
                } label: {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // View count
                HStack(spacing: 4) {
                    Image(systemName: "eye")
                        .font(.system(size: 14))
                    Text("\(story.seenCount)")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
        .onAppear {
            // Start visibility timer for single-use tracking
            ContentConsumptionTracker.shared.startVisibilityTimer(
                contentId: story.id,
                contentType: .story
            )
        }
        .onDisappear {
            // When user scrolls past without viewing long enough, mark as skipped
            ContentConsumptionTracker.shared.markSkipped(
                contentId: story.id,
                contentType: .story
            )
        }


    }
    
    // MARK: - Expires Indicator
    private var expiresIndicator: some View {
        let remaining = story.expiresAt.timeIntervalSince(Date())
        let hours = Int(remaining / 3600)
        let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
        
        return HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 11))
            Text(hours > 0 ? "\(hours)h" : "\(minutes)m")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.orange.opacity(0.15), in: Capsule())
    }
}

// MARK: - Scope Badge (Liquid Glass)
/// Displays Friend/Local scope with optional single-view indicator
struct ScopeBadge: View {
    let scope: String  // "friends" or "local"
    var isSingleView: Bool = false
    
    private var displayText: String {
        scope == "friends" ? "Friend" : "Local"
    }
    
    private var icon: String {
        scope == "friends" ? "person.2.fill" : "location.fill"
    }
    
    private var badgeColor: Color {
        scope == "friends" ? .blue : .green
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            
            Text(displayText)
                .font(.system(size: 10, weight: .semibold))
            
            // Single-view indicator
            if isSingleView {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 8))
            }
        }
        .foregroundStyle(badgeColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(badgeColor.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Story Feed Section
/// Shows multiple stories from the same author or a single story
struct StoryFeedSection: View {
    let stories: [Story]
    @State private var selectedStory: Story?
    @State private var showViewer = false
    @State private var showReplySheet = false
    @State private var replyStory: Story?
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(stories) { story in
                StoryFeedCard(
                    story: story,
                    onTap: {
                        selectedStory = story
                        showViewer = true
                    },
                    onLike: {
                        Task {
                            try? await StoryService.shared.toggleLike(storyId: story.id)
                        }
                    },
                    onReply: {
                        replyStory = story
                        showReplySheet = true
                    }
                )
                
                Divider()
                    .padding(.vertical, 8)
            }
        }
        .fullScreenCover(isPresented: $showViewer) {
            if let story = selectedStory {
                StoryViewerView(
                    author: StoryAuthor(
                        authorId: story.authorId,
                        authorUsername: story.authorUsername,
                        authorAvatar: story.authorAvatar,
                        hasUnseen: !story.isSeen,
                        storyCount: 1,
                        latestStoryId: story.id,
                        latestCreatedAt: story.createdAt
                    )
                ) { _ in
                    showViewer = false
                }
            }
        }
        .sheet(isPresented: $showReplySheet) {
            if let story = replyStory {
                StoryReplySheet(story: story)
            }
        }
    }
}

// MARK: - Story Reply Sheet
struct StoryReplySheet: View {
    let story: Story
    @Environment(\.dismiss) private var dismiss
    @State private var replyText = ""
    @State private var isSending = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Story preview
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: story.mediaUrl)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.2))
                    }
                    .frame(width: 60, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replying to")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("@\(story.authorUsername)")
                            .font(.headline)
                    }
                    
                    Spacer()
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                // Reply input
                TextField("Send a message...", text: $replyText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .lineLimit(1...5)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        sendReply()
                    } label: {
                        if isSending {
                            ProgressView()
                        } else {
                            Text("Send")
                                .bold()
                        }
                    }
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    private func sendReply() {
        guard !replyText.isEmpty else { return }
        isSending = true
        
        Task {
            do {
                try await StoryService.shared.reply(storyId: story.id, content: replyText)
                Haptics.success()
                dismiss()
            } catch {
                Haptics.error()
                isSending = false
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ScrollView {
        VStack(spacing: 20) {
            StoryFeedCard(
                story: Story(
                    id: "1",
                    authorId: "u1",
                    authorUsername: "john_doe",
                    authorAvatar: nil,
                    mediaUrl: "https://picsum.photos/400/600",
                    mediaType: "image",
                    audience: "friends",
                    isSingleView: false,
                    createdAt: Date().addingTimeInterval(-3600),
                    expiresAt: Date().addingTimeInterval(20 * 3600),
                    seenCount: 24,
                    isSeen: false,
                    isLiked: false,
                    isOwn: false
                ),
                onTap: {},
                onLike: {},
                onReply: {}
            )
            
            // Local single-view story
            StoryFeedCard(
                story: Story(
                    id: "2",
                    authorId: "u2",
                    authorUsername: "jane_smith",
                    authorAvatar: nil,
                    mediaUrl: "https://picsum.photos/400/601",
                    mediaType: "image",
                    audience: "local",
                    isSingleView: true,
                    createdAt: Date().addingTimeInterval(-1800),
                    expiresAt: Date().addingTimeInterval(22 * 3600),
                    seenCount: 12,
                    isSeen: false,
                    isLiked: true,
                    isOwn: false
                ),
                onTap: {},
                onLike: {},
                onReply: {}
            )
        }
    }
}
