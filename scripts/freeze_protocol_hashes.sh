#!/usr/bin/env bash
# Freeze SHA-256 hashes for protocol/* normative specs (external review packet).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/docs/PROTOCOL_FREEZE_HASHES_V1.md}"
{
  echo "# Raven protocol freeze hashes"
  echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Branch: $(cd "$REPO" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "# Commit: $(cd "$REPO" && git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "#"
  echo "# Format: SHA256  path (relative to repo root)"
  echo
  cd "$REPO"
  # Normative markdown + reference python under protocol/
  find protocol -type f \( -name '*.md' -o -name '*.py' -o -name '*.json' -o -name '*.toml' \) \
    ! -path '*/__pycache__/*' ! -path '*/.pytest_cache/*' \
    | LC_ALL=C sort \
    | while read -r f; do
        shasum -a 256 "$f"
      done
  echo
  echo "# Shared vectors (rvn1) — byte-exact fixtures"
  find shared-vectors/rvn1 -type f \( -name '*.json' -o -name '*.md' \) \
    ! -path '*/__pycache__/*' \
    | LC_ALL=C sort \
    | while read -r f; do
        shasum -a 256 "$f"
      done
} >"$OUT"
echo "wrote $OUT"
wc -l "$OUT"
