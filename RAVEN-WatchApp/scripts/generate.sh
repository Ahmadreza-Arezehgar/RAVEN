#!/usr/bin/env bash
# generate.sh — regenerate RAVEN.xcodeproj from project.yml.
#
# Run after editing project.yml (sources, capabilities, deployment target).
# Requires xcodegen — install via `brew install xcodegen`.

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not installed. Run: brew install xcodegen" >&2
    exit 1
fi

xcodegen generate --project . --spec project.yml
echo "✓ RAVEN-Watch.xcodeproj regenerated"
