"""
Knowledge Facts Router - For Offline Wiki feature

API endpoints for creating, retrieving, and verifying knowledge facts.
"""

from datetime import datetime, timezone
from typing import List, Optional
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
import google.generativeai as genai
import os
import json

from database import get_db
# 🔴 hacker-audit 2026-05-20 — use the STRICT get_current_user.
# PREVIOUSLY this imported get_current_user_optional (returns None
# instead of raising), so every knowledge endpoint accepted
# anonymous callers — unmetered Gemini calls on /verify and a
# crash-or-leak on the facts endpoints. Knowledge endpoints now
# require a valid token.
from auth import get_current_user
from models import User

router = APIRouter(prefix="/api/knowledge", tags=["knowledge"])

# ═══════════════════════════════════════════════════════════════════
# MODELS
# ═══════════════════════════════════════════════════════════════════

class FactCreate(BaseModel):
    title: str = Field(..., min_length=1, max_length=100)
    claim: str = Field(..., min_length=10, max_length=2000)
    tags: List[str] = []
    lang: str = "en"
    sources: List[str] = []

class FactVerifyRequest(BaseModel):
    title: str
    claim: str
    lang: str = "en"
    tags: List[str] = []

class VerifyResponse(BaseModel):
    is_likely_true: bool
    confidence: float
    category: str
    key_reasons: List[str]
    suggested_sources: List[str]
    summary: str

class FactResponse(BaseModel):
    id: str
    title: str
    claim: str
    tags: List[str]
    lang: str
    created_at: datetime
    verify_status: str
    verify_score: int
    verify_reason: Optional[str]
    author_display_name: Optional[str]

# ═══════════════════════════════════════════════════════════════════
# VERIFICATION WITH GEMINI
# ═══════════════════════════════════════════════════════════════════

# Configure Gemini
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
if GEMINI_API_KEY:
    genai.configure(api_key=GEMINI_API_KEY)

VERIFY_PROMPT = """You are a fact-checking AI assistant. Analyze the following claim for accuracy.

IMPORTANT: Be strict and accurate. Only mark claims as likely true if you have high confidence based on established facts.

Title: {title}
Claim: {claim}
Language: {lang}
Tags: {tags}

Respond with a JSON object in this EXACT format:
{{
  "is_likely_true": true/false,
  "confidence": 0.0-1.0 (your confidence level),
  "category": "science/history/health/technology/nature/society/other",
  "key_reasons": ["reason 1", "reason 2", ...],
  "suggested_sources": ["source 1", "source 2", ...] (optional),
  "summary": "Brief explanation of your analysis"
}}

Be concise. If the claim is well-known and established, you can be more confident.
If the claim is controversial, speculative, or lacks evidence, lower your confidence.
"""

async def verify_with_gemini(title: str, claim: str, lang: str, tags: List[str]) -> VerifyResponse:
    """Verify a fact claim using Gemini AI"""
    
    if not GEMINI_API_KEY:
        # Return neutral response if no API key
        return VerifyResponse(
            is_likely_true=False,
            confidence=0.5,
            category="other",
            key_reasons=["AI verification not configured"],
            suggested_sources=[],
            summary="Unable to verify - API not configured"
        )
    
    try:
        model = genai.GenerativeModel('gemini-1.5-flash')
        
        prompt = VERIFY_PROMPT.format(
            title=title,
            claim=claim,
            lang=lang,
            tags=", ".join(tags) if tags else "none"
        )
        
        response = model.generate_content(prompt)
        
        # Parse JSON from response
        text = response.text.strip()
        
        # Handle markdown code blocks
        if text.startswith("```json"):
            text = text[7:]
        if text.startswith("```"):
            text = text[3:]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()
        
        data = json.loads(text)
        
        return VerifyResponse(
            is_likely_true=data.get("is_likely_true", False),
            confidence=float(data.get("confidence", 0.5)),
            category=data.get("category", "other"),
            key_reasons=data.get("key_reasons", []),
            suggested_sources=data.get("suggested_sources", []),
            summary=data.get("summary", "")
        )
        
    except json.JSONDecodeError as e:
        print(f"❌ [Verify] JSON parse error: {e}")
        print(f"❌ [Verify] Raw response: {response.text if response else 'None'}")
        return VerifyResponse(
            is_likely_true=False,
            confidence=0.3,
            category="other",
            key_reasons=["Error parsing AI response"],
            suggested_sources=[],
            summary="Verification failed - parsing error"
        )
    except Exception as e:
        print(f"❌ [Verify] Gemini error: {e}")
        return VerifyResponse(
            is_likely_true=False,
            confidence=0.3,
            category="other",
            key_reasons=[f"AI error: {str(e)}"],
            suggested_sources=[],
            summary="Verification failed"
        )

# ═══════════════════════════════════════════════════════════════════
# ENDPOINTS
# ═══════════════════════════════════════════════════════════════════

@router.post("/verify", response_model=VerifyResponse)
async def verify_fact(
    request: FactVerifyRequest,
    current_user: User = Depends(get_current_user)
):
    """
    Verify a fact claim using AI.
    Returns confidence score and analysis.
    """
    print(f"🔍 [Knowledge] Verifying: {request.title}")
    
    result = await verify_with_gemini(
        title=request.title,
        claim=request.claim,
        lang=request.lang,
        tags=request.tags
    )
    
    status_text = "verified" if result.is_likely_true and result.confidence >= 0.85 else "unverified"
    print(f"✅ [Knowledge] Result: {status_text} (confidence: {result.confidence})")
    
    return result


