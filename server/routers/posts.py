
from fastapi import APIRouter, Depends, HTTPException, status, Request, Response
from sqlalchemy.orm import Session
from sqlalchemy import func, or_, and_
from pydantic import BaseModel, Field, ConfigDict
from typing import List, Optional
from datetime import datetime

from database import get_db
from models import User, Post, PostLike, PostBookmark, Repost, Comment, PostView, ContentConsumption, MeshViewReceipt
from routers.users import get_current_user
from encryption import encrypt_text, decrypt_text
from middleware.rate_limit import rate_limiter
from cache import cache, TTL_FEED
import hashlib
import os
import json

# Server salt for hashing viewer identity (privacy-first)
# In production, use environment variable
SERVER_SALT = os.environ.get('VIEW_SALT', 'raven_view_salt_2026_secure')

# Inline video-jump command parser. Mirrors the iOS regex in
# `Views/Components/HashtagText.swift::VideoTimestampParser` so a token like
# `v0:21` resolves to the same seconds offset on both sides. We extract on
# create-post so feed payloads carry the chapter list and clients don't have
# to re-scan the body per render.
import re as _re_chapters
_VIDEO_CHAPTER_RE = _re_chapters.compile(
    r'(?<![A-Za-z0-9])v(?:(\d{1,2}):)?(\d{1,2}):(\d{1,2})\b'
)


def extract_video_chapters(text: str) -> list:
    """Return a list of {seconds, label, token} dicts in source order.
    Defensive against malformed minutes/seconds (>=60). Caller serialises
    with json.dumps; we don't store the body's actual character ranges
    because the iOS side recomputes them on render anyway."""
    if not text:
        return []
    out = []
    seen = set()
    for m in _VIDEO_CHAPTER_RE.finditer(text):
        hours = int(m.group(1) or 0)
        mins = int(m.group(2))
        secs = int(m.group(3))
        if mins >= 60 or secs >= 60:
            continue
        total = hours * 3600 + mins * 60 + secs
        if total in seen:
            continue
        seen.add(total)
        out.append({
            "seconds": total,
            "token": m.group(0),
            "label": m.group(0)[1:],
        })
    return out


router = APIRouter(prefix="/api/posts", tags=["posts"])

def build_full_url(request: Request, path: str) -> str:
    """Convert relative path to full URL."""
    if not path:
        return None
    if path.startswith("http://") or path.startswith("https://"):
        return path  # Already full URL
    base_url = str(request.base_url).rstrip('/')
    return f"{base_url}{path}"

# Request/Response models
class MediaItemInput(BaseModel):
    """A single media item (image or video) with type info and optional thumbnail."""
    url: str
    media_type: str = "image"  # "image" or "video"
    thumbnail_url: Optional[str] = None  # Required for videos (preview image)


class MentionEntityInput(BaseModel):
    """Structured @mention entity from the iOS picker.

    Optional `entities` on `CreatePostRequest` lets the picker bypass the
    fragile regex extraction (which breaks on usernames containing `.` /
    `-`). When entities are provided, server processes them PREFERENTIALLY
    and skips the regex path.

    Accepts BOTH camelCase and snake_case keys — iOS NetworkService runs
    `.convertToSnakeCase` on its encoder so the JSON arrives as
    `{"user_id":"...","range_start":0,"range_length":10,...}`. Same fix as
    `routers/comments.py:MentionEntityPayload`.
    """
    model_config = ConfigDict(populate_by_name=True)

    type: str = "mention"
    userId: str = Field(alias="user_id")
    username: str
    rangeStart: int = Field(alias="range_start")
    rangeLength: int = Field(alias="range_length")


class CreatePostRequest(BaseModel):
    content: str
    image_url: Optional[str] = None  # Legacy single image (backward compat)
    image_urls: Optional[List[str]] = None  # Legacy multi-image (backward compat)
    media_items: Optional[List[MediaItemInput]] = None  # NEW: Mixed media with type info (images + videos)
    is_local: bool = True
    visibility: str = "public"  # public, friends, local
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    radius_m: int = 2000  # Visibility radius for local posts (meters)
    post_id: Optional[str] = None  # Client-provided ID for mesh post idempotency
    mesh_origin: bool = False  # True if post originated from offline mesh network
    author_id: Optional[str] = None  # Original author ID (for gateway mesh uploads)
    author_username: Optional[str] = None  # Original author username (for gateway mesh uploads)
    hashtags: Optional[List[str]] = None  # Extracted hashtags for mesh posts
    mesh_signature: Optional[str] = None  # Base64 Ed25519 signature from origin device
    mesh_signer_key: Optional[str] = None  # Base64 public key of signing device
    # Voice post fields
    voice_url: Optional[str] = None  # CDN URL for uploaded voice audio
    voice_duration: Optional[int] = None  # Duration in seconds
    waveform: Optional[List[float]] = None  # Waveform data for visualization
    # Raven Shot: opt-in for social map display
    show_on_raven_shot: Optional[bool] = False  # True = display post on Raven Shot map
    # Human-readable location name (e.g. "Starbucks, Madrid")
    location_name: Optional[str] = None
    # Optional structured @mentions from the iOS composer's MentionPicker.
    # When supplied, the server uses these directly (correct for any
    # username, including those with dots/hyphens) and skips the
    # backwards-compat regex extraction.
    entities: Optional[List[MentionEntityInput]] = None
    # User tagging (tag people in post/photos)
    tagged_users: Optional[List[str]] = None  # List of user IDs to tag
    # Tracing
    client_request_id: Optional[str] = None  # End-to-end tracing UUID from client

class TopCommentResponse(BaseModel):
    """Top comment preview for per-media display."""
    id: str
    author_name: str
    author_avatar: Optional[str]
    content: str
    likes: int

class PostMediaResponse(BaseModel):
    """Media item for multi-media posts (images + videos)."""
    id: str
    url: str
    order_index: int
    media_type: Optional[str] = "image"  # "image" or "video"
    thumbnail_url: Optional[str] = None  # Video thumbnail CDN URL (null for images)
    top_comments: Optional[List[TopCommentResponse]] = None

class PostResponse(BaseModel):
    id: str
    author_id: str
    author_username: str
    author_avatar: Optional[str]
    content: str
    image_url: Optional[str]  # Legacy single image (backward compat)
    media: Optional[List[PostMediaResponse]] = None  # Multi-image support
    timestamp: datetime
    edited_at: Optional[datetime]  # When post was last edited (null if never)
    likes: int
    comments: int
    reposts: int
    view_count: int  # Unique view count (no viewer list for privacy)
    is_local: bool
    is_liked: bool  # Whether current user liked this post
    is_reposted: bool  # Whether current user reposted this
    is_bookmarked: bool = False  # Whether current user bookmarked this post
    visibility: str = "public"  # public, friends, local
    distance_m: Optional[int] = None  # Rounded distance for privacy (local feed only)
    post_type: Optional[str] = None   # "text", "image", "room", "voice", "voice_chain"
    room_id: Optional[str] = None     # FK to AudioRoom if post_type == "room"
    mesh_origin: bool = False         # True if post was initially created/shared via mesh (offline-first)
    # Voice post fields
    voice_url: Optional[str] = None
    voice_duration: Optional[int] = None
    waveform: Optional[List[float]] = None
    # Collaborative post fields
    co_authors: Optional[List[str]] = None  # List of co-author user IDs
    co_author_usernames: Optional[List[str]] = None  # Cached display names
    origin_chain_id: Optional[str] = None
    is_verified: bool = False  # Author's identity verification status
    is_premium: bool = False   # Author's RAVEN+ subscription status
    # Contact avatar preview fields (up to 20 user IDs for client-side intersection)
    like_preview_user_ids: Optional[List[str]] = None
    comment_preview_user_ids: Optional[List[str]] = None
    # Raven Shot fields
    show_on_raven_shot: bool = False  # Opt-in for social map display
    latitude: Optional[float] = None  # For map rendering (geo-fuzzed)
    longitude: Optional[float] = None  # For map rendering (geo-fuzzed)
    # Location name
    location_name: Optional[str] = None  # Human-readable location (e.g. "Starbucks, Madrid")
    # Tagged users
    tagged_users: Optional[List[dict]] = None  # [{id, username, avatar_path}]
    # Inline video-jump commands parsed from the body at create-time.
    # Each entry is `{seconds: int, label: str, token: str}` — the iOS
    # feed renders one chapter marker per entry on the scrub bar.
    video_chapters: Optional[List[dict]] = None

    class Config:
        from_attributes = True

class PaginatedFeedResponse(BaseModel):
    """Paginated feed response wrapper with hasMore flag for infinite scroll."""
    items: List[PostResponse]
    hasMore: bool
    nextOffset: int

class EditPostRequest(BaseModel):
    content: str

class RepostRequest(BaseModel):
    content: Optional[str] = None  # Optional quote/comment


def get_post_stats(db: Session, post_id: str, current_user_id: str) -> dict:
    """Get post statistics and user interaction status."""
    # Count likes
    likes = db.query(PostLike).filter(PostLike.post_id == post_id).count()
    
    # Count comments
    comments = db.query(Comment).filter(Comment.post_id == post_id).count()
    
    # Count reposts
    reposts = db.query(Repost).filter(Repost.original_post_id == post_id).count()
    
    # Check if current user liked
    is_liked = db.query(PostLike).filter(
        PostLike.post_id == post_id,
        PostLike.user_id == current_user_id
    ).first() is not None
    
    # Check if current user reposted
    is_reposted = db.query(Repost).filter(
        Repost.original_post_id == post_id,
        Repost.user_id == current_user_id
    ).first() is not None

    # Check if current user bookmarked
    is_bookmarked = db.query(PostBookmark).filter(
        PostBookmark.post_id == post_id,
        PostBookmark.user_id == current_user_id
    ).first() is not None

    return {
        "likes": likes,
        "comments": comments,
        "reposts": reposts,
        "is_liked": is_liked,
        "is_reposted": is_reposted,
        "is_bookmarked": is_bookmarked
    }


