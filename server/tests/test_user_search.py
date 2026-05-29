"""Tests for the user-search bug fix.

`GET /api/users/search` used to return a minimal `UserProfile`
(`avatar_path`, no display name, no badges) — but the iOS `SearchUser`
model + the rest of Discover expect `avatar_url` + `display_name` +
badges, so every search result rendered with no photo and no name.
The endpoint now returns `UserSearchResult` (the correct shape).

These call the router function directly (bypassing HTTP/auth) — same
pattern as the other server test modules.
"""

import os
import sys
import uuid

import pytest

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SERVER_DIR = os.path.dirname(_THIS_DIR)
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)
os.environ.setdefault("ENVIRONMENT", "development")
os.environ.setdefault("JWT_SECRET", "test-secret-key-for-pytest-only-do-not-use-in-prod")

from encryption import encrypt_text  # noqa: E402
from models import User  # noqa: E402
from routers.users import UserSearchResult, search_users  # noqa: E402


def _mk_user(db, username, **kw):
    """Create a User. Safety columns are set explicitly so a fresh
    test user is actually discoverable (defaults vary)."""
    u = User(
        id=str(uuid.uuid4()),
        username=username,
        public_key="pk-" + username,
        is_private=kw.get("is_private", False),
        is_banned=kw.get("is_banned", False),
        is_restricted=kw.get("is_restricted", False),
        status=kw.get("status", "active"),
        who_can_see_profile=kw.get("who_can_see_profile", "public"),
        avatar_path=kw.get("avatar_path"),
        is_verified=kw.get("is_verified", False),
        is_premium=kw.get("is_premium", False),
        first_name=kw.get("first_name"),
        last_name=kw.get("last_name"),
    )
    db.add(u)
    db.commit()
    return u


def test_search_returns_avatar_url(test_db):
    """The headline bug: results must carry `avatar_url` (the iOS
    SearchUser key), populated from the DB's avatar_path column."""
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "bobby", avatar_path="/media/bob.jpg")
    results = search_users(q="bob", current_user=alice, db=db)
    assert len(results) == 1
    assert isinstance(results[0], UserSearchResult)
    assert results[0].username == "bobby"
    assert results[0].avatar_url == "/media/bob.jpg"
    db.close()


def test_search_returns_badges(test_db):
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "bobverified", is_verified=True)
    _mk_user(db, "bobpremium", is_premium=True)
    by_name = {r.username: r for r in search_users(q="bob", current_user=alice, db=db)}
    assert by_name["bobverified"].is_verified is True
    assert by_name["bobverified"].is_premium is False
    assert by_name["bobpremium"].is_premium is True
    db.close()


def test_search_display_name_shown_for_private_accounts(test_db):
    """🔵 (2026-05-22) — a private (friends-only) account's display
    name IS shown in search results. Being private gates the PROFILE
    (posts / bio / details), not basic discoverability — you must be
    able to recognise who you're about to send a follow request to."""
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "publicbob", who_can_see_profile="public",
             first_name=encrypt_text("Bob"), last_name=encrypt_text("Builder"))
    _mk_user(db, "guardedbob", who_can_see_profile="friends",
             first_name=encrypt_text("Bob"), last_name=encrypt_text("Hidden"))
    by_name = {r.username: r for r in search_users(q="bob", current_user=alice, db=db)}
    assert by_name["publicbob"].display_name == "Bob Builder"
    # private profile: real name now surfaces too (so it's recognisable)
    assert by_name["guardedbob"].display_name == "Bob Hidden"
    db.close()


def test_search_excludes_self(test_db):
    db = test_db()
    alice = _mk_user(db, "alice")
    assert all(r.id != alice.id for r in search_users(q="ali", current_user=alice, db=db))
    db.close()


def test_search_finds_private_by_username_excludes_banned(test_db):
    """🔵 (2026-05-22) — a private account IS findable by username so a
    follow request can be sent (it stays pending until the owner
    accepts); a banned account stays hidden. A private account's real
    name / bio remain unsearchable — see
    test_search_name_skips_friends_only_profile."""
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "bobprivate", is_private=True)
    _mk_user(db, "bobbanned", is_banned=True)
    _mk_user(db, "bobok")
    names = {r.username for r in search_users(q="bob", current_user=alice, db=db)}
    assert names == {"bobok", "bobprivate"}
    db.close()


