from fastapi import APIRouter, Depends, HTTPException, status, Header, Request
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime

from database import get_db
from models import User, FriendRequest, ScreenshotNotification, Post
from auth import decode_token
from encryption import decrypt_text
from middleware.rate_limit import rate_limiter
# 🔴 ROUND 71 phase 3 — used by the friend_request live broadcast.
# Sibling import: ws_manager lives at server/ws_manager.py.
from ws_manager import ws_manager

router = APIRouter(prefix="/api/users", tags=["users"])

# Response models
class UserProfile(BaseModel):
    id: str
    username: str
    avatar_path: Optional[str]
    bio: Optional[str]

    class Config:
        from_attributes = True

# 🔴 User-search result shape. Matches the iOS `SearchUser` model and
# the /api/discovery/suggested endpoint (avatar_url, display_name,
# badges). The old /search response (UserProfile — avatar_path, no
# name, no badges) didn't match, so every search result rendered with
# no photo and no name.
class UserSearchResult(BaseModel):
    id: str
    username: str
    display_name: Optional[str] = None
    avatar_url: Optional[str] = None
    is_verified: bool = False
    is_premium: bool = False

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

    # 🔴 ROUND 45 (2026-05-19) — hacker-audit Server F9 (HIGH):
    # cross-instance access-token revocation. The companion fix in
    # `routers/auth.py::logout` writes `user.tokens_invalidated_at`
    # to the DB; we read it here on every authenticated request.
    # Any JWT whose `iat` (issued-at) is older than the stamp is
    # rejected, even on a Cloud Run cold-start replica that has an
    # empty in-process revocation set. We allow a small clock-skew
    # buffer (2s) because `iat` is set with `int(datetime.utcnow()
    # .timestamp())` (whole-second resolution) while the stamp is
    # stored as a full microsecond DateTime.
    if user.tokens_invalidated_at is not None:
        iat = payload.get("iat")
        if iat is not None:
            try:
                invalidated_ts = user.tokens_invalidated_at.timestamp()
                if float(iat) < invalidated_ts - 2.0:
                    raise HTTPException(
                        status_code=status.HTTP_401_UNAUTHORIZED,
                        detail="Token was invalidated by explicit logout"
                    )
            except HTTPException:
                raise
            except Exception as _e:
                print(f"⚠️ tokens_invalidated_at compare failed for {user.username}: {_e}")

    # 🔴 ROUND 38 (2026-05-19) — premium-expiry lazy invalidation.
    #
    # PREVIOUSLY: every premium check across the codebase read
    # `current_user.is_premium` directly. The companion field
    # `premium_expires_at` was set by the RevenueCat webhook on
    # subscription start but NEVER consulted on read. Concrete
    # bypass paths:
    #   1. The RevenueCat cancel webhook fails (network blip,
    #      signature mismatch, deploy lag) → `is_premium` stays
    #      True forever even though the user stopped paying.
    #   2. A user requests a refund through Apple → Apple revokes
    #      the entitlement, but the cancel webhook can take hours
    #      to fire (or never fires if Apple's queue drops it).
    #      The user keeps RAVEN+ uploads / stealth / mesh-TTL for
    #      that window.
    #   3. Test users who once flipped `is_premium=True` for QA
    #      and forgot to flip it back keep premium forever.
    #
    # FIX: on every authenticated request, compare
    # `premium_expires_at` against now(). If the expiry has passed,
    # flip `is_premium` to False inline (lazy invalidation) so the
    # rest of the request handles them as a free user. `null`
    # expiry is treated as "permanent" (lifetime grants, internal
    # accounts) and left alone.
    if user.is_premium and user.premium_expires_at is not None:
        from datetime import datetime as _dt
        if user.premium_expires_at < _dt.utcnow():
            user.is_premium = False
            try:
                db.commit()
                print(f"🔻 Premium expired for {user.username} (was due {user.premium_expires_at.isoformat()})")
            except Exception as _e:
                db.rollback()
                print(f"⚠️ Could not flip is_premium=False for {user.username}: {_e}")

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
    # 🔴 hacker-audit 2026-05-20 — username-enumeration oracle.
    # This authenticated endpoint had no rate limit, so any account
    # could iterate the username space and enumerate every
    # registered user for targeting / password-spraying. Bound it
    # per-caller: 60/min is generous for type-ahead checks (the
    # client debounces) but kills bulk enumeration.
    rate_limiter.check_rate_limit(
        identifier=f"check_username_user:{current_user.id}",
        max_attempts=60,
        window_minutes=1,
        lockout_minutes=5,
    )

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


def _search_display_name(user: User) -> Optional[str]:
    """The decrypted real name for a search result, or None when the
    user set no name (the client then falls back to @username).

    🔵 (2026-05-22) — a private account's NAME is intentionally shown.
    `who_can_see_profile = "friends"` gates the full PROFILE (posts,
    bio, contact details), NOT basic discoverability — a private
    account must stay recognisable in search so people can send it a
    follow request (standard social-app behaviour). Only freeform
    bio / hobbies text stays unsearchable; see `search_users`."""
    first = decrypt_text(user.first_name) if user.first_name else ""
    last = decrypt_text(user.last_name) if user.last_name else ""
    name = f"{first} {last}".strip()
    return name or None


