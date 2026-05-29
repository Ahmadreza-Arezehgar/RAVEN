
from fastapi import APIRouter, Depends, HTTPException, status, Request, BackgroundTasks
from sqlalchemy.orm import Session
from sqlalchemy import func, or_
from pydantic import BaseModel
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
class PostMediaItem(BaseModel):
    """A single media item for a multi-media post.

    🟥 ROUND 46 (2026-05-17) — fixes the video-rendering regression.
    iOS has been sending this via the `media_items` field but the
    server's CreatePostRequest didn't define the field, so Pydantic
    silently dropped it. As a result every video in a multi-media
    post was lost (only the URLs in `image_urls` survived, and iOS
    pre-filters that list to image-only). Defining the schema
    surface here lets the server read the explicit per-item type
    and write PostMedia rows with `media_type='video'` when iOS
    says so — no more relying on URL-extension sniffing which
    fails for GCS signed URLs whose extension is hidden behind
    query parameters.
    """
    url: str
    media_type: Optional[str] = "image"   # "image" | "video"
    thumbnail_url: Optional[str] = None    # Required for videos (poster frame)

class CreatePostRequest(BaseModel):
    content: str
    image_url: Optional[str] = None  # Legacy single image (backward compat)
    image_urls: Optional[List[str]] = None  # Multi-image support (max 4)
    # 🟥 ROUND 46 (2026-05-17) — mixed media with explicit type.
    # iOS sends this with one entry per attached photo OR video,
    # carrying `media_type` so videos no longer have to be sniffed
    # from a URL extension that may be missing (GCS signed URLs).
    # When present, the create_post handler iterates THIS list and
    # ignores `image_urls` for media-row creation — the legacy
    # field is preserved only for older clients.
    media_items: Optional[List[PostMediaItem]] = None
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
    """Media item for multi-image posts."""
    id: str
    url: str
    order_index: int
    media_type: Optional[str] = "image"
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
    # 🔴 BUG FIX (2026-05-21) — comment-count vs comment-list mismatch.
    # The comment LIST endpoint (`comments.py::get_post_comments`)
    # filters `is_hidden != True`, but this COUNT did not — so a post
    # with a single hidden comment showed "1 comment" while the
    # comment sheet rendered empty ("the app says there's a comment
    # but shows nothing"). Filter `is_hidden` here too so the count
    # matches exactly what the list returns.
    comments = db.query(Comment).filter(
        Comment.post_id == post_id,
        Comment.is_hidden != True
    ).count()
    
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
    
    return {
        "likes": likes,
        "comments": comments,
        "reposts": reposts,
        "is_liked": is_liked,
        "is_reposted": is_reposted
    }


# 🟥 ROUND 45 (2026-05-17) — multi-media + video rendering fix.
#
# Bug: every feed endpoint (search, /feed, /feed/local, /feed/friends,
# post-detail, share-detail) built `PostResponse` WITHOUT setting the
# `media=[...]` field.  Result on iOS:
#   • Multi-image posts collapsed to a single image (only legacy
#     `image_url` came through).
#   • Videos lost their `media_type='video'` flag and rendered as
#     images (PostMedia.isVideo fell back to URL extension sniff
#     which fails when GCS URLs omit the extension).
#
# Fix: helper that bulk-loads PostMedia rows for a batch of post IDs
# and returns a `{post_id: [PostMediaResponse]}` map.  Each feed
# handler calls this once, then passes the right list into each
# PostResponse it builds.  Single SQL query for N posts (not N+1).
#
# media_type is preserved as-stored in DB.  Server still hardcodes
# 'image' on /api/posts upload (line ~638) — that's a separate
# fix (server needs to sniff URL extension and set 'video' when
# appropriate).  But for existing posts whose `media_type` was set
# correctly at some point, this restores them.
from models import PostMedia as _PostMediaModel

# ════════════════════════════════════════════════════════════════════
# 🟥 ROUND 51 (2026-05-17) — GCS signed-URL refresh on read.
#
# Bug: existing video / multi-media posts go DEAD ~15 minutes after
# upload.  Reason: `_upload_to_gcs` stores a V4-signed URL with a
# 15-minute TTL into `post_media.url` and `posts.image_url` (round-26
# hardening — no eternal-public-read URLs in DB dumps).  iOS just
# uses the URL as returned by /feed; once expired GCS returns 403.
# iOS has no re-sign fallback (no calls to /api/uploads/sign-read in
# the swift codebase).
#
# Fix: on every feed read, swap any stored signed URL for a FRESH
# 1-hour signed URL.  Cheap (no DB write, just `blob.generate_signed_url`
# locally), transparent, and bounded — 1 hour TTL gives slow-network
# clients enough time to download without re-fetching the feed.
#
# Pre-condition for prod: the Cloud Run service account must have
# `roles/iam.serviceAccountTokenCreator` (same IAM grant that
# _upload_to_gcs documents — both share the same signing path).
# Without it, signing falls back to the unsigned legacy URL, which
# only works if the bucket is public-read.
# ════════════════════════════════════════════════════════════════════
from typing import Optional as _Optional


