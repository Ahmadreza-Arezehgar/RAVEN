from sqlalchemy import Column, String, Integer, Boolean, DateTime, ForeignKey, Text, UniqueConstraint, Float
from sqlalchemy.orm import relationship
from datetime import datetime
from database import Base
import uuid

class User(Base):
    """User model with encrypted sensitive fields."""
    __tablename__ = "users"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    username = Column(String, unique=True, nullable=True, index=True)  # Nullable for OAuth users before username selection
    password_hash = Column(String, nullable=True)  # Nullable for OAuth users
    
    # OAuth fields
    oauth_provider = Column(String, nullable=True)  # 'google', 'apple', or None
    oauth_provider_id = Column(String, nullable=True, index=True)  # Provider's user ID
    
    # User profile fields
    first_name = Column(String)  # Encrypted
    last_name = Column(String)   # Encrypted
    birth_year = Column(Integer)
    birthday = Column(DateTime, nullable=True)  # Full birthday date
    email = Column(String, unique=True, nullable=True, index=True)  # Encrypted, optional
    email_hash = Column(String, unique=True, nullable=True, index=True)  # SHA256 hash for lookup
    phone = Column(String, unique=True, nullable=True, index=True)  # Encrypted, optional
    public_key = Column(Text)
    avatar_path = Column(String)
    bio = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    last_login = Column(DateTime)
    # 🔴 ROUND 45 (2026-05-19) — cross-instance access-token revocation.
    #
    # The pre-R45 `_revoked_access_jti` dict in `auth.py` was per-process.
    # Cloud Run auto-scales to N instances + scales-to-zero — every cold
    # start lost the revocation set, and a stolen JWT survived `/logout`
    # whenever the next request happened to land on a fresh instance.
    #
    # `tokens_invalidated_at` is the persistent fix: `/logout` stamps
    # this column with `utcnow()`, and `get_current_user` rejects any
    # token whose `iat` (issued-at) is BEFORE this stamp. Works
    # identically across N instances, survives cold start, and costs
    # one extra column read on the existing user-fetch query.
    tokens_invalidated_at = Column(DateTime, nullable=True)
    is_verified = Column(Boolean, default=False)  # Verified badge (blue tick)
    # MESSENGER PIVOT (2026-06): RAVEN+ subscription removed — every account is
    # premium for free. Default True, and premium_expires_at left NULL (= a
    # permanent grant), so the lazy-expiry downgrade in users.py never fires.
    # One-time migration for existing rows:
    #   UPDATE users SET is_premium = true, premium_expires_at = NULL;
    is_premium = Column(Boolean, default=True)   # all features free for everyone
    premium_expires_at = Column(DateTime, nullable=True)  # When subscription expires (null = permanent)
    verified_at = Column(DateTime, nullable=True)  # When identity verification was approved
    verification_badge_type = Column(String, default='identity', nullable=True)  # identity, business, creator
    verification_visibility = Column(Boolean, default=True)  # Show/hide badge
    
    # Email/Phone verification status (timestamps for when verified)
    email_verified = Column(Boolean, default=False)  # True after verification
    phone_verified = Column(Boolean, default=False)  # True after SMS verification
    email_verified_at = Column(DateTime, nullable=True)  # When email was verified
    phone_verified_at = Column(DateTime, nullable=True)  # When phone was verified
    phone_e164 = Column(String, unique=True, nullable=True, index=True)  # E.164 format (+1234567890)
    phone_hash = Column(String, unique=True, nullable=True, index=True)  # HMAC-SHA256 for contact matching
    allow_contact_discovery = Column(Boolean, default=True)  # Allow friends to find via phone
    verification_status = Column(String, default='pending')  # pending, verified
    status = Column(String, default='active')  # active, locked, pending
    
    # Privacy settings
    is_private = Column(Boolean, default=False)  # Private profile = posts/friends hidden
    show_birthday = Column(Boolean, default=False)  # Show birthday on profile
    
    # Notification preferences (server-side enforcement)
    push_enabled = Column(Boolean, default=True)  # Master switch: all push notifications
    message_notifications_enabled = Column(Boolean, default=True)  # Push for new messages
    friend_request_notifications_enabled = Column(Boolean, default=True)  # Push for friend requests
    likes_comments_notifications_enabled = Column(Boolean, default=True)  # Push for likes/comments/replies
    sounds_enabled = Column(Boolean, default=True)  # Push with sound vs silent
    message_preview_enabled = Column(Boolean, default=True)  # Show message text in push or "New message"
    
    # Privacy settings (server-side enforcement)
    show_online_status = Column(Boolean, default=True)  # Others can see online/last seen
    read_receipts_enabled = Column(Boolean, default=True)  # Send read receipts to sender
    who_can_message = Column(String, default="everyone")  # "everyone" | "friends"
    who_can_see_profile = Column(String, default="public")  # "public" | "friends"
    # 🔴 ROUND 71 phase 3 (2026-05-24) — back the three privacy toggles
    # the iOS PrivacySettingsView PATCHes. Previously these were
    # accepted by Pydantic but written via setattr to an unmapped
    # attribute, silently dropped on commit. Migration in main.py
    # provisions the columns; setattr smokescreen in users.py is
    # replaced with direct attribute writes.
    show_liked_posts = Column(Boolean, default=True)  # Other users can see my liked posts
    show_replies = Column(Boolean, default=True)  # Show my comment-replies on profile
    allow_contact_share = Column(Boolean, default=True)  # Allow friends to forward my contact card
    
    # Profile Enhancements
    hobbies = Column(Text, nullable=True)  # JSON array of hobbies/interests
    spotify_track_id = Column(String, nullable=True)
    spotify_track_title = Column(String, nullable=True)
    spotify_track_artist = Column(String, nullable=True)
    spotify_cover_url = Column(String, nullable=True)
    spotify_preview_url = Column(String, nullable=True)
    
    # Moderation enforcement
    is_banned = Column(Boolean, default=False)  # Permanently banned
    banned_at = Column(DateTime, nullable=True)  # When ban was applied
    ban_reason = Column(Text, nullable=True)  # Statement of Reasons for ban
    is_restricted = Column(Boolean, default=False)  # Temporarily restricted
    restricted_until = Column(DateTime, nullable=True)  # For tempban / timed restrictions
    restriction_scope = Column(String, nullable=True)  # posting, messaging, visibility, all
    
    # Push Notification fields
    push_token = Column(String, nullable=True, index=True)  # APNs or FCM device token
    push_platform = Column(String, nullable=True)  # 'ios' or 'android'
    
    # Relationships
    sent_messages = relationship("Message", foreign_keys="Message.sender_id", back_populates="sender")
    received_messages = relationship("Message", foreign_keys="Message.recipient_id", back_populates="recipient")
    posts = relationship("Post", back_populates="author")

