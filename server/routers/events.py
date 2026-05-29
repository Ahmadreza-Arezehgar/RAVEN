"""
Events router for tracking user interactions (Phase 2: Event Tracking System)

Event types:
- view_post (with duration_ms)
- like_post  
- comment_post
- share_post
- search_query
- click_hashtag
- follow_user
"""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional
from datetime import datetime

from database import get_db
from models import User, UserEvent, UserInterest, UserActionLog
from routers.users import get_current_user

router = APIRouter(prefix="/api/events", tags=["events"])


# ==================== Request Models ====================

class ViewEventRequest(BaseModel):
    post_id: str
    duration_ms: int  # Dwell time in milliseconds


class InteractionEventRequest(BaseModel):
    post_id: str
    event_type: str  # like_post, comment_post, share_post


class SearchEventRequest(BaseModel):
    query: str


class HashtagClickRequest(BaseModel):
    hashtag: str


# 🔴 ROUND 26 — unified user-action telemetry.
class UserActionLogRequest(BaseModel):
    """
    Single user-driven button press: block, report, follow, accept,
    decline, like, repost, bookmark, etc. The iOS / Android client
    fires this as a background fire-and-forget POST every time the
    user taps an action button — see UserActionTelemetry on the
    client side.
    """
    action: str  # e.g. "like", "unlike", "block", "follow", "report", "bookmark"
    target_id: Optional[str] = None
    target_type: Optional[str] = None  # "post" | "user" | "comment" | "message" | "group" | …
    metadata: Optional[dict] = None
    client: Optional[str] = None       # "ios" | "android" | "mac" | "web"


# ==================== Interest Scoring Weights ====================

INTEREST_WEIGHTS = {
    "view_post": 1,      # view (dwell>3s): +1
    "like_post": 3,      # like: +3
    "comment_post": 4,   # comment: +4
    "share_post": 5,     # share: +5
    "click_hashtag": 2,  # click hashtag: +2
    "search_query": 2    # search query match: +2
}

MIN_DWELL_MS = 3000  # Minimum dwell time (3 seconds) to count as a meaningful view


# ==================== Helper Functions ====================

def update_user_interests(db: Session, user_id: str, tags: list, event_type: str):
    """
    Update user interest scores based on event type.
    Creates new interest entries if they don't exist.
    """
    weight = INTEREST_WEIGHTS.get(event_type, 1)
    
    for tag in tags:
        # Clean and normalize the tag
        clean_tag = tag.lower().strip().replace("#", "")
        if not clean_tag:
            continue
        
        # Find or create interest entry
        interest = db.query(UserInterest).filter(
            UserInterest.user_id == user_id,
            UserInterest.tag == clean_tag
        ).first()
        
        if interest:
            interest.score += weight
            interest.updated_at = datetime.utcnow()
        else:
            import uuid
            interest = UserInterest(
                id=str(uuid.uuid4()),
                user_id=user_id,
                tag=clean_tag,
                score=weight,
                updated_at=datetime.utcnow()
            )
            db.add(interest)
    
    db.commit()


def extract_hashtags_from_content(content: str) -> list:
    """Extract hashtags from post content."""
    import re
    hashtags = re.findall(r'#(\w+)', content or "")
    return hashtags


# ==================== Endpoints ====================

