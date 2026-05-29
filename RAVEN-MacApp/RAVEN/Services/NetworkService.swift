// NetworkService — talks to the same FastAPI backend the iOS app and
// the Flutter app use:
//
//     https://raven-server-516053629173.europe-west1.run.app
//
// On every authenticated request we attach the `Authorization: Bearer
// <access_token>` header. On 401 we attempt a single refresh-rotate via
// `/api/auth/refresh`; if that also fails we wipe the keychain and
// surface `AuthExpired` so the UI can drop back to the auth landing.

import Foundation

enum APIError: Error, LocalizedError {
    case http(Int, String)
    case decode(String)
    case authExpired
    case transport(Error)
    case malformedURL

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .decode(let m): return "Decode failed: \(m)"
        case .authExpired: return "Session expired. Please sign in again."
        case .transport(let e): return e.localizedDescription
        case .malformedURL: return "Request URL could not be constructed."
        }
    }
}

private extension URLComponents {
    /// Throws `APIError.malformedURL` instead of force-unwrapping.
    /// Force-unwraps on `URLComponents.url` are safe for the request
    /// shapes we use today — but a future path-component interpolation
    /// (a chat id with a `#`, a username with a space) would crash the
    /// app. This helper makes those crashes impossible.
    func unwrappedURL() throws -> URL {
        guard let u = url else { throw APIError.malformedURL }
        return u
    }
}

/// Single source of truth for the RAVEN API host. Lifted out of the
/// `NetworkService` actor so callers like `RealtimeEngine` (which need
/// the URL synchronously to build a WebSocket endpoint) don't have to
/// duplicate the string. Previously the constant lived in two places
/// and a server-side host change would silently diverge.
let ravenAPIBaseURL: URL = URL(string: "https://raven-server-516053629173.europe-west1.run.app")!

