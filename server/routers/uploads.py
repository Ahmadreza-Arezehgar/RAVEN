from fastapi import APIRouter, Depends, File, UploadFile, HTTPException, status, Request
from sqlalchemy.orm import Session
from PIL import Image, ImageOps
import asyncio
import io
import uuid
import os
from pathlib import Path
from typing import Optional

from database import get_db
from models import User
from routers.users import get_current_user

router = APIRouter(prefix="/api/uploads", tags=["uploads"])


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
                "max_file_size_mb": 2048 if is_premium else 100,
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

# ⚡ CDN: When set, media URLs use CDN domain instead of raw GCS.
# Example: "https://media.raven-messager.com" → Cloudflare proxy → GCS
# Provides edge caching worldwide and ~10x faster image loads for users.
CDN_MEDIA_BASE_URL = os.getenv("CDN_MEDIA_BASE_URL", "")

# ⚡ PERF: Cached singleton — avoids ~200-500ms TLS/gRPC handshake per upload
_gcs_bucket_cache = None
_gcs_bucket_checked = False

def _get_gcs_bucket():
    """Get GCS bucket client (cached singleton). Returns None if GCS is unavailable (dev mode)."""
    global _gcs_bucket_cache, _gcs_bucket_checked
    if _gcs_bucket_checked:
        return _gcs_bucket_cache
    try:
        from google.cloud import storage as gcs_storage
        client = gcs_storage.Client()
        _gcs_bucket_cache = client.bucket(GCS_MEDIA_BUCKET)
        _gcs_bucket_checked = True
        cdn_status = f"CDN={CDN_MEDIA_BASE_URL}" if CDN_MEDIA_BASE_URL else "CDN=off (direct GCS)"
        print(f"✅ GCS bucket '{GCS_MEDIA_BUCKET}' connected (cached singleton, {cdn_status})")
        return _gcs_bucket_cache
    except Exception as e:
        _gcs_bucket_checked = True
        print(f"⚠️ GCS unavailable (dev mode): {type(e).__name__}: {e}")
        return None

def _make_media_url(bucket_name: str, gcs_path: str) -> str:
    """Build the public URL for a GCS object, using CDN if configured."""
    if CDN_MEDIA_BASE_URL:
        return f"{CDN_MEDIA_BASE_URL.rstrip('/')}/{gcs_path}"
    return f"https://storage.googleapis.com/{bucket_name}/{gcs_path}"

def _upload_to_gcs(bucket, content: bytes, gcs_path: str, content_type: str) -> str:
    """Upload bytes to GCS and return the public/CDN URL.
    
    Sets Cache-Control for CDN edge caching. Since filenames include UUIDs,
    content is immutable — new upload always produces a new URL.
    """
    blob = bucket.blob(gcs_path)
    # CDN optimization: immutable content (UUID filenames), cache for 1 year
    blob.cache_control = "public, max-age=31536000, immutable"
    blob.upload_from_string(content, content_type=content_type)
    # Bucket uses Uniform Bucket-Level Access — public read is set via IAM, not per-object ACL
    public_url = _make_media_url(bucket.name, gcs_path)
    print(f"☁️ Uploaded to GCS: {gcs_path} → {public_url}")
    return public_url


# ==================== Local Fallback Configuration ====================
UPLOAD_DIR = Path("uploads")
UPLOAD_DIR.mkdir(exist_ok=True)
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB (free tier image limit)
MAX_FILE_SIZE_PREMIUM = 2 * 1024 * 1024 * 1024  # 2GB (premium tier)
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp"}
MAX_IMAGE_DIMENSION = 2048  # Max width or height

# File upload configuration (PDF, DOC, etc.)
FILE_UPLOAD_DIR = Path("uploads/files")
FILE_UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
MAX_FILE_SIZE_BYTES = 100 * 1024 * 1024  # 100MB for files (free tier — videos need more room)
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


