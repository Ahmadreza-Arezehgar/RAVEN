"""Tests for the friend-request flow + the accept-notification fix.

Verifies the three things the flow must do:
  1. a friend request can be sent (creates a pending row),
  2. it lists for the recipient (GET /friend-requests),
  3. when the recipient accepts, the original requester is notified —
     an in-app Notification row of type "friend_accepted".

(3) is the fix: `accept_friend_request` / `accept_follow_request_alias`
used to update the DB and notify NOBODY.
"""

import asyncio
import os
import sys
import uuid
from datetime import datetime

import pytest

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SERVER_DIR = os.path.dirname(_THIS_DIR)
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)
os.environ.setdefault("ENVIRONMENT", "development")
os.environ.setdefault("JWT_SECRET", "test-secret-key-for-pytest-only-do-not-use-in-prod")

from fastapi import HTTPException  # noqa: E402

from models import FriendRequest, Notification, User, UserFollow  # noqa: E402
from routers.users import (  # noqa: E402
    accept_follow_request_alias,
    accept_friend_request,
    accept_pending_follow_request,
    get_follow_requests_alias,
    get_friend_requests,
    reject_follow_request_alias,
    send_friend_request,
)


def _mk_user(db, username):
    u = User(id=str(uuid.uuid4()), username=username, public_key="pk-" + username)
    db.add(u)
    db.commit()
    return u


def _pending(db, requester, recipient):
    """Insert a pending friend request; return its id."""
    fr = FriendRequest(
        id=str(uuid.uuid4()),
        requester_id=requester.id,
        recipient_id=recipient.id,
        status="pending",
        created_at=datetime.utcnow(),
    )
    db.add(fr)
    db.commit()
    return fr.id


