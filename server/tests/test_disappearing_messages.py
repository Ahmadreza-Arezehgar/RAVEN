"""Tests for v1.8 per-conversation disappearing messages.

Exercises the real router code in `routers/messages.py` by calling the
endpoint functions directly (bypassing HTTP / auth so we don't need
the heavyweight app). Covers: the timer GET/PUT endpoints, validation,
the block gate, the system control message, send-time expiry stamping,
read-path filtering, and the lazy purge — plus backward-compat checks
that the pre-existing per-message "Smart Message Expiry" still works.
"""

import asyncio
import os
import sys
import uuid
from datetime import datetime, timedelta

import pytest

# conftest.py already sets sys.path + env, but be defensive in case
# this module is collected in isolation.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SERVER_DIR = os.path.dirname(_THIS_DIR)
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)
os.environ.setdefault("ENVIRONMENT", "development")
os.environ.setdefault("JWT_SECRET", "test-secret-key-for-pytest-only-do-not-use-in-prod")

from fastapi import BackgroundTasks, HTTPException  # noqa: E402

import routers.messages as M  # noqa: E402
from routers.messages import (  # noqa: E402
    DisappearingSettingResponse,
    SendMessageRequest,
    SetDisappearingRequest,
    _disappearing_seconds_for,
    _ordered_pair,
    _purge_expired_for_user,
    get_conversation,
    get_disappearing_timer,
    get_inbox,
    get_unread_messages,
    send_message,
    set_disappearing_timer,
)
from encryption import encrypt_text  # noqa: E402
from models import Block, FriendRequest, Message, MessageReaction, User  # noqa: E402


# ─────────────────────────────────────────────────────────────────────
# Fixtures / helpers
# ─────────────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def _silence_ws(monkeypatch):
    """The timer endpoint pushes over WebSocket; stub it so tests need
    no Redis / live socket."""
    async def _noop(*args, **kwargs):
        return None
    monkeypatch.setattr(M.ws_manager, "notify", _noop)


def _mk_user(db, username):
    u = User(
        id=str(uuid.uuid4()),
        username=username,
        first_name=username.capitalize(),
        last_name="Test",
        public_key="pk-" + username,
    )
    db.add(u)
    db.commit()
    return u


def _make_friends(db, u1, u2):
    db.add(FriendRequest(
        id=str(uuid.uuid4()),
        requester_id=u1.id,
        recipient_id=u2.id,
        status="accepted",
    ))
    db.commit()


def _send(db, sender, recipient, content="hello", **kw):
    req = SendMessageRequest(recipient_id=recipient.id, content=content, **kw)
    return asyncio.run(send_message(
        req=req, current_user=sender, db=db,
        background_tasks=BackgroundTasks(),
    ))


def _set_timer(db, actor, peer, seconds):
    # The endpoint requires an ESTABLISHED conversation (friends or an
    # accepted message-request) — ensure friendship for the test.
    exists = db.query(FriendRequest).filter(
        FriendRequest.status == "accepted",
        ((FriendRequest.requester_id == actor.id)
         & (FriendRequest.recipient_id == peer.id))
        | ((FriendRequest.requester_id == peer.id)
           & (FriendRequest.recipient_id == actor.id)),
    ).first()
    if exists is None:
        db.add(FriendRequest(
            id=str(uuid.uuid4()), requester_id=actor.id, recipient_id=peer.id,
            status="accepted", created_at=datetime.utcnow()))
        db.commit()
    return asyncio.run(set_disappearing_timer(
        peer_id=peer.id, req=SetDisappearingRequest(seconds=seconds),
        current_user=actor, db=db,
    ))


# ─────────────────────────────────────────────────────────────────────
# Timer setting / reading
# ─────────────────────────────────────────────────────────────────────

def test_ordered_pair_is_canonical():
    assert _ordered_pair("a", "z") == ("a", "z")
    assert _ordered_pair("z", "a") == ("a", "z")


