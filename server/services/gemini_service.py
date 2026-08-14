import os
import httpx
import re
import json
import base64
import socket
import ipaddress
from urllib.parse import urlparse
from typing import Optional, Tuple


def _ip_is_safe(ip_str: str) -> bool:
    """True only for a public unicast address."""
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped is not None:
        # Re-classify ::ffff:a.b.c.d as its embedded IPv4 so an
        # IPv6-mapped internal address can't slip past the checks.
        ip = ip.ipv4_mapped
    return not (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_reserved or ip.is_multicast or ip.is_unspecified)


def _resolve_safe_public_ips(url: str):
    """🔒 SSRF guard (audit H7). Return the list of resolved IP strings for
    an https URL whose host resolves EXCLUSIVELY to public unicast
    addresses, else None.

    NOTE (documented residual): callers here still connect by hostname, so a
    fast DNS-rebind between this resolve and httpx's resolve remains a
    narrow TOCTOU. The version-sensitive fix (pin the vetted IP into the
    connection transport) is tracked as COMPILE_UNVERIFIED; this guard still
    blocks the direct-internal-IP, metadata-host and IPv6-mapped attacks.
    """
    try:
        parsed = urlparse(url)
    except Exception:
        return None
    if parsed.scheme != "https":
        return None
    host = parsed.hostname
    if not host:
        return None
    if host.lower().rstrip(".") in ("metadata", "metadata.google.internal"):
        return None
    try:
        infos = socket.getaddrinfo(host, parsed.port or 443, proto=socket.IPPROTO_TCP)
    except Exception:
        return None
    if not infos:
        return None
    ips = []
    for info in infos:
        ip_str = info[4][0]
        if not _ip_is_safe(ip_str):
            return None
        ips.append(ip_str)
    return ips


def _is_safe_public_url(url: str) -> bool:
    """Back-compat boolean wrapper. Prefer _resolve_safe_public_ips so the
    resolved IP can be PINNED into the connection (rebinding-safe)."""
    return _resolve_safe_public_ips(url) is not None


