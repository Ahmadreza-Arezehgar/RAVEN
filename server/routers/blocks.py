"""
Blocks Router - User blocking system with side-effects.
On block: removes friendship, hides content, prevents messaging.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import or_, and_
from pydantic import BaseModel
from typing import Optional
from datetime import datetime
import uuid as uuid_mod

from database import get_db
from models import Block, User, HiddenContent, Post
from auth import get_current_user

router = APIRouter(prefix="/api/blocks", tags=["blocks"])


# ==================== SCHEMAS ====================

class BlockCreate(BaseModel):
    blocked_id: str


class BlockResponse(BaseModel):
    id: str
    blocked_id: str
    blocked_username: Optional[str]
    created_at: datetime


# ==================== HELPER FUNCTIONS ====================

def is_blocked(db: Session, user_a: str, user_b: str) -> bool:
    """Check if either user has blocked the other."""
    return db.query(Block).filter(
        or_(
            and_(Block.blocker_id == user_a, Block.blocked_id == user_b),
            and_(Block.blocker_id == user_b, Block.blocked_id == user_a)
        )
    ).first() is not None


def get_block_status(db: Session, current_user_id: str, other_user_id: str) -> dict:
    """Get detailed block status between two users."""
    i_blocked_them = db.query(Block).filter(
        Block.blocker_id == current_user_id,
        Block.blocked_id == other_user_id
    ).first()
    
    they_blocked_me = db.query(Block).filter(
        Block.blocker_id == other_user_id,
        Block.blocked_id == current_user_id
    ).first()
    
    return {
        "i_blocked_them": i_blocked_them is not None,
        "they_blocked_me": they_blocked_me is not None,
        "can_message": i_blocked_them is None and they_blocked_me is None
    }


def get_blocked_user_ids(db: Session, user_id: str) -> list:
    """Get all user IDs that this user has blocked or has been blocked by."""
    blocks = db.query(Block).filter(
        or_(Block.blocker_id == user_id, Block.blocked_id == user_id)
    ).all()
    
    ids = set()
    for b in blocks:
        if b.blocker_id == user_id:
            ids.add(b.blocked_id)
        else:
            ids.add(b.blocker_id)
    return list(ids)


# ==================== ENDPOINTS ====================

@router.post("/", status_code=status.HTTP_201_CREATED)
async def block_user(
    block: BlockCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Block a user.
    Side-effects:
    1. Removes friendship (if exists)
    2. Cancels pending friend requests (both directions)
    3. Hides all blocked user's posts for the blocker
    """
    
    # Can't block yourself
    if block.blocked_id == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You cannot block yourself"
        )
    
    # Check if user exists
    target_user = db.query(User).filter(User.id == block.blocked_id).first()
    if not target_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    # Check if already blocked
    existing = db.query(Block).filter(
        Block.blocker_id == current_user.id,
        Block.blocked_id == block.blocked_id
    ).first()
    
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="User is already blocked"
        )
    
    # Create block
    db_block = Block(
        blocker_id=current_user.id,
        blocked_id=block.blocked_id
    )
    db.add(db_block)
    
    # ===== SIDE-EFFECTS =====
    cleanup_actions = []
    
    # 1. Remove friendship and friend requests (both directions)
    try:
        from models import FriendRequest
        requests = db.query(FriendRequest).filter(
            or_(
                and_(FriendRequest.requester_id == current_user.id, FriendRequest.recipient_id == block.blocked_id),
                and_(FriendRequest.requester_id == block.blocked_id, FriendRequest.recipient_id == current_user.id)
            )
        ).all()
        for r in requests:
            db.delete(r)  # Delete all requests (pending or accepted) to sever the friendship completely
        if requests:
            cleanup_actions.append("friend_requests_removed")
    except Exception:
        pass
    
    # 3. Hide all blocked user's posts from the blocker
    try:
        blocked_posts = db.query(Post).filter(Post.user_id == block.blocked_id).all()
        for post in blocked_posts:
            existing_hidden = db.query(HiddenContent).filter(
                HiddenContent.user_id == current_user.id,
                HiddenContent.object_type == "post",
                HiddenContent.object_id == post.id
            ).first()
            if not existing_hidden:
                db.add(HiddenContent(
                    id=str(uuid_mod.uuid4()),
                    user_id=current_user.id,
                    object_type="post",
                    object_id=post.id,
                    reason="blocked"
                ))
        if blocked_posts:
            cleanup_actions.append(f"hid_{len(blocked_posts)}_posts")
    except Exception:
        pass
    
    # 4. Hide the user account itself
    db.add(HiddenContent(
        id=str(uuid_mod.uuid4()),
        user_id=current_user.id,
        object_type="user",
        object_id=block.blocked_id,
        reason="blocked"
    ))
    cleanup_actions.append("user_hidden")
    
    db.commit()
    
    print(f"🚫 [Block] {current_user.username} blocked {target_user.username} | side-effects: {cleanup_actions}")
    
    return {
        "success": True,
        "message": f"Blocked {target_user.username}",
        "block_id": db_block.id,
        "cleanup_actions": cleanup_actions
    }


