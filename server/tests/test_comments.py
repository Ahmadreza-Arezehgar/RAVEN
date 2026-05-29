"""Tests for the comment-tree builder's NULL-column hardening.

`get_post_comments` → `build_comment_tree` builds one `CommentResponse`
per row. `is_verified` / `is_premium` (User) and `is_ai_generated` /
`score` (Comment) are nullable columns whose Python-side `default=`
never backfilled legacy / bootstrap rows. A NULL there used to crash
Pydantic's non-Optional `bool` / `int` validation and 500 the WHOLE
`get_post_comments` response — so a post card showed "N comments" but
the comment sheet / detail view rendered empty. The builder must now
coerce None → a safe default so one dirty row can't blank a post.

These call `build_comment_tree` directly (same pattern as the other
server test modules).
"""

import os
import sys
import uuid
from datetime import datetime

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
_SERVER_DIR = os.path.dirname(_THIS_DIR)
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)
os.environ.setdefault("ENVIRONMENT", "development")
os.environ.setdefault("JWT_SECRET", "test-secret-key-for-pytest-only-do-not-use-in-prod")

from encryption import encrypt_text  # noqa: E402
from models import Comment, User  # noqa: E402
from routers.comments import CommentResponse, build_comment_tree  # noqa: E402

_POST_ID = "post-under-test"


def _mk_user(db, username, **kw):
    u = User(
        id=str(uuid.uuid4()),
        username=username,
        public_key="pk-" + username,
        is_verified=kw.get("is_verified", False),
        is_premium=kw.get("is_premium", False),
    )
    db.add(u)
    db.commit()
    return u


def _mk_comment(db, author, **kw):
    c = Comment(
        id=str(uuid.uuid4()),
        post_id=_POST_ID,
        author_id=author.id,
        content=encrypt_text(kw.get("content", "a comment")),
        timestamp=datetime.utcnow(),
        score=kw.get("score", 0),
        is_ai_generated=kw.get("is_ai_generated", False),
    )
    db.add(c)
    db.commit()
    return c


def test_build_tree_handles_null_author_badges(test_db):
    """A comment whose author has NULL is_verified / is_premium must
    still render — coerced to False — not 500 the whole list."""
    db = test_db()
    reader = _mk_user(db, "reader")
    author = _mk_user(db, "ghostauthor")
    # Simulate a legacy / bootstrap row: badge columns never backfilled.
    author.is_verified = None
    author.is_premium = None
    db.commit()
    _mk_comment(db, author)
    rows = db.query(Comment).filter(Comment.post_id == _POST_ID).all()
    tree = build_comment_tree(rows, reader.id, db)
    assert len(tree) == 1
    assert isinstance(tree[0], CommentResponse)
    assert tree[0].is_verified is False
    assert tree[0].is_premium is False
    db.close()


def test_build_tree_handles_null_comment_columns(test_db):
    """A comment row with NULL is_ai_generated / score must not break
    CommentResponse validation."""
    db = test_db()
    reader = _mk_user(db, "reader")
    author = _mk_user(db, "author")
    c = _mk_comment(db, author)
    c.is_ai_generated = None
    c.score = None
    db.commit()
    rows = db.query(Comment).filter(Comment.post_id == _POST_ID).all()
    tree = build_comment_tree(rows, reader.id, db)
    assert len(tree) == 1
    assert tree[0].is_ai_generated is False
    assert tree[0].score == 0
    db.close()


def test_build_tree_handles_null_author_username(test_db):
    """A comment by a half-onboarded author (username NULL) must still
    render, with a safe placeholder name."""
    db = test_db()
    reader = _mk_user(db, "reader")
    author = _mk_user(db, "tmpname")
    author.username = None
    db.commit()
    _mk_comment(db, author)
    rows = db.query(Comment).filter(Comment.post_id == _POST_ID).all()
    tree = build_comment_tree(rows, reader.id, db)
    assert len(tree) == 1
    assert tree[0].author_name == "Unknown"
    db.close()


def test_build_tree_one_bad_row_keeps_the_rest(test_db):
    """The headline regression: a single dirty row used to take down
    the ENTIRE post's comment list. Every comment must survive."""
    db = test_db()
    reader = _mk_user(db, "reader")
    clean = _mk_user(db, "clean")
    dirty = _mk_user(db, "dirty")
    dirty.is_verified = None
    db.commit()
    _mk_comment(db, clean, content="clean one")
    _mk_comment(db, dirty, content="dirty one")
    rows = db.query(Comment).filter(Comment.post_id == _POST_ID).all()
    tree = build_comment_tree(rows, reader.id, db)
    assert len(tree) == 2  # both surface, not zero
    db.close()


def test_build_tree_healthy_comment_unaffected(test_db):
    """A normal, fully-populated comment still builds correctly — the
    hardening must not change the happy path."""
    db = test_db()
    reader = _mk_user(db, "reader")
    author = _mk_user(db, "author", is_verified=True)
    _mk_comment(db, author, content="hello", score=5)
    rows = db.query(Comment).filter(Comment.post_id == _POST_ID).all()
    tree = build_comment_tree(rows, reader.id, db)
    assert len(tree) == 1
    assert tree[0].is_verified is True
    assert tree[0].score == 5
    assert tree[0].content == "hello"
    assert tree[0].author_name == "author"
    db.close()