def _refresh_signed_url(url: _Optional[str]) -> _Optional[str]:
    """Re-sign a GCS-stored URL with a fresh 1-hour TTL, OR nullify
    legacy dead URLs.

    Pass through:
      • None / empty
      • GCS URLs we can't parse (returns original)
      • Third-party CDN / live legacy paths (returns original)

    Returns:
      • A NEW signed URL on success
      • `None` when the URL points to the now-defunct legacy Cloud
        Run host whose files were lost in the GCS migration (so iOS
        renders the post as text-only instead of a broken thumbnail).
      • The original URL on any unhandled error.
    """
    if not url:
        return url

    # 🟥 ROUND 53 (2026-05-17) — nullify legacy dead URLs.
    #
    # Discovery: a user reported "old multi-media + video posts
    # don't load". Tracing the actual URLs returned by /api/posts/user
    # showed every legacy media post points to:
    #   http://hybrid-messenger-api-516053629173.us-central1.run.app/uploads/...
    #
    # That host is the OLD pre-GCS Cloud Run service in us-central1.
    # It returns 404 on every probe (deleted/expired). The files
    # were never copied into the `raven-media-uploads` GCS bucket
    # (verified — every UUID grep returns "matched no objects").
    # The files are GONE.
    #
    # Behaviour without this guard: iOS receives the dead URL, tries
    # to load it, rejects the `http://` scheme outright (round-25
    # hardening), and the post renders with a broken-image placeholder
    # box and no text — the user-reported "empty box" symptom.
    #
    # Fix: return None for any URL matching the dead-host pattern.
    # `_load_media_map_for_posts` falls back to `media.url` when the
    # re-sign returns None, so we need an explicit sentinel — return
    # None and the caller drops the row from the response.
    DEAD_LEGACY_HOSTS = (
        "hybrid-messenger-api-516053629173.us-central1.run.app",
        # Add more legacy hosts here if they're discovered.
    )
    for dead in DEAD_LEGACY_HOSTS:
        if dead in url:
            print(f"☠️ [SignRefresh] DEAD-LEGACY URL nullified — file lost in GCS migration: {url[:100]}")
            return None

    # Identify GCS storage URLs by the canonical host. We handle both
    # the legacy `https://storage.googleapis.com/{bucket}/{path}` form
    # AND already-signed URLs (which have the same host + query
    # params). Either way we re-extract the object path and re-sign.
    needle = "storage.googleapis.com/"
    if needle not in url:
        return url

    try:
        from urllib.parse import urlparse
        parsed = urlparse(url)
        # parsed.path is `/{bucket}/{object_path}` (signed URLs use
        # the same path shape as unsigned). Strip the leading "/" +
        # bucket prefix.
        path = parsed.path.lstrip("/")
        # First path segment is the bucket name (the URL form
        # `https://storage.googleapis.com/{bucket}/{object_path}`).
        if "/" not in path:
            return url
        bucket_name, object_path = path.split("/", 1)
        if not object_path:
            return url

        # Re-sign via the existing GCS helper. Importing here so the
        # feed handlers don't pay the import cost on every call when
        # GCS isn't configured.
        from routers.uploads import _get_gcs_bucket
        bucket = _get_gcs_bucket()
        if bucket is None:
            return url  # dev mode — no GCS, leave URL alone
        # If the bucket in the URL differs from our configured bucket,
        # don't touch it (cross-bucket asset; out of our control).
        if bucket.name != bucket_name:
            return url

        from datetime import timedelta as _td
        blob = bucket.blob(object_path)
        # 🔴 ROUND 31 (2026-05-18) — Cloud Run signing fix.
        # Same root cause as the upload-side bug: metadata-server
        # credentials have no private key, so the default sign call
        # raises "you need a private key to sign credentials". This
        # caused EVERY feed refresh to log a stack trace and serve
        # the stored URL as-is — which is fine the first time but
        # 403s after the original 15-min TTL expires. End result for
        # the user: old image/video posts that "load the first time
        # but break later". Use the IAM signBlob path via
        # `_get_signing_credentials` so signing works without a key.
        from routers.uploads import _get_signing_credentials
        sa_email, access_token = _get_signing_credentials()
        sign_kwargs = {
            "version": "v4",
            "expiration": _td(hours=1),
            "method": "GET",
        }
        if sa_email and access_token:
            sign_kwargs["service_account_email"] = sa_email
            sign_kwargs["access_token"] = access_token
        signed = blob.generate_signed_url(**sign_kwargs)
        return signed
    except Exception as e:
        # Never break the feed because of signing edge cases. Log
        # and return original URL — iOS will show an expired-URL
        # broken thumbnail, same as before R51.
        print(f"⚠️ [SignRefresh] could not re-sign url, returning as-is: {type(e).__name__}: {e}")
        return url


def _load_media_map_for_posts(db: Session, request: Request, post_ids: list) -> dict:
    """Bulk-load PostMedia for a list of post IDs.

    Returns dict mapping post_id -> sorted-by-order [PostMediaResponse].
    Posts with no media are absent from the map (caller treats as None).

    🟥 ROUND 51: re-signs the GCS URL for each media item so feeds
    never serve stale (expired) signed URLs. Without this every
    existing video/image post goes 403 after 15 minutes.
    """
    if not post_ids:
        return {}
    rows = db.query(_PostMediaModel).filter(
        _PostMediaModel.post_id.in_(post_ids)
    ).order_by(_PostMediaModel.post_id, _PostMediaModel.order_index).all()

    grouped: dict = {}
    for media in rows:
        # Re-sign before building the absolute URL. _refresh_signed_url
        # only touches GCS URLs; local-dev paths fall through unchanged
        # and `build_full_url` adds the Cloud Run host prefix.
        #
        # 🟥 ROUND 53 (2026-05-17) — when the URL points to the dead
        # legacy host (file lost in GCS migration), `_refresh_signed_url`
        # returns None on purpose. DROP the media row entirely rather
        # than serve a known-bad URL — the post then renders as
        # text-only on iOS, which is a far cleaner UX than a broken
        # thumbnail with an empty box.
        fresh_url = _refresh_signed_url(media.url)
        if fresh_url is None:
            continue
        grouped.setdefault(media.post_id, []).append(
            PostMediaResponse(
                id=media.id,
                url=build_full_url(request, fresh_url),
                order_index=media.order_index,
                # Preserve media_type as stored.  Defaults to 'image'
                # on the model side if NULL, but we pass it through
                # so videos correctly surface 'video' when set.
                media_type=media.media_type or "image",
                top_comments=None,  # top_comments are per-media + expensive;
                                    # the dedicated per-post helper handles
                                    # post-detail loads.  Feed cards don't
                                    # render them.
            )
        )
    return grouped


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
    # 🔴 BUG FIX (2026-05-21) — must filter `is_hidden != True` so the
    # feed's per-post comment count matches the comment-list endpoint
    # (which excludes hidden comments). Without this the post card
    # shows "N comments" but the comment sheet renders fewer.
    comments_rows = db.query(
        Comment.post_id, func.count(Comment.id)
    ).filter(
        Comment.post_id.in_(post_ids),
        Comment.is_hidden != True
    ).group_by(Comment.post_id).all()
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
    
    # 6. Preview liker IDs (max 20 per post, most recent first)
    liker_preview_rows = db.query(PostLike.post_id, PostLike.user_id).filter(
        PostLike.post_id.in_(post_ids)
    ).order_by(PostLike.timestamp.desc()).all()
    liker_map = {}
    for pid, uid in liker_preview_rows:
        liker_map.setdefault(pid, [])
        if len(liker_map[pid]) < 20:
            liker_map[pid].append(uid)
    
    # 7. Preview commenter IDs (max 20 per post, most recent first)
    commenter_preview_rows = db.query(Comment.post_id, Comment.author_id).filter(
        Comment.post_id.in_(post_ids)
    ).order_by(Comment.timestamp.desc()).all()
    commenter_map = {}
    for pid, uid in commenter_preview_rows:
        commenter_map.setdefault(pid, [])
        if len(commenter_map[pid]) < 20 and uid not in commenter_map[pid]:
            commenter_map[pid].append(uid)
    
    # Build result map
    result = {}
    for pid in post_ids:
        result[pid] = {
            "likes": likes_map.get(pid, 0),
            "comments": comments_map.get(pid, 0),
            "reposts": reposts_map.get(pid, 0),
            "is_liked": pid in liked_ids,
            "is_reposted": pid in reposted_ids,
            "like_preview_user_ids": liker_map.get(pid, []),
            "comment_preview_user_ids": commenter_map.get(pid, []),
        }
    return result