class GeminiService:
    """Service for integrating with Google Gemini API using direct REST calls."""
    
    # API configuration
    BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
    TEXT_MODEL = "gemini-2.0-flash"  # Full multilingual model (supports Persian, Arabic, etc.)
    VISION_MODEL = "gemini-2.0-flash"  # Multimodal model for images

    
    # Language detection patterns (fast, local detection)
    LANGUAGE_PATTERNS = {
        'fa': re.compile(r'[\u0600-\u06FF]'),  # Persian/Arabic script
        'ar': re.compile(r'[\u0600-\u06FF]'),  # Arabic (same script, detect by context)
        'zh': re.compile(r'[\u4e00-\u9fff]'),  # Chinese
        'ja': re.compile(r'[\u3040-\u309f\u30a0-\u30ff]'),  # Japanese
        'ko': re.compile(r'[\uac00-\ud7af]'),  # Korean
        'ru': re.compile(r'[\u0400-\u04FF]'),  # Russian/Cyrillic
        'he': re.compile(r'[\u0590-\u05FF]'),  # Hebrew
        'th': re.compile(r'[\u0e00-\u0e7f]'),  # Thai
    }
    
    LANGUAGE_NAMES = {
        'en': 'English',
        'fa': 'Persian/Farsi',
        'ar': 'Arabic',
        'zh': 'Chinese',
        'ja': 'Japanese',
        'ko': 'Korean',
        'ru': 'Russian',
        'he': 'Hebrew',
        'th': 'Thai',
        'es': 'Spanish',
        'fr': 'French',
        'de': 'German',
        'it': 'Italian',
        'pt': 'Portuguese',
        'nl': 'Dutch',
        'tr': 'Turkish',
    }
    
    def __init__(self, api_key: str):
        """Initialize Gemini service with API key."""
        self.api_key = api_key
    
    def detect_language(self, text: str) -> str:
        """
        Detect language from text using fast local patterns.
        Returns ISO 639-1 code (e.g., 'en', 'fa', 'ar').
        """
        if not text:
            return 'en'
        
        # Count characters matching each script
        text_sample = text[:500]  # First 500 chars for speed
        
        for lang, pattern in self.LANGUAGE_PATTERNS.items():
            matches = len(pattern.findall(text_sample))
            if matches > len(text_sample) * 0.1:  # More than 10% of text
                # Distinguish Persian from Arabic by common words
                if lang in ['fa', 'ar']:
                    persian_markers = ['است', 'که', 'را', 'این', 'با', 'از', 'می', 'هست', 'نیست']
                    arabic_markers = ['هذا', 'في', 'على', 'من', 'الى', 'إن', 'هو', 'هي']
                    
                    persian_count = sum(1 for m in persian_markers if m in text_sample)
                    arabic_count = sum(1 for m in arabic_markers if m in text_sample)
                    
                    return 'fa' if persian_count >= arabic_count else 'ar'
                return lang
        
        # Default to English for Latin script
        return 'en'
    
    async def _download_audio_as_base64(self, audio_url: str) -> Tuple[Optional[str], Optional[str]]:
        """
        Download audio from URL and convert to base64 for Gemini API.
        
        Returns:
            Tuple of (base64_data, mime_type) or (None, None) if failed
        """
        if not audio_url:
            return None, None

        # 🔒 SECURITY (audit H7 — SSRF / metadata-token exfil): audio_url
        # is client-controlled (stored verbatim from comment/message/group
        # media_url). Refuse anything that isn't an https URL resolving to
        # a public address, and DISABLE redirects so a public 302→internal
        # bounce can't reintroduce the attack.
        if not _is_safe_public_url(audio_url):
            print("🚫 [Transcribe] Refusing unsafe/non-public audio URL")
            return None, None

        print(f"🎙️ [Transcribe] Downloading audio: {audio_url[:80]}...")

        try:
            async with httpx.AsyncClient(timeout=30.0, follow_redirects=False) as client:
                response = await client.get(audio_url)

                if response.status_code != 200:
                    print(f"❌ [Transcribe] Failed to download audio: {response.status_code}")
                    return None, None
                
                # Detect MIME type
                content_type = response.headers.get("content-type", "audio/mp4")
                if "m4a" in audio_url or "mp4" in content_type:
                    mime_type = "audio/mp4"
                elif "mp3" in audio_url or "mpeg" in content_type:
                    mime_type = "audio/mpeg"
                elif "wav" in audio_url or "wav" in content_type:
                    mime_type = "audio/wav"
                elif "ogg" in audio_url:
                    mime_type = "audio/ogg"
                elif "aac" in audio_url:
                    mime_type = "audio/aac"
                else:
                    mime_type = "audio/mp4"  # Default for m4a recordings
                
                audio_bytes = response.content
                if len(audio_bytes) == 0:
                    print("❌ [Transcribe] Downloaded audio is empty (0 bytes)")
                    return None, None
                # 🔒 (audit L-15) cap the remote body so a client-referenced
                # URL can't buffer an unbounded object (+1.33x base64 copy)
                # into RAM. Audio messages are small; 25 MB is generous.
                _MAX_AUDIO_BYTES = 25 * 1024 * 1024
                if len(audio_bytes) > _MAX_AUDIO_BYTES:
                    print(f"❌ [Transcribe] Audio exceeds {_MAX_AUDIO_BYTES}-byte cap")
                    return None, None
                
                base64_data = base64.b64encode(audio_bytes).decode("utf-8")
                print(f"✅ [Transcribe] Audio downloaded: {len(audio_bytes)} bytes, type: {mime_type}")
                
                return base64_data, mime_type
                
        except Exception as e:
            print(f"❌ [Transcribe] Error downloading audio: {e}")
            return None, None

    async def transcribe_audio(self, audio_url: str) -> dict:
        """
        Transcribe audio using Gemini 2.0 Flash's native audio understanding.
        
        Supports any language — Gemini auto-detects and transcribes in the
        original spoken language with proper punctuation.
        
        Args:
            audio_url: Public URL to an audio file (m4a, mp3, wav, etc.)
            
        Returns:
            dict with keys:
                - text: str (transcribed text)
                - language: str (ISO 639-1 code, e.g. 'en', 'fa', 'ar')
                - confidence: float (0.0–1.0)
            Or on failure:
                - text: None, language: None, confidence: 0, error: str
        """
        print(f"🎙️ [Transcribe] Starting transcription for: {audio_url[:80]}...")
        
        # Download audio
        audio_base64, mime_type = await self._download_audio_as_base64(audio_url)
        if not audio_base64:
            return {"text": None, "language": None, "confidence": 0, "error": "Failed to download audio"}
        
        # Build Gemini request with audio.
        #
        # 🔴 ROUND 43 (2026-05-19) — API-key URL-leak fix.
        #
        # PREVIOUSLY: `url = f"...?key={self.api_key}"` embedded the
        # Gemini API key in the URL query string. Concrete leaks:
        #   1. `httpx` raises exceptions that include the full URL
        #      in the message (`HTTPStatusError: 500 for url
        #      'https://...?key=AIza...REAL_KEY'`). Those messages
        #      get `print`'d at line 242 to stdout, which on Cloud
        #      Run is shipped to centralised logs that any teammate
        #      with `logging.viewer` IAM can read.
        #   2. URL-shaped strings are over-eagerly captured by
        #      crash reporters, APM agents, and structured logs.
        #   3. The Google Cloud edge logs every URL it sees.
        # Net effect: the production GEMINI_API_KEY was one log
        # query away from anyone with logs-viewer permission.
        #
        # FIX: move the key into the `x-goog-api-key` HEADER, which
        # Google's API supports identically. Headers are NOT echoed
        # in HTTP error messages, NOT captured by URL-substring
        # log scanners, and NOT visible in URL-only access logs.
        url = f"{self.BASE_URL}/{self.TEXT_MODEL}:generateContent"
        headers = {"x-goog-api-key": self.api_key}
        
        prompt = """You are a precise audio transcription system.

TASK: Transcribe the attached audio file exactly as spoken.

RULES:
1. Transcribe in the ORIGINAL language(s) spoken. Do NOT translate.
2. Add proper punctuation and capitalization.
3. If multiple languages are spoken, transcribe each in its original language.
4. Detect the primary language spoken.
5. Return ONLY valid JSON, no markdown, no code fences.

RESPONSE FORMAT (strict JSON):
{"language": "<ISO 639-1 code>", "text": "<full transcript>", "confidence": <0.0-1.0>}

Examples:
- Persian audio → {"language": "fa", "text": "سلام، حال شما چطوره؟", "confidence": 0.95}
- English audio → {"language": "en", "text": "Hey, how are you doing?", "confidence": 0.97}
- Mixed → {"language": "multi", "text": "Hello, سلام, how are you?", "confidence": 0.88}"""

        payload = {
            "contents": [{
                "parts": [
                    {"text": prompt},
                    {
                        "inline_data": {
                            "mime_type": mime_type,
                            "data": audio_base64
                        }
                    }
                ]
            }],
            "generationConfig": {
                "temperature": 0.1,  # Low temp for accuracy
                "maxOutputTokens": 4096,  # Long transcripts
            }
        }
        
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                response = await client.post(url, json=payload, headers=headers)

                if response.status_code == 200:
                    data = response.json()
                    candidates = data.get("candidates", [])
                    if candidates:
                        content = candidates[0].get("content", {})
                        parts = content.get("parts", [])
                        if parts:
                            raw_text = parts[0].get("text", "").strip()
                            
                            # Strip markdown code fences if present
                            if raw_text.startswith("```"):
                                lines = raw_text.split("\n")
                                raw_text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])
                                raw_text = raw_text.strip()
                            
                            # Parse JSON response
                            try:
                                result = json.loads(raw_text)
                                print(f"✅ [Transcribe] Success: lang={result.get('language')}, "
                                      f"len={len(result.get('text', ''))}, "
                                      f"conf={result.get('confidence')}")
                                return {
                                    "text": result.get("text", ""),
                                    "language": result.get("language", "en"),
                                    "confidence": result.get("confidence", 0.5)
                                }
                            except json.JSONDecodeError:
                                # Gemini returned plain text instead of JSON
                                print(f"⚠️ [Transcribe] Non-JSON response, using as plain text")
                                return {
                                    "text": raw_text,
                                    "language": self.detect_language(raw_text),
                                    "confidence": 0.7
                                }
                    
                    print("⚠️ [Transcribe] No text in Gemini response")
                    return {"text": None, "language": None, "confidence": 0, "error": "Empty response"}
                else:
                    error_msg = response.text[:200]
                    print(f"❌ [Transcribe] Gemini API error: {response.status_code} - {error_msg}")
                    return {"text": None, "language": None, "confidence": 0, "error": f"API error {response.status_code}"}
                    
        except Exception as e:
            print(f"❌ [Transcribe] Gemini API exception: {e}")
            return {"text": None, "language": None, "confidence": 0, "error": str(e)}

    async def _download_image_as_base64(self, image_url: str) -> Tuple[Optional[str], Optional[str]]:
        """
        Download image from URL and convert to base64 for Gemini Vision API.
        
        Args:
            image_url: Public URL of the image
            
        Returns:
            Tuple of (base64_data, mime_type) or (None, None) if failed
        """
        if not image_url:
            return None, None

        # 🔒 SECURITY (audit SSRF bypass #2): image_url is client-controlled
        # (stored post/message media). The H7 guard was applied to the audio
        # path ONLY — this vision path had NO guard and followed redirects,
        # so image_url="http://169.254.169.254/computeMetadata/v1/..." (or a
        # public 302→internal bounce) base64'd the SA token into the vision
        # request. Same guard as audio, and DISABLE redirects.
        if not _resolve_safe_public_ips(image_url):
            print("🚫 [Vision] Refusing unsafe/non-public image URL")
            return None, None

        print(f"🖼️ [Vision] Downloading image: {image_url[:60]}...")

        try:
            async with httpx.AsyncClient(timeout=15.0, follow_redirects=False) as client:
                response = await client.get(image_url)
                
                if response.status_code != 200:
                    print(f"❌ [Vision] Failed to download image: {response.status_code}")
                    return None, None
                
                # Get content type
                content_type = response.headers.get("content-type", "image/jpeg")
                # Normalize MIME type
                if "jpeg" in content_type or "jpg" in content_type:
                    mime_type = "image/jpeg"
                elif "png" in content_type:
                    mime_type = "image/png"
                elif "webp" in content_type:
                    mime_type = "image/webp"
                elif "gif" in content_type:
                    mime_type = "image/gif"
                else:
                    mime_type = "image/jpeg"  # Default to JPEG
                
                # Convert to base64
                image_bytes = response.content
                if len(image_bytes) == 0:
                    print("❌ [Vision] Downloaded image is empty (0 bytes)")
                    return None, None
                
                base64_data = base64.b64encode(image_bytes).decode("utf-8")
                print(f"✅ [Vision] Image downloaded: {len(image_bytes)} bytes, type: {mime_type}")
                
                return base64_data, mime_type
                
        except Exception as e:
            print(f"❌ [Vision] Error downloading image: {e}")
            return None, None

    async def generate_response(
        self, 
        question: str, 
        post_content: str,
        thread_history: list = None,
        language: str = None,  # If None, auto-detect from question
        enable_search: bool = False,  # ✅ NEW: Enable web search for fact-checking
        image_url: str = None,  # ✅ Image URL for vision analysis
        local_image_base64: str = None,  # ✅ NEW: Pre-loaded base64 image
        local_image_mime: str = None  # ✅ NEW: MIME type for local image
    ) -> dict:
        """
        Generate AI response to user question about a post.
        
        Args:
            question: The user's question extracted from @ask
            post_content: The content of the post being discussed
            thread_history: Previous comments in the same thread (for context)
            language: Language code for response. If None, auto-detected from question.
            enable_search: If True, perform web search for fact-checking
            image_url: Optional image URL for vision analysis (external URL)
            local_image_base64: Pre-loaded base64 encoded image (for local files)
            local_image_mime: MIME type of the local image
            
        Returns:
            Dict with 'response', 'sources' (if search), 'search_performed'
        """
        
        # ✅ Auto-detect language from question if not provided
        detected_lang = language or self.detect_language(question)
        lang_name = self.LANGUAGE_NAMES.get(detected_lang, 'English')
        
        print(f"🌐 [Gemini] Detected language: {detected_lang} ({lang_name})")
        
        # ✅ Web search integration
        search_context = ""
        sources = []
        search_performed = False
        
        if enable_search:
            from .search_service import get_search_service
            search_service = get_search_service()
            
            if search_service and search_service.should_search(question, detected_lang):
                print(f"🔍 [Gemini] Performing web search for: {question[:50]}...")
                search_results = await search_service.search(question, num_results=5)
                
                if search_results:
                    search_performed = True
                    sources = [{"title": r.title, "url": r.url, "source": r.source} for r in search_results]
                    search_context = "\n\nWeb search results:\n"
                    for i, result in enumerate(search_results[:5], 1):
                        search_context += f"{i}. {result.get('title', 'N/A')}: {result.get('snippet', 'N/A')}\n"
                    print(f"✅ [Gemini] Added {len(search_results)} search results to context")
        
        # ✅ Handle image for Vision API FIRST (before building prompt)
        # Use local_image_base64 directly if provided, otherwise download from URL
        image_base64 = None
        mime_type = None
        use_vision_model = False
        
        if local_image_base64 and local_image_mime:
            # Use pre-loaded local image
            image_base64 = local_image_base64
            mime_type = local_image_mime
            use_vision_model = True
            print(f"🖼️ [Gemini] Using local image ({mime_type})")
        elif image_url:
            print(f"🖼️ [Gemini] Image URL provided, attempting download...")
            image_base64, mime_type = await self._download_image_as_base64(image_url)
            use_vision_model = image_base64 is not None
        
        # ✅ Build prompt AFTER image handling (so we can pass has_image flag)
        prompt = self._build_prompt(
            question, 
            post_content, 
            thread_history, 
            detected_lang, 
            lang_name,
            search_context=search_context,
            search_performed=search_performed,
            has_image=use_vision_model  # ✅ Pass image flag to prompt!
        )
        
        # ✅ Select model based on whether we have an image
        model = self.VISION_MODEL if use_vision_model else self.TEXT_MODEL
        # 🔴 ROUND 43 — same header-not-query-string fix as
        # `transcribe_audio` above. See ROUND 43 comment there.
        url = f"{self.BASE_URL}/{model}:generateContent"
        headers = {"x-goog-api-key": self.api_key}
        
        print(f"🤖 [Gemini] Using model: {model} (vision: {use_vision_model})")
        
        # ✅ Build payload - multimodal if image, text-only otherwise
        if use_vision_model and image_base64:
            # Multimodal payload with image
            payload = {
                "contents": [{
                    "parts": [
                        {"text": prompt},
                        {
                            "inline_data": {
                                "mime_type": mime_type,
                                "data": image_base64
                            }
                        }
                    ]
                }],
                "generationConfig": {
                    "temperature": 0.7,
                    "maxOutputTokens": 800,  # More tokens for image description
                }
            }
            print(f"📤 [Gemini] Sending multimodal request with image ({mime_type})")
        else:
            # Text-only payload
            payload = {
                "contents": [{"parts": [{"text": prompt}]}],
                "generationConfig": {
                    "temperature": 0.7,
                    "maxOutputTokens": 500 if not search_performed else 800,
                }
            }
        
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(url, json=payload, headers=headers)

                if response.status_code == 200:
                    data = response.json()
                    # Extract text from response
                    candidates = data.get("candidates", [])
                    if candidates:
                        content = candidates[0].get("content", {})
                        parts = content.get("parts", [])
                        if parts:
                            text = parts[0].get("text", "")
                            print(f"✅ AI response ({detected_lang}): {text[:50]}...")
                            return {
                                "response": text,
                                "sources": sources,
                                "search_performed": search_performed,
                                "language": detected_lang
                            }
                    print("⚠️ No text in AI response")
                    return {"response": None, "sources": [], "search_performed": search_performed}
                else:
                    print(f"❌ Gemini API error: {response.status_code} - {response.text}")
                    return {"response": None, "sources": [], "search_performed": search_performed}
                    
        except Exception as e:
            print(f"❌ Gemini API error: {e}")
            return {"response": None, "sources": [], "search_performed": search_performed}

    
    def _build_prompt(
        self, 
        question: str, 
        post_content: str, 
        thread_history: list,
        lang_code: str,
        lang_name: str,
        search_context: str = "",  # ✅ Web search results
        search_performed: bool = False,  # ✅ Whether search was done
        has_image: bool = False  # ✅ NEW: Whether an image is attached
    ) -> str:
        """Build the prompt for Gemini with HARD language lock."""
        
        # ✅ DEBUG: Log prompt components
        print(f"📝 [PROMPT-DEBUG] Building prompt...")
        print(f"📝 [PROMPT-DEBUG] Post content in prompt: {len(post_content)} chars")
        print(f"📝 [PROMPT-DEBUG] Question: {question[:100]}...")
        print(f"📝 [PROMPT-DEBUG] Has image: {has_image}")
        
        # Build thread context if available
        thread_context = ""
        if thread_history:
            thread_context = "\n\nPrevious comments in this thread:\n"
            for i, comment in enumerate(thread_history[-5:], 1):  # Last 5 comments
                author = comment.get('author', 'User')
                content = comment.get('content', '')
                thread_context += f"{i}. {author}: {content}\n"
        
        # ✅ Build search section if search was performed
        search_section = ""
        fact_check_format = ""
        if search_performed and search_context:
            search_section = f"""

═══════════════════════════════════════════════════════════════
🔍 WEB SEARCH RESULTS (Use these as primary sources)
═══════════════════════════════════════════════════════════════
{search_context}
"""
            fact_check_format = """

📋 RESPONSE FORMAT (Required for fact-checking):
1. **Verdict**: (Confirmed ✅ / Unconfirmed ⚠️ / False ❌ / Mixed 🔄)
2. **Summary**: 1-2 sentence explanation
3. **Evidence**: 2-3 key points from sources
4. **Confidence**: (High / Medium / Low)

If sources conflict, explain the differences.
"""
        
        # ✅ NEW: Build image instruction if image is present
        image_instruction = ""
        if has_image:
            image_instruction = """

═══════════════════════════════════════════════════════════════
🖼️ IMAGE ATTACHED - ANALYZE THE IMAGE!
═══════════════════════════════════════════════════════════════
An image is attached to this post. The user's question is about this image.
You MUST carefully look at and analyze the attached image to answer the question.
Describe what you see in the image and answer the user's question based on the visual content.
"""
        
        # ✅ HARD LANGUAGE LOCK - Very explicit instruction
        return f"""You are Gemini, an AI assistant in a social media app.

═══════════════════════════════════════════════════════════════
⚠️ CRITICAL LANGUAGE INSTRUCTION ⚠️
═══════════════════════════════════════════════════════════════
Default: Respond in {lang_name} ({lang_code}).

TRANSLATION RULES:
✅ You CAN translate text to ANY language when asked (Persian, Arabic, Chinese, etc.)
✅ If user asks to translate, DO IT immediately in the requested language.
✅ If user asks "translate to Persian", respond ONLY in Persian.
✅ If user asks "ترجمه کن به فارسی", respond in Persian.

The user's question language ({lang_code}) determines your default response language,
but you MUST switch languages when translation is explicitly requested.
═══════════════════════════════════════════════════════════════
{image_instruction}{search_section}
📌 Post Content:
{post_content}
{thread_context}
💬 User Question:
{question}
{fact_check_format}
Be helpful, accurate, and concise. You can translate to ANY language when asked."""


# Global instance
_gemini_service: Optional[GeminiService] = None


def get_gemini_service() -> GeminiService:
    """Get or create the global Gemini service instance."""
    global _gemini_service
    
    if _gemini_service is None:
        api_key = os.getenv("GEMINI_API_KEY")
        if not api_key:
            raise ValueError("GEMINI_API_KEY environment variable not set")
        _gemini_service = GeminiService(api_key)
    
    return _gemini_service
