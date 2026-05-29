"""
Crash & performance diagnostics — receives MetricKit / CrashGuard reports
from the iOS client.

iOS sends a payload like:
    {
      "type": "crash" | "hang" | "disk" | "cpu" | "exception",
      "occurred_at": "2026-04-30T22:00:00Z",
      "app_version": "1.4 (123)",
      "os_version": "iOS 26.4",
      "device_model": "iPhone17,1",
      "session_id": "...",
      "summary": "short human-readable description",
      "payload_b64": "...",   # gzipped MXDiagnostic payload (optional)
    }

We store it in `crash_reports` for later querying (`SELECT … WHERE
type = 'crash' AND occurred_at > NOW() - interval '24 hours'`).
"""
import base64
import uuid
import json
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import Column, String, DateTime, Integer, Text
from sqlalchemy.orm import Session

from database import get_db, Base
from models import User
from routers.users import get_current_user

router = APIRouter(prefix="/api/diagnostics", tags=["diagnostics"])


class CrashReport(Base):
    __tablename__ = "crash_reports"
    id = Column(String, primary_key=True)
    user_id = Column(String, nullable=True, index=True)
    type = Column(String, nullable=False, index=True)
    occurred_at = Column(DateTime, nullable=False, index=True)
    received_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    app_version = Column(String, nullable=True)
    os_version = Column(String, nullable=True)
    device_model = Column(String, nullable=True)
    session_id = Column(String, nullable=True)
    summary = Column(String, nullable=True)
    payload_size = Column(Integer, default=0)  # raw bytes after b64-decode
    payload = Column(Text, nullable=True)      # JSON string, optional


# ────────────────────────────────────────────────────────────────────

class DiagnosticPayload(BaseModel):
    type: str
    occurredAt: datetime
    appVersion: Optional[str] = None
    osVersion: Optional[str] = None
    deviceModel: Optional[str] = None
    sessionId: Optional[str] = None
    summary: Optional[str] = None
    payloadB64: Optional[str] = None


@router.post("")
def submit_diagnostic(
    body: DiagnosticPayload,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    if body.type not in {"crash", "hang", "disk", "cpu", "exception"}:
        raise HTTPException(status_code=400, detail="Unsupported diagnostic type")

    payload_str: Optional[str] = None
    payload_size = 0
    if body.payloadB64:
        try:
            raw = base64.b64decode(body.payloadB64)
            payload_size = len(raw)
            # Cap stored payload at 1 MB to keep DB rows bounded
            if payload_size > 1_000_000:
                raise HTTPException(status_code=413, detail="Diagnostic payload too large")
            try:
                payload_str = raw.decode("utf-8")
                # Validate it's JSON; if not, store as-is
                json.loads(payload_str)
            except (UnicodeDecodeError, json.JSONDecodeError):
                payload_str = body.payloadB64  # fall back to opaque
        except Exception:
            raise HTTPException(status_code=400, detail="Invalid payloadB64")

    row = CrashReport(
        id=str(uuid.uuid4()),
        user_id=current_user.id,
        type=body.type,
        occurred_at=body.occurredAt,
        app_version=body.appVersion,
        os_version=body.osVersion,
        device_model=body.deviceModel,
        session_id=body.sessionId,
        summary=(body.summary or "")[:500],
        payload_size=payload_size,
        payload=payload_str,
    )
    db.add(row)
    db.commit()
    return {"status": "received", "id": row.id}
