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
    
    private let pageSize = 15  // ⚡ Reduced from 20 — faster first paint, infinite scroll loads more
    
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
    // Bounded — long sessions used to grow this set unbounded. When it
    // reaches the cap we drop the oldest half (FIFO via insertion order).
    // 2,000 IDs ≈ ~80KB memory, comfortably above any realistic session.
    private var viewedPostIds: [String] = []        // insertion-ordered for FIFO eviction
    private var viewedPostIdsSet: Set<String> = []  // O(1) membership test
    private static let maxViewedPostIds = 2_000

    // MARK: - Sequential View Recording (prevents Thundering Herd)
    // Each recordView fires independently (Bug 5 fix: no more chaining)
    // viewedPostIds deduplication prevents repeat requests.

    // MARK: - Comments Cache
    // Bounded LRU — capped at 200 posts. Hot posts get re-promoted on
    // access. Each entry holds a small array of Comment structs; 200
    // posts × ~10 comments ≈ a few hundred KB at worst.
    private var commentsCache: [String: [Comment]] = [:]
    private var commentsAccessOrder: [String] = []   // most-recently-accessed last
    private static let maxCommentsCacheEntries = 200
    private var commentsPrefetchingIds: Set<String> = []
    
    // MARK: - Cache Status
    @Published var isLoadingFromCache = false
    /// Whether initial server fetch has completed at least once (prevents empty state flash)
    @Published var isInitialLoadComplete = false
    
    private var meshPostObserver: NSObjectProtocol?
    private var locationCancellable: AnyCancellable?

    /// Per-post worker that owns the in-flight `/like` and `/repost`
    /// network calls. Rapid taps used to spawn one Task per tap, and
    /// the responses raced — the heart visibly bounced between liked
    /// and not-liked as each one's reconcile pass overwrote the UI.
    /// Now we keep at most one worker per post; if a tap arrives while
    /// one is running, the worker re-checks the (already-flipped)
    /// optimistic UI state on its next iteration and converges with
    /// the server in a single extra round-trip.
    private var likeWorker: [String: Task<Void, Never>] = [:]
    private var repostWorker: [String: Task<Void, Never>] = [:]
    
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
        // ⚡ PERF: Debounce location updates — only update if moved >15m AND >5s since last update.
        // Without this, every minor GPS jitter triggers a full feed re-rank (O(n log n)).
        self.locationCancellable = LocationManager.shared.$lastLocation
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .filter { [weak self] newLocation in
                guard let self, let current = self.currentLocation else { return true }
                // Minimum 15m movement AND 5s cooldown
                return newLocation.distance(from: current) > 15 &&
                       newLocation.timestamp.timeIntervalSince(current.timestamp) > 5
            }
            .sink { [weak self] location in
                self?.currentLocation = location
            }
        
        // 🚀 EAGER CACHE WARM: Load cached posts IMMEDIATELY when FeedStore is created.
        // This runs before FeedView even appears, so the feed is never empty on cold start.
        // Uses the fast shallow query (top 30 posts) for <10ms first-paint.
        Task { @MainActor [weak self] in
            await self?.warmCacheOnStartup()
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
        if commentsCache[serverId] != nil {
            // Promote on access (LRU bookkeeping)
            commentsAccessOrder.removeAll { $0 == serverId }
            commentsAccessOrder.append(serverId)
        }
        return commentsCache[serverId]
    }

    /// Set cached comments for a post (with LRU eviction at the cap)
    func setCachedComments(_ comments: [Comment], for postId: String) {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        commentsCache[serverId] = comments
        commentsAccessOrder.removeAll { $0 == serverId }
        commentsAccessOrder.append(serverId)
        evictCommentsCacheIfNeeded()
    }

    /// Drop oldest entries when over the cap.
    private func evictCommentsCacheIfNeeded() {
        while commentsAccessOrder.count > Self.maxCommentsCacheEntries {
            let evictKey = commentsAccessOrder.removeFirst()
            commentsCache.removeValue(forKey: evictKey)
        }
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
                // Use the LRU-aware setter rather than touching the dict directly
                setCachedComments(comments, for: serverId)
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
        commentsAccessOrder.removeAll { $0 == serverId }
    }
    
    // MARK: - Eager Cache Warm (Twitter-style instant feed)
    /// Called from init() — loads top 30 cached posts per feed BEFORE any view appears.
    /// Uses the fast shallow query for <10ms latency.
    private func warmCacheOnStartup() async {
        isLoadingFromCache = true
        
        do {
            // 🚀 Parallel cache load — both feeds at once for maximum speed
            async let cachedLocal = postRepository.getRecentPosts(feedType: .local, limit: 30)
            async let cachedFriends = postRepository.getRecentPosts(feedType: .friends, limit: 30)
            
            let (local, friends) = try await (cachedLocal, cachedFriends)
            
            if !local.isEmpty {
                mergedLocalPosts = deduplicateByID(local)
                #if DEBUG
                print("🚀💾 Eager warm: \(mergedLocalPosts.count) cached local posts")
                #endif
            }
            
            if !friends.isEmpty {
                friendsPosts = deduplicateByID(friends)
                #if DEBUG
                print("🚀💾 Eager warm: \(friendsPosts.count) cached friends posts")
                #endif
            }
        } catch {
            #if DEBUG
            print("⚠️ Failed to warm cache: \(error)")
            #endif
        }
        
        isLoadingFromCache = false
    }
    
    // MARK: - Load from Cache (full — fallback if eager warm missed)
    /// Loads cached posts from SQLite. Used as fallback if eager warm hasn't run yet.
    func loadFromCache() async {
        // Skip if eager warm already populated the feed
        guard mergedLocalPosts.isEmpty && friendsPosts.isEmpty else { return }
        
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
        
        // Insert optimistically in memory.
        // `isVerified` snapshotted from AuthService here because that
        // type is now @MainActor and asPost() is non-isolated.
        let post = draft.asPost(isVerified: AuthService.shared.currentUser?.isVerified ?? false)
        
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

        // Build the final id: take the server's canonical (lowercase)
        // UUID and append back any client-side `-loop-N` suffix that
        // we use internally to disambiguate duplicate appearances of
        // the same post.
        //
        // BUG FIX: previously this preserved the WHOLE client id
        // (`updatedPost.id = mergedLocalPosts[i].id`), which kept the
        // Swift-generated uppercase UUID even after the server
        // returned its lowercase canonical form. The mismatch then
        // broke deletes (`DELETE /api/posts/<UPPERCASE>` → 404).
        func mergedId(for oldId: String) -> String {
            if let range = oldId.range(of: "-loop-") {
                return serverPost.id + String(oldId[range.lowerBound...])
            }
            return serverPost.id
        }

        // Update in-memory: find by clientPostId (case-insensitive) and replace with serverPost
        // IMPORTANT: Preserve draft's media if server returns nil (server may not support multi-image yet)
        for i in mergedLocalPosts.indices {
            if mergedLocalPosts[i].serverId.lowercased() == clientPostId.lowercased() {
                var updatedPost = serverPost.withSource(.nearby)
                updatedPost.id = mergedId(for: mergedLocalPosts[i].id)
                if updatedPost.media == nil || updatedPost.media?.isEmpty == true {
                    updatedPost.media = mergedLocalPosts[i].media
                }
                mergedLocalPosts[i] = updatedPost
            }
        }
        for i in friendsPosts.indices {
            if friendsPosts[i].serverId.lowercased() == clientPostId.lowercased() {
                var updatedPost = serverPost
                updatedPost.id = mergedId(for: friendsPosts[i].id)
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
            
            // --- SMART MERGE & DEDUPLICATION (LOWERCASE FIX) ---
            // 1. Preserve pending offline posts (client-side UUIDs or mesh posts)
            var serverPostBySignature: [String: Post] = [:]
            for post in combinedRawPosts {
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
                if combinedRawPosts.contains(where: { $0.serverId.lowercased() == pending.serverId.lowercased() }) { return false }
                return true
            }
            
            let existingIds = Set(existingServerPosts.map { $0.serverId.lowercased() })
            let newPosts = combinedRawPosts.filter { !existingIds.contains($0.serverId.lowercased()) }
            
            let freshPostsDict = Dictionary(combinedRawPosts.map { ($0.serverId.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            let updatedExisting = existingServerPosts.compactMap { oldPost -> Post? in
                if let fresh = freshPostsDict[oldPost.serverId.lowercased()] { 
                    var copy = fresh
                    copy.id = oldPost.id
                    return copy 
                }
                return oldPost // Keep old paginated posts so the feed doesn't shrink!
            }
            
            var finalRaw = trulyPendingPosts + newPosts + updatedExisting

            // BUG FIX (2026-05-14): If the geo-bounded queries returned
            // zero posts (sparse area, new region, server cache miss),
            // fall back to the global Recommended feed instead of
            // showing "No posts yet". Notifications about new posts
            // (raven_news, follows, etc.) keep arriving via the
            // notifications endpoint, so an empty feed visibly
            // contradicts what the user expects. The recommended feed
            // is content-only (no geo filter) and works in any region.
            if combinedRawPosts.isEmpty && existingServerPosts.isEmpty {
                let userLang = Locale.current.language.languageCode?.identifier ?? "en"
                if let recommended: [Post] = try? await networkService.get(path: "/api/feed/recommended?lang=\(userLang)") {
                    #if DEBUG
                    print("📡 [FeedStore] Local + ForYou both empty → backfilling with \(recommended.count) recommended posts")
                    #endif
                    finalRaw = trulyPendingPosts + recommended.map { $0.withSource(.forYou) }
                }
            }

            // 🌟 Single RavenRank™ pass on the fully-merged set (was 2 passes before) 🌟
            let rankedPosts = await RavenRankEngine.shared.rankLocalFeed(
                posts: finalRaw,
                userLocation: self.currentLocation,
                currentUserId: myId,
                limit: max(1000, finalRaw.count) // Endless
            )
            
            // 4. Animate the new posts sliding in from the top
            #if DEBUG
            for p in rankedPosts {
                let hasVideoMedia = p.media?.contains(where: { $0.isVideo }) == true || p.allMedia.contains(where: { $0.isVideo })
                if hasVideoMedia || p.postType == "video" {
                    print("🎬🔍 [Feed→UI] VIDEO id=\(p.id.prefix(8)) postType='\(p.postType ?? "nil")' mediaCount=\(p.media?.count ?? 0) mediaTypes=\(p.media?.map({ "'\($0.mediaType ?? "nil")':\($0.url.suffix(20))" }) ?? []) imageUrl=\(p.imageUrl?.suffix(20) ?? "nil")")
                }
            }
            #endif
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                mergedLocalPosts = deduplicateByID(rankedPosts)
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
        isInitialLoadComplete = true
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
                
                // ⚡ PERF: Only rank the NEW page — don't re-sort the entire feed.
                // The existing feed is already ranked; appending a ranked page preserves order.
                let myId = AuthService.shared.currentUser?.id ?? ""
                let taggedNew = uniqueNewPosts.map { $0.withSource(.nearby) }
                
                // Lightweight rank pass on just the new page (not the whole feed)
                let rankedNew = await RavenRankEngine.shared.rankLocalFeed(
                    posts: taggedNew,
                    userLocation: self.currentLocation,
                    currentUserId: myId,
                    limit: taggedNew.count
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
                
                // ⚡ PERF: Only rank the NEW page — don't re-sort the entire friends feed.
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
        // BUG FIX (2026-05-14): The GPS-off fallback path used to
        // return without setting `isInitialLoadComplete`, which kept
        // the FeedView in its indeterminate state (no spinner, no
        // empty state, no posts). Mark the initial load done so the
        // view can render either the posts we just loaded or, in the
        // (rare) case the recommended endpoint also returned zero, the
        // "No posts yet" empty state — not a permanently blank screen.
        isInitialLoadComplete = true
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
            
            // --- SMART MERGE & DEDUPLICATION FOR FRIENDS FEED (LOWERCASE FIX) ---
            let serverPosts = response.items
            var serverPostBySignature: [String: Post] = [:]
            for post in serverPosts {
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
                if serverPosts.contains(where: { $0.serverId.lowercased() == pending.serverId.lowercased() }) { return false }
                return true
            }
            
            let existingIds = Set(existingServerPosts.map { $0.serverId.lowercased() })
            let newPosts = serverPosts.filter { !existingIds.contains($0.serverId.lowercased()) }
            
            let freshPostsDict = Dictionary(serverPosts.map { ($0.serverId.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            let updatedExisting = existingServerPosts.compactMap { oldPost -> Post? in
                if let fresh = freshPostsDict[oldPost.serverId.lowercased()] { 
                    var copy = fresh
                    copy.id = oldPost.id
                    return copy 
                }
                return oldPost 
            }
            
            let finalRaw = trulyPendingPosts + newPosts + updatedExisting
            
            // 🌟 Single RavenRank™ pass on the fully-merged set (was 2 passes before) 🌟
            let rankedFriendsPosts = await RavenRankEngine.shared.rankFriendsFeed(
                posts: finalRaw,
                currentUserId: myId,
                limit: max(1000, finalRaw.count)
            )
            
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                friendsPosts = deduplicateByID(rankedFriendsPosts)
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
        isInitialLoadComplete = true
    }
    
    // MARK: - Toggle Like (Optimistic + Single-Worker Convergence)
    //
    // Tapping the heart is a TOGGLE on the server (`POST /api/posts/{id}/like`
    // flips the state and returns the new `(isLiked, likes)`). With the old
    // implementation each rapid tap spawned its own Task; the responses came
    // back out of order and the UI visibly oscillated (the "delay / odd"
    // behaviour the user reported). The new flow:
    //
    //   1. Optimistically flip the UI on EVERY tap so feedback stays instant.
    //   2. Keep at most ONE network worker per post. A second tap arriving
    //      while a worker is in flight is absorbed by the worker's next loop
    //      iteration: it re-reads the latest UI desire and fires another
    //      toggle until the server's `isLiked` matches the user's intent.
    //   3. On hard network failure, rebuild the UI to whatever the server
    //      last reported (or revert to the captured initial state if no
    //      server response ever came back).
    func toggleLike(postId: String) async {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        // Skip client-side UUIDs (uppercase format) that haven't synced to server yet
        guard serverId.first?.isUppercase != true else {
            #if DEBUG
            print("⏭️ Skipping like for client-side post: \(serverId.prefix(8))...")
            #endif
            return
        }

        // Step 1 — Optimistic UI flip on every tap.
        let initialPost = findPost(byId: serverId)
        let initialLiked = initialPost?.isLiked ?? false
        let initialLikes = initialPost?.likes ?? 0
        updatePostInFeeds(postId: serverId) { post in
            var updated = post
            updated.likes = post.isLiked ? max(post.likes - 1, 0) : post.likes + 1
            updated.isLiked = !post.isLiked
            return updated
        }

        // Step 2 — Coalesce concurrent taps. If a worker is already
        // running, it'll observe the new optimistic state on its next
        // iteration; bail out so we don't spawn a second one.
        guard likeWorker[serverId] == nil else { return }

        likeWorker[serverId] = Task { [weak self] in
            await self?.runLikeConvergence(
                serverId: serverId,
                fallbackLiked: initialLiked,
                fallbackLikes: initialLikes
            )
            self?.likeWorker[serverId] = nil
        }
    }

    /// Loop POSTs to `/like` until the server's reported `isLiked` matches
    /// the latest optimistic UI desire, or we run out of retries / the
    /// network errors out (in which case we revert to `fallback*`).
    private func runLikeConvergence(
        serverId: String,
        fallbackLiked: Bool,
        fallbackLikes: Int
    ) async {
        // Cap at 4 iterations so a runaway tap-fest can't pin the loop
        // indefinitely. Four is enough to absorb a triple-tap burst
        // (one extra round-trip per non-matching tap) while still
        // bounded for telemetry.
        for _ in 0..<4 {
            let desiredLiked = findPost(byId: serverId)?.isLiked ?? fallbackLiked
            do {
                let response: LikeResponse = try await networkService.post(
                    path: "/api/posts/\(serverId)/like",
                    body: EmptyBody()
                )

                if response.isLiked == desiredLiked {
                    // Server matches user intent — apply final count + exit.
                    updatePostInFeeds(postId: serverId) { post in
                        var updated = post
                        updated.likes = response.likes
                        updated.isLiked = response.isLiked
                        return updated
                    }
                    #if DEBUG
                    print("❤️ \(response.action) post \(serverId) (converged)")
                    #endif
                    return
                }
                // Mismatch → user has tapped again since we fired. Loop
                // and toggle once more without touching the UI (which
                // already reflects the latest desire optimistically).
            } catch {
                #if DEBUG
                print("❌ Like error (reverting to initial): \(error)")
                #endif
                updatePostInFeeds(postId: serverId) { post in
                    var updated = post
                    updated.isLiked = fallbackLiked
                    updated.likes = fallbackLikes
                    return updated
                }
                Haptics.error()
                return
            }
        }
    }
    
    // MARK: - Toggle Repost (Optimistic + Single-Worker Convergence)
    //
    // Same pattern as `toggleLike`: only one in-flight worker per post,
    // optimistic UI flips on every tap, the worker re-reads the latest
    // optimistic state and converges with the server. Quote-reposts
    // (`quote != nil`) are NOT a pure toggle — they always create a new
    // post — so we keep the legacy single-shot path for them.
    func toggleRepost(postId: String, quote: String? = nil) async {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        guard serverId.first?.isUppercase != true else {
            #if DEBUG
            print("⏭️ Skipping repost for client-side post: \(serverId.prefix(8))...")
            #endif
            return
        }

        // Quote reposts mint a new post each time — never debounce.
        if quote != nil {
            await runRepostQuoteOnce(serverId: serverId, quote: quote)
            return
        }

        let initialPost = findPost(byId: serverId)
        let initialReposted = initialPost?.isReposted ?? false
        let initialReposts = initialPost?.reposts ?? 0

        updatePostInFeeds(postId: serverId) { post in
            var updated = post
            updated.reposts = post.isReposted ? max(post.reposts - 1, 0) : post.reposts + 1
            updated.isReposted = !post.isReposted
            return updated
        }

        guard repostWorker[serverId] == nil else { return }

        repostWorker[serverId] = Task { [weak self] in
            await self?.runRepostConvergence(
                serverId: serverId,
                fallbackReposted: initialReposted,
                fallbackReposts: initialReposts
            )
            self?.repostWorker[serverId] = nil
        }
    }

    /// Single-shot quote repost (legacy path). Each call mints a new
    /// quote post on the server; coalescing them would silently drop
    /// the user's content.
    private func runRepostQuoteOnce(serverId: String, quote: String?) async {
        let initialPost = findPost(byId: serverId)
        let initialReposted = initialPost?.isReposted ?? false
        let initialReposts = initialPost?.reposts ?? 0

        updatePostInFeeds(postId: serverId) { post in
            var updated = post
            updated.reposts = post.isReposted ? max(post.reposts - 1, 0) : post.reposts + 1
            updated.isReposted = !post.isReposted
            return updated
        }

        do {
            let response: RepostResponse = try await networkService.post(
                path: "/api/posts/\(serverId)/repost",
                body: RepostBody(content: quote)
            )
            updatePostInFeeds(postId: serverId) { post in
                var updated = post
                updated.reposts = response.reposts
                updated.isReposted = response.isReposted
                return updated
            }
        } catch {
            updatePostInFeeds(postId: serverId) { post in
                var updated = post
                updated.reposts = initialReposts
                updated.isReposted = initialReposted
                return updated
            }
            Haptics.error()
        }
    }

    private func runRepostConvergence(
        serverId: String,
        fallbackReposted: Bool,
        fallbackReposts: Int
    ) async {
        for _ in 0..<4 {
            let desiredReposted = findPost(byId: serverId)?.isReposted ?? fallbackReposted
            do {
                let response: RepostResponse = try await networkService.post(
                    path: "/api/posts/\(serverId)/repost",
                    body: RepostBody(content: nil)
                )
                if response.isReposted == desiredReposted {
                    updatePostInFeeds(postId: serverId) { post in
                        var updated = post
                        updated.reposts = response.reposts
                        updated.isReposted = response.isReposted
                        return updated
                    }
                    #if DEBUG
                    print("🔄 \(response.action) post \(serverId) (converged)")
                    #endif
                    return
                }
            } catch {
                #if DEBUG
                print("❌ Repost error (reverting to initial): \(error)")
                #endif
                updatePostInFeeds(postId: serverId) { post in
                    var updated = post
                    updated.isReposted = fallbackReposted
                    updated.reposts = fallbackReposts
                    return updated
                }
                Haptics.error()
                return
            }
        }
    }
    
    // MARK: - Record View (viewport-based, returns count without mutating feed)
    func recordView(postId: String) async -> Int? {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        // Skip client-side UUIDs (uppercase format) that haven't synced to server yet
        if serverId.first?.isUppercase == true { return nil }
        
        // Prevent duplicate view calls in same session (bounded — see
        // FIFO eviction below; keeps memory usage flat over long sessions).
        guard !viewedPostIdsSet.contains(serverId) else { return nil }
        viewedPostIdsSet.insert(serverId)
        viewedPostIds.append(serverId)
        if viewedPostIds.count > Self.maxViewedPostIds {
            // Drop oldest half so we amortise the work — single-element
            // removal would O(n)-shift the array on every view past the cap.
            let drop = viewedPostIds.prefix(Self.maxViewedPostIds / 2)
            viewedPostIdsSet.subtract(drop)
            viewedPostIds.removeFirst(drop.count)
        }
        
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
        let rawServerId = postId.components(separatedBy: "-loop-")[0]
        // Server stores UUIDs in canonical lowercase form; Swift's
        // `UUID().uuidString` produces UPPERCASE. If the post still
        // carries a Swift-generated id (failed/in-flight upload, or
        // the legacy bug where updatePost preserved the client-side
        // id), the path `DELETE /api/posts/<UPPERCASE>` returns 404.
        // Normalising here makes the call resilient regardless of
        // which form the in-memory model holds.
        let serverId = rawServerId.lowercased()
        // Skip client-side UUIDs that haven't synced. Detection:
        // if the ORIGINAL string contained any uppercase ASCII letter,
        // it can only be a Swift-generated id (server canonical
        // form is all-lowercase hex digits), so the post never
        // reached the server and we just drop it locally.
        let containsUppercaseLetter = rawServerId.contains { $0.isASCII && $0.isLetter && $0.isUppercase }
        if containsUppercaseLetter {
            removePostFromFeeds(postId: rawServerId)
            removePostFromFeeds(postId: serverId)
            #if DEBUG
            print("🗑️ Removed local draft post: \(rawServerId.prefix(8))...")
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

    // MARK: - Not Interested (local hide)
    /// Locally remove a post from every feed and remember the choice so we
    /// don't surface it again next session. Server-side reranking can be
    /// wired later — for now the user-visible behaviour matches Twitter's
    /// "Not interested" instantly hiding the card.
    func markNotInterested(postId: String) {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        removePostFromFeeds(postId: serverId)
        var hidden = Set(UserDefaults.standard.stringArray(forKey: "raven.feed.notInterested") ?? [])
        hidden.insert(serverId)
        UserDefaults.standard.set(Array(hidden), forKey: "raven.feed.notInterested")
    }

    // MARK: - Bookmark (server-backed + UserDefaults mirror)
    //
    // Bookmarks now live on the server (`POST /api/posts/{id}/bookmark`,
    // `DELETE …/bookmark`, `GET /api/posts/me/bookmarks`). The local
    // UserDefaults set is kept as a *cache* so:
    //   1) The button reflects the right state instantly on cold-start
    //      before the feed has loaded.
    //   2) Offline taps still flip the icon and survive a relaunch;
    //      the next online toggle reconciles with the server.
    private static let bookmarksKey = "raven.feed.bookmarks"

    /// Best-effort sync read. Prefers the server-backed
    /// `Post.isBookmarked` if the cached post knows it; falls back to
    /// the UserDefaults mirror.
    func isBookmarked(postId: String) -> Bool {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        if let post = findPost(byId: serverId), let server = post.isBookmarked {
            return server
        }
        let saved = UserDefaults.standard.stringArray(forKey: Self.bookmarksKey) ?? []
        return saved.contains(serverId)
    }

    /// Optimistic flip: updates the local mirror + cached Post and
    /// fires the server call. Returns the new state immediately so
    /// the UI button can show its colour without an `await`. If the
    /// network call fails the local state is rolled back and the
    /// caller (via the next body re-eval) sees the original value.
    @discardableResult
    func toggleBookmark(postId: String) -> Bool {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        let wasSaved = isBookmarked(postId: serverId)
        let nowSaved = !wasSaved

        // Mirror cache flip
        var saved = Set(UserDefaults.standard.stringArray(forKey: Self.bookmarksKey) ?? [])
        if nowSaved { saved.insert(serverId) } else { saved.remove(serverId) }
        UserDefaults.standard.set(Array(saved), forKey: Self.bookmarksKey)

        // Cached Post flip so the bar re-renders against the live state.
        updatePostInFeeds(postId: serverId) { post in
            var updated = post
            updated.isBookmarked = nowSaved
            return updated
        }

        // Server sync — best-effort. Skip if id is a client-side UUID
        // (still pending mesh→online sync).
        guard serverId.first?.isUppercase != true else { return nowSaved }
        let net = networkService
        Task { [weak self] in
            do {
                struct BookmarkResp: Decodable {
                    let status: String
                    let action: String?
                    let is_bookmarked: Bool?
                }
                if nowSaved {
                    let _: BookmarkResp = try await net.post(
                        path: "/api/posts/\(serverId)/bookmark",
                        body: EmptyBody()
                    )
                } else {
                    let _: BookmarkResp = try await net.delete(
                        path: "/api/posts/\(serverId)/bookmark"
                    )
                }
                _ = self
            } catch {
                // Roll back on failure so the icon doesn't lie.
                #if DEBUG
                print("❌ [Bookmark] sync failed, rolling back: \(error)")
                #endif
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    var rb = Set(UserDefaults.standard.stringArray(forKey: Self.bookmarksKey) ?? [])
                    if wasSaved { rb.insert(serverId) } else { rb.remove(serverId) }
                    UserDefaults.standard.set(Array(rb), forKey: Self.bookmarksKey)
                    self.updatePostInFeeds(postId: serverId) { post in
                        var updated = post
                        updated.isBookmarked = wasSaved
                        return updated
                    }
                }
            }
        }

        return nowSaved
    }

    // MARK: - Save Offline (local)
    private static let offlineKey = "raven.feed.savedOffline"
    func isSavedOffline(postId: String) -> Bool {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        let saved = UserDefaults.standard.stringArray(forKey: Self.offlineKey) ?? []
        return saved.contains(serverId)
    }
    @discardableResult
    func toggleSaveOffline(postId: String) -> Bool {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        var saved = Set(UserDefaults.standard.stringArray(forKey: Self.offlineKey) ?? [])
        let nowSaved: Bool
        if saved.contains(serverId) { saved.remove(serverId); nowSaved = false }
        else { saved.insert(serverId); nowSaved = true }
        UserDefaults.standard.set(Array(saved), forKey: Self.offlineKey)
        return nowSaved
    }
    
    // MARK: - Helper: Find post by ID across all feeds
    private func findPost(byId postId: String) -> Post? {
        return mergedLocalPosts.first(where: { $0.serverId == postId })
            ?? friendsPosts.first(where: { $0.serverId == postId })
            ?? recommendedPosts.first(where: { $0.serverId == postId })
    }

    /// Public lookup — used by views (e.g. the fullscreen video
    /// player) that need to render live like/repost counts. Hits the
    /// same `@Published` arrays as the private helper, so callers
    /// observing this `FeedStore` get re-rendered automatically when
    /// counts mutate.
    func livePost(byId postId: String) -> Post? {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        return findPost(byId: serverId)
    }

    /// Public read-only accessor for surfaces that need to display
    /// live post stats (likes / reposts / isLiked) — e.g. the
    /// fullscreen video player's bottom action bar. Reads from the
    /// same @Published arrays so SwiftUI re-renders observers when
    /// `toggleLike` / `toggleRepost` mutate state.
    func liveSnapshot(of postId: String) -> Post? {
        let serverId = postId.components(separatedBy: "-loop-")[0]
        return findPost(byId: serverId)
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

