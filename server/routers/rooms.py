"""
Audio Rooms API - Clubhouse-like voice rooms with presentation support.

Features:
- Create/join/leave audio rooms
- Anonymous mode for privacy
- Raise hand to speak
- Host controls (mute, kick, promote/demote)
- PDF/Image presentation sharing
"""

from fastapi import APIRouter, Depends, HTTPException, status, UploadFile, File
from sqlalchemy.orm import Session
from sqlalchemy import and_, or_
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime
import uuid
import random
import os

from database import get_db
from models import User, AudioRoom, AudioRoomParticipant, AudioRoomRequest, AudioRoomAsset, Post
from routers.users import get_current_user
from encryption import decrypt_text
from ws_manager import ws_manager  # singleton — needed for real-time fan-out
from services.livekit_service import get_livekit_control  # SFU server-side controls
import secrets
import string

router = APIRouter(prefix="/api/rooms", tags=["audio-rooms"])


# ──────────────────────────────────────────────────────────────────────────
# REAL-TIME FAN-OUT
#
# Every room state-change endpoint (join / leave / raise-hand / role / mute /
# kick / end / mute-all) uses this helper to push an instant event to every
# CURRENT participant via the existing /ws/inbox WebSocket. iOS subscribes
# once, pivots on `event.type == "room_event"`, and refreshes its room state
# without waiting up to 5 s for the next poll.
#
# Hidden ("ghost") participants are excluded from broadcasts about themselves
# but DO receive other participants' events (so their UI stays fresh).
# ──────────────────────────────────────────────────────────────────────────
async def _broadcast_room_event(
    db: Session,
    room_id: str,
    payload: dict,
    *,
    exclude_user_id: Optional[str] = None,
):
    """Push a `room_event` envelope to every current participant of a room."""
    try:
        rows = db.query(AudioRoomParticipant.user_id).filter(
            AudioRoomParticipant.room_id == room_id,
            AudioRoomParticipant.left_at.is_(None),
        ).all()
        recipients = [r[0] for r in rows if r[0] != exclude_user_id]
        if not recipients:
            return
        for uid in recipients:
            await ws_manager.notify(uid, payload)
    except Exception as e:
        # Best-effort — don't fail the host action just because WS fan-out
        # didn't reach someone. Polling fallback still catches them.
        print(f"⚠️ [Rooms] WS fan-out failed for room {room_id[:8]}: {e}")

# ==================== ANONYMOUS NAMES ====================

ANONYMOUS_ANIMALS = [
    "Fox", "Owl", "Bear", "Wolf", "Penguin", "Rabbit", "Koala", 
    "Panda", "Tiger", "Eagle", "Dolphin", "Phoenix", "Dragon",
    "Falcon", "Raven", "Lion", "Leopard", "Hawk", "Panther", "Lynx"
]

def generate_anonymous_name() -> tuple[str, int]:
    """Generate anonymous display name and avatar index."""
    animal = random.choice(ANONYMOUS_ANIMALS)
    number = random.randint(10, 99)
    avatar_index = ANONYMOUS_ANIMALS.index(animal)
    return f"Anonymous {animal} #{number}", avatar_index


def get_user_display_name(user) -> str:
    """Get decrypted display name for a user."""
    if not user:
        return "Unknown"
    
    try:
        first_name = decrypt_text(user.first_name) if user.first_name else ""
        last_name = decrypt_text(user.last_name) if user.last_name else ""
        
        # Handle decrypt failures and "None" strings
        if first_name in ("[DECRYPT_FAILED]", "None", "null", ""):
            first_name = ""
        if last_name in ("[DECRYPT_FAILED]", "None", "null", ""):
            last_name = ""
        
        # Filter out encrypted blobs that start with gAAAA
        if first_name.startswith("gAAAA"):
            first_name = ""
        if last_name.startswith("gAAAA"):
            last_name = ""
        
        full_name = f"{first_name} {last_name}".strip()
        
        # Fallback order: full_name -> username -> "User + short id"
        if not full_name:
            if user.username:
                return user.username
            return f"User • {str(user.id)[:6]}"
        
        return full_name
    except Exception as e:
        print(f"❌ Error decrypting user name: {e}")
        return user.username or f"User • {str(user.id)[:6]}"


# ==================== REQUEST/RESPONSE MODELS ====================

class CreateRoomRequest(BaseModel):
    title: str
    description: Optional[str] = None
    room_image_url: Optional[str] = None
    privacy: str = "public"  # public, friends, invite
    allow_anonymous: bool = True
    allow_raise_hand: bool = True
    max_participants: int = 100


class RoomResponse(BaseModel):
    id: str
    title: str
    description: Optional[str]
    host_user_id: str
    host_name: Optional[str]
    host_avatar: Optional[str]
    room_image_url: Optional[str]
    privacy: str
    allow_anonymous: bool
    allow_raise_hand: bool
    is_live: bool
    participant_count: int
    max_participants: int
    created_at: datetime
    share_slug: Optional[str] = None
    
    class Config:
        from_attributes = True


class ParticipantResponse(BaseModel):
    id: str
    user_id: str
    display_name: str
    avatar_url: Optional[str]
    display_mode: str
    role: str
    is_muted: bool
    is_hand_raised: bool
    joined_at: datetime
    
    class Config:
        from_attributes = True


class JoinRoomRequest(BaseModel):
    anonymous: bool = False
    is_stealth: bool = False  # Ghost Mode: join but hidden from participant list (premium only)


class RaiseHandRequest(BaseModel):
    raised: bool = True


