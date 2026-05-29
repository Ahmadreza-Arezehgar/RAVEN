"""
news_bot/poster.py
==================

Logs the bot account into the RAVEN backend and publishes each picked
story as a regular post. The bot is a normal user from the server's
perspective — the only thing that distinguishes it visually is the
`is_verified` blue tick on the account itself, which an operator
flips manually in the DB (one-time setup).

Auth flow:

    POST /api/auth/login            ← username + password
    → access_token, refresh_token

    POST /api/posts/create          ← Authorization: Bearer <token>
       { content, visibility: "public" }

We don't bother refreshing the access token — the bot only runs for a
few seconds at a time and tokens last well over an hour. If a request
401s we just re-login from scratch.
"""

from __future__ import annotations

import ipaddress
import json
import socket
from dataclasses import dataclass
from typing import Optional
from urllib.parse import urlparse

import httpx

from .config import Config
from .ranker import RankedPick


# ── SSRF protection for image mirroring ──────────────────────────────
#
# The bot accepts image URLs from third-party RSS feeds and dereferences
# them. Without validation a malicious (or compromised) RSS source could
# point the bot at internal LAN addresses, the cloud-metadata endpoint
# (169.254.169.254), or the user's localhost services and use the bot
# as a confused-deputy probe.
#
# Defence:
#   1. Only http/https schemes.
#   2. Resolve the hostname server-side and reject any non-global IP.
#   3. Disable redirect-following — a 30x to an internal URL would
#      otherwise sneak past the host check.
#   4. Cap response size during streaming, not just after the fact.

def _is_url_safe(url: str) -> tuple[bool, str]:
    """Return (ok, reason). Reject anything that could SSRF the host."""
    try:
        parsed = urlparse(url)
    except Exception as e:
        return False, f"unparseable URL: {e!s}"

    if parsed.scheme not in ("http", "https"):
        return False, f"unsupported scheme {parsed.scheme!r}"
    if not parsed.hostname:
        return False, "missing host"

    # Resolve all A/AAAA records for the host. Any non-global address
    # disqualifies the URL — defeats both the literal-IP form and the
    # DNS-rebinding trick where a hostname resolves to 127.0.0.1.
    try:
        addrs = {info[4][0] for info in socket.getaddrinfo(
            parsed.hostname, None, type=socket.SOCK_STREAM
        )}
    except socket.gaierror as e:
        return False, f"DNS failure: {e!s}"

    for addr in addrs:
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            return False, f"bad address {addr!r}"
        # `is_global` is True only for routable public addresses. It
        # rejects RFC 1918 (10/8, 172.16/12, 192.168/16), loopback
        # (127/8, ::1), link-local (169.254/16, fe80::/10),
        # multicast, reserved, unspecified, and benchmark ranges.
        if not ip.is_global:
            return False, f"non-global address {addr!r}"
    return True, ""


class PosterError(RuntimeError):
    """Raised when the server returns an unexpected status."""


@dataclass
class PostResult:
    url: str                      # original article URL (for dedup key)
    raven_post_id: Optional[str]  # server-assigned id (for analytics)
    ok: bool
    error: Optional[str] = None


