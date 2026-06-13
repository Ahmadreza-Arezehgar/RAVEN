from fastapi import APIRouter, Depends, HTTPException, status, BackgroundTasks
from sqlalchemy.orm import Session
from sqlalchemy import or_, and_
from pydantic import BaseModel, Field, field_validator
from typing import List, Optional, Literal
from datetime import datetime, timedelta

from database import get_db
from models import User, Message, GroupMessage, Group, GroupMember, ConversationSetting
from routers.users import get_current_user
from encryption import encrypt_text, decrypt_text
from middleware.rate_limit import rate_limiter
from ws_manager import ws_manager
import os

router = APIRouter(prefix="/api/messages", tags=["messages"])

# Constants for validation
MAX_MESSAGE_LENGTH = 10000  # 10KB max message content
MAX_FILENAME_LENGTH = 255

# ═══════════════════════════════════════════════════════════════════
# 🔴 v1.8 (2026-05-21) — per-conversation disappearing messages.
# ═══════════════════════════════════════════════════════════════════
# A conversation-level timer: set it once and every NEW message in
# that 1:1 chat is auto-stamped with `expires_at`, then filtered and
# lazily purged once it elapses. Built on the existing
# `Message.expires_at` column, so it is fully backward compatible —
# old clients keep working and the mesh wire format is untouched.

# Allowed timer durations, in seconds. 0 = off. The keys double as
# the validation whitelist (rejecting arbitrary / abusive values) and
# as the human labels for the in-chat system control message.
_DISAPPEARING_LABELS = {
    0: "off",
    30: "30 seconds",
    300: "5 minutes",
    3600: "1 hour",
    28800: "8 hours",
    86400: "1 day",
    604800: "1 week",
    2592000: "30 days",
}
ALLOWED_DISAPPEARING_SECONDS = set(_DISAPPEARING_LABELS.keys())


def _ordered_pair(a: str, b: str) -> tuple:
    """Canonical ordering of a user pair so a 1:1 conversation maps to
    exactly one ConversationSetting row regardless of direction."""
    return (a, b) if a <= b else (b, a)


def _get_conversation_setting(db: Session, user_a: str, user_b: str):
    """Fetch the ConversationSetting row for a 1:1 pair, or None."""
    low, high = _ordered_pair(user_a, user_b)
    return db.query(ConversationSetting).filter(
        ConversationSetting.user_low_id == low,
        ConversationSetting.user_high_id == high,
    ).first()


def _disappearing_seconds_for(db: Session, user_a: str, user_b: str) -> int:
    """The active disappearing-messages timer for a 1:1 pair (0 = off)."""
    setting = _get_conversation_setting(db, user_a, user_b)
    return setting.disappearing_seconds if setting else 0


def _disappearing_label(seconds: int) -> str:
    """Human label for a timer duration (used in the system message)."""
    return _DISAPPEARING_LABELS.get(seconds, f"{seconds} seconds")


def _disappearing_system_text(actor: User, seconds: int) -> str:
    """The control-message text shown in-chat when the timer changes."""
    name = actor.username if (actor and actor.username) else "Someone"
    if seconds <= 0:
        return f"{name} turned off disappearing messages"
    return (f"{name} set disappearing messages to "
            f"{_disappearing_label(seconds)}")


def _not_expired_clause():
    """SQLAlchemy filter clause: the message has not passed its
    disappearing-messages expiry. Belt-and-suspenders alongside the
    lazy purge — guarantees an expired message is never returned even
    in the window before the next purge runs."""
    return or_(
        Message.expires_at.is_(None),
        Message.expires_at > datetime.utcnow(),
    )


def _purge_expired_for_user(db: Session, user_id: str) -> int:
    """Lazy GC: hard-delete messages involving `user_id` whose
    disappearing timer has elapsed. Disappearing means GONE, so the
    rows (and their reaction / voice / story-reply children) are
    deleted, not merely hidden.

    🔴 ROUND 70 (2026-05-23) — hacker-audit EPHEMERAL-CRIT-2.
    Previously only deleted DB rows; the GCS blob behind
    `message.audio_url` lived forever (or until manual bucket GC).
    Combined with the iOS-side gap (also fixed in round 70 in
    MessageRepository.purgeExpiredMessages), this meant a
    "disappearing" message's media bytes were recoverable from
    either side indefinitely.

    Fix: collect (audio_url) from the soon-to-be-deleted rows
    BEFORE the DELETE, parse out the GCS object path, and call
    bucket.delete_blob() on each. Failures swallowed individually so
    one bad path doesn't block the rest.

    Best-effort: ANY failure is swallowed + rolled back so a purge
    problem can never break message delivery — the read-path filter
    (`_not_expired_clause`) still hides expired rows in that case."""
    try:
        now = datetime.utcnow()
        # Snapshot expiring rows with their media URLs BEFORE delete.
        expiring = db.query(Message.id, Message.audio_url).filter(
            Message.expires_at.isnot(None),
            Message.expires_at <= now,
            or_(Message.sender_id == user_id,
                Message.recipient_id == user_id),
        ).all()
        if not expiring:
            return 0
        expired_ids = [r[0] for r in expiring]
        media_urls = [r[1] for r in expiring if r[1]]

        # Clear child rows first so the message delete cannot trip a
        # foreign-key constraint on Postgres.
        from models import MessageReaction, VoiceMessage, StoryReply
        db.query(MessageReaction).filter(
            MessageReaction.message_id.in_(expired_ids)
        ).delete(synchronize_session=False)
        db.query(VoiceMessage).filter(
            VoiceMessage.message_id.in_(expired_ids)
        ).delete(synchronize_session=False)
        db.query(StoryReply).filter(
            StoryReply.message_id.in_(expired_ids)
        ).delete(synchronize_session=False)
        deleted = db.query(Message).filter(
            Message.id.in_(expired_ids)
        ).delete(synchronize_session=False)
        db.commit()

        # 🔴 ROUND 70 — best-effort GCS blob purge AFTER the DB
        # commit succeeds. Imports are lazy because most calls (no
        # media) don't need GCS at all.
        if media_urls:
            try:
                from routers.uploads import _get_gcs_bucket
                bucket = _get_gcs_bucket()
                if bucket is not None:
                    for url in media_urls:
                        try:
                            # Extract GCS object path from URL. Handles:
                            #   - https://storage.googleapis.com/<bucket>/<path>...
                            #   - https://...?X-Goog-Signature=... (signed URL)
                            #   - relative `images/uuid.jpg`
                            object_path = None
                            if url.startswith("http"):
                                # Strip query string + leading "https://host/bucket/"
                                base = url.split("?", 1)[0]
                                marker = f"/{bucket.name}/"
                                idx = base.find(marker)
                                if idx >= 0:
                                    object_path = base[idx + len(marker):]
                            else:
                                object_path = url.lstrip("/")
                            if object_path:
                                bucket.blob(object_path).delete()
                        except Exception as e:
                            import logging
                            logging.getLogger("messages.purge").warning(
                                f"GCS blob delete failed for {url[:40]}: {type(e).__name__}: {e}")
            except Exception as e:
                import logging
                logging.getLogger("messages.purge").warning(
                    f"GCS purge skipped: {type(e).__name__}: {e}")

        return deleted
    except Exception as e:
        db.rollback()
        import logging
        logging.getLogger("messages.purge").warning(
            f"expired-message purge skipped: {type(e).__name__}: {e}")
        return 0

# Request/Response models
class SendMessageRequest(BaseModel):
    recipient_id: str
    content: str = Field(..., max_length=MAX_MESSAGE_LENGTH)
    message_id: Optional[str] = None  # Client-generated UUID for idempotency
    audio_url: Optional[str] = None   # Voice message audio URL
    audio_duration_seconds: Optional[int] = None  # Voice message duration
    message_type: Literal["text", "voice", "image", "file", "video", "video_note", "location", "system", "ephemeral_photo", "post_share", "postShare"] = "text"
    # File attachment metadata
    file_name: Optional[str] = Field(None, max_length=MAX_FILENAME_LENGTH)
    file_size: Optional[int] = Field(None, ge=0, le=100*1024*1024)  # Max 100MB
    mime_type: Optional[str] = Field(None, max_length=100)
    # ✅ Reply fields
    reply_to_message_id: Optional[str] = None
    reply_to_text_preview: Optional[str] = Field(None, max_length=500)
    reply_to_sender_name: Optional[str] = Field(None, max_length=100)
    reply_to_type: Optional[Literal["text", "voice", "image", "file", "video", "video_note", "location", "system", "ephemeral_photo", "post_share", "postShare"]] = None
    # ✅ Scheduled message fields
    send_mode: Literal["instant", "scheduled"] = "instant"
    scheduled_at_utc: Optional[datetime] = None
    # ✅ Smart Message Expiry
    expiry_mode: Optional[Literal["none", "deleteAfterRead", "deleteAfter24h", "deleteAfter7d", "deleteIfScreenshot", "deleteIfForwarded"]] = None
    # 🔴 ROUND 26 — Telegram-style media albums.
    # When the client multi-picks N items and hits Send, every item
    # is POSTed as its own /send (preserves existing E2EE / progress
    # / ACK lifecycle) but shares an opaque `media_group_key`. The
    # receiver groups items with the same key into one bubble.
    # `_total` is stamped by the sender so a receiver that hasn't
    # downloaded every sibling yet can still render a "1 of N" /
    # placeholder. Server is a passthrough; it doesn't enforce N≤10.
    media_group_key: Optional[str] = Field(None, max_length=64)
    media_group_index: Optional[int] = Field(None, ge=0, le=99)
    media_group_total: Optional[int] = Field(None, ge=1, le=99)

class MessageResponse(BaseModel):
    id: str
    sender_id: str
    recipient_id: str
    content: Optional[str] = None  # Made Optional to handle decrypt failures
    timestamp: datetime
    read_at: Optional[datetime]
    delivered_at: Optional[datetime]
    is_duplicate: bool = False  # True if message already existed
    sender_username: Optional[str] = None  # Added for receiver to know sender
    sender_name: Optional[str] = None
    audio_url: Optional[str] = None  # Voice message audio URL
    audio_duration_seconds: Optional[int] = None  # Voice message duration
    message_type: str = "text"  # text, voice, image, file
    # ✅ roomId for client to know which conversation this belongs to
    room_id: Optional[str] = None  # For 1:1: sender_id (peer), for groups: group_id
    # File attachment metadata
    file_name: Optional[str] = None
    file_size: Optional[int] = None
    mime_type: Optional[str] = None
    # ✅ Reply fields
    reply_to_message_id: Optional[str] = None
    reply_to_text_preview: Optional[str] = None
    reply_to_sender_name: Optional[str] = None
    reply_to_type: Optional[str] = None
    # ✅ Scheduled message fields
    send_mode: str = "instant"
    scheduled_at_utc: Optional[datetime] = None
    # ✅ v2.0 Delivery status fields
    status: str = "accepted"  # accepted, delivered, queued_for_push
    recipient_delivered: bool = False  # True if actually on recipient device
    recipient_online: bool = False  # True if recipient currently connected
    # ✅ Smart Message Expiry fields
    expiry_mode: Optional[str] = None
    expires_at: Optional[datetime] = None
    allow_forward: bool = True
    # 🔴 ROUND 26 — album grouping fields passed through to the client.
    media_group_key: Optional[str] = None
    media_group_index: Optional[int] = None
    media_group_total: Optional[int] = None

    class Config:
        from_attributes = True

