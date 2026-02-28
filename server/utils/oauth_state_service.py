"""
OAuth State Service - CSRF Protection

Provides state parameter management for OAuth flows to prevent CSRF attacks.

Usage:
1. Before redirecting to OAuth provider:
   state = generate_oauth_state(user_session_id)
   redirect_url = f"{oauth_url}&state={state}"

2. On OAuth callback:
   if not validate_oauth_state(request.state):
       raise HTTPException(401, "Invalid state parameter")
"""
from typing import Optional, Dict
from datetime import datetime, timedelta
import secrets
import hashlib

# In production, replace with Redis or database storage
_state_store: Dict[str, Dict] = {}

# Configuration
STATE_EXPIRY_MINUTES = 10
STATE_TOKEN_BYTES = 32


def generate_oauth_state(
    session_hint: Optional[str] = None,
    extra_data: Optional[Dict] = None
) -> str:
    """
    Generate a cryptographically secure state parameter.
    
    Args:
        session_hint: Optional session identifier to bind state to
        extra_data: Optional data to associate with this state
        
    Returns:
        Secure random state token (URL-safe base64)
    """
    state = secrets.token_urlsafe(STATE_TOKEN_BYTES)
    
    _state_store[state] = {
        "session_hint": session_hint,
        "extra_data": extra_data or {},
        "created_at": datetime.utcnow(),
        "expires_at": datetime.utcnow() + timedelta(minutes=STATE_EXPIRY_MINUTES)
    }
    
    # Cleanup old states periodically
    _cleanup_expired_states()
    
    return state


def validate_oauth_state(state: str) -> Optional[Dict]:
    """
    Validate and consume a state parameter.
    
    Args:
        state: The state parameter from OAuth callback
        
    Returns:
        Dict with session_hint and extra_data if valid, None otherwise
        
    Note: State is consumed on validation (single-use)
    """
    if not state:
        return None
    
    entry = _state_store.pop(state, None)
    
    if not entry:
        print(f"⚠️ OAuth state not found: {state[:16]}...")
        return None
    
    # Check expiry
    if datetime.utcnow() > entry["expires_at"]:
        print(f"⚠️ OAuth state expired: {state[:16]}...")
        return None
    
    print(f"✅ OAuth state validated: {state[:16]}...")
    return {
        "session_hint": entry.get("session_hint"),
        "extra_data": entry.get("extra_data", {})
    }


def _cleanup_expired_states():
    """
    Remove expired state entries.
    Called periodically during state generation.
    """
    now = datetime.utcnow()
    expired = [
        state for state, data in _state_store.items()
        if data["expires_at"] < now
    ]
    
    for state in expired:
        del _state_store[state]
    
    if expired:
        print(f"🧹 Cleaned up {len(expired)} expired OAuth states")


def generate_pkce_challenge() -> tuple[str, str]:
    """
    Generate PKCE (Proof Key for Code Exchange) parameters.
    
    Returns:
        Tuple of (code_verifier, code_challenge)
        
    Use code_verifier when exchanging auth code for tokens.
    Use code_challenge in initial authorization request.
    """
    # Generate random verifier
    code_verifier = secrets.token_urlsafe(32)
    
    # Create SHA256 challenge
    verifier_bytes = code_verifier.encode('ascii')
    challenge_bytes = hashlib.sha256(verifier_bytes).digest()
    
    # Base64url encode (without padding)
    import base64
    code_challenge = base64.urlsafe_b64encode(challenge_bytes).rstrip(b'=').decode('ascii')
    
    return code_verifier, code_challenge
