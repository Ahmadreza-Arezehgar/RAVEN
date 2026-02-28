"""
Channels API Router — Telegram-style broadcast channels.

Endpoints:
- POST /api/channels                        — Create channel
- GET  /api/channels/check-username         — Check @username availability
- GET  /api/channels/search                 — Search channels (Discover)
- GET  /api/channels/{id}                   — Get channel details
- PATCH /api/channels/{id}                  — Update channel (owner/admin)
- POST /api/channels/{id}/join              — Join public channel
- POST /api/channels/{id}/leave             — Leave channel
- POST /api/channels/{id}/posts             — Create post (owner/admin)
- GET  /api/channels/{id}/posts             — List posts (paginated)
- POST /api/channels/{id}/mute              — Toggle mute
- GET  /api/channels/{id}/search-posts      — Full-text search within channel
- POST /api/channels/posts/{post_id}/forward — Forward post (public only)
- POST /api/channels/{id}/invite            — Generate invite link (private)
- POST /api/channels/join-invite/{code}     — Join via invite code
- POST /api/channels/{id}/verification/request — Request verification
"""

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from sqlalchemy import func, or_
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
from database import SessionLocal
from routers.users import get_current_user
from models import User, Channel, ChannelMember, ChannelPost, ChannelInviteLink
import uuid
import secrets
import re
import logging

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/channels", tags=["channels"])


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# ═══════════════════════════════════════════════════════════════════════════
# REQUEST / RESPONSE MODELS
# ═══════════════════════════════════════════════════════════════════════════

class CreateChannelRequest(BaseModel):
    name: str
    channel_username: str
    description: Optional[str] = None
    avatar_url: Optional[str] = None
    type: str = "public"  # "public" or "private"


