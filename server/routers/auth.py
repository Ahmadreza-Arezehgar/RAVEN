from fastapi import APIRouter, Depends, HTTPException, status, Request
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional, Tuple
from datetime import datetime
import re
import logging

logger = logging.getLogger(__name__)

from database import get_db
from jose import jwt, JWTError
from models import User
from auth import (
    hash_password, verify_password, create_access_token, create_refresh_token, 
    decode_token, SECRET_KEY, ALGORITHM,
    create_db_refresh_token, validate_db_refresh_token, revoke_refresh_token
)
from encryption import encrypt_text
from middleware.rate_limit import rate_limiter

router = APIRouter(prefix="/api/auth", tags=["authentication"])

# Request/Response models
class RegisterRequest(BaseModel):
    username: str
    password: str
    first_name: str
    last_name: str
    birth_year: int
    email: str  # ✅ Email is now REQUIRED
    phone: Optional[str] = None  # Optional, SMS disabled
    public_key: Optional[str] = None

class LoginRequest(BaseModel):
    username: str
    password: str

class TokenResponse(BaseModel):
    user_id: str
    username: Optional[str] = None  # Optional for OAuth users who haven't selected username
    token: str
    token_type: str = "bearer"


# ==================== PASSWORD VALIDATION ====================

# Common passwords to reject
COMMON_PASSWORDS = {
    '123456', '12345678', '1234567890', 'password', 'password123',
    'qwerty', 'qwerty123', 'abc123', 'letmein', 'welcome',
    'admin', 'login', 'master', 'dragon', 'passw0rd',
    'iloveyou', 'sunshine', 'princess', 'football', 'monkey',
    'shadow', 'michael', 'jennifer', 'trustno1', '123123',
    '654321', 'superman', 'batman', 'whatever'
}

def validate_password(password: str, username: str = None) -> Tuple[bool, str]:
    """
    Validate password against strong password policy.
    
    Policy:
    - Minimum 10 characters
    - At least 1 uppercase letter (A-Z)
    - At least 1 lowercase letter (a-z)
    - At least 1 number (0-9)
    - At least 1 special character
    - Cannot contain username
    - Cannot be a common password
    
    Returns: (is_valid, error_message)
    """
    if len(password) < 10:
        return False, "Password must be at least 10 characters"
    
    if not re.search(r'[A-Z]', password):
        return False, "Password must contain at least one uppercase letter"
    
    if not re.search(r'[a-z]', password):
        return False, "Password must contain at least one lowercase letter"
    
    if not re.search(r'\d', password):
        return False, "Password must contain at least one number"
    
    if not re.search(r'[!@#$%^&*()_+\-=\[\]{}/?.,<>:;"|\\`~]', password):
        return False, "Password must contain at least one special character (!@#$%^&*()_+-=[]{}/?.,<>:;)"
    
    if username and username.lower() in password.lower():
        return False, "Password cannot contain your username"
    
    if password.lower() in COMMON_PASSWORDS:
        return False, "This password is too common. Please choose a stronger password"
    
    return True, ""


