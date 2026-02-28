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
from encryption import encrypt_text

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
    
    # Create dedupe hash
    dedupe = hashlib.sha256(
        f"{current_user.id}:{req.doc_type}:{req.legal_first_name}:{req.legal_last_name}".encode()
    ).hexdigest()
    
    # Create verification request
    verification = VerificationRequest(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        status="pending",
        legal_first_name=encrypt_text(req.legal_first_name.strip()),
        legal_last_name=encrypt_text(req.legal_last_name.strip()),
        country=req.country.strip(),
        category=req.category,
        doc_type=req.doc_type,
        doc_front_url=req.doc_front_url,
        doc_back_url=req.doc_back_url,
        selfie_url=req.selfie_url,
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
    """Cancel a pending verification request."""
    pending = db.query(VerificationRequest).filter(
        VerificationRequest.user_id == current_user.id,
        VerificationRequest.status == "pending"
    ).first()
    
    if not pending:
        raise HTTPException(status_code=404, detail="No pending request found.")
    
    # Delete the request documents
    for url in [pending.doc_front_url, pending.doc_back_url, pending.selfie_url]:
        if url:
            file_path = Path(url.lstrip("/"))
            if file_path.exists():
                file_path.unlink()
    
    # Update status
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