@router.post("/send", response_model=MessageResponse)
async def send_message(
    req: SendMessageRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    background_tasks: BackgroundTasks = BackgroundTasks()
):
    """
    Send a message to another user (idempotent).
    
    - If message_id provided and exists, returns existing message (no duplicate)
    - Encrypts message content
    - Stores in database
    - Returns message with decrypted content
    """
    # Rate limit: max 30 messages per minute per user (burst protection)
    rate_limiter.check_rate_limit(
        identifier=f"msg:{current_user.id}",
        max_attempts=30,
        window_minutes=1,
        lockout_minutes=5
    )
    
    # Check for duplicate if message_id provided (idempotency)
    if req.message_id:
        existing = db.query(Message).filter(Message.id == req.message_id).first()
        if existing:
            # 🔴 hacker-audit 2026-05-20 — idempotency-collision IDOR.
            # Idempotent re-send is only meaningful when the SAME
            # sender retries the SAME message. If the supplied
            # message_id already belongs to a row the caller did NOT
            # send, echoing it back would hand the caller another
            # user's decrypted message content. Reject the collision.
            if existing.sender_id != current_user.id:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="message_id already in use",
                )
            print(f"⚠️ Duplicate message {req.message_id}, returning existing")
            sender = db.query(User).filter(User.id == existing.sender_id).first()
            return MessageResponse(
                id=existing.id,
                sender_id=existing.sender_id,
                recipient_id=existing.recipient_id,
                content=decrypt_text(existing.content),
                timestamp=existing.timestamp,
                read_at=existing.read_at,
                delivered_at=existing.delivered_at,
                is_duplicate=True,
                sender_username=sender.username if sender else None,
                sender_name=f"{sender.first_name} {sender.last_name}" if sender else None,
                audio_url=existing.audio_url,
                audio_duration_seconds=existing.audio_duration_seconds,
                message_type=existing.message_type or "text",
                file_name=existing.file_name,
                file_size=existing.file_size,
                mime_type=existing.mime_type,
                # ✅ Reply fields
                reply_to_message_id=existing.reply_to_message_id,
                reply_to_text_preview=existing.reply_to_text_preview,
                reply_to_sender_name=existing.reply_to_sender_name,
                reply_to_type=existing.reply_to_type,
                # ✅ Smart Message Expiry
                expiry_mode=existing.expiry_mode,
                expires_at=existing.expires_at,
                allow_forward=existing.allow_forward if existing.allow_forward is not None else True,
                # 🔴 ROUND 26 — album passthrough on idempotency hit
                media_group_key=existing.media_group_key,
                media_group_index=existing.media_group_index,
                media_group_total=existing.media_group_total,
            )
    
    # Verify recipient exists
    recipient = db.query(User).filter(User.id == req.recipient_id).first()
    if not recipient:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Recipient not found"
        )
    
    # ✅ Check block status - prevent messaging if either user blocked the other
    from models import Block
    block_exists = db.query(Block).filter(
        or_(
            and_(Block.blocker_id == current_user.id, Block.blocked_id == req.recipient_id),
            and_(Block.blocker_id == req.recipient_id, Block.blocked_id == current_user.id)
        )
    ).first()
    
    if block_exists:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can't message this user"
        )
    
    # ✅ Check friendship status — gate non-friend messaging via Message Requests
    #
    # 🐞 ROUND 22 BUG FIX. The previous version queried the `Friendship`
    # table — but that table is NEVER WRITTEN ANYWHERE in the codebase
    # (grep -rn "Friendship(" returned only the model definition,
    # no inserts). Friend state actually lives in `FriendRequest` with
    # `status == "accepted"` — see the matching pattern in
    # `rooms.py:380` (which explicitly notes "friendships table may be
    # empty — friend status is tracked via friend_requests") and
    # `nearby.py:57`.
    #
    # Symptom: even users who explicitly accepted each other as friends
    # got `403 "Only RAVEN+ users can send message requests to
    # non-friends"` on every send. The user's iOS log showed this
    # exact path: d33b45bb (Main_Z3ous) sending to 0f7c70a8
    # (reviewer1) — both accepted as friends in the UI, but the
    # Friendship row didn't exist so `are_friends == False`.
    #
    # The fix mirrors rooms.py exactly: check `FriendRequest` with
    # `status='accepted'` in either direction.
    from models import FriendRequest, MessageRequest
    are_friends = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(
            and_(FriendRequest.requester_id == current_user.id,
                 FriendRequest.recipient_id == req.recipient_id),
            and_(FriendRequest.requester_id == req.recipient_id,
                 FriendRequest.recipient_id == current_user.id)
        )
    ).first() is not None
    
    if not are_friends:
        # MESSENGER PIVOT (2026-06): subscription removed — sending a message
        # request to a non-friend is free for everyone (previously RAVEN+ only).

        # Look up or create a MessageRequest row
        msg_request = db.query(MessageRequest).filter(
            MessageRequest.sender_id == current_user.id,
            MessageRequest.receiver_id == req.recipient_id
        ).first()
        
        if not msg_request:
            msg_request = MessageRequest(
                sender_id=current_user.id,
                receiver_id=req.recipient_id,
                status="pending",
                sent_count=0
            )
            db.add(msg_request)
            db.flush()
        
        # Enforce status rules
        if msg_request.status in ("declined", "blocked"):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Your message request was declined"
            )
        
        if msg_request.status == "pending" and msg_request.sent_count >= 3:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Message request limit reached (3 messages). Wait for the recipient to accept."
            )
        
        # Increment sent_count for pending requests
        if msg_request.status == "pending":
            msg_request.sent_count += 1
            db.flush()
        
        print(f"📨 [MessageRequest] {current_user.username} → {recipient.username} (status={msg_request.status}, count={msg_request.sent_count})")
    
    # ✅ Check "who can message me" privacy setting
    if getattr(recipient, 'who_can_message', 'everyone') == 'friends':
        from models import FriendRequest
        is_friends_req = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(
                and_(FriendRequest.requester_id == current_user.id, FriendRequest.recipient_id == req.recipient_id),
                and_(FriendRequest.requester_id == req.recipient_id, FriendRequest.recipient_id == current_user.id)
            )
        ).first()
        
        if not is_friends_req and not are_friends:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="This user only accepts messages from friends"
            )
    
    # Create message with encrypted content
    # Use client-provided message_id if given, otherwise auto-generate
    # For scheduled messages: store but don't deliver until scheduled_at_utc
    is_scheduled = req.send_mode == "scheduled" and req.scheduled_at_utc is not None
    
    # ✅ Calculate expiry based on mode
    expires_at = None
    allow_forward = True
    
    if req.expiry_mode:
        if req.expiry_mode == "deleteAfter24h":
            expires_at = datetime.utcnow() + timedelta(hours=24)
        elif req.expiry_mode == "deleteAfter7d":
            expires_at = datetime.utcnow() + timedelta(days=7)
        elif req.expiry_mode == "deleteIfForwarded":
            allow_forward = False
        # deleteAfterRead and deleteIfScreenshot handled by client

    # 🔴 v1.8 — per-conversation disappearing-messages timer.
    # If this pair has a timer set and the message didn't already get
    # an explicit per-message expiry above, stamp `expires_at` from
    # the conversation timer. Server-enforced ⇒ disappearing works for
    # every client version, even ones with no disappearing-messages UI.
    # Scheduled messages are skipped — their countdown would start at
    # schedule time rather than delivery time.
    if expires_at is None and not is_scheduled:
        _conv_secs = _disappearing_seconds_for(db, current_user.id, req.recipient_id)
        if _conv_secs > 0:
            expires_at = datetime.utcnow() + timedelta(seconds=_conv_secs)

    # ═══════════════════════════════════════════════════════════════════════════
    # FIX v2: NEVER set delivered_at at send time.
    # The presence system is unreliable (e.g. device reports hasInternet=True
    # via cellular even when WiFi is off and user can't actually receive).
    # Instead, delivered_at is set when the recipient ACTUALLY fetches the
    # message — either via /inbox polling or /bridge-downlink relay.
    # ═══════════════════════════════════════════════════════════════════════════
    import logging
    _send_logger = logging.getLogger("messages.send")
    
    initial_delivered_at = None  # Always NULL — set on actual receipt
    if is_scheduled:
        _send_logger.warning(f"📨 [Send] Scheduled message for {req.recipient_id[:8]} — delivered_at=NULL")
    else:
        _send_logger.warning(f"📨 [Send] Message to {req.recipient_id[:8]} — delivered_at=NULL (set on receipt)")
    
    message = Message(
        id=req.message_id,  # Will use default UUID if None
        sender_id=current_user.id,
        recipient_id=req.recipient_id,
        content=encrypt_text(req.content),
        timestamp=datetime.utcnow(),
        delivered_at=initial_delivered_at,
        audio_url=req.audio_url,
        audio_duration_seconds=req.audio_duration_seconds,
        message_type=req.message_type,
        file_name=req.file_name,
        file_size=req.file_size,
        mime_type=req.mime_type,
        # ✅ Reply fields
        reply_to_message_id=req.reply_to_message_id,
        reply_to_text_preview=req.reply_to_text_preview,
        reply_to_sender_name=req.reply_to_sender_name,
        reply_to_type=req.reply_to_type,
        # ✅ Scheduled message fields
        send_mode=req.send_mode,
        scheduled_at_utc=req.scheduled_at_utc,
        # ✅ Smart Message Expiry
        expiry_mode=req.expiry_mode,
        expires_at=expires_at,
        allow_forward=allow_forward,
        # 🔴 ROUND 26 — Telegram-style album grouping passthrough.
        media_group_key=req.media_group_key,
        media_group_index=req.media_group_index,
        media_group_total=req.media_group_total
    )
    
    # 🔍 DEBUG: Log audio_url for voice messages to trace storage issues
    if req.message_type == "voice":
        print(f"🎤 [SendMessage] VOICE msg id={req.message_id}")
        print(f"   req.audio_url: {req.audio_url}")
        print(f"   req.audio_duration_seconds: {req.audio_duration_seconds}")
        print(f"   → message.audio_url: {message.audio_url}")
    
    db.add(message)
    db.commit()
    db.refresh(message)
    
    # 🔍 DEBUG: Verify audio_url survived DB round-trip
    if req.message_type == "voice":
        print(f"   → AFTER COMMIT message.audio_url: {message.audio_url}")
    
    # ✅ Create notification for recipient (skip for scheduled messages)
    if not is_scheduled:
        from models import Notification
        import json
        
        # 🔴 Bug fix (2026-05-16): split the legacy formatted
        # `preview_text` (used as APNs body fallback) from the
        # RAW caption text we now store in the notification row.
        # Earlier the same "🎬 Video" / "📷 Image" placeholder
        # was written into `data.preview` AND the iOS verb
        # formatter ALSO prefixed its own emoji + word — the
        # activity list rendered "sent a 🎬 video: 🎬 Video"
        # (doubled emoji + redundant noun). The fix sends the
        # actual caption to the client (empty when there's no
        # caption) and lets `formatMessagePreview` paint the
        # verb-shaped line. APNs body (line 541) still uses
        # `preview_text` so the system-level banner reads the
        # nicely-formatted string when the server-side preview
        # is enabled.
        if req.message_type == "text":
            preview_text = req.content[:100] if req.content else "New message"
        elif req.message_type == "voice":
            preview_text = "🎤 Voice message"
        elif req.message_type == "image":
            preview_text = "📷 Image"
        elif req.message_type == "video":
            preview_text = "🎬 Video"
        elif req.message_type == "video_note":
            preview_text = "🎥 Video note"
        elif req.message_type == "location":
            preview_text = "📍 Location"
        elif req.message_type in ("post_share", "postShare"):
            preview_text = "📬 Shared a post"
        else:
            preview_text = "New message"

        # 🔴 ROUND 70 (2026-05-23) — hacker-audit SERVER-DB-CRIT-1.
        # Previously stored the first 200 chars of `req.content`
        # PLAINTEXT in `notifications.data`. For text messages this
        # was the ACTUAL user-typed message body (or its ciphertext
        # for sealed sends, but pre-round-10 / non-sealed paths
        # included plaintext). Insider with Postgres read access
        # could read every recent message preview by scanning the
        # notifications table.
        #
        # Fix: don't persist any message body in the notification
        # row. The client re-fetches the actual message via /inbox
        # or WS when it surfaces the notification. The only
        # in-notification text now is the message_type tag, which
        # the client uses to render a generic "sent a photo" /
        # "sent a voice note" label.
        notif = Notification(
            user_id=req.recipient_id,
            type="message",  # All message types are "message" type notifications
            data=json.dumps({
                "room_id": current_user.id,  # For 1:1, room_id = sender's id (for navigation)
                "sender_id": current_user.id,
                "sender_username": current_user.username,
                # Round 70 — no plaintext preview. Client renders a
                # generic verb from message_type.
                "preview": "",
                "message_type": req.message_type  # text, voice, image, video
            }),
            is_read=False
        )
        db.add(notif)
        db.commit()
        print(f"🔔 Message notification created for {recipient.username} (type={req.message_type})")
        
        # ⚡ INSTANT PUSH: Notify WebSocket-connected recipient immediately
        await ws_manager.notify(req.recipient_id, {
            "id": message.id,
            "sender_id": message.sender_id,
            "recipient_id": message.recipient_id,
            "content": req.content,
            "timestamp": message.timestamp.isoformat() + "Z",
            "read_at": None,
            "delivered_at": None,
            "sender_username": current_user.username,
            "sender_name": f"{current_user.first_name} {current_user.last_name}",
            "message_type": message.message_type or "text",
            "room_id": current_user.id,
            "audio_url": message.audio_url,
            "audio_duration_seconds": message.audio_duration_seconds,
            "file_name": message.file_name,
            "file_size": message.file_size,
            "mime_type": message.mime_type,
            "reply_to_message_id": message.reply_to_message_id,
            "reply_to_text_preview": message.reply_to_text_preview,
            "reply_to_sender_name": message.reply_to_sender_name,
            "reply_to_type": message.reply_to_type,
            "expiry_mode": message.expiry_mode,
            "expires_at": message.expires_at.isoformat() + "Z" if message.expires_at else None,
            "allow_forward": message.allow_forward if message.allow_forward is not None else True,
        })
        
        # ⚡ PERF: Defer push + bridge wake to background (saves ~100-300ms on response)
        background_tasks.add_task(
            _send_push_and_bridge_wake,
            sender_id=current_user.id,
            sender_username=current_user.username,
            sender_first_name=current_user.first_name,
            sender_last_name=current_user.last_name,
            sender_avatar=current_user.avatar_path,  # R71 p3: feed the in-app banner
            recipient_id=req.recipient_id,
            recipient_username=recipient.username,
            recipient_push_token=recipient.push_token,
            recipient_push_platform=recipient.push_platform,
            recipient_notification_settings={
                "push_notifications": getattr(recipient, 'push_notifications', True),
                "push_messages": getattr(recipient, 'push_messages', True),
                "push_show_preview": getattr(recipient, 'push_show_preview', True),
            },
            content=req.content,
            message_type=req.message_type,
            preview_text=preview_text,
        )
    else:
        print(f"⏰ Scheduled message created: {current_user.username} → {recipient.username} at {req.scheduled_at_utc}")
    
    # ✅ v2.1: delivered_at is always NULL at send time — delivery is confirmed when
    # recipient polls /inbox or bridge relays via /bridge-downlink.
    if is_scheduled:
        delivery_status = "accepted"
        recipient_delivered = False
    elif recipient.push_token:
        delivery_status = "queued_for_push"
        recipient_delivered = False  # Push queued, not confirmed delivery
    else:
        delivery_status = "accepted"
        recipient_delivered = False
    
    # Return with decrypted content + scheduled fields + delivery status
    return MessageResponse(
        id=message.id,
        sender_id=message.sender_id,
        recipient_id=message.recipient_id,
        content=decrypt_text(message.content),
        timestamp=message.timestamp,
        read_at=message.read_at,
        delivered_at=message.delivered_at,
        is_duplicate=False,
        sender_username=current_user.username,
        sender_name=f"{current_user.first_name} {current_user.last_name}",
        audio_url=message.audio_url,
        audio_duration_seconds=message.audio_duration_seconds,
        message_type=message.message_type or "text",
        file_name=message.file_name,
        file_size=message.file_size,
        mime_type=message.mime_type,
        # ✅ Reply fields
        reply_to_message_id=message.reply_to_message_id,
        reply_to_text_preview=message.reply_to_text_preview,
        reply_to_sender_name=message.reply_to_sender_name,
        reply_to_type=message.reply_to_type,
        # ✅ Scheduled fields
        send_mode=message.send_mode or "instant",
        scheduled_at_utc=message.scheduled_at_utc,
        # ✅ v2.0 Delivery status
        status=delivery_status,
        recipient_delivered=recipient_delivered,
        recipient_online=False,  # v2.1: not checked at send time anymore
        # ✅ Smart Message Expiry
        expiry_mode=message.expiry_mode,
        expires_at=message.expires_at,
        allow_forward=message.allow_forward if message.allow_forward is not None else True,
        # 🔴 ROUND 26 — album passthrough on first send
        media_group_key=message.media_group_key,
        media_group_index=message.media_group_index,
        media_group_total=message.media_group_total,
    )


# ============================================================================
# ⚡ BACKGROUND TASK: Push + Bridge Wake (deferred from /send for performance)
# ============================================================================

async def _send_push_and_bridge_wake(
    sender_id: str,
    sender_username: str,
    sender_first_name: str,
    sender_last_name: str,
    recipient_id: str,
    recipient_username: str,
    recipient_push_token: str,
    recipient_push_platform: str,
    recipient_notification_settings: dict,
    content: str,
    message_type: str,
    preview_text: str,
    sender_avatar: str = None,  # R71 p3: avatar path for foreground in-app banner
):
    """Background task: send push notification + bridge wake silently after /send returns."""
    try:
        # 1. Send push notification if recipient has token
        if recipient_push_token and recipient_push_platform == "ios":
            from services.apns_service import get_apns_service, APNsService
            
            # Check notification preferences
            allowed = (
                recipient_notification_settings.get("push_notifications", True) and
                recipient_notification_settings.get("push_messages", True)
            )
            show_preview = recipient_notification_settings.get("push_show_preview", True)
            
            if allowed:
                # 🔴 ROUND 34 (2026-05-19) — name-leak in push title.
                #
                # PREVIOUSLY: the server decrypted the sender's real
                # first_name + last_name (stored encrypted in the
                # `users` table for a reason!) and shipped the cleartext
                # to APNs as the push title. Two leaks:
                #   1. Apple's APNs sees `"firstName lastName"` in the
                #      payload — even users who only ever expose a
                #      username in the app.
                #   2. The recipient's lock screen shows the sender's
                #      real name, defeating username-only privacy.
                #
                # FIX: send `sender_username` as the title. The
                # recipient's iOS app can map username → display name
                # locally from its address book if the recipient
                # actually knows this person; the push payload itself
                # leaks only what the sender already publicly exposes
                # (their handle).
                sender_name = sender_username or "Someone"

                # 🔴 ROUND 34 — also harden the preview side. The
                # message body can be encrypted ciphertext (the iOS
                # Notification Service Extension is supposed to
                # decrypt it). Pre-R34 we shipped whatever was in
                # `content` straight to APNs, which leaked the
                # plaintext for non-E2EE messages AND let an
                # un-paired observer see ciphertext-looking blobs
                # on lock screens. Now: if the preview LOOKS like
                # ciphertext (Fernet `gAAAA…`, base64 blobs >40
                # chars w/ no URL-ish punctuation), fall back to a
                # generic "New message" so the lock-screen text is
                # always either real human content or a clean
                # placeholder, never gibberish.
                preview = content or preview_text
                if not show_preview:
                    preview = "New message"
                elif preview:
                    pv = preview.strip()
                    looks_ciphertext = (
                        pv.startswith("gAAAA")
                        or (
                            len(pv) > 40
                            and all(c.isalnum() or c in "+/=_-" for c in pv)
                            and not any(c in pv for c in " :/?&=.")
                        )
                    )
                    if looks_ciphertext:
                        preview = "New message"
                
                apns = get_apns_service()
                push_result = await apns.send_message_notification(
                    device_token=recipient_push_token,
                    sender_name=sender_name,
                    message_preview=preview,
                    room_id=sender_id,
                    sender_id=sender_id,
                    message_type=message_type,
                    sender_avatar=sender_avatar,  # R71 p3
                )
                if push_result:
                    print(f"📱 ✅ [BG] Push sent to {recipient_username}")
                else:
                    print(f"📱 ❌ [BG] Push failed for {recipient_username}")
            else:
                print(f"📱 ⏭️ [BG] Push skipped for {recipient_username} (notifications disabled)")
        
        print(f"📨 [BG] Message sent: {sender_username} → {recipient_username} (type={message_type})")
        
        # 2. Bridge wake: send silent push to recipient's friends so a
        #    nearby online friend wakes their BLE engine and forwards
        #    the message to the offline recipient.
        #
        # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — friendship
        # source-of-truth fix. The pre-fix query joined `Friendship`,
        # but that table is NEVER populated anywhere in the codebase
        # (grep confirmed only the model definition exists; no
        # inserts). Result: `bridge_friends` was ALWAYS empty, NO
        # bridge wake fired, and any message from an online sender to
        # an offline (BLE-only) recipient relied entirely on a
        # nearby bridge happening to poll the server on its own
        # schedule — typically meaning the recipient never got the
        # message at all. This is the user-reported "C→A
        # doesn't work" symptom in the
        # A(BLE-only) → B(bridge) → C(WiFi-only) topology.
        #
        # Fix: query `FriendRequest WHERE status='accepted'` like
        # every other path in the codebase (users.py:get_friends and
        # similar). Mirror both directions because friendships are
        # bidirectional via two rows.
        try:
            from models import FriendRequest, User as UserModel
            from services.apns_service import get_apns_service
            from database import SessionLocal
            from sqlalchemy import or_, and_

            db = SessionLocal()
            try:
                # Friend IDs of `recipient_id` from accepted FriendRequest rows.
                friend_id_rows = db.query(FriendRequest.requester_id, FriendRequest.recipient_id).filter(
                    FriendRequest.status == "accepted",
                    or_(
                        FriendRequest.requester_id == recipient_id,
                        FriendRequest.recipient_id == recipient_id,
                    ),
                ).all()
                friend_ids = set()
                for req_id, rec_id in friend_id_rows:
                    other = rec_id if req_id == recipient_id else req_id
                    if other and other != recipient_id and other != sender_id:
                        friend_ids.add(other)

                if friend_ids:
                    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) —
                    # diagnostic counters so the "No bridge friends
                    # found" log line tells us WHY: zero accepted
                    # friendships, or friendships exist but none
                    # have push tokens.
                    friends_with_token = db.query(UserModel).filter(
                        UserModel.id.in_(friend_ids),
                        UserModel.push_token.isnot(None),
                    ).all()
                    bridge_friends = [
                        u for u in friends_with_token if u.push_platform == "ios"
                    ][:3]
                    print(
                        f"🌉 [BG Bridge Wake] {recipient_username}: "
                        f"accepted_friends={len(friend_ids)}, "
                        f"with_push_token={len(friends_with_token)}, "
                        f"ios_eligible={len(bridge_friends)}"
                    )
                else:
                    bridge_friends = []
                    print(
                        f"🌉 [BG Bridge Wake] {recipient_username}: zero accepted "
                        f"FriendRequest rows — nothing to wake. "
                        f"(Has the recipient ever accepted a friend request?)"
                    )

                if bridge_friends:
                    apns = get_apns_service()
                    for bridge in bridge_friends:
                        wake_result = await apns.send_bridge_wake_push(
                            device_token=bridge.push_token,
                            recipient_id=recipient_id
                        )
                        if wake_result:
                            print(f"🌉 [BG Bridge Wake] Silent push sent to {bridge.username}")
                        else:
                            print(f"🌉 [BG Bridge Wake] Failed to wake {bridge.username}")
                elif friend_ids:
                    print(
                        f"🌉 [BG Bridge Wake] {recipient_username}: friends exist but "
                        f"none have an iOS push token registered. "
                        f"(Friend(s) must open RAVEN on iOS at least once after install/login)"
                    )
            finally:
                db.close()
        except Exception as e:
            print(f"🌉 [BG Bridge Wake] Error: {e}")
    except Exception as e:
        print(f"❌ [BG] Push/bridge wake error: {e}")


# ============================================================================
# BRIDGE ENDPOINT (for mesh-to-server forwarding)
# Allows online devices to forward messages from offline users
# ============================================================================

class BridgeMessageRequest(BaseModel):
    recipient_id: str
    content: str
    message_type: str = "text"
    message_id: str  # Original message ID from sender
    bridged_from: str  # Device fingerprint that bridged this
    original_sender_id: str  # The actual sender (offline user)
    original_sender_name: Optional[str] = None
    # 🛡️ SECURITY: Bridge device Ed25519 signature
    bridge_signature: Optional[str] = None   # Base64 Ed25519 signature
    bridge_public_key: Optional[str] = None  # Base64 Ed25519 public key
    # 📡 Mesh DTN metadata (sent by iOS client, optional for backward compat)
    is_bridged: Optional[bool] = None
    created_at: Optional[str] = None         # ISO8601 timestamp of original message
    ttl_seconds: Optional[int] = None
    hop_count: Optional[int] = None
    hop_limit: Optional[int] = None
    spray_counter: Optional[int] = None
    # 👥 GROUP: fields for group mesh bridge (added for group mesh support)
    is_group: Optional[bool] = False
    group_id: Optional[str] = None
    group_member_ids: Optional[List[str]] = None
    # ROUND 22 — hacker-audit Bridge F1 / F2:
    # `group_key_version` lets the receiver decrypt the bridged
    # group ciphertext locally (round-21 fix moved decryption from
    # the bridge node onto the recipient). Server stores + fans
    # this version unchanged so the WS subscriber's GroupKeyService
    # can pick the right key.
    #
    # `original_signature` + `original_signer_public_key` carry the
    # sender's Ed25519 signature through the bridge so we can
    # verify authorship server-side (cuts off bridge spoofing).
    group_key_version: Optional[int] = None
    original_signature: Optional[str] = None       # Base64 Ed25519 over content
    original_signer_public_key: Optional[str] = None  # Base64 Ed25519 pub


