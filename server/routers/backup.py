"""
Backup Router - Cloud backup and restore for messages and media
"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import desc
from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime
import uuid
import json

from database import get_db
from models import User, Message, Backup, MediaObject, VoiceMessage, Post
from routers.users import get_current_user

router = APIRouter(prefix="/api/backup", tags=["backup"])


# ==================== SCHEMAS ====================

class BackupStartRequest(BaseModel):
    is_encrypted: bool = False
    encryption_key_hash: Optional[str] = None


class BackupStartResponse(BaseModel):
    backup_id: str
    created_at: datetime


class BackupChunkRequest(BaseModel):
    backup_id: str
    messages: List[dict]  # Serialized messages
    media: List[dict]  # Media metadata


class BackupFinishRequest(BaseModel):
    backup_id: str


class BackupInfo(BaseModel):
    id: str
    created_at: datetime
    size_bytes: int
    message_count: int
    media_count: int
    is_encrypted: bool
    status: str
    
    class Config:
        from_attributes = True


class RestoreResponse(BaseModel):
    backup_id: str
    message_count: int
    media_count: int
    messages: List[dict]
    media_urls: List[dict]


# ==================== ENDPOINTS ====================

@router.post("/start", response_model=BackupStartResponse)
def start_backup(
    request: BackupStartRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Initialize a new backup session."""
    
    # Create backup record
    backup = Backup(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        is_encrypted=request.is_encrypted,
        encryption_key_hash=request.encryption_key_hash,
        status="uploading"
    )
    
    db.add(backup)
    db.commit()
    db.refresh(backup)
    
    print(f"📦 Backup started for {current_user.username}: {backup.id}")
    
    return BackupStartResponse(
        backup_id=backup.id,
        created_at=backup.created_at
    )


@router.put("/chunk")
def upload_backup_chunk(
    request: BackupChunkRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Upload a chunk of backup data (messages + media metadata)."""
    
    backup = db.query(Backup).filter(
        Backup.id == request.backup_id,
        Backup.user_id == current_user.id
    ).first()
    
    if not backup:
        raise HTTPException(status_code=404, detail="Backup not found")
    
    if backup.status != "uploading":
        raise HTTPException(status_code=400, detail="Backup not in uploading state")
    
    # Update counts
    backup.message_count += len(request.messages)
    backup.media_count += len(request.media)
    
    # Calculate size (rough estimate)
    chunk_size = len(json.dumps(request.messages)) + len(json.dumps(request.media))
    backup.size_bytes += chunk_size
    
    # Update last message timestamp
    if request.messages:
        timestamps = [m.get('timestamp') for m in request.messages if m.get('timestamp')]
        if timestamps:
            backup.last_message_at = max(timestamps)
    
    db.commit()
    
    print(f"📦 Backup chunk uploaded: {len(request.messages)} messages, {len(request.media)} media")
    
    return {"status": "ok", "message_count": backup.message_count, "media_count": backup.media_count}


@router.post("/finish")
def finish_backup(
    request: BackupFinishRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Finalize the backup."""
    
    backup = db.query(Backup).filter(
        Backup.id == request.backup_id,
        Backup.user_id == current_user.id
    ).first()
    
    if not backup:
        raise HTTPException(status_code=404, detail="Backup not found")
    
    backup.status = "completed"
    db.commit()
    
    print(f"✅ Backup completed for {current_user.username}: {backup.message_count} messages, {backup.media_count} media")
    
    return {
        "status": "completed",
        "backup_id": backup.id,
        "size_bytes": backup.size_bytes,
        "message_count": backup.message_count,
        "media_count": backup.media_count
    }


@router.get("/latest", response_model=Optional[BackupInfo])
def get_latest_backup(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get the user's latest completed backup."""
    
    backup = db.query(Backup).filter(
        Backup.user_id == current_user.id,
        Backup.status == "completed"
    ).order_by(desc(Backup.created_at)).first()
    
    if not backup:
        return None
    
    return BackupInfo(
        id=backup.id,
        created_at=backup.created_at,
        size_bytes=backup.size_bytes,
        message_count=backup.message_count,
        media_count=backup.media_count,
        is_encrypted=backup.is_encrypted,
        status=backup.status
    )


@router.post("/restore", response_model=RestoreResponse)
def restore_backup(
    backup_id: Optional[str] = None,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Restore from a backup. Returns all messages and media URLs."""
    
    # Get the backup (latest if not specified)
    if backup_id:
        backup = db.query(Backup).filter(
            Backup.id == backup_id,
            Backup.user_id == current_user.id,
            Backup.status == "completed"
        ).first()
    else:
        backup = db.query(Backup).filter(
            Backup.user_id == current_user.id,
            Backup.status == "completed"
        ).order_by(desc(Backup.created_at)).first()
    
    if not backup:
        raise HTTPException(status_code=404, detail="No backup found")
    
    # Get all user's messages from server
    messages = db.query(Message).filter(
        (Message.sender_id == current_user.id) | 
        (Message.recipient_id == current_user.id)
    ).order_by(Message.timestamp).all()
    
    # Get all user's media
    media = db.query(MediaObject).filter(
        MediaObject.owner_id == current_user.id
    ).all()
    
    # Get voice messages
    voice_messages = db.query(VoiceMessage).filter(
        (VoiceMessage.sender_id == current_user.id) |
        (VoiceMessage.recipient_id == current_user.id)
    ).all()
    
    # Serialize messages
    messages_data = [{
        "id": m.id,
        "sender_id": m.sender_id,
        "recipient_id": m.recipient_id,
        "content": m.content,
        "timestamp": m.timestamp.isoformat() if m.timestamp else None,
        "read_at": m.read_at.isoformat() if m.read_at else None,
    } for m in messages]
    
    # Serialize media URLs
    media_data = [{
        "id": m.id,
        "type": m.type,
        "url": m.url,
        "size_bytes": m.size_bytes,
    } for m in media]
    
    # Add voice messages to media
    for vm in voice_messages:
        media_data.append({
            "id": vm.id,
            "type": "voice",
            "url": vm.audio_url,
            "duration_seconds": vm.duration_seconds,
        })
    
    print(f"📥 Restore initiated for {current_user.username}: {len(messages_data)} messages, {len(media_data)} media")
    
    return RestoreResponse(
        backup_id=backup.id,
        message_count=len(messages_data),
        media_count=len(media_data),
        messages=messages_data,
        media_urls=media_data
    )


@router.get("/history")
def get_backup_history(
    limit: int = 10,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get user's backup history."""
    
    backups = db.query(Backup).filter(
        Backup.user_id == current_user.id
    ).order_by(desc(Backup.created_at)).limit(limit).all()
    
    return [{
        "id": b.id,
        "created_at": b.created_at.isoformat(),
        "size_bytes": b.size_bytes,
        "message_count": b.message_count,
        "media_count": b.media_count,
        "status": b.status,
    } for b in backups]
