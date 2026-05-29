"""
simulation/api.py
=================

Thin HTTP client for the endpoints the simulation needs from RAVEN:

  • POST /api/auth/register                — bootstrap a persona
  • POST /api/auth/login                   — per-cycle token mint
  • GET  /api/posts/feed                   — fetch posts to react to
  • POST /api/posts/create                 — publish a text post
  • POST /api/posts/{post_id}/like         — like a post
  • POST /api/posts/{post_id}/view         — record a view
  • POST /api/comments/create              — post a reply

Everything is synchronous (`httpx.Client`); the orchestrator processes
one persona at a time, so concurrency would be premature here. Each
method raises `RavenAPIError` on non-2xx so the orchestrator can choose
to log + skip rather than crash the daemon.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import httpx


logger = logging.getLogger("simulation.api")


class RavenAPIError(RuntimeError):
    def __init__(self, status: int, body: str, route: str):
        super().__init__(f"{route} → {status}: {body[:240]}")
        self.status = status
        self.body = body
        self.route = route


@dataclass
class FeedPost:
    id: str
    author_id: str
    author_username: str
    content: str
    timestamp: str
    likes: int
    comments: int
    is_liked: bool


class RavenClient:
    def __init__(self, base_url: str, *, timeout: float = 25.0):
        self.base_url = base_url.rstrip("/")
        self._http = httpx.Client(
            base_url=self.base_url,
            timeout=timeout,
            headers={"User-Agent": "raven-simulation/1.0"},
            follow_redirects=False,  # explicit; we never expect 30x
        )
        self.token: Optional[str] = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self._http.close()

    # ── Auth ─────────────────────────────────────────────────────

    def register(
        self, *,
        username: str, password: str,
        first_name: str, last_name: str,
        birth_year: int, email: str,
    ) -> str:
        """Returns the new user_id. Raises if the server complains."""
        r = self._http.post("/api/auth/register", json={
            "username": username, "password": password,
            "first_name": first_name, "last_name": last_name,
            "birth_year": birth_year, "email": email,
        })
        if r.status_code != 200:
            raise RavenAPIError(r.status_code, r.text, "/register")
        body = r.json()
        self.token = body.get("token") or body.get("access_token")
        return body["user_id"]

    def login(self, *, username: str, password: str) -> str:
        r = self._http.post("/api/auth/login", json={
            "username": username, "password": password,
        })
        if r.status_code != 200:
            raise RavenAPIError(r.status_code, r.text, "/login")
        body = r.json()
        self.token = body.get("token") or body.get("access_token")
        if not self.token:
            raise RavenAPIError(200, "login: no token in response", "/login")
        return body["user_id"]

    def _auth_headers(self) -> Dict[str, str]:
        assert self.token, "must login or register first"
        return {"Authorization": f"Bearer {self.token}"}

    # ── Feed ─────────────────────────────────────────────────────

    def fetch_feed(self, limit: int = 20) -> List[FeedPost]:
        """Pull the public feed. Server respects `limit` / `offset`."""
        r = self._http.get(
            "/api/posts/feed",
            params={"limit": limit, "offset": 0},
            headers=self._auth_headers(),
        )
        if r.status_code != 200:
            raise RavenAPIError(r.status_code, r.text, "/feed")
        body = r.json()
        # The feed endpoint may return either a bare list or a
        # paginated envelope `{items, hasMore, nextOffset}` (see
        # PaginatedFeedResponse in posts.py). Handle both.
        items = body["items"] if isinstance(body, dict) and "items" in body else body
        out: List[FeedPost] = []
        for p in items:
            try:
                out.append(FeedPost(
                    id=p["id"],
                    author_id=p["author_id"],
                    author_username=p.get("author_username", "?"),
                    content=p.get("content", ""),
                    timestamp=p.get("timestamp", ""),
                    likes=int(p.get("likes", 0)),
                    comments=int(p.get("comments", 0)),
                    is_liked=bool(p.get("is_liked", False)),
                ))
            except (KeyError, TypeError, ValueError):
                continue
        return out

    # ── Mutations ────────────────────────────────────────────────

    def create_post(self, content: str) -> str:
        """Create a public text post. Returns the new post id."""
        payload = {
            "content": content,
            "visibility": "public",
            "is_local": False,
        }
        r = self._http.post(
            "/api/posts/create",
            headers=self._auth_headers(),
            json=payload,
        )
        if r.status_code != 200:
            raise RavenAPIError(r.status_code, r.text, "/posts/create")
        try:
            return r.json().get("id", "")
        except json.JSONDecodeError:
            return ""

    def like(self, post_id: str) -> None:
        r = self._http.post(
            f"/api/posts/{post_id}/like",
            headers=self._auth_headers(),
        )
        # /like toggles, so 200 and 409 (already-liked) both fine.
        if r.status_code not in (200, 201, 204, 409):
            raise RavenAPIError(r.status_code, r.text, f"/posts/{post_id}/like")

    def view(self, post_id: str) -> None:
        r = self._http.post(
            f"/api/posts/{post_id}/view",
            headers=self._auth_headers(),
        )
        # View endpoint is intentionally idempotent server-side, so
        # 200 / 204 / 409 are all acceptable.
        if r.status_code not in (200, 201, 204, 409):
            raise RavenAPIError(r.status_code, r.text, f"/posts/{post_id}/view")

    def comment(self, post_id: str, content: str) -> str:
        payload = {
            "post_id": post_id,
            "content": content,
            "comment_type": "text",
        }
        r = self._http.post(
            "/api/comments/create",
            headers=self._auth_headers(),
            json=payload,
        )
        if r.status_code != 200:
            raise RavenAPIError(r.status_code, r.text, "/comments/create")
        try:
            return r.json().get("id", "")
        except json.JSONDecodeError:
            return ""

    # ── Social graph (follow + friend-request) ────────────────────

    def follow(self, user_id: str) -> dict:
        """Follow a user. Server returns `{"status": "following"|"mutual"|"requested"}`
        depending on the followee's privacy + reciprocal state. `"requested"`
        means the followee is a private account and the row is pending."""
        r = self._http.post(
            f"/api/users/follow/{user_id}",
            headers=self._auth_headers(),
        )
        if r.status_code != 200:
            raise RavenAPIError(r.status_code, r.text, f"/users/follow/{user_id}")
        try:
            return r.json()
        except json.JSONDecodeError:
            return {}

    def send_friend_request(self, user_id: str) -> dict:
        """Send a friend request to `user_id`. The server may auto-accept
        if the recipient already has a pending request to us (mutual)."""
        r = self._http.post(
            "/api/users/friend-request",
            params={"recipient_id": user_id},
            headers=self._auth_headers(),
        )
        if r.status_code != 200:
            raise RavenAPIError(r.status_code, r.text, "/users/friend-request")
        try:
            return r.json()
        except json.JSONDecodeError:
            return {}
