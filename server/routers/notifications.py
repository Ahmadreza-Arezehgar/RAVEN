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
    """Mark all notifications as read.

    🔴 ROUND 70 (2026-05-23) — friend_request notifications are
    EXCLUDED. They live in a dedicated "Pending Requests" folder in
    the iOS Activity center and stay actionable (unread visual
    treatment + count badge) until the user explicitly taps
    Accept / Decline. Marking them read server-side would silently
    dismiss the folder's purple count on the next poll, defeating
    the "respond to clear" UX contract.
    """
    db.query(Notification).filter(
        Notification.user_id == current_user.id,
        Notification.is_read == False,
        Notification.type != "friend_request",
    ).update({Notification.is_read: True}, synchronize_session=False)

    db.commit()

    return {"status": "success", "message": "All notifications marked as read"}


@router.post("/read-by-room/{room_id}")
def mark_room_notifications_read(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    🔴 Bug fix (2026-05-16): mark every message / group-message
    notification for this room as read.

    Called by the iOS client whenever the user opens a chat —
    previously the per-pill badge ("All [50]") stayed stuck on the
    same number forever because nothing decremented `is_read` for
    notifications even when the user had clearly seen the
    underlying messages.

    Uses Postgres' JSON `->>` operator so we can match on the
    `data.room_id` field inside the JSON blob without a schema
    change. Indexed scans by `user_id + is_read` keep the update
    cheap for users with thousands of historical notifications.
    """
    from sqlalchemy import text as sql_text
    # JSON-text match — Notification.data is stored as a JSON
    # string (see messages.py / groups.py creation sites). The
    # JSON layout for chat notifications always carries `room_id`
    # at the top level of the payload dict.
    updated = db.query(Notification).filter(
        Notification.user_id == current_user.id,
        Notification.is_read == False,
        Notification.type.in_(["message", "group_message"]),
        sql_text("(data::json ->> 'room_id') = :rid").bindparams(rid=room_id)
    ).update({Notification.is_read: True}, synchronize_session=False)

    db.commit()
    return {"status": "success", "updated": updated}


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
    """Delete a single notification.

    🔴 ROUND 70 — refuse to delete friend_request notifications.
    They are only removable via the matching Accept / Decline path
    on /api/users/friend-request/{id}/accept|decline, which deletes
    the notification row as a side effect of resolving the
    underlying FriendRequest. Without this guard, a malicious or
    confused client could clear pending requests from the user's
    Activity center without the user ever seeing them.
    """
    notification = db.query(Notification).filter(
        Notification.id == notification_id,
        Notification.user_id == current_user.id
    ).first()

    if notification:
        if notification.type == "friend_request":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Friend requests can only be cleared via accept or decline.",
            )
        db.delete(notification)
        db.commit()
        print(f"🗑️ {current_user.username} deleted notification {notification_id}")

    return {"status": "success", "message": "Notification deleted"}


@router.delete("")
def clear_all_notifications(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Delete all notifications for the current user.

    🔴 ROUND 70 — friend_request rows are PRESERVED so the iOS
    Pending Requests folder remains intact. Clear-All only wipes
    informational notifications (likes, comments, messages, etc.);
    actionable items the user hasn't responded to stick around.
    """
    count = db.query(Notification).filter(
        Notification.user_id == current_user.id,
        Notification.type != "friend_request",
    ).delete(synchronize_session=False)

    db.commit()
    print(f"🗑️ {current_user.username} cleared {count} notifications (friend requests preserved)")

    return {"status": "success", "message": f"Deleted {count} notifications"}