def test_send_creates_pending_request(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    resp = asyncio.run(send_friend_request(
        recipient_id=bob.id, request=None, current_user=alice, db=db))
    assert "request_id" in resp
    rows = db.query(FriendRequest).filter(
        FriendRequest.requester_id == alice.id,
        FriendRequest.recipient_id == bob.id,
    ).all()
    assert len(rows) == 1 and rows[0].status == "pending"
    db.close()


def test_send_friend_request_creates_notification(test_db):
    """🔵 (2026-05-22) — the recipient must get an in-app
    `friend_request` Notification. Previously `send_friend_request`
    only fired an APNs push, so the request was invisible in-app —
    and entirely absent on the Simulator (no real push token)."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    asyncio.run(send_friend_request(
        recipient_id=bob.id, request=None, current_user=alice, db=db))
    notifs = db.query(Notification).filter(
        Notification.user_id == bob.id,
        Notification.type == "friend_request",
    ).all()
    assert len(notifs) == 1
    assert "alice" in (notifs[0].data or "")
    assert notifs[0].is_read is False
    db.close()


def test_request_appears_for_recipient(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    _pending(db, alice, bob)
    bob_reqs = get_friend_requests(current_user=bob, db=db)
    assert len(bob_reqs) == 1
    assert bob_reqs[0].requester_id == alice.id
    assert bob_reqs[0].requester_username == "alice"
    # the requester does NOT see it as an incoming request
    assert get_friend_requests(current_user=alice, db=db) == []
    db.close()


def test_accept_notifies_requester(test_db):
    """🔴 The fix — accepting a request notifies the original sender."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    req_id = _pending(db, alice, bob)

    result = asyncio.run(accept_friend_request(
        request_id=req_id, current_user=bob, db=db))
    assert result["friend_id"] == alice.id

    assert db.query(FriendRequest).filter(
        FriendRequest.id == req_id).first().status == "accepted"

    # the requester (alice) now has a friend_accepted notification
    notifs = db.query(Notification).filter(
        Notification.user_id == alice.id,
        Notification.type == "friend_accepted",
    ).all()
    assert len(notifs) == 1
    assert "bob" in (notifs[0].data or "")
    db.close()


def test_accept_via_follow_alias_notifies(test_db):
    """The /follow-request/{id}/accept alias must notify too."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    req_id = _pending(db, alice, bob)
    asyncio.run(accept_follow_request_alias(
        request_id=req_id, current_user=bob, db=db))
    assert db.query(FriendRequest).filter(
        FriendRequest.id == req_id).first().status == "accepted"
    assert db.query(Notification).filter(
        Notification.user_id == alice.id,
        Notification.type == "friend_accepted",
    ).count() == 1
    db.close()


def test_accept_only_by_recipient(test_db):
    """A third party cannot accept someone else's friend request —
    and no notification is produced when the accept is rejected."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    charlie = _mk_user(db, "charlie")
    req_id = _pending(db, alice, bob)
    with pytest.raises(HTTPException) as ei:
        asyncio.run(accept_friend_request(
            request_id=req_id, current_user=charlie, db=db))
    assert ei.value.status_code == 404
    assert db.query(FriendRequest).filter(
        FriendRequest.id == req_id).first().status == "pending"
    assert db.query(Notification).count() == 0
    db.close()


# ───────────────────────────────────────────────────────────────────
# 🔵 (2026-05-22) — PRIVATE-ACCOUNT FOLLOW REQUESTS.
#
# A request to follow a PRIVATE account is a `UserFollow` row with
# status="pending" — a different table from `FriendRequest`. The iOS
# "Follow Requests" screen reads ONE url (/follow-requests), so the
# server must surface both kinds there, and the shared accept/reject
# buttons must resolve an id back to whichever table owns it.
# ───────────────────────────────────────────────────────────────────


def _pending_follow(db, follower, followee):
    """Insert a pending UserFollow (a request to follow a private
    account); return its id."""
    uf = UserFollow(
        id=str(uuid.uuid4()),
        follower_id=follower.id,
        followee_id=followee.id,
        status="pending",
        created_at=datetime.utcnow(),
    )
    db.add(uf)
    db.commit()
    return uf.id


def test_pending_follow_lists_for_private_account(test_db):
    """🔵 A pending follow request must surface in the same
    /follow-requests list the iOS screen reads — before the fix it
    only ever returned FriendRequest rows."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    follow_id = _pending_follow(db, alice, bob)
    reqs = get_follow_requests_alias(current_user=bob, db=db)
    assert len(reqs) == 1
    assert reqs[0].id == follow_id
    assert reqs[0].requester_id == alice.id
    assert reqs[0].requester_username == "alice"
    assert reqs[0].status == "pending"
    # the follower does NOT see their own outgoing request
    assert get_follow_requests_alias(current_user=alice, db=db) == []
    db.close()


def test_follow_and_friend_requests_merge_in_one_list(test_db):
    """The list must carry BOTH a FriendRequest and a pending
    UserFollow at once — that merge is the headline fix."""
    db = test_db()
    alice = _mk_user(db, "alice")
    bob = _mk_user(db, "bob")
    carol = _mk_user(db, "carol")
    _pending(db, alice, bob)         # a friend request → bob
    _pending_follow(db, carol, bob)  # a follow request → bob
    reqs = get_follow_requests_alias(current_user=bob, db=db)
    assert {r.requester_username for r in reqs} == {"alice", "carol"}
    db.close()


def test_accept_pending_follow_notifies_follower(test_db):
    """🔵 Accepting a pending follow flips the row to accepted AND
    notifies the follower (`follow_accepted`) — it used to be silent."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    follow_id = _pending_follow(db, alice, bob)
    result = asyncio.run(accept_pending_follow_request(
        follow_id=follow_id, current_user=bob, db=db))
    assert result["status"] == "accepted"
    assert db.query(UserFollow).filter(
        UserFollow.id == follow_id).first().status == "accepted"
    notifs = db.query(Notification).filter(
        Notification.user_id == alice.id,
        Notification.type == "follow_accepted",
    ).all()
    assert len(notifs) == 1
    assert "bob" in (notifs[0].data or "")
    db.close()


def test_accept_follow_alias_resolves_userfollow_id(test_db):
    """The shared /follow-request/{id}/accept button must also accept
    a pending UserFollow id, not just a FriendRequest id."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    follow_id = _pending_follow(db, alice, bob)
    result = asyncio.run(accept_follow_request_alias(
        request_id=follow_id, current_user=bob, db=db))
    assert result["follower_id"] == alice.id
    assert db.query(UserFollow).filter(
        UserFollow.id == follow_id).first().status == "accepted"
    assert db.query(Notification).filter(
        Notification.user_id == alice.id,
        Notification.type == "follow_accepted",
    ).count() == 1
    db.close()


def test_reject_follow_alias_deletes_pending_row(test_db):
    """Rejecting via the shared alias removes the pending UserFollow
    and stays silent — no notification reaches the follower."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    follow_id = _pending_follow(db, alice, bob)
    resp = reject_follow_request_alias(
        request_id=follow_id, current_user=bob, db=db)
    assert "message" in resp
    assert db.query(UserFollow).filter(
        UserFollow.id == follow_id).first() is None
    assert db.query(Notification).count() == 0
    db.close()


def test_profile_reports_mutual_follow_status(test_db):
    """🔵 (2026-05-22) — the profile endpoint must report followStatus
    from the user_follows table, not just the friend system. A
    mutually-followed account must read 'mutual' so the button shows
    'Friends' on first render — not a stale 'Follow' that only
    corrects itself after a redundant tap."""
    from routers.users import get_user_full_profile
    db = test_db()
    me = _mk_user(db, "me")
    other = _mk_user(db, "other")
    db.add(UserFollow(id=str(uuid.uuid4()), follower_id=me.id,
                      followee_id=other.id, status="accepted"))
    db.add(UserFollow(id=str(uuid.uuid4()), follower_id=other.id,
                      followee_id=me.id, status="accepted"))
    db.commit()
    prof = get_user_full_profile(user_id=other.id, current_user=me, db=db)
    assert prof["followStatus"] == "mutual"
    assert prof["isFollowingYou"] is True
    db.close()


def test_profile_reports_pending_follow_as_requested(test_db):
    """A pending follow (a request to a private account) must read
    'requested' so the button shows 'Requested', not 'Follow'."""
    from routers.users import get_user_full_profile
    db = test_db()
    me = _mk_user(db, "me")
    other = _mk_user(db, "other")
    db.add(UserFollow(id=str(uuid.uuid4()), follower_id=me.id,
                      followee_id=other.id, status="pending"))
    db.commit()
    prof = get_user_full_profile(user_id=other.id, current_user=me, db=db)
    assert prof["followStatus"] == "requested"
    assert prof["isFollowingYou"] is False
    db.close()


def test_accept_follow_only_by_followee(test_db):
    """A third party cannot approve a follow request aimed at someone
    else — the pending row is untouched and nobody is notified."""
    db = test_db()
    alice = _mk_user(db, "alice")
    bob = _mk_user(db, "bob")
    mallory = _mk_user(db, "mallory")
    follow_id = _pending_follow(db, alice, bob)
    with pytest.raises(HTTPException) as ei:
        asyncio.run(accept_follow_request_alias(
            request_id=follow_id, current_user=mallory, db=db))
    assert ei.value.status_code == 404
    assert db.query(UserFollow).filter(
        UserFollow.id == follow_id).first().status == "pending"
    assert db.query(Notification).count() == 0
    db.close()
