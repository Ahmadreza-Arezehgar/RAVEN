"""
Post Notification Subscriptions Router
Allows users to subscribe to notifications when another user posts
"""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from models import PostSubscription, User, RoomVisibility
from datetime import datetime

# Import get_current_user from users router
from routers.users import get_current_user

router = APIRouter(prefix="/profiles", tags=["subscriptions"])


@router.post("/{target_id}/post-notify/enable")
async def enable_post_notify(
    target_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Enable post notifications for a target user."""
    # Can't subscribe to yourself
    if target_id == current_user.id:
        raise HTTPException(status_code=400, detail="Cannot subscribe to yourself")
    
    # Check if target user exists
    target = db.query(User).filter(User.id == target_id).first()
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    
    # Check if subscription already exists
    existing = db.query(PostSubscription).filter(
        PostSubscription.subscriber_id == current_user.id,
        PostSubscription.target_id == target_id
    ).first()
    
    if existing:
        # Re-enable if disabled
        existing.enabled = True
        db.commit()
    else:
        # Create new subscription
        subscription = PostSubscription(
            subscriber_id=current_user.id,
            target_id=target_id,
            enabled=True
        )
        db.add(subscription)
        db.commit()
    
    return {
        "success": True,
        "message": f"Post notifications enabled for @{target.username}",
        "enabled": True,
        "target_username": target.username
    }


@router.post("/{target_id}/post-notify/disable")
async def disable_post_notify(
    target_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Disable post notifications for a target user."""
    # Find existing subscription
    existing = db.query(PostSubscription).filter(
        PostSubscription.subscriber_id == current_user.id,
        PostSubscription.target_id == target_id
    ).first()
    
    if existing:
        existing.enabled = False
        db.commit()
    
    return {
        "success": True,
        "message": "Post notifications disabled",
        "enabled": False
    }


@router.get("/{target_id}/post-notify/status")
async def get_post_notify_status(
    target_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get post notification status for a target user."""
    subscription = db.query(PostSubscription).filter(
        PostSubscription.subscriber_id == current_user.id,
        PostSubscription.target_id == target_id
    ).first()
    
    return {
        "enabled": subscription.enabled if subscription else False,
        "subscribed_since": subscription.created_at.isoformat() if subscription else None
    }


# ==================== ROOM VISIBILITY ENDPOINTS ====================

# ==================== ROOM VISIBILITY ENDPOINTS ====================

@router.post("/rooms/{room_id}/mark-read")
async def mark_room_as_read(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Mark all messages in a room as read for the current user."""
    # Find or create room visibility
    visibility = db.query(RoomVisibility).filter(
        RoomVisibility.user_id == current_user.id,
        RoomVisibility.room_id == room_id
    ).first()
    
    if visibility:
        visibility.last_read_at = datetime.utcnow()
    else:
        visibility = RoomVisibility(
            user_id=current_user.id,
            room_id=room_id,
            last_read_at=datetime.utcnow()
        )
        db.add(visibility)
    
    db.commit()
    
    return {
        "success": True,
        "room_id": room_id,
        "read_at": visibility.last_read_at.isoformat()
    }


@router.post("/rooms/{room_id}/hide")
async def hide_room(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Hide a conversation for the current user (delete for me)."""
    # Find or create room visibility
    visibility = db.query(RoomVisibility).filter(
        RoomVisibility.user_id == current_user.id,
        RoomVisibility.room_id == room_id
    ).first()
    
    if visibility:
        visibility.hidden = True
    else:
        visibility = RoomVisibility(
            user_id=current_user.id,
            room_id=room_id,
            hidden=True
        )
        db.add(visibility)
    
    db.commit()
    
    return {
        "success": True,
        "room_id": room_id,
        "hidden": True
    }


@router.post("/rooms/{room_id}/unhide")
async def unhide_room(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Unhide a conversation (called when new message arrives)."""
    visibility = db.query(RoomVisibility).filter(
        RoomVisibility.user_id == current_user.id,
        RoomVisibility.room_id == room_id
    ).first()
    
    if visibility:
        visibility.hidden = False
        db.commit()
    
    return {
        "success": True,
        "room_id": room_id,
        "hidden": False
    }
