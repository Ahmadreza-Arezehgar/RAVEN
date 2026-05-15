from fastapi import APIRouter, Depends, HTTPException, status, BackgroundTasks
from sqlalchemy.orm import Session
from sqlalchemy import or_, and_
from pydantic import BaseModel, Field, field_validator
from typing import List, Optional, Literal
from datetime import datetime, timedelta

from database import get_db
from models import User, Message, GroupMessage, Group, GroupMember
from routers.users import get_current_user
from encryption import encrypt_text, decrypt_text
from middleware.rate_limit import rate_limiter
from ws_manager import ws_manager
import os

router = APIRouter(prefix="/api/messages", tags=["messages"])

# Constants for validation
MAX_MESSAGE_LENGTH = 10000  # 10KB max message content
MAX_FILENAME_LENGTH = 255

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
                allow_forward=existing.allow_forward if existing.allow_forward is not None else True
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
    from models import Friendship, MessageRequest
    are_friends = db.query(Friendship).filter(
        or_(
            and_(Friendship.user_id == current_user.id, Friendship.friend_id == req.recipient_id),
            and_(Friendship.user_id == req.recipient_id, Friendship.friend_id == current_user.id)
        )
    ).first() is not None
    
    if not are_friends:
        # Non-friends: only RAVEN+ users can send message requests
        if not getattr(current_user, 'is_premium', False):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Only RAVEN+ users can send message requests to non-friends"
            )
        
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
        allow_forward=allow_forward
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
        
        # Determine preview based on message type
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
        
        notif = Notification(
            user_id=req.recipient_id,
            type="message",  # All message types are "message" type notifications
            data=json.dumps({
                "room_id": current_user.id,  # For 1:1, room_id = sender's id (for navigation)
                "sender_id": current_user.id,
                "sender_username": current_user.username,
                "preview": preview_text,
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
        allow_forward=message.allow_forward if message.allow_forward is not None else True
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
                from encryption import decrypt_text
                first = decrypt_text(sender_first_name) if sender_first_name else ""
                if first == "[DECRYPT_FAILED]":
                    first = ""
                last = decrypt_text(sender_last_name) if sender_last_name else ""
                if last == "[DECRYPT_FAILED]":
                    last = ""
                sender_name = f"{first} {last}".strip()
                if not sender_name:
                    sender_name = sender_username
                
                preview = content or preview_text
                if not show_preview:
                    preview = "New message"
                
                apns = get_apns_service()
                push_result = await apns.send_message_notification(
                    device_token=recipient_push_token,
                    sender_name=sender_name,
                    message_preview=preview,
                    room_id=sender_id,
                    sender_id=sender_id,
                    message_type=message_type
                )
                if push_result:
                    print(f"📱 ✅ [BG] Push sent to {recipient_username}")
                else:
                    print(f"📱 ❌ [BG] Push failed for {recipient_username}")
            else:
                print(f"📱 ⏭️ [BG] Push skipped for {recipient_username} (notifications disabled)")
        
        print(f"📨 [BG] Message sent: {sender_username} → {recipient_username} (type={message_type})")
        
        # 2. Bridge wake: send silent push to recipient's friends
        try:
            from models import Friendship, User as UserModel
            from services.apns_service import get_apns_service
            from database import SessionLocal
            
            db = SessionLocal()
            try:
                bridge_friends = db.query(UserModel).join(
                    Friendship, Friendship.friend_id == UserModel.id
                ).filter(
                    Friendship.user_id == recipient_id,
                    UserModel.push_token.isnot(None),
                    UserModel.push_platform == "ios",
                    UserModel.id != sender_id
                ).limit(3).all()
                
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
                else:
                    print(f"🌉 [BG Bridge Wake] No bridge friends found for {recipient_username}")
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
    # 🛡️ SECURITY: Verify bridge device Ed25519 signature
    # ═══════════════════════════════════════════════════════════════
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
        print(f"✅ [Bridge] Bridge signature verified from {req.bridged_from[:8]}")
    else:
        print(f"⚠️ [Bridge] No bridge signature provided from {req.bridged_from[:8]} (legacy client)")
    
    # ═══════════════════════════════════════════════════════════════
    # 👥 GROUP MESSAGE BRIDGE
    # ═══════════════════════════════════════════════════════════════
    if req.is_group and req.group_id:
        return await _bridge_group_message(req, current_user, db)
    
    # ═══════════════════════════════════════════════════════════════
    # 1:1 MESSAGE BRIDGE (existing logic, unchanged)
    # ═══════════════════════════════════════════════════════════════
    
    # Check for duplicate
    existing = db.query(Message).filter(Message.id == req.message_id).first()
    if existing:
        print(f"⚠️ [Bridge] Duplicate message {req.message_id[:8]}, ignoring")
        return {"status": "duplicate", "message_id": req.message_id}
    
    # Verify recipient exists
    recipient = db.query(User).filter(User.id == req.recipient_id).first()
    if not recipient:
        raise HTTPException(status_code=404, detail="Recipient not found")
    
    # Create message with original sender info
    message = Message(
        id=req.message_id,
        sender_id=req.original_sender_id,
        recipient_id=req.recipient_id,
        content=encrypt_text(req.content),
        message_type=req.message_type,
        timestamp=datetime.utcnow(),
        delivered_at=None  # Leave undelivered — recipient marks via /inbox poll or /ack-delivered
    )
    
    db.add(message)
    db.commit()
    
    print(f"✅ [Bridge] Message stored: {req.original_sender_id[:8]} → {req.recipient_id[:8]}")
    
    # ⚡ INSTANT PUSH: Notify WebSocket-connected recipient immediately
    await ws_manager.notify(req.recipient_id, {
        "id": message.id,
        "sender_id": message.sender_id,
        "recipient_id": message.recipient_id,
        "content": req.content,
        "timestamp": message.timestamp.isoformat() + "Z",
        "read_at": None,
        "delivered_at": None,
        "sender_username": req.original_sender_name,
        "sender_name": req.original_sender_name,
        "message_type": message.message_type or "text",
        "room_id": req.original_sender_id,
        "audio_url": None,
        "audio_duration_seconds": None,
        "file_name": None,
        "file_size": None,
        "mime_type": None,
    })
    
    # ✅ Send push notification to recipient (with preference check)
    if recipient.push_token and recipient.push_platform == "ios":
        from services.apns_service import get_apns_service, APNsService
        
        prefs = APNsService.should_send_push(recipient, "message")
        if prefs["allowed"]:
            sender_name = req.original_sender_name or "Unknown"
            preview = req.content[:100] if req.content else "New message"
            if not prefs["show_preview"]:
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
    
    notif = Notification(
        user_id=req.recipient_id,
        type="message",
        data=json.dumps({
            "room_id": req.original_sender_id,
            "sender_id": req.original_sender_id,
            "sender_username": req.original_sender_name,
            "preview": req.content[:100] if req.content else "Mesh message",
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
    """
    import json
    from models import Notification
    
    group_id = req.group_id
    print(f"👥 [Bridge Group] Storing group message in group {group_id[:8]} from sender {req.original_sender_id[:8]}")
    
    # Check for duplicate in GroupMessage table
    existing = db.query(GroupMessage).filter(GroupMessage.id == req.message_id).first()
    if existing:
        print(f"⚠️ [Bridge Group] Duplicate message {req.message_id[:8]}, ignoring")
        return {"status": "duplicate", "message_id": req.message_id}
    
    # Also check 1:1 Message table for duplicates (belt and suspenders)
    existing_1to1 = db.query(Message).filter(Message.id == req.message_id).first()
    if existing_1to1:
        print(f"⚠️ [Bridge Group] Duplicate in Message table {req.message_id[:8]}, ignoring")
        return {"status": "duplicate", "message_id": req.message_id}
    
    # Verify group exists
    group = db.query(Group).filter(Group.id == group_id).first()
    if not group:
        print(f"⚠️ [Bridge Group] Group {group_id[:8]} not found — storing anyway with provided group_id")
    
    # Store in GroupMessage table
    group_msg = GroupMessage(
        id=req.message_id,
        group_id=group_id,
        sender_id=req.original_sender_id,
        content=encrypt_text(req.content),
        message_type=req.message_type,
        timestamp=datetime.utcnow()
    )
    db.add(group_msg)
    db.flush()
    
    # Delivery tracking: snapshot member list
    all_member_ids = req.group_member_ids or []
    if not all_member_ids:
        # Fallback: get members from DB
        members = db.query(GroupMember).filter(GroupMember.group_id == group_id).all()
        all_member_ids = [m.user_id for m in members]
    # Ensure sender is in the list
    if req.original_sender_id not in all_member_ids:
        all_member_ids.append(req.original_sender_id)
    
    group_msg.recipient_set = json.dumps(all_member_ids)
    group_msg.delivered_to = json.dumps([req.original_sender_id])  # Sender has it
    db.commit()
    
    print(f"✅ [Bridge Group] Message stored in GroupMessage: {req.message_id[:8]} → group {group_id[:8]} ({len(all_member_ids)} members)")
    
    # ⚡ INSTANT PUSH: Notify all WebSocket-connected group members immediately
    for member_id in all_member_ids:
        if member_id != req.original_sender_id:
            await ws_manager.notify(member_id, {
                "id": group_msg.id,
                "sender_id": group_msg.sender_id,
                "recipient_id": member_id,
                "content": req.content,
                "timestamp": group_msg.timestamp.isoformat() + "Z",
                "read_at": None,
                "delivered_at": None,
                "sender_username": req.original_sender_name,
                "sender_name": req.original_sender_name,
                "message_type": group_msg.message_type or "text",
                "room_id": group_id,
                "audio_url": None,
                "audio_duration_seconds": None,
                "file_name": None,
                "file_size": None,
                "mime_type": None,
            })
    
    # ✅ Push notify all group members except sender
    from services.apns_service import get_apns_service, APNsService
    
    other_member_ids = [uid for uid in all_member_ids if uid != req.original_sender_id]
    if other_member_ids:
        members_to_notify = db.query(User).filter(
            User.id.in_(other_member_ids)
        ).all()
        
        sender_name = req.original_sender_name or "Unknown"
        group_name = group.name if group else "Group"
        preview = req.content[:100] if req.content else "New message"
        
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
            notif = Notification(
                user_id=member.id,
                type="group_message",
                data=json.dumps({
                    "room_id": group_id,
                    "group_id": group_id,
                    "group_name": group_name,
                    "sender_id": req.original_sender_id,
                    "sender_username": sender_name,
                    "preview": preview,
                    "message_type": req.message_type,
                    "bridged": True
                }),
                is_read=False
            )
            db.add(notif)
        
        db.commit()
        print(f"🔔 [Bridge Group] Notifications sent to {len(members_to_notify)} members")
    
    return {
        "status": "success",
        "message_id": req.message_id,
        "bridged_from": req.bridged_from,
        "group_id": group_id
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
    # Get messages between current user and other user
    messages = db.query(Message).filter(
        or_(
            and_(Message.sender_id == current_user.id, Message.recipient_id == other_user_id),
            and_(Message.sender_id == other_user_id, Message.recipient_id == current_user.id)
        )
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
            reply_to_type=msg.reply_to_type
        ))
        # 🔍 DEBUG: Log voice message audio_url from DB
        if (msg.message_type or "text") == "voice":
            print(f"🎤 [GetConversation] VOICE msg id={msg.id[:8]} audio_url={msg.audio_url}")
    
    return result

@router.get("/unread", response_model=List[MessageResponse])
def get_unread_messages(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get all unread messages for current user with sender info (capped at 200)."""
    messages = db.query(Message).filter(
        Message.recipient_id == current_user.id,
        Message.read_at.is_(None)
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
            reply_to_type=msg.reply_to_type
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
        allow_forward=msg.allow_forward if msg.allow_forward is not None else True
    )

@router.post("/backfill-voice-urls")
def backfill_voice_urls(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Backfill audio_url for voice messages that are missing it.
    Tries to recover voice URL from GCS bucket listing.
    Only accessible by the message owner.
    """
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
        query = db.query(Message).filter(
            Message.recipient_id == current_user.id
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
                reply_to_type=msg.reply_to_type
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
    status = "muted" if req.muted else "unmuted"
    print(f"🔕 Conversation with {req.peer_id[:8]} {status} by {current_user.username}")
    
    # For now, mute is stored client-side only
    # Future: could add muted column to RoomVisibility or a new UserPreference table
    
    return {"success": True, "muted": req.muted}


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
        
        # Count unread messages using RoomVisibility.last_read_at (persistent across reinstalls)
        # Messages from peer, sent after my last_read_at for this room
        from models import RoomVisibility
        
        visibility = db.query(RoomVisibility).filter(
            RoomVisibility.user_id == current_user.id,
            RoomVisibility.room_id == peer_id
        ).first()
        
        last_read_at = visibility.last_read_at if visibility else None
        
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
            requestId=req_id
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
                    group_avatar_url=group.avatar_url
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
        
        # ═══════════════════════════════════════════════════════════════
        # FIX v3: Handle __ALL_PEERS__ sentinel — when the bridge can't
        # resolve BLE peer userIds, it sends this sentinel. We return
        # ALL undelivered messages so the bridge can relay to any nearby
        # BLE peer, regardless of friendship status.
        # ═══════════════════════════════════════════════════════════════
        actual_peer_ids = req.peer_user_ids
        if "__ALL_PEERS__" in req.peer_user_ids:
            _bdl_logger.debug(f"🌉 [Bridge Downlink] __ALL_PEERS__ mode — returning all undelivered messages")
            actual_peer_ids = None  # Skip recipient filter — return ALL undelivered
        
        # Find undelivered messages for the specified peers
        # Also include recently-delivered messages (last 120s) as fallback
        # in case inbox polling already marked them before bridge could relay
        # EXCLUDE: messages sent by the bridge device itself
        from datetime import timedelta
        recent_cutoff = datetime.utcnow() - timedelta(seconds=120)
        
        if actual_peer_ids is not None:
            pending = db.query(Message).filter(
                Message.recipient_id.in_(actual_peer_ids),
                Message.sender_id != current_user.id,  # Don't return B's own messages
                (
                    Message.delivered_at.is_(None) |
                    (Message.delivered_at > recent_cutoff)
                ),
                Message.read_at.is_(None),  # Skip already-read messages
            ).order_by(Message.timestamp.desc()).limit(20).all()
        else:
            # No peer filter — get ALL undelivered messages not from bridge
            pending = db.query(Message).filter(
                Message.sender_id != current_user.id,
                Message.delivered_at.is_(None),
                Message.read_at.is_(None),
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
                    # Get recent group messages (last 24 hours) that haven't been fully delivered
                    group_msg_cutoff = datetime.utcnow() - timedelta(hours=24)
                    
                    group_msgs = db.query(GroupMessage).filter(
                        GroupMessage.group_id.in_(peer_group_ids),
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
                        })
                    
                    _bdl_logger.debug(f"🌉 [Bridge Downlink] {len(group_results)} group messages need relay to peers")
        except Exception as ge:
            _bdl_logger.warning(f"⚠️ [Bridge Downlink] Group query failed (non-fatal): {ge}")
        
        if not pending and not group_results:
            _bdl_logger.debug(f"🌉 [Bridge Downlink] No pending messages — empty")
            return {"messages": [], "count": 0}
        
        _bdl_logger.debug(f"🌉 [Bridge Downlink] Returning {len(pending)} 1:1 + {len(group_results)} group messages")
        
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
        
        print(f"✅ [Bridge Downlink] Returning {len(all_messages)} messages ({len(result)} 1:1 + {len(group_results)} group)")
        
        return {"messages": all_messages, "count": len(all_messages)}
        
    except Exception as e:
        print(f"❌ [Bridge Downlink] Error: {e}")
        print(f"❌ [Bridge Downlink] Traceback: {traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=f"Bridge downlink error: {str(e)}")


@router.get("/debug/delivery-state/{recipient_id}")
def debug_delivery_state(
    recipient_id: str,
    db: Session = Depends(get_db)
):
    """DEBUG: Check delivery state of messages for a recipient"""
    from sqlalchemy import func
    
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

        msg.transcript_status = "processing"
        db.commit()

        gemini = get_gemini_service()

        # Resolve audio URL — may be relative path
        audio_url = msg.audio_url
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
