"""
Device Router - Cryptographic device identity management.

Handles device registration via public key fingerprints and
provides friend fingerprint lookup for mesh auto-connect.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import and_, or_
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
import base64
import uuid

from database import get_db
from models import Device, User, FriendRequest
from routers.users import get_current_user

router = APIRouter(prefix="/api/devices", tags=["devices"])


# ──────────────────────────────────────────────────────────────────────────
# Public-key validation
#
# Without this, a client could store a 5MB blob in the `public_key` column.
# Worse, a bridge-signature verifier later in the request lifecycle would
# crash trying to load the key as Ed25519. Validate at the trust boundary.
# ──────────────────────────────────────────────────────────────────────────

# Ed25519 public keys are exactly 32 raw bytes → 44 chars base64 (incl. '=').
# Allow a small slack (40–48) to tolerate slightly different encodings.
_PUBKEY_MIN_B64 = 40
_PUBKEY_MAX_B64 = 64
_PUBKEY_RAW_LEN = 32


def validate_public_key_b64(value: Optional[str], *, field_name: str = "public_key") -> Optional[str]:
    """Validate a base64-encoded Ed25519/X25519 public key from a client.

    Returns the value unchanged on success; raises 400 on any failure.
    Pass `None`-tolerant — if the field is genuinely optional the caller
    can pass None and we skip validation.
    """
    if value is None:
        return None
    if not isinstance(value, str):
        raise HTTPException(status_code=400, detail=f"{field_name} must be a string")
    length = len(value)
    if length < _PUBKEY_MIN_B64 or length > _PUBKEY_MAX_B64:
        raise HTTPException(
            status_code=400,
            detail=f"{field_name} length out of range (got {length}, expected {_PUBKEY_MIN_B64}-{_PUBKEY_MAX_B64} base64 chars)",
        )
    try:
        raw = base64.b64decode(value, validate=True)
    except Exception:
        raise HTTPException(status_code=400, detail=f"{field_name} is not valid base64")
    if len(raw) != _PUBKEY_RAW_LEN:
        raise HTTPException(
            status_code=400,
            detail=f"{field_name} decodes to {len(raw)} bytes; Curve25519 keys are exactly {_PUBKEY_RAW_LEN}",
        )
    return value


# ==================== SCHEMAS ====================

class DeviceRegisterRequest(BaseModel):
    device_fingerprint: str
    public_key: str
    platform: Optional[str] = None  # ios/android
    device_name: Optional[str] = None


class DeviceResponse(BaseModel):
    id: str
    fingerprint: str
    platform: Optional[str]
    device_name: Optional[str]
    last_seen_at: datetime


class FriendFingerprintResponse(BaseModel):
    user_id: str
    username: str
    fingerprint: str
    avatar_path: Optional[str] = None


class FingerprintLookupResponse(BaseModel):
    user_id: str
    username: str
    avatar_path: Optional[str] = None
    is_friend: bool


# ==================== ENDPOINTS ====================

@router.post("/register", response_model=DeviceResponse)
async def register_device(
    request: DeviceRegisterRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Register device fingerprint with user account.
    
    Called on app startup when online. If fingerprint already registered
    for this user, updates last_seen_at. If registered for different user,
    returns error (key reuse attempt).
    """
    # 🔐 Validate the supplied public key BEFORE any DB work — prevents
    # storing 5MB blobs and prevents downstream crypto verifiers from
    # exploding at request time.
    validate_public_key_b64(request.public_key, field_name="public_key")

    # Cap fingerprint length too — it's just a hex hash of the pubkey,
    # 64 chars for SHA-256, but be generous.
    if not request.device_fingerprint or len(request.device_fingerprint) > 128:
        raise HTTPException(status_code=400, detail="Invalid device_fingerprint length")

    # Check if fingerprint already exists
    existing = db.query(Device).filter(
        Device.fingerprint == request.device_fingerprint
    ).first()
    
    if existing:
        if existing.user_id == current_user.id:
            # Same user, same device - update last seen
            existing.last_seen_at = datetime.utcnow()
            existing.platform = request.platform or existing.platform
            existing.device_name = request.device_name or existing.device_name
            db.commit()
            db.refresh(existing)
            return DeviceResponse(
                id=existing.id,
                fingerprint=existing.fingerprint,
                platform=existing.platform,
                device_name=existing.device_name,
                last_seen_at=existing.last_seen_at
            )
        else:
            # Different user trying to register same fingerprint - reject
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Device fingerprint already registered to another user"
            )
    
    # New device - register
    device = Device(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        fingerprint=request.device_fingerprint,
        public_key=request.public_key,
        platform=request.platform,
        device_name=request.device_name,
        last_seen_at=datetime.utcnow()
    )
    
    db.add(device)
    db.commit()
    db.refresh(device)
    
    print(f"✅ [Devices] Registered device {request.device_fingerprint[:16]}... for user {current_user.username}")
    
    return DeviceResponse(
        id=device.id,
        fingerprint=device.fingerprint,
        platform=device.platform,
        device_name=device.device_name,
        last_seen_at=device.last_seen_at
    )