def get_voice_and_collab_fields(post, db=None, author=None) -> dict:
    """Extract voice post and collaborative post fields from a Post model.

    🟥 ROUND 51 — re-sign voice_url so expired GCS signed URLs get
    refreshed on every feed read. See `_refresh_signed_url` doc.
    """
    fields = {
        "voice_url": _refresh_signed_url(getattr(post, 'voice_url', None)),
        "voice_duration": getattr(post, 'voice_duration', None),
        "waveform": None,
        "co_authors": None,
        "co_author_usernames": None,
        "origin_chain_id": getattr(post, 'origin_chain_id', None),
        "is_verified": (author.is_verified or False) if author else False,
        "is_premium": (author.is_premium or False) if author else False,
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
    return fields


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
    
    search_query = db.query(Post).filter(Post.visibility.in_(['public', 'local', None]), Post.is_hidden != True)
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
                image_url=build_full_url(request, _refresh_signed_url(post.image_url)),
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
def create_post(
    request: Request,
    req: CreatePostRequest,
    background_tasks: BackgroundTasks,
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
                image_url=build_full_url(request, _refresh_signed_url(existing.image_url)),
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
    
    # 🔴 hacker-audit 2026-05-19 — mesh post author-spoof close.
    #
    # PREVIOUSLY: any client could POST {mesh_origin: true,
    # author_id: <victim>, content: "..."} and the server stored
    # the post with `author_id = victim`. The optional fields
    # `mesh_signature` / `mesh_signer_key` (below) were ACCEPTED
    # and stored unchanged but NEVER verified server-side — so a
    # forged sig or no sig at all both passed. This is the same
    # bridge-spoof pattern messages.py had (round 26) and that
    # we hardened in the round-1 audit. Concrete attack:
    #   1. Attacker creates account A.
    #   2. POST /api/posts/create with mesh_origin=true,
    #      author_id="<celebrity user_id>", content="endorsement".
    #   3. Server stores post as celebrity's; mesh_origin badge in
    #      the iOS UI is the LESS-SUSPICIOUS variant ("verified
    #      offline-mesh post") — anti-trust signal flipped.
    #
    # FIX: a mesh-origin upload claiming a different author MUST
    # carry an Ed25519 signature from the claimed author's identity
    # key, verified server-side against `content`. If missing or
    # invalid, fall back to `author_id = current_user.id` and
    # ignore the mesh_origin flag. Bridges that legitimately
    # forward signed mesh posts are unaffected; spoofers without a
    # valid sig get attributed to themselves instead of the victim.
    actual_author_id = current_user.id
    use_mesh_origin_flag = bool(req.mesh_origin)
    if req.mesh_origin and req.author_id and req.author_id != current_user.id:
        sig_ok = False
        if req.mesh_signature and req.mesh_signer_key:
            try:
                from services.mesh_crypto import verify_message_signature
                sig_ok = verify_message_signature(
                    content=req.content or "",
                    signature_b64=req.mesh_signature,
                    public_key_b64=req.mesh_signer_key,
                )
            except Exception as _e:
                sig_ok = False
                print(f"⚠️ [PostCreate] mesh sig verify crashed ({type(_e).__name__}): rejecting attribution")
        if sig_ok:
            actual_author_id = req.author_id
            print(f"🌐 [GATEWAY] Mesh post from {req.author_id[:8]} VERIFIED, uploaded by gateway {current_user.id[:8]}")
        else:
            # Attribution refused — store as the uploader's own post.
            use_mesh_origin_flag = False
            print(f"🚨 [GATEWAY] mesh_origin author spoof attempt: claimed {req.author_id[:8]} but no valid sig — attributing to gateway {current_user.id[:8]}")
    
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
        'geohash': geohash_val
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
    
    # Set mesh origin flag if from gateway bridge AND attribution
    # passed the sig check above (use_mesh_origin_flag). Otherwise
    # the post is just a normal user post that the attacker tried
    # to mis-attribute — we already attributed it to them.
    if use_mesh_origin_flag:
        post_data['mesh_origin'] = True
        # Phase 2: Store Ed25519 signature from origin device.
        # By this point sig is verified (or absent because uploader
        # is the original author).
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
    
    post = Post(**post_data)
    
    db.add(post)
    db.commit()
    db.refresh(post)
    print(f"✅ [PostCreate] COMMITTED post_id={post.id[:8]} client_request_id={crid[:8]}")
    
    # Invalidate feed caches on new post.
    # 🔴 ROUND 71 phase 3: include `feed:recommended:*` — the delete
    # path (posts.py:2247-2250) clears it but create did not, so a
    # newly-created post was hidden from the recommendation surface
    # until TTL_FEED (60s) elapsed.
    cache.invalidate("feed:global:*")
    cache.invalidate("feed:local:*")
    cache.invalidate("feed:friends:*")
    cache.invalidate("feed:recommended:*")
    
    # Create PostMedia records for multi-image posts
    # 🟥 ROUND 46 (2026-05-17) — multi-media + video FIX, part 2.
    #
    # Round 45 fixed the FEED side (returning `media=[...]` in
    # /feed responses) but left the WRITE side broken: iOS sends
    # `media_items: [{url, media_type, thumbnail_url}, ...]` but
    # the server only read `req.image_urls` (a flat URL list with
    # no per-item type info). iOS pre-filters `image_urls` to
    # images only, so:
    #   • Multi-media posts (image + video): video dropped on write.
    #   • Video-only posts: zero PostMedia rows, video URL lost.
    #
    # Now we prefer `req.media_items` (new path) and fall back to
    # `req.image_urls` for older clients. URL-extension sniffing
    # is kept as a last-resort for the legacy fallback only — GCS
    # signed URLs hide the extension behind `?X-Goog-...` query
    # params, so the only reliable signal for new clients is the
    # explicit `media_type` field the client sets when it
    # uploads.
    media_responses = []
    print(f"🔍 DEBUG create_post: req.image_urls = {req.image_urls} media_items.count={len(req.media_items) if req.media_items else 0}")

    _VIDEO_EXTS = {"mp4", "mov", "m4v", "avi", "webm", "mkv", "qt"}
    def _sniff_media_type(url: str) -> str:
        # Strip query params before checking extension.
        clean = url.split("?", 1)[0]
        ext = clean.rsplit(".", 1)[-1].lower() if "." in clean else ""
        return "video" if ext in _VIDEO_EXTS else "image"

    from models import PostMedia
    import uuid as uuid_mod
    max_media = 10 if current_user.is_premium else 4  # RAVEN+: 10, Free: 4

    # PREFER `media_items` (Round 46 path) over `image_urls` (legacy).
    # iOS clients on app version >= R46 always send media_items;
    # older clients still send image_urls and nothing else.
    if req.media_items and len(req.media_items) > 0:
        for idx, item in enumerate(req.media_items[:max_media]):
            url = item.url
            if not url:
                continue
            # Trust the client's explicit type; fall back to sniff
            # only when the field is missing/empty.
            media_type = item.media_type or _sniff_media_type(url)
            if media_type not in {"image", "video"}:
                media_type = "image"   # defensive
            media_id = str(uuid_mod.uuid4())
            media = PostMedia(
                id=media_id,
                post_id=post.id,
                url=url,
                order_index=idx,
                media_type=media_type
            )
            db.add(media)
            media_responses.append(PostMediaResponse(
                id=media_id,
                url=build_full_url(request, url),
                order_index=idx,
                media_type=media_type,
                top_comments=None
            ))
        db.commit()
        print(f"🖼️ [Round46] Created {len(media_responses)} PostMedia rows from media_items for post {post.id[:8]}")
    elif req.image_urls and len(req.image_urls) > 0:
        # Legacy path (older iOS / Android / Mac clients without
        # the media_items field). Sniff URL extension for type.
        for idx, url in enumerate(req.image_urls[:max_media]):
            media_id = str(uuid_mod.uuid4())
            sniffed_type = _sniff_media_type(url)
            media = PostMedia(
                id=media_id,
                post_id=post.id,
                url=url,
                order_index=idx,
                media_type=sniffed_type
            )
            db.add(media)
            media_responses.append(PostMediaResponse(
                id=media_id,
                url=build_full_url(request, url),
                order_index=idx,
                media_type=sniffed_type,
                top_comments=None
            ))
        db.commit()
        print(f"🖼️ [Legacy] Created {len(media_responses)} PostMedia rows from image_urls for post {post.id[:8]}")
    
    content_preview = req.content[:50] if req.content else "(image only)"
    print(f"📝 Post created by {current_user.username}: {content_preview}... [visibility={req.visibility}]")
    
    # 🔔 Notify post subscribers (push + in-app)
    from models import PostSubscription, Notification
    subscribers = db.query(PostSubscription).filter(
        PostSubscription.target_id == current_user.id,
        PostSubscription.enabled == True
    ).all()
    
    if subscribers:
        from services.apns_service import get_apns_service, APNsService
        import asyncio
        apns = get_apns_service()
        
        author_name = APNsService.build_push_display_name(current_user)
        post_preview = req.content[:100] if req.content else "(image)"
        
        for sub in subscribers:
            # Create in-app notification
            notif_data = json.dumps({
                "postId": post.id,
                "authorId": current_user.id,
                "authorUsername": current_user.username,
                "postPreview": post_preview
            })
            notification = Notification(
                user_id=sub.subscriber_id,
                type="new_post",
                data=notif_data,
                is_read=False
            )
            db.add(notification)
            
            # Send push to subscriber (with preference check)
            subscriber_user = db.query(User).filter(User.id == sub.subscriber_id).first()
            if subscriber_user and subscriber_user.push_token and subscriber_user.push_platform == "ios":
                prefs = APNsService.should_send_push(subscriber_user, "new_post")
                if prefs["allowed"]:
                    # 🔴 BUG FIX (2026-05-20) — was `asyncio.ensure_future(...)`
                    # which crashed with `RuntimeError: no current event
                    # loop in thread 'AnyIO worker thread'` on every
                    # subscriber push. `create_post` is a SYNC endpoint
                    # → FastAPI runs it in a threadpool worker → those
                    # workers have no asyncio loop attached → ensure_future
                    # raised. The whole endpoint returned HTTP 500
                    # AFTER the post was already committed, so iOS saw
                    # a "failed" post (and any uploaded image went
                    # orphan in GCS, presenting as "media not loading").
                    # FastAPI's BackgroundTasks safely schedules the
                    # coroutine after the response is sent and is
                    # thread-aware. Same behavior, no crash.
                    background_tasks.add_task(
                        apns.send_new_post_notification,
                        device_token=subscriber_user.push_token,
                        author_name=author_name,
                        post_preview=post_preview,
                        post_id=post.id,
                        author_id=current_user.id,
                    )
                else:
                    print(f"📱 ⏭️ New post push skipped for {subscriber_user.username} (disabled)")
        
        db.commit()
        print(f"🔔 Notified {len(subscribers)} post subscribers for @{current_user.username}")
    
    
    # For mesh gateway uploads, resolve the actual author (may differ from current_user)
    if actual_author_id != current_user.id:
        actual_author = db.query(User).filter(User.id == actual_author_id).first()
        resp_username = actual_author.username if actual_author else (req.author_username or "Unknown")
        resp_avatar = build_full_url(request, actual_author.avatar_path) if actual_author else None
    else:
        resp_username = current_user.username
        resp_avatar = build_full_url(request, current_user.avatar_path)
    
    return PostResponse(
        id=post.id,
        author_id=post.author_id,
        author_username=resp_username,
        author_avatar=resp_avatar,
        content=decrypt_text(post.content),
        image_url=build_full_url(request, _refresh_signed_url(post.image_url)),
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
        **get_voice_and_collab_fields(post, db, author=current_user)
    )

@router.get("/feed", response_model=List[PostResponse])
def get_feed(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
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
        Post.is_hidden != True,
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
    
    # Batch-load authors and stats (eliminates N+1)
    post_ids = [p.id for p in posts]
    author_ids = list(set(p.author_id for p in posts))
    authors_map = {u.id: u for u in db.query(User).filter(User.id.in_(author_ids)).all()} if author_ids else {}
    stats_map = get_batch_post_stats(db, post_ids, current_user.id)
    media_map = _load_media_map_for_posts(db, request, post_ids)  # Round 45

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
            image_url=build_full_url(request, _refresh_signed_url(post.image_url)),
            media=media_map.get(post.id),  # Round 45 — multi-media + video
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
            like_preview_user_ids=stats.get("like_preview_user_ids", []),
            comment_preview_user_ids=stats.get("comment_preview_user_ids", []),
                **get_voice_and_collab_fields(post, db, author=author)
        ))

    # Cache result
    cache.set(cache_key, [r.dict() for r in result], ttl=TTL_FEED)

    return result


# ==================== LOCAL FEED (Interest-Based Algorithm) ====================
@router.get("/feed/local")
def get_local_feed(
    request: Request,
    lat: float = None,
    lng: float = None,
    radius_m: int = 5000,  # Default 5km radius
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
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
        Post.is_hidden != True,
        Post.timestamp > seven_days_ago
    )
    # Exclude blocked users
    if blocked_ids:
        query = query.filter(~Post.author_id.in_(blocked_ids))
    # Exclude hidden posts
    if hidden_post_ids:
        query = query.filter(~Post.id.in_(hidden_post_ids))
    
    # Cursor-based pagination (preferred) — avoids slow OFFSET scans
    if cursor:
        try:
            cursor_dt = datetime.fromisoformat(cursor)
            query = query.filter(Post.timestamp < cursor_dt)
        except ValueError:
            pass

    # 🔴 BUG FIX (2026-05-16): SQLAlchemy requires `.order_by()` to
    # come BEFORE `.limit()` / `.offset()` — chaining them in the
    # other order throws InvalidRequestError("Query.order_by() being
    # called on a Query which already has LIMIT or OFFSET applied")
    # at runtime. The previous version called `.offset()` in the
    # non-cursor branch above and then `.order_by(...).limit(...)`
    # below, which 500'd every offset-paginated request to
    # /api/posts/feed/local (including the iOS Local tab's initial
    # fetch). Apply order_by first, then offset/limit.
    query = query.order_by(Post.timestamp.desc())
    if not cursor:
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
    # Round 45: bulk-load PostMedia so feed cards render multi-image
    # albums + videos correctly (was: only legacy image_url, which
    # collapsed multi-media to a single image and erased video
    # mediaType info).
    media_map = _load_media_map_for_posts(db, request, post_ids)

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
                image_url=build_full_url(request, _refresh_signed_url(post.image_url)),
                media=media_map.get(post.id),  # Round 45 — multi-media + video
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
    limit: int = 50,
    offset: int = 0,
    cursor: Optional[str] = None
):
    """
    Get FRIENDS feed - posts from accepted friends.
    - Shows ONLY friends-visibility posts (not public)
    - Only from users who are accepted friends (mutual)
    - Ordered by timestamp DESC
    """
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
    
    # NOTE: Single-use content exclusion DISABLED
    # Posts now remain visible even after being viewed
    # To re-enable single-use content, uncomment the consumed_ids filter below
    # 
    # consumed_ids = db.query(ContentConsumption.content_id).filter(
    #     ContentConsumption.user_id == current_user.id,
    #     ContentConsumption.content_type == 'post'
    # ).subquery()
    
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
    
    query = db.query(Post).filter(
        Post.author_id.in_(friend_ids),
        Post.is_hidden != True,
        Post.visibility == 'friends'
    )
    if hidden_post_ids:
        query = query.filter(~Post.id.in_(hidden_post_ids))
    
    # Cursor-based pagination (preferred)
    if cursor:
        try:
            cursor_dt = datetime.fromisoformat(cursor)
            query = query.filter(Post.timestamp < cursor_dt)
        except ValueError:
            pass

    # 🔴 ROUND 26 (2026-05-16) — REAL ROOT-CAUSE FIX.
    #   Bug discovered via live test: `/api/posts/feed/friends`
    #   threw `sqlalchemy.exc.InvalidRequestError: Query.order_by()
    #   being called on a Query which already has LIMIT or OFFSET
    #   applied`. The original code called `.offset(offset)` in the
    #   else-branch above BEFORE `.order_by()` / `.limit()` on the
    #   line below, which SQLAlchemy refuses (because mixing
    #   order_by after offset/limit produces semantically-undefined
    #   results in the SQL spec).
    #
    #   This was EXACTLY the same bug that hit `feed/local` in an
    #   earlier round — fixed there by reordering, but the same
    #   pattern existed verbatim in `feed/friends` and went
    #   unnoticed until live-testing exposed it as 500s on the
    #   user's friends-only feed.
    #
    #   FIX: always order BEFORE applying offset/limit. The
    #   cursor-filter branch is a Post.timestamp filter so it's
    #   safe to apply in either order, but for clarity we keep
    #   it above the order_by call.
    query = query.order_by(Post.timestamp.desc())
    if not cursor:
        query = query.offset(offset)
    posts = query.limit(limit).all()

    # Batch-load authors and stats (eliminates N+1)
    post_ids = [p.id for p in posts]
    author_ids = list(set(p.author_id for p in posts))
    authors_map = {u.id: u for u in db.query(User).filter(User.id.in_(author_ids)).all()} if author_ids else {}
    stats_map = get_batch_post_stats(db, post_ids, current_user.id)
    media_map = _load_media_map_for_posts(db, request, post_ids)  # Round 45

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
            image_url=build_full_url(request, _refresh_signed_url(post.image_url)),
            media=media_map.get(post.id),  # Round 45 — multi-media + video
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
            like_preview_user_ids=stats.get("like_preview_user_ids", []),
            comment_preview_user_ids=stats.get("comment_preview_user_ids", []),
                **get_voice_and_collab_fields(post, db, author=author)
        ))

    has_more = len(result) == limit  # If we got exactly limit posts, there are likely more
    next_offset = offset + len(result)
    
    print(f"👥 Friends feed for {current_user.username}: {len(result)} posts from {len(friend_ids)} friends (offset={offset}, hasMore={has_more})")
    response = PaginatedFeedResponse(items=result, hasMore=has_more, nextOffset=next_offset)
    cache.set(cache_key, response.dict(), ttl=TTL_FEED)
    return response


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

    # 🔴 ROUND 70 — gate likes on visibility. Previously a non-friend
    # could like a friends-only post and the like-notification would
    # be pushed to the author, leaking that the non-friend reached
    # the post (existence oracle + privacy break).
    if not _can_user_access_post(post, current_user.id, db):
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
                # 🔵 (2026-05-23) — Instagram-style notification row
                # needs the liker's avatar (row leading-edge) and the
                # post's thumbnail (row trailing-edge). Carry both in
                # the notification data so iOS doesn't have to make
                # extra round-trips when rendering the list.
                data=json.dumps({
                    "post_id": post_id,
                    "liker_id": current_user.id,
                    "liker_username": current_user.username,
                    "liker_avatar": current_user.avatar_path,
                    "post_image_url": post.image_url,
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

    # 🔴 ROUND 70 — gate reposts on visibility. Reposting a friends-
    # only post broadcasts it to the reposter's own feed surface,
    # bypassing the author's friend-only intent entirely.
    if not _can_user_access_post(post, current_user.id, db):
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

    # 🔴 ROUND 70 — gate view records on visibility. Non-friends
    # incrementing the view count on a friends-only post was a
    # cheap "this post exists" oracle + skewed analytics.
    if not _can_user_access_post(post, current_user.id, db):
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
    """Get all posts by a specific user.

    🔴 ROUND 70 (2026-05-23) — hacker-audit POSTS-IDOR-CRIT-1
    (CRITICAL: visibility filter was missing → friends-only posts
    returned to anyone who hit this endpoint with a userId).

    Visibility rules enforced now:
      • author viewing their own posts → return all (incl. private)
      • visibility='public' → anyone
      • visibility='local' → anyone (local-feed posts are geo-bounded
        at fetch time elsewhere; this endpoint shows the author's
        timeline which always includes their local posts)
      • visibility='friends' → only mutual friends (FriendRequest
        accepted in either direction)
      • visibility='private' → only the author
      • visibility NULL/unset → treat as 'public' (legacy posts)
    """
    from sqlalchemy import or_, and_
    from models import FriendRequest, Block

    is_self = (user_id == current_user.id)
    # Determine friend status once per request (cheaper than per-row).
    is_friend = False
    if not is_self:
        is_friend = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(
                and_(FriendRequest.requester_id == current_user.id,
                     FriendRequest.recipient_id == user_id),
                and_(FriendRequest.requester_id == user_id,
                     FriendRequest.recipient_id == current_user.id),
            )
        ).first() is not None

        # 🔴 ROUND 71 S6: bidirectional block exclusion. A blocked
        # author's profile feed must return empty to the blockee, and
        # vice versa.
        blocked = db.query(Block).filter(
            or_(
                and_(Block.blocker_id == current_user.id, Block.blocked_id == user_id),
                and_(Block.blocker_id == user_id, Block.blocked_id == current_user.id),
            )
        ).first()
        if blocked is not None:
            return []

        # 🔴 ROUND 71 S6: gate by author's `is_private` flag. Round-70
        # added per-post visibility filtering but ignored the
        # account-level privacy bit. A private user's posts with
        # `visibility IN (NULL,'public','local')` still leaked to
        # non-friends.
        author_row = db.query(User).filter(User.id == user_id).first()
        if author_row is None:
            raise HTTPException(status_code=404, detail="User not found")
        if bool(getattr(author_row, "is_private", False)) and not is_friend:
            return []

    if is_self:
        # Author sees everything (incl. private drafts).
        visibility_filter = True  # noqa: E712 — pass-through
    elif is_friend:
        # Friends see public + local + friends; never private.
        visibility_filter = or_(
            Post.visibility.is_(None),
            Post.visibility == "public",
            Post.visibility == "local",
            Post.visibility == "friends",
        )
    else:
        # Strangers see public + local only.
        visibility_filter = or_(
            Post.visibility.is_(None),
            Post.visibility == "public",
            Post.visibility == "local",
        )

    posts_query = db.query(Post).filter(
        Post.author_id == user_id,
        Post.is_hidden != True,
    )
    if visibility_filter is not True:
        posts_query = posts_query.filter(visibility_filter)
    posts = posts_query.order_by(Post.timestamp.desc()).limit(limit).all()
    
    author = db.query(User).filter(User.id == user_id).first()
    
    result = []
    for post in posts:
        stats = get_post_stats(db, post.id, current_user.id)
        
        result.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=build_full_url(request, author.avatar_path) if author else None,
            content=decrypt_text(post.content),
            image_url=build_full_url(request, _refresh_signed_url(post.image_url)),
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
        ))
    
    return result


