"""
Notifications Router - Fetch all notifications for a user
"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime
import json

from database import get_db
from models import User, Notification
from routers.users import get_current_user

router = APIRouter(prefix="/api/notifications", tags=["notifications"])


class NotificationResponse(BaseModel):
    id: str
    type: str  # 'like', 'comment', 'mention', 'post_from_followed'
    data: dict
    timestamp: datetime
    is_read: bool
    
    class Config:
        from_attributes = True


@router.get("", response_model=List[NotificationResponse])
def get_notifications(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
    unread_only: bool = False
):
    """Get all notifications for the current user."""
    
    query = db.query(Notification).filter(
        Notification.user_id == current_user.id
    )
    
    if unread_only:
        query = query.filter(Notification.is_read == False)
    
    notifications = query.order_by(
        Notification.timestamp.desc()
    ).limit(limit).all()
    
    result = []
    
    # Add regular notifications
    for n in notifications:
        # Parse JSON data
        try:
            data = json.loads(n.data) if n.data else {}
        except:
            data = {}
        
        result.append(NotificationResponse(
            id=n.id,
            type=n.type,
            data=data,
            timestamp=n.timestamp,
            is_read=n.is_read
        ))
    
    # Note: Friend requests are NOT injected here anymore.
    # They were hardcoded as is_read=False which caused them to always
    # revert to unread on every fetch. The client handles friend requests
    # separately via the friend_request notification type (created when
    # a friend request is actually sent) and the friend requests UI.
    
    # Sort all results by timestamp (newest first)
    result.sort(key=lambda x: x.timestamp, reverse=True)
    
    # Limit total results
    result = result[:limit]
    
    print(f"🔔 {current_user.username} fetched {len(result)} notifications")
    return result


@router.post("/{notification_id}/read")
def mark_notification_read(
    notification_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Mark a notification as read."""
    notification = db.query(Notification).filter(
        Notification.id == notification_id,
        Notification.user_id == current_user.id
    ).first()
    
    if not notification:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Notification not found"
        )
    
    notification.is_read = True
    db.commit()
    
    return {"status": "success", "message": "Notification marked as read"}


@router.post("/{notification_id}/unread")
def mark_notification_unread(
    notification_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Mark a notification as unread."""
    notification = db.query(Notification).filter(
        Notification.id == notification_id,
        Notification.user_id == current_user.id
    ).first()
    
    if not notification:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Notification not found"
        )
    
    notification.is_read = False
    db.commit()
    
    return {"status": "success", "message": "Notification marked as unread"}


@router.post("/read-all")
def mark_all_notifications_read(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Mark all notifications as read."""
    db.query(Notification).filter(
        Notification.user_id == current_user.id,
        Notification.is_read == False
    ).update({Notification.is_read: True})
    
    db.commit()
    
    return {"status": "success", "message": "All notifications marked as read"}


@router.get("/unread-count")
def get_unread_count(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get count of unread notifications."""
    count = db.query(Notification).filter(
        Notification.user_id == current_user.id,
        Notification.is_read == False
    ).count()
    
    return {"unread_count": count}


@router.delete("/{notification_id}")
def delete_notification(
    notification_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Delete a single notification."""
    notification = db.query(Notification).filter(
        Notification.id == notification_id,
        Notification.user_id == current_user.id
    ).first()
    
    if notification:
        db.delete(notification)
        db.commit()
        print(f"🗑️ {current_user.username} deleted notification {notification_id}")
    
    return {"status": "success", "message": "Notification deleted"}


@router.delete("")
def clear_all_notifications(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Delete all notifications for the current user."""
    count = db.query(Notification).filter(
        Notification.user_id == current_user.id
    ).delete()
    
    db.commit()
    print(f"🗑️ {current_user.username} cleared all {count} notifications")
    
    return {"status": "success", "message": f"Deleted {count} notifications"}
