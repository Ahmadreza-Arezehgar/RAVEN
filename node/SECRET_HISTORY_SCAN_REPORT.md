# Secret History Scan Report

- Generated: `2026-08-12T16:19:32Z` (triage table refreshed this wave)
- Branch: `feature/raven-serverless-v1`
- HEAD: see latest local commit on branch
- Script: `scripts/secret_history_scan.sh`
- Hit rows: **5** (pattern class only — values redacted)
- CI hard-fail classes present: **0**

## Policy

- Findings are flagged for **HUMAN** rotation / history rewrite decisions.
- This script does **not** rotate credentials or rewrite git history.
- Public test vectors / shared-vectors hex are excluded from path scope.
- `.env.example` / README placeholder assignments are reported but do not hard-fail CI.

## Rotate-or-false-positive table

| Class | Path | Line | Verdict | Action |
|-------|------|------|---------|--------|
| `ENV_SECRET_ASSIGNMENT` | `news_bot/README.md` | 84 | **FALSE_POSITIVE** (docs fixture) | none — keep as example |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 36 | **FALSE_POSITIVE** (placeholder template) | none — expected in `.env.example` |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 51 | **FALSE_POSITIVE** (placeholder template) | none |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 87 | **FALSE_POSITIVE** (placeholder template) | none |
| `ENV_SECRET_ASSIGNMENT` | `server/setup-resend.sh` | 27 | **HUMAN_CONFIRM** | confirm no live Resend key; if live → **ROTATE** at provider + purge history |

## Summary

| Verdict | Count |
|---------|------:|
| FALSE_POSITIVE | 4 |
| HUMAN_CONFIRM (rotate if real) | 1 |
| Confirmed live secret in tree | **0** |

## Human follow-ups (BLOCKED_HUMAN only if live)

1. Spot-check `server/setup-resend.sh:27` — if a real key was ever used, rotate at Resend and consider history purge.
2. Do not commit `.env` / key material; keep gitignored.
3. Canonical report: this file. `node/SECRET_SCAN_REPORT_*.txt` is a pointer stub only.

## CI

`--ci` exits non-zero only for hard-fail classes (PEM/cloud tokens/untracked secret files / non-example ENV assignments).
