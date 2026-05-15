"""
Recommendation router for personalized feed (Phase 4)

Scoring algorithm:
- contentScore = sum(userProfile[tag] for tag in post.hashtags)
- recencyScore = exp(-hours_since(post.created_at) / 24)
- popularityScore = log(1 + post.like_count + post.comment_count * 1.5)
- authorBoost = 0.2 if interacted_recently else 0
- diversityPenalty = -0.3 if too_many_same_tags else 0
- finalScore = 0.55*content + 0.25*recency + 0.15*popularity + authorBoost + diversityPenalty
"""

from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session
from datetime import datetime, timedelta
from typing import List
import math
import re

from database import get_db
from models import User, Post, UserInterest, SeenPost, UserEvent
from routers.users import get_current_user
from routers.posts import PostResponse, get_post_stats, get_batch_post_stats, get_batch_post_media, build_full_url, get_voice_and_collab_fields
from encryption import decrypt_text
from cache import cache, TTL_FEED

router = APIRouter(prefix="/api/feed", tags=["recommendation"])


# ==================== Helper Functions ====================

def get_user_interest_profile(db: Session, user_id: str) -> dict:
    """Get user's interest profile as a tag -> score dictionary."""
    interests = db.query(UserInterest).filter(
        UserInterest.user_id == user_id
    ).all()
    return {i.tag.lower(): i.score for i in interests}


def extract_hashtags(content: str) -> list:
    """Extract hashtags from post content."""
    return [tag.lower() for tag in re.findall(r'#(\w+)', content or "")]


def has_interacted_with_author_recently(db: Session, user_id: str, author_id: str, days: int = 7) -> bool:
    """Check if user has interacted with this author recently."""
    cutoff = datetime.utcnow() - timedelta(days=days)
    
    # Check for any event involving posts by this author
    from sqlalchemy import and_
    recent_event = db.query(UserEvent).join(
        Post, UserEvent.post_id == Post.id
    ).filter(
        and_(
            UserEvent.user_id == user_id,
            Post.author_id == author_id,
            UserEvent.created_at > cutoff
        )
    ).first()
    
    return recent_event is not None


def mark_post_as_seen(db: Session, user_id: str, post_id: str):
    """Mark a post as seen by the user."""
    import uuid
    
    # Check if already seen
    existing = db.query(SeenPost).filter(
        SeenPost.user_id == user_id,
        SeenPost.post_id == post_id
    ).first()
    
    if not existing:
        seen = SeenPost(
            id=str(uuid.uuid4()),
            user_id=user_id,
            post_id=post_id,
            seen_at=datetime.utcnow()
        )
        db.add(seen)
        db.commit()


def get_recently_seen_post_ids(db: Session, user_id: str, hours: int = 48) -> set:
    """Get post IDs that user has seen in the last N hours."""
    cutoff = datetime.utcnow() - timedelta(hours=hours)
    
    seen = db.query(SeenPost.post_id).filter(
        SeenPost.user_id == user_id,
        SeenPost.seen_at > cutoff
    ).all()
    
    return {s.post_id for s in seen}


