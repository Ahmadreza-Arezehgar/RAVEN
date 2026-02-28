// RAVEN - Discovery View
// Converted from Flutter discovery/search screens

import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedCategory = "Trending"
    @State private var searchResults: [User] = []
    @State private var trendingTopics: [String] = []
    @State private var suggestedUsers: [SuggestedUserItem] = []
    @State private var isSearching = false
    
    let categories = ["Trending", "People", "Posts", "Nearby"]
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                SearchBar(text: $searchText, placeholder: "Search RAVEN...")
                    .padding()
                    .onChange(of: searchText) { _, newValue in
                        performSearch(newValue)
                    }
                
                if searchText.isEmpty {
                    // Category selector
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(categories, id: \.self) { category in
                                categoryChip(category)
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    // Content based on selected category
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            switch selectedCategory {
                            case "Trending":
                                trendingSection
                            case "People":
                                peopleSection
                            case "Posts":
                                postsSection
                            case "Nearby":
                                nearbySection
                            default:
                                EmptyView()
                            }
                        }
                        .padding()
                    }
                } else {
                    // Search results
                    searchResultsSection
                }
            }
            .navigationTitle("Discover")
            .onAppear {
                loadDiscoveryContent()
            }
        }
    }
    
    @ViewBuilder
    func categoryChip(_ title: String) -> some View {
        Button {
            withAnimation { selectedCategory = title }
        } label: {
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(selectedCategory == title ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    selectedCategory == title ? Color.ravenPrimary : Color(UIColor.systemGray5)
                )
                .cornerRadius(20)
        }
    }
    
    // MARK: - Trending Section
    var trendingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trending Topics")
                .font(.headline)
            
            if trendingTopics.isEmpty {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonView(width: 150, height: 20)
                }
            } else {
                ForEach(Array(trendingTopics.enumerated()), id: \.offset) { index, topic in
                    NavigationLink {
                        HashtagFeedView(hashtag: topic)
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading) {
                                Text("#\(topic)")
                                    .font(.subheadline.bold())
                                
                                Text("\(Int.random(in: 100...5000)) posts")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - People Section
    var peopleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Suggested for You")
                .font(.headline)
            
            if suggestedUsers.isEmpty {
                ForEach(0..<5, id: \.self) { _ in
                    HStack {
                        SkeletonView(width: 44, height: 44, cornerRadius: 22)
                        VStack(alignment: .leading) {
                            SkeletonView(width: 100, height: 14)
                            SkeletonView(width: 60, height: 12)
                        }
                        Spacer()
                    }
                }
            } else {
                ForEach(suggestedUsers) { user in
                    HStack(spacing: 12) {
                        AvatarView(url: user.avatarUrl, name: user.displayName, size: 44)
                        
                        VStack(alignment: .leading) {
                            Text(user.displayName)
                                .font(.subheadline.bold())
                            Text("@\(user.username)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if !user.reason.isEmpty {
                                Text(user.reason)
                                    .font(.caption2)
                                    .foregroundColor(.ravenPrimary)
                            }
                        }
                        
                        Spacer()
                        
                        Button("Follow") {
                            // Follow user
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.ravenPrimary)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    // MARK: - Posts Section
    var postsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Popular Posts")
                .font(.headline)
            
            // Sample posts would go here
            ContentUnavailableView("No Popular Posts", systemImage: "text.bubble", description: Text("Check back later"))
        }
    }
    
    // MARK: - Nearby Section
    var nearbySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("People Nearby")
                    .font(.headline)
                
                Spacer()
                
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.ravenPrimary)
            }
            
            // Nearby users via mesh
            ContentUnavailableView(
                "Enable Mesh",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Turn on mesh networking to discover nearby users")
            )
        }
    }
    
    // MARK: - Search Results
    var searchResultsSection: some View {
        Group {
            if isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty && !searchText.isEmpty {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("Try a different search term"))
            } else {
                List(searchResults) { user in
                    NavigationLink {
                        ProfileView(userId: user.id)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(url: user.avatarUrl, name: user.displayName, size: 44)
                            
                            VStack(alignment: .leading) {
                                Text(user.displayName)
                                    .font(.subheadline.bold())
                                Text("@\(user.username)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
    
    // MARK: - Data Loading
    func loadDiscoveryContent() {
        // Load trending topics
        trendingTopics = ["ios18", "swift", "mesh", "privacy", "tech"]
        
        // Load suggested users from discovery API
        Task {
            do {
                suggestedUsers = try await APIService.shared.getSuggestedUsers()
            } catch {
                print("❌ Failed to load suggested users: \(error)")
            }
        }
    }
    
    func performSearch(_ query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        
        Task {
            searchResults = await appState.searchUsers(query)
            isSearching = false
        }
    }
}

// MARK: - Hashtag Feed View
struct HashtagFeedView: View {
    let hashtag: String
    @State private var posts: [Post] = []
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(posts) { post in
                    PostCard(post: post)
                    Divider()
                }
            }
        }
        .navigationTitle("#\(hashtag)")
        .onAppear {
            loadPosts()
        }
    }
    
    func loadPosts() {
        // Load posts with hashtag
    }
}

// MARK: - Profile View
struct ProfileView: View {
    let userId: String
    @EnvironmentObject var appState: AppState
    @State private var user: User?
    @State private var posts: [Post] = []
    @State private var selectedTab = 0
    @State private var isFollowing = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                if let user = user {
                    profileHeader(user)
                } else {
                    ProgressView()
                        .frame(height: 200)
                }
                
                // Stats
                statsBar
                
                // Tab selector
                HStack(spacing: 0) {
                    tabButton("Posts", icon: "square.grid.2x2", index: 0)
                    tabButton("Replies", icon: "bubble.left", index: 1)
                    tabButton("Media", icon: "photo", index: 2)
                }
                .padding(.top)
                
                // Content
                LazyVStack(spacing: 0) {
                    ForEach(posts) { post in
                        PostCard(post: post)
                        Divider()
                    }
                }
            }
        }
        .navigationTitle("@\(user?.username ?? "")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                let isBlocked = appState.contacts.first(where: { $0.userId == userId })?.isBlocked == true
                
                Menu {
                    Button(role: isBlocked ? .cancel : .destructive) {
                        Task {
                            await appState.toggleBlockStatus(
                                userId: userId,
                                username: user?.username ?? "Unknown",
                                displayName: user?.displayName ?? "User",
                                avatarUrl: user?.avatarUrl,
                                isCurrentlyBlocked: isBlocked
                            )
                            if !isBlocked { posts = [] } // Immediately clear posts on block
                        }
                    } label: {
                        Label(isBlocked ? "Unblock User" : "Block User", systemImage: isBlocked ? "hand.raised.slash.fill" : "hand.raised.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            loadProfile()
        }
    }
    
    @ViewBuilder
    func profileHeader(_ user: User) -> some View {
        VStack(spacing: 16) {
            AvatarView(url: user.avatarUrl, name: user.displayName, size: 80)
            
            VStack(spacing: 4) {
                Text(user.displayName)
                    .font(.title2.bold())
                
                Text("@\(user.username)")
                    .foregroundColor(.secondary)
                
                if let bio = user.bio {
                    Text(bio)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            
            // Follow button
            Button {
                isFollowing.toggle()
            } label: {
                Text(isFollowing ? "Following" : "Follow")
                    .font(.headline)
                    .foregroundColor(isFollowing ? .primary : .white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 10)
                    .background(isFollowing ? Color(UIColor.systemGray5) : Color.ravenPrimary)
                    .cornerRadius(20)
            }
        }
        .padding()
    }
    
    var statsBar: some View {
        HStack {
            stat(value: 42, label: "Posts")
            Divider().frame(height: 30)
            stat(value: 1234, label: "Followers")
            Divider().frame(height: 30)
            stat(value: 567, label: "Following")
        }
        .padding()
        .glassBackground()
    }
    
    @ViewBuilder
    func stat(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.abbreviated)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button {
            withAnimation { selectedTab = index }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                
                Rectangle()
                    .fill(selectedTab == index ? Color.ravenPrimary : .clear)
                    .frame(height: 2)
            }
            .foregroundColor(selectedTab == index ? .ravenPrimary : .secondary)
            .frame(maxWidth: .infinity)
        }
    }
    
    func loadProfile() {
        Task {
            user = try? await APIService.shared.getUserById(userId)
        }
    }
}

#Preview {
    DiscoveryView()
        .environmentObject(AppState())
        .preferredColorScheme(.dark)
}