@router.post("/register", response_model=TokenResponse)
def register(req: RegisterRequest, request: Request, db: Session = Depends(get_db)):
    """
    Register a new user.
    
    - Requires email
    - Checks if username already exists
    - Hashes password with bcrypt
    - Encrypts sensitive fields (first_name, last_name, email, phone)
    - Returns JWT token
    """
    import hashlib
    import logging
    
    logger = logging.getLogger(__name__)
    
    try:
        # Rate limit: Prevent registration spam
        # Limit by IP address (5 registrations per 60 minutes)
        client_ip = request.client.host
        rate_limiter.check_rate_limit(
            identifier=f"register:{client_ip}",
            max_attempts=5,
            window_minutes=60,
            lockout_minutes=120
        )
        
        # Validate: email is required
        if not req.email:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Email is required"
            )
        
        # Validate email format
        if req.email and '@' not in req.email:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Invalid email format"
            )
        
        # Validate phone format (must include country code)
        if req.phone and not req.phone.startswith('+'):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Phone number must include country code (e.g., +1234567890)"
            )
        
        # Validate password strength (STRONG PASSWORD POLICY).
        # Phase 2A clients pre-stretch passwords with PBKDF2 and send
        # `RVNS1$<base64>` instead of the raw password. The strength
        # policy applies to the raw password and is enforced
        # client-side BEFORE stretching, so when we see the prefix we
        # just sanity-check the wire shape (44 chars of base64 +
        # padding == 32 raw bytes).
        if req.password.startswith("RVNS1$"):
            stretched_b64 = req.password[len("RVNS1$"):]
            if len(stretched_b64) != 44:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Malformed stretched password",
                )
        else:
            is_valid, error_msg = validate_password(req.password, req.username)
            if not is_valid:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=error_msg
                )

        # 🔐 Validate optional public_key BEFORE any DB write — same trust-boundary
        # rationale as in routers/devices.py register_device.
        if req.public_key is not None:
            from routers.devices import validate_public_key_b64
            validate_public_key_b64(req.public_key, field_name="public_key")
        
        # Check if username already exists
        existing_user = db.query(User).filter(User.username == req.username).first()
        if existing_user:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Username already taken"
            )
        
        # Create email hash for lookup (consistent across instances)
        # ✅ Use email_hash for duplicate check (encryption is non-deterministic!)
        email_hash = hashlib.sha256(req.email.lower().strip().encode()).hexdigest() if req.email else None
        
        # Check if email already exists using email_hash
        if email_hash:
            existing_email = db.query(User).filter(User.email_hash == email_hash).first()
            if existing_email:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Email already registered"
                )
        
        # Check if phone already exists (if provided)
        # Note: Phone uses E.164 format which is deterministic, but still use hash if available
        if req.phone:
            # For now, check by encrypted phone (TODO: add phone_hash column)
            existing_phone = db.query(User).filter(User.phone == encrypt_text(req.phone)).first()
            if existing_phone:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Phone number already registered"
                )
        
        # Create new user
        user = User(
            username=req.username,
            password_hash=hash_password(req.password),
            first_name=encrypt_text(req.first_name),
            last_name=encrypt_text(req.last_name),
            birth_year=req.birth_year,
            email=encrypt_text(req.email) if req.email else None,
            email_hash=email_hash,
            phone=encrypt_text(req.phone) if req.phone else None,
            public_key=req.public_key,
            created_at=datetime.utcnow()
        )
        
        db.add(user)
        db.commit()
        db.refresh(user)
        
        # ✅ Generate access token (JWT) and refresh token (opaque + DB)
        access_token = create_access_token({"sub": user.id})
        refresh_token = create_db_refresh_token(db, user_id=user.id, device_name="initial_registration")
        
        print(f"✅ Registered new user: {user.username} ({user.id})")
        
        # ✅ Verification email is sent by the client after registration
        # via /send-code endpoint (do NOT send here to avoid cooldown conflicts)
        
        return {
            "user_id": user.id,
            "username": user.username,
            "token": access_token,
            "refresh_token": refresh_token,
            "token_type": "bearer"
        }
    
    except HTTPException:
        # Re-raise FastAPI HTTP exceptions as-is
        raise
    except Exception as e:
        # Log the actual error for debugging
        logger.error(f"❌ Registration failed: {e}", exc_info=True)
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Registration failed. Please try again later."
        )

