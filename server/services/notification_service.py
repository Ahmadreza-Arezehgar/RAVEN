"""
Notification Service - Email Delivery via Resend

Features:
- Resend API for sending emails
- Console fallback for development
- HTML email templates

Configure via environment variables:
- RESEND_API_KEY
- RESEND_FROM_EMAIL (default: no-reply@raven-messager.com)
"""

import os
import logging
from typing import Optional
from abc import ABC, abstractmethod

logger = logging.getLogger(__name__)


# ==================== EMAIL PROVIDERS ====================

class EmailProvider(ABC):
    @abstractmethod
    def send(self, to: str, subject: str, body: str, html: Optional[str] = None) -> bool:
        pass


class ResendProvider(EmailProvider):
    """Resend email provider - modern email API."""
    
    def __init__(self):
        self.api_key = os.getenv('RESEND_API_KEY')
        self.from_email = os.getenv('RESEND_FROM_EMAIL', 'no-reply@raven-messager.com')
    
    def send(self, to: str, subject: str, body: str, html: Optional[str] = None) -> bool:
        if not self.api_key:
            logger.warning("Resend API key not configured, falling back to console")
            return False
        
        try:
            import requests
            import time
            
            start_time = time.time()
            
            payload = {
                'from': f'RAVEN Messenger <{self.from_email}>',
                'to': [to],
                'subject': subject,
                'text': body,
                'html': html or body
            }
            
            logger.info(f"📧 [Resend] Sending to={to[:3]}*** | subject={subject} | from={self.from_email}")
            
            response = requests.post(
                'https://api.resend.com/emails',
                headers={
                    'Authorization': f'Bearer {self.api_key}',
                    'Content-Type': 'application/json'
                },
                json=payload,
                timeout=10  # 10 second timeout to prevent hanging
            )
            
            elapsed = time.time() - start_time
            
            if response.status_code in (200, 201):
                try:
                    response_data = response.json()
                    message_id = response_data.get('id', 'unknown')
                    logger.info(f"✅ [Resend] Email sent to {to[:3]}*** | message_id={message_id} | elapsed={elapsed:.2f}s")
                except:
                    logger.info(f"✅ [Resend] Email sent to {to[:3]}*** | elapsed={elapsed:.2f}s")
                return True
            else:
                logger.error(f"❌ [Resend] API error: status={response.status_code} | to={to[:3]}*** | from={self.from_email} | body={response.text[:500]} | elapsed={elapsed:.2f}s")
                return False
        except Exception as e:
            logger.error(f"❌ [Resend] Exception: {type(e).__name__}: {e} | to={to[:3]}***")
            return False


class ConsoleEmailProvider(EmailProvider):
    """Development-only provider that logs to console."""
    
    def send(self, to: str, subject: str, body: str, html: Optional[str] = None) -> bool:
        logger.info(f"📧 [DEV EMAIL] To: {to}")
        logger.info(f"📧 [DEV EMAIL] Subject: {subject}")
        logger.info(f"📧 [DEV EMAIL] Body: {body}")
        print(f"\n📧 [DEV EMAIL] To: {to}")
        print(f"📧 [DEV EMAIL] Subject: {subject}")
        print(f"📧 [DEV EMAIL] Body: {body}\n")
        return True


# ==================== NOTIFICATION SERVICE ====================