class Message(Base):
    """Message model with encrypted content."""
    __tablename__ = "messages"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    sender_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    recipient_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    content = Column(Text, nullable=False)  # Encrypted
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    read_at = Column(DateTime)
    delivered_at = Column(DateTime)
    
    # Voice message fields
    message_type = Column(String, default="text")  # text, voice, image, file
    audio_url = Column(String, nullable=True)  # URL for voice/image/file on CDN
    audio_duration_seconds = Column(Integer, nullable=True)  # Voice message duration
    
    # File attachment metadata (for file/image/voice messages)
    file_name = Column(String, nullable=True)  # Original filename
    file_size = Column(Integer, nullable=True)  # Size in bytes
    mime_type = Column(String, nullable=True)  # e.g. "application/pdf"
    
    # ✅ Reply fields (so receivers can see reply preview)
    reply_to_message_id = Column(String, nullable=True)
    reply_to_text_preview = Column(String, nullable=True)  # Max 50 chars
    reply_to_sender_name = Column(String, nullable=True)
    reply_to_type = Column(String, nullable=True)  # text, voice, image, file
    
    # ✅ Scheduled message fields
    send_mode = Column(String, default="instant")  # instant, scheduled
    scheduled_at_utc = Column(DateTime, nullable=True, index=True)  # When to send
    
    # ✅ Smart Message Expiry fields
    expiry_mode = Column(String, nullable=True)  # none, deleteAfterRead, deleteAfter24h, deleteAfter7d, deleteIfScreenshot, deleteIfForwarded
    expires_at = Column(DateTime, nullable=True, index=True)  # Auto-calculated expiry time
    is_expired = Column(Boolean, default=False, index=True)  # Mark expired for cleanup
    allow_forward = Column(Boolean, default=True)  # False for deleteIfForwarded
    
    # Voice message transcription (on-demand via Gemini)
    transcript_text = Column(Text, nullable=True)
    transcript_status = Column(String, default='none')      # none|pending|processing|ready|failed
    transcript_language = Column(String, nullable=True)     # ISO 639-1 code

    # 🔴 ROUND 26 — Telegram-style media albums.
    # When a sender multi-picks N photos/videos, each item still
    # produces its own Message row (so each item keeps its own
    # encrypted body, signed URLs, ACK lifecycle), but they share
    # an opaque `media_group_key`. The receiver groups rows with
    # the same key into one rendered "album" bubble. Server is a
    # passthrough — it doesn't enforce N ≤ 10 or any ordering;
    # the client owns the UX rules.
    media_group_key = Column(String, nullable=True, index=True)
    media_group_index = Column(Integer, nullable=True)      # 0-based position in album
    media_group_total = Column(Integer, nullable=True)      # total items in album

    # Relationships
    sender = relationship("User", foreign_keys=[sender_id], back_populates="sent_messages")
    recipient = relationship("User", foreign_keys=[recipient_id], back_populates="received_messages")

class Post(Base):
    """Post model with encrypted content and GPS location for local feed."""
    __tablename__ = "posts"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    author_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    content = Column(Text, nullable=False)  # Encrypted
    image_url = Column(String)
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    edited_at = Column(DateTime, nullable=True)  # When post was last edited (null if never edited)
    likes = Column(Integer, default=0)
    is_local = Column(Boolean, default=True)
    
    # GPS Location fields for Local Feed
    latitude = Column(Float, nullable=True, index=True)
    longitude = Column(Float, nullable=True, index=True)
    geohash = Column(String(12), nullable=True, index=True)  # For efficient radius queries
    view_count = Column(Integer, default=0)  # Atomic view counter (no viewer list for privacy)
    
    # Visibility control for local posts
    visibility = Column(String, default='public', index=True)  # 'public' | 'friends' | 'local'
    radius_m = Column(Integer, default=2000)  # Visibility radius for local posts (meters)
    
    # Moderation
    is_hidden = Column(Boolean, default=False)  # Hidden by moderation action
    
    # Room post support
    post_type = Column(String, default='text', index=True)  # 'text' | 'image' | 'room' | 'voice' | 'voice_chain'
    room_id = Column(String, ForeignKey("audio_rooms.id"), nullable=True, index=True)
    
    # Voice post support
    voice_url = Column(String, nullable=True)          # CDN URL for voice audio
    voice_duration = Column(Integer, nullable=True)     # Duration in seconds
    waveform = Column(Text, nullable=True)              # JSON array of floats for waveform viz
    
    # Collaborative post support (chain publish)
    origin_chain_id = Column(String, nullable=True)     # FK to voice/video chain if published from chain
    co_authors = Column(Text, nullable=True)            # JSON array of user IDs
    
    # Voice transcription (on-demand via Gemini)
    transcript_text = Column(Text, nullable=True)           # Full transcript text
    transcript_status = Column(String, default='none')      # none|pending|processing|ready|failed
    transcript_language = Column(String, nullable=True)     # ISO 639-1 code (e.g. 'en', 'fa')
    
    # Mesh post support
    mesh_origin = Column(Boolean, default=False)  # True if post was created offline via mesh
    hashtags = Column(Text, nullable=True)  # JSON array of hashtags e.g. ["raven", "mesh"]
    mesh_signature = Column(Text, nullable=True)  # Base64 Ed25519 signature from origin device
    mesh_signer_key = Column(String, nullable=True)  # Base64 public key of the signing device
    
    # Relationships
    author = relationship("User", back_populates="posts")
    room = relationship("AudioRoom", foreign_keys=[room_id])
    comments = relationship("Comment", back_populates="post", cascade="all, delete-orphan")
    media = relationship("PostMedia", back_populates="post", cascade="all, delete-orphan", order_by="PostMedia.order_index")

class PostMedia(Base):
    """Media items for multi-image posts (max 4 per post)."""
    __tablename__ = "post_media"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    url = Column(String, nullable=False)
    order_index = Column(Integer, default=0)  # 0-3 for ordering
    media_type = Column(String, default='image')  # 'image' | 'video'
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    post = relationship("Post", back_populates="media")

class FriendRequest(Base):
    """Friend request model for tracking friend requests."""
    __tablename__ = "friend_requests"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    requester_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    recipient_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    status = Column(String, nullable=False, default="pending")  # pending, accepted, rejected
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class ScreenshotNotification(Base):
    """Track screenshot attempts on profile pictures."""
    __tablename__ = "screenshot_notifications"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    profile_owner_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    screenshotter_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    is_read = Column(Boolean, default=False)

class Comment(Base):
    """Comment model with support for threaded replies and AI-generated responses."""
    __tablename__ = "comments"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    author_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    parent_comment_id = Column(String, ForeignKey("comments.id"), nullable=True, index=True)
    content = Column(Text, nullable=False)  # Encrypted
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    score = Column(Integer, default=0, index=True)  # likes - dislikes for sorting
    is_ai_generated = Column(Boolean, default=False)  # Mark AI-generated responses
    media_id = Column(String, ForeignKey("post_media.id"), nullable=True, index=True)  # For per-media comments
    entities = Column(Text, nullable=True)  # JSON: [{type, userId, username, rangeStart, rangeLength}]
    is_hidden = Column(Boolean, default=False)  # Hidden by moderation action
    is_pinned = Column(Boolean, default=False, index=True)  # 🔴 ROUND 26 — author can pin a comment to top
    edited_at = Column(DateTime, nullable=True)  # 🔴 ROUND 26 — last PATCH timestamp; null = never edited
    comment_type = Column(String, default="text")  # "text" | "voice" | "image"
    media_url = Column(String, nullable=True)       # CDN URL for voice/image
    duration_sec = Column(Float, nullable=True)      # Voice duration in seconds
    
    # Voice comment transcription (on-demand via Gemini)
    transcript_text = Column(Text, nullable=True)
    transcript_status = Column(String, default='none')      # none|pending|processing|ready|failed
    transcript_language = Column(String, nullable=True)
    
    # Relationships
    post = relationship("Post", back_populates="comments")
    author = relationship("User", foreign_keys=[author_id])
    parent = relationship("Comment", remote_side=[id], back_populates="replies", foreign_keys=[parent_comment_id])
    replies = relationship("Comment", back_populates="parent", cascade="all, delete-orphan", foreign_keys=[parent_comment_id])

