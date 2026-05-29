# RAVEN Simulation — 20 personas living on the network

A scheduled "agent" that registers 20 fully-defined synthetic users
on RAVEN and drives them via **Gemini 2.5 Flash** so each one posts,
likes, replies, and views in voice. Every persona acts at most once
per **15 hours** so the feed feels paced and human, not bot-storm.

## What it does (one tick)

```
┌────────────────────────────────────────────────────────────────┐
│ 1. ensure 20 personas have state rows                         │
│ 2. bootstrap up to 2 unregistered personas via /auth/register │
│ 3. find personas due to act (last_action_at + 15h ≤ now)      │
│ 4. pick up to 3 to act this tick                              │
│ 5. for each acting persona:                                   │
│    a. /auth/login → fresh JWT                                 │
│    b. /posts/feed → record /posts/{id}/view on unseen posts   │
│    c. roll weighted action: post / reply / like / view-only   │
│    d. execute action via Gemini + RAVEN API                   │
│    e. stamp last_action_at                                    │
└────────────────────────────────────────────────────────────────┘
```

Tick cadence is **every 30 minutes** by default (set in
`run-loop.sh::INTERVAL_SECONDS`). Over the first 5 hours all 20
personas register; after that, normal rhythm = ~1.3 actions per hour
spread across the 20.

## The 20 personas

Hand-curated for diversity across language (14 EN-primary,
6 FA-primary), age (21–52), city (Tehran, Toronto, Berlin, London,
Mexico City, Dublin, Osaka, Shiraz, Budapest, Naples, Chicago,
Beirut, Esfahan, Glasgow, Bangalore, Mashhad, Lisbon, Tabriz,
Vienna), and profession (designer, journalist, barista, civil
engineer, dentist, trainer, illustrator, lit teacher, finance
analyst, sous chef, music producer, ER nurse, photographer, urban
gardener, indie gamedev, climate researcher, taxi driver, dance
teacher, CS student, history teacher).

Each persona carries:
- a real first + last name
- age, city, country
- profession (in both EN and FA)
- 3–6 personality traits
- 4–5 typical topics they post about
- a primary language (`en` / `fa`)
- per-action weights (post / reply / like / view)

See `personas.py` for the full table.

## Files

| File | Purpose |
|---|---|
| `personas.py` | The 20 persona definitions |
| `state.py`    | SQLite-backed per-persona state (passwords, counters, seen-post log) |
| `api.py`      | RAVEN HTTP client (register / login / feed / post / like / view / comment) |
| `ai.py`       | Gemini-driven content generation, FA + EN prompt templates |
| `main.py`     | Orchestrator entry point (`python -m simulation`) |
| `run-loop.sh` | Daemon wrapper (called by launchd) |
| `.env`        | Secrets (GEMINI_API_KEY + RAVEN_BASE_URL) — NEVER commit |

## Setup (one time)

```bash
cd /Users/ahmd/hybrid_messenger/simulation
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
# create .env with GEMINI_API_KEY=AIza... and RAVEN_BASE_URL=...
```

## Run

```bash
# one tick, exit
python -m simulation -v

# dry-run (Gemini fires, no /create POST)
python -m simulation --dry-run

# state dashboard
python -m simulation --status

# continuous (foreground)
./run-loop.sh

# continuous (launchd, recommended)
launchctl load ~/Library/LaunchAgents/com.ravenmessenger.simulation.plist
tail -f /tmp/raven-simulation.log
```

## Cost

Per Gemini call ≈ **$0.0005** at 2.5-flash pricing. With 20 personas
× ~1.6 actions/day = ~32 calls/day = **~$0.5/month**. Often free-tier
covers it outright.

## Stopping

```bash
launchctl unload ~/Library/LaunchAgents/com.ravenmessenger.simulation.plist
```

State (`simulation_state.sqlite`) survives so personas resume cleanly
the next time the daemon starts.
