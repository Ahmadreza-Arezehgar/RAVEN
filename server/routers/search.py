"""
Search Router - Post Search API
"""
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime

from database import get_db
from models import User, Post, PostLike, Comment, Repost
from routers.users import get_current_user
from routers.posts import get_post_stats
from encryption import decrypt_text

router = APIRouter(prefix="/api/search", tags=["search"])


class PostSearchResponse(BaseModel):
    id: str
    author_id: str
    author_username: str
    author_avatar: Optional[str]
    content: str
    image_url: Optional[str]
    timestamp: datetime
    likes: int
    comments: int
    reposts: int
    is_local: bool
    is_liked: bool
    is_reposted: bool

    class Config:
        from_attributes = True


def _escape_like(s: str) -> str:
    r"""Escape SQL LIKE wildcards in user input.

    🔴 hacker-audit 2026-05-19: without this, q="%" matched every
    row → full-table scan + bulk content exfil. q="a_b" matched
    "aXb"/"a1b" too (silent corruption of intent). We use backslash
    as the escape char and pair it with ``.escape('\\')`` on the
    SQLAlchemy filter so the DB driver knows to treat ``\%`` literally.
    """
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


@router.get("/posts", response_model=List[PostSearchResponse])
def search_posts(
    q: str = Query(..., min_length=1, max_length=200, description="Search query"),
    sort: str = Query("latest", regex="^(latest|top)$"),
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Search posts by content.

    - **q**: Search query (required, min 1 character)
    - **sort**: Sort order - 'latest' (by timestamp) or 'top' (by likes)
    - **limit**: Max results (1-100, default 50)
    - **offset**: Pagination offset

    🔴 hacker-audit 2026-05-19 — two findings rolled in:
      1. PREVIOUSLY q was wrapped in `%{q}%` with no escape. q="%"
         matched every row → DoS + bulk content exfil; q="a_b"
         silently broadened the match. Now wildcard chars are
         escaped before substitution.
      2. PREVIOUSLY this endpoint returned posts of ANY visibility
         (public, friends, local, private). A friends-only or
         private post by user A was readable in search results by
         random user B who typed a likely keyword. Now we filter to
         {public OR author=self}. Friends-only / local / private
         post results are scoped to the author. Matches the same
         predicate /feed already enforces (posts.py:627 etc.).
    """
    from sqlalchemy import or_ as _or_

    search_term = f"%{_escape_like(q)}%"

    query = db.query(Post).filter(
        Post.content.ilike(search_term, escape="\\"),
        Post.is_hidden != True,
        _or_(
            Post.visibility == "public",
            Post.visibility.is_(None),  # legacy rows default to public
            Post.author_id == current_user.id,
        ),
    )

    # Apply sorting
    if sort == "top":
        # Sort by likes count (need subquery for accurate count)
        query = query.order_by(Post.likes.desc(), Post.timestamp.desc())
    else:
        query = query.order_by(Post.timestamp.desc())

    # Apply pagination
    posts = query.offset(offset).limit(limit).all()
    
    # Build response with stats
    result = []
    for post in posts:
        author = db.query(User).filter(User.id == post.author_id).first()
        stats = get_post_stats(db, post.id, current_user.id)
        
        # Decrypt content for response
        try:
            decrypted_content = decrypt_text(post.content)
        except Exception:
            decrypted_content = post.content
        
        result.append(PostSearchResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=author.avatar_path if author else None,
            content=decrypted_content,
            image_url=post.image_url,
            timestamp=post.timestamp,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"]
        ))
    
    print(f"🔍 Search '{q}' returned {len(result)} posts (sort={sort})")
    
    return result


@router.get("/hashtag/{tag}", response_model=List[PostSearchResponse])
def search_by_hashtag(
    tag: str,
    sort: str = Query("latest", regex="^(latest|top)$"),
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Search posts by hashtag.

    🔴 hacker-audit 2026-05-19 — same two findings as /search/posts:
    LIKE wildcards in `tag` returned every post; missing visibility
    filter let friends-only / private posts leak to anyone who
    guessed the hashtag. Now: escape `%`/`_`, length-cap, and gate
    on {public OR author=self}.
    """
    from sqlalchemy import or_ as _or_

    if len(tag) > 64:
        return []

    hashtag_pattern = f"%#{_escape_like(tag)}%"

    query = db.query(Post).filter(
        Post.content.ilike(hashtag_pattern, escape="\\"),
        Post.is_hidden != True,
        _or_(
            Post.visibility == "public",
            Post.visibility.is_(None),
            Post.author_id == current_user.id,
        ),
    )

    if sort == "top":
        query = query.order_by(Post.likes.desc(), Post.timestamp.desc())
    else:
        query = query.order_by(Post.timestamp.desc())

    posts = query.offset(offset).limit(limit).all()
    
    result = []
    for post in posts:
        author = db.query(User).filter(User.id == post.author_id).first()
        stats = get_post_stats(db, post.id, current_user.id)
        
        try:
            decrypted_content = decrypt_text(post.content)
        except Exception:
            decrypted_content = post.content
        
        result.append(PostSearchResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=author.avatar_path if author else None,
            content=decrypted_content,
            image_url=post.image_url,
            timestamp=post.timestamp,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"]
        ))
    
    print(f"#️⃣ Hashtag #{tag} returned {len(result)} posts")
    
    return result
