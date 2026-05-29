"""
Admin endpoints for database management.
DANGER: These endpoints can destroy all data!
"""
import secrets as _secrets_mod
from fastapi import APIRouter, Depends, HTTPException, Header
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session
from database import get_db
import os

router = APIRouter(prefix="/api/admin", tags=["admin"])

# 🔴 ROUND 56 (2026-05-19) — hacker-audit Server F15 (CATASTROPHIC).
#
# THE BUG:
#   PREVIOUSLY: `ADMIN_SECRET = os.getenv("ADMIN_SECRET", "RAVEN_ADMIN_2026")`
#   plus `if x_admin_secret != ADMIN_SECRET`. Two compounding
#   disasters:
#
#   (a) Hardcoded default secret literally checked into the repo
#       (and into the GitHub mirror we just shared with a
#       collaborator). On any deploy where the operator forgot to
#       set ADMIN_SECRET, the secret falls back to a string anyone
#       reading the source can copy-paste:
#
#         curl -X POST https://api.raven-messager.com/api/admin/reset-database \
#              -H "X-Admin-Secret: RAVEN_ADMIN_2026"
#
#       One HTTP call → `/reset-database` deletes EVERY row in
#       every table: users, messages, posts, verification requests,
#       backups. Total destruction with zero authentication.
#
#       The same un-authentication unlocks:
#         • /clear-messages          (wipe all DMs)
#         • /verification/queue      (list every KYC submission)
#         • /verification/doc/...    (DOWNLOAD ANY USER'S ID DOC +
#                                     selfie photos — passports,
#                                     national IDs, driver licenses
#                                     of every verified user)
#         • /verification/{id}       (decrypted legal names of every
#                                     verified user)
#         • /verification/{id}/approve  (grant attacker a verified
#                                     badge by approving their own
#                                     blank request)
#         • /run-migration           (run arbitrary ALTER TABLE)
#         • /reports                 (read every abuse report)
#
#   (b) `x_admin_secret != ADMIN_SECRET` is direct string compare,
#       not constant-time. Even if the operator sets a strong env,
#       a timing oracle can leak the first byte of the secret over
#       network noise (low-rate attack but eventually fatal).
#
# THE FIX (defense in layers):
#   1. Fail closed when ADMIN_SECRET is empty. Production refuses
#      to serve admin endpoints at all — same posture as the round
#      46 RevenueCat webhook fix.
#   2. Refuse to serve admin endpoints when ADMIN_SECRET equals the
#      known historical default ("RAVEN_ADMIN_2026"). Even if some
#      operator literally typed that into the env var, treat it as
#      "secret is leaked" and lock the admin surface.
#   3. Constant-time compare via `secrets.compare_digest`.
#   4. Operators MUST set a fresh strong secret (e.g.,
#      `python -c "import secrets; print(secrets.token_urlsafe(48))"`)
#      before admin endpoints work.
ADMIN_SECRET = os.getenv("ADMIN_SECRET", "")

# 🔴 ROUND 56 — the well-known historical default. Any deploy whose
# operator left this literal string in place is treated as "unset"
# so the admin surface stays locked.
_KNOWN_BAD_DEFAULTS = {
    "RAVEN_ADMIN_2026",
    "RAVEN_ADMIN",
    "admin",
    "secret",
    "changeme",
    "",
}


def verify_admin_secret(x_admin_secret: str = Header(...)):
    """Verify the admin secret header.

    🔴 ROUND 56 — fail-closed posture + constant-time compare. See
    the module-level comment block for the catastrophic bug this
    replaces.
    """
    # 1. Refuse to authorize if the configured secret is empty or
    #    matches the historical default. Logs loudly so the
    #    operator notices.
    if not ADMIN_SECRET or ADMIN_SECRET in _KNOWN_BAD_DEFAULTS:
        env = os.getenv("ENVIRONMENT", "development")
        if env == "production":
            # In production this is a SEV-1; never allow admin work.
            print(
                "🚫 [Admin] CRITICAL: ADMIN_SECRET is unset or set to a "
                "known-bad default. Refusing all admin requests. "
                "Operator: set ADMIN_SECRET to a fresh "
                "`secrets.token_urlsafe(48)` value."
            )
        raise HTTPException(
            status_code=503,
            detail="admin endpoints disabled — operator must configure ADMIN_SECRET",
        )

    # 2. Constant-time compare so a partial-match timing oracle
    #    can't dribble out the first byte of the configured secret.
    if not _secrets_mod.compare_digest(str(x_admin_secret or ""), str(ADMIN_SECRET)):
        raise HTTPException(status_code=403, detail="Invalid admin secret")
    return True


