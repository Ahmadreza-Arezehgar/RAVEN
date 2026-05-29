"""
simulation/main.py
==================

One tick of the simulation orchestrator. Designed to run on a ~30-minute
launchd timer, single-shot per tick — there is no internal scheduling
loop here. The daemon wrapper (`run-loop.sh`) handles cadence and
restart.

Per-tick logic:
  1. Load all 20 personas from the static config; ensure a state row
     exists for each.
  2. Bootstrap missing accounts: pick up to N=2 unregistered personas
     and `/api/auth/register` them. The server's per-IP register
     rate-limit (5/hour) means we bootstrap gradually over a few hours
     rather than blasting all 20 at once.
  3. For each registered persona whose `last_action_at + 15h ≤ now`,
     mark them "due."
  4. From the "due" set, sample up to ACTIVE_PER_TICK personas so we
     never wake everyone at the same wall-clock instant — keeps the
     network feeling staggered.
  5. For each acting persona:
        a. Login (gets a fresh JWT)
        b. Pull a small feed slice; record /view on each unseen post
           (this is the "view counted" behaviour the user asked for)
        c. Pick ONE primary action via the persona's own weights:
           {post, reply, like, view_only}
        d. Execute it through Gemini + the RAVEN API
        e. Stamp last_action_at

Failure isolation: every persona's tick is wrapped in try/except so one
broken persona never breaks the others.

Run:
    python -m simulation               # do one tick, exit
    python -m simulation --dry-run     # rehearse without /create POSTs
    python -m simulation --status      # print persona table + recent log
"""

from __future__ import annotations

import argparse
import logging
import os
import random
import sys
import time
import traceback
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Tuple

from .ai import Gemini, GeminiError
from .api import FeedPost, RavenAPIError, RavenClient
from .personas import PERSONAS, Persona
from .state import PersonaRow, StateStore


# ── Tunables ────────────────────────────────────────────────────────

# 🆕 2026-05-23 — cadences tightened to 50 / 20 minutes (was 15h / 3h).
# The user explicitly asked for ~50 min between post-actions per
# persona so the feed feels much more alive. Social actions
# (reply / like) cycle proportionally faster.
#
# Cost / load check:
#   • 20 personas × 24h × 60min / 50min  ≈  576 Gemini calls/day.
#   • Gemini 2.5 Flash at ~$0.0005/call → ~$0.29/day = ~$9/month.
#     Well inside free-tier RPM (15) and TPM limits.
#   • Server-side: ~576 posts/day + ~1700 replies+likes/day across
#     20 personas. Same order of magnitude as a small real network.
POST_INTERVAL_SECONDS = 50 * 60           # 50 minutes between posts per persona
SOCIAL_INTERVAL_SECONDS = 20 * 60         # 20 minutes between replies/likes per persona

# Legacy hour-based aliases — kept for any external imports.
POST_INTERVAL_HOURS = POST_INTERVAL_SECONDS / 3600
SOCIAL_INTERVAL_HOURS = SOCIAL_INTERVAL_SECONDS / 3600
ACTIVE_PER_TICK = 10              # max personas allowed any kind of action
                                  # per tick (posts + socials combined).
                                  # 🆕 2026-05-23 — bumped from 7 → 10 to
                                  # meet the new 50-min post / 20-min
                                  # social demand. With a 20-min daemon
                                  # tick interval this gives 30 actions/h
                                  # throughput which covers ~24/h of post
                                  # demand and leaves headroom for social.
REGISTER_PER_TICK = 6             # try this many login-or-registers each tick
                                  # (login-first means we don't hit the 5/hr
                                  # register rate-limit unless a persona is
                                  # truly new and server bootstrap didn't run)

# Backwards-compat alias kept for any old call sites; not used by the new
# cadence logic below.
ACTION_INTERVAL_HOURS = POST_INTERVAL_HOURS
FEED_FETCH_LIMIT = 30             # how many posts to scan on a tick

