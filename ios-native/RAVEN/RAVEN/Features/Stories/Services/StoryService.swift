import Foundation

// MARK: - Story Service
/// API client for Stories feature using NetworkService
@MainActor
final class StoryService: ObservableObject {
    static let shared = StoryService()
    
    private var baseURL: String { AppConfig.apiBaseURL }
    
    // MARK: - Published Properties
    @Published var myStories: [Story] = []
    
    private init() {}
    
    // MARK: - Fetch My Stories
    /// Fetch current user's stories and update local cache
    func fetchMyStories() async {
        do {
            myStories = try await getMyStories()
            #if DEBUG
            print("📸 [StoryService] Fetched \(myStories.count) my stories")
            #endif
        } catch {
            #if DEBUG
            print("📸 [StoryService] Failed to fetch my stories: \(error)")
            #endif
        }
    }
    
    // MARK: - Upload Media
    /// Upload story media (image/video) and return CDN URL
    func uploadStoryMedia(data: Data, filename: String = "story.jpg") async throws -> String {
        guard let url = AppConfig.apiURL(path: "/api/uploads/image") else {
            throw NSError(domain: "StoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Add auth token
        if let (token, _) = await KeychainService.shared.getToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // Build multipart body
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: image/jpeg\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")
        
        request.httpBody = body
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }
        
        // Parse response to get URL
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let imageUrl = json["image_url"] as? String {
            return imageUrl
        }
        
        throw NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid upload response"])
    }
    
    // MARK: - Create Story
    func createStory(
        mediaUrl: String,
        mediaType: String = "image",
        audience: String = "friends",
        isSingleView: Bool = false,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) async throws {
        let body = CreateStoryRequest(
            mediaUrl: mediaUrl,
            mediaType: mediaType,
            audience: audience,
            isSingleView: isSingleView,
            latitude: latitude,
            longitude: longitude
        )
        
        let _: StoryResponseBasic = try await NetworkService.shared.post(
            path: "/api/stories/create",
            body: body
        )
        
        let svTag = isSingleView ? " [SINGLE-VIEW]" : ""
        #if DEBUG
        print("📸 [StoryService] Story created successfully\(svTag)")
        #endif
    }
    
    // MARK: - Get Story Feed (Combined)
    func getStoryFeed() async throws -> [StoryAuthor] {
        return try await NetworkService.shared.get(path: "/api/stories/feed")
    }
    
    // MARK: - Get My Stories (all devices)
    /// Returns all of current user's stories regardless of audience
    func getMyStories() async throws -> [Story] {
        return try await NetworkService.shared.get(path: "/api/stories/mine")
    }
    
    // MARK: - Get Friends Feed
    /// Returns stories from friends with audience=friends
    func getFriendsFeed() async throws -> [Story] {
        return try await NetworkService.shared.get(path: "/api/stories/feed/friends")
    }
    
    // MARK: - Get Local Feed
    /// Returns stories with audience=local within radius
    func getLocalFeed(latitude: Double, longitude: Double) async throws -> [Story] {
        return try await NetworkService.shared.get(
            path: "/api/stories/feed/local?latitude=\(latitude)&longitude=\(longitude)"
        )
    }
    
    // MARK: - Get User Stories
    func getUserStories(userId: String) async throws -> [Story] {
        return try await NetworkService.shared.get(path: "/api/stories/user/\(userId)")
    }
    
    // MARK: - Mark Seen
    /// Mark a story as seen. For single-view stories, this will prevent future viewing.
    func markSeen(storyId: String, reason: String = "swipe") async throws {
        let body = MarkSeenRequest(reason: reason)
        let _: MarkSeenResponse = try await NetworkService.shared.post(
            path: "/api/stories/\(storyId)/seen",
            body: body
        )
    }
    
    // MARK: - Like Story
    func toggleLike(storyId: String) async throws -> Bool {
        let response: StoryLikeResponse = try await NetworkService.shared.post(
            path: "/api/stories/\(storyId)/like",
            body: EmptyBody()
        )
        return response.isLiked
    }
    
    // MARK: - Report Screenshot
    func reportScreenshot(storyId: String) async throws {
        let _: StoryEmptyResponse = try await NetworkService.shared.post(
            path: "/api/stories/\(storyId)/screenshot",
            body: EmptyBody()
        )
    }
    
    // MARK: - Reply to Story
    func reply(storyId: String, content: String) async throws {
        let _: StoryEmptyResponse = try await NetworkService.shared.post(
            path: "/api/stories/\(storyId)/reply",
            body: StoryReplyRequest(content: content)
        )
    }
    
    // MARK: - Delete Story
    /// Delete a story (only owner can delete)
    func deleteStory(storyId: String) async throws {
        let _: StoryEmptyResponse = try await NetworkService.shared.delete(
            path: "/api/stories/\(storyId)"
        )
        #if DEBUG
        print("🗑️ [StoryService] Story deleted: \(storyId)")
        #endif
        
        // Remove from local cache
        myStories.removeAll { $0.id == storyId }
    }
}

// MARK: - Request/Response Models

private struct CreateStoryRequest: Codable {
    let mediaUrl: String
    let mediaType: String
    let audience: String
    let isSingleView: Bool
    let latitude: Double?
    let longitude: Double?
}

private struct StoryReplyRequest: Codable {
    let content: String
}

private struct MarkSeenRequest: Codable {
    let reason: String
}

private struct EmptyBody: Codable {}

private struct StoryEmptyResponse: Codable {
    let ok: Bool?
}

private struct MarkSeenResponse: Codable {
    let ok: Bool
    let seenCount: Int?
    let isSingleView: Bool?
}

private struct StoryLikeResponse: Codable {
    let ok: Bool
    let action: String
    let isLiked: Bool
    let likeCount: Int
}

private struct StoryResponseBasic: Codable {
    let id: String
}

// MARK: - Public Models

struct StoryAuthor: Codable, Identifiable {
    let authorId: String
    let authorUsername: String
    let authorAvatar: String?
    let hasUnseen: Bool
    let storyCount: Int
    let latestStoryId: String
    let latestCreatedAt: Date
    
