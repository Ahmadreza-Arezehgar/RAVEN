"""
APNs (Apple Push Notification Service) Push Provider

This service sends push notifications to iOS devices using APNs HTTP/2 API.
Requires:
- APNS_KEY_ID: Key ID from Apple Developer portal
- APNS_TEAM_ID: Team ID from Apple Developer portal  
- APNS_BUNDLE_ID: App bundle ID (e.g., com.raven.messenger)
- APNS_KEY_PATH: Path to .p8 private key file

For production, set APNS_USE_SANDBOX=false
"""

import os
import re
import jwt
import httpx
import time
import json
import logging
from typing import Optional, Dict, Any
from datetime import datetime

logger = logging.getLogger(__name__)


class APNsService:
    """Apple Push Notification Service provider."""
    
    # Pre-compiled regex for detecting encrypted Fernet tokens in notification text
    _fernet_pattern = re.compile(r'gAAAAA[A-Za-z0-9_\-]{20,}')

    @staticmethod
    def push_token_for(user) -> Optional[str]:
        """🔴 ROUND 70 — canonical push-token reader.

        `user.push_token` may be either a legacy plaintext APNs/FCM
        token OR a new Fernet-wrapped value (round-70 register_push).
        This helper unwraps the new format and falls through to raw
        for legacy rows, so every send-path can be migrated to it
        in one place without coordinating across callers.
        """
        raw = getattr(user, "push_token", None)
        if not raw:
            return None
        # New Fernet payloads start with `gAAAAA…` (the standard
        # Fernet magic prefix). Cheap O(1) sniff before attempting
        # the decrypt — saves a Fernet object construction on every
        # send for the (still-large during migration) population of
        # legacy plaintext tokens.
        if raw.startswith("gAAAA"):
            try:
                from encryption import decrypt_text as _dec
                return _dec(raw)
            except Exception:
                # Decrypt failure (key rotation, corrupted row) →
                # treat as no token. Better to skip the push than
                # ship a malformed token to APNs and get a 400.
                return None
        return raw  # legacy plaintext
    
    def __init__(self):
        self.key_id = os.getenv('APNS_KEY_ID')
        self.team_id = os.getenv('APNS_TEAM_ID')
        self.bundle_id = os.getenv('APNS_BUNDLE_ID', 'com.raven.messenger')
        self.key_path = os.getenv('APNS_KEY_PATH', 'apns_key.p8')
        self.use_sandbox = os.getenv('APNS_USE_SANDBOX', 'true').lower() == 'true'
        
        # APNs endpoints
        self.sandbox_host = 'https://api.sandbox.push.apple.com'
        self.production_host = 'https://api.push.apple.com'
        
        # JWT token cache
        self._token: Optional[str] = None
        self._token_expires_at: float = 0
        
        # Load private key
        self._private_key: Optional[str] = None
        self._load_key()
        
        if self._private_key:
            logger.info(f"✅ APNs configured (sandbox={self.use_sandbox})")
        else:
            logger.warning("⚠️ APNs not configured - push notifications disabled")
    
    @staticmethod
    def build_push_display_name(user) -> str:
        """
        Build a decrypted display name for push notifications from a User model.
        Decrypts first_name/last_name, filters [DECRYPT_FAILED], falls back to username.
        Use this everywhere instead of inline decrypt logic.
        """
        from encryption import decrypt_text
        first = ""
        last = ""
        try:
            if user.first_name:
                first = decrypt_text(user.first_name) or ""
                if first == "[DECRYPT_FAILED]":
                    first = ""
            if user.last_name:
                last = decrypt_text(user.last_name) or ""
                if last == "[DECRYPT_FAILED]":
                    last = ""
        except Exception:
            pass
        display_name = f"{first} {last}".strip()
        return display_name if display_name else (getattr(user, 'username', None) or "Someone")
    
    @staticmethod
    def get_unread_badge_count(db, user_id: str) -> int:
        """
        Get the unread notification count for badge display.
        Returns count of unread notifications for the user.
        """
        try:
            from models import Notification
            count = db.query(Notification).filter(
                Notification.user_id == user_id,
                Notification.is_read == False
            ).count()
            return min(count, 99)  # Cap at 99 for badge display
        except Exception as e:
            logger.warning(f"Badge count query failed: {e}")
            return 0
    
    @staticmethod
    async def cleanup_stale_token(device_token: str):
        """
        Remove a stale/unregistered device token from the database.
        Called when APNs returns 'Unregistered' for a token.
        """
        try:
            from database import SessionLocal
            from models import User
            db = SessionLocal()
            try:
                users = db.query(User).filter(User.push_token == device_token).all()
                for user in users:
                    logger.info(f"🧹 Removing stale push token for user {user.username} ({device_token[:16]}...)")
                    user.push_token = None
                    user.push_platform = None
                db.commit()
            finally:
                db.close()
        except Exception as e:
            logger.error(f"Failed to cleanup stale token: {e}")
    
    def _load_key(self):
        """Load the APNs private key from file."""
        if not self.key_id or not self.team_id:
            return
            
        try:
            if os.path.exists(self.key_path):
                with open(self.key_path, 'r') as f:
                    self._private_key = f.read()
        except Exception as e:
            logger.error(f"Failed to load APNs key: {e}")
    
    @property
    def is_configured(self) -> bool:
        """Check if APNs is properly configured."""
        return bool(self._private_key and self.key_id and self.team_id)
    
    def _get_token(self) -> Optional[str]:
        """Get JWT token for APNs, refreshing if needed."""
        if not self.is_configured:
            return None
            
        # Refresh token if expired (tokens last 1 hour, refresh at 50 min)
        if time.time() >= self._token_expires_at:
            try:
                now = int(time.time())
                payload = {
                    'iss': self.team_id,
                    'iat': now
                }
                self._token = jwt.encode(
                    payload,
                    self._private_key,
                    algorithm='ES256',
                    headers={
                        'kid': self.key_id
                    }
                )
                self._token_expires_at = now + 50 * 60  # 50 minutes
                logger.debug("🔑 APNs token refreshed")
            except Exception as e:
                logger.error(f"Failed to create APNs token: {e}")
                return None
                
        return self._token
    
    async def _curl_send(
        self,
        url: str,
        token: str,
        payload_json: str,
        priority: int = 10,
        push_type: str = "alert",
    ) -> tuple:
        """
        Send a push via curl HTTP/2 to APNs.
        Returns (status_code: int, response_body: str, error: str|None).
        """
        import asyncio
        import tempfile
        
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as tmp:
            tmp_path = tmp.name
        
        curl_cmd = [
            'curl', '-s',
            '-o', tmp_path,
            '-w', '%{http_code}',
            '--http2',
            '-X', 'POST',
            '-H', f'authorization: bearer {token}',
            '-H', f'apns-topic: {self.bundle_id}',
            '-H', f'apns-priority: {priority}',
            '-H', f'apns-push-type: {push_type}',
            '-H', 'content-type: application/json',
            '-d', payload_json,
            '--max-time', '10',
            '--connect-timeout', '5',
            url
        ]
        
        try:
            proc = await asyncio.create_subprocess_exec(
                *curl_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=15)
            except asyncio.TimeoutError:
                proc.kill()
                return (-1, "", "timeout")
            
            status_str = stdout.decode().strip()
            stderr_str = stderr.decode().strip()
            
            if proc.returncode != 0:
                return (-1, "", f"curl exit {proc.returncode}: {stderr_str}")
            
            try:
                status_code = int(status_str)
            except ValueError:
                return (-1, "", f"bad status: '{status_str}'")
            
            response_body = ""
            try:
                with open(tmp_path, 'r') as f:
                    response_body = f.read()
            except Exception:
                pass
            
            return (status_code, response_body, None)
            
        finally:
            try:
                os.unlink(tmp_path)
            except Exception:
                pass

    async def send_push(
        self,
        device_token: str,
        title: str,
        body: str,
        data: Optional[Dict[str, Any]] = None,
        sound: str = "default",
        badge: Optional[int] = None,
        thread_id: Optional[str] = None,
        category: Optional[str] = None,
        mutable_content: bool = False,
        priority: int = 10
    ) -> bool:
        """
        Send a push notification to an iOS device via APNs HTTP/2 API.
        Uses curl subprocess for reliable HTTP/2.
        Automatically retries with opposite environment on BadEnvironmentKeyInToken.
        """
        if not self.is_configured:
            logger.warning("APNs not configured - skipping push")
            return False

        token = self._get_token()
        if not token:
            logger.error("❌ APNs token generation failed - cannot send push")
            return False

        # 🔴 ROUND 70 — coerce-decrypt the device_token at entry so
        # callers that still read `user.push_token` directly (vs the
        # new `push_token_for(user)` helper) keep working after the
        # at-rest Fernet wrap landed. Fernet payloads start with
        # `gAAAA…` — cheap sniff before attempting decrypt.
        if device_token and isinstance(device_token, str) and device_token.startswith("gAAAA"):
            try:
                from encryption import decrypt_text as _dec
                device_token = _dec(device_token)
            except Exception:
                logger.warning("⚠️ failed to decrypt Fernet-wrapped push_token — skipping send")
                return False

        notif_type = data.get('type', 'unknown') if data else 'unknown'

        # 🛡️ Safety net: detect encrypted Fernet tokens leaking into notification text
        if self._fernet_pattern.search(title):
            logger.warning(f"⚠️ ENCRYPTED TEXT detected in push title! Replacing with fallback. Original: {title[:30]}...")
            title = "New Message"
        if self._fernet_pattern.search(body):
            logger.warning(f"⚠️ ENCRYPTED TEXT detected in push body! Replacing with fallback. Original: {body[:30]}...")
            body = "You have a new notification"
        
        logger.info(f"📤 [Push] title=\"{title}\" body=\"{body[:50]}\" type={notif_type} token={device_token[:16]}...")
        
        # Build APNs payload
        aps_payload: Dict[str, Any] = {
            'alert': {
                'title': title,
                'body': body
            },
            'sound': sound
        }
        
        if badge is not None:
            aps_payload['badge'] = badge
        if thread_id:
            aps_payload['thread-id'] = thread_id
        if category:
            aps_payload['category'] = category
        if mutable_content:
            aps_payload['mutable-content'] = 1
        
        payload = {'aps': aps_payload}
        if data:
            payload.update(data)
        
        payload_json = json.dumps(payload)
        
        # Try configured environment first, then fallback to alternate
        environments = [
            (self.use_sandbox, "SANDBOX" if self.use_sandbox else "PRODUCTION"),
        ]
        
        try:
            # First attempt with configured environment
            host = self.sandbox_host if self.use_sandbox else self.production_host
            env_label = environments[0][1]
            url = f"{host}/3/device/{device_token}"
            
            logger.info(f"🚀 Sending push via curl to {device_token[:16]}... [{env_label}]")
            
            status_code, response_body, error = await self._curl_send(
                url, token, payload_json, priority
            )
            
            if error:
                logger.error(f"❌ curl error [{env_label}]: {error}")
                return False
            
            if status_code == 200:
                logger.info(f"📱 Push sent [{env_label}] type={notif_type} to {device_token[:16]}...")
                return True
            
            # Parse error reason
            reason = "Unknown"
            try:
                if response_body:
                    error_data = json.loads(response_body)
                    reason = error_data.get('reason', 'Unknown')
            except Exception:
                pass
            
            # If environment mismatch, retry with opposite environment
            if reason in ('BadEnvironmentKeyInToken', 'BadDeviceToken'):
                alt_sandbox = not self.use_sandbox
                alt_host = self.sandbox_host if alt_sandbox else self.production_host
                alt_label = "SANDBOX" if alt_sandbox else "PRODUCTION"
                alt_url = f"{alt_host}/3/device/{device_token}"
                
                logger.warning(f"🔄 Retrying push with {alt_label} (got {reason} from {env_label})")
                
                status_code2, response_body2, error2 = await self._curl_send(
                    alt_url, token, payload_json, priority
                )
                
                if error2:
                    logger.error(f"❌ curl error [{alt_label}]: {error2}")
                    return False
                
                if status_code2 == 200:
                    logger.info(f"📱 Push sent [{alt_label}] type={notif_type} to {device_token[:16]}... (fallback worked!)")
                    # Update preference for future sends
                    self.use_sandbox = alt_sandbox
                    logger.info(f"🔧 Switched APNs environment to {alt_label} for future pushes")
                    return True
                else:
                    reason2 = "Unknown"
                    try:
                        if response_body2:
                            error_data2 = json.loads(response_body2)
                            reason2 = error_data2.get('reason', 'Unknown')
                    except Exception:
                        pass
                    logger.error(f"❌ APNs error [{alt_label}] ({status_code2}): {reason2}")
                    return False
            
            logger.error(f"❌ APNs error [{env_label}] ({status_code}): {reason} | type={notif_type} token={device_token[:16]}...")
            
            if reason == 'Unregistered':
                logger.warning(f"🧹 Device unregistered: {device_token[:16]}... — cleaning up stale token")
                import asyncio
                asyncio.ensure_future(self.cleanup_stale_token(device_token))
                
            return False
                
        except Exception as e:
            import traceback
            logger.error(f"❌ Push failed: {e}\n{traceback.format_exc()}")
            return False
    
    async def send_message_notification(
        self,
        device_token: str,
        sender_name: str,
        message_preview: str,
        room_id: str,
        sender_id: str,
        message_type: str = "text",
        badge: Optional[int] = None,
        sender_avatar: Optional[str] = None,
        is_group: bool = False,
        group_name: Optional[str] = None,
    ) -> bool:
        """Send push notification for a new message.

        🔴 ROUND 71 phase 3 follow-up (2026-05-24) — payload now
        carries `sender_username`, `sender_avatar`, `preview`, and
        `is_group` so the foregrounded iOS app can paint a
        rich in-app banner (real display name + avatar + type-aware
        preview emoji) instead of falling back to the generic
        "New message / 💬 Message" placeholder. Pre-fix the data
        dict carried only {type, room_id, sender_id, message_type}
        and `RealtimeEngine.showToast`'s `if let senderName =
        payload["sender_username"]` guard early-returned because
        the field was absent — every APNs-driven foreground toast
        was silently dropped.
        """
        # Format notification body based on message type
        if message_type == "voice":
            body = "🎤 Voice message"
        elif message_type == "image":
            body = "📷 Image"
        elif message_type == "video":
            body = "🎬 Video"
        elif message_type == "file":
            body = "📎 File"
        elif message_type == "location":
            body = "📍 Location"
        else:
            # Truncate text preview
            body = message_preview[:100] if len(message_preview) > 100 else message_preview

        data: dict = {
            'type': 'message',
            'room_id': room_id,
            'sender_id': sender_id,
            'message_type': message_type,
            # NEW: surface everything the in-app banner needs so we
            # don't have to scrape it out of aps.alert.
            'sender_username': sender_name,
            'preview': body,
            'is_group': is_group,
        }
        if sender_avatar:
            data['sender_avatar'] = sender_avatar
        if is_group and group_name:
            data['group_name'] = group_name

        return await self.send_push(
            device_token=device_token,
            title=sender_name,
            body=body,
            data=data,
            thread_id=f"chat_{room_id}",
            category='MESSAGE',
            mutable_content=True,
            badge=badge
        )
    
    async def send_bridge_wake_push(
        self,
        device_token: str,
        recipient_id: str,
        message_count: int = 1
    ) -> bool:
        """
        Send a silent push to wake a bridge device for downlink relay.
        
        Uses content-available: 1 (background push) — no alert, no sound.
        Apple requires: push-type=background, priority=5.
        """
        if not self.is_configured:
            return False

        # 🔴 ROUND 71 S19: coerce-decrypt Fernet-wrapped push token
        # at entry (mirror of round-70 fix in `send_push`). After
        # round-70 push tokens are stored Fernet-wrapped; callers
        # passing `user.push_token` directly into this helper would
        # ship `gAAAAA…` as the APNs device id → 400 BadDeviceToken
        # → silent bridge-push failure for every migrated user.
        if device_token and isinstance(device_token, str) and device_token.startswith("gAAAA"):
            try:
                from encryption import decrypt_text as _dec
                device_token = _dec(device_token)
            except Exception:
                logger.warning("⚠️ [BridgeWake] Fernet decrypt of push_token failed — skipping")
                return False

        token = self._get_token()
        if not token:
            return False

        payload = {
            "aps": {"content-available": 1},
            "type": "bridge_wake",
            "recipient_id": recipient_id,
            "message_count": message_count
        }

        host = self.sandbox_host if self.use_sandbox else self.production_host
        url = f"{host}/3/device/{device_token}"
        
        headers = {
            'authorization': f'bearer {token}',
            'apns-topic': self.bundle_id,
            'apns-priority': '5',          # Low priority (required for silent push)
            'apns-push-type': 'background'  # Required for content-available
        }
        
        try:
            import asyncio
            import tempfile
            
            payload_json = json.dumps(payload)
            
            with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as tmp:
                tmp_path = tmp.name
            
            curl_cmd = [
                'curl', '-s',
                '-o', tmp_path,
                '-w', '%{http_code}',
                '--http2',
                '-X', 'POST',
                '-H', f'authorization: bearer {token}',
                '-H', f'apns-topic: {self.bundle_id}',
                '-H', 'apns-priority: 5',
                '-H', 'apns-push-type: background',
                '-H', 'content-type: application/json',
                '-d', payload_json,
                '--max-time', '10',
                '--connect-timeout', '5',
                url
            ]
            
            proc = await asyncio.create_subprocess_exec(
                *curl_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            
            try:
                stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=15)
            except asyncio.TimeoutError:
                proc.kill()
                logger.error(f"❌ Bridge wake push timed out")
                return False
            
            status_str = stdout.decode().strip()
            if proc.returncode != 0:
                logger.error(f"❌ Bridge wake curl failed (exit {proc.returncode}): {stderr.decode().strip()}")
                return False
            
            try:
                status_code = int(status_str)
            except ValueError:
                return False
            finally:
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
            
            if status_code == 200:
                logger.info(f"🌉 Bridge wake push sent for recipient {recipient_id[:8]} → {device_token[:16]}...")
                return True
            else:
                logger.error(f"❌ Bridge wake push failed ({status_code})")
                return False
        except Exception as e:
            logger.error(f"❌ Bridge wake push error: {e}")
            return False
    
    async def send_like_notification(
        self,
        device_token: str,
        liker_name: str,
        post_id: str,
        badge: Optional[int] = None
    ) -> bool:
        """Send push notification for a post like."""
        return await self.send_push(
            device_token=device_token,
            title="New Like",
            body=f"{liker_name} liked your post",
            data={
                'type': 'like',
                'post_id': post_id
            },
            thread_id=f"likes_{post_id}",
            category='LIKE',
            badge=badge
        )
    
    async def send_comment_notification(
        self,
        device_token: str,
        commenter_name: str,
        comment_preview: str,
        post_id: str,
        badge: Optional[int] = None
    ) -> bool:
        """Send push notification for a new comment."""
        return await self.send_push(
            device_token=device_token,
            title=f"{commenter_name} commented",
            body=comment_preview[:100],
            data={
                'type': 'comment',
                'post_id': post_id
            },
            thread_id=f"comments_{post_id}",
            category='COMMENT',
            badge=badge
        )
    
    async def send_friend_request_notification(
        self,
        device_token: str,
        requester_name: str,
        requester_id: str,
        badge: Optional[int] = None
    ) -> bool:
        """Send push notification for a friend request."""
        return await self.send_push(
            device_token=device_token,
            title="New Friend Request",
            body=f"{requester_name} wants to be friends",
            data={
                'type': 'friend_request',
                'requester_id': requester_id
            },
            category='FRIEND_REQUEST',
            badge=badge
        )

    async def send_friend_accepted_notification(
        self,
        device_token: str,
        accepter_name: str,
        accepter_id: str,
        badge: Optional[int] = None
    ) -> bool:
        """Send push notification when a friend request is accepted."""
        return await self.send_push(
            device_token=device_token,
            title="Friend Request Accepted",
            body=f"{accepter_name} accepted your friend request",
            data={
                'type': 'friend_accepted',
                'accepter_id': accepter_id
            },
            category='FRIEND_REQUEST',
            badge=badge
        )

    async def send_mention_notification(
        self,
        device_token: str,
        mentioner_name: str,
        mention_type: str,
        snippet: str,
        deep_link: str,
        room_id: str = None,
        post_id: str = None,
        source_id: str = None,
        group_name: str = None
    ) -> bool:
        """
        Send push notification for an @mention.
        
        Args:
            mention_type: 'chat_message' or 'post_comment'
            snippet: Short preview of the message/comment
            deep_link: In-app navigation URI
            group_name: Name of the group (for chat mentions)
        """
        if mention_type == "chat_message":
            title = f"Mentioned you in {group_name or 'a group'}"
        else:
            title = "Mentioned you in a comment"
        
        body = f"{mentioner_name}: {snippet[:80]}"
        
        data = {
            'type': 'mention',
            'mention_type': mention_type,
            'deep_link': deep_link,
            'source_id': source_id or ''
        }
        if room_id:
            data['room_id'] = room_id
        if post_id:
            data['post_id'] = post_id
        
        thread_id = f"mentions_{room_id or post_id or 'general'}"
        
        return await self.send_push(
            device_token=device_token,
            title=title,
            body=body,
            data=data,
            thread_id=thread_id,
            category='MENTION',
            mutable_content=True
        )

    async def send_new_post_notification(
        self,
        device_token: str,
        author_name: str,
        post_preview: str,
        post_id: str,
        author_id: str
    ) -> bool:
        """Send push notification when a subscribed user creates a new post."""
        body = post_preview[:100] if len(post_preview) > 100 else post_preview
        return await self.send_push(
            device_token=device_token,
            title=f"📝 {author_name} posted",
            body=body,
            data={
                'type': 'new_post',
                'post_id': post_id,
                'author_id': author_id
            },
            thread_id=f"posts_{author_id}",
            category='NEW_POST'
        )
    
    @staticmethod
    def should_send_push(user, notification_type: str) -> dict:
        """
        Check user's notification preferences before sending push.
        
        Args:
            user: User model instance (must have notification pref columns)
            notification_type: One of 'message', 'friend_request', 'like',
                             'comment', 'mention', 'new_post'
        
        Returns:
            dict with keys:
                - allowed: bool (whether to send)
                - sound: str or None (sound name or None for silent)
                - show_preview: bool (whether to show message content)
        """
        result = {
            "allowed": True,
            "sound": "default",
            "show_preview": True
        }
        
        # Master switch
        if not getattr(user, 'push_enabled', True):
            result["allowed"] = False
            return result
        
        # Type-specific checks
        if notification_type == "message":
            if not getattr(user, 'message_notifications_enabled', True):
                result["allowed"] = False
                return result
            result["show_preview"] = getattr(user, 'message_preview_enabled', True)
        
        elif notification_type == "friend_request":
            if not getattr(user, 'friend_request_notifications_enabled', True):
                result["allowed"] = False
                return result
        
        elif notification_type in ("like", "comment"):
            if not getattr(user, 'likes_comments_notifications_enabled', True):
                result["allowed"] = False
                return result
        
        elif notification_type == "mention":
            # Mentions always go through if push is enabled (master switch)
            pass
        
        elif notification_type == "new_post":
            # New post notifications always go through if push is enabled
            pass
        
        # Sound preference
        if not getattr(user, 'sounds_enabled', True):
            result["sound"] = None
        
        return result



# Singleton instance
_apns_service: Optional[APNsService] = None


def get_apns_service() -> APNsService:
    """Get or create APNs service singleton."""
    global _apns_service
    if _apns_service is None:
        _apns_service = APNsService()
    return _apns_service
