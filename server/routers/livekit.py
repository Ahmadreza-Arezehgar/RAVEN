"""
LiveKit Token Generation for Audio Rooms.

Generates JWT tokens for clients to connect to LiveKit rooms.
"""

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session
import time
import jwt
import os

from database import get_db
from models import User, AudioRoom, AudioRoomParticipant
from routers.users import get_current_user

router = APIRouter(prefix="/api/livekit", tags=["livekit"])

# LiveKit server config (set via environment variables)
LIVEKIT_API_KEY = os.getenv("LIVEKIT_API_KEY", "")
LIVEKIT_API_SECRET = os.getenv("LIVEKIT_API_SECRET", "")
LIVEKIT_URL = os.getenv("LIVEKIT_URL", "wss://your-livekit-server.livekit.cloud")


class TokenRequest(BaseModel):
    room_id: str
    participant_name: str


class TokenResponse(BaseModel):
    token: str
    url: str


@router.post("/token", response_model=TokenResponse)
def get_livekit_token(
    request: TokenRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Generate a LiveKit access token for joining an audio room."""
    
    print(f"🎙️ [LiveKit Token] Request from user: {current_user.username}")
    print(f"   Room ID: {request.room_id}")
    print(f"   Participant: {request.participant_name}")
    
    # Check configuration
    print(f"   API Key configured: {bool(LIVEKIT_API_KEY)}")
    print(f"   API Secret configured: {bool(LIVEKIT_API_SECRET)}")
    print(f"   LiveKit URL: {LIVEKIT_URL}")
    
    if not LIVEKIT_API_KEY or not LIVEKIT_API_SECRET:
        print("❌ [LiveKit Token] NOT CONFIGURED!")
        raise HTTPException(
            status_code=503,
            detail="LiveKit not configured. Set LIVEKIT_API_KEY and LIVEKIT_API_SECRET."
        )
    
    # Verify room exists and user is a participant
    room = db.query(AudioRoom).filter(
        AudioRoom.id == request.room_id,
        AudioRoom.is_live == True
    ).first()
    
    if not room:
        print(f"❌ [LiveKit Token] Room not found: {request.room_id}")
        raise HTTPException(status_code=404, detail="Room not found or not live")
    
    print(f"✅ [LiveKit Token] Room found: '{room.title}'")
    
    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == request.room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.left_at == None
    ).first()
    
    if not participant:
        print(f"❌ [LiveKit Token] User not a participant of room")
        raise HTTPException(status_code=403, detail="Not a participant of this room")
    
    print(f"✅ [LiveKit Token] Participant found - Role: {participant.role}")
    
    # Determine permissions based on role
    can_publish = participant.role in ["host", "cohost", "speaker"]
    can_subscribe = True  # Everyone can listen
    
    print(f"   Can publish audio: {can_publish}")
    print(f"   Can subscribe: {can_subscribe}")
    
    # Generate LiveKit JWT token
    #
    # 🕐 TTL = 6 HOURS.
    #
    # The OLD value (1 hour) created a hard cliff: any room running >60 min
    # had clients silently fail to reconnect after WiFi/cell hiccups because
    # the cached token had expired. iOS LiveKit doesn't auto-refresh the token.
    #
    # 6h covers the realistic upper bound for an audio room session. For
    # marathon rooms, iOS calls back to /api/livekit/token on the
    # `room_event.needs_token_refresh` WebSocket signal (fired e.g. on role
    # change) and on `connectionState == .reconnecting`.
    now = int(time.time())
    exp = now + 6 * 3600  # 6 hours
    
    # Use a consistent room name format
    livekit_room_name = f"audio-room-{request.room_id}"
    
    video_grants = {
        "roomJoin": True,
        "room": livekit_room_name,
        "canPublish": can_publish,
        "canSubscribe": can_subscribe,
        "canPublishData": True,
        # Video disabled for audio-only rooms
        "canPublishSources": ["microphone"] if can_publish else [],
    }
    
    # 🛡️ JWT metadata is CLIENT-READABLE — every other LiveKit participant
    # can decode it. Don't leak `displayMode` (would let everyone see who
    # joined as ghost / hidden). Only expose `role` which is already public
    # via the room participant list anyway.
    claims = {
        "iss": LIVEKIT_API_KEY,
        "sub": current_user.id,
        "name": request.participant_name,
        "exp": exp,
        "nbf": now,
        "iat": now,
        "video": video_grants,
        "metadata": f'{{"role":"{participant.role}"}}'
    }
    
    print(f"✅ [LiveKit Token] Generating JWT...")
    print(f"   LiveKit Room: {livekit_room_name}")
    print(f"   Claims: iss={LIVEKIT_API_KEY[:6]}..., sub={current_user.id[:8]}...")
    
    token = jwt.encode(claims, LIVEKIT_API_SECRET, algorithm="HS256")
    
    print(f"✅ [LiveKit Token] Token generated! Length: {len(token)}")
    print(f"🎉 [LiveKit Token] SUCCESS - Returning token for {request.participant_name}")
    
    return TokenResponse(token=token, url=LIVEKIT_URL)


@router.get("/config")
def get_livekit_config():
    """Get LiveKit connection info (public endpoint for debugging)."""
    return {
        "configured": bool(LIVEKIT_API_KEY and LIVEKIT_API_SECRET),
        "url": LIVEKIT_URL if LIVEKIT_API_KEY else None,
        "api_key_set": bool(LIVEKIT_API_KEY),
        "api_secret_set": bool(LIVEKIT_API_SECRET),
    }


@router.get("/debug")
def get_debug_info(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Debug endpoint to check LiveKit configuration and user's rooms."""
    
    # Get user's active room participations
    active_participations = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.left_at == None
    ).all()
    
    rooms_info = []
    for p in active_participations:
        room = db.query(AudioRoom).filter(AudioRoom.id == p.room_id).first()
        if room:
            rooms_info.append({
                "room_id": room.id,
                "title": room.title,
                "is_live": room.is_live,
                "participant_count": room.participant_count,
                "your_role": p.role
            })
    
    return {
        "livekit": {
            "configured": bool(LIVEKIT_API_KEY and LIVEKIT_API_SECRET),
            "url": LIVEKIT_URL,
        },
        "user": {
            "id": current_user.id,
            "username": current_user.username,
        },
        "active_rooms": rooms_info
    }
