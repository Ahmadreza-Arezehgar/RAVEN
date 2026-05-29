from passlib.context import CryptContext
from jose import JWTError, jwt
from datetime import datetime, timedelta
from typing import Optional
import secrets
import os

# JWT Configuration
# CRITICAL: In production, JWT_SECRET MUST come from Secret Manager
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
SECRET_KEY = os.getenv("JWT_SECRET")

if ENVIRONMENT == "production":
    if not SECRET_KEY:
        raise RuntimeError(
            "❌ CRITICAL: JWT_SECRET must be set in production! "
            "App will NOT start without a secure signing key."
        )
    print("✅ [Auth] JWT_SECRET loaded from environment")
else:
    # Development fallback: use a stable key so tokens survive server restart
    if not SECRET_KEY:
        SECRET_KEY = "dev-secret-key-change-in-production-abc123xyz789"
        print("⚠️  [Auth] Using dev fallback JWT_SECRET (development only)")

ALGORITHM = "HS256"

# 🔴 ROUND 71 S27: shortened access-token TTL from 7d → 30min.
# Previously 10080 minutes defeated the round-13 jti + tokens_invalidated_at
# revocation defense — a leaked JWT remained valid for a full week
# after logout / password-reset. iOS already has a working refresh-
# token rotation loop in `KeychainService.refreshAccessToken`, so
# background-mode 401s should self-heal via that path.
# Refresh tokens: Effectively permanent — only invalidated on explicit sign-out
# or app uninstall. Revocation is handled via DB (revoke_refresh_token).
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "30"))
REFRESH_TOKEN_EXPIRE_DAYS = int(os.getenv("REFRESH_TOKEN_EXPIRE_DAYS", "3650"))


pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(password: str) -> str:
    """
    Hash password using bcrypt.
    
    Args:
        password: Plain text password
        
    Returns:
        Hashed password
    """
    return pwd_context.hash(password)

def verify_password(plain_password: str, hashed_password: str) -> bool:
    """
    Verify password against hash.
    
    Args:
        plain_password: Plain text password
        hashed_password: Hashed password from database
        
    Returns:
        True if password matches
    """
    return pwd_context.verify(plain_password, hashed_password)

def create_access_token(data: dict, expires_delta: Optional[timedelta] = None):
    """
    Create JWT access token with proper claims.
    
    Args:
        data: Data to encode in token (typically {"sub": user_id})
        expires_delta: Optional expiration time
        
    Returns:
        JWT token string
    """
    to_encode = data.copy()
    now = datetime.utcnow()
    
    if expires_delta:
        expire = now + expires_delta
    else:
        expire = now + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    
    # Standard JWT claims for security
    to_encode.update({
        "exp": expire,           # Expiration time
        "iat": now,              # Issued at
        "iss": "hybrid-messenger",  # Issuer
        "aud": "hybrid-messenger-app",  # Audience
        "jti": secrets.token_urlsafe(16),  # JWT ID (unique per token)
        "type": "access",  # Token type for validation
    })
    
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt


def create_refresh_token(data: dict, expires_delta: Optional[timedelta] = None):
    """
    DEPRECATED: Use create_opaque_refresh_token instead for DB-backed tokens.
    Kept for backward compatibility during migration.
    """
    to_encode = data.copy()
    now = datetime.utcnow()
    
    if expires_delta:
        expire = now + expires_delta
    else:
        expire = now + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    
    to_encode.update({
        "exp": expire,
        "iat": now,
        "iss": "hybrid-messenger",
        "aud": "hybrid-messenger-app",
        "jti": secrets.token_urlsafe(16),
        "type": "refresh",
    })
    
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt


# ==================== OPAQUE REFRESH TOKENS (DB-backed) ====================

import hashlib

def generate_opaque_refresh_token() -> str:
    """
    Generate a cryptographically secure opaque refresh token.
    
    Returns:
        64-character hex string (32 bytes of entropy)
    """
    return secrets.token_hex(32)


def hash_refresh_token(token: str) -> str:
    """
    Hash refresh token using SHA256 for secure DB storage.
    
    Args:
        token: Raw refresh token
        
    Returns:
        SHA256 hash as hex string (64 characters)
    """
    return hashlib.sha256(token.encode()).hexdigest()


