"""
Language Detection Service

Detects the language of text content for personalization.
Uses langdetect library with fallback to simple heuristics.
"""
from typing import Optional
import re

# Try to import langdetect, fallback to simple detection if not available
try:
    from langdetect import detect, DetectorFactory
    DetectorFactory.seed = 0  # For consistent results
    LANGDETECT_AVAILABLE = True
except ImportError:
    LANGDETECT_AVAILABLE = False
    print("⚠️ langdetect not installed, using simple language detection")


# Language patterns for fallback detection
PERSIAN_PATTERN = re.compile(r'[\u0600-\u06FF\uFB50-\uFDFF\uFE70-\uFEFF]')
ARABIC_PATTERN = re.compile(r'[\u0600-\u06FF]')
CHINESE_PATTERN = re.compile(r'[\u4e00-\u9fff]')
GERMAN_PATTERN = re.compile(r'\b(der|die|das|und|ist|ein|eine|nicht|ich|du|wir)\b', re.IGNORECASE)
SPANISH_PATTERN = re.compile(r'\b(el|la|los|las|es|un|una|que|de|en|por|para)\b', re.IGNORECASE)


def detect_language(text: str) -> Optional[str]:
    """
    Detect the language of text content.
    
    Returns:
        ISO 639-1 language code (en, fa, de, es, zh) or None if detection fails.
    """
    if not text or len(text.strip()) < 3:
        return None
    
    # Clean text - remove URLs, mentions, hashtags
    clean_text = re.sub(r'https?://\S+', '', text)
    clean_text = re.sub(r'@\w+', '', clean_text)
    clean_text = re.sub(r'#\w+', '', clean_text)
    clean_text = clean_text.strip()
    
    if len(clean_text) < 3:
        return None
    
    # Try langdetect first (more accurate)
    if LANGDETECT_AVAILABLE:
        try:
            lang = detect(clean_text)
            # Map to our supported languages
            lang_map = {
                'fa': 'fa',  # Persian/Farsi
                'ar': 'fa',  # Map Arabic script to Persian (common in our app)
                'en': 'en',
                'de': 'de',
                'es': 'es',
                'zh-cn': 'zh',
                'zh-tw': 'zh',
            }
            return lang_map.get(lang, lang if lang in ['en', 'fa', 'de', 'es', 'zh'] else 'en')
        except Exception:
            pass
    
    # Fallback: Simple pattern-based detection
    return _simple_detect(clean_text)


def _simple_detect(text: str) -> str:
    """Simple pattern-based language detection as fallback."""
    
    # Check for Persian/Arabic script (Farsi)
    if PERSIAN_PATTERN.search(text):
        return 'fa'
    
    # Check for Chinese characters
    if CHINESE_PATTERN.search(text):
        return 'zh'
    
    # Check for German words
    if GERMAN_PATTERN.search(text):
        return 'de'
    
    # Check for Spanish words
    if SPANISH_PATTERN.search(text):
        return 'es'
    
    # Default to English
    return 'en'


def update_user_language_preference(user_id: str, text: str, db) -> Optional[str]:
    """
    Update user's language preference based on their content.
    Uses exponential moving average to smooth language detection.
    
    Args:
        user_id: The user's ID
        text: Text content to analyze
        db: Database session
        
    Returns:
        Detected language code or None
    """
    from models import User
    
    detected_lang = detect_language(text)
    if not detected_lang:
        return None
    
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        return detected_lang
    
    # If user doesn't have a preferred language, set it
    if not hasattr(user, 'preferred_language') or not user.preferred_language:
        # Will need to add this column first
        pass
    
    return detected_lang


# For testing
if __name__ == "__main__":
    test_cases = [
        ("Hello, how are you?", "en"),
        ("سلام، حالت چطوره؟", "fa"),
        ("Hallo, wie geht es dir?", "de"),
        ("Hola, ¿cómo estás?", "es"),
        ("你好，你好吗？", "zh"),
    ]
    
    print("Language Detection Test:")
    for text, expected in test_cases:
        result = detect_language(text)
        status = "✅" if result == expected else "❌"
        print(f"  {status} '{text[:30]}...' → {result} (expected: {expected})")
