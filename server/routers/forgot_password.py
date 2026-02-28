"""
Forgot Password Router - Password reset flow with OTP.

Endpoints:
- POST /api/auth/forgot-password  - Send password reset OTP
- POST /api/auth/reset-password   - Verify OTP and set new password
"""

from fastapi import APIRouter, Depends, HTTPException, status, Request
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional
import re

from database import get_db
from models import User
from auth import hash_password
from services.otp_service import (
    OTPService, 
    send_password_reset_email, 
    send_password_reset_sms
)
from encryption import encrypt_text, decrypt_text
from middleware.rate_limit import rate_limiter

router = APIRouter(prefix="/api/auth", tags=["password_reset"])


# ==================== PASSWORD VALIDATION (same as auth.py) ====================

COMMON_PASSWORDS = {
    '123456', '12345678', '1234567890', 'password', 'password123',
    'qwerty', 'qwerty123', 'abc123', 'letmein', 'welcome',
    'admin', 'login', 'master', 'dragon', 'passw0rd',
    'iloveyou', 'sunshine', 'princess', 'football', 'monkey'
}

def validate_password(password: str, username: str = None) -> tuple[bool, str]:
    """Validate password against strong password policy."""
    if len(password) < 10:
        return False, "Password must be at least 10 characters"
    
    if not re.search(r'[A-Z]', password):
        return False, "Password must contain at least one uppercase letter"
    
    if not re.search(r'[a-z]', password):
        return False, "Password must contain at least one lowercase letter"
    
    if not re.search(r'\d', password):
        return False, "Password must contain at least one number"
    
    if not re.search(r'[!@#$%^&*()_+\-=\[\]{}/?.,<>:;"|\\`~]', password):
        return False, "Password must contain at least one special character"
    
    if username and username.lower() in password.lower():
        return False, "Password cannot contain your username"
    
    if password.lower() in COMMON_PASSWORDS:
        return False, "This password is too common"
    
    return True, ""


# ==================== REQUEST/RESPONSE MODELS ====================

class ForgotPasswordRequest(BaseModel):
    """Request to initiate password reset."""
    email_or_phone: str  # Can be email or phone number


class ResetPasswordRequest(BaseModel):
    """Request to reset password with OTP."""
    email_or_phone: str
    code: str
    new_password: str


# ==================== ENDPOINTS ====================

@router.post("/forgot-password")
async def forgot_password(
    req: ForgotPasswordRequest,
    request: Request,
    db: Session = Depends(get_db)
):
    """
    Send password reset OTP to user's email or phone.
    
    Accepts either email or phone number.
    """
    # Rate limiting by IP
    client_ip = request.client.host
    rate_limiter.check_rate_limit(
        identifier=f"forgot_password:{client_ip}",
        max_attempts=5,
        window_minutes=15,
        lockout_minutes=60
    )
    
    identifier = req.email_or_phone.strip()
    
    # Determine if it's email or phone
    is_phone = identifier.startswith('+')
    channel = 'sms' if is_phone else 'email'
    
    # Find user by email or phone
    # Note: Email and phone are encrypted in DB, so we need to search differently
    # For now, we'll iterate through users (not ideal for large DBs)
    # In production, consider using a separate lookup table with hashed emails/phones
    
    user = None
    all_users = db.query(User).all()
    
    for u in all_users:
        if is_phone and u.phone:
            try:
                decrypted_phone = decrypt_text(u.phone)
                if decrypted_phone == identifier:
                    user = u
                    break
            except:
                continue
        elif not is_phone and u.email:
            try:
                decrypted_email = decrypt_text(u.email)
                if decrypted_email.lower() == identifier.lower():
                    user = u
                    break
            except:
                continue
    
    # Always return success to prevent user enumeration
    if not user:
        print(f"⚠️ Password reset requested for unknown: {identifier}")
        return {
            "success": True,
            "message": "If an account exists with this email/phone, a reset code has been sent.",
            "expires_in_minutes": OTPService.OTP_EXPIRY_MINUTES
        }
    
    # Generate OTP
    code, success, message = OTPService.create_otp(
        db=db,
        user_id=user.id,
        channel=channel,
        purpose='password_reset'
    )
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=message
        )
    
    # Send OTP
    if is_phone:
        send_password_reset_sms(identifier, code)
        print(f"🔐 Password reset SMS sent to user {user.id}")
    else:
        send_password_reset_email(identifier, code)
        print(f"🔐 Password reset email sent to user {user.id}")
    
    return {
        "success": True,
        "message": "If an account exists with this email/phone, a reset code has been sent.",
        "expires_in_minutes": OTPService.OTP_EXPIRY_MINUTES
    }


@router.post("/reset-password")
async def reset_password(
    req: ResetPasswordRequest,
    request: Request,
    db: Session = Depends(get_db)
):
    """
    Reset password using OTP code.
    
    Requires:
    - email_or_phone: The email or phone used in forgot-password
    - code: 6-digit OTP
    - new_password: New password (must meet strong password policy)
    """
    # Rate limiting
    client_ip = request.client.host
    rate_limiter.check_rate_limit(
        identifier=f"reset_password:{client_ip}",
        max_attempts=10,
        window_minutes=15,
        lockout_minutes=30
    )
    
    identifier = req.email_or_phone.strip()
    is_phone = identifier.startswith('+')
    channel = 'sms' if is_phone else 'email'
    
    # Find user
    user = None
    all_users = db.query(User).all()
    
    for u in all_users:
        if is_phone and u.phone:
            try:
                decrypted_phone = decrypt_text(u.phone)
                if decrypted_phone == identifier:
                    user = u
                    break
            except:
                continue
        elif not is_phone and u.email:
            try:
                decrypted_email = decrypt_text(u.email)
                if decrypted_email.lower() == identifier.lower():
                    user = u
                    break
            except:
                continue
    
    if not user:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid request"
        )
    
    # Verify OTP
    success, message = OTPService.verify_otp(
        db=db,
        user_id=user.id,
        channel=channel,
        code=req.code,
        purpose='password_reset'
    )
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=message
        )
    
    # Validate new password
    is_valid, error_msg = validate_password(req.new_password, user.username)
    if not is_valid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=error_msg
        )
    
    # Update password
    user.password_hash = hash_password(req.new_password)
    db.commit()
    
    print(f"✅ Password reset successful for user {user.id}")
    
    return {
        "success": True,
        "message": "Password reset successfully. You can now sign in with your new password."
    }