class RavenPoster:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._client = httpx.Client(
            base_url=cfg.raven_base_url,
            timeout=20,
            headers={"User-Agent": "raven-news-bot/1.0"},
        )
        self._token: Optional[str] = None

    def __enter__(self):
        self._login()
        return self

    def __exit__(self, *_):
        self._client.close()

    # ── Auth ────────────────────────────────────────────────────────

    def _login(self) -> None:
        r = self._client.post(
            "/api/auth/login",
            json={
                "username": self.cfg.raven_bot_username,
                "password": self.cfg.raven_bot_password,
            },
        )
        if r.status_code != 200:
            raise PosterError(
                f"login failed: {r.status_code} {r.text[:300]}"
            )
        body = r.json()
        token = body.get("token") or body.get("access_token")
        if not token:
            # Don't echo `body` — error paths can carry unrelated keys
            # (refresh_token, server-side trace IDs, partial user
            # objects) that we don't want landing in /tmp/raven-news-bot.log.
            raise PosterError("login response missing 'token' field")
        self._token = token

    # ── Publish ─────────────────────────────────────────────────────

    def publish(self, pick: RankedPick) -> PostResult:
        """Render a pick into a RAVEN post body + send it."""
        assert self._token, "must call _login first"

        content = _render_body(pick)

        # Image mirroring intentionally disabled (user request, 2026-05-12).
        # We keep `_mirror_image` + the SSRF gate around for the day we
        # turn this back on, but for now every post is text-only. The
        # source link inside the body already auto-renders as a card on
        # most clients (iOS PostCard, etc.).
        payload = {
            "content": content,
            "visibility": "public",
            "is_local": False,
        }

        r = self._client.post(
            "/api/posts/create",
            headers={"Authorization": f"Bearer {self._token}"},
            json=payload,
        )

        # Token might have died mid-run — re-login + retry once.
        if r.status_code == 401:
            self._login()
            r = self._client.post(
                "/api/posts/create",
                headers={"Authorization": f"Bearer {self._token}"},
                json=payload,
            )

        if r.status_code != 200:
            return PostResult(
                url=pick.url, raven_post_id=None, ok=False,
                error=f"HTTP {r.status_code}: {r.text[:200]}",
            )

        try:
            post_id = r.json().get("id")
        except json.JSONDecodeError:
            post_id = None
        return PostResult(url=pick.url, raven_post_id=post_id, ok=True)

    # ── Image mirroring ─────────────────────────────────────────────

    def _mirror_image(self, source_url: str) -> str | None:
        """
        Download `source_url` and push it through RAVEN's image upload
        endpoint. Returns the RAVEN-hosted image URL on success, or None
        on any failure (network, bad MIME, oversize, SSRF reject).
        Per-image failures are isolated so a single broken thumbnail
        never blocks a post.
        """
        # ── SSRF gate ──────────────────────────────────────────────
        ok, reason = _is_url_safe(source_url)
        if not ok:
            print(f"[poster] SSRF reject ({reason}): {source_url[:80]}")
            return None

        try:
            # `follow_redirects=False` — a 30x to an internal URL would
            # otherwise sneak past the host check above. If the publisher
            # legitimately serves images behind a redirect, the bot's
            # next tick gets a fresh URL via the feed.
            #
            # Read in 64 KB chunks with a hard cap so a malicious server
            # can't tarpit us by streaming forever.
            cap = 8 * 1024 * 1024
            data = bytearray()
            ctype = ""
            with httpx.Client(timeout=15, follow_redirects=False) as fetcher:
                with fetcher.stream("GET", source_url, headers={
                    "User-Agent": (
                        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                        "AppleWebKit/537.36 (KHTML, like Gecko) "
                        "Chrome/123.0.0.0 Safari/537.36"
                    ),
                }) as resp:
                    if resp.status_code != 200:
                        print(f"[poster] image fetch {resp.status_code}: {source_url[:80]}")
                        return None
                    ctype = (resp.headers.get("content-type") or "").split(";")[0].strip().lower()
                    for chunk in resp.iter_bytes(chunk_size=64 * 1024):
                        data.extend(chunk)
                        if len(data) > cap:
                            print(f"[poster] image too big (>{cap} bytes): {source_url[:80]}")
                            return None
            data = bytes(data)

            # `ctype` was captured inside the streaming `with` above.
            # Pick the filename extension that matches.
            ext_from_ctype = {
                "image/jpeg": ".jpg",
                "image/jpg":  ".jpg",
                "image/png":  ".png",
                "image/webp": ".webp",
                "image/gif":  ".gif",
            }.get(ctype)
            if ext_from_ctype is None:
                # Fall back to the URL extension.
                lower = source_url.lower().split("?")[0]
                for ext in (".jpg", ".jpeg", ".png", ".webp", ".gif"):
                    if lower.endswith(ext):
                        ext_from_ctype = ext if ext != ".jpeg" else ".jpg"
                        ctype = f"image/{ext.lstrip('.')}".replace("/jpg", "/jpeg")
                        break
            if ext_from_ctype is None:
                # Unknown image type — the RAVEN endpoint will reject it,
                # don't waste a round-trip.
                print(f"[poster] unknown image type ({ctype}): {source_url[:80]}")
                return None

            files = {"file": (f"news{ext_from_ctype}", data, ctype or "image/jpeg")}

            # Upload through the authenticated image endpoint.
            up = self._client.post(
                "/api/uploads/image",
                headers={"Authorization": f"Bearer {self._token}"},
                files=files,
            )
            if up.status_code == 401:
                self._login()
                up = self._client.post(
                    "/api/uploads/image",
                    headers={"Authorization": f"Bearer {self._token}"},
                    files=files,
                )
            if up.status_code != 200:
                print(f"[poster] image upload {up.status_code}: {up.text[:160]}")
                return None
            try:
                return up.json().get("image_url")
            except json.JSONDecodeError:
                return None
        except Exception as e:                              # noqa: BLE001 - best-effort
            print(f"[poster] image mirror failed for {source_url[:80]}: {e!s}")
            return None


# ── Post body template ─────────────────────────────────────────────

def _render_body(pick: RankedPick) -> str:
    """
    Render a ranked pick into the post body our chat / feed will show.
    Format:

        <HEADLINE>

        <BODY>

        🔗 Source: <SOURCE NAME>
        <ARTICLE URL>
    """
    return (
        f"{pick.headline}\n\n"
        f"{pick.body}\n\n"
        f"🔗 {pick.source}\n"
        f"{pick.url}"
    )
