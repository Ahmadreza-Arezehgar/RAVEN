"""
Message Requests Router — Accept / Decline / Block actions for receivers.

When a RAVEN+ user messages a non-friend, a MessageRequest row is created.
The receiver can then accept (unlocks chat), decline (permanently blocks further messages),
or block the sender entirely.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import or_, and_

from database import get_db
from models import User, MessageRequest
from routers.users import get_current_user

router = APIRouter(prefix="/api/message-requests", tags=["message_requests"])


def _resolve_request(db: Session, request_id: str, current_user_id: str) -> MessageRequest:
    """
    Resolve a MessageRequest by its UUID first, then fall back to treating
    request_id as the peer's user_id (sender_id lookup).
    Raises 404 if not found.
    """
    msg_request = db.query(MessageRequest).filter(MessageRequest.id == request_id).first()
    if not msg_request:
        # Fallback: caller passed the peer's userId instead of the request UUID
        msg_request = db.query(MessageRequest).filter(
            MessageRequest.receiver_id == current_user_id,
            MessageRequest.sender_id == request_id,
        ).first()
    if not msg_request:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Message request not found")
    return msg_request


@router.post("/{request_id}/accept")
async def accept_message_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Accept a message request — unlocks the conversation for both parties."""
    msg_request = _resolve_request(db, request_id, current_user.id)

    if msg_request.receiver_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the receiver can accept")

    if msg_request.status in ("declined", "blocked"):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Request already resolved")

    msg_request.status = "accepted"
    db.commit()

    print(f"✅ [MessageRequest] Request {msg_request.id} accepted by {current_user.username}")
    return {"status": "accepted", "request_id": msg_request.id}


@router.post("/{request_id}/decline")
async def decline_message_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Decline a message request — permanently denies future sends."""
    msg_request = _resolve_request(db, request_id, current_user.id)

    if msg_request.receiver_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the receiver can decline")

    msg_request.status = "declined"
    db.commit()

    print(f"❌ [MessageRequest] Request {msg_request.id} declined by {current_user.username}")
    return {"status": "declined", "request_id": msg_request.id}


@router.post("/{request_id}/block")
async def block_message_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Block the sender of a message request.
    1. Marks the MessageRequest as 'blocked'
    2. Creates a Block record so all messaging/content filters apply
    """
    msg_request = _resolve_request(db, request_id, current_user.id)

    if msg_request.receiver_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the receiver can block")

    msg_request.status = "blocked"

    # Create Block record (idempotent — skip if already exists)
    from models import Block
    existing_block = db.query(Block).filter(
        and_(
            Block.blocker_id == current_user.id,
            Block.blocked_id == msg_request.sender_id,
        )
    ).first()

    if not existing_block:
        db.add(Block(blocker_id=current_user.id, blocked_id=msg_request.sender_id))

    db.commit()

    print(f"🚫 [MessageRequest] Request {msg_request.id} blocked by {current_user.username}")
    return {"status": "blocked", "request_id": msg_request.id}