@router.post("/reset-database")
def reset_database(
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """
    ⚠️ DANGER: Completely reset the database!
    This deletes ALL data: users, messages, posts, etc.
    
    Requires X-Admin-Secret header.
    """
    try:
        # Get all table names
        from models import (
            User, Message, Post, Comment, PostLike, 
            Notification, FriendRequest, HashtagFollow,
            Report, Block, ScreenshotNotification,
            Backup, CommentVote, Repost, PostView,
            Device, Group, GroupMember, Friendship,
            UserEvent, UserInterest, SeenPost, UserNegativeFeedback
        )
        
        # Order matters due to foreign keys - delete children first
        tables_to_clear = [
            UserNegativeFeedback,
            SeenPost,
            UserInterest,
            UserEvent,
            Friendship,
            GroupMember,
            Group,
            Device,
            PostView,
            Repost,
            CommentVote,
            Backup,
            Block,
            ScreenshotNotification,
            Report,
            HashtagFollow,
            FriendRequest,
            Notification,
            PostLike,
            Comment,
            Post,
            Message,
            User,
        ]
        
        deleted_counts = {}
        
        for model in tables_to_clear:
            try:
                count = db.query(model).delete()
                deleted_counts[model.__tablename__] = count
            except Exception as e:
                print(f"Error deleting {model.__tablename__}: {e}")
                deleted_counts[model.__tablename__] = f"error: {str(e)}"
        
        db.commit()
        
        return {
            "status": "success",
            "message": "Database has been completely reset!",
            "deleted": deleted_counts
        }
        
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Reset failed: {str(e)}")


@router.post("/clear-messages")
def clear_messages(
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """
    Clear only messages (keep users and posts).
    Requires X-Admin-Secret header.
    """
    try:
        from models import Message
        
        count = db.query(Message).delete()
        db.commit()
        
        return {
            "status": "success",
            "message": f"Deleted {count} messages"
        }
        
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Clear failed: {str(e)}")


@router.post("/run-migration")
def run_migration(
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """
    Run database migrations to add new columns.
    Safe to run multiple times — duplicate column errors are caught and skipped.
    """
    from sqlalchemy import text
    
    # NOTE: SQLite doesn't support IF NOT EXISTS in ALTER TABLE,
    # so we rely on the try-except to skip already-existing columns.
    migrations = [
        # Phone hash for contact sync
        "ALTER TABLE users ADD COLUMN phone_hash VARCHAR(64)",
        "ALTER TABLE users ADD COLUMN allow_contact_discovery BOOLEAN DEFAULT TRUE",
        "CREATE INDEX IF NOT EXISTS idx_users_phone_hash ON users(phone_hash)",
        # Notification preferences
        "ALTER TABLE users ADD COLUMN push_enabled BOOLEAN DEFAULT TRUE",
        "ALTER TABLE users ADD COLUMN message_notifications_enabled BOOLEAN DEFAULT TRUE",
        "ALTER TABLE users ADD COLUMN friend_request_notifications_enabled BOOLEAN DEFAULT TRUE",
        "ALTER TABLE users ADD COLUMN likes_comments_notifications_enabled BOOLEAN DEFAULT TRUE",
        "ALTER TABLE users ADD COLUMN sounds_enabled BOOLEAN DEFAULT TRUE",
        "ALTER TABLE users ADD COLUMN message_preview_enabled BOOLEAN DEFAULT TRUE",
        # Privacy settings
        "ALTER TABLE users ADD COLUMN show_online_status BOOLEAN DEFAULT TRUE",
        "ALTER TABLE users ADD COLUMN read_receipts_enabled BOOLEAN DEFAULT TRUE",
        "ALTER TABLE users ADD COLUMN who_can_message VARCHAR DEFAULT 'everyone'",
        "ALTER TABLE users ADD COLUMN who_can_see_profile VARCHAR DEFAULT 'public'",
    ]
    
    results = []
    for sql in migrations:
        try:
            db.execute(text(sql))
            db.commit()
            results.append({"sql": sql[:55] + "...", "status": "success"})
        except Exception as e:
            db.rollback()
            error_msg = str(e).lower()
            if "duplicate" in error_msg or "already exists" in error_msg:
                results.append({"sql": sql[:55] + "...", "status": "skipped (already exists)"})
            else:
                results.append({"sql": sql[:55] + "...", "status": f"error: {str(e)}"})
    
    return {
        "status": "success",
        "message": "Migrations completed",
        "results": results
    }


# ==================== IDENTITY VERIFICATION ADMIN ====================

@router.get("/verification/queue")
def get_verification_queue(
    status_filter: str = "pending",
    limit: int = 50,
    offset: int = 0,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """List verification requests by status."""
    from models import VerificationRequest, User
    from encryption import decrypt_text
    
    query = db.query(VerificationRequest).filter(
        VerificationRequest.status == status_filter
    ).order_by(VerificationRequest.submitted_at.asc())
    
    total = query.count()
    requests = query.offset(offset).limit(limit).all()
    
    items = []
    # 🔴 ROUND 71 S25 + FIX-UP: country + legal_name need decrypt-or-
    # passthrough. Local import of `decrypt_text` because admin.py
    # does NOT import it at module top — same NameError bug pattern
    # as serve_verification_document.
    from encryption import decrypt_text as _q_dec
    def _try_dec(val):
        if not val:
            return None
        try:
            return _q_dec(val)
        except Exception:
            return val

    for req in requests:
        user = db.query(User).filter(User.id == req.user_id).first()
        first = _try_dec(req.legal_first_name) or ""
        last = _try_dec(req.legal_last_name) or ""
        items.append({
            "id": req.id,
            "user_id": req.user_id,
            "username": user.username if user else "unknown",
            "avatar": user.avatar_path if user else None,
            "status": req.status,
            "category": req.category,
            "country": _try_dec(req.country) or "—",
            "doc_type": req.doc_type,
            "legal_name": f"{first} {last}".strip(),
            "submitted_at": req.submitted_at.isoformat() if req.submitted_at else None,
            "has_front": bool(req.doc_front_url),
            "has_back": bool(req.doc_back_url),
            "has_selfie": bool(req.selfie_url),
        })
    
    return {"total": total, "items": items}


@router.get("/verification/doc/{user_id}/{filename}")
def serve_verification_document(
    user_id: str,
    filename: str,
    _: bool = Depends(verify_admin_secret)
):
    """Serve a verification document image (admin only).
    Supports both GCS storage (production) and local filesystem (development).

    🔴 ROUND 71 S26: previously only the admin-secret header was
    required; no DB lookup confirmed the (user_id, filename) pair
    actually belonged to a VerificationRequest row. Anyone with the
    admin secret (which leaks via logs / dev tools / shared docs)
    could guess `user_id/filename` GCS paths and download arbitrary
    files from the bucket. Now: a Session dep + lookup against
    VerificationRequest.doc_*_url confirms the path is referenced
    by an actual KYC submission before serving.
    """
    from pathlib import Path
    import mimetypes
    from fastapi.responses import Response
    from database import SessionLocal
    from models import VerificationRequest

    # Sanitize path components to prevent directory traversal
    if '..' in user_id or '/' in user_id or '..' in filename or '/' in filename:
        raise HTTPException(status_code=400, detail="Invalid path")

    # 🔴 ROUND 71 S26: ownership check — verify this path actually
    # belongs to a VerificationRequest row. Decrypt-then-substring
    # match (round-70 Fernet-wrapped) with a small per-user scan
    # (KYC volume is low). Refuses 404 on unknown paths to prevent
    # arbitrary bucket reads.
    #
    # 🔴 ROUND 71 FIX-UP: `decrypt_text` is not imported at module
    # top; the previous edit assumed it was. Local import here so
    # the function actually runs instead of throwing NameError →
    # 500 on every admin doc fetch.
    from encryption import decrypt_text as _vd_dec
    _db = SessionLocal()
    try:
        _vreqs = _db.query(VerificationRequest).filter(
            VerificationRequest.user_id == user_id
        ).all()
        _found = False
        for _vr in _vreqs:
            for _col in ("doc_front_url", "doc_back_url", "selfie_url"):
                _stored = getattr(_vr, _col, None)
                if not _stored:
                    continue
                try:
                    _plain = _vd_dec(_stored)
                except Exception:
                    _plain = _stored
                if _plain and filename in _plain:
                    _found = True
                    break
            if _found:
                break
        if not _found:
            raise HTTPException(status_code=404, detail="Document not found")
    finally:
        _db.close()

    gcs_path = f"{user_id}/{filename}"
    print(f"📄 [VerifDoc] Serving: {gcs_path}")
    
    # Determine content type
    content_type, _ = mimetypes.guess_type(filename)
    if not content_type:
        content_type = "image/jpeg"
    
    # Try GCS first
    GCS_BUCKET = os.getenv("VERIFICATION_DOCS_BUCKET", "hybrid-messenger-verification-docs")
    gcs_error = None
    try:
        from google.cloud import storage as gcs_storage
        print(f"   ✅ GCS library loaded, bucket={GCS_BUCKET}")
        client = gcs_storage.Client()
        bucket = client.bucket(GCS_BUCKET)
        blob = bucket.blob(gcs_path)
        
        exists = blob.exists()
        print(f"   📍 blob.exists() = {exists}")
        
        if exists:
            content = blob.download_as_bytes()
            print(f"   ✅ Downloaded {len(content)} bytes")
            return Response(
                content=content,
                media_type=content_type,
                headers={"Cache-Control": "private, no-store"}
            )
        else:
            gcs_error = f"Blob not found in GCS: {GCS_BUCKET}/{gcs_path}"
            print(f"   ❌ {gcs_error}")
    except ImportError:
        gcs_error = "google-cloud-storage not installed"
        print(f"   ❌ {gcs_error}")
    except Exception as e:
        gcs_error = f"GCS error: {type(e).__name__}: {e}"
        print(f"   ❌ {gcs_error}")
    
    # Fallback: local filesystem
    file_path = Path("uploads/verification_docs") / user_id / filename
    print(f"   🔍 Local fallback: {file_path} (exists={file_path.exists()})")
    if file_path.exists() and file_path.is_file():
        return FileResponse(
            path=str(file_path),
            media_type=content_type,
            headers={"Cache-Control": "private, no-store"}
        )
    
    detail = f"Document not found: {gcs_path}"
    if gcs_error:
        detail += f" | {gcs_error}"
    print(f"   ❌ FINAL: {detail}")
    raise HTTPException(status_code=404, detail=detail)


@router.get("/verification/debug/{request_id}")
def debug_verification_request(
    request_id: str,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Debug endpoint: show raw stored URLs for a verification request."""
    from models import VerificationRequest
    req = db.query(VerificationRequest).filter(
        VerificationRequest.id == request_id
    ).first()
    if not req:
        raise HTTPException(status_code=404, detail="Request not found")
    
    # 🔴 ROUND 70 — KYC URL columns may carry either legacy plaintext
    # or new Fernet-wrapped bytes; decrypt-or-passthrough handles both.
    from encryption import decrypt_text as _dec
    def _kyc(val):
        if not val:
            return None
        try:
            return _dec(val)
        except Exception:
            return val  # legacy plaintext

    return {
        "id": req.id,
        "user_id": req.user_id,
        "doc_type": req.doc_type,
        "raw_doc_front_url": _kyc(req.doc_front_url),
        "raw_doc_back_url": _kyc(req.doc_back_url),
        "raw_selfie_url": _kyc(req.selfie_url),
        "status": req.status,
    }


@router.get("/verification/{request_id}")
def get_verification_detail(
    request_id: str,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Get full details of a verification request (admin only)."""
    from models import VerificationRequest, User
    from encryption import decrypt_text
    import json as json_mod
    
    req = db.query(VerificationRequest).filter(
        VerificationRequest.id == request_id
    ).first()
    
    if not req:
        raise HTTPException(status_code=404, detail="Request not found")
    
    user = db.query(User).filter(User.id == req.user_id).first()
    
    def to_admin_url(stored_url):
        """Convert stored URL (gcs:// or local path) to admin-accessible URL."""
        if not stored_url:
            return None
        
        # Debug: log what we're converting
        print(f"🔍 [Verification] Converting URL: {stored_url}")
        
        if stored_url.startswith("gcs://"):
            # Extract user_id/filename from gcs://bucket/user_id/filename
            parts = stored_url.split("/", 3)  # ['gcs:', '', 'bucket', 'user_id/filename']
            if len(parts) >= 4:
                result = f"/api/admin/verification/doc/{parts[3]}"
                print(f"   → GCS URL: {result}")
                return result
        
        if stored_url.startswith("http://") or stored_url.startswith("https://"):
            # Full URL — extract the path portion after /uploads/ or /verification_docs/
            for marker in ["/verification_docs/", "/uploads/verification_docs/"]:
                idx = stored_url.find(marker)
                if idx >= 0:
                    path_after = stored_url[idx + len(marker):]
                    result = f"/api/admin/verification/doc/{path_after}"
                    print(f"   → Full URL: {result}")
                    return result
            # Fallback: return as-is (might be a direct link)
            print(f"   → Direct URL (no conversion)")
            return stored_url
        
        # Legacy local path: verification_docs/user_id/filename
        clean = stored_url.replace("verification_docs/", "").lstrip("/")
        result = f"/api/admin/verification/doc/{clean}"
        print(f"   → Local path: {result}")
        return result
    
    # 🔴 ROUND 70 — KYC URL columns may be Fernet-wrapped now.
    # Try decrypt; fall through to plaintext for legacy rows. Country
    # may also be wrapped on round-70+ rows.
    def _try_dec(val):
        if not val:
            return None
        try:
            return decrypt_text(val)
        except Exception:
            return val

    return {
        "id": req.id,
        "user_id": req.user_id,
        "username": user.username if user else "deleted_user",
        "avatar": user.avatar_path if user else None,
        "status": req.status,
        "legal_first_name": decrypt_text(req.legal_first_name),
        "legal_last_name": decrypt_text(req.legal_last_name),
        "country": (_try_dec(req.country) or "—"),
        "category": req.category or "—",
        "doc_type": req.doc_type or "Not specified",
        "doc_front_url": to_admin_url(_try_dec(req.doc_front_url)),
        "doc_back_url": to_admin_url(_try_dec(req.doc_back_url)),
        "selfie_url": to_admin_url(_try_dec(req.selfie_url)),
        "links": json_mod.loads(req.links_json) if req.links_json else [],
        "submitted_at": req.submitted_at.isoformat() if req.submitted_at else None,
        "reviewed_at": req.reviewed_at.isoformat() if req.reviewed_at else None,
        "decision_reason": req.decision_reason,
        "notes_internal": req.notes_internal,
    }


from pydantic import BaseModel as PydanticBaseModel

class AdminVerificationAction(PydanticBaseModel):
    reason: str = ""
    notes: str = ""
    badge_type: str = "identity"  # identity, business, creator


@router.post("/verification/{request_id}/approve")
async def approve_verification(
    request_id: str,
    action: AdminVerificationAction,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Approve a verification request — sets is_verified=True on User."""
    from models import VerificationRequest, User, Notification
    from datetime import datetime
    import uuid as uuid_mod
    
    req = db.query(VerificationRequest).filter(
        VerificationRequest.id == request_id,
        VerificationRequest.status.in_(["pending", "needs_more_info"])
    ).first()
    
    if not req:
        raise HTTPException(status_code=404, detail="No pending request found")
    
    now = datetime.utcnow()
    
    # Update request
    req.status = "verified"
    req.reviewed_at = now
    req.decision_reason = action.reason or "Your identity has been verified."
    req.notes_internal = action.notes
    
    # Update user
    user = db.query(User).filter(User.id == req.user_id).first()
    if user:
        user.is_verified = True
        user.verified_at = now
        user.verification_badge_type = action.badge_type
        
        # Create notification
        notif = Notification(
            id=str(uuid_mod.uuid4()),
            user_id=user.id,
            type="verification_approved",
            data="{}",
            is_read=False
        )
        db.add(notif)
        
        # Send push notification
        if user.push_token and getattr(user, 'push_platform', None) == "ios":
            try:
                from services.apns_service import get_apns_service
                apns = get_apns_service()
                await apns.send_push(
                    device_token=user.push_token,
                    title="Verification Approved ✓",
                    body="Congratulations! Your identity has been verified. You now have a verified badge.",
                    data={"type": "verification_status", "status": "verified"}
                )
            except Exception as e:
                print(f"⚠️ Push notification failed: {e}")
    
    db.commit()
    
    print(f"✅ Verification APPROVED for user {req.user_id}")
    return {"status": "approved", "request_id": request_id}


@router.post("/verification/{request_id}/reject")
async def reject_verification(
    request_id: str,
    action: AdminVerificationAction,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Reject a verification request."""
    from models import VerificationRequest, User, Notification
    from datetime import datetime
    import uuid as uuid_mod
    
    req = db.query(VerificationRequest).filter(
        VerificationRequest.id == request_id,
        VerificationRequest.status.in_(["pending", "needs_more_info"])
    ).first()
    
    if not req:
        raise HTTPException(status_code=404, detail="No pending request found")
    
    now = datetime.utcnow()
    
    req.status = "rejected"
    req.reviewed_at = now
    req.decision_reason = action.reason or "Your verification request was not approved."
    req.notes_internal = action.notes
    
    # Create notification
    notif = Notification(
        id=str(uuid_mod.uuid4()),
        user_id=req.user_id,
        type="verification_rejected",
        data="{}",
        is_read=False
    )
    db.add(notif)
    
    # Send push
    try:
        user = db.query(User).filter(User.id == req.user_id).first()
        if user and user.push_token and getattr(user, 'push_platform', None) == "ios":
            from services.apns_service import get_apns_service
            apns = get_apns_service()
            await apns.send_push(
                device_token=user.push_token,
                title="Verification Update",
                body="Your verification request needs attention. Tap to learn more.",
                data={"type": "verification_status", "status": "rejected"}
            )
    except Exception as e:
        print(f"⚠️ Push notification failed: {e}")
    
    db.commit()
    
    print(f"❌ Verification REJECTED for user {req.user_id}: {action.reason}")
    return {"status": "rejected", "request_id": request_id}


@router.post("/verification/{request_id}/need-more-info")
def request_more_info(
    request_id: str,
    action: AdminVerificationAction,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Request additional documents/info from the user."""
    from models import VerificationRequest, Notification
    from datetime import datetime
    import uuid as uuid_mod
    
    req = db.query(VerificationRequest).filter(
        VerificationRequest.id == request_id,
        VerificationRequest.status == "pending"
    ).first()
    
    if not req:
        raise HTTPException(status_code=404, detail="No pending request found")
    
    now = datetime.utcnow()
    
    req.status = "needs_more_info"
    req.reviewed_at = now
    req.decision_reason = action.reason or "Additional information is required."
    req.notes_internal = action.notes
    
    # Create notification
    notif = Notification(
        id=str(uuid_mod.uuid4()),
        user_id=req.user_id,
        type="verification_more_info",
        data="{}",
        is_read=False
    )
    db.add(notif)
    
    db.commit()
    
    print(f"ℹ️ More info requested for verification {req.user_id}: {action.reason}")
    return {"status": "needs_more_info", "request_id": request_id}


# ==================== REPORT MANAGEMENT ====================

@router.get("/reports")
def list_reports(
    status_filter: str = None,
    limit: int = 50,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """List reports (admin-secret only)."""
    from models import Report, User
    
    query = db.query(Report).order_by(Report.created_at.desc())
    if status_filter:
        query = query.filter(Report.status == status_filter)
    
    reports = query.limit(limit).all()
    
    items = []
    for r in reports:
        reporter = db.query(User).filter(User.id == r.reporter_id).first()
        reported = db.query(User).filter(User.id == r.reported_user_id).first() if r.reported_user_id else None
        items.append({
            "id": r.id,
            "status": r.status,
            "target_type": r.target_type,
            "target_id": r.target_id,
            "reason": r.reason,
            "note": r.note,
            "reporter": reporter.username if reporter else "unknown",
            "reported_user": reported.username if reported else None,
            "decision": r.decision,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        })
    
    return {"total": len(items), "items": items}


@router.post("/reports/{report_id}/dismiss")
def dismiss_report(
    report_id: str,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Dismiss a report (admin-secret only)."""
    from models import Report
    
    report = db.query(Report).filter(Report.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    
    report.status = "dismissed"
    report.decision = "none"
    report.decision_reason = "Dismissed by admin"
    db.commit()
    
    print(f"🗑️ Report {report_id} dismissed")
    return {"status": "dismissed", "report_id": report_id}


@router.post("/reports/dismiss-all")
def dismiss_all_reports(
    status_filter: str = "open",
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Dismiss all reports with a given status (admin-secret only)."""
    from models import Report
    from datetime import datetime
    
    reports = db.query(Report).filter(Report.status == status_filter).all()
    count = len(reports)
    
    for r in reports:
        r.status = "dismissed"
        r.decision = "none"
        r.decision_reason = "Bulk dismissed by admin"
        r.decided_at = datetime.utcnow()
    
    db.commit()
    
    print(f"🗑️ Bulk dismissed {count} reports with status={status_filter}")
    return {"status": "success", "dismissed_count": count}


# ==================== POST MANAGEMENT ====================

@router.get("/posts")
def admin_list_posts(
    limit: int = 50,
    offset: int = 0,
    author: str = None,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """List posts for admin review (admin-secret only)."""
    from models import Post, User
    from encryption import decrypt_text
    
    query = db.query(Post).order_by(Post.timestamp.desc())
    if author:
        # Filter by author username (partial match)
        user = db.query(User).filter(User.username.ilike(f"%{author}%")).first()
        if user:
            query = query.filter(Post.author_id == user.id)
        else:
            return {"total": 0, "items": []}
    
    total = query.count()
    posts = query.offset(offset).limit(limit).all()
    
    items = []
    author_cache = {}
    for p in posts:
        if p.author_id not in author_cache:
            u = db.query(User).filter(User.id == p.author_id).first()
            author_cache[p.author_id] = u
        author_user = author_cache[p.author_id]
        
        items.append({
            "id": p.id,
            "author_id": p.author_id,
            "author_username": author_user.username if author_user else "deleted",
            "content": decrypt_text(p.content)[:200] if p.content else "",
            "post_type": p.post_type or "text",
            "visibility": p.visibility or "public",
            "is_hidden": p.is_hidden or False,
            "view_count": p.view_count or 0,
            "timestamp": p.timestamp.isoformat() if p.timestamp else None,
        })
    
    return {"total": total, "items": items}


@router.delete("/posts/{post_id}")
def admin_delete_post(
    post_id: str,
    _: bool = Depends(verify_admin_secret)
):
    """
    Hard-delete a post and all related records (admin-secret only).
    Uses raw connection (not ORM session) for reliable cascade with savepoints.
    """
    from sqlalchemy import text
    from database import engine
    
    # Get a raw DBAPI connection — bypasses SQLAlchemy's state tracking
    # which blocks operations after an error (even with SAVEPOINTs)
    raw_conn = engine.raw_connection()
    try:
        cursor = raw_conn.cursor()
        
        # Check post exists
        cursor.execute("SELECT id, author_id FROM posts WHERE id = %s", (post_id,))
        post_row = cursor.fetchone()
        if not post_row:
            raise HTTPException(status_code=404, detail="Post not found")
        
        author_id = post_row[1]
        
        # Cascade tables to clean (order matters for FK constraints)
        cascade_queries = [
            ("comment_votes", "DELETE FROM comment_votes WHERE comment_id IN (SELECT id FROM comments WHERE post_id = %s)"),
            ("comments", "DELETE FROM comments WHERE post_id = %s"),
            ("post_likes", "DELETE FROM post_likes WHERE post_id = %s"),
            ("reposts", "DELETE FROM reposts WHERE original_post_id = %s"),
            ("post_views", "DELETE FROM post_views WHERE post_id = %s"),
            ("post_media", "DELETE FROM post_media WHERE post_id = %s"),
            ("content_consumption", "DELETE FROM content_consumption WHERE content_id = %s"),
            ("seen_posts", "DELETE FROM seen_posts WHERE post_id = %s"),
            ("mentions", "DELETE FROM mentions WHERE post_id = %s"),
            ("user_events", "DELETE FROM user_events WHERE post_id = %s"),
            ("mesh_view_receipts", "DELETE FROM mesh_view_receipts WHERE post_id = %s"),
            ("hidden_content", "DELETE FROM hidden_content WHERE object_type = 'post' AND object_id = %s"),
            ("reports", "DELETE FROM reports WHERE target_type = 'post' AND target_id = %s"),
            ("moderation_actions", "DELETE FROM moderation_actions WHERE target_type = 'post' AND target_id = %s"),
        ]
        
        warnings = []
        for i, (label, sql) in enumerate(cascade_queries):
            sp = f"cascade_{i}"
            try:
                cursor.execute(f"SAVEPOINT {sp}")
                cursor.execute(sql, (post_id,))
                cursor.execute(f"RELEASE SAVEPOINT {sp}")
            except Exception as e:
                warnings.append(f"{label}: {str(e)[:80]}")
                cursor.execute(f"ROLLBACK TO SAVEPOINT {sp}")
        
        # Delete the post itself
        cursor.execute("DELETE FROM posts WHERE id = %s", (post_id,))
        raw_conn.commit()
        cursor.close()
        
        print(f"🗑️ [Admin] Post {post_id} hard-deleted (author: {author_id})")
        if warnings:
            print(f"⚠️ [Admin] Cascade warnings: {warnings}")
        
        return {"status": "deleted", "post_id": post_id, "warnings": warnings or None}
        
    except HTTPException:
        raw_conn.rollback()
        raise
    except Exception as e:
        raw_conn.rollback()
        raise HTTPException(status_code=500, detail=f"Delete failed: {str(e)}")
    finally:
        raw_conn.close()


# ==================== PUSH NOTIFICATION DEBUG ====================

@router.get("/push-debug")
async def admin_push_debug(
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """
    Debug push notification pipeline: check APNs config, key file, and list users with tokens.
    Uses raw SQL to avoid ORM crashes if columns are missing.
    """
    from services.apns_service import get_apns_service
    from sqlalchemy import text
    
    apns = get_apns_service()
    
    # Check if push_token column exists
    col_check = db.execute(text("""
        SELECT column_name FROM information_schema.columns 
        WHERE table_name = 'users' AND column_name = 'push_token'
    """)).fetchone()
    
    push_token_col_exists = col_check is not None
    
    user_list = []
    if push_token_col_exists:
        try:
            rows = db.execute(text("""
                SELECT id, username, push_token, push_platform 
                FROM users WHERE push_token IS NOT NULL LIMIT 10
            """)).fetchall()
            for row in rows:
                user_list.append({
                    "id": str(row[0])[:8] + "...",
                    "username": row[1],
                    "push_platform": row[3],
                    "push_token_prefix": row[2][:16] + "..." if row[2] else None,
                })
        except Exception as e:
            user_list = [{"error": str(e)}]
    
    result = {
        "apns": {
            "configured": apns.is_configured,
            "bundle_id": apns.bundle_id,
            "use_sandbox": apns.use_sandbox,
            "key_id": apns.key_id,
            "team_id": apns.team_id,
            "key_loaded": apns._private_key is not None,
            "key_path": apns.key_path,
            "key_file_exists": os.path.exists(apns.key_path) if apns.key_path else False,
        },
        "database": {
            "push_token_column_exists": push_token_col_exists,
        },
        "users_with_tokens": user_list,
        "total_users_with_tokens": len(user_list),
    }
    
    return result


@router.post("/push-test/{username}")
async def admin_push_test(
    username: str,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Send a test push notification to a specific user. Protected by admin secret."""
    from services.apns_service import get_apns_service
    from sqlalchemy import text
    import time
    
    # Get user via raw SQL (safe if ORM columns are mismatched)
    row = db.execute(text(
        "SELECT id, username, push_token, push_platform FROM users WHERE username = :u"
    ), {"u": username}).fetchone()
    
    if not row:
        raise HTTPException(status_code=404, detail=f"User '{username}' not found")
    
    user_id, uname, token, platform = row[0], row[1], row[2], row[3]
    
    if not token:
        return {"error": f"User '{username}' has no push_token stored"}
    
    apns = get_apns_service()
    if not apns.is_configured:
        return {"error": "APNs not configured", "key_loaded": apns._private_key is not None}
    
    diagnostics = {
        "username": username,
        "token_prefix": token[:16] + "...",
        "platform": platform,
        "bundle_id": apns.bundle_id,
        "sandbox": apns.use_sandbox,
    }
    
    # Test 1: Check if we can reach api.push.apple.com
    t0 = time.time()
    try:
        import socket
        host = "api.push.apple.com" if not apns.use_sandbox else "api.sandbox.push.apple.com"
        sock = socket.create_connection((host, 443), timeout=5)
        sock.close()
        dns_time = time.time() - t0
        diagnostics["connectivity"] = f"OK — TCP connect in {dns_time:.2f}s"
    except Exception as e:
        diagnostics["connectivity"] = f"FAILED — {e}"
        return diagnostics
    
    # Test 2: Try to send push
    t1 = time.time()
    try:
        success = await apns.send_push(
            device_token=token,
            title="🧪 Push Test",
            body="If you see this, push notifications work!",
            data={"type": "push_test"},
        )
        push_time = time.time() - t1
        diagnostics["push_sent"] = success
        diagnostics["push_time"] = f"{push_time:.2f}s"
        diagnostics["status"] = "SUCCESS" if success else "FAILED (check server logs)"
    except Exception as e:
        push_time = time.time() - t1
        diagnostics["push_sent"] = False
        diagnostics["push_error"] = str(e)
        diagnostics["push_time"] = f"{push_time:.2f}s"
    
    return diagnostics


@router.get("/apns-connectivity")
async def admin_apns_connectivity(
    _: bool = Depends(verify_admin_secret)
):
    """Test basic connectivity to APNs servers."""
    import socket
    import ssl
    import time
    
    results = {}
    
    for host in ["api.push.apple.com", "api.sandbox.push.apple.com"]:
        t0 = time.time()
        try:
            # Test TCP connection
            sock = socket.create_connection((host, 443), timeout=5)
            tcp_time = time.time() - t0
            
            # Test TLS handshake
            t1 = time.time()
            ctx = ssl.create_default_context()
            ssock = ctx.wrap_socket(sock, server_hostname=host)
            tls_time = time.time() - t1
            
            # Check ALPN (HTTP/2 support)
            alpn = ssock.selected_alpn_protocol()
            
            ssock.close()
            
            results[host] = {
                "status": "OK",
                "tcp_connect": f"{tcp_time:.3f}s",
                "tls_handshake": f"{tls_time:.3f}s",
                "alpn_protocol": alpn,
                "http2_supported": alpn == "h2",
            }
        except Exception as e:
            elapsed = time.time() - t0
            results[host] = {
                "status": f"FAILED: {e}",
                "elapsed": f"{elapsed:.3f}s",
            }
    
    # Also check curl HTTP/2 support
    try:
        import subprocess
        curl_version = subprocess.run(
            ['curl', '--version'], capture_output=True, text=True, timeout=5
        )
        curl_info = curl_version.stdout.split('\n')[0] if curl_version.stdout else "unknown"
        has_http2 = 'nghttp2' in curl_version.stdout or 'HTTP2' in curl_version.stdout
        results["curl"] = {
            "version": curl_info,
            "http2_support": has_http2,
        }
    except Exception as e:
        results["curl"] = {"error": str(e)}
    
    return results


# ==================== BROADCAST NOTIFICATION ====================


class BroadcastRequest(PydanticBaseModel):
    """Payload for /broadcast-notification. Both languages are sent
    in one push (concatenated with a separator) so a Persian user
    and an English user each recognise their half. Title is short
    enough to fit a lock-screen line on either locale."""
    title_en: str = "Security Update — please update RAVEN"
    title_fa: str = "به‌روزرسانی امنیتی — لطفاً RAVEN را به‌روز کنید"
    body_en: str = (
        "We've shipped important security fixes. Open the App Store "
        "and update RAVEN to the latest version."
    )
    body_fa: str = (
        "اصلاحات امنیتی مهم منتشر شده است. لطفاً RAVEN را از اپ استور "
        "به آخرین نسخه به‌روزرسانی کنید."
    )
    dry_run: bool = True   # default safe: count recipients, don't actually send
    max_recipients: int = 100_000


@router.post("/broadcast-notification")
async def broadcast_notification(
    req: BroadcastRequest,
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret),
):
    """One-shot fan-out of a security-update notification to every
    user with a push token.

    Channels:
      • In-app `Notification` row (always created)
      • APNs push (only when `dry_run=False` AND `push_token` set)

    Safety:
      • Default `dry_run=True` returns counts only — actually sending
        requires an explicit `{ "dry_run": false }` in the body.
      • Caps at `max_recipients` so an accidental call can't fan out
        infinitely.
      • Skips banned / restricted users.
      • De-duplicates per `push_token` (a stale token recycled across
        accounts only pushes once).
      • Caller can pre-translate title/body per language; we pick the
        right one per user by `User.language` if present, else fall
        back to English.
    """
    from models import User as _User, Notification as _Notif
    from services.apns_service import get_apns_service, APNsService
    import json as _json
    import uuid as _uuid
    from datetime import datetime as _dt

    # Recipients: any user with a push token who isn't banned/restricted.
    candidates_q = db.query(_User).filter(
        _User.push_token.isnot(None),
        _User.push_token != "",
        (_User.is_banned == False) | (_User.is_banned.is_(None)),
        (_User.is_restricted == False) | (_User.is_restricted.is_(None)),
    )
    total_eligible = candidates_q.count()
    candidates = candidates_q.limit(req.max_recipients).all()

    if req.dry_run:
        # Preview only — no notifications, no pushes.
        platforms: dict = {}
        for u in candidates:
            p = (u.push_platform or "unknown").lower()
            platforms[p] = platforms.get(p, 0) + 1
        return {
            "dry_run": True,
            "eligible_total": total_eligible,
            "would_notify": len(candidates),
            "by_platform": platforms,
            "title_en": req.title_en,
            "title_fa": req.title_fa,
            "body_en": req.body_en[:120],
            "body_fa": req.body_fa[:120],
            "hint": "POST again with {\"dry_run\": false} to actually send.",
        }

    # Real broadcast. We send synchronously per-batch but the apns
    # client uses HTTP/2 multiplexing — throughput is plenty for tens
    # of thousands of recipients in a single request.
    apns = get_apns_service()
    sent_push = 0
    sent_notif = 0
    skipped_pref = 0
    failed_push = 0
    seen_tokens: set[str] = set()

    for u in candidates:
        # Pick the right language for each recipient based on the
        # user's `language` column. Fallback to English when unset.
        lang = (getattr(u, "language", None) or "").lower()
        title = req.title_fa if lang.startswith("fa") else req.title_en
        body = req.body_fa if lang.startswith("fa") else req.body_en

        # 1) In-app notification row
        try:
            notif = _Notif(
                id=str(_uuid.uuid4()),
                user_id=u.id,
                type="security_update",
                data=_json.dumps({
                    "event": "security_update",
                    "title": title,
                    "body": body,
                    "min_app_version": "latest",
                }),
                is_read=False,
                timestamp=_dt.utcnow(),
            )
            db.add(notif)
            sent_notif += 1
        except Exception as e:
            logging.warning(f"in-app notif failed for {u.id}: {e}")

        # 2) APNs push (only iOS for now)
        if (u.push_platform or "").lower() != "ios":
            continue
        token = u.push_token or ""
        if not token or token in seen_tokens:
            continue
        seen_tokens.add(token)

        # Respect each user's push preferences. The "system" channel
        # is treated as always-allowed for security messages, since
        # forcing a quiet hour to swallow a security update is worse
        # than a single mistimed buzz.
        prefs = APNsService.should_send_push(u, "system")
        if not prefs.get("allowed", True):
            skipped_pref += 1
            continue

        try:
            ok = await apns.send_push(
                device_token=token,
                title=title,
                body=body,
                data={
                    "type": "security_update",
                    "url": "https://apps.apple.com/app/raven-messenger/id6739196697",
                },
            )
            if ok:
                sent_push += 1
            else:
                failed_push += 1
        except Exception as e:
            failed_push += 1
            logging.warning(f"apns push failed for {u.id}: {e}")

    try:
        db.commit()
    except Exception as e:
        db.rollback()
        logging.error(f"broadcast commit failed: {e}")

    print(f"📢 [Broadcast] notif={sent_notif} push={sent_push} "
          f"skip-pref={skipped_pref} fail={failed_push} "
          f"of total_eligible={total_eligible}")

    return {
        "dry_run": False,
        "eligible_total": total_eligible,
        "in_app_notifications_created": sent_notif,
        "push_notifications_sent": sent_push,
        "push_skipped_by_preference": skipped_pref,
        "push_failed": failed_push,
    }


# ==================== APPLE REVIEWER ACCOUNT SETUP ====================

@router.post("/setup-reviewers")
def setup_reviewer_accounts(
    db: Session = Depends(get_db),
    _: bool = Depends(verify_admin_secret)
):
    """Create or fix Apple reviewer demo accounts.
    
    Handles all cases:
    - Creates accounts if they don't exist
    - Fixes username/password if email already registered with different username
    - Makes reviewer accounts friends with each other
    """
    from sqlalchemy import text
    from auth import hash_password
    from encryption import encrypt_text
    import hashlib
    import uuid

    # 🔴 hacker-audit 2026-05-20 — no hardcoded credentials in source.
    # PREVIOUSLY both reviewer accounts shipped the literal password
    # "REDACTED-ROTATE-ME" right here in the repo (and echoed it in
    # the response) — anyone with read access to the source or git
    # history could log into the production reviewer accounts.
    # NOW: take the password from REVIEWER_PASSWORD; if it is unset,
    # mint a strong random one. Either way it is returned ONCE in
    # this admin-only response so the operator can hand it to review.
    reviewer_password = os.getenv("REVIEWER_PASSWORD") or _secrets_mod.token_urlsafe(18)

    reviewer_accounts = [
        {
            "username": "reviewer1",
            "password": reviewer_password,
            "first_name": "Apple",
            "last_name": "Reviewer",
            "email": "apple-reviewer-1@raven-messenger.com",
        },
        {
            "username": "reviewer2",
            "password": reviewer_password,
            "first_name": "App",
            "last_name": "Reviewer",
            "email": "apple-reviewer-2@raven-messenger.com",
        },
    ]

    results = []
    reviewer_ids = []

    for acct in reviewer_accounts:
        hashed_pw = hash_password(acct["password"])
        email_hash = hashlib.sha256(acct["email"].lower().encode()).hexdigest()

        # 1. Check if username already exists
        row = db.execute(
            text("SELECT id FROM users WHERE username = :u"),
            {"u": acct["username"]}
        ).fetchone()

        if row:
            # Username exists — just update password + ensure email_verified
            uid = row[0]
            db.execute(text(
                "UPDATE users SET password_hash = :pw, email_verified = TRUE WHERE id = :id"
            ), {"pw": hashed_pw, "id": uid})
            reviewer_ids.append(uid)
            results.append({"username": acct["username"], "action": "password_updated", "id": uid})
            continue

        # 2. Check if email_hash already exists (registered with different username)
        row = db.execute(
            text("SELECT id, username FROM users WHERE email_hash = :eh"),
            {"eh": email_hash}
        ).fetchone()

        if row:
            uid = row[0]
            old_username = row[1]
            # Update username, password, and email_verified
            db.execute(text(
                "UPDATE users SET username = :u, password_hash = :pw, email_verified = TRUE WHERE id = :id"
            ), {"u": acct["username"], "pw": hashed_pw, "id": uid})
            reviewer_ids.append(uid)
            results.append({
                "username": acct["username"],
                "action": f"fixed (was '{old_username}')",
                "id": uid
            })
            continue

        # 3. Create new account
        uid = str(uuid.uuid4())
        db.execute(text("""
            INSERT INTO users
                (id, username, password_hash, first_name, last_name,
                 birth_year, email, email_hash, email_verified, created_at)
            VALUES
                (:id, :username, :pw, :fn, :ln,
                 2000, :email, :eh, TRUE, NOW())
        """), {
            "id": uid,
            "username": acct["username"],
            "pw": hashed_pw,
            "fn": encrypt_text(acct["first_name"]),
            "ln": encrypt_text(acct["last_name"]),
            "email": encrypt_text(acct["email"]),
            "eh": email_hash,
        })
        reviewer_ids.append(uid)
        results.append({"username": acct["username"], "action": "created", "id": uid})

    db.commit()

    # Make reviewer accounts friends with each other
    friendship_status = "skipped"
    if len(reviewer_ids) == 2:
        for a, b in [(reviewer_ids[0], reviewer_ids[1]), (reviewer_ids[1], reviewer_ids[0])]:
            existing = db.execute(
                text("SELECT 1 FROM friendships WHERE user_id = :a AND friend_id = :b"),
                {"a": a, "b": b}
            ).fetchone()
            if not existing:
                db.execute(text("""
                    INSERT INTO friendships (id, user_id, friend_id, created_at)
                    VALUES (:id, :uid, :fid, NOW())
                """), {"id": str(uuid.uuid4()), "uid": a, "fid": b})
                friendship_status = "created"
        db.commit()

    return {
        "status": "success",
        "accounts": results,
        "friendship": friendship_status,
        "login_instructions": {
            "account_1": {"username": "reviewer1", "password": reviewer_password},
            "account_2": {"username": "reviewer2", "password": reviewer_password},
        }
    }