def compute_post_score(
    post,
    content: str,
    user_profile: dict,
    db: Session,
    user_id: str,
    session_state: dict
) -> float:
    """
    Compute recommendation score for a post using weighted factors.

    Formula:
    score = w_lang * LangMatch + w_tags * TagSim + w_author * AuthorAffinity
          + w_media * MediaMatch + w_trend * TrendScore + w_fresh * Freshness
          - w_seen * SeenPenalty - w_repeat * AuthorFatigue - w_neg * NegativeSignals

    PERFORMANCE NOTE (2026-05-14):
    The negative-signals block formerly issued THREE per-post queries:
    Block, UserNegativeFeedback(author), UserNegativeFeedback(tag) for
    each tag. With ~500 candidates and ~3 tags average that meant
    ~2,500 sequential round-trips per `/api/feed/recommended` request,
    blowing past Cloud Run's 60-second response-deadline (504 timeout)
    for fresh users with cold caches. Callers now precompute three
    sets (`blocked_ids`, `negative_authors`, `negative_tags`) ONCE and
    pass them in via `session_state`. Per-post work drops to in-memory
    set membership.
    """
    from models import UserNegativeFeedback, Block, UserEvent
    
    # Weights (tuned per spec)
    W_LANG = 2.0
    W_TAGS = 3.0
    W_AUTHOR = 2.0
    W_MEDIA = 1.0
    W_TREND = 1.0
    W_FRESH = 1.5
    W_SEEN = 4.0
    W_REPEAT = 2.0
    W_NEG = 10.0
    
    post_tags = extract_hashtags(content)
    
    # ========================
    # 1. Language Match (0.0 - 1.0)
    # ========================
    lang_score = 0.2  # Default for unknown
    detected_lang = detect_language(content)
    user_lang = session_state.get('user_lang', 'en')
    if detected_lang == user_lang:
        lang_score = 1.0
    elif detected_lang in ['en', 'fa'] and user_lang in ['en', 'fa']:
        lang_score = 0.5  # Bilingual boost
    
    # ========================
    # 2. Tag Similarity (sum of matching weights)
    # ========================
    tag_score = sum(user_profile.get(tag, 0) for tag in post_tags)
    
    # ========================
    # 3. Author Affinity
    # ========================
    author_affinity = 0.0
    author_key = f"author:{post.author_id}"
    if author_key in user_profile:
        author_affinity = min(user_profile[author_key], 5.0)  # Cap at 5
    elif has_interacted_with_author_recently(db, user_id, post.author_id):
        author_affinity = 1.0
    
    # ========================
    # 4. Media Match (simple: 1.0 for any content)
    # ========================
    media_score = 1.0 if post.image_url else 0.8  # Slight boost for images
    
    # ========================
    # 5. Trend Score (engagement rate)
    # ========================
    impressions = max(post.view_count or 1, 1)
    engagements = (post.likes or 0) + ((post.comment_count if hasattr(post, 'comment_count') else 0) * 2)
    trend_score = math.log(1 + engagements) / math.log(1 + impressions + 10)
    
    # ========================
    # 6. Freshness Boost (exponential decay, half-life 24h)
    # ========================
    hours_old = (datetime.utcnow() - post.timestamp).total_seconds() / 3600
    freshness = math.exp(-hours_old / 24)
    
    # ========================
    # 7. Seen Penalty (already handled in candidate filtering, but add small penalty)
    # ========================
    seen_penalty = 0.0  # Filtered out in candidates
    
    # ========================
    # 8. Author Fatigue (penalty if too many posts from same author in session)
    # ========================
    author_count = session_state.get('author_counts', {}).get(post.author_id, 0)
    author_fatigue = 1.0 if author_count >= 2 else 0.0
    # Update count for future posts
    if 'author_counts' not in session_state:
        session_state['author_counts'] = {}
    session_state['author_counts'][post.author_id] = author_count + 1
    
    # ========================
    # 9. Negative Signals (blocks, hides, reports)
    # ========================
    # PERFORMANCE FIX (2026-05-14): negative-signal lookups are now
    # in-memory set membership against precomputed structures the
    # caller injects through `session_state`. The previous version
    # made 1 + 1 + N (per-tag) DB queries PER POST, which exploded
    # to ~2,500 round-trips for a typical 500-candidate batch and
    # produced 504s on cold caches. See `_load_negative_sets()`.
    negative_score = 0.0
    blocked_ids = session_state.get('blocked_ids', frozenset())
    negative_authors = session_state.get('negative_authors', frozenset())
    negative_tags = session_state.get('negative_tags', frozenset())

    # Check if author is blocked
    if post.author_id in blocked_ids:
        return -1000.0  # Completely filter out

    # Check for negative feedback on this author
    if post.author_id in negative_authors:
        negative_score += 5.0  # Heavy penalty for hidden authors

    # Check for negative feedback on post tags
    for tag in post_tags:
        if tag in negative_tags:
            negative_score += 1.0  # Smaller penalty per tag
    
    # ========================
    # Final Score
    # ========================
    final_score = (
        W_LANG * lang_score +
        W_TAGS * tag_score +
        W_AUTHOR * author_affinity +
        W_MEDIA * media_score +
        W_TREND * trend_score +
        W_FRESH * freshness -
        W_SEEN * seen_penalty -
        W_REPEAT * author_fatigue -
        W_NEG * negative_score
    )
    
    return final_score


