"""
Redis-based Rate Limiting Middleware for Production
Provides distributed rate limiting across multiple Cloud Run instances

Features:
- Atomic operations using Redis sorted sets
- Per-IP and per-user rate limiting
- Automatic cleanup of old entries
- Lockout mechanism after threshold exceeded
"""
from fastapi import HTTPException, Request
from typing import Optional
from datetime import datetime, timedelta
import os
import redis
from functools import wraps

# Environment detection
ENVIRONMENT = os.getenv('ENVIRONMENT', 'development')
REDIS_URL = os.getenv('REDIS_URL', 'redis://localhost:6379')

print(f"🔧 Environment: {ENVIRONMENT}")
print(f"🔧 Redis URL: {REDIS_URL}")


class RedisRateLimiter:
    """Production-grade distributed rate limiter using Redis"""
    
    def __init__(self, redis_url: str):
        try:
            self.redis = redis.from_url(
                redis_url,
                decode_responses=True,
                socket_connect_timeout=5,
            )
            # Test connection
            self.redis.ping()
            print(f"✅ Connected to Redis: {redis_url}")
        except Exception as e:
            print(f"❌ Redis connection failed: {e}")
            print(f"⚠️ Falling back to memory-based rate limiting")
            raise
    
    def check_rate_limit(
        self,
        identifier: str,
        max_attempts: int = 5,
        window_minutes: int = 15,
        lockout_minutes: int = 30
    ) -> None:
        """
        Check if request should be rate limited
        
        Args:
            identifier: Unique identifier (IP:username, IP, etc.)
            max_attempts: Maximum attempts allowed in window
            window_minutes: Time window for counting attempts
            lockout_minutes: How long to lock out after exceeding limit
            
        Raises:
            HTTPException: 429 if rate limit exceeded
        """
        now = datetime.utcnow().timestamp()
        
        # Check lockout
        lockout_key = f"lockout:{identifier}"
        if self.redis.exists(lockout_key):
            ttl = self.redis.ttl(lockout_key)
            raise HTTPException(
                status_code=429,
                detail="Too many attempts. Try again later.",
                headers={"Retry-After": str(ttl)}
            )
        
        # Track attempts with sorted set (atomic operations)
        attempts_key = f"attempts:{identifier}"
        cutoff = now - (window_minutes * 60)
        
        # Pipeline for atomic operations
        pipe = self.redis.pipeline()
        
        # Remove old attempts
        pipe.zremrangebyscore(attempts_key, 0, cutoff)
        
        # Count recent attempts
        pipe.zcard(attempts_key)
        
        # Execute pipeline
        results = pipe.execute()
        count = results[1]  # Result of zcard
        
        if count >= max_attempts:
            # Set lockout
            self.redis.setex(
                lockout_key,
                timedelta(minutes=lockout_minutes),
                "locked"
            )
            
            lockout_seconds = lockout_minutes * 60
            print(f"🚫 Rate limit exceeded for {identifier[:20]}... - locked out for {lockout_minutes} minutes")
            
            raise HTTPException(
                status_code=429,
                detail="Too many attempts. Try again later.",
                headers={"Retry-After": str(lockout_seconds)}
            )
        
        # Add this attempt (timestamp as both score and member)
        self.redis.zadd(attempts_key, {str(now): now})
        
        # Set expiry on attempts key
        self.redis.expire(attempts_key, window_minutes * 60)
        
        attempts_left = max_attempts - (count + 1)
        if attempts_left <= 2:
            print(f"⚠️ Rate limit check: {identifier[:20]}... - {attempts_left} attempts remaining")
    
    def reset(self, identifier: str) -> None:
        """Reset rate limit for identifier (e.g., after successful login)"""
        attempts_key = f"attempts:{identifier}"
        lockout_key = f"lockout:{identifier}"
        
        self.redis.delete(attempts_key)
        self.redis.delete(lockout_key)
        
        print(f"🔄 Reset rate limit for {identifier[:20]}...")


# Global rate limiter instance
_redis_limiter: Optional[RedisRateLimiter] = None


def get_rate_limiter() -> RedisRateLimiter:
    """
    Get rate limiter instance (singleton pattern)
    Creates Redis connection on first call
    """
    global _redis_limiter
    
    if _redis_limiter is None:
        if ENVIRONMENT == 'production':
            try:
                _redis_limiter = RedisRateLimiter(REDIS_URL)
            except Exception as e:
                print(f"❌ Failed to create Redis rate limiter: {e}")
                print(f"⚠️ Rate limiting will not work properly in production!")
                # Import fallback
                from middleware.rate_limit import rate_limiter as memory_limiter
                return memory_limiter
        else:
            # Development: use memory-based limiter
            print("ℹ️ Using memory-based rate limiter (development mode)")
            from middleware.rate_limit import rate_limiter as memory_limiter
            return memory_limiter
    
    return _redis_limiter


def rate_limit_check(
    request: Request,
    identifier: Optional[str] = None,
    max_attempts: int = 5,
    window_minutes: int = 15,
    lockout_minutes: int = 30
):
    """
    Decorator-friendly rate limit check
    
    Usage:
        @router.post("/api/auth/login")
        def login(request: Request, ...):
            rate_limit_check(request, f"login:{request.client.host}")
            ...
    """
    limiter = get_rate_limiter()
    
    if identifier is None:
        # Default to IP address
        identifier = f"generic:{request.client.host}"
    
    limiter.check_rate_limit(
        identifier=identifier,
        max_attempts=max_attempts,
        window_minutes=window_minutes,
        lockout_minutes=lockout_minutes
    )
