"""
Concert Mode — auto-join the ephemeral group for everyone in a venue.

User taps "Concert Mode" at a concert / festival / convention. We hash their
location into a geo-cell (~150m radius) and return the ephemeral group for
that cell. If no group exists yet for the cell, we mint one. The group
auto-expires after `CONCERT_TTL_HOURS` so it doesn't survive past the event.

Wire format
-----------
POST /api/concert-mode/join { lat, lng } → { groupId, name, expiresAt, isNew }

Privacy
-------
The H3 cell is the only stored location data. The cell is ~150m on a side,
which is enough to cover one venue but not enough to identify a person's
home/workplace. The group has a generic name like "Concert nearby ⚡". No
member list is shown to outsiders — only people in the group see who's in
it (same as any other group chat).

Group key
---------
Concert groups get a per-group AES-256 key just like any other group, so
mesh-broadcast messages within the group stay confidential to its members
(see `routers/group_keys.py`). When a group expires, its key auto-revokes
on the next admin action.
"""
import uuid
from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import Column, String, DateTime, Index
from sqlalchemy.orm import Session

from database import get_db, Base
from models import User, Group, GroupMember
from routers.users import get_current_user
from routers.group_keys import ensure_group_key

router = APIRouter(prefix="/api/concert-mode", tags=["concert_mode"])

CONCERT_TTL_HOURS = 12


class ConcertGroup(Base):
    """Maps geo-cells to ephemeral group IDs. Auto-expires."""
    __tablename__ = "concert_groups"
    id = Column(String, primary_key=True)
    h3_cell = Column(String, nullable=False, index=True)
    group_id = Column(String, nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    expires_at = Column(DateTime, nullable=False, index=True)

    __table_args__ = (
        Index("idx_concert_h3_active", "h3_cell", "expires_at"),
    )


# ────────────────────────────────────────────────────────────────────

class JoinRequest(BaseModel):
    lat: float
    lng: float


class JoinResponse(BaseModel):
    groupId: str
    name: str
    h3Cell: str
    expiresAt: datetime
    isNew: bool
    memberCount: int


def _h3_cell(lat: float, lng: float, resolution: int = 9) -> str:
    """Approximate H3-style hex cell. We don't depend on the h3 Python lib
    here; coarse 0.001° rounding gives ~110m bins which is close enough to
    H3 resolution-9 for venue clustering. If you want true H3, install
    `h3` and replace this with `h3.latlng_to_cell(lat, lng, 9)`."""
    rounded_lat = round(lat, 3)
    rounded_lng = round(lng, 3)
    return f"v1:{rounded_lat:.3f},{rounded_lng:.3f}"


def _bucket_count(n: int) -> int:
    """Coarse buckets so the response can't be used to enumerate
    crowd density per cell.

    🔴 hacker-audit 2026-05-19: previously `memberCount` returned
    the EXACT count for every cell. An attacker could sweep lat/lng
    on a ~111m grid, call /join for each, and harvest a real-time
    density map of every Concert cell on the planet — including
    private gatherings and the precise count of attendees. Coarse
    buckets preserve the UX signal ("there are some / many people
    here") while making cell-by-cell enumeration useless for
    finer-grained surveillance.
    """
    if n <= 1:
        return 1
    if n <= 5:
        return 5
    if n <= 20:
        return 20
    if n <= 50:
        return 50
    return 100  # 51+ all bucket here


@router.post("/join", response_model=JoinResponse)
def join_concert(
    body: JoinRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    # 🔴 hacker-audit 2026-05-19: hard rate-limit per user to make
    # cell-sweep attacks impractical even with the bucketed count.
    # 10 joins/hour is plenty for legit use (you don't join 10
    # concerts in an hour); a scanner trips the limiter in seconds.
    try:
        from middleware.rate_limit import rate_limiter
        rate_limiter.check_rate_limit(
            identifier=f"concert_join:{current_user.id}",
            max_attempts=10,
            window_minutes=60,
            lockout_minutes=60,
        )
    except HTTPException:
        raise
    except Exception:
        pass

    cell = _h3_cell(body.lat, body.lng)
    now = datetime.utcnow()

    # Reuse an unexpired concert group for this cell, otherwise mint a new one.
    existing = (
        db.query(ConcertGroup)
        .filter(ConcertGroup.h3_cell == cell, ConcertGroup.expires_at > now)
        .order_by(ConcertGroup.created_at.desc())
        .first()
    )

    is_new = False
    if existing is not None:
        group = db.query(Group).filter(Group.id == existing.group_id).first()
        if group is None:
            existing = None  # stale row — fall through to create

    if existing is None:
        # Create the underlying ChatGroup
        group = Group(
            id=str(uuid.uuid4()),
            name="Concert nearby ⚡",
            description="Ephemeral group — everyone within ~150m at this moment.",
            created_by=current_user.id,
            visibility="private",
            link_join_enabled=False,
        )
        db.add(group)
        db.flush()

        # Persist the cell mapping
        existing = ConcertGroup(
            id=str(uuid.uuid4()),
            h3_cell=cell,
            group_id=group.id,
            expires_at=now + timedelta(hours=CONCERT_TTL_HOURS),
        )
        db.add(existing)

        # Mint the per-group AES key
        try:
            ensure_group_key(db, group.id)
        except Exception as e:
            # Non-fatal — group is still usable, just without mesh encryption
            print(f"⚠️ [ConcertMode] ensure_group_key failed: {e}")

        is_new = True

    # Add the caller as a member if not already
    membership = (
        db.query(GroupMember)
        .filter(GroupMember.group_id == existing.group_id, GroupMember.user_id == current_user.id)
        .first()
    )
    if membership is None:
        db.add(GroupMember(
            id=str(uuid.uuid4()),
            group_id=existing.group_id,
            user_id=current_user.id,
            role="member",
            joined_at=now,
        ))

    member_count = db.query(GroupMember).filter(GroupMember.group_id == existing.group_id).count()
    if membership is None:
        member_count += 1

    db.commit()

    return JoinResponse(
        groupId=existing.group_id,
        name=group.name if group else "Concert nearby ⚡",
        h3Cell=cell,
        expiresAt=existing.expires_at,
        isNew=is_new,
        memberCount=_bucket_count(member_count),
    )


@router.post("/leave")
def leave_concert(
    body: JoinRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Remove caller from the concert group for this cell. Doesn't delete
    the group itself — it expires on its own TTL."""
    cell = _h3_cell(body.lat, body.lng)
    now = datetime.utcnow()
    existing = (
        db.query(ConcertGroup)
        .filter(ConcertGroup.h3_cell == cell, ConcertGroup.expires_at > now)
        .order_by(ConcertGroup.created_at.desc())
        .first()
    )
    if existing is None:
        return {"status": "no_active_group"}
    db.query(GroupMember).filter(
        GroupMember.group_id == existing.group_id,
        GroupMember.user_id == current_user.id,
    ).delete()
    db.commit()
    return {"status": "left"}