actor NetworkService {
    static let shared = NetworkService()

    let baseURL = ravenAPIBaseURL

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        // FastAPI emits naive `datetime` values like "2026-05-01T11:44:22.945753"
        // (no `Z`, microsecond precision). The default `.iso8601` is too strict
        // for that, so we decode via a custom strategy that tries the
        // ISO 8601 formatter with fractional seconds first, falls back to the
        // strict ISO 8601 form, and finally accepts a unix epoch number.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        // FastAPI's naive datetimes (no timezone, fractional seconds) need
        // an explicit DateFormatter — ISO8601DateFormatter rejects them.
        // The server sometimes emits a `T` separator (`2026-05-02T11:44:22.945`)
        // and sometimes a space (`2026-05-02 20:30:16.912600`). We accept
        // both by normalizing the space to `T` before parsing.
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(secondsFromGMT: 0)
        // After `trimFractionalSeconds` we always have 3-digit ms here.
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"

        let naiveSeconds = DateFormatter()
        naiveSeconds.locale = Locale(identifier: "en_US_POSIX")
        naiveSeconds.timeZone = TimeZone(secondsFromGMT: 0)
        naiveSeconds.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // Number?
            if let secs = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: secs)
            }
            let raw = try container.decode(String.self)
            // FastAPI emits microseconds (6 digits). Apple's DateFormatter
            // tops out at milliseconds (3) — extra digits flip the parsed
            // year into the year 12000 etc. We shave the fractional part
            // down to 3 digits before trying the formatters. Also bridge
            // space-separated datetimes by swapping in the canonical `T`.
            var normalized = trimFractionalSeconds(raw)
            if normalized.contains(" ") && !normalized.contains("T") {
                normalized = normalized.replacingOccurrences(of: " ", with: "T")
            }
            if let d = isoFractional.date(from: normalized) { return d }
            if let d = iso.date(from: normalized) { return d }
            if let d = naive.date(from: normalized) { return d }
            if let d = naiveSeconds.date(from: normalized) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(raw)"
            )
        }
        return d
    }()

    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Auth-free

    func login(username: String, password: String) async throws -> LoginResponse {
        try await post(path: "/api/auth/login",
                       body: ["username": username, "password": password],
                       authed: false)
    }

    func qrLoginInit() async throws -> QrInitResponse {
        try await post(path: "/api/auth/qr-login/init", body: EmptyBody(), authed: false)
    }

    func oauthApple(identityToken: String, authorizationCode: String) async throws -> OAuthTokenResponse {
        try await post(
            path: "/api/auth/oauth/apple",
            body: OAuthAppleRequest(identityToken: identityToken, authorizationCode: authorizationCode),
            authed: false
        )
    }

    func oauthGoogle(idToken: String) async throws -> OAuthTokenResponse {
        try await post(
            path: "/api/auth/oauth/google",
            body: OAuthGoogleRequest(idToken: idToken),
            authed: false
        )
    }

    func qrLoginPoll(sessionId: String, nonce: String) async throws -> QrPollResponse {
        let url = baseURL
            .appendingPathComponent("/api/auth/qr-login/poll/\(sessionId)")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "nonce", value: nonce)]
        var req = URLRequest(url: try comps.unwrappedURL())
        req.httpMethod = "GET"
        return try await perform(req)
    }

    // MARK: - Authed

    func currentUser() async throws -> User {
        try await get(path: "/api/users/me")
    }

    func feed() async throws -> [Post] {
        try await get(path: "/api/posts/feed")
    }

    /// `GET /api/posts/feed/friends` — posts only from people the user has
    /// accepted/followed. Returns a `PaginatedFeedResponse` wrapper or a
    /// bare array (the server shortcuts to `[]` when the user has no
    /// friends / no location). We accept both shapes.
    func feedFriends() async throws -> [Post] {
        try await getFlexibleFeed(path: "/api/posts/feed/friends")
    }

    /// `GET /api/posts/feed/local` — same dual-shape handling as
    /// `feedFriends()`. Without lat/lng query params the server returns a
    /// bare empty array (`[]`); with them, a paginated wrapper.
    func feedLocal() async throws -> [Post] {
        try await getFlexibleFeed(path: "/api/posts/feed/local")
    }

    /// Decode an endpoint that may return either `[Post]` or
    /// `{items: [Post], hasMore, nextOffset}` — both server shortcuts and
    /// the canonical paginated response are accepted.
    private func getFlexibleFeed(path: String) async throws -> [Post] {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        try await applyAuth(&req)
        let (data, _) = try await executeRaw(req)
        // Try the bare-array shape first (it's cheaper). Fall back to the
        // paginated wrapper if that fails.
        if let items = try? jsonDecoder.decode([Post].self, from: data) {
            return items
        }
        let wrapper = try jsonDecoder.decode(PaginatedFeed.self, from: data)
        return wrapper.items
    }

    /// `POST /api/posts/create` — text post.
    func createPost(content: String) async throws -> Post {
        try await post(path: "/api/posts/create",
                       body: ["content": content, "visibility": "public"])
    }

    /// `POST /api/posts/create` with one or more attached images. Each
    /// image is uploaded first via `uploadImage`; the URLs go into the
    /// `image_urls` legacy field so older clients render them too.
    func createPostWithImages(content: String, imageUrls: [String]) async throws -> Post {
        struct Body: Encodable {
            let content: String
            let visibility: String
            let image_urls: [String]
            let image_url: String?
        }
        let body = Body(
            content: content,
            visibility: "public",
            image_urls: imageUrls,
            image_url: imageUrls.first
        )
        return try await post(path: "/api/posts/create", body: body)
    }

    /// `PATCH /api/posts/{post_id}` — edit the post body (own posts only).
    @discardableResult
    func editPost(postId: String, content: String) async throws -> Post {
        try await patch(path: "/api/posts/\(postId)", body: ["content": content])
    }

    /// `DELETE /api/comments/{comment_id}` — author/post-owner can delete.
    func deleteComment(commentId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/comments/\(commentId)"))
        req.httpMethod = "DELETE"
        try await applyAuth(&req)
        _ = try await executeRaw(req)
    }

    /// `DELETE /api/posts/{post_id}` — only the post's author can delete.
    func deletePost(postId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/posts/\(postId)"))
        req.httpMethod = "DELETE"
        try await applyAuth(&req)
        _ = try await executeRaw(req)
    }

    /// `POST /api/posts/{post_id}/like` toggles like state. Returns the new
    /// likes count and whether the current user has liked.
    @discardableResult
    func toggleLike(postId: String) async throws -> ToggleLikeResponse {
        try await post(path: "/api/posts/\(postId)/like", body: EmptyBody())
    }

    /// `POST /api/comments/create` — top-level comment on a post.
    @discardableResult
    func createComment(postId: String, content: String) async throws -> CommentDTO {
        try await post(
            path: "/api/comments/create",
            body: ["post_id": postId, "content": content]
        )
    }

    /// `GET /api/comments/post/{post_id}` — newest first.
    func comments(forPost postId: String) async throws -> [CommentDTO] {
        try await get(path: "/api/comments/post/\(postId)")
    }

    /// `POST /api/comments/{comment_id}/vote` — `vote` is +1 / 0 / -1.
    /// Returns the new score and the user's vote after the toggle.
    @discardableResult
    func voteComment(commentId: String, vote: Int) async throws -> CommentVoteResponse {
        try await post(
            path: "/api/comments/\(commentId)/vote",
            body: ["vote": vote]
        )
    }

    /// `GET /api/messages/conversation/{other_user_id}` — full thread with
    /// another user, server applies the same auth + visibility rules as
    /// `/inbox`.
    func conversation(with otherUserId: String) async throws -> [Message] {
        try await get(path: "/api/messages/conversation/\(otherUserId)")
    }

    /// `GET /api/groups/{group_id}/messages` — messages in a group thread.
    func groupMessages(groupId: String) async throws -> [Message] {
        try await get(path: "/api/groups/\(groupId)/messages")
    }

    /// `POST /api/groups/{group_id}/messages` — send a text message to a
    /// group. Returns the persisted message echoed back so the client can
    /// optimistically prepend it.
    @discardableResult
    func sendGroupMessage(groupId: String, content: String) async throws -> Message {
        try await post(
            path: "/api/groups/\(groupId)/messages",
            body: ["content": content, "message_type": "text"]
        )
    }

    /// `GET /api/notifications` — recent notifications (likes, replies,
    /// follows). Empty array means caught up.
    func notifications() async throws -> [NotificationItem] {
        try await get(path: "/api/notifications")
    }

    /// `POST /api/notifications/{id}/read` — mark a single notification
    /// as read.
    func markNotificationRead(id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/notifications/\(id)/read",
            body: EmptyBody()
        )
    }

    /// `POST /api/notifications/read-all` — clear all unread notifications.
    func markAllNotificationsRead() async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/notifications/read-all",
            body: EmptyBody()
        )
    }

    /// `PATCH /api/users/me` — update profile fields. Only the keys in
    /// `fields` are sent; the server treats missing keys as "leave as-is".
    @discardableResult
    func updateProfile(_ fields: [String: String]) async throws -> User {
        try await patch(path: "/api/users/me", body: fields)
    }

    /// `GET /api/users/me/settings` — fetch notification + privacy
    /// preferences. Server returns a nested `{notification, privacy}` map.
    func fetchNotificationPreferences() async throws -> NotificationPreferences {
        let envelope: SettingsEnvelope = try await get(path: "/api/users/me/settings")
        return envelope.notification
    }

    /// `PATCH /api/users/notification-preferences` — partial update;
    /// missing keys leave server values untouched.
    @discardableResult
    func updateNotificationPreferences(_ patch: NotificationPreferences) async throws -> NotificationPreferences {
        let resp: NotificationPreferences = try await self.patch(
            path: "/api/users/notification-preferences",
            body: patch
        )
        return resp
    }

    /// `GET /api/linked-devices` — devices paired to the current account.
    func linkedDevices() async throws -> [LinkedDevice] {
        try await get(path: "/api/linked-devices")
    }

    /// `POST /api/linked-devices/{device_id}/revoke` — sign out the
    /// device and invalidate its tokens.
    func revokeLinkedDevice(deviceId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/linked-devices/\(deviceId)/revoke",
            body: EmptyBody()
        )
    }

    /// `POST /api/users/change-password` — current and new password.
    func changePassword(current: String, new: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/users/change-password",
            body: ["current_password": current, "new_password": new]
        )
    }

    /// `POST /api/users/profile-picture` — change the avatar to a URL the
    /// server already knows about (after `uploadImage`).
    @discardableResult
    func setAvatar(imageUrl: String) async throws -> User {
        try await post(
            path: "/api/users/profile-picture",
            body: ["image_url": imageUrl]
        )
    }

    /// `POST /api/uploads/voice` — multipart upload of a voice file
    /// (m4a / mp3 / wav / ogg / aac). Returns the CDN URL.
    func uploadVoice(data: Data, filename: String, mimeType: String = "audio/m4a") async throws -> String {
        let boundary = "raven-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/uploads/voice"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&req)

        var body = Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)
        req.httpBody = body

        let (respData, _) = try await executeRaw(req)
        struct UploadVoiceResponse: Decodable {
            let voiceUrl: String
            enum CodingKeys: String, CodingKey { case voiceUrl = "voice_url" }
        }
        let parsed = try JSONDecoder().decode(UploadVoiceResponse.self, from: respData)
        return parsed.voiceUrl
    }

    /// Send a voice DM message.
    @discardableResult
    func sendVoiceMessage(recipientId: String, audioUrl: String, durationSeconds: Int) async throws -> SentMessage {
        struct Body: Encodable {
            let recipient_id: String
            let content: String
            let message_type: String
            let audio_url: String
            let audio_duration_seconds: Int
        }
        return try await post(
            path: "/api/messages/send",
            body: Body(
                recipient_id: recipientId,
                content: "",
                message_type: "voice",
                audio_url: audioUrl,
                audio_duration_seconds: durationSeconds
            )
        )
    }

    /// Send a voice message to a group chat.
    @discardableResult
    func sendGroupVoiceMessage(groupId: String, audioUrl: String, durationSeconds: Int) async throws -> Message {
        struct Body: Encodable {
            let content: String
            let message_type: String
            let audio_url: String
            let audio_duration_seconds: Int
        }
        return try await post(
            path: "/api/groups/\(groupId)/messages",
            body: Body(
                content: "",
                message_type: "voice",
                audio_url: audioUrl,
                audio_duration_seconds: durationSeconds
            )
        )
    }

    /// `POST /api/uploads/image` — multipart upload of a local image file.
    /// Returns the CDN URL the server stored it at, ready to drop into a
    /// post body or a `PATCH /api/users/me` avatar update.
    func uploadImage(data: Data, filename: String, mimeType: String = "image/jpeg") async throws -> String {
        let boundary = "raven-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/uploads/image"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        try await applyAuth(&req)

        var body = Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)
        req.httpBody = body

        let (respData, _) = try await executeRaw(req)
        struct UploadImageResponse: Decodable {
            let imageUrl: String
            enum CodingKeys: String, CodingKey { case imageUrl = "image_url" }
        }
        let parsed = try JSONDecoder().decode(UploadImageResponse.self, from: respData)
        return parsed.imageUrl
    }

    /// `GET /api/messages/conversations` — proper conversation list. The
    /// `/inbox` endpoint actually returns flat messages; we used to call it
    /// here and it always failed to decode, hence the empty Messages tab.
    func inbox() async throws -> [ConversationSummary] {
        try await get(path: "/api/messages/conversations")
    }

    /// `GET /api/messages/inbox?since=<iso>` — flat list of new messages
    /// for incremental polling, used by `RealtimeEngine` as a fallback
    /// when the WebSocket isn't connected. Mirrors what the iOS production
    /// app polls.
    func inboxMessages(since: Date? = nil) async throws -> [Message] {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("/api/messages/inbox"),
            resolvingAgainstBaseURL: false
        )!
        if let since {
            // Server parses with `datetime.fromisoformat(s.replace('Z',
            // '+00:00'))` — emit a UTC ISO 8601 string with `Z`.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            comps.queryItems = [URLQueryItem(name: "since", value: f.string(from: since))]
        }
        var req = URLRequest(url: try comps.unwrappedURL())
        req.httpMethod = "GET"
        try await applyAuth(&req)
        return try await perform(req, authed: true)
    }

    /// `GET /api/mesh/pending-bridges?since=<iso>` — bridge envelopes
    /// stashed by other devices that haven't been picked up yet. Called
    /// on (re)connect to drain anything that arrived while we were away.
    /// Server stores opaque base64; the caller decides what to do with it.
    func pendingBridges(since: Date? = nil) async throws -> [PendingBridgeEnvelope] {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("/api/mesh/pending-bridges"),
            resolvingAgainstBaseURL: false
        )!
        if let since {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            comps.queryItems = [URLQueryItem(name: "since", value: f.string(from: since))]
        }
        var req = URLRequest(url: try comps.unwrappedURL())
        req.httpMethod = "GET"
        try await applyAuth(&req)
        let resp: PendingBridgesResponse = try await perform(req, authed: true)
        return resp.envelopes
    }

    func trendingHashtags() async throws -> [TrendingHashtag] {
        try await get(path: "/api/hashtags/trending")
    }

    /// `GET /api/search/posts?q=...` — full-text search across posts.
    /// Used by the Explore tab.
    func searchPosts(query: String) async throws -> [Post] {
        let url = baseURL.appendingPathComponent("/api/search/posts")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: try comps.unwrappedURL())
        req.httpMethod = "GET"
        try await applyAuth(&req)
        return try await perform(req, authed: true)
    }

    /// `GET /api/hashtags/posts/{hashtag}` — feed of posts under a tag.
    func postsForHashtag(_ tag: String) async throws -> [Post] {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        return try await get(path: "/api/hashtags/posts/\(cleaned)")
    }

    /// `GET /api/users/{user_id}` — full profile for a specific user.
    func userProfile(userId: String) async throws -> User {
        try await get(path: "/api/users/\(userId)")
    }

    /// `GET /api/users/friend-requests` — pending friend requests for me.
    func friendRequests() async throws -> [FriendRequestDTO] {
        try await get(path: "/api/users/friend-requests")
    }

    /// `POST /api/users/friend-request/{request_id}/accept`.
    func acceptFriendRequest(id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/users/friend-request/\(id)/accept",
            body: EmptyBody()
        )
    }

    /// `POST /api/users/friend-request/{request_id}/reject`.
    func rejectFriendRequest(id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/users/friend-request/\(id)/reject",
            body: EmptyBody()
        )
    }

    /// `POST /api/users/follow/{target_id}` — follow another user.
    func followUser(userId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(path: "/api/users/follow/\(userId)", body: EmptyBody())
    }

    /// `DELETE /api/users/follow/{target_id}` — unfollow.
    func unfollowUser(userId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/users/follow/\(userId)"))
        req.httpMethod = "DELETE"
        try await applyAuth(&req)
        _ = try await executeRaw(req)
    }

    /// `GET /api/posts/user/{user_id}` — posts authored by a specific user.
    func postsByUser(userId: String) async throws -> [Post] {
        try await get(path: "/api/posts/user/\(userId)")
    }

    // MARK: - Bell subscriptions (per-user notification preferences)
    //
    // Mirrors the iOS-side `ProfileBellSettingsSheet` plumbing. Lets
    // the user opt into push notifications for a specific other user
    // — separately for posts and audio rooms — via the `bell` icon on
    // that user's profile.
    //
    // Server endpoints (see `server/routers/notifications.py`):
    //   GET    /api/notifications/subscriptions/{target_id} → state
    //   POST   /api/notifications/subscriptions/{target_id} → upsert
    //   DELETE /api/notifications/subscriptions/{target_id} → off

    func bellSubscription(userId: String) async throws -> BellSubscriptionResponse {
        try await get(path: "/api/notifications/subscriptions/\(userId)")
    }

    @discardableResult
    func setBellSubscription(
        userId: String,
        notifyPosts: Bool,
        notifyAudioRooms: Bool
    ) async throws -> BellSubscriptionResponse {
        struct Body: Encodable {
            let notify_posts: Bool
            let notify_audio_rooms: Bool
        }
        return try await post(
            path: "/api/notifications/subscriptions/\(userId)",
            body: Body(notify_posts: notifyPosts, notify_audio_rooms: notifyAudioRooms)
        )
    }

    /// Remove the bell subscription entirely (both `notify_posts` and
    /// `notify_audio_rooms` go off, the row is deleted server-side).
    func deleteBellSubscription(userId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/notifications/subscriptions/\(userId)"))
        req.httpMethod = "DELETE"
        try await applyAuth(&req)
        _ = try await executeRaw(req)
    }

    /// `/api/users/search?q=` — used by the compose-message flow to resolve
    /// a `@handle` into a user id when sending DMs.
    func searchUsers(query: String) async throws -> [User] {
        let url = baseURL
            .appendingPathComponent("/api/users/search")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        var req = URLRequest(url: try comps.unwrappedURL())
        req.httpMethod = "GET"
        try await applyAuth(&req)
        return try await perform(req, authed: true)
    }

    /// `POST /api/messages/send` — direct-message a user by id. Optional
    /// reply metadata is forwarded so the server can echo it back to the
    /// recipient and the recipient's bubble can render the quote.
    ///
    /// `messageId` is a client-generated UUID. The server adopts it as
    /// the row id (`Message(id=req.message_id)`) and uses it for
    /// idempotency: a retry with the same id returns the existing row
    /// instead of creating a duplicate. Forwarding it also lets
    /// `ChatStore` insert an optimistic local row with the same id and
    /// have it collapse cleanly when `reload()` returns the canonical
    /// version.
    @discardableResult
    func sendMessage(
        recipientId: String,
        content: String,
        messageId: String? = nil,
        replyToMessageId: String? = nil,
        replyToTextPreview: String? = nil,
        replyToSenderName: String? = nil,
        replyToType: String? = nil,
        expiryMode: String? = nil,
        sendMode: String? = nil,
        scheduledAtUtc: Date? = nil
    ) async throws -> SentMessage {
        struct Body: Encodable {
            let message_id: String?
            let recipient_id: String
            let content: String
            let message_type: String
            let reply_to_message_id: String?
            let reply_to_text_preview: String?
            let reply_to_sender_name: String?
            let reply_to_type: String?
            let expiry_mode: String?
            let send_mode: String?
            let scheduled_at_utc: Date?
        }
        return try await post(
            path: "/api/messages/send",
            body: Body(
                message_id: messageId,
                recipient_id: recipientId,
                content: content,
                message_type: "text",
                reply_to_message_id: replyToMessageId,
                reply_to_text_preview: replyToTextPreview,
                reply_to_sender_name: replyToSenderName,
                reply_to_type: replyToType,
                expiry_mode: expiryMode,
                send_mode: sendMode,
                scheduled_at_utc: scheduledAtUtc
            )
        )
    }

    // MARK: - Message actions (edit, delete, react, pin, save, transcribe)

    /// `PATCH /api/messages/{message_id}` — edit own text message. Returns
    /// the updated content + edited_at.
    @discardableResult
    func editMessage(messageId: String, content: String) async throws -> EditedMessage {
        try await patch(
            path: "/api/messages/\(messageId)",
            body: ["content": content]
        )
    }

    /// `DELETE /api/messages/{message_id}` — delete-for-everyone (only the
    /// sender is allowed by the server).
    func deleteMessage(messageId: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/messages/\(messageId)"))
        req.httpMethod = "DELETE"
        try await applyAuth(&req)
        _ = try await executeRaw(req)
    }

    /// `POST /api/messages/{message_id}/reactions` — toggle a reaction.
    /// Returns the updated reactions list and "added"/"removed".
    @discardableResult
    func toggleReaction(messageId: String, emoji: String, isGroup: Bool = false) async throws -> ReactionToggleResponse {
        struct Body: Encodable {
            let emoji: String
            let is_group: Bool
        }
        return try await post(
            path: "/api/messages/\(messageId)/reactions",
            body: Body(emoji: emoji, is_group: isGroup)
        )
    }

    /// `GET /api/messages/{message_id}/reactions` — current reactions.
    func reactions(messageId: String, isGroup: Bool = false) async throws -> [MessageReactionRow] {
        let url = baseURL.appendingPathComponent("/api/messages/\(messageId)/reactions")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "is_group", value: isGroup ? "true" : "false")]
        var req = URLRequest(url: try comps.unwrappedURL())
        req.httpMethod = "GET"
        try await applyAuth(&req)
        let resp: ReactionListResponse = try await perform(req, authed: true)
        return resp.reactions
    }

    /// `POST /api/messages/{message_id}/pin` — pin or unpin.
    @discardableResult
    func togglePin(messageId: String, pinned: Bool, isGroup: Bool = false) async throws -> PinToggleResponse {
        struct Body: Encodable {
            let pinned: Bool
            let is_group: Bool
        }
        return try await post(
            path: "/api/messages/\(messageId)/pin",
            body: Body(pinned: pinned, is_group: isGroup)
        )
    }

    /// `GET /api/messages/conversation/{peer_id}/pinned` — DM pins.
    func pinnedDM(peerId: String) async throws -> [PinnedMessage] {
        try await get(path: "/api/messages/conversation/\(peerId)/pinned")
    }

    /// `GET /api/messages/group/{group_id}/pinned` — group pins.
    func pinnedGroup(groupId: String) async throws -> [PinnedMessage] {
        try await get(path: "/api/messages/group/\(groupId)/pinned")
    }

    /// `POST /api/messages/{message_id}/save` — bookmark a message.
    @discardableResult
    func saveMessage(messageId: String, isGroup: Bool = false) async throws -> SaveActionResponse {
        try await post(
            path: "/api/messages/\(messageId)/save",
            body: ["is_group": isGroup]
        )
    }

    /// `DELETE /api/messages/{message_id}/save?is_group=…` — remove bookmark.
    func unsaveMessage(messageId: String, isGroup: Bool = false) async throws {
        let url = baseURL.appendingPathComponent("/api/messages/\(messageId)/save")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "is_group", value: isGroup ? "true" : "false")]
        var req = URLRequest(url: try comps.unwrappedURL())
        req.httpMethod = "DELETE"
        try await applyAuth(&req)
        _ = try await executeRaw(req)
    }

    /// `GET /api/messages/saved` — user's saved-messages collection.
    func savedMessages() async throws -> [SavedMessageItem] {
        try await get(path: "/api/messages/saved")
    }

    /// `POST /api/messages/{id}/transcribe` — kick off voice transcription.
    @discardableResult
    func transcribeVoice(messageId: String) async throws -> TranscribeResponse {
        try await post(
            path: "/api/messages/\(messageId)/transcribe",
            body: EmptyBody()
        )
    }

    /// `GET /api/messages/{id}/transcript` — fetch finished transcript text.
    func voiceTranscript(messageId: String) async throws -> TranscribeResponse {
        try await get(path: "/api/messages/\(messageId)/transcript")
    }

    // MARK: - Read receipts / typing

    /// `POST /api/messages/read` — mark messages from `peerId` as read.
    /// Pass `messageIds` to read just a subset; nil reads the whole thread.
    func markRead(peerId: String, messageIds: [String]? = nil) async throws {
        struct Body: Encodable {
            let room_id: String
            let message_ids: [String]?
            let is_stealth: Bool
        }
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/messages/read",
            body: Body(room_id: peerId, message_ids: messageIds, is_stealth: false)
        )
    }

    /// `POST /api/messages/read-all` — mark every unread message in every
    /// thread as read. Used by the inbox "Mark all as read" action.
    func markAllRead() async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/messages/read-all",
            body: EmptyBody()
        )
    }

    /// `POST /api/messages/typing` — fire-and-forget typing indicator.
    func sendTyping(peerId: String, isTyping: Bool, isGroup: Bool = false) async throws {
        struct Body: Encodable {
            let peer_id: String
            let is_typing: Bool
            let is_group: Bool
        }
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/messages/typing",
            body: Body(peer_id: peerId, is_typing: isTyping, is_group: isGroup)
        )
    }

    // MARK: - Conversation actions

    /// `POST /api/messages/conversations/mute` — mute a 1:1 conversation.
    func muteConversation(peerId: String, muted: Bool) async throws {
        struct Body: Encodable {
            let peer_id: String
            let muted: Bool
        }
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/messages/conversations/mute",
            body: Body(peer_id: peerId, muted: muted)
        )
    }

    /// `POST /api/messages/conversations/delete` — delete a 1:1
    /// conversation (one-sided; peer still has it).
    func deleteConversation(peerId: String) async throws {
        struct Body: Encodable { let peer_id: String }
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/messages/conversations/delete",
            body: Body(peer_id: peerId)
        )
    }

    // MARK: - Search / unread / lookup

    /// `GET /api/messages/search?peer_id=…&q=…` — full-text DM search.
    func searchMessages(peerId: String, query: String, limit: Int = 50) async throws -> [SearchMatch] {
        let url = baseURL.appendingPathComponent("/api/messages/search")
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "peer_id", value: peerId),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        var req = URLRequest(url: try comps.unwrappedURL())
        req.httpMethod = "GET"
        try await applyAuth(&req)
        let resp: SearchMatchesResponse = try await perform(req, authed: true)
        return resp.matches
    }

    /// `GET /api/messages/unread` — flat list of every unread message
    /// across all threads (used for the global unread badge).
    func unreadMessages() async throws -> [Message] {
        try await get(path: "/api/messages/unread")
    }

    /// `GET /api/messages/lookup/{message_id}` — look up a single message
    /// by id (used by deep-link / search-jump flows).
    func lookupMessage(_ id: String) async throws -> Message {
        try await get(path: "/api/messages/lookup/\(id)")
    }

    // MARK: - Group settings

    /// `POST /api/groups/{group_id}/leave` — leave a group.
    func leaveGroup(groupId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/groups/\(groupId)/leave",
            body: EmptyBody()
        )
    }

    /// `GET /api/groups/{group_id}` — full group metadata + member list.
    func groupDetails(groupId: String) async throws -> GroupDetails {
        try await get(path: "/api/groups/\(groupId)")
    }

    // MARK: - Presence

    /// `GET /api/users/{id}/presence` — online status. Returns nil if the
    /// server doesn't expose presence yet (404), so the UI can degrade
    /// gracefully.
    func presence(userId: String) async throws -> PresenceInfo? {
        do {
            return try await get(path: "/api/users/\(userId)/presence")
        } catch APIError.http(404, _) {
            return nil
        }
    }

    // MARK: - Message requests

    /// `POST /api/message-requests/{request_id}/accept` — accept incoming
    /// DM request from an unknown user.
    func acceptMessageRequest(requestId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/message-requests/\(requestId)/accept",
            body: EmptyBody()
        )
    }

    func declineMessageRequest(requestId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/message-requests/\(requestId)/decline",
            body: EmptyBody()
        )
    }

    func blockMessageRequest(requestId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await post(
            path: "/api/message-requests/\(requestId)/block",
            body: EmptyBody()
        )
    }

    /// Send a 1:1 image message. The server's `SendMessageRequest`
    /// re-purposes `audio_url` for image URLs when `message_type: "image"`,
    /// matching the iOS client's behavior.
    @discardableResult
    func sendImageMessage(recipientId: String, imageUrl: String) async throws -> SentMessage {
        struct Body: Encodable {
            let recipient_id: String
            let content: String
            let message_type: String
            let audio_url: String
        }
        return try await post(
            path: "/api/messages/send",
            body: Body(
                recipient_id: recipientId,
                content: "",
                message_type: "image",
                audio_url: imageUrl
            )
        )
    }

    /// Send an image to a group chat.
    @discardableResult
    func sendGroupImageMessage(groupId: String, imageUrl: String) async throws -> Message {
        struct Body: Encodable {
            let content: String
            let message_type: String
            let audio_url: String
        }
        return try await post(
            path: "/api/groups/\(groupId)/messages",
            body: Body(content: "", message_type: "image", audio_url: imageUrl)
        )
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(path: String, authed: Bool = true) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        if authed { try await applyAuth(&req) }
        return try await perform(req, authed: authed)
    }

    private func post<B: Encodable, T: Decodable>(
        path: String,
        body: B,
        authed: Bool = true
    ) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try jsonEncoder.encode(body)
        if authed { try await applyAuth(&req) }
        return try await perform(req, authed: authed)
    }

    private func patch<B: Encodable, T: Decodable>(
        path: String,
        body: B,
        authed: Bool = true
    ) async throws -> T {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try jsonEncoder.encode(body)
        if authed { try await applyAuth(&req) }
        return try await perform(req, authed: authed)
    }

    private func applyAuth(_ req: inout URLRequest) async throws {
        if let token = KeychainService.shared.read(.accessToken), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Send `req`, honor the refresh-rotate-on-401 contract, and return
    /// the raw response body. Used by `perform` (decoded JSON) and by the
    /// few endpoints that decode the body their own way: multipart upload
    /// responses, the flexible feed (array OR wrapper), and void
    /// DELETEs that don't have a body to decode at all.
    ///
    /// The caller is responsible for building `req` and applying the
    /// initial auth header — on a 401 retry we strip the stale header
    /// off the captured request and re-apply with the rotated token.
    private func executeRaw(_ req: URLRequest, authed: Bool = true, allowRefresh: Bool = true) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw APIError.http(0, "no response")
            }
            // 401 from an authed call means our access token went stale.
            // First-attempt path: try a single refresh-rotate, re-attach
            // the new bearer, and replay the request once. If the refresh
            // itself fails with 401 we wipe and surface `authExpired` so
            // the caller can drop back to the auth landing.
            //
            // 401 from an unauthed call (login, register, OAuth exchange)
            // means "wrong credentials" — same status code, very different
            // user-facing message. We branch here so AuthService can
            // `friendly()` them differently.
            if http.statusCode == 401 && authed {
                if allowRefresh {
                    try await attemptRefresh()
                    var retry = req
                    retry.setValue(nil, forHTTPHeaderField: "Authorization")
                    try await applyAuth(&retry)
                    return try await executeRaw(retry, authed: authed, allowRefresh: false)
                }
                throw APIError.authExpired
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw APIError.http(http.statusCode, body)
            }
            return (data, http)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error)
        }
    }

    private func perform<T: Decodable>(_ req: URLRequest, authed: Bool = false, allowRefresh: Bool = true) async throws -> T {
        let (data, _) = try await executeRaw(req, authed: authed, allowRefresh: allowRefresh)
        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            throw APIError.decode("\(error)")
        }
    }

    // MARK: - Token refresh
    //
    // The header doc-comment promised refresh-rotate on 401; this is
    // the missing implementation. Single-flight via a stored Task —
    // concurrent 401s all await the same in-flight refresh, so we don't
    // burn the rotating refresh token by racing N parallel POSTs.

    private var refreshTask: Task<Void, Error>?

    private func attemptRefresh() async throws {
        if let existing = refreshTask {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { try await performRefresh() }
        refreshTask = task
        do {
            try await task.value
            refreshTask = nil
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func performRefresh() async throws {
        guard let refreshToken = KeychainService.shared.read(.refreshToken),
              !refreshToken.isEmpty else {
            // No refresh token to spend — caller must re-auth.
            throw APIError.authExpired
        }
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/auth/refresh"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try jsonEncoder.encode(["refresh_token": refreshToken])

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            // Network blip — keep the refresh token, propagate as
            // transport so the caller surfaces "Couldn't reach server"
            // rather than forcing a logout.
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.http(0, "no response")
        }
        if http.statusCode == 401 {
            // Refresh token genuinely rejected — wipe so we don't loop
            // and signal the caller to bounce to the auth landing.
            KeychainService.shared.wipe()
            throw APIError.authExpired
        }
        guard (200...299).contains(http.statusCode) else {
            // Server hiccup — don't wipe, let the user retry.
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let body = try jsonDecoder.decode(RefreshResponse.self, from: data)
        KeychainService.shared.set(body.token, for: .accessToken)
        if let rotated = body.refreshToken, !rotated.isEmpty {
            // Server rotates refresh tokens on every successful refresh
            // (one-shot use). If we drop the new one we'll fail the next
            // refresh — so persist before returning.
            KeychainService.shared.set(rotated, for: .refreshToken)
        }
    }

    // MARK: - Group polls
    //
    // The macOS app currently doesn't compose polls (groups are still
    // one-tap from iOS) but it DOES need to render the live tally + cast
    // votes when a poll-typed message lands in a group thread.

    /// `GET /api/groups/{group_id}/polls/{poll_id}` — full state of one
    /// poll (options, vote counts, my_votes, is_closed).
    func getPoll(groupId: String, pollId: String) async throws -> PollDTO {
        try await get(path: "/api/groups/\(groupId)/polls/\(pollId)")
    }

    /// `POST /api/groups/{group_id}/polls/{poll_id}/vote` — cast a vote on
    /// a poll option. Server returns the updated `PollDTO`.
    @discardableResult
    func votePoll(groupId: String, pollId: String, optionId: String) async throws -> PollDTO {
        try await post(
            path: "/api/groups/\(groupId)/polls/\(pollId)/vote",
            body: ["option_id": optionId]
        )
    }

    /// `POST /api/groups/{group_id}/polls/{poll_id}/close` — creator-only
    /// freeze of the tally. Returns the closed `PollDTO`.
    @discardableResult
    func closePoll(groupId: String, pollId: String) async throws -> PollDTO {
        try await post(
            path: "/api/groups/\(groupId)/polls/\(pollId)/close",
            body: EmptyBody()
        )
    }
}

// MARK: - DTOs

struct EmptyBody: Encodable {}

/// Server response for `GET /api/notifications/subscriptions/{userId}`.
/// `subscribed` is the master flag (true when ANY toggle is on); the
/// two individual flags drive the UI toggles directly.
struct BellSubscriptionResponse: Decodable {
    let subscribed: Bool
    let notifyPosts: Bool
    let notifyAudioRooms: Bool

    enum CodingKeys: String, CodingKey {
        case subscribed
        case notifyPosts = "notify_posts"
        case notifyAudioRooms = "notify_audio_rooms"
    }
}

struct LoginResponse: Decodable {
    let userId: String
    let username: String
    let token: String
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case token
        case refreshToken = "refresh_token"
    }
}

/// `POST /api/auth/refresh` response. The server may emit a rotated
/// refresh token whenever the prior one was the DB-backed opaque
/// variety; legacy JWT refresh tokens come back without rotation.
struct RefreshResponse: Decodable {
    let token: String
    let tokenType: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
    }
}