def get_batch_post_stats(db: Session, post_ids: list, current_user_id: str) -> dict:
    """Batch-fetch stats for multiple posts in 5 queries instead of 5 per post.
    
    Returns dict mapping post_id -> stats dict.
    For 50 posts: 5 queries instead of 250.
    """
    if not post_ids:
        return {}
    
    # 1. Batch count likes per post
    likes_rows = db.query(
        PostLike.post_id, func.count(PostLike.id)
    ).filter(PostLike.post_id.in_(post_ids)).group_by(PostLike.post_id).all()
    likes_map = dict(likes_rows)
    
    # 2. Batch count comments per post
    comments_rows = db.query(
        Comment.post_id, func.count(Comment.id)
    ).filter(Comment.post_id.in_(post_ids)).group_by(Comment.post_id).all()
    comments_map = dict(comments_rows)
    
    # 3. Batch count reposts per post
    reposts_rows = db.query(
        Repost.original_post_id, func.count(Repost.id)
    ).filter(Repost.original_post_id.in_(post_ids)).group_by(Repost.original_post_id).all()
    reposts_map = dict(reposts_rows)
    
    # 4. Which posts has current user liked?
    liked_ids = set(row[0] for row in db.query(PostLike.post_id).filter(
        PostLike.post_id.in_(post_ids),
        PostLike.user_id == current_user_id
    ).all())
    
    # 5. Which posts has current user reposted?
    reposted_ids = set(row[0] for row in db.query(Repost.original_post_id).filter(
        Repost.original_post_id.in_(post_ids),
        Repost.user_id == current_user_id
    ).all())

    # 5b. Which posts has current user bookmarked?
    bookmarked_ids = set(row[0] for row in db.query(PostBookmark.post_id).filter(
        PostBookmark.post_id.in_(post_ids),
        PostBookmark.user_id == current_user_id
    ).all())
    
    # 6. Preview liker IDs (max 20 per post, most recent first)
    # ⚡ PERF FIX: Single batch query with ROW_NUMBER window function
    # instead of N per-post queries. For 50 posts: 1 query instead of 50.
    liker_map = {}
    try:
        from sqlalchemy import text
        liker_sql = text("""
            SELECT post_id, user_id FROM (
                SELECT post_id, user_id, 
                       ROW_NUMBER() OVER (PARTITION BY post_id ORDER BY timestamp DESC) as rn
                FROM post_likes
                WHERE post_id = ANY(:pids)
            ) ranked WHERE rn <= 20
        """)
        liker_rows = db.execute(liker_sql, {"pids": post_ids}).fetchall()
        for row in liker_rows:
            liker_map.setdefault(row[0], []).append(row[1])
    except Exception:
        # Fallback for SQLite (no window functions in older versions)
        pass
    
    # 7. Preview commenter IDs (max 20 unique per post, most recent first)
    # ⚡ PERF FIX: Single batch query with DISTINCT ON (PostgreSQL)
    commenter_map = {}
    try:
        commenter_sql = text("""
            SELECT post_id, author_id FROM (
                SELECT post_id, author_id,
                       ROW_NUMBER() OVER (PARTITION BY post_id, author_id ORDER BY timestamp DESC) as dup_rn,
                       ROW_NUMBER() OVER (PARTITION BY post_id ORDER BY timestamp DESC) as rn
                FROM comments
                WHERE post_id = ANY(:pids)
            ) ranked WHERE dup_rn = 1 AND rn <= 20
        """)
        commenter_rows = db.execute(commenter_sql, {"pids": post_ids}).fetchall()
        for row in commenter_rows:
            commenter_map.setdefault(row[0], []).append(row[1])
    except Exception:
        # Fallback for SQLite
        pass
    
    # Build result map
    result = {}
    for pid in post_ids:
        result[pid] = {
            "likes": likes_map.get(pid, 0),
            "comments": comments_map.get(pid, 0),
            "reposts": reposts_map.get(pid, 0),
            "is_liked": pid in liked_ids,
            "is_reposted": pid in reposted_ids,
            "is_bookmarked": pid in bookmarked_ids,
            "like_preview_user_ids": liker_map.get(pid, []),
            "comment_preview_user_ids": commenter_map.get(pid, []),
        }
    return result


def get_voice_and_collab_fields(post, db=None, author=None) -> dict:
    """Extract voice post and collaborative post fields from a Post model."""
    fields = {
        "voice_url": getattr(post, 'voice_url', None),
        "voice_duration": getattr(post, 'voice_duration', None),
        "waveform": None,
        "co_authors": None,
        "co_author_usernames": None,
        "origin_chain_id": getattr(post, 'origin_chain_id', None),
        "is_verified": (author.is_verified or False) if author else False,
        "is_premium": (author.is_premium or False) if author else False,
        "video_chapters": None,
    }
    # Parse waveform JSON
    raw_waveform = getattr(post, 'waveform', None)
    if raw_waveform:
        try:
            fields["waveform"] = json.loads(raw_waveform)
        except Exception:
            pass
    # Parse co_authors JSON
    raw_co_authors = getattr(post, 'co_authors', None)
    if raw_co_authors:
        try:
            co_author_ids = json.loads(raw_co_authors)
            fields["co_authors"] = co_author_ids
            if db and co_author_ids:
                users = db.query(User).filter(User.id.in_(co_author_ids)).all()
                user_map = {u.id: u.username for u in users}
                fields["co_author_usernames"] = [user_map.get(uid, "Unknown") for uid in co_author_ids]
        except Exception:
            pass
    # Pre-parsed video chapters (populated at create-time so the feed avoids
    # re-running the regex per render). Quietly drop malformed entries.
    raw_chapters = getattr(post, 'video_chapters', None)
    if raw_chapters:
        try:
            decoded = json.loads(raw_chapters)
            if isinstance(decoded, list):
                fields["video_chapters"] = [c for c in decoded if isinstance(c, dict)]
        except Exception:
            pass
    return fields


def get_batch_post_media(request: Request, db: Session, post_ids: List[str]) -> dict:
    """Batch-load PostMedia for multiple posts in a single query.
    
    Returns: dict mapping post_id -> List[PostMediaResponse] (only for posts that have media).
    """
    if not post_ids:
        return {}
    
    from models import PostMedia
    
    media_rows = db.query(PostMedia).filter(
        PostMedia.post_id.in_(post_ids)
    ).order_by(PostMedia.post_id, PostMedia.order_index).all()
    
    if not media_rows:
        return {}
    
    media_map = {}
    for m in media_rows:
        if m.post_id not in media_map:
            media_map[m.post_id] = []
        media_map[m.post_id].append(PostMediaResponse(
            id=m.id,
            url=build_full_url(request, m.url),
            order_index=m.order_index,
            media_type=m.media_type or 'image',
            thumbnail_url=build_full_url(request, m.thumbnail_url) if getattr(m, 'thumbnail_url', None) else None,
            top_comments=None
        ))
    
    return media_map


def get_post_media_with_comments(
    request: Request,
    db: Session,
    post_id: str,
    current_user_id: str
) -> Optional[List[PostMediaResponse]]:
    """
    Get post media with top 3 comments per media.
    
    Ranking algorithm:
        score = likes×3 + replies×2 + (friend_boost?10:0)
    """
    from models import PostMedia, CommentVote, FriendRequest
    
    # Get all media for this post
    media_items = db.query(PostMedia).filter(
        PostMedia.post_id == post_id
    ).order_by(PostMedia.order_index).all()
    
    if not media_items:
        return None
    
    # Get current user's friends for friend boost
    sent_friends = db.query(FriendRequest.recipient_id).filter(
        FriendRequest.requester_id == current_user_id,
        FriendRequest.status == "accepted"
    ).all()
    received_friends = db.query(FriendRequest.requester_id).filter(
        FriendRequest.recipient_id == current_user_id,
        FriendRequest.status == "accepted"
    ).all()
    friend_ids = set([f[0] for f in sent_friends] + [f[0] for f in received_friends])
    
    result = []
    for media in media_items:
        # Get comments for this specific media
        comments = db.query(Comment).filter(
            Comment.post_id == post_id,
            Comment.media_id == media.id
        ).all()
        
        # Score and rank comments
        scored_comments = []
        for comment in comments:
            # Get like count for this comment
            likes_count = db.query(CommentVote).filter(
                CommentVote.comment_id == comment.id,
                CommentVote.vote == 1
            ).count()
            
            # Get reply count
            replies_count = db.query(Comment).filter(
                Comment.parent_comment_id == comment.id
            ).count()
            
            # Check if commenter is a friend
            is_friend = comment.author_id in friend_ids
            
            # Calculate score: likes×3 + replies×2 + friend_boost
            score = (likes_count * 3) + (replies_count * 2) + (10 if is_friend else 0)
            
            # Get author info
            author = db.query(User).filter(User.id == comment.author_id).first()
            
            scored_comments.append({
                'comment': TopCommentResponse(
                    id=comment.id,
                    author_name=author.username if author else "Unknown",
                    author_avatar=build_full_url(request, author.avatar_path) if author else None,
                    content=decrypt_text(comment.content),
                    likes=likes_count
                ),
                'score': score
            })
        
        # Sort by score descending, take top 3
        scored_comments.sort(key=lambda x: x['score'], reverse=True)
        top_comments = [c['comment'] for c in scored_comments[:3]] if scored_comments else None
        
        result.append(PostMediaResponse(
            id=media.id,
            url=build_full_url(request, media.url),
            order_index=media.order_index,
            media_type=media.media_type,
            thumbnail_url=build_full_url(request, media.thumbnail_url) if getattr(media, 'thumbnail_url', None) else None,
            top_comments=top_comments
        ))
    
    return result


# ==================== SEARCH POSTS ====================
@router.get("/search", response_model=List[PostResponse])
def search_posts(
    request: Request,
    q: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 20,
    offset: int = 0
):
    """
    Search posts by content.
    Returns 200 with empty array if no results (NOT 404).
    """
    # Minimum 2 chars for search
    if not q or len(q) < 2:
        return []
    
    # Fetch recent public/local posts and filter by content match
    from routers.blocks import get_blocked_user_ids
    from models import HiddenContent
    blocked_ids = get_blocked_user_ids(db, current_user.id)
    hidden_post_ids = [h.object_id for h in db.query(HiddenContent.object_id).filter(
        HiddenContent.user_id == current_user.id, HiddenContent.object_type == "post"
    ).all()]
    
    search_query = db.query(Post).filter(Post.visibility.in_(['public', 'local', None]), or_(Post.is_hidden == False, Post.is_hidden == None))
    if blocked_ids:
        search_query = search_query.filter(~Post.author_id.in_(blocked_ids))
    if hidden_post_ids:
        search_query = search_query.filter(~Post.id.in_(hidden_post_ids))
    posts = search_query.order_by(Post.timestamp.desc()).offset(offset).limit(limit * 3).all()
    
    # Filter by content match (decrypt and check)
    result = []
    search_lower = q.lower()
    
    for post in posts:
        content = decrypt_text(post.content) or ""
        if search_lower in content.lower():
            author = db.query(User).filter(User.id == post.author_id).first()
            stats = get_post_stats(db, post.id, current_user.id)
            
            result.append(PostResponse(
                id=post.id,
                author_id=post.author_id,
                author_username=author.username if author else "Unknown",
                author_avatar=build_full_url(request, author.avatar_path) if author else None,
                content=content,
                image_url=build_full_url(request, post.image_url),
                timestamp=post.timestamp,
                edited_at=post.edited_at,
                likes=stats["likes"],
                comments=stats["comments"],
                reposts=stats["reposts"],
                view_count=post.view_count or 0,
                is_local=post.is_local,
                is_liked=stats["is_liked"],
                is_reposted=stats["is_reposted"],
                visibility=post.visibility or "public",
                post_type=post.post_type,
                room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            location_name=getattr(post, 'location_name', None),
                **get_voice_and_collab_fields(post, db, author=author)
            ))
            
            if len(result) >= limit:
                break
    
    print(f"🔍 [Search] '{q}' → {len(result)} posts found")
    return result  # Always 200, even if empty []


# ==================== CONTENT CONSUMPTION ====================

class ConsumeContentRequest(BaseModel):
    content_id: str
    content_type: str  # 'post' | 'story'
    status: str  # 'seen' | 'skipped'
    client_event_id: Optional[str] = None

