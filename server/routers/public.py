"""
routers/public.py
=================

Read-only endpoints that serve *publicly shareable* content for the
web preview pipeline (raven-messager.com `/post/{id}`, `/u/{username}`,
`/echo/{id}`, etc.).

Why a separate router?
----------------------
The main `routers/posts.py` endpoints require auth (`Depends(get_current_user)`)
and return viewer-specific fields like `is_liked` / `is_reposted`. Those
endpoints can't be hit from the Vercel Edge Function that renders share
previews — there is no logged-in user there, and we don't want to issue
a service token to an internet-facing edge function.

Instead, this router exposes a narrow, well-defined slice of data that
is safe to return to anonymous callers:

  * Only posts with `visibility='public'` and `is_hidden=False`.
  * Only authors whose profile is `is_private=False` AND
    `who_can_see_profile='public'`.
  * No like-state, no bookmark-state, no viewer-specific fields.
  * Content is decrypted server-side before being returned (it lives
    encrypted at rest with the server key, just like every other
    response — the privacy boundary is the user's E2EE messages, not
    public posts which are explicitly broadcast).

Error semantics
---------------
Return 404 for ALL of these cases:
  * Post does not exist.
  * Post is hidden by moderation.
  * Post visibility is not 'public' (could be 'friends' or 'local').
  * Author's profile is private.
  * Author is banned.

Returning 404 (rather than 403) means a private post is indistinguishable
from a non-existent one — share URLs leak no information about whether
a given UUID corresponds to a real-but-private post.

Caching
-------
The handler sets `Cache-Control: public, s-maxage=60` so Vercel's edge
+ Cloud Run + any CDN in between can cache the response for a minute.
That's short enough that edits propagate quickly, long enough that a
viral share doesn't hammer the database.
"""

from fastapi import APIRouter, HTTPException, Request, Response, status
from sqlalchemy.orm import Session
from sqlalchemy import func
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime

from database import get_db
from models import User, Post, PostLike, Comment, Repost
from encryption import decrypt_text
from fastapi import Depends


router = APIRouter(prefix="/api/public", tags=["public"])


# ──────────────────────────────────────────────────────────────────
# Response models. Deliberately a narrower shape than the
# auth-required `PostResponse` — no viewer state, no internal fields.
# ──────────────────────────────────────────────────────────────────

class PublicAuthor(BaseModel):
    username: str
    display_name: Optional[str] = None        # First name if exposed
    avatar_url: Optional[str] = None
    is_verified: bool = False
    is_premium: bool = False


class PublicPost(BaseModel):
    id: str
    author: PublicAuthor
    content: str
    image_url: Optional[str] = None
    timestamp: datetime
    edited_at: Optional[datetime] = None
    post_type: str = "text"
    voice_url: Optional[str] = None
    voice_duration: Optional[int] = None
    transcript_text: Optional[str] = None
    likes: int = 0
    comments: int = 0
    reposts: int = 0


class PublicProfile(BaseModel):
    username: str
    display_name: Optional[str] = None
    bio: Optional[str] = None
    avatar_url: Optional[str] = None
    is_verified: bool = False
    is_premium: bool = False
    created_at: datetime
    post_count: int = 0


# ──────────────────────────────────────────────────────────────────
# Helpers.
# ──────────────────────────────────────────────────────────────────

def _full_url(request: Request, path: Optional[str]) -> Optional[str]:
    """Promote a stored relative path (e.g. ``/uploads/avatars/x.jpg``)
    to an absolute URL using the request's base. Pass-through for
    already-absolute URLs and ``None``."""
    if not path:
        return None
    if path.startswith("http://") or path.startswith("https://"):
        return path
    base = str(request.base_url).rstrip("/")
    return f"{base}{path}"


def _author_is_shareable(author: Optional[User]) -> bool:
    """Return True iff the author is a real, public, non-banned user.

    The principle (per product decision 2026-05-17): a post is shown
    on the public web ONLY when both the post AND the account are
    public. Marking an account `is_private=True` (or
    `who_can_see_profile != 'public'`) suppresses every public-web
    surface for that user — even posts they explicitly set to
    `visibility='public'`. Inside-the-app visibility is unaffected.

    Used as the gating predicate for both `/api/public/users/{name}`
    (direct profile lookup) and `/api/public/posts/{id}` (so even a
    post explicitly marked `visibility='public'` 404s if its author
    later locked their profile).
    """
    if author is None:
        return False
    if author.is_banned:
        return False
    if author.is_private:
        return False
    if (author.who_can_see_profile or "public") != "public":
        return False
    if author.status and author.status not in ("active",):
        return False
    return True


