# Secret History Scan Report

- Generated: `2026-08-12T16:04:04Z` (triage note updated this implementation wave)
- Branch: `feature/raven-serverless-v1`
- HEAD: see latest local commit on branch
- Script: `scripts/secret_history_scan.sh`
- Hit rows: **5** (pattern class only — values redacted)
- CI hard-fail classes present: **0** (1=yes)

## Policy

- Findings are flagged for **HUMAN** rotation / history rewrite decisions.
- This script does **not** rotate credentials or rewrite git history.
- Public test vectors / shared-vectors hex are excluded from path scope.
- `.env.example` / README placeholder assignments are reported but do not hard-fail CI.

## Findings (actionable triage)

| Class | Path | Line | Action | Triage |
|-------|------|------|--------|--------|
| `ENV_SECRET_ASSIGNMENT` | `news_bot/README.md` | 84 | human_review | Fixture / docs example — not a live secret |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 36 | human_review | Placeholder template — expected |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 51 | human_review | Placeholder template — expected |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 87 | human_review | Placeholder template — expected |
| `ENV_SECRET_ASSIGNMENT` | `server/setup-resend.sh` | 27 | human_review | Setup script placeholder — human confirm no live key |

## Human follow-ups (BLOCKED_HUMAN if real secrets)

1. Review each row; ignore intentional fixtures (current set looks like examples).
2. If a live credential is confirmed: rotate at the provider, then decide on history purge.
3. Do not commit `.env` / key material; keep gitignored.
4. Canonical report path: this file. `node/SECRET_SCAN_REPORT_*.txt` is a pointer stub only.

## CI

`--ci` exits non-zero only for hard-fail classes (PEM/cloud tokens/untracked secret files / non-example ENV assignments).
