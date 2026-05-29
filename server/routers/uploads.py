from fastapi import APIRouter, Depends, File, UploadFile, HTTPException, status, Request
from sqlalchemy.orm import Session
from PIL import Image, ImageOps
import io
import uuid
import os
from pathlib import Path
from typing import Optional

from database import get_db
from models import User
from routers.users import get_current_user

router = APIRouter(prefix="/api/uploads", tags=["uploads"])


# ==================== Signed-URL Resign Endpoint ====================
#
# Round 26 — pairs with the `_upload_to_gcs` switch to signed URLs.
# A receiver presents the GCS object path (extracted from the
# original URL) and gets back a fresh 15-min signed URL. The
# auth gate stays at `current_user` so a leaked URL still can't
# be re-signed by an unauthenticated party — the bar moves from
# "have a URL → forever access" to "have a URL AND a live session
# token → 15 minutes".
@router.post("/sign-read")
def sign_read_url(
    body: dict,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Re-sign a `gs://bucket/object` path for a 15-minute GET.

    🔴 ROUND 26 (2026-05-16) — REAL hacker-mode audit fix (MEDIA-CRIT-1).
    ────────────────────────────────────────────────────────────────────
    PREVIOUSLY: any authenticated user could pass ANY `object_path`
    and get back a fresh signed URL. Combined with the legacy mesh
    leak (pre-round-26 envelopes shipped `mediaUrl` plaintext on the
    wire), a rogue relay could harvest paths from envelopes it
    transited and then call this endpoint from its own account to
    download every photo/video/voice/PDF in the bucket. The endpoint
    comment claimed "have a URL AND a live session token → 15 minutes",
    but didn't enforce "have a URL AND BE A LEGITIMATE PARTY".

    NOW: we look up the object_path in the four tables that actually
    own media URLs (Message, Comment, PostMedia, GroupMessage) and
    reject unless the caller is sender, recipient, post author, or
    group member. We use SQL `LIKE '%<path>%'` because the stored
    URL may be the full GCS URL or the relative `kind/uuid` form.
    A null result (path doesn't appear in any table) is treated as
    404 to avoid leaking existence.
    """
    from datetime import datetime, timedelta
    from sqlalchemy import or_, and_
    from models import (
        Message, Comment, Post, PostMedia, GroupMessage, GroupMember,
        FriendRequest, SnapMessage, ChannelPost, VoiceMessage,
        AudioRoomAsset, VerificationRequest,
    )
    try:
        from models import Story  # may not exist in every deploy
    except ImportError:
        Story = None

    object_path = (body or {}).get("object_path") or ""
    if not object_path or "/" not in object_path:
        raise HTTPException(status_code=400, detail="object_path required")

    # 🔴 ROUND 68 (2026-05-20) — hacker-audit MEDIA F2
    # (LOW: unescaped LIKE wildcards in caller-controlled input).
    #
    # `object_path` is fully attacker-controlled. It was interpolated
    # straight into a SQL `LIKE` pattern, so a caller could inject
    # `%` / `_` wildcards. This does NOT enable cross-user media
    # theft — the signed URL is always generated for the LITERAL
    # `object_path` via `bucket.blob(object_path)`, and a wildcarded
    # path can never literally equal a real GCS object name — but it
    # DOES let an attacker broaden the ownership-probe query and
    # force ~7 leading-wildcard full-table scans per request (a cheap
    # DoS amplifier). Escape the LIKE metacharacters and pass an
    # explicit ESCAPE char so `%` / `_` in the input are matched
    # literally.
    def _esc_like(s: str) -> str:
        return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    # Pattern for substring match — the stored URL might be:
    #   • bare relative path:  "voice/abc.m4a"
    #   • full GCS URL:        "https://storage.googleapis.com/.../voice/abc.m4a"
    #   • signed URL with qp:  "https://.../voice/abc.m4a?X-Goog-..."
    # All three contain `voice/abc.m4a` as a substring.
    like_pat = f"%{_esc_like(object_path)}%"

    authorized = False
    _now = datetime.utcnow()

    # 1. 1:1 messages: only sender / recipient AND not past expiry.
    # 🔴 ROUND 70 — added expires_at check so a "deleteAfterRead"
    # / disappearing message cannot be re-signed after it should be
    # gone. Belt-and-suspenders alongside _purge_expired_for_user
    # which deletes the row + GCS blob; this guard fires in the
    # window between expiry and the lazy purge.
    if db.query(Message.id).filter(
        Message.audio_url.like(like_pat, escape="\\"),
        or_(Message.expires_at.is_(None), Message.expires_at > _now),
        or_(
            Message.sender_id == current_user.id,
            Message.recipient_id == current_user.id,
        )
    ).first() is not None:
        authorized = True

    # 2. Comments: only the post author or the comment author. Other
    #    viewers can already read the public surface so they don't
    #    need a signed URL — they hit the CDN URL the comment list
    #    served them.
    if not authorized:
        comment = db.query(Comment).filter(
            Comment.media_url.like(like_pat, escape="\\")
        ).first()
        if comment is not None:
            post = db.query(Post).filter(Post.id == comment.post_id).first()
            if post is not None and (
                comment.author_id == current_user.id
                or post.author_id == current_user.id
            ):
                authorized = True

    # 🔴 ROUND 70 — helper: is the caller authorized to see this post
    # under its visibility flag? Mirrors `posts._can_user_access_post`
    # but inlined here to avoid the cyclic import.
    def _post_allows(p: Post) -> bool:
        if p.author_id == current_user.id:
            return True
        v = (p.visibility or "public").lower().strip()
        if v in ("", "public", "local"):
            return True
        if v == "friends":
            return db.query(FriendRequest).filter(
                FriendRequest.status == "accepted",
                or_(
                    and_(FriendRequest.requester_id == current_user.id,
                         FriendRequest.recipient_id == p.author_id),
                    and_(FriendRequest.requester_id == p.author_id,
                         FriendRequest.recipient_id == current_user.id),
                )
            ).first() is not None
        return False  # 'private' → author only

    # 3. Post attachments (image/video carousel): only post author
    #    OR users who can see the post per its visibility column.
    if not authorized:
        media_row = db.query(PostMedia).filter(
            PostMedia.url.like(like_pat, escape="\\")
        ).first()
        if media_row is not None:
            post = db.query(Post).filter(Post.id == media_row.post_id).first()
            if post is not None and _post_allows(post):
                authorized = True

    # 3b. Legacy single-image posts (Post.image_url stored directly).
    if not authorized:
        legacy_post = db.query(Post).filter(
            Post.image_url.like(like_pat, escape="\\")
        ).first()
        if legacy_post is not None and _post_allows(legacy_post):
            authorized = True

    # 3c. Voice posts (Post.voice_url).
    if not authorized:
        voice_post = db.query(Post).filter(
            Post.voice_url.like(like_pat, escape="\\")
        ).first()
        if voice_post is not None and _post_allows(voice_post):
            authorized = True

    # 4. Group messages: any current group member.
    if not authorized:
        gmsg = db.query(GroupMessage).filter(
            or_(
                GroupMessage.audio_url.like(like_pat, escape="\\"),
                GroupMessage.file_url.like(like_pat, escape="\\") if hasattr(GroupMessage, "file_url") else False,
            )
        ).first()
        if gmsg is not None:
            is_member = db.query(GroupMember).filter(
                GroupMember.group_id == gmsg.group_id,
                GroupMember.user_id == current_user.id,
            ).first() is not None
            if is_member:
                authorized = True

    # 🔴 ROUND 70 — extended coverage. The previous endpoint only
    # checked Message/GroupMessage/Comment/PostMedia/Post.image_url/
    # Post.voice_url. Every other table that stores a media URL was
    # silently uncovered — so after the initial 15-min signed-URL
    # window expired, those uploads were undownloadable for
    # legitimate users AND any pre-expiry interception couldn't
    # later be denied (the GCS path still resolves until rotation).
    # New coverage:

    # 5. Snap messages: only sender / recipient AND only while
    #    `expires_at > now` (snaps are by design self-destructing —
    #    after expiry the URL must be dead, server-side enforced).
    if not authorized:
        snap = db.query(SnapMessage).filter(
            SnapMessage.media_url.like(like_pat, escape="\\"),
            or_(SnapMessage.expires_at.is_(None), SnapMessage.expires_at > _now),
            or_(
                SnapMessage.sender_id == current_user.id,
                SnapMessage.recipient_id == current_user.id,
            )
        ).first()
        if snap is not None:
            authorized = True

    # 6. Stories: only the author OR friends (story 'audience'
    #    rules), and only while unexpired. Story model is optional
    #    in some deploys — guard the import.
    if not authorized and Story is not None:
        story = db.query(Story).filter(
            Story.media_url.like(like_pat, escape="\\"),
            or_(Story.expires_at.is_(None), Story.expires_at > _now),
        ).first()
        if story is not None:
            if story.author_id == current_user.id:
                authorized = True
            else:
                # Audience check: 'friends' restricts to mutual
                # friends. Other audience values (e.g. 'public')
                # fall through to allow.
                aud = (getattr(story, "audience", None) or "friends").lower()
                if aud == "friends":
                    is_friend = db.query(FriendRequest).filter(
                        FriendRequest.status == "accepted",
                        or_(
                            and_(FriendRequest.requester_id == current_user.id,
                                 FriendRequest.recipient_id == story.author_id),
                            and_(FriendRequest.requester_id == story.author_id,
                                 FriendRequest.recipient_id == current_user.id),
                        )
                    ).first() is not None
                    if is_friend:
                        authorized = True
                else:
                    authorized = True

    # 7. Channel posts: any current channel member / subscriber.
    if not authorized:
        cpost = db.query(ChannelPost).filter(
            ChannelPost.media_url.like(like_pat, escape="\\")
        ).first()
        if cpost is not None:
            try:
                from models import ChannelMember
                is_member = db.query(ChannelMember).filter(
                    ChannelMember.channel_id == cpost.channel_id,
                    ChannelMember.user_id == current_user.id,
                ).first() is not None
                if is_member:
                    authorized = True
            except Exception:
                # ChannelMember table not present in this deploy —
                # fall through to 404.
                pass

    # 8. Voice messages (separate table from Message.audio_url):
    #    only sender / recipient of the parent message.
    if not authorized:
        vmsg = db.query(VoiceMessage).filter(
            VoiceMessage.audio_url.like(like_pat, escape="\\")
        ).first()
        if vmsg is not None:
            parent = db.query(Message).filter(Message.id == vmsg.message_id).first()
            if parent is not None and current_user.id in (
                parent.sender_id, parent.recipient_id
            ):
                authorized = True

    # 9. Audio-room presentation assets (PDFs / images shown in a
    #    live room): only current room participants.
    if not authorized:
        asset = db.query(AudioRoomAsset).filter(
            AudioRoomAsset.url.like(like_pat, escape="\\")
        ).first()
        if asset is not None:
            try:
                from models import AudioRoomParticipant
                is_participant = db.query(AudioRoomParticipant).filter(
                    AudioRoomParticipant.room_id == asset.room_id,
                    AudioRoomParticipant.user_id == current_user.id,
                ).first() is not None
                if is_participant:
                    authorized = True
            except Exception:
                pass

    # 9b. 🔴 ROUND 70 — Avatars (User.avatar_path + Group.avatar_url).
    # Avatars are intentionally public-readable across the app's
    # social surfaces (any user who can see another user can see
    # their avatar). So sign-read for an avatar path is authorized
    # for any authenticated user — but we still require the path to
    # actually live on a User or Group row to prevent attacker-chosen
    # paths from being signed indiscriminately.
    if not authorized:
        try:
            from models import User as _User, Group as _Group
            user_avatar = db.query(_User.id).filter(
                _User.avatar_path.like(like_pat, escape="\\")
            ).first()
            if user_avatar is not None:
                authorized = True
            elif hasattr(_Group, "avatar_url"):
                group_avatar = db.query(_Group.id).filter(
                    _Group.avatar_url.like(like_pat, escape="\\")
                ).first()
                if group_avatar is not None:
                    authorized = True
        except Exception:
            pass

    # 10. KYC verification documents: author OR admin only. Combine
    #    the doc_front_url / doc_back_url / selfie_url columns; a
    #    leak of any of these would expose government-ID + selfie.
    #
    # 🔴 ROUND 70 phase 2 — KYC columns are now Fernet-wrapped (also
    # round 70). LIKE-on-ciphertext won't match the plaintext
    # `object_path`. Iterate the small VerificationRequest set in
    # Python and decrypt-then-compare. KYC requests volume is low
    # (≤ tens per user), so a full scan is acceptable; for scale
    # we'd add a `doc_path_hash` column and index that.
    if not authorized:
        all_vreqs = db.query(VerificationRequest).all()
        for vreq in all_vreqs:
            for col_name in ("doc_front_url", "doc_back_url", "selfie_url"):
                stored = getattr(vreq, col_name, None)
                if not stored:
                    continue
                # Try decrypt; fall through to raw on legacy rows.
                try:
                    from encryption import decrypt_text as _dec_url
                    plain = _dec_url(stored)
                except Exception:
                    plain = stored
                if plain and object_path in plain:
                    is_owner = vreq.user_id == current_user.id
                    is_admin = bool(getattr(current_user, "is_admin", False))
                    if is_owner or is_admin:
                        authorized = True
                    break
            if authorized:
                break

    if not authorized:
        # 404 (not 403) so we don't leak whether the path exists.
        # An attacker probing random UUIDs gets the same response
        # for "doesn't exist" and "exists but not yours".
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Object not found or not accessible"
        )

    bucket = _get_gcs_bucket()
    if bucket is None:
        # Dev fallback — return the path as-is so the client knows
        # it's a local development URL.
        return {"signed_url": object_path, "expires_in_seconds": 0}
    try:
        blob = bucket.blob(object_path)
        # 🔴 ROUND 31 — IAM-signing path (see `_get_signing_credentials`).
        sa_email, access_token = _get_signing_credentials()
        sign_kwargs = {
            "version": "v4",
            "expiration": timedelta(minutes=15),
            "method": "GET",
        }
        if sa_email and access_token:
            sign_kwargs["service_account_email"] = sa_email
            sign_kwargs["access_token"] = access_token
        signed_url = blob.generate_signed_url(**sign_kwargs)
        return {"signed_url": signed_url, "expires_in_seconds": 900}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"sign failed: {type(e).__name__}")


# ==================== Upload Limits Endpoint ====================
@router.get("/limits")
def get_upload_limits(
    current_user: User = Depends(get_current_user)
):
    """
    Returns the current user's upload limits based on their subscription tier.
    iOS client uses this to enforce limits client-side and show upgrade prompts.
    """
    is_premium = current_user.is_premium or False
    tier = "raven_plus" if is_premium else "free"
    
    return {
        "tier": tier,
        "is_premium": is_premium,
        "limits": {
            "image": {
                "max_file_size_mb": 2048 if is_premium else 10,
                "max_dimension_px": 8192 if is_premium else 2048,
            },
            "file": {
                "max_file_size_mb": 2048 if is_premium else 25,
            },
            "voice": {
                "max_file_size_mb": 2048 if is_premium else 50,
                "max_duration_seconds": 600 if is_premium else 120,
            },
            "video_note": {
                "max_file_size_mb": 2048 if is_premium else 50,
            },
            "post": {
                "max_media_per_post": 10 if is_premium else 4,
                "max_video_duration_seconds": 600 if is_premium else 120,
                "video_export_preset": "1920x1080" if is_premium else "1280x720",
                "image_compression_quality": 1.0 if is_premium else 0.75,
            },
            "ai": {
                "daily_transcription_limit": -1 if is_premium else 3,  # -1 = unlimited
                "daily_gemini_limit": -1 if is_premium else 5,
            },
        }
    }

# ==================== GCS Configuration ====================
# In production (Cloud Run), files go to GCS for persistence.
# In development, falls back to local filesystem.
GCS_MEDIA_BUCKET = os.getenv("GCS_MEDIA_BUCKET", "raven-media-uploads")

def _get_gcs_bucket():
    """Get GCS bucket client. Returns None if GCS is unavailable (dev mode)."""
    try:
        from google.cloud import storage as gcs_storage
        client = gcs_storage.Client()
        return client.bucket(GCS_MEDIA_BUCKET)
    except Exception as e:
        print(f"⚠️ GCS unavailable (dev mode): {type(e).__name__}: {e}")
        return None


# ────────────────────────────────────────────────────────────────────
# 🔴 ROUND 31 (2026-05-18) — V4 signed-URL credentials on Cloud Run.
#
# Cloud Run instances authenticate via Compute Engine metadata-server
# tokens, NOT a private key file. The default `blob.generate_signed_url`
# call assumes a key file is available and raises
#
#     AttributeError: you need a private key to sign credentials. the
#     credentials you are currently using <class 'google.auth.compute_
#     engine.credentials.Credentials'> just contains a token.
#
# … on every single sign attempt. Symptoms in production:
#   • /api/uploads/video/sign → HTTP 503 → iOS falls back to multipart
#     → Cloud Run 32 MB cap → 413 for any video > 32 MB
#     (the user-reported "can't upload video" regression)
#   • /api/uploads/sign-read → returns the stored URL as-is →
#     old GCS signed URLs that already expired serve 403 forever
#     (the user-reported "videos previously uploaded show as images
#     / don't load" regression — the broken thumbnail surfaces)
#
# Fix: when running on Cloud Run, refresh the metadata-server token
# and pass `service_account_email` + `access_token` to every
# `generate_signed_url` call. The GCS SDK then routes the signing
# request through the IAM `signBlob` API instead of looking for a
# private key locally. Requires the service account to hold
# `roles/iam.serviceAccountTokenCreator` on ITSELF — granted via
#
#     gcloud iam service-accounts add-iam-policy-binding \
#       516053629173-compute@developer.gserviceaccount.com \
#       --member="serviceAccount:516053629173-compute@developer.gserviceaccount.com" \
#       --role="roles/iam.serviceAccountTokenCreator"
#
# Locally (dev) credentials usually DO have a private key, so the
# returned tuple is (None, None) and `generate_signed_url` falls
# back to local signing. Both modes work without code paths.

# Lazy-cached: the refreshed token is good for ~1 hour, refreshing
# on every call is wasteful. We refresh transparently on demand.
_signing_creds_cache: dict = {"creds": None}


def _get_signing_credentials():
    """Return `(service_account_email, access_token)` suitable for
    passing to `blob.generate_signed_url(...)` on Cloud Run.

    Returns `(None, None)` in dev / when credentials have a local
    private key — caller passes through to the SDK's default
    behavior.
    """
    try:
        import google.auth
        import google.auth.transport.requests as _gauth_requests

        creds = _signing_creds_cache.get("creds")
        if creds is None:
            creds, _project = google.auth.default(
                scopes=["https://www.googleapis.com/auth/cloud-platform"]
            )
            _signing_creds_cache["creds"] = creds

        # If we have a private key locally (dev / service-account JSON),
        # the SDK can sign without IAM — return None so we don't
        # over-engineer the call.
        if hasattr(creds, "signer_email") and not hasattr(creds, "service_account_email"):
            return (None, None)

        # Compute Engine credentials path: refresh to mint a token,
        # then return (email, token) so the SDK uses IAM signBlob.
        if not getattr(creds, "valid", False):
            creds.refresh(_gauth_requests.Request())

        sa_email = getattr(creds, "service_account_email", None)
        token = getattr(creds, "token", None)
        if sa_email and token:
            return (sa_email, token)
        return (None, None)
    except Exception as e:
        print(f"⚠️ [SignCreds] could not get signing credentials: {type(e).__name__}: {e}")
        return (None, None)

def _upload_to_gcs(bucket, content: bytes, gcs_path: str, content_type: str) -> str:
    """Upload bytes to GCS and return a TIME-BOUNDED signed URL.

    🔴 ROUND 26 — hacker-audit Server F1 CRITICAL fix.
    Before: bucket was Uniform-Bucket-Level-Access public-read,
    object URLs returned as plain `https://storage.googleapis.com/...`
    eternal/unauthenticated. ANY observer of the URL — Cloud Run
    access logs, a DB dump, MITM at the bridge, a leaked APNs body,
    a compromised contact — could `curl` the PDF / photo / voice
    note FOREVER with zero auth. The bug was twice-amplified by
    Mesh F1 (URLs ride plaintext on every BLE spray).

    Now: each new upload returns a V4 signed URL with a 15-minute
    expiration. Receivers re-sign via the `/api/uploads/sign-read`
    proxy whenever they need to fetch (added below). Captured URLs
    expire before the attacker can use them at scale.

    Migration note: existing rows in the DB carry the old
    eternal URLs; those remain readable until the bucket is
    flipped to private (ops runbook step). The new uploads
    coexist via the same column.
    """
    from datetime import timedelta
    blob = bucket.blob(gcs_path)
    blob.cache_control = "private, max-age=900, no-transform"
    blob.upload_from_string(content, content_type=content_type)
    # Signed URL — server-side resign is required to read after
    # expiry. 15 min is the sweet spot: long enough for a slow
    # mobile download + a sane redelivery retry, short enough that
    # a leaked URL is useless by the next chat session.
    try:
        # 🔴 ROUND 31 — pass IAM signing credentials so Cloud Run
        # (no private key) can sign via signBlob API. See
        # `_get_signing_credentials` for the why.
        sa_email, access_token = _get_signing_credentials()
        sign_kwargs = {
            "version": "v4",
            "expiration": timedelta(minutes=15),
            "method": "GET",
        }
        if sa_email and access_token:
            sign_kwargs["service_account_email"] = sa_email
            sign_kwargs["access_token"] = access_token
        signed_url = blob.generate_signed_url(**sign_kwargs)
        print(f"☁️ Uploaded to GCS: {gcs_path} → signed URL (15-min TTL)")
        return signed_url
    except Exception as e:
        # Cloud Run's default service account may need an IAM
        # role bump (`roles/iam.serviceAccountTokenCreator`) to
        # sign URLs. If signing fails (dev key file missing, IAM
        # not granted yet), fall back to the legacy public URL
        # so we don't break uploads during the rollout — and log
        # loudly so the operator notices.
        print(f"⚠️ Signed-URL generation failed ({type(e).__name__}: {e}) — "
              f"falling back to unsigned URL. Grant the Cloud Run service "
              f"account 'roles/iam.serviceAccountTokenCreator' to enable signing.")
        return f"https://storage.googleapis.com/{bucket.name}/{gcs_path}"


# ==================== Local Fallback Configuration ====================
UPLOAD_DIR = Path("uploads")
UPLOAD_DIR.mkdir(exist_ok=True)
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB (free tier image limit)
MAX_FILE_SIZE_PREMIUM = 2 * 1024 * 1024 * 1024  # 2GB (premium tier)
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
MAX_IMAGE_DIMENSION = 2048           # free-tier max dimension
MAX_IMAGE_DIMENSION_PREMIUM = 8192   # 🔴 ROUND 71 S4 — premium tier matches /limits response

# File upload configuration (PDF, DOC, etc.)
FILE_UPLOAD_DIR = Path("uploads/files")
FILE_UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
MAX_FILE_SIZE_BYTES = 25 * 1024 * 1024  # 25MB for files (free tier)
MAX_FILE_SIZE_BYTES_PREMIUM = 2 * 1024 * 1024 * 1024  # 2GB (premium tier)
ALLOWED_FILE_EXTENSIONS = {".pdf", ".doc", ".docx", ".txt", ".mp4", ".mov", ".m4v", ".avi"}
MIME_TYPES = {
    ".pdf": "application/pdf",
    ".doc": "application/msword",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".txt": "text/plain",
    ".mp4": "video/mp4",
    ".mov": "video/quicktime",
    ".m4v": "video/x-m4v",
    ".avi": "video/x-msvideo",
}


@router.post("/image")
async def upload_image(
    request: Request,
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Upload an image file.
    
    - Validates file type (JPEG, PNG, WebP)
    - Validates file size (max 10MB)
    - Fixes EXIF orientation (auto-rotates)
    - Optimizes image (resizes if needed)
    - Uploads to GCS (production) or local filesystem (dev)
    - Returns image URL path
    """
    try:
        # Read file content first (needed for the vault-blob sniff).
        file_ext = Path(file.filename or "").suffix.lower()
        content = await file.read()

        # Validate file size (premium-aware) — applies to all paths.
        max_size = MAX_FILE_SIZE_PREMIUM if current_user.is_premium else MAX_FILE_SIZE
        if len(content) > max_size:
            max_mb = max_size / (1024*1024)
            detail = f"File too large. Maximum size: {max_mb:.1f}MB"
            if not current_user.is_premium:
                detail += " — Upgrade to RAVEN+ for up to 2GB uploads! 🚀"
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=detail
            )

        # 🔴 2026-05-20 — Vault image passthrough.
        # A Vault image is an opaque RVNV1 AES-GCM blob, NOT a real
        # image: PIL cannot open it and re-encoding would corrupt the
        # ciphertext. PREVIOUSLY such uploads (filename ".vlt") were
        # rejected here with "Invalid file type" — vault image send
        # was broken end to end. When the upload carries the RVNV1
        # magic, store the bytes verbatim and skip the extension
        # check + image optimisation. The recipient's
        # VaultPayloadResolver decrypts it client-side.
        if content[:8] == b"RVNV1\x00\x00\x00":
            unique_filename = f"{uuid.uuid4()}.vlt"
            bucket = _get_gcs_bucket()
            if bucket:
                gcs_path = f"images/{unique_filename}"
                full_image_url = _upload_to_gcs(
                    bucket, content, gcs_path, "application/octet-stream"
                )
            else:
                file_path = UPLOAD_DIR / unique_filename
                with open(file_path, "wb") as f:
                    f.write(content)
                base_url = str(request.base_url).rstrip('/')
                full_image_url = f"{base_url}/uploads/{unique_filename}"
                print(f"📁 Vault image stored locally: {unique_filename}")
            print(f"✅ Vault image stored opaque: {unique_filename} by user {current_user.username}")
            return {"image_url": full_image_url, "filename": unique_filename}

        # Non-vault images: validate the extension, then optimise.
        if file_ext not in ALLOWED_EXTENSIONS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid file type. Allowed: {', '.join(ALLOWED_EXTENSIONS)}"
            )

        # Validate and optimize image
        try:
            image = Image.open(io.BytesIO(content))
            
            # 🔧 FIX: Apply EXIF orientation (auto-rotate based on EXIF data)
            # This prevents the 90-degree rotation issue on iOS photos
            image = ImageOps.exif_transpose(image)
            
            # Convert RGBA to RGB if necessary
            if image.mode == 'RGBA':
                background = Image.new('RGB', image.size, (255, 255, 255))
                background.paste(image, mask=image.split()[3])
                image = background
            elif image.mode not in ('RGB', 'L'):
                image = image.convert('RGB')
            
            # Resize if too large (maintain aspect ratio)
            # 🔴 ROUND 71 S4: premium-aware max dimension. Was hardcoded
            # 2048 even for premium users despite `/limits` advertising
            # 8192 — premium uploads were silently downscaled and the
            # tier promise was a lie.
            _max_dim = MAX_IMAGE_DIMENSION_PREMIUM if current_user.is_premium else MAX_IMAGE_DIMENSION
            if image.width > _max_dim or image.height > _max_dim:
                image.thumbnail((_max_dim, _max_dim), Image.Resampling.LANCZOS)
            
            # Generate unique filename
            unique_filename = f"{uuid.uuid4()}{file_ext}"
            
            # Save optimized image to buffer
            output_buffer = io.BytesIO()
            if file_ext in ['.jpg', '.jpeg']:
                image.save(output_buffer, 'JPEG', quality=85, optimize=True)
                content_type = "image/jpeg"
            elif file_ext == '.png':
                image.save(output_buffer, 'PNG', optimize=True)
                content_type = "image/png"
            elif file_ext == '.webp':
                image.save(output_buffer, 'WEBP', quality=85)
                content_type = "image/webp"
            else:
                content_type = "image/jpeg"
            
            optimized_content = output_buffer.getvalue()
            
            # Try GCS first (production), fall back to local (development)
            bucket = _get_gcs_bucket()
            if bucket:
                gcs_path = f"images/{unique_filename}"
                full_image_url = _upload_to_gcs(bucket, optimized_content, gcs_path, content_type)
            else:
                # Local fallback (development)
                file_path = UPLOAD_DIR / unique_filename
                image.save(file_path, image.format or 'JPEG', quality=85, optimize=True)
                base_url = str(request.base_url).rstrip('/')
                full_image_url = f"{base_url}/uploads/{unique_filename}"
                print(f"📁 Image saved locally: {unique_filename}")
            
            print(f"✅ Image uploaded: {unique_filename} by user {current_user.username}")
            
            # Return full URL
            return {
                "image_url": full_image_url,
                "filename": unique_filename
            }
            
        except HTTPException:
            raise
        except Exception as e:
            print(f"❌ Image processing error: {e}")
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Invalid image file"
            )
    
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Upload error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Upload failed"
        )


