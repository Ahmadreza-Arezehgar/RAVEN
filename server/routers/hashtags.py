"""
Hashtag Router

Endpoints for hashtag discovery, following, and search.
"""
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session
from sqlalchemy import func, or_
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime, timedelta
import re

from database import get_db
from models import User, Post, HashtagFollow
from routers.users import get_current_user
from routers.posts import PostResponse, get_post_stats, build_full_url, get_voice_and_collab_fields
from encryption import decrypt_text

router = APIRouter(prefix="/api/hashtags", tags=["hashtags"])


# ==================== Schemas ====================

class HashtagFollowRequest(BaseModel):
    hashtag: str  # Can include or exclude #


class HashtagInfo(BaseModel):
    hashtag: str
    post_count: int
    is_following: bool


class TrendingHashtag(BaseModel):
    hashtag: str
    post_count: int
    recent_posts: int  # Posts in last 24h


# ==================== Helper Functions ====================

def normalize_hashtag(tag: str) -> str:
    """Normalize hashtag: lowercase, remove # prefix."""
    return tag.lower().lstrip('#').strip()


def extract_hashtags_from_post(post: Post) -> List[str]:
    """Extract hashtags from post content."""
    content = post.content
    if content:
        try:
            content = decrypt_text(content)
        except:
            pass
        return [normalize_hashtag(h) for h in re.findall(r'#(\w+)', content)]
    return []


# ==================== Endpoints ====================

