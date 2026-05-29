// Models for the macOS native app.
//
// Kept intentionally small — only what the desktop UI displays. The full
// schemas live in `ios-native/RAVEN/RAVEN/Models/` and on the FastAPI
// server. We use `Codable` with `CodingKeys` so the JSON the FastAPI
// returns (snake_case) maps cleanly to camelCase Swift properties.

import Foundation

// MARK: - User

struct User: Identifiable, Equatable {
    let id: String
    let username: String
    let email: String?
    let firstName: String?
    let lastName: String?
    let avatarPath: String?  // full URL to the avatar image, or nil
    let bio: String?
    /// Optional profile badges + counters surfaced when the API returns
    /// them (e.g. `/api/users/me` and `/api/users/profile/{id}`). Default
    /// to nil when the field isn't present on the response.
    var isVerified: Bool? = nil
    var isPremium: Bool? = nil
    var postCount: Int? = nil
    var friendCount: Int? = nil
    var followingCount: Int? = nil

    var initials: String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

extension User: Codable {
    /// `/api/users/me` returns camelCase; `/api/users/search` returns
    /// snake_case. We accept both transparently so a `User` decodes from
    /// either response shape.
    enum CodingKeys: String, CodingKey {
        case id, username, email, bio
        // camelCase variants (users/me)
        case firstName, lastName, avatarPath
        // snake_case variants (users/search)
        case first_name, last_name, avatar_path, avatar_url
        // Profile badges + counters (both casings).
        case isVerified, isPremium, postCount, friendCount, followingCount
        case is_verified, is_premium, post_count, friend_count, following_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        email = try? c.decode(String.self, forKey: .email)
        bio = try? c.decode(String.self, forKey: .bio)
        firstName = (try? c.decode(String.self, forKey: .firstName))
            ?? (try? c.decode(String.self, forKey: .first_name))
        lastName = (try? c.decode(String.self, forKey: .lastName))
            ?? (try? c.decode(String.self, forKey: .last_name))
        avatarPath = (try? c.decode(String.self, forKey: .avatarPath))
            ?? (try? c.decode(String.self, forKey: .avatar_path))
            ?? (try? c.decode(String.self, forKey: .avatar_url))
        isVerified = (try? c.decode(Bool.self, forKey: .isVerified))
            ?? (try? c.decode(Bool.self, forKey: .is_verified))
        isPremium = (try? c.decode(Bool.self, forKey: .isPremium))
            ?? (try? c.decode(Bool.self, forKey: .is_premium))
        postCount = (try? c.decode(Int.self, forKey: .postCount))
            ?? (try? c.decode(Int.self, forKey: .post_count))
        friendCount = (try? c.decode(Int.self, forKey: .friendCount))
            ?? (try? c.decode(Int.self, forKey: .friend_count))
        followingCount = (try? c.decode(Int.self, forKey: .followingCount))
            ?? (try? c.decode(Int.self, forKey: .following_count))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(username, forKey: .username)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(firstName, forKey: .firstName)
        try c.encodeIfPresent(lastName, forKey: .lastName)
        try c.encodeIfPresent(avatarPath, forKey: .avatarPath)
        try c.encodeIfPresent(bio, forKey: .bio)
    }
}

// MARK: - Post

struct Post: Identifiable, Codable, Equatable {
    let id: String
    let authorId: String
    let authorUsername: String
    let authorAvatar: String?
    let content: String
    let imageUrl: String?         // legacy single-image
    let media: [PostMedia]?       // multi-media (images + videos), preferred
    let timestamp: Date
    let likes: Int
    let comments: Int
    let viewCount: Int
    let isLiked: Bool
    let visibility: String
    let postType: String?         // "text" | "image" | "voice" | …
    let voiceUrl: String?         // direct voice CDN URL when postType == voice

