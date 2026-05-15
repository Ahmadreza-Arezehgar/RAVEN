 import SwiftUI
import Combine
import CoreLocation

/// FeedStore manages the feed data and API interactions
@MainActor
final class FeedStore: ObservableObject {
    // MARK: - Singleton (always available for CreatePostView optimistic inserts)
    static let shared = FeedStore()
    
    // MARK: - Published Properties
    @Published var mergedLocalPosts: [Post] = []   // Merged Nearby + ForYou
    @Published var friendsPosts: [Post] = []
    @Published var recommendedPosts: [Post] = []   // Global For You feed
    
    @Published var isLoadingLocal = false
    @Published var isLoadingFriends = false
    @Published var isLoadingRecommended = false
    
    @Published var errorMessage: String?
    @Published var hasLocationPermission = true     // Track GPS permission
    
    // MARK: - Infinite Scroll Pagination (separate per feed)
    @Published var isLoadingMoreLocal = false
    private var localFeedOffset = 0
    @Published var hasMoreLocal = true
    
    @Published var isLoadingMoreFriends = false
    private var friendsFeedOffset = 0
    @Published var hasMoreFriends = true
    
    private let pageSize = 20
    
    // MARK: - Recommended Backfill (Twitter/X-style endless feed)
    @Published var isBackfillingLocal = false
    @Published var isBackfillingFriends = false
    private var recommendedLocalOffset = 0
    private var recommendedFriendsOffset = 0
    @Published var hasMoreRecommendedLocal = true
    @Published var hasMoreRecommendedFriends = true
    
    // MARK: - Location
    @Published var currentLocation: CLLocation?
    
    // MARK: - Dependencies
    private let networkService: NetworkService
    private let postRepository = PostRepository.shared
    
    // MARK: - View Tracking (prevent duplicate views)
    private var viewedPostIds: Set<String> = []
    
    // MARK: - Sequential View Recording (prevents Thundering Herd)
    // Each recordView fires independently (Bug 5 fix: no more chaining)
    // viewedPostIds deduplication prevents repeat requests.
    
    // MARK: - Comments Cache
    private var commentsCache: [String: [Comment]] = [:]
    private var commentsPrefetchingIds: Set<String> = []
    
    // MARK: - Cache Status
    @Published var isLoadingFromCache = false
    
    private var meshPostObserver: NSObjectProtocol?
    private var locationCancellable: AnyCancellable?
    