@router.post("/login")
def login(req: LoginRequest, request: Request, db: Session = Depends(get_db)):
    """
    Login existing user.
    
    - Verifies username and password
    - Updates last_login timestamp
    - Returns JWT access token + refresh token
    """
    # Rate limit: Prevent brute force attacks
    # Limit by IP:username combination (5 attempts per 15 minutes)
    client_ip = request.client.host
    identifier = f"login:{client_ip}:{req.username}"
    rate_limiter.check_rate_limit(
        identifier=identifier,
        max_attempts=5,
        window_minutes=15,
        lockout_minutes=30
    )
    
    # Find user by username
    user = db.query(User).filter(User.username == req.username).first()
    
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password"
        )
    
    # Verify password — and silently upgrade legacy bcrypt hashes to
    # Argon2id on the way through. The user never sees this happen,
    # but after one successful login their stored hash is the modern
    # GPU-resistant scheme.
    from auth import verify_and_maybe_rehash
    ok, fresh_hash = verify_and_maybe_rehash(req.password, user.password_hash)
    if not ok:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password"
        )
    if fresh_hash is not None:
        user.password_hash = fresh_hash
        logger.info("[auth] Migrated password hash to argon2id for user %s", user.id)

    # Update last login
    user.last_login = datetime.utcnow()
    db.commit()
    
    # Reset rate limit on successful login
    rate_limiter.reset(identifier)
    
    # ✅ Generate access token (JWT) and refresh token (opaque + DB)
    access_token = create_access_token({"sub": user.id})
    
    # Extract device info for session tracking
    user_agent = request.headers.get("User-Agent", "Unknown device")
    client_ip = request.client.host if request.client else None
    refresh_token = create_db_refresh_token(
        db, 
        user_id=user.id, 
        device_name=user_agent[:100],  # Limite device name length
        ip_address=client_ip
    )
    
    # ✅ Create security notification for login event
    from models import Notification
    import json
    
    user_agent = request.headers.get("User-Agent", "Unknown device")
    client_ip = request.client.host if request.client else "Unknown"
    
    # Use the new `security_alert` type so iOS routes through the
    # SECURITY_ALERT category (with the "Review" auth-required action)
    # instead of the legacy generic `security` bucket.
    security_notif = Notification(
        user_id=user.id,
        type="security_alert",
        data=json.dumps({
            "event": "new_login",
            "device": user_agent[:100],
            "ip": client_ip,
        }),
        timestamp=datetime.utcnow(),
        is_read=False
    )
    db.add(security_notif)
    db.commit()

    # Push side-effect — best effort, must never fail the login.
    if user.push_token:
        try:
            from services.apns_service import get_apns_service, APNsService
            gate = APNsService.should_send_push(user, "security_alert")
            if gate["allowed"]:
                import asyncio
                async def _emit():
                    apns = get_apns_service()
                    await apns.send_security_alert(
                        device_token=user.push_token,
                        title="🔐 New sign-in",
                        body=f"{user_agent[:80]} ({client_ip})",
                        event_id=str(security_notif.id),
                        push_environment=user.push_environment,
                    )
                # Don't block the response — fire-and-forget
                try:
                    asyncio.get_event_loop().create_task(_emit())
                except RuntimeError:
                    asyncio.run(_emit())
        except Exception as exc:
            print(f"⚠️ security_alert push failed (non-fatal): {exc}")

    print(f"✅ User logged in: {user.username} ({user.id})")
    print(f"🔐 Security notification created for login from {client_ip}")
    
    return {
        "user_id": user.id,
        "username": user.username,
        "token": access_token,
        "refresh_token": refresh_token,
        "token_type": "bearer"
    }


# ==================== REFRESH TOKEN ====================

class RefreshRequest(BaseModel):
    refresh_token: str


@router.post("/refresh")
def refresh_token_endpoint(req: RefreshRequest, request: Request, db: Session = Depends(get_db)):
    """
    Exchange refresh token for new access token AND new refresh token.
    
    Security Features:
    - Token Rotation: Each refresh token can only be used ONCE
    - Theft Detection: If an old token is reused, ALL user sessions are revoked
    - Long expiry: Refresh tokens valid for 90 days
    
    Supports both:
    - New: opaque tokens with rotation (recommended)
    - Legacy: JWT refresh tokens (for backward compatibility, no rotation)
    """
    from auth import validate_and_rotate_refresh_token, validate_db_refresh_token
    
    raw_token = req.refresh_token
    user_id = None
    new_refresh_token = None
    
    # Get client info for audit
    user_agent = request.headers.get("User-Agent", "Unknown device")
    client_ip = request.client.host if request.client else None
    
    # ✅ First, try DB-backed opaque token with ROTATION
    user_id, new_refresh_token = validate_and_rotate_refresh_token(
        db, 
        raw_token,
        device_name=user_agent[:100],
        ip_address=client_ip
    )
    
    if not user_id:
        # ✅ Fallback to legacy JWT validation for old tokens (no rotation).
        # Explicit expected_type="refresh" — decode_token defaults to access-only.
        payload = decode_token(raw_token, expected_type="refresh")

        if payload:
            user_id = payload.get("sub")
            # For legacy tokens, generate a new opaque refresh token to migrate them
            if user_id:
                from auth import create_db_refresh_token
                new_refresh_token = create_db_refresh_token(
                    db, 
                    user_id=user_id, 
                    device_name=f"migrated_{user_agent[:50]}",
                    ip_address=client_ip
                )
                print(f"🔄 [Auth] Migrated legacy JWT refresh token to opaque for user {user_id}")
    
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired refresh token"
        )
    
    # Verify user still exists
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found"
        )
    
    # ✅ Generate new access token
    new_access_token = create_access_token({"sub": user.id})
    
    print(f"🔄 Token refreshed for user: {user.username}")
    
    # Return both tokens - client MUST save the new refresh token!
    response = {
        "token": new_access_token,
        "token_type": "bearer"
    }
    
    if new_refresh_token:
        response["refresh_token"] = new_refresh_token
    
    return response