    /// All renderable media items, prefer `media` array, fall back to legacy
    /// single `imageUrl`. Empty when the post is text-only.
    var displayableMedia: [PostMedia] {
        if let media, !media.isEmpty { return media }
        if let url = imageUrl, !url.isEmpty {
            return [PostMedia(id: "legacy", url: url, orderIndex: 0,
                              mediaType: "image", thumbnailUrl: nil)]
        }
        return []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case authorUsername = "author_username"
        case authorAvatar = "author_avatar"
        case content
        case imageUrl = "image_url"
        case media
        case timestamp
        case likes
        case comments
        case viewCount = "view_count"
        case isLiked = "is_liked"
        case visibility
        case postType = "post_type"
        case voiceUrl = "voice_url"
    }

    /// Build a copy with updated like state — used by the optimistic update
    /// in PostCardView after `/api/posts/{id}/like` returns.
    func withLikeState(likes: Int, isLiked: Bool) -> Post {
        Post(
            id: id, authorId: authorId, authorUsername: authorUsername,
            authorAvatar: authorAvatar, content: content, imageUrl: imageUrl,
            media: media, timestamp: timestamp, likes: likes, comments: comments,
            viewCount: viewCount, isLiked: isLiked, visibility: visibility,
            postType: postType, voiceUrl: voiceUrl
        )
    }

    /// Build a copy with replaced body content, used after the user edits
    /// their own post via PATCH /api/posts/{id}.
    func withContent(_ newContent: String) -> Post {
        Post(
            id: id, authorId: authorId, authorUsername: authorUsername,
            authorAvatar: authorAvatar, content: newContent, imageUrl: imageUrl,
            media: media, timestamp: timestamp, likes: likes, comments: comments,
            viewCount: viewCount, isLiked: isLiked, visibility: visibility,
            postType: postType, voiceUrl: voiceUrl
        )
    }
}

/// Mirrors `PostMediaResponse` in `server/routers/posts.py`.
struct PostMedia: Identifiable, Codable, Equatable {
    let id: String
    let url: String
    let orderIndex: Int
    let mediaType: String?       // "image" | "video"
    let thumbnailUrl: String?    // video thumbnail (nil for images)

    enum CodingKeys: String, CodingKey {
        case id, url
        case orderIndex = "order_index"
        case mediaType = "media_type"
        case thumbnailUrl = "thumbnail_url"
    }
}

// MARK: - Conversation

/// Conversation summary returned by `/api/messages/conversations`. Server
/// uses camelCase here (not snake_case like the rest of the API), so no
/// CodingKeys overrides are needed for the top-level fields. Group chat
/// fields stay snake_case because the server splits them out.
struct ConversationSummary: Identifiable, Codable, Equatable {
    let roomId: String
    let peer: ConversationPeer
    let lastMessage: ConversationLastMessage?
    let unreadCount: Int
    let isPinned: Bool
    let isMuted: Bool
    let updatedAt: Date
    let isGroup: Bool
    let groupName: String?
    let groupAvatarUrl: String?
    /// Message-request fields. When the conversation is a 1:1 between
    /// users who aren't yet friends, the server tags it with a request
    /// status — receiver sees Block/Decline/Accept, sender sees a
    /// "X/3 messages left" counter and can't send more once exhausted.
    var requestStatus: String?       // pending | accepted | declined | blocked
    var isRequestSender: Bool?       // true: I started the request; false: I'm the receiver
    var requestId: String?           // server MessageRequest UUID (for the action endpoints)
    var pendingSentCount: Int?       // how many of the 3-message budget the sender used

    var id: String { roomId }

    /// Peer user id — what the macOS thread view uses to call
    /// `GET /api/messages/conversation/{other_user_id}`.
    var peerId: String { peer.userId }
    var peerUsername: String { peer.username }

    var isRequestPending: Bool {
        !isGroup && (requestStatus == "pending")
    }

    enum CodingKeys: String, CodingKey {
        case roomId, peer, lastMessage, unreadCount, isPinned, isMuted, updatedAt
        case isGroup = "is_group"
        case groupName = "group_name"
        case groupAvatarUrl = "group_avatar_url"
        case requestStatus = "request_status"
        case isRequestSender = "is_request_sender"
        case requestId = "request_id"
        case pendingSentCount = "pending_sent_count"
    }
}

struct ConversationPeer: Codable, Equatable {
    let userId: String
    let username: String
    let firstName: String?
    let lastName: String?
    let avatarPath: String?
    let isVerified: Bool
    let isPremium: Bool
}

struct ConversationLastMessage: Codable, Equatable {
    let id: String
    let content: String?
    let messageType: String
    let timestamp: Date
    let senderId: String
}

// MARK: - Message

/// `/api/hashtags/trending` row.
struct TrendingHashtag: Identifiable, Codable, Equatable {
    var id: String { hashtag }
    let hashtag: String
    let postCount: Int
    let recentPosts: Int

