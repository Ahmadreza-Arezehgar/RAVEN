# RAVEN - API Contract Reference
> **Version**: 1.2 (Added AI Ask)  
> **Backend**: FastAPI (Python)  
> **Base URL**: `https://api.raven.app` (production)

---

## ⚠️ Critical Auth Flow Rules

1. **Register returns RESTRICTED token** until email verified
2. **OTP expiry: 10 minutes** (600 seconds) - unified everywhere
3. **Password: min 10 chars** + uppercase + lowercase + number + special + no username

---

## 1. Authentication

### 1.1 Register
```http
POST /api/auth/register
```

**Request:**
```json
{
  "username": "string (required, 3-20 chars)",
  "password": "string (required, min 10 chars + complexity)",
  "first_name": "string (required)",
  "last_name": "string (required)",
  "birth_year": "int (required)",
  "email": "string (required)",
  "phone": "string (optional, E.164 format +1234567890)"
}
```

**Response (200):**
```json
{
  "user_id": "uuid",
  "username": "string",
  "token": "jwt_restricted_token",
  "token_type": "bearer",
  "email_verified": false,
  "token_scope": "restricted"
}
```

> ⚠️ **CRITICAL**: Token is RESTRICTED until email verified.
> Restricted token can ONLY access: `/auth/send-code`, `/auth/verify-code`, `/auth/resend-code`, `/users/me`
> Full token granted after successful `/auth/verify-code`

---

### 1.2 Login
```http
POST /api/auth/login
```

**Request:**
```json
{
  "username": "string",
  "password": "string"
}
```

**Response (200):**
```json
{
  "user_id": "uuid",
  "username": "string",
  "token": "jwt_token",
  "token_type": "bearer",
  "email_verified": true
}
```

> Only verified users can login. Unverified users get error.

---

### 1.3 Google OAuth
```http
POST /api/auth/oauth/google
```

**Response (200):**
```json
{
  "user_id": "uuid",
  "username": "string or null",
  "token": "jwt_token",
  "token_type": "bearer",
  "requires_username": "bool",
  "email_verified": true,
  "auth_method": "google"
}
```

> OAuth users are auto-verified (Google/Apple verified their email)

---

### 1.4 Send Verification Code
```http
POST /api/auth/send-code
```

**Response:**
```json
{
  "success": true,
  "message": "Code sent",
  "expires_in_seconds": 600,
  "cooldown_seconds": 60
}
```

> **10-minute expiry (600s)** - unified across all docs

---

### 1.5 Verify Code
```http
POST /api/auth/verify-code
```

**Response (on success):**
```json
{
  "success": true,
  "email_verified": true,
  "full_access_token": "jwt_full_token",
  "token_scope": "full"
}
```

> After successful verification, client replaces restricted token with full token

---

## 2. Conversations (NEW - Required for Inbox)

### 2.1 Get Conversations List
```http
GET /api/conversations?limit=50
Authorization: Bearer {token}
```

**Response:**
```json
[
  {
    "room_id": "uuid_uuid (sorted user IDs)",
    "peer": {
      "id": "uuid",
      "username": "string",
      "first_name": "string",
      "last_name": "string",
      "avatar_path": "url"
    },
    "last_message": {
      "id": "uuid",
      "content": "string (decrypted, truncated 50 chars)",
      "message_type": "text | voice | image | file",
      "timestamp": "ISO datetime",
      "sender_id": "uuid",
      "delivery_authority": "server | mesh"
    },
    "unread_count": 3,
    "is_pinned": false,
    "is_muted": false,
    "updated_at": "ISO datetime"
  }
]
```

> ✅ This is the source of truth for Inbox UI. Poll every 10-20 seconds.

---

### 2.2 Get Conversation Media
```http
GET /api/conversations/{room_id}/media?type=image,file,voice&limit=50
Authorization: Bearer {token}
```

**Response:**
```json
[
  {
    "id": "uuid",
    "message_type": "image | file | voice",
    "url": "cdn_url",
    "thumbnail_url": "url (for images)",
    "filename": "string",
    "mime_type": "string",
    "file_size": 123456,
    "duration_seconds": 45,
    "sender_id": "uuid",
    "timestamp": "ISO datetime"
  }
]
```

> ✅ Returns ALL media from BOTH parties in conversation

---

## 3. Messages

### 3.1 Send Message
```http
POST /api/messages/send
Authorization: Bearer {token}
```

**Request:**
```json
{
  "recipient_id": "uuid",
  "content": "string (optional for media)",
  "message_id": "uuid (optional, for idempotency)",
  "message_type": "text | voice | image | file",
  "attachment_url": "string (required for media types)",
  "thumbnail_url": "string (for images)",
  "filename": "string (for files)",
  "mime_type": "string",
  "file_size": 123456,
  "duration_seconds": 45,
  "reply_to_message_id": "uuid (optional)",
  "reply_to_text_preview": "string (max 50 chars)",
  "send_mode": "instant | scheduled",
  "scheduled_at_utc": "ISO datetime"
}
```

**Validation Rules:**
- `type=text`: `content` required
- `type=image/file/voice`: `attachment_url` required
- `type=voice`: `duration_seconds` required