class ChangeRoleRequest(BaseModel):
    role: str  # speaker, listener, cohost


class RoomDetailResponse(BaseModel):
    room: RoomResponse
    participants: List[ParticipantResponse]
    pending_requests: int
    active_asset: Optional[dict]


# ==================== ROOM CRUD ====================

@router.post("", response_model=RoomResponse)
async def create_room(
    req: CreateRoomRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Create a new audio room. Creator becomes host.
    
    For public/friends rooms, automatically creates a Post in the feed.
    For invite-only rooms, no post is created - only share link.
    """
    
    # Generate unique share slug (8 chars, alphanumeric)
    def generate_slug():
        chars = string.ascii_lowercase + string.digits
        return ''.join(secrets.choice(chars) for _ in range(8))
    
    share_slug = generate_slug()
    # Ensure uniqueness
    while db.query(AudioRoom).filter(AudioRoom.share_slug == share_slug).first():
        share_slug = generate_slug()
    
    # ═══ Premium capacity cap (free: 100, premium: 5000) ═══
    max_cap = 5000 if current_user.is_premium else 100
    clamped_max = min(req.max_participants, max_cap)
    
    room = AudioRoom(
        title=req.title,
        description=req.description,
        host_user_id=current_user.id,
        room_image_url=req.room_image_url,
        privacy=req.privacy,
        allow_anonymous=req.allow_anonymous,
        allow_raise_hand=req.allow_raise_hand,
        max_participants=clamped_max,
        share_slug=share_slug,
        is_live=True,
        participant_count=1  # Host counts
    )
    
    db.add(room)
    db.flush()
    
    # Add host as participant
    host_participant = AudioRoomParticipant(
        room_id=room.id,
        user_id=current_user.id,
        display_mode="real",
        role="host",
        is_muted=False
    )
    db.add(host_participant)
    
    # Auto-create Post for public/friends rooms (NOT invite-only)
    if req.privacy in ("public", "friends"):
        room_post = Post(
            author_id=current_user.id,
            content=f"🎙️ {req.title}",  # Room title as post content
            post_type="room",
            room_id=room.id,
            visibility=req.privacy,  # 'public' or 'friends'
            latitude=current_user.latitude if hasattr(current_user, 'latitude') else None,
            longitude=current_user.longitude if hasattr(current_user, 'longitude') else None,
            geohash=current_user.geohash if hasattr(current_user, 'geohash') else None
        )
        db.add(room_post)
        print(f"📝 Created room post in {req.privacy} feed")
    
    db.commit()
    db.refresh(room)
    
    print(f"🎙️ Audio room created: '{room.title}' by {current_user.username} (slug: {share_slug})")
    
    # 🔔 Notify bell subscribers (audio room notifications)
    from models import UserNotificationSubscription, Notification
    bell_subs = db.query(UserNotificationSubscription).filter(
        UserNotificationSubscription.target_id == current_user.id,
        UserNotificationSubscription.notify_audio_rooms == True
    ).all()
    
    if bell_subs:
        from services.apns_service import get_apns_service, APNsService
        import json
        apns = get_apns_service()
        host_name = get_user_display_name(current_user)
        
        for sub in bell_subs:
            # Create in-app notification
            notif_data = json.dumps({
                "roomId": room.id,
                "hostId": current_user.id,
                "hostUsername": current_user.username,
                "roomTitle": room.title
            })
            notification = Notification(
                user_id=sub.subscriber_id,
                type="audio_room",
                data=notif_data,
                is_read=False
            )
            db.add(notification)
            
            # Send push
            subscriber_user = db.query(User).filter(User.id == sub.subscriber_id).first()
            if subscriber_user and subscriber_user.push_token and subscriber_user.push_platform == "ios":
                prefs = APNsService.should_send_push(subscriber_user, "audio_room")
                if prefs["allowed"]:
                    try:
                        push_result = await apns.send_audio_room_notification(
                            device_token=subscriber_user.push_token,
                            host_name=host_name,
                            room_title=room.title,
                            room_id=room.id,
                            host_id=current_user.id,
                            badge=APNsService.get_unread_badge_count(db, sub.subscriber_id)
                        )
                        print(f"🔔 [PUSH] event=audio_room sender={current_user.id[:8]} "
                              f"receiver={sub.subscriber_id[:8]} status={'sent' if push_result else 'failed'}")
                    except Exception as e:
                        print(f"🔔 [PUSH] event=audio_room sender={current_user.id[:8]} "
                              f"receiver={sub.subscriber_id[:8]} status=error reason={e}")
                else:
                    print(f"🔔 [PUSH] event=audio_room receiver={sub.subscriber_id[:8]} status=skipped reason=disabled")
        
        db.commit()
        print(f"🔔 Notified {len(bell_subs)} audio room subscribers for @{current_user.username}")
    
    return RoomResponse(
        id=room.id,
        title=room.title,
        description=room.description,
        host_user_id=room.host_user_id,
        host_name=get_user_display_name(current_user),
        host_avatar=current_user.avatar_path,
        room_image_url=room.room_image_url,
        privacy=room.privacy,
        allow_anonymous=room.allow_anonymous,
        allow_raise_hand=room.allow_raise_hand,
        is_live=room.is_live,
        participant_count=room.participant_count,
        max_participants=room.max_participants,
        created_at=room.created_at,
        share_slug=room.share_slug
    )


# ==================== HEARTBEAT (Auto-close support) ====================

@router.post("/{room_id}/heartbeat")
def room_heartbeat(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Client sends heartbeat every ~15s to indicate active participation.
    
    Updates participant's last_heartbeat_at and room's last_activity.
    Used by background cleanup job to detect and close stale rooms.
    """
    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.left_at.is_(None)
    ).first()
    
    if not participant:
        raise HTTPException(status_code=404, detail="Not in room")
    
    now = datetime.utcnow()
    participant.last_heartbeat_at = now
    
    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if room:
        room.last_activity = now
    
    db.commit()
    
    return {"success": True}


