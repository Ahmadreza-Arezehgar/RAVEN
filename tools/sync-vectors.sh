#!/usr/bin/env bash
# Sync `shared-vectors/v1` into every consumer that vendors a copy.
#
# Consumers in this monorepo:
#   - RAVEN-iOS/MeshV1/Tests/MeshV1Tests/Resources/v1   (SPM test resources)
#
# The Android client lives in a separate repository (raven-android) and
# vendors its own copy under `shared-vectors/v1`. To sync it too, set
# `RAVEN_ANDROID_PATH` to its path:
#
#   RAVEN_ANDROID_PATH=$HOME/raven-android tools/sync-vectors.sh
#
# Run this after `python3 shared-vectors/generate_v1.py` (or after editing
# any vector by hand). Idempotent — re-running with no upstream changes is
# a no-op.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
SRC="$ROOT/shared-vectors/v1"

if [ ! -d "$SRC" ]; then
  echo "shared-vectors/v1 does not exist; run generate_v1.py first." >&2
  exit 1
fi

sync_to() {
  local dest="$1"
  echo "→ syncing to $dest"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -R "$SRC" "$dest"
}

sync_to "$ROOT/RAVEN-iOS/MeshV1/Tests/MeshV1Tests/Resources/v1"

if [ -n "${RAVEN_ANDROID_PATH:-}" ]; then
  sync_to "$RAVEN_ANDROID_PATH/shared-vectors/v1"
fi

echo
echo "OK. Run consumers' tests:"
echo "  swift test --package-path RAVEN-iOS/MeshV1"
if [ -n "${RAVEN_ANDROID_PATH:-}" ]; then
  echo "  cd \"$RAVEN_ANDROID_PATH\" && ./gradlew :modules:mesh:test"
fi
