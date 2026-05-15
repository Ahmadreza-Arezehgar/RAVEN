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
        expiration: int = 3600,
        collapse_id: Optional[str] = None,
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
            '-H', f'apns-expiration: {expiration}',
            '-H', 'content-type: application/json',
        ]
        # apns-collapse-id is APNs's native dedup mechanism — when
        # set, an undelivered alert with the same id is replaced by
        # this one (max 64 bytes per Apple's spec). Used so retried
        # message pushes don't stack up in Notification Center.
        if collapse_id:
            collapse_truncated = collapse_id[:64]
            curl_cmd.extend(['-H', f'apns-collapse-id: {collapse_truncated}'])
        curl_cmd.extend([
            '-d', payload_json,
            '--max-time', '10',
            '--connect-timeout', '5',
            url
        ])
        
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
        priority: int = 10,
        push_environment: Optional[str] = None,
        collapse_id: Optional[str] = None,
    ) -> bool:
        """
        Send a push notification to an iOS device via APNs HTTP/2 API.
        Uses curl subprocess for reliable HTTP/2.
        Automatically retries with opposite environment on BadEnvironmentKeyInToken.
        
        Args:
            push_environment: Optional. "sandbox" or "production". If provided,
                sends directly to that environment (no fallback). If None, uses
                the server's configured default and retries the opposite on error.
        """
        if not self.is_configured:
            logger.warning("APNs not configured - skipping push")
            return False
            
        token = self._get_token()
        if not token:
            logger.error("❌ APNs token generation failed - cannot send push")
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
        # ⚠️ IMPORTANT: Do NOT include content-available:1 in alert pushes.
        # Combining content-available with apns-push-type:alert causes
        # undefined behavior per Apple docs — APNs may silently drop the
        # notification, which is the root cause of intermittent lock screen
        # failures. content-available is only used in send_bridge_wake_push
        # (which correctly uses apns-push-type:background + priority:5).
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
        
        # Determine which environment to try first.
        # If push_environment is explicitly set per-user, use that directly.
        # Otherwise fall back to the server's configured default.
        if push_environment == "sandbox":
            use_sandbox_first = True
        elif push_environment == "production":
            use_sandbox_first = False
        else:
            use_sandbox_first = self.use_sandbox
        
        try:
            # First attempt
            host = self.sandbox_host if use_sandbox_first else self.production_host
            env_label = "SANDBOX" if use_sandbox_first else "PRODUCTION"
            url = f"{host}/3/device/{device_token}"
            
            logger.info(f"🚀 Sending push via curl to {device_token[:16]}... [{env_label}]")
            
            status_code, response_body, error = await self._curl_send(
                url, token, payload_json, priority, collapse_id=collapse_id
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
            
            # If environment mismatch, retry with opposite environment.
            # ⚠️ CRITICAL: Do NOT mutate self.use_sandbox here!
            # The singleton is shared across ALL concurrent requests.
            # Flipping it causes production tokens to fail after a sandbox
            # token succeeds (or vice versa). Each retry is per-token only.
            if reason == 'BadEnvironmentKeyInToken':
                alt_sandbox = not use_sandbox_first
                alt_host = self.sandbox_host if alt_sandbox else self.production_host
                alt_label = "SANDBOX" if alt_sandbox else "PRODUCTION"
                alt_url = f"{alt_host}/3/device/{device_token}"
                
                logger.warning(f"🔄 Retrying push with {alt_label} (got {reason} from {env_label})")
                
                status_code2, response_body2, error2 = await self._curl_send(
                    alt_url, token, payload_json, priority, collapse_id=collapse_id
                )
                
                if error2:
                    logger.error(f"❌ curl error [{alt_label}]: {error2}")
                    return False
                
                if status_code2 == 200:
                    logger.info(f"📱 Push sent [{alt_label}] type={notif_type} to {device_token[:16]}... (fallback worked!)")
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
                    
                    # If both environments reject the token, it's truly invalid
                    if reason2 in ('BadDeviceToken', 'Unregistered'):
                        logger.warning(f"🧹 Token invalid in both environments: {device_token[:16]}... — cleaning up")
                        import asyncio
                        asyncio.ensure_future(self.cleanup_stale_token(device_token))
                    
                    return False
            
            logger.error(f"❌ APNs error [{env_label}] ({status_code}): {reason} | type={notif_type} token={device_token[:16]}...")
            
            if reason == 'Unregistered':
                logger.warning(f"🧹 Device unregistered: {device_token[:16]}... — cleaning up stale token")
                import asyncio
                asyncio.ensure_future(self.cleanup_stale_token(device_token))
            elif reason == 'BadDeviceToken':
                logger.warning(f"🧹 Bad device token: {device_token[:16]}... — cleaning up stale token")
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
        push_environment: Optional[str] = None,
        message_id: Optional[str] = None,
        client_message_id: Optional[str] = None,
    ) -> bool:
        """Send push notification for a new message.

        ``message_id`` / ``client_message_id`` are echoed in the data
        payload AND used as the APNs collapse id so the iOS client
        can dedup against a mesh-delivered copy of the same message.
        Either id works — when both are present, message_id wins.
        """

        # Format notification based on message type
        if message_type == "voice":
            body = "🎤 Voice message"
        elif message_type == "image":
            body = "📷 Image"
        elif message_type == "video":
            body = "🎬 Video"
        else:
            # Truncate text preview
            body = message_preview[:100] if len(message_preview) > 100 else message_preview

        data = {
            'type': 'message',
            'room_id': room_id,
            'sender_id': sender_id,
            'message_type': message_type,
        }
        if message_id:
            data['message_id'] = message_id
        if client_message_id:
            data['client_message_id'] = client_message_id

        # Prefer the server message id for the collapse key — same
        # value the iOS client uses as the local-notification
        # identifier in `RAVENApp.swift`'s mesh handler. APNs
        # collapses outgoing alerts that share this id so retransmits
        # don't pile up either.
        collapse_id = message_id or client_message_id

        return await self.send_push(
            device_token=device_token,
            title=sender_name,
            body=body,
            data=data,
            thread_id=f"chat_{room_id}",
            category='MESSAGE',
            mutable_content=True,
            badge=badge,
            push_environment=push_environment,
            collapse_id=collapse_id,
        )
    
    async def send_group_message_notification(
        self,
        device_token: str,
        sender_name: str,
        group_name: str,
        message_preview: str,
        room_id: str,
        sender_id: str,
        message_type: str = "text",
        badge: Optional[int] = None,
        push_environment: Optional[str] = None
    ) -> bool:
        """Send push notification for a group message.
        
        Uses type='group_message' so the iOS client can distinguish
        group messages from DMs and show the correct thread grouping.
        """
        
        # Format notification based on message type
        if message_type == "voice":
            body = "🎤 Voice message"
        elif message_type == "image":
            body = "📷 Image"
        elif message_type == "video":
            body = "🎬 Video"
        elif message_type == "video_note":
            body = "🎥 Video note"
        elif message_type == "location":
            body = "📍 Location"
        elif message_type == "file":
            body = "📎 File"
        else:
            body = message_preview[:100] if len(message_preview) > 100 else message_preview
        
        return await self.send_push(
            device_token=device_token,
            title=f"{sender_name} in {group_name}",
            body=body,
            data={
                'type': 'group_message',
                'room_id': room_id,
                'group_id': room_id,
                'group_name': group_name,
                'sender_id': sender_id,
                'sender_name': sender_name,
                'message_type': message_type,
                'preview': body
            },
            thread_id=f"group_{room_id}",
            category='MESSAGE',
            mutable_content=True,
            badge=badge,
            push_environment=push_environment
        )
    
    async def send_added_to_group_notification(
        self,
        device_token: str,
        adder_name: str,
        group_name: str,
        group_id: str,
        badge: Optional[int] = None,
        push_environment: Optional[str] = None
    ) -> bool:
        """Send push notification when a user is added to a group."""
        return await self.send_push(
            device_token=device_token,
            title=f"Added to {group_name}",
            body=f"{adder_name} added you to {group_name}",
            data={
                'type': 'added_to_group',
                'group_id': group_id,
                'room_id': group_id,
                'group_name': group_name,
                'sender_name': adder_name
            },
            thread_id=f"group_{group_id}",
            badge=badge,
            push_environment=push_environment
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
        badge: Optional[int] = None,
        push_environment: Optional[str] = None
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
            badge=badge,
            push_environment=push_environment
        )
    
    async def send_comment_notification(
        self,
        device_token: str,
        commenter_name: str,
        comment_preview: str,
        post_id: str,
        badge: Optional[int] = None,
        push_environment: Optional[str] = None
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
            badge=badge,
            push_environment=push_environment
        )
    
    async def send_friend_request_notification(
        self,
        device_token: str,
        requester_name: str,
        requester_id: str,
        badge: Optional[int] = None,
        push_environment: Optional[str] = None
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
            badge=badge,
            push_environment=push_environment
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
        group_name: str = None,
        push_environment: Optional[str] = None
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
            mutable_content=True,
            push_environment=push_environment
        )

    async def send_new_post_notification(
        self,
        device_token: str,
        author_name: str,
        post_preview: str,
        post_id: str,
        author_id: str,
        push_environment: Optional[str] = None
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
            category='NEW_POST',
            push_environment=push_environment
        )
    
    async def send_audio_room_notification(
        self,
        device_token: str,
        host_name: str,
        room_title: str,
        room_id: str,
        host_id: str,
        badge: int = 0,
        push_environment: Optional[str] = None
    ) -> bool:
        """Send push notification when a subscribed user creates an audio room."""
        return await self.send_push(
            device_token=device_token,
            title=f"🎙️ {host_name} started a room",
            body=room_title[:100],
            data={
                'type': 'audio_room',
                'room_id': room_id,
                'host_id': host_id
            },
            badge=badge,
            thread_id=f"rooms_{host_id}",
            category='AUDIO_ROOM',
            push_environment=push_environment
        )

    # ────────────────────────────────────────────────────────────────────
    # Privacy & Safety pushes (added 2026-05-14)
    # ────────────────────────────────────────────────────────────────────

    async def send_security_alert(
        self,
        device_token: str,
        title: str,
        body: str,
        event_id: str,
        push_environment: Optional[str] = None
    ) -> bool:
        """New-device sign-in, password change, biometric disabled, etc."""
        return await self.send_push(
            device_token=device_token,
            title=title,
            body=body[:200],
            data={'type': 'security_alert', 'event_id': event_id},
            thread_id="security",
            category='SECURITY_ALERT',
            push_environment=push_environment
        )

    async def send_live_location_started(
        self,
        device_token: str,
        sharer_name: str,
        room_id: str,
        sharer_id: str,
        push_environment: Optional[str] = None
    ) -> bool:
        return await self.send_push(
            device_token=device_token,
            title=f"📍 {sharer_name} is sharing live location",
            body="Tap to open the map.",
            data={
                'type': 'live_location_started',
                'room_id': room_id,
                'sharer_id': sharer_id
            },
            thread_id=f"livelocation_{room_id}",
            category='LIVE_LOCATION',
            push_environment=push_environment
        )

    async def send_live_location_ended(
        self,
        device_token: str,
        sharer_name: str,
        room_id: str,
        sharer_id: str,
        push_environment: Optional[str] = None
    ) -> bool:
        return await self.send_push(
            device_token=device_token,
            title=f"📍 {sharer_name} stopped sharing live location",
            body="",
            data={
                'type': 'live_location_ended',
                'room_id': room_id,
                'sharer_id': sharer_id
            },
            thread_id=f"livelocation_{room_id}",
            category='LIVE_LOCATION',
            push_environment=push_environment
        )

    async def send_reaction_notification(
        self,
        device_token: str,
        reactor_name: str,
        emoji: str,
        room_id: str,
        message_id: str,
        push_environment: Optional[str] = None
    ) -> bool:
        return await self.send_push(
            device_token=device_token,
            title=f"{emoji} {reactor_name}",
            body="reacted to your message",
            data={
                'type': 'reaction',
                'room_id': room_id,
                'message_id': message_id,
                'emoji': emoji
            },
            thread_id=f"reactions_{room_id}",
            category='REACTION',
            push_environment=push_environment
        )

    async def send_contact_shared_notification(
        self,
        device_token: str,
        sharer_name: str,
        recipient_name: str,
        room_id: str,
        sharer_id: str,
        push_environment: Optional[str] = None
    ) -> bool:
        """Notify a user that their profile was shared as a contact card."""
        return await self.send_push(
            device_token=device_token,
            title="👤 Your profile was shared",
            body=f"{sharer_name} shared your contact with {recipient_name}.",
            data={
                'type': 'contact_shared',
                'room_id': room_id,
                'sharer_id': sharer_id
            },
            thread_id="contact_shared",
            category='CONTACT_SHARED',
            push_environment=push_environment
        )

    async def send_profile_view_notification(
        self,
        device_token: str,
        viewer_name: str,
        viewer_id: str,
        push_environment: Optional[str] = None
    ) -> bool:
        """Sent only when the viewer is NOT a friend (filter at call site)."""
        return await self.send_push(
            device_token=device_token,
            title="👀 Someone viewed your profile",
            body=f"{viewer_name} opened your profile.",
            data={'type': 'profile_view', 'viewer_id': viewer_id},
            thread_id="profile_views",
            category='PROFILE_VIEW',
            push_environment=push_environment
        )

    async def send_screenshot_notification(
        self,
        device_token: str,
        viewer_name: str,
        viewer_id: str,
        scope: str,
        room_id: Optional[str] = None,
        push_environment: Optional[str] = None
    ) -> bool:
        """`scope` is 'profile' or 'chat'."""
        if scope == "chat":
            cat = 'SCREENSHOT_CHAT'
            body = f"{viewer_name} took a screenshot of your chat."
            data = {
                'type': 'screenshot_chat',
                'viewer_id': viewer_id,
                'room_id': room_id or ""
            }
        else:
            cat = 'SCREENSHOT_PROFILE'
            body = f"{viewer_name} took a screenshot of your profile."
            data = {'type': 'screenshot_profile', 'viewer_id': viewer_id}
        return await self.send_push(
            device_token=device_token,
            title="📸 Screenshot detected",
            body=body,
            data=data,
            thread_id="screenshots",
            category=cat,
            push_environment=push_environment
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
            # Check granular mention preference
            if not getattr(user, 'mention_notifications_enabled', True):
                result["allowed"] = False
                return result
        
        elif notification_type == "new_post":
            # Check granular new post preference
            if not getattr(user, 'new_post_notifications_enabled', True):
                result["allowed"] = False
                return result
        
        elif notification_type == "audio_room":
            # Check granular audio room preference
            if not getattr(user, 'audio_room_notifications_enabled', True):
                result["allowed"] = False
                return result

        # ── New types added 2026-05-14 (Privacy & Safety section) ──
        elif notification_type == "security_alert":
            if not getattr(user, 'security_alert_notifications_enabled', True):
                result["allowed"] = False
                return result

        elif notification_type in ("live_location_started", "live_location_ended"):
            if not getattr(user, 'live_location_notifications_enabled', True):
                result["allowed"] = False
                return result

        elif notification_type == "reaction":
            if not getattr(user, 'reaction_notifications_enabled', True):
                result["allowed"] = False
                return result

        elif notification_type == "contact_shared":
            if not getattr(user, 'contact_shared_notifications_enabled', True):
                result["allowed"] = False
                return result

        elif notification_type == "profile_view":
            # Default OFF (opt-in) — see migration. The getattr default
            # mirrors that, so existing users with no column entry stay
            # silent until they explicitly opt in.
            if not getattr(user, 'profile_view_notifications_enabled', False):
                result["allowed"] = False
                return result

        elif notification_type in ("screenshot_profile", "screenshot_chat"):
            if not getattr(user, 'screenshot_notifications_enabled', True):
                result["allowed"] = False
                return result

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
