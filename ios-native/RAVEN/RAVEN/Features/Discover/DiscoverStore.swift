import SwiftUI
import Combine

/// DiscoverStore manages search state with debounce, cancellation, and pagination
@MainActor
final class DiscoverStore: ObservableObject {
    // MARK: - Published Properties
    @Published var query: String = ""
    @Published var accounts: [SearchUser] = []
    @Published var suggestedAccounts: [SearchUser] = []  // Combined contacts + algorithmic
    @Published var sentRequestIds: Set<String> = []  // Track sent friend requests
    @Published var friendIds: Set<String> = []  // Track existing friends
    @Published var posts: [Post] = []
    @Published var isLoadingAccounts = false
    @Published var isLoadingSuggestions = false
    @Published var isLoadingPosts = false
    @Published var accountsError: String?
    @Published var postsError: String?
    
    
    // MARK: - Show More Sheet
    @Published var showAllSuggestionsSheet = false
    @Published var allSuggestions: [SearchUser] = []  // Full list for sheet
    @Published var isLoadingAllSuggestions = false
    
    // MARK: - Pagination
    @Published var postsPage: Int = 0
    @Published var hasMorePosts = true
    private let postsLimit = 20
    
    // MARK: - Dependencies
    private let networkService: NetworkService
    
    // MARK: - Task Management (for cancellation)
    private var searchAccountsTask: Task<Void, Never>?
    private var searchPostsTask: Task<Void, Never>?
    
    // MARK: - Debounce
    private let debounceInterval: UInt64 = 300_000_000 // 300ms in nanoseconds
    
    // MARK: - Cache
    private static let cacheKey = "discovery_suggestions_cache"
    private static let cacheTimestampKey = "discovery_suggestions_timestamp"
    private static let cacheDuration: TimeInterval = 6 * 60 * 60 // 6 hours
    
    init(networkService: NetworkService = .shared) {
        self.networkService = networkService
        // Auto-load suggestions and friends on init
        Task {
            await loadFriends()
            await loadSuggestedAccounts()
        }
    }
    
    // MARK: - Load Friends List
    func loadFriends() async {
        do {
            let friends: [FriendInfo] = try await networkService.get(
                path: "/api/users/friends",
                queryItems: []
            )
            friendIds = Set(friends.map { $0.id })
            #if DEBUG
            print("👫 Loaded \(friends.count) friends")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to load friends: \(error)")
            #endif
        }
    }
    
    // MARK: - Load Suggested Accounts (from Discovery API)
    func loadSuggestedAccounts(forceRefresh: Bool = false) async {
        // Check cache first (unless force refresh)
        if !forceRefresh, let cached = loadFromCache() {
            suggestedAccounts = cached
            #if DEBUG
            print("👥 Loaded \(cached.count) suggestions from cache")
            #endif
            return
        }
        
        guard forceRefresh || suggestedAccounts.isEmpty else { return }
        
        isLoadingSuggestions = true
        
        do {
            let response: SuggestedFriendsResponse = try await networkService.get(
                path: "/api/discovery/suggested",
                queryItems: [
                    URLQueryItem(name: "limit", value: "10")
                ]
            )
            suggestedAccounts = response.items.map { item in
                SearchUser(
                    id: item.userId,
                    username: item.username,
                    displayName: item.displayName,
                    avatarUrl: item.avatarUrl,
                    isMutual: nil,
                    source: item.source,
                    reason: item.reason,
                    mutualFriendsCount: item.mutualFriendsCount
                )
            }
            
            // Save to cache
            saveToCache(suggestedAccounts)
            
            #if DEBUG
            print("👥 Loaded \(suggestedAccounts.count) suggestions from API")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to load suggestions: \(error)")
            #endif
        }
        
        isLoadingSuggestions = false
    }
    
    // MARK: - Load All Suggestions (for "Show more" sheet)
    func loadAllSuggestions() async {
        isLoadingAllSuggestions = true
        
        do {
            let response: SuggestedFriendsResponse = try await networkService.get(
                path: "/api/discovery/suggested",
                queryItems: [
                    URLQueryItem(name: "limit", value: "200")
                ]
            )
            allSuggestions = response.items.map { item in
                SearchUser(
                    id: item.userId,
                    username: item.username,
                    displayName: item.displayName,
                    avatarUrl: item.avatarUrl,
                    isMutual: nil,
                    source: item.source,
                    reason: item.reason,
                    mutualFriendsCount: item.mutualFriendsCount
                )
            }
            #if DEBUG
            print("👥 Loaded \(allSuggestions.count) suggestions for sheet")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to load all suggestions: \(error)")
            #endif
        }
        
        isLoadingAllSuggestions = false
    }
    