# ==================== OAUTH ENDPOINTS ====================

class OAuthGoogleRequest(BaseModel):
    id_token: str

class OAuthAppleRequest(BaseModel):
    identity_token: str
    authorization_code: str

class UsernameCheckResponse(BaseModel):
    available: bool

class SetUsernameRequest(BaseModel):
    username: str
    temp_token: str  # JWT token from OAuth flow

@router.post("/oauth/google", response_model=TokenResponse)
def oauth_google(req: OAuthGoogleRequest, db: Session = Depends(get_db)):
    """
    Authenticate user with Google OAuth.
    
    - Verifies Google ID token
    - Creates user if doesn't exist
    - Returns JWT token and requires_username flag
    """
    from utils.oauth_verification import verify_google_token
    
    # Verify Google token
    google_user = verify_google_token(req.id_token)
    if not google_user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Google token"
        )
    
    google_id = google_user['sub']
    email = google_user.get('email')
    first_name = google_user.get('given_name')
    last_name = google_user.get('family_name')
    
    # Check if user already exists
    user = db.query(User).filter(User.oauth_provider_id == google_id, User.oauth_provider == 'google').first()
    
    if user:
        # Existing user - update last login
        user.last_login = datetime.utcnow()
        db.commit()
        
        # ✅ Generate both access AND refresh tokens
        token = create_access_token({"sub": user.id})
        refresh_token = create_db_refresh_token(db, user_id=user.id, device_name="google_oauth")
        
        # Check if user has selected username
        if user.username:
            print(f"✅ Google OAuth: Existing user {user.username} logged in")
            return {
                "user_id": user.id,
                "username": user.username,
                "token": token,
                "refresh_token": refresh_token,
                "token_type": "bearer"
            }
        else:
            print(f"✅ Google OAuth: Existing user logged in (requires username)")
            return {
                "user_id": user.id,
                "username": None,
                "token": token,
                "refresh_token": refresh_token,
                "token_type": "bearer",
                "requires_username": True
            }
    else:
        # New user - create account without username
        # ✅ Google OAuth users are auto-verified (Google already verified their email)
        import hashlib
        email_hash = hashlib.sha256(email.lower().encode()).hexdigest() if email else None
        
        user = User(
            oauth_provider='google',
            oauth_provider_id=google_id,
            first_name=encrypt_text(first_name) if first_name else None,
            last_name=encrypt_text(last_name) if last_name else None,
            email=encrypt_text(email) if email else None,
            email_hash=email_hash,
            email_verified=True,  # ✅ Auto-verified for Google OAuth
            email_verified_at=datetime.utcnow(),
            verification_status='verified',
            created_at=datetime.utcnow(),
            last_login=datetime.utcnow()
        )
        
        db.add(user)
        db.commit()
        db.refresh(user)
        
        # ✅ Generate both access AND refresh tokens
        token = create_access_token({"sub": user.id})
        refresh_token = create_db_refresh_token(db, user_id=user.id, device_name="google_oauth_new")
        
        print(f"✅ Google OAuth: New user created (requires username)")
        
        # Return special response indicating username is needed
        return {
            "user_id": user.id,
            "username": None,
            "token": token,
            "refresh_token": refresh_token,
            "token_type": "bearer",
            "requires_username": True
        }