**Response:**
```json
{
  "id": "uuid",
  "sender_id": "uuid",
  "recipient_id": "uuid",
  "content": "string",
  "timestamp": "ISO datetime",
  "created_at": "ISO datetime (server received)",
  "delivered_at": null,
  "read_at": null,
  "message_type": "text",
  "delivery_authority": "server",
  "attachment_url": null,
  "duration_seconds": null
}
```

### Message Status Definitions

| Field | When Set | Description |
|-------|----------|-------------|
| `created_at` | Server receives | Server timestamp on reception |
| `delivered_at` | Device ACK | Recipient device pulled/received message |
| `read_at` | Chat opened | Recipient opened conversation |

---

## 4. Notifications

### 4.1 Get Notifications
```http
GET /api/notifications?limit=50
Authorization: Bearer {token}
```

**Response:**
```json
[
  {
    "id": "uuid",
    "type": "message | like | comment | friendRequest | security",
    "data": { ... },
    "timestamp": "ISO datetime",
    "is_read": false
  }
]
```

### Notification Payload Schema (for Deep Links)

#### type: "message"
```json
{
  "room_id": "uuid_uuid",
  "peer_id": "uuid",
  "peer_username": "string",
  "sender_id": "uuid",
  "sender_username": "string",
  "message_id": "uuid",
  "preview": "string (truncated content)",
  "message_type": "text | voice | image | file"
}
```

#### type: "like"
```json
{
  "post_id": "uuid",
  "liker_id": "uuid",
  "liker_username": "string"
}
```

#### type: "comment"
```json
{
  "post_id": "uuid",
  "comment_id": "uuid",
  "commenter_id": "uuid",
  "commenter_username": "string",
  "preview": "string"
}
```

#### type: "friendRequest"
```json
{
  "requester_id": "uuid",
  "requester_username": "string"
}
```

#### type: "security"
```json
{
  "event": "new_login | password_changed",
  "device": "string",
  "ip": "string",
  "location": "string (optional)"
}
```

---

## 5. Posts

### 5.1 Create Post
```http
POST /api/posts
Authorization: Bearer {token}
```

### 5.2 Forward Post (In-App Only)
```http
POST /api/posts/{post_id}/forward
Authorization: Bearer {token}
```

**Request:**
```json
{
  "recipient_ids": ["uuid", "uuid"]
}
```

> ✅ Replaces Repost/Share. No external sharing.

---

## 6. AI Ask (Gemini Integration)

### 6.1 Ask AI About a Post
```http
POST /api/ai/ask
Authorization: Bearer {token}
```

**Request:**
```json
{
  "post_id": "uuid (required)",
  "question": "string (required)",
  "comment_id": "uuid (optional - for threaded context)",
  "idempotency_key": "string (optional - prevents duplicate requests)",
  "context": "string (optional - additional context)",
  "enable_search": true,
  "lang": "en"
}
```

**Response (200):**
```json
{
  "answer": "string",
  "model": "gemma-3-4b-it",
  "tokens_used": null,
  "sources": ["bbc.com", "reuters.com"],
  "cached": false
}
```

> ✅ `sources` only contains domain names (no full URLs for privacy)
> ✅ `cached: true` if idempotency key matched a previous request

---

### 6.2 Ask via Comment (@ask Trigger)

When a user comments `@ask <question>` on a post, the backend automatically:

1. Detects the `@ask` trigger
2. Fetches post content (text + image)
3. Sends to Gemini with full context
4. Creates an AI reply comment in the thread

**Example:**
```
User: @ask what is he saying in this video?
Gemini (auto-reply): The person in the video is explaining...
```

**Trigger patterns:**
- `@ask what is this?`
- `@ask summarize this post`
- `@ask روش فارسی جواب بده` (Persian)

---

### 6.3 Web Search (Fact-Checking)

AI automatically performs web search when question contains:
- `verify`, `confirm`, `true`, `false`, `fact`, `source`
- `واقعیه`, `حقیقت`, `راسته` (Persian)
- `حقيقة`, `تأكيد` (Arabic)

**Response includes:**
```json
{
  "answer": "Based on verified sources...",
  "sources": ["bbc.com", "reuters.com", "wikipedia.org"]
}
```

> ⚠️ Sources are domain names only, not full URLs

---

*(Unchanged from previous version)*

---

## 8. Rate Limits

| Endpoint | Limit | Window | Lockout |
|----------|-------|--------|---------|
| Register | 5 | 60 min | 120 min |
| Login | 5 | 15 min | 30 min |
| Send Code | 20 | 60 min | 60 min |
| Verify Code | 10 | 15 min | 30 min |

---

## 9. Security Notes

1. **Passwords**: Min 10 chars + uppercase + lowercase + number + special + no username
2. **OTP Expiry**: 10 minutes (600 seconds) - unified
3. **Restricted Tokens**: Register returns limited-scope token
4. **Encryption**: Sensitive fields encrypted at rest
5. **Block Check**: Messages blocked between blocked users

---

*Document updated: 2026-01-31 (v1.2 - Added AI Ask)*
