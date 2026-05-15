"""
Contacts sync router for finding friends by phone hash.
Privacy-first: Server only receives hashed phone numbers.
"""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
from database import get_db
from auth import get_current_user
import models
import hashlib
import hmac
import os

router = APIRouter(prefix="/api/contacts", tags=["contacts"])

# App-wide salt for phone hashing (must match iOS client)
PHONE_HASH_SALT = os.getenv("PHONE_HASH_SALT", "raven_contact_sync_v1")


class ContactSyncRequest(BaseModel):
    hashes: List[str]


class MatchedUser(BaseModel):
    userId: str
    username: str
    displayName: str
    avatarUrl: Optional[str] = None


class ContactSyncResponse(BaseModel):
    matches: List[MatchedUser]


class UpdateDiscoveryRequest(BaseModel):
    allow_discovery: bool


def compute_phone_hash(phone_e164: str) -> str:
    """Compute HMAC-SHA256 hash of phone number for matching."""
    return hmac.new(
        PHONE_HASH_SALT.encode('utf-8'),
        phone_e164.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()


@router.post("/sync", response_model=ContactSyncResponse)
async def sync_contacts(
    request: ContactSyncRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """
    Find which contacts are on Raven.
    
    Client sends HMAC-SHA256 hashes of contact phone numbers.
    Server matches against users who have allow_contact_discovery=True.
    """
    if not request.hashes:
        return ContactSyncResponse(matches=[])
    
    # Limit to prevent abuse
    if len(request.hashes) > 5000:
        raise HTTPException(status_code=400, detail="Too many hashes (max 5000)")
    
    # Find matching users
    matching_users = db.query(models.User).filter(
        models.User.phone_hash.in_(request.hashes),
        models.User.allow_contact_discovery == True,
        models.User.id != current_user.id,  # Don't match self
        models.User.status == 'active'
    ).all()
    
    # Filter out blocked users
    blocked_ids = set()
    blocks = db.query(models.Block).filter(
        (models.Block.blocker_id == current_user.id) | 
        (models.Block.blocked_id == current_user.id)
    ).all()
    for block in blocks:
        blocked_ids.add(block.blocker_id)
        blocked_ids.add(block.blocked_id)
    
    matches = []
    for user in matching_users:
        if user.id in blocked_ids:
            continue
            
        display_name = f"{user.first_name or ''} {user.last_name or ''}".strip()
        if not display_name:
            display_name = user.username or "Unknown"
            
        matches.append(MatchedUser(
            userId=user.id,
            username=user.username or "",
            displayName=display_name,
            avatarUrl=user.avatar_path
        ))
    
    return ContactSyncResponse(matches=matches)


@router.delete("/sync")
async def remove_contact_data(
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """
    Remove user's phone hash to opt out of contact discovery.
    Also sets allow_contact_discovery to False.
    """
    current_user.phone_hash = None
    current_user.allow_contact_discovery = False
    db.commit()
    
    return {"message": "Contact data removed"}


@router.put("/discovery")
async def update_discovery_setting(
    request: UpdateDiscoveryRequest,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """Toggle whether others can find this user via phone contacts."""
    current_user.allow_contact_discovery = request.allow_discovery
    
    # If enabling and has phone, regenerate hash
    if request.allow_discovery and current_user.phone_e164:
        current_user.phone_hash = compute_phone_hash(current_user.phone_e164)
    elif not request.allow_discovery:
        current_user.phone_hash = None
    
    db.commit()
    
    return {
        "allow_discovery": current_user.allow_contact_discovery,
        "message": "Discovery setting updated"
    }


@router.get("/discovery")
async def get_discovery_setting(
    current_user: models.User = Depends(get_current_user)
):
    """Get current discovery setting."""
    return {
        "allow_discovery": current_user.allow_contact_discovery,
        "has_phone": current_user.phone_e164 is not None
    }
