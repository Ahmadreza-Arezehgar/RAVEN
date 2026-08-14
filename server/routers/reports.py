"""
Reports Router — Full moderation lifecycle.
Supports: 8 target types, 11 reasons, AI triage, decision, appeal, and audit log.

User endpoints:
  POST   /api/reports              — Submit a report
  GET    /api/reports/reasons      — Dynamic reason list
  GET    /api/reports/my-reports   — Reports I submitted
  GET    /api/reports/my-actions   — Decisions affecting me (Statement of Reasons)
  POST   /api/reports/{id}/appeal  — Appeal a decision

Admin endpoints:
  GET    /api/reports/admin/queue          — Filterable triage queue
  GET    /api/reports/admin/{id}           — Full report detail
  POST   /api/reports/admin/{id}/decision  — Record decision + action
  POST   /api/reports/admin/{id}/appeal    — Accept/reject appeal
  PATCH  /api/reports/admin/{id}           — Update status
  GET    /api/reports/admin/stats          — Dashboard stats
  GET    /api/reports/admin/actions        — Audit log
"""

from fastapi import APIRouter, Depends, HTTPException, status, BackgroundTasks
from sqlalchemy.orm import Session
from sqlalchemy import and_, func
from pydantic import BaseModel
from typing import Optional
from datetime import datetime, timedelta
import uuid as uuid_mod
import json

from database import get_db
from auth import get_current_user
from models import User, Report, HiddenContent, ModerationAction


router = APIRouter(prefix="/api/reports", tags=["reports"])


# ==================== CONSTANTS ====================

VALID_TARGET_TYPES = [
    "user", "post", "comment", "message",
    "group", "room", "story", "media"
]

REPORT_REASONS = [
    {"code": "spam", "label": "Spam / Scam", "icon": "envelope.badge.fill", "applies_to": ["user", "post", "comment", "message", "group", "room", "story", "media"]},
    {"code": "harassment", "label": "Harassment / Bullying", "icon": "person.fill.xmark", "applies_to": ["user", "post", "comment", "message", "group", "room", "story"]},
    {"code": "hate_speech", "label": "Hate Speech", "icon": "exclamationmark.bubble.fill", "applies_to": ["user", "post", "comment", "message", "group", "room", "story"]},
    {"code": "violence", "label": "Violence / Dangerous Content", "icon": "flame.fill", "applies_to": ["post", "comment", "message", "story", "media"]},
    {"code": "nudity", "label": "Nudity / Sexual Content", "icon": "eye.slash.fill", "applies_to": ["post", "comment", "message", "story", "media"]},
    {"code": "illegal", "label": "Illegal Content", "icon": "hand.raised.fill", "applies_to": ["post", "comment", "message", "group", "room", "story", "media"]},
    {"code": "impersonation", "label": "Impersonation", "icon": "person.2.fill", "applies_to": ["user", "group", "room"]},
    {"code": "privacy", "label": "Privacy Violation", "icon": "lock.slash.fill", "applies_to": ["post", "comment", "message", "story", "media"]},
    {"code": "self_harm", "label": "Self-harm / Suicide", "icon": "heart.slash.fill", "applies_to": ["post", "comment", "message", "story"]},
    {"code": "false_info", "label": "False Information", "icon": "xmark.seal.fill", "applies_to": ["post", "comment", "message"]},
    {"code": "other", "label": "Other", "icon": "ellipsis.circle.fill", "applies_to": ["user", "post", "comment", "message", "group", "room", "story", "media"]},
]

VALID_REASON_CODES = [r["code"] for r in REPORT_REASONS]

VALID_DECISIONS = ["none", "warn", "remove_content", "restrict", "tempban", "ban", "mute", "shadowban"]
VALID_STATUSES = ["open", "triaged", "escalated", "actioned", "dismissed"]


# ==================== SCHEMAS ====================

class ReportCreate(BaseModel):
    target_type: str
    target_id: str
    reported_user_id: Optional[str] = None
    reason: str
    note: Optional[str] = None
    evidence: Optional[list] = None  # List of screenshot URLs / file IDs
    context: Optional[dict] = None

class ReportResponse(BaseModel):
    id: str
    target_type: str
    target_id: str
    reason: str
    note: Optional[str]
    status: str
    created_at: datetime
    
    class Config:
        from_attributes = True

class DecisionCreate(BaseModel):
    decision: str          # warn, remove_content, restrict, tempban, ban, mute, shadowban
    decision_reason: str   # Statement of Reasons text
    parameters: Optional[dict] = None  # {duration: "7d", ...}

class AppealCreate(BaseModel):
    text: str

class AppealDecision(BaseModel):
    accepted: bool
    reason: Optional[str] = None

class ReportStatusUpdate(BaseModel):
    status: str


# ==================== USER ENDPOINTS ====================

@router.get("/reasons")
async def get_report_reasons(object_type: Optional[str] = None):
    """
    Get available report reasons, optionally filtered by object_type.
    This allows the iOS client to dynamically display reasons without hardcoding.
    """
    if object_type:
        if object_type not in VALID_TARGET_TYPES:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid object_type. Must be one of: {VALID_TARGET_TYPES}"
            )
        return [r for r in REPORT_REASONS if object_type in r["applies_to"]]
    
    return REPORT_REASONS