    enum CodingKeys: String, CodingKey {
        case hashtag
        case postCount = "post_count"
        case recentPosts = "recent_posts"
    }
}

struct Message: Identifiable, Codable, Equatable {
    let id: String
    let senderId: String
    /// Optional because group messages don't carry a recipient id (the
    /// recipients are the group members, not a single user).
    let recipientId: String?
    let content: String?            // Server emits `null` when decryption fails
    let timestamp: Date
    let messageType: String?        // "text" | "voice" | "image" | "file" | "video" | "location" | …
    let audioUrl: String?           // voice messages (also re-used by image type per server convention)
    let audioDurationSeconds: Int?  // voice duration
    let fileName: String?
    let fileSize: Int?
    let mimeType: String?
    /// Group-message sender display name (`sender_name`) and avatar.
    /// `sender_username` from DM responses is also accepted via `senderName`.
    let senderName: String?
    let senderAvatar: String?

    // Reply / quote metadata (server SendMessageRequest reply_to_*).
    let replyToMessageId: String?
    let replyToTextPreview: String?
    let replyToSenderName: String?
    let replyToType: String?

    // Edit / delete state.
    let editedAt: Date?

    // Delivery state — server fans these out when it can.
    let readAt: Date?
    let deliveredAt: Date?

    // Pinning (set on the row when pinned).
    let pinnedAt: Date?
    let pinnedByUserId: String?

    // Smart-expiry (DMs only).
    let expiryMode: String?
    let expiresAt: Date?
    let allowForward: Bool?

    // Group polls — set when `messageType == "poll"`. Clients fetch the
    // live tally via /api/groups/{group_id}/polls/{poll_id}.
    let pollId: String?

    var displayContent: String {
        // Honor structured types BEFORE falling through to raw `content`,
        // otherwise a contact-card payload (JSON in the text field) leaks
        // its `{"displayName":...}` body wherever displayContent is shown
        // (composer reply pill, pinned banner, search results).
        if messageType == "contact_card" {
            return "👤 Shared contact"
        }
        if let content, !content.isEmpty {
            // The server uses Fernet for at-rest message encryption. When
            // the server's decrypt path fails (rare — usually a key rotation
            // for old rows), it sometimes leaks the raw ciphertext through
            // to clients. The Fernet token format always starts with
            // "gAAAAA" + base64 padding. Detect that and show a friendly
            // placeholder instead of the gibberish blob.
            if Message.looksEncrypted(content) {
                return "🔒 Encrypted message"
            }
            // Defensive: contact-card stored as `text` (older clients
            // didn't know the type). Recognise the JSON shape so any
            // displayContent caller hides the raw blob.
            if Message.looksLikeContactCardJSON(content) {
                return "👤 Shared contact"
            }
            return content
        }
        switch messageType {
        case "voice": return "🎤 Voice message"
        case "image": return "🖼️ Image"
        case "video": return "🎬 Video"
        case "file":  return "📎 \(fileName ?? "File")"
        case "location": return "📍 Location"
        case "system": return content ?? ""
        default:      return "🔒 Encrypted message"
        }
    }

    /// Cheap shape probe — matches the iOS sibling `ContactSharePayload.
    /// looksLikeContactCard`. We don't decode here; just check the
    /// fields a contact-card JSON always carries.
    static func looksLikeContactCardJSON(_ s: String) -> Bool {
        guard s.hasPrefix("{") else { return false }
        return s.contains("\"displayName\"")
            && s.contains("\"username\"")
            && s.contains("\"userId\"")
    }

