"""
Ephemeral Photo (Snap) Endpoints
──────────────────────────────────
One-shot photo messages that auto-delete after viewing.
Uses the existing SnapMessage model.
"""
from fastapi import APIRouter, Depends, File, UploadFile, HTTPException, status, Request, Form
from sqlalchemy.orm import Session
from PIL import Image, ImageOps
import io
import uuid
import os
from pathlib import Path
from datetime import datetime, timedelta

from database import get_db
from models import User, SnapMessage
from routers.users import get_current_user

router = APIRouter(prefix="/api/snaps", tags=["snaps"])

# ==================== Storage Configuration ====================
GCS_MEDIA_BUCKET = os.getenv("GCS_MEDIA_BUCKET", "raven-media-uploads")
EPHEMERAL_UPLOAD_DIR = Path("uploads/ephemeral")
EPHEMERAL_UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

# ── Guard: ensure snap_messages table AND required columns exist ──
# Uses information_schema to avoid poisoning PostgreSQL transactions
# (a failed SELECT aborts the entire tx in Postgres).
_table_checked = False
def _ensure_table():
    global _table_checked
    if _table_checked:
        return
    try:
        from database import engine
        from sqlalchemy import text, inspect

        # 1. Ensure table exists
        inspector = inspect(engine)
        if "snap_messages" not in inspector.get_table_names():
            SnapMessage.__table__.create(engine, checkfirst=True)
            print("📸 snap_messages table created on-demand")

        # 2. Check columns via information_schema (no transaction poison risk)
        required_columns = {
            "conversation_id": "ALTER TABLE snap_messages ADD COLUMN conversation_id VARCHAR",
            "ttl_seconds": "ALTER TABLE snap_messages ADD COLUMN ttl_seconds INTEGER DEFAULT 10",
        }

        with engine.connect() as conn:
            result = conn.execute(text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_name = 'snap_messages'"
            ))
            existing = {row[0] for row in result}

            for col, ddl in required_columns.items():
                if col not in existing:
                    conn.execute(text(ddl))
                    print(f"📸 Added column snap_messages.{col}")

            conn.commit()

        _table_checked = True
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"⚠️ snap_messages table/column check failed: {e}")

MAX_SNAP_SIZE = 10 * 1024 * 1024  # 10MB
ALLOWED_SNAP_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
MAX_SNAP_DIMENSION = 2048
SIGNED_URL_EXPIRY_SECONDS = 30  # Short-lived access


def _get_gcs_bucket():
    """Get GCS bucket client. Returns None if GCS is unavailable (dev mode)."""
    try:
        from google.cloud import storage as gcs_storage
        client = gcs_storage.Client()
        return client.bucket(GCS_MEDIA_BUCKET)
    except Exception:
        return None


# ────────────────────────────────────────────────────────────────────
# 🔴 H8 — V4 signed-URL credentials on Cloud Run (mirrors uploads.py
# ROUND 31). Cloud Run authenticates via Compute Engine metadata-server
# tokens, NOT a private key file. A plain `blob.generate_signed_url`
# raises `AttributeError: you need a private key to sign credentials`
# there, and the old except-block returned the RAW unsigned GCS URL —
# useless on the private UBLA bucket and, if ever public, an eternal
# unauthenticated leak that defeats the 30-second ephemeral guarantee.
#
# Fix: pass `version="v4"` + IAM `service_account_email`/`access_token`
# so the SDK routes signing through IAM signBlob (needs
# `roles/iam.serviceAccountTokenCreator` on the service account itself).
# Locally, credentials carry a private key so we return (None, None)
# and the SDK signs directly. Identical to uploads._get_signing_credentials.
_signing_creds_cache: dict = {"creds": None}


