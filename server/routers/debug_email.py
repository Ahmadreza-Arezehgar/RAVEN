"""
Debug Email Router - Test email delivery functionality.

Endpoints (admin-only, disabled in production):
- GET /api/debug/test-email - Send a test verification email
- GET /api/debug/email-config - Inspect email provider config

🔴 SECURITY (hacker-audit 2026-05-19):
PREVIOUSLY these endpoints had ZERO auth. Anyone on the internet could:
  1. Spam `?to=victim@gmail.com` to flood arbitrary inboxes from our
     Resend sender (reputation / phishing-relay risk).
  2. Hit `/email-config` to harvest the first 8 chars of RESEND_API_KEY
     plus the configured FROM address — useful for crafting spoofed
     templates and for narrowing brute-force on the rest of the key.
  3. Use the timing/response difference to enumerate which addresses
     bounce vs. deliver (since send_verification_email returns success
     bool based on provider response).

FIX:
  - Require the X-Admin-Secret header (same gate as /api/admin/*) on
    BOTH endpoints. verify_admin_secret already fails-closed when
    ADMIN_SECRET is empty/default (admin.py round 56).
  - Refuse to run at all in production (ENVIRONMENT=production) — these
    are dev-only diagnostics; if you need to test mail in prod, send
    an actual verification flow through the verified user account.
  - Strip the API-key preview from /email-config. The fact that a key
    is configured is sufficient signal; revealing leading bytes only
    helps an attacker.
"""

import os
from fastapi import APIRouter, Depends, HTTPException, Query
from routers.admin import verify_admin_secret
from services.notification_service import get_notification_service

router = APIRouter(prefix="/api/debug", tags=["debug"])


def _refuse_in_production() -> None:
    if os.getenv("ENVIRONMENT", "development").lower() == "production":
        raise HTTPException(
            status_code=404,
            detail="Not found",
        )


@router.get("/test-email", include_in_schema=False)
async def send_test_email(
    to: str = Query(..., description="Email address to send test to"),
    _: bool = Depends(verify_admin_secret),
):
    """Send a test verification email. Admin-only, dev-only."""
    _refuse_in_production()

    if not to or '@' not in to:
        raise HTTPException(status_code=400, detail="Invalid email address")

    resend_key = os.getenv('RESEND_API_KEY')
    if not resend_key:
        return {
            "success": False,
            "error": "RESEND_API_KEY not configured",
            "message": "Email provider is not set up. Check environment variables."
        }

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
    return {
        "success": False,
        "message": f"Failed to send email to {to}",
        "hint": "Check server logs for Resend API errors"
    }


@router.get("/email-config", include_in_schema=False)
async def check_email_config(_: bool = Depends(verify_admin_secret)):
    """Inspect email provider config. Admin-only, dev-only.

    Never returns any portion of the API key itself — only a boolean
    indicating whether it's configured. The FROM address is operational
    config and is safe to surface.
    """
    _refuse_in_production()
    resend_key = os.getenv('RESEND_API_KEY')
    resend_from = os.getenv('RESEND_FROM_EMAIL', 'no-reply@raven-messager.com')

    return {
        "resend_api_key_configured": bool(resend_key),
        "from_email": resend_from,
        "status": "ready" if resend_key else "not_configured"
    }