@router.post("/content/consume")
def consume_content(
    req: ConsumeContentRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Mark content as consumed (seen/skipped). Idempotent.
    
    Once consumed, this content will NOT appear in feeds again.
    Works like Snapchat/BeReal - single-use content.
    """
    # Validate content_type
    if req.content_type not in ['post', 'story']:
        raise HTTPException(status_code=400, detail="content_type must be 'post' or 'story'")
    
    # Validate status
    if req.status not in ['seen', 'skipped']:
        raise HTTPException(status_code=400, detail="status must be 'seen' or 'skipped'")
    
    # Idempotent: check if already consumed
    existing = db.query(ContentConsumption).filter(
        ContentConsumption.user_id == current_user.id,
        ContentConsumption.content_id == req.content_id
    ).first()
    
    if existing:
        return {"status": "already_consumed", "consumed_at": existing.consumed_at.isoformat()}
    
    # Create consumption record
    consumption = ContentConsumption(
        user_id=current_user.id,
        content_id=req.content_id,
        content_type=req.content_type,
        status=req.status,
        client_event_id=req.client_event_id
    )
    
    db.add(consumption)
    db.commit()
    
    print(f"📍 [Consume] {current_user.username} {req.status} {req.content_type}:{req.content_id[:8]}")
    return {"status": "consumed"}


@router.post("/create", response_model=PostResponse)
async def create_post(
    request: Request,
    req: CreatePostRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Create a new post with optional location for local feed.
    
    Supports idempotency via post_id for mesh post sync:
    - If post_id is provided and post exists, return existing post
    - If post_id is provided and post doesn't exist, create with that ID
    """
    # Tracing: log client_request_id if provided
    crid = req.client_request_id or "none"
    print(f"📝 [PostCreate] START client_request_id={crid[:8]} user={current_user.id[:8]}")
    
    # Rate limit: max 10 posts per 5 minutes per user
    rate_limiter.check_rate_limit(
        identifier=f"post:{current_user.id}",
        max_attempts=10,
        window_minutes=5,
        lockout_minutes=15
    )
    
    import random
    from geohash import encode as encode_geohash
    
    # IDEMPOTENCY: Check if post with this ID already exists
    if req.post_id:
        existing = db.query(Post).filter(Post.id == req.post_id).first()
        if existing:
            # Return existing post (idempotent - mesh post already synced)
            print(f"📝 [IDEMPOTENT] Post {req.post_id[:8]} already exists, returning existing")
            stats = get_post_stats(db, existing.id, current_user.id)
            # Resolve the actual author (may differ from gateway user for mesh posts)
            post_author = db.query(User).filter(User.id == existing.author_id).first()
            return PostResponse(
                id=existing.id,
                author_id=existing.author_id,
                author_username=post_author.username if post_author else "Unknown",
                author_avatar=build_full_url(request, post_author.avatar_path) if post_author else None,
                content=decrypt_text(existing.content),
                image_url=build_full_url(request, existing.image_url),
                timestamp=existing.timestamp,
                edited_at=existing.edited_at,
                likes=stats['likes'],
                comments=stats['comments'],
                reposts=stats['reposts'],
                view_count=existing.view_count or 0,
                is_local=existing.is_local,
                is_liked=stats['is_liked'],
                is_reposted=stats['is_reposted'],
                visibility=existing.visibility or "public",
                post_type=existing.post_type,
                room_id=existing.room_id,
                mesh_origin=existing.mesh_origin or False,
                **get_voice_and_collab_fields(existing, db, author=post_author)
            )
    
    # Validate coordinates if provided
    lat, lng, geohash_val = None, None, None
    if req.latitude is not None and req.longitude is not None:
        # Sanity check coordinates
        if not (-90 <= req.latitude <= 90):
            raise HTTPException(status_code=400, detail="Invalid latitude (must be -90 to 90)")
        if not (-180 <= req.longitude <= 180):
            raise HTTPException(status_code=400, detail="Invalid longitude (must be -180 to 180)")
        
        # Apply geo-fuzzing for privacy (±50m random offset)
        # 1 degree ≈ 111km, so 50m ≈ 0.00045 degrees
        fuzz_range = 0.00045
        lat = req.latitude + random.uniform(-fuzz_range, fuzz_range)
        lng = req.longitude + random.uniform(-fuzz_range, fuzz_range)
        
        # Compute geohash for efficient radius queries
        geohash_val = encode_geohash(lat, lng, precision=7)
    
    # Use client-provided post_id if available (for mesh post sync)
    # For mesh-originated posts, use the original author ID from the mesh envelope
    actual_author_id = current_user.id
    if req.mesh_origin and req.author_id:
        # Gateway bridge: preserve original author
        actual_author_id = req.author_id
        print(f"🌐 [GATEWAY] Mesh post from original author {req.author_id[:8]}... uploaded by gateway {current_user.id[:8]}...")
    
    post_data = {
        'author_id': actual_author_id,
        'content': encrypt_text(req.content),
        'image_url': req.image_url,
        'timestamp': datetime.utcnow(),
        'is_local': req.is_local,
        'likes': 0,
        'visibility': req.visibility,
        'radius_m': req.radius_m,
        'latitude': lat,
        'longitude': lng,
        'geohash': geohash_val,
        'show_on_raven_shot': bool(req.show_on_raven_shot) if req.show_on_raven_shot else False,
        'location_name': req.location_name[:200] if req.location_name else None  # Max 200 chars
    }
    
    # Voice post handling
    if req.voice_url:
        post_data['voice_url'] = req.voice_url
        post_data['voice_duration'] = req.voice_duration
        post_data['post_type'] = 'voice'
        if req.waveform:
            import json as json_mod2
            post_data['waveform'] = json_mod2.dumps(req.waveform)
    
    # If mesh post_id provided, use it as the post ID
    if req.post_id:
        post_data['id'] = req.post_id
    
    # Set mesh origin flag if from gateway bridge
    if req.mesh_origin:
        post_data['mesh_origin'] = True
        # Phase 2: Store Ed25519 signature from origin device
        if req.mesh_signature:
            post_data['mesh_signature'] = req.mesh_signature
        if req.mesh_signer_key:
            post_data['mesh_signer_key'] = req.mesh_signer_key
    
    # Extract and store hashtags (from client or auto-extracted from content)
    import re, json as json_mod
    hashtags = req.hashtags or []
    if not hashtags and req.content:
        hashtags = list(set(tag.lower() for tag in re.findall(r'#(\w+)', req.content)))
    if hashtags:
        post_data['hashtags'] = json_mod.dumps(hashtags[:20])  # Max 20 hashtags

    # Inline video-jump commands (`v0:21`, `v1:23`…). Parsed once here and
    # cached on the row so the feed doesn't have to re-scan every render —
    # capped at 32 markers per post to keep payloads bounded.
    chapters = extract_video_chapters(req.content)
    if chapters:
        post_data['video_chapters'] = json_mod.dumps(chapters[:32])

    post = Post(**post_data)
    
    db.add(post)
    db.commit()
    db.refresh(post)
    print(f"✅ [PostCreate] COMMITTED post_id={post.id[:8]} client_request_id={crid[:8]}")
    
    # Invalidate feed caches on new post
    cache.invalidate("feed:global:*")
    cache.invalidate("feed:local:*")
    cache.invalidate("feed:friends:*")
    
    # Create PostMedia records for multi-media posts (images + videos)
    media_responses = []
    from models import PostMedia
    import uuid as uuid_mod
    max_media = 10 if current_user.is_premium else 4  # RAVEN+: 10, Free: 4
    
    # PRIMARY: Use media_items if present (new iOS client sends this for mixed media)
    if req.media_items and len(req.media_items) > 0:
        print(f"🔍 DEBUG create_post: req.media_items = {[m.dict() for m in req.media_items]}")
        for idx, item in enumerate(req.media_items[:max_media]):
            media_id = str(uuid_mod.uuid4())
            media = PostMedia(
                id=media_id,
                post_id=post.id,
                url=item.url,
                order_index=idx,
                media_type=item.media_type or 'image',
                thumbnail_url=item.thumbnail_url
            )
            db.add(media)
            media_responses.append(PostMediaResponse(
                id=media_id,
                url=build_full_url(request, item.url),
                order_index=idx,
                media_type=item.media_type or 'image',
                thumbnail_url=build_full_url(request, item.thumbnail_url) if item.thumbnail_url else None,
                top_comments=None
            ))
        db.commit()
        print(f"🎬 Created {len(media_responses)} PostMedia records (mixed) for post {post.id[:8]}")
        
        # Set post_type based on media content (video takes priority)
        has_video = any(item.media_type == "video" for item in req.media_items[:max_media])
        if has_video and not post.post_type:
            post.post_type = "video"
        elif not post.post_type:
            post.post_type = "image"
        db.commit()
    
    # FALLBACK: Use image_urls for backward compatibility (legacy clients)
    elif req.image_urls and len(req.image_urls) > 0:
        print(f"🔍 DEBUG create_post: req.image_urls = {req.image_urls}")
        for idx, url in enumerate(req.image_urls[:max_media]):
            media_id = str(uuid_mod.uuid4())
            media = PostMedia(
                id=media_id,
                post_id=post.id,
                url=url,
                order_index=idx,
                media_type='image'
            )
            db.add(media)
            media_responses.append(PostMediaResponse(
                id=media_id,
                url=build_full_url(request, url),
                order_index=idx,
                media_type='image',
                thumbnail_url=None,
                top_comments=None
            ))
        db.commit()
        print(f"🖼️ Created {len(media_responses)} PostMedia records (legacy) for post {post.id[:8]}")
    
    content_preview = req.content[:50] if req.content else "(image only)"
    print(f"📝 Post created by {current_user.username}: {content_preview}... [visibility={req.visibility}]")
    
    # 🔔 Notify post subscribers (push + in-app)
    # Uses both legacy PostSubscription AND new UserNotificationSubscription (bell feature)
    from models import PostSubscription, Notification, UserNotificationSubscription
    
    # Collect subscriber IDs from both sources (deduplicated)
    legacy_subs = db.query(PostSubscription).filter(
        PostSubscription.target_id == current_user.id,
        PostSubscription.enabled == True
    ).all()
    
    bell_subs = db.query(UserNotificationSubscription).filter(
        UserNotificationSubscription.target_id == current_user.id,
        UserNotificationSubscription.notify_posts == True
    ).all()
    
    # Deduplicate subscriber IDs
    notified_ids = set()
    all_subscriber_ids = []
    for sub in legacy_subs:
        if sub.subscriber_id not in notified_ids:
            notified_ids.add(sub.subscriber_id)
            all_subscriber_ids.append(sub.subscriber_id)
    for sub in bell_subs:
        if sub.subscriber_id not in notified_ids:
            notified_ids.add(sub.subscriber_id)
            all_subscriber_ids.append(sub.subscriber_id)
    
    if all_subscriber_ids:
        from services.apns_service import get_apns_service, APNsService
        apns = get_apns_service()
        
        author_name = APNsService.build_push_display_name(current_user)
        post_preview = req.content[:100] if req.content else "(image)"
        
        for subscriber_id in all_subscriber_ids:
            # Create in-app notification
            notif_data = json.dumps({
                "postId": post.id,
                "authorId": current_user.id,
                "authorUsername": current_user.username,
                "postPreview": post_preview
            })
            notification = Notification(
                user_id=subscriber_id,
                type="new_post",
                data=notif_data,
                is_read=False
            )
            db.add(notification)
            
            # Send push to subscriber (with preference check)
            subscriber_user = db.query(User).filter(User.id == subscriber_id).first()
            if subscriber_user and subscriber_user.push_token and subscriber_user.push_platform == "ios":
                prefs = APNsService.should_send_push(subscriber_user, "new_post")
                if prefs["allowed"]:
                    try:
                        push_result = await apns.send_new_post_notification(
                            device_token=subscriber_user.push_token,
                            author_name=author_name,
                            post_preview=post_preview,
                            post_id=post.id,
                            author_id=current_user.id
                        )
                        print(f"🔔 [PUSH] event=new_post sender={current_user.id[:8]} "
                              f"receiver={subscriber_id[:8]} status={'sent' if push_result else 'failed'}")
                    except Exception as e:
                        print(f"🔔 [PUSH] event=new_post sender={current_user.id[:8]} "
                              f"receiver={subscriber_id[:8]} status=error reason={e}")
                else:
                    print(f"🔔 [PUSH] event=new_post receiver={subscriber_id[:8]} status=skipped reason=disabled")
        
        db.commit()
        print(f"🔔 Notified {len(all_subscriber_ids)} post subscribers for @{current_user.username}")
    
    
    # 🔔 Process @mentions in post content (Tag users).
    #
    # Two paths:
    #   1. PREFERRED — `req.entities` (structured, from iOS MentionPicker).
    #      Correct for any username (incl. dots/hyphens). Carries the user_id
    #      directly so we don't need a regex+lookup.
    #   2. FALLBACK — regex extraction from `req.content`. Used by older
    #      clients and mesh-bridged posts. Breaks on `@john.doe` style names.
    if req.entities:
        # Entity path: extract username list (lowercased for the SAME
        # downstream block of code as regex). The downstream block re-queries
        # by username for batch resolution; entities also carry the id but
        # the existing downstream code is keyed on username — keep it simple.
        seen = set()
        mention_usernames = []
        for ent in req.entities:
            if ent.type != "mention":
                continue
            uname = (ent.username or "").lower()
            if uname and uname not in seen:
                seen.add(uname)
                mention_usernames.append(uname)
            if len(mention_usernames) >= 10:
                break
    elif req.content:
        import re as re_mod
        mention_usernames = list(set(
            m.lower() for m in re_mod.findall(r'@(\w+)', req.content)
        ))[:10]  # Max 10 mentions per post
    else:
        mention_usernames = []

    if mention_usernames:
        # NOTE: `if mention_usernames` was previously implied by the outer
        # `if req.content`. Keep behavior identical; just add an indent shim.
        if True:
            from models import Mention
            from routers.blocks import get_blocked_user_ids
            
            # Batch-resolve usernames to users
            mentioned_users = db.query(User).filter(
                func.lower(User.username).in_(mention_usernames)
            ).all()
            
            if mentioned_users:
                blocked_ids = set(get_blocked_user_ids(db, actual_author_id))
                
                if 'apns' not in dir() or 'APNsService' not in dir():
                    from services.apns_service import get_apns_service, APNsService
                    import asyncio
                    apns = get_apns_service()
                
                author_name = APNsService.build_push_display_name(current_user)
                post_preview = req.content[:100] if req.content else "(post)"
                mention_count = 0
                
                for mentioned_user in mentioned_users:
                    # Skip self-mentions
                    if mentioned_user.id == actual_author_id:
                        continue
                    # Skip blocked users
                    if mentioned_user.id in blocked_ids:
                        continue
                    
                    mention_count += 1
                    
                    # Create Mention record
                    mention_record = Mention(
                        type="post",
                        source_id=post.id,
                        post_id=post.id,
                        mentioned_user_id=mentioned_user.id,
                        mentioned_by_user_id=actual_author_id,
                        snippet=post_preview,
                        deep_link=f"raven://post/{post.id}",
                        is_read=False
                    )
                    db.add(mention_record)
                    
                    # Create in-app Notification
                    if 'Notification' not in dir():
                        from models import Notification
                    notif_data = json.dumps({
                        "postId": post.id,
                        "authorId": actual_author_id,
                        "authorUsername": current_user.username,
                        "postPreview": post_preview,
                        "mentionType": "post"
                    })
                    notification = Notification(
                        user_id=mentioned_user.id,
                        type="mention",
                        data=notif_data,
                        is_read=False
                    )
                    db.add(notification)
                    
                    # Send push notification
                    if mentioned_user.push_token and mentioned_user.push_platform == "ios":
                        prefs = APNsService.should_send_push(mentioned_user, "mention")
                        if prefs["allowed"]:
                            asyncio.ensure_future(apns.send_mention_notification(
                                device_token=mentioned_user.push_token,
                                mentioner_name=author_name,
                                mention_type="post",
                                snippet=post_preview,
                                deep_link=f"raven://post/{post.id}",
                                post_id=post.id,
                                source_id=post.id
                            ))
                
                if mention_count > 0:
                    db.commit()
                    print(f"📢 [Mentions] Tagged {mention_count} users in post {post.id[:8]} by @{current_user.username}")
    
    # For mesh gateway uploads, resolve the actual author (may differ from current_user)
    if actual_author_id != current_user.id:
        actual_author = db.query(User).filter(User.id == actual_author_id).first()
        resp_username = actual_author.username if actual_author else (req.author_username or "Unknown")
        resp_avatar = build_full_url(request, actual_author.avatar_path) if actual_author else None
    else:
        resp_username = current_user.username
        resp_avatar = build_full_url(request, current_user.avatar_path)
    
    response = PostResponse(
        id=post.id,
        author_id=post.author_id,
        author_username=resp_username,
        author_avatar=resp_avatar,
        content=decrypt_text(post.content),
        image_url=build_full_url(request, post.image_url),
        media=media_responses if media_responses else None,  # Multi-image support
        timestamp=post.timestamp,
        edited_at=post.edited_at,
        likes=0,
        comments=0,
        reposts=0,
        view_count=0,
        is_local=post.is_local,
        is_liked=False,
        is_reposted=False,
        visibility=post.visibility or "public",
        post_type=post.post_type,
        room_id=post.room_id,
        mesh_origin=post.mesh_origin or False,
        show_on_raven_shot=post.show_on_raven_shot or False,
        latitude=post.latitude,
        longitude=post.longitude,
        location_name=post.location_name,
        **get_voice_and_collab_fields(post, db, author=current_user)
    )
    
    # 🏷️ Process user tags (tag people in post)
    tag_responses = []
    if req.tagged_users:
        from models import PostTag
        from routers.blocks import get_blocked_user_ids
        import asyncio
        
        blocked_ids = set(get_blocked_user_ids(db, actual_author_id))
        tagged_user_ids = list(set(req.tagged_users[:20]))  # Max 20 tags, deduplicated
        
        # Batch-resolve user IDs
        tagged_user_objs = db.query(User).filter(User.id.in_(tagged_user_ids)).all()
        
        if 'apns' not in dir() or 'APNsService' not in dir():
            from services.apns_service import get_apns_service, APNsService
            apns = get_apns_service()
        author_name = APNsService.build_push_display_name(current_user)
        
        for tagged_user in tagged_user_objs:
            # Skip self-tags and blocked users
            if tagged_user.id == actual_author_id:
                continue
            if tagged_user.id in blocked_ids:
                continue
            
            # Create PostTag record
            tag_record = PostTag(
                post_id=post.id,
                tagged_user_id=tagged_user.id,
                tagged_by_user_id=actual_author_id
            )
            db.add(tag_record)
            
            tag_responses.append({
                "id": tagged_user.id,
                "username": tagged_user.username,
                "avatar_path": build_full_url(request, tagged_user.avatar_path) if tagged_user.avatar_path else None
            })
            
            # Create in-app Notification
            notif_data = json.dumps({
                "postId": post.id,
                "authorId": actual_author_id,
                "authorUsername": current_user.username,
                "tagType": "post"
            })
            notification = Notification(
                user_id=tagged_user.id,
                type="tag",
                data=notif_data,
                is_read=False
            )
            db.add(notification)
            
            # Send push notification
            if tagged_user.push_token and tagged_user.push_platform == "ios":
                prefs = APNsService.should_send_push(tagged_user, "mention")
                if prefs["allowed"]:
                    asyncio.ensure_future(apns.send_mention_notification(
                        device_token=tagged_user.push_token,
                        mentioner_name=author_name,
                        mention_type="photo_tag",
                        snippet="tagged you in a post",
                        deep_link=f"raven://post/{post.id}",
                        post_id=post.id,
                        source_id=post.id
                    ))
        
        if tag_responses:
            db.commit()
            print(f"🏷️ [Tags] Tagged {len(tag_responses)} users in post {post.id[:8]} by @{current_user.username}")
    
    # Update response with tags and location_name
    response.tagged_users = tag_responses if tag_responses else None
    response.location_name = post.location_name
    
    return response

@router.get("/feed", response_model=List[PostResponse])
def get_feed(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 20,
    offset: int = 0,
    cursor: Optional[str] = None
):
    """Get feed of posts with like/comment/repost stats. Excludes blocked/hidden.
    
    Supports cursor-based pagination (preferred) and offset (legacy).
    Pass `cursor` = ISO timestamp of last post to get next page efficiently.
    """
    # Cache check (keyed per-user because blocked/hidden lists differ)
    cache_key = f"feed:global:{current_user.id}:{cursor or offset}:{limit}"
    cached = cache.get(cache_key)
    if cached is not None:
        return cached
    
    from routers.blocks import get_blocked_user_ids
    from models import HiddenContent
    
    blocked_ids = get_blocked_user_ids(db, current_user.id)
    hidden_post_ids = [h.object_id for h in db.query(HiddenContent.object_id).filter(
        HiddenContent.user_id == current_user.id,
        HiddenContent.object_type == "post"
    ).all()]
    
    query = db.query(Post).filter(
        or_(Post.is_hidden == False, Post.is_hidden == None),
        or_(Post.visibility == 'public', Post.visibility == None)
    ).order_by(Post.timestamp.desc())
    if blocked_ids:
        query = query.filter(~Post.author_id.in_(blocked_ids))
    if hidden_post_ids:
        query = query.filter(~Post.id.in_(hidden_post_ids))
    
    # Cursor-based pagination (preferred) — avoids slow OFFSET scans
    if cursor:
        try:
            cursor_dt = datetime.fromisoformat(cursor)
            query = query.filter(Post.timestamp < cursor_dt)
        except ValueError:
            pass  # Fall through to offset if cursor is invalid
    else:
        query = query.offset(offset)
    
    posts = query.limit(limit).all()
    
    import time as _time
    _t0 = _time.monotonic()
    
    # Batch-load authors and stats (eliminates N+1)
    post_ids = [p.id for p in posts]
    author_ids = list(set(p.author_id for p in posts))
    authors_map = {u.id: u for u in db.query(User).filter(User.id.in_(author_ids)).all()} if author_ids else {}
    
    _t1 = _time.monotonic()
    stats_map = get_batch_post_stats(db, post_ids, current_user.id)
    _t2 = _time.monotonic()
    media_map = get_batch_post_media(request, db, post_ids)
    _t3 = _time.monotonic()
    
    print(f"⚡ [Feed] {len(posts)} posts: authors={(_t1-_t0)*1000:.0f}ms stats={(_t2-_t1)*1000:.0f}ms media={(_t3-_t2)*1000:.0f}ms total={(_t3-_t0)*1000:.0f}ms")
    
    result = []
    for post in posts:
        author = authors_map.get(post.author_id)
        stats = stats_map.get(post.id, {"likes": 0, "comments": 0, "reposts": 0, "is_liked": False, "is_reposted": False})
        
        result.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=build_full_url(request, author.avatar_path) if author else None,
            content=decrypt_text(post.content),
            image_url=build_full_url(request, post.image_url),
            timestamp=post.timestamp,
            edited_at=post.edited_at,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            view_count=post.view_count or 0,
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"],
            post_type=post.post_type,
            room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            location_name=getattr(post, 'location_name', None),
            media=media_map.get(post.id),
            like_preview_user_ids=stats.get("like_preview_user_ids", []),
            comment_preview_user_ids=stats.get("comment_preview_user_ids", []),
            show_on_raven_shot=post.show_on_raven_shot or False,
            latitude=post.latitude,
            longitude=post.longitude,
            **get_voice_and_collab_fields(post, db, author=author)
        ))
    
    # Cache result
    serialized = [r.dict() for r in result]
    cache.set(cache_key, serialized, ttl=TTL_FEED)
    
    # ⚡ PERF: ETag support — if content hasn't changed, return 304 (no body)
    etag_src = f"{len(result)}:{result[0].timestamp.isoformat() if result else 'empty'}"
    etag = f'"feed-{hashlib.md5(etag_src.encode()).hexdigest()[:16]}"'
    client_etag = request.headers.get("if-none-match")
    if client_etag and client_etag == etag:
        return Response(status_code=304, headers={"ETag": etag})
    
    return Response(
        content=json.dumps(serialized, default=str),
        media_type="application/json",
        headers={"ETag": etag}
    )


