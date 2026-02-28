"""
Interest Tracking Service

Tracks and updates user interests based on engagement actions.
Implements weighted scoring with time decay.
"""
from datetime import datetime, timedelta
from typing import List, Optional, Dict
from sqlalchemy.orm import Session
import json
import re
import math

from models import UserInterest, UserEvent, Post
from encryption import decrypt_text


# Scoring weights for different actions
WEIGHTS = {
    'view_post': 1,      # View with dwell > 3s
    'like_post': 3,
    'comment_post': 4,
    'share_post': 5,
    'click_hashtag': 2,
    'search_query': 2,
}

# Time decay: half-life in days
DECAY_HALF_LIFE_DAYS = 7


def extract_tags_from_post(post: Post, db: Session = None) -> List[str]:
    """
    Extract relevant tags from a post for interest tracking.
    
    Tags include:
    - Explicit hashtags (#technology, #food)
    - Inferred topics (future: use ML/AI)
    """
    tags = []
    
    # Get post content
    content = post.content
    if content:
        # Try to decrypt if encrypted
        try:
            content = decrypt_text(content)
        except:
            pass
        
        # Extract hashtags
        hashtags = re.findall(r'#(\w+)', content)
        tags.extend([h.lower() for h in hashtags])
        
        # Extract @mentions as potential interest in that user's content
        mentions = re.findall(r'@(\w+)', content)
        tags.extend([f"user:{m.lower()}" for m in mentions])
    
    return list(set(tags))  # Unique tags only


def update_user_interests(
    user_id: str,
    event_type: str,
    post: Optional[Post],
    hashtag: Optional[str],
    query: Optional[str],
    db: Session
) -> List[str]:
    """
    Update user interests based on an engagement event.
    
    Args:
        user_id: The user's ID
        event_type: Type of event (like_post, comment_post, etc.)
        post: The post involved (if any)
        hashtag: Clicked hashtag (if any)
        query: Search query (if any)
        db: Database session
        
    Returns:
        List of tags that were updated
    """
    weight = WEIGHTS.get(event_type, 1)
    tags_updated = []
    
    # Extract tags from post
    if post:
        tags = extract_tags_from_post(post, db)
        for tag in tags:
            _update_interest_score(user_id, tag, weight, db)
            tags_updated.append(tag)
    
    # Track hashtag click
    if hashtag:
        tag = hashtag.lower().lstrip('#')
        _update_interest_score(user_id, tag, weight, db)
        tags_updated.append(tag)
    
    # Track search query (split into words)
    if query:
        words = query.lower().split()
        for word in words:
            if len(word) >= 3:  # Skip short words
                _update_interest_score(user_id, f"search:{word}", weight * 0.5, db)
                tags_updated.append(f"search:{word}")
    
    return tags_updated


def _update_interest_score(user_id: str, tag: str, weight: float, db: Session):
    """Update a single interest score with decay."""
    
    # Find existing interest
    interest = db.query(UserInterest).filter(
        UserInterest.user_id == user_id,
        UserInterest.tag == tag
    ).first()
    
    now = datetime.utcnow()
    
    if interest:
        # Apply time decay to existing score
        days_since_update = (now - interest.updated_at).total_seconds() / 86400
        decay_factor = math.pow(0.5, days_since_update / DECAY_HALF_LIFE_DAYS)
        decayed_score = interest.score * decay_factor
        
        # Add new weight
        interest.score = decayed_score + weight
        interest.updated_at = now
    else:
        # Create new interest
        interest = UserInterest(
            user_id=user_id,
            tag=tag,
            score=weight,
            updated_at=now
        )
        db.add(interest)
    
    db.commit()


def get_user_interests(user_id: str, db: Session, limit: int = 20) -> List[Dict]:
    """
    Get user's top interests with current scores (after decay).
    
    Returns:
        List of {tag, score} dicts sorted by score descending
    """
    interests = db.query(UserInterest).filter(
        UserInterest.user_id == user_id
    ).all()
    
    now = datetime.utcnow()
    result = []
    
    for interest in interests:
        # Apply current decay
        days_since_update = (now - interest.updated_at).total_seconds() / 86400
        decay_factor = math.pow(0.5, days_since_update / DECAY_HALF_LIFE_DAYS)
        current_score = interest.score * decay_factor
        
        # Skip very low scores
        if current_score < 0.1:
            continue
            
        result.append({
            'tag': interest.tag,
            'score': round(current_score, 2)
        })
    
    # Sort by score descending
    result.sort(key=lambda x: x['score'], reverse=True)
    
    return result[:limit]


def log_user_event(
    user_id: str,
    event_type: str,
    db: Session,
    post_id: Optional[str] = None,
    hashtag: Optional[str] = None,
    query: Optional[str] = None,
    duration_ms: Optional[int] = None
):
    """
    Log a user event and update interests.
    
    This is the main entry point for tracking user engagement.
    """
    # Create event record
    event = UserEvent(
        user_id=user_id,
        event_type=event_type,
        post_id=post_id,
        hashtag=hashtag,
        query=query,
        duration_ms=duration_ms,
        created_at=datetime.utcnow()
    )
    db.add(event)
    db.commit()
    
    # Update interests if post is involved
    post = None
    if post_id:
        post = db.query(Post).filter(Post.id == post_id).first()
    
    # Skip view events with short dwell time
    if event_type == 'view_post' and (not duration_ms or duration_ms < 3000):
        return
    
    # Update interests
    tags = update_user_interests(user_id, event_type, post, hashtag, query, db)
    
    if tags:
        print(f"📊 Updated interests for {user_id}: {tags[:5]}...")