@router.post("/follow")
def follow_hashtag(
    req: HashtagFollowRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Follow a hashtag to see more posts with it in your feed."""
    tag = normalize_hashtag(req.hashtag)
    
    if not tag or len(tag) < 2:
        raise HTTPException(status_code=400, detail="Invalid hashtag")
    
    # Check if already following
    existing = db.query(HashtagFollow).filter(
        HashtagFollow.user_id == current_user.id,
        HashtagFollow.hashtag == tag
    ).first()
    
    if existing:
        return {"status": "already_following", "hashtag": tag}
    
    # Create follow
    follow = HashtagFollow(
        user_id=current_user.id,
        hashtag=tag,
        created_at=datetime.utcnow()
    )
    db.add(follow)
    db.commit()
    
    print(f"#️⃣ {current_user.username} followed #{tag}")
    return {"status": "followed", "hashtag": tag}


@router.delete("/follow/{hashtag}")
def unfollow_hashtag(
    hashtag: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Unfollow a hashtag."""
    tag = normalize_hashtag(hashtag)
    
    follow = db.query(HashtagFollow).filter(
        HashtagFollow.user_id == current_user.id,
        HashtagFollow.hashtag == tag
    ).first()
    
    if follow:
        db.delete(follow)
        db.commit()
        return {"status": "unfollowed", "hashtag": tag}
    
    return {"status": "not_following", "hashtag": tag}


@router.get("/following", response_model=List[str])
def get_followed_hashtags(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get list of hashtags the user follows."""
    follows = db.query(HashtagFollow.hashtag).filter(
        HashtagFollow.user_id == current_user.id
    ).all()
    
    return [f.hashtag for f in follows]


@router.get("/posts/{hashtag}", response_model=List[PostResponse])
def get_posts_by_hashtag(
    hashtag: str,
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
    offset: int = 0
):
    """Get all posts with a specific hashtag."""
    tag = normalize_hashtag(hashtag)
    
    if not tag:
        raise HTTPException(status_code=400, detail="Invalid hashtag")
    
    # Search for posts containing this hashtag
    # Note: This uses LIKE which is not optimal for large datasets
    # In production, use a hashtag junction table or full-text search
    # 🔴 hacker-audit 2026-05-20 — escape LIKE wildcards in the tag.
    # normalize_hashtag does not strip % / _, so an unescaped tag
    # turned this ILIKE into an attacker-controlled wildcard scan.
    from routers.search import _escape_like
    pattern = f"%#{_escape_like(tag[:64])}%"

    # 🔴 ROUND 71 S11: hashtag feed now respects `is_hidden`,
    # `HiddenContent`, and bidirectional blocks (mirrors round-26
    # main-feed filter trio). Previously moderated / per-user-hidden
    # posts and blocked authors all reappeared via #tag.
    from models import HiddenContent, Block
    hidden_ids_subq = db.query(HiddenContent.object_id).filter(
        HiddenContent.user_id == current_user.id,
        HiddenContent.object_type == "post",
    ).subquery()
    blocker_ids = [r[0] for r in db.query(Block.blocker_id).filter(
        Block.blocked_id == current_user.id
    ).all()]
    blockee_ids = [r[0] for r in db.query(Block.blocked_id).filter(
        Block.blocker_id == current_user.id
    ).all()]
    blocked_user_ids = set(blocker_ids) | set(blockee_ids)

    post_query = db.query(Post).filter(
        or_(Post.visibility == 'public', Post.visibility == None),
        Post.is_hidden != True,
        ~Post.id.in_(hidden_ids_subq),
        Post.content.ilike(pattern, escape="\\")  # Case-insensitive LIKE
    )
    if blocked_user_ids:
        post_query = post_query.filter(~Post.author_id.in_(blocked_user_ids))
    posts = post_query.order_by(Post.timestamp.desc()).offset(offset).limit(limit).all()
    
    result = []
    for post in posts:
        # Verify hashtag actually exists after decryption
        post_tags = extract_hashtags_from_post(post)
        if tag not in post_tags:
            continue
        
        author = db.query(User).filter(User.id == post.author_id).first()
        stats = get_post_stats(db, post.id, current_user.id)
        content = decrypt_text(post.content) if post.content else ""
        
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
            **get_voice_and_collab_fields(post, db)
        ))
    
    print(f"#️⃣ Found {len(result)} posts for #{tag}")
    return result


@router.get("/info/{hashtag}", response_model=HashtagInfo)
def get_hashtag_info(
    hashtag: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get info about a hashtag: post count and follow status."""
    tag = normalize_hashtag(hashtag)
    
    # Count posts (approximate - uses LIKE)
    # 🔴 hacker-audit 2026-05-20 — escape LIKE wildcards (see above).
    from routers.search import _escape_like
    pattern = f"%#{_escape_like(tag[:64])}%"
    post_count = db.query(Post).filter(
        or_(Post.visibility == 'public', Post.visibility == None),
        Post.content.ilike(pattern, escape="\\")
    ).count()
    
    # Check if following
    is_following = db.query(HashtagFollow).filter(
        HashtagFollow.user_id == current_user.id,
        HashtagFollow.hashtag == tag
    ).first() is not None
    
    return HashtagInfo(
        hashtag=tag,
        post_count=post_count,
        is_following=is_following
    )


@router.get("/trending", response_model=List[TrendingHashtag])
def get_trending_hashtags(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 10
):
    """Get trending hashtags based on recent post activity."""
    # Get posts from last 24 hours
    cutoff = datetime.utcnow() - timedelta(hours=24)
    
    recent_posts = db.query(Post).filter(
        Post.timestamp > cutoff,
        or_(Post.visibility == 'public', Post.visibility == None)
    ).all()
    
    # Count hashtag occurrences
    hashtag_counts = {}
    for post in recent_posts:
        tags = extract_hashtags_from_post(post)
        for tag in tags:
            if tag not in hashtag_counts:
                hashtag_counts[tag] = {"total": 0, "recent": 0}
            hashtag_counts[tag]["total"] += 1
            hashtag_counts[tag]["recent"] += 1
    
    # Sort by recent count
    sorted_tags = sorted(
        hashtag_counts.items(),
        key=lambda x: x[1]["recent"],
        reverse=True
    )
    
    result = []
    for tag, counts in sorted_tags[:limit]:
        result.append(TrendingHashtag(
            hashtag=tag,
            post_count=counts["total"],
            recent_posts=counts["recent"]
        ))
    
    return result