    // MARK: - Send Friend Request
    func sendFriendRequest(to userId: String) async {
        // ⚡ Optimistic: instantly mark as sent
        sentRequestIds.insert(userId)
        do {
            let _: DiscoverEmptyResponse = try await networkService.post(
                path: "/api/users/friend-request",
                body: DiscoverEmptyBody(),
                queryItems: [URLQueryItem(name: "recipient_id", value: userId)]
            )
            #if DEBUG
            print("✅ Friend request sent to \(userId)")
            #endif
        } catch {
            // Rollback on failure
            sentRequestIds.remove(userId)
            #if DEBUG
            print("❌ Friend request failed: \(error)")
            #endif
        }
    }
    
    // MARK: - Remove Friend
    func removeFriend(_ userId: String) async {
        // ⚡ Optimistic: remove from friends immediately
        friendIds.remove(userId)
        
        do {
            // Call DELETE API
            let response: RemoveFriendResponse = try await networkService.delete(
                path: "/api/users/friends/\(userId)"
            )
            
            #if DEBUG
            print("🗑️ Friend removed: \(userId) - \(response.message ?? "Success")")
            #endif
            
            // Reload friends list to ensure consistency
            await loadFriends()
            
            // Also refresh suggestions to update UI
            suggestedAccounts = []  // Clear cache
            clearCache()
            await loadSuggestedAccounts(forceRefresh: true)
            
        } catch {
            // Rollback on failure
            friendIds.insert(userId)
            #if DEBUG
            print("❌ Remove friend failed: \(error)")
            #endif
        }
    }
    
    // Response model for remove friend
    struct RemoveFriendResponse: Decodable {
        let success: Bool?
        let message: String?
    }
    
    // MARK: - Query Changed (with debounce & cancellation)
    func onQueryChange(_ newQuery: String) {
        // Cancel previous tasks
        searchAccountsTask?.cancel()
        searchPostsTask?.cancel()
        
        // Reset pagination
        postsPage = 0
        hasMorePosts = true
        
        // If empty query, load suggestions
        if newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accounts = []
            posts = []
            isLoadingAccounts = false
            isLoadingPosts = false
            return
        }
        
        // 🚀 Keep previous results visible until new ones arrive (no flicker)
        isLoadingAccounts = true
        isLoadingPosts = true
        
        // Debounced search for accounts
        searchAccountsTask = Task {
            do {
                try await Task.sleep(nanoseconds: debounceInterval)
                guard !Task.isCancelled else { return }
                await searchAccounts(query: newQuery)
            } catch {
                // Task was cancelled
            }
        }
        