# 🆕 2026-05-23 — social-graph bootstrap. Each persona, once it's
# registered, follows a small handful of other personas and sends one
# friend request. This populates `UserFollow` + `FriendRequest` so the
# network has a real social graph (and the `/feed/friends` endpoint
# eventually has content). Done lazily — at most this many per tick so
# we don't blast the server at once.
GRAPH_BOOTSTRAP_PER_TICK = 2      # personas seeded per tick
GRAPH_FOLLOW_COUNT = 4            # follows per persona on seed
GRAPH_FRIEND_REQ_COUNT = 1        # friend-requests per persona on seed
MAX_VIEWS_ACTIVE = 8              # views during an active persona's tick
MAX_VIEWS_PASSIVE = 5             # views during a passive (non-acting) tick
PASSIVE_VIEW_PROB = 0.85          # chance each registered persona does a passive view this tick
DRY_RUN = False                   # set via CLI


logger = logging.getLogger("simulation")


# ─────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────

def _now() -> int:
    return int(time.time())


def _due_to_post(row: PersonaRow) -> bool:
    """True iff this persona may make a NEW top-level post this tick.
    Governed by POST_INTERVAL_HOURS (default 15h)."""
    if row.user_id is None:
        return False
    if row.last_post_at is None:
        return True
    return _now() - row.last_post_at >= POST_INTERVAL_SECONDS


def _due_for_social(row: PersonaRow) -> bool:
    """True iff this persona may reply / like this tick.
    Governed by SOCIAL_INTERVAL_HOURS (default 3h) — replies and
    likes are lightweight social interactions that happen many times
    a day even for users who only publish their own post once a day.
    Real-world cadence: most active users like 5-15 things per day
    and reply to 2-5; at 3h cadence we get ~8 social actions/day per
    persona, which matches that profile."""
    if row.user_id is None:
        return False
    if row.last_social_at is None:
        return True
    return _now() - row.last_social_at >= SOCIAL_INTERVAL_SECONDS


def _due(row: PersonaRow) -> bool:
    """Persona has ANY action available this tick (post OR social)."""
    return _due_to_post(row) or _due_for_social(row)


def _social_weighted_pick(persona: Persona) -> str:
    """When a persona is only due for a SOCIAL action (not a post),
    pick reply vs like vs pure-view using the persona's reply/like
    weights — post is intentionally excluded here, because the post
    cadence is on its own 15h timer.
    """
    options = [
        ("reply", persona.reply_weight),
        ("like", persona.like_weight),
        ("view", persona.view_only_weight),
    ]
    total = sum(w for _, w in options)
    if total <= 0:
        return "reply"
    r = random.random() * total
    cum = 0.0
    for name, w in options:
        cum += w
        if r <= cum:
            return name
    return "reply"


def _persona_by_name(username: str) -> Persona:
    for p in PERSONAS:
        if p.username == username:
            return p
    raise KeyError(username)


# ─────────────────────────────────────────────────────────────────────
# The per-persona tick
# ─────────────────────────────────────────────────────────────────────

def _bootstrap_persona(client: RavenClient, persona: Persona,
                       row: PersonaRow, store: StateStore) -> bool:
    """Make sure the persona has a server-side account, then stamp
    `user_id` in our local state. Returns True on success.

    Strategy (login-first): the server runs a startup bootstrap that
    creates all 20 simulation accounts with their .env-supplied
    passwords. So try /login FIRST — if it works, the server already
    knows this persona and we don't waste a register-rate-limit slot.
    Fall back to /register only if login returns 401 (account truly
    missing), in which case we ARE creating a new account.
    """
    if DRY_RUN:
        logger.info(f"[dry] would login-or-register {persona.username}")
        return False

    # ── First try: login. Server bootstrap already created the row. ─
    try:
        user_id = client.login(
            username=persona.username, password=row.password,
        )
        store.mark_registered(persona.username, user_id)
        store.log(persona.username, "login-bootstrap", target=user_id)
        logger.info(f"♻️ logged in (server-bootstrapped) {persona.username} → {user_id[:8]}")
        return True
    except RavenAPIError as login_err:
        # 401 → account doesn't exist OR wrong password. Try register.
        # Any other status (500, 503, 429) is transient → try next tick.
        if login_err.status != 401:
            logger.info(f"⏳ login transient for {persona.username}: {login_err.status}")
            return False
        # fall through to /register

    # ── Fall back: register a brand-new account. ────────────────────
    try:
        user_id = client.register(
            username=persona.username,
            password=row.password,
            first_name=persona.display_first,
            last_name=persona.display_last,
            birth_year=persona.birth_year,
            email=persona.email,
        )
        store.mark_registered(persona.username, user_id)
        store.log(persona.username, "registered", target=user_id)
        logger.info(f"✅ registered {persona.username} → {user_id[:8]}")
        return True
    except RavenAPIError as e:
        if e.status == 400 and (
            "already" in (e.body or "").lower()
            or "exists" in (e.body or "").lower()
        ):
            # Account exists but our login above failed → password
            # mismatch between local state.db and server. Indicate the
            # operator should reset (the server bootstrap will heal
            # it on next deploy automatically).
            logger.warning(
                f"⚠️ {persona.username}: account exists but login failed "
                f"with our local password. Server bootstrap will overwrite "
                f"on next deploy."
            )
            store.log(persona.username, "register-conflict", detail=e.body[:300])
            return False
        if e.status == 429:
            logger.info(f"⏳ register rate-limited for {persona.username}")
            return False
        logger.warning(f"❌ register {persona.username} failed: {e}")
        store.log(persona.username, "register-failed", detail=str(e))
        return False