/// `POST /api/auth/oauth/apple` request payload — matches the FastAPI
/// `OAuthAppleRequest` model in `server/routers/auth.py`.
struct OAuthAppleRequest: Encodable {
    let identityToken: String
    let authorizationCode: String

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
    }
}

/// `POST /api/auth/oauth/google` request payload.
struct OAuthGoogleRequest: Encodable {
    let idToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}

/// Response from the OAuth Apple/Google endpoints. Differs from the email
/// `LoginResponse` only in that `username` may be null when the OAuth user
/// hasn't picked a handle yet — in that case `requiresUsername` is true.
struct OAuthTokenResponse: Decodable {
    let userId: String
    let username: String?
    let token: String
    let refreshToken: String?
    let requiresUsername: Bool?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case token
        case refreshToken = "refresh_token"
        case requiresUsername = "requires_username"
    }
}

struct QrInitResponse: Decodable {
    let sessionId: String
    let nonce: String
    let expiresAt: Date
}

struct QrPollResponse: Decodable {
    let status: String
    let token: String?
    let refreshToken: String?
    let userId: String?
    let username: String?
}

/// `GET /api/mesh/pending-bridges` row — opaque base64-encoded mesh
/// envelope that was uplinked by a bridging device. We don't decrypt
/// these on the App Store build (no E2E key infrastructure inside the
/// sandbox), but we ack reception via idempotency_key so we don't re-
/// process the same envelope across reconnects.
struct PendingBridgeEnvelope: Decodable, Equatable {
    let idempotencyKey: String
    let envelopeB64: String
    let bridgedAt: Date

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case envelopeB64 = "envelope_b64"
        case bridgedAt = "bridged_at"
    }
}

