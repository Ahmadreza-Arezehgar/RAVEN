"""
AI Triage Service — Uses Gemini Flash to classify, score, and summarize reports.
Runs asynchronously after report submission.

Decision rules:
- High confidence + Low severity + spam → auto-action (hide + mark actioned)
- High severity OR sensitive categories → escalate to human
- Otherwise → triaged (medium-priority queue)
"""

import os
import json
import httpx
from datetime import datetime
from typing import Optional
from sqlalchemy.orm import Session


# Gemini API config (same as GeminiService)
GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
GEMINI_MODEL = "gemini-2.0-flash"

# Categories that require human review
HIGH_RISK_CATEGORIES = {"harassment", "hate_speech", "violence", "sexual", "self_harm", "csam", "terrorism"}

# Categories eligible for auto-action at high confidence
AUTO_ACTION_CATEGORIES = {"spam", "scam"}

TRIAGE_PROMPT = """You are a content moderation AI for a social messaging platform called RAVEN.
Analyze the following reported content and provide a structured assessment.

REPORT DETAILS:
- Report reason given by reporter: {reason}
- Reporter's note: {note}
- Target type: {target_type}
- Content text: {content_text}

INSTRUCTIONS:
1. Classify this content into ONE primary category from this list:
   spam, harassment, hate_speech, sexual, violence, scam, self_harm, copyright, impersonation, privacy_violation, false_info, benign

2. Rate severity from 0 to 100:
   - 0-20: Benign or very minor (e.g., mild spam, borderline content)
   - 21-50: Moderate concern (e.g., rude language, misleading info)
   - 51-80: Serious (e.g., targeted harassment, graphic content)
   - 81-100: Critical (e.g., threats, CSAM, terrorism)

3. Rate your confidence from 0.0 to 1.0 in your classification.

4. Suggest ONE action:
   none, warn, remove_content, restrict, tempban, ban

5. Write a 1-2 sentence summary for a human moderator.

RESPOND IN EXACTLY THIS JSON FORMAT (no markdown, no code fences):
{{"category": "...", "severity": 0, "confidence": 0.0, "suggested_action": "...", "summary": "..."}}
"""