def detect_language(text: str) -> str:
    """Simple language detection using character ranges."""
    if not text:
        return 'unknown'
    
    # Persian/Arabic characters
    persian_pattern = re.compile(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]')
    persian_count = len(persian_pattern.findall(text))
    
    # Latin characters
    latin_pattern = re.compile(r'[a-zA-Z]')
    latin_count = len(latin_pattern.findall(text))
    
    total = persian_count + latin_count
    if total == 0:
        return 'unknown'
    
    if persian_count / total > 0.3:
        return 'fa'
    return 'en'


# ==================== Endpoints ====================

@router.get("/recommended", response_model=List[PostResponse])
def get_recommended_feed(
    request: Request,
    lang: str = 'en',  # User's UI language preference
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
    offset: int = 0
):
    """
    Get personalized "For You" feed based on user interests.
    
    Features:
    - 9-factor scoring (language, tags, author, media, trend, freshness, penalties)
    - Epsilon-greedy exploration: 85% scored + 15% fresh/diverse
    - Diversity: max 2 posts per author in top 10
    """
    from sqlalchemy import or_
    import random
    
    # Cache check (60s TTL for recommended — more expensive to compute)
    cache_key = f"feed:recommended:{current_user.id}:{lang}:{offset}:{limit}"
    cached = cache.get(cache_key)
    if cached is not None:
        return cached
    
    # Get user's interest profile
    user_profile = get_user_interest_profile(db, current_user.id)

    # Get recently seen posts to exclude
    seen_post_ids = get_recently_seen_post_ids(db, current_user.id)

    # Candidate posts: all public posts, scored by algorithm (no time cutoff)
    candidate_posts = db.query(Post).filter(
        or_(Post.visibility == 'public', Post.visibility == None)
    ).order_by(Post.timestamp.desc()).limit(500).all()  # Larger candidate pool

    # Filter out recently seen posts
    candidates = [p for p in candidate_posts if p.id not in seen_post_ids]

    # PERFORMANCE FIX (2026-05-14): precompute negative-signal sets
    # in three SELECT statements so per-post scoring becomes O(1)
    # set lookup. Previously each post triggered up to 1+1+N DB
    # round-trips inside `compute_post_score`, which exploded to
    # ~2,500 queries for a 500-candidate batch and produced 504
    # gateway timeouts on cold caches (reproducible for fresh users
    # without prior interactions).
    from models import Block, UserNegativeFeedback
    blocked_ids = {
        b.blocked_id for b in db.query(Block.blocked_id)
        .filter(Block.blocker_id == current_user.id).all()
    }
    neg_rows = db.query(UserNegativeFeedback.target_type, UserNegativeFeedback.target_id) \
        .filter(UserNegativeFeedback.user_id == current_user.id).all()
    negative_authors = {r.target_id for r in neg_rows if r.target_type == 'author'}
    negative_tags = {r.target_id for r in neg_rows if r.target_type == 'tag'}

    # Session state for tracking author fatigue during scoring
    session_state = {
        'user_lang': lang,
        'author_counts': {},
        'blocked_ids': frozenset(blocked_ids),
        'negative_authors': frozenset(negative_authors),
        'negative_tags': frozenset(negative_tags),
    }
    scored_posts = []

    for post in candidates:
        content = decrypt_text(post.content) if post.content else ""
        score = compute_post_score(post, content, user_profile, db, current_user.id, session_state)
        if score > -100:  # Filter out blocked content
            scored_posts.append((post, score, content))
    
    # Sort by score descending
    scored_posts.sort(key=lambda x: x[1], reverse=True)
    
    # ===== EPSILON-GREEDY EXPLORATION =====
    # 85% top-scored, 15% exploration (fresh authors, trending)
    EXPLORE_RATIO = 0.15
    explore_count = max(1, int(limit * EXPLORE_RATIO))
    exploit_count = limit - explore_count
    
    # Get exploit posts (top scored)
    exploit_posts = scored_posts[:exploit_count * 2]  # Extra pool for diversity filtering
    
    # Get explore posts (fresh authors not in top scored)
    top_authors = {p[0].author_id for p in exploit_posts[:20]}
    explore_candidates = [p for p in scored_posts[20:] if p[0].author_id not in top_authors and p[1] > 0]
    random.shuffle(explore_candidates)
    explore_posts = explore_candidates[:explore_count]
    
    # ===== DIVERSITY ENFORCEMENT =====
    # Max 2 posts per author in final result
    final_posts = []
    author_in_result = {}
    
    for post, score, content in exploit_posts:
        if author_in_result.get(post.author_id, 0) >= 2:
            continue
        author_in_result[post.author_id] = author_in_result.get(post.author_id, 0) + 1
        final_posts.append((post, score, content))
        if len(final_posts) >= exploit_count:
            break
    
    # Add exploration posts
    for post, score, content in explore_posts:
        if author_in_result.get(post.author_id, 0) >= 2:
            continue
        author_in_result[post.author_id] = author_in_result.get(post.author_id, 0) + 1
        final_posts.append((post, score, content))
    
    # Apply offset and limit
    result_posts = final_posts[offset:offset + limit]
    
    # Batch-load authors, stats, and media (eliminates N+1 queries)
    result_post_ids = [p[0].id for p in result_posts]
    result_author_ids = list(set(p[0].author_id for p in result_posts))
    authors_map = {u.id: u for u in db.query(User).filter(User.id.in_(result_author_ids)).all()} if result_author_ids else {}
    stats_map = get_batch_post_stats(db, result_post_ids, current_user.id)
    media_map = get_batch_post_media(request, db, result_post_ids)
    
    # Build response
    result = []
    for post, score, content in result_posts:
        author = authors_map.get(post.author_id)
        stats = stats_map.get(post.id, {"likes": 0, "comments": 0, "reposts": 0, "is_liked": False, "is_reposted": False})
        
        result.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=build_full_url(request, author.avatar_path) if author else None,
            content=content,
            image_url=build_full_url(request, post.image_url),
            media=media_map.get(post.id),
            timestamp=post.timestamp,
            edited_at=post.edited_at,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            view_count=post.view_count or 0,
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"],
            visibility=post.visibility or "public",
            post_type=post.post_type,
            room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            like_preview_user_ids=stats.get("like_preview_user_ids", []),
            comment_preview_user_ids=stats.get("comment_preview_user_ids", []),
            **get_voice_and_collab_fields(post, db)
        ))
    
    print(f"🎯 Recommended feed for {current_user.username}: {len(result)} posts ({exploit_count} exploit + {len(explore_posts)} explore)")
    
    # Cache result (60s for recommendation — more expensive to compute)
    cache.set(cache_key, [r.dict() for r in result], ttl=60)
    
    return result


