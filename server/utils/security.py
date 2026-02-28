"""
Security Utilities
Helpers for secure IP extraction, log sanitization, and environment detection
"""
import os
import hashlib
from fastapi import Request
from typing import Optional


def get_client_ip(request: Request) -> str:
    """
    Extract real client IP address, handling proxies correctly
    
    Args:
        request: FastAPI request object
        
    Returns:
        str: Client IP address
        
    Security Notes:
        - Only trusts X-Forwarded-For when TRUST_PROXY=true
        - In production (Cloud Run), proxies are trusted
        - In development, uses direct client IP
    """
    # Check if we should trust proxy headers
    trust_proxy = os.getenv("TRUST_PROXY", "false").lower() == "true"
    
    if trust_proxy:
        # Get first IP from X-Forwarded-For chain
        forwarded = request.headers.get("X-Forwarded-For")
        if forwarded:
            # X-Forwarded-For format: "client, proxy1, proxy2"
            return forwarded.split(",")[0].strip()
    
    # Fallback to direct client IP
    return request.client.host if request.client else "unknown"


def sanitize_for_log(identifier: str, length: int = 12) -> str:
    """
    Hash sensitive identifier for safe logging
    
    Args:
        identifier: Sensitive string (username, email, IP:username combo)
        length: Length of hash to return (default 12)
        
    Returns:
        str: SHA-256 hash prefix for logging
        
    Example:
        >>> sanitize_for_log("192.168.1.1:alice")
        'a3f5c8b2e9d1'
    """
    hash_obj = hashlib.sha256(identifier.encode('utf-8'))
    return hash_obj.hexdigest()[:length]


def is_production() -> bool:
    """
    Check if running in production environment
    
    Returns:
        bool: True if production, False otherwise
        
    Environment Variables:
        ENV: Set to 'production' for prod, 'development' for dev
    """
    return os.getenv("ENV", "development").lower() == "production"


def is_development() -> bool:
    """Check if running in development environment"""
    return not is_production()


def create_composite_identifier(ip: str, username: str) -> str:
    """
    Create composite identifier to prevent DoS lockout attacks
    
    Combines IP + normalized username so an attacker can't lock out
    a victim by trying their username from a different IP.
    
    Args:
        ip: Client IP address
        username: Username (will be normalized)
        
    Returns:
        str: Composite identifier "ip:username"
        
    Example:
        >>> create_composite_identifier("192.168.1.1", "Alice ")
        '192.168.1.1:alice'
    """
    normalized_username = username.lower().strip()
    return f"{ip}:{normalized_username}"


def safe_log(message: str, identifier: Optional[str] = None) -> None:
    """
    Log message with optional sensitive identifier sanitization
    
    Args:
        message: Log message
        identifier: Optional sensitive identifier to sanitize
        
    Examples:
        >>> safe_log("Rate limit check", "192.168.1.1:alice")
        # Dev: Rate limit check: 192.168.1.1:alice
        # Prod: Rate limit check: a3f5c8b2e9d1
    """
    if identifier:
        if is_development():
            print(f"{message}: {identifier}")
        else:
            safe_id = sanitize_for_log(identifier)
            print(f"{message}: {safe_id}")
    else:
        print(message)