class UpdateChannelRequest(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    avatar_url: Optional[str] = None
    type: Optional[str] = None


class CreatePostRequest(BaseModel):
    content_type: str = "text"
    content_payload: Optional[str] = None
    media_url: Optional[str] = None


class ForwardPostRequest(BaseModel):
    target_id: str        # recipient user_id or group_id
    is_group: bool = False


class ChannelMemberResponse(BaseModel):
    user_id: str
    username: str
    avatar_url: Optional[str]
    role: str
    joined_at: datetime

    class Config:
        from_attributes = True


class ChannelResponse(BaseModel):
    id: str
    owner_id: str
    channel_username: str
    name: str
    description: Optional[str]
    avatar_url: Optional[str]
    type: str
    verified_status: str
    created_at: datetime
    member_count: int
    my_role: Optional[str] = None
    is_muted: bool = False

    class Config:
        from_attributes = True


class ChannelPostResponse(BaseModel):
    id: str
    channel_id: str
    author_id: str
    author_username: Optional[str] = None
    author_role: Optional[str] = None
    content_type: str
    content_payload: Optional[str]
    media_url: Optional[str]
    created_at: datetime

    class Config:
        from_attributes = True


class PromoteMemberRequest(BaseModel):
    role: str  # "admin" or "moderator"


class ChannelSearchResult(BaseModel):
    id: str
    username: str
    name: str
    avatar_url: Optional[str]
    members_count: int
    verified_status: bool
    type: str

    class Config:
        from_attributes = True


# ═══════════════════════════════════════════════════════════════════════════
# USERNAME VALIDATION
# ═══════════════════════════════════════════════════════════════════════════

USERNAME_PATTERN = re.compile(r'^[a-zA-Z][a-zA-Z0-9_]{3,19}$')


def validate_channel_username(username: str) -> bool:
    """Validate channel username: 4-20 chars, starts with letter, alphanumeric + underscore."""
    return bool(USERNAME_PATTERN.match(username))


# ═══════════════════════════════════════════════════════════════════════════
# HELPER: get membership + role check
# ═══════════════════════════════════════════════════════════════════════════

def _get_membership(db: Session, channel_id: str, user_id: str) -> Optional[ChannelMember]:
    return db.query(ChannelMember).filter(
        ChannelMember.channel_id == channel_id,
        ChannelMember.user_id == user_id
    ).first()


def _require_admin(db: Session, channel_id: str, user_id: str) -> ChannelMember:
    """Require user to be owner or admin of the channel."""
    member = _get_membership(db, channel_id, user_id)
    if not member or member.role not in ("owner", "admin"):
        raise HTTPException(status_code=403, detail="Only owner/admin can perform this action")
    return member


def _require_poster(db: Session, channel_id: str, user_id: str) -> ChannelMember:
    """Require user to be owner, admin, or moderator (can post in channel)."""
    member = _get_membership(db, channel_id, user_id)
    if not member or member.role not in ("owner", "admin", "moderator"):
        raise HTTPException(status_code=403, detail="Only owner/admin/moderator can post")
    return member


# ═══════════════════════════════════════════════════════════════════════════
# ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════

# ── Check username availability ────────────────────────────────────────────

@router.get("/check-username")
def check_username(
    u: str = Query(..., min_length=4, max_length=20),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Check if a channel @username is available."""
    clean = u.lstrip("@").lower()
    if not validate_channel_username(clean):
        return {"available": False, "reason": "Invalid format. Use 4-20 chars: letters, numbers, underscore. Must start with a letter."}

    exists = db.query(Channel).filter(
        func.lower(Channel.channel_username) == clean
    ).first()
    return {"available": exists is None}


# ── Search channels (for Discover) ────────────────────────────────────────

@router.get("/search")
def search_channels(
    q: str = Query("", min_length=0, max_length=100),
    limit: int = Query(20, ge=1, le=50),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Search channels by name or @username. Returns public channels + private channels user is in."""
    query = db.query(Channel)

    if q.strip():
        search_term = f"%{q.strip().lower()}%"
        query = query.filter(
            or_(
                func.lower(Channel.name).like(search_term),
                func.lower(Channel.channel_username).like(search_term)
            )
        )

    # Only show public channels + private channels the user is a member of
    my_private_channel_ids = [
        m.channel_id for m in db.query(ChannelMember.channel_id).filter(
            ChannelMember.user_id == current_user.id
        ).all()
    ]
    query = query.filter(
        or_(
            Channel.type == "public",
            Channel.id.in_(my_private_channel_ids) if my_private_channel_ids else False
        )
    )

    channels = query.order_by(Channel.created_at.desc()).limit(limit).all()

    results = []
    for ch in channels:
        member_count = db.query(func.count(ChannelMember.id)).filter(
            ChannelMember.channel_id == ch.id
        ).scalar()
        results.append(ChannelSearchResult(
            id=ch.id,
            username=ch.channel_username,
            name=ch.name,
            avatar_url=ch.avatar_url,
            members_count=member_count or 0,
            verified_status=(ch.verified_status == "verified"),
            type=ch.type
        ))

    return results


# ── Create channel ─────────────────────────────────────────────────────────

@router.post("")
def create_channel(
    req: CreateChannelRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Create a new broadcast channel. Creator becomes owner."""
    # Validate username
    clean_username = req.channel_username.lstrip("@").lower()
    if not validate_channel_username(clean_username):
        raise HTTPException(status_code=400, detail="Invalid username format. Use 4-20 chars: letters, numbers, underscore. Must start with a letter.")

    # Check uniqueness
    existing = db.query(Channel).filter(
        func.lower(Channel.channel_username) == clean_username
    ).first()
    if existing:
        raise HTTPException(status_code=409, detail="Channel username already taken")

    # Validate type
    if req.type not in ("public", "private"):
        raise HTTPException(status_code=400, detail="Type must be 'public' or 'private'")

    # Create channel
    channel = Channel(
        id=str(uuid.uuid4()),
        owner_id=current_user.id,
        channel_username=clean_username,
        name=req.name.strip(),
        description=req.description,
        avatar_url=req.avatar_url,
        type=req.type
    )
    db.add(channel)

    # Add owner as member with "owner" role
    owner_member = ChannelMember(
        id=str(uuid.uuid4()),
        channel_id=channel.id,
        user_id=current_user.id,
        role="owner"
    )
    db.add(owner_member)
    db.commit()

    logger.info(f"📢 Channel created: @{clean_username} by {current_user.username}")

    return {
        "id": channel.id,
        "channel_username": channel.channel_username,
        "name": channel.name,
        "type": channel.type,
        "roomId": channel.id,
        "is_channel": True,
        "channel_type": channel.type,
        "my_role": "owner"
    }


# ── Get channel details ───────────────────────────────────────────────────

@router.get("/{channel_id}")
def get_channel_details(
    channel_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get channel details. Public channels are visible to everyone, private requires membership."""
    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    membership = _get_membership(db, channel_id, current_user.id)

    # Private channels require membership to view
    if channel.type == "private" and not membership:
        raise HTTPException(status_code=403, detail="This is a private channel. You must be a member to view it.")

    member_count = db.query(func.count(ChannelMember.id)).filter(
        ChannelMember.channel_id == channel_id
    ).scalar()

    return ChannelResponse(
        id=channel.id,
        owner_id=channel.owner_id,
        channel_username=channel.channel_username,
        name=channel.name,
        description=channel.description,
        avatar_url=channel.avatar_url,
        type=channel.type,
        verified_status=channel.verified_status,
        created_at=channel.created_at,
        member_count=member_count or 0,
        my_role=membership.role if membership else None,
        is_muted=membership.muted if membership else False
    )


# ── Update channel (owner/admin) ──────────────────────────────────────────

@router.patch("/{channel_id}")
def update_channel(
    channel_id: str,
    req: UpdateChannelRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Update channel info. Only owner/admin."""
    _require_admin(db, channel_id, current_user.id)
    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    if req.name is not None:
        channel.name = req.name.strip()
    if req.description is not None:
        channel.description = req.description
    if req.avatar_url is not None:
        channel.avatar_url = req.avatar_url
    if req.type is not None and req.type in ("public", "private"):
        channel.type = req.type

    db.commit()
    return {"status": "updated"}


# ── Join channel ───────────────────────────────────────────────────────────

@router.post("/{channel_id}/join")
def join_channel(
    channel_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Join a public channel."""
    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    if channel.type == "private":
        raise HTTPException(status_code=403, detail="This is a private channel. Use an invite link to join.")

    # Check if already a member
    existing = _get_membership(db, channel_id, current_user.id)
    if existing:
        if existing.role == "banned":
            raise HTTPException(status_code=403, detail="You are banned from this channel")
        return {"status": "already_member"}

    member = ChannelMember(
        id=str(uuid.uuid4()),
        channel_id=channel_id,
        user_id=current_user.id,
        role="member"
    )
    db.add(member)
    db.commit()

    logger.info(f"👤 {current_user.username} joined channel @{channel.channel_username}")
    return {"status": "joined"}


# ── Leave channel ──────────────────────────────────────────────────────────

@router.post("/{channel_id}/leave")
def leave_channel(
    channel_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Leave a channel. Owner cannot leave (must transfer ownership first)."""
    membership = _get_membership(db, channel_id, current_user.id)
    if not membership:
        raise HTTPException(status_code=404, detail="Not a member")

    if membership.role == "owner":
        raise HTTPException(status_code=400, detail="Owner cannot leave. Transfer ownership first.")

    db.delete(membership)
    db.commit()
    return {"status": "left"}


# ── Create post (owner/admin only) ────────────────────────────────────────

@router.post("/{channel_id}/posts")
def create_post(
    channel_id: str,
    req: CreatePostRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Create a new post in the channel. Owner/admin/moderator can post."""
    membership = _require_poster(db, channel_id, current_user.id)

    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    post = ChannelPost(
        id=str(uuid.uuid4()),
        channel_id=channel_id,
        author_id=current_user.id,
        content_type=req.content_type,
        content_payload=req.content_payload,
        media_url=req.media_url
    )
    db.add(post)
    db.commit()

    logger.info(f"📝 New post in @{channel.channel_username} by {current_user.username}")  
    return ChannelPostResponse(
        id=post.id,
        channel_id=post.channel_id,
        author_id=post.author_id,
        author_username=current_user.username,
        author_role=membership.role,
        content_type=post.content_type,
        content_payload=post.content_payload,
        media_url=post.media_url,
        created_at=post.created_at
    )


# ── List posts (paginated) ────────────────────────────────────────────────

@router.get("/{channel_id}/posts")
def list_posts(
    channel_id: str,
    limit: int = Query(20, ge=1, le=100),
    before: Optional[str] = None,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get posts in a channel (paginated, newest first)."""
    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    # Private channels require membership
    if channel.type == "private":
        membership = _get_membership(db, channel_id, current_user.id)
        if not membership:
            raise HTTPException(status_code=403, detail="Private channel. Membership required.")

    query = db.query(ChannelPost).filter(ChannelPost.channel_id == channel_id)

    if before:
        cursor_post = db.query(ChannelPost).filter(ChannelPost.id == before).first()
        if cursor_post:
            query = query.filter(ChannelPost.created_at < cursor_post.created_at)

    posts = query.order_by(ChannelPost.created_at.desc()).limit(limit).all()

    # Batch-fetch author usernames
    author_ids = list(set(p.author_id for p in posts))
    authors = {u.id: u for u in db.query(User).filter(User.id.in_(author_ids)).all()} if author_ids else {}

    # Batch-fetch memberships for author roles
    member_roles = {}
    if author_ids:
        memberships = db.query(ChannelMember).filter(
            ChannelMember.channel_id == channel_id,
            ChannelMember.user_id.in_(author_ids)
        ).all()
        member_roles = {m.user_id: m.role for m in memberships}

    return [
        ChannelPostResponse(
            id=p.id,
            channel_id=p.channel_id,
            author_id=p.author_id,
            author_username=authors.get(p.author_id, None) and authors[p.author_id].username,
            author_role=member_roles.get(p.author_id),
            content_type=p.content_type,
            content_payload=p.content_payload,
            media_url=p.media_url,
            created_at=p.created_at
        )
        for p in posts
    ]


# ── Toggle mute ────────────────────────────────────────────────────────────

@router.post("/{channel_id}/mute")
def toggle_mute(
    channel_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Toggle mute for the current user in the channel."""
    membership = _get_membership(db, channel_id, current_user.id)
    if not membership:
        raise HTTPException(status_code=404, detail="Not a member")

    membership.muted = not membership.muted
    db.commit()
    return {"muted": membership.muted}


# ── Search within channel ─────────────────────────────────────────────────

@router.get("/{channel_id}/search-posts")
def search_posts(
    channel_id: str,
    q: str = Query(..., min_length=1, max_length=200),
    limit: int = Query(20, ge=1, le=50),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Search posts within a channel by text content."""
    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    if channel.type == "private":
        membership = _get_membership(db, channel_id, current_user.id)
        if not membership:
            raise HTTPException(status_code=403, detail="Private channel. Membership required.")

    search_term = f"%{q.strip().lower()}%"
    posts = db.query(ChannelPost).filter(
        ChannelPost.channel_id == channel_id,
        func.lower(ChannelPost.content_payload).like(search_term)
    ).order_by(ChannelPost.created_at.desc()).limit(limit).all()

    author_ids = list(set(p.author_id for p in posts))
    authors = {u.id: u for u in db.query(User).filter(User.id.in_(author_ids)).all()} if author_ids else {}

    # Batch-fetch memberships for author roles
    member_roles = {}
    if author_ids:
        memberships = db.query(ChannelMember).filter(
            ChannelMember.channel_id == channel_id,
            ChannelMember.user_id.in_(author_ids)
        ).all()
        member_roles = {m.user_id: m.role for m in memberships}

    return [
        ChannelPostResponse(
            id=p.id,
            channel_id=p.channel_id,
            author_id=p.author_id,
            author_username=authors.get(p.author_id, None) and authors[p.author_id].username,
            author_role=member_roles.get(p.author_id),
            content_type=p.content_type,
            content_payload=p.content_payload,
            media_url=p.media_url,
            created_at=p.created_at
        )
        for p in posts
    ]


# ── Forward post (public only) ────────────────────────────────────────────

@router.post("/posts/{post_id}/forward")
def forward_post(
    post_id: str,
    req: ForwardPostRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Forward a channel post to a user or group. Only allowed for public channels."""
    post = db.query(ChannelPost).filter(ChannelPost.id == post_id).first()
    if not post:
        raise HTTPException(status_code=404, detail="Post not found")

    channel = db.query(Channel).filter(Channel.id == post.channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    # ❌ ENFORCE: private channels cannot be forwarded
    if channel.type == "private":
        raise HTTPException(
            status_code=403,
            detail="This channel is private. Forwarding and publishing are disabled."
        )

    # Forward is allowed — client handles the actual message creation
    # Server just validates and returns the post data for forwarding
    return {
        "status": "allowed",
        "post": ChannelPostResponse(
            id=post.id,
            channel_id=post.channel_id,
            author_id=post.author_id,
            content_type=post.content_type,
            content_payload=post.content_payload,
            media_url=post.media_url,
            created_at=post.created_at
        ),
        "forwarded_from": {
            "channel_id": channel.id,
            "channel_username": channel.channel_username,
            "channel_name": channel.name
        }
    }


# ── Generate invite link (private channels) ───────────────────────────────

@router.post("/{channel_id}/invite")
def generate_invite(
    channel_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Generate or retrieve invite link for a channel. Only owner/admin."""
    _require_admin(db, channel_id, current_user.id)

    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    # Check for existing invite
    existing = db.query(ChannelInviteLink).filter(
        ChannelInviteLink.channel_id == channel_id
    ).first()

    if existing:
        return {
            "invite_code": existing.invite_code,
            "channel_id": channel_id,
            "enabled": existing.enabled,
            "use_count": existing.use_count
        }

    # Generate new invite
    code = secrets.token_urlsafe(12)
    invite = ChannelInviteLink(
        id=str(uuid.uuid4()),
        channel_id=channel_id,
        invite_code=code,
        created_by=current_user.id
    )
    db.add(invite)
    db.commit()

    return {
        "invite_code": code,
        "channel_id": channel_id,
        "enabled": True,
        "use_count": 0
    }


# ── Join via invite code ──────────────────────────────────────────────────

@router.post("/join-invite/{code}")
def join_via_invite(
    code: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Join a channel using an invite code."""
    invite = db.query(ChannelInviteLink).filter(
        ChannelInviteLink.invite_code == code,
        ChannelInviteLink.enabled == True
    ).first()

    if not invite:
        raise HTTPException(status_code=404, detail="Invalid or expired invite link")

    # Check max uses
    if invite.max_uses and invite.use_count >= invite.max_uses:
        raise HTTPException(status_code=410, detail="Invite link has reached maximum uses")

    # Check expiry
    if invite.expires_at and invite.expires_at < datetime.utcnow():
        raise HTTPException(status_code=410, detail="Invite link has expired")

    # Check if already a member
    existing = _get_membership(db, invite.channel_id, current_user.id)
    if existing:
        if existing.role == "banned":
            raise HTTPException(status_code=403, detail="You are banned from this channel")
        return {"status": "already_member", "channel_id": invite.channel_id}

    member = ChannelMember(
        id=str(uuid.uuid4()),
        channel_id=invite.channel_id,
        user_id=current_user.id,
        role="member"
    )
    db.add(member)
    invite.use_count += 1
    db.commit()

    return {"status": "joined", "channel_id": invite.channel_id}


# ── Request verification ──────────────────────────────────────────────────

@router.post("/{channel_id}/verification/request")
def request_verification(
    channel_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Request verification for a channel. Requires >=1000 members and owner role."""
    membership = _get_membership(db, channel_id, current_user.id)
    if not membership or membership.role != "owner":
        raise HTTPException(status_code=403, detail="Only the channel owner can request verification")

    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    if channel.verified_status == "verified":
        return {"status": "already_verified"}

    member_count = db.query(func.count(ChannelMember.id)).filter(
        ChannelMember.channel_id == channel_id
    ).scalar()

    if (member_count or 0) < 1000:
        raise HTTPException(
            status_code=400,
            detail=f"Channel needs at least 1000 members for verification. Current: {member_count}"
        )

    channel.verified_status = "eligible"
    db.commit()

    logger.info(f"✅ Channel @{channel.channel_username} marked as eligible for verification ({member_count} members)")
    return {"status": "eligible", "message": "Your channel is now eligible for verification. An admin will review it."}


# ── Get my role in channel ─────────────────────────────────────────────────

@router.get("/{channel_id}/me")
def get_my_membership(
    channel_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get my role and permissions in this channel."""
    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    membership = _get_membership(db, channel_id, current_user.id)
    if not membership:
        return {"role": None, "can_post": False, "can_manage": False}

    role = membership.role
    return {
        "role": role,
        "can_post": role in ("owner", "admin", "moderator"),
        "can_manage": role in ("owner", "admin"),
        "is_muted": membership.muted
    }


# ── Get channel members ───────────────────────────────────────────────────

@router.get("/{channel_id}/members")
def get_members(
    channel_id: str,
    limit: int = Query(50, ge=1, le=200),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get channel members. Requires membership."""
    channel = db.query(Channel).filter(Channel.id == channel_id).first()
    if not channel:
        raise HTTPException(status_code=404, detail="Channel not found")

    membership = _get_membership(db, channel_id, current_user.id)
    if not membership:
        raise HTTPException(status_code=403, detail="Membership required")

    members = db.query(ChannelMember).filter(
        ChannelMember.channel_id == channel_id
    ).order_by(ChannelMember.joined_at).limit(limit).all()

    user_ids = [m.user_id for m in members]
    users = {u.id: u for u in db.query(User).filter(User.id.in_(user_ids)).all()} if user_ids else {}

    return [
        ChannelMemberResponse(
            user_id=m.user_id,
            username=users.get(m.user_id, None) and users[m.user_id].username or "unknown",
            avatar_url=users.get(m.user_id, None) and users[m.user_id].avatar_url,
            role=m.role,
            joined_at=m.joined_at
        )
        for m in members
    ]


# ── Promote member ────────────────────────────────────────────────────────

@router.post("/{channel_id}/members/{user_id}/promote")
def promote_member(
    channel_id: str,
    user_id: str,
    req: PromoteMemberRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Promote a member to admin or moderator. Owner can promote to admin/mod, admin can promote to mod."""
    actor = _get_membership(db, channel_id, current_user.id)
    if not actor or actor.role not in ("owner", "admin"):
        raise HTTPException(status_code=403, detail="Only owner/admin can promote members")

    if req.role not in ("admin", "moderator"):
        raise HTTPException(status_code=400, detail="Role must be 'admin' or 'moderator'")

    # Only owner can promote to admin
    if req.role == "admin" and actor.role != "owner":
        raise HTTPException(status_code=403, detail="Only the owner can promote to admin")

    target = _get_membership(db, channel_id, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User is not a member of this channel")

    if target.role == "owner":
        raise HTTPException(status_code=400, detail="Cannot change owner role")

    target.role = req.role
    db.commit()

    logger.info(f"⬆️ {user_id} promoted to {req.role} in channel {channel_id} by {current_user.username}")
    return {"status": "promoted", "new_role": req.role}


# ── Demote member ─────────────────────────────────────────────────────────

@router.post("/{channel_id}/members/{user_id}/demote")
def demote_member(
    channel_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Demote admin/moderator back to member. Owner can demote anyone, admin can demote moderators."""
    actor = _get_membership(db, channel_id, current_user.id)
    if not actor or actor.role not in ("owner", "admin"):
        raise HTTPException(status_code=403, detail="Only owner/admin can demote members")

    target = _get_membership(db, channel_id, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User is not a member of this channel")

    if target.role == "owner":
        raise HTTPException(status_code=400, detail="Cannot demote the owner")

    # Admin can only demote moderators, not other admins
    if target.role == "admin" and actor.role != "owner":
        raise HTTPException(status_code=403, detail="Only the owner can demote admins")

    target.role = "member"
    db.commit()

    logger.info(f"⬇️ {user_id} demoted to member in channel {channel_id} by {current_user.username}")
    return {"status": "demoted", "new_role": "member"}


# ── Remove member ─────────────────────────────────────────────────────────

@router.post("/{channel_id}/members/{user_id}/remove")
def remove_member(
    channel_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Remove a member from the channel. Owner/admin only."""
    actor = _require_admin(db, channel_id, current_user.id)

    if user_id == current_user.id:
        raise HTTPException(status_code=400, detail="Cannot remove yourself. Use leave instead.")

    target = _get_membership(db, channel_id, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User is not a member of this channel")

    if target.role == "owner":
        raise HTTPException(status_code=400, detail="Cannot remove the owner")

    # Admin cannot remove other admins
    if target.role == "admin" and actor.role != "owner":
        raise HTTPException(status_code=403, detail="Only the owner can remove admins")

    db.delete(target)
    db.commit()

    logger.info(f"🚫 {user_id} removed from channel {channel_id} by {current_user.username}")
    return {"status": "removed"}


# ── Ban member ────────────────────────────────────────────────────────────

@router.post("/{channel_id}/members/{user_id}/ban")
def ban_member(
    channel_id: str,
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Ban a member from the channel (remove + prevent rejoin). Owner/admin only."""
    actor = _require_admin(db, channel_id, current_user.id)

    if user_id == current_user.id:
        raise HTTPException(status_code=400, detail="Cannot ban yourself")

    target = _get_membership(db, channel_id, user_id)
    if not target:
        raise HTTPException(status_code=404, detail="User is not a member of this channel")

    if target.role == "owner":
        raise HTTPException(status_code=400, detail="Cannot ban the owner")

    if target.role == "admin" and actor.role != "owner":
        raise HTTPException(status_code=403, detail="Only the owner can ban admins")

    # Set role to "banned" instead of deleting — prevents rejoin
    target.role = "banned"
    db.commit()

    logger.info(f"🔨 {user_id} banned from channel {channel_id} by {current_user.username}")
    return {"status": "banned"}