# ==================== LOCAL FEED (Interest-Based Algorithm) ====================
@router.get("/feed/local")
def get_local_feed(
    request: Request,
    lat: float = None,
    lng: float = None,
    radius_m: int = 5000,  # Default 5km radius
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 20,
    offset: int = 0,
    cursor: Optional[str] = None
):
    """
    Get LOCAL feed - posts near user's location with interest-based ranking.
    
    Algorithm combines:
    - Location proximity (geohash)
    - User interests (from likes, comments, shares history)
    - Engagement score (likes + comments + reposts)
    - Recency (time decay)
    
    NO priority for stories over posts - everything ranked equally.
    """
    import math
    from geohash import encode as encode_geohash, get_neighbors
    from datetime import timedelta
    from sqlalchemy import or_
    from services.interest_service import get_user_interests, extract_tags_from_post
    
    # Haversine distance formula
    def haversine_distance(lat1, lng1, lat2, lng2):
        """Calculate distance in meters between two coordinates."""
        R = 6371000  # Earth radius in meters
        phi1, phi2 = math.radians(lat1), math.radians(lat2)
        delta_phi = math.radians(lat2 - lat1)
        delta_lambda = math.radians(lng2 - lng1)
        a = math.sin(delta_phi/2)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda/2)**2
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        return R * c
    
    # Round distance to nearest 100m for privacy
    def round_distance(meters):
        return int(round(meters / 100) * 100)
    
    # Calculate interest score for a post
    def calculate_interest_score(post, user_interests_dict):
        """Score based on matching user interests."""
        post_tags = extract_tags_from_post(post)
        score = 0.0
        for tag in post_tags:
            if tag in user_interests_dict:
                score += user_interests_dict[tag]
        return score
    
    # Calculate engagement score
    def calculate_engagement_score(stats):
        """Weighted engagement: likes=1, comments=2, reposts=3"""
        return stats['likes'] + (stats['comments'] * 2) + (stats['reposts'] * 3)
    
    # Calculate recency score (0-1, higher = more recent)
    def calculate_recency_score(post_time, now):
        """Exponential decay: half-life = 6 hours"""
        hours_old = (now - post_time).total_seconds() / 3600
        return math.exp(-0.116 * hours_old)  # ln(2)/6 ≈ 0.116
    
    # Use provided location or return empty
    if not (lat and lng):
        print(f"📍 Local feed for {current_user.username}: No location provided")
        return []
    
    # Cache check (keyed by geohash prefix for location-based grouping)
    from geohash import encode as _gh_encode
    cache_geohash = _gh_encode(lat, lng, precision=5)
    cache_key = f"feed:local:{current_user.id}:{cache_geohash}:{cursor or offset}:{limit}"
    cached = cache.get(cache_key)
    if cached is not None:
        return PaginatedFeedResponse(**cached)
    
    # Get blocked/hidden filters (matching get_feed and get_friends_feed)
    from routers.blocks import get_blocked_user_ids
    from models import HiddenContent
    
    blocked_ids = get_blocked_user_ids(db, current_user.id)
    hidden_post_ids = [h.object_id for h in db.query(HiddenContent.object_id).filter(
        HiddenContent.user_id == current_user.id,
        HiddenContent.object_type == "post"
    ).all()]
    
    # Get user's interests for personalization
    user_interests = get_user_interests(current_user.id, db, limit=50)
    user_interests_dict = {i['tag']: i['score'] for i in user_interests}
    
    # Compute user's geohash
    user_geohash = encode_geohash(lat, lng, precision=6)
    
    # Get neighboring geohashes for broader coverage
    neighbor_hashes = get_neighbors(user_geohash)
    all_hashes = [user_geohash] + neighbor_hashes
    
    # 7-day recency filter
    seven_days_ago = datetime.utcnow() - timedelta(days=7)
    now = datetime.utcnow()
    
    # NOTE: Single-use content exclusion DISABLED
    # Posts now remain visible even after being viewed
    # To re-enable single-use content, uncomment the consumed_ids filter below
    #
    # consumed_ids = db.query(ContentConsumption.content_id).filter(
    #     ContentConsumption.user_id == current_user.id,
    #     ContentConsumption.content_type == 'post'
    # ).subquery()
    
    # Query posts in nearby geohashes with visibility filter
    # Apply offset to support pagination for scored feeds
    query = db.query(Post).filter(
        or_(
            *[Post.geohash.like(f"{h[:5]}%") for h in all_hashes],  # Prefix match
            Post.geohash == None  # Include posts without location (deprioritized via max distance)
        ),
        or_(Post.visibility == 'public', Post.visibility == None),
        or_(Post.is_hidden == False, Post.is_hidden == None),
        Post.timestamp > seven_days_ago
    )
    # Exclude blocked users
    if blocked_ids:
        query = query.filter(~Post.author_id.in_(blocked_ids))
    # Exclude hidden posts
    if hidden_post_ids:
        query = query.filter(~Post.id.in_(hidden_post_ids))
    
    # Cursor-based pagination (preferred) — avoids slow OFFSET scans.
    # Cursor uses a WHERE clause (filter), so it can be applied here.
    if cursor:
        try:
            cursor_dt = datetime.fromisoformat(cursor)
            query = query.filter(Post.timestamp < cursor_dt)
        except ValueError:
            pass

    # ⚠️ SQLAlchemy enforces this order: order_by() MUST come before
    # offset()/limit(). Previously this code applied .offset() first
    # (legacy fallback path) and then chained .order_by().limit() — which
    # raised `Query.order_by() being called on a Query which already has
    # LIMIT or OFFSET applied`, returning a 500 to every cursorless caller.
    query = query.order_by(Post.timestamp.desc())
    if not cursor and offset:
        query = query.offset(offset)

    posts = query.limit(limit * 3).all()  # Fetch extra for scoring
    total_fetched = len(posts)  # Track actual DB rows consumed for pagination
    
    # Debug: log voice post counts for feed diagnostics
    voice_count = sum(1 for p in posts if p.post_type == 'voice')
    if voice_count > 0:
        print(f"🎤 Local feed: {voice_count} voice posts in query result (total {len(posts)} posts)")
    
    # Batch-load authors and stats BEFORE scoring loop (eliminates N+1)
    post_ids = [p.id for p in posts]
    author_ids = list(set(p.author_id for p in posts))
    authors_map = {u.id: u for u in db.query(User).filter(User.id.in_(author_ids)).all()} if author_ids else {}
    stats_map = get_batch_post_stats(db, post_ids, current_user.id)
    media_map = get_batch_post_media(request, db, post_ids)
    
    # Score and filter posts
    scored_posts = []
    for post in posts:

        # Posts without location: include with max distance (deprioritized, not hidden)
        if post.latitude is None or post.longitude is None:
            distance = radius_m  # Assign max radius so they sort last
        else:
            # Calculate actual distance
            distance = haversine_distance(lat, lng, post.latitude, post.longitude)
            
            # Filter by radius (only for posts WITH location)
            if distance > radius_m:
                continue
        
        # Get stats from batch map
        stats = stats_map.get(post.id, {"likes": 0, "comments": 0, "reposts": 0, "is_liked": False, "is_reposted": False})
        
        # Calculate combined score
        interest_score = calculate_interest_score(post, user_interests_dict)
        engagement_score = calculate_engagement_score(stats)
        recency_score = calculate_recency_score(post.timestamp, now)
        
        # Weighted combination: interest (40%) + engagement (30%) + recency (30%)
        final_score = (interest_score * 0.4) + (engagement_score * 0.1 * 0.3) + (recency_score * 10 * 0.3)
        
        author = authors_map.get(post.author_id)
        
        scored_posts.append({
            'post': PostResponse(
                id=post.id,
                author_id=post.author_id,
                author_username=author.username if author else "Unknown",
                author_avatar=build_full_url(request, author.avatar_path) if author else None,
                content=decrypt_text(post.content),
                image_url=build_full_url(request, post.image_url),
                timestamp=post.timestamp,
                edited_at=post.edited_at,
                likes=stats["likes"],
                comments=stats["comments"],
                reposts=stats["reposts"],
                view_count=post.view_count or 0,
                is_local=post.is_local,
                is_liked=stats["is_liked"],
                is_reposted=stats["is_reposted"],
                visibility=post.visibility or "public",
                distance_m=round_distance(distance),
                post_type=post.post_type,
                room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            location_name=getattr(post, 'location_name', None),
                media=media_map.get(post.id),
                like_preview_user_ids=stats.get("like_preview_user_ids", []),
                comment_preview_user_ids=stats.get("comment_preview_user_ids", []),
                **get_voice_and_collab_fields(post, db, author=author)
            ),
            'score': final_score
        })
    
    # Sort by score descending
    scored_posts.sort(key=lambda x: x['score'], reverse=True)
    
    # Return top N posts
    result = [sp['post'] for sp in scored_posts[:limit]]
    # Advance offset by total DB rows consumed (not scored result count)
    # This ensures next page doesn't re-fetch or skip rows
    next_offset = offset + total_fetched
    has_more = total_fetched >= limit  # More in DB if we got at least limit rows
    
    print(f"📍 Local feed for {current_user.username}: {len(result)} posts (fetched={total_fetched}, scored={len(scored_posts)}, offset={offset}, nextOffset={next_offset}, hasMore={has_more})")
    response = PaginatedFeedResponse(items=result, hasMore=has_more, nextOffset=next_offset)
    cache.set(cache_key, response.dict(), ttl=TTL_FEED)
    return response


