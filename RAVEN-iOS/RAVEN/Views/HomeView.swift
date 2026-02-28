// RAVEN - Home View (Social Feed)
// Converted from Flutter home_tabs.dart

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0
    @State private var showCompose = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab Switcher
                HStack(spacing: 0) {
                    tabButton("Local", index: 0)
                    tabButton("Following", index: 1)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                // Feed
                TabView(selection: $selectedTab) {
                    feedList
                        .tag(0)
                    
                    feedList
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showCompose) {
                ComposePostView()
            }
            .onAppear {
                Task {
                    await appState.loadFeed()
                }
            }
        }
    }
    
    @ViewBuilder
    func tabButton(_ title: String, index: Int) -> some View {
        Button {
            withAnimation { selectedTab = index }
        } label: {
            VStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(selectedTab == index ? .primary : .secondary)
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(selectedTab == index ? Color.ravenPrimary : .clear)
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if appState.isLoadingFeed && appState.feedPosts.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        PostPlaceholder()
                    }
                } else if appState.feedPosts.isEmpty {
                    ContentUnavailableView(
                        "No Posts Yet",
                        systemImage: "text.bubble",
                        description: Text("Be the first to post something!")
                    )
                    .padding(.top, 60)
                } else {
                    ForEach(appState.feedPosts) { post in
                        NavigationLink {
                            PostDetailView(post: post)
                        } label: {
                            PostCard(post: post, onLike: {
                                Task {
                                    await appState.toggleLike(post: post)
                                }
                            })
                        }
                        .buttonStyle(.plain)
                        
                        Divider()
                    }
                }
            }
        }
        .refreshable {
            await appState.loadFeed()
        }
    }
}

// MARK: - Post Card
struct PostCard: View {
    let post: Post
    var onLike: (() -> Void)?
    var onComment: (() -> Void)?
    var onRepost: (() -> Void)?
    
    @EnvironmentObject var appState: AppState
    @State private var showLikeAnimation = false
    @State private var showLikedBySheet = false
    @State private var showCommentedBySheet = false
    
    // Computed contact avatars for like/comment stacks
    private var likeContactAvatars: [ContactAffinityStore.ContactAvatar] {
        ContactAffinityStore.shared.topContacts(
            from: post.likePreviewUserIds,
            contacts: appState.contacts
        )
    }
    