@router.get("", response_model=List[RoomResponse])
def list_rooms(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    privacy: Optional[str] = None
):
    """List all live audio rooms."""
    
    # Cleanup: mark stale participants (no heartbeat for >30s) as left
    from datetime import timedelta
    stale_threshold = datetime.utcnow() - timedelta(seconds=30)
    
    stale_participants = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.left_at.is_(None),
        AudioRoomParticipant.last_heartbeat_at != None,
        AudioRoomParticipant.last_heartbeat_at < stale_threshold
    ).all()
    
    affected_room_ids = set()
    for p in stale_participants:
        p.left_at = datetime.utcnow()
        affected_room_ids.add(p.room_id)
        print(f"💀 Stale participant removed: user {p.user_id[:8]} from room {p.room_id[:8]}")
    
    # Recalculate participant counts for affected rooms
    for rid in affected_room_ids:
        active_count = db.query(AudioRoomParticipant).filter(
            AudioRoomParticipant.room_id == rid,
            AudioRoomParticipant.left_at.is_(None)
        ).count()
        room = db.query(AudioRoom).filter(AudioRoom.id == rid).first()
        if room:
            room.participant_count = active_count
    
    if stale_participants:
        db.commit()
    
    # Cleanup: close any rooms with 0 participants
    empty_rooms = db.query(AudioRoom).filter(
        AudioRoom.is_live == True,
        AudioRoom.participant_count <= 0
    ).all()
    
    for room in empty_rooms:
        room.is_live = False
        room.ended_at = datetime.utcnow()
        # Hide associated room post from feeds
        room_post = db.query(Post).filter(Post.room_id == room.id).first()
        if room_post:
            room_post.is_hidden = True
        print(f"🧹 Auto-closed empty room: '{room.title}'")
    
    if empty_rooms:
        db.commit()
    
    # Now query live rooms
    query = db.query(AudioRoom).filter(
        AudioRoom.is_live == True,
        AudioRoom.participant_count > 0
    )
    
    if privacy:
        query = query.filter(AudioRoom.privacy == privacy)
    else:
        # Default: only show public rooms (exclude friends & invite)
        query = query.filter(AudioRoom.privacy.notin_(["friends", "invite"]))
    
    rooms = query.order_by(AudioRoom.created_at.desc()).limit(50).all()
    
    result = []
    for room in rooms:
        host = db.query(User).filter(User.id == room.host_user_id).first()
        result.append(RoomResponse(
            id=room.id,
            title=room.title,
            description=room.description,
            host_user_id=room.host_user_id,
            host_name=get_user_display_name(host),
            host_avatar=host.avatar_path if host else None,
            room_image_url=room.room_image_url,
            privacy=room.privacy,
            allow_anonymous=room.allow_anonymous,
            allow_raise_hand=room.allow_raise_hand,
            is_live=room.is_live,
            participant_count=room.participant_count,
            max_participants=room.max_participants,
            created_at=room.created_at,
            share_slug=room.share_slug
        ))
    
    return result


