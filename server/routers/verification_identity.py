"""
Identity Verification Router - User-facing endpoints for verification requests.

Endpoints:
- POST /api/verification/request    - Submit a new verification request
- GET  /api/verification/status     - Get current verification status
- POST /api/verification/cancel     - Cancel a pending request
- POST /api/verification/upload-doc - Upload identity document (restricted)
"""
from fastapi import APIRouter, Depends, HTTPException, status, File, UploadFile, Request
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime, timedelta
import uuid
import hashlib
import json
import os
from pathlib import Path

from database import get_db
from models import User, VerificationRequest, Notification
from routers.users import get_current_user
from encryption import encrypt_text, decrypt_text

router = APIRouter(prefix="/api/verification", tags=["verification"])

# Secure upload directory for identity documents (NOT publicly served)
VERIFICATION_DOCS_DIR = Path("uploads/verification_docs")
VERIFICATION_DOCS_DIR.mkdir(parents=True, exist_ok=True)

# Configuration
REAPPLY_COOLDOWN_DAYS = 30
MAX_DOC_SIZE = 10 * 1024 * 1024  # 10MB per document
ALLOWED_DOC_EXTENSIONS = {".jpg", ".jpeg", ".png", ".pdf"}


# ==================== Request/Response Models ====================

class VerificationSubmitRequest(BaseModel):
    legal_first_name: str
    legal_last_name: str
    country: str
    category: str = "person"  # person, brand, org
    doc_type: str  # passport, national_id, drivers_license
    doc_front_url: Optional[str] = None
    doc_back_url: Optional[str] = None
    selfie_url: Optional[str] = None
    links: Optional[List[dict]] = None  # [{type: "website", url: "..."}, ...]

class VerificationStatusResponse(BaseModel):
    status: str
    submitted_at: Optional[str] = None
    reviewed_at: Optional[str] = None
    reason: Optional[str] = None
    category: Optional[str] = None
    badge_type: Optional[str] = None
    can_reapply: bool = False
    reapply_after: Optional[str] = None


# ==================== Endpoints ====================