def test_set_and_get_timer_is_symmetric(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")

    # default = off
    assert get_disappearing_timer(peer_id=bob.id, current_user=alice, db=db
                                  ).disappearing_seconds == 0

    resp = _set_timer(db, alice, bob, 3600)
    assert isinstance(resp, DisappearingSettingResponse)
    assert resp.disappearing_seconds == 3600
    assert resp.updated_by_id == alice.id

    # bob resolves the SAME shared row from the other direction
    assert get_disappearing_timer(peer_id=alice.id, current_user=bob, db=db
                                  ).disappearing_seconds == 3600

    # turn it back off
    assert _set_timer(db, bob, alice, 0).disappearing_seconds == 0
    assert _disappearing_seconds_for(db, alice.id, bob.id) == 0
    db.close()


def test_invalid_duration_rejected(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    with pytest.raises(HTTPException) as ei:
        _set_timer(db, alice, bob, 99999)  # not in the whitelist
    assert ei.value.status_code == 400
    db.close()


def test_self_and_missing_peer_rejected(test_db):
    db = test_db()
    alice = _mk_user(db, "alice")
    with pytest.raises(HTTPException) as ei_self:
        _set_timer(db, alice, alice, 3600)
    assert ei_self.value.status_code == 400
    with pytest.raises(HTTPException) as ei_ghost:
        asyncio.run(set_disappearing_timer(
            peer_id="ghost-id", req=SetDisappearingRequest(seconds=3600),
            current_user=alice, db=db))
    assert ei_ghost.value.status_code == 404
    db.close()


def test_block_prevents_timer_change(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    db.add(Block(id=str(uuid.uuid4()), blocker_id=bob.id, blocked_id=alice.id))
    db.commit()
    with pytest.raises(HTTPException) as ei:
        _set_timer(db, alice, bob, 3600)
    assert ei.value.status_code == 403
    db.close()


def test_timer_change_inserts_system_message_with_guard(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")

    _set_timer(db, alice, bob, 86400)
    sysq = db.query(Message).filter(Message.message_type == "system")
    assert sysq.count() == 1

    # setting the SAME value again => no new system message
    _set_timer(db, alice, bob, 86400)
    assert sysq.count() == 1

    # a real change => another system message
    _set_timer(db, alice, bob, 0)
    assert sysq.count() == 2
    db.close()


def test_set_timer_requires_established_conversation(test_db):
    """🔴 hacker-audit — set_disappearing_timer must NOT let a user
    inject a system message into a stranger's chat. Two unrelated
    users → rejected, and nothing is injected."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    with pytest.raises(HTTPException) as ei:
        asyncio.run(set_disappearing_timer(
            peer_id=bob.id, req=SetDisappearingRequest(seconds=3600),
            current_user=alice, db=db))
    assert ei.value.status_code == 403
    assert db.query(Message).filter(Message.message_type == "system").count() == 0
    db.close()


def test_set_timer_rejected_with_only_pending_message_request(test_db):
    """A PENDING (unanswered) message-request is NOT enough — the peer
    never accepted, so the timer's system message stays gated."""
    from models import MessageRequest
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    db.add(MessageRequest(id=str(uuid.uuid4()), sender_id=alice.id,
                          receiver_id=bob.id, status="pending", sent_count=1))
    db.commit()
    with pytest.raises(HTTPException) as ei:
        asyncio.run(set_disappearing_timer(
            peer_id=bob.id, req=SetDisappearingRequest(seconds=3600),
            current_user=alice, db=db))
    assert ei.value.status_code == 403
    db.close()


def test_set_timer_allowed_with_accepted_message_request(test_db):
    """An ACCEPTED message-request IS an established conversation —
    the timer can be set even without a FriendRequest row."""
    from models import MessageRequest
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    db.add(MessageRequest(id=str(uuid.uuid4()), sender_id=alice.id,
                          receiver_id=bob.id, status="accepted", sent_count=1))
    db.commit()
    resp = asyncio.run(set_disappearing_timer(
        peer_id=bob.id, req=SetDisappearingRequest(seconds=3600),
        current_user=alice, db=db))
    assert resp.disappearing_seconds == 3600
    db.close()


# ─────────────────────────────────────────────────────────────────────
# Send-time expiry stamping
# ─────────────────────────────────────────────────────────────────────

def test_send_stamps_expiry_from_conversation_timer(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    _make_friends(db, alice, bob)

    # no timer => no expiry
    assert _send(db, alice, bob, content="plain").expires_at is None

    _set_timer(db, alice, bob, 3600)
    before = datetime.utcnow()
    r = _send(db, alice, bob, content="timed")
    assert r.expires_at is not None
    assert 3500 < (r.expires_at - before).total_seconds() < 3700

    # shared timer applies in the reverse direction too
    assert _send(db, bob, alice, content="reverse").expires_at is not None
    db.close()


def test_per_message_expiry_still_works(test_db):
    """Backward compat: pre-existing Smart Message Expiry untouched."""
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    _make_friends(db, alice, bob)
    before = datetime.utcnow()
    r = _send(db, alice, bob, content="x", expiry_mode="deleteAfter24h")
    assert r.expires_at is not None
    assert 86000 < (r.expires_at - before).total_seconds() < 86800
    db.close()


def test_explicit_expiry_wins_over_conversation_timer(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    _make_friends(db, alice, bob)
    _set_timer(db, alice, bob, 2592000)  # conversation timer = 30 days
    before = datetime.utcnow()
    # explicit 24h per-message mode must win
    r = _send(db, alice, bob, content="x", expiry_mode="deleteAfter24h")
    assert 86000 < (r.expires_at - before).total_seconds() < 86800
    db.close()


# ─────────────────────────────────────────────────────────────────────
# Read-path filtering + lazy purge
# ─────────────────────────────────────────────────────────────────────

def _raw_message(db, sender, recipient, content, expires_at=None):
    """Insert a Message directly; return its id as a plain string —
    safe to assert on after the row may have been purged (an expired
    ORM instance would raise ObjectDeletedError on attribute access)."""
    mid = str(uuid.uuid4())
    db.add(Message(
        id=mid,
        sender_id=sender.id,
        recipient_id=recipient.id,
        content=encrypt_text(content),
        timestamp=datetime.utcnow(),
        expires_at=expires_at,
    ))
    db.commit()
    return mid


def test_expired_message_filtered_and_purged_on_conversation_read(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    live_id = _raw_message(db, alice, bob, "live")
    dead_id = _raw_message(db, alice, bob, "dead",
                           expires_at=datetime.utcnow() - timedelta(seconds=5))

    msgs = get_conversation(other_user_id=alice.id, current_user=bob, db=db)
    contents = {m.content for m in msgs}
    assert "live" in contents
    assert "dead" not in contents

    # purge actually hard-deleted the expired row
    assert db.query(Message).filter(Message.id == dead_id).first() is None
    assert db.query(Message).filter(Message.id == live_id).first() is not None
    db.close()


def test_expired_message_excluded_from_inbox(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    live_id = _raw_message(db, alice, bob, "live")
    dead_id = _raw_message(db, alice, bob, "dead",
                           expires_at=datetime.utcnow() - timedelta(seconds=1))
    inbox_ids = {m.id for m in get_inbox(current_user=bob, db=db)}
    assert live_id in inbox_ids
    assert dead_id not in inbox_ids
    db.close()


def test_expired_message_excluded_from_unread(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    live_id = _raw_message(db, alice, bob, "live")
    dead_id = _raw_message(db, alice, bob, "dead",
                           expires_at=datetime.utcnow() - timedelta(seconds=1))
    unread_ids = {m.id for m in get_unread_messages(current_user=bob, db=db)}
    assert live_id in unread_ids
    assert dead_id not in unread_ids
    db.close()


def test_purge_helper_deletes_expired_and_reaction_children(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    dead_id = _raw_message(db, alice, bob, "dead",
                           expires_at=datetime.utcnow() - timedelta(minutes=1))
    live_id = _raw_message(db, alice, bob, "live")
    # a reaction child hanging off the expired message
    db.add(MessageReaction(
        id=str(uuid.uuid4()), message_id=dead_id, is_group=False,
        user_id=bob.id, emoji="👍"))
    db.commit()

    deleted = _purge_expired_for_user(db, alice.id)
    assert deleted == 1
    assert db.query(Message).filter(Message.id == dead_id).first() is None
    assert db.query(Message).filter(Message.id == live_id).first() is not None
    # the orphan reaction child is gone too
    assert db.query(MessageReaction).filter(
        MessageReaction.message_id == dead_id).count() == 0
    db.close()


def test_future_expiry_is_not_purged(test_db):
    db = test_db()
    alice, bob = _mk_user(db, "alice"), _mk_user(db, "bob")
    future_id = _raw_message(db, alice, bob, "future",
                             expires_at=datetime.utcnow() + timedelta(hours=1))
    assert _purge_expired_for_user(db, alice.id) == 0
    msgs = get_conversation(other_user_id=alice.id, current_user=bob, db=db)
    assert "future" in {m.content for m in msgs}
    assert db.query(Message).filter(Message.id == future_id).first() is not None
    db.close()
