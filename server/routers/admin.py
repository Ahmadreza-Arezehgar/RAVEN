"""
Admin endpoints for database management.
DANGER: These endpoints can destroy all data!
"""
from fastapi import APIRouter, Depends, HTTPException, Header
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session
from database import get_db
import os

router = APIRouter(prefix="/api/admin", tags=["admin"])

# Secret key for admin operations - set via environment variable
ADMIN_SECRET = os.getenv("ADMIN_SECRET", "RAVEN_ADMIN_2026")


def verify_admin_secret(x_admin_secret: str = Header(...)):
    """Verify the admin secret header."""
    if x_admin_secret != ADMIN_SECRET:
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
    for req in requests:
        user = db.query(User).filter(User.id == req.user_id).first()
        items.append({
            "id": req.id,
            "user_id": req.user_id,
            "username": user.username if user else "unknown",
            "avatar": user.avatar_path if user else None,
            "status": req.status,
            "category": req.category,
            "country": req.country,
            "doc_type": req.doc_type,
            "legal_name": f"{decrypt_text(req.legal_first_name)} {decrypt_text(req.legal_last_name)}",
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
    """
    from pathlib import Path
    import mimetypes
    from fastapi.responses import Response
    
    # Sanitize path components to prevent directory traversal
    if '..' in user_id or '/' in user_id or '..' in filename or '/' in filename:
        raise HTTPException(status_code=400, detail="Invalid path")
    
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
    
    return {
        "id": req.id,
        "user_id": req.user_id,
        "doc_type": req.doc_type,
        "raw_doc_front_url": req.doc_front_url,
        "raw_doc_back_url": req.doc_back_url,
        "raw_selfie_url": req.selfie_url,
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
    
    return {
        "id": req.id,
        "user_id": req.user_id,
        "username": user.username if user else "deleted_user",
        "avatar": user.avatar_path if user else None,
        "status": req.status,
        "legal_first_name": decrypt_text(req.legal_first_name),
        "legal_last_name": decrypt_text(req.legal_last_name),
        "country": req.country or "—",
        "category": req.category or "—",
        "doc_type": req.doc_type or "Not specified",
        "doc_front_url": to_admin_url(req.doc_front_url),
        "doc_back_url": to_admin_url(req.doc_back_url),
        "selfie_url": to_admin_url(req.selfie_url),
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

    reviewer_accounts = [
        {
            "username": "reviewer1",
            "password": "REDACTED-ROTATE-ME",
            "first_name": "Apple",
            "last_name": "Reviewer",
            "email": "apple-reviewer-1@raven-messenger.com",
        },
        {
            "username": "reviewer2",
            "password": "REDACTED-ROTATE-ME",
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
            "account_1": {"username": "reviewer1", "password": "REDACTED-ROTATE-ME"},
            "account_2": {"username": "reviewer2", "password": "REDACTED-ROTATE-ME"},
        }
    }