@router.post("/request", status_code=201)
async def submit_verification_request(
    req: VerificationSubmitRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Submit a new identity verification request.
    
    - Only 1 pending request allowed per user (409 if exists)
    - After rejection, must wait REAPPLY_COOLDOWN_DAYS before reapplying
    - Validates required fields
    """
    # Check for existing pending request
    existing = db.query(VerificationRequest).filter(
        VerificationRequest.user_id == current_user.id,
        VerificationRequest.status.in_(["pending", "needs_more_info"])
    ).first()
    
    if existing:
        raise HTTPException(
            status_code=409,
            detail="You already have a pending verification request."
        )
    
    # Check reapply cooldown after rejection
    last_rejected = db.query(VerificationRequest).filter(
        VerificationRequest.user_id == current_user.id,
        VerificationRequest.status == "rejected"
    ).order_by(VerificationRequest.reviewed_at.desc()).first()
    
    if last_rejected and last_rejected.reviewed_at:
        cooldown_end = last_rejected.reviewed_at + timedelta(days=REAPPLY_COOLDOWN_DAYS)
        if datetime.utcnow() < cooldown_end:
            raise HTTPException(
                status_code=429,
                detail=f"You can reapply after {cooldown_end.strftime('%Y-%m-%d')}."
            )
    
    # Validate required fields
    if not req.legal_first_name.strip() or not req.legal_last_name.strip():
        raise HTTPException(status_code=400, detail="Legal name is required.")
    if req.category not in ("person", "brand", "org"):
        raise HTTPException(status_code=400, detail="Category must be person, brand, or org.")
    if req.doc_type not in ("passport", "national_id", "drivers_license"):
        raise HTTPException(status_code=400, detail="Invalid document type.")

    # 🔴 hacker-audit 2026-05-19: the three URL fields are client-
    # supplied strings, but the only legitimate values are either:
    #   (a) a GCS pointer from /upload-doc, shape "gcs://<bucket>/<uid>/<file>"
    #   (b) a local-fallback path, shape "verification_docs/<uid>/<file>"
    # …and BOTH must be scoped to the calling user's own user-id
    # subdirectory. Without this gate, an attacker could:
    #   - point doc_front_url at *another user's* doc and ride the
    #     admin review on someone else's KYC photos.
    #   - inject `javascript:` or `data:` URLs which the admin UI
    #     might render unsafely (XSS into the privileged review UI).
    #   - chain into the cancel-path delete bug (now also fixed
    #     defence-in-depth below).
    def _validate_doc_url(url: Optional[str], field_name: str) -> Optional[str]:
        if url is None:
            return None
        url = url.strip()
        if not url:
            return None
        if len(url) > 1024:
            raise HTTPException(status_code=400, detail=f"{field_name} too long")
        expected_local_prefix = f"verification_docs/{current_user.id}/"
        expected_gcs_prefix_fragment = f"/{current_user.id}/"
        if url.startswith(expected_local_prefix):
            # Local-fallback URL from /upload-doc — accept and
            # strip nothing.
            return url
        if url.startswith("gcs://") and expected_gcs_prefix_fragment in url:
            # GCS pointer — also acceptable. We don't parse buckets
            # here because the read path (admin.serve_verification_document)
            # already enforces the configured bucket.
            return url
        raise HTTPException(
            status_code=400,
            detail=f"{field_name} must come from /api/verification/upload-doc for this user",
        )

    validated_front = _validate_doc_url(req.doc_front_url, "doc_front_url")
    validated_back = _validate_doc_url(req.doc_back_url, "doc_back_url")
    validated_selfie = _validate_doc_url(req.selfie_url, "selfie_url")
    
    # Create dedupe hash
    dedupe = hashlib.sha256(
        f"{current_user.id}:{req.doc_type}:{req.legal_first_name}:{req.legal_last_name}".encode()
    ).hexdigest()
    
    # Create verification request
    # 🔴 ROUND 70 — KYC doc URLs now Fernet-wrapped at rest (matches
    # the model header comment that already claimed "encrypted").
    # Previously these were plaintext columns; insider DB read +
    # 15-min signed-URL replay → passport + selfie download. The
    # decrypt path in admin.py is wrapped in `_kyc_decrypt` (added
    # in same round) so the admin viewer still works.
    verification = VerificationRequest(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        status="pending",
        legal_first_name=encrypt_text(req.legal_first_name.strip()),
        legal_last_name=encrypt_text(req.legal_last_name.strip()),
        country=encrypt_text(req.country.strip()),
        category=req.category,
        doc_type=req.doc_type,
        doc_front_url=encrypt_text(validated_front) if validated_front else None,
        doc_back_url=encrypt_text(validated_back) if validated_back else None,
        selfie_url=encrypt_text(validated_selfie) if validated_selfie else None,
        links_json=json.dumps(req.links) if req.links else None,
        submitted_at=datetime.utcnow(),
        hash_dedupe=dedupe
    )
    
    db.add(verification)
    db.commit()
    
    print(f"📋 Verification request submitted by {current_user.username} ({verification.id})")
    
    return {
        "request_id": verification.id,
        "status": "pending",
        "message": "Your verification request has been submitted and is under review."
    }


@router.get("/status")
async def get_verification_status(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get current verification status for the authenticated user."""
    
    # If already verified via User model, return verified
    if current_user.is_verified:
        return VerificationStatusResponse(
            status="verified",
            reviewed_at=current_user.verified_at.isoformat() if current_user.verified_at else None,
            badge_type=current_user.verification_badge_type or "identity",
            can_reapply=False
        )
    
    # Check latest request
    latest = db.query(VerificationRequest).filter(
        VerificationRequest.user_id == current_user.id
    ).order_by(VerificationRequest.submitted_at.desc()).first()
    
    if not latest:
        return VerificationStatusResponse(
            status="not_verified",
            can_reapply=True
        )
    
    # Calculate reapply eligibility
    can_reapply = False
    reapply_after = None
    
    if latest.status == "rejected" and latest.reviewed_at:
        cooldown_end = latest.reviewed_at + timedelta(days=REAPPLY_COOLDOWN_DAYS)
        if datetime.utcnow() >= cooldown_end:
            can_reapply = True
        else:
            reapply_after = cooldown_end.isoformat()
    elif latest.status == "revoked":
        can_reapply = True
    
    return VerificationStatusResponse(
        status=latest.status,
        submitted_at=latest.submitted_at.isoformat() if latest.submitted_at else None,
        reviewed_at=latest.reviewed_at.isoformat() if latest.reviewed_at else None,
        reason=latest.decision_reason,
        category=latest.category,
        can_reapply=can_reapply,
        reapply_after=reapply_after
    )


@router.post("/cancel")
async def cancel_verification_request(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Cancel a pending verification request.

    🔴 hacker-audit 2026-05-19 — CRITICAL arbitrary-file-deletion fix.

    PREVIOUSLY this endpoint took the three URL strings off the
    verification request row and ran:

        for url in [doc_front_url, doc_back_url, selfie_url]:
            file_path = Path(url.lstrip("/"))
            if file_path.exists():
                file_path.unlink()

    Those URLs are CLIENT-SUPPLIED on POST /api/verification/request
    — there's no validation that they live inside the verification-
    docs directory, or even that they're relative paths at all. An
    attacker could submit a request with e.g.
      doc_front_url = "encryption.key"
      doc_back_url  = "raven.db"
      selfie_url    = "AuthKey_XZ5LNZVH3C.p8"
    …then immediately POST /api/verification/cancel and the server
    happily unlinks all three files inside its working directory.
    `"../../"` traversal also worked — anything reachable by the
    server process's filesystem credentials.

    Concretely this could delete:
      • encryption.key      → all Fernet-wrapped legacy/system
                              messages become unreadable forever
      • raven.db / messenger.db → wipe the SQLite DB (dev or
                                  mis-configured single-instance prod)
      • AuthKey_*.p8        → push notifications die
      • any other server-writable file under the process cwd

    FIX:
      1. Only touch files that resolve INSIDE
         `VERIFICATION_DOCS_DIR / current_user.id`. Anything else
         (GCS URLs, absolute paths, traversal, other users' subdirs)
         is silently skipped — we still NULL the column either way.
      2. Use `Path.resolve(strict=False)` and verify
         `realpath(file).is_relative_to(realpath(allowed_root))`
         before any unlink.
      3. NULL the columns on the DB row so a stale URL can never be
         re-cancel'd to re-trigger the (now-bounded) delete.
    """
    pending = db.query(VerificationRequest).filter(
        VerificationRequest.user_id == current_user.id,
        VerificationRequest.status == "pending"
    ).first()

    if not pending:
        raise HTTPException(status_code=404, detail="No pending request found.")

    # Resolve the per-user allowed root once, up front. Anything that
    # doesn't resolve inside this directory is rejected — including
    # absolute paths, ".." traversal, and other users' subdirs.
    allowed_root = (VERIFICATION_DOCS_DIR / str(current_user.id)).resolve()

    # 🔴 PB-M9 (GDPR erasure) — the doc_*_url columns are stored
    # Fernet-WRAPPED at rest (see /request: encrypt_text(...)). The
    # previous cancel logic fed the raw ciphertext into the path
    # containment check, which always failed (ciphertext has no
    # slashes → never resolves inside allowed_root), so NO file was
    # ever deleted — yet the columns were NULLed, orphaning the KYC
    # document forever. We now DECRYPT first, then delete from BOTH
    # backends the doc could live in:
    #   • local-fallback path  "verification_docs/<uid>/<file>"
    #   • GCS pointer          "gcs://<bucket>/<uid>/<file>"
    expected_gcs_fragment = f"/{current_user.id}/"

    def _delete_local(rel_path: str) -> None:
        # Reuse the strict per-user containment guard (defence in
        # depth): absolute paths, "..", and other users' subdirs are
        # refused before any unlink.
        if rel_path.startswith("/") or ".." in rel_path.split("/"):
            return
        try:
            candidate = (Path.cwd() / rel_path).resolve(strict=False)
        except (OSError, RuntimeError):
            return
        try:
            candidate.relative_to(allowed_root)
        except ValueError:
            return
        if candidate.is_file():
            try:
                candidate.unlink()
            except OSError:
                pass

    def _delete_gcs(gcs_url: str) -> None:
        # Only delete blobs scoped to THIS user's subdir. Shape:
        # gcs://<bucket>/<uid>/<file>. Refuse anything whose object
        # path isn't under "<uid>/".
        without_scheme = gcs_url[len("gcs://"):]
        parts = without_scheme.split("/", 1)
        if len(parts) != 2:
            return
        object_path = parts[1]  # "<uid>/<file>"
        if not object_path.startswith(f"{current_user.id}/"):
            return
        if ".." in object_path.split("/"):
            return
        GCS_BUCKET = os.getenv(
            "VERIFICATION_DOCS_BUCKET", "hybrid-messenger-verification-docs"
        )
        try:
            from google.cloud import storage as gcs_storage
            client = gcs_storage.Client()
            bucket = client.bucket(GCS_BUCKET)
            bucket.blob(object_path).delete()
            print(f"🗑️ [KYC-cancel] GCS blob purged: {object_path}")
        except Exception as e:
            # GCS unavailable (dev) or blob already gone — best effort.
            print(
                f"⚠️ [KYC-cancel] GCS blob delete skipped for "
                f"{object_path}: {type(e).__name__}: {e}"
            )

    def _erase_doc(stored: Optional[str]) -> None:
        if not stored:
            return
        # Columns are Fernet-wrapped at rest; decrypt to the original
        # storage pointer. decrypt_text passes through opaque/plain
        # values and returns "[DECRYPT_FAILED]" (never raises) on a
        # bad blob, which simply won't match either backend prefix.
        try:
            url = decrypt_text(stored)
        except Exception:
            return
        if not url:
            return
        url = url.strip()
        if url.startswith("gcs://"):
            _delete_gcs(url)
        elif "://" in url:
            # Unknown remote scheme — nothing we manage here.
            return
        else:
            _delete_local(url)

    for stored in (pending.doc_front_url, pending.doc_back_url, pending.selfie_url):
        _erase_doc(stored)

    # Null the columns so the row can't be replayed to re-trigger the
    # delete path on a future call (defence in depth).
    pending.doc_front_url = None
    pending.doc_back_url = None
    pending.selfie_url = None
    pending.status = "cancelled"
    pending.reviewed_at = datetime.utcnow()
    db.commit()

    return {"status": "cancelled", "message": "Verification request cancelled."}


@router.post("/upload-doc")
async def upload_verification_document(
    request: Request,
    file: UploadFile = File(...),
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Upload an identity document for verification.
    Files are stored in Google Cloud Storage for persistence across deploys.
    Falls back to local filesystem in development.
    """
    # Validate file extension
    ext = os.path.splitext(file.filename or "")[1].lower()
    if ext not in ALLOWED_DOC_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid file type. Allowed: {', '.join(ALLOWED_DOC_EXTENSIONS)}"
        )
    
    # Read and validate size
    content = await file.read()
    if len(content) > MAX_DOC_SIZE:
        raise HTTPException(
            status_code=413,
            detail=f"File too large. Maximum {MAX_DOC_SIZE // (1024*1024)}MB allowed."
        )
    
    # Generate unique filename (no PII in filename)
    file_id = str(uuid.uuid4())
    filename = f"{file_id}{ext}"
    gcs_path = f"{current_user.id}/{filename}"
    
    # Try GCS first (production), fall back to local (development)
    GCS_BUCKET = os.getenv("VERIFICATION_DOCS_BUCKET", "hybrid-messenger-verification-docs")
    stored_url = None
    
    try:
        from google.cloud import storage as gcs_storage
        client = gcs_storage.Client()
        bucket = client.bucket(GCS_BUCKET)
        blob = bucket.blob(gcs_path)
        blob.upload_from_string(content, content_type=file.content_type or "image/jpeg")
        stored_url = f"gcs://{GCS_BUCKET}/{gcs_path}"
        print(f"📄 Verification doc uploaded to GCS by {current_user.username}: {gcs_path}")
    except Exception as e:
        print(f"🚨 GCS upload FAILED for {current_user.username}: {type(e).__name__}: {e}")
        print(f"   Bucket: {GCS_BUCKET}, Path: {gcs_path}")
        print(f"   ⚠️ Falling back to LOCAL storage — files WILL BE LOST on redeploy!")
        # Fallback: local filesystem (development only)
        user_dir = VERIFICATION_DOCS_DIR / current_user.id
        user_dir.mkdir(parents=True, exist_ok=True)
        file_path = user_dir / filename
        with open(file_path, "wb") as f:
            f.write(content)
        stored_url = f"verification_docs/{current_user.id}/{filename}"
        print(f"📄 Verification doc uploaded locally by {current_user.username}: {filename}")
    
    return {
        "doc_url": stored_url,
        "filename": filename,
        "size": len(content),
        "mime_type": file.content_type
    }

