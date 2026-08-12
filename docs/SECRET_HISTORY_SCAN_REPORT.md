# Secret History Scan Report

- Generated: `2026-08-12T16:04:04Z`
- Branch: `feature/raven-serverless-v1`
- HEAD: `679e5e8`
- Script: `scripts/secret_history_scan.sh`
- Hit rows: **5** (pattern class only — values redacted)
- CI hard-fail classes present: **0** (1=yes)

## Policy

- Findings are flagged for **HUMAN** rotation / history rewrite decisions.
- This script does **not** rotate credentials or rewrite git history.
- Public test vectors / shared-vectors hex are excluded from path scope.
- `.env.example` / README placeholder assignments are reported but do not hard-fail CI.

## Findings

| Class | Path | Line | Action |
|-------|------|------|--------|
| `ENV_SECRET_ASSIGNMENT` | `news_bot/README.md` | 84 | human_review |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 36 | human_review |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 51 | human_review |
| `ENV_SECRET_ASSIGNMENT` | `server/.env.example` | 87 | human_review |
| `ENV_SECRET_ASSIGNMENT` | `server/setup-resend.sh` | 27 | human_review |

## Human follow-ups (BLOCKED_HUMAN if real secrets)

1. Review each row; ignore intentional fixtures.
2. If a live credential is confirmed: rotate at the provider, then decide on history purge.
3. Do not commit `.env` / key material; keep gitignored.

## CI

`--ci` exits non-zero only for hard-fail classes (PEM/cloud tokens/untracked secret files / non-example ENV assignments).
