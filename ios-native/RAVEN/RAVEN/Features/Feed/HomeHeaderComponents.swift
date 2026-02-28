import SwiftUI

// MARK: - Home Header Avatar Button
/// Circular avatar button for the Home header with Instagram-style "My Story" ring
/// - Shows ring indicator if user has active story
/// - Shows "+" button if no story  
/// - Tapping opens own story viewer (if exists) or profile (if no story)
struct HomeHeaderAvatarButton: View {
    // ✅ FIX: Access @Observable directly without @State wrapper
    private var authService: AuthService { AuthService.shared }
    // ❌ DISABLED: Story functionality
    // @ObservedObject private var storyService = StoryService.shared
    
    private var user: User? { authService.currentUser }
    // private var hasActiveStory: Bool { !storyService.myStories.isEmpty }
    private var hasActiveStory: Bool { false } // Stories disabled
    
    @State private var showStoryViewer = false
    @State private var showCamera = false
    
    var body: some View {
        // ❌ DISABLED: Just show avatar, no story functionality
        avatarView
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            // ✅ Force refresh when user changes
            .id(user?.avatarPath ?? "no-avatar")
        
        /* ❌ DISABLED: Story button functionality
        Button {
            Haptics.light()
            if hasActiveStory {
                // Show own story viewer
                showStoryViewer = true
            } else {
                // Open camera to add story
                showCamera = true
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                // Avatar with story ring
                avatarView
                    .overlay(
                        Circle()
                            .stroke(
                                hasActiveStory ?
                                    LinearGradient(
                                        colors: [.blue, .purple, .pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ) :
                                    LinearGradient(
                                        colors: [.gray.opacity(0.3)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                lineWidth: hasActiveStory ? 2.5 : 1
                            )
                            .frame(width: 38, height: 38)
                    )
                
                // "+" button when no story
                if !hasActiveStory {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .background(
                            Circle()
                                .fill(.blue)
                                .frame(width: 14, height: 14)
                        )
                        .offset(x: 2, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showStoryViewer) {
            if let user = user, !storyService.myStories.isEmpty {
                // Create StoryAuthor from current user
                let author = StoryAuthor(
                    authorId: user.id,
                    authorUsername: user.username ?? "Me",
                    authorAvatar: user.avatarPath,
                    hasUnseen: false, // Own stories are always "seen"
                    storyCount: storyService.myStories.count,
                    latestStoryId: storyService.myStories.first?.id ?? "",
                    latestCreatedAt: storyService.myStories.first?.createdAt ?? Date()
                )
                StoryViewerView(author: author) { _ in
                    showStoryViewer = false
                }
            }
        }

        .fullScreenCover(isPresented: $showCamera) {
            StoryCameraView()
        }
        .onAppear {
            // Fetch my stories on appear
            Task {
                await storyService.fetchMyStories()
            }
        }
        */
    }
    
    private var avatarView: some View {
        Group {
            if let path = user?.avatarPath, let url = URL(string: path) {
                // ✅ Add cache-busting query param based on path hash
                let cacheBustURL = URL(string: path + (path.contains("?") ? "&" : "?") + "v=\(path.hashValue)")
                AsyncImage(url: cacheBustURL ?? url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        initialsView
                    @unknown default:
                        initialsView
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            } else {
                initialsView
            }
        }
    }
    
    private var initialsView: some View {
        Text(user?.initials ?? "?")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 36, height: 36)
            .background(Color(.systemGray5))
            .clipShape(Circle())
    }
}


// MARK: - Home Header Bell Button
/// Bell icon button for the Home header with unread badge
struct HomeHeaderBellButton: View {
    // Use @ObservedObject for proper observation of unreadCount changes
    @ObservedObject private var pipeline = NotificationPipeline.shared
    
    var body: some View {
        Button {
            Haptics.light()
            DeepLinkRouter.shared.navigate(to: .notifications)
        } label: {
            ZStack(alignment: .topTrailing) {
                // Clean bell icon centered in glass circle
                Image(systemName: pipeline.unreadCount > 0 ? "bell.badge.fill" : "bell.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(pipeline.unreadCount > 0 ? .orange : .primary)
                    .frame(width: 44, height: 44)
                
                // Badge count
                if pipeline.unreadCount > 0 {
                    Text(pipeline.unreadCount > 99 ? "99+" : "\(pipeline.unreadCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .offset(x: 6, y: -4)
                }
            }
            // FIX: Make entire 44x44 area tappable (prevents touch pass-through on glass backgrounds)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews
#Preview("Home Header Avatar") {
    HStack {
        HomeHeaderAvatarButton()
        Spacer()
        Text("Home")
            .font(.headline)
        Spacer()
        HomeHeaderBellButton()
    }
    .padding()
    .background(Color(.systemBackground))
}
