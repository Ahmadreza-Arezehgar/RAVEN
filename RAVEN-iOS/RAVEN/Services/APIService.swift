// RAVEN - API Service
// Converted from Flutter api_service.dart to Swift

import Foundation
import Combine

/// API Service for server communication (WiFi mode)
/// Equivalent to Flutter's ApiService
actor APIService {
    static let shared = APIService()
    
    // Production Server (Cloud Run)
    private let baseURL = "https://raven-server-5iwa2y5n3a-ww.a.run.app"
    
    private var token: String?
    
    private init() {
        // Load token from keychain on init
        token = KeychainHelper.get(key: "jwt_token")
    }
    
    // MARK: - Headers
    private var headers: [String: String] {
        var h = ["Content-Type": "application/json"]
        if let token = token {
            h["Authorization"] = "Bearer \(token)"
        }
        return h
    }
    
    func setToken(_ newToken: String?) {
        token = newToken
        if let t = newToken {
            KeychainHelper.save(key: "jwt_token", value: t)
        } else {
            KeychainHelper.delete(key: "jwt_token")
        }
    }
    
    // MARK: - Generic Request
    private func request<T: Decodable>(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        queryParams: [String: String]? = nil
    ) async throws -> T {
        var urlString = "\(baseURL)\(path)"
        
        if let params = queryParams {
            let query = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
            urlString += "?\(query)"
        }
        
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = 30
        
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        print("📬 [\(method)] \(path) → \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = errorJson["detail"] as? String {
                throw APIError.serverError(detail)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    // MARK: - Authentication
    
    /// Register new user
    func register(
        username: String,
        password: String,
        firstName: String,
        lastName: String,
        birthYear: Int,
        email: String?
    ) async throws -> AuthResponse {
        var body: [String: Any] = [
            "username": username,
            "password": password,
            "first_name": firstName,
            "last_name": lastName,
            "birth_year": birthYear
        ]
        if let email = email { body["email"] = email }
        
        let response: AuthResponse = try await request(method: "POST", path: "/api/auth/register", body: body)
        setToken(response.token)
        return response
    }
    
    /// Login existing user
    func login(username: String, password: String) async throws -> AuthResponse {
        let response: AuthResponse = try await request(
            method: "POST",
            path: "/api/auth/login",
            body: ["username": username, "password": password]
        )
        setToken(response.token)
        return response
    }
    
    /// OAuth Google
    func oauthGoogle(idToken: String) async throws -> AuthResponse {
        let response: AuthResponse = try await request(
            method: "POST",
            path: "/api/auth/oauth/google",
            body: ["id_token": idToken]
        )
        setToken(response.token)
        return response
    }
    
    /// OAuth Apple
    func oauthApple(identityToken: String, authorizationCode: String) async throws -> AuthResponse {
        let response: AuthResponse = try await request(
            method: "POST",
            path: "/api/auth/oauth/apple",
            body: ["identity_token": identityToken, "authorization_code": authorizationCode]
        )
        setToken(response.token)
        return response
    }
    
    /// Check username availability
    func checkUsername(_ username: String) async throws -> UsernameCheckResponse {
        try await request(method: "GET", path: "/api/auth/check-username", queryParams: ["username": username])
    }
    
    /// Send verification code
    func sendVerificationCode(identifier: String, channel: String, purpose: String) async throws {
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/api/auth/send-code",
            body: ["identifier": identifier, "channel": channel, "purpose": purpose]
        )
    }
    
    /// Verify code
    func verifyCode(identifier: String, code: String, purpose: String) async throws -> VerifyCodeResponse {
        try await request(
            method: "POST",
            path: "/api/auth/verify-code",
            body: ["identifier": identifier, "code": code, "purpose": purpose]
        )
    }
    
    // MARK: - User
    
    /// Get current user
    func getCurrentUser() async throws -> User {
        try await request(method: "GET", path: "/api/users/me")
    }
    
    /// Get user by ID
    func getUserById(_ userId: String) async throws -> User {
        try await request(method: "GET", path: "/api/users/\(userId)")
    }
    
    /// Search users
    func searchUsers(_ query: String) async throws -> [User] {
        try await request(method: "GET", path: "/api/users/search", queryParams: ["q": query])
    }
    
    /// Update profile
    func updateProfile(bio: String? = nil, hobbies: [String]? = nil) async throws -> User {
        var body: [String: Any] = [:]
        if let bio = bio { body["bio"] = bio }
        if let hobbies = hobbies { body["hobbies"] = hobbies }
        return try await request(method: "PATCH", path: "/api/users/me", body: body)
    }
    
    /// Update profile picture
    func updateProfilePicture(imageUrl: String) async throws -> Bool {
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/api/users/profile-picture",
            body: ["image_url": imageUrl]
        )
        return true
    }
    
    // MARK: - Messaging
    
    /// Send message
    func sendMessage(
        recipientId: String,
        content: String,
        messageId: String? = nil,
        messageType: String? = nil,
        mediaUrl: String? = nil,
        fileName: String? = nil,
        mimeType: String? = nil,
        replyToMessageId: String? = nil,
        replyToTextPreview: String? = nil,
        replyToSenderName: String? = nil,
        replyToType: String? = nil,
        sendMode: String = "instant",
        scheduledAtUtc: Date? = nil
    ) async throws -> Bool {
        var body: [String: Any] = [
            "recipient_id": recipientId,
            "content": content,
            "send_mode": sendMode
        ]
        
        if let id = messageId { body["message_id"] = id }
        if let type = messageType { body["message_type"] = type }
        if let url = mediaUrl { body["audio_url"] = url }
        if let name = fileName { body["file_name"] = name }
        if let mime = mimeType { body["mime_type"] = mime }
        if let replyId = replyToMessageId { body["reply_to_message_id"] = replyId }
        if let replyText = replyToTextPreview { body["reply_to_text_preview"] = replyText }
        if let replySender = replyToSenderName { body["reply_to_sender_name"] = replySender }
        if let replyType = replyToType { body["reply_to_type"] = replyType }
        if let scheduled = scheduledAtUtc { body["scheduled_at_utc"] = ISO8601DateFormatter().string(from: scheduled) }
        
        let _: EmptyResponse = try await request(method: "POST", path: "/api/messages/send", body: body)
        return true
    }
    
    /// Get inbox
    func getInbox(since: Date? = nil) async throws -> [MessageResponse] {
        var params: [String: String] = [:]
        if let since = since {
            params["since"] = ISO8601DateFormatter().string(from: since)
        }
        return try await request(method: "GET", path: "/api/messages/inbox", queryParams: params.isEmpty ? nil : params)
    }
    
    /// Get conversation messages
    func getMessages(with userId: String) async throws -> [MessageResponse] {
        try await request(method: "GET", path: "/api/messages/conversation/\(userId)")
    }
    
    // MARK: - Media Upload
    
    /// Upload image
    func uploadImage(data: Data, fileName: String) async throws -> String {
        let response: UploadResponse = try await uploadMultipart(
            path: "/api/uploads/image",
            fileData: data,
            fileName: fileName,
            mimeType: "image/jpeg"
        )
        return response.imageUrl ?? response.url ?? ""
    }
    
    /// Upload voice
    func uploadVoice(data: Data, fileName: String) async throws -> String {
        let response: UploadResponse = try await uploadMultipart(
            path: "/api/voice/upload",
            fileData: data,
            fileName: fileName,
            mimeType: "audio/mp4"
        )
        return response.audioUrl ?? response.url ?? ""
    }
    
    /// Upload file
    func uploadFile(data: Data, fileName: String, mimeType: String, onProgress: ((Double) -> Void)? = nil) async throws -> UploadResponse {
        try await uploadMultipart(path: "/api/uploads/file", fileData: data, fileName: fileName, mimeType: mimeType)
    }
    
    private func uploadMultipart<T: Decodable>(
        path: String,
        fileData: Data,
        fileName: String,
        mimeType: String
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }
        
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let defaultData = Data()
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? defaultData)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8) ?? defaultData)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8) ?? defaultData)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? defaultData)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.uploadFailed
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    // MARK: - Posts
    
    /// Get feed posts
    func getFeed(page: Int = 0, limit: Int = 20) async throws -> [Post] {
        try await request(method: "GET", path: "/api/posts/feed", queryParams: ["page": "\(page)", "limit": "\(limit)"])
    }
    
    /// Create post
    func createPost(content: String, mediaUrls: [String]? = nil) async throws -> Post {
        var body: [String: Any] = ["content": content]
        if let urls = mediaUrls { body["media_urls"] = urls }
        return try await request(method: "POST", path: "/api/posts", body: body)
    }
    
    /// Like/Unlike post
    func toggleLike(postId: String) async throws -> Bool {
        let _: EmptyResponse = try await request(method: "POST", path: "/api/posts/\(postId)/like")
        return true
    }
    
    /// Get post comments
    func getComments(postId: String) async throws -> [Comment] {
        try await request(method: "GET", path: "/api/posts/\(postId)/comments")
    }
    
    /// Add comment
    func addComment(postId: String, content: String, parentId: String? = nil) async throws -> Comment {
        var body: [String: Any] = ["content": content]
        if let parentId = parentId { body["parent_id"] = parentId }
        return try await request(method: "POST", path: "/api/posts/\(postId)/comments", body: body)
    }
    
    /// Search posts
    func searchPosts(_ query: String, sort: String = "latest") async throws -> [Post] {
        try await request(method: "GET", path: "/api/search/posts", queryParams: ["q": query, "sort": sort])
    }
    
    // MARK: - Discovery
    
    /// Get suggested users for discovery
    func getSuggestedUsers(limit: Int = 10) async throws -> [SuggestedUserItem] {
        let response: SuggestedFriendsResponse = try await request(
            method: "GET",
            path: "/api/discovery/suggested",
            queryParams: ["limit": "\(limit)"]
        )
        return response.items
    }
    
    // MARK: - Server Time
    
    /// Get server time for synchronization
    func getServerTime() async throws -> Date {
        let response: TimeResponse = try await request(method: "GET", path: "/api/time")
        return ISO8601DateFormatter().date(from: response.utc) ?? Date()
    }
    
    // MARK: - Blocking
    
    func blockUser(userId: String) async throws -> Bool {
        let _: EmptyResponse = try await request(method: "POST", path: "/api/users/\(userId)/block")
        return true
    }
    
    func unblockUser(userId: String) async throws -> Bool {
        let _: EmptyResponse = try await request(method: "POST", path: "/api/users/\(userId)/unblock")
        return true
    }
}

