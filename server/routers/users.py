from fastapi import APIRouter, Depends, HTTPException, status, Header, Request
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime

from database import get_db
from models import User, FriendRequest, ScreenshotNotification, Post, Follow
from auth import decode_token
from encryption import decrypt_text
from middleware.rate_limit import rate_limiter

router = APIRouter(prefix="/api/users", tags=["users"])

# Response models
class UserProfile(BaseModel):
    id: str
    username: str
    avatar_path: Optional[str]
    bio: Optional[str]
    # Badge flags — surfaced so the iOS render path can paint a verified
    # checkmark / premium ring directly off the search result. Without
    # these, official accounts (raven_news, raven_economic, …) showed up
    # un-badged in search and Discover even though `users.is_verified`
    # was true server-side.
    is_verified: Optional[bool] = False
    is_premium: Optional[bool] = False

    class Config:
        from_attributes = True

class FriendRequestResponse(BaseModel):
    id: str
    requester_id: str
    requester_username: str
    requester_avatar: Optional[str]
    recipient_id: str
    status: str
    created_at: datetime
    
    class Config:
        from_attributes = True

class ProfilePictureUpdate(BaseModel):
    image_url: str

class ProfileUpdate(BaseModel):
    """Request model for updating user profile fields."""
    display_name: Optional[str] = None  # firstName lastName combo
    username: Optional[str] = None  # Must be unique
    bio: Optional[str] = None
    birthday: Optional[datetime] = None  # Date of birth
    tags: Optional[List[str]] = None  # Tags/interests array
    phone: Optional[str] = None  # Phone number with country code

class ScreenshotNotificationResponse(BaseModel):
    id: str
    screenshotter_username: str
    screenshotter_avatar: Optional[str]
    timestamp: datetime
    is_read: bool
    
    class Config:
        from_attributes = True

class PushTokenRequest(BaseModel):
    """Request model for registering push notification token."""
    token: str
    platform: str = "ios"  # ios or android
    environment: Optional[str] = None  # "sandbox" or "production" (APNs endpoint)

# Dependency to get current user from JWT token
def get_current_user(authorization: str = Header(None), db: Session = Depends(get_db)) -> User:
    """Extract user from JWT token."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid authorization header"
        )
    
    token = authorization.replace("Bearer ", "")
    payload = decode_token(token)
    
    if not payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token"
        )
    
    user_id = payload.get("sub")
    user = db.query(User).filter(User.id == user_id).first()
    
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found"
        )
    
    return user


# ==================== USERNAME CHECK ====================

@router.get("/check-username/{username}")
def check_username_availability(
    username: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Check if a username is available.
    
    Returns: {"available": true/false}
    """
    # Normalize username
    username_lower = username.lower().strip()
    
    # If it's the user's current username, it's available
    if current_user.username and current_user.username.lower() == username_lower:
        return {"available": True}
    
    # Check if username exists
    existing = db.query(User).filter(
        User.username.ilike(username_lower)
    ).first()
    
    available = existing is None
    print(f"🔍 Username check: '{username}' - {'available' if available else 'taken'}")
    
    return {"available": available}