def test_search_minimum_query_length(test_db):
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "bob")
    assert search_users(q="b", current_user=alice, db=db) == []
    assert search_users(q="  ", current_user=alice, db=db) == []
    db.close()


def test_search_honors_limit(test_db):
    db = test_db()
    alice = _mk_user(db, "alice")
    for i in range(25):
        _mk_user(db, f"searchablebob{i}")
    assert len(search_users(q="searchablebob", current_user=alice, db=db, limit=5)) == 5
    assert len(search_users(q="searchablebob", current_user=alice, db=db)) == 20  # default
    # limit is capped — never returns more than 50
    assert len(search_users(q="searchablebob", current_user=alice, db=db, limit=999)) <= 50
    db.close()


def test_search_escapes_like_wildcards(test_db):
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "bob")
    # "%" must be literal — "b%" matches no real username, so "bob"
    # must NOT come back (it would if % were a live SQL wildcard).
    assert search_users(q="b%", current_user=alice, db=db) == []
    # the plain query still works
    assert {r.username for r in search_users(q="bob", current_user=alice, db=db)} == {"bob"}
    db.close()


def test_search_matches_real_name(test_db):
    """The headline bug: a user must be findable by the real name
    they go by, even when their @username shares no characters with
    it. first_name / last_name are encrypted at rest, so this
    exercises the decrypt-and-match path that SQL LIKE can't do."""
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "raven_founder", who_can_see_profile="public",
             first_name=encrypt_text("Ahmadreza"), last_name=encrypt_text("Arezehgar"))
    # found by first name
    assert [r.username for r in search_users(q="ahmadreza", current_user=alice, db=db)] == ["raven_founder"]
    # found by last name
    assert [r.username for r in search_users(q="arezehgar", current_user=alice, db=db)] == ["raven_founder"]
    # the result still carries the real name for display
    assert search_users(q="ahmadreza", current_user=alice, db=db)[0].display_name == "Ahmadreza Arezehgar"
    db.close()


def test_search_name_match_for_everyone_visibility(test_db):
    """`who_can_see_profile='everyone'` is a public-equivalent value
    (seed data / older rows use it). Name search and display_name
    must both treat it exactly like 'public'."""
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "raven_ceo", who_can_see_profile="everyone",
             first_name=encrypt_text("Ahmadreza"), last_name=encrypt_text("Arezehgar"))
    results = search_users(q="ahmadreza", current_user=alice, db=db)
    assert {r.username for r in results} == {"raven_ceo"}
    assert results[0].display_name == "Ahmadreza Arezehgar"
    db.close()


def test_search_finds_private_account_by_real_name(test_db):
    """🔵 (2026-05-22) — a private (friends-only) account IS findable
    by real name, exactly like by @username. Being private gates the
    profile content, not discoverability: people must be able to find
    a private account by name to send it a follow request. (Only
    freeform bio / hobbies text stays gated to public profiles.)"""
    db = test_db()
    alice = _mk_user(db, "alice")
    _mk_user(db, "guarded_handle", who_can_see_profile="friends",
             first_name=encrypt_text("Ahmadreza"), last_name=encrypt_text("Arezehgar"))
    # findable by real name
    assert {r.username for r in search_users(q="ahmadreza", current_user=alice, db=db)} == {"guarded_handle"}
    # and still by @username
    assert {r.username for r in search_users(q="guarded", current_user=alice, db=db)} == {"guarded_handle"}
    db.close()


def test_search_skips_users_without_username(test_db):
    """A half-onboarded account (real name set, @username still NULL)
    must not reach UserSearchResult — its `username` is non-optional,
    so a None there is a 500. The name-match path could otherwise
    surface such an account."""
    db = test_db()
    alice = _mk_user(db, "alice")
    nameless = User(
        id=str(uuid.uuid4()),
        username=None,
        public_key="pk-nameless",
        is_private=False,
        is_banned=False,
        is_restricted=False,
        status="active",
        who_can_see_profile="public",
        first_name=encrypt_text("Ahmadreza"),
        last_name=encrypt_text("Arezehgar"),
    )
    db.add(nameless)
    db.commit()
    # does not raise, and the nameless account never surfaces
    assert search_users(q="ahmadreza", current_user=alice, db=db) == []
    db.close()
