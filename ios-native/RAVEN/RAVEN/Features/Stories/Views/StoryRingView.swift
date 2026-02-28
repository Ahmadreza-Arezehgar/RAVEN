import SwiftUI

// MARK: - Notification Name for Story Updates
extension Notification.Name {
    static let storyCreated = Notification.Name("storyCreated")
}

// MARK: - Story Ring View
/// Horizontal scroll of story ring avatars for Home screen
struct StoryRingView: View {
    @StateObject private var storyService = StoryService.shared
    @State private var storyAuthors: [StoryAuthor] = []
    @State private var isLoading = true
    @State private var selectedAuthor: StoryAuthor?
    @State private var showViewer = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                // Skeleton loading
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(0..<5, id: \.self) { _ in
                            skeletonRing
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else if storyAuthors.isEmpty {
                // No stories - hide completely
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(storyAuthors) { author in
                            StoryRingItem(author: author) {
                                selectedAuthor = author
                                showViewer = true
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .onAppear {
            loadStories()
        }
        // ✅ Listen for story creation notification to refresh
        .onReceive(NotificationCenter.default.publisher(for: .storyCreated)) { _ in
            #if DEBUG
            print("📸 [StoryRingView] Received storyCreated notification, refreshing...")
            #endif
            loadStories()
        }
        .fullScreenCover(isPresented: $showViewer) {
            if let author = selectedAuthor {
                StoryViewerView(author: author) { seenIds in
                    showViewer = false
                    // Refresh stories after viewing (server will filter seen)
                    if !seenIds.isEmpty {
                        loadStories()
                    }
                }
            }
        }
    }
    
    private var skeletonRing: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(.gray.opacity(0.2))
                .frame(width: 64, height: 64)
            
            RoundedRectangle(cornerRadius: 4)
                .fill(.gray.opacity(0.2))
                .frame(width: 48, height: 12)
        }
    }
    
    private func loadStories() {
        Task {
            do {
                let authors = try await StoryService.shared.getStoryFeed()
                #if DEBUG
                print("📸 [StoryRingView] Loaded \(authors.count) story authors")
                #endif
                storyAuthors = authors
                isLoading = false
            } catch {
                #if DEBUG
                print("❌ [StoryRingView] Failed to load stories: \(error)")
                #endif
                isLoading = false
            }
        }
    }
}

// MARK: - Story Ring Item
/// Individual story ring avatar with gradient border
struct StoryRingItem: View {
    let author: StoryAuthor
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Avatar with gradient ring
                ZStack {
                    // Gradient ring (unseen = colorful, seen = gray)
                    Circle()
                        .stroke(
                            author.hasUnseen
                                ? LinearGradient(
                                    colors: [.purple, .pink, .orange],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [.gray.opacity(0.4), .gray.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                            lineWidth: 3
                        )
                        .frame(width: 64, height: 64)
                    
                    // Avatar
                    AsyncImage(url: URL(string: author.authorAvatar ?? "")) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                Text(String(author.authorUsername.prefix(1)).uppercased())
                                    .font(.title3.weight(.medium))
                                    .foregroundStyle(.white)
                            )
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    
                    // Story count badge
                    if author.storyCount > 1 {
                        Text("\(author.storyCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue, in: Capsule())
                            .offset(x: 22, y: 22)
                    }
                }
                
                // Username
                Text(author.authorUsername)
                    .font(.caption)
                    .foregroundStyle(author.hasUnseen ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview
#Preview {
    VStack {
        StoryRingView()
        Spacer()
    }
    .background(Color(.systemBackground))
}