def _persona_tick(persona: Persona, row: PersonaRow,
                  gemini: Gemini, store: StateStore,
                  base_url: str) -> None:
    """One persona, one action. Each persona uses its own RavenClient
    so a bad token / 401 on one doesn't leak into another.

    Special case: a persona's FIRST ever action is a guaranteed post,
    not a weighted random pick. This gives every new face an
    introduction to the network instead of having half of them silently
    register + like-something + disappear for 15 hours.
    """
    first_ever = (row.last_action_at is None and row.total_posts == 0
                  and row.total_replies == 0 and row.total_likes == 0)

    # Action selection respects the SEPARATE post and social cadences.
    # Roles:
    #   • debut → guaranteed POST so every new face introduces itself
    #   • due to post AND due for social → ~30% chance of post,
    #       otherwise social (keeps the timeline mostly social)
    #   • due to post only → post
    #   • due for social only → social weighted pick
    if first_ever:
        action = "post"
        logger.info(f"🎯 {persona.username} → post (debut)")
    elif _due_to_post(row) and _due_for_social(row):
        if random.random() < 0.30:
            action = "post"
            logger.info(f"🎯 {persona.username} → post (50min window)")
        else:
            action = _social_weighted_pick(persona)
            logger.info(f"🎯 {persona.username} → {action} (social, post-due-deferred)")
    elif _due_to_post(row):
        action = "post"
        logger.info(f"🎯 {persona.username} → post (50min window)")
    else:
        action = _social_weighted_pick(persona)
        logger.info(f"🎯 {persona.username} → {action} (social, 20min window)")

    with RavenClient(base_url) as client:
        # Login first (fresh JWT each tick — they're short-lived).
        try:
            client.login(username=persona.username, password=row.password)
        except RavenAPIError as e:
            store.log(persona.username, "login-failed", detail=str(e))
            logger.warning(f"❌ login {persona.username}: {e}")
            return

        # ── Pre-action: register some views on the feed ─────────
        feed: List[FeedPost] = []
        try:
            feed = client.fetch_feed(limit=FEED_FETCH_LIMIT)
        except RavenAPIError as e:
            logger.info(f"  · fetch_feed failed for {persona.username}: {e}")

        # Active persona views: pick from a wider window (not just top
        # of feed) so older posts also accumulate views, mixed random
        # + recency-weighted so the newest stuff still gets priority.
        views_recorded = _do_view_pass(
            client, persona, store, feed,
            max_views=MAX_VIEWS_ACTIVE,
            stamp_last_action=False,   # primary action below will stamp it
        )
        if views_recorded:
            store.log(persona.username, "views", detail=f"{views_recorded} posts")

        # ── Primary action ──────────────────────────────────────
        try:
            if action == "post":
                _do_post(client, persona, store)
            elif action == "reply":
                _do_reply(client, persona, store, feed, gemini)
            elif action == "like":
                _do_like(client, persona, store, feed)
            elif action == "view":
                # Already happened in the pre-action loop above —
                # just stamp last_action_at so the 15h window starts.
                store.mark_action(persona.username, "view")
                store.log(persona.username, "view-only")
            else:
                logger.warning(f"unknown action {action!r}")
        finally:
            # _do_* funcs that use Gemini close out; if Gemini ever
            # rate-limits or fails, we still want last_action_at to
            # advance so we don't hammer the same persona next tick.
            pass


