"""
WebSocket Connection Manager — Event-Driven Push + Redis Pub/Sub

Instead of polling the DB every 3 seconds, this manager maintains per-user
asyncio.Queue instances. When a message is saved, `notify()` pushes the data
directly into the recipient's queue — achieving near-instant delivery (~50ms
vs 3000ms).

Multi-instance support:
    In production (Cloud Run), multiple container instances may be running.
    User A might be connected to Instance 1 while a message for A arrives at
    Instance 2. Redis Pub/Sub bridges this gap:
    - notify() publishes to Redis channel `ws:user:{user_id}`
    - connect() subscribes to that channel for the connected user
    - Local queue is still used for same-instance delivery (fastest path)

Usage:
    # In main.py (WebSocket handler)
    await ws_manager.connect(user_id, websocket)
    ...
    await ws_manager.disconnect(user_id) 

    # In messages.py (after saving a message)
    from ws_manager import ws_manager
    await ws_manager.notify(recipient_id, message_dict)
"""

import asyncio
import json
import logging
import os
from typing import Optional
from fastapi import WebSocket

logger = logging.getLogger(__name__)

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")


class WebSocketManager:
    """Manages WebSocket connections with per-user event queues for instant push."""

    def __init__(self):
        # user_id → WebSocket connection
        self._connections: dict[str, WebSocket] = {}
        # user_id → asyncio.Queue for pending messages
        self._queues: dict[str, asyncio.Queue] = {}
        # Lock for thread-safe operations
        self._lock = asyncio.Lock()
        # Redis Pub/Sub (lazy init)
        self._redis = None
        self._pubsub = None
        self._pubsub_tasks: dict[str, asyncio.Task] = {}
        self._redis_available = False

    def _init_redis(self):
        """Lazy-init Redis for Pub/Sub (production only)."""
        if self._redis is not None:
            return
        if ENVIRONMENT != "production":
            return
        try:
            import redis.asyncio as aioredis
            self._redis = aioredis.from_url(
                REDIS_URL,
                decode_responses=True,
                socket_connect_timeout=3,
            )
            self._redis_available = True
            logger.info("✅ [WSManager] Redis Pub/Sub initialized")
        except Exception as e:
            self._redis_available = False
            logger.warning(f"⚠️ [WSManager] Redis Pub/Sub unavailable: {e}")

    async def _subscribe_user(self, user_id: str):
        """Subscribe to Redis channel for cross-instance message delivery."""
        if not self._redis_available:
            return
        try:
            pubsub = self._redis.pubsub()
            channel = f"ws:user:{user_id}"
            await pubsub.subscribe(channel)
            logger.info(f"📡 [WSManager] Subscribed to {channel}")

            async def _listener():
                try:
                    async for message in pubsub.listen():
                        if message["type"] == "message":
                            data = json.loads(message["data"])
                            # Push to local queue (if user still connected locally)
                            queue = self._queues.get(user_id)
                            if queue:
                                try:
                                    queue.put_nowait(data)
                                except asyncio.QueueFull:
                                    pass
                except asyncio.CancelledError:
                    await pubsub.unsubscribe(channel)
                    await pubsub.close()
                except Exception as e:
                    logger.warning(f"⚠️ [WSManager] Pub/Sub listener error: {e}")

            task = asyncio.create_task(_listener())
            self._pubsub_tasks[user_id] = task
        except Exception as e:
            logger.warning(f"⚠️ [WSManager] Subscribe failed for {user_id[:8]}: {e}")

    async def _unsubscribe_user(self, user_id: str):
        """Cancel Pub/Sub listener for user."""
        task = self._pubsub_tasks.pop(user_id, None)
        if task:
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass

    async def connect(self, user_id: str, websocket: WebSocket) -> asyncio.Queue:
        """
        Register a WebSocket connection for a user.
        Returns the user's event queue to await on.
        
        If the user already has a connection, the old one is replaced
        (handles reconnection gracefully).
        """
        self._init_redis()

        async with self._lock:
            # Close existing connection if any (user reconnected)
            if user_id in self._connections:
                old_ws = self._connections[user_id]
                try:
                    await old_ws.close(code=4002, reason="Replaced by new connection")
                except Exception:
                    pass
                await self._unsubscribe_user(user_id)
                logger.info(f"🔌 [WSManager] Replaced existing connection for {user_id[:8]}")

            self._connections[user_id] = websocket
            # Create a fresh queue (drop stale events from old session)
            self._queues[user_id] = asyncio.Queue(maxsize=100)

            logger.info(f"🔌 [WSManager] Connected: {user_id[:8]} (total: {len(self._connections)})")

        # Subscribe to Redis for cross-instance delivery (outside lock)
        await self._subscribe_user(user_id)

        return self._queues[user_id]

    async def disconnect(self, user_id: str):
        """Unregister a user's WebSocket connection."""
        async with self._lock:
            self._connections.pop(user_id, None)
            self._queues.pop(user_id, None)
            logger.info(f"🔌 [WSManager] Disconnected: {user_id[:8]} (total: {len(self._connections)})")
        await self._unsubscribe_user(user_id)

    async def notify(self, user_id: str, message_data: dict):
        """
        Push a message event to a connected user's queue.
        
        If the user is not connected, this is a no-op (message is still
        stored in DB and will be fetched on next bridge-downlink or reconnect).
        
        In production, also publishes to Redis Pub/Sub so other instances
        can deliver the message if the user is connected there.
        
        Non-blocking: if the queue is full, the event is dropped (rare edge case
        with >100 unprocessed events).
        """
        # Local delivery (same instance — fastest path)
        queue = self._queues.get(user_id)
        if queue is not None:
            try:
                queue.put_nowait(message_data)
                logger.info(f"⚡ [WSManager] Pushed message to {user_id[:8]} (queue size: {queue.qsize()})")
            except asyncio.QueueFull:
                logger.warning(f"⚠️ [WSManager] Queue full for {user_id[:8]}, dropping event")

        # Cross-instance delivery via Redis Pub/Sub
        if self._redis_available and self._redis:
            try:
                channel = f"ws:user:{user_id}"
                await self._redis.publish(channel, json.dumps(message_data, default=str))
            except Exception as e:
                logger.warning(f"⚠️ [WSManager] Redis publish failed: {e}")

    def is_connected(self, user_id: str) -> bool:
        """Check if a user has an active WebSocket connection."""
        return user_id in self._connections

    @property
    def connection_count(self) -> int:
        """Number of active WebSocket connections."""
        return len(self._connections)


# Global singleton
ws_manager = WebSocketManager()