@router.get("/popular-tags")
async def get_popular_tags(
    limit: int = 20,
    current_user: User = Depends(get_current_user)
):
    """
    Get most popular tags for knowledge facts.
    This is a placeholder - implement with actual database queries.
    """
    # TODO: Query database for tag counts
    default_tags = [
        {"tag": "science", "count": 150},
        {"tag": "history", "count": 120},
        {"tag": "health", "count": 100},
        {"tag": "technology", "count": 95},
        {"tag": "nature", "count": 80},
        {"tag": "psychology", "count": 70},
        {"tag": "space", "count": 65},
        {"tag": "food", "count": 60},
        {"tag": "culture", "count": 55},
        {"tag": "economics", "count": 50},
    ]
    return default_tags[:limit]


@router.get("/featured")
async def get_featured_facts(
    lang: str = "en",
    limit: int = 10,
    current_user: User = Depends(get_current_user)
):
    """
    Get featured/editor's pick facts.
    Placeholder for curated content.
    """
    # TODO: Implement with actual database + curation system
    return {
        "facts": [],
        "message": "Featured facts coming soon"
    }


# ═══════════════════════════════════════════════════════════════════
# FACT SYNC ENDPOINTS
# ═══════════════════════════════════════════════════════════════════

class FactData(BaseModel):
    """Complete fact data for sync"""
    id: str
    title: str
    claim: str
    tags: List[str] = []
    lang: str = "en"
    created_at: str
    updated_at: str
    author_id: Optional[str] = None
    author_display_name: Optional[str] = None
    privacy_mode: str = "showName"
    sources: List[str] = []
    verify_status: str = "unverified"
    verify_score: int = 0
    verify_reason: Optional[str] = None
    hash: str
    ttl: Optional[int] = None
    sync_count: int = 0


# In-memory storage for facts (replace with database in production)
_facts_db: dict = {}


@router.post("/facts")
async def upload_fact(
    fact: FactData,
    current_user: User = Depends(get_current_user)
):
    """
    Upload a fact to the server for global sync.
    Used when device has internet connectivity.
    """
    print(f"📤 [Knowledge] Received fact: {fact.title} from user {current_user.id}")

    # 🔴 hacker-audit 2026-05-20 — server-authoritative author + write-IDOR guard.
    # PREVIOUSLY the client-supplied fact.author_id was stored verbatim
    # and ANY caller could overwrite ANY fact.id (the only check was a
    # newer updated_at) — allowing both author spoofing and the
    # poisoning/erasing of other users' facts. Now the author is
    # always the authenticated caller, and an existing fact can only
    # be updated by its original author.
    fact.author_id = current_user.id

    # Check if fact exists
    existing = _facts_db.get(fact.id)

    if existing:
        if existing.get("author_id") != current_user.id:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="This fact belongs to another user",
            )
        # Update if newer
        existing_updated = existing.get("updated_at", "")
        if fact.updated_at > existing_updated:
            _facts_db[fact.id] = fact.dict()
            print(f"📤 [Knowledge] Updated existing fact: {fact.id}")
    else:
        # Store new fact
        _facts_db[fact.id] = fact.dict()
        print(f"📤 [Knowledge] Stored new fact: {fact.id}")
    
    return {"status": "ok", "id": fact.id}


@router.get("/facts")
async def get_facts(
    since: Optional[int] = None,  # milliseconds since epoch
    limit: int = 100,
    lang: Optional[str] = None,
    tag: Optional[str] = None,
    current_user: User = Depends(get_current_user)
):
    """
    Get facts from server for sync.
    Optionally filter by timestamp, language, or tag.
    """
    facts = list(_facts_db.values())
    
    # Filter by since timestamp
    if since:
        since_dt = datetime.fromtimestamp(since / 1000, tz=timezone.utc)
        facts = [f for f in facts if datetime.fromisoformat(f.get("updated_at", "2000-01-01")) > since_dt]
    
    # Filter by language
    if lang:
        facts = [f for f in facts if f.get("lang") == lang]
    
    # Filter by tag
    if tag:
        facts = [f for f in facts if tag in f.get("tags", [])]
    
    # Sort by updated_at descending
    facts.sort(key=lambda x: x.get("updated_at", ""), reverse=True)
    
    # Limit
    facts = facts[:limit]

    # 🔴 hacker-audit 2026-05-20 — honor privacy_mode on sync.
    # The facts wiki is shared, but a fact uploaded with
    # privacy_mode != "showName" must not expose its author's id or
    # display name to other users. Redact author identity on the way
    # out (build copies — never mutate the stored dicts).
    safe_facts = []
    for f in facts:
        if f.get("privacy_mode", "showName") != "showName":
            f = {**f, "author_id": None, "author_display_name": None}
        safe_facts.append(f)
    facts = safe_facts

    print(f"📥 [Knowledge] Returning {len(facts)} facts to user {current_user.id}")

    return {"facts": facts, "count": len(facts)}