@router.post("", response_model=ReportResponse, status_code=status.HTTP_201_CREATED)
async def submit_report(
    report: ReportCreate,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Submit a report for any content type.
    After report: content hidden for reporter + AI triage enqueued.
    """
    # Validate target_type
    if report.target_type not in VALID_TARGET_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid target_type. Must be one of: {VALID_TARGET_TYPES}"
        )
    
    # Validate reason
    if report.reason not in VALID_REASON_CODES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid reason. Must be one of: {VALID_REASON_CODES}"
        )
    
    # 🔴 ROUND 71 phase 3: self-report guard moved BELOW
    # resolved_reported_user_id resolution. The pre-fix guard
    # only triggered for `target_type == "user"`; a user could
    # still report their own post/comment/message/group.

    # 🔴 ROUND 71 phase 3 — duplicate guard scoped to a time
    # window AND non-dismissed status. Previously this query was
    # permanent + global: a single report locked the user out of
    # EVER reporting the same target again, even if the offender
    # re-offended years later or the original report was
    # dismissed. Now we only block re-reports within the last 30
    # days that aren't `dismissed` — accepted appeals set
    # report.status back to "dismissed" (see
    # admin_appeal_decision), so re-reports of vindicated targets
    # are also unblocked. Legitimate re-reports against repeat
    # offenders can land.
    from datetime import timedelta as _td
    _now = datetime.utcnow()
    _dedupe_window = _now - _td(days=30)
    recent = db.query(Report).filter(
        and_(
            Report.reporter_id == current_user.id,
            Report.target_type == report.target_type,
            Report.target_id == report.target_id,
            Report.created_at >= _dedupe_window,
            Report.status != "dismissed",
        )
    ).first()

    if recent:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="You have already reported this content recently."
        )
    
    # Rate limiting: max 5 reports/hour, 20 reports/day
    from datetime import timedelta
    now = datetime.utcnow()
    hourly_count = db.query(Report).filter(
        Report.reporter_id == current_user.id,
        Report.created_at >= now - timedelta(hours=1)
    ).count()
    if hourly_count >= 5:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many reports. Please wait before submitting another."
        )
    
    daily_count = db.query(Report).filter(
        Report.reporter_id == current_user.id,
        Report.created_at >= now - timedelta(hours=24)
    ).count()
    if daily_count >= 20:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Daily report limit reached. Please try again tomorrow."
        )
    
    # 🔴 hacker-audit 2026-05-20 — derive reported_user_id server-side
    # from the target's real owner; never trust the client value
    # (a spoofed one gets an innocent third party banned).
    resolved_reported_user_id = _resolve_reported_user_id(
        db, report.target_type, report.target_id
    )

    # 🔴 ROUND 71 phase 3 — broaden self-report guard. The original
    # check only blocked `target_type == "user"`, but the same user
    # could still report their own post/comment/message/group via
    # those other target types. Reject if the resolved owner of the
    # target is the caller — works for every target_type.
    if (
        resolved_reported_user_id is not None
        and resolved_reported_user_id == current_user.id
    ):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You cannot report your own content.",
        )

    # Create report
    report_id = str(uuid_mod.uuid4())
    db_report = Report(
        id=report_id,
        reporter_id=current_user.id,
        target_type=report.target_type,
        target_id=report.target_id,
        reported_user_id=resolved_reported_user_id,
        reason=report.reason,
        note=report.note,
        evidence_json=json.dumps(report.evidence) if report.evidence else None,
        context_json=json.dumps(report.context) if report.context else None,
        status="open"
    )
    
    db.add(db_report)
    
    # Auto-hide content for the reporter
    _hide_content_for_user(
        db=db,
        user_id=current_user.id,
        object_type=report.target_type,
        object_id=report.target_id,
        reason="reported"
    )
    
    db.commit()
    db.refresh(db_report)
    
    print(f"📢 [Report] {current_user.username}: {report.target_type}/{report.target_id} — {report.reason}")
    
    # Enqueue AI triage (runs in background — non-blocking)
    background_tasks.add_task(_run_triage, report_id)
    
    return db_report


@router.get("/my-reports")
async def get_my_reports(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """Get reports submitted by the current user."""
    reports = db.query(Report).filter(
        Report.reporter_id == current_user.id
    ).order_by(Report.created_at.desc()).limit(50).all()
    
    return [
        {
            "id": r.id,
            "target_type": r.target_type,
            "target_id": r.target_id,
            "reason": r.reason,
            "status": r.status,
            "decision": r.decision,
            "created_at": r.created_at.isoformat()
        }
        for r in reports
    ]


@router.get("/my-actions")
async def get_my_actions(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Get moderation decisions affecting the current user (Statement of Reasons — DSA Art. 17).
    Returns actioned reports where the user is the target/owner of reported content.
    """
    reports = db.query(Report).filter(
        Report.reported_user_id == current_user.id,
        Report.decision != "none"
    ).order_by(Report.decided_at.desc()).limit(50).all()
    
    return [
        {
            "id": r.id,
            "target_type": r.target_type,
            "target_id": r.target_id,
            "reason": r.reason,
            "decision": r.decision,
            "decision_reason": r.decision_reason,
            "decided_at": r.decided_at.isoformat() if r.decided_at else None,
            "appeal_status": r.appeal_status,
            "can_appeal": r.appeal_status == "none" and r.decision != "none"
        }
        for r in reports
    ]


@router.post("/{report_id}/appeal")
async def submit_appeal(
    report_id: str,
    appeal: AppealCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Appeal a moderation decision (DSA Article 20 — internal complaint handling).
    Only the affected user can appeal. Must have a decision and no existing appeal.
    """
    report = db.query(Report).filter(Report.id == report_id).first()
    # 🔴 hacker-audit 2026-05-20 — identical 404 for "not found" and
    # "not yours" so this endpoint can't be probed as an oracle to
    # confirm which report_ids exist or who they target.
    if not report or report.reported_user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Report not found")
    
    # Must have a decision to appeal
    if report.decision == "none":
        raise HTTPException(status_code=400, detail="No decision to appeal")
    
    # Can't appeal twice
    if report.appeal_status != "none":
        raise HTTPException(status_code=400, detail="Appeal already submitted")
    
    # Validate text
    if not appeal.text or len(appeal.text.strip()) < 10:
        raise HTTPException(status_code=400, detail="Appeal text must be at least 10 characters")
    
    report.appeal_status = "pending"
    report.appeal_text = appeal.text.strip()
    db.commit()
    
    print(f"📝 [Appeal] User {current_user.username} appealed report {report_id[:8]}")
    return {"message": "Appeal submitted", "appeal_status": "pending"}


# ==================== ADMIN ENDPOINTS ====================

# 🔴 hacker-audit 2026-05-19 — username-based admin gate is fragile.
#
# PREVIOUSLY `is_admin` granted admin powers based on a hardcoded
# list of USERNAMES. Three concrete failure modes:
#   1. If the iOS PATCH /me endpoint ever allowed username changes
#      (it does — line 640 of users.py), a regular user could
#      register, then RENAME themselves to "Raven-messenger" if
#      that handle was ever free (e.g. after the real account got
#      banned/deleted), and instantly inherit moderation powers.
#      Username collision uniqueness check exists, but doesn't help
#      if the real account is gone.
#   2. Compromise of one of those three accounts (password reuse,
#      phishing, lost device) gives a full takeover of moderation —
#      not just one user's inbox.
#   3. Confusable / homoglyph attack: register username with
#      `ABBASBAZAR` using Cyrillic А (U+0410), pass the equality
#      check at the DB layer if collation is locale-sensitive. The
#      Python `in` here is byte-equality so this one is safe today
#      but the code shape encourages bugs.
#
# Fix is operational, not just code:
#   • Source of truth is `ADMIN_USER_IDS` populated from the
#     `RAVEN_ADMIN_USER_IDS` env var (comma-separated UUIDs).
#     Empty by default — admin actions just refuse.
#   • Username list kept ONLY as a bootstrap shim and gated behind
#     `ALLOW_USERNAME_ADMIN=1` env var so production explicitly
#     opts out and the username path is dead in normal deploys.
import os as _os_for_admin

_ADMIN_USER_IDS_ENV = _os_for_admin.getenv("RAVEN_ADMIN_USER_IDS", "")
ADMIN_USER_IDS = [u.strip() for u in _ADMIN_USER_IDS_ENV.split(",") if u.strip()]
_ALLOW_USERNAME_ADMIN = _os_for_admin.getenv("ALLOW_USERNAME_ADMIN", "0").lower() in ("1", "true", "yes")
_LEGACY_ADMIN_USERNAMES = {"ABBASBAZAR", "MAHLAMOHAMMADREZA2005", "Raven-messenger"}


def is_admin(user: User) -> bool:
    """Check if user is an admin (by user-id env list)."""
    if user.id in ADMIN_USER_IDS:
        return True
    if _ALLOW_USERNAME_ADMIN and user.username in _LEGACY_ADMIN_USERNAMES:
        # Legacy fallback — explicit opt-in via env var.
        return True
    return False


@router.get("/admin/queue")
async def get_moderation_queue(
    status_filter: Optional[str] = None,
    target_type: Optional[str] = None,
    min_severity: Optional[int] = None,
    ai_category: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """[Admin] Filterable moderation queue sorted by priority."""
    if not is_admin(current_user):
        raise HTTPException(status_code=403, detail="Admin access required")
    
    query = db.query(Report)
    
    if status_filter:
        query = query.filter(Report.status == status_filter)
    if target_type:
        query = query.filter(Report.target_type == target_type)
    if min_severity is not None:
        query = query.filter(Report.ai_severity >= min_severity)
    if ai_category:
        query = query.filter(Report.ai_category == ai_category)
    
    # Sort: escalated first, then by severity desc, then by date
    reports = query.order_by(
        # Escalated reports first
        (Report.status == "escalated").desc(),
        # Then by severity (highest first)
        Report.ai_severity.desc().nullslast(),
        # Then by date
        Report.created_at.desc()
    ).offset(offset).limit(limit).all()
    
    result = []
    for r in reports:
        reporter = db.query(User).filter(User.id == r.reporter_id).first()
        reported = db.query(User).filter(User.id == r.reported_user_id).first() if r.reported_user_id else None
        
        result.append({
            "id": r.id,
            "reporter_username": reporter.username if reporter else "Unknown",
            "reported_username": reported.username if reported else None,
            "target_type": r.target_type,
            "target_id": r.target_id,
            "reason": r.reason,
            "note": r.note,
            "status": r.status,
            "ai_category": r.ai_category,
            "ai_severity": r.ai_severity,
            "ai_confidence": r.ai_confidence,
            "ai_summary": r.ai_summary,
            "decision": r.decision,
            "appeal_status": r.appeal_status,
            "created_at": r.created_at.isoformat(),
            "triaged_at": r.triaged_at.isoformat() if r.triaged_at else None
        })
    
    return result


@router.get("/admin/stats")
async def get_report_stats(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """[Admin] Dashboard statistics."""
    if not is_admin(current_user):
        raise HTTPException(status_code=403, detail="Admin access required")
    
    total = db.query(Report).count()
    
    by_status = {}
    for s in VALID_STATUSES:
        by_status[s] = db.query(Report).filter(Report.status == s).count()
    
    by_reason = {}
    for r in VALID_REASON_CODES:
        count = db.query(Report).filter(Report.reason == r).count()
        if count > 0:
            by_reason[r] = count
    
    by_type = {}
    for t in VALID_TARGET_TYPES:
        count = db.query(Report).filter(Report.target_type == t).count()
        if count > 0:
            by_type[t] = count
    
    by_decision = {}
    for d in VALID_DECISIONS:
        count = db.query(Report).filter(Report.decision == d).count()
        if count > 0:
            by_decision[d] = count
    
    pending_appeals = db.query(Report).filter(Report.appeal_status == "pending").count()
    
    return {
        "total": total,
        "by_status": by_status,
        "by_reason": by_reason,
        "by_type": by_type,
        "by_decision": by_decision,
        "pending_appeals": pending_appeals
    }


@router.get("/admin/actions")
async def get_audit_log(
    limit: int = 100,
    offset: int = 0,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """[Admin] Full audit log of all moderation actions."""
    if not is_admin(current_user):
        raise HTTPException(status_code=403, detail="Admin access required")
    
    actions = db.query(ModerationAction).order_by(
        ModerationAction.timestamp.desc()
    ).offset(offset).limit(limit).all()
    
    return [
        {
            "id": a.id,
            "report_id": a.report_id,
            "target_type": a.target_type,
            "target_id": a.target_id,
            "action_type": a.action_type,
            "parameters": json.loads(a.parameters_json) if a.parameters_json else None,
            "actor": a.actor,
            "timestamp": a.timestamp.isoformat(),
            "reversible": a.reversible,
            "reversed_at": a.reversed_at.isoformat() if a.reversed_at else None,
            "reversed_by": a.reversed_by
        }
        for a in actions
    ]


@router.get("/admin/{report_id}")
async def get_report_detail(
    report_id: str,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """[Admin] Full report detail with AI triage, context, and decision history."""
    if not is_admin(current_user):
        raise HTTPException(status_code=403, detail="Admin access required")
    
    report = db.query(Report).filter(Report.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    
    reporter = db.query(User).filter(User.id == report.reporter_id).first()
    reported = db.query(User).filter(User.id == report.reported_user_id).first() if report.reported_user_id else None
    
    # Fetch related moderation actions
    actions = db.query(ModerationAction).filter(
        ModerationAction.report_id == report.id
    ).order_by(ModerationAction.timestamp.desc()).all()
    
    # Fetch target info
    target_info = _fetch_target_info(db, report.target_type, report.target_id)
    
    return {
        "id": report.id,
        "reporter": {
            "id": reporter.id if reporter else None,
            "username": reporter.username if reporter else "Unknown"
        },
        "reported_user": {
            "id": reported.id if reported else None,
            "username": reported.username if reported else None
        } if reported else None,
        "target_type": report.target_type,
        "target_id": report.target_id,
        "target_info": target_info,
        "reason": report.reason,
        "note": report.note,
        "evidence": json.loads(report.evidence_json) if report.evidence_json else None,
        "context": json.loads(report.context_json) if report.context_json else None,
        "status": report.status,
        "created_at": report.created_at.isoformat(),
        # AI Triage
        "ai_category": report.ai_category,
        "ai_severity": report.ai_severity,
        "ai_confidence": report.ai_confidence,
        "ai_summary": report.ai_summary,
        "triaged_at": report.triaged_at.isoformat() if report.triaged_at else None,
        # Decision
        "decision": report.decision,
        "decision_reason": report.decision_reason,
        "decided_by": report.decided_by,
        "decided_at": report.decided_at.isoformat() if report.decided_at else None,
        # Appeal
        "appeal_status": report.appeal_status,
        "appeal_text": report.appeal_text,
        "appeal_decided_by": report.appeal_decided_by,
        "appeal_decided_at": report.appeal_decided_at.isoformat() if report.appeal_decided_at else None,
        # Audit log
        "actions": [
            {
                "id": a.id,
                "action_type": a.action_type,
                "actor": a.actor,
                "timestamp": a.timestamp.isoformat(),
                "reversed": a.reversed_at is not None
            }
            for a in actions
        ]
    }


@router.post("/admin/{report_id}/decision")
async def admin_decision(
    report_id: str,
    decision: DecisionCreate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    [Admin] Record a moderation decision.
    Creates audit log entry and executes side-effects (content removal, user restriction, etc.)
    """
    if not is_admin(current_user):
        raise HTTPException(status_code=403, detail="Admin access required")
    
    if decision.decision not in VALID_DECISIONS:
        raise HTTPException(status_code=400, detail=f"Invalid decision. Must be one of: {VALID_DECISIONS}")
    
    if not decision.decision_reason or len(decision.decision_reason.strip()) < 5:
        raise HTTPException(status_code=400, detail="Decision reason is required (Statement of Reasons)")
    
    report = db.query(Report).filter(Report.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    # 🔴 ROUND 71 phase 3 — decision idempotency. Previously a
    # second POST against an already-decided report re-ran the side-
    # effects: re-banned, reset `banned_at`, re-created a
    # moderation_decision Notification, and appended another
    # ModerationAction row. Reject re-apply unless the admin
    # explicitly passes `parameters.override = true`.
    _override = bool((decision.parameters or {}).get("override", False))
    if report.decision and report.decision != "none" and not _override:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Report already actioned with '{report.decision}'. "
                "Pass parameters.override=true to re-decide."
            ),
        )

    # Update report
    report.decision = decision.decision
    report.decision_reason = decision.decision_reason.strip()
    report.decided_by = current_user.id
    report.decided_at = datetime.utcnow()
    report.status = "actioned" if decision.decision != "none" else "dismissed"
    
    # Create audit log entry
    action = ModerationAction(
        id=str(uuid_mod.uuid4()),
        report_id=report.id,
        target_type=report.target_type,
        target_id=report.target_id,
        action_type=decision.decision,
        parameters_json=json.dumps(decision.parameters) if decision.parameters else None,
        actor=current_user.id,
        reversible=decision.decision not in ["ban"]  # Permanent bans are harder to reverse
    )
    db.add(action)
    
    # Execute side-effects
    _execute_decision(db, report, decision.decision, decision.parameters)
    
    # Create notification for the reported user (Statement of Reasons)
    if report.reported_user_id:
        from models import Notification
        notif = Notification(
            id=str(uuid_mod.uuid4()),
            user_id=report.reported_user_id,
            type="moderation_decision",
            data=json.dumps({
                "report_id": report.id,
                "decision": decision.decision,
                "reason": decision.decision_reason.strip()[:200],
                "target_type": report.target_type,
                "target_id": report.target_id
            })
        )
        db.add(notif)
    
    db.commit()
    
    print(f"⚖️ [Decision] Admin {current_user.username}: {decision.decision} on {report.target_type}/{report.target_id[:8]} — {decision.decision_reason[:50]}")
    return {"message": "Decision recorded", "decision": decision.decision, "status": report.status}


@router.post("/admin/{report_id}/appeal")
async def admin_appeal_decision(
    report_id: str,
    appeal_decision: AppealDecision,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """[Admin] Accept or reject an appeal."""
    if not is_admin(current_user):
        raise HTTPException(status_code=403, detail="Admin access required")
    
    report = db.query(Report).filter(Report.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    
    if report.appeal_status != "pending":
        raise HTTPException(status_code=400, detail="No pending appeal")
    
    if appeal_decision.accepted:
        # Accept appeal — reverse the action
        report.appeal_status = "accepted"
        report.appeal_decided_by = current_user.id
        report.appeal_decided_at = datetime.utcnow()
        report.status = "dismissed"
        
        # Reverse moderation actions
        actions = db.query(ModerationAction).filter(
            ModerationAction.report_id == report.id,
            ModerationAction.reversed_at.is_(None),
            ModerationAction.reversible == True
        ).all()
        
        for action in actions:
            action.reversed_at = datetime.utcnow()
            action.reversed_by = current_user.id
        
        # Create reversal audit entry
        reversal = ModerationAction(
            id=str(uuid_mod.uuid4()),
            report_id=report.id,
            target_type=report.target_type,
            target_id=report.target_id,
            action_type="reverse",
            parameters_json=json.dumps({"reason": "appeal_accepted", "original_decision": report.decision}),
            actor=current_user.id,
            reversible=False
        )
        db.add(reversal)
        
        # Reverse side-effects
        _reverse_decision(db, report)
        
        report.decision = "none"
        
        print(f"✅ [Appeal] ACCEPTED by {current_user.username} for report {report_id[:8]}")
    else:
        # Reject appeal
        report.appeal_status = "rejected"
        report.appeal_decided_by = current_user.id
        report.appeal_decided_at = datetime.utcnow()
        
        print(f"❌ [Appeal] REJECTED by {current_user.username} for report {report_id[:8]}")
    
    db.commit()
    return {"message": f"Appeal {'accepted' if appeal_decision.accepted else 'rejected'}", "appeal_status": report.appeal_status}


@router.patch("/admin/{report_id}")
async def update_report_status(
    report_id: str,
    update: ReportStatusUpdate,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """[Admin] Update the status of a report."""
    if not is_admin(current_user):
        raise HTTPException(status_code=403, detail="Admin access required")
    
    if update.status not in VALID_STATUSES:
        raise HTTPException(status_code=400, detail=f"Invalid status. Must be one of: {VALID_STATUSES}")
    
    report = db.query(Report).filter(Report.id == report_id).first()
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    
    old_status = report.status
    report.status = update.status
    db.commit()
    
    print(f"📋 [Admin] Report {report_id[:8]}: {old_status} → {update.status} (by {current_user.username})")
    return {"message": "Report status updated", "new_status": update.status}


# ==================== HELPERS ====================

def _hide_content_for_user(db: Session, user_id: str, object_type: str, object_id: str, reason: str = "reported"):
    """Hide a piece of content from a specific user."""
    existing = db.query(HiddenContent).filter(
        HiddenContent.user_id == user_id,
        HiddenContent.object_type == object_type,
        HiddenContent.object_id == object_id
    ).first()
    
    if not existing:
        hidden = HiddenContent(
            id=str(uuid_mod.uuid4()),
            user_id=user_id,
            object_type=object_type,
            object_id=object_id,
            reason=reason
        )
        db.add(hidden)


def get_hidden_ids(db: Session, user_id: str, object_type: str) -> list:
    """Get list of hidden object IDs for a user and type."""
    return [
        h.object_id for h in
        db.query(HiddenContent.object_id).filter(
            HiddenContent.user_id == user_id,
            HiddenContent.object_type == object_type
        ).all()
    ]


def _resolve_reported_user_id(db: Session, target_type: str, target_id: str) -> Optional[str]:
    """🔴 hacker-audit 2026-05-20 — derive the reported user from the target.

    PREVIOUSLY submit_report stored the client-supplied
    reported_user_id verbatim, so an attacker could report some
    innocuous object but name a DIFFERENT victim as reported_user_id —
    and every moderation action (ban/tempban/restrict/mute) runs
    against report.reported_user_id. That let an attacker get an
    arbitrary user banned. The owner is now resolved server-side from
    the reported object; the client-supplied value is ignored.
    """
    try:
        if target_type == "user":
            return target_id
        if target_type == "post":
            from models import Post
            row = db.query(Post).filter(Post.id == target_id).first()
            return row.author_id if row else None
        if target_type == "comment":
            # 🔒 SECURITY (audit PB-H3): the model is `Comment`, not
            # `PostComment`. The wrong name raised ImportError (swallowed
            # by the except below) so the owner never resolved,
            # reported_user_id stayed NULL, and EVERY admin moderation
            # branch on a reported comment silently no-op'd (ban/tempban/
            # restrict/mute/warn/shadowban), plus the self-report guard
            # was bypassed for comments.
            from models import Comment
            row = db.query(Comment).filter(Comment.id == target_id).first()
            if not row:
                return None
            return getattr(row, "author_id", None) or getattr(row, "user_id", None)
        if target_type == "message":
            from models import Message
            row = db.query(Message).filter(Message.id == target_id).first()
            return row.sender_id if row else None
        if target_type == "group":
            from models import Group
            row = db.query(Group).filter(Group.id == target_id).first()
            return getattr(row, "created_by", None) if row else None
        if target_type == "room":
            from models import AudioRoom
            row = db.query(AudioRoom).filter(AudioRoom.id == target_id).first()
            return getattr(row, "host_user_id", None) if row else None
    except Exception as e:
        print(f"⚠️ [Report] reported_user resolve failed: {e}")
    # story / media / unknown — no clean owner; leave unset so no
    # user-level action is auto-applied (admin reviews manually).
    return None


def _fetch_target_info(db: Session, target_type: str, target_id: str) -> dict:
    """Fetch displayable info about the reported target (for admin review)."""
    try:
        if target_type == "user":
            user = db.query(User).filter(User.id == target_id).first()
            if user:
                return {
                    "username": user.username,
                    "display_name": user.display_name,
                    "bio": user.bio,
                    "created_at": user.created_at.isoformat() if user.created_at else None
                }
        elif target_type == "post":
            from models import Post
            from encryption import decrypt_text
            post = db.query(Post).filter(Post.id == target_id).first()
            if post:
                # 🔒 (audit PB-H3): content is AES-GCM/Fernet at rest —
                # decrypt so admins review the actual text, not ciphertext.
                _c = None
                if post.content:
                    try:
                        _c = decrypt_text(post.content)[:500]
                    except Exception:
                        _c = None
                return {
                    "content": _c,
                    "author_id": post.author_id,
                }
        elif target_type == "comment":
            # 🔒 (audit PB-H3): correct model is `Comment`; decrypt too.
            from models import Comment
            from encryption import decrypt_text
            comment = db.query(Comment).filter(Comment.id == target_id).first()
            if comment:
                _c = None
                if comment.content:
                    try:
                        _c = decrypt_text(comment.content)[:500]
                    except Exception:
                        _c = None
                return {"content": _c, "author_id": getattr(comment, "author_id", None)}
    except Exception as e:
        print(f"⚠️ [Report] Error fetching target info: {e}")
    
    return {}


def _execute_decision(db: Session, report: Report, decision: str, parameters: dict = None):
    """Execute side-effects for a moderation decision."""
    try:
        if decision == "remove_content":
            # Actually delete content from the database (hard delete + full cascade)
            if report.target_type == "post":
                from models import (Post, Comment, PostLike, Repost, PostView, PostMedia,
                                    ContentConsumption, Notification, CommentVote, SeenPost,
                                    Mention, UserEvent, MeshViewReceipt)
                post = db.query(Post).filter(Post.id == report.target_id).first()
                if post:
                    # Delete ALL related records first (full cascade — matches delete_post)
                    # 1. CommentVotes on this post's comments
                    comment_ids = [c.id for c in db.query(Comment.id).filter(Comment.post_id == report.target_id).all()]
                    if comment_ids:
                        db.query(CommentVote).filter(CommentVote.comment_id.in_(comment_ids)).delete(synchronize_session=False)
                    # 2. Comments
                    db.query(Comment).filter(Comment.post_id == report.target_id).delete(synchronize_session=False)
                    # 3. Mentions
                    db.query(Mention).filter(Mention.post_id == report.target_id).delete(synchronize_session=False)
                    # 4. User events
                    db.query(UserEvent).filter(UserEvent.post_id == report.target_id).delete(synchronize_session=False)
                    # 5. Seen/consumption records
                    db.query(SeenPost).filter(SeenPost.post_id == report.target_id).delete(synchronize_session=False)
                    db.query(ContentConsumption).filter(
                        ContentConsumption.content_id == report.target_id,
                        ContentConsumption.content_type == "post"
                    ).delete(synchronize_session=False)
                    # 6. Mesh view receipts
                    db.query(MeshViewReceipt).filter(MeshViewReceipt.post_id == report.target_id).delete(synchronize_session=False)
                    # 7. Post interactions
                    db.query(PostLike).filter(PostLike.post_id == report.target_id).delete(synchronize_session=False)
                    db.query(Repost).filter(Repost.original_post_id == report.target_id).delete(synchronize_session=False)
                    db.query(PostView).filter(PostView.post_id == report.target_id).delete(synchronize_session=False)
                    # 8. Media
                    db.query(PostMedia).filter(PostMedia.post_id == report.target_id).delete(synchronize_session=False)
                    # 9. Hidden content records
                    db.query(HiddenContent).filter(
                        HiddenContent.object_type == "post",
                        HiddenContent.object_id == report.target_id
                    ).delete(synchronize_session=False)
                    # 10. Notifications referencing this post
                    try:
                        notifs = db.query(Notification).filter(
                            Notification.data.like(f'%{report.target_id}%')
                        ).all()
                        for n in notifs:
                            db.delete(n)
                    except Exception as e:
                        print(f"⚠️ [Moderation] Notification cleanup warning: {e}")
                    db.delete(post)
                    print(f"🗑️ [Moderation] Permanently deleted post {report.target_id[:8]} with full cascade")
            elif report.target_type == "comment":
                from models import Comment
                comment = db.query(Comment).filter(Comment.id == report.target_id).first()
                if comment:
                    db.delete(comment)
                    print(f"🗑️ [Moderation] Permanently deleted comment {report.target_id[:8]}...")
        
        elif decision == "restrict":
            # User restriction (e.g., can't post for N days)
            if report.reported_user_id:
                user = db.query(User).filter(User.id == report.reported_user_id).first()
                if user:
                    user.is_restricted = True
                    duration = (parameters or {}).get("duration", "7d")
                    days = int(duration.replace("d", "")) if "d" in str(duration) else 7
                    user.restricted_until = datetime.utcnow() + timedelta(days=days)
                    user.restriction_scope = (parameters or {}).get("scope", "posting")
        
        elif decision == "tempban":
            # Temporary ban
            if report.reported_user_id:
                user = db.query(User).filter(User.id == report.reported_user_id).first()
                if user:
                    user.is_banned = True
                    user.banned_at = datetime.utcnow()
                    user.ban_reason = report.decision_reason
                    duration = (parameters or {}).get("duration", "30d")
                    days = int(duration.replace("d", "")) if "d" in str(duration) else 30
                    user.restricted_until = datetime.utcnow() + timedelta(days=days)
        
        elif decision == "ban":
            # Permanent ban
            if report.reported_user_id:
                user = db.query(User).filter(User.id == report.reported_user_id).first()
                if user:
                    user.is_banned = True
                    user.banned_at = datetime.utcnow()
                    user.ban_reason = report.decision_reason
        
        elif decision == "warn":
            # Create an in-app warning notification
            if report.reported_user_id:
                from models import Notification
                warning = Notification(
                    id=str(uuid_mod.uuid4()),
                    user_id=report.reported_user_id,
                    type="moderation_warning",
                    data=json.dumps({
                        "report_id": report.id,
                        "message": "Your content has been flagged for violating community guidelines. Further violations may result in restrictions.",
                        "target_type": report.target_type,
                        "target_id": report.target_id
                    })
                )
                db.add(warning)
        
        elif decision == "mute":
            # Restrict posting ability
            if report.reported_user_id:
                user = db.query(User).filter(User.id == report.reported_user_id).first()
                if user:
                    user.is_restricted = True
                    duration = (parameters or {}).get("duration", "7d")
                    days = int(duration.replace("d", "")) if "d" in str(duration) else 7
                    user.restricted_until = datetime.utcnow() + timedelta(days=days)
                    user.restriction_scope = "posting"
        
        elif decision == "shadowban":
            # User can post but content is hidden from others
            if report.reported_user_id:
                user = db.query(User).filter(User.id == report.reported_user_id).first()
                if user:
                    user.is_restricted = True
                    user.restriction_scope = "visibility"
        
    except Exception as e:
        print(f"⚠️ [Decision] Error executing side-effect '{decision}': {e}")


def _reverse_decision(db: Session, report: Report):
    """Reverse side-effects when an appeal is accepted.

    🔴 ROUND 71 phase 3 — scoped reversal. Previously this function
    blanket-cleared `is_hidden` on the target post/comment AND every
    user-level sanction (`is_banned`, `is_restricted`, `ban_reason`,
    …). If a user had been sanctioned by *another* actioned report,
    accepting an appeal on report A wiped sanctions from report B
    too — a single accepted appeal fully reset the user even when
    unrelated reports were still standing.

    The fix: before clearing each side-effect, check for OTHER
    actioned reports that still justify it. Only clear when this is
    the last active sanction.
    """
    try:
        # Per-content reversal (`is_hidden`): un-hide only if no
        # OTHER actioned report against this same target still
        # demands it.
        _content_decisions = ("warn", "remove_content", "shadowban")
        if report.target_type == "post":
            from models import Post
            post = db.query(Post).filter(Post.id == report.target_id).first()
            if post:
                other = db.query(Report).filter(
                    Report.id != report.id,
                    Report.target_type == "post",
                    Report.target_id == report.target_id,
                    Report.decision.in_(_content_decisions),
                    Report.status == "actioned",
                ).first()
                if other is None:
                    post.is_hidden = False
                else:
                    print(f"⚠️ [Reverse] Post {report.target_id[:8]} stays hidden "
                          f"due to active report {other.id[:8]}")
        elif report.target_type == "comment":
            from models import Comment
            comment = db.query(Comment).filter(Comment.id == report.target_id).first()
            if comment:
                other = db.query(Report).filter(
                    Report.id != report.id,
                    Report.target_type == "comment",
                    Report.target_id == report.target_id,
                    Report.decision.in_(_content_decisions),
                    Report.status == "actioned",
                ).first()
                if other is None:
                    comment.is_hidden = False
                else:
                    print(f"⚠️ [Reverse] Comment {report.target_id[:8]} stays hidden "
                          f"due to active report {other.id[:8]}")

        # User-level sanctions: only clear if no OTHER actioned
        # ban/restrict report against this user is still standing.
        _user_decisions = ("ban", "tempban", "restrict", "mute", "shadowban")
        if report.reported_user_id:
            other_user_action = db.query(Report).filter(
                Report.id != report.id,
                Report.reported_user_id == report.reported_user_id,
                Report.decision.in_(_user_decisions),
                Report.status == "actioned",
            ).first()
            if other_user_action is None:
                user = db.query(User).filter(User.id == report.reported_user_id).first()
                if user:
                    user.is_banned = False
                    user.banned_at = None
                    user.ban_reason = None
                    user.is_restricted = False
                    user.restricted_until = None
                    user.restriction_scope = None
            else:
                print(f"⚠️ [Reverse] User {report.reported_user_id[:8]} retains sanctions "
                      f"due to active report {other_user_action.id[:8]} "
                      f"(decision={other_user_action.decision})")

    except Exception as e:
        print(f"⚠️ [Reverse] Error reversing decision: {e}")


async def _run_triage(report_id: str):
    """Background task to run AI triage on a report."""
    try:
        from database import SessionLocal
        db = SessionLocal()
        try:
            from services.ai_triage import triage_report
            await triage_report(report_id, db)
        finally:
            db.close()
    except Exception as e:
        print(f"❌ [Triage BG] Error: {e}")
