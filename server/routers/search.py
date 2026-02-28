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


@router.get("/posts", response_model=List[PostSearchResponse])
def search_posts(
    q: str = Query(..., min_length=1, description="Search query"),
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
    """
    # Build search query (SQLite LIKE for MVP)
    # Note: For production, use Postgres full-text search or Meilisearch
    search_term = f"%{q}%"
    
    query = db.query(Post).filter(
        Post.content.ilike(search_term)
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
    """
    Search posts by hashtag.
    """
    # Search for hashtag pattern
    hashtag_pattern = f"%#{tag}%"
    
    query = db.query(Post).filter(
        Post.content.ilike(hashtag_pattern)
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