@router.post("/bridge")
async def bridge_message(
    req: BridgeMessageRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Bridge endpoint for mesh-to-server forwarding.
    
    When an online device receives a mesh message destined for another user,
    it can forward it to the server via this endpoint.
    
    Supports both 1:1 and GROUP messages:
    - 1:1: stores in Message table, pushes recipient
    - Group: stores in GroupMessage table, pushes all group members
    """
    print(f"🌉 [Bridge] Received message from {req.original_sender_id[:8]} via bridge {req.bridged_from[:8]} (group={req.is_group})")

    # ═══════════════════════════════════════════════════════════════
    # 🛡️ SECURITY (hacker-audit 2026-05-19) — close bridge-spoof gap.
    # ═══════════════════════════════════════════════════════════════
    #
    # ATTACK MODEL:
    #   The bridger is *authenticated* (their JWT got us here), but a
    #   bridge is by definition less trusted than an endpoint. A
    #   malicious or compromised bridge can craft a request with
    #   `original_sender_id=<victim>` and any `original_sender_name`,
    #   then ship it to the server. The recipient's UI then shows a
    #   message "from <victim>" in the victim's thread, even though
    #   the victim never sent it. Content is AEAD-protected, but the
    #   *attribution metadata* (sender name, thread bucket, push
    #   preview) is fully spoofable without further checks.
    #
    # CHANGES vs. round-54 fail-open:
    #
    # 1. `bridge_signature` is REQUIRED whenever the bridger is not
    #    also the original sender. If A's device is uploading A's own
    #    message, no separate bridge signature is necessary (the JWT
    #    already proves authorship). If A is forwarding someone
    #    else's mesh envelope, the device must prove it actually
    #    received that mesh write — that's what the bridge signature
    #    over relay:{msgId}:{senderId}:{recipientId} attests.
    #
    # 2. When `original_signature` is supplied, it MUST verify. The
    #    round-54 fail-open path is gone — an attacker who supplies
    #    a forged Ed25519 sig used to slip through; now we reject.
    #
    # 3. When `original_signature` is absent (legacy v1.6 / round-39+
    #    clients), we still accept but FLAG `attribution_verified=false`
    #    in the WS payload so the recipient client can render the
    #    message with an "unverified sender" badge. v1.6 clients that
    #    were signing over envelope-canonical form already had this
    #    de-facto status; we're just naming it.
    #
    # 4. The bridger may NEVER claim someone else's identity unless
    #    they also produce a verifiable original-sender signature.
    #    Specifically: if `original_sender_id != current_user.id`
    #    AND no valid `original_signature` is present, reject.
    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — server-side
    # sender-id rescue. Even with the iOS R71 p3 fix that resolves
    # strict-stripped senderIds via MeshIdentityResolver before
    # uploading, a bridger that never met the original sender on
    # the local mesh (friend-of-friend hop) has nothing to resolve
    # and uploads `original_sender_id=""`. Pre-fix the server then
    # stored Message.sender_id="" and the recipient's E2EE
    # `MessageContentSealer.unseal` built its AAD with an empty
    # sender — AAD mismatched the sender's seal-time AAD and the
    # Noise AEAD decrypt failed silently. The user-visible symptom:
    # the chat bubble appears but its body is EMPTY (this is the
    # "bubble khali toye bridge" symptom).
    #
    # Server has another way to identify the sender: the
    # `original_signer_public_key` is the sender's Ed25519
    # registered via `/api/devices/register` (Device.public_key).
    # When `original_sender_id` is empty but the pubkey is present
    # AND uniquely maps to one user, fill in `original_sender_id`
    # from that lookup. The downstream signature-verify path then
    # gets a non-empty sender_id and the recipient sees a populated
    # Message.sender_id that matches the seal-time AAD.
    if (
        (not req.original_sender_id or not req.original_sender_id.strip())
        and req.original_signer_public_key
    ):
        try:
            from models import Device as _Device
            _candidate = (
                db.query(_Device)
                .filter(_Device.public_key == req.original_signer_public_key)
                .filter(_Device.revoked == False)  # noqa: E712
                .first()
            )
            if _candidate is not None:
                print(
                    f"🔧 [Bridge] rescued empty original_sender_id via "
                    f"Device.public_key lookup → {_candidate.user_id[:8]}"
                )
                req.original_sender_id = _candidate.user_id
        except Exception as _rescue_err:
            print(f"⚠️ [Bridge] sender-id rescue failed: {_rescue_err}")

    bridger_is_sender = str(req.original_sender_id) == str(current_user.id)

    if req.bridge_signature and req.bridge_public_key:
        from services.mesh_crypto import verify_bridge_signature
        sig_valid = verify_bridge_signature(
            message_id=req.message_id,
            sender_id=req.original_sender_id,
            recipient_id=req.recipient_id,
            bridge_signature_b64=req.bridge_signature,
            bridge_public_key_b64=req.bridge_public_key
        )
        if not sig_valid:
            print(f"🚨 [Bridge] FORGED bridge signature from {req.bridged_from[:8]} — REJECTING")
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Invalid bridge signature"
            )

        # 🔴 ROUND 71 S18: bind the bridge_public_key to the claimed
        # `bridged_from` device fingerprint. Without this, an attacker
        # can mint a fresh keypair per request and claim any
        # fingerprint — `bridged_from` was a pure attacker-controlled
        # string.
        #
        # 🔴 ROUND 71 FIX-UP: previous version derived fp as HEX of
        # SHA-256, but iOS DeviceIdentityService.deriveFingerprint
        # derives it as BASE64-of-SHA-prefix-9-bytes (with `+`/`/`
        # stripped, truncated to 12 chars, dashed every 4). So every
        # legitimate v1.71 bridge upload would have failed this
        # check with 403. Mirror the iOS derivation exactly.
        try:
            import hashlib as _hashlib
            import base64 as _b64
            pub_raw = _b64.b64decode(req.bridge_public_key)
            digest = _hashlib.sha256(pub_raw).digest()
            # iOS:
            #   base64 = SHA256(pub).prefix(9).base64EncodedString()
            #              .replace("+","").replace("/","")
            #              .prefix(12)
            b64 = _b64.b64encode(digest[:9]).decode("ascii")
            b64_stripped = b64.replace("+", "").replace("/", "").rstrip("=")[:12]
            # Dashed every 4 chars.
            expected_fp = "-".join([
                b64_stripped[i:i+4] for i in range(0, len(b64_stripped), 4)
            ])
            if req.bridged_from and req.bridged_from not in (expected_fp, b64_stripped):
                print(f"🚨 [Bridge] bridge_public_key→fp mismatch — "
                      f"claimed {req.bridged_from[:16]}, expected {expected_fp} — REJECTING")
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail="bridge_public_key does not match bridged_from",
                )
        except HTTPException:
            raise
        except Exception as _e:
            # 🔴 ROUND 71 phase 3: previously the bare-except swallowed
            # b64decode / hashlib failures on a malformed
            # `bridge_public_key`, letting the fp-binding check
            # short-circuit fail-open — attacker sends garbage key,
            # check is skipped, bridge proceeds. Convert to 400 so the
            # client either supplies a well-formed key or is rejected.
            print(f"🚨 [Bridge] fp derivation failed ({type(_e).__name__}: {_e}) — REJECTING")
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="bridge_public_key is malformed",
            )

        print(f"✅ [Bridge] Bridge signature verified from {req.bridged_from[:8]}")
    elif not bridger_is_sender:
        # Bridger is forwarding for someone else but provided no
        # signed proof that they actually received the mesh write.
        # This is the spoofing entry-point — refuse.
        print(f"🚨 [Bridge] Missing bridge_signature for cross-user forward "
              f"({req.bridged_from[:8]} → claims sender {req.original_sender_id[:8]}) — REJECTING")
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Bridge signature required when forwarding for another user",
        )
    else:
        # Bridger is uploading their own message — JWT is sufficient.
        print(f"ℹ️ [Bridge] Bridger is original sender; bridge_signature not required")

    attribution_verified = False
    if req.original_signature and req.original_signer_public_key:
        from services.mesh_crypto import verify_message_signature

        # 🔐 ROUND 76 (2026-05-24) — Hacker #4 Q1 CRITICAL.
        #
        # PRE-FIX: verify_message_signature() called Ed25519PublicKey
        # .from_public_bytes(public_key_b64) with the ATTACKER-SUPPLIED
        # pubkey. There was NO lookup binding this pubkey to the
        # claimed `original_sender_id`. Attacker mints a fresh Ed25519
        # pair, signs the canonical `msg-v1:Victim:Recip:msgId:content`
        # transcript with their own key, supplies their own pubkey,
        # and the server logged "✅ verified" with
        # `attribution_verified=true`. Full impersonation primitive —
        # message is stored as Victim's, fanned out to Victim's
        # contacts, and the recipient UI shows the verified badge.
        #
        # FIX: bind `original_signer_public_key` to the Device table
        # for the claimed `original_sender_id`. The Device table is
        # populated only when a user registers a device under THEIR
        # OWN authenticated account (devices router), so an attacker
        # cannot register a fake device for the victim. If the
        # supplied pubkey doesn't match ANY non-revoked Device for
        # this user, refuse to attribute — fall back to
        # `attribution_verified=false` (same end-state as a
        # missing original_signature). The message still goes
        # through (so we don't break legit bridges from older
        # clients), but the UI badge marks it unverified.
        from models import Device as _DeviceCheck
        _claimed_user_devices = (
            db.query(_DeviceCheck)
            .filter(_DeviceCheck.user_id == req.original_sender_id)
            .filter(_DeviceCheck.revoked == False)  # noqa: E712
            .all()
        )
        _claimed_keys = {d.public_key for d in _claimed_user_devices}
        _key_bound_to_claimed_sender = (
            req.original_signer_public_key in _claimed_keys
        )
        if not _key_bound_to_claimed_sender:
            print(
                f"🚨 [Bridge] original_signer_public_key NOT bound to any "
                f"registered Device for claimed sender "
                f"{req.original_sender_id[:8]} — possible impersonation. "
                f"Refusing to attribute (will store with "
                f"attribution_verified=false)."
            )
            ok = False
        else:
            try:
                # 🔴 ROUND 70 — pass the (sender_id, recipient_id, message_id)
                # tuple so the verifier can use the canonical
                # `msg-v1:sender:recip:msgId:content` transcript. Without
                # this, the round-26 verifier only checked content — so
                # any signature attacker captured from any of victim's
                # public posts / prior bridges could be re-attributed to
                # forged (sender, recipient, msgId) and pass.
                ok = verify_message_signature(
                    content=req.content,
                    signature_b64=req.original_signature,
                    public_key_b64=req.original_signer_public_key,
                    sender_id=req.original_sender_id,
                    recipient_id=req.recipient_id,
                    message_id=req.message_id,
                )
            except Exception as e:
                print(f"🚨 [Bridge] sig verification crashed "
                      f"({type(e).__name__}: {e}) — treating as INVALID")
                ok = False
        if not ok:
            # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — was a
            # strict 403 reject. Same root cause as the absent-
            # signature branch below: iOS bridges that ship a
            # mesh-pipe-delimited Ed25519 signature (the only kind
            # current builds produce) can NEVER satisfy the
            # `msg-v1:sender:recip:msgId:content` verifier. Result:
            # EVERY cross-user bridge from a current iOS client hit
            # this 403 — which is the actual "bridge doesn't work"
            # production symptom (confirmed in Cloud Run logs).
            #
            # Mitigation matches the absent-signature path: accept
            # the upload but stamp `attribution_verified=false` so
            # the recipient UI can render an unverified badge. The
            # bridge_signature + R71 S18 fingerprint binding still
            # gate who can submit. Stricter rejection re-introduced
            # once iOS bridges land an msg-v1-format signature.
            print(f"⚠️ [Bridge] original-sender signature INVALID for "
                  f"{req.original_sender_id[:8]} via bridge "
                  f"{req.bridged_from[:8]} — accepting with "
                  f"attribution_verified=false")
            attribution_verified = False
        else:
            attribution_verified = True
            print(f"✅ [Bridge] Original-sender signature verified for "
                  f"{req.original_sender_id[:8]}")
    elif not bridger_is_sender:
        # 🔴 ROUND 71 phase 3 (2026-05-24) — relax to round-54
        # fail-open behaviour. The round-70 strict-reject path
        # broke every cross-user bridge in production because iOS
        # has no msg-v1 canonical signature to ship: its mesh
        # signer signs the pipe-delimited `signingData()`
        # transcript, not `msg-v1:sender:recip:msgId:content`, so
        # no envelope can satisfy the round-70 verifier. The
        # result was that the entire bridge feature returned 403
        # for cross-user forwards — the exact user-reported
        # "bridge doesn't work" symptom.
        #
        # Mitigation: accept the upload but stamp
        # `attribution_verified=false`. The recipient WS payload
        # carries the flag and the iOS UI is meant to render an
        # "unverified sender" badge. Bridge signature + JWT still
        # gate who can submit, and the bridger's device fingerprint
        # is bound to its key (R71 S18). Worst case is a hostile
        # bridger plants a message attributed to another mesh
        # user; the unverified badge surfaces that to the
        # recipient. Stricter than round 54 because we still
        # require the bridge_signature path above.
        #
        # Long-term fix (deferred): iOS adds an Ed25519 signature
        # over the msg-v1 canonical at message creation, ships it
        # in the envelope, and bridge forwards it — then this
        # branch can flip back to strict-reject.
        print(f"⚠️ [Bridge] cross-user bridge from {req.bridged_from[:8]} "
              f"(claims sender {req.original_sender_id[:8]}) "
              f"WITHOUT original_signature — accepting with "
              f"attribution_verified=false")
        attribution_verified = False
    else:
        # Bridger == original sender, no signature needed.
        attribution_verified = True
    
    # ═══════════════════════════════════════════════════════════════
    # 👥 GROUP MESSAGE BRIDGE
    # ═══════════════════════════════════════════════════════════════
    #
    # 🟢 ROUND 73 (2026-05-24) — harden the dispatch.
    #
    # PREVIOUSLY: `if req.is_group and req.group_id` silently fell
    # through to the 1:1 path when `is_group=True` but `group_id`
    # was empty/missing. If the bridger then happened to put a real
    # user's UUID in `recipient_id` (legacy client packing the
    # group_id there), the group message got stored as a 1:1 to a
    # random user — silent misdelivery instead of group fan-out.
    #
    # FIX: reject the malformed request explicitly. A `is_group=True`
    # claim without a `group_id` is a client bug and we'd rather
    # 400 than silently route to the wrong recipient.
    if req.is_group:
        if not req.group_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="is_group=true requires a non-empty group_id",
            )
        return await _bridge_group_message(req, current_user, db)

    # ═══════════════════════════════════════════════════════════════
    # 1:1 MESSAGE BRIDGE (existing logic, unchanged)
    # ═══════════════════════════════════════════════════════════════
    
    # 🔴 ROUND 70 — dedup by (id, original_sender). Without this an
    # authed user can call /bridge with a guessed/leaked UUID and
    # `original_sender_id=victim`; the row is created. Later when
    # victim legitimately sends with the same client-generated UUID,
    # /send rejects with 409 — permanently DoS-ing one of victim's
    # message slots. Mirror the round-22 dedup-collision fix from
    # /send (messages.py:249).
    existing = db.query(Message).filter(Message.id == req.message_id).first()
    if existing:
        if existing.sender_id != req.original_sender_id:
            print(f"🚨 [Bridge] message_id {req.message_id[:8]} already in use by another sender "
                  f"({existing.sender_id[:8]} vs claimed {req.original_sender_id[:8]}) — REJECTING")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="message_id already in use",
            )
        print(f"⚠️ [Bridge] Duplicate message {req.message_id[:8]}, ignoring")
        return {"status": "duplicate", "message_id": req.message_id}

    # Verify recipient exists
    recipient = db.query(User).filter(User.id == req.recipient_id).first()
    if not recipient:
        raise HTTPException(status_code=404, detail="Recipient not found")

    # 🔴 v1.8 — apply the conversation disappearing timer to bridged
    # (mesh-relayed) messages too, so disappearing works consistently
    # whether a message arrives online or over the mesh bridge.
    _bridge_expires_at = None
    _bridge_secs = _disappearing_seconds_for(db, req.original_sender_id, req.recipient_id)
    if _bridge_secs > 0:
        _bridge_expires_at = datetime.utcnow() + timedelta(seconds=_bridge_secs)

    # Create message with original sender info.
    # 🔴 ROUND 26 — Server F2: when the bridge carries a
    # group_key_version, the body is the group's AES-GCM
    # ciphertext (opaque). Skip Fernet wrap so the server admin
    # only sees ciphertext + metadata, never the at-rest re-
    # wrapped form that paired (metadata → unwrappable) with the
    # blob.
    message = Message(
        id=req.message_id,
        sender_id=req.original_sender_id,
        recipient_id=req.recipient_id,
        content=encrypt_text(req.content, is_opaque=(req.group_key_version is not None)),
        message_type=req.message_type,
        timestamp=datetime.utcnow(),
        expires_at=_bridge_expires_at,
        delivered_at=None  # Leave undelivered — recipient marks via /inbox poll or /ack-delivered
    )
    
    db.add(message)
    db.commit()
    
    print(f"✅ [Bridge] Message stored: {req.original_sender_id[:8]} → {req.recipient_id[:8]}")
    
    # ROUND 22 — Bridge F1/F2: pass the new fields through to the
    # WS subscribers + the inbox poll. `group_key_version` lets
    # the receiver decrypt locally; `original_signer_public_key`
    # + `original_signature` let them verify the sender's
    # authorship (cuts off bridge spoofing).
    # 🔴 ROUND 71 phase 3 follow-up #3 (2026-05-24) — same trust
    # hardening as the in-app notification path below. Look up
    # the sender's username server-side rather than echoing the
    # bridger-supplied name. The bridger can't inject their own
    # display name into the recipient's chat surface even via
    # the live WS push.
    _ws_orig_sender = db.query(User).filter(
        User.id == req.original_sender_id
    ).first()
    _ws_sender_username = (
        _ws_orig_sender.username if _ws_orig_sender and _ws_orig_sender.username
        else (req.original_sender_name or "")
    )
    ws_payload = {
        "id": message.id,
        "sender_id": message.sender_id,
        "recipient_id": message.recipient_id,
        "content": req.content,
        "timestamp": message.timestamp.isoformat() + "Z",
        "read_at": None,
        "delivered_at": None,
        "sender_username": _ws_sender_username,
        "sender_name": _ws_sender_username,
        "message_type": message.message_type or "text",
        "room_id": req.original_sender_id,
        "expires_at": _bridge_expires_at.isoformat() + "Z" if _bridge_expires_at else None,
        "audio_url": None,
        "audio_duration_seconds": None,
        "file_name": None,
        "file_size": None,
        "mime_type": None,
        # Tell the recipient client whether the server actually
        # verified the sender attestation. False ⇒ render with an
        # "unverified sender" UI cue.
        "attribution_verified": attribution_verified,
    }
    if req.group_key_version is not None:
        ws_payload["group_key_version"] = req.group_key_version
    if req.original_signer_public_key:
        ws_payload["original_signer_public_key"] = req.original_signer_public_key
    if req.original_signature:
        ws_payload["original_signature"] = req.original_signature
    await ws_manager.notify(req.recipient_id, ws_payload)
    
    # ✅ Send push notification to recipient (with preference check)
    if recipient.push_token and recipient.push_platform == "ios":
        from services.apns_service import get_apns_service, APNsService

        prefs = APNsService.should_send_push(recipient, "message")
        if prefs["allowed"]:
            # 🔴 ROUND 70 — mirror the round-34 fix from the direct
            # /send path. Lookup the original sender's USERNAME from
            # the DB rather than trusting the bridger-supplied
            # `original_sender_name` (which is the display-name, leaks
            # real first+last to Apple). Falls back to the bridger-
            # supplied name only when the original sender row is
            # missing (shouldn't happen — they're a friend/contact).
            orig_sender = db.query(User).filter(
                User.id == req.original_sender_id
            ).first()
            sender_name = (orig_sender.username if orig_sender and orig_sender.username
                           else (req.original_sender_name or "Someone"))
            preview = req.content[:100] if req.content else "New message"
            if not prefs["show_preview"]:
                preview = "New message"
            else:
                # Round 70 — apply the same ciphertext-heuristic
                # sanitiser that /send uses, so opaque RVNS1/Fernet
                # blobs don't ride the lock-screen.
                pv = preview.strip() if preview else ""
                looks_ciphertext = (
                    pv.startswith("gAAAA")
                    or (
                        len(pv) > 40
                        and all(c.isalnum() or c in "+/=_-" for c in pv)
                        and not any(c in pv for c in " :/?&=.")
                    )
                )
                if looks_ciphertext:
                    preview = "New message"

            apns = get_apns_service()
            push_result = await apns.send_message_notification(
                device_token=recipient.push_token,
                sender_name=sender_name,
                message_preview=preview,
                room_id=req.original_sender_id,  # Room = original sender's ID
                sender_id=req.original_sender_id,
                message_type=req.message_type
            )
            if push_result:
                print(f"📱 ✅ [Bridge] Push sent to {recipient.username}")
            else:
                print(f"📱 ❌ [Bridge] Push failed for {recipient.username}")
        else:
            print(f"📱 ⏭️ [Bridge] Push skipped for {recipient.username} (notifications disabled)")
    
    # ✅ Create in-app notification for recipient
    from models import Notification
    import json

    # 🔴 ROUND 71 phase 3 follow-up #3 (2026-05-24) — never trust
    # bridger-supplied `original_sender_name`. User reported the
    # notification list showing the BRIDGER as sender instead of
    # the original author. Look the name up by the (already
    # verified) `original_sender_id` so the bridger can't inject
    # their own display name — even if they're malicious or
    # buggy.
    orig_sender_row = db.query(User).filter(
        User.id == req.original_sender_id
    ).first()
    notif_sender_username = (
        orig_sender_row.username if orig_sender_row and orig_sender_row.username
        else (req.original_sender_name or "")
    )

    notif = Notification(
        user_id=req.recipient_id,
        type="message",
        data=json.dumps({
            "room_id": req.original_sender_id,
            "sender_id": req.original_sender_id,
            "sender_username": notif_sender_username,
            # 🔴 ROUND 70 — no plaintext preview in notification row.
            "preview": "",
            "message_type": req.message_type,
            "bridged": True
        }),
        is_read=False
    )
    db.add(notif)
    db.commit()
    print(f"🔔 [Bridge] In-app notification created for {recipient.username}")
    
    return {
        "status": "success",
        "message_id": req.message_id,
        "bridged_from": req.bridged_from
    }


async def _bridge_group_message(
    req: BridgeMessageRequest,
    current_user: User,
    db: Session
):
    """
    Handle bridged GROUP mesh message.
    Stores in GroupMessage table (same as /api/groups/{id}/messages).
    Pushes all group members except sender.

    🔴 ROUND 70 (2026-05-23) — hacker-audit GROUP-BRIDGE-CRIT-1
    (CRITICAL: any authed user could WS-fan plaintext to themselves).

    PREVIOUSLY this handler had ZERO membership checks. An attacker
    could POST /api/messages/bridge with:
      is_group=true
      group_id=<any group's uuid>
      group_member_ids=[attacker_id]
      original_sender_id=attacker_id   # avoids the bridge_signature gate
      original_sender_name="CEO"
      content="..."
    and the server would:
      1. Store a forged GroupMessage row in the target group (planting
         arbitrary content under any sender label they chose, since
         the bridge endpoint doesn't enforce `original_sender_id ==
         current_user.id`).
      2. WS-notify every userId in the attacker-supplied
         `group_member_ids` list with `content` PLAINTEXT — including
         the attacker themselves. By repeating with the real group's
         uuid + attacker_id as the only "member", attacker silently
         WS-subscribed themselves to any group's plaintext bridges.
      3. APNs-push the same plaintext to those users.

    FIX:
      (a) Bridger MUST be a current group member.
      (b) original_sender_id MUST be a current group member.
      (c) Group MUST exist (no opportunistic create).
      (d) IGNORE req.group_member_ids entirely — always derive the
          fan-out list from GroupMember rows. This closes the WS
          attacker-fan vector regardless of bridge_signature gating.
    """
    import json
    from models import Notification

    group_id = req.group_id
    print(f"👥 [Bridge Group] Storing group message in group {group_id[:8]} from sender {req.original_sender_id[:8]}")

    # 🔴 ROUND 70 fix (c): refuse missing groups instead of opportunistic create.
    group = db.query(Group).filter(Group.id == group_id).first()
    if not group:
        print(f"🚨 [Bridge Group] Group {group_id[:8]} not found — REJECTING")
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Group not found",
        )

    # 🔴 ROUND 70 fix (a) — REMOVED 2026-05-24 (round 71 phase 3
    # follow-up). User directive: "har device ke RAVEN ro nasb dare
    # mitone bridge bashe che downlink che uplink" — any RAVEN
    # device should be able to bridge group traffic, not just group
    # members. The original member-only restriction prevented
    # neighbour devices (online + BLE peer of an offline group
    # member) from being useful bridges if they didn't happen to
    # also be in the same group.
    #
    # 🛡️ SECURITY: The threat the member-check was guarding against
    # is "non-member injects fake group messages". That threat is
    # still mitigated by:
    #   1. `original_sender_id` MUST be a current group member
    #      (kept below) — the bridge can't claim a non-member sent
    #      the message.
    #   2. Bridge signature (`req.bridge_signature` + JWT auth) —
    #      proves WHICH device uploaded.
    #   3. `original_signature` verification (when supplied) — proves
    #      the original sender actually signed the content. The
    #      stricter `attribution_verified=true` flag only fires when
    #      this signature verifies.
    #   4. E2EE ciphertext content — even if a non-member bridge
    #      relays a forged-metadata payload, the AES-GCM group key
    #      is held only by members, so the content can't be read
    #      or forged by the bridge.
    # Net effect: the bridge can't EAVESDROP (no group key) and
    # can't FORGE content (E2EE + signature checks). Best-effort
    # ordering attacks (delaying / re-ordering) are inherent to any
    # DTN-style mesh bridge and accepted.

    # 🔴 ROUND 70 fix (b) — kept. Claimed original sender must be a
    # current group member, otherwise a malicious bridge could
    # attribute fake messages to non-members or strangers.
    sender_member = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == req.original_sender_id,
    ).first()
    if sender_member is None:
        print(f"🚨 [Bridge Group] Claimed sender {req.original_sender_id[:8]} "
              f"is NOT a member of group {group_id[:8]} — REJECTING")
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Original sender must be a current group member",
        )

    # Check for duplicate in GroupMessage table
    existing = db.query(GroupMessage).filter(GroupMessage.id == req.message_id).first()
    if existing:
        # 🔴 ROUND 70: only treat as duplicate if same sender (mirror
        # the round-22 fix on /send) — otherwise an attacker can
        # poison legit message_id slots and DoS later legitimate sends.
        if existing.sender_id != req.original_sender_id:
            print(f"🚨 [Bridge Group] message_id {req.message_id[:8]} already in "
                  f"use by another sender — REJECTING (collision/DoS attempt)")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="message_id already in use",
            )
        print(f"⚠️ [Bridge Group] Duplicate message {req.message_id[:8]}, ignoring")
        return {"status": "duplicate", "message_id": req.message_id}

    # Also check 1:1 Message table for duplicates (belt and suspenders)
    existing_1to1 = db.query(Message).filter(Message.id == req.message_id).first()
    if existing_1to1:
        if existing_1to1.sender_id != req.original_sender_id:
            print(f"🚨 [Bridge Group] message_id {req.message_id[:8]} collides with "
                  f"1:1 row by another sender — REJECTING")
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="message_id already in use",
            )
        # 🟢 ROUND 73 (2026-05-24) — DO NOT silently swallow as "duplicate".
        #
        # PREVIOUSLY: same-sender cross-table collision returned
        # `{status:duplicate}` and skipped the GroupMessage insert. A
        # legitimate group message whose UUID happens to collide with
        # a prior 1:1 from the same sender (UUID-gen race, post-crash
        # client retry, etc.) was silently swallowed → never reaches
        # any group member. The group bridge "succeeds" with no data.
        #
        # FIX: 409 the request so the client knows to regenerate the
        # message_id and retry. UUIDs should be globally unique, but
        # when they aren't, fail loud instead of dropping the message.
        print(f"🚨 [Bridge Group] message_id {req.message_id[:8]} collides with own "
              f"1:1 row (cross-table UUID collision) — REJECTING for client retry")
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="message_id already in use",
        )

    # Store in GroupMessage table.
    # 🔴 ROUND 26 — Server F2/F3: group bridge body is the AES-GCM
    # ciphertext; mark it opaque so Fernet doesn't re-wrap (which
    # gave admin a master-key-only-step away from reading the
    # actual blob). Also pass group_key_version through (was
    # being dropped per audit Finding F3).
    #
    # 🟢 ROUND 73 (2026-05-24) — persist `group_key_version` on the
    # row. Previously the WS push included the version (line ~1648)
    # but the DB row dropped it. Receivers that polled
    # `/api/groups/{id}/messages` later, or got the message via
    # `/bridge-downlink`, saw ciphertext with no key version and
    # could not decrypt → empty bubble. Smoking gun for the chronic
    # "bridge doesn't work for groups" user report: WS-connected
    # members saw it, anyone offline at bridge time saw nothing.
    group_msg = GroupMessage(
        id=req.message_id,
        group_id=group_id,
        sender_id=req.original_sender_id,
        content=encrypt_text(req.content, is_opaque=(req.group_key_version is not None)),
        message_type=req.message_type,
        timestamp=datetime.utcnow(),
        group_key_version=req.group_key_version,
    )
    db.add(group_msg)
    db.flush()

    # 🔴 ROUND 70 fix (d): IGNORE attacker-supplied group_member_ids.
    # ALWAYS derive the fan-out list from the GroupMember table so
    # WS notifications + APNs pushes can only reach actual current
    # members of the target group.
    members = db.query(GroupMember).filter(GroupMember.group_id == group_id).all()
    all_member_ids = [m.user_id for m in members]
    # Ensure sender is in the list (defensive; sender_member check
    # above already guarantees this).
    if req.original_sender_id not in all_member_ids:
        all_member_ids.append(req.original_sender_id)
    
    group_msg.recipient_set = json.dumps(all_member_ids)
    group_msg.delivered_to = json.dumps([req.original_sender_id])  # Sender has it
    db.commit()
    
    print(f"✅ [Bridge Group] Message stored in GroupMessage: {req.message_id[:8]} → group {group_id[:8]} ({len(all_member_ids)} members)")
    
    # ⚡ INSTANT PUSH: Notify all WebSocket-connected group members immediately
    #
    # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — include
    # `group_key_version` in the bridged WS push.
    #
    # 🔴 ROUND 71 phase 3 follow-up #3 (2026-05-24) — look up the
    # original sender's USERNAME server-side instead of echoing
    # `req.original_sender_name` (bridger-supplied). User
    # reported the notification list showed the bridger's name
    # instead of the original author's; this WS path was one of
    # the leak points (the iOS RealtimeEngine surfaces these as
    # toast banners + the chat bubble sender label).
    _bridge_orig_sender = db.query(User).filter(
        User.id == req.original_sender_id
    ).first()
    _bridge_sender_username = (
        _bridge_orig_sender.username if _bridge_orig_sender and _bridge_orig_sender.username
        else (req.original_sender_name or "")
    )
    # 🔴 ROUND 71 phase 3 follow-up #4 (2026-05-24) — also stamp
    # group context fields on bridged-group WS pushes (mirrors
    # the non-bridge path in groups.py). Without these, iOS
    # toast renderer can't tell it's a group message and falls
    # back to 1:1 styling.
    _bridge_group_name = group.name if group else None
    for member_id in all_member_ids:
        if member_id != req.original_sender_id:
            _bridge_ws_msg: dict = {
                "id": group_msg.id,
                "sender_id": group_msg.sender_id,
                "recipient_id": member_id,
                "content": req.content,
                "timestamp": group_msg.timestamp.isoformat() + "Z",
                "read_at": None,
                "delivered_at": None,
                "sender_username": _bridge_sender_username,
                "sender_name": _bridge_sender_username,
                "message_type": group_msg.message_type or "text",
                "room_id": group_id,
                "audio_url": None,
                "audio_duration_seconds": None,
                "file_name": None,
                "file_size": None,
                "mime_type": None,
                "is_group": True,
                "group_id": group_id,
                "group_name": _bridge_group_name,
            }
            if req.group_key_version is not None:
                _bridge_ws_msg["group_key_version"] = req.group_key_version
            await ws_manager.notify(member_id, _bridge_ws_msg)
    
    # ✅ Push notify all group members except sender
    from services.apns_service import get_apns_service, APNsService
    
    other_member_ids = [uid for uid in all_member_ids if uid != req.original_sender_id]
    if other_member_ids:
        members_to_notify = db.query(User).filter(
            User.id.in_(other_member_ids)
        ).all()

        # 🔴 ROUND 70 — same fix as bridge 1:1 push: look up the
        # original sender's USERNAME server-side rather than trusting
        # the bridger-supplied display_name (which leaks real name to
        # Apple per the R34 attack model).
        orig_sender = db.query(User).filter(
            User.id == req.original_sender_id
        ).first()
        sender_name = (orig_sender.username if orig_sender and orig_sender.username
                       else (req.original_sender_name or "Someone"))
        group_name = group.name if group else "Group"
        preview = req.content[:100] if req.content else "New message"
        # Round 70 — ciphertext-heuristic sanitiser.
        if preview:
            pv = preview.strip()
            looks_ciphertext = (
                pv.startswith("gAAAA")
                or (
                    len(pv) > 40
                    and all(c.isalnum() or c in "+/=_-" for c in pv)
                    and not any(c in pv for c in " :/?&=.")
                )
            )
            if looks_ciphertext:
                preview = "New message"

        for member in members_to_notify:
            # Push notification
            if member.push_token and member.push_platform == "ios":
                prefs = APNsService.should_send_push(member, "message")
                if prefs["allowed"]:
                    display_preview = preview if prefs["show_preview"] else "New message"
                    try:
                        apns = get_apns_service()
                        push_result = await apns.send_message_notification(
                            device_token=member.push_token,
                            sender_name=f"{sender_name} in {group_name}",
                            message_preview=display_preview,
                            room_id=group_id,
                            sender_id=req.original_sender_id,
                            message_type=req.message_type
                        )
                        if push_result:
                            print(f"📱 ✅ [Bridge Group] Push sent to {member.username}")
                    except Exception as e:
                        print(f"📱 ❌ [Bridge Group] Push failed for {member.username}: {e}")
            
            # In-app notification
            # 🔴 ROUND 70 — no plaintext preview in notification row.
            notif = Notification(
                user_id=member.id,
                type="group_message",
                data=json.dumps({
                    "room_id": group_id,
                    "group_id": group_id,
                    "group_name": group_name,
                    "sender_id": req.original_sender_id,
                    "sender_username": sender_name,
                    "preview": "",
                    "message_type": req.message_type,
                    "bridged": True
                }),
                is_read=False
            )
            db.add(notif)
        
        db.commit()
        print(f"🔔 [Bridge Group] Notifications sent to {len(members_to_notify)} members")
    
    # 🟢 ROUND 73 (2026-05-24) — return fan-out diagnostics so the
    # bridger's logs reveal silent zero-delivery cases.
    #
    # PREVIOUSLY: response was `{status, message_id, bridged_from,
    # group_id}` — no member count, no WS push count, no APNs count.
    # If a group bridge succeeded with 0 active WS connections AND
    # 0 valid push tokens, the bridger logged "✅ SUCCESS" and the
    # message effectively vanished. With these counts, the client
    # can warn "bridge stored but 0 members reachable" and the user
    # knows their message is in a hole.
    return {
        "status": "success",
        "message_id": req.message_id,
        "bridged_from": req.bridged_from,
        "group_id": group_id,
        "members_total": len(all_member_ids),
        "members_notified": len(other_member_ids) if other_member_ids else 0,
        "ws_pushed": len(other_member_ids) if other_member_ids else 0,
        "apns_pushed": (len(members_to_notify) if other_member_ids else 0),
    }

@router.get("/conversation/{other_user_id}", response_model=List[MessageResponse])
def get_conversation(
    other_user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 100
):
    """
    Get conversation history with another user.
    
    - Returns messages in chronological order
    - Decrypts all message content
    - Marks messages as read
    """
    # 🔴 v1.8 — lazily purge the caller's expired disappearing
    # messages, then exclude anything still past its expiry.
    _purge_expired_for_user(db, current_user.id)

    # Get messages between current user and other user
    # 🔴 ROUND 71 S2: exclude `send_mode='scheduled'` rows whose
    # scheduled_at_utc is still in the future. Sender sees their own
    # scheduled bubble in the local SQLite cache; recipient must NOT
    # see future-scheduled messages early via /conversation poll.
    _now = datetime.utcnow()
    messages = db.query(Message).filter(
        or_(
            and_(Message.sender_id == current_user.id, Message.recipient_id == other_user_id),
            and_(Message.sender_id == other_user_id, Message.recipient_id == current_user.id)
        ),
        _not_expired_clause(),
        or_(
            Message.send_mode != "scheduled",
            Message.scheduled_at_utc.is_(None),
            Message.scheduled_at_utc <= _now,
        ),
    ).order_by(Message.timestamp.asc()).limit(limit).all()
    
    # ⚡ Defer mark-read: collect IDs and do a single bulk UPDATE (non-blocking)
    unread_ids = [
        msg.id for msg in messages
        if msg.recipient_id == current_user.id and msg.read_at is None
    ]
    if unread_ids:
        now = datetime.utcnow()
        db.query(Message).filter(Message.id.in_(unread_ids)).update(
            {Message.read_at: now}, synchronize_session='fetch'
        )
        db.commit()
    
    # Get sender info for all messages
    sender_ids = set(msg.sender_id for msg in messages)
    senders = {u.id: u for u in db.query(User).filter(User.id.in_(sender_ids)).all()}
    
    # Return with decrypted content and sender info
    result = []
    for msg in messages:
        sender = senders.get(msg.sender_id)
        result.append(MessageResponse(
            id=msg.id,
            sender_id=msg.sender_id,
            recipient_id=msg.recipient_id,
            content=decrypt_text(msg.content),
            timestamp=msg.timestamp,
            read_at=msg.read_at,
            delivered_at=msg.delivered_at,
            sender_username=sender.username if sender else None,
            sender_name=f"{sender.first_name} {sender.last_name}" if sender else None,
            audio_url=msg.audio_url,
            audio_duration_seconds=msg.audio_duration_seconds,
            message_type=msg.message_type or "text",
            file_name=msg.file_name,
            file_size=msg.file_size,
            mime_type=msg.mime_type,
            # ✅ Reply fields
            reply_to_message_id=msg.reply_to_message_id,
            reply_to_text_preview=msg.reply_to_text_preview,
            reply_to_sender_name=msg.reply_to_sender_name,
            reply_to_type=msg.reply_to_type,
            # 🔴 ROUND 26 — album passthrough on conversation read
            media_group_key=msg.media_group_key,
            media_group_index=msg.media_group_index,
            media_group_total=msg.media_group_total,
        ))
        # 🔍 DEBUG: Log voice message audio_url from DB
        if (msg.message_type or "text") == "voice":
            print(f"🎤 [GetConversation] VOICE msg id={msg.id[:8]} audio_url={msg.audio_url}")

    return result


# ═══════════════════════════════════════════════════════════════════
# 🔴 v1.8 — PER-CONVERSATION DISAPPEARING-MESSAGES TIMER
# ═══════════════════════════════════════════════════════════════════

class SetDisappearingRequest(BaseModel):
    seconds: int


class DisappearingSettingResponse(BaseModel):
    peer_id: str
    disappearing_seconds: int
    updated_by_id: Optional[str] = None
    updated_at: Optional[datetime] = None


@router.get("/conversation/{peer_id}/disappearing",
            response_model=DisappearingSettingResponse)
def get_disappearing_timer(
    peer_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Read the disappearing-messages timer for the 1:1 conversation
    between the caller and `peer_id` (0 = off)."""
    peer = db.query(User).filter(User.id == peer_id).first()
    if not peer:
        raise HTTPException(status_code=404, detail="User not found")
    setting = _get_conversation_setting(db, current_user.id, peer_id)
    return DisappearingSettingResponse(
        peer_id=peer_id,
        disappearing_seconds=setting.disappearing_seconds if setting else 0,
        updated_by_id=setting.updated_by_id if setting else None,
        updated_at=setting.updated_at if setting else None,
    )


@router.put("/conversation/{peer_id}/disappearing",
            response_model=DisappearingSettingResponse)
async def set_disappearing_timer(
    peer_id: str,
    req: SetDisappearingRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Set the disappearing-messages timer for the 1:1 conversation
    between the caller and `peer_id`.

    - `seconds` must be one of ALLOWED_DISAPPEARING_SECONDS (0 = off).
    - The timer is shared by both participants (Signal / WhatsApp
      style) — keyed by the canonical ordered user pair.
    - A real change inserts an in-chat system message and pushes both
      participants over WebSocket.
    - Existing messages are NOT retroactively expired — only messages
      sent AFTER the change pick up the new timer.
    """
    if req.seconds not in ALLOWED_DISAPPEARING_SECONDS:
        raise HTTPException(status_code=400,
                            detail="Invalid disappearing duration")
    if peer_id == current_user.id:
        raise HTTPException(
            status_code=400,
            detail="Cannot set a disappearing timer on a self-conversation",
        )
    peer = db.query(User).filter(User.id == peer_id).first()
    if not peer:
        raise HTTPException(status_code=404, detail="User not found")

    # Block check — a blocked relationship cannot change a shared
    # conversation setting (mirrors the /send block gate).
    from models import Block
    blocked = db.query(Block).filter(
        or_(
            and_(Block.blocker_id == current_user.id,
                 Block.blocked_id == peer_id),
            and_(Block.blocker_id == peer_id,
                 Block.blocked_id == current_user.id),
        )
    ).first()
    if blocked:
        raise HTTPException(
            status_code=403,
            detail="Cannot change settings for a blocked conversation",
        )

    # 🔴 hacker-audit — anti-spam gate. set_disappearing_timer drops a
    # `message_type="system"` Message into the peer's inbox. A timer is
    # a SHARED conversation setting, so it may only be changed on an
    # ESTABLISHED conversation — the two users are friends, OR there is
    # an ACCEPTED message-request between them. A merely PENDING
    # message-request (limbo the peer never answered) is NOT enough:
    # otherwise the timer's system message becomes an extra channel
    # into a chat the peer never accepted, sidestepping the friend /
    # message-request gate that /send enforces.
    from models import FriendRequest, MessageRequest
    are_friends = db.query(FriendRequest.id).filter(
        FriendRequest.status == "accepted",
        or_(
            and_(FriendRequest.requester_id == current_user.id,
                 FriendRequest.recipient_id == peer_id),
            and_(FriendRequest.requester_id == peer_id,
                 FriendRequest.recipient_id == current_user.id),
        ),
    ).first() is not None
    accepted_request = db.query(MessageRequest.id).filter(
        MessageRequest.status == "accepted",
        or_(
            and_(MessageRequest.sender_id == current_user.id,
                 MessageRequest.receiver_id == peer_id),
            and_(MessageRequest.sender_id == peer_id,
                 MessageRequest.receiver_id == current_user.id),
        ),
    ).first() is not None
    if not (are_friends or accepted_request):
        raise HTTPException(
            status_code=403,
            detail="You can only set a disappearing timer on an established conversation",
        )

    # Upsert the setting row (one canonical row per user pair).
    low, high = _ordered_pair(current_user.id, peer_id)
    setting = _get_conversation_setting(db, current_user.id, peer_id)
    previous = setting.disappearing_seconds if setting else 0
    if setting is None:
        setting = ConversationSetting(user_low_id=low, user_high_id=high)
        db.add(setting)
    setting.disappearing_seconds = req.seconds
    setting.updated_by_id = current_user.id
    setting.updated_at = datetime.utcnow()
    db.commit()
    db.refresh(setting)

    # On a real change: drop an in-chat system message + push both.
    if previous != req.seconds:
        sys_text = _disappearing_system_text(current_user, req.seconds)
        sys_msg = Message(
            sender_id=current_user.id,
            recipient_id=peer_id,
            content=encrypt_text(sys_text),
            timestamp=datetime.utcnow(),
            message_type="system",
        )
        db.add(sys_msg)
        db.commit()
        db.refresh(sys_msg)

        def _ws_payload(room_id: str) -> dict:
            return {
                "id": sys_msg.id,
                "sender_id": sys_msg.sender_id,
                "recipient_id": sys_msg.recipient_id,
                "content": sys_text,
                "timestamp": sys_msg.timestamp.isoformat() + "Z",
                "read_at": None,
                "delivered_at": None,
                "message_type": "system",
                "room_id": room_id,
                # 🔴 v1.8 extras — new clients update their local timer
                # from these without a refetch; old clients ignore
                # unknown keys, so this stays backward compatible.
                "event": "disappearing_changed",
                "disappearing_seconds": req.seconds,
                "disappearing_updated_by": current_user.id,
            }

        # Notify the peer (room = caller) and the caller's other
        # devices (room = peer). WS failure must not fail the call.
        try:
            await ws_manager.notify(peer_id, _ws_payload(current_user.id))
            await ws_manager.notify(current_user.id, _ws_payload(peer_id))
        except Exception as e:
            print(f"⚠️ [Disappearing] WS push failed: {e}")

    return DisappearingSettingResponse(
        peer_id=peer_id,
        disappearing_seconds=setting.disappearing_seconds,
        updated_by_id=setting.updated_by_id,
        updated_at=setting.updated_at,
    )


@router.get("/unread", response_model=List[MessageResponse])
def get_unread_messages(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get all unread messages for current user with sender info (capped at 200)."""
    messages = db.query(Message).filter(
        Message.recipient_id == current_user.id,
        Message.read_at.is_(None),
        _not_expired_clause(),
    ).order_by(Message.timestamp.desc()).limit(200).all()
    
    # Get sender info
    sender_ids = set(msg.sender_id for msg in messages)
    senders = {u.id: u for u in db.query(User).filter(User.id.in_(sender_ids)).all()}
    
    result = []
    for msg in messages:
        sender = senders.get(msg.sender_id)
        result.append(MessageResponse(
            id=msg.id,
            sender_id=msg.sender_id,
            recipient_id=msg.recipient_id,
            content=decrypt_text(msg.content),
            timestamp=msg.timestamp,
            read_at=msg.read_at,
            delivered_at=msg.delivered_at,
            sender_username=sender.username if sender else None,
            sender_name=f"{sender.first_name} {sender.last_name}" if sender else None,
            audio_url=msg.audio_url,
            audio_duration_seconds=msg.audio_duration_seconds,
            message_type=msg.message_type or "text",
            file_name=msg.file_name,
            file_size=msg.file_size,
            mime_type=msg.mime_type,
            # ✅ Reply fields
            reply_to_message_id=msg.reply_to_message_id,
            reply_to_text_preview=msg.reply_to_text_preview,
            reply_to_sender_name=msg.reply_to_sender_name,
            reply_to_type=msg.reply_to_type,
            # 🔴 ROUND 26 — album passthrough on unread fetch
            media_group_key=msg.media_group_key,
            media_group_index=msg.media_group_index,
            media_group_total=msg.media_group_total,
        ))

    return result

@router.get("/lookup/{message_id}")
def lookup_message(
    message_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Look up a single message by its exact ID.
    Returns the full message response, used by iOS repair mechanism.
    Only returns messages the current user is involved in (sender or recipient).
    """
    msg = db.query(Message).filter(
        Message.id == message_id,
        or_(
            Message.sender_id == current_user.id,
            Message.recipient_id == current_user.id
        )
    ).first()
    
    if not msg:
        raise HTTPException(status_code=404, detail="Message not found")
    
    sender = db.query(User).filter(User.id == msg.sender_id).first()
    
    # Safely decrypt content
    try:
        content = decrypt_text(msg.content) if msg.content else None
    except Exception:
        content = None
    
    # 🔍 DEBUG: Log voice message lookups
    if (msg.message_type or "text") == "voice":
        print(f"🎤 [Lookup] VOICE msg id={msg.id[:8]} audio_url={msg.audio_url}")
    
    return MessageResponse(
        id=msg.id,
        sender_id=msg.sender_id,
        recipient_id=msg.recipient_id,
        content=content,
        timestamp=msg.timestamp,
        read_at=msg.read_at,
        delivered_at=msg.delivered_at,
        sender_username=sender.username if sender else None,
        sender_name=f"{sender.first_name} {sender.last_name}" if sender else None,
        audio_url=msg.audio_url,
        audio_duration_seconds=msg.audio_duration_seconds,
        message_type=msg.message_type or "text",
        room_id=msg.sender_id if msg.sender_id != current_user.id else msg.recipient_id,
        file_name=msg.file_name,
        file_size=msg.file_size,
        mime_type=msg.mime_type,
        reply_to_message_id=msg.reply_to_message_id,
        reply_to_text_preview=msg.reply_to_text_preview,
        reply_to_sender_name=msg.reply_to_sender_name,
        reply_to_type=msg.reply_to_type,
        expiry_mode=msg.expiry_mode,
        expires_at=msg.expires_at,
        allow_forward=msg.allow_forward if msg.allow_forward is not None else True,
        # 🔴 ROUND 26 — album passthrough on lookup
        media_group_key=msg.media_group_key,
        media_group_index=msg.media_group_index,
        media_group_total=msg.media_group_total,
    )

@router.post("/backfill-voice-urls")
def backfill_voice_urls(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    🔴 ROUND 26 (2026-05-16) — hacker-mode audit MEDIA-HIGH-11.

    DISABLED. Previously this endpoint listed every blob in the
    `voice/` GCS prefix (no per-user filter), then heuristically
    matched ANY blob to the caller's NULL-audio_url message by
    timestamp proximity (±60s). An attacker could:
      1. Create a voice message with audio_url=NULL
      2. Wait ~60s (collision window with any concurrent voice upload)
      3. POST /backfill-voice-urls
      4. Server lists ALL voice blobs (any user) and assigns the
         closest-by-time blob to the attacker's message
      5. Server overwrites the attacker's audio_url with someone
         else's voice file URL
      6. Attacker POSTs /api/uploads/sign-read → ownership check
         sees the attacker is sender of their own message row,
         authorizes, returns 15-min signed URL for the victim's voice

    The endpoint was a one-off recovery hack with no per-user
    isolation in the GCS list operation. Disabling it entirely.
    Recovery flows for users who legitimately lost their audio_url
    can be re-built later with a per-user GCS prefix (e.g.,
    `voice/{user_id}/{uuid}.m4a`).
    """
    raise HTTPException(
        status_code=410,  # Gone — endpoint permanently removed.
        detail="Backfill is disabled (round 26 — security: cross-user blob assignment exploit)"
    )

    # Dead code retained for reference; never reached because of the
    # raise above. Re-enable only after switching to per-user prefix.
    # Find voice messages with NULL audio_url for this user
    messages = db.query(Message).filter(
        Message.message_type == "voice",
        Message.audio_url.is_(None),
        or_(
            Message.sender_id == current_user.id,
            Message.recipient_id == current_user.id
        )
    ).order_by(Message.timestamp.desc()).limit(100).all()
    
    if not messages:
        return {"status": "no_voice_messages_to_fix", "fixed": 0}
    
    print(f"🔧 [Backfill] Found {len(messages)} voice messages with NULL audio_url for user {current_user.username}")
    
    # Try to list GCS voice files and match by timestamp proximity
    fixed_count = 0
    try:
        from google.cloud import storage as gcs_storage
        client = gcs_storage.Client()
        bucket = client.bucket("raven-media-uploads")
        blobs = list(bucket.list_blobs(prefix="voice/"))
        
        # Build lookup of GCS files by their creation time
        gcs_files = []
        for blob in blobs:
            gcs_files.append({
                "name": blob.name,
                "url": f"https://storage.googleapis.com/raven-media-uploads/{blob.name}",
                "created": blob.time_created,
                "size": blob.size
            })
        
        print(f"🔧 [Backfill] Found {len(gcs_files)} voice files in GCS")
        
        # For each message, try to find the closest GCS file by timestamp
        for msg in messages:
            if not msg.timestamp:
                continue
            
            # Find GCS files created within 60 seconds of message creation
            # (voice upload happens just before message send)
            best_match = None
            best_diff = float('inf')
            
            for gcs_file in gcs_files:
                if gcs_file["created"]:
                    # Make both timezone-aware for comparison
                    msg_time = msg.timestamp
                    gcs_time = gcs_file["created"].replace(tzinfo=None) if gcs_file["created"].tzinfo else gcs_file["created"]
                    if msg_time.tzinfo:
                        msg_time = msg_time.replace(tzinfo=None)
                    
                    diff = abs((gcs_time - msg_time).total_seconds())
                    if diff < 60 and diff < best_diff:  # Within 60 seconds
                        best_match = gcs_file
                        best_diff = diff
            
            if best_match:
                msg.audio_url = best_match["url"]
                fixed_count += 1
                print(f"   ✅ Fixed msg {msg.id[:8]}: {best_match['url'][:60]}... (diff={best_diff:.1f}s)")
                # Remove matched file to prevent double-matching
                gcs_files.remove(best_match)
            else:
                print(f"   ⚠️ No GCS match for msg {msg.id[:8]} (timestamp={msg.timestamp})")
        
        db.commit()
        
    except Exception as e:
        print(f"❌ [Backfill] GCS scan failed: {e}")
        import traceback
        traceback.print_exc()
    
    return {
        "status": "completed",
        "total_null_voice_msgs": len(messages),
        "fixed": fixed_count,
        "remaining": len(messages) - fixed_count
    }

@router.get("/inbox", response_model=List[MessageResponse])
def get_inbox(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    since: Optional[str] = None,  # ISO format timestamp
    limit: int = 50
):
    """
    Get inbox messages for current user (for polling/sync).
    
    - Returns messages where current user is recipient
    - Filter by 'since' timestamp for incremental sync
    - Includes sender info for display
    """
    import traceback
    try:
        # 🔴 v1.8 — purge + exclude expired disappearing messages.
        _purge_expired_for_user(db, current_user.id)

        # 🔴 ROUND 71 S2: hide future-scheduled messages from /inbox
        # poll. Without this, every poll would surface scheduled
        # messages to recipients before the scheduled_at_utc.
        _now = datetime.utcnow()
        query = db.query(Message).filter(
            Message.recipient_id == current_user.id,
            _not_expired_clause(),
            or_(
                Message.send_mode != "scheduled",
                Message.scheduled_at_utc.is_(None),
                Message.scheduled_at_utc <= _now,
            ),
        )

        if since:
            try:
                since_dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
                query = query.filter(Message.timestamp > since_dt)
            except:
                pass
        
        messages = query.order_by(Message.timestamp.desc()).limit(limit).all()
        
        # Get sender info
        sender_ids = set(msg.sender_id for msg in messages)
        senders = {u.id: u for u in db.query(User).filter(User.id.in_(sender_ids)).all()} if sender_ids else {}
        
        result = []
        for msg in messages:
            sender = senders.get(msg.sender_id)
            # Safely decrypt content
            try:
                content = decrypt_text(msg.content) if msg.content else None
            except Exception as e:
                print(f"⚠️ [Inbox] Decrypt failed for msg {msg.id}: {e}")
                content = "[Encrypted]"
            
            result.append(MessageResponse(
                id=msg.id,
                sender_id=msg.sender_id,
                recipient_id=msg.recipient_id,
                content=content,
                timestamp=msg.timestamp,
                read_at=msg.read_at,
                delivered_at=msg.delivered_at,
                sender_username=sender.username if sender else None,
                sender_name=f"{sender.first_name} {sender.last_name}" if sender else None,
                audio_url=msg.audio_url,
                audio_duration_seconds=msg.audio_duration_seconds,
                message_type=msg.message_type or "text",
                # ✅ CRITICAL: Include roomId for iOS to match notifications
                room_id=msg.sender_id,  # For inbox: roomId = sender (peer) for 1:1 chats
                file_name=msg.file_name,
                file_size=msg.file_size,
                mime_type=msg.mime_type,
                # ✅ Reply fields
                reply_to_message_id=msg.reply_to_message_id,
                reply_to_text_preview=msg.reply_to_text_preview,
                reply_to_sender_name=msg.reply_to_sender_name,
                reply_to_type=msg.reply_to_type,
                # 🔴 ROUND 26 — album passthrough on inbox fetch
                media_group_key=msg.media_group_key,
                media_group_index=msg.media_group_index,
                media_group_total=msg.media_group_total,
            ))

        print(f"📬 Inbox for {current_user.username}: {len(result)} messages")
        
        # ═══════════════════════════════════════════════════════════════════
        # FIX v3: Do NOT mark delivered_at in /inbox — this prevents bridge-
        # downlink from discovering messages. delivered_at is set ONLY when:
        #   1. User opens conversation (/conversation endpoint → read_at)
        #   2. Bridge relays via /bridge-downlink
        #   3. Explicit /ack-delivered endpoint
        # ═══════════════════════════════════════════════════════════════════
        
        return result
    except Exception as e:
        print(f"❌ [Inbox] Error: {e}")
        print(f"❌ [Inbox] Traceback: {traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=f"Inbox error: {str(e)}")


# ============================================================================
# MARK MESSAGES AS READ ENDPOINT
# ============================================================================

class MarkReadRequest(BaseModel):
    room_id: str  # For 1:1 chats, this is the peer's user ID
    message_ids: Optional[List[str]] = None  # Optional: specific message IDs to mark as read
    is_stealth: bool = False  # Ghost Mode: mark read locally but don't broadcast receipt


@router.post("/read")
def mark_messages_read(
    req: MarkReadRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Mark messages as read for a conversation.
    
    - If message_ids provided: mark only those messages as read
    - If only room_id provided: mark ALL unread messages from that peer as read
    
    Returns count of messages marked as read.
    """
    now = datetime.utcnow()
    
    if req.message_ids:
        # Mark specific messages as read
        count = db.query(Message).filter(
            Message.id.in_(req.message_ids),
            Message.recipient_id == current_user.id,
            Message.read_at.is_(None)
        ).update({"read_at": now}, synchronize_session=False)
    else:
        # Mark all unread messages from this peer as read
        count = db.query(Message).filter(
            Message.sender_id == req.room_id,  # room_id = peer's user ID for 1:1
            Message.recipient_id == current_user.id,
            Message.read_at.is_(None)
        ).update({"read_at": now}, synchronize_session=False)
    
    db.commit()
    
    # ═══════════════════════════════════════════════════════════════════════════
    # UPDATE RoomVisibility.last_read_at (SOURCE OF TRUTH FOR READ STATE)
    # This persists across app reinstalls
    # ═══════════════════════════════════════════════════════════════════════════
    from models import RoomVisibility
    
    visibility = db.query(RoomVisibility).filter(
        RoomVisibility.user_id == current_user.id,
        RoomVisibility.room_id == req.room_id
    ).first()
    
    if visibility:
        visibility.last_read_at = now
    else:
        visibility = RoomVisibility(
            user_id=current_user.id,
            room_id=req.room_id,
            last_read_at=now
        )
        db.add(visibility)
    
    db.commit()
    
    print(f"👁️ Marked {count} messages as read from {req.room_id[:8]} for {current_user.username} (RoomVisibility updated)")
    
    # ✅ Read receipts privacy: tell client whether to broadcast the read status
    send_read_receipt = getattr(current_user, 'read_receipts_enabled', True)
    if send_read_receipt is None:
        send_read_receipt = True
    
    # ═══ Ghost Mode: premium users can suppress read receipts ═══
    if req.is_stealth and current_user.is_premium:
        send_read_receipt = False
        print(f"👻 [Ghost Mode] {current_user.username} read messages in stealth — receipt suppressed")
    elif req.is_stealth and not current_user.is_premium:
        print(f"🔒 [Ghost Mode] Stealth flag ignored for non-premium user {current_user.username}")
    
    if not send_read_receipt:
        print(f"🔒 Read receipts disabled for {current_user.username} — not broadcasting to sender")
    
    return {"success": True, "marked_count": count, "read_receipt_sent": send_read_receipt}


@router.post("/read-all")
def mark_all_messages_read(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Mark ALL unread messages across all conversations as read.
    Updates RoomVisibility.last_read_at for every peer with unread messages.
    """
    now = datetime.utcnow()
    
    # Find all distinct senders who have unread messages for this user
    unread_peers = db.query(Message.sender_id).filter(
        Message.recipient_id == current_user.id,
        Message.read_at.is_(None)
    ).distinct().all()
    
    peer_ids = [row[0] for row in unread_peers]
    
    # Mark all unread messages as read
    count = db.query(Message).filter(
        Message.recipient_id == current_user.id,
        Message.read_at.is_(None)
    ).update({"read_at": now}, synchronize_session=False)
    
    db.commit()
    
    # Update RoomVisibility for each peer
    from models import RoomVisibility
    
    for peer_id in peer_ids:
        visibility = db.query(RoomVisibility).filter(
            RoomVisibility.user_id == current_user.id,
            RoomVisibility.room_id == peer_id
        ).first()
        
        if visibility:
            visibility.last_read_at = now
        else:
            visibility = RoomVisibility(
                user_id=current_user.id,
                room_id=peer_id,
                last_read_at=now
            )
            db.add(visibility)
    
    db.commit()
    
    print(f"👁️ Marked ALL {count} messages as read for {current_user.username} across {len(peer_ids)} peers")
    
    return {"success": True, "marked_count": count, "peers_updated": len(peer_ids)}


# ============================================================================
# DELETE MESSAGE ENDPOINT
# ============================================================================

@router.delete("/{message_id}")
def delete_message(
    message_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Delete a message from the server.
    
    Only the sender can delete their own messages.
    This removes the message completely from the server.
    """
    # Find the message
    message = db.query(Message).filter(Message.id == message_id).first()
    
    if not message:
        raise HTTPException(status_code=404, detail="Message not found")
    
    # Only sender can delete their own messages
    if message.sender_id != current_user.id:
        raise HTTPException(status_code=403, detail="You can only delete your own messages")
    
    # Delete the message
    db.delete(message)
    db.commit()
    
    print(f"🗑️ Message {message_id[:8]} deleted by {current_user.username}")
    
    return {"success": True, "message_id": message_id}


# ============================================================================
# MUTE CONVERSATION ENDPOINT
# ============================================================================

class MuteConversationRequest(BaseModel):
    peer_id: str
    muted: bool


@router.post("/conversations/mute")
def mute_conversation(
    req: MuteConversationRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Mute or unmute a conversation with a specific peer.
    This is a user-specific preference - doesn't affect the peer.

    Note: The mute status is stored by the client (iOS/Android).
    This endpoint is a simple acknowledgement for potential future sync.
    """
    status_str = "muted" if req.muted else "unmuted"
    print(f"🔕 Conversation with {req.peer_id[:8]} {status_str} by {current_user.username}")

    # For now, mute is stored client-side only
    # Future: could add muted column to RoomVisibility or a new UserPreference table

    return {"success": True, "muted": req.muted}


# ============================================================================
# ARCHIVE CONVERSATION ENDPOINT (Round 49)
# ============================================================================
#
# 🟦 ROUND 49 (2026-05-17) — replaces the previous stub.
#
# Per-user, per-room archive bucket. iOS toggles via swipe →
# `ConversationStore.toggleArchive(roomId:)`. Server upserts a
# RoomVisibility row keyed by (user_id, room_id) — the same table
# that already tracks `hidden` and `last_read_at`.
#
# Cross-device sync flow:
#   1. Device A archives chat with peer X → POST /api/messages/conversations/archive
#      { room_id: "X", archived: true }
#   2. Server upserts RoomVisibility(user_id=A, room_id="X", is_archived=true).
#   3. Device A's next GET /api/messages/conversations sees is_archived=true
#      in the response and stores it locally.
#   4. Same for Device A's other devices — they pick it up on their next
#      /conversations poll and hide the row from the main inbox.
#   5. Unarchive flips the bit back to false.

class ArchiveConversationRequest(BaseModel):
    """Round 49 archive payload. `room_id` is the canonical thread ID:
    group_id for groups, peer_user_id for 1:1 (matches iOS local
    `roomId` semantics in ConversationStore)."""
    room_id: str
    archived: bool


@router.post("/conversations/archive")
def archive_conversation(
    req: ArchiveConversationRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Archive or unarchive a conversation for the current user.

    Idempotent: re-archiving an already-archived thread (or vice-versa)
    is a no-op + returns success. Storage is per-user — never affects
    the other party's view.
    """
    from models import RoomVisibility
    from datetime import datetime as _dt

    if not req.room_id or not req.room_id.strip():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="room_id is required",
        )

    room_id = req.room_id.strip()

    visibility = db.query(RoomVisibility).filter(
        RoomVisibility.user_id == current_user.id,
        RoomVisibility.room_id == room_id,
    ).first()

    if visibility is None:
        # First time we see this thread for archive purposes — create the
        # RoomVisibility row. last_read_at stays NULL (separate concern).
        visibility = RoomVisibility(
            user_id=current_user.id,
            room_id=room_id,
            is_archived=req.archived,
            archived_at=_dt.utcnow() if req.archived else None,
        )
        db.add(visibility)
    else:
        visibility.is_archived = req.archived
        visibility.archived_at = _dt.utcnow() if req.archived else None

    db.commit()

    action = "archived" if req.archived else "unarchived"
    print(f"🗂️ Conversation {room_id[:8]} {action} by {current_user.username}")

    return {"success": True, "archived": req.archived, "room_id": room_id}


# ============================================================================
# DELETE CONVERSATION ENDPOINT (one-sided)
# ============================================================================

class DeleteConversationRequest(BaseModel):
    peer_id: str


@router.post("/conversations/delete")
def delete_conversation(
    req: DeleteConversationRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Delete all messages in a conversation for the current user only.
    This is a one-sided delete - the peer still sees the messages.
    
    Instead of actually deleting, we mark messages as "deleted for user"
    by setting a deleted_for_user_id field or adding to a separate table.
    """
    # For a simple approach: actually delete messages where current user is recipient
    # AND mark messages where current user is sender as "deleted by sender"
    
    # Delete messages received from this peer
    received_count = db.query(Message).filter(
        Message.sender_id == req.peer_id,
        Message.recipient_id == current_user.id
    ).delete(synchronize_session=False)
    
    # Delete messages sent to this peer
    sent_count = db.query(Message).filter(
        Message.sender_id == current_user.id,
        Message.recipient_id == req.peer_id
    ).delete(synchronize_session=False)
    
    db.commit()
    
    total = received_count + sent_count
    print(f"🗑️ Deleted {total} messages in conversation with {req.peer_id[:8]} for {current_user.username}")
    
    return {"success": True, "deleted_count": total}


# ============================================================================
# CONVERSATIONS ENDPOINT (for iOS Inbox)
# Groups messages by peer and returns last message per conversation
# ============================================================================

class PeerResponse(BaseModel):
    userId: str
    username: str
    firstName: Optional[str]
    lastName: Optional[str]
    avatarPath: Optional[str]
    isVerified: bool = False
    isPremium: bool = False

class LastMessageResponse(BaseModel):
    id: str
    content: Optional[str]
    messageType: str = "text"
    timestamp: datetime
    senderId: str
    deliveryAuthority: Optional[str] = None

class ConversationResponse(BaseModel):
    roomId: str
    peer: PeerResponse
    lastMessage: Optional[LastMessageResponse]
    unreadCount: int
    isPinned: bool
    isMuted: bool
    updatedAt: datetime
    # Group conversation fields
    is_group: bool = False
    group_name: Optional[str] = None
    group_avatar_url: Optional[str] = None
    # Message request fields (1:1 only)
    requestStatus: Optional[str] = None       # pending, accepted, declined, blocked
    isRequestSender: Optional[bool] = None
    pendingSentCount: Optional[int] = None
    requestId: Optional[str] = None
    # Round 49 — per-user archive bucket. Decoded as `isArchived` on
    # iOS via NetworkService's `.convertFromSnakeCase` decoder.
    is_archived: bool = False


@router.get("/conversations", response_model=List[ConversationResponse])
def get_conversations(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    since: Optional[str] = None,
    limit: int = 50
):
    """
    Get conversations for current user, grouped by peer.
    
    Returns conversations with:
    - roomId: the peer's user ID (for 1:1 chats)
    - peer: user info of the other person
    - lastMessage: most recent message in the conversation
    - unreadCount: number of unread messages
    - isPinned, isMuted: local preferences (default false for now)
    - updatedAt: timestamp of last message
    """
    import traceback
    from sqlalchemy import func, case, desc
    
    # Find all unique conversation partners
    # For each peer, get the most recent message
    
    # Subquery to find distinct peers and latest message timestamp
    sent_peers = db.query(
        Message.recipient_id.label('peer_id'),
        func.max(Message.timestamp).label('last_time')
    ).filter(
        Message.sender_id == current_user.id
    ).group_by(Message.recipient_id)
    
    received_peers = db.query(
        Message.sender_id.label('peer_id'),
        func.max(Message.timestamp).label('last_time')
    ).filter(
        Message.recipient_id == current_user.id
    ).group_by(Message.sender_id)
    
    # Get unique peers from both sent and received
    all_peer_ids = set()
    peer_last_times = {}
    
    for row in sent_peers:
        all_peer_ids.add(row.peer_id)
        peer_last_times[row.peer_id] = row.last_time
        
    for row in received_peers:
        all_peer_ids.add(row.peer_id)
        if row.peer_id in peer_last_times:
            peer_last_times[row.peer_id] = max(peer_last_times[row.peer_id], row.last_time)
        else:
            peer_last_times[row.peer_id] = row.last_time
    
    # Round 49: bulk-fetch ALL RoomVisibility rows for this user once
    # (instead of per-peer N+1 queries below). Build a {room_id → row}
    # dict that the 1:1 loop AND the group loop can both consult for
    # `is_archived` and `last_read_at`.
    from models import RoomVisibility
    visibility_rows = db.query(RoomVisibility).filter(
        RoomVisibility.user_id == current_user.id
    ).all()
    visibility_by_room: dict = {v.room_id: v for v in visibility_rows}

    if not all_peer_ids:
        return []

    # Get peer info
    peers = {u.id: u for u in db.query(User).filter(User.id.in_(all_peer_ids)).all()}

    conversations = []

    for peer_id in all_peer_ids:
        peer = peers.get(peer_id)
        if not peer:
            continue

        # Get the most recent message between current user and this peer
        last_msg = db.query(Message).filter(
            or_(
                and_(Message.sender_id == current_user.id, Message.recipient_id == peer_id),
                and_(Message.sender_id == peer_id, Message.recipient_id == current_user.id)
            )
        ).order_by(Message.timestamp.desc()).first()

        # Pull this peer's row from the bulk fetch above (avoids N+1).
        visibility = visibility_by_room.get(peer_id)
        last_read_at = visibility.last_read_at if visibility else None
        is_archived_1to1 = bool(visibility.is_archived) if visibility else False
        
        if last_read_at:
            # Count messages from peer after my last read time
            unread_count = db.query(func.count(Message.id)).filter(
                Message.sender_id == peer_id,
                Message.recipient_id == current_user.id,
                Message.timestamp > last_read_at
            ).scalar() or 0
        else:
            # No read record = all incoming messages are unread
            unread_count = db.query(func.count(Message.id)).filter(
                Message.sender_id == peer_id,
                Message.recipient_id == current_user.id
            ).scalar() or 0
        
        # Build response
        last_message = None
        if last_msg:
            last_message = LastMessageResponse(
                id=last_msg.id,
                content=decrypt_text(last_msg.content) if last_msg.content else None,
                messageType=last_msg.message_type or "text",
                timestamp=last_msg.timestamp,
                senderId=last_msg.sender_id,
                deliveryAuthority=None
            )
        
        # ✅ Look up message request between current user and this peer
        from models import MessageRequest
        msg_req = db.query(MessageRequest).filter(
            or_(
                and_(MessageRequest.sender_id == current_user.id, MessageRequest.receiver_id == peer_id),
                and_(MessageRequest.sender_id == peer_id, MessageRequest.receiver_id == current_user.id)
            )
        ).first()
        
        req_status = msg_req.status if msg_req else None
        is_req_sender = (msg_req.sender_id == current_user.id) if msg_req else None
        pending_count = msg_req.sent_count if msg_req else None
        req_id = msg_req.id if msg_req else None
        
        conversations.append(ConversationResponse(
            roomId=peer_id,  # For 1:1 chats, roomId = peer's user ID
            peer=PeerResponse(
                userId=peer.id,
                username=peer.username,
                firstName=peer.first_name,
                lastName=peer.last_name,
                avatarPath=peer.avatar_path if hasattr(peer, 'avatar_path') else None,
                isVerified=peer.is_verified or False,
                isPremium=peer.is_premium or False
            ),
            lastMessage=last_message,
            unreadCount=unread_count,
            isPinned=False,  # TODO: Implement pin/mute preferences
            isMuted=False,
            updatedAt=last_msg.timestamp if last_msg else datetime.utcnow(),
            is_group=False,
            requestStatus=req_status,
            isRequestSender=is_req_sender,
            pendingSentCount=pending_count,
            requestId=req_id,
            is_archived=is_archived_1to1,   # Round 49 — cross-device archive sync
        ))
    
    # ═══════════════════════════════════════════════════════════════════════════
    # ADD GROUP CONVERSATIONS (wrapped in try-except for missing table graceful handling)
    # ═══════════════════════════════════════════════════════════════════════════
    try:
        from models import Group, GroupMember
        
        # Find all groups the user is a member of
        memberships = db.query(GroupMember).filter(
            GroupMember.user_id == current_user.id
        ).all()
        
        group_ids = [m.group_id for m in memberships]
        
        if group_ids:
            groups = db.query(Group).filter(Group.id.in_(group_ids)).all()
            
            for group in groups:
                # Get creator info as "peer" for display (we'll use group_name for actual display)
                creator = db.query(User).filter(User.id == group.created_by).first()
                
                # Create a "fake" peer representing the group creator (for backward compatibility)
                # The client uses is_group + group_name for display
                peer_response = PeerResponse(
                    userId=group.created_by,
                    username=creator.username if creator else "group",
                    firstName=creator.first_name if creator else None,
                    lastName=creator.last_name if creator else None,
                    avatarPath=group.avatar_url  # Use group avatar
                )
                
                # TODO: Get last group message and unread count
                # For now, use group creation time as updatedAt
                # Round 49: per-user archive lookup for this group.
                grp_visibility = visibility_by_room.get(group.id)
                is_archived_grp = bool(grp_visibility.is_archived) if grp_visibility else False

                conversations.append(ConversationResponse(
                    roomId=group.id,  # For groups, roomId = group ID
                    peer=peer_response,
                    lastMessage=None,  # TODO: Implement group messages
                    unreadCount=0,
                    isPinned=False,
                    isMuted=False,
                    updatedAt=group.created_at,
                    is_group=True,
                    group_name=group.name,
                    group_avatar_url=group.avatar_url,
                    is_archived=is_archived_grp,   # Round 49 — cross-device archive sync
                ))
                
            print(f"👥 Added {len(groups)} groups to conversations")
    except Exception as e:
        # Group tables may not exist in production yet - that's OK, just skip groups
        print(f"⚠️ [Conversations] Could not fetch groups (table may not exist): {e}")
    
    # Sort by most recent first
    conversations.sort(key=lambda c: c.updatedAt, reverse=True)
    
    print(f"💬 Conversations for {current_user.username}: {len(conversations)} (incl. groups)")
    return conversations[:limit]


# ==================== MESH DELIVERY ACK ====================

class AckDeliveredRequest(BaseModel):
    """Report that a message was delivered via mesh"""
    client_message_id: Optional[str] = None  # Primary field per spec
    message_id: Optional[str] = None  # Legacy compatibility
    delivered_at: Optional[datetime] = None
    delivered_via: str = "mesh"  # "mesh" or "server"
    
    @property
    def resolved_id(self) -> str:
        """Get the message ID from either field"""
        return self.client_message_id or self.message_id or ""


class AckDeliveredResponse(BaseModel):
    """Response to ack-delivered request"""
    success: bool
    message_id: str
    already_delivered: bool = False
    stop_mesh: bool = False  # Tell client to stop mesh transmission


@router.post("/ack-delivered", response_model=AckDeliveredResponse)
def ack_delivered(
    req: AckDeliveredRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Report that a message was delivered (typically via mesh).
    This allows the server to:
    1. Mark the message as delivered
    2. Tell other nodes to stop mesh transmission
    3. Prevent duplicate delivery attempts
    """
    mid = req.resolved_id
    if not mid:
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail="client_message_id or message_id required")
    
    print(f"📨 [Mesh ACK] Message {mid[:8]} delivered via {req.delivered_via}")
    
    # Find the message
    message = db.query(Message).filter(Message.id == mid).first()
    
    if not message:
        # Message not in server DB yet - this is fine for mesh-first delivery
        print(f"⚠️ [Mesh ACK] Message {mid[:8]} not in server DB (mesh-first delivery)")
        return AckDeliveredResponse(
            success=True,
            message_id=mid,
            already_delivered=False,
            stop_mesh=True  # Still stop mesh since it's delivered
        )

    # 🔴 hacker-audit 2026-05-20 — ack-delivered IDOR.
    # Only the sender or recipient of a message may flip its
    # delivery state. Without this, anyone who guesses a message_id
    # could mark a stranger's message delivered — suppressing mesh
    # re-delivery so the real recipient never receives it.
    if message.sender_id != current_user.id and message.recipient_id != current_user.id:
        raise HTTPException(status_code=404, detail="Message not found")

    # Check if already delivered
    already_delivered = message.delivered_at is not None
    
    if not already_delivered:
        # Mark as delivered
        message.delivered_at = req.delivered_at or datetime.utcnow()
        db.commit()
        print(f"✅ [Mesh ACK] Message {mid[:8]} marked as delivered")
    else:
        print(f"ℹ️ [Mesh ACK] Message {mid[:8]} was already delivered")
    
    return AckDeliveredResponse(
        success=True,
        message_id=mid,
        already_delivered=already_delivered,
        stop_mesh=True  # Always tell client to stop mesh for this message
    )


# ==================== CANCELLED MESSAGES (control-plane) ====================

@router.get("/cancelled")
def get_cancelled_messages(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    since: Optional[str] = None
):
    """
    Get list of cancelled/delivered message IDs for mesh stop-list.
    Preferred endpoint for CANCEL propagation (iOS tries this first).
    Returns { cancelled: [...], message_ids: [...], stop_list: [...] }
    """
    query = db.query(Message.id, Message.delivered_at).filter(
        or_(
            Message.sender_id == current_user.id,
            Message.recipient_id == current_user.id
        ),
        Message.delivered_at.isnot(None)
    )
    
    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
            query = query.filter(Message.delivered_at > since_dt)
        except ValueError:
            pass
    
    delivered_messages = query.order_by(Message.delivered_at.desc()).limit(100).all()
    ids = [msg.id for msg in delivered_messages]
    
    print(f"🛑 [Cancelled] Returning {len(ids)} message IDs for {current_user.username} (since={since})")
    
    return {
        "cancelled": ids,
        "message_ids": ids,
        "stop_list": ids
    }


# ==================== GET STOP LIST ====================

@router.get("/stop-list")
def get_stop_list(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    since: Optional[str] = None  # ISO format timestamp for incremental polling
):
    """
    Get list of message IDs that should be stopped in mesh.
    Called when device reconnects to internet.
    Returns messages that are already delivered via server.
    
    Query params:
        since: ISO8601 timestamp - only return messages delivered after this time
    """
    # Build query for messages sent by or to user that are already delivered
    query = db.query(Message.id, Message.delivered_at).filter(
        or_(
            Message.sender_id == current_user.id,
            Message.recipient_id == current_user.id
        ),
        Message.delivered_at.isnot(None)
    )
    
    # Filter by since timestamp if provided
    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
            query = query.filter(Message.delivered_at > since_dt)
        except ValueError:
            pass  # Ignore invalid timestamp format
    
    delivered_messages = query.order_by(Message.delivered_at.desc()).limit(100).all()
    
    stop_list = [msg.id for msg in delivered_messages]
    
    print(f"🛑 [Stop List] Returning {len(stop_list)} message IDs for {current_user.username} (since={since})")
    
    return {"stop_list": stop_list}


# ============================================================================
# BRIDGE DOWNLINK — Server-to-Mesh relay
# Allows online bridge devices to fetch pending messages for BLE peers
# ============================================================================

class BridgeDownlinkRequest(BaseModel):
    peer_user_ids: List[str] = Field(..., max_length=10)  # Max 10 peers at once


# 🔴 ROUND 26 (2026-05-17) — REAL BRIDGE BUG FIX.
#
# iOS `BLEMeshEngine.swift:4261` prefers POST /api/messages/smart-bridge-downlink
# (richer request: immediate_peers + current_geohash + bridge_user_id) and
# only falls back to the legacy /bridge-downlink on error. The smart
# endpoint was never implemented server-side, so EVERY bridge poll cycle
# hit a 405 first, then retried the legacy endpoint — wasting one
# round-trip (~200ms over cross-Atlantic Cloud Run→Cloud-SQL latency)
# per poll. Confirmed in live logs:
#
#   POST 405 /api/messages/smart-bridge-downlink
#   POST 200 /api/messages/bridge-downlink   (✅ Returning 1 messages)
#
# FIX: alias smart-bridge-downlink to the legacy handler, accepting the
# richer request shape but ignoring the geohash/bridgeUserId smart-routing
# fields for now (the legacy handler already returns the right messages;
# geohash-based filtering is a future optimisation). This collapses the
# bridge-poll cycle from 2 round-trips to 1.
class SmartBridgeDownlinkRequest(BaseModel):
    """iOS-side smart-bridge-downlink request shape.

    `immediate_peers` is what the legacy endpoint calls `peer_user_ids` —
    the userIds of BLE peers currently in range. `current_geohash` and
    `bridge_user_id` are accepted but not yet used for smart routing
    (tracked as a future optimisation that would filter messages by
    recipient-location proximity).
    """
    immediate_peers: List[str] = Field(default_factory=list, max_length=10)
    current_geohash: Optional[str] = None
    bridge_user_id: Optional[str] = None


@router.post("/smart-bridge-downlink")
async def smart_bridge_downlink(
    req: SmartBridgeDownlinkRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Round-26 alias: delegates to the legacy handler with the
    `immediate_peers` field as `peer_user_ids`. Future work: filter
    by `current_geohash` proximity to the recipient's last-known
    geohash, so distant bridges don't waste BLE airtime carrying
    messages they can't deliver."""
    legacy_req = BridgeDownlinkRequest(peer_user_ids=req.immediate_peers)
    return await bridge_downlink(legacy_req, current_user=current_user, db=db)


@router.post("/bridge-downlink")
async def bridge_downlink(
    req: BridgeDownlinkRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Bridge Downlink: fetch undelivered messages for BLE mesh peers.
    
    Called by a bridge device (B) that is BOTH online AND has BLE peers.
    Returns messages where:
      - recipient_id is one of the provided peer_user_ids
      - delivered_at is NULL (not yet delivered)
      - sender_id != current_user (don't return B's own outgoing messages)
    
    After returning, marks messages as delivered (bridged downlink).
    """
    if not req.peer_user_ids:
        return {"messages": [], "count": 0}
    
    import traceback
    import logging
    _bdl_logger = logging.getLogger("messages.bridge_downlink")
    
    _bdl_logger.debug(f"🌉 [Bridge Downlink] Request from bridge={current_user.username}, peers={len(req.peer_user_ids)}")
    
    try:
        from sqlalchemy import func
        
        # 🔴 ROUND 26 (2026-05-16) — hacker-mode audit MEDIA-CRIT-8.
        #
        # PREVIOUSLY: `__ALL_PEERS__` was a debug-shortcut sentinel
        # that the bridge sent when it couldn't resolve BLE peer
        # userIds. The server interpreted it as "return ALL
        # undelivered messages from ANY recipient" (the
        # `actual_peer_ids = None` branch), and the response
        # included `decrypt_text(msg.content)`, `audio_url`,
        # `file_name`, `mime_type`, sender_username, and reply
        # previews. ANY authenticated user could POST
        # `{"peer_user_ids": ["__ALL_PEERS__"]}` and drain the
        # entire pending message queue across the platform —
        # including media URLs, group rosters, and decrypted text.
        # ONE curl, one minute of polling = full content scrape.
        #
        # FIX: drop the sentinel branch. The bridge MUST present
        # concrete peer_user_ids it has a legitimate reason to
        # query (it learned them via BLE discovery, and the BLE
        # learn path is now signature-verified per MESH-HIGH-4).
        # If the bridge has no peer ids, it gets an empty response.
        actual_peer_ids = [pid for pid in (req.peer_user_ids or []) if pid != "__ALL_PEERS__"]
        if not actual_peer_ids:
            _bdl_logger.info("🌉 [Bridge Downlink] no concrete peer_user_ids — returning empty (round-26 hardening: __ALL_PEERS__ sentinel deleted)")
            return BridgeDownlinkResponse(messages=[]) if False else {"messages": [], "group_messages": []}

        # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) — friendship
        # IDOR guard REMOVED. RAVEN's threat model places E2EE
        # confidentiality on the content itself: the message body
        # ships sealed (Noise transport or — future — ATSAM
        # static-key ECDH) so the bridge sees only opaque
        # ciphertext, NEVER plaintext. The bridge is infrastructure
        # — its job is to forward bytes for any BLE peer it sees,
        # regardless of whether the bridger has a `FriendRequest`
        # row with that peer.
        #
        # The pre-fix guard refused downlink for peers the bridger
        # wasn't accepted-friends with, which broke the entire
        # cross-pair bridge use case (A↔B paired via QR-offline,
        # B↔C separately, A→C bridge through B impossible because
        # B is not C's friend in the DB). That's exactly the
        # production "C → A doesn't work" symptom the user
        # reported.
        #
        # Metadata that the bridger CAN see (sender/recipient/
        # timestamp/count of pending rows) is acceptable in
        # RAVEN's threat model — same as any DTN where neighbours
        # learn that you talk to someone, just not what you said.
        # Content is the secret; metadata is the cost of mesh
        # delivery. The sender's fail-closed seal (see
        # `MessageRouter.swift` — refuses to ship if it can't
        # produce ciphertext) is what keeps the actual messages
        # private regardless of who the bridger is.
        #
        # Rate-limiting is already applied at the
        # `/smart-bridge-downlink` route level via the global
        # rate limiter; adding a sustained-abuse cap here is a
        # follow-up if drain attempts show up in prod metrics.
        _bdl_logger.info(
            "🌉 [Bridge Downlink] bridge=%s polling for %d peer(s) (friendship-IDOR-guard removed per R71 p3 mesh-bridge directive)",
            current_user.id, len(actual_peer_ids),
        )

        # Find undelivered messages for the specified peers
        # Also include recently-delivered messages (last 120s) as fallback
        # in case inbox polling already marked them before bridge could relay
        # EXCLUDE: messages sent by the bridge device itself
        from datetime import timedelta
        recent_cutoff = datetime.utcnow() - timedelta(seconds=120)

        # 🟥 ROUND 42 v2 (2026-05-17) — multi-device bridge downlink
        # (narrowed).
        #
        # Round 42 v1 added a "same-user recipient bypass" so the
        # bridge could relay C→A messages even when B (other device
        # of same user) had already ACKed delivered.  But the v1
        # cutoff (7 days) was way too generous and caused the
        # server to return 20 messages on EVERY 15-second poll —
        # the full LIMIT.  The iOS bridge dedup TTL is shorter
        # than 7 days, so the same messages got re-broadcast on
        # mesh forever, flooding the network.
        #
        # v2: cut the multi-device window to 5 minutes.  Rationale:
        #   • A fresh C→A message will reach the server, WS-push to
        #     B, and B's next 15-second poll picks it up — all within
        #     30 s.  The 5-minute window gives 10× headroom.
        #   • Messages older than 5 minutes that B "saw" via WS but
        #     didn't relay are unlikely to still need relaying — the
        #     user has probably moved on.
        #   • Limiting to 5 minutes caps the per-poll result size to
        #     N messages received in that window, never the full 20.
        multi_device_cutoff = datetime.utcnow() - timedelta(minutes=5)

        pending = db.query(Message).filter(
            Message.recipient_id.in_(actual_peer_ids),
            Message.sender_id != current_user.id,  # Don't return B's own messages
            (
                # Case A: recipient is a DIFFERENT user — apply the
                # original delivered/read filter.
                (
                    (Message.recipient_id != current_user.id) &
                    (
                        Message.delivered_at.is_(None) |
                        (Message.delivered_at > recent_cutoff)
                    ) &
                    Message.read_at.is_(None)
                )
                |
                # Case B: recipient is the bridge user (multi-device).
                # Bypass delivered/read, but only for messages from the
                # last 5 minutes — long enough for B's next poll to
                # catch a fresh push, short enough not to replay
                # ancient history every poll.
                (
                    (Message.recipient_id == current_user.id) &
                    (Message.timestamp > multi_device_cutoff)
                )
            ),
        ).order_by(Message.timestamp.desc()).limit(20).all()
        
        _bdl_logger.debug(f"🌉 [Bridge Downlink] Found {len(pending)} pending 1:1 messages")
        
        # Get sender info for 1:1 messages
        sender_ids = set(msg.sender_id for msg in pending)
        
        # ═══════════════════════════════════════════════════════════════
        # 👥 GROUP MESSAGES: Also fetch undelivered group messages for
        # peers who are group members but haven't received the message.
        # ═══════════════════════════════════════════════════════════════
        group_results = []
        try:
            import json as _json
            
            # Find groups where any peer is a member
            peer_ids_for_groups = actual_peer_ids if actual_peer_ids is not None else []
            if peer_ids_for_groups:
                # Get group IDs where any peer is a member
                peer_group_memberships = db.query(GroupMember.group_id, GroupMember.user_id).filter(
                    GroupMember.user_id.in_(peer_ids_for_groups)
                ).all()
                
                peer_group_ids = list(set(m.group_id for m in peer_group_memberships))
                
                if peer_group_ids:
                    # 🔴 ROUND 33 (2026-05-19) — group metadata-leak fix.
                    #
                    # PREVIOUSLY: bridge_downlink returned up to 24
                    # hours of recent group messages for every group
                    # any peer was a member of. A malicious "helper"
                    # could declare `peer_user_ids = ["victim"]` and
                    # scrape a day's worth of activity (timestamps,
                    # `delivered_to` rosters, sender IDs) for every
                    # group the victim belongs to — without the
                    # helper being a member of any of those groups.
                    #
                    # Two tightenings:
                    #   1. The window matches the 1:1 multi-device
                    #      cutoff (5 min). That's enough for a fresh
                    #      message to be relayed once and no more —
                    #      no replay scraping.
                    #   2. The bridge only sees groups it ITSELF is
                    #      a member of. That stops the cross-group
                    #      roster leak entirely; a non-member bridge
                    #      gets nothing for groups it doesn't already
                    #      have access to.
                    group_msg_cutoff = datetime.utcnow() - timedelta(minutes=5)

                    # Restrict the visible group set to groups the
                    # bridge user is ALSO a member of.
                    bridge_group_ids = set(
                        gid for (gid,) in db.query(GroupMember.group_id)
                        .filter(GroupMember.user_id == current_user.id)
                        .all()
                    )
                    visible_group_ids = [g for g in peer_group_ids if g in bridge_group_ids]

                    if not visible_group_ids:
                        _bdl_logger.info(
                            f"🌉 [Bridge Downlink] bridge {current_user.username[:8]} is not a "
                            f"member of any peer's groups — group_messages omitted"
                        )
                        group_msgs = []
                    else:
                        group_msgs = db.query(GroupMessage).filter(
                            GroupMessage.group_id.in_(visible_group_ids),
                            GroupMessage.sender_id != current_user.id,  # Don't relay own messages
                            GroupMessage.timestamp > group_msg_cutoff,
                        ).order_by(GroupMessage.timestamp.desc()).limit(20).all()
                    
                    _bdl_logger.debug(f"🌉 [Bridge Downlink] Found {len(group_msgs)} candidate group messages")
                    
                    # Build a set of which peer is in which group
                    peer_groups_map = {}
                    for m in peer_group_memberships:
                        peer_groups_map.setdefault(m.group_id, set()).add(m.user_id)
                    
                    for gmsg in group_msgs:
                        # Check which peers need this message (not yet in delivered_to)
                        delivered_to = set(_json.loads(gmsg.delivered_to or "[]"))
                        group_peers = peer_groups_map.get(gmsg.group_id, set())
                        undelivered_peers = group_peers - delivered_to
                        
                        if not undelivered_peers:
                            continue  # All peers have it
                        
                        # Get all members of this group for the envelope
                        all_group_members = [m.user_id for m in db.query(GroupMember).filter(
                            GroupMember.group_id == gmsg.group_id
                        ).all()]
                        
                        sender = db.query(User).filter(User.id == gmsg.sender_id).first()
                        
                        try:
                            content = decrypt_text(gmsg.content) if gmsg.content else None
                        except Exception:
                            content = "[Encrypted]"
                        
                        # 🔴 ROUND 71 phase 3 follow-up (2026-05-24) —
                        # include `group_key_version` in the bridge-
                        # downlink payload so the receiver can pick
                        # the right key to AES-GCM-decrypt the
                        # ciphertext. Without this, B's mesh
                        # re-broadcast to A would strand A with an
                        # unsealable blob.
                        _gkv = getattr(gmsg, 'group_key_version', None)
                        group_results.append({
                            "id": gmsg.id,
                            "sender_id": gmsg.sender_id,
                            "recipient_id": list(undelivered_peers)[0],  # Primary target peer
                            "content": content,
                            "timestamp": gmsg.timestamp.isoformat() if gmsg.timestamp else None,
                            "read_at": None,
                            "delivered_at": None,
                            "sender_username": sender.username if sender else None,
                            "sender_name": f"{sender.first_name} {sender.last_name}" if sender else None,
                            "message_type": gmsg.message_type or "text",
                            "room_id": gmsg.group_id,
                            "is_group": True,
                            "group_id": gmsg.group_id,
                            "group_member_ids": all_group_members,
                            "group_key_version": _gkv,
                        })
                    
                    _bdl_logger.debug(f"🌉 [Bridge Downlink] {len(group_results)} group messages need relay to peers")
        except Exception as ge:
            _bdl_logger.warning(f"⚠️ [Bridge Downlink] Group query failed (non-fatal): {ge}")
        
        # ═══════════════════════════════════════════════════════════════
        # 🟦 ROUND 47 (2026-05-17) — GROUP LIFECYCLE EVENTS
        # ═══════════════════════════════════════════════════════════════
        # Surface RECENT group_create events for any peer that is a
        # member of a group created within the last 24 hours.
        #
        # WHY: when an online user A creates a group containing a
        # BLE-only peer C, neither WebSocket push nor APNs can reach
        # C (no internet). The mesh-broadcast from A (Round 46) is
        # one path, but if A's BLE link to the spray cluster is
        # unreliable the event is lost. The bridge B (online + BLE
        # peer of C) now ALSO receives the group_create here and
        # re-broadcasts it over mesh — a server-mediated bridge for
        # lifecycle events analogous to the chat-message bridge that
        # already lives in this handler.
        #
        # We return events for groups created in the last 24h where
        # ANY peer in actual_peer_ids is a member. The iOS bridge
        # consumer dedupes via the regular MeshDedupRepository
        # (clientMessageId-based), so re-receiving the same event
        # on every poll is a cheap no-op.
        group_event_results = []
        try:
            from models import Group as _Group, GroupMember as _GM, User as _User
            from datetime import timedelta as _td
            grp_cutoff = datetime.utcnow() - _td(hours=24)

            # Find recently-created groups where ANY peer is a member.
            grp_peer_rows = db.query(_GM, _Group).join(
                _Group, _Group.id == _GM.group_id
            ).filter(
                _GM.user_id.in_(actual_peer_ids),
                _Group.created_at > grp_cutoff,
            ).all()

            # Dedup by group_id (multiple peers in same group → one event)
            seen_gids = set()
            recent_groups = []
            for _gm, _grp in grp_peer_rows:
                if _grp.id in seen_gids:
                    continue
                seen_gids.add(_grp.id)
                recent_groups.append(_grp)

            for grp in recent_groups:
                # Build full member list for the event payload.
                members_rows = db.query(_GM, _User).join(
                    _User, _User.id == _GM.user_id
                ).filter(_GM.group_id == grp.id).all()

                members_payload = [
                    {
                        "user_id": _gm.user_id,
                        "username": _u.username or "",
                        "avatar_url": _u.avatar_path,
                        "role": _gm.role or "member",
                        "joined_at": (_gm.joined_at or grp.created_at).isoformat() + "Z",
                    }
                    for _gm, _u in members_rows
                ]
                creator = db.query(_User).filter(_User.id == grp.created_by).first()
                creator_uname = creator.username if creator else None

                group_event_results.append({
                    "type": "group_create",
                    "group_id": grp.id,
                    "group_name": grp.name,
                    "avatar_url": grp.avatar_url,
                    "description": grp.description,
                    "created_by": grp.created_by,
                    "creator_username": creator_uname,
                    "created_at": (grp.created_at or datetime.utcnow()).isoformat() + "Z",
                    "member_count": len(members_payload),
                    "members": members_payload,
                })
            if group_event_results:
                _bdl_logger.info(f"🌉 [Bridge Downlink] +{len(group_event_results)} group lifecycle events for {len(actual_peer_ids)} peer(s)")
        except Exception as ge:
            _bdl_logger.warning(f"⚠️ [Bridge Downlink] Group lifecycle event query failed (non-fatal): {ge}")

        if not pending and not group_results and not group_event_results:
            _bdl_logger.debug(f"🌉 [Bridge Downlink] No pending messages — empty")
            return {"messages": [], "group_events": [], "count": 0}

        _bdl_logger.debug(f"🌉 [Bridge Downlink] Returning {len(pending)} 1:1 + {len(group_results)} group msgs + {len(group_event_results)} lifecycle")
        
        # Build 1:1 message results
        senders = {u.id: u for u in db.query(User).filter(User.id.in_(sender_ids)).all()} if sender_ids else {}
        
        result = []
        for msg in pending:
            sender = senders.get(msg.sender_id)
            
            # Decrypt content
            try:
                content = decrypt_text(msg.content) if msg.content else None
            except Exception as e:
                print(f"⚠️ [Bridge Downlink] Decrypt failed for msg {msg.id}: {e}")
                content = "[Encrypted]"
            
            result.append(MessageResponse(
                id=msg.id,
                sender_id=msg.sender_id,
                recipient_id=msg.recipient_id,
                content=content,
                timestamp=msg.timestamp,
                read_at=msg.read_at,
                delivered_at=msg.delivered_at,
                sender_username=sender.username if sender else None,
                sender_name=f"{sender.first_name} {sender.last_name}" if sender else None,
                audio_url=msg.audio_url,
                audio_duration_seconds=msg.audio_duration_seconds,
                message_type=msg.message_type or "text",
                room_id=msg.sender_id,  # roomId = sender for recipient
                file_name=msg.file_name,
                file_size=msg.file_size,
                mime_type=msg.mime_type,
                reply_to_message_id=msg.reply_to_message_id,
                reply_to_text_preview=msg.reply_to_text_preview,
                reply_to_sender_name=msg.reply_to_sender_name,
                reply_to_type=msg.reply_to_type
            ))
            
            # Phase 4: Do NOT mark delivered_at here — wait for bridge ACK after BLE delivery.
            if msg.delivered_at is None:
                pass  # Leave delivered_at as None — client will ACK after BLE success
        
        db.commit()
        
        # Combine 1:1 + group results
        one_to_one_serialized = [r.model_dump(mode='json') for r in result]
        all_messages = one_to_one_serialized + group_results

        print(f"✅ [Bridge Downlink] Returning {len(all_messages)} messages ({len(result)} 1:1 + {len(group_results)} group) + {len(group_event_results)} group_events")

        # Round 47: `group_events` is a NEW top-level array carrying
        # group lifecycle events (group_create, etc.) that the iOS
        # bridge translates into mesh `payloadKind=group_create`
        # broadcasts for its BLE-only neighbours. Older iOS clients
        # that don't decode this field silently ignore it (Decodable
        # `optional` fields tolerate missing/unknown keys), so the
        # change is fully back-compat.
        return {
            "messages": all_messages,
            "group_events": group_event_results,
            "count": len(all_messages),
        }
        
    except Exception as e:
        print(f"❌ [Bridge Downlink] Error: {e}")
        print(f"❌ [Bridge Downlink] Traceback: {traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=f"Bridge downlink error: {str(e)}")


@router.get("/debug/delivery-state/{recipient_id}")
def debug_delivery_state(
    recipient_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """DEBUG: Check delivery state of messages for the CALLER's account.

    🔴 ROUND 26 (2026-05-16) — hacker-mode audit MEDIA-HIGH-9.

    PREVIOUSLY: this endpoint had NO auth dependency at all
    (only `db: Session = Depends(get_db)`). An anonymous attacker
    could `curl https://host/api/messages/debug/delivery-state/<any_user_id>`
    and get total/undelivered/delivered counts plus the last-5
    message timestamps with 8-char sender_id prefixes — perfect
    for mapping per-user activity, deriving online windows, and
    correlating mesh ↔ server identities via sender-id prefix
    matching against captured envelopes.

    FIX: require a valid JWT AND refuse unless `recipient_id ==
    current_user.id` — the endpoint becomes a self-diagnostic
    only, not a cross-user surveillance tool.
    """
    from sqlalchemy import func

    if recipient_id != current_user.id:
        # 404 (not 403) so the attacker can't confirm a userId exists.
        raise HTTPException(status_code=404, detail="Not found")

    total = db.query(func.count(Message.id)).filter(
        Message.recipient_id == recipient_id
    ).scalar()

    undelivered = db.query(func.count(Message.id)).filter(
        Message.recipient_id == recipient_id,
        Message.delivered_at.is_(None)
    ).scalar()

    # Get last 5 messages with their delivery state
    recent = db.query(Message).filter(
        Message.recipient_id == recipient_id
    ).order_by(Message.timestamp.desc()).limit(5).all()

    msgs = []
    for m in recent:
        msgs.append({
            "id": m.id[:8],
            "sender_id": m.sender_id[:8],
            "timestamp": m.timestamp.isoformat() if m.timestamp else None,
            "delivered_at": m.delivered_at.isoformat() if m.delivered_at else None,
            "read_at": m.read_at.isoformat() if m.read_at else None,
        })

    return {
        "recipient_id": recipient_id[:8],
        "total_messages": total,
        "undelivered": undelivered,
        "delivered": total - undelivered,
        "recent_messages": msgs
    }


# ═══════════════════════════════════════════════════════════════════════════
# VOICE MESSAGE TRANSCRIPTION (Gemini-powered, any language)
# ═══════════════════════════════════════════════════════════════════════════

async def _run_message_transcription(message_id: str):
    """Background task: transcribe a voice message using Gemini."""
    from database import SessionLocal
    from services.gemini_service import get_gemini_service

    db = SessionLocal()
    try:
        msg = db.query(Message).filter(Message.id == message_id).first()
        if not msg or msg.message_type != "voice" or not msg.audio_url:
            print(f"❌ [MsgTranscribe] Message {message_id[:8]}… not found or not voice")
            return

        # 🔴 ROUND 71 S30: skip vault voice messages — sending vault
        # ciphertext to Gemini burns the user's quota AND writes
        # garbage `[DECRYPT_FAILED]`-shape transcripts. Vault audio
        # is recipient-only by design; transcription would defeat
        # the entire vault contract. Detection: `allow_forward=False`
        # is the round-70 marker for vault sends, OR the audio_url
        # ends with the `.vlt` suffix.
        _is_vault = (msg.allow_forward is False) or (
            isinstance(msg.audio_url, str) and (
                ".vlt" in msg.audio_url.lower()
            )
        )
        if _is_vault:
            msg.transcript_status = "failed"
            db.commit()
            print(f"🔒 [MsgTranscribe] refusing vault voice {message_id[:8]} (allow_forward={msg.allow_forward})")
            return

        msg.transcript_status = "processing"
        db.commit()

        gemini = get_gemini_service()

        # Resolve audio URL — may be relative path.
        # 🔴 ROUND 71 S7-parallel: re-sign the GCS URL via
        # `_refresh_signed_url` because the stored URL is a 1-hr
        # signed URL that may have expired.
        from routers.posts import _refresh_signed_url as _refresh_voice
        audio_url = _refresh_voice(msg.audio_url) or msg.audio_url
        if not audio_url.startswith("http"):
            base = os.environ.get("SERVER_BASE_URL", "").rstrip("/")
            if not base:
                base = "https://raven-server-5iwa2y5n3a-ww.a.run.app"
            audio_url = f"{base}/{audio_url.lstrip('/')}"

        print(f"🎙️ [MsgTranscribe] Resolved audio URL: {audio_url[:100]}...")

        result = await gemini.transcribe_audio(audio_url)

        if result.get("text"):
            msg.transcript_text = result["text"]
            msg.transcript_language = result.get("language")
            msg.transcript_status = "ready"
            db.commit()
            print(f"✅ Message transcript ready: {message_id[:8]}… lang={result.get('language')}")
        else:
            msg.transcript_status = "failed"
            db.commit()
            print(f"❌ Message transcript failed: {message_id[:8]}… {result.get('error')}")
    except Exception as e:
        print(f"❌ Message transcript error: {e}")
        import traceback
        traceback.print_exc()
        try:
            msg = db.query(Message).filter(Message.id == message_id).first()
            if msg:
                msg.transcript_status = "failed"
                db.commit()
        except Exception:
            pass
    finally:
        db.close()


from fastapi import BackgroundTasks as _MsgBT


@router.post("/{message_id}/transcribe")
async def transcribe_voice_message(
    message_id: str,
    background_tasks: _MsgBT,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Trigger transcription for a voice message. Idempotent."""
    # ═══ Premium Rate Limit (3/day for free users, unlimited for premium) ═══
    from middleware.premium_rate_limit import check_ai_quota
    check_ai_quota(current_user)
    msg = db.query(Message).filter(Message.id == message_id).first()
    if not msg:
        raise HTTPException(status_code=404, detail="Message not found")

    if msg.message_type != "voice" or not msg.audio_url:
        raise HTTPException(status_code=400, detail="Not a voice message")

    # Verify caller is sender or recipient
    if msg.sender_id != current_user.id and msg.recipient_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not your message")

    # Idempotent: return cached if ready
    if msg.transcript_status == "ready":
        return {
            "status": "ready",
            "language": msg.transcript_language,
            "text": msg.transcript_text
        }

    # Already pending/processing — don't re-queue
    if msg.transcript_status in ("pending", "processing"):
        return {"status": msg.transcript_status}

    # Queue transcription
    msg.transcript_status = "pending"
    db.commit()

    background_tasks.add_task(_run_message_transcription, message_id)

    print(f"🎙️ Queued message transcription: {message_id[:8]}… by {current_user.username}")
    return {"status": "pending"}


@router.get("/{message_id}/transcript")
def get_message_transcript(
    message_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get transcript for a voice message (poll endpoint)."""
    msg = db.query(Message).filter(Message.id == message_id).first()
    if not msg:
        raise HTTPException(status_code=404, detail="Message not found")

    # Verify caller is sender or recipient
    if msg.sender_id != current_user.id and msg.recipient_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not your message")

    return {
        "status": msg.transcript_status or "none",
        "language": msg.transcript_language,
        "text": msg.transcript_text
    }


# ==================== MESSAGE REACTIONS ====================
#
# 🔴 2026-05-20 — the iOS client (MessageReactionStore,
# ReactionPickerCapsule, EmojiReactionPickerSheet) shipped a complete
# reaction UI calling these two endpoints, but the server side never
# existed — every POST/GET 404'd, so a tapped reaction flashed on
# screen then reverted. These endpoints are that missing server half.


class ReactionDTO(BaseModel):
    id: str
    user_id: str
    emoji: str
    created_at: datetime


class ToggleReactionRequest(BaseModel):
    # camelCase `isGroup` matches what the iOS NetworkService Body
    # encodes — its request encoder does NOT snake_case-convert.
    emoji: str
    isGroup: bool = False


class ToggleReactionResponse(BaseModel):
    action: str                      # "added" | "removed"
    reactions: List[ReactionDTO]


class ReactionsListResponse(BaseModel):
    reactions: List[ReactionDTO]


# Max distinct emoji reactions one user may hold on one message.
# Mirrors MessageReactionStore.maxReactionsPerUser on iOS.
_MAX_REACTIONS_PER_USER = 3


def _reaction_audience(db: Session, message_id: str, is_group: bool, user_id: str) -> List[str]:
    """Authorize `user_id` to react to `message_id` and return the
    OTHER participants' user-ids (used for the live-sync WS push).

    Raises 404 — never 403 — for both "no such message" and "not a
    participant", so reaction probing can't confirm a message exists.
    """
    if is_group:
        gmsg = db.query(GroupMessage).filter(GroupMessage.id == message_id).first()
        if not gmsg:
            raise HTTPException(status_code=404, detail="Message not found")
        members = db.query(GroupMember).filter(
            GroupMember.group_id == gmsg.group_id
        ).all()
        member_ids = [m.user_id for m in members]
        if user_id not in member_ids:
            raise HTTPException(status_code=404, detail="Message not found")
        return [uid for uid in member_ids if uid != user_id]

    msg = db.query(Message).filter(Message.id == message_id).first()
    if not msg:
        raise HTTPException(status_code=404, detail="Message not found")
    if user_id not in (msg.sender_id, msg.recipient_id):
        raise HTTPException(status_code=404, detail="Message not found")
    other = msg.recipient_id if msg.sender_id == user_id else msg.sender_id
    return [other] if other and other != user_id else []


def _reaction_dtos(db: Session, message_id: str) -> List[ReactionDTO]:
    from models import MessageReaction
    rows = db.query(MessageReaction).filter(
        MessageReaction.message_id == message_id
    ).order_by(MessageReaction.created_at.asc()).all()
    return [
        ReactionDTO(id=r.id, user_id=r.user_id, emoji=r.emoji, created_at=r.created_at)
        for r in rows
    ]


@router.post("/{message_id}/reactions", response_model=ToggleReactionResponse)
async def toggle_message_reaction(
    message_id: str,
    req: ToggleReactionRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Toggle the (caller, emoji) reaction on a message.

    Adds the reaction if absent, removes it if present — no separate
    DELETE. A user may hold at most `_MAX_REACTIONS_PER_USER` distinct
    emoji on one message; adding beyond the cap evicts their oldest.
    The full reaction list is returned AND pushed to the other
    participant(s) over /ws/inbox as a `message_reaction` event so
    reactions appear live on both sides.
    """
    from models import MessageReaction

    emoji = (req.emoji or "").strip()
    if not emoji or len(emoji) > 32:
        raise HTTPException(status_code=400, detail="Invalid emoji")

    audience = _reaction_audience(db, message_id, req.isGroup, current_user.id)

    existing = db.query(MessageReaction).filter(
        MessageReaction.message_id == message_id,
        MessageReaction.user_id == current_user.id,
        MessageReaction.emoji == emoji,
    ).first()

    if existing:
        db.delete(existing)
        action = "removed"
    else:
        # Per-user cap — evict the oldest until adding one more keeps
        # the user at or below the cap.
        mine = db.query(MessageReaction).filter(
            MessageReaction.message_id == message_id,
            MessageReaction.user_id == current_user.id,
        ).order_by(MessageReaction.created_at.asc()).all()
        while len(mine) >= _MAX_REACTIONS_PER_USER:
            db.delete(mine.pop(0))
        db.add(MessageReaction(
            message_id=message_id,
            is_group=bool(req.isGroup),
            user_id=current_user.id,
            emoji=emoji,
        ))
        action = "added"

    db.commit()

    dtos = _reaction_dtos(db, message_id)

    # Live sync — push the updated reaction list to the other
    # participant(s); the client's RealtimeEngine maps a
    # `message_reaction` event onto MessageReactionStore.
    ws_payload = {
        "type": "message_reaction",
        "message_id": message_id,
        "reactions": [
            {
                "id": d.id,
                "user_id": d.user_id,
                "emoji": d.emoji,
                "created_at": d.created_at.isoformat() + "Z",
            }
            for d in dtos
        ],
    }
    for uid in audience:
        try:
            await ws_manager.notify(uid, ws_payload)
        except Exception as ex:
            print(f"⚠️ [Reactions] WS notify failed for {uid[:8]}: {ex}")

    return ToggleReactionResponse(action=action, reactions=dtos)


@router.get("/{message_id}/reactions", response_model=ReactionsListResponse)
def list_message_reactions(
    message_id: str,
    is_group: bool = False,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return every reaction on a message. Caller must be a participant."""
    _reaction_audience(db, message_id, is_group, current_user.id)  # authz / 404
    return ReactionsListResponse(reactions=_reaction_dtos(db, message_id))
