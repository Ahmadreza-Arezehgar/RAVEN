"""
Verification Service - Secure OTP/Token Management

Features:
- SHA256 hashed tokens (never plaintext)
- 5-minute expiry
- Max 5 attempts per token
- 60-second cooldown between resends
- Daily limit (10 per email/phone)
"""

import hashlib
import secrets
import string
from datetime import datetime, timedelta
from typing import Optional, Tuple
from sqlalchemy.orm import Session
from sqlalchemy import func

from models import VerificationToken, User


# ==================== CONSTANTS ====================

OTP_LENGTH = 6
TOKEN_LENGTH = 32  # For email links
TOKEN_EXPIRY_MINUTES = 10  # OTP valid for 10 minutes
COOLDOWN_SECONDS = 60  # Resend cooldown
MAX_ATTEMPTS = 5  # Max wrong attempts before lockout
DAILY_LIMIT = 10


# ==================== HELPERS ====================

def _hash_token(token: str) -> str:
    """Hash token using SHA256."""
    return hashlib.sha256(token.encode()).hexdigest()


def _generate_otp() -> str:
    """Generate 6-digit numeric OTP."""
    return ''.join(secrets.choice(string.digits) for _ in range(OTP_LENGTH))


def _generate_token() -> str:
    """Generate secure random token for email links."""
    return secrets.token_urlsafe(TOKEN_LENGTH)


# ==================== CORE FUNCTIONS ====================

def check_cooldown(db: Session, sent_to: str, purpose: str) -> Optional[int]:
    """
    Check if user is in cooldown period.
    
    Returns: Seconds remaining in cooldown, or None if no cooldown.
    """
    now = datetime.utcnow()
    
    # Find most recent token for this destination + purpose
    token = db.query(VerificationToken).filter(
        VerificationToken.sent_to == sent_to,
        VerificationToken.purpose == purpose,
        VerificationToken.cooldown_until > now
    ).order_by(VerificationToken.created_at.desc()).first()
    
    if token and token.cooldown_until:
        remaining = (token.cooldown_until - now).total_seconds()
        return max(0, int(remaining))
    
    return None


def check_daily_limit(db: Session, sent_to: str, purpose: str) -> bool:
    """
    Check if daily limit reached for this destination.
    
    Returns: True if limit reached, False if OK to send.
    """
    today_start = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    
    count = db.query(VerificationToken).filter(
        VerificationToken.sent_to == sent_to,
        VerificationToken.purpose == purpose,
        VerificationToken.created_at >= today_start
    ).count()
    
    return count >= DAILY_LIMIT


def create_verification_token(
    db: Session,
    user_id: str,
    channel: str,  # 'email' or 'sms'
    purpose: str,  # 'verify_email', 'verify_phone', 'reset_password'
    sent_to: str,  # Email or phone
) -> Tuple[Optional[str], Optional[str]]:
    """
    Create a new verification token.
    
    Returns: (token, error_message)
    - For SMS: token is 6-digit OTP
    - For email: token is secure URL token
    """
    # Check cooldown
    cooldown = check_cooldown(db, sent_to, purpose)
    if cooldown:
        return None, f"Please wait {cooldown} seconds before requesting a new code"
    
    # Check daily limit
    if check_daily_limit(db, sent_to, purpose):
        return None, "Daily limit reached. Please try again tomorrow"
    
    # Invalidate any existing unused tokens
    db.query(VerificationToken).filter(
        VerificationToken.sent_to == sent_to,
        VerificationToken.purpose == purpose,
        VerificationToken.consumed_at.is_(None)
    ).update({"consumed_at": datetime.utcnow()})
    
    # Generate 6-digit OTP for both email and SMS
    raw_token = _generate_otp()
    
    # Create token record
    token_record = VerificationToken(
        user_id=user_id,
        channel=channel,
        purpose=purpose,
        token_hash=_hash_token(raw_token),
        sent_to=sent_to,
        expires_at=datetime.utcnow() + timedelta(minutes=TOKEN_EXPIRY_MINUTES),
        cooldown_until=datetime.utcnow() + timedelta(seconds=COOLDOWN_SECONDS),
    )
    
    db.add(token_record)
    db.commit()
    
    return raw_token, None


