import SwiftUI

/// View to display posts with a specific hashtag and allow following
struct HashtagView: View {
    let hashtag: String  // Without # prefix
    
    @State private var posts: [Post] = []
    @State private var isLoading = true
    @State private var isFollowing = false
    @State private var postCount = 0
    @State private var errorMessage: String?
    
    @Environment(\.dismiss) private var dismiss
    private let networkService = NetworkService.shared
    @State private var currentUserId: String = ""
    @State private var selectedHashtag: String? = nil
    
    var body: some View {
        // ✅ FIX Bug 1: Removed NavigationStack — this view is always embedded
        // in one (via MainShellView tab or .sheet wrapper in DiscoverView).
        // Nesting NavigationStacks causes freeze, missing back button & crashes.
        VStack(spacing: 0) {
            // Header with hashtag info
            hashtagHeader
                .padding()
                .background(.ultraThinMaterial)
            
            Divider()
            
            // Posts list
            if isLoading {
                Spacer()
                ProgressView()
                    .padding()
                Spacer()
            } else if posts.isEmpty {
                emptyState
            } else {
                postsList
            }
        }
        .navigationTitle("#\(hashtag)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .task {
            currentUserId = await KeychainService.shared.getUserId() ?? ""
            await loadHashtagData()
        }
    }
    
    // MARK: - Hashtag Header
    private var hashtagHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("#\(hashtag)")
                    .font(.title2.bold())
                
                Text("\(postCount) posts")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Follow/Unfollow button
            Button {
                Task {
                    await toggleFollow()
                }
            } label: {
                Text(isFollowing ? "Following" : "Follow")
                    .font(.subheadline.bold())
                    .foregroundColor(isFollowing ? .secondary : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(isFollowing ? Color.secondary.opacity(0.2) : Color.accentColor)
                    )
            }
        }
    }
    
    // MARK: - Posts List
    private var postsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(posts) { post in
                    NavigationLink(destination: PostDetailView(postId: post.id)) {
                        PostCard(
                            post: post,
                            feedStore: FeedStore.shared,
                            currentUserId: currentUserId,
                            onOpenComments: {},
                            onForward: {},
                            onHashtagTap: { tag in
                                selectedHashtag = tag
                            }
                        )
                    }
                    .buttonStyle(.plain)
                    
                    Divider()
                }
            }
        }
        .refreshable {
            await loadHashtagData()
        }
        // 🔴 FIX: استفاده از item به جای isPresented برای جلوگیری از کرش قطعی سیستم ناوبری SwiftUI
        .navigationDestination(item: $selectedHashtag) { tag in
            HashtagView(hashtag: tag)
        }
    }
    
    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "number")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            
            Text("No posts with #\(hashtag)")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Be the first to post with this hashtag!")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Data Loading
    private func loadHashtagData() async {
        isLoading = true
        
        let safeTag = hashtag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? hashtag
        
        do {
            // Fetch hashtag info
            struct HashtagInfo: Decodable {
                let hashtag: String
                let postCount: Int
                let isFollowing: Bool
            }
            
            let info: HashtagInfo = try await networkService.get(
                path: "/api/hashtags/info/\(safeTag)"
            )
            postCount = info.postCount
            isFollowing = info.isFollowing
            
            // Fetch posts
            let fetchedPosts: [Post] = try await networkService.get(
                path: "/api/hashtags/posts/\(safeTag)"
            )
            posts = fetchedPosts
            
        } catch {
            #if DEBUG
            print("❌ Failed to load hashtag data: \(error)")
            #endif
            errorMessage = "Failed to load posts"
        }
        
        isLoading = false
    }
    
    // MARK: - Follow/Unfollow
    private func toggleFollow() async {
        Haptics.light()
        
        let safeTag = hashtag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? hashtag
        
        do {
            struct FollowRequest: Encodable {
                let hashtag: String
            }
            struct FollowResponse: Decodable {
                let status: String
            }
            
            if isFollowing {
                // Unfollow
                let _: FollowResponse = try await networkService.delete(
                    path: "/api/hashtags/follow/\(safeTag)"
                )
                isFollowing = false
            } else {
                // Follow
                let _: FollowResponse = try await networkService.post(
                    path: "/api/hashtags/follow",
                    body: FollowRequest(hashtag: hashtag)
                )
                isFollowing = true
            }
            
            Haptics.success()
        } catch {
            #if DEBUG
            print("❌ Failed to toggle follow: \(error)")
            #endif
            Haptics.error()
        }
    }
}

// MARK: - Preview
#Preview {
    HashtagView(hashtag: "technology")
}