    var id: String { authorId }
}

struct Story: Codable, Identifiable {
    let id: String
    let authorId: String
    let authorUsername: String
    let authorAvatar: String?
    let mediaUrl: String
    let mediaType: String
    let audience: String  // "friends" or "local" (scope badge)
    let createdAt: Date
    let expiresAt: Date
    let seenCount: Int
    let isSeen: Bool
    let isLiked: Bool
    let isOwn: Bool
    
    // Optional with default - server may not send for older stories
    var isSingleView: Bool = false
    
    // Computed property for scope badge display
    var scopeBadgeText: String {
        audience == "friends" ? "Friend" : "Local"
    }
    
    // Custom decoding to handle nil isSingleView
    enum CodingKeys: String, CodingKey {
        case id, authorId, authorUsername, authorAvatar, mediaUrl, mediaType
        case audience, createdAt, expiresAt, seenCount, isSeen, isLiked, isOwn, isSingleView
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        authorId = try container.decode(String.self, forKey: .authorId)
        authorUsername = try container.decode(String.self, forKey: .authorUsername)
        authorAvatar = try container.decodeIfPresent(String.self, forKey: .authorAvatar)
        mediaUrl = try container.decode(String.self, forKey: .mediaUrl)
        mediaType = try container.decode(String.self, forKey: .mediaType)
        audience = try container.decode(String.self, forKey: .audience)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        seenCount = try container.decode(Int.self, forKey: .seenCount)
        isSeen = try container.decode(Bool.self, forKey: .isSeen)
        isLiked = try container.decode(Bool.self, forKey: .isLiked)
        isOwn = try container.decode(Bool.self, forKey: .isOwn)
        isSingleView = try container.decodeIfPresent(Bool.self, forKey: .isSingleView) ?? false
    }
    
    // Manual initializer for local creation
    init(id: String, authorId: String, authorUsername: String, authorAvatar: String?, 
         mediaUrl: String, mediaType: String, audience: String, isSingleView: Bool = false,
         createdAt: Date, expiresAt: Date, seenCount: Int, isSeen: Bool, isLiked: Bool, isOwn: Bool) {
        self.id = id
        self.authorId = authorId
        self.authorUsername = authorUsername
        self.authorAvatar = authorAvatar
        self.mediaUrl = mediaUrl
        self.mediaType = mediaType
        self.audience = audience
        self.isSingleView = isSingleView
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.seenCount = seenCount
        self.isSeen = isSeen
        self.isLiked = isLiked
        self.isOwn = isOwn
    }
}
