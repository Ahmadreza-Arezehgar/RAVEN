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
    """Generate a LiveKit access token for joining an audio room.

    🔴 ROUND 59 (2026-05-19) — hacker-audit LiveKit F1 (HIGH).
    Three findings rolled into one fix:
      (a) The log lines previously emitted
          `Claims: iss={LIVEKIT_API_KEY[:6]}...` — a 6-char prefix
          of a LiveKit API key is enough material to noticeably
          narrow brute-force when combined with leaked log
          aggregators. Same family as the round-46 secret-prefix
          leak. Removed.
      (b) `participant_name` came STRAIGHT from the request body
          into the JWT `name` claim, which LiveKit shows to every
          other participant. An attacker could set
          `participant_name = "Anthropic Support"` (or the real
          name of another participant in the room) and impersonate
          on screen. Replaced with the server-known canonical
          username + display-mode prefix so the wire identity
          can't be spoofed.
      (c) 1-hour TTL was the LiveKit example default, not a
          considered choice. A token stolen mid-call (e.g., from a
          backup or a leaked URL) keeps working long after the
          user leaves the room. Cut to 10 minutes; client refreshes
          on reconnect.
    """
    print(f"🎙️ [LiveKit Token] Request from user: {current_user.username} room={request.room_id[:8]}")
    # 🔴 ROUND 59 — do NOT log the requested participant_name; it's
    # attacker-controlled and ends up overwritten anyway.

    # 🔴 ROUND 59 — only log boolean configuration state; never
    # log any prefix of the API key or secret.
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

    participant = db.query(AudioRoomParticipant).filter(
        AudioRoomParticipant.room_id == request.room_id,
        AudioRoomParticipant.user_id == current_user.id,
        AudioRoomParticipant.left_at == None
    ).first()

    if not participant:
        print(f"❌ [LiveKit Token] User not a participant of room")
        raise HTTPException(status_code=403, detail="Not a participant of this room")

    # 🔴 hacker-audit 2026-05-20 — re-check friends-only privacy at
    # token mint (defense in depth). A stale participant row is not
    # sufficient: for a friends-only room the caller must still be the
    # host or an accepted friend of the host. Catches a caller who
    # joined while a friend and was unfriended afterwards.
    room_privacy = (getattr(room, "privacy", None) or "public").lower()
    if room_privacy == "friends" and room.host_user_id != current_user.id:
        from models import FriendRequest
        still_friend = db.query(FriendRequest.id).filter(
            FriendRequest.status == "accepted",
            ((FriendRequest.requester_id == current_user.id) &
             (FriendRequest.recipient_id == room.host_user_id))
            | ((FriendRequest.requester_id == room.host_user_id) &
               (FriendRequest.recipient_id == current_user.id)),
        ).first() is not None
        if not still_friend:
            print(f"❌ [LiveKit Token] caller not authorised for friends-only room")
            raise HTTPException(status_code=403, detail="Not authorized for this room")

    print(f"✅ [LiveKit Token] role={participant.role}")

    # Determine permissions based on role
    can_publish = participant.role in ["host", "cohost", "speaker"]
    can_subscribe = True  # Everyone can listen

    # Generate LiveKit JWT token
    now = int(time.time())
    # 🔴 ROUND 59 — 10-minute TTL (was 3600). Mobile clients refresh
    # on reconnect; long-lived tokens are a useless gift to whoever
    # captures one.
    exp = now + 600

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

    # 🔴 ROUND 59 — the JWT's `name` claim is what LiveKit echoes to
    # every other participant in the room. Trust the SERVER's view
    # of the user (canonical username), not the client-supplied
    # `participant_name`. Stealth/anonymous modes get a generic
    # label so cross-pair identity correlation through the room UI
    # is impossible.
    display_mode = (participant.display_mode or "real").lower()
    if display_mode == "anonymous":
        display_name = f"Anonymous #{current_user.id[:4]}"
    elif display_mode == "hidden":
        display_name = "Listener"
    else:
        display_name = current_user.username or "user"

    claims = {
        "iss": LIVEKIT_API_KEY,
        "sub": current_user.id,
        "name": display_name,
        "exp": exp,
        "nbf": now,
        "iat": now,
        "video": video_grants,
        # 🔴 ROUND 59 — metadata uses json.dumps so a username with
        # an embedded `"` doesn't break the claim. Previously f-string
        # interpolation would have allowed a malformed JSON injection
        # if the display_mode column ever held a quote (e.g., from a
        # legacy admin migration).
        "metadata": _safe_json_metadata(participant.role, display_mode),
    }

    token = jwt.encode(claims, LIVEKIT_API_SECRET, algorithm="HS256")
    print(f"🎉 [LiveKit Token] minted ttl=600s for {current_user.username[:12]}")

    return TokenResponse(token=token, url=LIVEKIT_URL)


def _safe_json_metadata(role: str, display_mode: str) -> str:
    """🔴 ROUND 59 — JSON-safe metadata field for LiveKit token.

    Hand-rolled `f'{{...}}'` interpolation broke whenever role or
    display_mode contained a special character. `json.dumps` is the
    right primitive.
    """
    import json as _json
    return _json.dumps({
        "role": str(role or "listener"),
        "displayMode": str(display_mode or "real"),
    })


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
