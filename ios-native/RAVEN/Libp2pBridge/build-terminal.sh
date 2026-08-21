#!/usr/bin/env bash
# Cross-platform release builds for the RAVEN terminal client.
# Output: ../../dist/raven-<os>-<arch>[.exe]  (dist/ is the repo-wide artifacts dir)
set -euo pipefail
cd "$(dirname "$0")"

OUT_DIR="${1:-../../dist/terminal}"
mkdir -p "$OUT_DIR"
VERSION="$(git -C ../.. describe --tags --always 2>/dev/null || echo dev)"
LDFLAGS="-s -w -X main.version=${VERSION}"

build() {
  local goos="$1" goarch="$2"
  local out="raven-${goos}-${goarch}"
  [ "$goos" = "windows" ] && out="${out}.exe"
  echo "building ${out} ..."
  GOOS="$goos" GOARCH="$goarch" CGO_ENABLED=0 \
    go build -trimpath -ldflags "${LDFLAGS}" -o "${OUT_DIR}/${out}" ./cmd/raven
}

build darwin  arm64
build darwin  amd64
build linux   amd64
build linux   arm64
build windows amd64
build windows arm64

echo
echo "artifacts in ${OUT_DIR}:"
ls -lh "$OUT_DIR" | awk 'NR>1 {print "  " $9 " (" $5 ")"}'
