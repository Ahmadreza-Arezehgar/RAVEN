"""
Message Requests Router — Accept / Decline / Block actions for receivers.

When a RAVEN+ user messages a non-friend, a MessageRequest row is created.
The receiver can then accept (unlocks chat), decline (permanently blocks further messages),
or block the sender entirely.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from database import get_db
from models import User, MessageRequest
from routers.users import get_current_user

router = APIRouter(prefix="/api/message-requests", tags=["message_requests"])


@router.post("/{request_id}/accept")
async def accept_message_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Accept a message request — unlocks the conversation for both parties."""
    msg_request = db.query(MessageRequest).filter(MessageRequest.id == request_id).first()
    if not msg_request:
        # Fallback: treat request_id as room_id (peer's user id)
        msg_request = db.query(MessageRequest).filter(
            MessageRequest.receiver_id == current_user.id,
            MessageRequest.sender_id == request_id,
        ).first()

    if not msg_request:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Message request not found")

    if msg_request.receiver_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the receiver can accept")

    if msg_request.status in ("declined", "blocked"):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Request already resolved")

    msg_request.status = "accepted"
    db.commit()

    print(f"✅ [MessageRequest] Request {request_id} accepted by {current_user.username}")
    return {"status": "accepted", "request_id": msg_request.id}


@router.post("/{request_id}/decline")
async def decline_message_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Decline a message request — permanently denies future sends."""
    msg_request = db.query(MessageRequest).filter(MessageRequest.id == request_id).first()
    if not msg_request:
        msg_request = db.query(MessageRequest).filter(
            MessageRequest.receiver_id == current_user.id,
            MessageRequest.sender_id == request_id,
        ).first()

    if not msg_request:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Message request not found")

    if msg_request.receiver_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the receiver can decline")

    msg_request.status = "declined"
    db.commit()

    print(f"❌ [MessageRequest] Request {request_id} declined by {current_user.username}")
    return {"status": "declined", "request_id": msg_request.id}


# 🔴 ROUND 26 (2026-05-16) — REAL ROUND-2 FIX.
# iOS `ChatView.swift:1752` POSTs `/api/message-requests/{id}/{action}`
# where action ∈ {accept, decline, block}. The accept + decline endpoints
# already existed (above), but `block` was silently 404-ing. Adding it
# now — same fallback-lookup rules as decline, plus an idempotent insert
# into the `Block` table so the sender disappears from feeds and can't
# send new requests.
@router.post("/{request_id}/block")
async def block_message_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Block the sender of a message request — hard block + status update."""
    from models import Block
    import uuid as _uuid
    from datetime import datetime

    msg_request = db.query(MessageRequest).filter(MessageRequest.id == request_id).first()
    if not msg_request:
        msg_request = db.query(MessageRequest).filter(
            MessageRequest.receiver_id == current_user.id,
            MessageRequest.sender_id == request_id,
        ).first()

    if not msg_request:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Message request not found")

    if msg_request.receiver_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the receiver can block")

    msg_request.status = "blocked"

    # Idempotent: only insert if no existing Block row.
    existing = db.query(Block).filter(
        Block.blocker_id == current_user.id,
        Block.blocked_id == msg_request.sender_id,
    ).first()
    if existing is None:
        db.add(Block(
            id=str(_uuid.uuid4()),
            blocker_id=current_user.id,
            blocked_id=msg_request.sender_id,
            created_at=datetime.utcnow(),
        ))

    db.commit()

    print(f"🚫 [MessageRequest] Request {request_id} BLOCKED by {current_user.username}")
    return {"status": "blocked", "request_id": msg_request.id}
