"""
Verification Router - Email/SMS OTP verification endpoints.

Endpoints:
- POST /api/auth/send-email-otp     - Send OTP to user's email
- POST /api/auth/verify-email-otp   - Verify email OTP
- POST /api/auth/send-sms-otp       - Send OTP to user's phone
- POST /api/auth/verify-sms-otp     - Verify SMS OTP
- GET  /api/auth/verification-status - Check verification status
"""

from fastapi import APIRouter, Depends, HTTPException, status, Request
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import Optional

from database import get_db
from models import User
from auth import get_current_user_optional
from services.otp_service import OTPService, send_email_otp, send_sms_otp
from encryption import decrypt_text
from middleware.rate_limit import rate_limiter

router = APIRouter(prefix="/api/auth", tags=["verification"])


# ==================== REQUEST/RESPONSE MODELS ====================

class SendOTPRequest(BaseModel):
    """Request to send OTP (requires auth token)."""
    pass  # Token is in header


class VerifyOTPRequest(BaseModel):
    """Request to verify OTP code."""
    code: str


class VerificationStatusResponse(BaseModel):
    """Response with user's verification status."""
    email_verified: bool
    phone_verified: bool
    verification_status: str
    has_email: bool
    has_phone: bool


# ==================== EMAIL VERIFICATION ====================

@router.post("/send-email-otp")
async def send_email_otp_endpoint(
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user_optional)
):
    """
    Send OTP to user's email for verification.
    Requires authenticated user.
    """
    if not current_user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required"
        )
    
    if not current_user.email:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No email address on file"
        )
    
    if current_user.email_verified:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Email already verified"
        )
    
    # Rate limiting by IP
    client_ip = request.client.host
    rate_limiter.check_rate_limit(
        identifier=f"email_otp:{client_ip}",
        max_attempts=5,
        window_minutes=10,
        lockout_minutes=30
    )
    
    # Generate OTP
    code, success, message = OTPService.create_otp(
        db=db,
        user_id=current_user.id,
        channel='email',
        purpose='verification'
    )
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=message
        )
    
    # Decrypt email and send OTP
    email = decrypt_text(current_user.email)
    success = send_email_otp(email, code)
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to send verification email. Please try again."
        )
    
    print(f"📧 Email OTP sent to user {current_user.id}")
    
    return {
        "success": True,
        "message": "Verification code sent to your email",
        "expires_in_minutes": OTPService.OTP_EXPIRY_MINUTES
    }


@router.post("/verify-email-otp")
async def verify_email_otp_endpoint(
    req: VerifyOTPRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user_optional)
):
    """
    Verify email OTP code.
    """
    if not current_user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required"
        )
    
    if current_user.email_verified:
        return {
            "success": True,
            "message": "Email already verified"
        }
    
    # Verify OTP
    success, message = OTPService.verify_otp(
        db=db,
        user_id=current_user.id,
        channel='email',
        code=req.code,
        purpose='verification'
    )
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=message
        )
    
    # Mark user as verified
    OTPService.mark_user_verified(db, current_user.id, 'email')
    
    print(f"✅ Email verified for user {current_user.id}")
    
    return {
        "success": True,
        "message": "Email verified successfully",
        "verification_status": "verified"
    }


# ==================== SMS VERIFICATION ====================

@router.post("/send-sms-otp")
async def send_sms_otp_endpoint(
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user_optional)
):
    """
    Send OTP to user's phone for verification.
    Requires authenticated user.
    """
    if not current_user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required"
        )
    
    if not current_user.phone:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No phone number on file"
        )
    
    if current_user.phone_verified:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Phone number already verified"
        )
    
    # Rate limiting by IP
    client_ip = request.client.host
    rate_limiter.check_rate_limit(
        identifier=f"sms_otp:{client_ip}",
        max_attempts=3,  # SMS is more expensive, stricter limit
        window_minutes=10,
        lockout_minutes=60
    )
    
    # Generate OTP
    code, success, message = OTPService.create_otp(
        db=db,
        user_id=current_user.id,
        channel='sms',
        purpose='verification'
    )
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=message
        )
    
    # Decrypt phone and send OTP
    phone = decrypt_text(current_user.phone)
    success = send_sms_otp(phone, code)
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to send verification SMS. Please try again."
        )
    
    print(f"📱 SMS OTP sent to user {current_user.id}")
    
    return {
        "success": True,
        "message": "Verification code sent to your phone",
        "expires_in_minutes": OTPService.OTP_EXPIRY_MINUTES
    }


@router.post("/verify-sms-otp")
async def verify_sms_otp_endpoint(
    req: VerifyOTPRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user_optional)
):
    """
    Verify SMS OTP code.
    """
    if not current_user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required"
        )
    
    if current_user.phone_verified:
        return {
            "success": True,
            "message": "Phone number already verified"
        }
    
    # Verify OTP
    success, message = OTPService.verify_otp(
        db=db,
        user_id=current_user.id,
        channel='sms',
        code=req.code,
        purpose='verification'
    )
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=message
        )
    
    # Mark phone as verified
    OTPService.mark_user_verified(db, current_user.id, 'sms')
    
    print(f"✅ Phone verified for user {current_user.id}")
    
    return {
        "success": True,
        "message": "Phone number verified successfully"
    }


# ==================== STATUS CHECK ====================

@router.get("/verification-status", response_model=VerificationStatusResponse)
async def get_verification_status(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user_optional)
):
    """
    Get current user's verification status.
    """
    if not current_user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required"
        )
    
    return VerificationStatusResponse(
        email_verified=current_user.email_verified or False,
        phone_verified=current_user.phone_verified or False,
        verification_status=current_user.verification_status or 'pending',
        has_email=current_user.email is not None,
        has_phone=current_user.phone is not None
    )
