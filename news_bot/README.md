# RAVEN News Bot

A scheduled "agent" that posts the day's most important political news
into RAVEN, under a regular verified account. Designed to look like
a wire service — short headline, 2-3 sentence summary, source name +
direct link.

**Powered by Google Gemini 2.5 Flash** (Google's cheapest current-gen
model with tool use). A typical run costs well under $0.01 — and the
free tier covers a healthy chunk of the daily volume outright.

## What it does (one cycle)

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. fetcher.py  → fetches ~10 RSS feeds in parallel              │
│ 2. dedup.py    → drops articles already posted (SQLite store)   │
│ 3. ranker.py   → Gemini 2.5 Flash scores + summarizes the rest  │
│ 4. poster.py   → POSTs each top pick to RAVEN /api/posts/create │
│ 5. dedup.py    → marks each published URL as seen               │
└──────────────────────────────────────────────────────────────────┘
```

The bot is **single-shot**: one cron tick = one cycle. Idle when
there's nothing fresh.

## One-time setup

### 1. Create the bot's RAVEN account

The bot is a normal RAVEN user — sign up via the iOS / Mac app:

- **Display name:** `Raven News`
- **Username:** `raven_news` (or whatever the app accepts)
- **Password:** a strong one — this is a service account.

After signup, update the user row so the display name renders as
"Raven News" with capitalization and the space preserved (the iOS
sign-up flow asks for `first_name` + `last_name`; you can set
`first_name=Raven` and `last_name=News` directly):

```sql
UPDATE users
SET first_name = 'Raven', last_name = 'News'
WHERE username = 'raven_news';
```

### 2. Verify it (optional but recommended)

For the blue tick, an operator flips
`users.is_verified = TRUE`
and sets `verified_at` to NOW() in the database:

```sql
UPDATE users
SET is_verified = TRUE, verified_at = NOW()
WHERE username = 'raven_news';
```

The chat / feed UI picks up the tick on the next refresh.

### 3. Get a Gemini API key

Create one at <https://aistudio.google.com/apikey>. The free tier
already covers a meaningful slice of the daily volume on Flash; add a
billing-enabled project if you want the paid tier's higher RPM limits
and implicit-cache discounts. Note your key — it starts with `AIza...`.

### 4. Install dependencies

```bash
cd /Users/ahmd/hybrid_messenger/news_bot
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 5. Configure secrets

Create a `.env` next to `main.py` (NEVER commit this):

```bash
# Google Gemini
GEMINI_API_KEY=AIza...
GEMINI_MODEL=gemini-2.5-flash

# RAVEN bot creds
RAVEN_BASE_URL=https://raven-server-516053629173.europe-west1.run.app
RAVEN_BOT_USERNAME=raven_news
RAVEN_BOT_PASSWORD=<strong password>

# Tuning — defaults match the agreed editorial cadence
MAX_POSTS_PER_RUN=5
MIN_IMPORTANCE_SCORE=6
OUTPUT_LANGUAGE=en               # English by default; flip to `fa` for Persian
DEDUP_DB_PATH=./news_bot_seen.sqlite
```

`MAX_POSTS_PER_RUN=5` + 50-minute cadence = up to ~144 posts/day in the
worst case. Tune lower if the channel feels noisy.

## Running it

### Dry run (no actual posts)

```bash
source .venv/bin/activate
python -m news_bot.main --dry-run -v
```

You'll see the rendered picks in the terminal. Nothing is posted, the
dedup store isn't touched. Use this to validate prompts + sources.

### Live run

```bash
python -m news_bot.main -v
```

### Production schedule — every 50 minutes

Cron can't cleanly express "every 50 minutes" (its minute field only
accepts intervals that evenly divide 60), so the bot ships with a
small daemon wrapper that sleeps between ticks:

```bash
# Foreground (test):
./run-loop.sh

# Detached background, log to file:
nohup ./run-loop.sh > /tmp/raven-news-bot.log 2>&1 &
echo $! > /tmp/raven-news-bot.pid

# Stop later:
kill "$(cat /tmp/raven-news-bot.pid)"
```

The default interval is **3000 seconds (50 min)**. Override via
`INTERVAL_SECONDS=1800 ./run-loop.sh` (30 min) if you want more
coverage.

#### Persistent service (recommended for production)

**macOS — launchd:** drop this plist at
`~/Library/LaunchAgents/com.ravenmessenger.newsbot.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.ravenmessenger.newsbot</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/ahmd/hybrid_messenger/news_bot/run-loop.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/raven-news-bot.log</string>
    <key>StandardErrorPath</key><string>/tmp/raven-news-bot.log</string>
</dict>
</plist>
```

Then: `launchctl load ~/Library/LaunchAgents/com.ravenmessenger.newsbot.plist`.

**Linux — systemd:** drop a unit at
`/etc/systemd/system/raven-news-bot.service`:

