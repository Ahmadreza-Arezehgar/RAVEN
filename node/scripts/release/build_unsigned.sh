#!/usr/bin/env bash
# Build an unsigned, default-feature Raven terminal release for this host.
# This script intentionally excludes every experimental/unsafe Cargo feature.
set -euo pipefail

NODE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_ROOT="$(cd "$NODE_ROOT/.." && pwd)"

VERSION="${RAVEN_RELEASE_VERSION:-0.1.0}"
case "$VERSION" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: RAVEN_RELEASE_VERSION may contain only letters, digits, dot, underscore, and dash" >&2
    exit 2
    ;;
esac

case "$(uname -s)" in
  Darwin) HOST_OS="darwin" ;;
  Linux)
    HOST_OS="linux"
    if [[ "${RAVEN_ALLOW_BLOCKED_LINUX_PACKAGE:-}" != "1" ]]; then
      echo "ERROR: fresh Linux identity creation is held at the R1 protected-store gate" >&2
      echo "Refusing a distributable-looking archive that cannot initialize safely." >&2
      echo "For build-review only, set RAVEN_ALLOW_BLOCKED_LINUX_PACKAGE=1." >&2
      exit 2
    fi
    ;;
  *)
    echo "ERROR: this archive builder supports macOS and Linux; build Windows artifacts in Windows CI" >&2
    exit 2
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH="x86_64" ;;
  arm64|aarch64) HOST_ARCH="aarch64" ;;
  *) HOST_ARCH="$(uname -m | tr -c 'A-Za-z0-9._-' '_')" ;;
esac

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_ROOT="${RAVEN_RELEASE_OUT_DIR:-$REPO_ROOT/dist}"
mkdir -p "$OUT_ROOT"
if [[ -L "$OUT_ROOT" ]]; then
  echo "ERROR: refusing a symlinked release output directory: $OUT_ROOT" >&2
  exit 2
fi

PACKAGE="raven-serverless-${VERSION}-${HOST_OS}-${HOST_ARCH}-${STAMP}-$$"
STAGE="$OUT_ROOT/$PACKAGE"
ARCHIVE="$OUT_ROOT/$PACKAGE.tar.gz"
BUILD_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/raven-release-build.XXXXXX")"
cleanup_build() {
  rm -rf -- "$BUILD_TARGET"
}
trap cleanup_build EXIT HUP INT TERM

HOST_TRIPLE="$(rustc -vV | sed -n 's/^host: //p')"
case "$HOST_TRIPLE" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: could not determine a safe Rust host triple" >&2
    exit 2
    ;;
esac
mkdir "$STAGE"
mkdir "$STAGE/bin" "$STAGE/docs"

echo "Building Raven release binaries with default features only..."
CARGO_TARGET_DIR="$BUILD_TARGET" cargo build \
  --locked \
  --release \
  --target "$HOST_TRIPLE" \
  --manifest-path "$NODE_ROOT/Cargo.toml" \
  -p ash \
  -p raven-node \
  -p raven-swarm

BUILT_BIN="$BUILD_TARGET/$HOST_TRIPLE/release"
install -m 755 "$BUILT_BIN/raven" "$STAGE/bin/raven"
install -m 755 "$BUILT_BIN/ash" "$STAGE/bin/ash"
install -m 755 "$BUILT_BIN/raven-node" "$STAGE/bin/raven-node"
install -m 755 "$BUILT_BIN/raven-swarm" "$STAGE/bin/raven-swarm"

install -m 644 "$REPO_ROOT/LICENSE" "$STAGE/LICENSE"
for doc in \
  INSTALL_macOS.md \
  INSTALL_Linux.md \
  INSTALL_Windows.md \
  SERVERLESS_MODEL.md \
  SIGNING_NOTARIZATION_CHECKLIST.md; do
  install -m 644 "$NODE_ROOT/$doc" "$STAGE/docs/$doc"
done

cat >"$STAGE/README.txt" <<EOF
RAVEN Serverless Terminal Messaging — unsigned host build
version=$VERSION
target=$HOST_OS-$HOST_ARCH
built_utc=$STAMP

This archive is not notarized or Authenticode-signed.
It contains only default-feature release binaries; experimental mailbox/NAT
and unsafe demo crypto are not compiled into this package.

Quick start:
  ./bin/raven --data-dir ./raven-data init
  ./bin/raven --data-dir ./raven-data doctor
  ./bin/raven-node service --data-dir ./raven-data
EOF

if [[ "$HOST_OS" == "linux" ]]; then
  cat >>"$STAGE/README.txt" <<'EOF'

LINUX R1 SECURITY HOLD:
Fresh identity creation is intentionally disabled until the prompt-free,
protected Secret Service backend is approved. This review-only archive must
not be presented as an installable Linux release and will not fall back to a
plaintext/locked-file Release identity.
EOF
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

(
  cd "$STAGE"
  find . -type f ! -name SHA256SUMS.txt | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s  %s\n' "$(sha256_file "$file")" "${file#./}"
  done
) >"$STAGE/SHA256SUMS.txt"

tar -C "$OUT_ROOT" -czf "$ARCHIVE" "$PACKAGE"
printf '%s  %s\n' "$(sha256_file "$ARCHIVE")" "$(basename "$ARCHIVE")" \
  >"$ARCHIVE.sha256"

echo "UNSIGNED_RELEASE_OK"
echo "layout=$STAGE"
echo "archive=$ARCHIVE"
echo "archive_checksum=$ARCHIVE.sha256"