@router.get("/friends", response_model=List[FriendFingerprintResponse])
async def get_friend_fingerprints(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get device fingerprints for all friends.
    
    Returns fingerprints of devices belonging to users who have
    accepted friend requests with the current user (bidirectional).
    Used by mesh to auto-connect with friends without prompts.
    """
    print(f"🔍 [Devices] get_friend_fingerprints called for user: {current_user.username} (id: {current_user.id})")
    
    # Get all accepted friendships (both directions)
    friendships = db.query(FriendRequest).filter(
        and_(
            FriendRequest.status == "accepted",
            or_(
                FriendRequest.requester_id == current_user.id,
                FriendRequest.recipient_id == current_user.id
            )
        )
    ).all()
    
    print(f"🔍 [Devices] Found {len(friendships)} accepted friendships")
    
    # Extract friend user IDs
    friend_ids = set()
    for fr in friendships:
        if fr.requester_id == current_user.id:
            friend_ids.add(fr.recipient_id)
            print(f"🔍 [Devices]   Friend: {fr.recipient_id}")
        else:
            friend_ids.add(fr.requester_id)
            print(f"🔍 [Devices]   Friend: {fr.requester_id}")
    
    if not friend_ids:
        print(f"⚠️ [Devices] No friend IDs found - returning empty list")
        return []
    
    print(f"🔍 [Devices] Looking up devices for {len(friend_ids)} friends")
    
    # Get devices for all friends (excluding revoked)
    devices = db.query(Device, User).join(User).filter(
        and_(
            Device.user_id.in_(friend_ids),
            Device.revoked == False
        )
    ).all()
    
    print(f"🔍 [Devices] Found {len(devices)} devices for friends")
    
    result = []
    for device, user in devices:
        print(f"🔍 [Devices]   Device: {device.fingerprint[:16]}... -> {user.username}")
        result.append(FriendFingerprintResponse(
            user_id=user.id,
            username=user.username or "Unknown",
            fingerprint=device.fingerprint,
            avatar_path=user.avatar_path
        ))
    
    print(f"📥 [Devices] Returning {len(result)} friend fingerprints for {current_user.username}")
    
    return result


@router.get("/lookup/{fingerprint}", response_model=FingerprintLookupResponse)
async def lookup_fingerprint(
    fingerprint: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Look up user info for a fingerprint.
    
    Used by Nearby People to show username for unknown mesh peers.
    Returns user info and whether they are already friends.
    """
    device = db.query(Device).filter(
        and_(
            Device.fingerprint == fingerprint,
            Device.revoked == False
        )
    ).first()
    
    if not device:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Device fingerprint not found"
        )
    
    user = db.query(User).filter(User.id == device.user_id).first()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    # Check if they are friends
    is_friend = db.query(FriendRequest).filter(
        and_(
            FriendRequest.status == "accepted",
            or_(
                and_(
                    FriendRequest.requester_id == current_user.id,
                    FriendRequest.recipient_id == user.id
                ),
                and_(
                    FriendRequest.requester_id == user.id,
                    FriendRequest.recipient_id == current_user.id
                )
            )
        )
    ).first() is not None
    
    return FingerprintLookupResponse(
        user_id=user.id,
        username=user.username or "Unknown",
        avatar_path=user.avatar_path,
        is_friend=is_friend
    )


@router.delete("/revoke/{fingerprint}")
async def revoke_device(
    fingerprint: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Revoke a device fingerprint (e.g., after device theft).
    
    Marks the device as revoked so it won't be returned in
    friend fingerprint lists. Cannot undo - device must re-register
    with a new key.
    """
    device = db.query(Device).filter(
        and_(
            Device.fingerprint == fingerprint,
            Device.user_id == current_user.id
        )
    ).first()
    
    if not device:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Device not found or not owned by you"
        )
    
    device.revoked = True
    db.commit()
    
    print(f"🗑 [Devices] Revoked device {fingerprint[:16]}... for user {current_user.username}")
    
    return {"message": "Device revoked successfully"}


@router.get("/my", response_model=List[DeviceResponse])
async def get_my_devices(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    List all devices registered to current user.
    """
    devices = db.query(Device).filter(
        and_(
            Device.user_id == current_user.id,
            Device.revoked == False
        )
    ).all()
    
    return [
        DeviceResponse(
            id=d.id,
            fingerprint=d.fingerprint,
            platform=d.platform,
            device_name=d.device_name,
            last_seen_at=d.last_seen_at
        )
        for d in devices
    ]
