"""
OAuth verification utilities for Google and Apple Sign-In.

Security Features:
- ✅ JWT signature verification (fetches public keys)
- ✅ Audience (aud) validation
- ✅ Issuer (iss) validation
- ✅ Expiry (exp) validation
- ✅ Required claims enforcement
"""
from typing import Optional, Dict
from functools import lru_cache
from datetime import datetime, timedelta
import requests
from jose import jwt, JWTError, jwk
from jose.utils import base64url_decode
import json

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

APPLE_ISSUER = "https://appleid.apple.com"
APPLE_KEYS_URL = f"{APPLE_ISSUER}/auth/keys"
GOOGLE_ISSUER = "https://accounts.google.com"
GOOGLE_TOKENINFO_URL = "https://oauth2.googleapis.com/tokeninfo"

# ⚠️ IMPORTANT: Set these to your actual values
APP_BUNDLE_ID = "app.raven.ios"  # iOS bundle ID (must match Xcode project)
GOOGLE_CLIENT_ID = None  # Set via environment variable


# ═══════════════════════════════════════════════════════════════════════════════
# GOOGLE TOKEN VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════

def verify_google_token(id_token: str, expected_client_id: Optional[str] = None) -> Optional[Dict]:
    """
    Verify Google ID token and extract user info.
    
    Security checks:
    - Token signature (via Google's tokeninfo endpoint)
    - Audience validation (if expected_client_id provided)
    - Expiry validation
    
    Returns dict with:
        - sub: Google user ID
        - email: User email
        - name: Full name
        - email_verified: Whether email is verified
    """
    try:
        # Verify token with Google's tokeninfo endpoint
        response = requests.get(
            f'{GOOGLE_TOKENINFO_URL}?id_token={id_token}',
            timeout=10
        )
        
        if response.status_code != 200:
            print(f"❌ Google token verification failed: {response.status_code}")
            return None
        
        user_info = response.json()
        
        # Validate required fields
        if 'sub' not in user_info or 'email' not in user_info:
            print("❌ Invalid Google token: missing required fields")
            return None
        
        # ✅ Audience validation (if client ID provided)
        if expected_client_id and user_info.get('aud') != expected_client_id:
            print(f"❌ Google token: audience mismatch. Expected {expected_client_id}, got {user_info.get('aud')}")
            return None
        
        # ✅ Expiry validation
        exp = user_info.get('exp')
        if exp and int(exp) < datetime.utcnow().timestamp():
            print("❌ Google token expired")
            return None
        
        print(f"✅ Google token verified for user: {user_info.get('email')}")
        return user_info
        
    except requests.RequestException as e:
        print(f"❌ Google token verification network error: {e}")
        return None
    except Exception as e:
        print(f"❌ Google token verification error: {e}")
        return None


# ═══════════════════════════════════════════════════════════════════════════════
# APPLE TOKEN VERIFICATION (SECURE)
# ═══════════════════════════════════════════════════════════════════════════════

@lru_cache(maxsize=1)
def _fetch_apple_public_keys() -> Dict:
    """
    Fetch Apple's public keys for JWT verification.
    Cached to avoid repeated network calls.
    
    Returns JWK Set as dict.
    """
    try:
        response = requests.get(APPLE_KEYS_URL, timeout=10)
        response.raise_for_status()
        keys = response.json()
        print(f"✅ Fetched {len(keys.get('keys', []))} Apple public keys")
        return keys
    except Exception as e:
        print(f"❌ Failed to fetch Apple public keys: {e}")
        return {"keys": []}


def _get_apple_signing_key(token: str) -> Optional[str]:
    """
    Get the correct Apple public key for a JWT based on its 'kid' header.
    """
    try:
        # Decode header without verification to get 'kid'
        header = jwt.get_unverified_header(token)
        kid = header.get('kid')
        
        if not kid:
            print("❌ Apple token missing 'kid' in header")
            return None
        
        # Find matching key in Apple's JWK Set
        keys = _fetch_apple_public_keys()
        for key in keys.get('keys', []):
            if key.get('kid') == kid:
                # Convert JWK to PEM format
                return jwk.construct(key).public_key()
        
        print(f"❌ No Apple key found for kid: {kid}")
        return None
        
    except Exception as e:
        print(f"❌ Error getting Apple signing key: {e}")
        return None


def verify_apple_token(identity_token: str, expected_audience: Optional[str] = None) -> Optional[Dict]:
    """
    Verify Apple identity token with FULL security checks.
    
    Security checks:
    - ✅ JWT signature verification (using Apple's public keys)
    - ✅ Issuer validation (must be https://appleid.apple.com)
    - ✅ Audience validation (must match app bundle ID)
    - ✅ Expiry validation
    - ✅ Required claims enforcement
    
    Returns dict with:
        - sub: Apple user ID (stable, unique per user per app)
        - email: User email (may be privaterelay if user hid email)
        - is_private_email: Whether email is Apple's private relay
    """
    audience = expected_audience or APP_BUNDLE_ID
    
    try:
        # Step 1: Get the signing key
        public_key = _get_apple_signing_key(identity_token)
        if not public_key:
            return None
        
        # Step 2: Verify and decode with FULL validation
        decoded = jwt.decode(
            identity_token,
            public_key,
            algorithms=["RS256"],
            audience=audience,      # ✅ Audience check
            issuer=APPLE_ISSUER,    # ✅ Issuer check
            options={
                "verify_signature": True,   # ✅ CRITICAL: Verify signature
                "verify_exp": True,         # ✅ Check expiry
                "verify_iat": True,         # ✅ Check issued-at
                "verify_aud": True,         # ✅ Check audience
                "verify_iss": True,         # ✅ Check issuer
                "require": ["sub", "aud", "iss", "exp", "iat"]
            }
        )
        
        # Step 3: Extract user info
        email = decoded.get('email')
        is_private_email = email.endswith('@privaterelay.appleid.com') if email else False
        
        user_info = {
            'sub': decoded['sub'],
            'email': email,
            'is_private_email': is_private_email,
            'email_verified': decoded.get('email_verified', False),
        }
        
        print(f"✅ Apple token verified for user: {user_info['sub'][:16]}...")
        return user_info
        
    except jwt.ExpiredSignatureError:
        print("❌ Apple token expired")
        return None
    except JWTError as e:
        error_msg = str(e).lower()
        if 'audience' in error_msg:
            print(f"❌ Apple token: invalid audience (expected {audience})")
        elif 'issuer' in error_msg:
            print(f"❌ Apple token: invalid issuer (expected {APPLE_ISSUER})")
        else:
            print(f"❌ Apple token JWT error: {e}")
        return None
    except Exception as e:
        print(f"❌ Apple token verification error: {e}")
        return None


def clear_apple_keys_cache():
    """
    Clear the cached Apple public keys.
    Call this if you suspect keys have rotated.
    """
    _fetch_apple_public_keys.cache_clear()
    print("🔄 Apple public keys cache cleared")