@router.get("/local/foryou", response_model=List[PostResponse])
def get_local_for_you_feed(
    request: Request,
    lat: float,
    lng: float,
    radius_m: int = 5000,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
    limit: int = 50,
    offset: int = 0
):
    """
    Get personalized LOCAL feed: combines location proximity with recommendation scoring.
    
    - First filters by location (like /feed/local)
    - Then applies recommendation scoring
    - Returns posts sorted by combined score
    """
    import math
    from geohash import encode as encode_geohash, get_neighbors
    from sqlalchemy import or_
    
    def haversine_distance(lat1, lng1, lat2, lng2):
        R = 6371000
        phi1, phi2 = math.radians(lat1), math.radians(lat2)
        delta_phi = math.radians(lat2 - lat1)
        delta_lambda = math.radians(lng2 - lng1)
        a = math.sin(delta_phi/2)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda/2)**2
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        return R * c
    
    def round_distance(meters):
        return int(round(meters / 100) * 100)
    
    # Get user's interest profile
    user_profile = get_user_interest_profile(db, current_user.id)
    
    # Get recently seen posts to exclude
    seen_post_ids = get_recently_seen_post_ids(db, current_user.id)
    
    # Compute geohash for location query
    user_geohash = encode_geohash(lat, lng, precision=6)
    neighbor_hashes = get_neighbors(user_geohash)
    all_hashes = [user_geohash] + neighbor_hashes
    
    # Query nearby posts (no time cutoff — algorithm scoring handles recency)
    candidate_posts = db.query(Post).filter(
        or_(*[Post.geohash.like(f"{h[:5]}%") for h in all_hashes]),
        or_(Post.visibility == 'public', Post.visibility == None)
    ).order_by(Post.timestamp.desc()).limit(200).all()
    
    # Filter by distance and score
    session_state = {'user_lang': 'en', 'author_counts': {}}
    scored_posts = []
    
    for post in candidate_posts:
        if post.id in seen_post_ids:
            continue
        if post.latitude is None or post.longitude is None:
            continue
        
        # Calculate distance
        distance = haversine_distance(lat, lng, post.latitude, post.longitude)
        if distance > radius_m:
            continue
        
        content = decrypt_text(post.content) if post.content else ""
        rec_score = compute_post_score(post, content, user_profile, db, current_user.id, session_state)
        
        # Add distance factor (closer = better)
        distance_factor = 1 - (distance / radius_m)  # 1.0 at center, 0.0 at edge
        combined_score = rec_score + (0.2 * distance_factor)  # Slight boost for closer posts
        
        scored_posts.append((post, combined_score, content, distance))
    
    # Sort by combined score
    scored_posts.sort(key=lambda x: x[1], reverse=True)
    
    # Build response
    paged_posts = scored_posts[offset:offset + limit]
    paged_post_ids = [p[0].id for p in paged_posts]
    paged_author_ids = list(set(p[0].author_id for p in paged_posts))
    authors_map = {u.id: u for u in db.query(User).filter(User.id.in_(paged_author_ids)).all()} if paged_author_ids else {}
    stats_map = get_batch_post_stats(db, paged_post_ids, current_user.id)
    media_map = get_batch_post_media(request, db, paged_post_ids)
    
    result = []
    for post, score, content, distance in paged_posts:
        author = authors_map.get(post.author_id)
        stats = stats_map.get(post.id, {"likes": 0, "comments": 0, "reposts": 0, "is_liked": False, "is_reposted": False})
        
        result.append(PostResponse(
            id=post.id,
            author_id=post.author_id,
            author_username=author.username if author else "Unknown",
            author_avatar=build_full_url(request, author.avatar_path) if author else None,
            content=content,
            image_url=build_full_url(request, post.image_url),
            media=media_map.get(post.id),
            timestamp=post.timestamp,
            edited_at=post.edited_at,
            likes=stats["likes"],
            comments=stats["comments"],
            reposts=stats["reposts"],
            view_count=post.view_count or 0,
            is_local=post.is_local,
            is_liked=stats["is_liked"],
            is_reposted=stats["is_reposted"],
            visibility=post.visibility or "public",
            distance_m=round_distance(distance),
            post_type=post.post_type,
            room_id=post.room_id,
            mesh_origin=post.mesh_origin or False,
            like_preview_user_ids=stats.get("like_preview_user_ids", []),
            comment_preview_user_ids=stats.get("comment_preview_user_ids", []),
            **get_voice_and_collab_fields(post, db)
        ))
    
    print(f"🎯📍 Local For You for {current_user.username}: {len(result)} posts within {radius_m}m")
    return result


