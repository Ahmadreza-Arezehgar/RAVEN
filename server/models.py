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
    is_verified = Column(Boolean, default=False)  # Verified badge (blue tick)
    is_premium = Column(Boolean, default=False)   # RAVEN+ subscription (golden crown)
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
    show_liked_posts = Column(Boolean, default=True)  # Others can see liked posts on profile
    show_replies = Column(Boolean, default=True)  # Others can see replies on profile
    
    # Notification preferences (server-side enforcement)
    push_enabled = Column(Boolean, default=True)  # Master switch: all push notifications
    message_notifications_enabled = Column(Boolean, default=True)  # Push for new messages
    friend_request_notifications_enabled = Column(Boolean, default=True)  # Push for friend requests
    likes_comments_notifications_enabled = Column(Boolean, default=True)  # Push for likes/comments/replies
    sounds_enabled = Column(Boolean, default=True)  # Push with sound vs silent
    message_preview_enabled = Column(Boolean, default=True)  # Show message text in push or "New message"
    
    # Granular social notification preferences
    new_post_notifications_enabled = Column(Boolean, default=True)  # Push for bell-subscribed new posts
    audio_room_notifications_enabled = Column(Boolean, default=True)  # Push for bell-subscribed audio rooms
    mention_notifications_enabled = Column(Boolean, default=True)  # Push for @mentions

    # New notification toggles (added 2026-05-14 to match the iOS
    # NotificationsSettingsView "Privacy & Safety" + "Social" sections).
    # Server-side enforcement: a push of the matching type is silently
    # dropped when the corresponding column is False — clients still
    # respect their local toggle for when their cache is stale, but the
    # server is the source of truth.
    security_alert_notifications_enabled = Column(Boolean, default=True)   # New-device sign-in, password change…
    live_location_notifications_enabled = Column(Boolean, default=True)    # Friend started/stopped live location
    reaction_notifications_enabled = Column(Boolean, default=True)         # Emoji reaction on my message
    contact_shared_notifications_enabled = Column(Boolean, default=True)   # Someone shared my profile as a contact card
    profile_view_notifications_enabled = Column(Boolean, default=False)    # Non-friend opened my profile (off by default)
    screenshot_notifications_enabled = Column(Boolean, default=True)       # Screenshot of my profile / my chat

    # Cross-feature privacy toggle — read by the contact-card share
    # flow to decide whether to accept or refuse a share request that
    # targets THIS user. Default True for parity with prior behaviour;
    # users can turn it off in iOS Settings → Privacy.
    allow_contact_share = Column(Boolean, default=True)
    
    # Two-Factor Authentication
    two_factor_enabled = Column(Boolean, default=False)  # Whether 2FA is active
    totp_secret = Column(String, nullable=True)  # TOTP secret for authenticator apps
    
    # Privacy settings (server-side enforcement)
    show_online_status = Column(Boolean, default=True)  # Others can see online/last seen
    read_receipts_enabled = Column(Boolean, default=True)  # Send read receipts to sender
    who_can_message = Column(String, default="everyone")  # "everyone" | "friends"
    who_can_see_profile = Column(String, default="public")  # "public" | "friends"

    # Presence — written by /presence/heartbeat every 30s and on every
    # authenticated request. Read by /presence/{user_id} to determine
    # online/offline. Stored in DB (not in-memory cache) so it survives
    # Cloud Run cold starts and works across multiple instances.
    last_active_at = Column(DateTime, nullable=True, index=True)
    last_active_has_internet = Column(Boolean, default=False)
    
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
    push_environment = Column(String, nullable=True)  # 'sandbox' or 'production' (APNs endpoint)
    
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
    # Set when the sender edits the message body. NULL means "never edited".
    edited_at = Column(DateTime, nullable=True)

    # Pin state — either party can pin/unpin in a 1:1. NULL means "not pinned".
    pinned_at = Column(DateTime, nullable=True, index=True)
    pinned_by_user_id = Column(String, nullable=True)

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
    
    # Raven Shot: opt-in for social map display
    show_on_raven_shot = Column(Boolean, default=False, index=True)  # True = display on map

    # Inline video-jump commands (`vM:SS`) parsed from the post body at
    # create-time. Stored as a JSON list of {seconds: int, label: str, token:
    # str} entries so the iOS feed can render scrub-bar chapter markers
    # without re-running the regex per render. Plaintext is fine: the tokens
    # are public navigation aids, not the post body.
    video_chapters = Column(Text, nullable=True)
    
    # Human-readable location name (e.g. "Starbucks, Madrid")
    location_name = Column(String, nullable=True)
    
    # Relationships
    author = relationship("User", back_populates="posts")
    room = relationship("AudioRoom", foreign_keys=[room_id])
    comments = relationship("Comment", back_populates="post", cascade="all, delete-orphan")
    media = relationship("PostMedia", back_populates="post", cascade="all, delete-orphan", order_by="PostMedia.order_index")

