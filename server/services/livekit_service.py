"""
LiveKit server-side controls for audio rooms.

Without this module, the `mute_participant`, `kick_participant`, `mute_all`,
and `end_room` endpoints in `routers/rooms.py` only flip DB rows and never
reach the actual SFU. The host believes they muted someone — that someone
keeps broadcasting until their own client polls and decides to mute itself.
This was the single biggest "audio rooms have issues" complaint.

Usage:

    from services.livekit_service import LiveKitControl

    control = LiveKitControl()
    await control.mute_participant(room_id="<uuid>", identity="<user_id>", muted=True)
    await control.remove_participant(room_id="<uuid>", identity="<user_id>")
    await control.delete_room(room_id="<uuid>")

Identities MUST match what the JWT puts in `sub` (i.e. the User.id, see
`livekit.py:111`). Room name MUST match the `room` claim in the JWT
(`audio-room-{room_id}`).

All methods are best-effort and never raise — LiveKit failures don't
deserve to break the user-visible host action. They log the failure and
let the DB row update proceed. The contract is: server tries to enforce
on the SFU; the DB row is the source of truth.
"""

from __future__ import annotations

import asyncio
import os
from typing import Optional

# Don't crash the server if the SDK isn't installed (e.g. during early
# build runs). The module degrades to no-op with a loud log.
try:
    from livekit import api as lkapi  # type: ignore
    _SDK_AVAILABLE = True
except Exception as _e:
    lkapi = None  # type: ignore
    _SDK_AVAILABLE = False
    _SDK_IMPORT_ERROR = str(_e)


def _room_name(room_id: str) -> str:
    """Match the convention used in `routers/livekit.py:97`."""
    return f"audio-room-{room_id}"


class LiveKitControl:
    """Thin async wrapper around LiveKit RoomService for the host actions
    we need: mute, remove participant, delete room.

    Reads `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` from env.
    """

    def __init__(
        self,
        url: Optional[str] = None,
        api_key: Optional[str] = None,
        api_secret: Optional[str] = None,
    ) -> None:
        self.url = url or os.getenv("LIVEKIT_URL", "")
        self.api_key = api_key or os.getenv("LIVEKIT_API_KEY", "")
        self.api_secret = api_secret or os.getenv("LIVEKIT_API_SECRET", "")

    @property
    def is_configured(self) -> bool:
        return _SDK_AVAILABLE and bool(self.url and self.api_key and self.api_secret)

    def _client(self):
        """Build a fresh RoomService client. The official SDK uses an
        async-managed httpx pool internally; we open + close per-call to
        avoid leaking sessions across Cloud Run instance lifetimes."""
        if not self.is_configured:
            return None
        # `RoomService` from livekit-api uses websocket-style URL but the
        # HTTP API expects https. Convert ws:// → http:// and wss:// → https://
        http_url = self.url.replace("wss://", "https://").replace("ws://", "http://")
        return lkapi.LiveKitAPI(http_url, self.api_key, self.api_secret)

    async def _mute_track(self, room_id: str, identity: str, muted: bool) -> bool:
        """Force-mute a participant's published audio track on the SFU.

        Note: LiveKit's mute is per-track. We enumerate published tracks
        and mute every audio track. Returns True on at least one mute.
        """
        client = self._client()
        if client is None:
            print(f"⚠️ [LiveKitControl] mute skipped — SDK/config unavailable")
            return False
        try:
            room_name = _room_name(room_id)
            participants = await client.room.list_participants(
                lkapi.ListParticipantsRequest(room=room_name)
            )
            target = next(
                (p for p in participants.participants if p.identity == identity),
                None,
            )
            if target is None:
                print(f"⚠️ [LiveKitControl] participant {identity[:8]} not found in {room_name}")
                return False
            muted_any = False
            for track in target.tracks:
                # Only audio tracks (source==MICROPHONE) — skip video/screen.
                # `track.source` is an enum; comparing by name is most portable.
                if str(track.source).lower().endswith("microphone") or track.type == 0:
                    await client.room.mute_published_track(
                        lkapi.MuteRoomTrackRequest(
                            room=room_name,
                            identity=identity,
                            track_sid=track.sid,
                            muted=muted,
                        )
                    )
                    muted_any = True
            return muted_any
        except Exception as e:
            print(f"⚠️ [LiveKitControl] mute_track failed: {type(e).__name__}: {e}")
            return False
        finally:
            try:
                await client.aclose()
            except Exception:
                pass

    async def mute_participant(self, room_id: str, identity: str, muted: bool = True) -> bool:
        """Public mute API — server-side enforcement of host's mute action."""
        return await self._mute_track(room_id, identity, muted)

    async def remove_participant(self, room_id: str, identity: str) -> bool:
        """Disconnect a participant from the SFU (kick).

        Their LiveKit session ends; their mic is gone immediately, not on
        next client poll.
        """
        client = self._client()
        if client is None:
            print(f"⚠️ [LiveKitControl] remove skipped — SDK/config unavailable")
            return False
        try:
            await client.room.remove_participant(
                lkapi.RoomParticipantIdentity(
                    room=_room_name(room_id),
                    identity=identity,
                )
            )
            return True
        except Exception as e:
            print(f"⚠️ [LiveKitControl] remove_participant failed: {type(e).__name__}: {e}")
            return False
        finally:
            try:
                await client.aclose()
            except Exception:
                pass

    async def delete_room(self, room_id: str) -> bool:
        """End the SFU room — disconnects ALL participants instantly.

        Without this, end_room only flips `is_live=False` on the DB row;
        clients keep streaming audio to a phantom room until they poll.
        """
        client = self._client()
        if client is None:
            print(f"⚠️ [LiveKitControl] delete_room skipped — SDK/config unavailable")
            return False
        try:
            await client.room.delete_room(
                lkapi.DeleteRoomRequest(room=_room_name(room_id))
            )
            return True
        except Exception as e:
            print(f"⚠️ [LiveKitControl] delete_room failed: {type(e).__name__}: {e}")
            return False
        finally:
            try:
                await client.aclose()
            except Exception:
                pass


# Module-level singleton — cheap to construct (no network until used).
_control: Optional[LiveKitControl] = None


def get_livekit_control() -> LiveKitControl:
    global _control
    if _control is None:
        _control = LiveKitControl()
    return _control