@router.get("/search", response_model=List[UserSearchResult])
def search_users(
    q: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 20,
):
    """
    Search users by username, real name, bio, or tags/hobbies.

    - Case-insensitive partial match on username AND real name for
      ANY account, including private ones — a private account must be
      findable so a follow request can be sent (it stays pending
      until the owner accepts)
    - Bio / hobbies match only for fully-public profiles — freeform
      text can carry sensitive info, so it stays non-enumerable
    - Excludes current user
    - Excludes banned / restricted / pending accounts
    - Excludes accounts that have blocked the current user
    - Requires q ≥ 2 chars (enumeration defense)
    - Caller-supplied `limit` (default 20, capped at 50)

    🔴 ROUND 70 — added per-user rate limit. Previously unlimited;
    an attacker could brute-force 2-char prefixes (~1.3k queries)
    and dump the directory in seconds.
    """
    # Round 70 — rate limit to deter bulk-scrape.
    rate_limiter.check_rate_limit(
        identifier=f"user_search:{current_user.id}",
        max_attempts=30,
        window_minutes=1,
        lockout_minutes=5,
    )
    from sqlalchemy import or_, and_
    from models import Block

    # 🔴 ROUND 42 (2026-05-19) — search-endpoint enumeration leak.
    #
    # PREVIOUSLY: the only filter was `User.id != current_user.id`.
    # Three real exposures:
    #
    #   1. Private accounts (`is_private=True`) showed up in search
    #      results. ⚠️ REVISED 2026-05-22 — this is now INTENTIONAL.
    #      A private account MUST be findable — by username AND by
    #      real name — so a follow request can be sent (it stays
    #      pending until the owner accepts). Being "private" gates the
    #      PROFILE (posts / bio / details), not discoverability. Only
    #      freeform bio + hobbies text stays unsearchable; the 2-char
    #      gate + rate limiting remain the enumeration guard.
    #
    #   2. No minimum-length gate on `q`. A single-character query
    #      returned 10 random users; iterating over the alphabet
    #      enumerated 260+ accounts in a few seconds.
    #
    #   3. Bio + hobbies fields were full-text searchable. Users
    #      who wrote sensitive things in bios (politics, health,
    #      sexual orientation, employer) became findable by an
    #      attacker fishing for keywords. People don't expect
    #      bio TEXT to be a search corpus.
    #
    # FIX (privacy-preserving search):
    #   • Reject `q` shorter than 2 chars
    #   • Filter out banned / restricted / non-active users from the
    #     result set entirely (private accounts are NOT filtered —
    #     see point 1 above; they remain findable by username)
    #   • Filter out users who have blocked the current user (so
    #     blocking is bidirectional in discoverability terms)
    #   • Username + real-name search work for everyone (it's the
    #     normal expectation — that's how you find a person to
    #     follow); bio + hobbies only surface for accounts whose
    #     owner explicitly published a public profile
    #     (who_can_see_profile == 'public') — and even then only as
    #     a secondary signal.
    q_clean = (q or "").strip()
    if len(q_clean) < 2:
        return []

    # Escape SQL LIKE wildcards so a query containing % or _ matches
    # those characters literally instead of behaving as wildcards.
    q_escaped = q_clean.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    search_term = f"%{q_escaped}%"

    # Users who have blocked the current user — those rows hide from
    # the searcher entirely (no enumeration via search even if username
    # is unique).
    blocked_me_ids = db.query(Block.blocker_id).filter(
        Block.blocked_id == current_user.id
    ).subquery()

    base_filters = [
        User.id != current_user.id,
        User.username.isnot(None),           # half-onboarded accounts have no handle
        # NOTE: `is_private` is intentionally NOT filtered here — a
        # private account must be reachable by username so a follow
        # request can be sent. Its name / bio / hobbies stay
        # unsearchable: public_extra_match + the real-name scan are
        # gated on `who_can_see_profile`, while the bare username
        # match is universal.
        User.is_banned == False,             # noqa: E712
        User.is_restricted == False,         # noqa: E712
        (User.status.is_(None)) | (User.status == "active"),
        ~User.id.in_(blocked_me_ids),
    ]

    # Username gets a full ilike match; bio/hobbies only for
    # explicitly-public profiles (who_can_see_profile == 'public').
    username_match = User.username.ilike(search_term, escape="\\")
    public_extra_match = and_(
        (User.who_can_see_profile.is_(None)) | (User.who_can_see_profile == "public"),
        or_(
            User.bio.ilike(search_term, escape="\\"),
            User.hobbies.ilike(search_term, escape="\\"),
        )
    )

    capped_limit = max(1, min(limit, 50))

    # SQL-side matches: username (any non-private account) plus
    # bio/hobbies (public profiles only). Dict insertion order keeps
    # these ahead of the weaker real-name matches appended below.
    matches = {}
    for user in (
        db.query(User)
        .filter(*base_filters, or_(username_match, public_extra_match))
        .limit(capped_limit)
        .all()
    ):
        matches[user.id] = user

    # Real-name match. first_name / last_name are Fernet-encrypted at
    # rest and the ciphertext is non-deterministic, so they can NOT be
    # matched with a SQL LIKE — the search has to decrypt each
    # candidate's name and substring-match it in Python. Without this,
    # a user is only findable by @username, never by the name they
    # actually go by.
    #
    # 🔵 (2026-05-22) — NOT gated on `who_can_see_profile`. Real-name
    # search now covers private accounts too: you find a person by
    # their name to send a follow request, exactly as on every other
    # social app. Being private gates the PROFILE, not search. (Only
    # bio/hobbies — freeform, possibly-sensitive text — stay gated, in
    # `public_extra_match` above.) Bounded scan so a huge user table
    # can't stall search.
    if len(matches) < capped_limit:
        needle = q_clean.lower()
        name_candidates = (
            db.query(User)
            .filter(
                *base_filters,
                (User.first_name.isnot(None)) | (User.last_name.isnot(None)),
            )
            .limit(500)
            .all()
        )
        for user in name_candidates:
            if len(matches) >= capped_limit:
                break
            if user.id in matches:
                continue
            first = decrypt_text(user.first_name) if user.first_name else ""
            last = decrypt_text(user.last_name) if user.last_name else ""
            if needle in f"{first} {last}".lower():
                matches[user.id] = user

    return [
        UserSearchResult(
            id=user.id,
            username=user.username,
            display_name=_search_display_name(user),
            avatar_url=user.avatar_path,
            is_verified=bool(getattr(user, "is_verified", False)),
            is_premium=bool(getattr(user, "is_premium", False)),
        )
        for user in list(matches.values())[:capped_limit]
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
        friend_rows = db.query(Friendship).filter(
            or_(Friendship.user_id == my_id, Friendship.friend_id == my_id)
        ).all()
        friend_ids = set()
        for f in friend_rows:
            friend_ids.add(f.friend_id if f.user_id == my_id else f.user_id)
        
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
                    user_friendships = db.query(Friendship).filter(
                        or_(Friendship.user_id == user.id, Friendship.friend_id == user.id)
                    ).all()
                    for uf in user_friendships:
                        user_friends.add(uf.friend_id if uf.user_id == user.id else uf.user_id)
                    
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
                        "is_mutual": False
                    })
        
        # ── Step 3: Algorithmic suggestions (fill to limit) ──
        remaining = limit - len(results)
        if remaining > 0:
            algo_excluded = excluded_ids | contact_user_ids
            candidates = {}  # user_id -> {score, sources, user}
            
            # Source 1: Friends-of-friends
            for fid in list(friend_ids)[:50]:  # Limit to 50 friends for performance
                fof_rows = db.query(Friendship).filter(
                    or_(Friendship.user_id == fid, Friendship.friend_id == fid)
                ).all()
                for fof in fof_rows:
                    fof_id = fof.friend_id if fof.user_id == fid else fof.user_id
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
                        "is_mutual": False
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
                    "is_mutual": False
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
    #
    # 🔴 ROUND 32 (2026-05-19) — phone-binding desync fix.
    #
    # PREVIOUSLY: this branch updated `current_user.phone` (the
    # encrypted display string) but left `phone_verified`,
    # `phone_e164`, and `phone_hash` UNTOUCHED. A user whose
    # account was previously phone-verified to `+1-555-OLD` could
    # PATCH `phone = "+1-555-NEW"` and have their PROFILE display
    # the new number while contact-match lookup still bound the
    # account to the old hash. Two concrete failures:
    #   1. Profile UI shows "+1-555-NEW", but a friend's address-
    #      book sync would only match the account on "+1-555-OLD".
    #   2. If the old phone ever changed hands, the new owner's
    #      contact-discovery match would surface this user's
    #      account — a phishing / impersonation primitive.
    #
    # FIX: any change to the display phone clears the verified
    # flag and the canonical (e164 + hash) fields. The user must
    # re-run the SMS verification flow on the new number to get
    # back into contact-discovery. This makes the display phone
    # and the match phone always agree.
    if update.phone is not None:
        new_phone = (update.phone or "").strip()
        old_phone_plain = decrypt_text(current_user.phone) if current_user.phone else None
        if new_phone:
            # Only invalidate the binding if the number is actually
            # changing — re-PATCHing the same verified phone shouldn't
            # downgrade the verified state.
            if (old_phone_plain or "") != new_phone:
                current_user.phone = encrypt_text(new_phone)
                current_user.phone_verified = False
                current_user.phone_verified_at = None
                current_user.phone_e164 = None
                current_user.phone_hash = None
                print(f"📱 Phone updated for {current_user.username} — re-verification required")
            else:
                print(f"📱 Phone unchanged for {current_user.username}, skipping invalidation")
        else:
            # Clearing the phone — also drop the verified binding.
            current_user.phone = None
            current_user.phone_verified = False
            current_user.phone_verified_at = None
            current_user.phone_e164 = None
            current_user.phone_hash = None
            print(f"📱 Phone cleared for {current_user.username}")

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
        Backup, MediaObject, SyncQueue, PostSubscription,
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
    """
    # 🔴 ROUND 70 — wrap push_token with Fernet at rest. Even though
    # the Fernet key lives on the same server, this raises the bar:
    # a partial DB-read (read-replica leak, snapshot exfil, support
    # SQL query result) no longer hands out a plaintext push token
    # that an attacker could forge APNs/FCM messages with. A FULL
    # server compromise still gets the key — that's the documented
    # threat model. The token is decrypted lazily inside
    # `apns_service.send_*` via `_push_token_for(user)` which falls
    # back to raw on legacy rows (during the migration window).
    from encryption import encrypt_text
    current_user.push_token = encrypt_text(req.token)
    current_user.push_platform = req.platform
    db.commit()

    print(f"📱 Push token registered for {current_user.username} ({req.platform}): {req.token[:16]}...")

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


class PrivacySettingsUpdate(BaseModel):
    """Request model for updating privacy settings.

    🔴 ROUND 71 S20: previously declared only 4 fields. iOS
    `PrivacySettingsView` PATCHes 3 additional toggles that pydantic
    silently dropped (`show_liked_posts`, `show_replies`,
    `allow_contact_share`) — server returned 200, but the values were
    never persisted, so the toggle popped back on the next /me/settings
    GET. Adding the missing fields + the matching column writes below."""
    show_online_status: Optional[bool] = None
    read_receipts: Optional[bool] = None
    who_can_message: Optional[str] = None
    who_can_see_profile: Optional[str] = None
    show_liked_posts: Optional[bool] = None
    show_replies: Optional[bool] = None
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
    
    db.commit()
    
    print(f"⚙️ Notification preferences updated for {current_user.username}: "
          f"push={current_user.push_enabled}, msg={current_user.message_notifications_enabled}, "
          f"friends={current_user.friend_request_notifications_enabled}, "
          f"likes={current_user.likes_comments_notifications_enabled}, "
          f"sounds={current_user.sounds_enabled}, preview={current_user.message_preview_enabled}")
    
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

    # 🔴 ROUND 71 phase 3 (2026-05-24): persist the three privacy
    # toggles. R71 S20 originally added these via setattr-on-unmapped,
    # which SQLAlchemy silently dropped at commit. Phase 3 added the
    # backing Columns on User + migration in main.py; we now write
    # them as ordinary attributes so the values actually persist and
    # re-hydrate via /me/settings.
    if update.show_liked_posts is not None:
        current_user.show_liked_posts = bool(update.show_liked_posts)
    if update.show_replies is not None:
        current_user.show_replies = bool(update.show_replies)
    if update.allow_contact_share is not None:
        current_user.allow_contact_share = bool(update.allow_contact_share)

    db.commit()
    
    print(f"🔒 Privacy settings updated for {current_user.username}: "
          f"online={current_user.show_online_status}, receipts={current_user.read_receipts_enabled}, "
          f"msg_access={current_user.who_can_message}, profile={current_user.who_can_see_profile}")
    
    return {"success": True, "message": "Privacy settings updated"}


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
        },
        "privacy": {
            "show_online_status": current_user.show_online_status if current_user.show_online_status is not None else True,
            "read_receipts": current_user.read_receipts_enabled if current_user.read_receipts_enabled is not None else True,
            "who_can_message": current_user.who_can_message or "everyone",
            "who_can_see_profile": current_user.who_can_see_profile or "public",
            # 🔴 ROUND 71 phase 3: surface the three new privacy
            # toggles so iOS PrivacySettingsView re-hydrates them on
            # app launch instead of always defaulting to True.
            "show_liked_posts": current_user.show_liked_posts if current_user.show_liked_posts is not None else True,
            "show_replies": current_user.show_replies if current_user.show_replies is not None else True,
            "allow_contact_share": current_user.allow_contact_share if current_user.allow_contact_share is not None else True,
        }
    }


# ==================== FRIEND REQUESTS ====================


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
    
    # 🔴 BUG FIX (2026-05-21) — self-request guard. Without this you
    # could friend-request yourself (e.g. by scanning your own QR
    # code), producing a `friend_requests` row where requester ==
    # recipient and a "friend request from yourself" in the UI.
    if recipient_id == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cannot send a friend request to yourself"
        )

    # Check if recipient exists
    recipient = db.query(User).filter(User.id == recipient_id).first()
    if not recipient:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )

    from sqlalchemy import or_, and_
    from models import Block

    # 🔴 BUG FIX (2026-05-21) — bidirectional block check. Previously
    # `send_friend_request` had NO block check at all (unlike
    # /messages/send and /snaps/send), so a blocked user could still
    # spam friend requests at someone who blocked them.
    blocked = db.query(Block).filter(
        or_(
            and_(Block.blocker_id == current_user.id, Block.blocked_id == recipient_id),
            and_(Block.blocker_id == recipient_id, Block.blocked_id == current_user.id),
        )
    ).first()
    if blocked:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Cannot send a friend request to this user"
        )

    # 🔴 BUG FIX (2026-05-21) — the duplicate check was one-directional
    # and only looked at `status="pending"` for THIS direction. It
    # missed two cases that produced spurious / crossed rows:
    #
    #   (a) ALREADY FRIENDS — an `accepted` row already exists (either
    #       direction). The old code didn't see it, so re-scanning a
    #       friend's QR created a brand-new pending request from
    #       someone who's already your friend.
    #   (b) REVERSE PENDING — the recipient already sent ME a pending
    #       request. The old code created a SECOND pending row in the
    #       opposite direction → a crossed pair that auto-resolved to
    #       nothing. The natural behaviour is to AUTO-ACCEPT: if they
    #       asked to befriend me and I now ask to befriend them, we're
    #       friends.

    # (a) already friends?
    already_friends = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(
            and_(FriendRequest.requester_id == current_user.id,
                 FriendRequest.recipient_id == recipient_id),
            and_(FriendRequest.requester_id == recipient_id,
                 FriendRequest.recipient_id == current_user.id),
        )
    ).first()
    if already_friends:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You are already friends with this user"
        )

    # (b) reverse pending → auto-accept instead of creating a crossed row.
    reverse_pending = db.query(FriendRequest).filter(
        FriendRequest.requester_id == recipient_id,
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending",
    ).first()
    if reverse_pending:
        reverse_pending.status = "accepted"
        reverse_pending.updated_at = datetime.utcnow()
        db.commit()

        # 🔴 ROUND 71 S21: notify the ORIGINAL requester that their
        # request was just auto-accepted, AND clear the stale
        # friend_request notification row on the auto-accepter's
        # side. Previously this fast-path silently flipped the row
        # to accepted but neither side got a notification + the
        # original requester's "X wants to be friends" entry sat
        # stale forever in their Activity center.
        try:
            await _notify_friend_request_accepted(db, reverse_pending, current_user)
        except Exception as _e:
            print(f"⚠️ [Auto-accept] notify failed: {_e}")
        _delete_friend_request_notifications(db, current_user.id, reverse_pending.id)

        print(f"🤝 Auto-accepted: {current_user.username} ↔ {recipient.username} (mutual request)")
        return {
            "message": "You are now friends",
            "request_id": reverse_pending.id,
            "auto_accepted": True,
        }

    # Same-direction pending — already sent.
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

    # 🔵 (2026-05-22) — persist an in-app Notification row so the
    # request shows in the recipient's Notification Center and counts
    # toward the unread badge. PREVIOUSLY this endpoint only fired an
    # APNs push — which is ephemeral and never arrives on the
    # Simulator — so a friend request was effectively invisible
    # in-app (14 requests in prod, 0 notification rows). Best-effort:
    # a notification failure must not fail the already-committed
    # request. Mirrors the `follow_request` row in `follow_user`.
    #
    # 🔴 ROUND 71 phase 3 (2026-05-24) — populate `requester_username`
    # via the same display-name resolver the APNs push uses, so OAuth
    # users without a chosen username still render with their real
    # first/last name in the recipient's notification center instead
    # of a permanent "Someone". Pre-fix the raw `current_user.username`
    # was None for those accounts and iOS fell back to "Someone" with
    # no avatar — the exact UX bug the user reported.
    from services.apns_service import APNsService as _APNs
    _requester_display = _APNs.build_push_display_name(current_user)
    try:
        import json as _json
        from models import Notification
        _notif = Notification(
            user_id=recipient_id,
            type="friend_request",
            data=_json.dumps({
                "request_id": friend_request.id,
                "requester_id": current_user.id,
                # Always populated — display-name resolver falls back
                # through first+last → username → "Someone".
                "requester_username": _requester_display,
                # May be None when the requester hasn't uploaded an
                # avatar; iOS GlassAvatar renders initials in that case.
                "requester_avatar": current_user.avatar_path,
            }),
            is_read=False,
        )
        db.add(_notif)
        db.commit()
        db.refresh(_notif)

        # 🔴 ROUND 71 phase 3 — live WS broadcast. Pre-fix the
        # recipient had to wait for the next /api/notifications poll
        # (or an APNs push) before the friend-request row showed up
        # — meaning recipients in foreground often missed it for
        # ~30s. Push a FLAT payload that matches the existing iOS
        # RealtimeEngine `friend_request` toast handler so the
        # in-app banner fires immediately + the notification list
        # picks up the new row on the next refresh.
        try:
            await ws_manager.notify(recipient_id, {
                "type": "friend_request",
                "notification_id": _notif.id,
                "request_id": friend_request.id,
                "requester_id": current_user.id,
                "requester_username": _requester_display,
                "requester_avatar": current_user.avatar_path,
                "timestamp": _notif.timestamp.isoformat() + "Z",
                "is_read": False,
            })
        except Exception as _ws_err:
            print(f"⚠️ friend_request WS broadcast failed: {_ws_err}")
    except Exception as _e:
        db.rollback()
        print(f"⚠️ friend_request notification failed: {_e}")

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

def _delete_friend_request_notifications(
    db: Session, user_id: str, request_id: str
) -> None:
    """🔴 ROUND 70 — drop every Notification row of type='friend_request'
    that points at `request_id` for `user_id`. Called from both the
    accept and decline paths so the iOS Pending Requests folder clears
    once the underlying FriendRequest is resolved.

    Best-effort: deletion failures are logged and swallowed so the
    accept/decline transaction still commits cleanly. The next iOS
    poll will catch any stragglers via the standard markAllAsRead /
    Clear-All flow (which now also respects friend requests; see
    round-70 changes in notifications.py)."""
    try:
        from sqlalchemy import text as _sql_text
        from models import Notification  # local import; mirrors rest of this module
        # Friend-request notifications are created by
        # `_notify_friend_request` (server-side) with
        # `data.request_id == <FriendRequest.id>`. Match on that.
        deleted = db.query(Notification).filter(
            Notification.user_id == user_id,
            Notification.type == "friend_request",
            _sql_text("(data::json ->> 'request_id') = :rid").bindparams(rid=request_id),
        ).delete(synchronize_session=False)
        if deleted:
            db.commit()
            print(f"🗑️ [Friend] cleared {deleted} friend_request notification(s) for {user_id[:8]}")
    except Exception as e:
        import logging
        logging.getLogger("users.friend").warning(
            f"friend_request notification cleanup skipped: {type(e).__name__}: {e}")
        try:
            db.rollback()
        except Exception:
            pass


async def _notify_friend_request_accepted(
    db: Session, friend_request: FriendRequest, accepter: User
) -> None:
    """🔴 Notify the original requester that `accepter` accepted their
    friend request — an in-app Notification row plus an APNs push.
    Best-effort: a notification failure must never fail the accept."""
    try:
        requester = db.query(User).filter(
            User.id == friend_request.requester_id
        ).first()
        if not requester:
            return
        import json as _json
        from models import Notification
        db.add(Notification(
            user_id=requester.id,
            type="friend_accepted",
            # 🔵 (2026-05-23) — also expose the accepter under
            # `requester_*` keys (the iOS NotificationData struct only
            # has those) so the row renders with the accepter's
            # actual name + avatar instead of "Someone".
            data=_json.dumps({
                "user_id": accepter.id,
                "username": accepter.username,
                "request_id": friend_request.id,
                "requester_id": accepter.id,
                "requester_username": accepter.username,
                "requester_avatar": accepter.avatar_path,
            }),
            is_read=False,
        ))
        db.commit()
        # APNs push — best-effort, iOS only, respects the user's prefs.
        if requester.push_token and requester.push_platform == "ios":
            from services.apns_service import get_apns_service, APNsService
            prefs = APNsService.should_send_push(requester, "friend_request")
            if prefs["allowed"]:
                apns = get_apns_service()
                await apns.send_friend_accepted_notification(
                    device_token=requester.push_token,
                    accepter_name=APNsService.build_push_display_name(accepter),
                    accepter_id=accepter.id,
                    badge=APNsService.get_unread_badge_count(db, requester.id),
                )
    except Exception as e:
        try:
            db.rollback()
        except Exception:
            pass
        print(f"⚠️ [FriendAccept] notify failed: {e}")


@router.post("/friend-request/{request_id}/accept")
async def accept_friend_request(
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
    db.commit()

    # 🔴 ROUND 70 — delete the matching friend_request notification(s)
    # for this recipient so the iOS Pending Requests folder clears the
    # row on the very next poll. Without this, the optimistic
    # client-side removal would race the next /api/notifications poll
    # which would re-add the row.
    _delete_friend_request_notifications(db, current_user.id, request_id)

    # ✅ Get requester info to return to client
    requester = db.query(User).filter(User.id == friend_request.requester_id).first()
    print(f"✅ {current_user.username} accepted friend request from {requester.username if requester else 'Unknown'}")

    # 🔴 Notify the requester their request was accepted (push + in-app).
    await _notify_friend_request_accepted(db, friend_request, current_user)

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

    # 🔴 ROUND 70 — same cleanup as accept: drop the matching
    # friend_request notification so the Pending Requests folder
    # actually empties on next poll. Without this, iOS would
    # optimistically remove it then bounce it back seconds later.
    _delete_friend_request_notifications(db, current_user.id, request_id)

    print(f"❌ {current_user.username} rejected friend request")

    return {"message": "Friend request rejected"}


# 🔴 ROUND 26 — iOS has historically called `/decline` (matching the
# user-facing button label "Delete / Decline") while the server only
# implemented `/reject`. Adding the alias so old + new clients both work.
@router.post("/friend-request/{request_id}/decline")
def decline_friend_request_alias(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Alias for /reject — kept because iOS calls this path."""
    return reject_friend_request(request_id, current_user, db)