def _public_author(request: Request, author: User) -> PublicAuthor:
    # First name is stored encrypted (it's a real-name field). Decrypt
    # opportunistically — if decryption fails we just omit display_name
    # rather than 500 the share link.
    display = None
    try:
        if author.first_name:
            display = decrypt_text(author.first_name)
    except Exception:
        display = None

    return PublicAuthor(
        username=author.username,
        display_name=display,
        avatar_url=_full_url(request, author.avatar_path),
        is_verified=bool(author.is_verified),
        is_premium=bool(author.is_premium),
    )


def _public_cache_headers(response: Response, seconds: int = 60) -> None:
    response.headers["Cache-Control"] = (
        f"public, s-maxage={seconds}, max-age=30, stale-while-revalidate=600"
    )
    # Belt-and-suspenders: explicitly tell crawlers it's safe to index.
    response.headers["X-Robots-Tag"] = "index, follow"


# ──────────────────────────────────────────────────────────────────
# Endpoints.
# ──────────────────────────────────────────────────────────────────

@router.get("/posts/{post_id}", response_model=PublicPost)
def get_public_post(
    post_id: str,
    request: Request,
    response: Response,
    db: Session = Depends(get_db),
):
    """Return a publicly-shareable post by ID.

    Returns 404 for any private, hidden, friends-only, or local-only
    post — and also if the author later locked their profile.
    """
    post: Optional[Post] = db.query(Post).filter(Post.id == post_id).first()

    if not post or post.is_hidden:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")

    if (post.visibility or "public") != "public":
        # Friends-only / local posts are not shareable to anonymous
        # callers. Use 404 so the URL leaks no information about
        # whether the post exists at all.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")

    author: Optional[User] = db.query(User).filter(User.id == post.author_id).first()
    if not _author_is_shareable(author):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")

    # Decrypt body once. Fall back to empty string if decryption fails
    # (corrupt row in dev) — the OG card still gets a working title.
    try:
        content = decrypt_text(post.content) if post.content else ""
    except Exception:
        content = ""

    # Counts: pull live from the join tables so the response reflects
    # the current state. Cheap because each is an indexed COUNT(*).
    likes_count    = db.query(func.count(PostLike.id)).filter(PostLike.post_id == post.id).scalar() or 0
    comments_count = db.query(func.count(Comment.id)).filter(Comment.post_id == post.id).scalar() or 0
    # NOTE: Repost uses `original_post_id` (FK to the post being reposted),
    # not `post_id` — keep this consistent with `models.Repost`.
    reposts_count  = db.query(func.count(Repost.id)).filter(Repost.original_post_id == post.id).scalar() or 0

    _public_cache_headers(response)
    return PublicPost(
        id=post.id,
        author=_public_author(request, author),
        content=content,
        image_url=_full_url(request, post.image_url),
        timestamp=post.timestamp,
        edited_at=post.edited_at,
        post_type=post.post_type or "text",
        voice_url=_full_url(request, post.voice_url),
        voice_duration=post.voice_duration,
        transcript_text=post.transcript_text,
        likes=likes_count,
        comments=comments_count,
        reposts=reposts_count,
    )


@router.get("/users/{username}", response_model=PublicProfile)
def get_public_profile(
    username: str,
    request: Request,
    response: Response,
    db: Session = Depends(get_db),
):
    """Return a publicly-shareable profile by username.

    Same shareability rules as `_author_is_shareable`. Private profiles
    return 404 (not 403) to avoid leaking the existence of the account.
    """
    user: Optional[User] = (
        db.query(User).filter(func.lower(User.username) == username.lower()).first()
    )
    if not _author_is_shareable(user):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile not found")

    # Display name from encrypted first_name, opportunistic.
    display = None
    try:
        if user.first_name:
            display = decrypt_text(user.first_name)
    except Exception:
        display = None

    bio = None
    try:
        # Bio is stored plaintext in the current schema — handle either
        # plaintext or accidentally-encrypted rows.
        if user.bio:
            bio = user.bio
    except Exception:
        bio = None

    post_count = (
        db.query(func.count(Post.id))
        .filter(
            Post.author_id == user.id,
            Post.is_hidden == False,            # noqa: E712
            Post.visibility == "public",
        )
        .scalar()
        or 0
    )

    _public_cache_headers(response, seconds=120)
    return PublicProfile(
        username=user.username,
        display_name=display,
        bio=bio,
        avatar_url=_full_url(request, user.avatar_path),
        is_verified=bool(user.is_verified),
        is_premium=bool(user.is_premium),
        created_at=user.created_at,
        post_count=post_count,
    )
