"""
Recommendation Service

Core recommendation engine that scores and ranks posts for personalized feeds.
Uses hybrid approach: content-based + collaborative + engagement signals.
"""
from datetime import datetime, timedelta
from typing import List, Dict, Optional, Tuple
from sqlalchemy.orm import Session
from sqlalchemy import or_, and_, func
import math
import json
import re

from models import Post, User, UserInterest, SeenPost, PostLike, Friendship
from encryption import decrypt_text
from services.language_service import detect_language


# Scoring weights for the final formula
SCORING_WEIGHTS = {
    'interest_match': 0.40,      # How well post matches user interests
    'language_match': 0.25,      # Same language = boost
    'engagement_rate': 0.20,     # Popular posts (likes/views ratio)
    'freshness': 0.10,           # Recent posts
    'author_affinity': 0.05,     # Friends/followed users
}


def get_recommended_posts(
    user_id: str,
    db: Session,
    limit: int = 20,
    offset: int = 0,
    preferred_language: Optional[str] = None
) -> List[Dict]:
    """
    Get personalized feed recommendations for a user.
    
    Args:
        user_id: The user's ID
        db: Database session
        limit: Number of posts to return
        offset: Pagination offset
        preferred_language: User's preferred language (auto-detect if not provided)
        
    Returns:
        List of scored posts with metadata
    """
    # Get user's interests
    user_interests = _get_user_interest_map(user_id, db)
    
    # Get user's friends for affinity scoring
    friend_ids = _get_friend_ids(user_id, db)
    
    # Get recently seen posts to exclude
    seen_post_ids = _get_seen_post_ids(user_id, db, hours=48)
    
    # Get candidate posts (recent public posts)
    candidates = _get_candidate_posts(db, seen_post_ids, limit=limit * 5)
    
    # Score each candidate
    scored_posts = []
    for post in candidates:
        score = _calculate_post_score(
            post=post,
            user_interests=user_interests,
            friend_ids=friend_ids,
            user_id=user_id,
            preferred_language=preferred_language,
            db=db
        )
        scored_posts.append((post, score))
    
    # Sort by score descending
    scored_posts.sort(key=lambda x: x[1], reverse=True)
    
    # Apply pagination
    paginated = scored_posts[offset:offset + limit]
    
    # Build response
    result = []
    for post, score in paginated:
        result.append({
            'post': post,
            'score': round(score, 3),
            'debug': {
                'interest': round(score * SCORING_WEIGHTS['interest_match'], 3),
                'language': round(score * SCORING_WEIGHTS['language_match'], 3),
                'engagement': round(score * SCORING_WEIGHTS['engagement_rate'], 3),
            }
        })
    
    print(f"🎯 Recommended {len(result)} posts for user (from {len(candidates)} candidates)")
    return result


def _get_user_interest_map(user_id: str, db: Session) -> Dict[str, float]:
    """Get user's interests as a tag -> score map."""
    interests = db.query(UserInterest).filter(
        UserInterest.user_id == user_id
    ).all()
    
    now = datetime.utcnow()
    result = {}
    
    for interest in interests:
        # Apply time decay
        days_since = (now - interest.updated_at).total_seconds() / 86400
        decay = math.pow(0.5, days_since / 7)
        score = interest.score * decay
        
        if score >= 0.1:
            result[interest.tag] = score
    
    return result


def _get_friend_ids(user_id: str, db: Session) -> set:
    """Get set of friend user IDs."""
    friendships = db.query(Friendship).filter(
        or_(
            Friendship.user_id == user_id,
            Friendship.friend_id == user_id
        )
    ).all()
    
    friends = set()
    for f in friendships:
        if f.user_id == user_id:
            friends.add(f.friend_id)
        else:
            friends.add(f.user_id)
    
    return friends


def _get_seen_post_ids(user_id: str, db: Session, hours: int = 48) -> set:
    """Get recently seen post IDs to exclude from recommendations."""
    cutoff = datetime.utcnow() - timedelta(hours=hours)
    
    seen = db.query(SeenPost.post_id).filter(
        SeenPost.user_id == user_id,
        SeenPost.seen_at > cutoff
    ).all()
    
    return {s[0] for s in seen}


def _get_candidate_posts(db: Session, exclude_ids: set, limit: int = 100) -> List[Post]:
    """Get candidate posts for recommendations."""
    # Get recent public posts
    cutoff = datetime.utcnow() - timedelta(days=7)
    
    query = db.query(Post).filter(
        Post.timestamp > cutoff,
        or_(Post.visibility == 'public', Post.visibility == None)
    )
    
    # Exclude seen posts
    if exclude_ids:
        query = query.filter(~Post.id.in_(exclude_ids))
    
    # Order by recency and engagement
    posts = query.order_by(Post.timestamp.desc()).limit(limit).all()
    
    return posts


