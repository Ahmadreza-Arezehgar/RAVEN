"""
Discovery router — Suggested Friends endpoint.

Provides personalized friend suggestions combining:
  A) Contact-based matches (users whose phone hash was synced)
  B) Algorithmic suggestions (mutual friends, mutual groups, geo, interests, activity)

Scoring formula:
  Score(u) = 5*mutualFriends + 3*mutualGroups + 2*sameGeoBucket + 1*sharedInterests
             + recencyBoost - alreadySeenPenalty
"""

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.orm import Session
from sqlalchemy import func, and_, or_
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime, timedelta
from database import get_db
from auth import get_current_user
import models
import json
from encryption import decrypt_text
import logging

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/discovery", tags=["discovery"])


# ==================== Response Models ====================

class SuggestedUserItem(BaseModel):
    user_id: str
    username: str
    display_name: str
    avatar_url: Optional[str] = None
    source: str  # "contacts" or "algorithm"
    reason: str  # e.g. "From your contacts", "3 mutual friends"
    mutual_friends_count: int = 0


class SuggestedFriendsResponse(BaseModel):
    items: List[SuggestedUserItem]


# ==================== Helpers ====================

def _get_excluded_ids(db: Session, user_id: str) -> set:
    """Get IDs that should be excluded from suggestions:
    - Self
    - Existing friends (bidirectional)
    - Blocked (either direction)
    - Pending friend requests (either direction)
    """
    excluded = {user_id}

    # Existing friends
    friendships = db.query(models.FriendRequest).filter(
        models.FriendRequest.status == "accepted",
        or_(
            models.FriendRequest.requester_id == user_id,
            models.FriendRequest.recipient_id == user_id
        )
    ).all()
    for f in friendships:
        excluded.add(f.requester_id)
        excluded.add(f.recipient_id)

    # Blocks
    blocks = db.query(models.Block).filter(
        or_(
            models.Block.blocker_id == user_id,
            models.Block.blocked_id == user_id
        )
    ).all()
    for b in blocks:
        excluded.add(b.blocker_id)
        excluded.add(b.blocked_id)

    # Pending friend requests
    pending = db.query(models.FriendRequest).filter(
        models.FriendRequest.status == "pending",
        or_(
            models.FriendRequest.requester_id == user_id,
            models.FriendRequest.recipient_id == user_id
        )
    ).all()
    for p in pending:
        excluded.add(p.requester_id)
        excluded.add(p.recipient_id)

    return excluded


def _get_my_friends(db: Session, user_id: str) -> set:
    """Get the set of user IDs who are friends with user_id."""
    my_friends = set()
    friendships = db.query(models.FriendRequest).filter(
        models.FriendRequest.status == "accepted",
        or_(
            models.FriendRequest.requester_id == user_id,
            models.FriendRequest.recipient_id == user_id
        )
    ).all()
    for f in friendships:
        other = f.recipient_id if f.requester_id == user_id else f.requester_id
        my_friends.add(other)
    return my_friends


def _get_contact_suggestions(
    db: Session, user: models.User, excluded_ids: set,
    my_friends: set, limit: int = 5
) -> List[SuggestedUserItem]:
    """
    Get suggestions from user's synced contacts.
    Matches users whose phone_hash is set and allow_contact_discovery is True.
    Prioritizes users with more mutual friends and recent activity.
    """
    query = db.query(models.User).filter(
        models.User.allow_contact_discovery == True,
        models.User.phone_hash.isnot(None),
        or_(models.User.status == 'active', models.User.status.is_(None)),
        models.User.id.notin_(excluded_ids)
    )

    # Get all candidates
    contact_candidates = query.all()

    if not contact_candidates:
        return []

    # Score contact candidates by mutual friends and activity
    now = datetime.utcnow()
    day_ago = now - timedelta(hours=24)
    scored = []

    for u in contact_candidates:
        # Count mutual friends
        their_friends = set()
        their_friendships = db.query(models.FriendRequest).filter(
            models.FriendRequest.status == "accepted",
            or_(
                models.FriendRequest.requester_id == u.id,
                models.FriendRequest.recipient_id == u.id
            )
        ).all()
        for f in their_friendships:
            other = f.recipient_id if f.requester_id == u.id else f.requester_id
            their_friends.add(other)

        mutual_count = len(my_friends & their_friends)

        # Recency boost
        recency = 2 if (u.last_login and u.last_login > day_ago) else 0

        score = 5 * mutual_count + recency

        first = decrypt_text(u.first_name) if u.first_name else ""
        last = decrypt_text(u.last_name) if u.last_name else ""
        display_name = f"{first} {last}".strip()
        if not display_name:
            display_name = u.username or "Unknown"

        reason = "From your contacts"
        if mutual_count > 0:
            reason += f" · {mutual_count} mutual friend{'s' if mutual_count != 1 else ''}"

        scored.append((score, SuggestedUserItem(
            user_id=u.id,
            username=u.username or "",
            display_name=display_name,
            avatar_url=u.avatar_path,
            source="contacts",
            reason=reason,
            mutual_friends_count=mutual_count
        )))

    # Sort by score descending
    scored.sort(key=lambda x: x[0], reverse=True)
    return [item for _, item in scored[:limit]]


