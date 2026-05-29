"""
simulation/ai.py
================

Gemini-driven content generation for each persona. Two entry points:

  • `compose_post(persona)`        → an in-voice short post
  • `compose_reply(persona, post)` → an in-voice reply to a given post

Both honor the persona's primary language (en / fa) and traits. The
system instruction is hand-tuned to suppress the "AI tells" — no
hashtag spam, no emoji bombardment, no "as an AI" preambles, no
"hope you're doing well" sycophancy.

Model: `gemini-2.5-flash` — same key the news bot uses.
"""

from __future__ import annotations

import logging
import os
import random
from datetime import datetime
from typing import Optional

import httpx

from .personas import Persona


logger = logging.getLogger("simulation.ai")

GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"


# ────────────────────────────────────────────────────────────────────
# System instructions — separate FA / EN templates so prompt voice
# matches output voice. The shared rules at the bottom are appended
# to whichever template fires.
# ────────────────────────────────────────────────────────────────────

_SHARED_RULES = """
RULES YOU MUST FOLLOW:
1. Return ONLY the post / reply text. No preamble, no quotes around it,
   no "Sure, here is...".
2. Sound like a real human on social media — slightly imperfect, with
   natural punctuation. Use lowercase where natural. Don't always start
   the same way.
3. NO HASHTAG SPAM. Zero hashtags is fine. One is the absolute max,
   and only if it's natural.
4. Emoji: zero or one. Never more.
5. NEVER announce who you are. Never say "as a {profession}". Never
   say "today I…" if you weren't going to say it anyway.
6. Don't be sycophantic, motivational, or LinkedIn-y. Don't end with a
   generic positive note.
7. Don't reveal you're an AI. Don't break character.
8. Length: posts ≤ 280 characters. Replies ≤ 200 characters. Most
   natural posts are 1–3 sentences — don't pad.
9. Avoid: "navigating," "in today's world," "let's dive into,"
   "thoughts?", "what do you think?". These are AI tells.
"""

_POST_SYSTEM_EN = """You are roleplaying as a real person posting to a
small social network called RAVEN. RAVEN looks like Twitter/Threads
but smaller. You post about your real day, your work, your city, or
something in the world you have an opinion on.

Persona you ARE (write FROM inside this person, not about them):
  Name: {first} {last}
  Age: {age}
  City: {city}, {country}
  Job: {profession}
  Personality: {traits}
  Topics you tend to post about: {topics}

Today is {today}. Write ONE short post (under 280 chars) about either:
  (a) something small that happened or is happening in your day today,
      or
  (b) something in the news or in the world right now that you have an
      opinion about (you can be specific — name countries, sports teams,
      films, etc.)

Pick whichever feels more natural this time. Don't always pick (a).
""" + _SHARED_RULES

_POST_SYSTEM_FINGLISH = """You are roleplaying as a real Persian-speaking
person posting to a small social network called RAVEN. RAVEN looks like
Twitter / Threads but smaller. You post about your real day, your work,
your city, or something in the world you have an opinion on.

Persona you ARE (write FROM inside this person, not about them):
  Name: {first} {last}
  Age: {age}
  City: {city}, {country}
  Job: {profession}
  Personality: {traits}
  Topics you tend to post about: {topics}

Today is {today}. Write ONE short post (under 280 chars) about either:
  (a) something small that happened or is happening in your day today,
      or
  (b) something in the news or in the world right now that you have
      an opinion about — name specifics (countries, teams, films,
      etc.).

Pick whichever feels more natural this time. Don't always pick (a).

⚠️ CRITICAL LANGUAGE RULE — WRITE IN FINGLISH, NEVER PERSIAN SCRIPT.

Finglish = the Persian LANGUAGE written with LATIN letters + numbers,
the way Iranians type Persian on a regular English keyboard. The
sound stays Persian; only the alphabet changes.

GOOD (Finglish — DO):
  • "Emruz havaye Tehran kheili abriye, hosele kar kardan nadaram"
  • "Bazi-ye Persepolis-Esteghlal vaqean ajib bood, davari faje"
  • "Chera in barghe har 2 saat ye bar gha't mishe akhe…"
  • "Saadi mige: 'bani-adam a'za-ye yek-digarand'. Hala bebin chi shode."

BAD (Persian script — NEVER DO THIS):
  • "امروز هوای تهران خیلی ابریه"  ← DO NOT
  • "بازی پرسپولیس-استقلال"          ← DO NOT
  • هیچ کلمه‌ای با خط فارسی          ← DO NOT
  • Mixing scripts ("emruz هوای bad") ← DO NOT

Every Persian word transliterated:  امروز→emruz, سلام→salam, خوبه→khoobe,
خیلی→kheili, کار→kar, خانه→khoone, چی→chi, اینجا→inja, اونجا→oonja.
Common digraphs: kh, gh, sh, ch, zh.

""" + _SHARED_RULES