struct PendingBridgesResponse: Decodable {
    let envelopes: [PendingBridgeEnvelope]
}

/// `PATCH /api/messages/{id}` response — the new content + edited_at
/// stamp. Both come back snake_case from the server.
struct EditedMessage: Decodable {
    let id: String
    let content: String
    let editedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case content
        case editedAt = "edited_at"
    }
}

/// `POST /api/messages/{id}/reactions` response.
struct ReactionToggleResponse: Decodable {
    let action: String          // "added" | "removed"
    let reactions: [MessageReactionRow]
}

/// `GET /api/messages/{id}/reactions` envelope.
struct ReactionListResponse: Decodable {
    let reactions: [MessageReactionRow]
}

/// `POST /api/messages/{id}/pin` response.
struct PinToggleResponse: Decodable {
    let action: String          // "pinned" | "unpinned" | "noop"
    let pinned: Bool
    let pinnedAt: Date?
    let pinnedByUserId: String?

    enum CodingKeys: String, CodingKey {
        case action, pinned
        case pinnedAt = "pinned_at"
        case pinnedByUserId = "pinned_by_user_id"
    }
}

/// `POST/DELETE /api/messages/{id}/save` response.
struct SaveActionResponse: Decodable {
    let action: String          // "saved" | "removed" | "noop"
    let id: String?             // bookmark row id when saving
}