        // Debounced search for posts
        searchPostsTask = Task {
            do {
                try await Task.sleep(nanoseconds: debounceInterval)
                guard !Task.isCancelled else { return }
                await searchPosts(query: newQuery, reset: true)
            } catch {
                // Task was cancelled
            }
        }
    }
    
    // MARK: - Search Accounts
    // ✅ FIX Bug 3: Removed defer { isLoadingAccounts = false } — it fires on
    // CancellationError, resetting loading while the new debounced request is still sleeping,
    // causing "No accounts found" to flicker during fast typing.
    func searchAccounts(query: String) async {
        isLoadingAccounts = true
        accountsError = nil
        
        do {
            let results: [SearchUser] = try await networkService.get(
                path: "/api/users/search",
                queryItems: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: "20")
                ]
            )
            
            if !Task.isCancelled {
                // Rank accounts: prefix match > exact match > contains match
                accounts = rankAccounts(results, query: query)
                isLoadingAccounts = false
                #if DEBUG
                print("🔍 Found \(accounts.count) accounts for '\(query)'")
                #endif
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if !Task.isCancelled {
                accountsError = "Failed to search accounts"
                isLoadingAccounts = false
                #if DEBUG
                print("❌ Accounts search error: \(error)")
                #endif
            }
        }
    }
    
    // MARK: - Search Posts
    // ✅ FIX Bug 3: Removed defer { isLoadingPosts = false } — same race condition fix.
    func searchPosts(query: String, reset: Bool = false) async {
        if reset {
            postsPage = 0
            hasMorePosts = true
        }
        
        guard hasMorePosts else { return }
        
        isLoadingPosts = true
        postsError = nil
        
        do {
            let offset = postsPage * postsLimit
            let results: [Post] = try await networkService.get(
                path: "/api/posts/search",
                queryItems: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: "\(postsLimit)"),
                    URLQueryItem(name: "offset", value: "\(offset)")
                ]
            )
            
            if !Task.isCancelled {
                if reset {
                    posts = results
                } else {
                    let existingIds = Set(posts.map { $0.id })
                    let uniqueNewPosts = results.filter { !existingIds.contains($0.id) }
                    posts.append(contentsOf: uniqueNewPosts)
                }
                
                hasMorePosts = results.count >= postsLimit
                postsPage += 1
                isLoadingPosts = false
                
                #if DEBUG
                print("🔍 Found \(results.count) posts for '\(query)' (page \(postsPage))")
                #endif
            }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if !Task.isCancelled {
                postsError = "Failed to search posts"
                isLoadingPosts = false
                #if DEBUG
                print("❌ Posts search error: \(error)")
                #endif
            }
        }
    }
    
    // MARK: - Load More Posts (for pagination)
    func loadMorePostsIfNeeded(currentPost: Post) {
        guard let lastPost = posts.last, lastPost.id == currentPost.id else {
            return
        }
        
        guard hasMorePosts, !isLoadingPosts, !query.isEmpty else {
            return
        }
        
        isLoadingPosts = true // Lock immediately to prevent duplicate requests
        
        // FIX: Cancel previous pagination task and track for cancellation on query change
        searchPostsTask?.cancel()
        searchPostsTask = Task {
            await searchPosts(query: query, reset: false)
        }
    }
    
    // MARK: - Account Ranking
    private func rankAccounts(_ accounts: [SearchUser], query: String) -> [SearchUser] {
        let lowercasedQuery = query.lowercased()
        
        return accounts.sorted { a, b in
            let aUsername = a.username.lowercased()
            let bUsername = b.username.lowercased()
            let aDisplay = a.displayName?.lowercased() ?? ""
            let bDisplay = b.displayName?.lowercased() ?? ""
            
            // Priority 1: Exact username match
            let aExact = aUsername == lowercasedQuery
            let bExact = bUsername == lowercasedQuery
            if aExact != bExact { return aExact }
            
            // Priority 2: Username prefix match
            let aPrefix = aUsername.hasPrefix(lowercasedQuery)
            let bPrefix = bUsername.hasPrefix(lowercasedQuery)
            if aPrefix != bPrefix { return aPrefix }
            
            // Priority 3: Display name prefix match
            let aDisplayPrefix = aDisplay.hasPrefix(lowercasedQuery)
            let bDisplayPrefix = bDisplay.hasPrefix(lowercasedQuery)
            if aDisplayPrefix != bDisplayPrefix { return aDisplayPrefix }
            
            // Priority 4: Username contains match
            let aContains = aUsername.contains(lowercasedQuery)
            let bContains = bUsername.contains(lowercasedQuery)
            if aContains != bContains { return aContains }
            
            // Fallback: alphabetical
            return aUsername < bUsername
        }
    }
    
    // MARK: - Cache Management
    
    private func saveToCache(_ users: [SearchUser]) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(users) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheTimestampKey)
        }
    }
    
    private func loadFromCache() -> [SearchUser]? {
        let timestamp = UserDefaults.standard.double(forKey: Self.cacheTimestampKey)
        guard timestamp > 0 else { return nil }
        
        let age = Date().timeIntervalSince1970 - timestamp
        guard age < Self.cacheDuration else {
            clearCache()
            return nil
        }
        
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode([SearchUser].self, from: data)
    }
    
    private func clearCache() {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        UserDefaults.standard.removeObject(forKey: Self.cacheTimestampKey)
    }
}

// MARK: - Helper Types
private struct DiscoverEmptyBody: Encodable {}
private struct DiscoverEmptyResponse: Decodable {}

struct FriendInfo: Decodable, Identifiable {
    let id: String
    let username: String
    let displayName: String?
    let avatarUrl: String?  // ✅ FIX Bug 4: Match server key
    // Note: CodingKeys removed - NetworkService uses .convertFromSnakeCase automatically
}

// MARK: - Discovery API Response Models

struct SuggestedFriendsResponse: Decodable {
    let items: [SuggestedUserItemResponse]
}

struct SuggestedUserItemResponse: Decodable {
    let userId: String
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let source: String?
    let reason: String?
    let mutualFriendsCount: Int?
}
