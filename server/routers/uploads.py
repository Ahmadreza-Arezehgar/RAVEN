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
    # This URL is CDN-ready: put Cloudflare / Cloud CDN in front of storage.googleapis.com
    public_url = f"https://storage.googleapis.com/{bucket.name}/{gcs_path}"
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
            if image.width > MAX_IMAGE_DIMENSION or image.height > MAX_IMAGE_DIMENSION:
                image.thumbnail((MAX_IMAGE_DIMENSION, MAX_IMAGE_DIMENSION), Image.Resampling.LANCZOS)
            
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
        # Validate file extension
        original_filename = file.filename or "unknown"
        file_ext = Path(original_filename).suffix.lower()
        
        if file_ext not in ALLOWED_FILE_EXTENSIONS:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid file type. Allowed: {', '.join(ALLOWED_FILE_EXTENSIONS)}"
            )
        
        # Read file content
        content = await file.read()
        file_size = len(content)
        
        # Validate file size (premium-aware)
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