def create_db_refresh_token(
    db,
    user_id: str,
    device_id: str = None,
    device_name: str = None,
    ip_address: str = None,
    expires_days: int = None
) -> str:
    """
    Create opaque refresh token and store hash in DB.
    
    Args:
        db: Database session
        user_id: User ID to associate with token
        device_id: Optional device identifier
        device_name: Optional device name (e.g., "iPhone 15 Pro")
        ip_address: Client IP for audit
        expires_days: Override default expiration
        
    Returns:
        Raw opaque token (to be sent to client)
    """
    from models import RefreshToken
    
    # Generate opaque token
    raw_token = generate_opaque_refresh_token()
    token_hash = hash_refresh_token(raw_token)
    
    # Calculate expiration
    expire_days = expires_days or REFRESH_TOKEN_EXPIRE_DAYS
    expires_at = datetime.utcnow() + timedelta(days=expire_days)
    
    # Create DB record
    refresh_token = RefreshToken(
        user_id=user_id,
        token_hash=token_hash,
        expires_at=expires_at,
        device_id=device_id,
        device_name=device_name,
        ip_address=ip_address
    )
    
    db.add(refresh_token)
    db.commit()
    
    return raw_token


def validate_and_rotate_refresh_token(
    db,
    raw_token: str, 
    device_name: str = None,
    ip_address: str = None
) -> tuple[Optional[str], Optional[str]]:
    """
    Validate refresh token, rotate it, and detect theft.
    
    Token Rotation Security:
    1. Each refresh token can only be used ONCE
    2. Using a token generates a new token and invalidates the old one
    3. If an old (already-rotated) token is reused = THEFT DETECTED
       → All user tokens are revoked immediately
    
    Args:
        db: Database session
        raw_token: Raw token from client
        device_name: Device name for new token
        ip_address: IP address for audit
        
    Returns:
        Tuple of (user_id, new_refresh_token) or (None, None) if invalid
    """
    from models import RefreshToken
    
    token_hash = hash_refresh_token(raw_token)
    
    # Find the token
    refresh_token = db.query(RefreshToken).filter(
        RefreshToken.token_hash == token_hash
    ).first()
    
    if not refresh_token:
        return None, None
    
    # Check if token has been revoked
    if refresh_token.revoked_at is not None:
        print(f"🚨 [Security] Revoked token reuse attempt for user {refresh_token.user_id}")
        return None, None
    
    # Check expiration
    if refresh_token.expires_at <= datetime.utcnow():
        print(f"⏰ [Auth] Expired refresh token for user {refresh_token.user_id}")
        return None, None
    
    # 🚨 THEFT DETECTION: Token already replaced = someone stole it!
    if refresh_token.replaced_by is not None:
        print(f"🚨🚨🚨 [SECURITY ALERT] Token theft detected for user {refresh_token.user_id}!")
        print(f"    Token was already replaced - potential credential theft!")
        print(f"    Revoking ALL tokens for this user as security measure")
        
        # Revoke ALL tokens for this user
        now = datetime.utcnow()
        db.query(RefreshToken).filter(
            RefreshToken.user_id == refresh_token.user_id,
            RefreshToken.revoked_at == None
        ).update({RefreshToken.revoked_at: now})
        db.commit()
        
        return None, None
    
    # ✅ Token is valid - perform rotation
    user_id = refresh_token.user_id
    
    # Generate new token
    new_raw_token = generate_opaque_refresh_token()
    new_token_hash = hash_refresh_token(new_raw_token)
    expires_at = datetime.utcnow() + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    
    # Create new token record
    new_refresh_token = RefreshToken(
        user_id=user_id,
        token_hash=new_token_hash,
        expires_at=expires_at,
        device_id=refresh_token.device_id,  # Inherit device ID
        device_name=device_name or refresh_token.device_name,
        ip_address=ip_address or refresh_token.ip_address
    )
    db.add(new_refresh_token)
    db.flush()  # Get the new token's ID
    
    # Mark old token as replaced (but not revoked - allows detection)
    refresh_token.replaced_by = new_refresh_token.id
    
    db.commit()
    
    print(f"🔄 [Auth] Token rotated for user {user_id}")
    
    return user_id, new_raw_token