/// `GET /api/messages/search` envelope.
struct SearchMatchesResponse: Decodable {
    let matches: [SearchMatch]
}

/// Voice transcribe response (kicked off / fetched).
struct TranscribeResponse: Decodable {
    let status: String          // "pending" | "ready" | "failed"
    let text: String?
    let language: String?
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case status, text, language
        case durationSeconds = "duration_seconds"
    }
}

/// `GET /api/groups/{id}` — group metadata + member list. Permissive
/// decoder (extra fields ignored).
struct GroupDetails: Decodable {
    let id: String
    let name: String?
    let avatarUrl: String?
    let createdAt: Date?
    let createdBy: String?
    let members: [GroupMember]?

    enum CodingKeys: String, CodingKey {
        case id, name, members
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
        case createdBy = "created_by"
    }
}

struct GroupMember: Identifiable, Decodable, Equatable {
    let userId: String
    let username: String
    let firstName: String?
    let lastName: String?
    let avatarPath: String?
    let role: String?           // "owner" | "admin" | "member"
    let joinedAt: Date?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username, role
        case firstName = "first_name"
        case lastName = "last_name"
        case avatarPath = "avatar_path"
        case joinedAt = "joined_at"
    }
}

/// Heterogeneous-typed encodable wrapper — lets us pass `["k": value]`
/// dictionaries with mixed `Bool`/`Int`/`String` values to `post(body:)`
/// without having to declare a one-off struct for every action.
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ wrapped: T) {
        self._encode = { try wrapped.encode(to: $0) }
    }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