class NotificationService:
    """Unified notification service for email."""
    
    def __init__(self):
        # Try Resend first, fall back to console
        resend = ResendProvider()
        if resend.api_key:
            self.email_provider = resend
            logger.info("✅ Using Resend for emails")
        else:
            self.email_provider = ConsoleEmailProvider()
            logger.warning("⚠️ Resend not configured, using console for emails")
    
    def send_verification_email(self, to: str, code: str) -> bool:
        """Send email verification OTP."""
        subject = "Verify your RAVEN account"
        body = f"Your verification code is: {code}\n\nThis code expires in 5 minutes."
        html = f"""
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 400px; margin: 0 auto; padding: 20px; background: #ffffff;">
            <div style="text-align: center; margin-bottom: 24px;">
                <h1 style="color: #1a1a1a; font-size: 24px; margin: 0;">RAVEN</h1>
            </div>
            <h2 style="color: #1a1a1a; font-size: 20px;">Verify your email</h2>
            <p style="color: #666; font-size: 16px;">Your verification code is:</p>
            <div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); padding: 24px; border-radius: 16px; text-align: center; margin: 24px 0;">
                <span style="font-size: 36px; font-weight: bold; letter-spacing: 8px; color: #ffffff;">{code}</span>
            </div>
            <p style="color: #999; font-size: 13px; text-align: center;">This code expires in 5 minutes.</p>
            <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
            <p style="color: #bbb; font-size: 12px; text-align: center;">© 2026 RAVEN Messenger</p>
        </div>
        """
        return self.email_provider.send(to, subject, body, html)
    
    def send_password_reset_email(self, to: str, code: str) -> bool:
        """Send password reset code."""
        subject = "Reset your RAVEN password"
        body = f"Your password reset code is: {code}\n\nThis code expires in 5 minutes.\n\nIf you didn't request this, please ignore this email."
        html = f"""
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 400px; margin: 0 auto; padding: 20px; background: #ffffff;">
            <div style="text-align: center; margin-bottom: 24px;">
                <h1 style="color: #1a1a1a; font-size: 24px; margin: 0;">RAVEN</h1>
            </div>
            <h2 style="color: #1a1a1a; font-size: 20px;">Reset your password</h2>
            <p style="color: #666; font-size: 16px;">Your password reset code is:</p>
            <div style="background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%); padding: 24px; border-radius: 16px; text-align: center; margin: 24px 0;">
                <span style="font-size: 36px; font-weight: bold; letter-spacing: 8px; color: #ffffff;">{code}</span>
            </div>
            <p style="color: #999; font-size: 13px; text-align: center;">This code expires in 5 minutes.</p>
            <p style="color: #bbb; font-size: 12px; text-align: center;">If you didn't request this, you can safely ignore this email.</p>
            <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
            <p style="color: #bbb; font-size: 12px; text-align: center;">© 2026 RAVEN Messenger</p>
        </div>
        """
        return self.email_provider.send(to, subject, body, html)
    
    def send_registration_verification_email(self, to: str, code: str) -> bool:
        """Send registration verification code for new users."""
        subject = "Welcome to RAVEN - Verify your email"
        body = f"Your verification code is: {code}\n\nThis code expires in 5 minutes.\n\nWelcome to RAVEN Messenger!"
        html = f"""
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 400px; margin: 0 auto; padding: 20px; background: #0a0a0a; color: #ffffff;">
            <div style="text-align: center; margin-bottom: 24px;">
                <h1 style="color: #ffffff; font-size: 28px; margin: 0;">RAVEN</h1>
                <p style="color: #888; font-size: 14px; margin: 8px 0 0 0;">Secure Messaging</p>
            </div>
            <h2 style="color: #ffffff; font-size: 20px; text-align: center;">Welcome! 🎉</h2>
            <p style="color: #aaa; font-size: 16px; text-align: center;">Enter this code to verify your email:</p>
            <div style="background: linear-gradient(135deg, #6366f1 0%, #8b5cf6 100%); padding: 28px; border-radius: 20px; text-align: center; margin: 24px 0; box-shadow: 0 8px 32px rgba(99, 102, 241, 0.3);">
                <span style="font-size: 40px; font-weight: bold; letter-spacing: 10px; color: #ffffff;">{code}</span>
            </div>
            <p style="color: #666; font-size: 13px; text-align: center;">This code expires in 5 minutes.</p>
            <div style="background: #1a1a1a; border-radius: 12px; padding: 16px; margin: 24px 0;">
                <p style="color: #888; font-size: 13px; margin: 0; text-align: center;">
                    ✨ You're just one step away from joining RAVEN
                </p>
            </div>
            <hr style="border: none; border-top: 1px solid #333; margin: 24px 0;">
            <p style="color: #555; font-size: 12px; text-align: center;">© 2026 RAVEN Messenger</p>
        </div>
        """
        return self.email_provider.send(to, subject, body, html)


# Singleton instance
_notification_service: Optional[NotificationService] = None

def get_notification_service() -> NotificationService:
    global _notification_service
    if _notification_service is None:
        _notification_service = NotificationService()
    return _notification_service