@router.post("/file")
async def upload_file(
    request: Request,
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Upload a document file (PDF, DOC, DOCX, TXT).
    
    - Validates file type
    - Validates file size (max 25MB)
    - Uploads to GCS (production) or local filesystem (dev)
    - Returns file URL, filename, size, and mime_type
    """
    try:
        # Read file content first (vault sniff happens before extension check).
        original_filename = file.filename or "unknown"
        file_ext = Path(original_filename).suffix.lower()
        content = await file.read()
        file_size = len(content)

        # Validate file size (premium-aware) — applies to all paths.
        max_size = MAX_FILE_SIZE_BYTES_PREMIUM if current_user.is_premium else MAX_FILE_SIZE_BYTES
        if file_size > max_size:
            max_mb = max_size / (1024*1024)
            detail = f"File too large. Maximum size: {max_mb:.0f}MB"
            if not current_user.is_premium:
                detail += " — Upgrade to RAVEN+ for up to 2GB uploads! 🚀"
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=detail
            )

        # 🔴 ROUND 71 S3: vault-file passthrough (mirrors /upload/image
        # round-26 fix). PREVIOUSLY this endpoint rejected vault file
        # sends because the encrypted blob's extension wouldn't match
        # ALLOWED_FILE_EXTENSIONS. Now: sniff RVNV1 magic + store opaque.
        if content[:8] == b"RVNV1\x00\x00\x00":
            unique_filename = f"{uuid.uuid4()}.vlt"
            bucket = _get_gcs_bucket()
            if bucket:
                gcs_path = f"files/{unique_filename}"
                full_file_url = _upload_to_gcs(
                    bucket, content, gcs_path, "application/octet-stream"
                )
            else:
                file_path = FILE_UPLOAD_DIR / unique_filename
                with open(file_path, "wb") as f:
                    f.write(content)
                base_url = str(request.base_url).rstrip('/')
                full_file_url = f"{base_url}/uploads/files/{unique_filename}"
                print(f"📁 Vault file stored locally: {unique_filename}")
            print(f"✅ Vault file stored opaque: {unique_filename} by user {current_user.username}")
            return {
                "file_url": full_file_url,
                "filename": "vault.bin",
                "unique_filename": unique_filename,
                "size": file_size,
                "mime_type": "application/octet-stream",
            }

        # Non-vault path: now validate extension.
        if file_ext not in ALLOWED_FILE_EXTENSIONS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid file type. Allowed: {', '.join(ALLOWED_FILE_EXTENSIONS)}"
            )

        # Generate unique filename (preserve original extension)
        unique_filename = f"{uuid.uuid4()}{file_ext}"
        
        # Get MIME type
        mime_type = MIME_TYPES.get(file_ext, "application/octet-stream")
        
        # Try GCS first (production), fall back to local (development)
        bucket = _get_gcs_bucket()
        if bucket:
            gcs_path = f"files/{unique_filename}"
            full_file_url = _upload_to_gcs(bucket, content, gcs_path, mime_type)
        else:
            # Local fallback (development)
            file_path = FILE_UPLOAD_DIR / unique_filename
            with open(file_path, "wb") as f:
                f.write(content)
            base_url = str(request.base_url).rstrip('/')
            full_file_url = f"{base_url}/uploads/files/{unique_filename}"
            print(f"📁 File saved locally: {unique_filename}")
        
        print(f"✅ File uploaded: {unique_filename} ({file_size} bytes) by user {current_user.username}")
        
        return {
            "file_url": full_file_url,
            "filename": original_filename,
            "unique_filename": unique_filename,
            "size": file_size,
            "mime_type": mime_type,
        }
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ File upload error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="File upload failed"
        )


# Voice upload configuration
VOICE_UPLOAD_DIR = Path("uploads/voice")
VOICE_UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
MAX_VOICE_SIZE = 50 * 1024 * 1024  # 50MB for voice (free tier)
MAX_VOICE_SIZE_PREMIUM = 2 * 1024 * 1024 * 1024  # 2GB (premium tier)
ALLOWED_VOICE_EXTENSIONS = {".m4a", ".mp3", ".wav", ".ogg", ".aac"}


@router.post("/voice")
async def upload_voice(
    request: Request,
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Upload a voice/audio file.
    
    - Validates file type (m4a, mp3, wav, ogg, aac)
    - Validates file size (max 50MB)
    - Uploads to GCS (production) or local filesystem (dev)
    - Returns voice URL and metadata
    """
    try:
        original_filename = file.filename or "voice.m4a"
        file_ext = Path(original_filename).suffix.lower()
        
        if file_ext not in ALLOWED_VOICE_EXTENSIONS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid audio type. Allowed: {', '.join(ALLOWED_VOICE_EXTENSIONS)}"
            )
        
        content = await file.read()
        file_size = len(content)
        
        max_size = MAX_VOICE_SIZE_PREMIUM if current_user.is_premium else MAX_VOICE_SIZE
        if file_size > max_size:
            max_mb = max_size / (1024*1024)
            detail = f"Voice file too large. Maximum size: {max_mb:.0f}MB"
            if not current_user.is_premium:
                detail += " — Upgrade to RAVEN+ for up to 2GB voice uploads! 🎤"
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=detail
            )
        
        unique_filename = f"{uuid.uuid4()}{file_ext}"
        mime_type = f"audio/{file_ext[1:]}"
        
        # Try GCS first (production), fall back to local (development)
        bucket = _get_gcs_bucket()
        if bucket:
            gcs_path = f"voice/{unique_filename}"
            full_voice_url = _upload_to_gcs(bucket, content, gcs_path, mime_type)
        else:
            # Local fallback (development)
            file_path = VOICE_UPLOAD_DIR / unique_filename
            with open(file_path, "wb") as f:
                f.write(content)
            base_url = str(request.base_url).rstrip('/')
            full_voice_url = f"{base_url}/uploads/voice/{unique_filename}"
            print(f"📁 Voice saved locally: {unique_filename}")
        
        print(f"✅ Voice uploaded: {unique_filename} ({file_size} bytes) by user {current_user.username}")
        
        return {
            "voice_url": full_voice_url,
            "filename": original_filename,
            "unique_filename": unique_filename,
            "size": file_size,
            "mime_type": mime_type,
        }
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Voice upload error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Voice upload failed"
        )