def _do_view_pass(client: RavenClient, persona: Persona, store: StateStore,
                  feed: List[FeedPost], *, max_views: int,
                  stamp_last_action: bool) -> int:
    """Shared view-recording loop used by both the active tick and the
    passive-view pass. Picks `max_views` unseen posts (skipping the
    persona's own posts) and calls /view on each.

    `stamp_last_action=False` is the passive case — counter goes up
    but the 15h window does NOT reset, so a persona who only ever
    scrolls still becomes eligible to actively post / reply / like.
    """
    # Recency-weighted random selection. Top of feed (newest) is
    # 3× more likely than bottom; spreads view love across the
    # feed window so older posts also gain counts naturally.
    candidates = [
        p for p in feed
        if p.author_username != persona.username
        and not store.has_acted_on(persona.username, p.id, "view")
    ]
    if not candidates:
        return 0
    weights = [max(1, 3 * len(candidates) - i) for i in range(len(candidates))]
    # Sample WITHOUT replacement (max_views, or all if fewer).
    chosen: List[FeedPost] = []
    pool = list(zip(candidates, weights))
    while pool and len(chosen) < max_views:
        total = sum(w for _, w in pool)
        r = random.random() * total
        cum = 0.0
        for idx, (p, w) in enumerate(pool):
            cum += w
            if r <= cum:
                chosen.append(p)
                pool.pop(idx)
                break

    recorded = 0
    for post in chosen:
        try:
            if not DRY_RUN:
                client.view(post.id)
            store.record_seen(persona.username, post.id, "view")
            if stamp_last_action:
                store.mark_action(persona.username, "view")
            else:
                store.bump_view_counter(persona.username)
            recorded += 1
        except RavenAPIError as e:
            logger.debug(f"  · view {post.id[:8]} skipped: {e}")
    return recorded


def _seed_graph_bootstrap(persona: Persona,
                          row: PersonaRow,
                          by_user: dict,
                          store: StateStore,
                          base_url: str) -> bool:
    """One-time-per-persona social-graph seed.

    Picks a small random subset of OTHER registered personas and:
      • Follows `GRAPH_FOLLOW_COUNT` of them outright (the followee
        being public → instant accepted; private → pending. Both
        outcomes are fine for graph health.)
      • Sends `GRAPH_FRIEND_REQ_COUNT` friend requests to a different
        slice. Half of these will eventually be reciprocated (when
        the other persona's bootstrap picks us) → mutual `friends`
        via the round-2026-05-21 reverse-pending auto-accept fix.

    Returns True if we actually did the seed (flag flipped). Returns
    False if there weren't enough peer personas yet or the persona
    was already seeded.
    """
    if row.graph_bootstrapped:
        return False
    if row.user_id is None:
        return False

    candidates = [
        r for u, r in by_user.items()
        if u != persona.username and r.user_id is not None
    ]
    if len(candidates) < GRAPH_FOLLOW_COUNT + GRAPH_FRIEND_REQ_COUNT:
        # Not enough other registered personas yet — try next tick.
        return False

    random.shuffle(candidates)
    follow_targets = candidates[:GRAPH_FOLLOW_COUNT]
    friend_targets = candidates[GRAPH_FOLLOW_COUNT:GRAPH_FOLLOW_COUNT + GRAPH_FRIEND_REQ_COUNT]

    if DRY_RUN:
        store.mark_graph_bootstrapped(persona.username)
        logger.info(
            f"[dry] 🕸️ would seed {persona.username}: follow {[t.username for t in follow_targets]}, "
            f"friend-req {[t.username for t in friend_targets]}"
        )
        return True

    try:
        with RavenClient(base_url) as client:
            try:
                client.login(username=persona.username, password=row.password)
            except RavenAPIError as e:
                logger.info(f"  · graph-seed login {persona.username}: {e}")
                return False

            followed = 0
            for t in follow_targets:
                try:
                    resp = client.follow(t.user_id)
                    store.log(persona.username, "follow",
                              target=t.user_id,
                              detail=resp.get("status", ""))
                    followed += 1
                except RavenAPIError as e:
                    logger.debug(f"  · {persona.username} follow {t.user_id[:8]}: {e}")

            requested = 0
            for t in friend_targets:
                try:
                    resp = client.send_friend_request(t.user_id)
                    store.log(persona.username, "friend_req",
                              target=t.user_id,
                              detail="auto-accepted" if resp.get("auto_accepted") else "sent")
                    requested += 1
                except RavenAPIError as e:
                    # Common case here: the OTHER persona already sent
                    # us a friend request → server returns 200 with
                    # auto-accepted. A 400 "already friends" is also
                    # fine — graph edge exists either way.
                    logger.debug(f"  · {persona.username} friend-req {t.user_id[:8]}: {e}")

        store.mark_graph_bootstrapped(persona.username)
        logger.info(
            f"🕸️ {persona.username} graph-seeded: "
            f"{followed} follow(s) + {requested} friend-req(s)"
        )
        return True
    except Exception:
        logger.error(f"❌ graph-seed crashed for {persona.username}")
        traceback.print_exc()
        return False