    private var commentContactAvatars: [ContactAffinityStore.ContactAvatar] {
        ContactAffinityStore.shared.topContacts(
            from: post.commentPreviewUserIds,
            contacts: appState.contacts
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                AvatarView(url: post.authorAvatarUrl, name: post.authorName, size: 40)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.authorName)
                        .font(.subheadline.bold())
                    
                    HStack(spacing: 4) {
                        Text("@\(post.authorUsername)")
                        Text("·")
                        Text(post.createdAt.timeAgo)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button {
                    // More options
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                }
            }
            
            // Content
            Text(post.content)
                .font(.body)
                .multilineTextAlignment(.leading)
            
            // Media
            if !post.mediaUrls.isEmpty {
                mediaGrid
            }
            
            // Hashtags
            if !post.hashtags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(post.hashtags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption)
                            .foregroundColor(.ravenPrimary)
                    }
                }
            }
            
            // Actions
            HStack(spacing: 0) {
                // Like button with avatar stack
                actionWithAvatars(
                    icon: post.isLiked ? "heart.fill" : "heart",
                    count: post.likesCount,
                    color: post.isLiked ? .red : .secondary,
                    avatars: likeContactAvatars,
                    action: {
                        Haptics.impact(.light)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                            showLikeAnimation = true
                        }
                        onLike?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showLikeAnimation = false
                        }
                    },
                    onAvatarTap: { showLikedBySheet = true }
                )
                
                // Comment button with avatar stack
                actionWithAvatars(
                    icon: "bubble.right",
                    count: post.commentsCount,
                    color: .secondary,
                    avatars: commentContactAvatars,
                    action: { onComment?() },
                    onAvatarTap: { showCommentedBySheet = true }
                )
                
                actionButton(icon: post.isReposted ? "arrow.2.squarepath" : "arrow.2.squarepath", count: post.repostsCount, color: post.isReposted ? .green : .secondary) {
                    onRepost?()
                }
                
                Spacer()
                
                Button {
                    // Share
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.secondary)
                }
            }
            .font(.subheadline)
        }
        .padding()
        .scaleEffect(showLikeAnimation ? 1.02 : 1.0)
        .sheet(isPresented: $showLikedBySheet) {
            InteractionUsersSheet(
                title: "Liked by",
                previewUserIds: post.likePreviewUserIds,
                contacts: appState.contacts
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showCommentedBySheet) {
            InteractionUsersSheet(
                title: "Commented by",
                previewUserIds: post.commentPreviewUserIds,
                contacts: appState.contacts
            )
            .presentationDetents([.medium])
        }
    }
    
    @ViewBuilder
    var mediaGrid: some View {
        let urls = post.mediaUrls.prefix(4)
        
        if urls.count == 1, let first = urls.first {
            AsyncImage(url: URL(string: first)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxHeight: 200)
                    .clipped()
                    .cornerRadius(12)
            } placeholder: {
                Rectangle()
                    .fill(Color(UIColor.systemGray5))
                    .frame(height: 200)
                    .cornerRadius(12)
            }
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                    AsyncImage(url: URL(string: url)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 100)
                            .clipped()
                    } placeholder: {
                        Rectangle()
                            .fill(Color(UIColor.systemGray5))
                            .frame(height: 100)
                    }
                }
            }
            .cornerRadius(12)
        }
    }
    
    /// Action button with optional contact avatar stack.
    @ViewBuilder
    func actionWithAvatars(
        icon: String,
        count: Int,
        color: Color,
        avatars: [ContactAffinityStore.ContactAvatar],
        action: @escaping () -> Void,
        onAvatarTap: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                    if count > 0 {
                        Text(count.abbreviated)
                    }
                }
                .foregroundColor(color)
            }
            
            if !avatars.isEmpty {
                ContactAvatarStack(avatars: avatars, size: 17, onTap: onAvatarTap)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func actionButton(icon: String, count: Int, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                if count > 0 {
                    Text(count.abbreviated)
                }
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Interaction Users Sheet (Liked by / Commented by)
struct InteractionUsersSheet: View {
    let title: String
    let previewUserIds: [String]
    let contacts: [Contact]
    
    @Environment(\.dismiss) private var dismiss
    
    private var contactsInList: [Contact] {
        let contactUserIds = Set(contacts.map { $0.userId })
        let matchedIds = previewUserIds.filter { contactUserIds.contains($0) }
        return matchedIds.compactMap { uid in contacts.first { $0.userId == uid } }
    }
    
    private var othersCount: Int {
        max(0, previewUserIds.count - contactsInList.count)
    }
    
    var body: some View {
        NavigationStack {
            List {
                if !contactsInList.isEmpty {
                    Section("Your Contacts") {
                        ForEach(contactsInList, id: \.userId) { contact in
                            HStack(spacing: 12) {
                                AvatarView(url: contact.avatarUrl, name: contact.effectiveName, size: 36)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.effectiveName)
                                        .font(.subheadline.bold())
                                    Text("@\(contact.username)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                
                if othersCount > 0 {
                    Section {
                        HStack {
                            Image(systemName: "person.2")
                                .foregroundColor(.secondary)
                            Text("and \(othersCount) other\(othersCount == 1 ? "" : "s")")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if contactsInList.isEmpty && othersCount == 0 {
                    ContentUnavailableView(
                        "No One Yet",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("No interactions to show")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Post Placeholder
struct PostPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(UIColor.systemGray5))
                    .frame(width: 40, height: 40)
                
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(UIColor.systemGray5))
                        .frame(width: 100, height: 12)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(UIColor.systemGray5))
                        .frame(width: 60, height: 10)
                }
                
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.systemGray5))
                    .frame(height: 12)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.systemGray5))
                    .frame(width: 200, height: 12)
            }
        }
        .padding()
        .shimmer()
    }
}

// MARK: - Compose Post View
struct ComposePostView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var content = ""
    @State private var isPosting = false
    
    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $content)
                    .font(.body)
                    .padding()
                
                Spacer()
            }
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        postContent()
                    } label: {
                        if isPosting {
                            ProgressView()
                        } else {
                            Text("Post")
                                .bold()
                        }
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting)
                }
            }
        }
    }
    
    func postContent() {
        isPosting = true
        
        Task {
            do {
                let _ = try await APIService.shared.createPost(content: content)
                await appState.loadFeed()
                dismiss()
            } catch {
                isPosting = false
            }
        }
    }
}

// MARK: - Post Detail View
struct PostDetailView: View {
    let post: Post
    @State private var comments: [Comment] = []
    @State private var newComment = ""
    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PostCard(post: post)
                
                Divider()
                
                // Comments
                if isLoading {
                    ProgressView()
                        .padding()
                } else {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment)
                        Divider()
                    }
                }
            }
        }
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Add a comment...", text: $newComment)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(20)
                
                Button {
                    sendComment()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(.ravenPrimary)
                }
                .disabled(newComment.isEmpty)
            }
            .padding()
            .background(Color(UIColor.systemBackground))
        }
        .onAppear {
            loadComments()
        }
    }
    
    func loadComments() {
        Task {
            comments = (try? await APIService.shared.getComments(postId: post.id)) ?? []
            isLoading = false
        }
    }
    
    func sendComment() {
        let text = newComment
        newComment = ""
        
        Task {
            if let comment = try? await APIService.shared.addComment(postId: post.id, content: text) {
                comments.insert(comment, at: 0)
            }
        }
    }
}

// MARK: - Comment Row
struct CommentRow: View {
    let comment: Comment
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.authorAvatarUrl, name: comment.authorName, size: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(comment.authorName)
                        .font(.subheadline.bold())
                    Text("@\(comment.authorUsername)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(comment.createdAt.timeAgo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(comment.content)
                    .font(.subheadline)
            }
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Flow Layout
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, proposal: proposal)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, proposal: proposal)
        
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }
    
    private func layout(subviews: Subviews, proposal: ProposedViewSize) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        
        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
