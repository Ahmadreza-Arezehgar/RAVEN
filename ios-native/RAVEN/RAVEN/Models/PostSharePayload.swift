import Foundation

/// Payload for forwarded post messages
/// Embedded in ChatMessage.text as JSON when type == .postShare
struct PostSharePayload: Codable {
    let postId: String
    let authorId: String
    let authorUsername: String
    let textPreview: String      // First 140 chars
    let thumbUrl: String?
    let createdAt: Date
    
    /// Create payload from a Post
    init(from post: Post) {
        self.postId = post.serverId
        self.authorId = post.authorId
        self.authorUsername = post.authorUsername
        self.textPreview = String(post.content.prefix(140))
        self.thumbUrl = post.imageUrl
        self.createdAt = post.timestamp
    }
    
    /// Decode payload from JSON string
    static func decode(from jsonString: String) -> PostSharePayload? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PostSharePayload.self, from: data)
    }
    
    /// Encode payload to JSON string
    func encode() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