@router.post("/view")
def log_view_event(
    req: ViewEventRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Log a post view event with dwell time.
    Only counts towards interests if dwell_ms >= 3000ms.
    """
    import uuid
    from models import Post
    from encryption import decrypt_text
    
    # Create event record
    event = UserEvent(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        event_type="view_post",
        post_id=req.post_id,
        duration_ms=req.duration_ms,
        created_at=datetime.utcnow()
    )
    db.add(event)
    
    # Only update interests if meaningful dwell time
    if req.duration_ms >= MIN_DWELL_MS:
        # Get post to extract hashtags
        post = db.query(Post).filter(Post.id == req.post_id).first()
        if post:
            content = decrypt_text(post.content) if post.content else ""
            hashtags = extract_hashtags_from_content(content)
            if hashtags:
                update_user_interests(db, current_user.id, hashtags, "view_post")
    
    db.commit()
    
    print(f"👁️ View event: {current_user.username} viewed post {req.post_id[:8]} for {req.duration_ms}ms")
    return {"status": "ok"}


@router.post("/interaction")
def log_interaction_event(
    req: InteractionEventRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Log a post interaction event (like, comment, share).
    Updates user interest profile based on post hashtags.
    """
    import uuid
    from models import Post
    from encryption import decrypt_text
    
    if req.event_type not in ["like_post", "comment_post", "share_post"]:
        raise HTTPException(status_code=400, detail="Invalid event type")
    
    # Create event record
    event = UserEvent(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        event_type=req.event_type,
        post_id=req.post_id,
        created_at=datetime.utcnow()
    )
    db.add(event)
    
    # Get post to extract hashtags
    post = db.query(Post).filter(Post.id == req.post_id).first()
    if post:
        content = decrypt_text(post.content) if post.content else ""
        hashtags = extract_hashtags_from_content(content)
        if hashtags:
            update_user_interests(db, current_user.id, hashtags, req.event_type)
    
    db.commit()
    
    print(f"🎯 Interaction: {current_user.username} {req.event_type} on post {req.post_id[:8]}")
    return {"status": "ok"}


@router.post("/search")
def log_search_event(
    req: SearchEventRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Log a search query event."""
    import uuid
    
    event = UserEvent(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        event_type="search_query",
        query=req.query,
        created_at=datetime.utcnow()
    )
    db.add(event)
    
    # Search terms could also be treated as interests
    words = [w.strip().lower() for w in req.query.split() if len(w) > 2]
    if words:
        update_user_interests(db, current_user.id, words, "search_query")
    
    db.commit()
    
    print(f"🔍 Search: {current_user.username} searched '{req.query}'")
    return {"status": "ok"}


@router.post("/action")
def log_user_action(
    req: UserActionLogRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    🔴 ROUND 26 — unified user-action telemetry endpoint.

    Records ONE user-driven button press into `user_action_logs`.
    The iOS / Android client fires this in the background for every
    meaningful action (block, report, follow, accept, decline, like,
    repost, bookmark, mute, etc.) so we have:
      • An audit trail of who did what to whom and when.
      • Engagement analytics per button / per surface.
      • Anti-abuse signal source (rate-limit reports / blocks).

    The endpoint is intentionally permissive — the client sends
    arbitrary `action` strings. We don't enforce an enum so the
    server doesn't need a redeploy every time the iOS team adds a
    new tracked button. Constrain length so a misbehaving client
    can't DoS via huge metadata blobs.
    """
    import uuid
    import json as _json

    action = (req.action or "").strip()[:64]
    if not action:
        # Soft reject empty actions — return 200 so a flaky client
        # can never block the user's UI on this background call.
        return {"status": "ok", "noop": True}

    metadata_str: Optional[str] = None
    if req.metadata:
        try:
            metadata_str = _json.dumps(req.metadata)[:2048]
        except Exception:
            metadata_str = None

    log = UserActionLog(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        action=action,
        target_id=(req.target_id or None),
        target_type=(req.target_type or None),
        metadata_json=metadata_str,
        client=(req.client or None),
        timestamp=datetime.utcnow()
    )
    db.add(log)
    db.commit()
    return {"status": "ok"}


@router.post("/hashtag")
def log_hashtag_click(
    req: HashtagClickRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Log when user clicks on a hashtag."""
    import uuid
    
    event = UserEvent(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        event_type="click_hashtag",
        hashtag=req.hashtag,
        created_at=datetime.utcnow()
    )
    db.add(event)
    
    # Update interest for this hashtag
    update_user_interests(db, current_user.id, [req.hashtag], "click_hashtag")
    
    db.commit()
    
    print(f"#️⃣ Hashtag click: {current_user.username} clicked #{req.hashtag}")
    return {"status": "ok"}


@router.get("/interests")
def get_user_interests(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 20
):
    """
    Get the current user's interest profile.
    Returns top interests sorted by score.
    """
    interests = db.query(UserInterest).filter(
        UserInterest.user_id == current_user.id
    ).order_by(UserInterest.score.desc()).limit(limit).all()
    
    return {
        "interests": [
            {"tag": i.tag, "score": round(i.score, 2), "updated_at": i.updated_at.isoformat()}
            for i in interests
        ]
    }