extension AnyEncodable: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self.init(value) }
}
extension AnyEncodable: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self.init(value) }
}
extension AnyEncodable: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self.init(value) }
}

/// Subset of `MessageResponse` from `server/routers/messages.py` — just
/// the bits we need to confirm a send succeeded.
struct SentMessage: Decodable {
    let id: String
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id, timestamp
    }
}

/// `GET /api/users/me/settings` envelope — we project just the
/// notification half.
struct SettingsEnvelope: Decodable {
    let notification: NotificationPreferences
}

/// `NotificationPreferencesUpdate` — used for both reads and PATCHes.
/// All fields optional so a partial update only sends what changed.
struct NotificationPreferences: Codable, Equatable {
    var pushEnabled: Bool?
    var messagesEnabled: Bool?
    var friendRequestsEnabled: Bool?
    var likesCommentsEnabled: Bool?
    var soundsEnabled: Bool?
    var messagePreview: Bool?
    var newPostNotifications: Bool?
    var audioRoomNotifications: Bool?
    var mentionNotifications: Bool?

    enum CodingKeys: String, CodingKey {
        case pushEnabled = "push_enabled"
        case messagesEnabled = "messages_enabled"
        case friendRequestsEnabled = "friend_requests_enabled"
        case likesCommentsEnabled = "likes_comments_enabled"
        case soundsEnabled = "sounds_enabled"
        case messagePreview = "message_preview"
        case newPostNotifications = "new_post_notifications"
        case audioRoomNotifications = "audio_room_notifications"
        case mentionNotifications = "mention_notifications"
    }
}