# Video note upload configuration
VIDEO_NOTE_UPLOAD_DIR = Path("uploads/video_notes")
VIDEO_NOTE_UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
MAX_VIDEO_NOTE_SIZE = 50 * 1024 * 1024  # 50MB (free tier)
MAX_VIDEO_NOTE_SIZE_PREMIUM = 2 * 1024 * 1024 * 1024  # 2GB (premium tier)
ALLOWED_VIDEO_NOTE_EXTENSIONS = {".mp4", ".mov", ".m4v"}


@router.post("/video_note")
async def upload_video_note(
    request: Request,
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Upload a video note (circular recorded video).
    
    - Validates file type (mp4, mov, m4v)
    - Validates file size (max 50MB free, 2GB premium)
    - Uploads to GCS (production) or local filesystem (dev)
    - Returns video URL and metadata
    """
    try:
        original_filename = file.filename or "video_note.mp4"
        file_ext = Path(original_filename).suffix.lower()
        
        if file_ext not in ALLOWED_VIDEO_NOTE_EXTENSIONS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid video type. Allowed: {', '.join(ALLOWED_VIDEO_NOTE_EXTENSIONS)}"
            )
        
        content = await file.read()
        file_size = len(content)
        
        max_size = MAX_VIDEO_NOTE_SIZE_PREMIUM if current_user.is_premium else MAX_VIDEO_NOTE_SIZE
        if file_size > max_size:
            max_mb = max_size / (1024*1024)
            detail = f"Video note too large. Maximum size: {max_mb:.0f}MB"
            if not current_user.is_premium:
                detail += " — Upgrade to RAVEN+ for up to 2GB video notes! 🎬"
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail=detail
            )
        
        unique_filename = f"{uuid.uuid4()}{file_ext}"
        mime_type = MIME_TYPES.get(file_ext, "video/mp4")
        
        # Try GCS first (production), fall back to local (development)
        bucket = _get_gcs_bucket()
        if bucket:
            gcs_path = f"video_notes/{unique_filename}"
            full_video_url = _upload_to_gcs(bucket, content, gcs_path, mime_type)
        else:
            # Local fallback (development)
            file_path = VIDEO_NOTE_UPLOAD_DIR / unique_filename
            with open(file_path, "wb") as f:
                f.write(content)
            base_url = str(request.base_url).rstrip('/')
            full_video_url = f"{base_url}/uploads/video_notes/{unique_filename}"
            print(f"📁 Video note saved locally: {unique_filename}")
        
        print(f"✅ Video note uploaded: {unique_filename} ({file_size} bytes) by user {current_user.username}")

        return {
            "video_url": full_video_url,
            "filename": original_filename,
            "unique_filename": unique_filename,
            "size": file_size,
            "mime_type": mime_type,
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Video note upload error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Video note upload failed"
        )


# ==================== Signed PUT URL for Large Videos ====================
#
# 🟥 ROUND 48 (2026-05-17) — `/api/uploads/video/sign` endpoint.
#
# iOS's `PostUploadManager.uploadVideoStreaming` requests a signed PUT
# URL here, then uploads the video bytes DIRECTLY to GCS — bypassing
# Cloud Run's 32MB request-body cap. Without this endpoint, every
# video upload hit a 404 here and (until R48 broadened the iOS
# fallback gate) propagated as a hard upload failure. Even after the
# R48 iOS fix, the multipart-via-Cloud-Run fallback caps at 32MB,
# which is below the 95MB ceiling iOS compresses to for the free
# tier — so videos between 32MB and 95MB still fail without this
# endpoint.
#
# Request body:  { "file_ext": ".mp4", "content_type": "video/mp4" }
# Response:      { "upload_url": "<signed PUT URL>", "file_url": "<final URL>", "gcs_path": "videos/<uuid>.mp4" }
# Status 503:    GCS unavailable (dev mode) — iOS will fall back to
#                multipart through Cloud Run.
#
# Auth required: yes (any authenticated user can mint an upload URL
# for the `videos/` prefix; the URL is single-use and time-bounded).

# Allowed extensions / content types for the sign endpoint. Match the
# iOS uploader's compression preset (HEVC mp4).
_VIDEO_SIGN_ALLOWED_EXTS = {".mp4", ".mov", ".m4v", ".webm"}
_VIDEO_SIGN_ALLOWED_CONTENT_TYPES = {
    "video/mp4", "video/quicktime", "video/x-m4v", "video/webm",
}


@router.post("/video/sign")
async def sign_video_upload(
    body: dict,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Return a signed GCS PUT URL for direct video upload.

    iOS PUTs raw video bytes to `upload_url`, then stamps `file_url`
    on the post-create body. The signed URL has a 1-hour TTL — long
    enough for slow uploads on cellular, short enough to limit the
    blast radius if leaked.

    The accompanying read-side URL (`file_url`) is the unsigned
    `https://storage.googleapis.com/<bucket>/<path>` form. Readers
    re-sign via `/api/uploads/sign-read` at view time (round-26
    hardening — see `sign_read_url` above).
    """
    from datetime import timedelta as _td

    file_ext = (body or {}).get("file_ext", ".mp4")
    if not file_ext.startswith("."):
        file_ext = "." + file_ext
    file_ext = file_ext.lower()
    if file_ext not in _VIDEO_SIGN_ALLOWED_EXTS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported video extension {file_ext!r}. Allowed: {sorted(_VIDEO_SIGN_ALLOWED_EXTS)}"
        )

    content_type = (body or {}).get("content_type", "video/mp4")
    if content_type not in _VIDEO_SIGN_ALLOWED_CONTENT_TYPES:
        # Be lenient — fall back to mp4 rather than reject. iOS may
        # ship a slightly off content-type that GCS still accepts.
        content_type = "video/mp4"

    bucket = _get_gcs_bucket()
    if bucket is None:
        # iOS catches 503 and falls back to multipart-through-Cloud-Run.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Cloud storage unavailable",
        )

    gcs_path = f"videos/{uuid.uuid4()}{file_ext}"
    blob = bucket.blob(gcs_path)
    # Pre-stamp cache headers — same private+max-age combo as
    # _upload_to_gcs so the read-side CDN behavior is consistent.
    blob.cache_control = "private, max-age=900, no-transform"

    try:
        # V4 signed PUT — 1-hour expiration. Long enough to absorb
        # bad cellular + retry; short enough to limit replay.
        # 🔴 ROUND 31 — IAM-signing path (see `_get_signing_credentials`).
        sa_email, access_token = _get_signing_credentials()
        sign_kwargs = {
            "version": "v4",
            "expiration": _td(hours=1),
            "method": "PUT",
            "content_type": content_type,
        }
        if sa_email and access_token:
            sign_kwargs["service_account_email"] = sa_email
            sign_kwargs["access_token"] = access_token
        signed_put = blob.generate_signed_url(**sign_kwargs)
    except Exception as e:
        print(f"⚠️ [video/sign] generate_signed_url(PUT) failed: {type(e).__name__}: {e}")
        # Grant the Cloud Run service account
        # `roles/iam.serviceAccountTokenCreator` to enable signing.
        # Until that's done, return 503 so iOS falls back to the
        # multipart path through Cloud Run (size-capped at 32MB).
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Signed-URL signing unavailable",
        )

    # The post-upload read URL. Readers will re-sign this for actual
    # playback via /api/uploads/sign-read (round-26 fix).
    final_url = f"https://storage.googleapis.com/{bucket.name}/{gcs_path}"

    print(f"🔐 [video/sign] minted PUT URL for {current_user.username[:12]} → {gcs_path} (1h TTL)")

    return {
        "upload_url": signed_put,
        "file_url": final_url,
        "gcs_path": gcs_path,
    }
