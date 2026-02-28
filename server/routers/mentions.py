"""
Mentions API Router - Read, list, and mark mentions as read.

Endpoints:
- GET /api/mentions - Get all mentions for current user (paginated)
- GET /api/mentions/unread - Get unread mentions count and list
- POST /api/mentions/{id}/read - Mark a mention as read
- POST /api/mentions/read-all - Mark all mentions as read
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime

from database import get_db
from models import User, Mention
from routers.users import get_current_user

router = APIRouter(prefix="/api/mentions", tags=["mentions"])


# ═══════════════════════════════════════════════════════════════════════════
# RESPONSE MODELS
# ═══════════════════════════════════════════════════════════════════════════

class MentionResponse(BaseModel):
    id: str
    type: str  # chat_message, post_comment
    source_id: str
    post_id: Optional[str]
    room_id: Optional[str]
    mentioned_by_user_id: str
    mentioned_by_username: Optional[str]
    mentioned_by_avatar: Optional[str]
    created_at: datetime
    snippet: Optional[str]
    deep_link: Optional[str]
    is_read: bool
    
    class Config:
        from_attributes = True


class UnreadMentionsResponse(BaseModel):
    count: int
    mentions: List[MentionResponse]


# ═══════════════════════════════════════════════════════════════════════════
# ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════

@router.get("", response_model=List[MentionResponse])
def get_mentions(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
    offset: int = 0
):
    """Get all mentions for current user, ordered by most recent."""
    mentions = db.query(Mention).filter(
        Mention.mentioned_user_id == current_user.id
    ).order_by(Mention.created_at.desc()).offset(offset).limit(limit).all()
    
    return _build_mention_responses(mentions, db)


@router.get("/unread", response_model=UnreadMentionsResponse)
def get_unread_mentions(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get unread mentions count and list."""
    unread = db.query(Mention).filter(
        Mention.mentioned_user_id == current_user.id,
        Mention.is_read == False
    ).order_by(Mention.created_at.desc()).all()
    
    return UnreadMentionsResponse(
        count=len(unread),
        mentions=_build_mention_responses(unread, db)
    )


@router.post("/{mention_id}/read")
def mark_mention_read(
    mention_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Mark a single mention as read."""
    mention = db.query(Mention).filter(
        Mention.id == mention_id,
        Mention.mentioned_user_id == current_user.id
    ).first()
    
    if not mention:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Mention not found"
        )
    
    mention.is_read = True
    db.commit()
    
    return {"status": "success", "message": "Mention marked as read"}


@router.post("/read-all")
def mark_all_mentions_read(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Mark all mentions as read for current user."""
    count = db.query(Mention).filter(
        Mention.mentioned_user_id == current_user.id,
        Mention.is_read == False
    ).update({"is_read": True})
    
    db.commit()
    
    print(f"✅ [Mentions] Marked {count} mentions as read for {current_user.username}")
    return {"status": "success", "count": count}


# ═══════════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════════

def _build_mention_responses(mentions: list, db: Session) -> List[MentionResponse]:
    """Build mention responses with user info."""
    # Batch fetch mentioner info
    user_ids = list(set(m.mentioned_by_user_id for m in mentions))
    users = {u.id: u for u in db.query(User).filter(User.id.in_(user_ids)).all()} if user_ids else {}
    
    responses = []
    for m in mentions:
        mentioner = users.get(m.mentioned_by_user_id)
        responses.append(MentionResponse(
            id=m.id,
            type=m.type,
            source_id=m.source_id,
            post_id=m.post_id,
            room_id=m.room_id,
            mentioned_by_user_id=m.mentioned_by_user_id,
            mentioned_by_username=mentioner.username if mentioner else None,
            mentioned_by_avatar=mentioner.avatar_path if mentioner else None,
            created_at=m.created_at,
            snippet=m.snippet,
            deep_link=m.deep_link,
            is_read=m.is_read
        ))
    
    return responses