class CommentVote(Base):
    """Junction table for tracking user votes on comments (like/dislike)."""
    __tablename__ = "comment_votes"
    __table_args__ = (
        UniqueConstraint('comment_id', 'user_id', name='unique_comment_vote'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    comment_id = Column(String, ForeignKey("comments.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    vote = Column(Integer, nullable=False)  # +1 = like, -1 = dislike
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)



class PostLike(Base):
    """Junction table for tracking which users liked which posts (one like per user per post)."""
    __tablename__ = "post_likes"
    __table_args__ = (
        UniqueConstraint('post_id', 'user_id', name='unique_post_like'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)


class Repost(Base):
    """Track reposts of posts by users."""
    __tablename__ = "reposts"
    __table_args__ = (
        UniqueConstraint('original_post_id', 'user_id', name='unique_repost'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    original_post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    content = Column(Text, nullable=True)  # Optional quote/comment on repost (encrypted)
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # Relationships
    original_post = relationship("Post")
    user = relationship("User")


class PostView(Base):
    """Track unique post views with hashed viewer identity.
    
    Privacy-first design:
    - viewer_key is SHA256(userId + serverSalt), NOT raw userId
    - No endpoint exists to retrieve viewer list
    - Only view_count is exposed via API
    """
    __tablename__ = "post_views"
    __table_args__ = (
        UniqueConstraint('post_id', 'viewer_key', name='unique_post_view'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    viewer_key = Column(String(64), nullable=False, index=True)  # SHA256 hash = 64 hex chars
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)


class SnapMessage(Base):
    """One-shot disappearing photo/video messages."""
    __tablename__ = "snap_messages"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    sender_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    recipient_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    media_url = Column(String, nullable=False)  # Encrypted at rest
    media_type = Column(String, default="image")  # image/video
    
    # Timing
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    expires_at = Column(DateTime, nullable=False)  # 24h default
    opened_at = Column(DateTime, nullable=True)  # Set when first viewed
    view_duration = Column(Integer, default=8)  # Seconds to view
    
    # Controls
    view_limit = Column(Integer, default=1)  # 1 = one-shot
    view_count = Column(Integer, default=0)
    status = Column(String, default="sent")  # sent/opened/expired
    screenshot_attempted = Column(Boolean, default=False)
    
    # Ephemeral photo extras
    conversation_id = Column(String, nullable=True, index=True)  # Room context
    ttl_seconds = Column(Integer, default=10)  # Configurable TTL (5s or 10s)
    
    # Relationships
    sender = relationship("User", foreign_keys=[sender_id])
    recipient = relationship("User", foreign_keys=[recipient_id])


class VoiceMessage(Base):
    """Voice message with optional transcription."""
    __tablename__ = "voice_messages"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    message_id = Column(String, ForeignKey("messages.id"), nullable=True, index=True)  # Link to parent message
    sender_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    recipient_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    
    # Audio
    audio_url = Column(String, nullable=False)
    duration_seconds = Column(Integer, nullable=False)
    waveform_data = Column(Text, nullable=True)  # JSON array of amplitudes
    
    # Transcription
    transcript = Column(Text, nullable=True)  # Whisper-generated
    transcript_language = Column(String, nullable=True)  # en/es/de/fa
    transcript_status = Column(String, default="pending")  # pending/processing/ready/failed
    
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    sender = relationship("User", foreign_keys=[sender_id])
    recipient = relationship("User", foreign_keys=[recipient_id])


# ==================== BACKUP SYSTEM ====================

class Backup(Base):
    """Cloud backup metadata for user data."""
    __tablename__ = "backups"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    size_bytes = Column(Integer, default=0)
    message_count = Column(Integer, default=0)
    media_count = Column(Integer, default=0)
    last_message_at = Column(DateTime, nullable=True)
    version = Column(Integer, default=1)
    is_encrypted = Column(Boolean, default=False)
    encryption_key_hash = Column(String, nullable=True)  # For E2E encrypted backups
    status = Column(String, default="pending")  # pending, uploading, completed, failed
    
    # Relationships
    user = relationship("User")


class MediaObject(Base):
    """Track all media files stored on server for backup/restore."""
    __tablename__ = "media_objects"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    type = Column(String, nullable=False)  # voice, image, video
    url = Column(String, nullable=False)
    file_hash = Column(String, nullable=True, index=True)  # SHA256 for dedup
    size_bytes = Column(Integer, default=0)
    original_filename = Column(String, nullable=True)
    mime_type = Column(String, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    owner = relationship("User")


class SyncQueue(Base):
    """Queue for offline messages/media waiting to sync."""
    __tablename__ = "sync_queue"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    item_type = Column(String, nullable=False)  # message, voice, image, post
    item_id = Column(String, nullable=False, index=True)
    payload = Column(Text, nullable=False)  # JSON serialized data
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    retry_count = Column(Integer, default=0)
    last_error = Column(Text, nullable=True)
    status = Column(String, default="pending")  # pending, syncing, completed, failed


# ==================== POST NOTIFICATIONS ====================

class PostSubscription(Base):
    """Subscription to receive notifications when a user posts."""
    __tablename__ = "post_subscriptions"
    __table_args__ = (
        UniqueConstraint('subscriber_id', 'target_id', name='unique_post_subscription'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    subscriber_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    target_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    subscriber = relationship("User", foreign_keys=[subscriber_id])
    target = relationship("User", foreign_keys=[target_id])


# ==================== ROOM VISIBILITY ====================

class RoomVisibility(Base):
    """Track room visibility, read status, and per-user UI preferences per (user, room).

    Round 49 (2026-05-17): added `is_archived` + `archived_at` for
    cross-device archive sync. iOS already persists archive state in
    local SQLite (Migration 35); these columns let the server echo
    that state back via `/api/messages/conversations` so a fresh
    install / second device inherits the bucket.
    """
    __tablename__ = "room_visibility"
    __table_args__ = (
        UniqueConstraint('user_id', 'room_id', name='unique_room_user'),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    # Canonical thread identifier:
    #   • 1:1     → "{userId1}_{userId2}" OR a single peer userId (iOS uses peer-userId)
    #   • group   → the group_id (UUID)
    room_id = Column(String, nullable=False, index=True)
    hidden = Column(Boolean, default=False)  # Hide conversation for this user
    last_read_at = Column(DateTime, nullable=True)  # Last time user read messages in this room
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    # Round 49 — per-user archive bucket.
    is_archived = Column(Boolean, default=False, nullable=False)
    archived_at = Column(DateTime, nullable=True)

    # Relationships
    user = relationship("User")


# ==================== NOTIFICATIONS ====================

class Notification(Base):
    """Generic notification model for likes, new posts, etc."""
    __tablename__ = "notifications"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    type = Column(String, nullable=False, index=True)  # 'like', 'post_from_followed', 'comment', etc.
    data = Column(Text, nullable=True)  # JSON data with notification details
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    is_read = Column(Boolean, default=False, index=True)
    
    # Relationships
    user = relationship("User")


# ==================== DEVICE IDENTITY ====================

class Device(Base):
    """Device model for cryptographic identity (public key fingerprints).
    
    Used to link BLE/Mesh device fingerprints to user accounts.
    Enables friends to auto-connect over mesh without in-app prompts.
    """
    __tablename__ = "devices"
    __table_args__ = (
        UniqueConstraint('fingerprint', name='unique_device_fingerprint'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    fingerprint = Column(String, unique=True, nullable=False, index=True)  # SHA256 of public key
    public_key = Column(Text, nullable=False)  # PEM-encoded public key
    platform = Column(String, nullable=True)  # ios/android
    device_name = Column(String, nullable=True)  # "iPhone 15 Pro", optional
    last_seen_at = Column(DateTime, default=datetime.utcnow)
    revoked = Column(Boolean, default=False)  # For key revocation
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    user = relationship("User")


# ==================== VERIFICATION TOKENS ====================

class VerificationToken(Base):
    """Secure verification tokens for email/SMS verification and password reset.
    
    Security features:
    - Token stored as SHA256 hash (never plaintext)
    - Single-use (consumed_at marks as used)
    - Attempt limiting (max 5 attempts)
    - Cooldown between resends (60s)
    - Short expiry (5 minutes)
    """
    __tablename__ = "verification_tokens"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=True, index=True)  # Nullable for registration tokens
    channel = Column(String, nullable=False)  # 'email' or 'sms'
    purpose = Column(String, nullable=False)  # 'verify_email', 'verify_phone', 'reset_password'
    token_hash = Column(String, nullable=False)  # SHA256 hash of token/OTP
    sent_to = Column(String, nullable=False)  # Email address or phone number
    expires_at = Column(DateTime, nullable=False)
    attempts = Column(Integer, default=0)  # Failed verification attempts (max 5)
    cooldown_until = Column(DateTime, nullable=True)  # When next resend is allowed
    consumed_at = Column(DateTime, nullable=True)  # When token was successfully used
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    user = relationship("User")


class RefreshToken(Base):
    """Refresh tokens for secure session management.
    
    Features:
    - Long-lived (90 days)
    - Revocable (for logout or security)
    - Token rotation (each refresh generates new token)
    - Theft detection (old token reuse revokes all tokens)
    - Device tracking (optional)
    """
    __tablename__ = "refresh_tokens"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    token_hash = Column(String, nullable=False, index=True)  # SHA256 hash
    expires_at = Column(DateTime, nullable=False)
    revoked_at = Column(DateTime, nullable=True)  # When token was revoked
    replaced_by = Column(String, nullable=True, index=True)  # ID of replacement token (for rotation)
    device_id = Column(String, nullable=True)  # Optional device identifier
    device_name = Column(String, nullable=True)  # "iPhone 15 Pro"
    ip_address = Column(String, nullable=True)  # For security audit
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    user = relationship("User")


# Legacy OTPCode table - kept for backward compatibility
class OTPCode(Base):
    """DEPRECATED: Use VerificationToken instead. Kept for migration."""
    __tablename__ = "otp_codes"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    channel = Column(String, nullable=False)
    code = Column(String, nullable=False)
    purpose = Column(String, default='verification')
    expires_at = Column(DateTime, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    used_at = Column(DateTime, nullable=True)
    attempts = Column(Integer, default=0)
    
    user = relationship("User")


# ==================== CHANNELS (Telegram-style broadcast) ====================

class Channel(Base):
    """Broadcast channel — only owner/admin can post, members are read-only."""
    __tablename__ = "channels"

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    owner_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    channel_username = Column(String, unique=True, nullable=False, index=True)  # @channel_id, globally unique
    name = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    avatar_url = Column(String, nullable=True)
    type = Column(String, default="public")  # "public" or "private"
    verified_status = Column(String, default="none")  # none | eligible | verified
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    # Relationships
    owner = relationship("User", foreign_keys=[owner_id])
    members = relationship("ChannelMember", back_populates="channel", cascade="all, delete-orphan")
    posts = relationship("ChannelPost", back_populates="channel", cascade="all, delete-orphan")


class ChannelMember(Base):
    """Channel membership with role and per-user mute setting."""
    __tablename__ = "channel_members"
    __table_args__ = (
        UniqueConstraint('channel_id', 'user_id', name='unique_channel_member'),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    channel_id = Column(String, ForeignKey("channels.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    role = Column(String, default="member")  # owner, admin, mod, member
    muted = Column(Boolean, default=False)
    joined_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    # Relationships
    channel = relationship("Channel", back_populates="members")
    user = relationship("User")


class ChannelPost(Base):
    """Broadcast post in a channel (created by owner/admin only)."""
    __tablename__ = "channel_posts"

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    channel_id = Column(String, ForeignKey("channels.id"), nullable=False, index=True)
    author_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    content_type = Column(String, default="text")  # text, image, video, voice, shared_post
    content_payload = Column(Text, nullable=True)  # Text content or JSON payload
    media_url = Column(String, nullable=True)  # CDN URL for media
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    # Relationships
    channel = relationship("Channel", back_populates="posts")
    author = relationship("User", foreign_keys=[author_id])


class ChannelInviteLink(Base):
    """Invite link for joining a private channel."""
    __tablename__ = "channel_invite_links"

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    channel_id = Column(String, ForeignKey("channels.id"), nullable=False, index=True, unique=True)
    invite_code = Column(String, nullable=False, unique=True, index=True)
    created_by = Column(String, ForeignKey("users.id"), nullable=False)
    enabled = Column(Boolean, default=True)
    use_count = Column(Integer, default=0)
    max_uses = Column(Integer, nullable=True)  # None = unlimited
    expires_at = Column(DateTime, nullable=True)  # None = no expiry
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    channel = relationship("Channel")
    creator = relationship("User")


# ==================== GROUP CHAT ====================

class Group(Base):
    """Group chat model for multi-user conversations."""
    __tablename__ = "groups"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    name = Column(String, nullable=False)
    avatar_url = Column(String, nullable=True)
    description = Column(Text, nullable=True)
    created_by = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    visibility = Column(String, default="private")  # "public" or "private"
    link_join_enabled = Column(Boolean, default=True)  # Whether invite link joining is allowed
    
    # Fun Pack: Freeze Mode
    is_frozen = Column(Boolean, default=False)
    frozen_by = Column(String, nullable=True)        # user_id of admin who froze
    frozen_at = Column(DateTime, nullable=True)
    
    # Relationships
    creator = relationship("User", foreign_keys=[created_by])
    members = relationship("GroupMember", back_populates="group", cascade="all, delete-orphan")


class GroupMember(Base):
    """Group membership with role (admin/member)."""
    __tablename__ = "group_members"
    __table_args__ = (
        UniqueConstraint('group_id', 'user_id', name='unique_group_member'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    group_id = Column(String, ForeignKey("groups.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    role = Column(String, default="member")  # admin, member
    joined_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    group = relationship("Group", back_populates="members")
    user = relationship("User")


class GroupInviteLink(Base):
    """Invite link for joining a group."""
    __tablename__ = "group_invite_links"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    group_id = Column(String, ForeignKey("groups.id"), nullable=False, index=True, unique=True)
    invite_code = Column(String, nullable=False, unique=True, index=True)
    created_by = Column(String, ForeignKey("users.id"), nullable=False)
    enabled = Column(Boolean, default=True)
    use_count = Column(Integer, default=0)
    max_uses = Column(Integer, nullable=True)  # None = unlimited
    expires_at = Column(DateTime, nullable=True)  # None = no expiry
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    group = relationship("Group")
    creator = relationship("User")


class GroupMessage(Base):
    """Message in a group chat."""
    __tablename__ = "group_messages"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    group_id = Column(String, ForeignKey("groups.id"), nullable=False, index=True)
    sender_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    content = Column(Text, nullable=False)  # Encrypted
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # Message type
    message_type = Column(String, default="text")  # text, voice, image, file
    audio_url = Column(String, nullable=True)  # URL for voice/image/file on CDN
    audio_duration_seconds = Column(Integer, nullable=True)  # Voice message duration
    
    # File attachment metadata
    file_name = Column(String, nullable=True)
    file_size = Column(Integer, nullable=True)
    mime_type = Column(String, nullable=True)
    
    # Reply fields
    reply_to_message_id = Column(String, nullable=True)
    reply_to_text_preview = Column(String, nullable=True)
    reply_to_sender_name = Column(String, nullable=True)
    reply_to_type = Column(String, nullable=True)
    
    # Mention entities
    entities = Column(Text, nullable=True)  # JSON: [{type, userId, username, rangeStart, rangeLength}]
    
    # Fun Pack: Time Bomb
    bomb_duration_sec = Column(Integer, nullable=True)  # Seconds until message self-destructs
    
    # Fun Pack: Poll reference
    poll_id = Column(String, nullable=True)  # Links to GroupPoll if message_type="poll"
    
    # Mesh delivery tracking
    recipient_set = Column(Text, nullable=True)   # JSON list of user_ids who should receive this message
    delivered_to  = Column(Text, nullable=True)    # JSON list of user_ids who have ACKed receipt
    
    # Voice message transcription (on-demand via Gemini)
    transcript_text = Column(Text, nullable=True)
    transcript_status = Column(String, default='none')      # none|pending|processing|ready|failed
    transcript_language = Column(String, nullable=True)     # ISO 639-1 code

    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — group key version.
    # When non-NULL, `content` is the AES-GCM ciphertext encrypted
    # under the group's symmetric key at this version. The server
    # stores ciphertext as-is (no Fernet wrap — see is_opaque flag
    # in encrypt_text) and fans the version through to every member
    # so they can decrypt locally via GroupKeyService.
    group_key_version = Column(Integer, nullable=True)

    # 🔴 ROUND 26 — Telegram-style media albums (groups).
    # Mirrors the same shape we added to the 1:1 Message table.
    media_group_key = Column(String, nullable=True, index=True)
    media_group_index = Column(Integer, nullable=True)
    media_group_total = Column(Integer, nullable=True)

    # Relationships
    group = relationship("Group")
    sender = relationship("User")


# ==================== MENTIONS ====================

class Mention(Base):
    """Track @mentions in group chat messages and post comments."""
    __tablename__ = "mentions"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    type = Column(String, nullable=False)  # chat_message, post_comment
    source_id = Column(String, nullable=False)  # message_id or comment_id
    post_id = Column(String, nullable=True)  # For post_comment type
    room_id = Column(String, nullable=True)  # For chat_message type (group_id)
    mentioned_user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    mentioned_by_user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    snippet = Column(Text, nullable=True)  # Short preview text
    deep_link = Column(String, nullable=True)  # app://chat/<room_id>?message=<id>
    is_read = Column(Boolean, default=False, index=True)
    
    # Relationships
    mentioned_user = relationship("User", foreign_keys=[mentioned_user_id])
    mentioned_by = relationship("User", foreign_keys=[mentioned_by_user_id])


# ==================== IDENTITY VERIFICATION ====================

class VerificationRequest(Base):
    """Identity verification request with admin review workflow."""
    __tablename__ = "verification_requests"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    status = Column(String, nullable=False, default='pending')  # pending, needs_more_info, rejected, verified, revoked
    
    # Personal info (encrypted at rest)
    legal_first_name = Column(String, nullable=False)
    legal_last_name = Column(String, nullable=False)
    country = Column(String, nullable=False)
    category = Column(String, nullable=False, default='person')  # person, brand, org
    
    # Document info
    doc_type = Column(String, nullable=False)  # passport, national_id, drivers_license
    doc_front_url = Column(String, nullable=True)
    doc_back_url = Column(String, nullable=True)
    selfie_url = Column(String, nullable=True)
    
    # Optional external links for notability
    links_json = Column(Text, nullable=True)  # JSON array of {type, url}
    
    # Timestamps
    submitted_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    reviewed_at = Column(DateTime, nullable=True)
    
    # Admin review
    reviewer_admin_id = Column(String, nullable=True)
    decision_reason = Column(Text, nullable=True)   # Shown to user
    notes_internal = Column(Text, nullable=True)     # Admin-only notes
    
    # Anti-spam
    hash_dedupe = Column(String, nullable=True)      # Dedup hash
    version = Column(Integer, default=1)             # Optimistic locking
    
    # Relationships
    user = relationship("User", foreign_keys=[user_id])


# ==================== MODERATION ====================

class Report(Base):
    """User reports for content moderation — full lifecycle with AI triage, decision, and appeal."""
    __tablename__ = "reports"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    reporter_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    target_type = Column(String, nullable=False)  # user, post, comment, message, group, room, story, media
    target_id = Column(String, nullable=False, index=True)
    reported_user_id = Column(String, ForeignKey("users.id"), nullable=True, index=True)  # Owner of reported content
    reason = Column(String, nullable=False)  # spam, harassment, hate_speech, violence, nudity, illegal, impersonation, privacy, self_harm, false_info, other
    note = Column(Text, nullable=True)  # Optional description from reporter
    evidence_json = Column(Text, nullable=True)  # JSON: screenshot URLs, file IDs
    context_json = Column(Text, nullable=True)  # JSON: {conversation_id, message_id, post_id, ...}
    status = Column(String, default="open")  # open, triaged, escalated, actioned, dismissed
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # AI Triage fields (populated by ai_triage worker)
    ai_category = Column(String, nullable=True)   # spam, harassment, hate, sexual, violence, scam, etc.
    ai_severity = Column(Integer, nullable=True)   # 0-100
    ai_confidence = Column(Float, nullable=True)   # 0.0-1.0
    ai_summary = Column(Text, nullable=True)       # Short summary for admin review
    triaged_at = Column(DateTime, nullable=True)
    
    # Decision fields (set by admin or system for low-risk auto-actions)
    decision = Column(String, default="none")      # none, warn, remove_content, restrict, tempban, ban, mute, shadowban
    decision_reason = Column(Text, nullable=True)  # Statement of Reasons (DSA Article 17)
    decided_by = Column(String, nullable=True)     # admin user ID or "system"
    decided_at = Column(DateTime, nullable=True)
    
    # Appeal fields (DSA Article 20 — internal complaint handling)
    appeal_status = Column(String, default="none") # none, pending, accepted, rejected
    appeal_text = Column(Text, nullable=True)
    appeal_decided_by = Column(String, nullable=True)
    appeal_decided_at = Column(DateTime, nullable=True)
    
    # Relationships
    reporter = relationship("User", foreign_keys=[reporter_id])
    reported_user = relationship("User", foreign_keys=[reported_user_id])


class ModerationAction(Base):
    """Audit log for every moderation action — required for legal compliance and debugging."""
    __tablename__ = "moderation_actions"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    report_id = Column(String, ForeignKey("reports.id"), nullable=True, index=True)
    target_type = Column(String, nullable=False)     # user, post, comment, message, group, room
    target_id = Column(String, nullable=False, index=True)
    action_type = Column(String, nullable=False)     # warn, remove_content, restrict, tempban, ban, mute, shadowban, reverse
    parameters_json = Column(Text, nullable=True)    # JSON: {duration: "7d", scope: "posting", ...}
    actor = Column(String, nullable=False)           # admin_id or "system"
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    reversible = Column(Boolean, default=True)
    reversed_at = Column(DateTime, nullable=True)
    reversed_by = Column(String, nullable=True)
    
    # Relationships
    report = relationship("Report", foreign_keys=[report_id])


class Block(Base):
    """Block relationships between users."""
    __tablename__ = "blocks"
    __table_args__ = (
        UniqueConstraint('blocker_id', 'blocked_id', name='unique_block'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    blocker_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    blocked_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    blocker = relationship("User", foreign_keys=[blocker_id])
    blocked = relationship("User", foreign_keys=[blocked_id])


class HiddenContent(Base):
    """Content hidden from a user (via report or block)."""
    __tablename__ = "hidden_content"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    object_type = Column(String, nullable=False)  # post, comment, message, story, user
    object_id = Column(String, nullable=False)
    hidden_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    reason = Column(String, default="reported")  # reported, blocked, moderation
    
    # Unique constraint
    __table_args__ = (
        UniqueConstraint('user_id', 'object_type', 'object_id', name='unique_hidden'),
    )


class Friendship(Base):
    """Explicit friendship record (bidirectional after acceptance)."""
    __tablename__ = "friendships"
    __table_args__ = (
        UniqueConstraint('user_id', 'friend_id', name='unique_friendship'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    friend_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    user = relationship("User", foreign_keys=[user_id])
    friend = relationship("User", foreign_keys=[friend_id])


# ==================== MESSAGE REQUESTS ====================

class MessageRequest(Base):
    """Message request for non-friend messaging (RAVEN+ feature).
    
    Allows premium users to send up to 3 messages to non-friends.
    Receiver can accept, decline, or block the request.
    """
    __tablename__ = "message_requests"
    __table_args__ = (
        UniqueConstraint('sender_id', 'receiver_id', name='unique_message_request'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    sender_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    receiver_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    status = Column(String, nullable=False, default="pending")  # pending, accepted, declined, blocked
    sent_count = Column(Integer, nullable=False, default=0)  # Messages sent before acceptance (max 3)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Relationships
    sender = relationship("User", foreign_keys=[sender_id])
    receiver = relationship("User", foreign_keys=[receiver_id])


# ==================== RECOMMENDATION SYSTEM ====================

class UserEvent(Base):
    """Track user interactions for recommendation algorithm.
    
    Event types:
    - view_post (with duration_ms)
    - like_post
    - comment_post
    - share_post
    - search_query
    - click_hashtag
    - follow_user
    """
    __tablename__ = "user_events"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    event_type = Column(String, nullable=False, index=True)
    post_id = Column(String, ForeignKey("posts.id"), nullable=True, index=True)
    hashtag = Column(String, nullable=True, index=True)
    query = Column(String, nullable=True)
    duration_ms = Column(Integer, nullable=True)  # Dwell time for view events
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # Relationships
    user = relationship("User")


class UserInterest(Base):
    """User interest profile for personalized recommendations.
    
    Scores are weighted by interaction type:
    - view (dwell>3s): +1
    - like: +3
    - comment: +4
    - share: +5
    - click hashtag: +2
    
    Decay: scores halve every 7 days
    """
    __tablename__ = "user_interests"
    __table_args__ = (
        UniqueConstraint('user_id', 'tag', name='unique_user_interest'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    tag = Column(String, nullable=False, index=True)
    score = Column(Float, default=0.0)
    updated_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    user = relationship("User")


class SeenPost(Base):
    """Track which posts a user has seen for deduplication.
    
    Posts are hidden from recommendations for 48h after being seen.
    """
    __tablename__ = "seen_posts"
    __table_args__ = (
        UniqueConstraint('user_id', 'post_id', name='unique_seen_post'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    seen_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # Relationships
    user = relationship("User")


class HashtagFollow(Base):
    """Track hashtags a user follows for boosted feed visibility."""
    __tablename__ = "hashtag_follows"
    __table_args__ = (
        UniqueConstraint('user_id', 'hashtag', name='unique_hashtag_follow'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    hashtag = Column(String, nullable=False, index=True)  # Stored lowercase without #
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    user = relationship("User")


class UserNegativeFeedback(Base):
    """Track negative user feedback for recommendation algorithm.
    
    Feedback types:
    - hide_post: User hid a specific post (-10 score)
    - hide_author: User hid all posts from author (-100 author affinity)
    - not_interested: User marked topic as not interested (-5 to tag)
    - report: User reported content (-100 score)
    """
    __tablename__ = "user_negative_feedback"
    __table_args__ = (
        UniqueConstraint('user_id', 'target_type', 'target_id', name='unique_negative_feedback'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    feedback_type = Column(String, nullable=False, index=True)  # hide_post, hide_author, not_interested, report
    target_type = Column(String, nullable=False)  # post, author, tag
    target_id = Column(String, nullable=False, index=True)  # post_id, author_id, or tag
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    
    # Relationships
    user = relationship("User")


# ==================== AUDIO ROOMS (Clubhouse-like) ====================

class AudioRoom(Base):
    """Live audio room for voice conversations.
    
    Features:
    - Clubhouse-like audio rooms with host controls
    - Anonymous mode for privacy
    - Presentation support (PDF/Image)
    - Raise hand to speak
    """
    __tablename__ = "audio_rooms"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    title = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    host_user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    room_image_url = Column(String, nullable=True)
    
    # Privacy settings
    privacy = Column(String, default="public")  # public, friends, invite
    allow_anonymous = Column(Boolean, default=True)  # Allow anonymous join
    allow_raise_hand = Column(Boolean, default=True)  # Allow raise hand requests
    
    # Shareable link
    share_slug = Column(String(12), unique=True, nullable=True, index=True)  # For deep links: raven://room/{slug}
    
    # Room state
    is_live = Column(Boolean, default=True, index=True)
    is_locked = Column(Boolean, default=False, nullable=False)  # Host-set: block new joins
    participant_count = Column(Integer, default=0)
    max_participants = Column(Integer, default=100)
    
    # Timestamps
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    ended_at = Column(DateTime, nullable=True)
    last_activity = Column(DateTime, default=datetime.utcnow, nullable=True)  # For auto-close: updated by heartbeat
    
    # LiveKit room info
    livekit_room_name = Column(String, nullable=True)
    
    # Relationships
    host = relationship("User", foreign_keys=[host_user_id])
    participants = relationship("AudioRoomParticipant", back_populates="room", cascade="all, delete-orphan")
    requests = relationship("AudioRoomRequest", back_populates="room", cascade="all, delete-orphan")
    assets = relationship("AudioRoomAsset", back_populates="room", cascade="all, delete-orphan")


class AudioRoomParticipant(Base):
    """Participant in an audio room with role and identity mode."""
    __tablename__ = "audio_room_participants"
    __table_args__ = (
        UniqueConstraint('room_id', 'user_id', name='unique_room_participant'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    room_id = Column(String, ForeignKey("audio_rooms.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    
    # Identity mode
    display_mode = Column(String, default="real")  # real, anonymous
    anon_display_name = Column(String, nullable=True)  # "Anonymous Fox #27"
    anon_avatar_index = Column(Integer, nullable=True)  # Index for generic avatar
    
    # Role and state
    role = Column(String, default="listener")  # host, cohost, speaker, listener
    is_muted = Column(Boolean, default=True)
    is_hand_raised = Column(Boolean, default=False)
    
    # Timestamps
    joined_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    left_at = Column(DateTime, nullable=True)
    last_heartbeat_at = Column(DateTime, default=datetime.utcnow, nullable=True)  # For auto-close: client pings every 15s
    
    # Relationships
    room = relationship("AudioRoom", back_populates="participants")
    user = relationship("User")


class AudioRoomRequest(Base):
    """Raise hand request from listener to speak."""
    __tablename__ = "audio_room_requests"
    __table_args__ = (
        UniqueConstraint('room_id', 'user_id', 'status', name='unique_pending_request'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    room_id = Column(String, ForeignKey("audio_rooms.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    
    # Request state
    status = Column(String, default="pending")  # pending, accepted, declined, cancelled
    
    # Timestamps
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    resolved_at = Column(DateTime, nullable=True)
    resolved_by = Column(String, ForeignKey("users.id"), nullable=True)
    
    # Relationships
    room = relationship("AudioRoom", back_populates="requests")
    user = relationship("User", foreign_keys=[user_id])


class AudioRoomAsset(Base):
    """Presentation asset (PDF/Image) shared in audio room."""
    __tablename__ = "audio_room_assets"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    room_id = Column(String, ForeignKey("audio_rooms.id"), nullable=False, index=True)
    
    # Asset info
    type = Column(String, nullable=False)  # image, pdf
    url = Column(String, nullable=False)
    file_name = Column(String, nullable=True)
    file_size = Column(Integer, nullable=True)
    
    # State
    is_active = Column(Boolean, default=False)  # Currently being presented
    uploaded_by = Column(String, ForeignKey("users.id"), nullable=False)
    
    # Timestamps
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    room = relationship("AudioRoom", back_populates="assets")
    uploader = relationship("User", foreign_keys=[uploaded_by])


# =============================================================================
# STORIES (Instagram-style 24h ephemeral content)
# =============================================================================

class Story(Base):
    """24h ephemeral story with photo/video content."""
    __tablename__ = "stories"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    author_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    
    # Media
    media_url = Column(String, nullable=False)  # CDN URL for image/video
    media_type = Column(String, default="image")  # image, video
    
    # Audience control
    audience = Column(String, default="friends", index=True)  # friends, local
    
    # Location (for local stories)
    latitude = Column(Float, nullable=True)
    longitude = Column(Float, nullable=True)
    geohash = Column(String(12), nullable=True, index=True)
    
    # Timestamps
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    expires_at = Column(DateTime, nullable=False, index=True)  # Typically 24h after created_at
    
    # Single-view mode (can only be viewed once per viewer)
    is_single_view = Column(Boolean, default=False)
    
    # Stats
    seen_count = Column(Integer, default=0)
    
    # Relationships
    author = relationship("User", foreign_keys=[author_id])
    views = relationship("StorySeen", back_populates="story", cascade="all, delete-orphan")
    reactions = relationship("StoryReaction", back_populates="story", cascade="all, delete-orphan")


class StorySeen(Base):
    """Track who has seen a story."""
    __tablename__ = "story_seen"
    __table_args__ = (
        UniqueConstraint('story_id', 'viewer_id', name='unique_story_view'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    story_id = Column(String, ForeignKey("stories.id"), nullable=False, index=True)
    viewer_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    seen_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    reason = Column(String, nullable=True)  # 'swipe', 'timeout', 'manual_close'
    
    # Relationships
    story = relationship("Story", back_populates="views")
    viewer = relationship("User", foreign_keys=[viewer_id])


class StoryReaction(Base):
    """Reactions (likes) on stories."""
    __tablename__ = "story_reactions"
    __table_args__ = (
        UniqueConstraint('story_id', 'user_id', name='unique_story_reaction'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    story_id = Column(String, ForeignKey("stories.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    reaction_type = Column(String, default="like")  # like, love, fire, etc.
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    story = relationship("Story", back_populates="reactions")
    user = relationship("User", foreign_keys=[user_id])


class MessageReaction(Base):
    """Emoji reactions on chat messages — 1:1 and group.

    🔴 2026-05-20 — the iOS client shipped a complete reaction UI
    (MessageReactionStore / ReactionPickerCapsule / EmojiReaction-
    PickerSheet) calling POST/GET /api/messages/{id}/reactions, but
    the server half was never built — every call 404'd, so a tapped
    reaction flashed on screen then reverted. This model + the
    messages.py endpoints are that missing half.

    One table for both message kinds, distinguished by `is_group` so
    the endpoint knows which message table to authorize against. The
    unique constraint stops a user double-reacting with the same
    emoji on the same message.
    """
    __tablename__ = "message_reactions"
    __table_args__ = (
        UniqueConstraint('message_id', 'user_id', 'emoji', name='uq_reaction_msg_user_emoji'),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    message_id = Column(String, nullable=False, index=True)
    is_group = Column(Boolean, nullable=False, default=False)
    user_id = Column(String, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    emoji = Column(String, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)


class StoryScreenshot(Base):
    """Track screenshot attempts on stories."""
    __tablename__ = "story_screenshots"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    story_id = Column(String, ForeignKey("stories.id"), nullable=False, index=True)
    viewer_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    notified = Column(Boolean, default=False)  # Whether author was notified
    
    # Relationships
    story = relationship("Story")
    viewer = relationship("User", foreign_keys=[viewer_id])


class StoryReply(Base):
    """Link story replies to DM messages."""
    __tablename__ = "story_replies"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    story_id = Column(String, ForeignKey("stories.id"), nullable=False, index=True)
    message_id = Column(String, ForeignKey("messages.id"), nullable=False, index=True)
    from_user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    to_user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    story = relationship("Story")
    message = relationship("Message")
    from_user = relationship("User", foreign_keys=[from_user_id])
    to_user = relationship("User", foreign_keys=[to_user_id])


# ==================== CONTENT CONSUMPTION ====================

class ContentConsumption(Base):
    """Track consumed content (seen/skipped) per user for single-use feed items.
    
    Once consumed, content will not appear again in feeds (Friend/Local).
    Works like Snapchat/BeReal - seen or skipped = never shown again.
    """
    __tablename__ = "content_consumptions"
    __table_args__ = (
        UniqueConstraint('user_id', 'content_id', name='unique_user_content_consumption'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    content_id = Column(String, nullable=False, index=True)  # Post.id or Story.id
    content_type = Column(String, nullable=False, index=True)  # 'post' | 'story'
    status = Column(String, nullable=False)  # 'seen' | 'skipped'
    consumed_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    client_event_id = Column(String, nullable=True, index=True)  # For idempotency
    
    # Relationships
    user = relationship("User")


# ==================== MESH VIEW RECEIPTS ====================

class MeshViewReceipt(Base):
    """Track views for mesh-distributed posts.
    
    When a post is viewed via mesh network (offline), this receipt is created
    and propagated via DTN until it reaches an internet-connected device that
    syncs it to the server. The author's view count is updated accordingly.
    
    Uses viewerHash instead of userId for privacy in offline mesh scenarios.
    """
    __tablename__ = "mesh_view_receipts"
    __table_args__ = (
        UniqueConstraint('post_id', 'viewer_hash', name='unique_post_viewer_receipt'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    receipt_id = Column(String, nullable=False, index=True)  # Original UUID from client
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    viewer_hash = Column(String(64), nullable=False, index=True)  # SHA256(userId) for privacy
    origin_device_id = Column(String, nullable=False)  # Device that created the receipt
    hop_count = Column(Integer, default=0)  # How many mesh hops this receipt has traveled
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    synced_at = Column(DateTime, default=datetime.utcnow, nullable=False)  # When synced to server
    
    # Relationships
    post = relationship("Post")


# ==================== GROUP CHAT FUN PACK ====================

class GroupPoll(Base):
    """Poll attached to a group chat."""
    __tablename__ = "group_polls"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    group_id = Column(String, ForeignKey("groups.id"), nullable=False, index=True)
    creator_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    question = Column(Text, nullable=False)
    allow_multiple = Column(Boolean, default=False)    # Allow voting for multiple options
    is_anonymous = Column(Boolean, default=False)      # Hide who voted for what
    expires_at = Column(DateTime, nullable=True)       # Optional expiry
    is_closed = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    group = relationship("Group")
    creator = relationship("User")
    options = relationship("GroupPollOption", back_populates="poll", cascade="all, delete-orphan", order_by="GroupPollOption.order_index")
    votes = relationship("GroupPollVote", back_populates="poll", cascade="all, delete-orphan")


class GroupPollOption(Base):
    """One option in a poll."""
    __tablename__ = "group_poll_options"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    poll_id = Column(String, ForeignKey("group_polls.id"), nullable=False, index=True)
    text = Column(String, nullable=False)
    order_index = Column(Integer, default=0)
    vote_count = Column(Integer, default=0)
    
    # Relationships
    poll = relationship("GroupPoll", back_populates="options")


class GroupPollVote(Base):
    """A user's vote on a poll option."""
    __tablename__ = "group_poll_votes"
    __table_args__ = (
        UniqueConstraint('poll_id', 'option_id', 'user_id', name='unique_poll_vote'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    poll_id = Column(String, ForeignKey("group_polls.id"), nullable=False, index=True)
    option_id = Column(String, ForeignKey("group_poll_options.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    voted_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    poll = relationship("GroupPoll", back_populates="votes")
    option = relationship("GroupPollOption")
    user = relationship("User")


class GroupMask(Base):
    """Anonymous mask for group chat fun mode."""
    __tablename__ = "group_masks"
    __table_args__ = (
        UniqueConstraint('group_id', 'user_id', name='unique_group_mask'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    group_id = Column(String, ForeignKey("groups.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    mask_name = Column(String, nullable=False)     # "Shadow Fox", "Ghost Panda", etc.
    mask_emoji = Column(String, nullable=False)     # 🦊, 🐼, 👻, etc.
    is_active = Column(Boolean, default=True)
    assigned_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    group = relationship("Group")
    user = relationship("User")


class VoiceChain(Base):
    """Round-robin voice chain in group chat."""
    __tablename__ = "voice_chains"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    group_id = Column(String, ForeignKey("groups.id"), nullable=False, index=True)
    creator_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    title = Column(String, nullable=False)
    max_duration_sec = Column(Integer, default=15)  # Max seconds per link
    status = Column(String, default="open")          # open, closed
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    group = relationship("Group")
    creator = relationship("User")
    links = relationship("VoiceChainLink", back_populates="chain", cascade="all, delete-orphan", order_by="VoiceChainLink.order_index")


class VoiceChainLink(Base):
    """One link (audio clip) in a voice chain."""
    __tablename__ = "voice_chain_links"
    __table_args__ = (
        UniqueConstraint('chain_id', 'user_id', name='unique_chain_link'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    chain_id = Column(String, ForeignKey("voice_chains.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    audio_url = Column(String, nullable=False)
    duration_sec = Column(Integer, nullable=False)
    order_index = Column(Integer, default=0)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    chain = relationship("VoiceChain", back_populates="links")
    user = relationship("User")

class UserActionLog(Base):
    """
    Audit / telemetry log of every meaningful user-driven action.

    🔴 ROUND 26 (2026-05-16) — added at user request:
    "har dokmee ke user mizane app darja behesh reaction dashte
    bashe ... va dar paszaminie toye server sabt beshe"
    (every button the user taps should have a visible reaction AND
    be logged on the server in the background).

    Stores actions like block, report, follow, unfollow, accept,
    decline, like, unlike, repost, unrepost, bookmark, unbookmark,
    mute, mention, etc. Used for:
      • Audit trail (was this user spamming reports? who blocked
        whom and when?).
      • Light analytics (button engagement, conversion funnels).
      • Anti-abuse signals (rate-limiting per-user per-action).

    Designed for high-volume INSERT-only traffic. No FK constraints
    on `target_id` because target type varies (post / user /
    comment / message / group / poll / room) — keeping it as a
    bare string + a typed discriminator keeps the table cheap to
    write and easy to query for any target type.
    """
    __tablename__ = "user_action_logs"

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    action = Column(String, nullable=False, index=True)           # e.g. "like", "block", "follow"
    target_id = Column(String, nullable=True, index=True)         # post id, user id, message id, …
    target_type = Column(String, nullable=True)                   # "post" | "user" | "comment" | "message" | "group" | …
    metadata_json = Column(Text, nullable=True)                   # optional free-form JSON blob
    client = Column(String, nullable=True)                        # "ios" | "android" | "mac" | "web"
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    user = relationship("User")


# ═══════════════════════════════════════════════════════════════════════════
# 🔴 ROUND 26 (2026-05-16) — endpoint-mismatch fixes
#
# The iOS client was calling four endpoints that simply didn't exist on
# the server, so the actions silently 404'd and the optimistic UI lied
# about state to the user:
#   • POST/DELETE /api/users/follow/{id}      (one-way social follow)
#   • POST/DELETE /api/posts/{id}/bookmark    (private save-for-later)
#   • POST /api/comments/{id}/pin|/unpin      (post-author pin)
#   • PATCH /api/comments/{id}                (edit)
#
# The two models below back the new follow/bookmark endpoints. The
# pin/edit endpoints reuse the `Comment` columns added above.
# ═══════════════════════════════════════════════════════════════════════════


class UserFollow(Base):
    """One-way social follow (X / Twitter style).

    Distinct from `FriendRequest` / `friendships`: a follow is unilateral,
    requires no acceptance, and does NOT grant the follower direct-message
    access. Used by the recommendation engine and the "Following" feed.
    """
    __tablename__ = "user_follows"
    __table_args__ = (
        UniqueConstraint('follower_id', 'followee_id', name='unique_user_follow'),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    follower_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    followee_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    # 🔴 BUG FIX (2026-05-21) — follow-of-a-private-account approval.
    # "accepted" = an active follow (public account, or a private
    # account that approved the request). "pending" = the followee is
    # a private account and has NOT yet approved — the row grants
    # NOTHING (not counted as a follower) until the followee accepts.
    # Defaults to "accepted" so every pre-existing row keeps working.
    status = Column(String, nullable=False, default="accepted")  # "pending" | "accepted"

    follower = relationship("User", foreign_keys=[follower_id])
    followee = relationship("User", foreign_keys=[followee_id])


class PostBookmark(Base):
    """Per-user private bookmark on a post. Like `PostLike` but for the
    save-for-later flow — the bookmark count is NOT shown publicly and
    bookmarks never trigger notifications to the post author."""
    __tablename__ = "post_bookmarks"
    __table_args__ = (
        UniqueConstraint('post_id', 'user_id', name='unique_post_bookmark'),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    post = relationship("Post")
    user = relationship("User")


class ConversationSetting(Base):
    """🔴 v1.8 (2026-05-21) — per-1:1-conversation settings.

    Currently holds ONE setting: the disappearing-messages timer.
    A 1:1 DM has no `conversations` row (messages are just sender/
    recipient pairs), so the timer is keyed by the *canonical ordered*
    user pair — `user_low_id` is always the lexicographically smaller
    id. That guarantees exactly one row per conversation regardless of
    who set the timer, and either participant resolves the same row.

    `disappearing_seconds` of 0 means OFF. When > 0, every NEW message
    between the pair is stamped `expires_at = sent_at + seconds` by the
    /send (and /bridge) handlers; the message-fetch endpoints filter
    and lazily purge anything past its expiry. Existing messages are
    NOT retroactively expired when the timer changes — matches
    Signal / WhatsApp behaviour."""
    __tablename__ = "conversation_settings"
    __table_args__ = (
        UniqueConstraint('user_low_id', 'user_high_id',
                         name='uq_conversation_settings_pair'),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_low_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    user_high_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    # Disappearing-messages timer, seconds. 0 = off.
    disappearing_seconds = Column(Integer, default=0, nullable=False)
    # Who last changed the timer + when (drives the system message).
    updated_by_id = Column(String, ForeignKey("users.id"), nullable=True)
    updated_at = Column(DateTime, default=datetime.utcnow, nullable=False)


class AttestChallenge(Base):
    """🔴 v1.8 (2026-05-21) — feature #3: App Attest device enrolment.

    A single-use, short-lived nonce the client must attest over when
    enrolling its Apple App Attest key. Issued by POST /api/attest/
    challenge, consumed by POST /api/attest/enroll."""
    __tablename__ = "attest_challenges"

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    challenge = Column(String, nullable=False, unique=True, index=True)  # base64
    expires_at = Column(DateTime, nullable=False)
    consumed = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)


class DeviceAttestation(Base):
    """🔴 v1.8 (2026-05-21) — feature #3: a verified Apple App Attest
    device key. Created by POST /api/attest/enroll once the attestation
    chains to the Apple App Attest Root CA. The stored public key lets
    future requests be proven genuine via App Attest assertions (a
    follow-up); `sign_count` is the assertion replay counter — 0 at
    enrolment."""
    __tablename__ = "device_attestations"

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    key_id = Column(String, nullable=False, unique=True, index=True)  # base64
    public_key = Column(Text, nullable=False)          # PEM (SubjectPublicKeyInfo)
    environment = Column(String, nullable=False)       # production | development
    sign_count = Column(Integer, default=0, nullable=False)
    receipt = Column(Text, nullable=True)              # base64 Apple receipt
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    last_verified_at = Column(DateTime, default=datetime.utcnow, nullable=False)