@router.get("/friends/rooms", response_model=List[RoomResponse])
def list_friends_rooms(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """List live audio rooms from friends (friends-only privacy)."""
    from models import FriendRequest
    
    # Get list of accepted friend user IDs (using FriendRequest, NOT Friendship)
    # The friendships table may be empty — friend status is tracked via friend_requests
    sent = db.query(FriendRequest.recipient_id).filter(
        FriendRequest.requester_id == current_user.id,
        FriendRequest.status == "accepted"
    ).all()
    received = db.query(FriendRequest.requester_id).filter(
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "accepted"
    ).all()
    
    friend_ids = set([f[0] for f in sent] + [f[0] for f in received])
    # Include self so creators can see their own friends-only rooms
    friend_ids.add(current_user.id)
    
    # Query rooms hosted by friends with friends privacy
    rooms = db.query(AudioRoom).filter(
        AudioRoom.is_live == True,
        AudioRoom.participant_count > 0,
        AudioRoom.privacy == "friends",
        AudioRoom.host_user_id.in_(friend_ids)
    ).order_by(AudioRoom.created_at.desc()).limit(50).all()
    
    result = []
    for room in rooms:
        host = db.query(User).filter(User.id == room.host_user_id).first()
        result.append(RoomResponse(
            id=room.id,
            title=room.title,
            description=room.description,
            host_user_id=room.host_user_id,
            host_name=get_user_display_name(host),
            host_avatar=host.avatar_path if host else None,
            room_image_url=room.room_image_url,
            privacy=room.privacy,
            allow_anonymous=room.allow_anonymous,
            allow_raise_hand=room.allow_raise_hand,
            is_live=room.is_live,
            participant_count=room.participant_count,
            max_participants=room.max_participants,
            created_at=room.created_at,
            share_slug=room.share_slug
        ))
    
    print(f"📻 Fetched {len(result)} friends-only rooms for {current_user.username}")
    return result


class InviteLinkResponse(BaseModel):
    invite_link: str
    room_id: str
    expires_at: Optional[datetime] = None


@router.post("/{room_id}/invite-link", response_model=InviteLinkResponse)
def generate_invite_link(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Generate a shareable invite link for invite-only rooms."""
    
    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    
    # Only host or cohost can generate invite links
    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role.in_(["host", "cohost"])
    ).first()
    
    if not participant:
        raise HTTPException(status_code=403, detail="Only host/cohost can generate invite links")
    
    # Use share_slug for deep link (shorter, friendlier URLs)
    invite_link = f"raven://room/{room.share_slug or room.id}"
    
    print(f"🔗 Generated invite link for room '{room.title}'")
    
    return InviteLinkResponse(
        invite_link=invite_link,
        room_id=room_id,
        expires_at=None  # Links don't expire for now
    )


@router.get("/join/{share_slug}", response_model=RoomResponse)
def join_by_slug(
    share_slug: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Resolve share_slug to room for deep link join.
    
    Used by iOS Universal Links / deep links to resolve
    raven://room/{share_slug} to the actual room.
    """
    
    # Try share_slug first, fall back to room_id
    room = db.query(AudioRoom).filter(AudioRoom.share_slug == share_slug).first()
    if not room:
        # Fallback: maybe it's a direct room_id
        room = db.query(AudioRoom).filter(AudioRoom.id == share_slug).first()
    
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    
    if not room.is_live:
        raise HTTPException(status_code=400, detail="Room has ended")
    
    host = db.query(User).filter(User.id == room.host_user_id).first()
    
    print(f"🔗 Deep link resolved: {share_slug} -> room '{room.title}'")
    
    return RoomResponse(
        id=room.id,
        title=room.title,
        description=room.description,
        host_user_id=room.host_user_id,
        host_name=get_user_display_name(host),
        host_avatar=host.avatar_path if host else None,
        room_image_url=room.room_image_url,
        privacy=room.privacy,
        allow_anonymous=room.allow_anonymous,
        allow_raise_hand=room.allow_raise_hand,
        is_live=room.is_live,
        participant_count=room.participant_count,
        max_participants=room.max_participants,
        created_at=room.created_at,
        share_slug=room.share_slug
    )


@router.get("/{room_id}", response_model=RoomDetailResponse)
def get_room(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get room details with participants."""
    
    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    
    # Get host info
    host = db.query(User).filter(User.id == room.host_user_id).first()
    
    # Get participants (exclude hidden/stealth users from the list)
    participants = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.left_at.is_(None),
        AudioRoomParticipant.display_mode != "hidden"  # Ghost Mode: exclude stealth joins
    ).all()
    
    participant_list = []
    for p in participants:
        if p.display_mode == "anonymous":
            display_name = p.anon_display_name
            avatar_url = f"/avatars/anonymous/{p.anon_avatar_index}.png"
        else:
            user = db.query(User).filter(User.id == p.user_id).first()
            display_name = get_user_display_name(user)
            avatar_url = user.avatar_path if user else None
        
        # Bug 15 fix: always return real user_id so host controls can target the participant.
        # Privacy is maintained by hiding the display_name, not the user_id — the host
        # needs the real ID to mute/kick/promote.
        participant_list.append(ParticipantResponse(
            id=p.id,
            user_id=p.user_id,
            display_name=display_name,
            avatar_url=avatar_url,
            display_mode=p.display_mode,
            role=p.role,
            is_muted=p.is_muted,
            is_hand_raised=p.is_hand_raised,
            joined_at=p.joined_at
        ))
    
    # Count pending requests
    pending_requests = db.query(AudioRoomRequest).filter(
        AudioRoomRequest.room_id == room_id,
        AudioRoomRequest.status == "pending"
    ).count()
    
    # Get active asset
    active_asset = db.query(AudioRoomAsset).filter(
        AudioRoomAsset.room_id == room_id,
        AudioRoomAsset.is_active == True
    ).first()
    
    return RoomDetailResponse(
        room=RoomResponse(
            id=room.id,
            title=room.title,
            description=room.description,
            host_user_id=room.host_user_id,
            host_name=get_user_display_name(host),
            host_avatar=host.avatar_path if host else None,
            room_image_url=room.room_image_url,
            privacy=room.privacy,
            allow_anonymous=room.allow_anonymous,
            allow_raise_hand=room.allow_raise_hand,
            is_live=room.is_live,
            participant_count=room.participant_count,
            max_participants=room.max_participants,
            created_at=room.created_at,
            share_slug=room.share_slug  # Bug 4 fix: include share_slug
        ),
        participants=participant_list,
        pending_requests=pending_requests,
        active_asset={
            "id": active_asset.id,
            "type": active_asset.type,
            "url": active_asset.url,
            "file_name": active_asset.file_name
        } if active_asset else None
    )


# ==================== JOIN/LEAVE ====================

@router.post("/{room_id}/join", response_model=ParticipantResponse)
async def join_room(
    room_id: str,
    req: JoinRoomRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Join an audio room."""

    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")

    if not room.is_live:
        raise HTTPException(status_code=400, detail="Room has ended")

    # 🔒 Enforce is_locked — was settable via /settings but never checked
    # at the join boundary, so "lock room" was a no-op host control.
    if getattr(room, "is_locked", False) and room.host_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Room is locked by the host")

    if room.participant_count >= room.max_participants:
        raise HTTPException(status_code=400, detail="Room is full")
    
    # Check if already in room
    existing = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.left_at.is_(None)
    ).first()
    
    if existing:
        raise HTTPException(status_code=400, detail="Already in room")
    
    # Determine display mode
    anon_name = None
    anon_avatar = None
    
    if req.is_stealth and current_user.is_premium:
        display_mode = "hidden"  # Ghost Mode: not visible in participant list
        print(f"👻 [Ghost Mode] {current_user.username} joined room '{room.title}' in stealth")
    elif req.anonymous and room.allow_anonymous:
        display_mode = "anonymous"
    else:
        display_mode = "real"
    
    # Generate anonymous identity if requested
    if display_mode == "anonymous":
        anon_name, anon_avatar = generate_anonymous_name()
    
    participant = AudioRoomParticipant(
        room_id=room_id,
        user_id=current_user.id,
        display_mode=display_mode,
        anon_display_name=anon_name,
        anon_avatar_index=anon_avatar,
        role="listener",
        is_muted=True
    )
    
    db.add(participant)
    # Hidden participants don't count toward visible participant count
    if display_mode != "hidden":
        room.participant_count += 1
    db.commit()
    db.refresh(participant)
    
    print(f"👤 {current_user.username} joined room '{room.title}' ({display_mode})")

    # ⚡ REAL-TIME WS FAN-OUT — was a TODO, now wired.
    # Push a "room_event" envelope to every other current participant.
    # Clients subscribed via /ws/inbox already (for messages) reuse the
    # same channel and pivot on `type == "room_event"` to refresh the
    # room state instantly instead of waiting up to 5 s for the poll.
    if display_mode != "hidden":
        await _broadcast_room_event(db, room_id, {
            "type": "room_event",
            "event": "join",
            "room_id": room_id,
            "user_id": current_user.id,
            "display_name": (participant.anon_display_name if display_mode == "anonymous"
                             else get_user_display_name(current_user)),
            "role": participant.role,
            "is_muted": participant.is_muted,
        }, exclude_user_id=current_user.id)

    if participant.display_mode == "anonymous":
        display_name = participant.anon_display_name
        avatar_url = f"/avatars/anonymous/{participant.anon_avatar_index}.png"
    else:
        display_name = get_user_display_name(current_user)
        avatar_url = current_user.avatar_path
    
    # Bug 15 fix: always return real user_id so host controls work
    return ParticipantResponse(
        id=participant.id,
        user_id=participant.user_id,
        display_name=display_name,
        avatar_url=avatar_url,
        display_mode=participant.display_mode,
        role=participant.role,
        is_muted=participant.is_muted,
        is_hand_raised=participant.is_hand_raised,
        joined_at=participant.joined_at
    )


@router.post("/{room_id}/leave")
async def leave_room(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Leave an audio room."""

    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.left_at.is_(None)
    ).first()

    if not participant:
        raise HTTPException(status_code=404, detail="Not in room")

    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()

    participant.left_at = datetime.utcnow()

    # Bug 13 fix: only decrement count for visible participants (not ghost/hidden)
    if participant.display_mode != "hidden":
        room.participant_count = max(0, room.participant_count - 1)

    # Auto-close room if empty OR if host leaves
    room_ended = False
    if room.participant_count == 0 or participant.role == "host":
        room.is_live = False
        room.ended_at = datetime.utcnow()
        room_ended = True

        # Bug 9 fix: mark ALL remaining participants as left when room closes
        db.query(AudioRoomParticipant).filter(
            AudioRoomParticipant.room_id == room_id,
            AudioRoomParticipant.left_at.is_(None)
        ).update({"left_at": datetime.utcnow()})

        # Hide the auto-created room post from feeds
        room_post = db.query(Post).filter(Post.room_id == room_id).first()
        if room_post:
            room_post.is_hidden = True
        print(f"🔴 Room '{room.title}' ended (empty or host left)")

    db.commit()

    print(f"👋 {current_user.username} left room '{room.title}'")

    # ⚡ Real-time fan-out + LiveKit cleanup
    if room_ended:
        # Tell every other participant the room is dead RIGHT NOW.
        await _broadcast_room_event(db, room_id, {
            "type": "room_event",
            "event": "ended",
            "room_id": room_id,
        })
        # Disconnect everyone from the SFU. Without this, clients keep
        # streaming audio into a phantom room until they poll and notice.
        await get_livekit_control().delete_room(room_id)
    elif participant.display_mode != "hidden":
        await _broadcast_room_event(db, room_id, {
            "type": "room_event",
            "event": "leave",
            "room_id": room_id,
            "user_id": current_user.id,
        }, exclude_user_id=current_user.id)

    return {"success": True, "room_ended": room_ended}


# ==================== RAISE HAND ====================

@router.post("/{room_id}/raise-hand")
async def raise_hand(
    room_id: str,
    req: RaiseHandRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Raise or lower hand to request speaking."""

    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.left_at.is_(None)
    ).first()

    if not participant:
        raise HTTPException(status_code=404, detail="Not in room")

    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()

    if not room.allow_raise_hand:
        raise HTTPException(status_code=400, detail="Raise hand not allowed in this room")

    participant.is_hand_raised = req.raised

    if req.raised:
        existing_request = db.query(AudioRoomRequest).filter(
            AudioRoomRequest.room_id == room_id,
            AudioRoomRequest.user_id == current_user.id,
            AudioRoomRequest.status == "pending"
        ).first()

        if not existing_request:
            request = AudioRoomRequest(
                room_id=room_id,
                user_id=current_user.id,
                status="pending"
            )
            db.add(request)
    else:
        db.query(AudioRoomRequest).filter(
            AudioRoomRequest.room_id == room_id,
            AudioRoomRequest.user_id == current_user.id,
            AudioRoomRequest.status == "pending"
        ).update({"status": "cancelled"})

    db.commit()

    print(f"✋ {current_user.username} {'raised' if req.raised else 'lowered'} hand in room '{room.title}'")

    # ⚡ Push to host(s) so the raise-hand badge appears instantly instead
    # of waiting up to 5 s for the next /requests poll.
    await _broadcast_room_event(db, room_id, {
        "type": "room_event",
        "event": "hand_raised" if req.raised else "hand_lowered",
        "room_id": room_id,
        "user_id": current_user.id,
        "display_name": (participant.anon_display_name if participant.display_mode == "anonymous"
                         else get_user_display_name(current_user)),
    })

    return {"success": True, "hand_raised": req.raised}


@router.get("/{room_id}/requests", response_model=List[dict])
def get_requests(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get pending raise hand requests (host only)."""
    
    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    
    # Check if current user is host or cohost
    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role.in_(["host", "cohost"])
    ).first()
    
    if not participant:
        raise HTTPException(status_code=403, detail="Only host/cohost can view requests")
    
    requests = db.query(AudioRoomRequest).filter(
        AudioRoomRequest.room_id == room_id,
        AudioRoomRequest.status == "pending"
    ).order_by(AudioRoomRequest.created_at.asc()).all()
    
    result = []
    for req in requests:
        p = db.query(AudioRoomParticipant).filter(
            AudioRoomParticipant.room_id == room_id,
            AudioRoomParticipant.user_id == req.user_id,
            AudioRoomParticipant.left_at.is_(None)
        ).first()
        
        if p:
            if p.display_mode == "anonymous":
                display_name = p.anon_display_name
            else:
                user = db.query(User).filter(User.id == req.user_id).first()
                display_name = get_user_display_name(user)
            
            result.append({
                "request_id": req.id,
                "user_id": req.user_id,
                "display_name": display_name,
                "created_at": req.created_at.isoformat()
            })
    
    return result


@router.post("/{room_id}/requests/{user_id}/accept")
async def accept_request(
    room_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Accept a raise hand request (host only)."""
    
    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    
    # Check if current user is host or cohost
    host_participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role.in_(["host", "cohost"])
    ).first()
    
    if not host_participant:
        raise HTTPException(status_code=403, detail="Only host/cohost can accept requests")
    
    # Update request
    request = db.query(AudioRoomRequest).filter(
        AudioRoomRequest.room_id == room_id,
        AudioRoomRequest.user_id == user_id,
        AudioRoomRequest.status == "pending"
    ).first()
    
    if request:
        request.status = "accepted"
        request.resolved_at = datetime.utcnow()
        request.resolved_by = current_user.id
    
    # Promote to speaker
    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == user_id,
        AudioRoomParticipant.left_at.is_(None)
    ).first()
    
    if participant:
        participant.role = "speaker"
        participant.is_hand_raised = False
        participant.is_muted = False

    db.commit()

    print(f"✅ Request accepted: {user_id} promoted to speaker")

    # ⚡ Push role-change to everyone — the promoted user gets it too so
    # iOS can flip the publish permission without a 5-s poll lag.
    await _broadcast_room_event(db, room_id, {
        "type": "room_event",
        "event": "role_changed",
        "room_id": room_id,
        "user_id": user_id,
        "new_role": "speaker",
        "is_muted": False,
    })

    return {"success": True}


@router.post("/{room_id}/requests/{user_id}/decline")
async def decline_request(
    room_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Decline a raise hand request (host only)."""
    
    # Check if current user is host or cohost
    host_participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role.in_(["host", "cohost"])
    ).first()
    
    if not host_participant:
        raise HTTPException(status_code=403, detail="Only host/cohost can decline requests")
    
    # Update request
    db.query(AudioRoomRequest).filter(
        AudioRoomRequest.room_id == room_id,
        AudioRoomRequest.user_id == user_id,
        AudioRoomRequest.status == "pending"
    ).update({
        "status": "declined",
        "resolved_at": datetime.utcnow(),
        "resolved_by": current_user.id
    })
    
    # Lower hand
    db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == user_id
    ).update({"is_hand_raised": False})
    
    db.commit()

    print(f"❌ Request declined: {user_id}")

    # Tell the requester their hand was lowered (UX clarity)
    await _broadcast_room_event(db, room_id, {
        "type": "room_event",
        "event": "hand_lowered",
        "room_id": room_id,
        "user_id": user_id,
        "by_host": True,
    })

    return {"success": True}


# ==================== HOST CONTROLS ====================

@router.post("/{room_id}/role/{user_id}")
async def change_role(
    room_id: str,
    user_id: str,
    req: ChangeRoleRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Change a participant's role (host only)."""

    host_participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role == "host"
    ).first()

    if not host_participant:
        raise HTTPException(status_code=403, detail="Only host can change roles")

    if req.role not in ["speaker", "listener", "cohost"]:
        raise HTTPException(status_code=400, detail="Invalid role")

    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == user_id,
        AudioRoomParticipant.left_at.is_(None)
    ).first()

    if not participant:
        raise HTTPException(status_code=404, detail="Participant not found")

    participant.role = req.role
    if req.role == "listener":
        participant.is_muted = True
        # Force-mute on the SFU when demoting to listener
        await get_livekit_control().mute_participant(room_id, user_id, muted=True)

    db.commit()

    # ⚡ Real-time fan-out — instant role change everywhere.
    # Note: clients also need a fresh LiveKit JWT when role changes
    # (publish permission is encoded in the token), so the iOS handler
    # of this event will re-fetch via /api/livekit/token.
    await _broadcast_room_event(db, room_id, {
        "type": "room_event",
        "event": "role_changed",
        "room_id": room_id,
        "user_id": user_id,
        "new_role": req.role,
        "is_muted": participant.is_muted,
        "needs_token_refresh": True,  # publish grant changed
    })
    
    print(f"🔄 Role changed: {user_id} → {req.role}")
    
    return {"success": True, "new_role": req.role}


