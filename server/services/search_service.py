"""
Search Service - Web search integration for AI fact-checking
Uses Brave Search API (free tier: 2,000 queries/month)
"""
import os
import httpx
from typing import Optional, List
from dataclasses import dataclass
from datetime import datetime, timedelta
import json


@dataclass
class SearchResult:
    """A single search result from web search."""
    title: str
    url: str
    snippet: str
    published_date: Optional[str] = None
    source: Optional[str] = None


class SearchService:
    """
    Service for performing web searches to provide AI with real-time information.
    Currently uses Brave Search API (can be swapped for Bing/SerpAPI).
    """
    
    # Brave Search API
    BASE_URL = "https://api.search.brave.com/res/v1/web/search"
    
    # Cache for recent searches (simple in-memory cache)
    _cache: dict = {}
    _cache_ttl = timedelta(minutes=15)
    
    # Keywords that trigger search
    SEARCH_TRIGGER_KEYWORDS = {
        'en': ['verify', 'confirm', 'true', 'false', 'fact', 'source', 'breaking', 'news', 'today', 'yesterday', 'latest'],
        'fa': ['واقعیه', 'حقیقت', 'تایید', 'منبع', 'خبر', 'امروز', 'دیروز', 'جدید', 'فوری', 'راسته'],
        'ar': ['حقيقة', 'تأكيد', 'مصدر', 'خبر', 'اليوم', 'أمس'],
    }
    
    def __init__(self, api_key: str):
        """Initialize Search service with Brave API key."""
        self.api_key = api_key
    
    def should_search(self, text: str, lang: str = 'en') -> bool:
        """
        Determine if the question warrants a web search.
        Returns True if text contains fact-checking keywords.
        """
        text_lower = text.lower()
        
        # Check all language keywords
        for lang_code, keywords in self.SEARCH_TRIGGER_KEYWORDS.items():
            for keyword in keywords:
                if keyword in text_lower:
                    print(f"🔍 [Search] Trigger keyword found: '{keyword}'")
                    return True
        
        # Also trigger on question patterns
        question_patterns = ['?', 'آیا', 'هل', 'is this', 'is it', 'did he', 'did she']
        for pattern in question_patterns:
            if pattern in text_lower:
                return True
        
        return False
    
    async def search(
        self, 
        query: str, 
        num_results: int = 5,
        freshness: str = None  # 'pd' = past day, 'pw' = past week, 'pm' = past month
    ) -> List[SearchResult]:
        """
        Perform web search and return results.
        
        Args:
            query: Search query string
            num_results: Number of results to return (max 10)
            freshness: Time filter for results
            
        Returns:
            List of SearchResult objects
        """
        # Check cache first
        cache_key = f"{query}:{num_results}:{freshness}"
        if cache_key in self._cache:
            cached, timestamp = self._cache[cache_key]
            if datetime.now() - timestamp < self._cache_ttl:
                print(f"📦 [Search] Cache hit for: {query[:30]}...")
                return cached
        
        print(f"🌐 [Search] Searching for: {query}")
        
        headers = {
            "Accept": "application/json",
            "X-Subscription-Token": self.api_key
        }
        
        params = {
            "q": query,
            "count": min(num_results, 10),
            "text_decorations": False,
            "safesearch": "moderate"
        }
        
        if freshness:
            params["freshness"] = freshness
        
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(
                    self.BASE_URL,
                    headers=headers,
                    params=params
                )
                
                if response.status_code == 200:
                    data = response.json()
                    results = []
                    
                    web_results = data.get("web", {}).get("results", [])
                    for item in web_results[:num_results]:
                        results.append(SearchResult(
                            title=item.get("title", ""),
                            url=item.get("url", ""),
                            snippet=item.get("description", ""),
                            published_date=item.get("published_date"),
                            source=item.get("meta_url", {}).get("hostname", "")
                        ))
                    
                    # Cache results
                    self._cache[cache_key] = (results, datetime.now())
                    
                    print(f"✅ [Search] Found {len(results)} results")
                    return results
                else:
                    print(f"❌ [Search] API error: {response.status_code} - {response.text}")
                    return []
                    
        except Exception as e:
            print(f"❌ [Search] Error: {e}")
            return []
    
    def format_results_for_prompt(self, results: List[SearchResult]) -> str:
        """
        Format search results as text for inclusion in AI prompt.
        """
        if not results:
            return "No search results found."
        
        formatted = "📰 Web Search Results:\n"
        for i, r in enumerate(results, 1):
            formatted += f"\n{i}. **{r.title}**\n"
            formatted += f"   Source: {r.source or 'Unknown'}\n"
            formatted += f"   {r.snippet}\n"
            if r.published_date:
                formatted += f"   Published: {r.published_date}\n"
        
        return formatted
    
    def build_fact_check_response_format(self) -> str:
        """
        Return the expected response format for fact-checking responses.
        """
        return """
Based on the search results, provide a structured response:

1. **Verdict**: (Confirmed ✅ / Unconfirmed ⚠️ / False ❌ / Mixed 🔄)
2. **Summary**: Brief explanation (1-2 sentences)
3. **Evidence**: Key points from sources (2-3 bullets)
4. **Sources**: List the source names
5. **Confidence**: (High / Medium / Low)

If sources conflict, explain the discrepancy.
"""


# Global instance
_search_service: Optional[SearchService] = None


def get_search_service() -> Optional[SearchService]:
    """Get or create the global Search service instance."""
    global _search_service
    
    if _search_service is None:
        api_key = os.getenv("BRAVE_SEARCH_API_KEY")
        if not api_key:
            print("⚠️ [Search] BRAVE_SEARCH_API_KEY not set - search disabled")
            return None
        _search_service = SearchService(api_key)
    
    return _search_service
