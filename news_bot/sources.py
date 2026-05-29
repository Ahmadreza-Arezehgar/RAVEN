"""
news_bot/sources.py
===================

Curated news RSS feeds, grouped by **bot profile**. Each RAVEN news
account (`@raven_news`, `@raven_economic`, ...) is a separate daemon
process that points at a different profile.

Profiles (selectable via `BOT_PROFILE` env var, default
`politics_sports`):

  • `politics_sports` — `@raven_news`. Politics for a Persian-speaking
    audience + football / NBA / Formula 1.
  • `economic` — `@raven_economic`. US + Europe markets, central-bank
    policy, top-corp earnings, macro indicators.

Add a new profile = add a new tuple + a new key in `_PROFILES`. The
fetcher tolerates unreachable URLs — a feed that 404s today just gets
skipped, the next tick tries again.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class NewsSource:
    name: str           # short label printed in posts
    feed_url: str       # RSS / Atom feed
    language: str       # ISO-639-1 (`fa`, `en`, `ar`, ...)
    region: str         # short location label for tagging


# ── Profile 1: politics + sports (@raven_news) ────────────────────────
_POLITICS_SPORTS: tuple[NewsSource, ...] = (
    # ── Farsi-language political coverage ─────────────────────────────
    NewsSource(
        name="BBC فارسی",
        feed_url="https://feeds.bbci.co.uk/persian/rss.xml",
        language="fa",
        region="World/Iran",
    ),
    NewsSource(
        name="DW فارسی",
        feed_url="https://rss.dw.com/atom/rss-per-news",
        language="fa",
        region="World/Europe",
    ),
    NewsSource(
        name="ایران اینترنشنال",
        feed_url="https://www.iranintl.com/en/feed",   # EN feed; bot translates
        language="en",
        region="Iran",
    ),
    NewsSource(
        name="رادیو فردا",
        feed_url="https://www.radiofarda.com/api/zpkmqe$pe",
        language="fa",
        region="Iran",
    ),
    NewsSource(
        name="VOA فارسی",
        feed_url="https://ir.voanews.com/api/zr$qoer$g_",
        language="fa",
        region="World/Iran",
    ),

    # ── English political coverage (global) ───────────────────────────
    NewsSource(
        name="Reuters World",
        feed_url="https://feeds.reuters.com/Reuters/worldNews",
        language="en",
        region="Global",
    ),
    NewsSource(
        name="AP Politics",
        feed_url="https://feeds.apnews.com/apf-Politics",
        language="en",
        region="US/Global",
    ),
    NewsSource(
        name="BBC Politics",
        feed_url="https://feeds.bbci.co.uk/news/politics/rss.xml",
        language="en",
        region="UK/Global",
    ),
    NewsSource(
        name="NPR Politics",
        feed_url="https://feeds.npr.org/1014/rss.xml",
        language="en",
        region="US",
    ),
    NewsSource(
        name="Al Jazeera",
        feed_url="https://www.aljazeera.com/xml/rss/all.xml",
        language="en",
        region="Middle East/Global",
    ),
    NewsSource(
        name="The Guardian Politics",
        feed_url="https://www.theguardian.com/politics/rss",
        language="en",
        region="UK/Global",
    ),

    # ── Sports: Football / Soccer (Premier League, La Liga, intl.) ────
    NewsSource(
        name="BBC Sport Football",
        feed_url="https://feeds.bbci.co.uk/sport/football/rss.xml",
        language="en",
        region="Football/UK/Global",
    ),
    NewsSource(
        name="ESPN FC",
        feed_url="https://www.espn.com/espn/rss/soccer/news",
        language="en",
        region="Football/Global",
    ),
    NewsSource(
        name="Guardian Football",
        feed_url="https://www.theguardian.com/football/rss",
        language="en",
        region="Football/UK/Global",
    ),
    NewsSource(
        name="Sky Sports Football",
        feed_url="https://www.skysports.com/rss/12040",
        language="en",
        region="Football/UK",
    ),

    # ── Sports: NBA Basketball ────────────────────────────────────────
    NewsSource(
        name="ESPN NBA",
        feed_url="https://www.espn.com/espn/rss/nba/news",
        language="en",
        region="NBA/US",
    ),
    NewsSource(
        name="NBA.com",
        feed_url="https://www.nba.com/rss/nba_rss.xml",
        language="en",
        region="NBA/US",
    ),
    NewsSource(
        name="Bleacher Report NBA",
        feed_url="https://bleacherreport.com/articles/feed?tag_id=19",
        language="en",
        region="NBA/US",
    ),

    # ── Sports: Formula 1 ─────────────────────────────────────────────
    NewsSource(
        name="BBC Sport F1",
        feed_url="https://feeds.bbci.co.uk/sport/formula1/rss.xml",
        language="en",
        region="F1/Global",
    ),
    NewsSource(
        name="Autosport F1",
        feed_url="https://www.autosport.com/rss/feed/f1",
        language="en",
        region="F1/Global",
    ),
    NewsSource(
        name="ESPN F1",
        feed_url="https://www.espn.com/espn/rss/rpm/news",
        language="en",
        region="F1/Global",
    ),
    NewsSource(
        name="The Race",
        feed_url="https://the-race.com/feed/",
        language="en",
        region="F1/Motorsport",
    ),
)


# ── Profile 2: economic + markets (@raven_economic) ───────────────────
#
# Focus: US + Europe macro indicators, central-bank policy, top-corp
# earnings, M&A, stock-market moves. NOT geopolitics (the politics
# profile already covers that). NOT crypto-only outlets — the bot
# isn't a crypto-signals account.
_ECONOMIC: tuple[NewsSource, ...] = (
    # US markets + macro
    NewsSource(
        name="CNBC Top News",
        feed_url="https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114",
        language="en",
        region="US/Markets",
    ),
    NewsSource(
        name="MarketWatch Top",
        feed_url="http://feeds.marketwatch.com/marketwatch/topstories",
        language="en",
        region="US/Markets",
    ),
    NewsSource(
        name="Reuters Business",
        feed_url="https://feeds.reuters.com/reuters/businessNews",
        language="en",
        region="Global/Business",
    ),
    NewsSource(
        name="Reuters Markets",
        feed_url="https://feeds.reuters.com/reuters/marketsNews",
        language="en",
        region="Global/Markets",
    ),
    NewsSource(
        name="Yahoo Finance",
        feed_url="https://finance.yahoo.com/news/rssindex",
        language="en",
        region="US/Markets",
    ),
    NewsSource(
        name="WSJ Markets",
        feed_url="https://feeds.a.dj.com/rss/RSSMarketsMain.xml",
        language="en",
        region="US/Markets",
    ),
    NewsSource(
        name="WSJ US Business",
        feed_url="https://feeds.a.dj.com/rss/WSJcomUSBusiness.xml",
        language="en",
        region="US/Business",
    ),
    NewsSource(
        name="Investing.com",
        feed_url="https://www.investing.com/rss/news.rss",
        language="en",
        region="Global/Markets",
    ),
    NewsSource(
        name="Seeking Alpha",
        feed_url="https://seekingalpha.com/feed.xml",
        language="en",
        region="US/Markets",
    ),

    # Europe
    NewsSource(
        name="FT Markets",
        feed_url="https://www.ft.com/markets?format=rss",
        language="en",
        region="Europe/Markets",
    ),
    NewsSource(
        name="The Economist Finance",
        feed_url="https://www.economist.com/finance-and-economics/rss.xml",
        language="en",
        region="Europe/Macro",
    ),
    NewsSource(
        name="BBC Business",
        feed_url="https://feeds.bbci.co.uk/news/business/rss.xml",
        language="en",
        region="UK/Business",
    ),
    NewsSource(
        name="Euronews Business",
        feed_url="https://www.euronews.com/rss?level=theme&name=business",
        language="en",
        region="Europe/Business",
    ),
    NewsSource(
        name="Guardian Business",
        feed_url="https://www.theguardian.com/business/rss",
        language="en",
        region="UK/Business",
    ),
)


# ── Profile selection ─────────────────────────────────────────────────

_PROFILES: dict[str, tuple[NewsSource, ...]] = {
    "politics_sports": _POLITICS_SPORTS,
    "economic": _ECONOMIC,
}


def current_profile() -> str:
    """Active profile name from `BOT_PROFILE` env var. Defaults to the
    historical `politics_sports` profile so an unconfigured deployment
    keeps the original `@raven_news` behaviour."""
    return os.environ.get("BOT_PROFILE", "politics_sports").strip().lower()


# `SOURCES` is evaluated at import. Daemons that need to switch
# profiles MUST set `BOT_PROFILE` before importing `news_bot.sources`
# (the `run-loop.sh` wrapper does this from the `.env` it sources).
SOURCES: tuple[NewsSource, ...] = _PROFILES.get(current_profile(), _POLITICS_SPORTS)


def by_language(lang: str) -> tuple[NewsSource, ...]:
    """Convenience filter — e.g. `by_language("fa")` returns just Farsi feeds."""
    return tuple(s for s in SOURCES if s.language == lang)
