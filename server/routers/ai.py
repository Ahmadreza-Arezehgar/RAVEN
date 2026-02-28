"""
AI Router - Gemini AI integration for posts and comments.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional
import hashlib

from database import get_db
from models import User, Post
from routers.users import get_current_user
from services.gemini_service import get_gemini_service
from encryption import decrypt_text

router = APIRouter(prefix="/api/ai", tags=["ai"])

# ✅ Simple in-memory cache for idempotency (use Redis in production)
_ask_cache: dict = {}


class AskRequest(BaseModel):
    post_id: str
    question: str
    comment_id: Optional[str] = None  # ✅ For threaded context
    idempotency_key: Optional[str] = None  # ✅ Prevent duplicate requests
    context: Optional[str] = None  # Optional additional context
    enable_search: bool = True  # ✅ Enable web search
    lang: str = "en"


class AskResponse(BaseModel):
    answer: str
    model: str
    tokens_used: Optional[int] = None
    sources: list = []  # ✅ Web search sources (domain names only)
    cached: bool = False  # ✅ Whether this was a cached response


@router.post("/ask", response_model=AskResponse)
async def ask_gemini(
    req: AskRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    # ═══ Premium Rate Limit (3/day for free users, unlimited for premium) ═══
    from middleware.premium_rate_limit import check_ai_quota
    check_ai_quota(current_user)
    """
    Ask Gemini AI about a post.
    
    Request body:
    - post_id: The ID of the post to ask about
    - question: The question to ask (e.g., "Summarize this", "Explain in simple terms")
    - comment_id: Optional comment ID for threaded context
    - idempotency_key: Optional key to prevent duplicate requests
    - context: Optional additional context
    - enable_search: Whether to enable web search for fact-checking
    - lang: Language code (e.g., "en", "fa", "es")
    
    Returns:
    - answer: The AI-generated response
    - model: The model used
    - tokens_used: Number of tokens used (if available)
    - sources: List of source domain names (if web search was used)
    - cached: Whether this was a cached response
    """
    
    # ✅ Check idempotency cache first
    if req.idempotency_key:
        if req.idempotency_key in _ask_cache:
            cached_response = _ask_cache[req.idempotency_key]
            print(f"📦 [AI] Cache hit for idempotency key: {req.idempotency_key[:20]}...")
            return AskResponse(**cached_response, cached=True)
    else:
        # Generate idempotency key from request
        key_parts = f"{req.post_id}:{req.question}:{current_user.id}"
        req.idempotency_key = hashlib.sha256(key_parts.encode()).hexdigest()[:32]
        if req.idempotency_key in _ask_cache:
            cached_response = _ask_cache[req.idempotency_key]
            print(f"📦 [AI] Cache hit for auto-generated key")
            return AskResponse(**cached_response, cached=True)
    
    # Get the post
    post = db.query(Post).filter(Post.id == req.post_id).first()
    if not post:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Post not found"
        )
    
    # Decrypt post content
    post_content = decrypt_text(post.content)
    
    # ✅ DEBUG: Log what we're sending
    print(f"📄 [AI-ASK] Post ID: {req.post_id}")
    print(f"📄 [AI-ASK] Post content length: {len(post_content) if post_content else 0}")
    print(f"📄 [AI-ASK] Post content preview: {post_content[:100] if post_content else 'EMPTY'}...")
    print(f"🖼️ [AI-ASK] Post image URL: {post.image_url or 'None'}")
    
    # ✅ Handle empty or failed content
    if not post_content or post_content == "[DECRYPT_FAILED]":
        post_content = "[No text content in this post]"
        if post.image_url:
            post_content += " [This post contains an image]"
    
    # Combine context if provided
    full_context = post_content
    if req.context:
        full_context = f"{post_content}\n\nAdditional context: {req.context}"
    
    # Get Gemini service
    gemini = get_gemini_service()
    if not gemini:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Gemini AI service not available"
        )
    
    # Map language code to name
    lang_map = {
        "en": "English",
        "fa": "Persian",
        "ar": "Arabic",
        "es": "Spanish",
        "fr": "French",
        "de": "German",
        "zh": "Chinese",
        "ja": "Japanese",
        "ko": "Korean",
        "ru": "Russian",
        "pt": "Portuguese",
        "it": "Italian",
        "nl": "Dutch",
        "tr": "Turkish",
        "hi": "Hindi"
    }
    lang_name = lang_map.get(req.lang, "English")
    
    try:
        # Generate response
        result = await gemini.generate_response(
            question=req.question,
            post_content=full_context,
            thread_history=[],
            language=req.lang,
            enable_search=req.enable_search
        )
        
        response_text = result.get("response")
        sources = result.get("sources", [])
        
        if not response_text:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="AI failed to generate a response"
            )
        
        # ✅ Extract only domain names from sources (privacy)
        source_domains = [s.get("source", "") for s in sources if s.get("source")]
        
        print(f"🤖 AI Ask by {current_user.username}: {req.question[:50]}...")
        
        response_data = {
            "answer": response_text,
            "model": gemini.TEXT_MODEL,
            "tokens_used": None,
            "sources": source_domains
        }
        
        # ✅ Cache the response
        _ask_cache[req.idempotency_key] = response_data
        
        return AskResponse(**response_data, cached=False)
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Gemini error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"AI generation failed: {str(e)}"
        )

