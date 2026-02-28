import SwiftUI

/// Vertical scrolling list of post search results with pagination
struct SearchablePostsList: View {
    let posts: [Post]
    let isLoading: Bool
    let errorMessage: String?
    let onLoadMore: (Post) -> Void
    let currentUserId: String
    
    @ObservedObject var feedStore: FeedStore
    @State private var selectedHashtag: String? = nil
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isLoading && posts.isEmpty {
                    // Initial loading state
                    ForEach(0..<3, id: \.self) { _ in
                        PostSkeletonView()
                        Divider()
                    }
                } else if posts.isEmpty {
                    emptyStateView
                } else {
                    // Posts list
                    ForEach(posts) { post in
                        PostCard(
                            post: post,
                            feedStore: feedStore,
                            currentUserId: currentUserId,
                            onOpenComments: {
                                DeepLinkRouter.shared.navigate(to: .post(postId: post.id))
                            },
                            onAvatarTap: {
                                DeepLinkRouter.shared.navigate(to: .profile(userId: post.authorId))
                            },
                            onHashtagTap: { tag in selectedHashtag = tag }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            DeepLinkRouter.shared.navigate(to: .post(postId: post.id))
                        }
                        .onAppear {
                            onLoadMore(post)
                        }
                        
                        Divider()
                    }
                    
                    // Load more indicator
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding()
                            Spacer()
                        }
                    }
                }
            }
        }
        .onTapGesture { hideKeyboard() }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: Binding(
            get: { selectedHashtag != nil },
            set: { if !$0 { selectedHashtag = nil } }
        )) {
            if let tag = selectedHashtag {
                NavigationStack {
                    HashtagView(hashtag: tag)
                }
            }
        }
    }
    
    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            
            Text("No posts found")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("Try a different search term")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .padding(.top, 32)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NavigationStack {
        SearchablePostsList(
            posts: [],
            isLoading: true,
            errorMessage: nil,
            onLoadMore: { _ in },
            currentUserId: "preview",
            feedStore: FeedStore.shared
        )
    }
}
