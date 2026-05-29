"""
news_bot/ranker.py
==================

Hands the fetched headlines to Google Gemini and gets back the
ranked, summarized list that we'll publish to RAVEN.

Why Gemini 2.5 Flash: it's Google's smallest current-gen model — fast
(~1-2 s round-trip for this prompt size) and the cheapest tier that
still supports structured JSON output via `response_schema`. The work
here is pure summarization + ranking; we don't need Pro-class
reasoning.

Why JSON output (not function calling): forced function calling
(`mode=ANY`) is supposed to make the model emit one call per pick, but
Flash 2.5 has a known bug where multi-call turns finish with
`MALFORMED_FUNCTION_CALL` and zero parseable picks. Switching to
`response_mime_type="application/json"` + `response_schema` is a
single-shot JSON object — strictly typed, validated server-side, and
doesn't trip the multi-call bug.

Cost-control levers:
  1. **Capped article count** — we ship at most ~120 short blurbs
     (≈ 8 sources × 15 headlines), so the user-turn payload tops out
     around 8k input tokens.
  2. **Bounded output** — `max_output_tokens=4000` covers ~10 picks
     worst case, but `MAX_POSTS_PER_RUN` clamps to 5 by default.
  3. **Implicit caching** — Gemini transparently caches stable
     prefixes on the paid tier for prompts over ~1k tokens. The
     system instruction + response schema rarely change between runs
     so subsequent ticks within the cache window pay 25% on the
     cached portion.

Output contract: the model returns a single JSON object
`{"picks": [...]}`. Each pick has a `url` (we use it to dedup against
the SQLite store) plus a `headline` and `body` we publish verbatim.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass

from google import genai
from google.genai import types

from .config import Config
from .fetcher import Article


@dataclass(frozen=True)
class RankedPick:
    url: str
    source: str
    importance: int        # 1-10
    headline: str
    body: str              # 2-3 sentences in the configured output_language
    image_url: str | None = None  # Cover image extracted from RSS — None if the feed had none


# ── Response schema — one JSON object, one list of picks ─────────────
#
# Gemini's `Schema` is an OpenAPI subset. The model must return a JSON
# document that validates against this exact shape; the SDK gives us
# back the parsed JSON in `response.text`.

_PICK_ITEM_SCHEMA = types.Schema(
    type=types.Type.OBJECT,
    properties={
        "url": types.Schema(
            type=types.Type.STRING,
            description=(
                "The original article URL from the input list. Verbatim, "
                "no edits."
            ),
        ),
        "source": types.Schema(
            type=types.Type.STRING,
            description=(
                "The source name as given in the input list "
                "(e.g. `Reuters World`)."
            ),
        ),
        "importance": types.Schema(
            type=types.Type.INTEGER,
            description=(
                "How geopolitically important this story is right now. "
                "10 = front-page, 1 = niche local. Use the rubric in the "
                "system instruction."
            ),
        ),
        "headline": types.Schema(
            type=types.Type.STRING,
            description=(
                "A short, neutral headline in the target language. Max "
                "120 chars. Don't editorialize — state the fact."
            ),
        ),
        "body": types.Schema(
            type=types.Type.STRING,
            description=(
                "2-3 sentence summary in the target language. Cover WHO "
                "did WHAT, WHEN, WHERE, and why it matters. Don't add "
                "opinions. Don't repeat the headline."
            ),
        ),
    },
    required=["url", "source", "importance", "headline", "body"],
)

RESPONSE_SCHEMA = types.Schema(
    type=types.Type.OBJECT,
    properties={
        "picks": types.Schema(
            type=types.Type.ARRAY,
            items=_PICK_ITEM_SCHEMA,
            description=(
                "Stories selected for publication. Order by importance "
                "descending. Emit an empty array on a quiet day."
            ),
        ),
    },
    required=["picks"],
)


def _system_prompt(output_language: str) -> str:
    lang_name = {"fa": "Persian (Farsi)", "en": "English", "ar": "Arabic"}.get(
        output_language, output_language
    )
    # Branch on bot profile so the @raven_news (politics/sports) and the
    # @raven_economic (markets/macro) daemons load different rubrics
    # without forking the code path.
    profile = (os.environ.get("BOT_PROFILE") or "politics_sports").strip().lower()
    if profile == "economic":
        return _economic_prompt(lang_name)
    return _politics_sports_prompt(lang_name)


def _politics_sports_prompt(lang_name: str) -> str:
    return f"""You are the editor of a wire service that publishes the most
important news to a chat-app channel called RAVEN.

