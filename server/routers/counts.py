"""
Counts Router - Badge counts for bottom navigation
"""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from sqlalchemy import func
from pydantic import BaseModel
from datetime import datetime, timedelta

from database import get_db
from models import User, Message, Post, FriendRequest
from routers.users import get_current_user

router = APIRouter(prefix="/api/counts", tags=["counts"])


class BadgeCounts(BaseModel):
    unread_messages: int
    new_local_posts: int
    new_friend_posts: int
    security_alerts: int


@router.get("", response_model=BadgeCounts)
def get_badge_counts(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get badge counts for bottom navigation tabs.
    Called every 15-30 seconds for auto-refresh.
    """
    user_id = current_user.id
    
    # 1. Unread messages count
    unread_messages = db.query(func.count(Message.id)).filter(
        Message.recipient_id == user_id,
        Message.read_at.is_(None)
    ).scalar() or 0
    
    # 2. New local posts (last 24 hours, not by current user)
    since = datetime.utcnow() - timedelta(hours=24)
    new_local_posts = db.query(func.count(Post.id)).filter(
        Post.is_local == True,
        Post.author_id != user_id,
        Post.timestamp > since
    ).scalar() or 0
    
    # 3. New friend posts (from accepted friends, last 24 hours)
    # Get friend IDs
    friend_ids_query = db.query(FriendRequest.requester_id).filter(
        FriendRequest.recipient_id == user_id,
        FriendRequest.status == "accepted"
    ).union(
        db.query(FriendRequest.recipient_id).filter(
            FriendRequest.requester_id == user_id,
            FriendRequest.status == "accepted"
        )
    )
    friend_ids = [r[0] for r in friend_ids_query.all()]
    
    new_friend_posts = 0
    if friend_ids:
        new_friend_posts = db.query(func.count(Post.id)).filter(
            Post.author_id.in_(friend_ids),
            Post.timestamp > since
        ).scalar() or 0
    
    # 4. Security alerts (new logins, pending friend requests, etc.)
    # For now: count pending friend requests as "security alerts"
    pending_requests = db.query(func.count(FriendRequest.id)).filter(
        FriendRequest.recipient_id == user_id,
        FriendRequest.status == "pending"
    ).scalar() or 0
    
    print(f"📊 Counts for {current_user.username}: msgs={unread_messages}, local={new_local_posts}, friends={new_friend_posts}, alerts={pending_requests}")
    
    return BadgeCounts(
        unread_messages=unread_messages,
        new_local_posts=new_local_posts,
        new_friend_posts=new_friend_posts,
        security_alerts=pending_requests
    )