def _passive_view_tick(persona: Persona, row: PersonaRow,
                       store: StateStore, base_url: str) -> None:
    """A registered persona scrolls the feed for a moment — viewing a
    handful of posts WITHOUT triggering their 15h action window.

    Runs every tick for every registered persona (subject to
    `PASSIVE_VIEW_PROB`) so view counts grow at network speed, not at
    primary-action speed. Mirrors real-world user behaviour: people
    scroll many times per day but only post / like a few times.
    """
    if random.random() > PASSIVE_VIEW_PROB:
        return
    if DRY_RUN:
        return
    try:
        with RavenClient(base_url) as client:
            try:
                client.login(username=persona.username, password=row.password)
            except RavenAPIError as e:
                # Don't log loudly — login can transiently 429 if the
                # daemon races itself; we just skip this passive cycle.
                logger.debug(f"  · passive login {persona.username}: {e}")
                return
            try:
                feed = client.fetch_feed(limit=FEED_FETCH_LIMIT)
            except RavenAPIError:
                return
            recorded = _do_view_pass(
                client, persona, store, feed,
                max_views=MAX_VIEWS_PASSIVE,
                stamp_last_action=False,
            )
            if recorded:
                store.log(persona.username, "passive-view",
                          detail=f"{recorded} posts")
                logger.info(f"  👀 {persona.username} passively viewed {recorded}")
    except Exception:
        logger.error(f"❌ passive-view crashed for {persona.username}")
        traceback.print_exc()


def _do_post(client: RavenClient, persona: Persona,
             store: StateStore) -> None:
    """Generate + publish a fresh top-level post."""
    try:
        text = _gemini_singleton().compose_post(persona)
    except GeminiError as e:
        logger.warning(f"  · {persona.username} gemini post failed: {e}")
        store.log(persona.username, "post-gen-failed", detail=str(e))
        return
    if DRY_RUN:
        logger.info(f"  [dry] {persona.username} would post: {text!r}")
        store.log(persona.username, "post-dry", detail=text)
        return
    try:
        post_id = client.create_post(text)
        store.mark_action(persona.username, "post")
        store.log(persona.username, "post", target=post_id, detail=text[:200])
        logger.info(f"  📝 {persona.username} posted {post_id[:8]}")
    except RavenAPIError as e:
        logger.warning(f"  · {persona.username} post failed: {e}")
        store.log(persona.username, "post-failed", detail=str(e))


