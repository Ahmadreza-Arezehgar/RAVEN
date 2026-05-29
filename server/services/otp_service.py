"""
OTP (One-Time Password) Service for email and SMS verification.

This service handles:
- OTP generation (6-digit codes)
- OTP storage with expiration
- OTP verification with rate limiting
- Email/SMS sending (placeholder - connect to your provider)
"""

import secrets  # 🔴 ROUND 47 — CSPRNG-backed OTP generation.
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
        """Generate a 6-digit OTP code.

        🔴 ROUND 47 (2026-05-19) — hacker-audit Server F11 (CRITICAL).
        PREVIOUSLY: used `random.choices(string.digits, k=6)`. Python's
        `random` module is a Mersenne Twister — fast, fine for games,
        DISQUALIFIED for security. With ~624 32-bit outputs an attacker
        recovers the entire internal state and predicts every future
        output. Concrete attack against RAVEN:
          1. Attacker registers throwaway account A.
          2. Attacker triggers `/forgot-password` on A every 60 s
             (the RESEND_COOLDOWN floor) and sees the OTP delivered
             to their own email.
          3. Each 6-digit OTP burns ≈20 bits of MT state — repeat
             until ≈624 32-bit ints worth of output is observed
             (a few hours of harvesting, faster if other users'
             OTPs interleave because the MT state is process-global).
          4. With state recovered, attacker triggers
             `/forgot-password` for any victim email and PREDICTS the
             6-digit OTP the server will mail to the victim. Victim
             never sees the email open / phishing attempt because the
             OTP travels to the victim's real inbox — but attacker
             only needs to enter it back through `/reset-password`
             before the victim notices the mail.
        Same family of bugs as the Linux kernel CVE-2019-2185 OTP
        flaw and the classic Java SecureRandom-vs-Random mistake.

        FIX: `secrets` is HMAC-DRBG / OS CSPRNG. Each digit is sampled
        independently via `secrets.choice` — no state to leak.
        """
        return ''.join(secrets.choice(string.digits) for _ in range(OTPService.OTP_LENGTH))
    
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
        
        # Verify code (🔴 ROUND 47 — constant-time compare to avoid
        # leaking which prefix bytes matched on early-exit; the 5-try
        # cap below means timing alone is rarely exploitable, but
        # `compare_digest` is the right primitive and costs nothing).
        if not secrets.compare_digest(str(otp.code or ""), str(code or "")):
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
