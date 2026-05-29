"""
Nearby People — resolve a list of user IDs (learned via BLE mesh) into
public profiles for the "People Nearby" view.

The iOS client passes the user IDs it has heard from the mesh, and the
server returns the matching public-profile rows (display name + avatar).
This is just a batch profile lookup with friend-aware visibility — no new
data, just a focused endpoint.

Privacy: the server only returns profiles the caller is allowed to see. Users
who blocked the caller, or whose privacy settings don't allow profile lookup,
are filtered out. The mesh-broadcast layer's BLE advertising payload only
includes the userId (which is already publicly known to friends), so there's
no PII leak from being on a mesh that another user happens to be on.
"""
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from database import get_db
from models import User
from routers.users import get_current_user

router = APIRouter(prefix="/api/nearby", tags=["nearby"])


class NearbyLookupRequest(BaseModel):
    userIds: List[str]


class NearbyPersonResponse(BaseModel):
    userId: str
    username: str
    displayName: Optional[str] = None
    avatarPath: Optional[str] = None
    isFriend: bool = False


@router.post("/lookup", response_model=List[NearbyPersonResponse])
def lookup_nearby(
    body: NearbyLookupRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Resolve a batch of mesh-discovered user IDs into public profiles.

    🔴 hacker-audit 2026-05-19 — the module docstring claimed the
    server "only returns profiles the caller is allowed to see" but
    the code didn't actually filter:
      • Rows where the target had blocked the caller were returned.
      • Private-profile users (is_private=True) had their decrypted
        real names exposed to anyone who passed the UUID — and
        UUIDs leak (mesh broadcast, group lookups, mentions).
      • Targets with `who_can_see_profile != 'public'` were also
        unfiltered.
    All three gates are now enforced. Real-name decryption only
    happens for friends OR fully-public profiles; everyone else
    surfaces as their username only.
    """
    ids = list({uid for uid in body.userIds if uid and uid != current_user.id})
    if not ids:
        return []
    if len(ids) > 100:
        raise HTTPException(status_code=400, detail="Too many ids (max 100)")

    rows = db.query(User).filter(User.id.in_(ids)).all()
    # Best-effort friendship lookup.
    from models import FriendRequest, Block
    friendships = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        ((FriendRequest.requester_id == current_user.id) | (FriendRequest.recipient_id == current_user.id)),
    ).all()
    friend_ids = set()
    for fr in friendships:
        friend_ids.add(fr.requester_id if fr.requester_id != current_user.id else fr.recipient_id)

    # Users who blocked the caller — drop entirely.
    blocked_me_ids = {
        b.blocker_id for b in db.query(Block).filter(
            Block.blocked_id == current_user.id
        ).all()
    }

    from encryption import decrypt_text
    out: List[NearbyPersonResponse] = []
    for u in rows:
        if u.id in blocked_me_ids:
            continue
        is_friend = u.id in friend_ids
        is_private = bool(getattr(u, "is_private", False))
        who_can_see = (getattr(u, "who_can_see_profile", None) or "public").lower()
        expose_real_name = is_friend or (not is_private and who_can_see == "public")

        if expose_real_name:
            first = decrypt_text(u.first_name) if getattr(u, "first_name", None) else None
            last = decrypt_text(u.last_name) if getattr(u, "last_name", None) else None
            if first == "[DECRYPT_FAILED]":
                first = None
            if last == "[DECRYPT_FAILED]":
                last = None
            display = " ".join([s for s in [first, last] if s]) or u.username
        else:
            display = u.username

        out.append(NearbyPersonResponse(
            userId=u.id,
            username=u.username,
            displayName=display,
            avatarPath=u.avatar_path,
            isFriend=is_friend,
        ))
    return out