# ==================== FRIENDS FEED ====================
@router.get("/feed/friends")
def get_friends_feed(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 20,
    offset: int = 0,
    cursor: Optional[str] = None
):
    """
    Get FRIENDS feed - posts from accepted friends.
    - Shows ALL posts from friends (public + friends-only)
    - Only from users who are accepted friends (mutual)
    - Ordered by timestamp DESC
    """
    import traceback
    try:
        from models import FriendRequest
        
        # Get list of accepted friend user IDs
        sent_friends = db.query(FriendRequest.recipient_id).filter(
            FriendRequest.requester_id == current_user.id,
            FriendRequest.status == "accepted"
        ).all()
        
        received_friends = db.query(FriendRequest.requester_id).filter(
            FriendRequest.recipient_id == current_user.id,
            FriendRequest.status == "accepted"
        ).all()
        
        friend_ids = set([f[0] for f in sent_friends] + [f[0] for f in received_friends])
        
        # Include user's own posts in the friends feed
        friend_ids.add(current_user.id)
        
        if not friend_ids:
            return PaginatedFeedResponse(items=[], hasMore=False, nextOffset=0)
        
        # Query posts from friends and self (excluding blocked/hidden)
        from routers.blocks import get_blocked_user_ids
        from models import HiddenContent
        
        blocked_ids = get_blocked_user_ids(db, current_user.id)
        friend_ids -= set(blocked_ids)  # Remove blocked from friends
        
        hidden_post_ids = [h.object_id for h in db.query(HiddenContent.object_id).filter(
            HiddenContent.user_id == current_user.id,
            HiddenContent.object_type == "post"
        ).all()]
        
        # Cache check
        cache_key = f"feed:friends:{current_user.id}:{cursor or offset}:{limit}"
        cached = cache.get(cache_key)
        if cached is not None:
            return PaginatedFeedResponse(**cached)
        
        # ✅ FIX: Show ALL posts from friends (public + friends-only), not just friends-visibility
        query = db.query(Post).filter(
            Post.author_id.in_(friend_ids),
            or_(Post.is_hidden == False, Post.is_hidden == None),
            or_(Post.visibility == 'friends', Post.visibility == 'public', Post.visibility == None)
        )
        if hidden_post_ids:
            query = query.filter(~Post.id.in_(hidden_post_ids))
        
        # ✅ FIX: Apply order_by BEFORE offset/limit (SQLAlchemy requirement)
        query = query.order_by(Post.timestamp.desc())
        
        # Cursor-based pagination (preferred)
        if cursor:
            try:
                cursor_dt = datetime.fromisoformat(cursor)
                query = query.filter(Post.timestamp < cursor_dt)
            except ValueError:
                pass
        else:
            query = query.offset(offset)
        
        posts = query.limit(limit).all()

        # Batch-load authors and stats (eliminates N+1)
        post_ids = [p.id for p in posts]
        author_ids = list(set(p.author_id for p in posts))
        authors_map = {u.id: u for u in db.query(User).filter(User.id.in_(author_ids)).all()} if author_ids else {}
        stats_map = get_batch_post_stats(db, post_ids, current_user.id)
        media_map = get_batch_post_media(request, db, post_ids)
        
        result = []
        for post in posts:
            author = authors_map.get(post.author_id)
            stats = stats_map.get(post.id, {"likes": 0, "comments": 0, "reposts": 0, "is_liked": False, "is_reposted": False})
            
            result.append(PostResponse(
                id=post.id,
                author_id=post.author_id,
                author_username=author.username if author else "Unknown",
                author_avatar=build_full_url(request, author.avatar_path) if author else None,
                content=decrypt_text(post.content),
                image_url=build_full_url(request, post.image_url),
                timestamp=post.timestamp,
                edited_at=post.edited_at,
                likes=stats["likes"],
                comments=stats["comments"],
                reposts=stats["reposts"],
                view_count=post.view_count or 0,
                is_local=post.is_local,
                is_liked=stats["is_liked"],
                is_reposted=stats["is_reposted"],
                visibility=post.visibility or "public",
                post_type=post.post_type,
                room_id=post.room_id,
                mesh_origin=post.mesh_origin or False,
            location_name=getattr(post, 'location_name', None),
                media=media_map.get(post.id),
                like_preview_user_ids=stats.get("like_preview_user_ids", []),
                comment_preview_user_ids=stats.get("comment_preview_user_ids", []),
                    **get_voice_and_collab_fields(post, db, author=author)
            ))
        
        has_more = len(result) == limit  # If we got exactly limit posts, there are likely more
        next_offset = offset + len(result)
        
        print(f"👥 Friends feed for {current_user.username}: {len(result)} posts from {len(friend_ids)} friends (offset={offset}, hasMore={has_more})")
        response_data = PaginatedFeedResponse(items=result, hasMore=has_more, nextOffset=next_offset)
        serialized = response_data.dict()
        cache.set(cache_key, serialized, ttl=TTL_FEED)
        
        # ⚡ PERF: ETag support
        etag_src = f"{len(result)}:{result[0].timestamp.isoformat() if result else 'empty'}"
        etag = f'"friends-{hashlib.md5(etag_src.encode()).hexdigest()[:16]}"'
        client_etag = request.headers.get("if-none-match")
        if client_etag and client_etag == etag:
            return Response(status_code=304, headers={"ETag": etag})
        
        return Response(
            content=json.dumps(serialized, default=str),
            media_type="application/json",
            headers={"ETag": etag}
        )
    except Exception as e:
        print(f"❌❌❌ FRIENDS FEED CRASH: {type(e).__name__}: {e}")
        print(traceback.format_exc())
        raise