class PostMedia(Base):
    """Media items for multi-media posts (images + videos, max 4 free / 10 premium)."""
    __tablename__ = "post_media"
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    url = Column(String, nullable=False)
    order_index = Column(Integer, default=0)  # 0-based ordering
    media_type = Column(String, default='image')  # 'image' | 'video'
    thumbnail_url = Column(String, nullable=True)  # Video thumbnail CDN URL (null for images)
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    post = relationship("Post", back_populates="media")


class PostTag(Base):
    """User tags on posts/photos (like Instagram's Tag People)."""
    __tablename__ = "post_tags"
    __table_args__ = (
        UniqueConstraint('post_id', 'tagged_user_id', name='unique_post_tag'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    media_id = Column(String, nullable=True)  # Which photo/video (null = post-level tag)
    tagged_user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    tagged_by_user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    x_position = Column(Float, nullable=True)  # 0.0-1.0 relative position on image
    y_position = Column(Float, nullable=True)  # 0.0-1.0 relative position on image
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    post = relationship("Post")
    tagged_user = relationship("User", foreign_keys=[tagged_user_id])
    tagged_by = relationship("User", foreign_keys=[tagged_by_user_id])

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
    comment_type = Column(String, default="text")  # "text" | "voice" | "image"
    media_url = Column(String, nullable=True)       # CDN URL for voice/image
    duration_sec = Column(Float, nullable=True)      # Voice duration in seconds
    
    # Voice comment transcription (on-demand via Gemini)
    transcript_text = Column(Text, nullable=True)
    transcript_status = Column(String, default='none')      # none|pending|processing|ready|failed
    transcript_language = Column(String, nullable=True)

    # ── Edit support ──────────────────────────────────────────────────
    # Set on every successful PATCH /api/comments/{id}. Clients render an
    # "edited" hint next to the timestamp when this is non-null. We keep
    # the original `timestamp` immutable so sort order doesn't jump when
    # someone fixes a typo on an old comment.
    edited_at = Column(DateTime, nullable=True)

    # ── Pin support ───────────────────────────────────────────────────
    # When True, this comment floats above all others on the post.
    # Only the POST AUTHOR can pin/unpin (not the comment author).
    # Sort order: pinned first (by `pinned_at` desc), then by score+timestamp.
    is_pinned = Column(Boolean, default=False, index=True)
    pinned_at = Column(DateTime, nullable=True)

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


class PostBookmark(Base):
    """Junction table: which posts each user has bookmarked. Mirrors
    PostLike. Idempotent — `(post_id, user_id)` is unique so the
    toggle endpoint can flip without polluting the table."""
    __tablename__ = "post_bookmarks"
    __table_args__ = (
        UniqueConstraint('post_id', 'user_id', name='unique_post_bookmark'),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    post_id = Column(String, ForeignKey("posts.id"), nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    timestamp = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)


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


class UserNotificationSubscription(Base):
    """Per-user bell notification subscription (Bell icon on profile).
    
    Allows users to subscribe to specific notification categories
    for another user (e.g., notify when they post, start audio rooms).
    """
    __tablename__ = "user_notification_subscriptions"
    __table_args__ = (
        UniqueConstraint('subscriber_id', 'target_id', name='unique_user_notification_sub'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    subscriber_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    target_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    notify_posts = Column(Boolean, default=True)        # Notify when target posts
    notify_audio_rooms = Column(Boolean, default=True)   # Notify when target starts audio room
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Relationships
    subscriber = relationship("User", foreign_keys=[subscriber_id])
    target = relationship("User", foreign_keys=[target_id])


# ==================== ROOM VISIBILITY ====================

class RoomVisibility(Base):
    """Track room visibility and read status per user."""
    __tablename__ = "room_visibility"
    __table_args__ = (
        UniqueConstraint('user_id', 'room_id', name='unique_room_user'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    room_id = Column(String, nullable=False, index=True)  # Format: {userId1}_{userId2}
    hidden = Column(Boolean, default=False)  # Hide conversation for this user
    last_read_at = Column(DateTime, nullable=True)  # Last time user read messages in this room
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
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
    # Set when the sender edits the message body. NULL means "never edited".
    edited_at = Column(DateTime, nullable=True)

    # Pin state — any group member can pin/unpin. NULL means "not pinned".
    pinned_at = Column(DateTime, nullable=True, index=True)
    pinned_by_user_id = Column(String, nullable=True)

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


# ==================== FOLLOW SYSTEM (Instagram-style) ====================

class Follow(Base):
    """Directional follow relationship (A follows B).
    
    - Public accounts: Follow is instant.
    - Private accounts: Follow requires a FriendRequest (status=pending → accepted).
    - Mutual follows = Friends.
    """
    __tablename__ = "follows"
    __table_args__ = (
        UniqueConstraint('follower_id', 'following_id', name='unique_follow'),
    )
    
    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    follower_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    following_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    follower = relationship("User", foreign_keys=[follower_id])
    following = relationship("User", foreign_keys=[following_id])


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
    # Locked rooms refuse new joiners (host-only setting). Was settable via
    # /settings but never persisted because the column was missing — joining
    # a "locked" room silently still worked. Now actually a Real Thing.
    is_locked = Column(Boolean, default=False)
    
    # Shareable link
    share_slug = Column(String(12), unique=True, nullable=True, index=True)  # For deep links: raven://room/{slug}
    
    # Room state
    is_live = Column(Boolean, default=True, index=True)
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


# ─────────────────────────────────────────────────────────────────────────────
# MESSAGE REACTIONS
# Per-user emoji reactions on a 1:1 or group message. UniqueConstraint on
# (message_id, user_id, emoji) means a user can react with multiple distinct
# emojis to the same message but can't double-react with the same emoji.
# `is_group` switches which message table the FK points at — we keep the join
# loose (string ID, no FK) so this single table serves both rooms.
# ─────────────────────────────────────────────────────────────────────────────
class MessageReaction(Base):
    __tablename__ = "message_reactions"
    __table_args__ = (
        UniqueConstraint("message_id", "user_id", "emoji", name="uq_reaction_msg_user_emoji"),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    message_id = Column(String, nullable=False, index=True)
    is_group = Column(Boolean, default=False, nullable=False, index=True)
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    emoji = Column(String, nullable=False)  # short string ("👍", ":custom_id:")
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User")


class SavedMessage(Base):
    """Per-user message bookmark. The same message can be pinned (visible to
    every participant) AND saved (private to a single user) — pin and save
    are independent."""
    __tablename__ = "saved_messages"
    __table_args__ = (
        UniqueConstraint("user_id", "message_id", "is_group", name="uq_saved_user_msg"),
    )

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, ForeignKey("users.id"), nullable=False, index=True)
    message_id = Column(String, nullable=False, index=True)
    is_group = Column(Boolean, default=False, nullable=False)
    saved_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    user = relationship("User")