@router.post("/oauth/apple", response_model=TokenResponse)
def oauth_apple(req: OAuthAppleRequest, db: Session = Depends(get_db)):
    """
    Authenticate user with Apple OAuth.
    
    - Verifies Apple identity token
    - Creates user if doesn't exist
    - Returns JWT token and requires_username flag
    """
    try:
        from utils.oauth_verification import verify_apple_token
        
        print(f"🍎 Apple OAuth: Verifying token...")
        
        # Verify Apple token (uses default APP_BUNDLE_ID from oauth_verification)
        apple_user = verify_apple_token(req.identity_token)
        if not apple_user:
            print(f"❌ Apple OAuth: Token verification failed")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid Apple token"
            )
        
        apple_id = apple_user['sub']
        email = apple_user.get('email')
        
        print(f"🍎 Apple OAuth: Token verified, user: {apple_id[:16]}...")
        
        # Check if user already exists
        user = db.query(User).filter(User.oauth_provider_id == apple_id, User.oauth_provider == 'apple').first()
        
        if user:
            # Existing user - update last login
            user.last_login = datetime.utcnow()
            db.commit()
            
            # ✅ Generate both access AND refresh tokens
            token = create_access_token({"sub": user.id})
            refresh_token = create_db_refresh_token(db, user_id=user.id, device_name="apple_oauth")
            
            print(f"✅ Apple OAuth: Existing user {user.username} logged in")
            
            return {
                "user_id": user.id,
                "username": user.username,
                "token": token,
                "refresh_token": refresh_token,
                "token_type": "bearer"
            }
        else:
            # New user - create account without username
            # ✅ Apple OAuth users are auto-verified (Apple already verified their email)
            import hashlib
            email_hash = hashlib.sha256(email.lower().encode()).hexdigest() if email else None
            
            user = User(
                oauth_provider='apple',
                oauth_provider_id=apple_id,
                email=encrypt_text(email) if email else None,
                email_hash=email_hash,
                email_verified=True,  # ✅ Auto-verified for Apple OAuth
                email_verified_at=datetime.utcnow(),
                verification_status='verified',
                created_at=datetime.utcnow(),
                last_login=datetime.utcnow()
            )
            
            db.add(user)
            db.commit()
            db.refresh(user)
            
            # ✅ Generate both access AND refresh tokens
            token = create_access_token({"sub": user.id})
            refresh_token = create_db_refresh_token(db, user_id=user.id, device_name="apple_oauth_new")
            
            print(f"✅ Apple OAuth: New user created (requires username)")
            
            # Return special response indicating username is needed
            return {
                "user_id": user.id,
                "username": None,
                "token": token,
                "refresh_token": refresh_token,
                "token_type": "bearer",
                "requires_username": True
            }
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Apple OAuth EXCEPTION: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Apple OAuth error: {str(e)}"
        )

@router.get("/check-username", response_model=UsernameCheckResponse)
def check_username_availability(username: str, db: Session = Depends(get_db)):
    """
    Check if a username is available.
    """
    if not username or len(username) < 3:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Username must be at least 3 characters"
        )
    
    existing_user = db.query(User).filter(User.username == username).first()
    
    return UsernameCheckResponse(available=existing_user is None)

@router.post("/set-username")
def set_username(
    req: SetUsernameRequest,
    db: Session = Depends(get_db),
):
    """
    Set username for OAuth user.
    Requires authenticated JWT token passed in request body.
    """
    # Validate username
    if not req.username or len(req.username) < 3:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Username must be at least 3 characters"
        )
    
    # Check if username is taken
    existing_user = db.query(User).filter(User.username == req.username).first()
    if existing_user:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Username already taken"
        )
    
    # Extract user ID from temp token
    try:
        # Try with new claims first
        try:
            payload = jwt.decode(
                req.temp_token, 
                SECRET_KEY, 
                algorithms=[ALGORITHM],
                options={"verify_aud": False, "verify_iss": False}  # Backwards compatible
            )
        except JWTError:
            # Fallback for old tokens
            payload = jwt.decode(req.temp_token, SECRET_KEY, algorithms=[ALGORITHM])
        
        user_id = payload.get("sub")
        if not user_id:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid token"
            )
    except JWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token"
        )
    
    # Find user and update username
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    # Update username
    user.username = req.username
    db.commit()
    db.refresh(user)
    
    print(f"✅ Username set for user {user_id}: {req.username}")
    
    return {
        "success": True,
        "message": "Username set successfully",
        "user_id": user.id,
        "username": user.username
    }