@router.post("/{post_id}/like")
async def toggle_like_post(
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Toggle like on a post (one like per user)."""
    post = db.query(Post).filter(Post.id == post_id).first()
    
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    # Check if already liked by this user
    existing_like = db.query(PostLike).filter(
        PostLike.post_id == post_id,
        PostLike.user_id == current_user.id
    ).first()
    
    if existing_like:
        # Unlike - remove the like
        db.delete(existing_like)
        action = "unliked"
    else:
        # Like - add new like
        new_like = PostLike(
            post_id=post_id,
            user_id=current_user.id,
            timestamp=datetime.utcnow()
        )
        db.add(new_like)
        action = "liked"
        
        # Create notification for post owner (if not self-like)
        if post.author_id != current_user.id:
            from models import Notification
            notif = Notification(
                user_id=post.author_id,
                type="like",
                data=json.dumps({
                    "post_id": post_id,
                    "liker_id": current_user.id,
                    "liker_username": current_user.username,
                    "liker_avatar": current_user.avatar_path,
                }),
                timestamp=datetime.utcnow(),
                is_read=False
            )
            db.add(notif)
            print(f"🔔 Like notification created for {post.author_id}")
            
            # ✅ Send push notification to post owner (with preference check)
            author = db.query(User).filter(User.id == post.author_id).first()
            if author and author.push_token and author.push_platform == "ios":
                from services.apns_service import get_apns_service, APNsService
                
                prefs = APNsService.should_send_push(author, "like")
                if prefs["allowed"]:
                    apns = get_apns_service()
                    
                    liker_name = APNsService.build_push_display_name(current_user)
                    badge = APNsService.get_unread_badge_count(db, post.author_id)
                    
                    push_result = await apns.send_like_notification(
                        device_token=author.push_token,
                        liker_name=liker_name,
                        post_id=post_id,
                        badge=badge
                    )
                    if push_result:
                        print(f"📱 ✅ Like push sent to {author.username}")
                    else:
                        print(f"📱 ❌ Like push failed for {author.username}")
                else:
                    print(f"📱 ⏭️ Like push skipped for {author.username} (notifications disabled)")
        
        # Track interest for recommendation algorithm
        try:
            from services.interest_service import log_user_event
            log_user_event(current_user.id, 'like_post', db, post_id=post_id)
        except Exception as e:
            print(f"⚠️ Interest tracking failed: {e}")
    
    db.commit()
    
    # Get updated count
    like_count = db.query(PostLike).filter(PostLike.post_id == post_id).count()
    
    print(f"❤️ Post {action} by {current_user.username} (total: {like_count})")
    
    return {
        "status": "success",
        "action": action,
        "likes": like_count,
        "is_liked": action == "liked"
    }


@router.post("/{post_id}/repost")
def repost_post(
    post_id: str,
    req: RepostRequest = None,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Repost a post (with optional quote)."""
    post = db.query(Post).filter(Post.id == post_id).first()
    
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    # Check if already reposted
    existing_repost = db.query(Repost).filter(
        Repost.original_post_id == post_id,
        Repost.user_id == current_user.id
    ).first()
    
    if existing_repost:
        # Undo repost
        db.delete(existing_repost)
        action = "unreposted"
    else:
        # Create repost
        repost = Repost(
            original_post_id=post_id,
            user_id=current_user.id,
            content=encrypt_text(req.content) if req and req.content else None,
            timestamp=datetime.utcnow()
        )
        db.add(repost)
        action = "reposted"
    
    db.commit()
    
    # Get updated count
    repost_count = db.query(Repost).filter(Repost.original_post_id == post_id).count()
    
    print(f"🔄 Post {action} by {current_user.username} (total: {repost_count})")
    
    return {
        "status": "success",
        "action": action,
        "reposts": repost_count,
        "is_reposted": action == "reposted"
    }


# ─────────────────────────────────────────────────────────────────
# Bookmarks
# ─────────────────────────────────────────────────────────────────
#
# Toggle endpoint mirrors the Like flow: idempotent flip stored in
# `post_bookmarks`. Separate DELETE endpoint exists so a client can
# unambiguously *remove* the bookmark even if its local state has
# drifted from the server (no need to read-then-toggle).

@router.post("/{post_id}/bookmark")
def toggle_bookmark(
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Toggle bookmark on a post (one bookmark per user per post)."""
    post = db.query(Post).filter(Post.id == post_id).first()
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )

    existing = db.query(PostBookmark).filter(
        PostBookmark.post_id == post_id,
        PostBookmark.user_id == current_user.id
    ).first()

    if existing:
        db.delete(existing)
        action = "removed"
        is_bookmarked = False
    else:
        new_bm = PostBookmark(
            post_id=post_id,
            user_id=current_user.id,
            timestamp=datetime.utcnow()
        )
        db.add(new_bm)
        action = "added"
        is_bookmarked = True

    db.commit()
    print(f"🔖 Bookmark {action} by {current_user.username} for post {post_id[:8]}")

    return {
        "status": "success",
        "action": action,
        "is_bookmarked": is_bookmarked
    }


@router.delete("/{post_id}/bookmark")
def delete_bookmark(
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Idempotent unbookmark — succeeds even if no bookmark exists."""
    db.query(PostBookmark).filter(
        PostBookmark.post_id == post_id,
        PostBookmark.user_id == current_user.id
    ).delete(synchronize_session=False)
    db.commit()
    return {"status": "success", "is_bookmarked": False}


@router.get("/me/bookmarks", response_model=List[PostResponse])
def list_my_bookmarks(
    limit: int = 50,
    offset: int = 0,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """List the current user's bookmarked posts, most-recently-saved
    first. Returns full PostResponse objects so the client can render
    a Bookmarks tab without follow-up requests."""
    bm_rows = (
        db.query(PostBookmark)
        .filter(PostBookmark.user_id == current_user.id)
        .order_by(PostBookmark.timestamp.desc())
        .limit(limit)
        .offset(offset)
        .all()
    )
    if not bm_rows:
        return []

    post_ids = [r.post_id for r in bm_rows]
    posts = db.query(Post).filter(Post.id.in_(post_ids)).all()
    posts_by_id = {p.id: p for p in posts}

    stats = get_batch_post_stats(db, post_ids, current_user.id)

    # Preserve bookmark-order (most recent first) instead of DB order.
    out: List[PostResponse] = []
    for pid in post_ids:
        post = posts_by_id.get(pid)
        if post is None:
            continue
        s = stats.get(pid, {})
        author = db.query(User).filter(User.id == post.author_id).first()
        voice_collab = get_voice_and_collab_fields(post, db=db, author=author)
        out.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "unknown",
            author_avatar=author.avatar_path if author else None,
            content=post.content or "",
            image_url=post.image_url,
            timestamp=post.timestamp,
            edited_at=getattr(post, 'edited_at', None),
            likes=s.get("likes", 0),
            comments=s.get("comments", 0),
            reposts=s.get("reposts", 0),
            view_count=getattr(post, 'view_count', 0),
            is_local=getattr(post, 'is_local', False),
            is_liked=s.get("is_liked", False),
            is_reposted=s.get("is_reposted", False),
            is_bookmarked=True,
            visibility=getattr(post, 'visibility', 'public') or 'public',
            post_type=getattr(post, 'post_type', None),
            room_id=getattr(post, 'room_id', None),
            mesh_origin=False,
            is_verified=bool(author and getattr(author, 'is_verified', False)),
            is_premium=bool(author and getattr(author, 'is_premium', False)),
            **voice_collab,
        ))
    return out


@router.post("/{post_id}/view")
def record_view(
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Record a unique view on a post.
    
    Privacy-first design:
    - viewer_key is SHA256(userId + serverSalt), NOT raw userId
    - No endpoint exists to retrieve viewer list
    - Only view_count is returned
    
    IDEMPOTENT: Multiple calls for same user = same result (no duplicate counting)
    """
    # ✅ Debug: Confirm request reached server
    print(f"👁️ [VIEW ENDPOINT] Request received!")
    print(f"   ├── post_id: {post_id[:8]}...")
    print(f"   ├── user: {current_user.username} (id: {current_user.id[:8]}...)")
    
    post = db.query(Post).filter(Post.id == post_id).first()
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    # Hash userId with server salt for privacy
    viewer_key = hashlib.sha256(
        f"{current_user.id}{SERVER_SALT}".encode()
    ).hexdigest()
    
    # ✅ Check if this viewer already exists (idempotent)
    existing_view = db.query(PostView).filter(
        PostView.post_id == post_id,
        PostView.viewer_key == viewer_key
    ).first()
    
    if existing_view:
        # Already viewed - return current count without incrementing
        print(f"👁️ Duplicate view ignored for post {post_id[:8]}... (user already viewed)")
    else:
        # New view - insert and increment
        try:
            view = PostView(
                post_id=post_id,
                viewer_key=viewer_key
            )
            db.add(view)
            db.flush()  # Try to insert (will fail on unique constraint)
            
            # ✅ Count from post_views table for accuracy (instead of just incrementing)
            actual_count = db.query(PostView).filter(PostView.post_id == post_id).count()
            post.view_count = actual_count
            
            db.commit()
            print(f"👁️ View recorded for post {post_id[:8]}... (count: {post.view_count})")
        except Exception as e:
            db.rollback()
            print(f"👁️ View insert failed (likely duplicate): {e}")
    
    # ✅ Always return accurate count from post_views table
    actual_count = db.query(PostView).filter(PostView.post_id == post_id).count()
    
    # Sync posts.view_count if it's out of sync
    if post.view_count != actual_count:
        post.view_count = actual_count
        db.commit()
    
    return {
        "ok": True,
        "viewCount": actual_count
    }


@router.get("/user/{user_id}", response_model=List[PostResponse])
def get_user_posts(
    request: Request,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50
):
    """Get all posts by a specific user."""
    posts = db.query(Post).filter(
        Post.author_id == user_id,
        or_(Post.is_hidden == False, Post.is_hidden == None)
    ).order_by(Post.timestamp.desc()).limit(limit).all()
    
    print(f"📋 [UserPosts] user={user_id[:8]}: found {len(posts)} posts (limit={limit})")
    
    author = db.query(User).filter(User.id == user_id).first()
    
    # Batch fetch media
    media_map = get_batch_post_media(request, db, [p.id for p in posts])
    
    result = []
    for post in posts:
        stats = get_post_stats(db, post.id, current_user.id)
        
        result.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=build_full_url(request, author.avatar_path) if author else None,
            content=decrypt_text(post.content),
            image_url=build_full_url(request, post.image_url),
            media=media_map.get(post.id),
            timestamp=post.timestamp,
            edited_at=post.edited_at,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            view_count=post.view_count or 0,
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"],
            visibility=post.visibility or "public",
            post_type=post.post_type,
            room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            location_name=getattr(post, 'location_name', None),
            like_preview_user_ids=stats.get("like_preview_user_ids"),
            comment_preview_user_ids=stats.get("comment_preview_user_ids"),
                **get_voice_and_collab_fields(post, db, author=author)
        ))
    
    return result


@router.get("/user/{user_id}/likes", response_model=List[PostResponse])
def get_user_liked_posts(
    request: Request,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
    offset: int = 0
):
    """Get posts liked by a specific user.
    
    Privacy: respects user.show_liked_posts setting.
    Only the profile owner can see their liked posts if the setting is off.
    """
    from models import PostLike
    
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="User not found")
    
    # Privacy check: if show_liked_posts is off and requester is NOT the profile owner
    if not getattr(target_user, 'show_liked_posts', True) and current_user.id != user_id:
        return []
    
    # Private profile check
    if target_user.is_private and current_user.id != user_id:
        from models import FriendRequest
        is_friend = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(
                (FriendRequest.requester_id == current_user.id) & (FriendRequest.recipient_id == user_id),
                (FriendRequest.requester_id == user_id) & (FriendRequest.recipient_id == current_user.id)
            )
        ).first() is not None
        if not is_friend:
            return []
    
    # Get post IDs liked by user, most recent first
    liked_post_ids = [row[0] for row in db.query(PostLike.post_id).filter(
        PostLike.user_id == user_id
    ).order_by(PostLike.timestamp.desc()).offset(offset).limit(limit).all()]
    
    print(f"❤️ [Profile Likes] {user_id[:8]}: found {len(liked_post_ids)} liked post IDs")
    
    if not liked_post_ids:
        return []
    
    # Fetch posts (handle NULL is_hidden correctly)
    posts = db.query(Post).filter(
        Post.id.in_(liked_post_ids),
        or_(Post.is_hidden == False, Post.is_hidden == None)
    ).all()
    
    # Maintain liked order
    post_map = {p.id: p for p in posts}
    ordered_posts = [post_map[pid] for pid in liked_post_ids if pid in post_map]
    
    # Batch stats
    stats_map = get_batch_post_stats(db, [p.id for p in ordered_posts], current_user.id)
    media_map = get_batch_post_media(request, db, [p.id for p in ordered_posts])
    
    result = []
    for post in ordered_posts:
        author = db.query(User).filter(User.id == post.author_id).first()
        stats = stats_map.get(post.id, {"likes": 0, "comments": 0, "reposts": 0, "is_liked": False, "is_reposted": False})
        
        result.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=build_full_url(request, author.avatar_path) if author else None,
            content=decrypt_text(post.content),
            image_url=build_full_url(request, post.image_url),
            media=media_map.get(post.id),
            timestamp=post.timestamp,
            edited_at=post.edited_at,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            view_count=post.view_count or 0,
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"],
            visibility=post.visibility or "public",
            post_type=post.post_type,
            room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            location_name=getattr(post, 'location_name', None),
            like_preview_user_ids=stats.get("like_preview_user_ids"),
            comment_preview_user_ids=stats.get("comment_preview_user_ids"),
            **get_voice_and_collab_fields(post, db, author=author)
        ))
    
    print(f"❤️ [Profile Likes] {user_id[:8]}: {len(result)} liked posts")
    return result


@router.get("/user/{user_id}/replies", response_model=List[PostResponse])
def get_user_replies(
    request: Request,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
    offset: int = 0
):
    """Get posts that a user has replied to (commented on).
    
    Returns the parent posts (not the comments themselves).
    Privacy: respects user.show_replies setting.
    """
    from models import Comment
    
    target_user = db.query(User).filter(User.id == user_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="User not found")
    
    # Privacy check: if show_replies is off and requester is NOT the profile owner
    if not getattr(target_user, 'show_replies', True) and current_user.id != user_id:
        return []
    
    # Private profile check
    if target_user.is_private and current_user.id != user_id:
        from models import FriendRequest
        is_friend = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(
                (FriendRequest.requester_id == current_user.id) & (FriendRequest.recipient_id == user_id),
                (FriendRequest.requester_id == user_id) & (FriendRequest.recipient_id == current_user.id)
            )
        ).first() is not None
        if not is_friend:
            return []
    
    # Get distinct post IDs the user has commented on, most recent first
    commented_post_ids = [row[0] for row in db.query(Comment.post_id).filter(
        Comment.author_id == user_id,
        or_(Comment.is_hidden == False, Comment.is_hidden == None)
    ).group_by(Comment.post_id).order_by(
        func.max(Comment.timestamp).desc()
    ).offset(offset).limit(limit).all()]
    
    print(f"💬 [Profile Replies] {user_id[:8]}: found {len(commented_post_ids)} commented post IDs")
    
    if not commented_post_ids:
        return []
    
    # Fetch posts (handle NULL is_hidden correctly)
    posts = db.query(Post).filter(
        Post.id.in_(commented_post_ids),
        or_(Post.is_hidden == False, Post.is_hidden == None)
    ).all()
    
    # Maintain order
    post_map = {p.id: p for p in posts}
    ordered_posts = [post_map[pid] for pid in commented_post_ids if pid in post_map]
    
    # Batch stats
    stats_map = get_batch_post_stats(db, [p.id for p in ordered_posts], current_user.id)
    media_map = get_batch_post_media(request, db, [p.id for p in ordered_posts])
    
    result = []
    for post in ordered_posts:
        author = db.query(User).filter(User.id == post.author_id).first()
        stats = stats_map.get(post.id, {"likes": 0, "comments": 0, "reposts": 0, "is_liked": False, "is_reposted": False})
        
        result.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=build_full_url(request, author.avatar_path) if author else None,
            content=decrypt_text(post.content),
            image_url=build_full_url(request, post.image_url),
            media=media_map.get(post.id),
            timestamp=post.timestamp,
            edited_at=post.edited_at,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            view_count=post.view_count or 0,
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"],
            visibility=post.visibility or "public",
            post_type=post.post_type,
            room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            location_name=getattr(post, 'location_name', None),
            like_preview_user_ids=stats.get("like_preview_user_ids"),
            comment_preview_user_ids=stats.get("comment_preview_user_ids"),
            **get_voice_and_collab_fields(post, db, author=author)
        ))
    
    print(f"💬 [Profile Replies] {user_id[:8]}: {len(result)} replied-to posts")
    return result


@router.get("/{post_id}", response_model=PostResponse)
def get_post(
    request: Request,
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get a single post by ID."""
    post = db.query(Post).filter(Post.id == post_id).first()
    
    if not post or post.is_hidden:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    author = db.query(User).filter(User.id == post.author_id).first()
    stats = get_post_stats(db, post.id, current_user.id)
    
    return PostResponse(
        id=post.id,
        author_id=post.author_id,
        author_username=author.username if author else "Unknown",
        author_avatar=build_full_url(request, author.avatar_path) if author else None,
        content=decrypt_text(post.content),
        image_url=build_full_url(request, post.image_url),
        timestamp=post.timestamp,
        edited_at=post.edited_at,
        likes=stats["likes"],
        comments=stats["comments"],
        reposts=stats["reposts"],
        view_count=post.view_count or 0,
        is_local=post.is_local,
        is_liked=stats["is_liked"],
        is_reposted=stats["is_reposted"],
        post_type=post.post_type,
        room_id=post.room_id,
        mesh_origin=post.mesh_origin or False,
            **get_voice_and_collab_fields(post, db, author=author)
    )


# ==================== EDIT POST ====================
@router.patch("/{post_id}", response_model=PostResponse)
def edit_post(
    request: Request,
    post_id: str,
    req: EditPostRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Edit a post's content.
    Only the post author can edit their own posts.
    """
    post = db.query(Post).filter(Post.id == post_id).first()
    
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    # Ownership check
    if post.author_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only edit your own posts"
        )
    
    # Update content and set edited_at timestamp
    post.content = encrypt_text(req.content)
    post.edited_at = datetime.utcnow()
    
    db.commit()
    db.refresh(post)
    
    print(f"✏️ Post edited by {current_user.username}: {req.content[:50]}...")
    
    author = db.query(User).filter(User.id == post.author_id).first()
    stats = get_post_stats(db, post.id, current_user.id)
    
    return PostResponse(
        id=post.id,
        author_id=post.author_id,
        author_username=author.username if author else "Unknown",
        author_avatar=build_full_url(request, author.avatar_path) if author else None,
        content=decrypt_text(post.content),
        image_url=build_full_url(request, post.image_url),
        timestamp=post.timestamp,
        edited_at=post.edited_at,
        likes=stats["likes"],
        comments=stats["comments"],
        reposts=stats["reposts"],
        view_count=post.view_count or 0,
        is_local=post.is_local,
        is_liked=stats["is_liked"],
        is_reposted=stats["is_reposted"],
        post_type=post.post_type,
        room_id=post.room_id,
        mesh_origin=post.mesh_origin or False,
            **get_voice_and_collab_fields(post, db, author=author)
    )


# ==================== DELETE POST ====================
@router.delete("/{post_id}")
def delete_post(
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Delete a post.
    Only the post author can delete their own posts.
    Cascades to delete related likes, comments, reposts, and views.
    """
    post = db.query(Post).filter(Post.id == post_id).first()
    
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    # Ownership check (admins can delete any post)
    from routers.reports import is_admin
    if post.author_id != current_user.id and not is_admin(current_user):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only delete your own posts"
        )
    
    try:
        from models import PostMedia, CommentVote, SeenPost, Mention, UserEvent
        
        # 1. Delete CommentVotes on this post's comments (no cascade from Comment → CommentVote)
        comment_ids = [c.id for c in db.query(Comment.id).filter(Comment.post_id == post_id).all()]
        if comment_ids:
            db.query(CommentVote).filter(CommentVote.comment_id.in_(comment_ids)).delete(synchronize_session=False)
        
        # 2. Delete mentions referencing this post
        db.query(Mention).filter(Mention.post_id == post_id).delete(synchronize_session=False)
        
        # 3. Delete user event tracking records
        db.query(UserEvent).filter(UserEvent.post_id == post_id).delete(synchronize_session=False)
        
        # 3. Delete seen/consumption records
        db.query(SeenPost).filter(SeenPost.post_id == post_id).delete(synchronize_session=False)
        db.query(ContentConsumption).filter(ContentConsumption.content_id == post_id).delete(synchronize_session=False)
        
        # 4. Delete mesh view receipts
        db.query(MeshViewReceipt).filter(MeshViewReceipt.post_id == post_id).delete(synchronize_session=False)
        
        # 5. Delete post interactions (likes, reposts, views)
        db.query(PostLike).filter(PostLike.post_id == post_id).delete(synchronize_session=False)
        db.query(Repost).filter(Repost.original_post_id == post_id).delete(synchronize_session=False)
        db.query(PostView).filter(PostView.post_id == post_id).delete(synchronize_session=False)
        
        # 6. Delete the post (Comments + PostMedia cascade via ORM relationship)
        db.delete(post)
        db.commit()
        
        print(f"🗑️ Post deleted by {current_user.username}: {post_id[:8]}...")
        
        return {
            "status": "success",
            "deleted": True,
            "post_id": post_id
        }
    except Exception as e:
        db.rollback()
        print(f"❌ Failed to delete post {post_id[:8]}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to delete post: {str(e)}"
        )


# =============================================================================
# MESH VIEW RECEIPTS - Offline View Tracking
# =============================================================================

class MeshReceiptRequest(BaseModel):
    """Single mesh view receipt."""
    receipt_id: str
    post_id: str
    viewer_hash: str  # SHA256(userId) for privacy
    origin_device_id: str
    hop_count: int = 0
    created_at: Optional[datetime] = None

class MeshReceiptsBatchRequest(BaseModel):
    """Batch of mesh view receipts."""
    receipts: List[MeshReceiptRequest]


@router.post("/mesh/receipts")
def sync_mesh_view_receipts(
    req: MeshReceiptsBatchRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Batch sync mesh view receipts.
    
    When a device comes online after viewing mesh-distributed posts offline,
    it calls this endpoint to sync all pending view receipts.
    
    - Receipts are idempotent (unique constraint on post_id + viewer_hash)
    - View count on post is incremented for each NEW receipt
    - Existing receipts are silently skipped
    """
    synced = 0
    skipped = 0
    
    for receipt in req.receipts:
        try:
            # Check if receipt already exists
            existing = db.query(MeshViewReceipt).filter(
                MeshViewReceipt.post_id == receipt.post_id,
                MeshViewReceipt.viewer_hash == receipt.viewer_hash
            ).first()
            
            if existing:
                skipped += 1
                continue
            
            # Check if post exists
            post = db.query(Post).filter(Post.id == receipt.post_id).first()
            if not post:
                skipped += 1
                continue
            
            # Create new receipt
            new_receipt = MeshViewReceipt(
                receipt_id=receipt.receipt_id,
                post_id=receipt.post_id,
                viewer_hash=receipt.viewer_hash,
                origin_device_id=receipt.origin_device_id,
                hop_count=receipt.hop_count,
                created_at=receipt.created_at or datetime.utcnow()
            )
            db.add(new_receipt)
            
            # Increment view count on post
            if post.view_count is None:
                post.view_count = 1
            else:
                post.view_count += 1
            
            synced += 1
            
        except Exception as e:
            print(f"⚠️ [MeshReceipt] Error: {e}")
            skipped += 1
            continue
    
    db.commit()
    
    print(f"📊 [MeshReceipt] Synced by {current_user.username}: {synced} new, {skipped} skipped")
    
    return {
        "status": "success",
        "synced": synced,
        "skipped": skipped,
        "total": len(req.receipts)
    }


# ═══════════════════════════════════════════════════════════════════════════
# VOICE POST TRANSCRIPTION (Gemini-powered, any language)
# ═══════════════════════════════════════════════════════════════════════════

async def _run_post_transcription(post_id: str):
    """Background task: transcribe a voice post using Gemini."""
    from database import SessionLocal
    from services.gemini_service import get_gemini_service
    
    db = SessionLocal()
    try:
        post = db.query(Post).filter(Post.id == post_id).first()
        if not post or not post.voice_url:
            print(f"❌ [Transcribe] Post {post_id[:8]}… not found or no voice_url")
            return
        
        post.transcript_status = "processing"
        db.commit()
        
        gemini = get_gemini_service()
        
        # Resolve voice URL — may be relative path
        audio_url = post.voice_url
        if not audio_url.startswith("http"):
            # Build full URL from config/env
            base = os.environ.get("SERVER_BASE_URL", "").rstrip("/")
            if not base:
                print(f"⚠️ [Transcribe] SERVER_BASE_URL not set, trying request-based URL")
                base = "https://raven-server-5iwa2y5n3a-ww.a.run.app"
            audio_url = f"{base}/{audio_url.lstrip('/')}"
        
        print(f"🎙️ [Transcribe] Resolved audio URL: {audio_url[:100]}...")
        
        result = await gemini.transcribe_audio(audio_url)
        
        if result.get("text"):
            post.transcript_text = result["text"]
            post.transcript_language = result.get("language")
            post.transcript_status = "ready"
            db.commit()
            print(f"✅ Post transcript ready: {post_id[:8]}… lang={result.get('language')}")
        else:
            post.transcript_status = "failed"
            db.commit()
            print(f"❌ Post transcript failed: {post_id[:8]}… {result.get('error')}")
    except Exception as e:
        print(f"❌ Post transcript error: {e}")
        import traceback
        traceback.print_exc()
        try:
            post = db.query(Post).filter(Post.id == post_id).first()
            if post:
                post.transcript_status = "failed"
                db.commit()
        except Exception:
            pass
    finally:
        db.close()


from fastapi import BackgroundTasks as _BT


@router.post("/{post_id}/transcribe")
async def transcribe_voice_post(
    post_id: str,
    background_tasks: _BT,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Trigger transcription for a voice post. Idempotent."""
    # ═══ Premium Rate Limit (3/day for free users, unlimited for premium) ═══
    from middleware.premium_rate_limit import check_ai_quota
    check_ai_quota(current_user)
    post = db.query(Post).filter(Post.id == post_id).first()
    if not post:
        raise HTTPException(status_code=404, detail="Post not found")
    
    if not post.voice_url:
        raise HTTPException(status_code=400, detail="Not a voice post")
    
    # Idempotent: return cached if ready
    if post.transcript_status == "ready":
        return {
            "status": "ready",
            "language": post.transcript_language,
            "text": post.transcript_text
        }
    
    # Already pending/processing — don't re-queue
    if post.transcript_status in ("pending", "processing"):
        return {"status": post.transcript_status}
    
    # Queue transcription
    post.transcript_status = "pending"
    db.commit()
    
    background_tasks.add_task(_run_post_transcription, post_id)
    
    print(f"🎙️ Queued post transcription: {post_id[:8]}… by {current_user.username}")
    return {"status": "pending"}


@router.get("/{post_id}/transcript")
def get_post_transcript(
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get transcript for a voice post."""
    post = db.query(Post).filter(Post.id == post_id).first()
    if not post:
        raise HTTPException(status_code=404, detail="Post not found")
    
    return {
        "status": post.transcript_status or "none",
        "language": post.transcript_language,
        "text": post.transcript_text
    }


# ==================== RAVEN SHOT (Social Map Feed) ====================

@router.get("/raven-shot/feed", response_model=List[PostResponse])
def get_raven_shot_feed(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 100,
    latitude: Optional[float] = None,
    longitude: Optional[float] = None
):
    """Get posts opted-in to Raven Shot (social map display).
    
    Returns posts where:
    - show_on_raven_shot == True
    - latitude/longitude are present
    - Visibility is public OR author is a friend
    - Not from blocked/hidden users
    """
    from routers.blocks import get_blocked_user_ids
    from models import HiddenContent, FriendRequest
    
    blocked_ids = get_blocked_user_ids(db, current_user.id)
    hidden_post_ids = [h.object_id for h in db.query(HiddenContent.object_id).filter(
        HiddenContent.user_id == current_user.id, HiddenContent.object_type == "post"
    ).all()]
    
    # Get friend IDs for visibility filtering
    sent_friends = db.query(FriendRequest.recipient_id).filter(
        FriendRequest.requester_id == current_user.id,
        FriendRequest.status == "accepted"
    ).all()
    received_friends = db.query(FriendRequest.requester_id).filter(
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "accepted"
    ).all()
    friend_ids = set([f[0] for f in sent_friends] + [f[0] for f in received_friends])
    
    # Base query: posts with location that opted-in to Raven Shot
    query = db.query(Post).filter(
        Post.show_on_raven_shot == True,
        Post.latitude.isnot(None),
        Post.longitude.isnot(None),
        or_(Post.is_hidden == False, Post.is_hidden == None)
    )
    
    # Exclude blocked users
    if blocked_ids:
        query = query.filter(~Post.author_id.in_(blocked_ids))
    
    # Exclude hidden posts
    if hidden_post_ids:
        query = query.filter(~Post.id.in_(hidden_post_ids))
    
    # Visibility filter: public OR friends-only from actual friends OR own posts
    query = query.filter(
        or_(
            Post.visibility == 'public',
            Post.visibility == 'local',
            Post.visibility.is_(None),
            and_(Post.visibility == 'friends', Post.author_id.in_(friend_ids)),
            Post.author_id == current_user.id  # Always show own posts
        )
    )
    
    # Order by newest first, limit results
    posts = query.order_by(Post.timestamp.desc()).limit(limit).all()
    
    if not posts:
        return []
    
    # Batch load stats
    post_ids = [p.id for p in posts]
    batch_stats = get_batch_post_stats(db, post_ids, current_user.id)
    batch_media = get_batch_post_media(request, db, post_ids)
    
    result = []
    for post in posts:
        author = db.query(User).filter(User.id == post.author_id).first()
        stats = batch_stats.get(post.id, {
            "likes": 0, "comments": 0, "reposts": 0,
            "is_liked": False, "is_reposted": False,
            "like_preview_user_ids": [], "comment_preview_user_ids": []
        })
        
        result.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=build_full_url(request, author.avatar_path) if author else None,
            content=decrypt_text(post.content),
            image_url=build_full_url(request, post.image_url),
            media=batch_media.get(post.id),
            timestamp=post.timestamp,
            edited_at=post.edited_at,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            view_count=post.view_count or 0,
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"],
            visibility=post.visibility or "public",
            post_type=post.post_type,
            room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            location_name=getattr(post, 'location_name', None),
            show_on_raven_shot=True,
            latitude=post.latitude,
            longitude=post.longitude,
            **get_voice_and_collab_fields(post, db, author=author)
        ))
    
    print(f"📍 [RavenShot] Returning {len(result)} posts for map")
    return result