class MuteRequest(BaseModel):
    muted: bool = True


@router.post("/{room_id}/mute/{user_id}")
async def mute_participant(
    room_id: str,
    user_id: str,
    req: MuteRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Mute/unmute a participant (host only, or self).

    Server now actually enforces the mute on the LiveKit SFU — previously
    the DB row flipped but the user's mic kept broadcasting until their
    own client polled and noticed.
    """

    is_self = user_id == current_user.id

    if not is_self:
        host_participant = db.query(AudioRoomParticipant).filter(
            AudioRoomParticipant.room_id == room_id,
            AudioRoomParticipant.user_id == current_user.id,
            AudioRoomParticipant.role.in_(["host", "cohost"])
        ).first()

        if not host_participant:
            raise HTTPException(status_code=403, detail="Only host/cohost can mute others")

    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == user_id,
        AudioRoomParticipant.left_at.is_(None)
    ).first()

    if not participant:
        raise HTTPException(status_code=404, detail="Participant not found")

    participant.is_muted = req.muted
    db.commit()

    print(f"🔇 {user_id} {'muted' if req.muted else 'unmuted'}")

    # 🛡️ Force-mute on the SFU when the host (not self) silences someone.
    # Self-mute doesn't need this — the muting client already toggles its
    # own mic via LiveKit's local API.
    if not is_self and req.muted:
        await get_livekit_control().mute_participant(room_id, user_id, muted=True)

    # ⚡ Real-time notify
    await _broadcast_room_event(db, room_id, {
        "type": "room_event",
        "event": "muted" if req.muted else "unmuted",
        "room_id": room_id,
        "user_id": user_id,
        "by": current_user.id,
    })

    return {"success": True, "is_muted": req.muted}


@router.post("/{room_id}/kick/{user_id}")
async def kick_participant(
    room_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Kick a participant from room (host only).

    Server now actually disconnects the kicked user from the LiveKit SFU
    instead of just flipping `left_at` — their mic dies immediately.
    """

    host_participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role.in_(["host", "cohost"])
    ).first()

    if not host_participant:
        raise HTTPException(status_code=403, detail="Only host/cohost can kick")

    # Can't kick the host
    if user_id == db.query(AudioRoom).filter(AudioRoom.id == room_id).first().host_user_id:
        raise HTTPException(status_code=400, detail="Cannot kick the host")

    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == user_id,
        AudioRoomParticipant.left_at.is_(None)
    ).first()

    if not participant:
        raise HTTPException(status_code=404, detail="Participant not found")

    # 🛡️ Cohost cannot kick another cohost — only the host can demote/kick a cohost.
    # Without this, two cohosts could initiate a kick war.
    if (
        host_participant.role == "cohost"
        and participant.role == "cohost"
        and current_user.id != user_id
    ):
        raise HTTPException(status_code=403, detail="Cohosts cannot kick other cohosts; only the host can")

    participant.left_at = datetime.utcnow()

    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    room.participant_count = max(0, room.participant_count - 1)

    db.commit()

    print(f"👢 {user_id} kicked from room")

    # Disconnect from the SFU — instant, not on next poll
    await get_livekit_control().remove_participant(room_id, user_id)

    # Notify everyone
    await _broadcast_room_event(db, room_id, {
        "type": "room_event",
        "event": "kicked",
        "room_id": room_id,
        "user_id": user_id,
        "by": current_user.id,
    })

    return {"success": True}


