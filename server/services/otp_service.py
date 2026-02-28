"""
OTP (One-Time Password) Service for email and SMS verification.

This service handles:
- OTP generation (6-digit codes)
- OTP storage with expiration
- OTP verification with rate limiting
- Email/SMS sending (placeholder - connect to your provider)
"""

import random
import string
from datetime import datetime, timedelta
from typing import Optional, Tuple
from sqlalchemy.orm import Session

from models import OTPCode, User


class OTPService:
    """Service for generating and verifying OTP codes."""
    
    OTP_LENGTH = 6
    OTP_EXPIRY_MINUTES = 5
    MAX_ATTEMPTS = 5
    RESEND_COOLDOWN_SECONDS = 60
    
    @staticmethod
    def generate_code() -> str:
        """Generate a 6-digit OTP code."""
        return ''.join(random.choices(string.digits, k=OTPService.OTP_LENGTH))
    
    @staticmethod
    def create_otp(
        db: Session,
        user_id: str,
        channel: str,  # 'email' or 'sms'
        purpose: str = 'verification'  # 'verification' or 'password_reset'
    ) -> Tuple[str, bool, str]:
        """
        Create and store a new OTP code.
        
        Returns: (code, success, message)
        """
        # Check for existing recent OTP (rate limiting)
        recent_otp = db.query(OTPCode).filter(
            OTPCode.user_id == user_id,
            OTPCode.channel == channel,
            OTPCode.purpose == purpose,
            OTPCode.created_at > datetime.utcnow() - timedelta(seconds=OTPService.RESEND_COOLDOWN_SECONDS)
        ).first()
        
        if recent_otp:
            seconds_remaining = OTPService.RESEND_COOLDOWN_SECONDS - (datetime.utcnow() - recent_otp.created_at).seconds
            return '', False, f'Please wait {seconds_remaining} seconds before requesting a new code'
        
        # Invalidate any existing unused OTPs for this user/channel/purpose
        db.query(OTPCode).filter(
            OTPCode.user_id == user_id,
            OTPCode.channel == channel,
            OTPCode.purpose == purpose,
            OTPCode.used_at == None
        ).delete()
        
        # Generate new OTP
        code = OTPService.generate_code()
        
        otp = OTPCode(
            user_id=user_id,
            channel=channel,
            purpose=purpose,
            code=code,
            expires_at=datetime.utcnow() + timedelta(minutes=OTPService.OTP_EXPIRY_MINUTES)
        )
        
        db.add(otp)
        db.commit()
        
        return code, True, 'OTP created successfully'
    
    @staticmethod
    def verify_otp(
        db: Session,
        user_id: str,
        channel: str,
        code: str,
        purpose: str = 'verification'
    ) -> Tuple[bool, str]:
        """
        Verify an OTP code.
        
        Returns: (success, message)
        """
        otp = db.query(OTPCode).filter(
            OTPCode.user_id == user_id,
            OTPCode.channel == channel,
            OTPCode.purpose == purpose,
            OTPCode.used_at == None
        ).order_by(OTPCode.created_at.desc()).first()
        
        if not otp:
            return False, 'No pending verification code found. Please request a new one.'
        
        # Check expiration
        if datetime.utcnow() > otp.expires_at:
            return False, 'Verification code has expired. Please request a new one.'
        
        # Check max attempts
        if otp.attempts >= OTPService.MAX_ATTEMPTS:
            return False, 'Too many failed attempts. Please request a new code.'
        
        # Verify code
        if otp.code != code:
            otp.attempts += 1
            db.commit()
            remaining = OTPService.MAX_ATTEMPTS - otp.attempts
            return False, f'Invalid code. {remaining} attempts remaining.'
        
        # Mark as used
        otp.used_at = datetime.utcnow()
        db.commit()
        
        return True, 'Verification successful'
    
    @staticmethod
    def mark_user_verified(db: Session, user_id: str, channel: str) -> bool:
        """Mark user's email or phone as verified."""
        user = db.query(User).filter(User.id == user_id).first()
        if not user:
            return False
        
        if channel == 'email':
            user.email_verified = True
        elif channel == 'sms':
            user.phone_verified = True
        
        # Update overall verification status
        # User is verified if email is verified (SMS is optional)
        if user.email_verified:
            user.verification_status = 'verified'
        
        db.commit()
        return True


# ==================== EMAIL/SMS SENDING (USING NOTIFICATION SERVICE) ====================

def send_email_otp(email: str, code: str) -> bool:
    """
    Send OTP code via email using NotificationService (Resend API).
    
    Returns True if email was sent successfully, False otherwise.
    """
    from services.notification_service import get_notification_service
    
    try:
        notification = get_notification_service()
        success = notification.send_verification_email(email, code)
        if success:
            print(f"📧 Email OTP sent to {email[:3]}***")
        else:
            print(f"❌ Failed to send email OTP to {email[:3]}***")
        return success
    except Exception as e:
        print(f"❌ Error sending email OTP: {e}")
        return False


def send_sms_otp(phone: str, code: str) -> bool:
    """
    Send OTP code via SMS.
    
    TODO: Connect to SMS provider (Twilio, AWS SNS, Vonage) when needed.
    For now, logs to console for development.
    """
    print(f"📱 [DEV] SMS OTP to {phone}: {code}")
    # TODO: Implement actual SMS sending when SMS provider is configured
    return True


def send_password_reset_email(email: str, code: str) -> bool:
    """
    Send password reset OTP via email using NotificationService (Resend API).
    
    Returns True if email was sent successfully, False otherwise.
    """
    from services.notification_service import get_notification_service
    
    try:
        notification = get_notification_service()
        success = notification.send_password_reset_email(email, code)
        if success:
            print(f"🔐 Password reset email sent to {email[:3]}***")
        else:
            print(f"❌ Failed to send password reset email to {email[:3]}***")
        return success
    except Exception as e:
        print(f"❌ Error sending password reset email: {e}")
        return False


def send_password_reset_sms(phone: str, code: str) -> bool:
    """
    Send password reset OTP via SMS.
    
    TODO: Connect to SMS provider when needed.
    For now, logs to console for development.
    """
    print(f"🔐 [DEV] Password reset SMS to {phone}: {code}")
    # TODO: Implement actual SMS sending when SMS provider is configured
    return True