def _get_signing_credentials():
    """Return `(service_account_email, access_token)` for passing to
    `blob.generate_signed_url(...)` on Cloud Run. Returns `(None, None)`
    in dev / when credentials have a local private key."""
    try:
        import google.auth
        import google.auth.transport.requests as _gauth_requests

        creds = _signing_creds_cache.get("creds")
        if creds is None:
            creds, _project = google.auth.default(
                scopes=["https://www.googleapis.com/auth/cloud-platform"]
            )
            _signing_creds_cache["creds"] = creds

        # Local private key (dev / service-account JSON): SDK can sign
        # without IAM — return None so we don't over-engineer the call.
        if hasattr(creds, "signer_email") and not hasattr(creds, "service_account_email"):
            return (None, None)

        # Compute Engine path: refresh to mint a token, return (email, token).
        if not getattr(creds, "valid", False):
            creds.refresh(_gauth_requests.Request())

        sa_email = getattr(creds, "service_account_email", None)
        token = getattr(creds, "token", None)
        if sa_email and token:
            return (sa_email, token)
        return (None, None)
    except Exception as e:
        print(f"⚠️ [SnapSignCreds] could not get signing credentials: {type(e).__name__}: {e}")
        return (None, None)


def _upload_to_gcs(bucket, content: bytes, gcs_path: str, content_type: str) -> str:
    """Upload bytes to GCS and return the public URL."""
    blob = bucket.blob(gcs_path)
    blob.upload_from_string(content, content_type=content_type)
    public_url = f"https://storage.googleapis.com/{bucket.name}/{gcs_path}"
    print(f"☁️ Snap uploaded to GCS: {gcs_path}")
    return public_url


def _generate_signed_url(media_url: str, expiry_seconds: int = SIGNED_URL_EXPIRY_SECONDS) -> str:
    """Generate a short-lived signed URL for ephemeral media.
    Falls back to the raw URL in dev mode (no GCS)."""
    bucket = _get_gcs_bucket()
    if bucket and media_url.startswith("https://storage.googleapis.com/"):
        # Extract blob path from full URL
        prefix = f"https://storage.googleapis.com/{bucket.name}/"
        blob_path = media_url.replace(prefix, "")
        blob = bucket.blob(blob_path)
        try:
            # 🔴 H8 — pass IAM signing credentials so Cloud Run (no
            # private key) can sign via the signBlob API. See
            # `_get_signing_credentials` for the why.
            sa_email, access_token = _get_signing_credentials()
            sign_kwargs = {
                "version": "v4",
                "expiration": timedelta(seconds=expiry_seconds),
                "method": "GET",
            }
            if sa_email and access_token:
                sign_kwargs["service_account_email"] = sa_email
                sign_kwargs["access_token"] = access_token
            return blob.generate_signed_url(**sign_kwargs)
        except Exception as e:
            # 🔴 H8 — FAIL CLOSED. Never return the raw unsigned URL for
            # a private-bucket ephemeral snap. Grant the Cloud Run
            # service account 'roles/iam.serviceAccountTokenCreator' on
            # itself to enable signBlob if this fires in production.
            print(f"❌ Snap signed-URL generation failed ({type(e).__name__}: {e}) — "
                  f"refusing to serve unsigned ephemeral URL. Grant the Cloud Run "
                  f"service account 'roles/iam.serviceAccountTokenCreator'.")
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Snap media temporarily unavailable (signing failed).",
            )
    return media_url


def _delete_media(media_url: str):
    """Delete media from GCS or local filesystem."""
    bucket = _get_gcs_bucket()
    if bucket and media_url.startswith("https://storage.googleapis.com/"):
        prefix = f"https://storage.googleapis.com/{bucket.name}/"
        blob_path = media_url.replace(prefix, "")
        blob = bucket.blob(blob_path)
        try:
            blob.delete()
            print(f"🗑️ Deleted ephemeral media from GCS: {blob_path}")
        except Exception as e:
            print(f"⚠️ GCS delete failed: {e}")
    else:
        # Local file deletion
        try:
            filename = media_url.split("/")[-1]
            local_path = EPHEMERAL_UPLOAD_DIR / filename
            if local_path.exists():
                local_path.unlink()
                print(f"🗑️ Deleted local ephemeral file: {filename}")
        except Exception as e:
            print(f"⚠️ Local delete failed: {e}")


# ==================== Endpoints ====================