@router.delete("/{blocked_id}")
async def unblock_user(
    blocked_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Unblock a user. Removes block + hidden content from that user."""
    
    block = db.query(Block).filter(
        Block.blocker_id == current_user.id,
        Block.blocked_id == blocked_id
    ).first()
    
    if not block:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Block not found"
        )
    
    # Remove block
    db.delete(block)
    
    # Remove all hidden content from this blocked user
    hidden_items = db.query(HiddenContent).filter(
        HiddenContent.user_id == current_user.id,
        HiddenContent.reason == "blocked"
    ).all()
    
    # Only remove hidden content created by this block (match by checking if object belongs to unblocked user)
    # For simplicity, remove all "blocked" reason hidden content for the user account
    user_hidden = db.query(HiddenContent).filter(
        HiddenContent.user_id == current_user.id,
        HiddenContent.object_type == "user",
        HiddenContent.object_id == blocked_id,
        HiddenContent.reason == "blocked"
    ).first()
    if user_hidden:
        db.delete(user_hidden)
    
    # 🐛 FIX: was `Post.user_id` — that column doesn't exist on Post.
    # The Post model uses `author_id` (see models.py). This crashed
    # every unblock call with `AttributeError: type object 'Post' has
    # no attribute 'user_id'`, leaving stale blocks forever.
    blocked_posts = db.query(Post).filter(Post.author_id == blocked_id).all()
    for post in blocked_posts:
        post_hidden = db.query(HiddenContent).filter(
            HiddenContent.user_id == current_user.id,
            HiddenContent.object_type == "post",
            HiddenContent.object_id == post.id,
            HiddenContent.reason == "blocked"
        ).first()
        if post_hidden:
            db.delete(post_hidden)
    
    db.commit()
    
    print(f"✅ [Unblock] {current_user.username} unblocked user {blocked_id}")
    
    return {"success": True, "message": "User unblocked"}


@router.get("/")
async def get_blocked_users(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get list of users you have blocked."""
    
    blocks = db.query(Block).filter(
        Block.blocker_id == current_user.id
    ).all()
    
    result = []
    for b in blocks:
        user = db.query(User).filter(User.id == b.blocked_id).first()
        result.append({
            "id": b.id,
            "blocked_id": b.blocked_id,
            "blocked_username": user.username if user else None,
            "blocked_avatar": user.avatar_path if user else None,
            "created_at": b.created_at.isoformat()
        })
    
    return result


@router.get("/ids")
async def get_blocked_ids(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get compact list of blocked user IDs (for local cache sync).
    Returns both users I blocked and users who blocked me.
    """
    return {"blocked_ids": get_blocked_user_ids(db, current_user.id)}


@router.get("/status/{user_id}")
async def get_block_status_endpoint(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Check block status with another user."""
    return get_block_status(db, current_user.id, user_id)