# ==================== VERIFICATION ENDPOINTS ====================

class SendCodeRequest(BaseModel):
    """Request to send verification code."""
    identifier: str  # Email or phone (E.164)
    channel: str  # 'email' or 'sms'
    purpose: str  # 'verify_email', 'verify_phone', 'reset_password'


class VerifyCodeRequest(BaseModel):
    """Request to verify a code."""
    identifier: str  # Email or phone
    code: str  # 6-digit OTP or email token
    purpose: str


class ForgotPasswordRequest(BaseModel):
    """Request to initiate password reset."""
    identifier: str  # Email or phone


class ResetPasswordRequest(BaseModel):
    """Request to set new password."""
    identifier: str  # Email or phone
    code: str  # Verification token/OTP
    new_password: str


@router.post("/send-code")
def send_verification_code(
    req: SendCodeRequest,
    request: Request,
    db: Session = Depends(get_db)
):
    """
    Send verification code via email or SMS.
    
    Purposes:
    - 'registration': For new user signup (checks email not already used)
    - 'verify_email': For existing users to verify email
    - 'reset_password': For password recovery
    
    Anti-spam protections:
    - 60-second cooldown between sends
    - 10 codes per day limit
    - Rate limiting on IP
    """
    from services.verification_service import (
        create_verification_token, check_cooldown, check_daily_limit
    )
    from services.notification_service import get_notification_service
    from encryption import encrypt_text
    import hashlib
    
    # Rate limit by IP
    client_ip = request.client.host
    rate_limiter.check_rate_limit(
        identifier=f"send-code:{client_ip}",
        max_attempts=20,
        window_minutes=60,
        lockout_minutes=60
    )
    
    # ✅ SMS verification disabled - email only
    if req.channel != 'email':
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="SMS verification is disabled. Please use email."
        )
    
    # Validate purpose
    valid_purposes = ('registration', 'verify_email', 'reset_password')
    if req.purpose not in valid_purposes:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Purpose must be one of: {', '.join(valid_purposes)}"
        )
    
    # Normalize email
    email_lower = req.identifier.lower().strip()
    email_hash = hashlib.sha256(email_lower.encode()).hexdigest()
    
    # ==== REGISTRATION PURPOSE ====
    # For new signups: check that email is NOT already registered
    if req.purpose == 'registration':
        # Check by email_hash (covers both regular and OAuth users)
        existing_user = db.query(User).filter(User.email_hash == email_hash).first()
        
        if existing_user:
            # Don't reveal if it's OAuth or regular - just say email is taken
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="This email is already registered. Try signing in instead."
            )
        
        # For registration, we don't have a user yet
        # Create a temporary verification token linked to email
        token, error = create_verification_token(
            db=db,
            user_id=None,  # No user yet
            channel=req.channel,
            purpose='registration',
            sent_to=email_lower
        )
        
        if error:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=error
            )
        
        # Send verification email
        notification = get_notification_service()
        success = notification.send_registration_verification_email(email_lower, token)
        
        if not success:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Failed to send code. Please try again later"
            )
        
        print(f"📧 Sent registration code to {email_lower[:3]}***")
        
        return {
            "success": True,
            "message": "Verification code sent",
            "expires_in_seconds": 600  # 10 minutes
        }
    
    # ==== EXISTING USER PURPOSES (verify_email, reset_password) ====
    # Find user by email hash
    user = db.query(User).filter(User.email_hash == email_hash).first()
    
    logger.info(f"📧 [send-code] purpose={req.purpose} | email={req.identifier[:3]}*** | user_found={user is not None}")
    
    # For security: don't reveal if user exists (for reset_password)
    if req.purpose != 'reset_password' and not user:
        logger.warning(f"📧 [send-code] User not found for purpose={req.purpose}")
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    if not user:
        # Silently return success to prevent user enumeration
        logger.info(f"📧 [send-code] No user for reset_password — returning silent success")
        return {"success": True, "message": "If an account exists, a code was sent"}
    
    # Create verification token
    token, error = create_verification_token(
        db=db,
        user_id=user.id,
        channel=req.channel,
        purpose=req.purpose,
        sent_to=req.identifier
    )
    
    if error:
        logger.warning(f"📧 [send-code] Token creation failed: {error}")
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=error
        )
    
    logger.info(f"📧 [send-code] Token created for user={user.id[:8]}*** | purpose={req.purpose}")
    
    # Send notification (SMS is blocked above, so only email path here)
    notification = get_notification_service()
    
    if req.purpose == 'reset_password':
        success = notification.send_password_reset_email(req.identifier, token)
    else:
        success = notification.send_verification_email(req.identifier, token)
    
    if not success:
        logger.error(f"❌ [send-code] Email send FAILED for {req.identifier[:3]}*** | purpose={req.purpose}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to send code. Please try again later"
        )
    
    logger.info(f"✅ [send-code] Email sent successfully to {req.identifier[:3]}*** | purpose={req.purpose}")
    
    return {
        "success": True,
        "message": "Code sent successfully",
        "expires_in_seconds": 600  # 10 minutes
    }