    var isText: Bool { (messageType ?? "text") == "text" }
    var isVoice: Bool { messageType == "voice" }
    var isImage: Bool { messageType == "image" }
    var isFile: Bool { messageType == "file" }
    var isSystem: Bool { messageType == "system" }
    var isPinned: Bool { pinnedAt != nil }
    var isEdited: Bool { editedAt != nil }
    var hasReply: Bool { replyToMessageId != nil }

    /// Heuristic: Fernet tokens are URL-safe base64, always begin with
    /// `gAAAAA` (the version byte 0x80 + first bits of timestamp), and
    /// are at least ~80 characters. Plain user text never matches.
    ///
    /// Check is intentionally permissive: as long as the trimmed string
    /// *starts* with `gAAAAA` and is at least 60 chars, treat it as
    /// encrypted. Earlier the alphabet check rejected concatenated
    /// tokens that contained mid-string newlines on some ciphers and
    /// the raw blob leaked into the bubble — `hasPrefix` alone is a
    /// stronger signal than "every byte is base64-clean", and the cost
    /// of a false positive (one user message that happens to start with
    /// `gAAAAA`) is `🔒 Encrypted message` instead of the literal
    /// text. False positives in practice: zero — Fernet's prefix is a
    /// fixed 0x80 version byte, no plaintext starts with that.
    static func looksEncrypted(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 60 else { return false }
        return trimmed.hasPrefix("gAAAAA")
            // Some bridge re-wraps strip the leading byte one level deep —
            // the resulting blob is still ciphertext, just one Fernet
            // header lower. Pick those off too so the bubble doesn't leak.
            || trimmed.contains("gAAAAA")
            && trimmed.replacingOccurrences(of: " ", with: "").count >= 100
    }

