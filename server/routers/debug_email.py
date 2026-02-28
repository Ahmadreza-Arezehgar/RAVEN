"""
Debug Email Router - Test email delivery functionality.

Endpoints:
- GET /api/debug/test-email - Send a test verification email

IMPORTANT: This endpoint should be disabled or protected in production!
"""

import os
from fastapi import APIRouter, HTTPException, Query
from services.notification_service import get_notification_service

router = APIRouter(prefix="/api/debug", tags=["debug"])


@router.get("/test-email")
async def send_test_email(
    to: str = Query(..., description="Email address to send test to")
):
    """
    Send a test verification email to check email delivery.
    
    Uses the NotificationService with Resend API.
    
    WARNING: Disable this endpoint in production or add authentication!
    """
    # Basic email validation
    if not to or '@' not in to:
        raise HTTPException(status_code=400, detail="Invalid email address")
    
    # Check if Resend is configured
    resend_key = os.getenv('RESEND_API_KEY')
    if not resend_key:
        return {
            "success": False,
            "error": "RESEND_API_KEY not configured",
            "message": "Email provider is not set up. Check environment variables."
        }
    
    # Send test email
    notification = get_notification_service()
    test_code = "123456"
    
    success = notification.send_verification_email(to, test_code)
    
    if success:
        return {
            "success": True,
            "message": f"Test email sent to {to}",
            "code_sent": test_code,
            "provider": "Resend"
        }
    else:
        return {
            "success": False,
            "message": f"Failed to send email to {to}",
            "hint": "Check server logs for Resend API errors"
        }


@router.get("/email-config")
async def check_email_config():
    """
    Check if email configuration is properly set up.
    
    Returns status of environment variables without exposing secrets.
    """
    resend_key = os.getenv('RESEND_API_KEY')
    resend_from = os.getenv('RESEND_FROM_EMAIL', 'no-reply@raven-messager.com')
    
    return {
        "resend_api_key_configured": bool(resend_key),
        "resend_api_key_preview": f"{resend_key[:8]}..." if resend_key and len(resend_key) > 8 else None,
        "from_email": resend_from,
        "status": "ready" if resend_key else "not_configured"
    }