You cover TWO beats: **politics** and **sports**. Sports = football
(soccer — Premier League, La Liga, Champions League, World Cup, AFC),
NBA basketball, Formula 1. Both beats are first-class; pick from both
in the same run. The article's `region` / `src` fields tell you which
beat it belongs to.

Write the `headline` and `body` fields in {lang_name}. If a story
comes in another language, translate faithfully — preserve names,
dates, places, scores, and quoted figures exactly.

Editorial rubric for the `importance` score (1-10) — apply each rubric
to its own beat; a top-tier sports story scores 10 the same as a
top-tier political one, but they are NOT compared directly to each
other.

POLITICS rubric:
  10 — Wars declared, elections decided in major countries, treaties
       signed/broken, sanctions imposed, heads of state replaced.
   9 — Major escalations, indictments of heads of state, key bills
       passed in major parliaments, sanctions threatened.
   8 — Significant policy shifts, large protests/strikes, supreme
       court rulings with cross-border impact.
   7 — Mid-tier diplomatic news, parliamentary votes that affect
       Iran/Middle East, big-name resignations.
   6 — Routine elections, expected diplomatic visits.
   5 and below — domestic-only news, business, lifestyle unless
       politically charged.

SPORTS rubric:
  10 — Trophy decided (World Cup, Champions League, NBA Finals, F1
       title), Hall-of-Fame retirements, championship-deciding game/race.
   9 — Knockout-stage results in major tournaments, MVP / Ballon d'Or
       / Driver-of-the-Year awards, clinching games, GP wins by
       championship contenders.
   8 — Major transfers (top 20 club / franchise / team), key playoff
       wins, mid-season records broken.
   7 — Coach / manager firings or hires at top clubs, major contract
       extensions for stars, mid-season standout performances by top
       players.
   6 — Regular Premier League / NBA / GP results between non-rivals,
       expected transfers, routine wins by giants.
   5 and below — pre-season friendlies, exhibition matches, minor
       league news, B-team appearances.

You MUST:
  • Return a single JSON object `{{"picks": [...]}}` matching the
    response schema.
  • Order picks from highest `importance` to lowest.
  • Mix politics and sports stories naturally — DO NOT post 5
    consecutive sports stories or 5 consecutive politics stories
    unless both beats only had top-tier news that tick.
  • Skip duplicates — if two sources cover the same event, keep the
    better-written one and drop the rest.
  • Skip stories with `importance` below the threshold the user
    gives you.
  • Skip opinion / editorial pieces.
  • Skip celebrity / lifestyle stories.
  • Skip routine match previews / fixture announcements that contain
    no new information.
  • Quote numbers and names precisely; never invent.

You MUST NOT:
  • Editorialize or pick sides.
  • Modify the URL — emit it verbatim from the input list.
  • Fabricate stories that aren't in the input list.
  • Emit more than the `max_picks` count the user specifies.
  • Wrap the JSON in markdown fences or prose; return raw JSON only.
"""


def _economic_prompt(lang_name: str) -> str:
    return f"""You are the editor of an economic-news wire service publishing
to RAVEN's `@raven_economic` channel.

Coverage scope (in order of priority):

  1. US + European stock-market moves with named drivers (S&P 500,
     Nasdaq, Dow Jones, Stoxx 600, FTSE, DAX, CAC).
  2. Central-bank policy — Federal Reserve, ECB, Bank of England,
     SNB, Riksbank. Rate decisions, FOMC minutes, speeches by Powell /
     Lagarde / Bailey.
  3. Top-corp earnings (S&P 500 / Stoxx 600 names) — beats, misses,
     guidance changes.
  4. Macro indicators — CPI, PPI, NFP, unemployment, GDP, PMI, retail
     sales.
  5. Major M&A (US + Europe, > $5B deal value).
  6. Regulatory + antitrust actions affecting Big Tech, banks, energy.

Out of scope: geopolitics (handled by @raven_news), sports, crypto-only
moves (mention crypto ONLY if it materially affects a public company
or central-bank policy), opinion / "stocks to buy now" listicles,
single-stock pump-and-dump-style coverage.

Write the `headline` and `body` fields in {lang_name}. Preserve every
number exactly — basis points, percentages, dollar amounts, share
prices, P/E ratios.