@router.get("/{post_id}", response_model=PostResponse)
def get_post(
    request: Request,
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get a single post by ID.

    🔴 hacker-audit 2026-05-19 — sibling fix to ai.py and /transcribe.
    PREVIOUSLY this endpoint returned `decrypt_text(post.content)` for
    ANY post_id, regardless of visibility. Friends-only and (any
    future) private posts were directly readable by anyone who knew
    the UUID. UUIDs leak through groups, mentions, share links, error
    logs, the mesh-receipt path, and (historically) pre-round-26 mesh
    envelopes which embedded media URLs alongside the post id. The
    `/feed/friends` endpoint correctly scopes results to the caller's
    friend graph, but this single-post lookup bypassed all of that.
    Now we gate on the same `_can_user_access_post` helper that
    `/transcribe` and `/api/ai/ask` (also fixed) use, so visibility
    semantics stay identical across the three reader paths.
    """
    post = db.query(Post).filter(Post.id == post_id).first()

    if not post or post.is_hidden:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )

    if not _can_user_access_post(post, current_user.id, db):
        # 404 (not 403) so an attacker fishing for UUIDs can't
        # distinguish "exists but private" from "doesn't exist".
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found",
        )

    author = db.query(User).filter(User.id == post.author_id).first()
    stats = get_post_stats(db, post.id, current_user.id)
    
    return PostResponse(
        id=post.id,
        author_id=post.author_id,
        author_username=author.username if author else "Unknown",
        author_avatar=build_full_url(request, author.avatar_path) if author else None,
        content=decrypt_text(post.content),
        image_url=build_full_url(request, _refresh_signed_url(post.image_url)),
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
        image_url=build_full_url(request, _refresh_signed_url(post.image_url)),
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
        from models import PostMedia, CommentVote, SeenPost, Mention, UserEvent, PostBookmark, Notification

        # 🔴 ROUND 71 S5: snapshot every media URL before delete so we
        # can purge the GCS blobs afterwards. Previously the DB row +
        # PostMedia rows vanished but the underlying blobs persisted
        # forever in `raven-media-uploads`. Defeated the round-26
        # ephemerality intent.
        media_urls: list[str] = []
        if post.image_url:
            media_urls.append(post.image_url)
        if post.voice_url:
            media_urls.append(post.voice_url)
        for pm in db.query(PostMedia).filter(PostMedia.post_id == post_id).all():
            if pm.url:
                media_urls.append(pm.url)
            # Some PostMedia rows carry a separate thumbnail URL.
            tn = getattr(pm, "thumbnail_url", None)
            if tn:
                media_urls.append(tn)

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

        # 🔴 ROUND 71 FIX-UP: PostBookmark + Notification cascades.
        # PostBookmark has no DB-level cascade on its post_id FK, so
        # the `db.delete(post)` below would raise IntegrityError on
        # Postgres when ANY user had bookmarked the deleted post.
        # Also drop notification rows that reference this post via
        # the JSON `data.post_id` field so users don't tap a 404
        # ghost notification.
        db.query(PostBookmark).filter(PostBookmark.post_id == post_id).delete(synchronize_session=False)
        # Notification.data is a JSON string; subscriber notifications
        # (posts.py:1040) write `"postId"` (camelCase), while the
        # rest of the codebase writes `"post_id"`. Match both keys
        # so deleting a post wipes ghost notifications from every
        # producer. SQLite + Postgres both handle these LIKEs.
        _post_id_snake = f'%"post_id":%"{post_id}"%'
        _post_id_camel = f'%"postId":%"{post_id}"%'
        db.query(Notification).filter(
            or_(
                Notification.data.like(_post_id_snake),
                Notification.data.like(_post_id_camel),
            )
        ).delete(synchronize_session=False)

        # 6. Delete the post (Comments + PostMedia cascade via ORM relationship)
        db.delete(post)
        db.commit()

        # 🔴 ROUND 71 S5: best-effort GCS blob purge AFTER DB commit.
        # Per-blob failures swallowed so one bad path doesn't block
        # others. Same parsing logic as `_purge_expired_for_user`.
        if media_urls:
            try:
                from routers.uploads import _get_gcs_bucket
                bucket = _get_gcs_bucket()
                if bucket is not None:
                    for url in media_urls:
                        try:
                            object_path = None
                            if url.startswith("http"):
                                base = url.split("?", 1)[0]
                                marker = f"/{bucket.name}/"
                                idx = base.find(marker)
                                if idx >= 0:
                                    object_path = base[idx + len(marker):]
                            else:
                                object_path = url.lstrip("/")
                            if object_path:
                                bucket.blob(object_path).delete()
                                print(f"🗑️ [Delete] GCS blob purged: {object_path[:60]}")
                        except Exception as e:
                            print(f"⚠️ [Delete] GCS blob purge failed for {url[:40]}: {type(e).__name__}: {e}")
            except Exception as e:
                print(f"⚠️ [Delete] GCS bucket unavailable for cleanup: {e}")

        # 🔴 ROUND 71 S5: invalidate feed caches so deleted post
        # disappears from other viewers within seconds rather than
        # waiting for TTL_FEED (30s).
        # 🔴 ROUND 71 FIX-UP: import was wrong (`services.cache` →
        # module lives at `cache.py`) and method was wrong
        # (`delete_pattern` → method is `invalidate`). The bare
        # except swallowed both errors so the invalidation was a
        # silent no-op. Fixed both per the existing usage at
        # posts.py:927-929.
        try:
            from cache import cache as _cache
            _cache.invalidate("feed:global:*")
            _cache.invalidate("feed:friends:*")
            _cache.invalidate("feed:local:*")
            _cache.invalidate("feed:recommended:*")
            _cache.invalidate(f"post:{post_id}")
        except Exception as _cache_err:
            print(f"⚠️ [Delete] feed cache invalidation failed: {_cache_err}")
        
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

        # 🔴 ROUND 71 S7: re-sign the GCS URL before handing it to
        # Gemini. The stored `voice_url` is a 1-hour signed URL minted
        # at upload time; if the user requests transcription after
        # expiry (and there's nothing stopping that — uploads can be
        # weeks old), Gemini's fetch returns 403 and the post
        # permanently flips to `failed`. `_refresh_signed_url` mints a
        # fresh 15-min URL each call.
        audio_url = _refresh_signed_url(post.voice_url) or post.voice_url
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


def _can_user_access_post(post: Post, user_id: str, db: Session) -> bool:
    """
    🔴 ROUND 26 → ROUND 70 — visibility gate for ANY per-post action.

    Authorized parties:
      • post author (always)
      • anyone, when post.visibility ∈ {None, '', 'public'}
      • anyone, when post.visibility == 'local' (geo-bounded at fetch)
      • mutual friends (accepted FriendRequest either direction)
        when post.visibility == 'friends'
      • author only, when post.visibility == 'private'

    🔴 ROUND 70 fix: the round-26 version returned False for
    visibility=='friends' even for legit friends — that broke direct-
    fetch / transcribe for friends posts entirely AND masked the
    matching IDOR in /api/posts/user/{id} (separately fixed in round 70).
    Now: query FriendRequest accepted-either-direction.
    """
    if post.author_id == user_id:
        return True
    visibility = (post.visibility or "public").lower().strip()
    if visibility in ("", "public", "local"):
        return True
    if visibility == "friends":
        from sqlalchemy import or_, and_
        from models import FriendRequest
        is_friend = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(
                and_(FriendRequest.requester_id == user_id,
                     FriendRequest.recipient_id == post.author_id),
                and_(FriendRequest.requester_id == post.author_id,
                     FriendRequest.recipient_id == user_id),
            )
        ).first() is not None
        return is_friend
    # 'private' or any unknown future value → author only.
    return False


@router.post("/{post_id}/transcribe")
async def transcribe_voice_post(
    post_id: str,
    background_tasks: _BT,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Trigger transcription for a voice post. Idempotent."""
    # 🔴 ROUND 71 S8: REORDERED to check cache + visibility BEFORE
    # check_ai_quota. Previously a free user hitting an already-ready
    # post or a non-friend post burned 1 of their 3 daily uses on a
    # request that returned cached/404. Now: existence + access +
    # cache short-circuit run first; quota is only charged for an
    # actual new Gemini job.
    post = db.query(Post).filter(Post.id == post_id).first()
    if not post:
        raise HTTPException(status_code=404, detail="Post not found")

    # 🔴 ROUND 26 — MEDIA-HIGH-10: gate on visibility/author.
    if not _can_user_access_post(post, current_user.id, db):
        # 404 hides existence from fishing attackers.
        raise HTTPException(status_code=404, detail="Post not found")

    if not post.voice_url:
        raise HTTPException(status_code=400, detail="Not a voice post")

    # Idempotent: return cached if ready (no quota charge).
    if post.transcript_status == "ready":
        return {
            "status": "ready",
            "language": post.transcript_language,
            "text": post.transcript_text
        }

    # 🔴 ROUND 71 S8: also short-circuit pending/processing BEFORE
    # quota charge — repeat polls during an in-flight job must not
    # consume daily budget.
    if post.transcript_status in ("pending", "processing"):
        return {"status": post.transcript_status}

    # ═══ Premium Rate Limit (3/day for free users, unlimited for premium) ═══
    # Only reached when this call is genuinely going to enqueue work.
    from middleware.premium_rate_limit import check_ai_quota
    check_ai_quota(current_user)

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

    # 🔴 ROUND 26 — MEDIA-HIGH-10: same gate as /transcribe — the
    # transcript content has the same sensitivity as the audio.
    if not _can_user_access_post(post, current_user.id, db):
        raise HTTPException(status_code=404, detail="Post not found")

    return {
        "status": post.transcript_status or "none",
        "language": post.transcript_language,
        "text": post.transcript_text
    }


# ═══════════════════════════════════════════════════════════════════════════
# 🔴 ROUND 26 — POST BOOKMARKS (save-for-later)
#
# iOS has been POST/DELETE-ing `/api/posts/{id}/bookmark` since release
# day but the endpoints didn't exist server-side, so every tap was
# silently 404-ing and the optimistic bookmark UI got rolled back as
# soon as the network call returned. Adding the endpoints + backing
# table (see `models.PostBookmark` + migration in `main.py`).
#
# Bookmarks are PRIVATE: counts are never returned to other users,
# bookmark events never push a notification to the post author, and
# the only listing endpoint (GET /me/bookmarks) is scoped to the
# calling user.
# ═══════════════════════════════════════════════════════════════════════════


@router.post("/{post_id}/bookmark")
def bookmark_post(
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Save a post to the caller's private bookmarks. Idempotent."""
    post = db.query(Post).filter(Post.id == post_id).first()
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )

    # 🔴 ROUND 70 — gate bookmarks on visibility. A non-friend
    # bookmarking a friends-only post would later re-fetch the post
    # via /me/bookmarks → exfiltrating the friends-only content via
    # the bookmark surface.
    if not _can_user_access_post(post, current_user.id, db):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )

    existing = db.query(PostBookmark).filter(
        PostBookmark.post_id == post_id,
        PostBookmark.user_id == current_user.id,
    ).first()
    if existing:
        return {"status": "already_bookmarked", "action": "noop", "is_bookmarked": True}

    bookmark = PostBookmark(
        post_id=post_id,
        user_id=current_user.id,
    )
    db.add(bookmark)
    db.commit()

    print(f"🔖 {current_user.username} bookmarked post {post_id[:8]}…")
    return {"status": "ok", "action": "bookmarked", "is_bookmarked": True}


@router.delete("/{post_id}/bookmark")
def unbookmark_post(
    post_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Remove a bookmark. Idempotent — missing row returns success too."""
    bookmark = db.query(PostBookmark).filter(
        PostBookmark.post_id == post_id,
        PostBookmark.user_id == current_user.id,
    ).first()

    if bookmark:
        db.delete(bookmark)
        db.commit()
        print(f"🔖 {current_user.username} unbookmarked post {post_id[:8]}…")
        return {"status": "ok", "action": "unbookmarked", "is_bookmarked": False}

    return {"status": "not_bookmarked", "action": "noop", "is_bookmarked": False}


@router.get("/me/bookmarks")
def list_my_bookmarks(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
    offset: int = 0,
):
    """Return the caller's bookmarked posts, newest first."""
    rows = db.query(PostBookmark).filter(
        PostBookmark.user_id == current_user.id
    ).order_by(PostBookmark.timestamp.desc()).offset(offset).limit(limit).all()

    return {
        "bookmarks": [
            {"post_id": r.post_id, "saved_at": r.timestamp.isoformat()}
            for r in rows
        ],
        "total": db.query(PostBookmark).filter(
            PostBookmark.user_id == current_user.id
        ).count(),
    }
