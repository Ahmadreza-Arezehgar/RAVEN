#!/usr/bin/env bash
# Build the serverless libp2p bridge as an iOS xcframework via gomobile.
#
# Prereqs (one-time):
#   brew install go
#   go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20260611195102-4dd8f1dbf5d2
#   go install golang.org/x/mobile/cmd/gobind@v0.0.0-20260611195102-4dd8f1dbf5d2
#   (Xcode must be installed — gomobile uses it for the iOS toolchain.)
#
# Output: RavenLibp2p.xcframework (device arm64 + simulator arm64/x86_64).
# Then in Xcode: drag RavenLibp2p.xcframework into the RAVEN target →
# "Embed & Sign". See README.md.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/go/bin:$PATH"
MOBILE_VERSION="v0.0.0-20260611195102-4dd8f1dbf5d2"
OUT="${RAVEN_XCFRAMEWORK_OUT:-RavenLibp2p.xcframework}"

case "$OUT" in
  *.xcframework) ;;
  *) echo "ERROR: output must end in .xcframework: $OUT" >&2; exit 2 ;;
esac
if [[ -e "$OUT" || -L "$OUT" ]]; then
  echo "ERROR: refusing to replace existing generated output: $OUT" >&2
  echo "Move it aside or choose RAVEN_XCFRAMEWORK_OUT explicitly." >&2
  exit 2
fi

command -v gomobile >/dev/null 2>&1 || {
  echo "ERROR: gomobile is missing; install pinned x/mobile $MOBILE_VERSION" >&2
  exit 2
}
command -v gobind >/dev/null 2>&1 || {
  echo "ERROR: gobind is missing; install pinned x/mobile $MOBILE_VERSION" >&2
  exit 2
}

RESOLVED_MOBILE_VERSION="$(go list -m -f '{{.Version}}' golang.org/x/mobile)"
if [[ "$RESOLVED_MOBILE_VERSION" != "$MOBILE_VERSION" ]]; then
  echo "ERROR: go.mod pins x/mobile $RESOLVED_MOBILE_VERSION, expected $MOBILE_VERSION" >&2
  exit 2
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/raven-xcframework.XXXXXX")"
cleanup() {
  rm -rf -- "$BUILD_DIR"
}
trap cleanup EXIT HUP INT TERM
STAGED_OUT="$BUILD_DIR/RavenLibp2p.xcframework"

echo "▶ go modules (read-only)"
go mod download

echo "▶ go build (host sanity check)"
go build -mod=readonly ./...

echo "▶ gomobile bind → RavenLibp2p.xcframework (heavy)"
gomobile bind -target=ios,iossimulator -o "$STAGED_OUT" .
mv "$STAGED_OUT" "$OUT"

echo "✅ built:"
du -sh "$OUT"