def verify_token(
    db: Session,
    sent_to: str,
    token: str,
    purpose: str,
) -> Tuple[Optional[str], Optional[str]]:
    """
    Verify a token/OTP.
    
    Returns: (user_id, error_message)
    """
    now = datetime.utcnow()
    token_hash = _hash_token(token)
    
    # Find matching token
    token_record = db.query(VerificationToken).filter(
        VerificationToken.sent_to == sent_to,
        VerificationToken.purpose == purpose,
        VerificationToken.consumed_at.is_(None),
        VerificationToken.expires_at > now,
    ).order_by(VerificationToken.created_at.desc()).first()
    
    if not token_record:
        return None, "Code expired. Resend a new code."
    
    # Check attempts
    if token_record.attempts >= MAX_ATTEMPTS:
        return None, "Too many attempts. Resend a new code."
    
    # Verify hash
    if token_record.token_hash != token_hash:
        # Increment attempts
        token_record.attempts += 1
        db.commit()
        
        remaining = MAX_ATTEMPTS - token_record.attempts
        if remaining > 0:
            return None, f"Code is incorrect. Try again. ({remaining} attempts left)"
        else:
            return None, "Too many attempts. Resend a new code."
    
    # Success! Mark as consumed
    token_record.consumed_at = now
    db.commit()
    
    return token_record.user_id, None


def verify_registration_token(
    db: Session,
    sent_to: str,
    token: str,
) -> Tuple[bool, Optional[str]]:
    """
    Verify a registration token (for new signups where no user exists yet).
    
    Returns: (success, error_message)
    """
    now = datetime.utcnow()
    token_hash = _hash_token(token)
    
    # Find matching token for registration purpose (user_id is NULL)
    token_record = db.query(VerificationToken).filter(
        VerificationToken.sent_to == sent_to,
        VerificationToken.purpose == 'registration',
        VerificationToken.user_id.is_(None),  # Registration tokens have no user
        VerificationToken.consumed_at.is_(None),
        VerificationToken.expires_at > now,
    ).order_by(VerificationToken.created_at.desc()).first()
    
    if not token_record:
        return False, "Code expired. Resend a new code."
    
    # Check attempts
    if token_record.attempts >= MAX_ATTEMPTS:
        return False, "Too many attempts. Please request a new code"
    
    # Verify hash
    if token_record.token_hash != token_hash:
        # Increment attempts
        token_record.attempts += 1
        db.commit()
        
        remaining = MAX_ATTEMPTS - token_record.attempts
        if remaining > 0:
            return False, f"Code is incorrect. Try again. ({remaining} attempts left)"
        else:
            return False, "Too many attempts. Resend a new code."
    
    # Success! Mark as consumed
    token_record.consumed_at = now
    db.commit()
    
    return True, None


def mark_email_verified(db: Session, user_id: str) -> bool:
    """Mark user's email as verified."""
    user = db.query(User).filter(User.id == user_id).first()
    if user:
        user.email_verified = True
        user.email_verified_at = datetime.utcnow()
        if user.phone_verified:
            user.verification_status = 'verified'
        db.commit()
        return True
    return False


def mark_phone_verified(db: Session, user_id: str) -> bool:
    """Mark user's phone as verified."""
    user = db.query(User).filter(User.id == user_id).first()
    if user:
        user.phone_verified = True
        user.phone_verified_at = datetime.utcnow()
        if user.email_verified:
            user.verification_status = 'verified'
        db.commit()
        return True
    return False


def revoke_all_refresh_tokens(db: Session, user_id: str) -> int:
    """Revoke all refresh tokens for a user (for password reset or logout-all)."""
    from models import RefreshToken
    
    now = datetime.utcnow()
    result = db.query(RefreshToken).filter(
        RefreshToken.user_id == user_id,
        RefreshToken.revoked_at.is_(None)
    ).update({"revoked_at": now})
    
    db.commit()
    return result