@router.post("/send")
async def send_snap(
    request: Request,
    file: UploadFile = File(...),
    recipient_id: str = Form(...),
    ttl_seconds: int = Form(10),
    conversation_id: str = Form(None),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Upload an ephemeral photo and create a SnapMessage.

    - Validates image (JPEG, PNG, WebP, max 10MB)
    - Optimizes and uploads to GCS or local
    - Creates SnapMessage with specified TTL (5s or 10s)
    - Returns snap metadata

    🔴 ROUND 58 (2026-05-19) — hacker-audit Snap F2 (CRITICAL).
    PREVIOUSLY: this endpoint accepted any `recipient_id` and
    immediately created (a) a `SnapMessage` row, (b) a `Message`
    row in the recipient's inbox, (c) an in-app `Notification`,
    (d) a WebSocket push, AND (e) an APNs push. ALL of that bypassed
    the friend / message-request / block gate that the standard
    `/api/messages/send` enforces.

    Concrete attacks the gate was missing:
      • Snap bombing: attacker creates 100 throwaway accounts and
        sends a snap to every user in a target community → every
        target receives a push notification "📸 Ephemeral Photo"
        from a stranger. The push itself is harassment, even if
        the recipient never opens.
      • Block bypass: a blocked attacker can still snap-DM a victim
        who blocked them, because the block check lives in
        `/api/messages/send` (which uses `Block` joins) — it never
        ran here.
      • Stalker channel: snaps create a `Message` row that surfaces
        in the recipient's conversation list, opening a private
        chat thread against the victim's will.
      • Rate-free upload: a single account could fire 1000
        snaps/minute → S3/GCS cost amplification.

    FIX: mirror the gates that `/api/messages/send` already has —
    block-check both directions, require friendship OR an active
    message-request the recipient accepted, and per-sender rate
    limit. Senders also must own the conversation_id if one is
    supplied. Reuses the existing `rate_limiter` singleton.
    """
    from sqlalchemy import or_, and_
    from models import Block, FriendRequest, MessageRequest
    from middleware.rate_limit import rate_limiter

    # Ensure table exists (handles DB init race / skipped migrations)
    _ensure_table()

    try:
        # 🔴 ROUND 58 — Step 0: per-sender rate limit. 30 snaps/min
        # is comfortable for legitimate use, kills bombing.
        rate_limiter.check_rate_limit(
            identifier=f"snap_send:{current_user.id}",
            max_attempts=30,
            window_minutes=1,
            lockout_minutes=5,
        )

        # 🔴 ROUND 58 — Step 1: self-send is meaningless, reject.
        if recipient_id == current_user.id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Cannot send a snap to yourself",
            )

        # 🔴 ROUND 58 — Step 2: bidirectional block check.
        blocked = db.query(Block).filter(
            or_(
                and_(Block.blocker_id == current_user.id, Block.blocked_id == recipient_id),
                and_(Block.blocker_id == recipient_id, Block.blocked_id == current_user.id),
            )
        ).first()
        if blocked:
            # Same generic 403 regardless of direction so we don't
            # leak which side blocked which.
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Cannot send snap to this user",
            )

        # 🔴 ROUND 58 — Step 3: friendship-or-accepted-request gate.
        # Matches the policy `/api/messages/send` enforces: either
        # the two users are friends, OR the recipient has accepted a
        # message-request from the sender.
        is_friend = db.query(FriendRequest).filter(
            or_(
                and_(FriendRequest.requester_id == current_user.id,
                     FriendRequest.recipient_id == recipient_id,
                     FriendRequest.status == "accepted"),
                and_(FriendRequest.requester_id == recipient_id,
                     FriendRequest.recipient_id == current_user.id,
                     FriendRequest.status == "accepted"),
            )
        ).first() is not None

        if not is_friend:
            accepted_request = db.query(MessageRequest).filter(
                MessageRequest.sender_id == current_user.id,
                MessageRequest.recipient_id == recipient_id,
                MessageRequest.status == "accepted",
            ).first()
            if not accepted_request:
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail=(
                        "Snaps require an accepted friend request or "
                        "message request first."
                    ),
                )

        # Validate extension
        file_ext = Path(file.filename or "").suffix.lower()
        if file_ext not in ALLOWED_SNAP_EXTENSIONS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid file type. Allowed: {', '.join(ALLOWED_SNAP_EXTENSIONS)}",
            )

        # Read and validate size
        content = await file.read()
        if len(content) > MAX_SNAP_SIZE:
            raise HTTPException(
                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                detail="File too large. Maximum 10MB for snaps.",
            )

        # Clamp TTL
        ttl_seconds = max(3, min(ttl_seconds, 30))

        # Process image
        image = Image.open(io.BytesIO(content))
        image = ImageOps.exif_transpose(image)
        if image.mode == "RGBA":
            bg = Image.new("RGB", image.size, (255, 255, 255))
            bg.paste(image, mask=image.split()[3])
            image = bg
        elif image.mode not in ("RGB", "L"):
            image = image.convert("RGB")

        if image.width > MAX_SNAP_DIMENSION or image.height > MAX_SNAP_DIMENSION:
            image.thumbnail((MAX_SNAP_DIMENSION, MAX_SNAP_DIMENSION), Image.Resampling.LANCZOS)

        # Save to buffer
        output = io.BytesIO()
        if file_ext in [".jpg", ".jpeg"]:
            image.save(output, "JPEG", quality=80, optimize=True)
            content_type = "image/jpeg"
        elif file_ext == ".png":
            image.save(output, "PNG", optimize=True)
            content_type = "image/png"
        else:
            image.save(output, "WEBP", quality=80)
            content_type = "image/webp"

        optimized = output.getvalue()
        unique_filename = f"{uuid.uuid4()}{file_ext}"

        # Upload to GCS or local
        bucket = _get_gcs_bucket()
        if bucket:
            gcs_path = f"ephemeral/{unique_filename}"
            media_url = _upload_to_gcs(bucket, optimized, gcs_path, content_type)
        else:
            file_path = EPHEMERAL_UPLOAD_DIR / unique_filename
            with open(file_path, "wb") as f:
                f.write(optimized)
            base_url = str(request.base_url).rstrip("/")
            media_url = f"{base_url}/uploads/ephemeral/{unique_filename}"
            print(f"📁 Snap saved locally: {unique_filename}")

        # Create SnapMessage record
        snap = SnapMessage(
            id=str(uuid.uuid4()),
            sender_id=current_user.id,
            recipient_id=recipient_id,
            media_url=media_url,
            media_type="image",
            view_duration=ttl_seconds,
            view_limit=1,
            status="sent",
            expires_at=datetime.utcnow() + timedelta(hours=24),  # Auto-expire after 24h unopened
        )
        # Set optional fields if columns exist
        try:
            snap.conversation_id = conversation_id
        except Exception:
            pass
        try:
            snap.ttl_seconds = ttl_seconds
        except Exception:
            pass

        db.add(snap)
        db.commit()
        db.refresh(snap)

        print(f"📸 Snap created: {snap.id[:8]} from {current_user.username} → {recipient_id[:8]} (TTL={ttl_seconds}s)")

        # ── Create a Message record so it appears in the recipient's chat ──
        from models import Message, Notification
        from encryption import encrypt_text
        import json

        # 🔴 ROUND 26 (2026-05-16) — hacker-mode audit MEDIA-CRIT-7.
        #
        # PREVIOUSLY: this Message row stored `audio_url=media_url`
        # (the raw GCS URL of the snap). Recipients fetched the
        # message via `GET /api/messages/conversation/{sender_id}`
        # and got the GCS URL back — `curl $URL` returned the photo,
        # NO /snaps/{id}/open round-trip, view_count never incremented,
        # status stayed "sent", screenshot-detection never fired,
        # _delete_media() never ran. The 24-h snap.expires_at applied
        # to the SnapMessage row, not the GCS object. Effectively the
        # entire "ephemeral" guarantee was bypassable in one curl.
        #
        # FIX: don't put the GCS URL in `audio_url`. Recipients see
        # an in-chat row pointing at `snap_id`; they must hit
        # `/api/snaps/{id}/open` to get the (re-signed) URL, which
        # is the path that enforces view_count + auto-delete.
        message = Message(
            id=str(uuid.uuid4()),
            sender_id=current_user.id,
            recipient_id=recipient_id,
            content=encrypt_text(f"📸 Ephemeral photo ({ttl_seconds}s)"),
            message_type="ephemeral_photo",
            audio_url=None,  # round 26 — NEVER expose raw snap URL here
            timestamp=datetime.utcnow(),
        )
        db.add(message)

        # ── Create in-app notification ──
        notif = Notification(
            user_id=recipient_id,
            type="message",
            data=json.dumps({
                "room_id": current_user.id,
                "sender_id": current_user.id,
                "sender_username": current_user.username,
                "preview": "📸 Ephemeral Photo",
                "message_type": "ephemeral_photo",
                "snap_id": snap.id,
            }),
            is_read=False,
        )
        db.add(notif)
        db.commit()
        db.refresh(message)

        # ── WebSocket: instant delivery ──
        try:
            from ws_manager import ws_manager
            await ws_manager.notify(recipient_id, {
                "id": message.id,
                "sender_id": current_user.id,
                "recipient_id": recipient_id,
                "content": "📸 Ephemeral Photo",
                "timestamp": message.timestamp.isoformat() + "Z",
                "read_at": None,
                "delivered_at": None,
                "sender_username": current_user.username,
                "sender_name": current_user.username,
                "message_type": "ephemeral_photo",
                "room_id": current_user.id,
                # 🔴 ROUND 26 — MEDIA-CRIT-7: never ship raw snap URL.
                # Recipient must call /api/snaps/{id}/open to get a
                # short-lived signed URL AND trip the view-counter.
                "audio_url": None,
                "audio_duration_seconds": None,
                "file_name": None,
                "file_size": None,
                "mime_type": "image/jpeg",
                "snap_id": snap.id,
                "ttl_seconds": ttl_seconds,
            })
            print(f"⚡ [Snap] WebSocket notification sent to {recipient_id[:8]}")
        except Exception as ws_err:
            print(f"⚠️ [Snap] WebSocket notify failed: {ws_err}")

        # ── Push notification ──
        try:
            recipient = db.query(User).filter(User.id == recipient_id).first()
            if recipient and recipient.push_token and recipient.push_platform == "ios":
                from services.apns_service import get_apns_service, APNsService
                prefs = APNsService.should_send_push(recipient, "message")
                if prefs["allowed"]:
                    apns = get_apns_service()
                    push_result = await apns.send_message_notification(
                        device_token=recipient.push_token,
                        sender_name=current_user.username,
                        message_preview="📸 Ephemeral Photo" if prefs["show_preview"] else "New message",
                        room_id=current_user.id,
                        sender_id=current_user.id,
                        message_type="ephemeral_photo",
                    )
                    if push_result:
                        print(f"📱 ✅ [Snap] Push sent to {recipient.username}")
        except Exception as push_err:
            print(f"⚠️ [Snap] Push notification failed: {push_err}")

        return {
            "snap_id": snap.id,
            "message_id": message.id,
            "sender_id": current_user.id,
            "recipient_id": recipient_id,
            "media_type": "image",
            "ttl_seconds": ttl_seconds,
            "status": "sent",
            "created_at": snap.created_at.isoformat(),
            "message_type": "ephemeral_photo",
        }

    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"❌ Snap upload error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Snap upload failed: {str(e)}",
        )


@router.post("/{snap_id}/open")
async def open_snap(
    snap_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Open an ephemeral photo — returns a short-lived signed URL.
    
    - Only the recipient can open
    - Rejects if already viewed (view_count >= view_limit)
    - Sets opened_at, increments view_count
    - Returns a 30-second signed URL
    """
    snap = db.query(SnapMessage).filter(SnapMessage.id == snap_id).first()
    if not snap:
        raise HTTPException(status_code=404, detail="Snap not found")

    if snap.recipient_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized to view this snap")

    if snap.view_count >= snap.view_limit:
        raise HTTPException(status_code=410, detail="Snap already viewed")

    if snap.status == "expired":
        raise HTTPException(status_code=410, detail="Snap has expired")

    # Mark as opened
    now = datetime.utcnow()
    snap.opened_at = now
    snap.view_count += 1
    snap.status = "opened"
    snap.expires_at = now + timedelta(seconds=snap.view_duration or 10)
    db.commit()

    # Generate short-lived URL
    signed_url = _generate_signed_url(snap.media_url)
    ttl = snap.view_duration or 10

    print(f"👁️ Snap opened: {snap_id[:8]} by {current_user.username} (TTL={ttl}s)")

    return {
        "snap_id": snap.id,
        "media_url": signed_url,
        "ttl_seconds": ttl,
        "opened_at": snap.opened_at.isoformat(),
        "expires_at": snap.expires_at.isoformat(),
    }


@router.post("/{snap_id}/viewed")
async def complete_view(
    snap_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Confirm ephemeral photo view is complete — triggers media deletion.
    
    - Only the recipient can confirm
    - Sets status to 'expired'
    - Deletes media from storage
    """
    snap = db.query(SnapMessage).filter(SnapMessage.id == snap_id).first()
    if not snap:
        raise HTTPException(status_code=404, detail="Snap not found")

    if snap.recipient_id != current_user.id:
        raise HTTPException(status_code=403, detail="Not authorized")

    # Mark expired and delete media
    snap.status = "expired"
    db.commit()

    # Delete media file in background
    _delete_media(snap.media_url)

    print(f"🔥 Snap expired: {snap_id[:8]} — media deleted")

    return {"snap_id": snap.id, "status": "expired"}


@router.post("/{snap_id}/screenshot")
async def report_screenshot(
    snap_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Report that the recipient took a screenshot.

    - Sets screenshot_attempted = True
    - Can be used to notify the sender

    🔴 ROUND 57 (2026-05-19) — hacker-audit Snap F1 (CRITICAL).
    PREVIOUSLY: this endpoint had ZERO ownership check. Any
    authenticated user could call `/api/snaps/<arbitrary_snap_id>/
    screenshot` and trip `screenshot_attempted=True` on someone
    else's snap. Concrete attacks:
      • Harassment: attacker scrapes snap ids (via abuse of GET
        /pending against bot accounts) and reports each one as
        screenshotted → senders get false alerts → trust breaks
        between real friends.
      • Distraction: an attacker on a victim's chat thread can
        spam-report screenshots on their own snaps to flood the
        sender's notification feed.
    FIX: require `snap.recipient_id == current_user.id`, the same
    check used by `/open` and `/viewed`. Senders never report
    screenshots on their own sent snaps; non-recipients have no
    legitimate reason to call this endpoint.
    """
    snap = db.query(SnapMessage).filter(SnapMessage.id == snap_id).first()
    if not snap:
        raise HTTPException(status_code=404, detail="Snap not found")

    if snap.recipient_id != current_user.id:
        # 🔴 ROUND 57 — only the recipient can report a screenshot.
        # Return 403 (not 404) here because the snap clearly exists;
        # the caller's authorization is the missing piece.
        raise HTTPException(status_code=403, detail="Not authorized")

    snap.screenshot_attempted = True
    db.commit()

    print(f"📷 Screenshot detected on snap: {snap_id[:8]} by {current_user.username}")

    return {"snap_id": snap.id, "screenshot_attempted": True}


@router.get("/pending")
async def get_pending_snaps(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """
    Get all pending (un-opened) snaps for the current user.
    """
    snaps = (
        db.query(SnapMessage)
        .filter(
            SnapMessage.recipient_id == current_user.id,
            SnapMessage.status == "sent",
            SnapMessage.expires_at > datetime.utcnow(),
        )
        .order_by(SnapMessage.created_at.desc())
        .all()
    )

    return {
        "snaps": [
            {
                "snap_id": s.id,
                "sender_id": s.sender_id,
                "media_type": s.media_type,
                "ttl_seconds": s.view_duration,
                "status": s.status,
                "created_at": s.created_at.isoformat(),
            }
            for s in snaps
        ],
        "count": len(snaps),
    }