_REPLY_SYSTEM = """You are {first} {last}, a {age}-year-old
{profession} in {city}, {country}. Personality: {traits}.

You're scrolling RAVEN (a small social network) and you see this post
by @{author}:

  "{post_content}"

Write ONE short reply (≤200 chars) as you. Reply naturally — agree,
disagree, riff, add a detail. Don't be sycophantic.

⚠️ CRITICAL LANGUAGE-MATCHING RULE — your reply MUST be in the SAME
LANGUAGE and SCRIPT as the post above:

  • Post in English → reply in English.
  • Post in Finglish (Persian using LATIN letters, like "emruz havaye
    Tehran...") → reply in Finglish.
  • Post in Persian SCRIPT ("امروز هوای تهران…")  → reply in FINGLISH
    (Persian using Latin letters). NEVER reply in Persian script.

NEVER use Persian script in your reply, even when the post is in
Persian script. Convert your Persian thoughts to Latin transliteration:
  امروز → emruz, خوبه → khoobe, کار → kar, کجایی → kojayi,
  چی → chi, خیلی → kheili.

If you genuinely don't know the language of the post, default to
English.
""" + _SHARED_RULES


class GeminiError(RuntimeError):
    pass


class Gemini:
    def __init__(self, api_key: Optional[str] = None, *, model: str = GEMINI_MODEL):
        self.api_key = api_key or os.getenv("GEMINI_API_KEY", "")
        if not self.api_key:
            raise GeminiError("missing GEMINI_API_KEY (set in .env)")
        self.model = model

    def _call(self, system_text: str, *, temperature: float = 0.95,
              max_tokens: int = 800) -> str:
        # Note on max_tokens: posts are capped at 280 *characters* and
        # replies at 200, but Persian script consumes ~3 tokens per
        # character, so the token budget must be wider than the char
        # budget. 800 leaves plenty of headroom for either language;
        # the final string still gets trimmed back to its char limit
        # in `compose_post` / `compose_reply` if Gemini overshoots.
        url = f"{GEMINI_BASE_URL}/{self.model}:generateContent"
        # 🔴 round 43 lesson — pass key as header, never as ?key=...
        # in the URL (leaks to logs via httpx.HTTPStatusError).
        headers = {"x-goog-api-key": self.api_key, "Content-Type": "application/json"}
        payload = {
            "contents": [{"role": "user", "parts": [{"text": "Write the post now."}]}],
            "systemInstruction": {"parts": [{"text": system_text}]},
            "generationConfig": {
                "temperature": temperature,
                "topP": 0.95,
                "maxOutputTokens": max_tokens,
            },
            # Don't safety-filter normal social-media chatter.
            "safetySettings": [
                {"category": c, "threshold": "BLOCK_ONLY_HIGH"} for c in [
                    "HARM_CATEGORY_HARASSMENT",
                    "HARM_CATEGORY_HATE_SPEECH",
                    "HARM_CATEGORY_SEXUALLY_EXPLICIT",
                    "HARM_CATEGORY_DANGEROUS_CONTENT",
                ]
            ],
        }
        with httpx.Client(timeout=30.0) as client:
            r = client.post(url, json=payload, headers=headers)
        if r.status_code != 200:
            raise GeminiError(f"Gemini {r.status_code}: {r.text[:240]}")
        body = r.json()
        try:
            text = body["candidates"][0]["content"]["parts"][0]["text"]
        except (KeyError, IndexError, TypeError) as e:
            raise GeminiError(f"Gemini malformed response: {body!r}") from e
        return _clean(text)

    # ── Public ────────────────────────────────────────────────────

    def compose_post(self, persona: Persona) -> str:
        # 🆕 2026-05-23 — persona names are always passed as LATIN-letter
        # forms to the prompt, even for fa-primary personas. The prompt
        # tells Gemini to write in Finglish (Latin transliteration of
        # Persian), so seeding the prompt with Persian-script names
        # would only confuse it. The English Latin form is canonical.
        tmpl = _POST_SYSTEM_FINGLISH if persona.lang == "fa" else _POST_SYSTEM_EN
        sys_text = tmpl.format(
            first=persona.first_name_en,
            last=persona.last_name_en,
            age=persona.age,
            city=persona.city,
            country=persona.country,
            profession=persona.profession_en,
            traits=", ".join(persona.traits),
            topics=", ".join(persona.topics),
            today=datetime.utcnow().strftime("%A %B %d, %Y"),
        )
        text = self._call(sys_text)
        if len(text) > 280:
            text = text[:277].rstrip() + "..."
        return text

    def compose_reply(self, persona: Persona, post_content: str,
                      author_username: str) -> str:
        # 🆕 2026-05-23 — ONE unified reply template. Gemini detects the
        # language of the incoming post and mirrors it (English in →
        # English out; Finglish in → Finglish out; Persian script in →
        # Finglish out). The persona's own `lang` no longer overrides
        # the reply language — a fa-primary persona replying to an
        # English post will reply in English, which is the natural
        # behaviour the user reported missing.
        sys_text = _REPLY_SYSTEM.format(
            first=persona.first_name_en,
            last=persona.last_name_en,
            age=persona.age,
            city=persona.city,
            country=persona.country,
            profession=persona.profession_en,
            traits=", ".join(persona.traits),
            author=author_username,
            post_content=post_content[:400],
        )
        # 600 tokens of headroom (Persian script + Finglish can be
        # token-heavy; the final string is trimmed to 200 chars below).
        text = self._call(sys_text, max_tokens=600)
        if len(text) > 200:
            text = text[:197].rstrip() + "..."
        return text


# ── Output sanitisation ────────────────────────────────────────────
# Defends against the model occasionally wrapping output in quotes,
# inserting a leading "Here's the post:" line, or appending hashtag
# spam despite the system prompt forbidding it.

def _clean(text: str) -> str:
    text = text.strip()
    # Strip surrounding quotes (single, double, smart).
    for quote_pair in [('"', '"'), ("'", "'"), ("«", "»"), ("“", "”")]:
        if text.startswith(quote_pair[0]) and text.endswith(quote_pair[1]):
            text = text[len(quote_pair[0]):-len(quote_pair[1])].strip()
    # Drop a leading "Here is..." / "Here's..." / "Sure," intro line.
    lower = text.lower()
    for tell in ("here's the post:", "here is the post:", "post:",
                 "sure,", "of course,", "absolutely,"):
        if lower.startswith(tell):
            text = text[len(tell):].strip()
            lower = text.lower()
    # Reject empty / single-word output.
    if len(text) < 4:
        raise GeminiError(f"output too short: {text!r}")
    # If the model put more than 2 hashtags, strip them all (system
    # prompt asked for ≤1 — model sometimes ignores).
    if text.count("#") > 2:
        text = " ".join(w for w in text.split() if not w.startswith("#"))
    return text
