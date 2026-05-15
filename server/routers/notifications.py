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
from models import User, Notification, UserNotificationSubscription
from routers.users import get_current_user

router = APIRouter(prefix="/api/notifications", tags=["notifications"])


# ==================== BELL SUBSCRIPTION SCHEMAS ====================

class BellSubscriptionUpdate(BaseModel):
    notify_posts: Optional[bool] = True
    notify_audio_rooms: Optional[bool] = True

class BellSubscriptionResponse(BaseModel):
    subscribed: bool
    notify_posts: bool = False
    notify_audio_rooms: bool = False


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


# ==================== BELL SUBSCRIPTIONS (Per-User) ====================


@router.get("/subscriptions/{target_id}", response_model=BellSubscriptionResponse)
def get_bell_subscription(
    target_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get bell notification subscription state for a user."""
    sub = db.query(UserNotificationSubscription).filter(
        UserNotificationSubscription.subscriber_id == current_user.id,
        UserNotificationSubscription.target_id == target_id
    ).first()
    
    if not sub:
        return BellSubscriptionResponse(
            subscribed=False,
            notify_posts=False,
            notify_audio_rooms=False
        )
    
    return BellSubscriptionResponse(
        subscribed=True,
        notify_posts=sub.notify_posts,
        notify_audio_rooms=sub.notify_audio_rooms
    )


@router.post("/subscriptions/{target_id}", response_model=BellSubscriptionResponse)
def update_bell_subscription(
    target_id: str,
    update: BellSubscriptionUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Create or update bell notification subscription for a user.
    
    If no subscription exists, creates one. If one exists, updates it.
    Also creates/updates the legacy PostSubscription for backwards compat.
    """
    # Validate target user exists
    target = db.query(User).filter(User.id == target_id).first()
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    
    # Can't subscribe to yourself
    if target_id == current_user.id:
        raise HTTPException(status_code=400, detail="Cannot subscribe to yourself")
    
    # Upsert subscription
    sub = db.query(UserNotificationSubscription).filter(
        UserNotificationSubscription.subscriber_id == current_user.id,
        UserNotificationSubscription.target_id == target_id
    ).first()
    
    if sub:
        if update.notify_posts is not None:
            sub.notify_posts = update.notify_posts
        if update.notify_audio_rooms is not None:
            sub.notify_audio_rooms = update.notify_audio_rooms
        sub.updated_at = datetime.utcnow()
    else:
        sub = UserNotificationSubscription(
            subscriber_id=current_user.id,
            target_id=target_id,
            notify_posts=update.notify_posts if update.notify_posts is not None else True,
            notify_audio_rooms=update.notify_audio_rooms if update.notify_audio_rooms is not None else True
        )
        db.add(sub)
    
    # Sync with legacy PostSubscription for backwards compatibility
    from models import PostSubscription
    legacy_sub = db.query(PostSubscription).filter(
        PostSubscription.subscriber_id == current_user.id,
        PostSubscription.target_id == target_id
    ).first()
    
    if sub.notify_posts:
        if not legacy_sub:
            legacy_sub = PostSubscription(
                subscriber_id=current_user.id,
                target_id=target_id,
                enabled=True
            )
            db.add(legacy_sub)
        else:
            legacy_sub.enabled = True
    elif legacy_sub:
        legacy_sub.enabled = False
    
    db.commit()
    
    print(f"🔔 Bell subscription updated: {current_user.username} → @{target.username} "
          f"(posts={sub.notify_posts}, audio={sub.notify_audio_rooms})")
    
    return BellSubscriptionResponse(
        subscribed=True,
        notify_posts=sub.notify_posts,
        notify_audio_rooms=sub.notify_audio_rooms
    )


@router.delete("/subscriptions/{target_id}")
def delete_bell_subscription(
    target_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Remove bell notification subscription for a user."""
    sub = db.query(UserNotificationSubscription).filter(
        UserNotificationSubscription.subscriber_id == current_user.id,
        UserNotificationSubscription.target_id == target_id
    ).first()
    
    if sub:
        db.delete(sub)
    
    # Also disable legacy PostSubscription
    from models import PostSubscription
    legacy_sub = db.query(PostSubscription).filter(
        PostSubscription.subscriber_id == current_user.id,
        PostSubscription.target_id == target_id
    ).first()
    if legacy_sub:
        legacy_sub.enabled = False
    
    db.commit()
    
    target = db.query(User).filter(User.id == target_id).first()
    target_name = target.username if target else target_id[:8]
    print(f"🔕 Bell subscription removed: {current_user.username} → @{target_name}")

    return {"status": "success", "message": "Bell subscription removed"}


# ============================================================================
# Privacy & Safety event endpoints (added 2026-05-14)
#
# These let the iOS app emit best-effort signals — screenshot detected,
# profile viewed — that get fanned out to the target user as a push +
# stored notification. The recipient's notification preference is
# checked before any push goes out (see APNsService.should_send_push).
# ============================================================================

class ScreenshotEventBody(BaseModel):
    """The viewer is the *current* user (extracted from auth). The body
    only carries what the viewer was looking at when the system fired
    the screenshot signal."""
    scope: str  # 'profile' | 'chat'
    target_user_id: Optional[str] = None  # required for scope='profile'
    room_id: Optional[str] = None         # required for scope='chat'


@router.post("/screenshot")
async def report_screenshot(
    body: ScreenshotEventBody,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Called by iOS when `UIApplication.userDidTakeScreenshotNotification`
    fires inside a profile or chat. Best-effort — iOS only emits this
    while the app is foreground, so we treat it as a heads-up rather
    than a hard guarantee.

    Recipients:
    - scope='profile' → only the profile owner gets pinged.
    - scope='chat'    → all OTHER members of the room get pinged. For a
                        1:1 that's the peer; for a group, every member
                        except the screenshotter.
    """
    if body.scope not in ("profile", "chat"):
        raise HTTPException(status_code=400, detail="scope must be 'profile' or 'chat'")

    # Lazy import to avoid pulling apns when not configured locally.
    from services.apns_service import get_apns_service, APNsService

    targets: List[User] = []
    if body.scope == "profile":
        if not body.target_user_id:
            raise HTTPException(status_code=400, detail="target_user_id required for scope='profile'")
        # Self-screenshot is harmless — drop silently so we don't notify yourself.
        if body.target_user_id == current_user.id:
            return {"status": "self_screenshot_ignored"}
        owner = db.query(User).filter(User.id == body.target_user_id).first()
        if owner:
            targets.append(owner)
    else:
        if not body.room_id:
            raise HTTPException(status_code=400, detail="room_id required for scope='chat'")
        # 1:1 room ids are sorted "uidA_uidB"; for groups, look up members.
        if "_" in body.room_id and "-" not in body.room_id.split("_")[0]:
            parts = body.room_id.split("_")
            if len(parts) == 2:
                peer_id = parts[1] if parts[0] == current_user.id else parts[0]
                peer = db.query(User).filter(User.id == peer_id).first()
                if peer:
                    targets.append(peer)
        # Group case is best-effort — not all deployments expose a
        # group-members API path here. Skip for now, comes in a follow-up.

    apns = get_apns_service()
    sent = 0
    for target in targets:
        if not target.push_token:
            continue
        gate = APNsService.should_send_push(target, "screenshot_chat" if body.scope == "chat" else "screenshot_profile")
        if not gate["allowed"]:
            continue
        ok = await apns.send_screenshot_notification(
            device_token=target.push_token,
            viewer_name=current_user.username or "Someone",
            viewer_id=current_user.id,
            scope=body.scope,
            room_id=body.room_id,
            push_environment=target.push_environment,
        )
        # Persist the in-app notification so it shows in NotificationsListView too.
        n = Notification(
            user_id=target.id,
            type=("screenshot_chat" if body.scope == "chat" else "screenshot_profile"),
            data=json.dumps({
                "viewer_id": current_user.id,
                "viewer_username": current_user.username,
                "room_id": body.room_id,
            }),
        )
        db.add(n)
        sent += int(ok)
    db.commit()
    return {"status": "ok", "delivered": sent, "targeted": len(targets)}


class ProfileViewEventBody(BaseModel):
    """Posted by iOS when a user opens someone else's profile. The
    server filters out friend-views because seeing 'X viewed you'
    every time a friend opens your profile is noise."""
    target_user_id: str


@router.post("/profile-view")
async def report_profile_view(
    body: ProfileViewEventBody,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Notify the profile owner (only when viewer is NOT a friend AND
    the owner has profile_view_notifications_enabled — that toggle is
    OFF by default to avoid stalker-friendly UX)."""
    if body.target_user_id == current_user.id:
        return {"status": "self_view_ignored"}

    owner = db.query(User).filter(User.id == body.target_user_id).first()
    if not owner:
        raise HTTPException(status_code=404, detail="User not found")

    # Skip if friends — a friend opening your profile shouldn't ping.
    # The Friendship model lives in models.py; we query both directions.
    from models import Friendship
    is_friend = (
        db.query(Friendship)
        .filter(
            ((Friendship.requester_id == current_user.id) & (Friendship.addressee_id == owner.id))
            | ((Friendship.requester_id == owner.id) & (Friendship.addressee_id == current_user.id))
        )
        .filter(Friendship.status == "accepted")
        .first()
    )
    if is_friend:
        return {"status": "friend_view_ignored"}

    from services.apns_service import get_apns_service, APNsService
    gate = APNsService.should_send_push(owner, "profile_view")
    if not gate["allowed"]:
        return {"status": "preference_disabled"}

    if owner.push_token:
        apns = get_apns_service()
        await apns.send_profile_view_notification(
            device_token=owner.push_token,
            viewer_name=current_user.username or "Someone",
            viewer_id=current_user.id,
            push_environment=owner.push_environment,
        )

    n = Notification(
        user_id=owner.id,
        type="profile_view",
        data=json.dumps({
            "viewer_id": current_user.id,
            "viewer_username": current_user.username,
        }),
    )
    db.add(n)
    db.commit()
    return {"status": "ok"}