@router.post("/verify-code")
def verify_code(
    req: VerifyCodeRequest,
    request: Request,
    db: Session = Depends(get_db)
):
    """
    Verify an OTP or email token.
    
    Purposes:
    - 'registration': Verify email for new user signup (no user yet)
    - 'verify_email': Existing user email verification
    - 'reset_password': Password reset flow
    
    Returns success flag and email_verified flag.
    """
    from services.verification_service import (
        verify_token, verify_registration_token, mark_email_verified, mark_phone_verified
    )
    
    # Rate limit
    client_ip = request.client.host
    rate_limiter.check_rate_limit(
        identifier=f"verify-code:{client_ip}",
        max_attempts=10,
        window_minutes=15,
        lockout_minutes=30
    )
    
    # ==== REGISTRATION PURPOSE ====
    # For new signups: just verify the code (no user exists yet)
    if req.purpose == 'registration':
        success, error = verify_registration_token(
            db=db,
            sent_to=req.identifier.lower().strip(),
            token=req.code
        )
        
        if error:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=error
            )
        
        print(f"✅ Registration email verified: {req.identifier[:3]}***")
        
        return {
            "success": True,
            "message": "Email verified. You can now complete registration.",
            "email_verified": True
        }
    
    # ==== EXISTING USER PURPOSES ====
    # Verify the code
    user_id, error = verify_token(
        db=db,
        sent_to=req.identifier,
        token=req.code,
        purpose=req.purpose
    )
    
    if error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=error
        )
    
    # Mark as verified based on purpose
    if req.purpose == 'verify_email':
        mark_email_verified(db, user_id)
        print(f"✅ Email verified for user {user_id}")
    elif req.purpose == 'verify_phone':
        mark_phone_verified(db, user_id)
        print(f"✅ Phone verified for user {user_id}")
    
    # Get user
    user = db.query(User).filter(User.id == user_id).first()
    
    # Generate new token
    token = create_access_token({"sub": user_id})
    
    return {
        "success": True,
        "message": "Verification successful",
        "user_id": user_id,
        "username": user.username if user else None,
        "email_verified": True,
        "full_access_token": token,  # iOS expects this key name
        "token_scope": "full"
    }


