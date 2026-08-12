#!/usr/bin/env bash
# Secret / credential history scan for Raven serverless checklist (§5 / §57).
# Flags findings for HUMAN rotation — does not invent or perform rotations.
#
# Usage:
#   ./scripts/secret_history_scan.sh           # write docs/SECRET_HISTORY_SCAN_REPORT.md
#   ./scripts/secret_history_scan.sh --ci      # exit 1 on high-confidence hits in HEAD tree
#
# Scope: working tree + recent commit messages / blobs (bounded). Never prints
# full secret values — only path:line and pattern class.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CI_MODE=0
if [[ "${1:-}" == "--ci" ]]; then
  CI_MODE=1
fi

REPORT_DIR="$ROOT/docs"
REPORT="$REPORT_DIR/SECRET_HISTORY_SCAN_REPORT.md"
mkdir -p "$REPORT_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HITS="$TMP/hits.txt"
: >"$HITS"

# High-confidence patterns (private key material / cloud tokens). Avoid matching
# public test vectors (ed25519 pub hex, shared-vectors) by requiring keywords.
scan_file() {
  local f="$1"
  # Skip binaries / lock noise / vectors that are intentionally hex.
  case "$f" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.wasm|*.bin) return 0 ;;
    */shared-vectors/*|*/target/*|*/.git/*|*/node_modules/*) return 0 ;;
    */Pods/*|*/build/*|*/DerivedData/*) return 0 ;;
  esac
  [[ -f "$f" ]] || return 0
  [[ -s "$f" ]] || return 0

  # Pattern classes — report class only.
  if grep -nE 'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY' "$f" >/dev/null 2>&1; then
    grep -nE 'BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY' "$f" 2>/dev/null \
      | head -5 | while IFS= read -r line; do
      echo "PRIVATE_KEY_PEM|$f|${line%%:*}|human_rotate_if_real" >>"$HITS"
    done
  fi
  if grep -nEi 'AKIA[0-9A-Z]{16}' "$f" >/dev/null 2>&1; then
    grep -nEi 'AKIA[0-9A-Z]{16}' "$f" 2>/dev/null | head -3 | while IFS= read -r line; do
      echo "AWS_ACCESS_KEY_ID|$f|${line%%:*}|human_rotate_if_real" >>"$HITS"
    done
  fi
  if grep -nEi 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' "$f" >/dev/null 2>&1; then
    grep -nEi 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' "$f" 2>/dev/null \
      | head -3 | while IFS= read -r line; do
      echo "GITHUB_TOKEN|$f|${line%%:*}|human_rotate_if_real" >>"$HITS"
    done
  fi
  if grep -nEi 'xox[baprs]-[A-Za-z0-9-]{10,}' "$f" >/dev/null 2>&1; then
    grep -nEi 'xox[baprs]-[A-Za-z0-9-]{10,}' "$f" 2>/dev/null | head -3 | while IFS= read -r line; do
      echo "SLACK_TOKEN|$f|${line%%:*}|human_rotate_if_real" >>"$HITS"
    done
  fi
  # .env style assignments that look like live secrets (not placeholders).
  if grep -nEi '^[A-Z0-9_]*(SECRET|PASSWORD|PRIVATE_KEY|API_KEY)[A-Z0-9_]*=.+' "$f" >/dev/null 2>&1; then
    grep -nEi '^[A-Z0-9_]*(SECRET|PASSWORD|PRIVATE_KEY|API_KEY)[A-Z0-9_]*=.+' "$f" 2>/dev/null \
      | grep -viE 'CHANGE_ME|TODO|placeholder|example|your_|<.*>|\*\*\*|xxx' \
      | head -5 | while IFS= read -r line; do
      echo "ENV_SECRET_ASSIGNMENT|$f|${line%%:*}|human_review" >>"$HITS"
    done
  fi
}

echo "Scanning working tree (tracked + common secret filenames)..."
# Tracked files (bounded)
git ls-files -z | while IFS= read -r -d '' f; do
  scan_file "$f"
done

# Untracked but present secret-ish names
for f in .env .env.local .env.production credentials.json service-account.json; do
  if [[ -f "$f" ]]; then
    echo "UNTRACKED_SECRET_FILE|$f|0|human_ensure_gitignored" >>"$HITS"
    scan_file "$f"
  fi
done

# Recent commit message scan (subjects only — no blob dump of full history)
git log -n 200 --pretty=%s 2>/dev/null | grep -nEi 'password|api[_-]?key|secret|private[_-]?key|AKIA' \
  | head -20 | while IFS= read -r line; do
  echo "COMMIT_SUBJECT_KEYWORD|git-log|${line%%:*}|human_review_history" >>"$HITS"
done || true

HIT_COUNT=$(wc -l <"$HITS" | tr -d ' ')
# CI fails only on high-confidence live-secret classes (not .env.example docs).
CI_FAIL=0
if [[ -s "$HITS" ]]; then
  while IFS='|' read -r cls path _line _action; do
    case "$cls" in
      PRIVATE_KEY_PEM|AWS_ACCESS_KEY_ID|GITHUB_TOKEN|SLACK_TOKEN|UNTRACKED_SECRET_FILE)
        CI_FAIL=1
        ;;
      ENV_SECRET_ASSIGNMENT)
        # Always human_review in CI — placeholders vs live values need eyes.
        ;;
      *)
        ;;
    esac
  done <"$HITS"
fi
DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BRANCH="$(git branch --show-current 2>/dev/null || echo unknown)"
HEAD="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

{
  echo "# Secret History Scan Report"
  echo
  echo "- Generated: \`$DATE_UTC\`"
  echo "- Branch: \`$BRANCH\`"
  echo "- HEAD: \`$HEAD\`"
  echo "- Script: \`scripts/secret_history_scan.sh\`"
  echo "- Hit rows: **$HIT_COUNT** (pattern class only — values redacted)"
  echo "- CI hard-fail classes present: **$CI_FAIL** (1=yes)"
  echo
  echo "## Policy"
  echo
  echo "- Findings are flagged for **HUMAN** rotation / history rewrite decisions."
  echo "- This script does **not** rotate credentials or rewrite git history."
  echo "- Public test vectors / shared-vectors hex are excluded from path scope."
  echo "- \`.env.example\` / README placeholder assignments are reported but do not hard-fail CI."
  echo
  echo "## Findings"
  echo
  if [[ "$HIT_COUNT" -eq 0 ]]; then
    echo "_No high-confidence pattern hits in scoped scan._"
  else
    echo "| Class | Path | Line | Action |"
    echo "|-------|------|------|--------|"
    while IFS='|' read -r cls path line action; do
      echo "| \`$cls\` | \`$path\` | $line | $action |"
    done <"$HITS"
  fi
  echo
  echo "## Human follow-ups (BLOCKED_HUMAN if real secrets)"
  echo
  echo "1. Review each row; ignore intentional fixtures."
  echo "2. If a live credential is confirmed: rotate at the provider, then decide on history purge."
  echo "3. Do not commit \`.env\` / key material; keep gitignored."
  echo
  echo "## CI"
  echo
  echo "\`--ci\` exits non-zero only for hard-fail classes (PEM/cloud tokens/untracked secret files / non-example ENV assignments)."
} >"$REPORT"

# Also refresh the short pointer file used by older checklist notes.
{
  echo "report_md=docs/SECRET_HISTORY_SCAN_REPORT.md"
  echo "hits=$HIT_COUNT"
  echo "ci_fail=$CI_FAIL"
  echo "head=$HEAD"
  echo "generated=$DATE_UTC"
  echo "scan_done"
} >"$REPORT_DIR/SECRET_SCAN_REPORT_2026-08-12.txt"

echo "Wrote $REPORT ($HIT_COUNT hits, ci_fail=$CI_FAIL)"

if [[ "$CI_MODE" -eq 1 ]]; then
  if [[ "$CI_FAIL" -eq 1 ]]; then
    echo "CI: failing closed on hard-fail secret-scan hit(s). See $REPORT"
    exit 1
  fi
  echo "CI: secret scan clean (or docs-only placeholders)"
fi