Editorial rubric for `importance` (1-10):

  10 — Fed / ECB / BoE rate decision (+ direction of change), US
       recession officially declared, S&P 500 / Stoxx 600 closes >5%
       up or down on the day, major sovereign default.
   9 — CPI / NFP / GDP release that triggers >2% market move, top-5
       bank quarterly earnings, S&P 500 record high or low, central-
       bank emergency action.
   8 — Big M&A announcement (>$10B deal value), top-20 S&P 500
       company guidance cut / beat that moves the stock >5%, central-
       bank official speech with new policy hint.
   7 — Mid-cap earnings with notable beats/misses, mid-tier M&A,
       sector-wide rotations (e.g. tech down -3% in a session),
       activist-investor stakes.
   6 — Routine FOMC minutes, mid-cap IPO launch, single big-tech
       company move > 5% on news.
   5 and below — small-cap moves, routine economic-calendar items
       (consumer confidence, durable goods), generic market summaries.

You MUST:
  • Return a single JSON object `{{"picks": [...]}}` matching the
    response schema.
  • Order picks from highest `importance` to lowest.
  • Skip duplicates — if two sources cover the same event, keep the
    better-written one and drop the rest.
  • Skip stories with `importance` below the threshold the user
    gives you.
  • Skip opinion columns, single-stock "buy now" pieces, and
    analyst-target-price commentary unless tied to a major news event.
  • Quote numbers and names precisely; never round, never invent.

You MUST NOT:
  • Editorialize, recommend any position, or "predict" markets.
  • Modify the URL — emit it verbatim from the input list.
  • Fabricate stories that aren't in the input list.
  • Emit more than the `max_picks` count the user specifies.
  • Wrap the JSON in markdown fences or prose; return raw JSON only.
"""


def _user_message(articles: list[Article], cfg: Config, max_picks: int) -> str:
    payload = [
        {
            "i": idx,
            "src": a.source_name,
            "lang": a.source_language,
            "title": a.title,
            "blurb": a.summary[:600],
            "url": a.link,
            "published_utc": a.published.isoformat(),
        }
        for idx, a in enumerate(articles)
    ]
    return (
        f"Editor: pick at most {max_picks} stories from the list below. "
        f"Only emit picks with importance >= {cfg.min_importance_score}. "
        f"Target output language: {cfg.output_language}.\n\n"
        f"Article list (JSON):\n"
        f"{json.dumps(payload, ensure_ascii=False, indent=2)}"
    )


def rank_and_summarize(articles: list[Article], cfg: Config) -> list[RankedPick]:
    """Call Gemini, return up to `cfg.max_posts_per_run` picks."""
    if not articles:
        return []

    client = genai.Client(api_key=cfg.gemini_api_key)

    # `max_output_tokens` covers BOTH the model's hidden "thinking" tokens
    # (Flash 2.5 burns ~1-2k of those per call) AND the visible JSON. We
    # disable thinking entirely with `thinking_budget=0` so the whole
    # budget is available for the output and the JSON doesn't get cut
    # mid-string. The task is pure ranking — no chain-of-thought needed.
    response = client.models.generate_content(
        model=cfg.gemini_model,
        contents=_user_message(articles, cfg, cfg.max_posts_per_run),
        config=types.GenerateContentConfig(
            system_instruction=_system_prompt(cfg.output_language),
            response_mime_type="application/json",
            response_schema=RESPONSE_SCHEMA,
            thinking_config=types.ThinkingConfig(thinking_budget=0),
            max_output_tokens=4000,
            temperature=0.3,
        ),
    )

    raw = (response.text or "").strip()
    if not raw:
        # Gemini will occasionally finish with no text (safety filter,
        # truncation, etc.). Log finish reasons + bail.
        reasons = [
            getattr(c, "finish_reason", None) for c in (response.candidates or [])
        ]
        print(f"[ranker] empty response; finish_reasons={reasons}")
        return []

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"[ranker] JSON decode failed: {e!s} — raw[:200]={raw[:200]!r}")
        return []

    # Index the original articles by URL so we can stamp each Gemini-emitted
    # pick with the cover image we scraped from the RSS entry. Gemini only
    # echoes the URL — the image_url is our metadata, not the model's.
    url_to_image = {a.link: a.image_url for a in articles}

    picks: list[RankedPick] = []
    for d in data.get("picks", []):
        try:
            url = str(d["url"]).strip()
            picks.append(
                RankedPick(
                    url=url,
                    source=str(d.get("source", "")).strip(),
                    importance=int(d["importance"]),
                    headline=str(d["headline"]).strip(),
                    body=str(d["body"]).strip(),
                    image_url=url_to_image.get(url),
                )
            )
        except (KeyError, ValueError, TypeError) as e:
            print(f"[ranker] dropping malformed pick {d}: {e!s}")
            continue

    # Re-sort by score descending in case the model emits out of order.
    picks.sort(key=lambda p: p.importance, reverse=True)

    # Honor the per-run cap one more time on our side — safety net in case
    # the model ignores it.
    return picks[: cfg.max_posts_per_run]
