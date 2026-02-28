"""
Voice Messages Router - Voice recording upload and transcript generation
"""
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, BackgroundTasks, Request
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional
from datetime import datetime
import uuid
import os

from database import get_db
from models import User, VoiceMessage
from routers.users import get_current_user

router = APIRouter(prefix="/api/voice", tags=["voice"])


class VoiceMessageCreate(BaseModel):
    recipient_id: str
    duration_seconds: int


class VoiceMessageResponse(BaseModel):
    id: str
    sender_id: str
    recipient_id: str
    audio_url: str
    duration_seconds: int
    transcript: Optional[str]
    transcript_status: str
    created_at: datetime
    
    class Config:
        from_attributes = True


@router.post("/upload", response_model=VoiceMessageResponse)
async def upload_voice_message(
    request: Request,
    file: UploadFile = File(...),
    recipient_id: str = None,
    duration_seconds: int = 0,
    background_tasks: BackgroundTasks = None,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Upload a voice message and optionally generate transcript."""
    
    # Validate file - accept audio/* or file extensions typically used for audio
    valid_extensions = {'.m4a', '.mp3', '.wav', '.aac', '.ogg', '.mp4', '.m4b'}
    file_ext = ('.' + file.filename.split('.')[-1].lower()) if file.filename and '.' in file.filename else ''
    
    is_audio_content = file.content_type and (
        file.content_type.startswith('audio/') or 
        file.content_type in ('application/octet-stream', 'video/mp4')  # m4a sometimes comes as these
    )
    is_audio_extension = file_ext in valid_extensions
    
    if not is_audio_content and not is_audio_extension:
        print(f"❌ Invalid audio file: content_type={file.content_type}, filename={file.filename}")
        raise HTTPException(status_code=400, detail="Invalid audio file")
    
    # Save file
    voice_id = str(uuid.uuid4())
    extension = file.filename.split('.')[-1] if file.filename else 'm4a'
    filename = f"{voice_id}.{extension}"
    filepath = f"uploads/voice/{filename}"
    
    os.makedirs("uploads/voice", exist_ok=True)
    
    with open(filepath, "wb") as f:
        content = await file.read()
        f.write(content)
    
    # Build full URL for audio
    base_url = str(request.base_url).rstrip('/')
    full_audio_url = f"{base_url}/uploads/voice/{filename}"
    
    # Create voice message record
    voice_msg = VoiceMessage(
        id=voice_id,
        sender_id=current_user.id,
        recipient_id=recipient_id or current_user.id,  # Self if not specified
        audio_url=full_audio_url,  # Full URL, not relative path
        duration_seconds=duration_seconds,
        transcript_status="pending"
    )
    
    db.add(voice_msg)
    db.commit()
    db.refresh(voice_msg)
    
    # Queue transcript generation
    if background_tasks:
        background_tasks.add_task(
            generate_transcript,
            voice_id=voice_id,
            filepath=filepath,
        )
    
    print(f"🎙️ Voice message uploaded by {current_user.username}: {duration_seconds}s")
    
    return VoiceMessageResponse(
        id=voice_msg.id,
        sender_id=voice_msg.sender_id,
        recipient_id=voice_msg.recipient_id,
        audio_url=voice_msg.audio_url,
        duration_seconds=voice_msg.duration_seconds,
        transcript=voice_msg.transcript,
        transcript_status=voice_msg.transcript_status,
        created_at=voice_msg.created_at
    )


@router.get("/{voice_id}/transcript")
def get_transcript(
    voice_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get transcript for a voice message."""
    voice_msg = db.query(VoiceMessage).filter(VoiceMessage.id == voice_id).first()
    
    if not voice_msg:
        raise HTTPException(status_code=404, detail="Voice message not found")
    
    # Check access
    if voice_msg.sender_id != current_user.id and voice_msg.recipient_id != current_user.id:
        raise HTTPException(status_code=403, detail="Access denied")
    
    return {
        "id": voice_msg.id,
        "transcript": voice_msg.transcript,
        "transcript_language": voice_msg.transcript_language,
        "transcript_status": voice_msg.transcript_status
    }


async def generate_transcript(voice_id: str, filepath: str):
    """Background task to generate transcript using Gemini 2.0 Flash.
    
    Downloads audio from local file, sends to Gemini for transcription
    with automatic language detection.
    """
    from database import SessionLocal
    from services.gemini_service import get_gemini_service
    
    print(f"🔊 Generating transcript for {voice_id}...")
    
    db = SessionLocal()
    try:
        voice_msg = db.query(VoiceMessage).filter(VoiceMessage.id == voice_id).first()
        if not voice_msg:
            print(f"❌ Voice message {voice_id} not found")
            return
        
        # Mark as processing
        voice_msg.transcript_status = "processing"
        db.commit()
        
        # Run async transcription
        gemini = get_gemini_service()
        result = await gemini.transcribe_audio(voice_msg.audio_url)
        
        if result.get("text"):
            voice_msg.transcript = result["text"]
            voice_msg.transcript_language = result.get("language")
            voice_msg.transcript_status = "ready"
            db.commit()
            print(f"✅ Transcript ready for {voice_id}: "
                  f"lang={result.get('language')}, len={len(result['text'])}")
        else:
            voice_msg.transcript_status = "failed"
            db.commit()
            print(f"❌ Transcript failed for {voice_id}: {result.get('error', 'unknown')}")
            
    except Exception as e:
        print(f"❌ Transcript generation failed for {voice_id}: {e}")
        import traceback
        traceback.print_exc()
        try:
            voice_msg = db.query(VoiceMessage).filter(VoiceMessage.id == voice_id).first()
            if voice_msg:
                voice_msg.transcript_status = "failed"
                db.commit()
        except Exception:
            pass
    finally:
        db.close()