@router.post("/seen")
def mark_posts_as_seen(
    post_ids: List[str],
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Batch mark multiple posts as seen for deduplication."""
    for post_id in post_ids:
        mark_post_as_seen(db, current_user.id, post_id)
    
    return {"status": "ok", "marked": len(post_ids)}


@router.post("/feedback")
def submit_negative_feedback(
    feedback_type: str,  # hide_post, hide_author, not_interested, report
    target_type: str,  # post, author, tag
    target_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Submit negative feedback to improve recommendations.
    
    Feedback types:
    - hide_post: Hide a specific post (-10 to post score)
    - hide_author: Hide all posts from author (-100 author affinity)
    - not_interested: Mark topic as not interested (-5 to tag)
    - report: Report content (-100 score, flags for review)
    """
    from models import UserNegativeFeedback
    import uuid
    
    # Validate feedback type
    valid_types = {'hide_post', 'hide_author', 'not_interested', 'report'}
    if feedback_type not in valid_types:
        return {"status": "error", "message": f"Invalid feedback_type. Must be one of: {valid_types}"}
    
    # Check if already exists
    existing = db.query(UserNegativeFeedback).filter(
        UserNegativeFeedback.user_id == current_user.id,
        UserNegativeFeedback.target_type == target_type,
        UserNegativeFeedback.target_id == target_id
    ).first()
    
    if existing:
        # Update existing feedback
        existing.feedback_type = feedback_type
        db.commit()
        return {"status": "ok", "action": "updated"}
    
    # Create new feedback
    feedback = UserNegativeFeedback(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        feedback_type=feedback_type,
        target_type=target_type,
        target_id=target_id
    )
    db.add(feedback)
    db.commit()
    
    print(f"📉 Negative feedback from {current_user.username}: {feedback_type} on {target_type}:{target_id}")
    return {"status": "ok", "action": "created"}

