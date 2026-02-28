# RAVEN - Data Models Reference
> **Version**: 1.0  
> **Source**: Flutter `lib/models/` + Server `server/models.py`

---

## 1. User

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| username | String | ✓ | Unique, 3-20 chars alphanumeric+underscore |
| email | String? | - | Encrypted, nullable for OAuth |
| phone | String? | - | E.164 format (+1234567890) |
| firstName | String? | - | Encrypted |
| lastName | String? | - | Encrypted |
| avatarPath | String? | - | URL to avatar image |
| bio | String? | - | User biography (max 200 chars) |
| publicKey | String? | - | RSA public key for E2EE |
| createdAt | DateTime | ✓ | Account creation timestamp |
| showUsername | Bool | ✓ | Privacy: show username publicly |
| emailVerified | Bool | ✓ | Email verification status |
| phoneVerified | Bool | ✓ | Phone verification status |
| oauthProvider | String? | - | 'google', 'apple', or null |
| oauthProviderId | String? | - | Provider's user ID |
| authMethod | AuthMethod | ✓ | password, google, apple |

### AuthMethod Enum
```swift
enum AuthMethod {
    case password  // Email + password signup
    case google    // Google OAuth (auto-verified)
    case apple     // Apple OAuth (auto-verified)
}
```

### Computed Properties
- `displayName`: "FirstName LastName" or fallback to username

---

## 2. ChatMessage

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| roomId | String | ✓ | Conversation ID |
| senderId | String | ✓ | User ID of sender |
| senderName | String | ✓ | Display name at send time |
| recipientId | String | ✓ | User ID of recipient |
| text | String? | - | Message content (optional for media) |
| timestamp | DateTime | ✓ | When sent |
| status | MessageStatus | ✓ | Delivery state (see enum) |
| type | MessageType | ✓ | Content type (see enum) |
| deliveryAuthority | DeliveryAuthority | ✓ | server (blue) or mesh (purple) |

### ✅ Message Validation Rules
```swift
// Validation: at least one content source required
func isValid() -> Bool {
    switch type {
    case .text:
        return text != nil && !text!.isEmpty
    case .image, .file:
        return attachmentUrl != nil || localPath != nil
    case .voice:
        return audioUrl != nil || localPath != nil
    case .location:
        return true // coordinates in payload
    }
}
```

### DTN/Mesh Fields
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| ttl | Int | 10 | Time-to-live (hops remaining) |
| routePath | [String] | [] | Device IDs traversed |
| needsForwarding | Bool | true | Should relay to others |
| messageSignature | String? | - | HMAC for authentication |
| sprayCounter | Int | 5 | Spray-and-Wait copies left |
| originDeviceId | String? | - | Original sender device |
| hopCount | Int | 0 | Current hop number |
| hopLimit | Int | 10 | Maximum allowed hops |
| deliveryAuthority | DeliveryAuthority | .server | server or mesh |

### Media Fields
| Field | Type | Description |
|-------|------|-------------|
| audioUrl | String? | URL for voice/media file |
| fileName | String? | Original filename |
| mimeType | String? | MIME type (image/jpeg, application/pdf) |
| fileSize | Int? | Size in bytes |
| thumbnailUrl | String? | Thumbnail for previews |
| audioDurationSeconds | Int? | Voice message length |

### Voice Transcript Fields
| Field | Type | Description |
|-------|------|-------------|
| transcriptText | String? | AI-generated transcript |
| transcriptLang | String? | Language code (en, fa, es) |
| transcriptStatus | Int | 0=none, 1=generating, 2=ready, 3=failed |

### Offline-First Sync Fields
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| serverId | String? | - | Server-assigned ID after sync |
| syncState | SyncState | .localOnly | Sync status |
| localPath | String? | - | Local file path before upload |
| retryCount | Int | 0 | Sync retry attempts |
| lastError | String? | - | Last sync error |

### Reply Fields
| Field | Type | Description |
|-------|------|-------------|
| replyToMessageId | String? | ID of quoted message |
| replyToTextPreview | String? | Preview (max 50 chars) |
| replyToSenderName | String? | Sender name |
| replyToType | MessageType? | Type of quoted message |

### Other Fields
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| isLiked | Bool | false | Current user liked |
| sendMode | String | "instant" | "instant" or "scheduled" |
| scheduledAtUtc | DateTime? | - | When to send |
| deliveredAt | DateTime? | - | When delivered |
| readAt | DateTime? | - | When read |

---

## 3. Enums

### MessageStatus
```swift
enum MessageStatus: Int {
    case pending = 0
    case sending = 1
    case sent = 2
    case forwarding = 3
    case delivered = 4
    case read = 5
    case failed = 6
    case scheduled = 7
}
```

### MessageType
```swift
enum MessageType: Int {
    case text = 0
    case image = 1
    case file = 2
    case voice = 3
    case location = 4
}
```

### SyncState
```swift
enum SyncState: Int {
    case localOnly = 0
    case queued = 1
    case uploading = 2
    case synced = 3
    case failed = 4
}
```

### DeliveryAuthority
```swift
enum DeliveryAuthority: Int {
    case server = 0  // Blue indicator
    case mesh = 1    // Purple indicator
}
```

---