def _process_image_sync(content: bytes, file_ext: str, max_dimension: int) -> tuple:
    """CPU-bound image processing — runs in thread pool via asyncio.to_thread.
    
    Returns (optimized_bytes, content_type, output_ext).
    """
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
    if image.width > max_dimension or image.height > max_dimension:
        image.thumbnail((max_dimension, max_dimension), Image.Resampling.LANCZOS)
    
    # ⚡ PERF: Always output WebP — ~30% smaller than JPEG at same visual quality.
    # iOS 14+ and all modern browsers support WebP natively.
    # Fallback: keep original format only for PNG with transparency (already converted above).
    output_buffer = io.BytesIO()
    image.save(output_buffer, 'WEBP', quality=85, method=4)  # method=4 = good speed/quality balance
    content_type = "image/webp"
    output_ext = ".webp"
    
    return output_buffer.getvalue(), content_type, output_ext


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
    - Converts to WebP for ~30% smaller file size
    - Optimizes image (resizes if needed)
    - Uploads to GCS (production) or local filesystem (dev)
    - Returns image URL path
    """
    try:
        # Validate file extension
        file_ext = Path(file.filename or "").suffix.lower()
        if file_ext not in ALLOWED_EXTENSIONS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid file type. Allowed: {', '.join(ALLOWED_EXTENSIONS)}"
            )
        
        # Read file content
        content = await file.read()
        
        # Validate file size (premium-aware)
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
        
        # Validate and optimize image
        try:
            # ⚡ PERF: Run CPU-bound PIL processing in thread pool
            # to avoid blocking the async event loop (~50-200ms for large images)
            optimized_content, content_type, output_ext = await asyncio.to_thread(
                _process_image_sync, content, file_ext, MAX_IMAGE_DIMENSION
            )
            
            # Generate unique filename (always .webp now)
            unique_filename = f"{uuid.uuid4()}{output_ext}"
            
            # Try GCS first (production), fall back to local (development)
            bucket = _get_gcs_bucket()
            if bucket:
                gcs_path = f"images/{unique_filename}"
                full_image_url = _upload_to_gcs(bucket, optimized_content, gcs_path, content_type)
            else:
                # Local fallback (development)
                file_path = UPLOAD_DIR / unique_filename
                with open(file_path, "wb") as f:
                    f.write(optimized_content)
                base_url = str(request.base_url).rstrip('/')
                full_image_url = f"{base_url}/uploads/{unique_filename}"
                print(f"📁 Image saved locally: {unique_filename}")
            
            print(f"✅ Image uploaded: {unique_filename} ({len(content)} → {len(optimized_content)} bytes, {content_type}) by user {current_user.username}")
            
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


# ==================== GCS Signed URL Upload (bypasses Cloud Run 32MB limit) ====================
from pydantic import BaseModel

class SignedUploadRequest(BaseModel):
    file_ext: str  # e.g. ".mp4"
    content_type: str  # e.g. "video/mp4"

class SignedUploadResponse(BaseModel):
    upload_url: str  # PUT this URL with the file body
    file_url: str  # The final public/CDN URL after upload completes
    gcs_path: str  # GCS object path (for reference)

@router.post("/video/sign", response_model=SignedUploadResponse)
def get_signed_video_upload_url(
    req: SignedUploadRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Generate a GCS signed URL for direct video upload.
    
    Client uploads directly to GCS using HTTP PUT, completely bypassing
    Cloud Run's 32MB request body limit. Supports files up to 5GB.
    
    Flow:
    1. Client calls POST /api/uploads/video/sign with file extension
    2. Server returns a pre-signed PUT URL (valid 30 min)
    3. Client PUTs the video bytes directly to GCS
    4. Client uses the returned file_url in the post creation payload
    """
    # Validate extension
    allowed_video_exts = {".mp4", ".mov", ".m4v", ".avi"}
    ext = req.file_ext.lower()
    if ext not in allowed_video_exts:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid video type. Allowed: {', '.join(allowed_video_exts)}"
        )
    
    bucket = _get_gcs_bucket()
    if not bucket:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Cloud storage unavailable. Try the standard upload endpoint."
        )
    
    # Generate unique path
    unique_filename = f"{uuid.uuid4()}{ext}"
    gcs_path = f"files/{unique_filename}"
    
    try:
        blob = bucket.blob(gcs_path)
        # CDN optimization: immutable content (UUID filenames)
        blob.cache_control = "public, max-age=31536000, immutable"
        
        # Generate signed URL for PUT (30 min expiry)
        # On Cloud Run, compute engine credentials lack a local private key,
        # so we pass service_account_email + access_token to delegate signing
        # to the IAM signBlob API. The SA needs iam.serviceAccounts.signBlob.
        import datetime as dt
        import google.auth
        import google.auth.transport.requests
        
        credentials, project = google.auth.default()
        
        # Refresh to ensure we have a valid access token
        auth_request = google.auth.transport.requests.Request()
        credentials.refresh(auth_request)
        
        # Get the service account email for IAM signing
        if hasattr(credentials, 'service_account_email'):
            sa_email = credentials.service_account_email
        else:
            sa_email = f"{project}@appspot.gserviceaccount.com"
        
        signed_url = blob.generate_signed_url(
            version="v4",
            expiration=dt.timedelta(minutes=30),
            method="PUT",
            content_type=req.content_type,
            service_account_email=sa_email,
            access_token=credentials.token,
        )
        
        # Build the final public URL
        file_url = _make_media_url(bucket.name, gcs_path)
        
        print(f"🔐 [SignedUpload] Generated signed URL for {gcs_path} "
              f"(user={current_user.username}, ext={ext})")
        
        return SignedUploadResponse(
            upload_url=signed_url,
            file_url=file_url,
            gcs_path=gcs_path
        )
    except Exception as e:
        print(f"❌ [SignedUpload] Failed to generate signed URL: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to generate upload URL"
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
        # Validate file extension
        original_filename = file.filename or "unknown"
        file_ext = Path(original_filename).suffix.lower()
        
        if file_ext not in ALLOWED_FILE_EXTENSIONS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid file type. Allowed: {', '.join(ALLOWED_FILE_EXTENSIONS)}"
            )
        
        is_video = file_ext in {'.mp4', '.mov', '.m4v', '.avi'}
        max_size = MAX_FILE_SIZE_BYTES_PREMIUM if current_user.is_premium else MAX_FILE_SIZE_BYTES
        
        # Generate unique filename (preserve original extension)
        unique_filename = f"{uuid.uuid4()}{file_ext}"
        mime_type = MIME_TYPES.get(file_ext, "application/octet-stream")
        
        if is_video:
            # ⚡ Stream video to temp file in 1MB chunks — never loads full video into RAM
            import tempfile
            temp_path = Path(tempfile.mkdtemp()) / unique_filename
            file_size = 0
            try:
                with open(temp_path, "wb") as tmp:
                    while True:
                        chunk = await file.read(1024 * 1024)  # 1MB chunks
                        if not chunk:
                            break
                        file_size += len(chunk)
                        if file_size > max_size:
                            raise HTTPException(
                                status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                                detail=f"Video too large. Maximum: {max_size/(1024*1024):.0f}MB"
                                    + ("" if current_user.is_premium else " — Upgrade to RAVEN+ for up to 2GB! 🚀")
                            )
                        tmp.write(chunk)
                
                print(f"🎬 [VideoUpload] ext={file_ext} size={file_size/(1024*1024):.1f}MB user={current_user.username} premium={current_user.is_premium}")
                
                # Upload to GCS or local
                bucket = _get_gcs_bucket()
                if bucket:
                    content = temp_path.read_bytes()
                    gcs_path = f"files/{unique_filename}"
                    full_file_url = _upload_to_gcs(bucket, content, gcs_path, mime_type)
                    print(f"🎬 [VideoUpload] GCS upload OK → {full_file_url[:80]}...")
                else:
                    import shutil
                    dest_path = FILE_UPLOAD_DIR / unique_filename
                    shutil.move(str(temp_path), str(dest_path))
                    base_url = str(request.base_url).rstrip('/')
                    full_file_url = f"{base_url}/uploads/files/{unique_filename}"
                    print(f"📁 Video saved locally: {unique_filename}")
            finally:
                # Clean up temp file if still exists
                if temp_path.exists():
                    temp_path.unlink(missing_ok=True)
                temp_path.parent.rmdir()
        else:
            # Non-video files (small) — read entirely into memory
            content = await file.read()
            file_size = len(content)
            
            if file_size > max_size:
                max_mb = max_size / (1024*1024)
                detail = f"File too large. Maximum size: {max_mb:.0f}MB"
                if not current_user.is_premium:
                    detail += " — Upgrade to RAVEN+ for up to 2GB uploads! 🚀"
                raise HTTPException(
                    status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                    detail=detail
                )
            
            bucket = _get_gcs_bucket()
            if bucket:
                gcs_path = f"files/{unique_filename}"
                full_file_url = _upload_to_gcs(bucket, content, gcs_path, mime_type)
            else:
                file_path = FILE_UPLOAD_DIR / unique_filename
                with open(file_path, "wb") as f:
                    f.write(content)
                base_url = str(request.base_url).rstrip('/')
                full_file_url = f"{base_url}/uploads/files/{unique_filename}"
                print(f"📁 File saved locally: {unique_filename}")
        
        print(f"✅ File uploaded: {unique_filename} ({file_size} bytes, {mime_type}) by user {current_user.username}")
        
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
        import traceback
        traceback.print_exc()
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
