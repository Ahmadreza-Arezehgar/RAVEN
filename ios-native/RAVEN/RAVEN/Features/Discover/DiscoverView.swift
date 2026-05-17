import SwiftUI

// MARK: - Navigation Route for Profile
struct ProfileRoute: Hashable {
    let userId: String
}

/// Discover screen with split layout: Suggestions (top) + Posts (bottom)
struct DiscoverView: View {
    @StateObject private var discoverStore = DiscoverStore()
    @ObservedObject private var feedStore = FeedStore.shared
    @State private var currentUserId: String = ""
    
    // ✅ FIX Bug 5: Removed isCapturing state — Discover is public content,
    // blocking it during AirPlay/screen mirror is a UX-breaking soft-brick.
    @State private var selectedHashtag: String? = nil
    @State private var selectedTab: DiscoverTab = .all
    @State private var showNearby = false
    @State private var showConcertMode = false
    
    enum DiscoverTab: String, CaseIterable {
        case all = "All"
        case users = "Users"
        case posts = "Posts"
    }
    
    var body: some View {
        // ✅ FIX Bug 5: Removed ZStack + privacy overlay — Discover is public content.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                // MARK: - Search Bar
                SearchBar(text: $discoverStore.query)
                    .onChange(of: discoverStore.query) { _, newValue in
                        discoverStore.onQueryChange(newValue)
                    }
                
                // MARK: - Tabs
                if !discoverStore.query.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(DiscoverTab.allCases, id: \.self) { tab in
                                Button {
                                    Haptics.selection()
                                    withAnimation(.spring(response: 0.3)) {
                                        selectedTab = tab
                                    }
                                } label: {
                                    Text(tab.rawValue)
                                        .font(.subheadline.weight(selectedTab == tab ? .semibold : .medium))
                                        .foregroundStyle(selectedTab == tab ? .white : .primary)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(
                                            Capsule()
                                                .fill(selectedTab == tab ? Color.blue : Color.gray.opacity(0.15))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
                
                // MARK: - Suggested Profiles (when no search)
                if discoverStore.query.isEmpty {
                    SuggestedForYouSection(
                        accounts: discoverStore.suggestedAccounts,
                        isLoading: discoverStore.isLoadingSuggestions,
                        sentRequestIds: discoverStore.sentRequestIds,
                        friendIds: discoverStore.friendIds,
                        onSendRequest: { userId in
                            Task { await discoverStore.sendFriendRequest(to: userId) }
                        },
                        onRemoveFriend: { userId in
                            Task { await discoverStore.removeFriend(userId) }
                        },
                        onShowMore: {
                            discoverStore.showAllSuggestionsSheet = true
                            Task { await discoverStore.loadAllSuggestions() }
                        }
                    )
                    .padding(.vertical, 12)
                    .transition(.identity)
                    
                    // MARK: - Mesh Feature Cards
                    if FeatureFlag.isEchoEnabled || FeatureFlag.isClubModeEnabled {
                        meshFeatureCards
                    }
                } else {
                    if selectedTab == .all || selectedTab == .users {
                        // MARK: - Search Results: Accounts Carousel
                        AccountsCarousel(
                            accounts: discoverStore.accounts,
                            isLoading: discoverStore.isLoadingAccounts,
                            errorMessage: discoverStore.accountsError
                        )
                        .frame(height: 180)
                        .transition(.identity)
                        
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 0.5)
                            .padding(.horizontal, 16)
                    }
                    
                    if selectedTab == .all || selectedTab == .posts {
                        // MARK: - Posts Section (content-sized, no fixed height)
                        postsSection
                            .transition(.identity)
                    }
                }
            }
            // ✅ FIX: Disable implicit animations on query-driven view swaps to prevent
            // UIKitNavigationBar layoutSubviews crash (NSInternalInconsistencyException)
            // when keyboard presentation animation conflicts with navigation bar layout.
            .animation(.none, value: discoverStore.query)
        }
        .onTapGesture { hideKeyboard() }
        .safeAreaPadding(.bottom, DS.bottomTabClearance)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        // ✅ FIX Bug 2: Add navigationDestination for in-tab post detail navigation
        .navigationDestination(for: String.self) { postId in
            PostDetailView(postId: postId)
        }
        .navigationDestination(for: ProfileRoute.self) { route in
            UserProfileView(userId: route.userId)
        }
        .task {
            currentUserId = await KeychainService.shared.getUserId() ?? ""
            // Note: Contacts sync is handled by MainShellView on launch (with 2s delay)
        }
        .sheet(isPresented: $discoverStore.showAllSuggestionsSheet) {
            SuggestedProfilesSheet(
                suggestions: discoverStore.allSuggestions,
                isLoading: discoverStore.isLoadingAllSuggestions,
                sentRequestIds: discoverStore.sentRequestIds,
                friendIds: discoverStore.friendIds,
                onSendRequest: { userId in
                    Task { await discoverStore.sendFriendRequest(to: userId) }
                },
                onRemoveFriend: { userId in
                    Task { await discoverStore.removeFriend(userId) }
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { selectedHashtag != nil },
            set: { if !$0 { selectedHashtag = nil } }
        )) {
            if let tag = selectedHashtag {
                // ✅ FIX Bug 1: Wrap in NavigationStack only at sheet root
                NavigationStack {
                    HashtagView(hashtag: tag)
                }
            }
        }
        .sheet(isPresented: $showNearby) {
            NearbyPeopleSheet { userId in
                // Open chat with this user. Routes via DeepLinkRouter so the
                // existing 1:1 chat flow handles persistence + outbox.
                DeepLinkRouter.shared.route(to: .chat(roomId: userId))
            }
        }
        .sheet(isPresented: $showConcertMode) {
            ConcertModeSheet { groupId in
                // Drop the user into the venue group chat
                DeepLinkRouter.shared.route(to: .chat(roomId: groupId))
            }
        }

    }
    
    // MARK: - Posts Section (inlined to avoid nested ScrollView)
    @ViewBuilder
    private var postsSection: some View {
        LazyVStack(spacing: 0) {
            if discoverStore.isLoadingPosts && discoverStore.posts.isEmpty {
                // Initial loading shimmer
                ForEach(0..<3, id: \.self) { _ in
                    PostSkeletonView()
                    Divider()
                }
            } else if discoverStore.posts.isEmpty {
                // Empty state — content-sized, no maxHeight infinity
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
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            } else {
                // ✅ FIX Bug 2: Use NavigationLink instead of DeepLinkRouter
                // so posts open within the Discover tab's NavigationStack.
                ForEach(discoverStore.posts) { post in
                    PostCard(
                        post: post,
                        feedStore: feedStore,
                        currentUserId: currentUserId,
                        onOpenComments: {},
                        onAvatarTap: {},
                        onHashtagTap: { tag in selectedHashtag = tag }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        DeepLinkRouter.shared.navigate(to: .post(postId: post.id))
                    }
                    .onAppear {
                        discoverStore.loadMorePostsIfNeeded(currentPost: post)
                    }
                    
                    Divider()
                }
                
                // Load more indicator
                if discoverStore.isLoadingPosts {
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
    
    // MARK: - Mesh Feature Cards
    
    @ViewBuilder
    private var meshFeatureCards: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.purple)
                    .font(.subheadline)
                Text("Mesh Features")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // 🎤 Concert Mode — auto-group everyone in a venue.
                    // (Inner horizontal ScrollView claims the gesture below
                    // so panning these cards doesn't switch root tabs.)
                    Button {
                        Haptics.medium()
                        showConcertMode = true
                    } label: {
                        MeshFeatureCard(
                            icon: "music.mic",
                            title: "Concert Mode",
                            subtitle: "Group everyone here",
                            gradient: [.pink, .orange]
                        )
                    }
                    .buttonStyle(.plain)

                    // 🌐 People Nearby — opens a sheet listing every userId
                    // currently learned via BLE mesh, resolved to profiles.
                    Button {
                        Haptics.light()
                        showNearby = true
                    } label: {
                        MeshFeatureCard(
                            icon: "person.2.wave.2.fill",
                            title: "People Nearby",
                            subtitle: "Discover via mesh",
                            gradient: [.green, .mint]
                        )
                    }
                    .buttonStyle(.plain)

                    // Unified Mesh Features (Swipe between Echo / Club / Vault)
                    NavigationLink {
                        MeshFeaturesContainerView()
                    } label: {
                        MeshFeatureCard(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "Mesh Features",
                            subtitle: "Echo • Club • Vault",
                            gradient: [.blue, .purple]
                        )
                    }
                    .buttonStyle(.plain)
                    
                    // Individual quick-access cards
                    if FeatureFlag.isEchoEnabled {
                        NavigationLink {
                            EchoMapView()
                        } label: {
                            MeshFeatureCard(
                                icon: "waveform",
                                title: "Echo",
                                subtitle: "Anonymous Q&A",
                                gradient: [.purple, .indigo]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if FeatureFlag.isClubModeEnabled {
                        NavigationLink {
                            ClubListView()
                        } label: {
                            MeshFeatureCard(
                                icon: "person.3.fill",
                                title: "Club",
                                subtitle: "Group Tracking",
                                gradient: [.orange, .red]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if FeatureFlag.isVaultEnabled {
                        NavigationLink {
                            VaultListView()
                        } label: {
                            MeshFeatureCard(
                                icon: "lock.shield.fill",
                                title: "Vault",
                                subtitle: "Location Vault",
                                gradient: [.teal, .blue]
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            // 🚧 Claim the gesture while panning these horizontal cards so
            // the root TabPager does NOT switch tabs (Discover ↔ Account)
            // when the user is actually scrolling the mesh-feature carousel.
            // Same pattern as PeekCarousel in the feed.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) * 1.2 {
                            NestedSwipeCoordinator.shared.isHandlingSwipe = true
                        }
                    }
                    .onEnded { _ in
                        NestedSwipeCoordinator.shared.isHandlingSwipe = false
                    }
            )
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Mesh Feature Card

struct MeshFeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let gradient: [Color]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
            
            Spacer()
            
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 140, height: 120, alignment: .leading)
        .padding(14)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .shadow(color: gradient.first?.opacity(0.3) ?? .clear, radius: 8, y: 4)
    }
}

// MARK: - Unified Suggested For You Section (4 cards + Show more)
struct SuggestedForYouSection: View {
    let accounts: [SearchUser]
    let isLoading: Bool
    let sentRequestIds: Set<String>
    let friendIds: Set<String>
    let onSendRequest: (String) -> Void
    let onRemoveFriend: (String) -> Void
    let onShowMore: () -> Void
    
    // Show only first 4 cards. Contacts are surfaced first so the preview row
    // doesn't bury people the user already knows behind purely algorithmic
    // matches; remaining slots are filled in API order.
    private var previewAccounts: [SearchUser] {
        let contacts = accounts.filter { $0.source == "contacts" }
        let others = accounts.filter { $0.source != "contacts" }
        return Array((contacts + others).prefix(4))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with "Show more"
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.blue)
                        .font(.subheadline)
                    Text("Suggested for you")
                        .font(.headline)
                }
                
                Spacer()
                
                if accounts.count > 4 {
                    Button {
                        Haptics.light()
                        onShowMore()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Show more")
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.blue)
                    }
                }
            }
            .padding(.horizontal, 16)
            
            if isLoading {
                // Loading shimmer — actually shimmers now (the previous version
                // was just a static gray rectangle calling itself a shimmer).
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.gray.opacity(0.18))
                                .frame(width: 140, height: 180)
                                .shimmering()
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else if accounts.isEmpty {
                // Empty state
                Text("No suggestions available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                // Horizontal scroll of 4 preview cards with staggered fade-in.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // ✅ FIX Bug 6: Wrap cards in NavigationLink for tap-to-profile
                        ForEach(Array(previewAccounts.enumerated()), id: \.element.id) { index, user in
                            NavigationLink(value: ProfileRoute(userId: user.id)) {
                                SuggestedProfileCard(
                                    user: user,
                                    isFriend: friendIds.contains(user.id),
                                    hasSentRequest: sentRequestIds.contains(user.id),
                                    onSendRequest: { onSendRequest(user.id) },
                                    onRemoveFriend: { onRemoveFriend(user.id) }
                                )
                            }
                            .buttonStyle(.plain)
                            .staggeredAppear(index: index)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

// MARK: - Suggested Profile Card (with Source Label)
struct SuggestedProfileCard: View {
    let user: SearchUser
    let isFriend: Bool
    let hasSentRequest: Bool
    let onSendRequest: () -> Void
    let onRemoveFriend: () -> Void
    
    @State private var showRemoveAlert = false
    
    private var isContact: Bool {
        user.source == "contacts"
    }
    
    var body: some View {
        VStack(spacing: 10) {
            // Avatar (with long-press preview)
            GlassAvatar(
                name: user.displayName ?? user.username,
                path: user.avatarUrl,
                size: 52,
                showGlow: true,
                showOnlineIndicator: false
            )
            .userPreviewPopup(
                userId: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarPath: user.avatarUrl,
                bio: nil,
                createdAt: nil,
                isVerified: user.verifiedStatus,
                isPremium: user.premiumStatus
            )
            
            // Name + Username
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Text(user.displayName ?? user.username)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    
                    if user.verifiedStatus {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                    if user.premiumStatus {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                    }
                }
                
                Text("@\(user.username)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            // Source Label Capsule
            Text(isContact ? "From your contacts" : (user.reason ?? "Suggested"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isContact ? .green : .blue)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill((isContact ? Color.green : Color.blue).opacity(0.12))
                )
            
            // Action Button
            Button {
                Haptics.medium()
                if isFriend {
                    showRemoveAlert = true
                } else if !hasSentRequest {
                    onSendRequest()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: buttonIcon)
                        .font(.caption2)
                    Text(buttonText)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundColor(buttonTextColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(buttonBackground)
                )
                .overlay(
                    Capsule().stroke(buttonBorderColor, lineWidth: isFriend ? 1 : 0)
                )
            }
            .buttonStyle(.plain)
            .disabled(hasSentRequest && !isFriend)
        }
        .frame(width: 110, height: 185)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .alert("Remove Friend", isPresented: $showRemoveAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { onRemoveFriend() }
        } message: {
            Text("Remove \(user.displayName ?? user.username) from friends?")
        }
    }
    
    // Button styling
    private var buttonIcon: String {
        if isFriend { return "checkmark.circle.fill" }
        if hasSentRequest { return "checkmark" }
        return "person.badge.plus"
    }
    
    private var buttonText: String {
        if isFriend { return "Friend" }
        if hasSentRequest { return "Sent" }
        return "Add"
    }
    
    private var buttonTextColor: Color {
        if isFriend { return .green }
        if hasSentRequest { return .secondary }
        return .white
    }
    
    private var buttonBackground: some ShapeStyle {
        if isFriend { return AnyShapeStyle(.ultraThinMaterial) }
        if hasSentRequest { return AnyShapeStyle(Color.gray.opacity(0.2)) }
        return AnyShapeStyle(Color.blue)
    }
    
    private var buttonBorderColor: Color {
        if isFriend { return .green.opacity(0.5) }
        return .clear
    }
}

// MARK: - Suggested Profiles Sheet (Full list with Liquid Glass)
struct SuggestedProfilesSheet: View {
    let suggestions: [SearchUser]
    let isLoading: Bool
    let sentRequestIds: Set<String>
    let friendIds: Set<String>
    let onSendRequest: (String) -> Void
    let onRemoveFriend: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    // Filtered lists
    private var contactSuggestions: [SearchUser] {
        suggestions.filter { $0.source == "contacts" }
    }
    private var algorithmSuggestions: [SearchUser] {
        suggestions.filter { $0.source != "contacts" }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading {
                    VStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.gray.opacity(0.15))
                                .frame(height: 72)
                                .shimmering()
                        }
                    }
                    .padding()
                } else {
                    LazyVStack(spacing: 12) {
                        // Contact Suggestions Section
                        if !contactSuggestions.isEmpty {
                            SuggestionSectionHeader(
                                icon: "person.crop.circle.badge.checkmark",
                                title: "From Your Contacts",
                                color: .green
                            )
                            
                            // ✅ FIX Bug 6: Wrap rows in NavigationLink for tap-to-profile
                            ForEach(Array(contactSuggestions.enumerated()), id: \.element.id) { index, user in
                                NavigationLink(value: ProfileRoute(userId: user.id)) {
                                    SuggestionListRow(
                                        user: user,
                                        isFriend: friendIds.contains(user.id),
                                        hasSentRequest: sentRequestIds.contains(user.id),
                                        onSendRequest: { onSendRequest(user.id) },
                                        onRemoveFriend: { onRemoveFriend(user.id) }
                                    )
                                }
                                .buttonStyle(.plain)
                                .staggeredAppear(index: index)
                            }
                        }
                        
                        // Algorithmic Suggestions Section
                        if !algorithmSuggestions.isEmpty {
                            SuggestionSectionHeader(
                                icon: "sparkles",
                                title: "People You May Know",
                                color: .blue
                            )
                            .padding(.top, contactSuggestions.isEmpty ? 0 : 8)
                            
                            ForEach(Array(algorithmSuggestions.enumerated()), id: \.element.id) { index, user in
                                NavigationLink(value: ProfileRoute(userId: user.id)) {
                                    SuggestionListRow(
                                        user: user,
                                        isFriend: friendIds.contains(user.id),
                                        hasSentRequest: sentRequestIds.contains(user.id),
                                        onSendRequest: { onSendRequest(user.id) },
                                        onRemoveFriend: { onRemoveFriend(user.id) }
                                    )
                                }
                                .buttonStyle(.plain)
                                .staggeredAppear(index: contactSuggestions.count + index)
                            }
                        }
                        
                        if suggestions.isEmpty && !isLoading {
                            VStack(spacing: 12) {
                                Image(systemName: "person.2.slash")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                                Text("No suggestions available")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Suggested for You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Section Header for Sheet
struct SuggestionSectionHeader: View {
    let icon: String
    let title: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.subheadline)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

// MARK: - Suggestion List Row (for sheet)
struct SuggestionListRow: View {
    let user: SearchUser
    let isFriend: Bool
    let hasSentRequest: Bool
    let onSendRequest: () -> Void
    let onRemoveFriend: () -> Void
    
    @State private var showRemoveAlert = false
    
    private var isContact: Bool {
        user.source == "contacts"
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            GlassAvatar(
                name: user.displayName ?? user.username,
                path: user.avatarUrl,
                size: 48,
                showGlow: false,
                showOnlineIndicator: false
            )
            .userPreviewPopup(
                userId: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarPath: user.avatarUrl,
                bio: nil,
                createdAt: nil,
                isVerified: user.verifiedStatus,
                isPremium: user.premiumStatus
            )
            
            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text(user.displayName ?? user.username)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    
                    if user.verifiedStatus {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                    }
                    if user.premiumStatus {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.85, green: 0.70, blue: 0.35))
                    }
                }
                
                Text("@\(user.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                // Reason/source label
                if let reason = user.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isContact ? .green : .blue)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Action Button
            Button {
                Haptics.medium()
                if isFriend {
                    showRemoveAlert = true
                } else if !hasSentRequest {
                    onSendRequest()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: buttonIcon)
                    Text(buttonText)
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(buttonTextColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(buttonBackground)
                )
                .overlay(
                    Capsule().stroke(buttonBorderColor, lineWidth: isFriend ? 1 : 0)
                )
            }
            .buttonStyle(.plain)
            .disabled(hasSentRequest && !isFriend)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .alert("Remove Friend", isPresented: $showRemoveAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { onRemoveFriend() }
        } message: {
            Text("Remove \(user.displayName ?? user.username) from friends?")
        }
    }
    
    // Button styling
    private var buttonIcon: String {
        if isFriend { return "checkmark.circle.fill" }
        if hasSentRequest { return "checkmark" }
        return "person.badge.plus"
    }
    
    private var buttonText: String {
        if isFriend { return "Friend" }
        if hasSentRequest { return "Sent" }
        return "Add"
    }
    
    private var buttonTextColor: Color {
        if isFriend { return .green }
        if hasSentRequest { return .secondary }
        return .white
    }
    
    private var buttonBackground: some ShapeStyle {
        if isFriend { return AnyShapeStyle(.ultraThinMaterial) }
        if hasSentRequest { return AnyShapeStyle(Color.gray.opacity(0.2)) }
        return AnyShapeStyle(Color.blue)
    }
    
    private var buttonBorderColor: Color {
        if isFriend { return .green.opacity(0.5) }
        return .clear
    }
}

#Preview {
    DiscoverView()
}