def _do_reply(client: RavenClient, persona: Persona, store: StateStore,
              feed: List[FeedPost], gemini: Gemini) -> None:
    """Pick an unreplied feed post and Gemini-reply to it."""
    # Don't reply to our own posts; don't double-reply.
    candidates = [
        p for p in feed
        if p.author_username != persona.username
        and not store.has_acted_on(persona.username, p.id, "replied")
    ]
    if not candidates:
        logger.info(f"  · {persona.username}: no fresh reply targets, falling back to post")
        _do_post(client, persona, store)
        return
    # Slight skew toward more-recent posts (top of feed list).
    weights = [max(1, 12 - i) for i in range(len(candidates))]
    target = random.choices(candidates, weights=weights, k=1)[0]
    try:
        text = gemini.compose_reply(persona, target.content, target.author_username)
    except GeminiError as e:
        logger.warning(f"  · {persona.username} gemini reply failed: {e}")
        store.log(persona.username, "reply-gen-failed", detail=str(e))
        return
    if DRY_RUN:
        logger.info(f"  [dry] {persona.username} would reply to {target.id[:8]}: {text!r}")
        store.log(persona.username, "reply-dry", target=target.id, detail=text)
        return
    try:
        client.comment(target.id, text)
        store.record_seen(persona.username, target.id, "replied")
        store.mark_action(persona.username, "reply")
        store.log(persona.username, "reply", target=target.id, detail=text[:200])
        logger.info(f"  💬 {persona.username} replied to {target.id[:8]}")
    except RavenAPIError as e:
        logger.warning(f"  · {persona.username} reply failed: {e}")
        store.log(persona.username, "reply-failed", detail=str(e))


def _do_like(client: RavenClient, persona: Persona, store: StateStore,
             feed: List[FeedPost]) -> None:
    """Pick a feed post we haven't liked yet, and like it."""
    candidates = [
        p for p in feed
        if p.author_username != persona.username
        and not p.is_liked
        and not store.has_acted_on(persona.username, p.id, "liked")
    ]
    if not candidates:
        logger.info(f"  · {persona.username}: no fresh like targets, falling back to view-only")
        store.mark_action(persona.username, "view")
        store.log(persona.username, "no-like-targets")
        return
    # Prefer posts with some existing engagement (more interesting).
    weights = [1 + p.likes + p.comments * 2 for p in candidates]
    target = random.choices(candidates, weights=weights, k=1)[0]
    if DRY_RUN:
        logger.info(f"  [dry] {persona.username} would like {target.id[:8]}")
        store.log(persona.username, "like-dry", target=target.id)
        return
    try:
        client.like(target.id)
        store.record_seen(persona.username, target.id, "liked")
        store.mark_action(persona.username, "like")
        store.log(persona.username, "like", target=target.id)
        logger.info(f"  ❤️  {persona.username} liked {target.id[:8]}")
    except RavenAPIError as e:
        logger.warning(f"  · {persona.username} like failed: {e}")
        store.log(persona.username, "like-failed", detail=str(e))


# ─────────────────────────────────────────────────────────────────────
# Top-level tick
# ─────────────────────────────────────────────────────────────────────

_GEMINI_SINGLETON: Gemini | None = None

def _gemini_singleton() -> Gemini:
    global _GEMINI_SINGLETON
    if _GEMINI_SINGLETON is None:
        _GEMINI_SINGLETON = Gemini()
    return _GEMINI_SINGLETON