/// `GET /api/users/friend-requests` row.
struct FriendRequestDTO: Identifiable, Decodable, Equatable {
    let id: String
    let requesterId: String
    let requesterUsername: String
    let requesterAvatar: String?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case requesterUsername = "requester_username"
        case requesterAvatar = "requester_avatar"
    }
}

/// `LinkedDeviceResponse` — server emits camelCase here, no key mapping
/// needed.
struct LinkedDevice: Identifiable, Decodable, Equatable {
    let id: String
    let deviceName: String?
    let deviceModel: String?
    let deviceOs: String?
    let pairedAt: Date
    let lastSeenAt: Date
    let isThisDevice: Bool
}

/// `PaginatedFeedResponse` wrapper — used by `/feed/friends` and
/// `/feed/local`. We only need `items`; offset / cursor live in the DTO
/// for future pagination wiring.
struct PaginatedFeed: Decodable {
    let items: [Post]
    let hasMore: Bool?
    let nextOffset: Int?
}

/// `POST /api/posts/{id}/like` returns the new count and like state.
struct ToggleLikeResponse: Decodable {
    let status: String
    let action: String        // "liked" | "unliked"
    let likes: Int
    let isLiked: Bool

    enum CodingKeys: String, CodingKey {
        case status, action, likes
        case isLiked = "is_liked"
    }
}

/// `POST /api/comments/{id}/vote` response.
struct CommentVoteResponse: Decodable {
    let status: String
    let action: String       // "voted" | "removed" | "changed"
    let myVote: Int          // -1 / 0 / +1
    let score: Int

    enum CodingKeys: String, CodingKey {
        case status, action, score
        case myVote = "my_vote"
    }
}

/// Top-level comment on a post — matches `CommentResponse` in
/// `server/routers/comments.py`.
struct CommentDTO: Identifiable, Decodable, Equatable {
    let id: String
    let postId: String
    let authorId: String
    let authorName: String      // server emits `author_name`, not `author_username`
    let authorAvatar: String?
    let content: String
    let timestamp: Date
    let score: Int              // likes - dislikes
    let myVote: Int             // +1 / 0 / -1

    enum CodingKeys: String, CodingKey {
        case id
        case postId = "post_id"
        case authorId = "author_id"
        case authorName = "author_name"
        case authorAvatar = "author_avatar"
        case content
        case timestamp
        case score
        case myVote = "my_vote"
    }
}

/// `GET /api/notifications` row — matches `NotificationResponse` in
/// `server/routers/notifications.py`. The server packs the actor / target
/// / message into a free-form `data` dict; we project the bits we render
/// out of it via `NotificationData`.
struct NotificationItem: Identifiable, Decodable, Equatable {
    let id: String
    let kind: String            // "like" | "comment" | "mention" | "post_from_followed" | …
    let timestamp: Date
    let isRead: Bool
    let data: NotificationData