// MARK: - Response Models
struct AuthResponse: Codable {
    let token: String?
    let userId: String?
    let username: String?
    let needsUsername: Bool?
    let tempToken: String?
    
    enum CodingKeys: String, CodingKey {
        case token
        case userId = "user_id"
        case username
        case needsUsername = "needs_username"
        case tempToken = "temp_token"
    }
}

struct UsernameCheckResponse: Codable {
    let available: Bool
    let suggestion: String?
}

struct VerifyCodeResponse: Codable {
    let verified: Bool
}

struct MessageResponse: Codable {
    let id: String
    let senderId: String
    let senderName: String?
    let recipientId: String
    let content: String
    let timestamp: String
    let messageType: String?
    let audioUrl: String?
    let fileName: String?
    let mimeType: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case senderId = "sender_id"
        case senderName = "sender_name"
        case recipientId = "recipient_id"
        case content
        case timestamp
        case messageType = "message_type"
        case audioUrl = "audio_url"
        case fileName = "file_name"
        case mimeType = "mime_type"
    }
}

struct UploadResponse: Codable {
    let url: String?
    let imageUrl: String?
    let audioUrl: String?
    let fileUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case url
        case imageUrl = "image_url"
        case audioUrl = "audio_url"
        case fileUrl = "file_url"
    }
}

struct TimeResponse: Codable {
    let utc: String
}

struct EmptyResponse: Codable {}

struct SuggestedUserItem: Codable, Identifiable {
    let userId: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    let source: String
    let reason: String
    let mutualFriendsCount: Int
    
    var id: String { userId }
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case source
        case reason
        case mutualFriendsCount = "mutual_friends_count"
    }
}

struct SuggestedFriendsResponse: Codable {
    let items: [SuggestedUserItem]
}

// MARK: - API Errors
enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case httpError(Int)
    case serverError(String)
    case uploadFailed
    case decodingError
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .unauthorized: return "Unauthorized - please login again"
        case .httpError(let code): return "HTTP error \(code)"
        case .serverError(let message): return message
        case .uploadFailed: return "Upload failed"
        case .decodingError: return "Failed to decode response"
        }
    }
}