    enum CodingKeys: String, CodingKey {
        case id
        case senderId = "sender_id"
        case recipientId = "recipient_id"
        case content
        case timestamp
        case messageType = "message_type"
        case audioUrl = "audio_url"
        case audioDurationSeconds = "audio_duration_seconds"
        case fileName = "file_name"
        case fileSize = "file_size"
        case mimeType = "mime_type"
        case senderName = "sender_name"
        case senderUsername = "sender_username"
        case senderAvatar = "sender_avatar"
        case replyToMessageId = "reply_to_message_id"
        case replyToTextPreview = "reply_to_text_preview"
        case replyToSenderName = "reply_to_sender_name"
        case replyToType = "reply_to_type"
        case editedAt = "edited_at"
        case readAt = "read_at"
        case deliveredAt = "delivered_at"
        case pinnedAt = "pinned_at"
        case pinnedByUserId = "pinned_by_user_id"
        case expiryMode = "expiry_mode"
        case expiresAt = "expires_at"
        case allowForward = "allow_forward"
        case pollId = "poll_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        senderId = try c.decode(String.self, forKey: .senderId)
        recipientId = try? c.decode(String.self, forKey: .recipientId)
        content = try? c.decode(String.self, forKey: .content)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        messageType = try? c.decode(String.self, forKey: .messageType)
        audioUrl = try? c.decode(String.self, forKey: .audioUrl)
        audioDurationSeconds = try? c.decode(Int.self, forKey: .audioDurationSeconds)
        fileName = try? c.decode(String.self, forKey: .fileName)
        fileSize = try? c.decode(Int.self, forKey: .fileSize)
        mimeType = try? c.decode(String.self, forKey: .mimeType)
        // Group endpoints emit `sender_name`; DM endpoints emit
        // `sender_username`. Take whichever is present.
        senderName = (try? c.decode(String.self, forKey: .senderName))
            ?? (try? c.decode(String.self, forKey: .senderUsername))
        senderAvatar = try? c.decode(String.self, forKey: .senderAvatar)
        replyToMessageId = try? c.decode(String.self, forKey: .replyToMessageId)
        replyToTextPreview = try? c.decode(String.self, forKey: .replyToTextPreview)
        replyToSenderName = try? c.decode(String.self, forKey: .replyToSenderName)
        replyToType = try? c.decode(String.self, forKey: .replyToType)
        editedAt = try? c.decode(Date.self, forKey: .editedAt)
        readAt = try? c.decode(Date.self, forKey: .readAt)
        deliveredAt = try? c.decode(Date.self, forKey: .deliveredAt)
        pinnedAt = try? c.decode(Date.self, forKey: .pinnedAt)
        pinnedByUserId = try? c.decode(String.self, forKey: .pinnedByUserId)
        expiryMode = try? c.decode(String.self, forKey: .expiryMode)
        expiresAt = try? c.decode(Date.self, forKey: .expiresAt)
        allowForward = try? c.decode(Bool.self, forKey: .allowForward)
        pollId = try? c.decode(String.self, forKey: .pollId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(senderId, forKey: .senderId)
        try c.encodeIfPresent(recipientId, forKey: .recipientId)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(messageType, forKey: .messageType)
        try c.encodeIfPresent(audioUrl, forKey: .audioUrl)
        try c.encodeIfPresent(audioDurationSeconds, forKey: .audioDurationSeconds)
        try c.encodeIfPresent(fileName, forKey: .fileName)
        try c.encodeIfPresent(fileSize, forKey: .fileSize)
        try c.encodeIfPresent(mimeType, forKey: .mimeType)
        try c.encodeIfPresent(senderName, forKey: .senderName)
        try c.encodeIfPresent(senderAvatar, forKey: .senderAvatar)
        try c.encodeIfPresent(replyToMessageId, forKey: .replyToMessageId)
        try c.encodeIfPresent(replyToTextPreview, forKey: .replyToTextPreview)
        try c.encodeIfPresent(replyToSenderName, forKey: .replyToSenderName)
        try c.encodeIfPresent(replyToType, forKey: .replyToType)
        try c.encodeIfPresent(editedAt, forKey: .editedAt)
        try c.encodeIfPresent(readAt, forKey: .readAt)
        try c.encodeIfPresent(deliveredAt, forKey: .deliveredAt)
        try c.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try c.encodeIfPresent(pinnedByUserId, forKey: .pinnedByUserId)
        try c.encodeIfPresent(expiryMode, forKey: .expiryMode)
        try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(allowForward, forKey: .allowForward)
        try c.encodeIfPresent(pollId, forKey: .pollId)
    }
}

// MARK: - Reactions / Pinned / Saved / Search

/// One row in `GET /api/messages/{id}/reactions` and inside the
/// `message_reaction` WS event.
struct MessageReactionRow: Identifiable, Codable, Equatable {
    let id: String
    let userId: String
    let emoji: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case emoji
        case createdAt = "created_at"
    }
}

/// `GET /api/messages/conversation/{peer_id}/pinned` row.
struct PinnedMessage: Identifiable, Codable, Equatable {
    let id: String
    let senderId: String
    let senderUsername: String?
    let senderName: String?
    let content: String?
    let messageType: String
    let audioUrl: String?
    let audioDurationSeconds: Int?
    let timestamp: Date
    let pinnedAt: Date
    let pinnedByUserId: String

    enum CodingKeys: String, CodingKey {
        case id
        case senderId = "sender_id"
        case senderUsername = "sender_username"
        case senderName = "sender_name"
        case content
        case messageType = "message_type"
        case audioUrl = "audio_url"
        case audioDurationSeconds = "audio_duration_seconds"
        case timestamp
        case pinnedAt = "pinned_at"
        case pinnedByUserId = "pinned_by_user_id"
    }
}

/// `GET /api/messages/saved` row.
struct SavedMessageItem: Identifiable, Codable, Equatable {
    let id: String                  // bookmark row id
    let messageId: String
    let isGroup: Bool
    let savedAt: Date
    let senderUsername: String?
    let senderName: String?
    let content: String?
    let messageType: String
    let audioUrl: String?
    let audioDurationSeconds: Int?
    let timestamp: Date
    let peerUserId: String?
    let groupId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case messageId = "message_id"
        case isGroup = "is_group"
        case savedAt = "saved_at"
        case senderUsername = "sender_username"
        case senderName = "sender_name"
        case content
        case messageType = "message_type"
        case audioUrl = "audio_url"
        case audioDurationSeconds = "audio_duration_seconds"
        case timestamp
        case peerUserId = "peer_user_id"
        case groupId = "group_id"
    }
}