    enum CodingKeys: String, CodingKey {
        case id
        case kind = "type"
        case timestamp
        case isRead = "is_read"
        case data
    }
}

/// Loose unpacking of the server's `data: dict` field. The server uses
/// per-type keys (`liker_username`/`commenter_username` etc.), so we
/// peek at every plausible name and let the row pick the first hit.
struct NotificationData: Decodable, Equatable {
    let actorUsername: String?
    let actorAvatar: String?
    let preview: String?
    let postId: String?

    /// Server identifier of the user that triggered the notification —
    /// projected so notification taps can deep-link into a profile sheet
    /// without an extra `/api/users/by-username/...` round trip.
    let actorId: String?

    /// Security event sub-kind (e.g. "new_login"). Set only for `type:
    /// "security"` notifications, which carry no actor — just an event
    /// name plus a device user-agent string.
    let event: String?
    let device: String?

    /// Group context for thread events (pinned_message, poll_created,
    /// added_to_group, group_message). Lets the row format as
    /// "X did Y in <group>" without an extra fetch.
    let groupId: String?
    let groupName: String?
    /// Pinned-message reference for `type=pinned_message` so taps can
    /// deep-link into the chat thread + scroll to the original.
    let messageId: String?
    /// Poll id for `type=poll_created`.
    let pollId: String?
    /// Whether the source thread was a group; only meaningful on the new
    /// thread-event types.
    let isGroup: Bool?

    enum CodingKeys: String, CodingKey {
        // Likes
        case likerUsername = "liker_username"
        case likerAvatar = "liker_avatar"
        case likerId = "liker_id"
        // Comments / replies
        case commenterUsername = "commenter_username"
        case commenterAvatar = "commenter_avatar"
        case commenterId = "commenter_id"
        // Mentions
        case mentionerUsername = "mentioner_username"
        case mentionerAvatar = "mentioner_avatar"
        // Follows / friend requests
        case followerUsername = "follower_username"
        case requesterUsername = "requester_username"
        case requesterAvatar = "requester_avatar"
        // Mentions
        case mentionerUsernameId = "mentioner_id"
        // Follows / friend requests
        case requesterId = "requester_id"
        // DMs / group messages (these dominate the inbox in practice)
        case senderUsername = "sender_username"
        case senderAvatar = "sender_avatar"
        case senderId = "sender_id"
        // Group invites / member adds
        case addedBy = "added_by"
        case addedById = "added_by_id"
        // Generic fallbacks (some types still use the older keys)
        case actorUsername = "actor_username"
        case actorAvatar = "actor_avatar"
        case actorId = "actor_id"
        // Comment / message preview, post id for navigation
        case preview
        case postId = "post_id"
        case roomId = "room_id"
        // Security events (new login from another device, etc.)
        case event
        case device
        // Thread events (pinned_message, poll_created)
        case groupId = "group_id"
        case groupName = "group_name"
        case messageId = "message_id"
        case pollId = "poll_id"
        case isGroup = "is_group"
    }

    /// Conversation id when the notification was a DM/group message
    /// (used to deep-link back to the right thread).
    let roomId: String?

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        actorUsername = NotificationData.firstString(
            in: c,
            keys: [.likerUsername, .commenterUsername, .mentionerUsername,
                   .followerUsername, .requesterUsername, .senderUsername,
                   .addedBy, .actorUsername]
        )
        actorAvatar = NotificationData.firstString(
            in: c,
            keys: [.likerAvatar, .commenterAvatar, .mentionerAvatar,
                   .requesterAvatar, .senderAvatar, .actorAvatar]
        )
        actorId = NotificationData.firstString(
            in: c,
            keys: [.likerId, .commenterId, .mentionerUsernameId, .requesterId,
                   .senderId, .addedById, .actorId]
        )
        preview = (try? c?.decode(String.self, forKey: .preview))
        postId = (try? c?.decode(String.self, forKey: .postId))
        roomId = (try? c?.decode(String.self, forKey: .roomId))
        event = (try? c?.decode(String.self, forKey: .event))
        device = (try? c?.decode(String.self, forKey: .device))
        groupId = (try? c?.decode(String.self, forKey: .groupId))
        groupName = (try? c?.decode(String.self, forKey: .groupName))
        messageId = (try? c?.decode(String.self, forKey: .messageId))
        pollId = (try? c?.decode(String.self, forKey: .pollId))
        isGroup = (try? c?.decode(Bool.self, forKey: .isGroup))
    }

    private static func firstString(
        in container: KeyedDecodingContainer<CodingKeys>?,
        keys: [CodingKeys]
    ) -> String? {
        guard let container else { return nil }
        for key in keys {
            if let v = try? container.decode(String.self, forKey: key) {
                return v
            }
        }
        return nil
    }
}

// MARK: - Group poll DTOs
//
// Mirrors the server's PollResponse / PollOptionResponse from
// `server/routers/groups.py:1575-1600`. The macOS app uses these to
// render live tallies inside the chat thread and to cast / close votes.

struct PollOptionDTO: Decodable, Identifiable, Equatable {
    let id: String
    let text: String
    let voteCount: Int
    let voters: [String]   // empty when poll is anonymous

    enum CodingKeys: String, CodingKey {
        case id, text
        case voteCount = "vote_count"
        case voters
    }
}

struct PollDTO: Decodable, Identifiable, Equatable {
    let id: String
    let groupId: String
    let creatorId: String
    let creatorName: String
    let question: String
    let options: [PollOptionDTO]
    let allowMultiple: Bool
    let isAnonymous: Bool
    let isClosed: Bool
    let totalVotes: Int
    let myVotes: [String]   // option IDs the current user has selected
    let createdAt: Date
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, question, options
        case groupId = "group_id"
        case creatorId = "creator_id"
        case creatorName = "creator_name"
        case allowMultiple = "allow_multiple"
        case isAnonymous = "is_anonymous"
        case isClosed = "is_closed"
        case totalVotes = "total_votes"
        case myVotes = "my_votes"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}


/// Convenience for building multipart bodies — UTF-8 bytes from a string.
fileprivate extension String {
    var utf8Data: Data { Data(self.utf8) }
}

/// Truncate any fractional-second component to 3 digits ("microseconds →
/// milliseconds") so the standard formatters can parse it. Top-level
/// helper — actor stored-property initializers can't reference `Self`.
fileprivate func trimFractionalSeconds(_ s: String) -> String {
    guard let dot = s.firstIndex(of: ".") else { return s }
    var idx = s.index(after: dot)
    while idx < s.endIndex, s[idx].isNumber { idx = s.index(after: idx) }
    let digits = s.distance(from: s.index(after: dot), to: idx)
    guard digits > 3 else { return s }
    let keepEnd = s.index(s.index(after: dot), offsetBy: 3)
    return String(s[..<keepEnd]) + String(s[idx...])
}