@router.post("/forgot-password")
def forgot_password(
    req: ForgotPasswordRequest,
    request: Request,
    db: Session = Depends(get_db)
):
    """
    Initiate password reset flow.
    
    Always returns success to prevent user enumeration.
    """
    from services.verification_service import create_verification_token
    from services.notification_service import get_notification_service
    from encryption import encrypt_text
    
    # Rate limit
    client_ip = request.client.host
    rate_limiter.check_rate_limit(
        identifier=f"forgot-password:{client_ip}",
        max_attempts=5,
        window_minutes=60,
        lockout_minutes=120
    )
    
    # Detect if email or phone
    is_email = '@' in req.identifier
    channel = 'email' if is_email else 'sms'
    
    # Find user using email_hash for reliable lookup
    import hashlib
    if is_email:
        email_lower = req.identifier.lower().strip()
        email_hash = hashlib.sha256(email_lower.encode()).hexdigest()
        user = db.query(User).filter(User.email_hash == email_hash).first()
    else:
        user = db.query(User).filter(
            (User.phone == encrypt_text(req.identifier)) | 
            (User.phone_e164 == req.identifier)
        ).first()
    
    # Always return same message (prevent enumeration)
    if not user:
        print(f"⚠️ Password reset requested for unknown: {req.identifier[:3]}***")
        return {
            "success": True,
            "message": "If this email exists, we sent a reset link."
        }
    
    # ==== CHECK FOR GOOGLE/OAUTH ACCOUNT ====
    # If account was created via Google, they don't have a password to reset
    if user.oauth_provider and not user.password_hash:
        # Return a specific error for OAuth-only accounts
        # This is intentionally revealed since user knows their own email
        provider_name = user.oauth_provider.title()  # 'google' -> 'Google'
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"This account uses {provider_name} sign-in. Use 'Continue with {provider_name}' instead."
        )
    
    # Create reset token
    token, error = create_verification_token(
        db=db,
        user_id=user.id,
        channel=channel,
        purpose='reset_password',
        sent_to=req.identifier
    )
    
    if error:
        # Return success anyway to prevent timing attacks
        return {
            "success": True,
            "message": "If this email exists, we sent a reset link."
        }
    
    # Send notification and check result
    notification = get_notification_service()
    
    if is_email:
        success = notification.send_password_reset_email(req.identifier, token)
    else:
        success = notification.send_password_reset_sms(req.identifier, token)
    
    if success:
        print(f"🔐 Password reset email sent to {req.identifier[:3]}***")
    else:
        # Log failure but still return success to prevent enumeration
        print(f"❌ Failed to send password reset email to {req.identifier[:3]}***")
    
    return {
        "success": True,
        "message": "If this email exists, we sent a reset link."
    }


@router.post("/reset-password")
def reset_password(
    req: ResetPasswordRequest,
    request: Request,
    db: Session = Depends(get_db)
):
    """
    Set new password after verification.
    
    - Validates password strength
    - Revokes all refresh tokens (security)
    - Returns new access token
    """
    from services.verification_service import verify_token, revoke_all_refresh_tokens
    
    # Rate limit
    client_ip = request.client.host
    rate_limiter.check_rate_limit(
        identifier=f"reset-password:{client_ip}",
        max_attempts=5,
        window_minutes=30,
        lockout_minutes=60
    )
    
    # Validate password strength
    is_valid, error_msg = validate_password(req.new_password)
    if not is_valid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=error_msg
        )
    
    # Verify the code
    user_id, error = verify_token(
        db=db,
        sent_to=req.identifier,
        token=req.code,
        purpose='reset_password'
    )
    
    if error:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=error
        )
    
    # Update password
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    user.password_hash = hash_password(req.new_password)
    db.commit()
    
    # Revoke all refresh tokens (security measure)
    revoked_count = revoke_all_refresh_tokens(db, user_id)
    
    # Generate new access token
    token = create_access_token({"sub": user_id})
    
    print(f"✅ Password reset for user {user_id} (revoked {revoked_count} refresh tokens)")
    
    return {
        "success": True,
        "message": "Password reset successful",
        "user_id": user_id,
        "token": token
    }


@router.post("/logout")
def logout(
    request: Request,
    db: Session = Depends(get_db)
):
    """
    Logout user by revoking refresh token.
    
    Note: Access tokens cannot be revoked (short-lived by design).
    """
    from services.verification_service import revoke_all_refresh_tokens
    from auth import decode_token
    
    # Get token from header
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Not authenticated"
        )
    
    token = auth_header.replace("Bearer ", "")
    payload = decode_token(token)
    
    if not payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token"
        )
    
    user_id = payload.get("sub")
    
    # Revoke all refresh tokens for this user (new DB-backed tokens)
    from auth import revoke_all_user_tokens
    revoked_count = revoke_all_user_tokens(db, user_id)
    
    print(f"🚪 User {user_id} logged out (revoked {revoked_count} refresh tokens)")
    
    return {
        "success": True,
        "message": "Logged out successfully"
    }