@router.post("/{room_id}/end")
async def end_room(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """End the room (host only).

    Now actually deletes the LiveKit SFU room — every client gets disconnected
    instantly, instead of streaming audio into a phantom room until they poll.
    """

    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")

    if room.host_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only host can end room")

    room.is_live = False
    room.ended_at = datetime.utcnow()

    # Mark all participants as left
    db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.left_at.is_(None)
    ).update({"left_at": datetime.utcnow()})

    # Hide the auto-created room post from feeds
    room_post = db.query(Post).filter(Post.room_id == room_id).first()
    if room_post:
        room_post.is_hidden = True

    db.commit()

    print(f"🔴 Room '{room.title}' ended by host")

    # Notify everyone the room is dead — BEFORE deleting the SFU room so
    # the recipient list is still in our DB (delete_room itself is best-
    # effort). Order: notify (uses DB), then SFU teardown.
    await _broadcast_room_event(db, room_id, {
        "type": "room_event",
        "event": "ended",
        "room_id": room_id,
        "by": current_user.id,
    })
    await get_livekit_control().delete_room(room_id)

    return {"success": True}


# ==================== MUTE ALL / SETTINGS ====================

@router.post("/{room_id}/mute-all")
async def mute_all_speakers(
    room_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Mute all speakers in the room (host/cohost only).

    Now also force-mutes them on the LiveKit SFU.
    """

    host_participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role.in_(["host", "cohost"]),
        AudioRoomParticipant.left_at.is_(None)
    ).first()

    if not host_participant:
        raise HTTPException(status_code=403, detail="Only host/cohost can mute all")

    # Snapshot the targets BEFORE the bulk update so we can call LiveKit
    # for each one (the .update() returns the count, not the rows).
    targets = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.left_at.is_(None),
        AudioRoomParticipant.role.in_(["speaker", "cohost"]),
        AudioRoomParticipant.user_id != current_user.id,
        AudioRoomParticipant.is_muted == False
    ).all()
    target_ids = [p.user_id for p in targets]

    count = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.id.in_([p.id for p in targets])
    ).update({"is_muted": True}, synchronize_session=False) if target_ids else 0

    db.commit()

    print(f"🔇 Muted {count} speakers in room {room_id[:8]}")

    # 🛡️ SFU enforcement — without this, "Mute all" was theatre.
    lk = get_livekit_control()
    for uid in target_ids:
        await lk.mute_participant(room_id, uid, muted=True)

    # ⚡ Real-time fan-out
    await _broadcast_room_event(db, room_id, {
        "type": "room_event",
        "event": "mute_all",
        "room_id": room_id,
        "muted_user_ids": target_ids,
        "by": current_user.id,
    })

    return {"success": True, "muted_count": count}


class UpdateSettingRequest(BaseModel):
    key: str
    value: bool


@router.post("/{room_id}/settings")
def update_room_settings(
    room_id: str,
    req: UpdateSettingRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Update a room setting (host only)."""
    
    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    
    if room.host_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only host can update settings")
    
    allowed_keys = {"is_locked", "allow_raise_hand", "allow_anonymous"}
    if req.key not in allowed_keys:
        raise HTTPException(status_code=400, detail=f"Invalid setting key. Allowed: {allowed_keys}")
    
    setattr(room, req.key, req.value)
    db.commit()
    
    print(f"⚙️ Room setting updated: {req.key} = {req.value}")
    return {"success": True, "key": req.key, "value": req.value}


# ==================== PRESENTATION ASSETS ====================

@router.post("/{room_id}/assets")
async def upload_asset(
    room_id: str,
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Upload a presentation asset (host only)."""
    
    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if not room:
        raise HTTPException(status_code=404, detail="Room not found")
    
    # Check if current user is host or cohost
    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role.in_(["host", "cohost"])
    ).first()
    
    if not participant:
        raise HTTPException(status_code=403, detail="Only host/cohost can upload assets")
    
    # Determine type
    if file.content_type and file.content_type.startswith("image/"):
        asset_type = "image"
    elif file.content_type == "application/pdf":
        asset_type = "pdf"
    else:
        raise HTTPException(status_code=400, detail="Only images and PDFs allowed")
    
    # Bug 12 fix: actually save the uploaded file to disk
    file_id = str(uuid.uuid4())
    upload_dir = os.path.join("uploads", "rooms", room_id)
    os.makedirs(upload_dir, exist_ok=True)
    
    safe_filename = f"{file_id}_{file.filename}"
    file_path = os.path.join(upload_dir, safe_filename)
    
    file_data = await file.read()
    with open(file_path, "wb") as f:
        f.write(file_data)
    
    url = f"/api/files/rooms/{room_id}/{safe_filename}"
    
    # Deactivate previous active asset
    db.query(AudioRoomAsset).filter(
        AudioRoomAsset.room_id == room_id,
        AudioRoomAsset.is_active == True
    ).update({"is_active": False})
    
    asset = AudioRoomAsset(
        room_id=room_id,
        type=asset_type,
        url=url,
        file_name=file.filename,
        file_size=len(file_data),
        is_active=True,
        uploaded_by=current_user.id
    )
    
    db.add(asset)
    db.commit()
    db.refresh(asset)
    
    print(f"📄 Asset uploaded: {file.filename} ({asset_type}, {len(file_data)} bytes)")
    
    return {
        "id": asset.id,
        "type": asset.type,
        "url": asset.url,
        "file_name": asset.file_name,
        "is_active": asset.is_active
    }


@router.post("/{room_id}/assets/{asset_id}/activate")
def activate_asset(
    room_id: str,
    asset_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Activate a presentation asset (host only)."""
    
    # Check if current user is host or cohost
    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.role.in_(["host", "cohost"])
    ).first()
    
    if not participant:
        raise HTTPException(status_code=403, detail="Only host/cohost can activate assets")
    
    # Deactivate all other assets
    db.query(AudioRoomAsset).filter(
        AudioRoomAsset.room_id == room_id
    ).update({"is_active": False})
    
    # Activate this asset
    asset = db.query(AudioRoomAsset).filter(
        AudioRoomAsset.id == asset_id,
        AudioRoomAsset.room_id == room_id
    ).first()
    
    if not asset:
        raise HTTPException(status_code=404, detail="Asset not found")
    
    asset.is_active = True
    db.commit()
    
    print(f"📄 Asset activated: {asset.file_name}")
    
    return {"success": True, "active_asset_id": asset_id}


@router.delete("/{room_id}/assets/{asset_id}")
def delete_asset(
    room_id: str,
    asset_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Delete a presentation asset (host only)."""
    
    # Check if current user is host
    room = db.query(AudioRoom).filter(AudioRoom.id == room_id).first()
    if room.host_user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Only host can delete assets")
    
    asset = db.query(AudioRoomAsset).filter(
        AudioRoomAsset.id == asset_id,
        AudioRoomAsset.room_id == room_id
    ).first()
    
    if not asset:
        raise HTTPException(status_code=404, detail="Asset not found")
    
    db.delete(asset)
    db.commit()
    
    return {"success": True}
