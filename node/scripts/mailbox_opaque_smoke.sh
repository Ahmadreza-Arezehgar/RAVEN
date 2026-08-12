#!/usr/bin/env bash
# Offline mailbox retrieve smoke — opaque store_tag only (no username index).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cargo build -q -p ash -p raven-core
ASH=./target/debug/ash

# Deterministic K_route (32 bytes) — never a username.
K_ROUTE="$(python3 -c 'print("00"*32)')"
EPOCH=42
SLOT=0

# Pack a minimal opaque payload (not a full RVN1 — mailbox stores opaque bytes).
# Use a fake envelope hex that is clearly not a username.
ENV_HEX="$(python3 -c 'print("52564e31" + "01" + "ab"*64)')"

"$ASH" --data-dir "$TMP/store" mailbox put \
  --k-route-hex "$K_ROUTE" --epoch "$EPOCH" --slot "$SLOT" --envelope-hex "$ENV_HEX"

OUT="$("$ASH" --data-dir "$TMP/store" mailbox get \
  --k-route-hex "$K_ROUTE" --epoch "$EPOCH" --slot "$SLOT")"

echo "$OUT" | grep -q 'store_tag=' || {
  echo "FAIL: expected opaque store_tag hit"
  echo "$OUT"
  exit 1
}
echo "$OUT" | grep -qi 'username' && {
  echo "FAIL: username must never appear in mailbox index path"
  exit 1
}

# Overlap: previous epoch should still find when epoch advanced without put.
OUT2="$("$ASH" --data-dir "$TMP/store" mailbox get \
  --k-route-hex "$K_ROUTE" --epoch $((EPOCH + 1)) --slot "$SLOT")"
echo "$OUT2" | grep -q 'store_tag=' || {
  echo "FAIL: overlap retrieve (prev epoch) expected a hit"
  echo "$OUT2"
  exit 1
}

echo "OK mailbox opaque put/get + epoch overlap"
