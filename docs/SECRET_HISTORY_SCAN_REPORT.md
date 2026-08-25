# Secret History Scan Report

- Generated: `2026-08-13T13:23:18Z`
- Branch: `feature/raven-serverless-v1`
- HEAD: `53b05a8`
- Script: `scripts/secret_history_scan.sh`
- Hit rows: **3** (pattern class only — values redacted)
- Historical blobs examined: **2535** (all reachable refs)
- CI hard-fail classes present: **0** (1=yes)

## Policy

- Findings are flagged for **HUMAN** rotation / history rewrite decisions.
- Historical findings use `history:path@blob-id`; no matching value is emitted.
- This script does **not** rotate credentials or rewrite git history.
- Public test vectors / shared-vectors hex are excluded from path scope.
- Environment-style assignments are always reported for human review but do not hard-fail CI; PEM/cloud-token patterns and untracked secret files do.

## Findings

| Class | Path | Line | Action |
|-------|------|------|--------|
| `ENV_SECRET_ASSIGNMENT` | `history:news_bot/README.md@6f99d558b254` | 84 | human_review |
| `ENV_SECRET_ASSIGNMENT` | `history:server/.env.example@4387e6e4ba72` | 36 | human_review |
| `ENV_SECRET_ASSIGNMENT` | `history:server/setup-resend.sh@bfc2b9f760c0` | 27 | human_review |

## Human follow-ups (BLOCKED_HUMAN if real secrets)

1. Review each row; ignore intentional fixtures.
2. If a live credential is confirmed: rotate at the provider, then decide on history purge.
3. Do not commit `.env` / key material; keep gitignored.

## CI

`--ci` exits non-zero only for hard-fail classes (PEM/cloud-token patterns or untracked secret files). Environment-style assignments remain non-blocking human-review findings.
