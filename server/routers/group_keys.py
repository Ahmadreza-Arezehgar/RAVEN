"""
Group Symmetric Keys — per-group AES-256 keys for mesh-broadcast encryption.

Why
---
Today, anyone who learns a group's UUID can flood the BLE mesh with valid
signed envelopes targeting that groupId. Other peers must verify-and-drop
each one (CPU + battery cost). With per-group symmetric keys, those envelopes
fail decryption immediately — outsiders can't waste relay capacity.

Endpoints
---------
- GET  /api/groups/{group_id}/key            → current key (members only)
- POST /api/groups/{group_id}/key/rotate     → mint a new version (admins)

Threat model
------------
The server holds the key plaintext. This is acceptable because:
  * Server-routed group messages are already plaintext-on-server (no E2E for
    groups today). This is not a regression.
  * What we gain: any non-member device that hears a mesh-broadcast envelope
    has NO way to decrypt or forge a valid one without the key. The key is
    ONLY served over authenticated TLS to confirmed group members.
  * Forward secrecy on member-kick: bumping the version means a kicked
    member's cached key can't decrypt new messages.

Future evolution
----------------
A v2 can move to Signal-style sender keys (per-member, per-group) so the
server never sees plaintext. That's a multi-week project; this v1 is the
correct first step.
"""
import os
import secrets
import base64
from datetime import datetime
from typing import Optional, List

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import Column, String, Integer, DateTime, Index
from sqlalchemy.orm import Session

from database import get_db, Base
from models import User, Group, GroupMember
from routers.users import get_current_user

router = APIRouter(prefix="/api/groups", tags=["group_keys"])


class GroupKey(Base):
    """Per-group AES-256 symmetric key, versioned."""
    __tablename__ = "group_keys"
    id = Column(String, primary_key=True)              # uuid
    group_id = Column(String, nullable=False, index=True)
    version = Column(Integer, nullable=False)
    key_b64 = Column(String, nullable=False)           # 32-byte AES key, base64
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    __table_args__ = (
        Index("idx_group_keys_group_version", "group_id", "version", unique=True),
    )


class GroupKeyResponse(BaseModel):
    groupId: str
    version: int
    keyB64: str
    createdAt: datetime


# ────────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────────

def _is_member(db: Session, group_id: str, user_id: str) -> bool:
    return db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == user_id,
    ).first() is not None


def _is_admin(db: Session, group_id: str, user_id: str) -> bool:
    member = db.query(GroupMember).filter(
        GroupMember.group_id == group_id,
        GroupMember.user_id == user_id,
    ).first()
    return member is not None and member.role == "admin"


def _latest_key(db: Session, group_id: str) -> Optional[GroupKey]:
    return db.query(GroupKey).filter(
        GroupKey.group_id == group_id
    ).order_by(GroupKey.version.desc()).first()


def _mint_new_key(db: Session, group_id: str) -> GroupKey:
    """Create a fresh AES-256 key and persist it as the next version."""
    import uuid
    latest = _latest_key(db, group_id)
    next_version = (latest.version + 1) if latest else 1
    raw_key = secrets.token_bytes(32)
    key = GroupKey(
        id=str(uuid.uuid4()),
        group_id=group_id,
        version=next_version,
        key_b64=base64.b64encode(raw_key).decode("ascii"),
    )
    db.add(key)
    db.flush()
    return key


def ensure_group_key(db: Session, group_id: str) -> GroupKey:
    """Public helper: callable from group create / member-add flows. Returns
    the existing latest key, or mints version 1 if none exists yet."""
    existing = _latest_key(db, group_id)
    if existing is not None:
        return existing
    return _mint_new_key(db, group_id)


# ────────────────────────────────────────────────────────────────────────
# Endpoints
# ────────────────────────────────────────────────────────────────────────

@router.get("/{group_id}/key", response_model=GroupKeyResponse)
def get_group_key(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return the latest group key (members only). Mints version 1 if missing."""
    if db.query(Group).filter(Group.id == group_id).first() is None:
        raise HTTPException(status_code=404, detail="Group not found")
    if not _is_member(db, group_id, current_user.id):
        raise HTTPException(status_code=403, detail="Not a member of this group")

    key = ensure_group_key(db, group_id)
    db.commit()
    return GroupKeyResponse(
        groupId=group_id,
        version=key.version,
        keyB64=key.key_b64,
        createdAt=key.created_at,
    )


@router.post("/{group_id}/key/rotate", response_model=GroupKeyResponse)
def rotate_group_key(
    group_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Mint a fresh group key (admin only). Used after member-kick to
    achieve forward secrecy: kicked member's cached key won't decrypt new
    mesh broadcasts."""
    if db.query(Group).filter(Group.id == group_id).first() is None:
        raise HTTPException(status_code=404, detail="Group not found")
    if not _is_admin(db, group_id, current_user.id):
        raise HTTPException(status_code=403, detail="Admin only")

    key = _mint_new_key(db, group_id)
    db.commit()
    return GroupKeyResponse(
        groupId=group_id,
        version=key.version,
        keyB64=key.key_b64,
        createdAt=key.created_at,
    )
