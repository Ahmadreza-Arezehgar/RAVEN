"""
Data Export Router — GDPR-style "Download My Data" endpoint.

Returns all user-owned data as a downloadable JSON file.
"""
from fastapi import APIRouter, Depends, Header, HTTPException, status
from fastapi.responses import StreamingResponse
from sqlalchemy.orm import Session
from datetime import datetime
import json
import io

from database import get_db
from models import (
    User, Message, Post, PostMedia, Comment, PostLike, Repost,
    FriendRequest, Friendship, GroupMember, GroupMessage, Group,
    Notification, Device, VoiceMessage, SnapMessage
)
from auth import decode_token
from encryption import decrypt_text

router = APIRouter(prefix="/api/users", tags=["data-export"])


# ── Auth dependency (same pattern as users.py) ──

def _get_current_user(authorization: str = Header(None), db: Session = Depends(get_db)) -> User:
    """Extract user from JWT token."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid authorization header")
    
    token = authorization.replace("Bearer ", "")
    payload = decode_token(token)
    if not payload:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired token")
    
    user_id = payload.get("sub")
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found")
    
    return user


# ── Helpers ──

def _safe_decrypt(text: str) -> str:
    """Decrypt text, returning empty string on failure."""
    if not text:
        return ""
    try:
        result = decrypt_text(text)
        return result if result != "[DECRYPT_FAILED]" else ""
    except Exception:
        return ""


def _iso(dt) -> str | None:
    """Convert datetime to ISO string or None."""
    return dt.isoformat() + "Z" if dt else None


# ── Main endpoint ──

@router.get("/me/data-export")
def export_user_data(
    current_user: User = Depends(_get_current_user),
    db: Session = Depends(get_db)
):
    """
    Export all user data as a downloadable JSON file.
    
    Includes: profile, messages, posts, comments, likes, friends, groups.
    Encrypted fields are decrypted before export.
    Media URLs are included so the user can download files separately.
    """
    from sqlalchemy import or_
    import json as _json

    user_id = current_user.id
    username = current_user.username or "user"

    print(f"📦 [DataExport] Starting export for {username} ({user_id[:8]}...)")

    # ═══════════════════════════════════════════════
    # 1. PROFILE
    # ═══════════════════════════════════════════════
    hobbies = []
    if current_user.hobbies:
        try:
            hobbies = _json.loads(current_user.hobbies)
        except Exception:
            hobbies = []

    profile = {
        "id": user_id,
        "username": username,
        "email": _safe_decrypt(current_user.email),
        "phone": _safe_decrypt(current_user.phone),
        "first_name": _safe_decrypt(current_user.first_name),
        "last_name": _safe_decrypt(current_user.last_name),
        "bio": current_user.bio,
        "birthday": _iso(current_user.birthday) if hasattr(current_user, "birthday") and current_user.birthday else None,
        "avatar_url": current_user.avatar_path,
        "tags": hobbies,
        "created_at": _iso(current_user.created_at),
        "last_login": _iso(current_user.last_login),
        "email_verified": current_user.email_verified or False,
        "phone_verified": current_user.phone_verified or False,
        "is_verified": current_user.is_verified or False,
        "is_premium": current_user.is_premium or False,
    }

    # ═══════════════════════════════════════════════
    # 2. DIRECT MESSAGES (sent & received)
    # ═══════════════════════════════════════════════
    dm_rows = db.query(Message).filter(
        or_(Message.sender_id == user_id, Message.recipient_id == user_id)
    ).order_by(Message.timestamp.asc()).all()

    # Batch-load usernames for sender/recipient display
    dm_user_ids = set()
    for m in dm_rows:
        dm_user_ids.add(m.sender_id)
        dm_user_ids.add(m.recipient_id)
    dm_user_ids.discard(user_id)
    dm_users = {u.id: u.username for u in db.query(User.id, User.username).filter(User.id.in_(dm_user_ids)).all()} if dm_user_ids else {}

    direct_messages = []
    for m in dm_rows:
        other_id = m.recipient_id if m.sender_id == user_id else m.sender_id
        direct_messages.append({
            "id": m.id,
            "direction": "sent" if m.sender_id == user_id else "received",
            "other_user": dm_users.get(other_id, other_id),
            "content": _safe_decrypt(m.content),
            "type": m.message_type or "text",
            "media_url": m.audio_url,
            "file_name": m.file_name,
            "timestamp": _iso(m.timestamp),
        })

    # ═══════════════════════════════════════════════
    # 3. GROUP MESSAGES (sent by user)
    # ═══════════════════════════════════════════════
    gm_rows = db.query(GroupMessage).filter(
        GroupMessage.sender_id == user_id
    ).order_by(GroupMessage.timestamp.asc()).all()

    # Get group names
    gm_group_ids = set(g.group_id for g in gm_rows)
    group_names = {}
    if gm_group_ids:
        for g in db.query(Group.id, Group.name).filter(Group.id.in_(gm_group_ids)).all():
            group_names[g.id] = g.name

    group_messages = []
    for gm in gm_rows:
        group_messages.append({
            "id": gm.id,
            "group": group_names.get(gm.group_id, gm.group_id),
            "content": _safe_decrypt(gm.content),
            "type": gm.message_type or "text",
            "media_url": gm.audio_url,
            "timestamp": _iso(gm.timestamp),
        })

    # ═══════════════════════════════════════════════
    # 4. POSTS
    # ═══════════════════════════════════════════════
    post_rows = db.query(Post).filter(
        Post.author_id == user_id
    ).order_by(Post.timestamp.asc()).all()

    posts = []
    for p in post_rows:
        media_urls = [pm.url for pm in p.media] if p.media else []
        posts.append({
            "id": p.id,
            "content": _safe_decrypt(p.content),
            "type": p.post_type or "text",
            "image_url": p.image_url,
            "media_urls": media_urls,
            "voice_url": p.voice_url,
            "visibility": p.visibility,
            "likes": p.likes,
            "view_count": p.view_count,
            "timestamp": _iso(p.timestamp),
            "edited_at": _iso(p.edited_at),
        })

    # ═══════════════════════════════════════════════
    # 5. COMMENTS
    # ═══════════════════════════════════════════════
    comment_rows = db.query(Comment).filter(
        Comment.author_id == user_id
    ).order_by(Comment.timestamp.asc()).all()

    comments = []
    for c in comment_rows:
        comments.append({
            "id": c.id,
            "post_id": c.post_id,
            "content": _safe_decrypt(c.content),
            "type": c.comment_type or "text",
            "media_url": c.media_url,
            "score": c.score,
            "timestamp": _iso(c.timestamp),
        })

    # ═══════════════════════════════════════════════
    # 6. LIKES
    # ═══════════════════════════════════════════════
    like_rows = db.query(PostLike).filter(
        PostLike.user_id == user_id
    ).all()

    likes = [{"post_id": l.post_id, "timestamp": _iso(l.timestamp)} for l in like_rows]

    # ═══════════════════════════════════════════════
    # 7. FRIENDS
    # ═══════════════════════════════════════════════
    friend_rows = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(FriendRequest.requester_id == user_id, FriendRequest.recipient_id == user_id)
    ).all()

    friend_ids = set()
    for f in friend_rows:
        friend_ids.add(f.recipient_id if f.requester_id == user_id else f.requester_id)

    friend_users = {}
    if friend_ids:
        for u in db.query(User.id, User.username).filter(User.id.in_(friend_ids)).all():
            friend_users[u.id] = u.username

    friends = [
        {"user_id": fid, "username": friend_users.get(fid, fid)}
        for fid in friend_ids
    ]

    # ═══════════════════════════════════════════════
    # 8. GROUPS
    # ═══════════════════════════════════════════════
    memberships = db.query(GroupMember).filter(
        GroupMember.user_id == user_id
    ).all()

    membership_group_ids = [gm.group_id for gm in memberships]
    all_groups = {}
    if membership_group_ids:
        for g in db.query(Group).filter(Group.id.in_(membership_group_ids)).all():
            all_groups[g.id] = g

    groups = []
    for gm in memberships:
        g = all_groups.get(gm.group_id)
        groups.append({
            "group_id": gm.group_id,
            "name": g.name if g else gm.group_id,
            "role": gm.role if hasattr(gm, "role") else "member",
            "joined_at": _iso(gm.joined_at) if hasattr(gm, "joined_at") else None,
        })

    # ═══════════════════════════════════════════════
    # BUILD EXPORT
    # ═══════════════════════════════════════════════
    export_data = {
        "export_info": {
            "app": "RAVEN",
            "exported_at": datetime.utcnow().isoformat() + "Z",
            "user_id": user_id,
            "username": username,
            "format_version": "1.0",
        },
        "profile": profile,
        "direct_messages": direct_messages,
        "group_messages": group_messages,
        "posts": posts,
        "comments": comments,
        "likes": likes,
        "friends": friends,
        "groups": groups,
        "summary": {
            "direct_messages_count": len(direct_messages),
            "group_messages_count": len(group_messages),
            "posts_count": len(posts),
            "comments_count": len(comments),
            "likes_count": len(likes),
            "friends_count": len(friends),
            "groups_count": len(groups),
        },
    }

    # Serialize
    json_bytes = json.dumps(export_data, indent=2, ensure_ascii=False, default=str).encode("utf-8")
    date_str = datetime.utcnow().strftime("%Y%m%d")
    filename = f"raven_data_export_{username}_{date_str}.json"

    print(f"📦 [DataExport] Export complete for {username}: "
          f"{len(direct_messages)} DMs, {len(group_messages)} group msgs, "
          f"{len(posts)} posts, {len(comments)} comments, "
          f"{len(likes)} likes, {len(friends)} friends, {len(groups)} groups "
          f"({len(json_bytes)} bytes)")

    return StreamingResponse(
        io.BytesIO(json_bytes),
        media_type="application/json",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Content-Length": str(len(json_bytes)),
        }
    )
