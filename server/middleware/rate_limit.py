"""
Rate Limiting Middleware
Prevents brute force attacks on authentication endpoints

Security Notes:
- Use composite identifiers (IP:username) to prevent DoS lockout
- Logs are sanitized in production to prevent data leakage
- Retry-After headers included for standard compliance
"""
from fastapi import HTTPException
from collections import defaultdict
from datetime import datetime, timedelta
from typing import Dict, List
import threading
import sys
import os

# Add parent directory to path for imports
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from utils.security import sanitize_for_log, is_development


class RateLimiter:
    """Thread-safe rate limiter with lockout support"""
    
    def __init__(self):
        self.attempts: Dict[str, List[datetime]] = defaultdict(list)
        self.lockouts: Dict[str, datetime] = {}
        self.lock = threading.Lock()
    
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
            identifier: Unique identifier (IP:username, IP, device_id, etc.)
            max_attempts: Maximum attempts allowed in window
            window_minutes: Time window for counting attempts
            lockout_minutes: How long to lock out after exceeding limit
            
        Raises:
            HTTPException: 429 if rate limit exceeded
        """
        with self.lock:
            now = datetime.utcnow()
            
            # Check if currently locked out
            if identifier in self.lockouts:
                lockout_until = self.lockouts[identifier]
                if now < lockout_until:
                    remaining_seconds = int((lockout_until - now).total_seconds())
                    remaining_minutes = remaining_seconds // 60
                    raise HTTPException(
                        status_code=429,
                        detail=f"Too many attempts. Try again later.",
                        headers={"Retry-After": str(remaining_seconds)}
                    )
                else:
                    # Lockout expired
                    del self.lockouts[identifier]
                    self.attempts[identifier] = []
            
            # Clean old attempts outside the window
            cutoff = now - timedelta(minutes=window_minutes)
            self.attempts[identifier] = [
                timestamp for timestamp in self.attempts[identifier]
                if timestamp > cutoff
            ]
            
            # Check if limit exceeded
            if len(self.attempts[identifier]) >= max_attempts:
                # Trigger lockout
                lockout_seconds = lockout_minutes * 60
                self.lockouts[identifier] = now + timedelta(minutes=lockout_minutes)
                
                # Sanitized logging
                if is_development():
                    print(f"🚫 Rate limit exceeded for {identifier} - locked out for {lockout_minutes} minutes")
                else:
                    safe_id = sanitize_for_log(identifier)
                    print(f"🚫 Rate limit exceeded for {safe_id} - locked out for {lockout_minutes} minutes")
                
                raise HTTPException(
                    status_code=429,
                    detail=f"Too many attempts. Try again later.",
                    headers={"Retry-After": str(lockout_seconds)}
                )
            
            # Record this attempt
            self.attempts[identifier].append(now)
            attempts_left = max_attempts - len(self.attempts[identifier])
            
            # Sanitized logging
            if is_development():
                print(f"⚠️ Rate limit check: {identifier} - {attempts_left} attempts remaining")
            else:
                safe_id = sanitize_for_log(identifier)
                print(f"⚠️ Rate limit check: {safe_id} - {attempts_left} attempts remaining")
    
    def reset(self, identifier: str) -> None:
        """Reset rate limit for identifier (e.g., after successful login)"""
        with self.lock:
            if identifier in self.attempts:
                del self.attempts[identifier]
            if identifier in self.lockouts:
                del self.lockouts[identifier]
    
    def cleanup_old_entries(self, hours: int = 24) -> None:
        """Clean up entries older than specified hours"""
        with self.lock:
            cutoff = datetime.utcnow() - timedelta(hours=hours)
            
            # Clean attempts
            for identifier in list(self.attempts.keys()):
                self.attempts[identifier] = [
                    t for t in self.attempts[identifier] if t > cutoff
                ]
                if not self.attempts[identifier]:
                    del self.attempts[identifier]
            
            # Clean expired lockouts
            now = datetime.utcnow()
            self.lockouts = {
                k: v for k, v in self.lockouts.items()
                if v > now
            }


# Global rate limiter instance
rate_limiter = RateLimiter()