def _parse_hobbies(user) -> set:
    """Parse the JSON hobbies field into a set of lowercase strings."""
    if not user.hobbies:
        return set()
    try:
        hobbies = json.loads(user.hobbies)
        if isinstance(hobbies, list):
            return {h.lower().strip() for h in hobbies if isinstance(h, str)}
    except (json.JSONDecodeError, TypeError):
        pass
    return set()


def _get_algorithmic_suggestions(
    db: Session, user_id: str, user: models.User,
    excluded_ids: set, contact_ids: set,
    my_friends: set, limit: int = 5
) -> List[SuggestedUserItem]:
    """
    Get algorithmic suggestions based on:
    - Mutual friends count (weight 5)
    - Mutual groups count (weight 3)
    - Same geo bucket (weight 2) — geohash prefix matching
    - Shared interests/hobbies (weight 1)
    - Recency boost (+2 if active in 24h, +1 if active in 7d)
    """
    all_excluded = excluded_ids | contact_ids

    # --- Step 1: Get user's group IDs ---
    my_groups = set()
    memberships = db.query(models.GroupMember.group_id).filter(
        models.GroupMember.user_id == user_id
    ).all()
    my_groups = {m.group_id for m in memberships}

    # --- Step 2: Get user's geohash prefix (first 4 chars) ---
    my_geo_prefix = None
    # Try to get from user's most recent post with geohash
    recent_post = db.query(models.Post).filter(
        models.Post.author_id == user_id,
        models.Post.geohash.isnot(None)
    ).order_by(models.Post.timestamp.desc()).first()
    if recent_post and recent_post.geohash:
        my_geo_prefix = recent_post.geohash[:4]

    # --- Step 3: Get user's interests ---
    my_interests = _parse_hobbies(user)

    # --- Step 4: Find candidates (friends-of-friends + group-mates) ---
    candidates: dict = {}  # user_id -> {mutual_friends, mutual_groups, same_geo, shared_interests}

    # 4a: Friends of friends
    if my_friends:
        fof_friendships = db.query(models.FriendRequest).filter(
            models.FriendRequest.status == "accepted",
            or_(
                models.FriendRequest.requester_id.in_(my_friends),
                models.FriendRequest.recipient_id.in_(my_friends)
            )
        ).all()

        for f in fof_friendships:
            for candidate_id in (f.requester_id, f.recipient_id):
                if candidate_id in all_excluded or candidate_id in my_friends:
                    continue
                if candidate_id not in candidates:
                    candidates[candidate_id] = {
                        "mutual_friends": 0, "mutual_groups": 0,
                        "same_geo": False, "shared_interests": 0,
                        "source_type": "mutual"
                    }
                connector = f.requester_id if f.recipient_id == candidate_id else f.recipient_id
                if connector in my_friends:
                    candidates[candidate_id]["mutual_friends"] += 1

    # 4b: Group-mates
    if my_groups:
        group_mates = db.query(models.GroupMember).filter(
            models.GroupMember.group_id.in_(my_groups),
            models.GroupMember.user_id != user_id,
            models.GroupMember.user_id.notin_(all_excluded)
        ).all()

        for gm in group_mates:
            cid = gm.user_id
            if cid in my_friends:
                continue
            if cid not in candidates:
                candidates[cid] = {
                    "mutual_friends": 0, "mutual_groups": 0,
                    "same_geo": False, "shared_interests": 0,
                    "source_type": "group"
                }
            candidates[cid]["mutual_groups"] += 1

    if not candidates:
        # Fallback: recently active users
        fallback_users = db.query(models.User).filter(
            or_(models.User.status == 'active', models.User.status.is_(None)),
            models.User.id.notin_(all_excluded)
        ).order_by(
            models.User.last_login.desc().nullslast()
        ).limit(limit).all()
        
        logger.info(f"📊 Discovery fallback: found {len(fallback_users)} users")

        results = []
        for u in fallback_users:
            first = decrypt_text(u.first_name) if u.first_name else ""
            last = decrypt_text(u.last_name) if u.last_name else ""
            display_name = f"{first} {last}".strip()
            if not display_name:
                display_name = u.username or "Unknown"
            results.append(SuggestedUserItem(
                user_id=u.id,
                username=u.username or "",
                display_name=display_name,
                avatar_url=u.avatar_path,
                source="algorithm",
                reason="Suggested for you",
                mutual_friends_count=0
            ))
        return results

    # --- Step 5: Score candidates ---
    now = datetime.utcnow()
    day_ago = now - timedelta(hours=24)
    week_ago = now - timedelta(days=7)

    scored: list = []
    candidate_ids = list(candidates.keys())

    # Fetch user objects for candidates
    candidate_users = db.query(models.User).filter(
        models.User.id.in_(candidate_ids),
        or_(models.User.status == 'active', models.User.status.is_(None))
    ).all()

    user_map = {u.id: u for u in candidate_users}

    # Check geo bucket for candidates
    if my_geo_prefix:
        geo_posts = db.query(
            models.Post.author_id,
            func.max(models.Post.geohash).label('geohash')
        ).filter(
            models.Post.author_id.in_(candidate_ids),
            models.Post.geohash.isnot(None)
        ).group_by(models.Post.author_id).all()

        for gp in geo_posts:
            if gp.author_id in candidates and gp.geohash and gp.geohash[:4] == my_geo_prefix:
                candidates[gp.author_id]["same_geo"] = True

    # Diversity tracking: limit sources
    source_counts = {"mutual": 0, "group": 0, "interest": 0, "fallback": 0}
    max_per_source = max(3, limit)

    for uid, signals in candidates.items():
        u = user_map.get(uid)
        if not u:
            continue

        mf = signals["mutual_friends"]
        mg = signals["mutual_groups"]
        sg = 1 if signals["same_geo"] else 0

        # Shared interests
        their_interests = _parse_hobbies(u)
        si = len(my_interests & their_interests) if my_interests and their_interests else 0
        signals["shared_interests"] = si

        # Recency boost: +2 if 24h, +1 if 7d, 0 otherwise
        recency_boost = 0
        if u.last_login:
            if u.last_login > day_ago:
                recency_boost = 2
            elif u.last_login > week_ago:
                recency_boost = 1

        score = 5 * mf + 3 * mg + 2 * sg + 1 * si + recency_boost

        # Build reason string
        reasons = []
        if mf > 0:
            reasons.append(f"{mf} mutual friend{'s' if mf != 1 else ''}")
        if mg > 0:
            reasons.append(f"{mg} shared group{'s' if mg != 1 else ''}")
        if sg:
            reasons.append("Nearby")
        if si > 0:
            reasons.append(f"{si} shared interest{'s' if si != 1 else ''}")
        reason = " · ".join(reasons) if reasons else "Suggested for you"

        first = decrypt_text(u.first_name) if u.first_name else ""
        last = decrypt_text(u.last_name) if u.last_name else ""
        display_name = f"{first} {last}".strip()
        if not display_name:
            display_name = u.username or "Unknown"

        scored.append((score, signals["source_type"], SuggestedUserItem(
            user_id=u.id,
            username=u.username or "",
            display_name=display_name,
            avatar_url=u.avatar_path,
            source="algorithm",
            reason=reason,
            mutual_friends_count=mf
        )))

    # Sort by score descending
    scored.sort(key=lambda x: x[0], reverse=True)

    # Diversity enforcement: max 3 from any single source_type
    result = []
    for _, src, item in scored:
        if len(result) >= limit:
            break
        if source_counts.get(src, 0) < max_per_source:
            result.append(item)
            source_counts[src] = source_counts.get(src, 0) + 1

    return result