# 🔴 ROUND 26 — the QR-code offline retry queue posts the request with
# the recipient id baked into the URL path, not the query string. Accept
# both shapes so the queue flushes successfully when the user comes
# back online after scanning a friend's QR offline.
@router.post("/friend-request/{recipient_id}/send")
async def send_friend_request_path_variant(
    recipient_id: str,
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Path-style variant of POST /friend-request?recipient_id=...

    Same body, same response, same rate limit — just a different URL
    shape so the offline retry queue (`PendingFriendRequestQueue`)
    doesn't need a separate REST verb.
    """
    return await send_friend_request(
        recipient_id=recipient_id,
        request=request,
        current_user=current_user,
        db=db,
    )


# ═══════════════════════════════════════════════════════════════════════════
# 🔴 ROUND 26 — ONE-WAY USER FOLLOW (X / Twitter style)
#
# Distinct from friend-requests: a follow is unilateral, instant, and
# does NOT grant DM access. iOS has been calling these endpoints for
# months — they were silently 404'ing.
# ═══════════════════════════════════════════════════════════════════════════


@router.post("/follow/{user_id}")
async def follow_user(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Follow another user (one-way). No-op if already following.

    🔴 ROUND 26 (2026-05-16) — RESPONSE-SHAPE FIX.
    iOS `UserProfileView.followUser()` switches its `followStatus`
    state on the exact strings `"following"`, `"requested"`, or
    `"mutual"`. Anything else leaves `followStatus` untouched and
    the button keeps saying "Follow" even after a successful POST
    — which is exactly the symptom the user saw in the live test
    ("tapped Follow, server said 200, but UI button didn't change").

    `"requested"` is returned for private accounts (followee's
    `is_private = True`) — the follow row is created with
    `status="pending"` and grants nothing until the followee
    approves it via `/follow/pending/{id}/accept`.
    `"mutual"` means both directions exist as ACCEPTED follows.

    🔴 BUG FIX (2026-05-21) — two real bugs closed here:
      1. PRIVACY BYPASS: this endpoint's docstring always promised a
         "requested" pending flow for private accounts, but the code
         never checked `is_private` — it created an immediate
         accepted follow for everyone. A private account could be
         followed by anyone with zero approval. Now a private
         followee yields a `status="pending"` row + `"requested"`.
      2. BLOCK BYPASS: there was no `Block` check — you could follow
         someone you blocked, or who blocked you. Now rejected 403.
    """
    from models import UserFollow, Block, Notification
    from sqlalchemy import or_, and_
    import json as _json

    if user_id == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cannot follow yourself"
        )

    # Verify followee exists.
    followee = db.query(User).filter(User.id == user_id).first()
    if not followee:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )

    # 🔴 BUG FIX (2026-05-21) — bidirectional block check.
    blocked = db.query(Block).filter(
        or_(
            and_(Block.blocker_id == current_user.id, Block.blocked_id == user_id),
            and_(Block.blocker_id == user_id, Block.blocked_id == current_user.id),
        )
    ).first()
    if blocked:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Cannot follow this user"
        )

    def _is_mutual() -> bool:
        """Both directions exist as ACCEPTED follows."""
        return db.query(UserFollow).filter(
            UserFollow.follower_id == user_id,
            UserFollow.followee_id == current_user.id,
            UserFollow.status == "accepted",
        ).first() is not None

    # Idempotent: if the row exists, return its current state.
    existing = db.query(UserFollow).filter(
        UserFollow.follower_id == current_user.id,
        UserFollow.followee_id == user_id,
    ).first()
    if existing:
        if existing.status == "pending":
            return {"status": "requested", "message": "Follow request already pending"}
        return {
            "status": "mutual" if _is_mutual() else "following",
            "message": "Already following"
        }

    # 🔴 BUG FIX (2026-05-21) — respect `is_private`. A private
    # account must approve its followers; create a PENDING row that
    # grants nothing until accepted.
    is_private = bool(getattr(followee, "is_private", False))
    follow = UserFollow(
        follower_id=current_user.id,
        followee_id=user_id,
        status="pending" if is_private else "accepted",
    )
    db.add(follow)
    db.commit()
    db.refresh(follow)

    if is_private:
        print(f"⏳ {current_user.username} requested to follow {followee.username} (private)")
        # Tell the private account a follow request is waiting — an
        # in-app Notification row first.
        try:
            db.add(Notification(
                user_id=user_id,
                type="follow_request",
                data=_json.dumps({
                    "follow_id": follow.id,
                    "follower_id": current_user.id,
                    "follower_username": current_user.username,
                    # 🔵 (2026-05-23) — also expose under `requester_*`
                    # keys so the iOS notification cell can render this
                    # via the same data path as `friend_request` (the
                    # iOS NotificationData struct doesn't carry any
                    # follower_* fields).
                    "request_id": follow.id,
                    "requester_id": current_user.id,
                    "requester_username": current_user.username,
                    "requester_avatar": current_user.avatar_path,
                }),
                is_read=False,
            ))
            db.commit()
        except Exception as _e:
            db.rollback()
            print(f"⚠️ follow_request notification failed: {_e}")
        # 🔵 (2026-05-22) — and a best-effort APNs push, so a private
        # account learns of a follow request in real time (the
        # friend-request flow already pushes; this brings parity).
        try:
            if followee.push_token and followee.push_platform == "ios":
                from services.apns_service import get_apns_service, APNsService
                prefs = APNsService.should_send_push(followee, "friend_request")
                if prefs["allowed"]:
                    apns = get_apns_service()
                    requester_name = APNsService.build_push_display_name(current_user)
                    await apns.send_push(
                        device_token=followee.push_token,
                        title="New Follow Request",
                        body=f"{requester_name} requested to follow you",
                        data={
                            "type": "follow_request",
                            "follow_id": follow.id,
                            "follower_id": current_user.id,
                        },
                        category="FRIEND_REQUEST",
                        badge=APNsService.get_unread_badge_count(db, user_id),
                    )
        except Exception as _e:
            print(f"⚠️ follow_request push failed: {_e}")
        return {"status": "requested", "message": "Follow request sent"}

    print(f"➕ {current_user.username} followed {followee.username}")

    # 🔵 (2026-05-23) — Tell the followee they have a new follower.
    # PREVIOUSLY the non-private branch silently created the
    # UserFollow row with no notification, so a new public-account
    # follower was invisible to the followee until they happened to
    # open the followers list. Instagram surfaces this front-and-
    # centre in the notification feed; mirror it. Best-effort: never
    # fail the follow because of a notification glitch.
    try:
        db.add(Notification(
            user_id=user_id,
            type="new_follower",
            data=_json.dumps({
                "follower_id": current_user.id,
                "follower_username": current_user.username,
                # Mirror as `requester_*` so the iOS NotificationData
                # struct can render this with the existing data path.
                "requester_id": current_user.id,
                "requester_username": current_user.username,
                "requester_avatar": current_user.avatar_path,
            }),
            is_read=False,
        ))
        db.commit()
    except Exception as _e:
        db.rollback()
        print(f"⚠️ new_follower notification failed: {_e}")
    try:
        if followee.push_token and followee.push_platform == "ios":
            from services.apns_service import get_apns_service, APNsService
            prefs = APNsService.should_send_push(followee, "friend_request")
            if prefs["allowed"]:
                apns = get_apns_service()
                follower_name = APNsService.build_push_display_name(current_user)
                await apns.send_push(
                    device_token=followee.push_token,
                    title="New Follower",
                    body=f"{follower_name} started following you",
                    data={
                        "type": "new_follower",
                        "follower_id": current_user.id,
                    },
                    category="FRIEND_REQUEST",
                    badge=APNsService.get_unread_badge_count(db, user_id),
                )
    except Exception as _e:
        print(f"⚠️ new_follower push failed: {_e}")

    return {
        "status": "mutual" if _is_mutual() else "following",
        "message": "Now following"
    }


