"""
RevenueCat Webhook Router
Receives subscription lifecycle events from RevenueCat and updates user premium status.

Security: Protected by a shared secret in the Authorization header.
Idempotency: All operations are safe to replay — uses UPDATE SET which is naturally idempotent.

Event flow:
  Apple Pay → RevenueCat → POST /api/webhooks/revenuecat → Update users table
"""

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session
from datetime import datetime, timezone
import os
import logging
import traceback

from database import get_db, SessionLocal
from models import User

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/webhooks", tags=["webhooks"])

# Shared secret set in RevenueCat dashboard → Webhook settings
WEBHOOK_SECRET = os.getenv("REVENUECAT_WEBHOOK_SECRET", "")


def _verify_webhook_auth(request: Request) -> bool:
    """
    Validate that the request comes from RevenueCat using shared secret.
    Returns True if authorized, False otherwise.
    NEVER raises — we must always return 200 to RevenueCat.
    """
    if not WEBHOOK_SECRET:
        # If no secret configured, allow all (dev mode)
        logger.warning("⚠️ REVENUECAT_WEBHOOK_SECRET not set — webhook auth disabled")
        return True
    
    auth_header = request.headers.get("Authorization", "")
    # RevenueCat sends: "Bearer <secret>"
    expected = f"Bearer {WEBHOOK_SECRET}"
    
    if auth_header != expected:
        logger.warning(
            f"🚫 [Webhook] Unauthorized attempt from {request.client.host} | "
            f"Got: '{auth_header[:20]}…' | Expected: 'Bearer {WEBHOOK_SECRET[:4]}…'"
        )
        return False
    
    return True


@router.post("/revenuecat")
async def revenuecat_webhook(request: Request):
    """
    Receive subscription lifecycle events from RevenueCat.
    
    Event types handled:
    - INITIAL_PURCHASE / RENEWAL / PRODUCT_CHANGE / NON_RENEWING_PURCHASE → Set user as premium
    - CANCELLATION → Log only (user keeps premium until expiry)
    - EXPIRATION → Remove premium status
    - BILLING_ISSUE → Log warning
    - UNCANCELLATION → Log (auto-renewal re-enabled)
    - All others → Log and return 200
    
    ⚠️ CRITICAL: Always returns 200 OK to prevent RevenueCat retries.
    Any non-200 response = RevenueCat marks the webhook as FAILED.
    """
    try:
        # 1. Verify webhook authenticity
        if not _verify_webhook_auth(request):
            # Log but STILL return 200 — rejecting with 401 causes RevenueCat to
            # report 100% error rate and retry endlessly
            logger.error("🚫 [Webhook] Auth failed — returning 200 to prevent retry storm")
            return JSONResponse(status_code=200, content={"status": "ok"})
        
        # 2. Parse payload
        try:
            body = await request.json()
        except Exception as e:
            logger.error(f"❌ [Webhook] Failed to parse JSON body: {e}")
            return JSONResponse(status_code=200, content={"status": "ok"})
        
        # Log raw event type for debugging
        event = body.get("event", {})
        if not event:
            logger.warning(f"📦 [Webhook] Empty event payload: {str(body)[:200]}")
            return JSONResponse(status_code=200, content={"status": "ok"})
        
        event_type = event.get("type", "UNKNOWN")
        app_user_id = event.get("app_user_id", "")
        original_app_user_id = event.get("original_app_user_id", "")
        
        logger.info(
            f"📦 [Webhook] Received: {event_type} | "
            f"app_user_id: {app_user_id[:16] if app_user_id else 'N/A'}… | "
            f"original: {original_app_user_id[:16] if original_app_user_id else 'N/A'}…"
        )
        
        # RevenueCat sometimes sends $RCAnonymousID — skip those
        if not app_user_id or app_user_id.startswith("$"):
            # Try original_app_user_id as fallback
            if original_app_user_id and not original_app_user_id.startswith("$"):
                app_user_id = original_app_user_id
                logger.info(f"📦 [Webhook] Using original_app_user_id: {app_user_id[:16]}…")
            else:
                logger.info(f"📦 [Webhook] Skipping {event_type} for anonymous user: {app_user_id}")
                return JSONResponse(status_code=200, content={"status": "ok"})
        
        # Extract expiration date if available
        expiration_at_ms = event.get("expiration_at_ms")
        expires_at = None
        if expiration_at_ms:
            try:
                expires_at = datetime.fromtimestamp(expiration_at_ms / 1000, tz=timezone.utc)
            except (ValueError, TypeError, OSError):
                logger.warning(f"⚠️ [Webhook] Invalid expiration_at_ms: {expiration_at_ms}")
        
        logger.info(f"📦 [Webhook] Processing: {event_type} | User: {app_user_id[:12]}… | Expires: {expires_at}")
        
        # 3. Process event
        db: Session = SessionLocal()
        try:
            user = db.query(User).filter(User.id == app_user_id).first()
            
            if not user:
                logger.warning(f"⚠️ [Webhook] User not found in DB: {app_user_id}")
                return JSONResponse(status_code=200, content={"status": "ok", "message": "User not found"})
            
            if event_type in ("INITIAL_PURCHASE", "RENEWAL", "PRODUCT_CHANGE", "NON_RENEWING_PURCHASE"):
                # ✅ User purchased or renewed — activate premium
                user.is_premium = True
                if expires_at:
                    user.premium_expires_at = expires_at
                db.commit()
                logger.info(f"✅ [Webhook] Premium ACTIVATED for {user.username} until {expires_at}")
            
            elif event_type == "CANCELLATION":
                # ⚠️ User cancelled auto-renewal — DO NOT remove premium yet
                # They keep premium until expiration_at
                logger.info(f"⚠️ [Webhook] {user.username} cancelled auto-renewal (premium remains until {expires_at})")
            
            elif event_type == "UNCANCELLATION":
                # User re-enabled auto-renewal
                logger.info(f"✅ [Webhook] {user.username} re-enabled auto-renewal")
            
            elif event_type == "EXPIRATION":
                # ❌ Subscription fully expired — remove premium
                user.is_premium = False
                user.premium_expires_at = None
                db.commit()
                logger.info(f"❌ [Webhook] Premium EXPIRED for {user.username}")
            
            elif event_type == "BILLING_ISSUE":
                # ⚠️ Payment failed — log but don't change status yet
                # RevenueCat will retry and send EXPIRATION if it ultimately fails
                logger.warning(f"⚠️ [Webhook] Billing issue for {user.username}")
            
            elif event_type == "SUBSCRIBER_ALIAS":
                # User identity linked — no action needed
                logger.info(f"📦 [Webhook] Alias event for {user.username}")
            
            elif event_type == "TRANSFER":
                # Subscription transferred to another user
                logger.info(f"📦 [Webhook] Transfer event for {user.username}")
            
            else:
                logger.info(f"📦 [Webhook] Unhandled event type: {event_type} for {user.username}")
        
        except Exception as e:
            db.rollback()
            logger.error(f"❌ [Webhook] DB error processing {event_type}: {e}\n{traceback.format_exc()}")
        finally:
            db.close()
    
    except Exception as e:
        # Catch-all: NEVER let any exception bubble up — must return 200
        logger.error(f"❌ [Webhook] Unexpected error: {e}\n{traceback.format_exc()}")
    
    # Always return 200 to prevent RevenueCat retries
    return JSONResponse(status_code=200, content={"status": "ok"})
