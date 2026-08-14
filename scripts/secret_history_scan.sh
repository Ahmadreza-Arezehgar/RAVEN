#!/usr/bin/env bash
# Secret / credential history scan for Raven serverless checklist (§5 / §57).
# Flags findings for HUMAN rotation — does not invent or perform rotations.
#
# Usage:
#   ./scripts/secret_history_scan.sh           # write docs/SECRET_HISTORY_SCAN_REPORT.md
#   ./scripts/secret_history_scan.sh --ci      # exit 1 on hard-fail tree/history classes
#
# Scope: working tree + every blob reachable from every Git ref. Never prints
# full secret values — only path:line, pattern class, and a shortened blob ID.
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
HISTORY_BLOB_FILE="$TMP/history-blob"
HISTORY_OBJECTS="$TMP/history-objects.txt"
HISTORY_MATCHES="$TMP/history-matches.txt"
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
  local size
  size=$(wc -c <"$f" 2>/dev/null || echo 0)
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  (( size <= 2097152 )) || return 0
  LC_ALL=C grep -Iq . "$f" || return 0

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

# Scan one historical Git blob without checking it out and without ever
# printing the matching line. `display_path` is metadata from
# `git rev-list --objects --all`; the shortened object ID makes a finding
# reviewable even when the path was later renamed or deleted.
scan_history_blob() {
  local oid="$1"
  local display_path="$2"
  local size="$3"
  local short_oid="${oid:0:12}"
  local finding_path="history:${display_path}@${short_oid}"

  case "$display_path" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.wasm|*.bin) return 0 ;;
    */shared-vectors/*|*/target/*|*/node_modules/*|*/Pods/*|*/build/*|*/DerivedData/*) return 0 ;;
  esac

  # Ignore large/binary blobs before regex work. The size guard is a resource
  # bound, not a security exemption: source/config credentials should be far
  # below it, while archived media and generated databases should not consume
  # unbounded scanner memory/CPU.
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  (( size > 0 && size <= 2097152 )) || return 0
  git cat-file blob "$oid" >"$HISTORY_BLOB_FILE" 2>/dev/null || return 0
  LC_ALL=C grep -Iq . "$HISTORY_BLOB_FILE" || return 0

  # One parser pass per blob. It emits only class + line number + action;
  # matching source text never leaves the temporary file.
  awk '
    {
      upper = toupper($0)
      lower = tolower($0)
      if (!pem && upper ~ /BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY/) {
        print "PRIVATE_KEY_PEM|" NR "|human_rotate_if_real"; pem = 1
      }
      if (!aws && upper ~ /AKIA[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]/) {
        print "AWS_ACCESS_KEY_ID|" NR "|human_rotate_if_real"; aws = 1
      }
      if (!github && (lower ~ /ghp_[a-z0-9]{20,}/ || lower ~ /github_pat_[a-z0-9_]{20,}/)) {
        print "GITHUB_TOKEN|" NR "|human_rotate_if_real"; github = 1
      }
      if (!slack && lower ~ /xox[baprs]-[a-z0-9-]{10,}/) {
        print "SLACK_TOKEN|" NR "|human_rotate_if_real"; slack = 1
      }
      if (!envsecret && upper ~ /^[A-Z0-9_]*(SECRET|PASSWORD|PRIVATE_KEY|API_KEY)[A-Z0-9_]*=.+/ &&
          lower !~ /(change_me|todo|placeholder|example|your_|<.*>|\*\*\*|xxx)/) {
        print "ENV_SECRET_ASSIGNMENT|" NR "|human_review"; envsecret = 1
      }
    }
  ' "$HISTORY_BLOB_FILE" >"$HISTORY_MATCHES"

  while IFS='|' read -r cls line action; do
    [[ -n "${cls:-}" ]] || continue
    echo "$cls|$finding_path|${line:-0}|$action" >>"$HITS"
  done <"$HISTORY_MATCHES"
}

echo "Scanning working tree (tracked + common secret filenames)..."
# Tracked files (bounded)
git ls-files -z | while IFS= read -r -d '' f; do
  scan_file "$f"
done

# Include present untracked and ignored working files too. This catches a
# credential in a correctly-gitignored local deploy helper without exposing
# its value or pretending it was committed. Generated/build trees are skipped
# by `scan_file`; CI checkouts normally have no such local files.
git ls-files --others --exclude-standard -z | while IFS= read -r -d '' f; do
  scan_file "$f"
done
git ls-files --others --ignored --exclude-standard -z | while IFS= read -r -d '' f; do
  scan_file "$f"
done

echo "Scanning every reachable Git-history blob (values remain redacted)..."
HISTORY_BLOBS_SCANNED=0
git rev-list --objects --all \
  | git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize) %(rest)' \
  >"$HISTORY_OBJECTS"
while IFS=' ' read -r oid object_type object_size path; do
  [[ -n "${path:-}" ]] || continue
  [[ "$object_type" == "blob" ]] || continue
  HISTORY_BLOBS_SCANNED=$((HISTORY_BLOBS_SCANNED + 1))
  scan_history_blob "$oid" "$path" "$object_size"
done <"$HISTORY_OBJECTS"

# Untracked but present secret-ish names (also assign the hard-fail filename
# class so an accidental `.env` never gets downgraded to pattern-only review).
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
  echo "- Historical blobs examined: **$HISTORY_BLOBS_SCANNED** (all reachable refs)"
  echo "- CI hard-fail classes present: **$CI_FAIL** (1=yes)"
  echo
  echo "## Policy"
  echo
  echo "- Findings are flagged for **HUMAN** rotation / history rewrite decisions."
  echo "- Historical findings use \`history:path@blob-id\`; no matching value is emitted."
  echo "- This script does **not** rotate credentials or rewrite git history."
  echo "- Public test vectors / shared-vectors hex are excluded from path scope."
  echo "- Environment-style assignments are always reported for human review but do not hard-fail CI; PEM/cloud-token patterns and untracked secret files do."
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
  echo "\`--ci\` exits non-zero only for hard-fail classes (PEM/cloud-token patterns or untracked secret files). Environment-style assignments remain non-blocking human-review findings."
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
  echo "CI: no hard-fail secret classes (human-review findings may remain)"
fi