# Keep old function for backward compatibility during transition
def validate_db_refresh_token(db, raw_token: str) -> Optional[str]:
    """
    DEPRECATED: Use validate_and_rotate_refresh_token instead.
    This function doesn't rotate tokens - kept for transition period.
    """
    from models import RefreshToken
    
    token_hash = hash_refresh_token(raw_token)
    
    refresh_token = db.query(RefreshToken).filter(
        RefreshToken.token_hash == token_hash,
        RefreshToken.revoked_at == None,
        RefreshToken.replaced_by == None,  # Don't accept already-rotated tokens
        RefreshToken.expires_at > datetime.utcnow()
    ).first()
    
    if not refresh_token:
        return None
    
    return refresh_token.user_id


def revoke_refresh_token(db, raw_token: str) -> bool:
    """
    Revoke a refresh token (for logout).
    
    Args:
        db: Database session
        raw_token: Raw token from client
        
    Returns:
        True if revoked, False if not found
    """
    from models import RefreshToken
    
    token_hash = hash_refresh_token(raw_token)
    
    refresh_token = db.query(RefreshToken).filter(
        RefreshToken.token_hash == token_hash,
        RefreshToken.revoked_at == None
    ).first()
    
    if not refresh_token:
        return False
    
    refresh_token.revoked_at = datetime.utcnow()
    db.commit()
    
    return True


def revoke_all_user_tokens(db, user_id: str) -> int:
    """
    Revoke all refresh tokens for a user (for password change / security).
    
    Returns:
        Number of tokens revoked
    """
    from models import RefreshToken
    
    now = datetime.utcnow()
    count = db.query(RefreshToken).filter(
        RefreshToken.user_id == user_id,
        RefreshToken.revoked_at == None
    ).update({RefreshToken.revoked_at: now})
    
    db.commit()
    return count

# ==================== ACCESS-TOKEN REVOCATION (round 26 / Server F4) ====================
#
# 🔴 ROUND 26 (2026-05-16) — hacker-audit finding Server F4 (MEDIUM).
#
# Before this round, a freshly-minted access token was usable for the full
# 30-minute window even after the user explicitly logged out, rotated a
# credential, or the device was reported stolen. The refresh-token table
# had revocation (`RefreshToken.revoked_at`), but the access JWT was
# self-contained — decode_token would happily verify it from the
# signature alone.
#
# Practical attack: hacker steals an access token (via a man-in-the-
# middle on an old HTTPS cert pin, malware on the device, a logged-out
# session that wasn't wiped, etc.). User notices and hits "Log out all
# devices" — but the stolen token still works until its `exp`.
#
# Fix: maintain an in-memory revocation set keyed on the JWT `jti`
# (UUID-per-token) plus the original `exp`. `decode_token` rejects
# anything whose jti is in the set. A periodic sweeper (or the next
# call) drops entries whose `exp` has passed so the set can't grow
# unbounded — a revoked token that's already expired adds no security.
#
# In-memory is fine because:
#   1. Access tokens are short-lived (30min default). A pod restart
#      drops the revocation list, but every revoked token also expires
#      within 30min — gap is bounded and small.
#   2. Multi-pod deploys: the user's next /auth/logout hits ONE pod,
#      and the revocation only takes effect on that pod's traffic. The
#      other pods will see the revoked token until either (a) the
#      stolen-token attacker happens to route to a pod that received
#      the revoke, or (b) the token naturally expires. Acceptable for
#      the threat model — the user gets *some* immediate mitigation
#      without us needing a Redis dependency. A DB-backed JTI table is
#      a follow-up if traffic crosses the multi-pod threshold.
#
# `RefreshToken.revoked_at` is still the source of truth for "I am
# permanently logged out" — once the access token expires, no new
# access token can be minted from the revoked refresh row.

import threading
from typing import Tuple

_revoked_lock = threading.Lock()
# (jti, exp_unix_timestamp) — exp is used by the sweeper to evict
# entries that have aged out of usefulness. We track per-jti to keep
# membership tests O(1).
_revoked_access_jti: dict[str, int] = {}


def revoke_access_token(token: str) -> bool:
    """
    Decode `token` and add its `jti` to the revocation set so future
    calls to `decode_token(token)` return None.

    Used by /auth/logout. Returns True if a revocation was recorded;
    False if the token was already invalid (in which case revocation
    is moot — the token wouldn't have decoded anyway).
    """
    try:
        # `verify_exp=False` so we can revoke an already-expired token
        # idempotently (no error path the caller has to special-case).
        payload = jwt.decode(
            token,
            SECRET_KEY,
            algorithms=[ALGORITHM],
            issuer="hybrid-messenger",
            audience="hybrid-messenger-app",
            options={"verify_exp": False},
        )
    except JWTError:
        return False

    jti = payload.get("jti")
    exp = payload.get("exp")
    if not jti or not exp:
        return False
    try:
        exp_int = int(exp)
    except (TypeError, ValueError):
        return False

    with _revoked_lock:
        _revoked_access_jti[jti] = exp_int
        _sweep_revoked_locked()
    return True