def run_tick(base_url: str) -> None:
    store = StateStore()
    # Ensure a row exists for every persona — generates passwords on
    # first run.
    rows = [store.ensure_persona(p.username) for p in PERSONAS]
    by_user = {r.username: r for r in rows}

    # Bootstrap a handful of unregistered personas.
    with RavenClient(base_url) as boot_client:
        unregistered = [p for p in PERSONAS if by_user[p.username].user_id is None]
        random.shuffle(unregistered)
        for p in unregistered[:REGISTER_PER_TICK]:
            _bootstrap_persona(boot_client, p, by_user[p.username], store)
            # Refresh row in case register succeeded.
            by_user[p.username] = store.ensure_persona(p.username)

    # 🆕 2026-05-23 — social-graph bootstrap pass. Up to
    # `GRAPH_BOOTSTRAP_PER_TICK` personas seed their initial follow +
    # friend-request set against other registered personas. Once each
    # persona is bootstrapped the flag is sticky in SQLite so we
    # never re-run it. This is what makes `UserFollow` /
    # `FriendRequest` actually carry data; without it the personas
    # post + comment all day but the social graph stays empty.
    unseeded = [p for p in PERSONAS if not by_user[p.username].graph_bootstrapped
                and by_user[p.username].user_id is not None]
    random.shuffle(unseeded)
    for persona in unseeded[:GRAPH_BOOTSTRAP_PER_TICK]:
        row = by_user[persona.username]
        if _seed_graph_bootstrap(persona, row, by_user, store, base_url):
            by_user[persona.username] = store.ensure_persona(persona.username)

    # Pick the personas due to act this tick.
    due = [p for p in PERSONAS if _due(by_user[p.username])]
    random.shuffle(due)
    acting = due[:ACTIVE_PER_TICK]

    if not acting:
        # Compute when the next persona will first become "due" for
        # either a post (15h) or a social action (3h), whichever comes
        # sooner. That's the meaningful "next-tick-with-work" time.
        soonest = None
        for p in PERSONAS:
            r = by_user[p.username]
            if r.user_id is None:
                continue
            post_eligible = (r.last_post_at or 0) + POST_INTERVAL_SECONDS
            social_eligible = (r.last_social_at or 0) + SOCIAL_INTERVAL_SECONDS
            persona_soonest = min(post_eligible, social_eligible)
            if soonest is None or persona_soonest < soonest:
                soonest = persona_soonest
        if soonest is not None:
            mins = max(0, (soonest - _now()) // 60)
            logger.info(f"💤 no personas due this tick. Next eligible in ~{mins} min.")
        else:
            logger.info("💤 no personas due (all unregistered or freshly booted).")
        return

    logger.info(f"🌀 tick: {len(acting)} persona(s) acting "
                f"({', '.join(p.username for p in acting)})")

    acting_usernames = {p.username for p in acting}

    for persona in acting:
        row = by_user[persona.username]
        try:
            _persona_tick(persona, row, _gemini_singleton(), store, base_url)
        except Exception:
            logger.error(f"❌ persona-tick crashed for {persona.username}")
            traceback.print_exc()
            store.log(persona.username, "tick-crash",
                      detail=traceback.format_exc()[:1000])

    # ── Passive view pass ─────────────────────────────────────────
    # Every registered persona who DIDN'T act this tick has a chance
    # to scroll the feed and view a handful of posts. This is how
    # view counts grow at network speed instead of being stuck behind
    # the 15h-per-persona primary-action cadence.
    passive_candidates = [
        p for p in PERSONAS
        if by_user[p.username].user_id is not None
        and p.username not in acting_usernames
    ]
    random.shuffle(passive_candidates)
    passive_count = 0
    for persona in passive_candidates:
        row = by_user[persona.username]
        # Re-fetch row in case the active loop above mutated counters.
        _passive_view_tick(persona, row, store, base_url)
        passive_count += 1
    if passive_count:
        logger.info(f"👀 passive-view pass: {passive_count} persona(s)")


def print_status() -> None:
    """One-shot CLI: dump the persona table + recent activity."""
    store = StateStore()
    rows = store.all_personas()
    print(f"{'username':<22} {'reg':<5} {'last_action':<22} "
          f"{'posts':>5} {'reps':>5} {'likes':>5} {'views':>5}")
    print("-" * 90)
    for r in sorted(rows, key=lambda x: x.username):
        last = (datetime.utcfromtimestamp(r.last_action_at).strftime("%Y-%m-%d %H:%M:%S")
                if r.last_action_at else "—")
        reg = "✓" if r.user_id else "·"
        print(f"{r.username:<22} {reg:<5} {last:<22} "
              f"{r.total_posts:>5} {r.total_replies:>5} {r.total_likes:>5} {r.total_views:>5}")
    print()
    print("recent activity (last 20):")
    for at, user, act, target, detail in store.recent_log(20):
        target_s = (target or "")[:10]
        detail_s = (detail or "")[:80].replace("\n", " ")
        print(f"  {at}  {user:<22} {act:<14} {target_s:<11} {detail_s}")


# ─────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────

def main(argv: List[str] | None = None) -> int:
    global DRY_RUN
    parser = argparse.ArgumentParser(prog="python -m simulation")
    parser.add_argument("--dry-run", action="store_true",
                        help="Generate everything but don't POST to RAVEN")
    parser.add_argument("--status", action="store_true",
                        help="Print persona table + recent activity, exit")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    if args.status:
        print_status()
        return 0

    DRY_RUN = args.dry_run

    base_url = os.getenv(
        "RAVEN_BASE_URL",
        "https://raven-server-516053629173.europe-west1.run.app",
    )
    logger.info(f"⏰ tick start  base_url={base_url}  dry_run={DRY_RUN}")
    run_tick(base_url)
    logger.info("✅ tick done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