    private init(networkService: NetworkService = .shared) {
        self.networkService = networkService
        
        self.meshPostObserver = NotificationCenter.default.addObserver(
            forName: .meshPostReceived,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let post = notification.userInfo?["post"] as? Post {
                Task { @MainActor in
                    self?.insertMeshPostOptimistically(post)
                }
            }
        }
        
        // ✅ FIX Bug 6: Sync currentLocation from LocationManager so local feed actually works
        self.locationCancellable = LocationManager.shared.$lastLocation
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.currentLocation = location
            }
    }
    
    // MARK: - Deduplicate Helper
    /// Removes duplicate posts by ID, keeping the first occurrence
    private func deduplicateByID(_ posts: [Post]) -> [Post] {
        var seen = Set<String>()
        return posts.filter { seen.insert($0.id.lowercased()).inserted }
    }
    
    // MARK: - Comments Cache Methods
    
    /// Get cached comments for a post (returns nil if not cached)
    func getCachedComments(for postId: String) -> [Comment]? {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        return commentsCache[serverId]
    }
    
    /// Set cached comments for a post
    func setCachedComments(_ comments: [Comment], for postId: String) {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        commentsCache[serverId] = comments
    }
    
    /// Check if comments are being prefetched
    func isPrefetchingComments(for postId: String) -> Bool {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        return commentsPrefetchingIds.contains(serverId)
    }
    
    /// Prefetch comments for a post (called when post becomes visible)
    func prefetchComments(for postId: String) {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        // Skip if already cached or prefetching
        guard commentsCache[serverId] == nil,
              !commentsPrefetchingIds.contains(serverId) else { return }
        
        // Skip client-side posts
        guard serverId.first?.isUppercase != true else { return }
        
        commentsPrefetchingIds.insert(serverId)
        
        Task {
            do {
                let comments: [Comment] = try await networkService.get(
                    path: "/api/comments/post/\(serverId)"
                )
                commentsCache[serverId] = comments
                #if DEBUG
                print("💬 Prefetched \(comments.count) comments for post: \(serverId.prefix(8))...")
                #endif
            } catch {
                #if DEBUG
                print("⚠️ Failed to prefetch comments for \(serverId.prefix(8))...: \(error)")
                #endif
            }
            commentsPrefetchingIds.remove(serverId)
        }
    }
    
    /// Clear comments cache for a specific post (call after adding new comment)
    func invalidateCommentsCache(for postId: String) {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        commentsCache.removeValue(forKey: serverId)
    }
    
    // MARK: - Load from Cache (on app startup)
    /// Loads cached posts from SQLite immediately on startup
    func loadFromCache() async {
        isLoadingFromCache = true
        
        do {
            // Load local feed cache
            let cachedLocal = try await postRepository.getAllPosts(feedType: .local)
            if !cachedLocal.isEmpty {
                mergedLocalPosts = deduplicateByID(cachedLocal)
                #if DEBUG
                print("💾 Loaded \(mergedLocalPosts.count) cached local posts")
                #endif
            }
            
            // Load friends feed cache
            let cachedFriends = try await postRepository.getAllPosts(feedType: .friends)
            if !cachedFriends.isEmpty {
                friendsPosts = deduplicateByID(cachedFriends)
                #if DEBUG
                print("💾 Loaded \(friendsPosts.count) cached friends posts")
                #endif
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to load from cache: \(error)")
            #endif
        }
        
        isLoadingFromCache = false
    }
    
    // MARK: - Optimistic Insert (after creating a new post)
    func insertPostOptimistically(_ post: Post) {
        // Insert at the top of the appropriate feed based on visibility (guard against duplicates)
        if post.visibility == "friends" {
            friendsPosts.removeAll { $0.serverId == post.serverId }
            friendsPosts.insert(post, at: 0)
        } else {
            mergedLocalPosts.removeAll { $0.serverId == post.serverId }
            mergedLocalPosts.insert(post.withSource(.nearby), at: 0)
        }
        #if DEBUG
        print("📝 Optimistically inserted new post: \(post.id)")
        #endif
    }
    
    // MARK: - Insert Draft (saves to DB before upload)
    func insertDraft(_ draft: LocalPostDraft) async {
        #if DEBUG
        print("🔍 DEBUG insertDraft: visibility=\(draft.visibility), lat=\(draft.latitude ?? -999)")
        #endif
        
        // Route based on visibility alone:
        // visibility == "friends" → Friends tab, everything else → Local tab
        let feedType: FeedType = (draft.visibility == "friends") ? .friends : .local
        #if DEBUG
        print("🔍 DEBUG insertDraft: visibility=\(draft.visibility), feedType=\(feedType.rawValue)")
        #endif
        
        // Save to DB first
        do {
            try await postRepository.insertDraft(draft, feedType: feedType)
            #if DEBUG
            print("🔍 DEBUG insertDraft: DB save SUCCESS")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ Failed to save draft: \(error)")
            #endif
        }
        
        // Insert optimistically in memory
        let post = draft.asPost()
        
        if feedType == .local {
            // Posts intended for Local tab (with GPS or public fallback, guard against duplicates)
            mergedLocalPosts.removeAll { $0.serverId == post.serverId }
            mergedLocalPosts.insert(post.withSource(.nearby), at: 0)
            #if DEBUG
            print("🔍 DEBUG insertDraft: Inserted to mergedLocalPosts, new count=\(mergedLocalPosts.count)")
            #endif
        } else {
            // Friends-only posts go to Friends tab (guard against duplicates)
            friendsPosts.removeAll { $0.serverId == post.serverId }
            friendsPosts.insert(post, at: 0)
            #if DEBUG
            print("🔍 DEBUG insertDraft: Inserted to friendsPosts, new count=\(friendsPosts.count)")
            #endif
        }
        #if DEBUG
        print("📝 Inserted draft post: \(draft.clientPostId)")
        #endif
    }
    
    // MARK: - Update Post After Server Response
    func updatePost(clientPostId: String, with serverPost: Post) async {
        // Update DB
        do {
            try await postRepository.updateStatus(
                clientPostId: clientPostId,
                serverId: serverPost.id,
                status: .posted
            )
        } catch {
            #if DEBUG
            print("⚠️ Failed to update post status: \(error)")
            #endif
        }
        
        // Update in-memory: find by clientPostId (case-insensitive) and replace with serverPost
        // IMPORTANT: Preserve draft's media if server returns nil (server may not support multi-image yet)
        for i in mergedLocalPosts.indices {
            if mergedLocalPosts[i].serverId.lowercased() == clientPostId.lowercased() {
                var updatedPost = serverPost.withSource(.nearby)
                updatedPost.id = mergedLocalPosts[i].id // preserve loop suffix if any
                if updatedPost.media == nil || updatedPost.media?.isEmpty == true {
                    updatedPost.media = mergedLocalPosts[i].media
                }
                mergedLocalPosts[i] = updatedPost
            }
        }
        for i in friendsPosts.indices {
            if friendsPosts[i].serverId.lowercased() == clientPostId.lowercased() {
                var updatedPost = serverPost
                updatedPost.id = friendsPosts[i].id // preserve loop suffix if any
                if updatedPost.media == nil || updatedPost.media?.isEmpty == true {
                    updatedPost.media = friendsPosts[i].media
                }
                friendsPosts[i] = updatedPost
            }
        }
        #if DEBUG
        print("✅ Updated post: \(clientPostId) → \(serverPost.id)")
        #endif
    }
    
    // MARK: - Insert Mesh Post Optimistically (Real-Time)
    @MainActor
    private func insertMeshPostOptimistically(_ post: Post) {
        let sig = "\(post.authorId)_|_\(post.content)"
        let myId = AuthService.shared.currentUser?.id ?? ""
        
        if post.visibility == "friends" {
            guard !friendsPosts.contains(where: { $0.serverId.lowercased() == post.serverId.lowercased() || ($0.content.count > 5 && "\($0.authorId)_|_\($0.content)" == sig) }) else { return }
            var updated = friendsPosts
            updated.insert(post, at: 0)
            Task {
                let ranked = await RavenRankEngine.shared.rankFriendsFeed(posts: updated, currentUserId: myId, limit: max(1000, updated.count))
                await MainActor.run { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.friendsPosts = ranked } }
            }
        } else {
            guard !mergedLocalPosts.contains(where: { $0.serverId.lowercased() == post.serverId.lowercased() || ($0.content.count > 5 && "\($0.authorId)_|_\($0.content)" == sig) }) else { return }
            var updated = mergedLocalPosts
            updated.insert(post.withSource(.nearby), at: 0)
            Task {
                let ranked = await RavenRankEngine.shared.rankLocalFeed(posts: updated, userLocation: self.currentLocation, currentUserId: myId, limit: max(1000, updated.count))
                await MainActor.run { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.mergedLocalPosts = ranked } }
            }
        }
    }
    
    // MARK: - Mark Post Failed
    func markPostFailed(clientPostId: String) async {
        do {
            try await postRepository.updateStatus(
                clientPostId: clientPostId,
                serverId: nil,
                status: .failed
            )
        } catch {
            #if DEBUG
            print("⚠️ Failed to mark post as failed: \(error)")
            #endif
        }
        
        // Remove from in-memory feed arrays so the "ghost" post disappears from UI
        mergedLocalPosts.removeAll { $0.serverId == clientPostId }
        friendsPosts.removeAll { $0.serverId == clientPostId }
        #if DEBUG
        print("🗑️ Removed failed post from feed: \(clientPostId)")
        #endif
    }
    
    // MARK: - Fetch Merged Local Feed (Nearby + ForYou combined)
    /// Fetches both Nearby and ForYou posts, dedupes, and interleaves them 60/40
    func fetchMergedLocalFeed(lat: Double? = nil, lng: Double? = nil, radiusM: Int = 5000, isManualRefresh: Bool = true) async {
        // Offline-first: Skip server if no network
        guard NetworkMonitor.shared.isOnline || isManualRefresh else {
            #if DEBUG
            print("📦 [FeedStore] Offline - skipping feed fetch")
            #endif
            return
        }
        
        // Only show loading if we have no posts yet (prevents flash on refresh)
        let showLoading = mergedLocalPosts.isEmpty
        if showLoading { isLoadingLocal = true }
        errorMessage = nil
        
        let queryLat = lat ?? currentLocation?.coordinate.latitude
        let queryLng = lng ?? currentLocation?.coordinate.longitude
        
        // If no GPS, fetch ForYou only
        guard let lat = queryLat, let lng = queryLng else {
            hasLocationPermission = false
            await fetchForYouOnlyFallback()
            return
        }
        
        hasLocationPermission = true
        
        // Parallel fetch both sources
        do {
            async let nearbyResult = fetchNearbyRaw(lat: lat, lng: lng, radiusM: radiusM)
            async let forYouResult = fetchForYouRaw(lat: lat, lng: lng, radiusM: radiusM)
            
            // ✅ FIX Bug 5: Evaluate requests independently so ForYou failure
            // doesn't destroy the successfully-fetched nearby posts.
            let nearbyResponse = try await nearbyResult
            let nearby = nearbyResponse.items
            
            // ForYou is optional — a 404/500 here should NOT wipe the nearby feed
            let forYou = (try? await forYouResult) ?? []
            
            // Tag sources
            let nearbyTagged = nearby.map { $0.withSource(.nearby) }
            let forYouTagged = forYou.map { $0.withSource(.forYou) }
            
            let myId = AuthService.shared.currentUser?.id ?? ""
            
            // Combine raw posts for RavenRank
            let combinedRawPosts = nearbyTagged + forYouTagged
            
            // 🌟 Pass through the RavenRank™ engine 🌟
            var rankedPosts = await RavenRankEngine.shared.rankLocalFeed(
                posts: combinedRawPosts,
                userLocation: self.currentLocation,
                currentUserId: myId,
                limit: 1000  // High limit for endless feel
            )
            
            // --- SMART MERGE & DEDUPLICATION (LOWERCASE FIX) ---
            // 1. Preserve pending offline posts (client-side UUIDs or mesh posts)
            let serverIds = Set(rankedPosts.map { $0.serverId.lowercased() })
            var serverPostBySignature: [String: Post] = [:]
            for post in rankedPosts {
                if post.content.count > 5 {
                    let sig = "\(post.authorId)_|_\(post.content)"
                    serverPostBySignature[sig] = post
                }
            }
            
            let pendingPosts = mergedLocalPosts.filter { $0.serverId.first?.isUppercase == true || $0.meshStatus != nil || $0.initialSend == "mesh" }
            let existingServerPosts = mergedLocalPosts.filter { 
                !($0.serverId.first?.isUppercase == true || $0.meshStatus != nil || $0.initialSend == "mesh")
                && (!$0.id.contains("-loop-") || !isManualRefresh)
            }
            
            let trulyPendingPosts = pendingPosts.filter { pending in
                // Remove offline post that now exists on server (keep server version)
                if pending.content.count > 5 {
                    let sig = "\(pending.authorId)_|_\(pending.content)"
                    if let serverPost = serverPostBySignature[sig] {
                        if pending.serverId != serverPost.id {
                            Task.detached { try? await PostRepository.shared.delete(postId: pending.serverId) }
                        }
                        return false
                    }
                }
                if rankedPosts.contains(where: { $0.serverId.lowercased() == pending.serverId.lowercased() }) { return false }
                return true
            }
            
            let existingIds = Set(existingServerPosts.map { $0.serverId.lowercased() })
            let newPosts = rankedPosts.filter { !existingIds.contains($0.serverId.lowercased()) }
            
            let freshPostsDict = Dictionary(rankedPosts.map { ($0.serverId.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            let updatedExisting = existingServerPosts.compactMap { oldPost -> Post? in
                if let fresh = freshPostsDict[oldPost.serverId.lowercased()] { 
                    var copy = fresh
                    copy.id = oldPost.id
                    return copy 
                }
                return oldPost // Keep old paginated posts so the feed doesn't shrink!
            }
            
            let finalRaw = trulyPendingPosts + newPosts + updatedExisting
            
            // Feed everything back to the engine so algorithm ranks BOTH mesh & server posts
            let finalRanked = await RavenRankEngine.shared.rankLocalFeed(
                posts: finalRaw,
                userLocation: self.currentLocation,
                currentUserId: myId,
                limit: max(1000, finalRaw.count) // Endless
            )
            
            // 4. Animate the new posts sliding in from the top
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                mergedLocalPosts = deduplicateByID(finalRanked)
            }
            
            // 5. Fix pagination offset so Endless Scroll doesn't break
            if existingIds.isEmpty {
                localFeedOffset = nearbyResponse.nextOffset
                hasMoreLocal = nearbyResponse.hasMore
            } else if !newPosts.isEmpty {
                // Shift the offset by the number of new posts
                localFeedOffset += newPosts.count
            }
            
            if isManualRefresh {
                hasMoreLocal = nearbyResponse.hasMore
                recommendedLocalOffset = 0
                hasMoreRecommendedLocal = true
            }
            
            #if DEBUG
            print("📍✨ RavenRank™ ranked \(nearby.count) nearby + \(forYou.count) forYou → \(rankedPosts.count) total")
            #endif
            
            // Cache to DB in background (clear stale entries on manual refresh)
            let postsToCache = rankedPosts
            let shouldClearCache = isManualRefresh
            Task.detached { [postsToCache, postRepository, shouldClearCache] in
                do {
                    if shouldClearCache {
                        try await postRepository.clearCache(feedType: .local)
                    }
                    try await postRepository.upsertAll(postsToCache, feedType: .local)
                } catch {
                    #if DEBUG
                    print("⚠️ Failed to cache local feed: \(error)")
                    #endif
                }
            }
        } catch {
            // FIX: On network error, retain existing cached data instead of wiping
            #if DEBUG
            print("❌ Merged feed fetch error: \(error) — Retaining Cache!")
            #endif
        }
        
        isLoadingLocal = false
    }
    
    // MARK: - Infinite Scroll: Fetch More Local Posts
    func fetchMoreLocalPosts() async {
        // Guards: prevent multiple calls, no network, or no more content
        guard !isLoadingMoreLocal, !isLoadingLocal, hasMoreLocal, NetworkMonitor.shared.isOnline else {
            #if DEBUG
            print("📍🚫 [PAGINATION] fetchMoreLocalPosts BLOCKED: isLoadingMoreLocal=\(isLoadingMoreLocal), isLoadingLocal=\(isLoadingLocal), hasMoreLocal=\(hasMoreLocal), online=\(NetworkMonitor.shared.isOnline)")
            #endif
            return
        }
        
        guard let lat = currentLocation?.coordinate.latitude,
              let lng = currentLocation?.coordinate.longitude else {
            // ✅ FIX Bug 7: Without GPS, signal that organic local posts are exhausted
            // so the recommended backfill can kick in.
            hasMoreLocal = false
            return
        }
        
        isLoadingMoreLocal = true
        
        do {
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "lat", value: "\(lat)"),
                URLQueryItem(name: "lng", value: "\(lng)"),
                URLQueryItem(name: "radius_m", value: "5000"),
                URLQueryItem(name: "offset", value: "\(localFeedOffset)"),
                URLQueryItem(name: "limit", value: "\(pageSize)")
            ]
            
            let response: PaginatedFeedResponse = try await networkService.get(path: "/api/posts/feed/local", queryItems: queryItems)
            
            hasMoreLocal = response.hasMore
            
            if response.items.isEmpty {
                hasMoreLocal = false
            } else {
                // Dedupe against existing posts
                let existingIds = Set(mergedLocalPosts.map { $0.serverId })
                let uniqueNewPosts = response.items.filter { !existingIds.contains($0.id) }
                
                // ✅ FIX Bug 6: If all items are duplicates but server says there's more,
                // skip to the next page immediately instead of stalling forever.
                if uniqueNewPosts.isEmpty && response.hasMore {
                    localFeedOffset = response.nextOffset
                    isLoadingMoreLocal = false
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s backoff
                        await self.fetchMoreLocalPosts()
                    }
                    return
                }
                
                let myId = AuthService.shared.currentUser?.id ?? ""
                
                // Rank the newly fetched page before appending to maintain algorithm flow
                let rankedNew = await RavenRankEngine.shared.rankLocalFeed(
                    posts: uniqueNewPosts.map { $0.withSource(.nearby) },
                    userLocation: self.currentLocation,
                    currentUserId: myId,
                    limit: uniqueNewPosts.count
                )
                
                mergedLocalPosts.append(contentsOf: rankedNew)
                mergedLocalPosts = deduplicateByID(mergedLocalPosts)
                localFeedOffset = response.nextOffset
                
                #if DEBUG
                print("📍♾️ [PAGINATION] Loaded \(uniqueNewPosts.count) more local posts (offset: \(localFeedOffset), hasMore: \(hasMoreLocal), response.items=\(response.items.count), response.nextOffset=\(response.nextOffset), response.hasMore=\(response.hasMore))")
                #endif
            }
        } catch {
            #if DEBUG
            print("\u{274C} Failed to load more local posts: \(error)")
            #endif
        }
        
        isLoadingMoreLocal = false
    }
    
    // MARK: - Infinite Scroll: Fetch More Friends Posts
    func fetchMoreFriendsPosts() async {
        guard !isLoadingMoreFriends, !isLoadingFriends, hasMoreFriends, NetworkMonitor.shared.isOnline else { return }
        
        isLoadingMoreFriends = true
        
        do {
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "offset", value: "\(friendsFeedOffset)"),
                URLQueryItem(name: "limit", value: "\(pageSize)")
            ]
            
            let response: PaginatedFeedResponse = try await networkService.get(path: "/api/posts/feed/friends", queryItems: queryItems)
            
            hasMoreFriends = response.hasMore
            
            if response.items.isEmpty {
                hasMoreFriends = false
            } else {
                let existingIds = Set(friendsPosts.map { $0.serverId })
                let uniqueNewPosts = response.items.filter { !existingIds.contains($0.id) }
                
                // ✅ FIX Bug 6: Same stall-prevention as local feed.
                if uniqueNewPosts.isEmpty && response.hasMore {
                    friendsFeedOffset = response.nextOffset
                    isLoadingMoreFriends = false
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s backoff
                        await self.fetchMoreFriendsPosts()
                    }
                    return
                }
                
                let myId = AuthService.shared.currentUser?.id ?? ""
                let rankedNew = await RavenRankEngine.shared.rankFriendsFeed(
                    posts: uniqueNewPosts,
                    currentUserId: myId,
                    limit: uniqueNewPosts.count
                )
                
                friendsPosts.append(contentsOf: rankedNew)
                friendsPosts = deduplicateByID(friendsPosts)
                friendsFeedOffset = response.nextOffset
                
                #if DEBUG
                print("\u{1F465}\u{267E}\u{FE0F} Loaded \(uniqueNewPosts.count) more friends posts (offset: \(friendsFeedOffset), hasMore: \(hasMoreFriends))")
                #endif
            }
        } catch {
            #if DEBUG
            print("\u{274C} Failed to load more friends posts: \(error)")
            #endif
        }
        
        isLoadingMoreFriends = false
    }
    
    // MARK: - Raw Fetchers (internal helpers)
    private func fetchNearbyRaw(lat: Double, lng: Double, radiusM: Int) async throws -> PaginatedFeedResponse {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "lat", value: "\(lat)"),
            URLQueryItem(name: "lng", value: "\(lng)"),
            URLQueryItem(name: "radius_m", value: "\(radiusM)"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "\(pageSize)")
        ]
        let response: PaginatedFeedResponse = try await networkService.get(path: "/api/posts/feed/local", queryItems: queryItems)
        #if DEBUG
        print("📍📦 [PAGINATION] fetchNearbyRaw response: items=\(response.items.count), hasMore=\(response.hasMore), nextOffset=\(response.nextOffset)")
        #endif
        return response
    }
    
    private func fetchForYouRaw(lat: Double, lng: Double, radiusM: Int) async throws -> [Post] {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "lat", value: "\(lat)"),
            URLQueryItem(name: "lng", value: "\(lng)"),
            URLQueryItem(name: "radius_m", value: "\(radiusM)")
        ]
        return try await networkService.get(path: "/api/feed/local/foryou", queryItems: queryItems)
    }
    
    // MARK: - Fallback when GPS unavailable
    private func fetchForYouOnlyFallback() async {
        do {
            let userLang = Locale.current.language.languageCode?.identifier ?? "en"
            let posts: [Post] = try await networkService.get(path: "/api/feed/recommended?lang=\(userLang)")
            
            // Preserve pending posts during refresh
            let pendingPosts = mergedLocalPosts.filter { $0.id.first?.isUppercase == true }
            var result = posts.map { $0.withSource(.forYou) }
            if !pendingPosts.isEmpty {
                #if DEBUG
                print("🔄 Preserving \(pendingPosts.count) pending post(s) during fallback refresh")
                #endif
                result = pendingPosts + result
            }
            
            mergedLocalPosts = deduplicateByID(result)
            #if DEBUG
            print("🎯 GPS off → Loaded \(posts.count) ForYou posts as fallback")
            #endif
        } catch {
            errorMessage = "Failed to load feed: \(error.localizedDescription)"
            #if DEBUG
            print("❌ ForYou fallback error: \(error)")
            #endif
        }
        isLoadingLocal = false
    }
    
    // MARK: - Fetch Recommended Feed (global For You)
    func fetchRecommendedFeed() async {
        isLoadingRecommended = true
        errorMessage = nil
        
        do {
            let userLang = Locale.current.language.languageCode?.identifier ?? "en"
            let posts: [Post] = try await networkService.get(
                path: "/api/feed/recommended?lang=\(userLang)"
            )
            recommendedPosts = posts
            #if DEBUG
            print("🎯 Loaded \(posts.count) recommended posts")
            #endif
        } catch {
            errorMessage = "Failed to load recommendations: \(error.localizedDescription)"
            #if DEBUG
            print("❌ Recommended feed error: \(error)")
            #endif
        }
        
        isLoadingRecommended = false
    }
    
    // MARK: - Fetch Friends Feed
    func fetchFriendsFeed(isManualRefresh: Bool = true) async {
        // Offline-first: Skip server if no network
        guard NetworkMonitor.shared.isOnline || isManualRefresh else {
            #if DEBUG
            print("\u{1F4E6} [FeedStore] Offline - skipping friends feed fetch")
            #endif
            return
        }
        
        // Only show loading if we have no posts yet (prevents flash on refresh)
        let showLoading = friendsPosts.isEmpty
        if showLoading { isLoadingFriends = true }
        errorMessage = nil
        
        do {
            let myId = AuthService.shared.currentUser?.id ?? ""
            let response: PaginatedFeedResponse = try await networkService.get(
                path: "/api/posts/feed/friends"
            )
            
            //   Rank through RavenRank  engine 
            let rankedFriendsPosts = await RavenRankEngine.shared.rankFriendsFeed(
                posts: response.items,
                currentUserId: myId,
                affinities: [:],
                limit: 1000 
            )
            
            // --- SMART MERGE & DEDUPLICATION FOR FRIENDS FEED (LOWERCASE FIX) ---
            let serverIds = Set(rankedFriendsPosts.map { $0.serverId.lowercased() })
            var serverPostBySignature: [String: Post] = [:]
            for post in rankedFriendsPosts {
                if post.content.count > 5 {
                    let sig = "\(post.authorId)_|_\(post.content)"
                    serverPostBySignature[sig] = post
                }
            }
            
            let pendingPosts = friendsPosts.filter { $0.serverId.first?.isUppercase == true || $0.meshStatus != nil || $0.initialSend == "mesh" }
            let existingServerPosts = friendsPosts.filter { 
                !($0.serverId.first?.isUppercase == true || $0.meshStatus != nil || $0.initialSend == "mesh")
                && (!$0.id.contains("-loop-") || !isManualRefresh)
            }
            
            let trulyPendingPosts = pendingPosts.filter { pending in
                if pending.content.count > 5 {
                    let sig = "\(pending.authorId)_|_\(pending.content)"
                    if let serverPost = serverPostBySignature[sig] {
                        if pending.serverId != serverPost.id {
                            Task.detached { try? await PostRepository.shared.delete(postId: pending.serverId) }
                        }
                        return false
                    }
                }
                if rankedFriendsPosts.contains(where: { $0.serverId.lowercased() == pending.serverId.lowercased() }) { return false }
                return true
            }
            
            let existingIds = Set(existingServerPosts.map { $0.serverId.lowercased() })
            let newPosts = rankedFriendsPosts.filter { !existingIds.contains($0.serverId.lowercased()) }
            
            let freshPostsDict = Dictionary(rankedFriendsPosts.map { ($0.serverId.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            let updatedExisting = existingServerPosts.compactMap { oldPost -> Post? in
                if let fresh = freshPostsDict[oldPost.serverId.lowercased()] { 
                    var copy = fresh
                    copy.id = oldPost.id
                    return copy 
                }
                return oldPost 
            }
            
            let finalRaw = trulyPendingPosts + newPosts + updatedExisting
            
            let finalRanked = await RavenRankEngine.shared.rankFriendsFeed(
                posts: finalRaw,
                currentUserId: myId,
                limit: max(1000, finalRaw.count)
            )
            
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                friendsPosts = deduplicateByID(finalRanked)
            }
            
            if existingIds.isEmpty {
                friendsFeedOffset = response.nextOffset
                hasMoreFriends = response.hasMore
            } else if !newPosts.isEmpty {
                friendsFeedOffset += newPosts.count
            }
            
            if isManualRefresh {
                hasMoreFriends = response.hasMore
                recommendedFriendsOffset = 0
                hasMoreRecommendedFriends = true
            }
            
            isLoadingFriends = false
            
            #if DEBUG
            print("\u{1F465} Loaded \(response.items.count) friends posts")
            #endif
            
            // Cache to DB in background (clear stale entries on manual refresh)
            let posts = response.items
            let shouldClearCache = isManualRefresh
            Task.detached { [posts, postRepository, shouldClearCache] in
                do {
                    if shouldClearCache {
                        try await postRepository.clearCache(feedType: .friends)
                    }
                    try await postRepository.upsertAll(posts, feedType: .friends)
                } catch {
                    #if DEBUG
                    print("\u{26A0}\u{FE0F} Failed to cache friends feed: \(error)")
                    #endif
                }
            }
        } catch {
            errorMessage = "Failed to load friends feed: \(error.localizedDescription)"
            #if DEBUG
            print("\u{274C} Friends feed error: \(error)")
            #endif
        }
        
        isLoadingFriends = false
    }
    
    // MARK: - Toggle Like (Optimistic)
    func toggleLike(postId: String) async {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        // Skip client-side UUIDs (uppercase format) that haven't synced to server yet
        guard serverId.first?.isUppercase != true else {
            #if DEBUG
            print("⏭️ Skipping like for client-side post: \(serverId.prefix(8))...")
            #endif
            return
        }
        
        // ⚡ Step 1: OPTIMISTIC UPDATE — instantly toggle UI (0ms perceived latency)
        // Capture previous state for rollback
        let previousPost = findPost(byId: serverId)
        let wasLiked = previousPost?.isLiked ?? false
        let previousLikes = previousPost?.likes ?? 0
        
        // Fix: Use struct copy mutation to preserve ALL fields (badgeType, subscriptionTier, etc.)
        updatePostInFeeds(postId: serverId) { post in
            var updated = post
            updated.likes = post.isLiked ? max(post.likes - 1, 0) : post.likes + 1
            updated.isLiked = !post.isLiked
            return updated
        }
        
        // ⚡ Step 2: SYNC with server in background
        do {
            let response: LikeResponse = try await networkService.post(
                path: "/api/posts/\(serverId)/like",
                body: EmptyBody()
            )
            
            // Reconcile with server truth (fixes count drift)
            updatePostInFeeds(postId: serverId) { post in
                var updated = post
                updated.likes = response.likes
                updated.isLiked = response.isLiked
                return updated
            }
            
            #if DEBUG
            print("❤️ \(response.action) post \(serverId)")
            #endif
        } catch {
            // ⚡ Step 3: ROLLBACK on failure — revert to previous state
            #if DEBUG
            print("❌ Like error (reverting): \(error)")
            #endif
            updatePostInFeeds(postId: serverId) { post in
                var updated = post
                updated.likes = previousLikes
                updated.isLiked = wasLiked
                return updated
            }
            Haptics.error()
        }
    }
    
    // MARK: - Toggle Repost (Optimistic)
    func toggleRepost(postId: String, quote: String? = nil) async {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        // Skip client-side UUIDs (uppercase format) that haven't synced to server yet
        guard serverId.first?.isUppercase != true else {
            #if DEBUG
            print("⏭️ Skipping repost for client-side post: \(serverId.prefix(8))...")
            #endif
            return
        }
        
        // ⚡ Step 1: OPTIMISTIC UPDATE
        let previousPost = findPost(byId: serverId)
        let wasReposted = previousPost?.isReposted ?? false
        let previousReposts = previousPost?.reposts ?? 0
        
        updatePostInFeeds(postId: serverId) { post in
            var updated = post
            updated.reposts = post.isReposted ? max(post.reposts - 1, 0) : post.reposts + 1
            updated.isReposted = !post.isReposted
            return updated
        }
        
        // ⚡ Step 2: SYNC with server
        do {
            let body = RepostBody(content: quote)
            
            let response: RepostResponse = try await networkService.post(
                path: "/api/posts/\(serverId)/repost",
                body: body
            )
            
            // Reconcile with server truth
            updatePostInFeeds(postId: serverId) { post in
                var updated = post
                updated.reposts = response.reposts
                updated.isReposted = response.isReposted
                return updated
            }
            
            #if DEBUG
            print("🔄 \(response.action) post \(serverId)")
            #endif
        } catch {
            // ⚡ Step 3: ROLLBACK on failure
            #if DEBUG
            print("❌ Repost error (reverting): \(error)")
            #endif
            updatePostInFeeds(postId: serverId) { post in
                var updated = post
                updated.reposts = previousReposts
                updated.isReposted = wasReposted
                return updated
            }
            Haptics.error()
        }
    }
    
    // MARK: - Record View (viewport-based, returns count without mutating feed)
    func recordView(postId: String) async -> Int? {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        // Skip client-side UUIDs (uppercase format) that haven't synced to server yet
        if serverId.first?.isUppercase == true { return nil }
        
        // Prevent duplicate view calls in same session
        guard !viewedPostIds.contains(serverId) else { return nil }
        viewedPostIds.insert(serverId)
        
        do {
            let response: ViewResponse = try await networkService.post(
                path: "/api/posts/\(serverId)/view",
                body: EmptyBody()
            )
            #if DEBUG
            print("👁️ View recorded for \(serverId) (count: \(response.viewCount))")
            #endif
            // 🟢 Return the count — caller updates its own local state only
            return response.viewCount
        } catch {
            #if DEBUG
            print("❌ View error: \(error)")
            #endif
            return nil
        }
    }
    
    // MARK: - Delete Post (owner only)
    func deletePost(postId: String) async -> Bool {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        // Skip client-side UUIDs that haven't synced
        guard serverId.first?.isUppercase != true else {
            // For unsynced posts, just remove locally
            removePostFromFeeds(postId: serverId)
            #if DEBUG
            print("🗑️ Removed local draft post: \(serverId.prefix(8))...")
            #endif
            return true
        }
        
        // ⚡ Optimistic: snapshot feeds for rollback, then remove immediately
        let snapshotLocal = mergedLocalPosts
        let snapshotFriends = friendsPosts
        let snapshotRecommended = recommendedPosts
        removePostFromFeeds(postId: serverId)
        
        do {
            let _: DeletePostResponse = try await networkService.delete(
                path: "/api/posts/\(serverId)"
            )
            
            // Remove from DB cache
            Task.detached { [serverId, postRepository] in
                try? await postRepository.delete(postId: serverId)
            }
            
            #if DEBUG
            print("🗑️ Post deleted: \(serverId.prefix(8))...")
            #endif
            return true
        } catch {
            // ⚡ Rollback on failure — restore feeds
            mergedLocalPosts = snapshotLocal
            friendsPosts = snapshotFriends
            recommendedPosts = snapshotRecommended
            #if DEBUG
            print("❌ Delete error (rolled back): \(error)")
            #endif
            return false
        }
    }
    
    // MARK: - Helper: Remove post from all feeds
    private func removePostFromFeeds(postId: String) {
        mergedLocalPosts.removeAll { $0.serverId == postId }
        friendsPosts.removeAll { $0.serverId == postId }
        recommendedPosts.removeAll { $0.serverId == postId }
    }
    
    // MARK: - Helper: Find post by ID across all feeds
    private func findPost(byId postId: String) -> Post? {
        return mergedLocalPosts.first(where: { $0.serverId == postId })
            ?? friendsPosts.first(where: { $0.serverId == postId })
            ?? recommendedPosts.first(where: { $0.serverId == postId })
    }
    
    // MARK: - Helper: Update post in all feeds
    private func updatePostInFeeds(postId: String, transform: (Post) -> Post) {
        for idx in mergedLocalPosts.indices where mergedLocalPosts[idx].serverId == postId {
            mergedLocalPosts[idx] = transform(mergedLocalPosts[idx])
        }
        for idx in friendsPosts.indices where friendsPosts[idx].serverId == postId {
            friendsPosts[idx] = transform(friendsPosts[idx])
        }
        for idx in recommendedPosts.indices where recommendedPosts[idx].serverId == postId {
            recommendedPosts[idx] = transform(recommendedPosts[idx])
        }
    }
    
    // MARK: - ♾️ Twitter/X-Style Recommended Backfill
    
    /// When local organic posts run out, seamlessly backfill with algorithmic recommendations.
    func fetchRecommendedBackfillLocal() async {
        guard !isBackfillingLocal, !hasMoreLocal, hasMoreRecommendedLocal, NetworkMonitor.shared.isOnline else { return }
        
        let myId = AuthService.shared.currentUser?.id ?? ""
        isBackfillingLocal = true
        
        do {
            let userLang = Locale.current.language.languageCode?.identifier ?? "en"
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "lang", value: userLang),
                URLQueryItem(name: "offset", value: "\(recommendedLocalOffset)"),
                URLQueryItem(name: "limit", value: "\(pageSize)")
            ]
            
            let posts: [Post] = try await networkService.get(path: "/api/feed/recommended", queryItems: queryItems)
            
            if posts.isEmpty {
                // 🛑 Real Endless Scroll: End of database reached for this user
                isBackfillingLocal = false
                hasMoreRecommendedLocal = false
                return
            } else {
                let existingServerIds = Set(mergedLocalPosts.map { $0.serverId })
                let uniqueNewPosts = posts
                    .filter { !existingServerIds.contains($0.id) }
                    .map { $0.withSource(.recommended) }
                
                recommendedLocalOffset += posts.count
                
                if uniqueNewPosts.isEmpty {
                    // Try getting the next page recursively
                    if posts.count == pageSize {
                        isBackfillingLocal = false
                        Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await self.fetchRecommendedBackfillLocal()
                        }
                        return
                    } else {
                        hasMoreRecommendedLocal = false
                    }
                } else {
                    // 🌀 Rank the real database posts
                    let rankedNew = await RavenRankEngine.shared.rankLocalFeed(
                        posts: uniqueNewPosts,
                        userLocation: self.currentLocation,
                        currentUserId: myId,
                        limit: uniqueNewPosts.count
                    )
                    
                    mergedLocalPosts.append(contentsOf: rankedNew)
                    mergedLocalPosts = deduplicateByID(mergedLocalPosts)
                    
                    #if DEBUG
                    print("✨♾️ Backfilled \(uniqueNewPosts.count) REAL posts into Local feed (offset: \(recommendedLocalOffset))")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            print("❌ Recommended backfill (local) error: \(error)")
            #endif
        }
        
        isBackfillingLocal = false
    }
    
    /// When friends organic posts run out, seamlessly backfill with algorithmic recommendations.
    func fetchRecommendedBackfillFriends() async {
        guard !isBackfillingFriends, !hasMoreFriends, hasMoreRecommendedFriends, NetworkMonitor.shared.isOnline else { return }
        
        let myId = AuthService.shared.currentUser?.id ?? ""
        isBackfillingFriends = true
        
        do {
            let userLang = Locale.current.language.languageCode?.identifier ?? "en"
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "lang", value: userLang),
                URLQueryItem(name: "offset", value: "\(recommendedFriendsOffset)"),
                URLQueryItem(name: "limit", value: "\(pageSize)")
            ]
            
            let posts: [Post] = try await networkService.get(path: "/api/feed/recommended", queryItems: queryItems)
            
            if posts.isEmpty {
                isBackfillingFriends = false
                hasMoreRecommendedFriends = false
                return
            } else {
                let existingServerIds = Set(friendsPosts.map { $0.serverId })
                let uniqueNewPosts = posts
                    .filter { !existingServerIds.contains($0.id) }
                    .map { $0.withSource(.recommended) }
                
                recommendedFriendsOffset += posts.count
                
                if uniqueNewPosts.isEmpty {
                    if posts.count == pageSize {
                        isBackfillingFriends = false
                        Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await self.fetchRecommendedBackfillFriends()
                        }
                        return
                    } else {
                        hasMoreRecommendedFriends = false
                    }
                } else {
                    let rankedNew = await RavenRankEngine.shared.rankFriendsFeed(
                        posts: uniqueNewPosts,
                        currentUserId: myId,
                        limit: uniqueNewPosts.count
                    )
                    
                    friendsPosts.append(contentsOf: rankedNew)
                    friendsPosts = deduplicateByID(friendsPosts)
                    
                    #if DEBUG
                    print("✨♾️ Backfilled \(uniqueNewPosts.count) REAL posts into Friends feed (offset: \(recommendedFriendsOffset))")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            print("❌ Recommended backfill (friends) error: \(error)")
            #endif
        }
        
        isBackfillingFriends = false
    }
}

// MARK: - Request Bodies
private struct EmptyBody: Encodable {}
private struct RepostBody: Encodable {
    let content: String?
}