```ini
[Unit]
Description=RAVEN news bot (50-min cycle)
After=network-online.target

[Service]
ExecStart=/home/ravenbot/news_bot/run-loop.sh
Restart=always
RestartSec=30
User=ravenbot

[Install]
WantedBy=multi-user.target
```

Then: `sudo systemctl enable --now raven-news-bot`.

#### One-shot cron (legacy, if you must)

If you only have cron available and don't care about exact 50-min
spacing, the closest is "every 50th minute of the hour" (fires at :00,
:50, :40, :30, :20, :10 — i.e. 50-min gaps with one 10-min gap per
hour):

```bash
crontab -e
# add:
*/10 * * * * /Users/ahmd/hybrid_messenger/news_bot/run.sh >> /tmp/raven-news-bot.log 2>&1
```

But the daemon `run-loop.sh` is the recommended path.

## Editorial behavior

The Gemini system instruction in `ranker.py` enforces:

- **Persian output** by default (`OUTPUT_LANGUAGE=fa`). Source headlines
  in English / Arabic get translated faithfully (names preserved).
- **Neutrality** — no editorializing, no opinion picks.
- **Importance rubric** — 1-10 scale, only posts with score ≥
  `MIN_IMPORTANCE_SCORE` ship. Default is 7, which roughly maps to
  "would make the front page of an English-language broadsheet".
- **Source attribution** — every post ends with `🔗 <source name>`
  and the original URL.
- **Dedup** — same URL across feeds, two stories on the same event,
  re-runs within an hour: all suppressed.

## Cost model

Per cycle (rough numbers, current Gemini 2.5 Flash pricing —
$0.075 / 1M input tok, $0.30 / 1M output tok on the paid tier):

| | Tokens | $ at gemini-2.5-flash pricing |
|---|---|---|
| Input (articles JSON) | ~8,000 | ~$0.0006 |
| Input (system instruction) | ~1,000 | ~$0.00008 |
| Output (5 picks × ~300 tok) | ~1,500 | ~$0.00045 |
| **Total per run** | | **~$0.0011** |

50-minute loop = ~28 runs/day = **~$1 / month** at full load. Many
ticks short-circuit on the SQLite dedup check before calling the
model, so real spend lands closer to **$0.50 / month**. The Gemini
free tier may absorb the entire bill outright if you stay under its
RPM / TPM limits — check the dashboard at
<https://aistudio.google.com/apikey>.

## File layout

| File | Purpose |
|---|---|
| `config.py` | Loads env vars into a typed `Config` dataclass |
| `sources.py` | Curated RSS feed list (mix of Farsi + English) |
| `fetcher.py` | Parallel feed fetcher (feedparser) |
| `dedup.py` | SQLite "already posted" store |
| `ranker.py` | Gemini 2.5 Flash with forced function calling (`tool_config.mode=ANY`) |
| `poster.py` | RAVEN login + `/api/posts/create` client |
| `main.py` | Orchestrator (entry point: `python -m news_bot.main`) |
| `run.sh` | Cron-friendly wrapper that sources `.env` + handles venv |
| `requirements.txt` | Python deps |

## Troubleshooting

**"missing required env var GEMINI_API_KEY"** — `.env` isn't being
loaded. Either source it manually (`set -a; source .env; set +a`) or
use `run.sh`, which does that for you.

**"PermissionDenied: API key not valid"** — the key is wrong or has
been revoked. Generate a fresh one at
<https://aistudio.google.com/apikey> and update `.env`.

**"ResourceExhausted: quota exceeded"** — you hit a free-tier RPM /
RPD limit. Either wait, switch to a paid project, or lengthen
`INTERVAL_SECONDS` in `run-loop.sh`.

**"login failed: 401"** — bot credentials wrong, or the account was
banned / password-reset. Try logging in via the app first.

**"no picks met the importance threshold — quiet day"** — totally
normal at off-peak hours. Try lowering `MIN_IMPORTANCE_SCORE` to 6 if
your channel feels too quiet.

**Same article keeps reappearing** — the dedup DB lives at
`DEDUP_DB_PATH`. Check the path exists and is writable from the cron
context. Run `sqlite3 news_bot_seen.sqlite "SELECT COUNT(*) FROM
seen_articles"` to inspect.

**Feed errors in logs** — individual feeds occasionally 404 or change
schema. The fetcher tolerates per-feed failures silently. If a feed
is permanently dead, remove it from `sources.py`.

## What's NOT here (yet)

- **Image / video attachments.** Posts are text + link only. Adding
  an OpenGraph image would mean parsing each article HTML.
- **Localization beyond Farsi / English / Arabic.** The system prompt
  handles those three; for others, change the language map in
  `ranker.py:_system_prompt`.
- **Sentiment / partisan-balance accounting.** The rubric is neutral
  but the *source set* can lean one way if you load it that way.
  Audit `sources.py` for editorial balance.
- **Multi-channel publishing** (e.g. group chats vs. public feed).
  Today every post goes to the global feed via `/api/posts/create`.
  A group-targeted version would call `/api/groups/{id}/messages`.

PRs welcome.