def _sweep_revoked_locked() -> None:
    """Drop revoked entries that have passed their `exp` — called
    under `_revoked_lock`. Keeps the set's RAM bounded by the count
    of currently-live tokens."""
    if not _revoked_access_jti:
        return
    now = int(datetime.utcnow().timestamp())
    stale = [j for j, e in _revoked_access_jti.items() if e <= now]
    for j in stale:
        _revoked_access_jti.pop(j, None)


def is_access_jti_revoked(jti: str) -> bool:
    """O(1) membership check used inside `decode_token`."""
    if not jti:
        return False
    with _revoked_lock:
        # Opportunistic sweep so a quiet endpoint doesn't let the set
        # grow when there's no /auth/logout traffic.
        _sweep_revoked_locked()
        return jti in _revoked_access_jti


def decode_token(token: str) -> Optional[dict]:
    """
    Decode and verify JWT token with claim validation.

    Args:
        token: JWT token string

    Returns:
        Decoded token data or None if invalid

    🔴 ROUND 26 — Server F4: check the access-jti revocation set so
    a logged-out access token stops working immediately even though
    it hasn't reached `exp`.
    """
    try:
        payload = jwt.decode(
            token,
            SECRET_KEY,
            algorithms=[ALGORITHM],
            issuer="hybrid-messenger",
            audience="hybrid-messenger-app"
        )
    except JWTError:
        return None

    # Round 26 — Server F4: deny access tokens whose jti was revoked
    # (e.g. by /auth/logout). Refresh tokens have their own DB-backed
    # revocation in `RefreshToken.revoked_at` so we skip this check
    # for the refresh type.
    if payload.get("type") == "access":
        if is_access_jti_revoked(payload.get("jti", "")):
            return None

    return payload


# Optional dependency imports for get_current_user_optional
from fastapi import Header, Depends, HTTPException, status
from database import get_db
from sqlalchemy.orm import Session

def get_current_user_optional(authorization: str = Header(None), db: Session = Depends(get_db)):
    """
    Optional user extraction from JWT token.
    Returns None if no token or invalid token, instead of raising exception.
    """
    if not authorization or not authorization.startswith("Bearer "):
        return None
    
    token = authorization.replace("Bearer ", "")
    payload = decode_token(token)
    
    if not payload:
        return None
    
    user_id = payload.get("sub")
    if not user_id:
        return None
    
    # Import User model here to avoid circular import
    from models import User
    user = db.query(User).filter(User.id == user_id).first()
    return user



def get_current_user(authorization: str = Header(None), db: Session = Depends(get_db)):
    """
    Required user extraction from JWT token.
    Raises HTTPException if no token or invalid token.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated",
            headers={"WWW-Authenticate": "Bearer"}
        )
    
    token = authorization.replace("Bearer ", "")
    payload = decode_token(token)
    
    if not payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"}
        )
    
    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token payload",
            headers={"WWW-Authenticate": "Bearer"}
        )
    
    # Import User model here to avoid circular import
    from models import User
    user = db.query(User).filter(User.id == user_id).first()
    
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found",
            headers={"WWW-Authenticate": "Bearer"}
        )
    
    # ==================== MODERATION ENFORCEMENT ====================
    # Check if user is permanently banned
    if getattr(user, 'is_banned', False) and user.is_banned:
        reason = user.ban_reason or "Your account has been suspended for violating community guidelines."
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"Account suspended: {reason}"
        )
    
    # Check temporary restrictions — auto-clear if expired
    if getattr(user, 'is_restricted', False) and user.is_restricted:
        if user.restricted_until and user.restricted_until <= datetime.utcnow():
            # Restriction expired — auto-clear
            user.is_restricted = False
            user.restricted_until = None
            user.restriction_scope = None
            db.commit()
        # Note: active restrictions are enforced per-endpoint (posting, messaging, etc.)
        # We allow the request through but the user object carries restriction flags
    
    return user