@router.get("/search", response_model=List[UserProfile])
def search_users(
    q: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Search users by username, bio, or tags/hobbies.
    
    - Case-insensitive partial match on username, bio, and hobbies
    - Excludes current user
    - Limit 10 results
    """
    from sqlalchemy import or_
    
    search_term = f"%{q}%"
    users = db.query(User).filter(
        User.id != current_user.id,
        or_(
            User.username.ilike(search_term),
            User.bio.ilike(search_term),
            User.hobbies.ilike(search_term)
        )
    ).limit(10).all()
    
    return [
        UserProfile(
            id=user.id,
            username=user.username,
            avatar_path=user.avatar_path,
            bio=user.bio,
            is_verified=user.is_verified or False,
            is_premium=user.is_premium or False,
        )
        for user in users
    ]


# ==================== SUGGESTED PROFILES ====================

@router.get("/suggestions")
def get_suggestions(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    contact_hashes: Optional[str] = None,  # Comma-separated phone hashes
    limit: int = 10
):
    """
    Get suggested profiles for Discover page.
    
    Returns up to 10 suggestions:
    - Up to 5 from user's contacts (matched via phone hash)
    - Rest filled with algorithmic suggestions (friends-of-friends, shared groups, shared interests)
    
    Each result includes source ("contact" or "suggested") and reason.
    """
    from sqlalchemy import or_, func, case, text
    from models import Friendship, Block, FriendRequest, GroupMember, UserInterest
    import json
    
    try:
        my_id = current_user.id
        
        # ── Step 1: Build exclusion set ──
        # My friends (bidirectional)
        friend_rows = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(FriendRequest.requester_id == my_id, FriendRequest.recipient_id == my_id)
        ).all()
        friend_ids = set()
        for f in friend_rows:
            friend_ids.add(f.recipient_id if f.requester_id == my_id else f.requester_id)
        
        # Blocked users (both directions)
        block_rows = db.query(Block).filter(
            or_(Block.blocker_id == my_id, Block.blocked_id == my_id)
        ).all()
        blocked_ids = set()
        for b in block_rows:
            blocked_ids.add(b.blocker_id)
            blocked_ids.add(b.blocked_id)
        
        # Pending friend requests (both directions)
        pending_rows = db.query(FriendRequest).filter(
            or_(FriendRequest.requester_id == my_id, FriendRequest.recipient_id == my_id),
            FriendRequest.status == "pending"
        ).all()
        pending_ids = set()
        for p in pending_rows:
            pending_ids.add(p.requester_id)
            pending_ids.add(p.recipient_id)
        
        excluded_ids = {my_id} | friend_ids | blocked_ids | pending_ids
        
        results = []
        contact_user_ids = set()  # Track contact matches to avoid duplicates
        
        # ── Step 2: Contact suggestions (up to 5) ──
        if contact_hashes:
            hash_list = [h.strip() for h in contact_hashes.split(",") if h.strip()]
            if hash_list:
                contact_users = db.query(User).filter(
                    User.phone_hash.in_(hash_list),
                    User.allow_contact_discovery == True,
                    User.id.notin_(excluded_ids),
                    User.status == 'active'
                ).limit(20).all()  # Fetch more than 5 to allow ranking
                
                # Rank by mutual friends count
                contact_scored = []
                for user in contact_users:
                    # Count mutual friends
                    user_friends = set()
                    user_friendships = db.query(FriendRequest).filter(
                        FriendRequest.status == "accepted",
                        or_(FriendRequest.requester_id == user.id, FriendRequest.recipient_id == user.id)
                    ).all()
                    for uf in user_friendships:
                        user_friends.add(uf.recipient_id if uf.requester_id == user.id else uf.requester_id)
                    
                    mutual_count = len(friend_ids & user_friends)
                    contact_scored.append((user, mutual_count))
                
                # Sort by mutual friends desc, then by last_login desc
                contact_scored.sort(key=lambda x: (x[1], x[0].last_login or datetime.min), reverse=True)
                
                for user, mutual_count in contact_scored[:5]:
                    contact_user_ids.add(user.id)
                    display_name = _build_display_name(user)
                    reason = f"{mutual_count} mutual friends" if mutual_count > 0 else "From your contacts"
                    results.append({
                        "id": user.id,
                        "username": user.username or "",
                        "display_name": display_name,
                        "avatar_path": user.avatar_path,
                        "bio": user.bio,
                        "source": "contact",
                        "reason": reason,
                        "mutual_friends_count": mutual_count,
                        "is_mutual": False,
                        "is_verified": user.is_verified or False,
                        "is_premium": user.is_premium or False,
                    })
        
        # ── Step 3: Algorithmic suggestions (fill to limit) ──
        remaining = limit - len(results)
        if remaining > 0:
            algo_excluded = excluded_ids | contact_user_ids
            candidates = {}  # user_id -> {score, sources, user}
            
            # Source 1: Friends-of-friends
            for fid in list(friend_ids)[:50]:  # Limit to 50 friends for performance
                fof_rows = db.query(FriendRequest).filter(
                    FriendRequest.status == "accepted",
                    or_(FriendRequest.requester_id == fid, FriendRequest.recipient_id == fid)
                ).all()
                for fof in fof_rows:
                    fof_id = fof.recipient_id if fof.requester_id == fid else fof.requester_id
                    if fof_id in algo_excluded:
                        continue
                    if fof_id not in candidates:
                        candidates[fof_id] = {"score": 0, "sources": set(), "mutual_count": 0}
                    candidates[fof_id]["score"] += 5  # 5 per mutual friend
                    candidates[fof_id]["mutual_count"] += 1
                    candidates[fof_id]["sources"].add("mutual")
            
            # Source 2: Shared groups
            my_group_ids = [gm.group_id for gm in db.query(GroupMember).filter(
                GroupMember.user_id == my_id
            ).all()]
            
            if my_group_ids:
                group_members = db.query(GroupMember).filter(
                    GroupMember.group_id.in_(my_group_ids),
                    GroupMember.user_id != my_id
                ).all()
                
                group_user_count = {}
                for gm in group_members:
                    if gm.user_id in algo_excluded:
                        continue
                    group_user_count[gm.user_id] = group_user_count.get(gm.user_id, 0) + 1
                
                for uid, count in group_user_count.items():
                    if uid not in candidates:
                        candidates[uid] = {"score": 0, "sources": set(), "mutual_count": 0}
                    candidates[uid]["score"] += 2 * count  # 2 per shared group
                    candidates[uid]["sources"].add("group")
            
            # Source 3: Shared interests
            my_interests = db.query(UserInterest).filter(
                UserInterest.user_id == my_id,
                UserInterest.score > 0
            ).order_by(UserInterest.score.desc()).limit(20).all()
            my_tags = [i.tag for i in my_interests]
            
            if my_tags:
                similar_users = db.query(
                    UserInterest.user_id,
                    func.count(UserInterest.tag).label("shared_count")
                ).filter(
                    UserInterest.tag.in_(my_tags),
                    UserInterest.user_id != my_id,
                    UserInterest.score > 0
                ).group_by(UserInterest.user_id).having(
                    func.count(UserInterest.tag) >= 1
                ).limit(50).all()
                
                for row in similar_users:
                    uid = row[0]
                    if uid in algo_excluded:
                        continue
                    if uid not in candidates:
                        candidates[uid] = {"score": 0, "sources": set(), "mutual_count": 0}
                    candidates[uid]["score"] += 1 * row[1]  # 1 per shared interest
                    candidates[uid]["sources"].add("interest")
            
            # Fetch user objects for candidates and apply recency boost
            if candidates:
                candidate_ids = list(candidates.keys())
                candidate_users = db.query(User).filter(
                    User.id.in_(candidate_ids),
                    User.status == 'active'
                ).all()
                
                candidate_map = {u.id: u for u in candidate_users}
                
                # Apply recency boost and build final list
                from datetime import timedelta
                seven_days_ago = datetime.utcnow() - timedelta(days=7)
                
                scored = []
                for uid, data in candidates.items():
                    user = candidate_map.get(uid)
                    if not user:
                        continue
                    
                    score = data["score"]
                    # Recency boost: +1 if active in last 7 days
                    if user.last_login and user.last_login > seven_days_ago:
                        score += 1
                    
                    scored.append((user, score, data["sources"], data["mutual_count"]))
                
                # Sort by score desc
                scored.sort(key=lambda x: x[1], reverse=True)
                
                # Diversity: max 3 from any single primary source
                source_counts = {"mutual": 0, "group": 0, "interest": 0}
                max_per_source = 3
                
                for user, score, sources, mutual_count in scored:
                    if len(results) >= limit:
                        break
                    
                    # Check diversity — primary source is first in sources set
                    primary = "mutual" if "mutual" in sources else ("group" if "group" in sources else "interest")
                    # Only enforce if we have enough candidates
                    if source_counts.get(primary, 0) >= max_per_source and len(scored) > remaining:
                        continue
                    
                    source_counts[primary] = source_counts.get(primary, 0) + 1
                    
                    display_name = _build_display_name(user)
                    if mutual_count > 0:
                        reason = f"{mutual_count} mutual friends"
                    elif "group" in sources:
                        reason = "From a shared group"
                    elif "interest" in sources:
                        reason = "Similar interests"
                    else:
                        reason = "Suggested for you"
                    
                    results.append({
                        "id": user.id,
                        "username": user.username or "",
                        "display_name": display_name,
                        "avatar_path": user.avatar_path,
                        "bio": user.bio,
                        "source": "suggested",
                        "reason": reason,
                        "mutual_friends_count": mutual_count,
                        "is_mutual": False,
                        "is_verified": user.is_verified or False,
                        "is_premium": user.is_premium or False,
                    })
        
        # ── Step 4: Fallback — if still not enough, add random active users ──
        if len(results) < limit:
            fallback_excluded = excluded_ids | contact_user_ids | {r["id"] for r in results}
            fallback_users = db.query(User).filter(
                User.id.notin_(fallback_excluded),
                User.status == 'active',
                User.username.isnot(None)
            ).order_by(func.random()).limit(limit - len(results)).all()
            
            for user in fallback_users:
                display_name = _build_display_name(user)
                results.append({
                    "id": user.id,
                    "username": user.username or "",
                    "display_name": display_name,
                    "avatar_path": user.avatar_path,
                    "bio": user.bio,
                    "source": "suggested",
                    "reason": "Suggested for you",
                    "mutual_friends_count": 0,
                    "is_mutual": False,
                    "is_verified": user.is_verified or False,
                    "is_premium": user.is_premium or False,
                })
        
        print(f"👥 Suggestions for {current_user.username}: {len(results)} results "
              f"({sum(1 for r in results if r['source'] == 'contact')} contacts, "
              f"{sum(1 for r in results if r['source'] == 'suggested')} suggested)")
        
        return results
        
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"❌ Suggestions error: {e}")
        raise HTTPException(status_code=500, detail="Failed to get suggestions")


def _build_display_name(user: User) -> str:
    """Build display name from user's first/last name fields."""
    from encryption import decrypt_text
    first = ""
    last = ""
    try:
        if user.first_name:
            first = decrypt_text(user.first_name) or ""
            if first == "[DECRYPT_FAILED]":
                first = ""
        if user.last_name:
            last = decrypt_text(user.last_name) or ""
            if last == "[DECRYPT_FAILED]":
                last = ""
    except:
        pass
    display_name = f"{first} {last}".strip()
    return display_name if display_name else (user.username or "Unknown")


@router.get("/me")
def get_current_user_profile(current_user: User = Depends(get_current_user)):
    """Get current user's own profile with all fields needed for auth gate."""
    import json
    return {
        "id": current_user.id,
        "username": current_user.username,
        "email": decrypt_text(current_user.email) if current_user.email else None,
        "phone": decrypt_text(current_user.phone) if current_user.phone else None,
        "firstName": decrypt_text(current_user.first_name) if current_user.first_name else None,
        "lastName": decrypt_text(current_user.last_name) if current_user.last_name else None,
        "avatarPath": current_user.avatar_path,
        "bio": current_user.bio,
        "birthday": current_user.birthday.isoformat() if hasattr(current_user, 'birthday') and current_user.birthday else None,
        # Parse hobbies from JSON string to array
        "tags": json.loads(current_user.hobbies) if current_user.hobbies else [],
        "publicKey": current_user.public_key,
        # ✅ Use proper ISO8601 format with Z suffix for Swift compatibility
        "createdAt": current_user.created_at.strftime("%Y-%m-%dT%H:%M:%S.%fZ") if current_user.created_at else None,
        "emailVerified": current_user.email_verified or False,
        "phoneVerified": current_user.phone_verified or False,
        "isVerified": current_user.is_verified or False,
        "isPremium": current_user.is_premium or False,
        # Determine auth method from OAuth provider
        "authMethod": current_user.oauth_provider if current_user.oauth_provider else "password"
    }

class IdentityKeyRequest(BaseModel):
    """Body for `POST /api/users/me/identity-key`. Used by iOS native to
    upload its Curve25519 / Ed25519 raw public key (32 bytes, ~44 chars
    base64). Idempotent — overwriting an existing key with the same value
    is a no-op."""
    publicKey: str


@router.post("/me/identity-key")
def set_identity_key(
    body: IdentityKeyRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Register the user's signing public key on the server.

    iOS native generates an Ed25519 keypair via `DeviceIdentityService`
    and uploads the raw 32-byte public key (base64) here. Used by
    `qr-login` and any future server-side signature verification (mesh
    bridge attestations, key rotation chains, etc.).

    Validation: must be 40–64 base64 chars (covers both raw Ed25519
    and X25519). Larger PEM-encoded RSA keys are accepted only via
    the legacy registration path; new code paths use this endpoint.
    """
    raw = (body.publicKey or "").strip()
    length = len(raw)
    if length < 40 or length > 64:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"publicKey length out of range (got {length}, expected 40-64 base64 chars)",
        )
    # Reject obvious garbage early — the qr-login verifier will fail
    # cleanly if base64 doesn't decode to 32 bytes, but failing here
    # gives the client a clearer 400 vs a later 401.
    try:
        import base64 as _b64
        decoded = _b64.b64decode(raw, validate=True)
        if len(decoded) != 32:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"publicKey decodes to {len(decoded)} bytes, expected 32 (raw Ed25519)",
            )
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="publicKey is not valid base64",
        )

    if current_user.public_key == raw:
        return {"status": "unchanged"}
    current_user.public_key = raw
    db.commit()
    return {"status": "ok"}


@router.patch("/me")
def update_current_user_profile(
    update: ProfileUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Update current user's profile.

    - **display_name**: Full name (will be split into first/last)
    - **username**: Must be unique
    - **bio**: User's bio text
    - **birthday**: Date of birth
    - **tags**: List of interest tags
    """
    import json
    from encryption import encrypt_text
    
    # Handle display_name (split into first/last)
    if update.display_name is not None:
        parts = update.display_name.strip().split(" ", 1)
        first_name = parts[0] if parts else ""
        last_name = parts[1] if len(parts) > 1 else ""
        current_user.first_name = encrypt_text(first_name) if first_name else None
        current_user.last_name = encrypt_text(last_name) if last_name else None
    
    # Handle username (check uniqueness)
    if update.username is not None:
        username_lower = update.username.lower().strip()
        # Check if different from current and if taken
        if current_user.username is None or current_user.username.lower() != username_lower:
            existing = db.query(User).filter(
                User.username.ilike(username_lower),
                User.id != current_user.id
            ).first()
            if existing:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Username already taken"
                )
        current_user.username = update.username.strip()
    
    # Debug log for bio updates
    print(f"📝 Bio update request - received: '{update.bio}', current: '{current_user.bio}'")
    
    if update.bio is not None:
        current_user.bio = update.bio
        print(f"📝 Bio set to: '{current_user.bio}'")
    
    # Handle birthday (if column exists)
    if update.birthday is not None:
        if hasattr(current_user, 'birthday'):
            current_user.birthday = update.birthday
            
    if update.tags is not None:
        # Store as JSON array
        current_user.hobbies = json.dumps(update.tags)
    
    # Handle phone number (encrypt before storing)
    if update.phone is not None:
        if update.phone.strip():  # Non-empty phone
            current_user.phone = encrypt_text(update.phone.strip())
            print(f"📱 Phone updated for {current_user.username}")
        else:  # Empty phone - clear it
            current_user.phone = None
    
    db.commit()
    db.refresh(current_user)
    
    # Parse hobbies back to list for response
    hobbies_list = []
    if current_user.hobbies:
        try:
            hobbies_list = json.loads(current_user.hobbies)
        except:
            hobbies_list = [h.strip() for h in current_user.hobbies.split(",") if h.strip()]
    
    print(f"✅ {current_user.username} updated profile")
    
    # Return full user object for Swift to update
    return {
        "id": current_user.id,
        "username": current_user.username,
        "email": decrypt_text(current_user.email) if current_user.email else None,
        "phone": decrypt_text(current_user.phone) if current_user.phone else None,
        "firstName": decrypt_text(current_user.first_name) if current_user.first_name else None,
        "lastName": decrypt_text(current_user.last_name) if current_user.last_name else None,
        "avatarPath": current_user.avatar_path,
        "bio": current_user.bio,
        "birthday": current_user.birthday.isoformat() if hasattr(current_user, 'birthday') and current_user.birthday else None,
        "tags": hobbies_list,
        "publicKey": current_user.public_key,
        "createdAt": current_user.created_at.strftime("%Y-%m-%dT%H:%M:%S.%fZ") if current_user.created_at else None,
        "emailVerified": current_user.email_verified or False,
        "phoneVerified": current_user.phone_verified or False,
        "authMethod": current_user.oauth_provider if current_user.oauth_provider else "password"
    }


@router.delete("/me")
def close_account(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Permanently delete current user's account and all associated data.
    
    This is an IRREVERSIBLE action that deletes:
    - All posts, comments, and likes
    - All messages (sent and received)
    - All friend requests
    - All notifications
    - All devices and push tokens
    - The user account itself
    """
    from models import (
        Post, Comment, CommentVote, PostLike, Repost, PostView,
        Message, FriendRequest, ScreenshotNotification, Notification,
        Device, GroupMember, Block, Report, RoomVisibility,
        Backup, MediaObject, SyncQueue, PostSubscription, UserNotificationSubscription,
        UserEvent, UserInterest, SeenPost, HashtagFollow, UserNegativeFeedback,
        VerificationToken, RefreshToken, VoiceMessage, SnapMessage
    )
    
    user_id = current_user.id
    username = current_user.username
    
    try:
        # Delete user's posts and related data
        user_posts = db.query(Post).filter(Post.author_id == user_id).all()
        for post in user_posts:
            db.query(PostLike).filter(PostLike.post_id == post.id).delete()
            db.query(Repost).filter(Repost.original_post_id == post.id).delete()
            db.query(PostView).filter(PostView.post_id == post.id).delete()
            db.query(Comment).filter(Comment.post_id == post.id).delete()
        db.query(Post).filter(Post.author_id == user_id).delete()
        
        # Delete user's comments and votes on other posts
        db.query(CommentVote).filter(CommentVote.user_id == user_id).delete()
        db.query(Comment).filter(Comment.author_id == user_id).delete()
        
        # Delete user's likes and reposts
        db.query(PostLike).filter(PostLike.user_id == user_id).delete()
        db.query(Repost).filter(Repost.user_id == user_id).delete()
        
        # Delete messages (sent and received)
        db.query(Message).filter(
            (Message.sender_id == user_id) | (Message.recipient_id == user_id)
        ).delete(synchronize_session=False)
        
        # Delete voice messages and snap messages
        db.query(VoiceMessage).filter(
            (VoiceMessage.sender_id == user_id) | (VoiceMessage.recipient_id == user_id)
        ).delete(synchronize_session=False)
        db.query(SnapMessage).filter(
            (SnapMessage.sender_id == user_id) | (SnapMessage.recipient_id == user_id)
        ).delete(synchronize_session=False)
        
        # Delete friend requests (both sent and received)
        db.query(FriendRequest).filter(
            (FriendRequest.requester_id == user_id) | (FriendRequest.recipient_id == user_id)
        ).delete(synchronize_session=False)
        
        # Delete follow records (both directions)
        db.query(Follow).filter(
            (Follow.follower_id == user_id) | (Follow.following_id == user_id)
        ).delete(synchronize_session=False)
        
        # Delete notifications
        db.query(Notification).filter(Notification.user_id == user_id).delete()
        db.query(ScreenshotNotification).filter(
            (ScreenshotNotification.profile_owner_id == user_id) | 
            (ScreenshotNotification.screenshotter_id == user_id)
        ).delete(synchronize_session=False)
        
        # Delete group memberships
        db.query(GroupMember).filter(GroupMember.user_id == user_id).delete()
        
        # Delete blocks (both directions)
        db.query(Block).filter(
            (Block.blocker_id == user_id) | (Block.blocked_id == user_id)
        ).delete(synchronize_session=False)
        
        # Delete reports made by user
        db.query(Report).filter(Report.reporter_id == user_id).delete()
        
        # Delete room visibility records
        db.query(RoomVisibility).filter(RoomVisibility.user_id == user_id).delete()
        
        # Delete devices and tokens
        db.query(Device).filter(Device.user_id == user_id).delete()
        db.query(VerificationToken).filter(VerificationToken.user_id == user_id).delete()
        db.query(RefreshToken).filter(RefreshToken.user_id == user_id).delete()
        
        # Delete backup and sync data
        db.query(Backup).filter(Backup.user_id == user_id).delete()
        db.query(MediaObject).filter(MediaObject.owner_id == user_id).delete()
        db.query(SyncQueue).filter(SyncQueue.user_id == user_id).delete()
        
        # Delete subscription data
        db.query(PostSubscription).filter(
            (PostSubscription.subscriber_id == user_id) | (PostSubscription.target_id == user_id)
        ).delete(synchronize_session=False)
        
        # Delete bell notification subscriptions
        db.query(UserNotificationSubscription).filter(
            (UserNotificationSubscription.subscriber_id == user_id) | (UserNotificationSubscription.target_id == user_id)
        ).delete(synchronize_session=False)
        
        # Delete recommendation data
        db.query(UserEvent).filter(UserEvent.user_id == user_id).delete()
        db.query(UserInterest).filter(UserInterest.user_id == user_id).delete()
        db.query(SeenPost).filter(SeenPost.user_id == user_id).delete()
        db.query(HashtagFollow).filter(HashtagFollow.user_id == user_id).delete()
        db.query(UserNegativeFeedback).filter(UserNegativeFeedback.user_id == user_id).delete()
        
        # Finally delete the user
        db.delete(current_user)
        db.commit()
        
        print(f"🗑️ Account closed: {username} ({user_id})")
        
        return {"success": True, "message": "Account permanently deleted"}
        
    except Exception as e:
        db.rollback()
        print(f"❌ Failed to close account for {username}: {str(e)}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to delete account: {str(e)}"
        )


# Alternative POST endpoint for close account (some platforms block DELETE)
@router.post("/me/close")
def close_account_post(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Alternative POST endpoint for closing account (for platforms that block DELETE)."""
    return close_account(current_user=current_user, db=db)


# ==================== PUSH NOTIFICATIONS ====================

@router.post("/push-token")
def register_push_token(
    req: PushTokenRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Register or update push notification token for current user.
    
    - **token**: APNs device token (iOS) or FCM token (Android)
    - **platform**: "ios" or "android"
    - **environment**: "sandbox" (Xcode/TestFlight) or "production" (App Store)
    """
    current_user.push_token = req.token
    current_user.push_platform = req.platform
    current_user.push_environment = req.environment  # sandbox or production
    db.commit()
    
    env_label = f", env={req.environment}" if req.environment else ""
    print(f"📱 Push token registered for {current_user.username} ({req.platform}{env_label}): {req.token[:16]}...")
    
    return {"success": True, "message": "Push token registered"}


@router.get("/push-debug")
async def debug_push_status(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Debug endpoint: Check push notification readiness for current user.
    Returns token status, APNs configuration, and optionally sends a test push.
    """
    from services.apns_service import get_apns_service
    import os
    
    # 1. Check user's push token
    token = getattr(current_user, 'push_token', None)
    platform = getattr(current_user, 'push_platform', None)
    push_enabled = getattr(current_user, 'push_enabled', True)
    msg_notif = getattr(current_user, 'message_notifications_enabled', True)
    
    # 2. Check APNs service config
    apns = get_apns_service()
    
    result = {
        "user_id": current_user.id,
        "username": current_user.username,
        "push_token": f"{token[:16]}...{token[-8:]}" if token else None,
        "push_token_length": len(token) if token else 0,
        "push_platform": platform,
        "push_enabled": push_enabled,
        "message_notifications_enabled": msg_notif,
        "apns_configured": apns.is_configured,
        "apns_bundle_id": apns.bundle_id,
        "apns_use_sandbox": apns.use_sandbox,
        "apns_key_id": apns.key_id,
        "apns_team_id": apns.team_id,
        "apns_key_loaded": apns._private_key is not None,
        "apns_key_path": apns.key_path,
        "apns_key_file_exists": os.path.exists(apns.key_path) if apns.key_path else False,
    }
    
    # 3. Send test push if token exists
    if token and platform == "ios" and apns.is_configured:
        try:
            test_result = await apns.send_push(
                device_token=token,
                title="🧪 Push Test",
                body="If you see this, push notifications are working!",
                data={"type": "push_test"}
            )
            result["test_push_sent"] = test_result
            result["test_push_status"] = "SUCCESS" if test_result else "FAILED (check server logs for APNs error)"
        except Exception as e:
            result["test_push_sent"] = False
            result["test_push_error"] = str(e)
    else:
        reasons = []
        if not token:
            reasons.append("no push_token stored")
        if platform != "ios":
            reasons.append(f"platform is '{platform}' not 'ios'")
        if not apns.is_configured:
            reasons.append("APNs service not configured")
        result["test_push_sent"] = False
        result["test_push_skip_reason"] = ", ".join(reasons)
    
    return result

@router.delete("/push-token")
def unregister_push_token(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Remove push notification token (for logout)."""
    current_user.push_token = None
    current_user.push_platform = None
    db.commit()
    
    print(f"📱 Push token removed for {current_user.username}")
    
    return {"success": True, "message": "Push token removed"}

# ==================== NOTIFICATION & PRIVACY SETTINGS ====================


class NotificationPreferencesUpdate(BaseModel):
    """Request model for updating notification preferences."""
    push_enabled: Optional[bool] = None
    messages_enabled: Optional[bool] = None
    friend_requests_enabled: Optional[bool] = None
    likes_comments_enabled: Optional[bool] = None
    sounds_enabled: Optional[bool] = None
    message_preview: Optional[bool] = None
    new_post_notifications: Optional[bool] = None
    audio_room_notifications: Optional[bool] = None
    mention_notifications: Optional[bool] = None
    # ── Added 2026-05-14 — match iOS NotificationsSettingsView ──
    security_alert_notifications: Optional[bool] = None
    live_location_notifications: Optional[bool] = None
    reaction_notifications: Optional[bool] = None
    contact_shared_notifications: Optional[bool] = None
    profile_view_notifications: Optional[bool] = None
    screenshot_notifications: Optional[bool] = None


class PrivacySettingsUpdate(BaseModel):
    """Request model for updating privacy settings."""
    show_online_status: Optional[bool] = None
    read_receipts: Optional[bool] = None
    who_can_message: Optional[str] = None
    who_can_see_profile: Optional[str] = None
    show_liked_posts: Optional[bool] = None
    show_replies: Optional[bool] = None
    # ── Added 2026-05-14 ──
    # Cross-feature gate read by the contact-card share flow.
    allow_contact_share: Optional[bool] = None


@router.patch("/notification-preferences")
def update_notification_preferences(
    update: NotificationPreferencesUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Update notification preferences (server-side enforcement).
    
    All fields are optional — only provided fields are updated.
    These preferences are checked before every push notification.
    """
    if update.push_enabled is not None:
        current_user.push_enabled = update.push_enabled
    if update.messages_enabled is not None:
        current_user.message_notifications_enabled = update.messages_enabled
    if update.friend_requests_enabled is not None:
        current_user.friend_request_notifications_enabled = update.friend_requests_enabled
    if update.likes_comments_enabled is not None:
        current_user.likes_comments_notifications_enabled = update.likes_comments_enabled
    if update.sounds_enabled is not None:
        current_user.sounds_enabled = update.sounds_enabled
    if update.message_preview is not None:
        current_user.message_preview_enabled = update.message_preview
    if update.new_post_notifications is not None:
        current_user.new_post_notifications_enabled = update.new_post_notifications
    if update.audio_room_notifications is not None:
        current_user.audio_room_notifications_enabled = update.audio_room_notifications
    if update.mention_notifications is not None:
        current_user.mention_notifications_enabled = update.mention_notifications
    # ── Privacy & Safety (added 2026-05-14) ──────────────────────────
    if update.security_alert_notifications is not None:
        current_user.security_alert_notifications_enabled = update.security_alert_notifications
    if update.live_location_notifications is not None:
        current_user.live_location_notifications_enabled = update.live_location_notifications
    if update.reaction_notifications is not None:
        current_user.reaction_notifications_enabled = update.reaction_notifications
    if update.contact_shared_notifications is not None:
        current_user.contact_shared_notifications_enabled = update.contact_shared_notifications
    if update.profile_view_notifications is not None:
        current_user.profile_view_notifications_enabled = update.profile_view_notifications
    if update.screenshot_notifications is not None:
        current_user.screenshot_notifications_enabled = update.screenshot_notifications

    db.commit()

    print(f"⚙️ Notification preferences updated for {current_user.username}: "
          f"push={current_user.push_enabled}, msg={current_user.message_notifications_enabled}, "
          f"friends={current_user.friend_request_notifications_enabled}, "
          f"likes={current_user.likes_comments_notifications_enabled}, "
          f"sounds={current_user.sounds_enabled}, preview={current_user.message_preview_enabled}, "
          f"posts={current_user.new_post_notifications_enabled}, "
          f"rooms={current_user.audio_room_notifications_enabled}, "
          f"mentions={current_user.mention_notifications_enabled}")
    
    return {"success": True, "message": "Notification preferences updated"}


@router.patch("/privacy")
def update_privacy_settings(
    update: PrivacySettingsUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Update privacy settings (server-side enforcement).
    
    All fields are optional — only provided fields are updated.
    Privacy settings are enforced at API level (not just client).
    """
    if update.show_online_status is not None:
        current_user.show_online_status = update.show_online_status
    if update.read_receipts is not None:
        current_user.read_receipts_enabled = update.read_receipts
    if update.who_can_message is not None:
        if update.who_can_message not in ("everyone", "friends"):
            raise HTTPException(status_code=400, detail="who_can_message must be 'everyone' or 'friends'")
        current_user.who_can_message = update.who_can_message
    if update.who_can_see_profile is not None:
        if update.who_can_see_profile not in ("public", "friends"):
            raise HTTPException(status_code=400, detail="who_can_see_profile must be 'public' or 'friends'")
        current_user.who_can_see_profile = update.who_can_see_profile
        # Sync with existing is_private field
        current_user.is_private = (update.who_can_see_profile == "friends")
    if update.show_liked_posts is not None:
        current_user.show_liked_posts = update.show_liked_posts
    if update.show_replies is not None:
        current_user.show_replies = update.show_replies
    if update.allow_contact_share is not None:
        current_user.allow_contact_share = update.allow_contact_share

    db.commit()

    print(f"🔒 Privacy settings updated for {current_user.username}: "
          f"online={current_user.show_online_status}, receipts={current_user.read_receipts_enabled}, "
          f"msg_access={current_user.who_can_message}, profile={current_user.who_can_see_profile}, "
          f"show_likes={current_user.show_liked_posts}, show_replies={current_user.show_replies}")
    
    return {"success": True, "message": "Privacy settings updated"}


# ==================== CHANGE PASSWORD ====================

class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str

@router.post("/change-password")
def change_password(
    req: ChangePasswordRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Change the current user's password.
    
    Requires the current password for verification.
    New password must be at least 8 characters.
    OAuth-only users cannot change password (they don't have one).
    """
    from auth import verify_password, hash_password
    
    # OAuth-only users don't have a password
    if not current_user.password_hash:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cannot change password for OAuth accounts. Use your Google/Apple login."
        )
    
    # Verify current password
    if not verify_password(req.current_password, current_user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Current password is incorrect"
        )
    
    # Validate new password
    if len(req.new_password) < 8:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="New password must be at least 8 characters"
        )
    
    if req.current_password == req.new_password:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="New password must be different from current password"
        )
    
    # Update password hash
    current_user.password_hash = hash_password(req.new_password)
    db.commit()
    
    print(f"🔑 Password changed for user: {current_user.username}")
    
    return {"success": True, "message": "Password changed successfully"}


# ==================== TWO-FACTOR AUTHENTICATION ====================

class TwoFactorVerifyRequest(BaseModel):
    code: str

@router.post("/2fa/setup")
def setup_2fa(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Generate a 2FA secret and provisioning URI for QR code setup.
    
    Returns the secret and a URI that authenticator apps can scan.
    The user must call /2fa/verify with a valid code to actually enable 2FA.
    """
    import pyotp
    import secrets
    
    # Generate a new TOTP secret
    secret = pyotp.random_base32()
    
    # Store the secret temporarily (not yet verified)
    # We store it in the user record but keep 2FA disabled until verified
    current_user.totp_secret = secret
    db.commit()
    
    # Generate provisioning URI for QR code
    totp = pyotp.TOTP(secret)
    provisioning_uri = totp.provisioning_uri(
        name=current_user.username,
        issuer_name="RAVEN"
    )
    
    # Generate recovery codes
    recovery_codes = [secrets.token_hex(4).upper() for _ in range(8)]
    
    # Format the secret for manual entry (groups of 4)
    formatted_secret = "-".join(
        secret[i:i+4] for i in range(0, len(secret), 4)
    )
    
    print(f"🔐 2FA setup initiated for user: {current_user.username}")
    
    return {
        "secret": formatted_secret,
        "provisioning_uri": provisioning_uri,
        "recovery_codes": recovery_codes
    }

@router.post("/2fa/verify")
def verify_2fa(
    req: TwoFactorVerifyRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Verify a TOTP code and enable 2FA for the user.
    
    Must be called after /2fa/setup with a valid 6-digit code from the authenticator app.
    """
    import pyotp
    
    secret = getattr(current_user, 'totp_secret', None)
    if not secret:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="2FA setup not initiated. Call /2fa/setup first."
        )
    
    # Verify the code (with 1 window of tolerance for clock skew)
    totp = pyotp.TOTP(secret)
    if not totp.verify(req.code, valid_window=1):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid verification code. Please check your authenticator app."
        )
    
    # Enable 2FA
    current_user.two_factor_enabled = True
    db.commit()
    
    print(f"✅ 2FA enabled for user: {current_user.username}")
    
    return {"success": True, "message": "Two-factor authentication enabled successfully"}

@router.post("/2fa/disable")
def disable_2fa(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Disable 2FA for the current user.
    Clears the TOTP secret.
    """
    current_user.two_factor_enabled = False
    current_user.totp_secret = None
    db.commit()
    
    print(f"⚠️ 2FA disabled for user: {current_user.username}")
    
    return {"success": True, "message": "Two-factor authentication disabled"}


# ==================== ACTIVE SESSIONS ====================

@router.get("/sessions")
def get_active_sessions(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    List all active sessions (refresh tokens) for the current user.
    
    Returns device info, platform, location, and last active time.
    The current session is marked with is_current=True.
    """
    from models import RefreshToken
    
    # Get all active (non-revoked, non-expired) refresh tokens for this user
    tokens = db.query(RefreshToken).filter(
        RefreshToken.user_id == current_user.id,
        RefreshToken.revoked_at == None,
        RefreshToken.expires_at > datetime.utcnow()
    ).order_by(RefreshToken.created_at.desc()).all()
    
    sessions = []
    for token in tokens:
        sessions.append({
            "id": token.id,
            "device_name": token.device_name or "Unknown Device",
            "location": "Unknown Location",
            "last_active": token.created_at.isoformat() if token.created_at else datetime.utcnow().isoformat(),
            "is_current": False,
            "platform": "iOS"
        })
    
    # If no tokens found, return at least the current session
    if not sessions:
        sessions.append({
            "id": "current",
            "device_name": "This Device",
            "location": "Current Session",
            "last_active": datetime.utcnow().isoformat(),
            "is_current": True,
            "platform": "iOS"
        })
    else:
        # Mark the most recent session as current
        sessions[0]["is_current"] = True
    
    return sessions

# NOTE: /sessions/all MUST come before /sessions/{session_id}
# otherwise FastAPI matches "all" as a session_id parameter.
@router.delete("/sessions/all")
def revoke_all_other_sessions(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Revoke all sessions except the current one."""
    from models import RefreshToken
    
    # Revoke all active refresh tokens for this user
    tokens = db.query(RefreshToken).filter(
        RefreshToken.user_id == current_user.id,
        RefreshToken.revoked_at == None
    ).all()
    
    revoked_count = 0
    for token in tokens:
        token.revoked_at = datetime.utcnow()
        revoked_count += 1
    
    db.commit()
    
    print(f"🔒 Revoked {revoked_count} sessions for user {current_user.username}")
    
    return {"success": True, "message": f"Revoked {revoked_count} sessions"}

@router.delete("/sessions/{session_id}")
def revoke_session(
    session_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Revoke a specific session (refresh token)."""
    from models import RefreshToken
    
    token = db.query(RefreshToken).filter(
        RefreshToken.id == session_id,
        RefreshToken.user_id == current_user.id
    ).first()
    
    if not token:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Session not found"
        )
    
    token.revoked_at = datetime.utcnow()
    db.commit()
    
    print(f"🔒 Session revoked for user {current_user.username}: {session_id}")
    
    return {"success": True, "message": "Session revoked"}


@router.get("/me/settings")
def get_user_settings(
    current_user: User = Depends(get_current_user)
):
    """
    Get all notification + privacy settings for the current user.
    
    Called on app launch to hydrate iOS @AppStorage from server.
    Ensures settings persist across reinstalls/device changes.
    """
    return {
        "notification": {
            "push_enabled": current_user.push_enabled if current_user.push_enabled is not None else True,
            "messages_enabled": current_user.message_notifications_enabled if current_user.message_notifications_enabled is not None else True,
            "friend_requests_enabled": current_user.friend_request_notifications_enabled if current_user.friend_request_notifications_enabled is not None else True,
            "likes_comments_enabled": current_user.likes_comments_notifications_enabled if current_user.likes_comments_notifications_enabled is not None else True,
            "sounds_enabled": current_user.sounds_enabled if current_user.sounds_enabled is not None else True,
            "message_preview": current_user.message_preview_enabled if current_user.message_preview_enabled is not None else True,
            "new_post_notifications": current_user.new_post_notifications_enabled if current_user.new_post_notifications_enabled is not None else True,
            "audio_room_notifications": current_user.audio_room_notifications_enabled if current_user.audio_room_notifications_enabled is not None else True,
            "mention_notifications": current_user.mention_notifications_enabled if current_user.mention_notifications_enabled is not None else True,
        },
        "privacy": {
            "show_online_status": current_user.show_online_status if current_user.show_online_status is not None else True,
            "read_receipts": current_user.read_receipts_enabled if current_user.read_receipts_enabled is not None else True,
            "who_can_message": current_user.who_can_message or "everyone",
            "who_can_see_profile": current_user.who_can_see_profile or "public",
            "show_liked_posts": current_user.show_liked_posts if current_user.show_liked_posts is not None else True,
            "show_replies": current_user.show_replies if current_user.show_replies is not None else True,
        }
    }


# ==================== FOLLOW SYSTEM (Instagram-style) ====================


@router.post("/follow/{target_id}")
async def follow_user(
    target_id: str,
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Follow a user. If target is private, creates a follow request instead."""
    from sqlalchemy import or_, and_
    
    if target_id == current_user.id:
        raise HTTPException(status_code=400, detail="Cannot follow yourself")
    
    # Rate limit
    rate_limiter.check_rate_limit(
        identifier=f"follow:{current_user.id}",
        max_attempts=30,
        window_minutes=60,
        lockout_minutes=30
    )
    
    # Check target exists
    target = db.query(User).filter(User.id == target_id).first()
    if not target:
        raise HTTPException(status_code=404, detail="User not found")
    
    # Check if already following
    existing_follow = db.query(Follow).filter(
        Follow.follower_id == current_user.id,
        Follow.following_id == target_id
    ).first()
    if existing_follow:
        raise HTTPException(status_code=400, detail="Already following this user")
    
    # Check if target is private
    is_private = getattr(target, 'is_private', False)
    
    if is_private:
        # Check for existing pending request
        existing_request = db.query(FriendRequest).filter(
            FriendRequest.requester_id == current_user.id,
            FriendRequest.recipient_id == target_id,
            FriendRequest.status == "pending"
        ).first()
        
        if existing_request:
            raise HTTPException(status_code=400, detail="Follow request already sent")
        
        # Create follow request (reuse FriendRequest table)
        follow_request = FriendRequest(
            requester_id=current_user.id,
            recipient_id=target_id,
            status="pending"
        )
        db.add(follow_request)
        db.commit()
        db.refresh(follow_request)
        
        # Send push notification
        if target.push_token and target.push_platform == "ios":
            from services.apns_service import get_apns_service, APNsService
            prefs = APNsService.should_send_push(target, "friend_request")
            if prefs["allowed"]:
                apns = get_apns_service()
                requester_name = APNsService.build_push_display_name(current_user)
                badge = APNsService.get_unread_badge_count(db, target.id)
                push_result = await apns.send_friend_request_notification(
                    device_token=target.push_token,
                    requester_name=requester_name,
                    requester_id=current_user.id,
                    badge=badge
                )
                if push_result:
                    print(f"📱 ✅ Follow request push sent to {target.username}")
        
        print(f"📤 Follow request sent: {current_user.username} → {target.username} (private)")
        return {
            "status": "requested",
            "request_id": follow_request.id,
            "message": "Follow request sent"
        }
    else:
        # Public account — instant follow
        follow = Follow(
            follower_id=current_user.id,
            following_id=target_id
        )
        db.add(follow)
        db.commit()
        
        # Check if mutual follow (they already follow us)
        reverse_follow = db.query(Follow).filter(
            Follow.follower_id == target_id,
            Follow.following_id == current_user.id
        ).first()
        
        follow_status = "mutual" if reverse_follow else "following"
        
        print(f"✅ {current_user.username} followed {target.username} (status={follow_status})")
        return {
            "status": follow_status,
            "message": f"Now following {target.username}"
        }


@router.delete("/follow/{target_id}")
async def unfollow_user(
    target_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Unfollow a user or cancel a pending follow request."""
    # Try to remove follow record
    follow = db.query(Follow).filter(
        Follow.follower_id == current_user.id,
        Follow.following_id == target_id
    ).first()
    
    if follow:
        db.delete(follow)
        db.commit()
        print(f"🗑️ {current_user.username} unfollowed {target_id}")
        return {"status": "none", "message": "Unfollowed"}
    
    # Maybe it's a pending request — cancel it
    pending = db.query(FriendRequest).filter(
        FriendRequest.requester_id == current_user.id,
        FriendRequest.recipient_id == target_id,
        FriendRequest.status == "pending"
    ).first()
    
    if pending:
        db.delete(pending)
        db.commit()
        print(f"🗑️ {current_user.username} cancelled follow request to {target_id}")
        return {"status": "none", "message": "Follow request cancelled"}
    
    raise HTTPException(status_code=404, detail="Not following this user")


@router.get("/follow-requests", response_model=List[FriendRequestResponse])
def get_follow_requests(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get all pending follow requests for current user (private account)."""
    requests = db.query(FriendRequest).filter(
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending"
    ).order_by(FriendRequest.created_at.desc()).all()
    
    result = []
    for req in requests:
        requester = db.query(User).filter(User.id == req.requester_id).first()
        result.append(FriendRequestResponse(
            id=req.id,
            requester_id=req.requester_id,
            requester_username=requester.username if requester else "Unknown",
            requester_avatar=requester.avatar_path if requester else None,
            recipient_id=req.recipient_id,
            status=req.status,
            created_at=req.created_at
        ))
    
    print(f"📥 {current_user.username} has {len(result)} pending follow requests")
    return result


@router.post("/follow-request/{request_id}/accept")
def accept_follow_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Accept a follow request → creates a Follow record."""
    friend_request = db.query(FriendRequest).filter(
        FriendRequest.id == request_id,
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending"
    ).first()
    
    if not friend_request:
        raise HTTPException(status_code=404, detail="Follow request not found")
    
    # Mark request as accepted
    friend_request.status = "accepted"
    friend_request.updated_at = datetime.utcnow()
    
    # Create follow record (requester → current_user)
    follow = Follow(
        follower_id=friend_request.requester_id,
        following_id=current_user.id
    )
    db.add(follow)
    db.commit()
    
    requester = db.query(User).filter(User.id == friend_request.requester_id).first()
    print(f"✅ {current_user.username} accepted follow request from {requester.username if requester else 'Unknown'}")
    
    return {
        "message": "Follow request accepted",
        "follower_id": requester.id if requester else None,
        "follower_username": requester.username if requester else "Unknown",
        "follower_avatar": requester.avatar_path if requester else None
    }


@router.post("/follow-request/{request_id}/reject")
def reject_follow_request_new(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Reject a follow request."""
    friend_request = db.query(FriendRequest).filter(
        FriendRequest.id == request_id,
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending"
    ).first()
    
    if not friend_request:
        raise HTTPException(status_code=404, detail="Follow request not found")
    
    friend_request.status = "rejected"
    friend_request.updated_at = datetime.utcnow()
    db.commit()
    
    print(f"❌ {current_user.username} rejected follow request")
    return {"message": "Follow request rejected"}


@router.delete("/followers/{user_id}")
def remove_follower(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Remove someone from your followers (without blocking)."""
    follow = db.query(Follow).filter(
        Follow.follower_id == user_id,
        Follow.following_id == current_user.id
    ).first()
    
    if not follow:
        raise HTTPException(status_code=404, detail="This user is not following you")
    
    db.delete(follow)
    db.commit()
    
    target = db.query(User).filter(User.id == user_id).first()
    print(f"🗑️ {current_user.username} removed follower {target.username if target else user_id}")
    return {"message": "Follower removed"}


@router.get("/{user_id}/followers")
def get_user_followers(
    user_id: str,
    search: Optional[str] = None,
    cursor: int = 0,
    limit: int = 30,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get followers list of a user (paginated, searchable)."""
    from sqlalchemy import or_
    
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    
    # Privacy check for private accounts
    is_private = getattr(user, 'is_private', False)
    if is_private and user_id != current_user.id:
        # Check if viewer follows this user
        is_following = db.query(Follow).filter(
            Follow.follower_id == current_user.id,
            Follow.following_id == user_id
        ).first() is not None
        
        if not is_following:
            raise HTTPException(status_code=403, detail="This account is private")
    
    # Get follower IDs
    follower_ids = [f.follower_id for f in db.query(Follow).filter(
        Follow.following_id == user_id
    ).all()]
    
    if not follower_ids:
        return {"users": [], "total": 0, "hasMore": False}
    
    # Query users
    query = db.query(User).filter(User.id.in_(follower_ids))
    if search:
        query = query.filter(User.username.ilike(f"%{search}%"))
    
    total = query.count()
    users = query.offset(cursor).limit(limit).all()
    
    # Check which followers the current user is following
    current_following_ids = set()
    if users:
        uids = [u.id for u in users]
        current_follows = db.query(Follow.following_id).filter(
            Follow.follower_id == current_user.id,
            Follow.following_id.in_(uids)
        ).all()
        current_following_ids = {f[0] for f in current_follows}
    
    return {
        "users": [
            {
                "id": u.id,
                "username": u.username,
                "displayName": f"{decrypt_text(u.first_name) if u.first_name else ''} {decrypt_text(u.last_name) if u.last_name else ''}".strip() or None,
                "avatarUrl": u.avatar_path,
                "isVerified": u.is_verified or False,
                "isPremium": u.is_premium or False,
                "isFollowing": u.id in current_following_ids,
            }
            for u in users
        ],
        "total": total,
        "hasMore": (cursor + limit) < total
    }


@router.get("/{user_id}/following")
def get_user_following(
    user_id: str,
    search: Optional[str] = None,
    cursor: int = 0,
    limit: int = 30,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get following list of a user (paginated, searchable)."""
    from sqlalchemy import or_
    
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    
    # Privacy check
    is_private = getattr(user, 'is_private', False)
    if is_private and user_id != current_user.id:
        is_following = db.query(Follow).filter(
            Follow.follower_id == current_user.id,
            Follow.following_id == user_id
        ).first() is not None
        
        if not is_following:
            raise HTTPException(status_code=403, detail="This account is private")
    
    # Get following IDs
    following_ids = [f.following_id for f in db.query(Follow).filter(
        Follow.follower_id == user_id
    ).all()]
    
    if not following_ids:
        return {"users": [], "total": 0, "hasMore": False}
    
    # Query users
    query = db.query(User).filter(User.id.in_(following_ids))
    if search:
        query = query.filter(User.username.ilike(f"%{search}%"))
    
    total = query.count()
    users = query.offset(cursor).limit(limit).all()
    
    # Check which of these the current user is following
    current_following_ids = set()
    if users:
        uids = [u.id for u in users]
        current_follows = db.query(Follow.following_id).filter(
            Follow.follower_id == current_user.id,
            Follow.following_id.in_(uids)
        ).all()
        current_following_ids = {f[0] for f in current_follows}
    
    return {
        "users": [
            {
                "id": u.id,
                "username": u.username,
                "displayName": f"{decrypt_text(u.first_name) if u.first_name else ''} {decrypt_text(u.last_name) if u.last_name else ''}".strip() or None,
                "avatarUrl": u.avatar_path,
                "isVerified": u.is_verified or False,
                "isPremium": u.is_premium or False,
                "isFollowing": u.id in current_following_ids,
            }
            for u in users
        ],
        "total": total,
        "hasMore": (cursor + limit) < total
    }


@router.post("/migrate-friends-to-follows")
def migrate_friends_to_follows(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """One-time migration: Convert accepted FriendRequests to Follow records.
    
    Run once to migrate existing social graph. Safe to re-run (skips duplicates).
    """
    from sqlalchemy import or_
    
    accepted_requests = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted"
    ).all()
    
    created = 0
    for req in accepted_requests:
        # Create A→B follow
        existing_ab = db.query(Follow).filter(
            Follow.follower_id == req.requester_id,
            Follow.following_id == req.recipient_id
        ).first()
        if not existing_ab:
            db.add(Follow(
                follower_id=req.requester_id,
                following_id=req.recipient_id,
                created_at=req.created_at
            ))
            created += 1
        
        # Create B→A follow (mutual)
        existing_ba = db.query(Follow).filter(
            Follow.follower_id == req.recipient_id,
            Follow.following_id == req.requester_id
        ).first()
        if not existing_ba:
            db.add(Follow(
                follower_id=req.recipient_id,
                following_id=req.requester_id,
                created_at=req.created_at
            ))
            created += 1
    
    db.commit()
    print(f"🔄 Migration complete: {created} follow records created from {len(accepted_requests)} accepted friend requests")
    return {"migrated": created, "from_requests": len(accepted_requests)}


# ==================== FRIEND REQUESTS (Legacy — kept for backward compatibility) ====================


@router.post("/friend-request")
async def send_friend_request(
    recipient_id: str,
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Send a friend request."""
    # Rate limit: Prevent friend request spam
    # Limit by user (10 requests per hour)
    rate_limiter.check_rate_limit(
        identifier=f"friend_request:{current_user.id}",
        max_attempts=10,
        window_minutes=60,
        lockout_minutes=60
    )
    
    # Check if recipient exists
    recipient = db.query(User).filter(User.id == recipient_id).first()
    if not recipient:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    # Check if request already exists
    existing = db.query(FriendRequest).filter(
        FriendRequest.requester_id == current_user.id,
        FriendRequest.recipient_id == recipient_id,
        FriendRequest.status == "pending"
    ).first()
    
    if existing:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Friend request already sent"
        )
    
    # Create friend request
    friend_request = FriendRequest(
        requester_id=current_user.id,
        recipient_id=recipient_id,
        status="pending"
    )
    
    db.add(friend_request)
    db.commit()
    db.refresh(friend_request)
    
    # ✅ Send push notification to recipient (with preference check)
    if recipient.push_token and recipient.push_platform == "ios":
        from services.apns_service import get_apns_service, APNsService
        
        prefs = APNsService.should_send_push(recipient, "friend_request")
        if prefs["allowed"]:
            apns = get_apns_service()
            
            requester_name = APNsService.build_push_display_name(current_user)
            badge = APNsService.get_unread_badge_count(db, recipient.id)
            
            push_result = await apns.send_friend_request_notification(
                device_token=recipient.push_token,
                requester_name=requester_name,
                requester_id=current_user.id,
                badge=badge
            )
            if push_result:
                print(f"📱 ✅ Friend request push sent to {recipient.username}")
            else:
                print(f"📱 ❌ Friend request push failed for {recipient.username}")
        else:
            print(f"📱 ⏭️ Friend request push skipped for {recipient.username} (notifications disabled)")
    
    print(f"📤 Friend request sent: {current_user.username} -> {recipient.username}")
    
    return {"message": "Friend request sent", "request_id": friend_request.id}

# === FRIENDS ENDPOINTS ===

@router.get("/friends")
async def get_friends(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get all accepted friends for the current user.
    Returns friends from both directions (requests sent and received).
    """
    # Get friend requests where current user is sender and status is accepted
    sent_requests = db.query(FriendRequest).filter(
        FriendRequest.requester_id == current_user.id, # Changed sender_id to requester_id
        FriendRequest.status == "accepted"
    ).all()
    
    # Get friend requests where current user is receiver and status is accepted
    received_requests = db.query(FriendRequest).filter(
        FriendRequest.recipient_id == current_user.id, # Changed receiver_id to recipient_id
        FriendRequest.status == "accepted"
    ).all()
    
    # Collect all friend user IDs
    friend_ids = set()
    for req in sent_requests:
        friend_ids.add(req.recipient_id) # Changed receiver_id to recipient_id
    for req in received_requests:
        friend_ids.add(req.requester_id) # Changed sender_id to requester_id
    
    # Fetch user details for all friends
    friends = []
    for friend_id in friend_ids:
        friend_user = db.query(User).filter(User.id == friend_id).first()
        if friend_user:
            display_name = _build_display_name(friend_user)
            friends.append({
                "id": friend_user.id,
                "username": friend_user.username,
                "display_name": display_name,
                "avatar_path": friend_user.avatar_path,
            })
    
    return friends

@router.delete("/friends/{friend_id}")
async def remove_friend(
    friend_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Remove a friend from your friends list.
    This deletes the friend request record, allowing both users 
    to send new friend requests to each other in the future.
    """
    from sqlalchemy import or_, and_
    
    # Find the friend request (either direction)
    friend_request = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(
            and_(
                FriendRequest.requester_id == current_user.id,
                FriendRequest.recipient_id == friend_id
            ),
            and_(
                FriendRequest.requester_id == friend_id,
                FriendRequest.recipient_id == current_user.id
            )
        )
    ).first()
    
    if not friend_request:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Friend not found"
        )
    
    # Get friend's user info for logging
    friend = db.query(User).filter(User.id == friend_id).first()
    friend_name = friend.username if friend else "Unknown"
    
    # Delete the friend request record (allows re-adding later)
    db.delete(friend_request)
    db.commit()
    
    print(f"🗑️ {current_user.username} removed friend {friend_name}")
    
    return {"success": True, "message": f"Removed {friend_name} from friends"}

@router.get("/friend-requests", response_model=List[FriendRequestResponse])
def get_friend_requests(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get all pending friend requests for current user."""
    requests = db.query(FriendRequest).filter(
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending"
    ).order_by(FriendRequest.created_at.desc()).all()
    
    result = []
    for req in requests:
        requester = db.query(User).filter(User.id == req.requester_id).first()
        result.append(FriendRequestResponse(
            id=req.id,
            requester_id=req.requester_id,
            requester_username=requester.username if requester else "Unknown",
            requester_avatar=requester.avatar_path if requester else None,
            recipient_id=req.recipient_id,
            status=req.status,
            created_at=req.created_at
        ))
    
    print(f"📥 {current_user.username} has {len(result)} pending friend requests")
    return result

@router.post("/friend-request/{request_id}/accept")
def accept_friend_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Accept a friend request."""
    friend_request = db.query(FriendRequest).filter(
        FriendRequest.id == request_id,
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending"
    ).first()
    
    if not friend_request:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Friend request not found"
        )
    
    # Update status
    friend_request.status = "accepted"
    friend_request.updated_at = datetime.utcnow()
    
    # ✅ Also create Follow records (both directions = mutual friends)
    # This bridges the legacy FriendRequest system with the new Follow system
    from models import Follow
    for fid, tid in [
        (friend_request.requester_id, current_user.id),
        (current_user.id, friend_request.requester_id)
    ]:
        existing = db.query(Follow).filter(
            Follow.follower_id == fid,
            Follow.following_id == tid
        ).first()
        if not existing:
            db.add(Follow(follower_id=fid, following_id=tid))
    
    db.commit()
    
    # ✅ Get requester info to return to client
    requester = db.query(User).filter(User.id == friend_request.requester_id).first()
    print(f"✅ {current_user.username} accepted friend request from {requester.username if requester else 'Unknown'} (Follow records created)")
    
    # ✅ Return friend info so client doesn't need notification lookup
    return {
        "message": "Friend request accepted",
        "friend_id": requester.id if requester else None,
        "friend_username": requester.username if requester else "Unknown",
        "friend_avatar": requester.avatar_path if requester else None
    }

@router.post("/friend-request/{request_id}/reject")
def reject_friend_request(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Reject a friend request."""
    friend_request = db.query(FriendRequest).filter(
        FriendRequest.id == request_id,
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending"
    ).first()
    
    if not friend_request:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Friend request not found"
        )
    
    # Update status to rejected (or delete)
    friend_request.status = "rejected"
    friend_request.updated_at = datetime.utcnow()
    db.commit()
    
    print(f"❌ {current_user.username} rejected friend request")
    
    return {"message": "Friend request rejected"}

# ==================== PROFILE PICTURE ====================

@router.post("/profile-picture")
def update_profile_picture(
    update: ProfilePictureUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Update current user's profile picture."""
    # Validate image_url format (accept both relative /uploads/... and full URL)
    image_url = update.image_url
    
    # If full URL, validate and store appropriately
    if image_url.startswith("http://") or image_url.startswith("https://"):
        from urllib.parse import urlparse
        parsed = urlparse(image_url)
        
        # Accept GCS public URLs (production) — store full URL
        if "storage.googleapis.com" in parsed.netloc:
            pass  # Store as-is (full GCS URL)
        # Accept our own server uploads — extract relative path
        elif parsed.path.startswith("/uploads/"):
            image_url = parsed.path  # Store relative path
        else:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Invalid image URL format"
            )
    elif not image_url.startswith("/uploads/"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid image URL format"
        )
    
    # Update user's avatar_path
    current_user.avatar_path = image_url
    db.commit()
    db.refresh(current_user)
    
    print(f"✅ {current_user.username} updated profile picture to {update.image_url}")
    
    return UserProfile(
        id=current_user.id,
        username=current_user.username,
        avatar_path=current_user.avatar_path,
        bio=current_user.bio
    )

# ==================== SCREENSHOT NOTIFICATIONS ====================

@router.post("/{user_id}/screenshot-notification")
def record_screenshot_notification(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Record a screenshot notification when someone screenshots a profile picture."""
    # Verify profile owner exists
    profile_owner = db.query(User).filter(User.id == user_id).first()
    if not profile_owner:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    # Don't record if user screenshots their own profile
    if user_id == current_user.id:
        return {"message": "Cannot screenshot own profile"}
    
    # Create screenshot notification
    notification = ScreenshotNotification(
        profile_owner_id=user_id,
        screenshotter_id=current_user.id
    )
    
    db.add(notification)
    db.commit()
    
    print(f"📸 Screenshot notification: {current_user.username} screenshotted {profile_owner.username}'s profile")
    
    return {"message": "Screenshot notification recorded", "notification_id": notification.id}

@router.get("/screenshot-notifications", response_model=List[ScreenshotNotificationResponse])
def get_screenshot_notifications(
    mark_as_read: bool = False,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get all screenshot notifications for current user."""
    notifications = db.query(ScreenshotNotification).filter(
        ScreenshotNotification.profile_owner_id == current_user.id
    ).order_by(ScreenshotNotification.timestamp.desc()).all()
    
    # Optionally mark all as read
    if mark_as_read:
        for notif in notifications:
            notif.is_read = True
        db.commit()
    
    # Build response
    result = []
    for notif in notifications:
        screenshotter = db.query(User).filter(User.id == notif.screenshotter_id).first()
        result.append(ScreenshotNotificationResponse(
            id=notif.id,
            screenshotter_username=screenshotter.username if screenshotter else "Unknown",
            screenshotter_avatar=screenshotter.avatar_path if screenshotter else None,
            timestamp=notif.timestamp,
            is_read=notif.is_read
        ))
    
    print(f"📋 {current_user.username} viewed {len(result)} screenshot notifications")
    return result


# ==================== USER PROFILE ====================
# Note: This route MUST be at the end because /{user_id} is a catch-all
# that would match specific routes like /friend-requests if placed earlier

@router.get("/{user_id}")
def get_user(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get full user profile with stats, interests, and friendship status."""
    user = db.query(User).filter(User.id == user_id).first()
    
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    # Count posts
    post_count = db.query(Post).filter(Post.author_id == user_id).count()
    
    # Count followers and following from Follow table (consistent with /profile endpoint)
    followers_count = db.query(Follow).filter(Follow.following_id == user_id).count()
    following_count = db.query(Follow).filter(Follow.follower_id == user_id).count()
    
    # Get friendship status with current user
    friendship_status = "none"
    friendship_request_id = None
    
    if user_id != current_user.id:
        # Check if current user sent a request to this user
        sent_request = db.query(FriendRequest).filter(
            FriendRequest.requester_id == current_user.id,
            FriendRequest.recipient_id == user_id
        ).first()
        
        # Check if this user sent a request to current user
        received_request = db.query(FriendRequest).filter(
            FriendRequest.requester_id == user_id,
            FriendRequest.recipient_id == current_user.id
        ).first()
        
        if sent_request:
            if sent_request.status == "accepted":
                friendship_status = "friends"
            elif sent_request.status == "pending":
                friendship_status = "sent"
            friendship_request_id = sent_request.id
        elif received_request:
            if received_request.status == "accepted":
                friendship_status = "friends"
            elif received_request.status == "pending":
                friendship_status = "received"
            friendship_request_id = received_request.id
    else:
        friendship_status = "self"
    
    # Parse hobbies/interests from JSON or comma-separated
    interests = []
    if user.hobbies:
        import json
        try:
            interests = json.loads(user.hobbies)
        except:
            # Fallback to comma-separated
            interests = [h.strip() for h in user.hobbies.split(",") if h.strip()]
    
    # Build bio_song if Spotify data exists
    bio_song = None
    if user.spotify_track_id:
        bio_song = {
            "spotify_track_id": user.spotify_track_id,
            "title": user.spotify_track_title,
            "artist": user.spotify_track_artist,
            "cover_url": user.spotify_cover_url,
            "preview_url": user.spotify_preview_url
        }
    
    print(f"👤 [Profile] {current_user.username} viewed profile of {user.username} (posts={post_count}, followers={followers_count}, following={following_count}, friendship={friendship_status})")
    
    return {
        "id": user.id,
        "username": user.username,
        "first_name": decrypt_text(user.first_name) if user.first_name else None,
        "last_name": decrypt_text(user.last_name) if user.last_name else None,
        "display_name": user.username,
        "avatar_path": user.avatar_path,
        "avatar_url": user.avatar_path,  # Alias for client compatibility
        "bio": user.bio,
        "interests": interests,
        "bio_song": bio_song,
        "stats": {
            "posts": post_count,
            "followers": followers_count,
            "following": following_count,
            "friends": followers_count + following_count  # Total connections
        },
        "friendship": {
            "status": friendship_status,
            "request_id": friendship_request_id
        },
        "is_verified": user.is_verified or False,
        "is_premium": user.is_premium or False,
        "created_at": user.created_at.isoformat() if user.created_at else None
    }


# ==================== PROFILE PREVIEW & PRIVACY ====================

class ProfileSummaryResponse(BaseModel):
    """Quick profile summary for avatar preview popup."""
    postsCount: int
    friendsCount: int
    isFriend: bool
    requestStatus: str  # none, pending, accepted
    isOnline: bool = False
    lastActiveAt: Optional[datetime] = None

class FullProfileResponse(BaseModel):
    """Full user profile with privacy controls."""
    id: str
    username: str
    displayName: Optional[str]
    avatarUrl: Optional[str]
    bio: Optional[str]
    joinedAt: Optional[datetime]
    birthday: Optional[datetime]
    isPrivate: bool
    showBirthday: bool
    isVerified: bool
    postsCount: int
    friendsCount: int
    isFriend: bool
    requestStatus: str


@router.get("/{user_id}/profileSummary")
def get_profile_summary(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Quick profile summary for avatar long-press preview.
    Returns counts and friendship status.
    """
    # Find user
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    
    # Get posts count
    posts_count = db.query(Post).filter(Post.author_id == user_id).count()
    
    # Get friends count (accepted requests in both directions)
    from sqlalchemy import or_
    friends_count = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(
            FriendRequest.requester_id == user_id,
            FriendRequest.recipient_id == user_id
        )
    ).count()
    
    # Check if current user is friend with this user
    is_friend = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(
            (FriendRequest.requester_id == current_user.id) & (FriendRequest.recipient_id == user_id),
            (FriendRequest.requester_id == user_id) & (FriendRequest.recipient_id == current_user.id)
        )
    ).first() is not None
    
    # Check if there's a pending request
    pending_request = db.query(FriendRequest).filter(
        FriendRequest.status == "pending",
        or_(
            (FriendRequest.requester_id == current_user.id) & (FriendRequest.recipient_id == user_id),
            (FriendRequest.requester_id == user_id) & (FriendRequest.recipient_id == current_user.id)
        )
    ).first()
    
    request_status = "none"
    if is_friend:
        request_status = "accepted"
    elif pending_request:
        request_status = "pending"
    
    # Check if current user has post notifications enabled for this user
    from models import PostSubscription
    post_sub = db.query(PostSubscription).filter(
        PostSubscription.subscriber_id == current_user.id,
        PostSubscription.target_id == user_id,
        PostSubscription.enabled == True
    ).first()
    is_notify_enabled = post_sub is not None
    
    return {
        "postsCount": posts_count,
        "friendsCount": friends_count,
        "isFriend": is_friend,
        "requestStatus": request_status,
        "isNotifyEnabled": is_notify_enabled,
        "isOnline": False,  # TODO: Implement presence
        "lastActiveAt": user.last_login
    }


@router.get("/{user_id}/profile")
def get_user_full_profile(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Full profile for profile view screen with privacy controls.
    """
    from sqlalchemy import or_
    
    # Find user
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    
    # Get counts
    posts_count = db.query(Post).filter(Post.author_id == user_id).count()
    print(f"🔢 [Profile] {user.username}: raw posts_count={posts_count}")
    friends_count = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(
            FriendRequest.requester_id == user_id,
            FriendRequest.recipient_id == user_id
        )
    ).count()
    
    # ===== Auto-migrate legacy FriendRequest → Follow records =====
    # If accepted FriendRequests exist but no Follow records, create them.
    # This bridges the gap between the old friend system and the new follow system.
    try:
        accepted_frs = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(
                FriendRequest.requester_id == user_id,
                FriendRequest.recipient_id == user_id
            )
        ).all()
        
        migrated = 0
        for fr in accepted_frs:
            # Create Follow in both directions (mutual friends)
            for fid, tid in [(fr.requester_id, fr.recipient_id), (fr.recipient_id, fr.requester_id)]:
                existing = db.query(Follow).filter(
                    Follow.follower_id == fid,
                    Follow.following_id == tid
                ).first()
                if not existing:
                    db.add(Follow(follower_id=fid, following_id=tid))
                    migrated += 1
        
        if migrated > 0:
            db.commit()
            print(f"🔄 [Profile] Auto-migrated {migrated} Follow records for {user.username} from legacy FriendRequests")
    except Exception as e:
        db.rollback()
        print(f"⚠️ [Profile] Follow migration failed for {user.username}: {e}")
    
    # ===== Follow-based counts =====
    try:
        followers_count = db.query(Follow).filter(Follow.following_id == user_id).count()
        following_count = db.query(Follow).filter(Follow.follower_id == user_id).count()
        
        # Mutual friends = people who follow user AND user follows back
        follower_ids = set(f.follower_id for f in db.query(Follow.follower_id).filter(Follow.following_id == user_id).all())
        following_ids = set(f.following_id for f in db.query(Follow.following_id).filter(Follow.follower_id == user_id).all())
        mutual_friends_count = len(follower_ids & following_ids)
        
        # Fallback: if Follow table is empty but FriendRequests exist,
        # use friends_count as following/mutual (accepted friend = mutual follow)
        if following_count == 0 and friends_count > 0:
            following_count = friends_count
            followers_count = friends_count
            mutual_friends_count = friends_count
            print(f"🔄 [Profile] Using FriendRequest fallback for follow counts (friends={friends_count})")
    except Exception as e:
        print(f"⚠️ [Profile] Follow counts failed: {e}")
        followers_count = friends_count
        following_count = friends_count
        mutual_friends_count = friends_count
    
    print(f"👤 [Profile Stats] {user.username}: posts={posts_count}, followers={followers_count}, following={following_count}, friends_legacy={friends_count}, mutual={mutual_friends_count}")
    
    # Check friendship (legacy — keep for backward compat)
    is_friend = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(
            (FriendRequest.requester_id == current_user.id) & (FriendRequest.recipient_id == user_id),
            (FriendRequest.requester_id == user_id) & (FriendRequest.recipient_id == current_user.id)
        )
    ).first() is not None
    
    pending_request = db.query(FriendRequest).filter(
        FriendRequest.status == "pending",
        or_(
            (FriendRequest.requester_id == current_user.id) & (FriendRequest.recipient_id == user_id),
            (FriendRequest.requester_id == user_id) & (FriendRequest.recipient_id == current_user.id)
        )
    ).first()
    
    request_status = "accepted" if is_friend else ("pending" if pending_request else "none")
    
    # ===== Follow status (new) =====
    i_follow_them = db.query(Follow).filter(
        Follow.follower_id == current_user.id,
        Follow.following_id == user_id
    ).first() is not None
    
    they_follow_me = db.query(Follow).filter(
        Follow.follower_id == user_id,
        Follow.following_id == current_user.id
    ).first() is not None
    
    # Compute follow status
    if user_id == current_user.id:
        follow_status = "self"
    elif i_follow_them and they_follow_me:
        follow_status = "mutual"
    elif i_follow_them:
        follow_status = "following"
    else:
        # Check for pending follow request
        pending_follow = db.query(FriendRequest).filter(
            FriendRequest.requester_id == current_user.id,
            FriendRequest.recipient_id == user_id,
            FriendRequest.status == "pending"
        ).first()
        follow_status = "requested" if pending_follow else "none"
    
    # Also update is_friend to be true if mutual follow exists
    is_friend = is_friend or (i_follow_them and they_follow_me)
    
    # Get display name
    first_name = decrypt_text(user.first_name) if user.first_name else None
    last_name = decrypt_text(user.last_name) if user.last_name else None
    display_name = f"{first_name or ''} {last_name or ''}".strip() or None
    
    # Birthday: only show if user allows it
    show_birthday = getattr(user, 'show_birthday', False)
    birthday = user.birthday if show_birthday else None
    
    # Privacy
    is_private = getattr(user, 'is_private', False)
    
    # Can current user message this user?
    who_can_msg = getattr(user, 'who_can_message', 'everyone')
    can_message = True
    if who_can_msg == 'friends' and not is_friend:
        can_message = False
    
    # Is current user blocking this user?
    from models import Block
    is_blocked = db.query(Block).filter(
        Block.blocker_id == current_user.id,
        Block.blocked_id == user_id
    ).first() is not None
    
    return {
        "id": user.id,
        "username": user.username,
        "displayName": display_name,
        "avatarUrl": user.avatar_path,
        "bio": user.bio,
        "joinedAt": user.created_at,
        "birthday": birthday,
        "isPrivate": is_private,
        "showBirthday": show_birthday,
        "isVerified": user.is_verified or False,
        "isPremium": user.is_premium or False,
        "postsCount": posts_count,
        "friendsCount": friends_count,
        "followersCount": followers_count,
        "followingCount": following_count,
        "mutualFriendsCount": mutual_friends_count,
        "isFriend": is_friend,
        "requestStatus": request_status,
        "followStatus": follow_status,
        "isFollowingYou": they_follow_me,
        "canMessage": can_message,
        "isBlocked": is_blocked,
        "showLikedPosts": getattr(user, 'show_liked_posts', True) if user.id == current_user.id or getattr(user, 'show_liked_posts', True) else False,
        "showReplies": getattr(user, 'show_replies', True) if user.id == current_user.id or getattr(user, 'show_replies', True) else False
    }



@router.get("/{user_id}/posts")
def get_user_posts(
    user_id: str,
    cursor: Optional[str] = None,
    limit: int = 20,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get posts by a specific user.
    If profile is private and viewer is not a friend, returns 403.
    Count is always available via /profile endpoint.
    """
    from sqlalchemy import or_
    
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    
    is_private = getattr(user, 'is_private', False)
    
    # Privacy check: if private, only friends can see posts
    if is_private and user_id != current_user.id:
        is_friend = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(
                (FriendRequest.requester_id == current_user.id) & (FriendRequest.recipient_id == user_id),
                (FriendRequest.requester_id == user_id) & (FriendRequest.recipient_id == current_user.id)
            )
        ).first() is not None
        
        if not is_friend:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="This account is private"
            )
    
    # Build query
    query = db.query(Post).filter(Post.author_id == user_id)
    
    # Cursor-based pagination
    if cursor:
        from datetime import datetime as dt
        try:
            cursor_date = dt.fromisoformat(cursor)
            query = query.filter(Post.timestamp < cursor_date)
        except (ValueError, TypeError):
            pass
    
    posts = query.order_by(Post.timestamp.desc()).limit(limit).all()
    
    next_cursor = None
    if posts and len(posts) == limit:
        next_cursor = posts[-1].timestamp.isoformat() if posts[-1].timestamp else None
    
    # Count comments per post in batch
    from models import Comment
    post_ids = [p.id for p in posts]
    comment_counts = {}
    if post_ids:
        from sqlalchemy import func
        rows = db.query(Comment.post_id, func.count(Comment.id)).filter(
            Comment.post_id.in_(post_ids)
        ).group_by(Comment.post_id).all()
        comment_counts = {row[0]: row[1] for row in rows}
    
    def parse_waveform(raw):
        if not raw:
            return None
        try:
            import json as json_mod
            return json_mod.loads(raw)
        except Exception:
            return None
    
    return {
        "posts": [
            {
                "id": p.id,
                "content": p.content,
                "authorId": p.author_id,
                "authorUsername": user.username,
                "authorAvatar": user.avatar_path,
                "createdAt": p.timestamp.isoformat() if p.timestamp else None,
                "likes": p.likes or 0,
                "comments": comment_counts.get(p.id, 0),
                "mediaUrl": p.image_url,
                "mediaType": p.post_type or "text",
                "postType": p.post_type,
                "voiceUrl": p.voice_url,
                "voiceDuration": p.voice_duration,
                "waveform": parse_waveform(p.waveform),
                "isVerified": user.is_verified or False,
                "isPremium": user.is_premium or False,
            }
            for p in posts
        ],
        "nextCursor": next_cursor,
        "hasMore": len(posts) == limit
    }


@router.get("/{user_id}/friends")
def get_user_friends(
    user_id: str,
    search: Optional[str] = None,
    cursor: int = 0,
    limit: int = 30,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get friends list of a user.
    If profile is private and viewer is not a friend, returns 403.
    """
    from sqlalchemy import or_
    
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    
    is_private = getattr(user, 'is_private', False)
    
    # Privacy check
    if is_private and user_id != current_user.id:
        is_friend = db.query(FriendRequest).filter(
            FriendRequest.status == "accepted",
            or_(
                (FriendRequest.requester_id == current_user.id) & (FriendRequest.recipient_id == user_id),
                (FriendRequest.requester_id == user_id) & (FriendRequest.recipient_id == current_user.id)
            )
        ).first() is not None
        
        if not is_friend:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Friends list is private"
            )
    
    # Get friend IDs
    friend_ids = set()
    sent = db.query(FriendRequest).filter(
        FriendRequest.requester_id == user_id,
        FriendRequest.status == "accepted"
    ).all()
    received = db.query(FriendRequest).filter(
        FriendRequest.recipient_id == user_id,
        FriendRequest.status == "accepted"
    ).all()
    for r in sent:
        friend_ids.add(r.recipient_id)
    for r in received:
        friend_ids.add(r.requester_id)
    
    if not friend_ids:
        return {"friends": [], "total": 0, "hasMore": False}
    
    # Query friends
    friends_query = db.query(User).filter(User.id.in_(friend_ids))
    
    # Search filter
    if search:
        friends_query = friends_query.filter(
            User.username.ilike(f"%{search}%")
        )
    
    total = friends_query.count()
    friends = friends_query.offset(cursor).limit(limit).all()
    
    return {
        "friends": [
            {
                "id": f.id,
                "username": f.username,
                "displayName": f"{decrypt_text(f.first_name) if f.first_name else ''} {decrypt_text(f.last_name) if f.last_name else ''}".strip() or None,
                "avatarUrl": f.avatar_path,
                "bio": f.bio,
                "isVerified": f.is_verified or False,
                "isPremium": f.is_premium or False
            }
            for f in friends
        ],
        "total": total,
        "hasMore": (cursor + limit) < total
    }