async def triage_report(report_id: str, db: Session):
    """
    Run AI triage on a report. Updates the report record with AI fields.
    Called asynchronously after report submission.
    """
    from models import Report, ModerationAction, HiddenContent, Post
    import uuid as uuid_mod
    
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        print(f"⚠️ [Triage] No GEMINI_API_KEY — skipping AI triage for report {report_id[:8]}")
        return
    
    # 1. Fetch report
    report = db.query(Report).filter(Report.id == report_id).first()
    if not report:
        print(f"❌ [Triage] Report {report_id[:8]} not found")
        return
    
    # 2. Fetch target content text
    content_text = _fetch_content_text(db, report.target_type, report.target_id)
    
    # 3. Build prompt
    prompt = TRIAGE_PROMPT.format(
        reason=report.reason,
        note=report.note or "(no note provided)",
        target_type=report.target_type,
        content_text=content_text[:2000] if content_text else "(content not available)"
    )
    
    # 4. Call Gemini
    url = f"{GEMINI_BASE_URL}/{GEMINI_MODEL}:generateContent?key={api_key}"
    payload = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0.2,  # Low temp for consistent classification
            "maxOutputTokens": 300,
        }
    }
    
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(url, json=payload)
        
        if response.status_code != 200:
            print(f"❌ [Triage] Gemini API error: {response.status_code}")
            return
        
        data = response.json()
        candidates = data.get("candidates", [])
        if not candidates:
            print("❌ [Triage] No candidates in Gemini response")
            return
        
        text = candidates[0].get("content", {}).get("parts", [{}])[0].get("text", "")
        
        # 5. Parse JSON response
        result = _parse_triage_response(text)
        if not result:
            print(f"⚠️ [Triage] Failed to parse AI response: {text[:200]}")
            return
        
        # 6. Update report with AI fields
        report.ai_category = result["category"]
        report.ai_severity = max(0, min(100, result["severity"]))
        report.ai_confidence = max(0.0, min(1.0, result["confidence"]))
        report.ai_summary = result["summary"]
        report.triaged_at = datetime.utcnow()
        
        # 7. Apply decision rules
        category = result["category"]
        severity = report.ai_severity
        confidence = report.ai_confidence
        suggested = result.get("suggested_action", "none")
        
        if category in HIGH_RISK_CATEGORIES or severity >= 60:
            # Escalate to human — never auto-action
            report.status = "escalated"
            print(f"🚨 [Triage] ESCALATED report {report_id[:8]}: {category} / severity={severity}")
            
        elif category in AUTO_ACTION_CATEGORIES and confidence >= 0.9 and severity < 30:
            # Auto-action: low-risk obvious spam/scam — hide content temporarily
            report.status = "actioned"
            report.decision = "remove_content"
            report.decision_reason = f"Auto-moderated: {result['summary']}"
            report.decided_by = "system"
            report.decided_at = datetime.utcnow()
            
            # Create audit log
            action = ModerationAction(
                id=str(uuid_mod.uuid4()),
                report_id=report.id,
                target_type=report.target_type,
                target_id=report.target_id,
                action_type="remove_content",
                parameters_json=json.dumps({"auto": True, "ai_confidence": confidence}),
                actor="system",
                reversible=True
            )
            db.add(action)
            
            # Hide content globally (for all users — moderation hide)
            if report.target_type == "post":
                post = db.query(Post).filter(Post.id == report.target_id).first()
                if post:
                    post.is_hidden = True  # If this column exists; otherwise use HiddenContent
            
            print(f"🤖 [Triage] AUTO-ACTIONED report {report_id[:8]}: {category} (confidence={confidence:.2f})")
            
        else:
            # Medium priority — triaged, waiting for admin
            report.status = "triaged"
            print(f"📋 [Triage] Triaged report {report_id[:8]}: {category} / severity={severity}")
        
        db.commit()
        print(f"✅ [Triage] Complete for report {report_id[:8]}: category={category}, severity={severity}, status={report.status}")
        
    except Exception as e:
        print(f"❌ [Triage] Error during triage: {e}")
        import traceback
        traceback.print_exc()


def _parse_triage_response(text: str) -> Optional[dict]:
    """Parse the JSON response from Gemini, handling potential markdown formatting."""
    # Strip markdown code fences if present
    text = text.strip()
    if text.startswith("```"):
        lines = text.split("\n")
        text = "\n".join(lines[1:-1])  # Remove first and last lines
    text = text.strip()
    
    try:
        result = json.loads(text)
        # Validate required fields
        required = ["category", "severity", "confidence", "summary"]
        if all(k in result for k in required):
            return result
    except json.JSONDecodeError:
        pass
    
    # Fallback: try to extract JSON from mixed text
    import re
    json_match = re.search(r'\{[^{}]+\}', text)
    if json_match:
        try:
            return json.loads(json_match.group())
        except json.JSONDecodeError:
            pass
    
    return None


def _fetch_content_text(db: Session, target_type: str, target_id: str) -> str:
    """Fetch the actual text content of the reported target."""
    from models import Post, User
    
    try:
        if target_type == "post":
            post = db.query(Post).filter(Post.id == target_id).first()
            return post.content if post else ""
        
        elif target_type == "comment":
            # Comments are stored in post_comments table
            from models import PostComment
            comment = db.query(PostComment).filter(PostComment.id == target_id).first()
            return comment.content if comment else ""
        
        elif target_type == "message":
            from models import Message
            msg = db.query(Message).filter(Message.id == target_id).first()
            return msg.content if msg else ""
        
        elif target_type == "user":
            user = db.query(User).filter(User.id == target_id).first()
            if user:
                return f"Username: {user.username}, Display name: {user.display_name or ''}, Bio: {user.bio or ''}"
            return ""
        
        elif target_type in ("group", "room"):
            # Fetch group/room name + description
            return f"[{target_type} ID: {target_id}]"
        
        elif target_type == "story":
            return f"[Story ID: {target_id}]"
        
        elif target_type == "media":
            return f"[Media ID: {target_id}]"
        
    except Exception as e:
        print(f"⚠️ [Triage] Error fetching content for {target_type}/{target_id}: {e}")
    
    return ""