def _calculate_post_score(
    post: Post,
    user_interests: Dict[str, float],
    friend_ids: set,
    user_id: str,
    preferred_language: Optional[str],
    db: Session
) -> float:
    """
    Calculate recommendation score for a post.
    
    Score = weighted combination of:
    - interest_match: How well post tags match user interests
    - language_match: If post is in user's preferred language
    - engagement_rate: likes / views ratio
    - freshness: How recent the post is
    - author_affinity: Is author a friend?
    """
    
    # 1. Interest Match (0-1)
    interest_score = _calculate_interest_match(post, user_interests)
    
    # 2. Language Match (0 or 1)
    language_score = _calculate_language_match(post, preferred_language)
    
    # 3. Engagement Rate (0-1)
    engagement_score = _calculate_engagement_rate(post)
    
    # 4. Freshness (0-1)
    freshness_score = _calculate_freshness(post)
    
    # 5. Author Affinity (0 or 1)
    affinity_score = 1.0 if post.author_id in friend_ids else 0.0
    
    # Weighted combination
    total_score = (
        interest_score * SCORING_WEIGHTS['interest_match'] +
        language_score * SCORING_WEIGHTS['language_match'] +
        engagement_score * SCORING_WEIGHTS['engagement_rate'] +
        freshness_score * SCORING_WEIGHTS['freshness'] +
        affinity_score * SCORING_WEIGHTS['author_affinity']
    )
    
    # Don't show user their own posts in recommendations
    if post.author_id == user_id:
        total_score *= 0.1
    
    return total_score


def _calculate_interest_match(post: Post, user_interests: Dict[str, float]) -> float:
    """Calculate how well post matches user's interests (0-1)."""
    if not user_interests:
        return 0.5  # Neutral if no interests yet
    
    # Get post tags
    post_tags = _extract_post_tags(post)
    
    if not post_tags:
        return 0.3  # Slightly lower for untagged posts
    
    # Calculate match score
    matching_score = 0
    max_interest = max(user_interests.values()) if user_interests else 1
    
    for tag in post_tags:
        if tag in user_interests:
            # Normalize score to 0-1
            matching_score += user_interests[tag] / max_interest
    
    # Average over number of tags
    avg_score = matching_score / len(post_tags) if post_tags else 0
    
    return min(avg_score, 1.0)


def _extract_post_tags(post: Post) -> List[str]:
    """Extract tags from a post."""
    content = post.content
    if content:
        try:
            content = decrypt_text(content)
        except:
            pass
        
        # Extract hashtags
        hashtags = re.findall(r'#(\w+)', content)
        return [h.lower() for h in hashtags]
    
    return []


def _calculate_language_match(post: Post, preferred_language: Optional[str]) -> float:
    """Calculate language match score (0 or 1)."""
    if not preferred_language:
        return 0.5  # Neutral if no preference
    
    content = post.content
    if content:
        try:
            content = decrypt_text(content)
        except:
            pass
        
        post_lang = detect_language(content)
        if post_lang == preferred_language:
            return 1.0
        elif post_lang == 'en':
            return 0.7  # English is universal fallback
    
    return 0.3


def _calculate_engagement_rate(post: Post) -> float:
    """Calculate engagement rate (0-1)."""
    views = post.view_count or 1
    likes = post.likes or 0
    
    # Engagement ratio
    ratio = likes / views
    
    # Normalize to 0-1 (cap at 50% engagement)
    return min(ratio * 2, 1.0)


def _calculate_freshness(post: Post) -> float:
    """Calculate freshness score (0-1). Recent = higher."""
    now = datetime.utcnow()
    age_hours = (now - post.timestamp).total_seconds() / 3600
    
    # Decay: 50% after 24 hours
    decay = math.pow(0.5, age_hours / 24)
    
    return decay


def mark_post_seen(user_id: str, post_id: str, db: Session):
    """Mark a post as seen by the user."""
    existing = db.query(SeenPost).filter(
        SeenPost.user_id == user_id,
        SeenPost.post_id == post_id
    ).first()
    
    if not existing:
        seen = SeenPost(
            user_id=user_id,
            post_id=post_id,
            seen_at=datetime.utcnow()
        )
        db.add(seen)
        db.commit()