# ==================== Endpoint ====================

@router.get("/suggested", response_model=SuggestedFriendsResponse)
async def get_suggested_friends(
    response: Response,
    limit: int = Query(default=10, ge=1, le=200),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user)
):
    """
    Get personalized friend suggestions.

    Returns up to `limit` suggestions:
    - First half: contact-based matches (users on Raven from your phone contacts)
    - Second half: algorithmic (mutual friends, mutual groups, geo, interests, activity)

    Default limit=10 for the feed section.
    Use limit=200 for the "See All" sheet.
    """
    contact_limit = limit // 2
    algo_limit = limit - contact_limit

    # Get exclusion set and friends
    excluded = _get_excluded_ids(db, current_user.id)
    my_friends = _get_my_friends(db, current_user.id)

    # A) Contact-based suggestions
    contact_suggestions = _get_contact_suggestions(
        db, current_user, excluded, my_friends, contact_limit
    )

    # B) Algorithmic suggestions (exclude contact matches too)
    contact_user_ids = {s.user_id for s in contact_suggestions}
    algo_suggestions = _get_algorithmic_suggestions(
        db, current_user.id, current_user, excluded,
        contact_user_ids, my_friends, algo_limit
    )

    # If one side has fewer, fill from the other
    total = contact_suggestions + algo_suggestions
    if len(total) < limit:
        remaining = limit - len(total)
        already_ids = {s.user_id for s in total}
        extra = _get_algorithmic_suggestions(
            db, current_user.id, current_user,
            excluded | already_ids, set(), my_friends, remaining
        )
        total.extend(extra)

    # Cache headers: suggest client caches for 6 hours
    response.headers["Cache-Control"] = "private, max-age=21600"  # 6h

    logger.info(
        f"👥 Discovery for user {current_user.id}: "
        f"contacts={len(contact_suggestions)}, algo={len(algo_suggestions)}, "
        f"total={len(total)}"
    )

    return SuggestedFriendsResponse(items=total[:limit])