@router.delete("/follow/{user_id}")
def unfollow_user(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Unfollow a user. No-op if not currently following."""
    from models import UserFollow

    follow = db.query(UserFollow).filter(
        UserFollow.follower_id == current_user.id,
        UserFollow.followee_id == user_id,
    ).first()

    if follow:
        db.delete(follow)
        db.commit()
        print(f"➖ {current_user.username} unfollowed {user_id[:8]}…")
        return {"status": "unfollowed", "message": "Unfollowed"}

    # Treat missing follow as success so the client UI stays consistent
    # even if a tap got duplicated.
    return {"status": "not_following", "message": "Was not following"}


@router.get("/follow/status/{user_id}")
def get_follow_status(
    user_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Quick check: am I following this user? Used by profile views.

    🔴 BUG FIX (2026-05-21) — all reads filter `status == "accepted"`.
    A `pending` row (a not-yet-approved request to follow a private
    account) must NOT count as a follower and must report
    `is_following = False`, otherwise the privacy fix in
    `follow_user` would leak ("requested but already shows as a
    follower").
    """
    from models import UserFollow

    my_row = db.query(UserFollow).filter(
        UserFollow.follower_id == current_user.id,
        UserFollow.followee_id == user_id,
    ).first()
    is_following = my_row is not None and my_row.status == "accepted"
    is_requested = my_row is not None and my_row.status == "pending"

    follower_count = db.query(UserFollow).filter(
        UserFollow.followee_id == user_id,
        UserFollow.status == "accepted",
    ).count()
    following_count = db.query(UserFollow).filter(
        UserFollow.follower_id == user_id,
        UserFollow.status == "accepted",
    ).count()

    return {
        "is_following": is_following,
        "is_requested": is_requested,
        "follower_count": follower_count,
        "following_count": following_count,
    }


# ═══════════════════════════════════════════════════════════════════════════
# 🔴 BUG FIX (2026-05-21) — pending follow-request approval endpoints.
#
# When `follow_user` targets a PRIVATE account it now creates a
# `UserFollow` row with `status="pending"`. These three endpoints let
# the private account see and act on those pending requests — the
# missing other half of the privacy fix. Without an accept path a
# pending follow could never become a real follow (that was the
# original "accepting a follow request does nothing" bug).
# ═══════════════════════════════════════════════════════════════════════════


@router.get("/follow/pending")
def list_pending_follow_requests(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """List follow requests awaiting MY approval (I'm a private
    account and these users asked to follow me)."""
    from models import UserFollow

    rows = db.query(UserFollow).filter(
        UserFollow.followee_id == current_user.id,
        UserFollow.status == "pending",
    ).order_by(UserFollow.created_at.desc()).all()

    out = []
    for r in rows:
        u = db.query(User).filter(User.id == r.follower_id).first()
        out.append({
            "follow_id": r.id,
            "follower_id": r.follower_id,
            "follower_username": u.username if u else "unknown",
            "follower_avatar": u.avatar_path if u else None,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        })
    return out


async def _notify_follow_request_accepted(
    db: Session, follow_row, accepter: User
) -> None:
    """🔵 (2026-05-22) — Notify a follower that `accepter` (a private
    account) approved their follow request: an in-app Notification
    row plus an APNs push. Mirrors `_notify_friend_request_accepted`.
    Best-effort — a notification failure must never fail the accept.

    Added because approving a pending follow produced no signal at
    all, so the follower never learned their request went through."""
    try:
        follower = db.query(User).filter(
            User.id == follow_row.follower_id
        ).first()
        if not follower:
            return
        import json as _json
        from models import Notification
        db.add(Notification(
            user_id=follower.id,
            type="follow_accepted",
            # 🔵 (2026-05-23) — `requester_*` aliases for the iOS row.
            data=_json.dumps({
                "user_id": accepter.id,
                "username": accepter.username,
                "follow_id": follow_row.id,
                "requester_id": accepter.id,
                "requester_username": accepter.username,
                "requester_avatar": accepter.avatar_path,
            }),
            is_read=False,
        ))
        db.commit()
        # APNs push — best-effort, iOS only, respects the user's prefs.
        if follower.push_token and follower.push_platform == "ios":
            from services.apns_service import get_apns_service, APNsService
            prefs = APNsService.should_send_push(follower, "friend_request")
            if prefs["allowed"]:
                apns = get_apns_service()
                accepter_name = APNsService.build_push_display_name(accepter)
                await apns.send_push(
                    device_token=follower.push_token,
                    title="Follow Request Accepted",
                    body=f"{accepter_name} accepted your follow request",
                    data={
                        "type": "follow_accepted",
                        "accepter_id": accepter.id,
                    },
                    category="FRIEND_REQUEST",
                    badge=APNsService.get_unread_badge_count(db, follower.id),
                )
    except Exception as e:
        try:
            db.rollback()
        except Exception:
            pass
        print(f"⚠️ [FollowAccept] notify failed: {e}")


@router.post("/follow/pending/{follow_id}/accept")
async def accept_pending_follow_request(
    follow_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Approve a pending follow request → the follow becomes active.

    🔴 BUG FIX (2026-05-21) — this is the path that ACTUALLY creates
    the live follow. The old `accept_follow_request_alias` only
    flipped a `FriendRequest` row and never produced a `UserFollow`,
    so a follow could never complete. Here we flip the pending
    `UserFollow` row's `status` to `accepted` in place.

    🔵 (2026-05-22) — also notifies the follower (`follow_accepted`
    in-app row + APNs push); approving used to be completely silent.
    """
    from models import UserFollow

    row = db.query(UserFollow).filter(
        UserFollow.id == follow_id,
        UserFollow.followee_id == current_user.id,
        UserFollow.status == "pending",
    ).first()
    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Follow request not found"
        )

    row.status = "accepted"
    db.commit()
    print(f"✅ {current_user.username} accepted follow request {follow_id[:8]}…")
    await _notify_follow_request_accepted(db, row, current_user)
    return {"status": "accepted", "follower_id": row.follower_id}


@router.post("/follow/pending/{follow_id}/reject")
def reject_pending_follow_request(
    follow_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Decline a pending follow request → the pending row is deleted."""
    from models import UserFollow

    row = db.query(UserFollow).filter(
        UserFollow.id == follow_id,
        UserFollow.followee_id == current_user.id,
        UserFollow.status == "pending",
    ).first()
    if not row:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Follow request not found"
        )

    db.delete(row)
    db.commit()
    print(f"🚫 {current_user.username} rejected follow request {follow_id[:8]}…")
    return {"status": "rejected"}


# ═══════════════════════════════════════════════════════════════════════════
# 🔴 ROUND 26 (2026-05-16) — REAL ROUND-2 FIX.
#
# Audit-round-2 (after the user's repeated complaint) discovered four
# MORE missing endpoints that the iOS team called for months while
# the server 404'd silently:
#
#   GET    /api/users/follow-requests                  (list incoming)
#   POST   /api/users/follow-request/{id}/accept      (accept by req id)
#   POST   /api/users/follow-request/{id}/reject      (reject by req id)
#   DELETE /api/users/followers/{id}                  (kick a follower)
#
# These were named `follow-request` in iOS but semantically map to
# the existing friend-request flow (the model file is even called
# `FriendRequestsView.swift`). Rather than rename iOS — which would
# require coordinated app-update + carry-over auth state — we add
# server-side aliases that reuse the friend-request DB rows.
#
# The accept-response shape is intentionally different from
# `accept_friend_request` because iOS's `AcceptResponse` decoder
# expects `follower_*` keys (snake-case converted to `followerId`
# etc. by NetworkService). Returning `friend_*` would silently
# fail to decode and the iOS error path would fire — exactly the
# "tap accept, see no effect" symptom the user reported.
# ═══════════════════════════════════════════════════════════════════════════


@router.get("/follow-requests", response_model=List[FriendRequestResponse])
def get_follow_requests_alias(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Incoming requests awaiting MY approval — the data source for
    iOS `FriendRequestsView` / `AccountSettingsList`.

    🔵 (2026-05-22) — RECONCILES RAVEN'S TWO REQUEST SYSTEMS.
    iOS calls this one URL for its whole "Follow Requests" screen,
    but the server has two independent request tables:
      • `FriendRequest`                  — the mutual-friend handshake.
      • `UserFollow` (status="pending")  — a request to follow a
        PRIVATE account.
    The old alias returned only `FriendRequest` rows, so a private
    account's pending followers were invisible: the owner had no
    surface to accept or decline them. We now merge both. A
    `UserFollow` row is exposed under its own `id`, which
    `accept_follow_request_alias` / `reject_follow_request_alias`
    resolve back to the correct table."""
    from models import UserFollow

    result = get_friend_requests(current_user=current_user, db=db)

    pending_follows = db.query(UserFollow).filter(
        UserFollow.followee_id == current_user.id,
        UserFollow.status == "pending",
    ).order_by(UserFollow.created_at.desc()).all()

    for uf in pending_follows:
        follower = db.query(User).filter(User.id == uf.follower_id).first()
        # A half-onboarded follower (no @username yet) can't render in
        # the FriendRequestResponse shape — skip rather than 500.
        if not follower or not follower.username:
            continue
        result.append(FriendRequestResponse(
            id=uf.id,
            requester_id=uf.follower_id,
            requester_username=follower.username,
            requester_avatar=follower.avatar_path,
            recipient_id=current_user.id,
            status="pending",
            created_at=uf.created_at or datetime.utcnow(),
        ))

    print(f"📥 {current_user.username} has {len(result)} pending requests "
          f"({len(pending_follows)} follow)")
    return result


@router.post("/follow-request/{request_id}/accept")
async def accept_follow_request_alias(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Accept an incoming request, returning the `follower_*` response
    shape iOS's `AcceptResponse` decoder expects.

    🔵 (2026-05-22) — `request_id` may be a `FriendRequest.id` OR a
    pending `UserFollow.id` (a private account approving a
    follower — see `get_follow_requests_alias`). We try the
    friend-request table first, then fall back to the follow table,
    so the single iOS accept button works for both.
    """
    from models import UserFollow

    friend_request = db.query(FriendRequest).filter(
        FriendRequest.id == request_id,
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending"
    ).first()

    if friend_request:
        friend_request.status = "accepted"
        friend_request.updated_at = datetime.utcnow()
        db.commit()

        requester = db.query(User).filter(User.id == friend_request.requester_id).first()
        print(f"✅ {current_user.username} accepted follow request from {requester.username if requester else 'Unknown'}")

        # 🔴 Notify the requester their request was accepted (push + in-app).
        await _notify_friend_request_accepted(db, friend_request, current_user)

        return {
            "message": "Follow request accepted",
            "follower_id": requester.id if requester else None,
            "follower_username": requester.username if requester else "Unknown",
            "follower_avatar": requester.avatar_path if requester else None,
        }

    # 🔵 Fall back to a pending UserFollow (a private-account follower).
    follow_row = db.query(UserFollow).filter(
        UserFollow.id == request_id,
        UserFollow.followee_id == current_user.id,
        UserFollow.status == "pending",
    ).first()

    if follow_row:
        follow_row.status = "accepted"
        db.commit()

        follower = db.query(User).filter(User.id == follow_row.follower_id).first()
        print(f"✅ {current_user.username} accepted follow request from {follower.username if follower else 'Unknown'}")

        # 🔵 Notify the follower their request was approved (push + in-app).
        await _notify_follow_request_accepted(db, follow_row, current_user)

        return {
            "message": "Follow request accepted",
            "follower_id": follower.id if follower else None,
            "follower_username": follower.username if follower else "Unknown",
            "follower_avatar": follower.avatar_path if follower else None,
        }

    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail="Follow request not found"
    )


@router.post("/follow-request/{request_id}/reject")
def reject_follow_request_alias(
    request_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Reject an incoming request — a `FriendRequest` or a pending
    `UserFollow` (see `accept_follow_request_alias` for why both
    can land here). Declining a follow request is silent by design:
    the follower is not notified, matching standard social apps.
    """
    from models import UserFollow

    friend_request = db.query(FriendRequest).filter(
        FriendRequest.id == request_id,
        FriendRequest.recipient_id == current_user.id,
        FriendRequest.status == "pending",
    ).first()
    if friend_request:
        return reject_friend_request(request_id, current_user, db)

    # 🔵 Fall back to a pending UserFollow (a private-account follower).
    follow_row = db.query(UserFollow).filter(
        UserFollow.id == request_id,
        UserFollow.followee_id == current_user.id,
        UserFollow.status == "pending",
    ).first()
    if follow_row:
        db.delete(follow_row)
        db.commit()
        print(f"🚫 {current_user.username} rejected follow request {request_id[:8]}…")
        return {"message": "Follow request rejected"}

    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail="Follow request not found"
    )


@router.delete("/followers/{follower_id}")
def remove_follower(
    follower_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Remove a user from the caller's followers list. Bidirectional
    UI affordance — the followee can boot any follower at any time.
    Idempotent: missing row returns success.

    Deletes the `user_follows` row where `follower_id` = the kicked
    user and `followee_id` = the caller.
    """
    from models import UserFollow

    follow = db.query(UserFollow).filter(
        UserFollow.follower_id == follower_id,
        UserFollow.followee_id == current_user.id,
    ).first()

    if follow:
        db.delete(follow)
        db.commit()
        print(f"➖ {current_user.username} removed follower {follower_id[:8]}…")
        return {"success": True, "message": "Follower removed"}

    return {"success": True, "message": "Was not a follower"}


# ═══════════════════════════════════════════════════════════════════════════
# 🔴 ROUND 26 (2026-05-16) — REAL ROUND-2 FIX.
#
# iOS `NetworkService.uploadIdentityKey` POSTs to this endpoint once per
# session after login (see `RAVENApp.swift` post-sign-in hook). The body
# is `{publicKey: <base64 raw Ed25519 public key>}`, camelCase on the
# wire because `postCamelCase` deliberately skips snake conversion.
#
# Server-side persistence is the existing `User.public_key` column. We
# return `{status: "unchanged" | "updated"}` so iOS can tell whether
# the upload mattered. Without this endpoint, EVERY app launch logged
# a 404 in iOS's network error path and any code that depends on the
# server-side public key (qr-login attestation, mesh bridge signing)
# silently never worked.
# ═══════════════════════════════════════════════════════════════════════════


class IdentityKeyUpload(BaseModel):
    """iOS sends this in camelCase (postCamelCase path)."""
    publicKey: str


@router.post("/me/identity-key")
def upload_identity_key(
    body: IdentityKeyUpload,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Upload the device's Ed25519 raw public key. Idempotent —
    returns `unchanged` when the key matches what's already on file.

    Validation:
      • non-empty
      • length cap (32-byte raw key base64-encodes to ~44 chars; we
        accept up to 256 chars to leave headroom for future key
        formats without redeploying).
    """
    key = (body.publicKey or "").strip()
    if not key:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="publicKey must be a non-empty base64 string"
        )
    if len(key) > 256:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="publicKey too long (max 256 chars)"
        )

    if current_user.public_key == key:
        return {"status": "unchanged"}

    current_user.public_key = key
    db.commit()
    print(f"🔑 Identity key updated for {current_user.username} ({key[:8]}…)")
    return {"status": "updated"}

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
    #
    # 🔴 ROUND 36 (2026-05-19) — avatar URL spoofing fix.
    #
    # PREVIOUSLY: `"storage.googleapis.com" in parsed.netloc` is a
    # SUBSTRING check, not an exact-host match. An attacker could
    # spoof a GCS URL with hosts like:
    #   • storage.googleapis.com.evil.com
    #   • evilstorage.googleapis.com.attacker.io
    #   • my-malicious-bucket.fake-storage.googleapis.com.attacker.net
    # All of these contain the literal "storage.googleapis.com" and
    # passed the gate. The stored avatar URL would then be served
    # whenever any client rendered the user's profile — turning the
    # attacker's host into a tracker, a bandwidth-leech, or a
    # phishing surface (e.g. serving HTML disguised as an image).
    #
    # FIX: require EXACT host match on `storage.googleapis.com` OR
    # a strict subdomain of it (`<anything>.storage.googleapis.com`,
    # which is the legitimate per-bucket form). Reject everything
    # else. Also lock the upload-path branch to relative-only so a
    # full URL pointing at a third party with `/uploads/...` in the
    # path can't smuggle through.
    if image_url.startswith("http://") or image_url.startswith("https://"):
        from urllib.parse import urlparse
        parsed = urlparse(image_url)
        host = (parsed.hostname or "").lower()
        is_gcs_exact = (host == "storage.googleapis.com")
        is_gcs_bucket_subdomain = host.endswith(".storage.googleapis.com")
        if is_gcs_exact or is_gcs_bucket_subdomain:
            pass  # Store as-is (real GCS URL only)
        else:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Invalid image URL format (host not allowed)"
            )
    elif image_url.startswith("/uploads/"):
        pass  # Relative server-upload path — safe
    else:
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
    """Get full user profile with stats, interests, and friendship status.

    🔴 ROUND 70 — rate limit the profile-view endpoint. Previously
    unlimited; one auth token + a UUID dictionary = unlimited
    profile-graph harvest. Cap at 120/min/caller.

    🔴 hacker-audit 2026-05-19 — privacy-gate the decrypted real
    name. PREVIOUSLY this endpoint returned `first_name` and
    `last_name` (decrypted from at-rest Fernet) to ANY authenticated
    user, regardless of whether the target had `is_private=True` or
    `who_can_see_profile != 'public'`. An attacker who knew a
    target's user_id (UUIDs leak through groups, posts, mentions,
    bug reports, server-error logs) could harvest the legal name of
    every "private" user just by hitting this endpoint with their
    own auth token. Same gap as the `search` endpoint had pre-round
    42 — fixed there, missed here.
    NOW: real-name + bio + interests + bio_song are returned only
    when (a) the viewer IS the target, or (b) the target is not
    private AND profile is publicly visible AND viewer isn't on
    the target's block list. Otherwise we return the minimum shape
    Instagram-style (username, avatar, post count, friend status)
    plus an explicit `is_private: true` flag so the client UI knows.
    """
    # Round 70 — rate limit (per-caller). 120/min is generous for any
    # legitimate UI burst (chat-row avatar resolution, mention tap,
    # search → tap) and far below what an attacker needs for bulk
    # enumeration.
    rate_limiter.check_rate_limit(
        identifier=f"profile_view:{current_user.id}",
        max_attempts=120,
        window_minutes=1,
        lockout_minutes=5,
    )

    user = db.query(User).filter(User.id == user_id).first()

    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )

    # 🔴 ROUND 70 — also block-check: if the target has blocked the
    # caller, return 404 so the caller can't even confirm existence.
    try:
        from models import Block
        blocked = db.query(Block).filter(
            Block.blocker_id == user_id,
            Block.blocked_id == current_user.id,
        ).first()
        if blocked is not None and user_id != current_user.id:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="User not found"
            )
    except HTTPException:
        raise
    except Exception:
        pass

    # Count posts
    post_count = db.query(Post).filter(Post.author_id == user_id).count()
    
    # Count followers (friend requests where user is recipient and accepted)
    followers_count = db.query(FriendRequest).filter(
        FriendRequest.recipient_id == user_id,
        FriendRequest.status == "accepted"
    ).count()
    
    # Count following (friend requests where user is requester and accepted)
    following_count = db.query(FriendRequest).filter(
        FriendRequest.requester_id == user_id,
        FriendRequest.status == "accepted"
    ).count()
    
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

    # 🔴 hacker-audit 2026-05-19 — privacy gating on the actual fields.
    is_self = user_id == current_user.id
    is_private = bool(getattr(user, "is_private", False))
    is_friend = friendship_status == "friends"
    is_blocked_by_target = False
    if not is_self:
        from models import Block
        is_blocked_by_target = db.query(Block).filter(
            Block.blocker_id == user.id,
            Block.blocked_id == current_user.id,
        ).first() is not None

    # If target blocked the caller, behave like the user doesn't exist.
    if is_blocked_by_target:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    # Determine whether to expose the "rich" view (real name, bio,
    # interests, bio_song). Rich view = self, friend, or non-private
    # publicly-visible profile.
    who_can_see = (getattr(user, "who_can_see_profile", None) or "public").lower()
    expose_rich = is_self or is_friend or (
        not is_private and who_can_see == "public"
    )

    base = {
        "id": user.id,
        "username": user.username,
        "display_name": user.username,
        "avatar_path": user.avatar_path,
        "avatar_url": user.avatar_path,
        "stats": {
            "posts": post_count,
            "followers": followers_count,
            "following": following_count,
            "friends": followers_count + following_count,
        },
        "friendship": {
            "status": friendship_status,
            "request_id": friendship_request_id,
        },
        "is_verified": user.is_verified or False,
        "is_premium": user.is_premium or False,
        "is_private": is_private,
    }
    if expose_rich:
        base.update({
            "first_name": decrypt_text(user.first_name) if user.first_name else None,
            "last_name": decrypt_text(user.last_name) if user.last_name else None,
            "bio": user.bio,
            "interests": interests,
            "bio_song": bio_song,
            "created_at": user.created_at.isoformat() if user.created_at else None,
        })
    return base


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

    🔴 ROUND 70 — rate-limit (same budget as /{user_id}). Was
    previously unlimited; combined with `lastActiveAt` being
    visible by default, an attacker could build per-user activity
    timelines by polling.
    """
    rate_limiter.check_rate_limit(
        identifier=f"profile_summary:{current_user.id}",
        max_attempts=120,
        window_minutes=1,
        lockout_minutes=5,
    )

    # Find user
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    # 🔴 ROUND 70 — block-check.
    try:
        from models import Block
        blocked = db.query(Block).filter(
            Block.blocker_id == user_id,
            Block.blocked_id == current_user.id,
        ).first()
        if blocked is not None and user_id != current_user.id:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    except HTTPException:
        raise
    except Exception:
        pass
    
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
    
    # 🔴 hacker-audit 2026-05-19 — last_login leak.
    # PREVIOUSLY this endpoint always returned `lastActiveAt` (the
    # User.last_login timestamp) regardless of the target's
    # `show_online_status` setting. Same field is gated correctly on
    # /api/presence/{user_id} but was leaking here. An attacker who
    # disabled the privacy toggle on their side could still scrape
    # last-active times for a watchlist by polling profileSummary.
    # Mirror the presence-endpoint policy.
    show_online = bool(getattr(user, "show_online_status", True))
    last_active = user.last_login if (show_online or user.id == current_user.id) else None

    return {
        "postsCount": posts_count,
        "friendsCount": friends_count,
        "isFriend": is_friend,
        "requestStatus": request_status,
        "isNotifyEnabled": is_notify_enabled,
        "isOnline": False,  # TODO: Implement presence
        "lastActiveAt": last_active,
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
    friends_count = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        or_(
            FriendRequest.requester_id == user_id,
            FriendRequest.recipient_id == user_id
        )
    ).count()
    
    # Check friendship
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

    # Privacy
    is_private = getattr(user, 'is_private', False)
    is_self = user_id == current_user.id

    # 🔵 (2026-05-22) — real follow-state from the `user_follows` table.
    # PREVIOUSLY this endpoint returned only `requestStatus` (the FRIEND
    # system) and NO `followStatus`. The iOS follow button is driven by
    # `followStatus`, so a profile you ALREADY follow still rendered a
    # "Follow" button — and tapping it merely surfaced the true state
    # ("Friends" / "Following"), the exact "I tap Follow and it jumps to
    # Friends" bug. Computing it here makes the button correct on first
    # render; "requested" makes a pending private-account request show
    # as "Requested" instead of an actionable "Follow".
    from models import UserFollow
    follow_status = "self" if is_self else "none"
    is_following_you = False
    if not is_self:
        my_follow = db.query(UserFollow).filter(
            UserFollow.follower_id == current_user.id,
            UserFollow.followee_id == user_id,
        ).first()
        is_following_you = db.query(UserFollow).filter(
            UserFollow.follower_id == user_id,
            UserFollow.followee_id == current_user.id,
            UserFollow.status == "accepted",
        ).first() is not None
        if my_follow:
            if my_follow.status == "pending":
                follow_status = "requested"
            elif is_following_you:
                follow_status = "mutual"
            else:
                follow_status = "following"

    # 🔴 hacker-audit 2026-05-19 — block + privacy gating.
    from models import Block
    is_blocked = db.query(Block).filter(
        Block.blocker_id == current_user.id,
        Block.blocked_id == user_id
    ).first() is not None
    is_blocked_by_target = False
    if not is_self:
        is_blocked_by_target = db.query(Block).filter(
            Block.blocker_id == user_id,
            Block.blocked_id == current_user.id,
        ).first() is not None
    if is_blocked_by_target:
        # Target blocked us — present as not-found, same as
        # GET /users/{id} above.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    who_can_see = (getattr(user, "who_can_see_profile", None) or "public").lower()
    expose_rich = is_self or is_friend or (not is_private and who_can_see == "public")

    # Get display name — only decrypt when we'll actually expose it.
    display_name = None
    if expose_rich:
        first_name = decrypt_text(user.first_name) if user.first_name else None
        last_name = decrypt_text(user.last_name) if user.last_name else None
        display_name = f"{first_name or ''} {last_name or ''}".strip() or None

    # Birthday: only show if user allows it AND rich view is exposed.
    show_birthday = getattr(user, 'show_birthday', False)
    birthday = user.birthday if (show_birthday and expose_rich) else None

    # Can current user message this user?
    who_can_msg = getattr(user, 'who_can_message', 'everyone')
    can_message = True
    if who_can_msg == 'friends' and not is_friend:
        can_message = False

    return {
        "id": user.id,
        "username": user.username,
        "displayName": display_name,
        "avatarUrl": user.avatar_path,
        # Bio + joinedAt are part of the rich view too.
        "bio": user.bio if expose_rich else None,
        "joinedAt": user.created_at if expose_rich else None,
        "birthday": birthday,
        "isPrivate": is_private,
        "showBirthday": show_birthday,
        "isVerified": user.is_verified or False,
        "isPremium": user.is_premium or False,
        "postsCount": posts_count,
        "friendsCount": friends_count,
        "isFriend": is_friend,
        "requestStatus": request_status,
        "followStatus": follow_status,
        "isFollowingYou": is_following_you,
        "canMessage": can_message,
        "isBlocked": is_blocked,
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

    # 🔒 SECURITY (audit H9 — block bypass): mirror get_user's block
    # gate. If the target has blocked the caller, return 404 so a
    # blocked user cannot read the target's posts. Without this, the
    # is_private-only check below leaves every public account's posts
    # readable by someone they've blocked.
    if user_id != current_user.id:
        from models import Block
        if db.query(Block).filter(
            Block.blocker_id == user_id,
            Block.blocked_id == current_user.id,
        ).first() is not None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

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

    # 🔒 SECURITY (audit H9 — block bypass): mirror get_user's block
    # gate so a blocked user cannot enumerate the target's friend graph
    # (ids, usernames, decrypted names, bios).
    if user_id != current_user.id:
        from models import Block
        if db.query(Block).filter(
            Block.blocker_id == user_id,
            Block.blocked_id == current_user.id,
        ).first() is not None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

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