## 4. Contact

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| userId | String | ✓ | Referenced user's ID |
| username | String | ✓ | Username for display |
| nickname | String? | - | Custom name set by owner |
| avatarUrl | String? | - | Profile picture URL |
| addedAt | DateTime | ✓ | When added to contacts |
| status | Int | 0 | Legacy: 0=Stranger, 1=Friend... |
| relationshipStatus | RelationshipStatus | .stranger | Current relationship |
| pinned | Bool | false | Pinned to top |
| blocked | Bool | false | Is blocked |
| unreadCount | Int | 0 | Unread message count |
| lastMessageTime | DateTime? | - | Last message timestamp |
| lastMessagePreview | String? | - | Last message preview |
| isGroup | Bool | false | Is group chat |
| roomId | String? | - | Group room ID |

### Computed Properties
- `displayName`: nickname ?? username

### RelationshipStatus
```swift
enum RelationshipStatus: Int {
    case stranger = 0
    case pending = 1
    case following = 2
    case followbackPending = 3
    case friends = 4
    case declined = 5
    case blocked = 6
}
```

---

## 5. Post

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| authorId | String | ✓ | User ID of author |
| authorName | String | ✓ | Display name at post time |
| authorAvatar | String? | - | Author's avatar URL |
| content | String | ✓ | Post text (encrypted) |
| imageUrl | String? | - | Attached image URL |
| timestamp | DateTime | ✓ | When posted |
| editedAt | DateTime? | - | Last edit timestamp |
| likes | Int | 0 | Like count |
| comments | Int | 0 | Comment count |
| reposts | Int | 0 | Repost count |
| viewCount | Int | 0 | View count |
| likedBy | [String] | [] | User IDs who liked |
| isLiked | Bool | false | Current user liked |
| isReposted | Bool | false | Current user reposted |
| isLocal | Bool | true | Show in Local feed |
| sendMethod | PostSendMethod | .local | How created |
| actualSendMethod | PostSendMethod? | - | How actually sent |
| visibility | PostVisibility | .public | Who can see |

### PostSendMethod
```swift
enum PostSendMethod {
    case wifi
    case bluetooth
    case local
    case unknown
}
```

### PostVisibility
```swift
enum PostVisibility {
    case publicPost    // Both Local + Friends
    case friendsOnly   // Only Friends tab
}
```

---

## 6. AppNotification

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| type | NotificationType | ✓ | Notification category |
| title | String | ✓ | Header text |
| body | String | ✓ | Description text |
| avatarPath | String? | - | Related user avatar |
| userId | String? | - | Related user ID |
| timestamp | DateTime | ✓ | When created |
| isRead | Bool | false | Read status |
| data | Map? | - | Extra payload (JSON) |

### NotificationType
```swift
enum NotificationType: Int {
    case message = 0
    case friendRequest = 1
    case friendRequestSent = 2
    case mention = 3
    case like = 4
    case comment = 5
    case presence = 6    // Mesh: nearby user
    case deadDrop = 7    // Mesh: geo-cache
    case security = 8    // Login/password events
}
```

---

## 7. Comment

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| postId | String | ✓ | Parent post ID |
| authorId | String | ✓ | Commenter user ID |
| parentCommentId | String? | - | For threaded replies |
| content | String | ✓ | Comment text (encrypted) |
| timestamp | DateTime | ✓ | When posted |
| score | Int | 0 | likes - dislikes |
| isAiGenerated | Bool | false | AI-generated flag |

---

## 8. Group

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| name | String | ✓ | Group name |
| avatarUrl | String? | - | Group icon |
| description | String? | - | Group description |
| createdBy | String | ✓ | Creator user ID |
| createdAt | DateTime | ✓ | Creation timestamp |
| members | [GroupMember] | - | Member list |

### GroupMember
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| groupId | String | ✓ | Parent group ID |
| userId | String | ✓ | Member user ID |
| role | String | "member" | "admin" or "member" |
| joinedAt | DateTime | ✓ | When joined |

---

## 9. Device (for Mesh Identity)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| userId | String | ✓ | Owner user ID |
| fingerprint | String | ✓ | SHA256 of public key |
| publicKey | String | ✓ | PEM-encoded public key |
| platform | String? | - | "ios" or "android" |
| deviceName | String? | - | "iPhone 15 Pro" |
| lastSeenAt | DateTime | ✓ | Last activity |
| revoked | Bool | false | Key revoked flag |
| createdAt | DateTime | ✓ | When registered |

---

## 10. VerificationToken

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | String (UUID) | ✓ | Primary key |
| userId | String | ✓ | Target user ID |
| channel | String | ✓ | "email" or "sms" |
| purpose | String | ✓ | "verify_email", "verify_phone", "reset_password" |
| tokenHash | String | ✓ | SHA256 hash (never plaintext) |
| sentTo | String | ✓ | Email/phone where sent |
| expiresAt | DateTime | ✓ | Expiry (5 minutes) |
| attempts | Int | 0 | Failed attempts (max 5) |
| cooldownUntil | DateTime? | - | Next resend allowed |
| consumedAt | DateTime? | - | When successfully used |
| createdAt | DateTime | ✓ | When created |

---

*Document generated: 2026-01-30*