/// `GET /api/messages/search` match row (DMs only).
struct SearchMatch: Identifiable, Codable, Equatable {
    let id: String
    let senderId: String
    let content: String
    let timestamp: Date
    let editedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case senderId = "sender_id"
        case content
        case timestamp
        case editedAt = "edited_at"
    }
}

extension Message {
    /// Materialize a `Message` from a `MeshEnvelope`. Used by
    /// RealtimeEngine to convert mesh-delivered envelopes into the
    /// same shape the WebSocket pushes, so chat views don't have to
    /// branch on transport.
    static func fromMeshEnvelope(_ env: MeshEnvelope) -> Message {
        var dict: [String: Any] = [
            "id": env.clientMessageId,
            "sender_id": env.senderId,
            "recipient_id": env.recipientId,
            "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: env.timestamp)),
            "message_type": Self.meshTypeToString(env.type),
        ]
        if let text = env.text { dict["content"] = text }
        if let mediaUrl = env.mediaUrl { dict["audio_url"] = mediaUrl }
        if let duration = env.audioDuration { dict["audio_duration_seconds"] = duration }
        if let fileName = env.fileName { dict["file_name"] = fileName }
        if let fileSize = env.fileSize { dict["file_size"] = fileSize }
        if let mimeType = env.mimeType { dict["mime_type"] = mimeType }
        if !env.senderName.isEmpty { dict["sender_username"] = env.senderName }
        if let r = env.replyToMessageId { dict["reply_to_message_id"] = r }
        if let r = env.replyToTextPreview { dict["reply_to_text_preview"] = r }
        if let r = env.replyToSenderName { dict["reply_to_sender_name"] = r }

        guard
            let data = try? JSONSerialization.data(withJSONObject: dict),
            let decoded = try? JSONDecoder.snake.decode(Message.self, from: data)
        else {
            // Should never hit — fall back to a minimal Message.
            let minimal = "{\"id\":\"\(env.clientMessageId)\",\"sender_id\":\"\(env.senderId)\",\"timestamp\":0}"
            return (try? JSONDecoder.snake.decode(Message.self, from: Data(minimal.utf8)))!
        }
        return decoded
    }

    private static func meshTypeToString(_ raw: Int) -> String {
        switch raw {
        case 0: return "text"
        case 1: return "image"
        case 2: return "file"
        case 3: return "voice"
        case 4: return "location"
        case 5: return "post_share"
        case 6: return "system"
        case 7: return "video"
        case 8: return "video_note"
        case 9: return "ephemeral_photo"
        default: return "text"
        }
    }

    /// Build a synthetic Message for the optimistic-insert path.
    /// ChatStore appends one of these the moment the user hits send so
    /// the bubble appears before the round-trip completes; `reload()`
    /// then replaces it in-place because we forward this same `id` as
    /// `message_id` and the server uses it as the row id (idempotent).
    static func localPending(
        id: String,
        senderId: String,
        recipientId: String,
        content: String,
        replyToMessageId: String? = nil,
        replyToTextPreview: String? = nil,
        replyToSenderName: String? = nil,
        replyToType: String? = nil
    ) -> Message {
        var dict: [String: Any] = [
            "id": id,
            "sender_id": senderId,
            "recipient_id": recipientId,
            "content": content,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message_type": "text",
        ]
        if let replyToMessageId { dict["reply_to_message_id"] = replyToMessageId }
        if let replyToTextPreview { dict["reply_to_text_preview"] = replyToTextPreview }
        if let replyToSenderName { dict["reply_to_sender_name"] = replyToSenderName }
        if let replyToType { dict["reply_to_type"] = replyToType }
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict),
            let decoded = try? JSONDecoder.snake.decode(Message.self, from: data)
        else {
            let minimal = "{\"id\":\"\(id)\",\"sender_id\":\"\(senderId)\",\"timestamp\":0}"
            return (try? JSONDecoder.snake.decode(Message.self, from: Data(minimal.utf8)))!
        }
        return decoded
    }
}

/// `GET /api/users/{id}/presence` — when supported by the server.
struct PresenceInfo: Codable, Equatable {
    let userId: String
    let online: Bool
    let lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case online
        case lastSeenAt = "last_seen_at"
    }
}
