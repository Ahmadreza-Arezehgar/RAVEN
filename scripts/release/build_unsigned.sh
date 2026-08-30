#!/usr/bin/env bash
# Compatibility entry point. Keep all release policy in the canonical builder
# so this historical path cannot bypass platform holds, clean-tree checks, or
# third-party license/notice generation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$REPO_ROOT/node/scripts/release/build_unsigned.sh" "$@"
