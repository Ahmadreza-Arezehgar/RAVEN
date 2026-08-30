#!/usr/bin/env bash
# Build an unsigned, default-feature Raven terminal release for this host.
# This script intentionally excludes every experimental/unsafe Cargo feature.
set -euo pipefail
umask 022

NODE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_ROOT="$(cd "$NODE_ROOT/.." && pwd)"

for command_name in cargo git python3 rustc; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: required build command is missing: $command_name" >&2
    exit 2
  }
done

MACOS_LAB_ACK_VALUE="I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK"
case "$(uname -s)" in
  Darwin)
    HOST_OS="darwin"
    if [[ "${RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK:-}" != "$MACOS_LAB_ACK_VALUE" ]]; then
      echo "ERROR: macOS package creation is held at the Keychain identity-handoff gate" >&2
      echo "The separately signed raven and raven-node executables have not passed a" >&2
      echo "physical launchd/Keychain ACL continuity test. Refusing a distributable-looking archive." >&2
      echo "For isolated build review only, set:" >&2
      echo "RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK=$MACOS_LAB_ACK_VALUE" >&2
      exit 2
    fi
    echo "WARNING: building a review-only macOS archive with unvalidated Keychain handoff" >&2
    ;;
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

CARGO_VERSION="$(
  cargo metadata --no-deps --format-version 1 --manifest-path "$NODE_ROOT/Cargo.toml" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(p["version"] for p in d["packages"] if p["name"] == "raven-core"))'
)"
VERSION="${RAVEN_RELEASE_VERSION:-$CARGO_VERSION}"
case "$VERSION" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: RAVEN_RELEASE_VERSION may contain only letters, digits, dot, underscore, and dash" >&2
    exit 2
    ;;
esac
if [[ "$VERSION" != "$CARGO_VERSION" ]]; then
  echo "ERROR: release version $VERSION does not match Cargo workspace version $CARGO_VERSION" >&2
  exit 2
fi

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --verify HEAD)"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal --ignore-submodules=none)" ]]; then
  echo "ERROR: release archives require a completely clean Git tree, including submodules" >&2
  git -C "$REPO_ROOT" status --short --ignore-submodules=none >&2
  exit 2
fi

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" show -s --format=%ct HEAD)}"
case "$SOURCE_DATE_EPOCH" in
  *[!0-9]*|'')
    echo "ERROR: SOURCE_DATE_EPOCH must be a non-negative integer" >&2
    exit 2
    ;;
esac
export SOURCE_DATE_EPOCH
export LC_ALL=C
export TZ=UTC

BUILD_UTC="$(python3 - "$SOURCE_DATE_EPOCH" <<'PY'
from datetime import datetime, timezone
import sys

print(datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH="x86_64" ;;
  arm64|aarch64) HOST_ARCH="aarch64" ;;
  *) HOST_ARCH="$(uname -m | tr -c 'A-Za-z0-9._-' '_')" ;;
esac

HOST_TRIPLE="$(rustc -vV | sed -n 's/^host: //p')"
case "$HOST_TRIPLE" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: could not determine a safe Rust host triple" >&2
    exit 2
    ;;
esac

OUT_ROOT="${RAVEN_RELEASE_OUT_DIR:-$REPO_ROOT/dist}"
if [[ -L "$OUT_ROOT" ]]; then
  echo "ERROR: refusing a symlinked release output directory: $OUT_ROOT" >&2
  exit 2
fi
mkdir -p "$OUT_ROOT"
if [[ ! -d "$OUT_ROOT" || -L "$OUT_ROOT" ]]; then
  echo "ERROR: release output is not a real directory: $OUT_ROOT" >&2
  exit 2
fi

PACKAGE="raven-serverless-${VERSION}-${HOST_OS}-${HOST_ARCH}"
FINAL_STAGE="$OUT_ROOT/$PACKAGE"
FINAL_ARCHIVE="$OUT_ROOT/$PACKAGE.tar.gz"
FINAL_CHECKSUM="$FINAL_ARCHIVE.sha256"
LOCK_DIR="$OUT_ROOT/.$PACKAGE.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: another release build is active (or left a stale lock): $LOCK_DIR" >&2
  exit 2
fi

BUILD_TARGET=""
OUTPUT_WORK=""
cleanup() {
  if [[ -n "$BUILD_TARGET" && -d "$BUILD_TARGET" ]]; then
    rm -rf -- "$BUILD_TARGET"
  fi
  if [[ -n "$OUTPUT_WORK" && -d "$OUTPUT_WORK" ]]; then
    rm -rf -- "$OUTPUT_WORK"
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

if [[ -e "$FINAL_STAGE" || -L "$FINAL_STAGE" \
   || -e "$FINAL_ARCHIVE" || -L "$FINAL_ARCHIVE" \
   || -e "$FINAL_CHECKSUM" || -L "$FINAL_CHECKSUM" ]]; then
  echo "ERROR: deterministic release output already exists for $PACKAGE; move it aside first" >&2
  exit 2
fi

# The package and archive are constructed under hidden temporary paths on the
# output filesystem. Final `mv` operations therefore publish only complete
# directory/archive/checksum objects and cannot expose partially-written files.
OUTPUT_WORK="$(mktemp -d "$OUT_ROOT/.${PACKAGE}.stage.XXXXXX")"
BUILD_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/raven-release-build.XXXXXX")"
STAGE="$OUTPUT_WORK/$PACKAGE"
ARCHIVE_TMP="$OUTPUT_WORK/$PACKAGE.tar.gz"
CHECKSUM_TMP="$OUTPUT_WORK/$PACKAGE.tar.gz.sha256"
mkdir -p "$STAGE/bin" "$STAGE/docs"

echo "Building Raven release binaries with default features only..."
CARGO_HOME_PATH="${CARGO_HOME:-$HOME/.cargo}"
REMAP_FLAGS="--remap-path-prefix=$REPO_ROOT=/usr/src/raven"
REMAP_FLAGS+=$'\x1f'"--remap-path-prefix=$BUILD_TARGET=/build/raven-target"
REMAP_FLAGS+=$'\x1f'"--remap-path-prefix=$CARGO_HOME_PATH=/usr/local/cargo"
(
  unset RUSTFLAGS RUSTDOCFLAGS
  export CARGO_ENCODED_RUSTFLAGS="$REMAP_FLAGS"
  export CARGO_INCREMENTAL=0
  export CARGO_TARGET_DIR="$BUILD_TARGET"
  cargo build \
    --locked \
    --release \
    --target "$HOST_TRIPLE" \
    --manifest-path "$NODE_ROOT/Cargo.toml" \
    -p ash \
    -p raven-node \
    -p raven-swarm
)

BUILT_BIN="$BUILD_TARGET/$HOST_TRIPLE/release"
install -m 755 "$BUILT_BIN/raven" "$STAGE/bin/raven"
install -m 755 "$BUILT_BIN/ash" "$STAGE/bin/ash"
install -m 755 "$BUILT_BIN/raven-node" "$STAGE/bin/raven-node"
install -m 755 "$BUILT_BIN/raven-swarm" "$STAGE/bin/raven-swarm"

install -m 644 "$REPO_ROOT/LICENSE" "$STAGE/LICENSE"
for doc in \
  IDENTITY_SEED_STORAGE.md \
  INSTALL_Linux.md \
  INSTALL_Windows.md \
  INSTALL_macOS.md \
  SERVERLESS_MODEL.md \
  SIGNING_NOTARIZATION_CHECKLIST.md \
  WINDOWS.md; do
  install -m 644 "$NODE_ROOT/$doc" "$STAGE/docs/$doc"
done
install -m 644 "$NODE_ROOT/scripts/install/WINDOWS_SERVICE.md" "$STAGE/docs/WINDOWS_SERVICE.md"

python3 "$NODE_ROOT/scripts/release/generate_third_party_licenses.py" \
  --manifest-path "$NODE_ROOT/Cargo.toml" \
  --target "$HOST_TRIPLE" \
  --output "$STAGE/THIRD_PARTY_LICENSES_AND_NOTICES.txt"

cat >"$STAGE/README.txt" <<EOF
RAVEN Serverless Terminal Messaging — unsigned host build
version=$VERSION
target=$HOST_OS-$HOST_ARCH
built_utc=$BUILD_UTC

This archive is not notarized or Authenticode-signed.
It contains only default-feature release binaries; experimental mailbox/NAT
and unsafe demo crypto are not compiled into this package.
Third-party license texts and separate dependency notices are in
THIRD_PARTY_LICENSES_AND_NOTICES.txt.

Build-review commands (do not initialize or install a service from this held archive):
  ./bin/raven --help
  ./bin/raven-node --help
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

if [[ "$HOST_OS" == "darwin" ]]; then
  cat >>"$STAGE/README.txt" <<'EOF'

MACOS KEYCHAIN HANDOFF HOLD:
This review-only archive was produced with an explicit unsafe lab
acknowledgement. Identity continuity between the separate raven and raven-node
executables under launchd has not passed the required signed physical-Keychain
test. Do not distribute or install it as a background service.
EOF
fi

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

cat >"$STAGE/PROVENANCE.txt" <<EOF
format=raven-unsigned-provenance-v1
version=$VERSION
git_sha=$GIT_SHA
source_tree_clean=true
source_date_epoch=$SOURCE_DATE_EPOCH
build_utc=$BUILD_UTC
host_os=$HOST_OS
host_arch=$HOST_ARCH
target_triple=$HOST_TRIPLE
build_profile=release
cargo_packages=ash,raven-node,raven-swarm
cargo_features=default
cargo_incremental=0
distribution_status=review-only
third_party_license_generator=cargo-about-0.9.1
third_party_license_file=THIRD_PARTY_LICENSES_AND_NOTICES.txt
rust_path_remap=/usr/src/raven,/build/raven-target,/usr/local/cargo
cargo_lock_sha256=$(sha256_file "$NODE_ROOT/Cargo.lock")
rustc=$(rustc --version)
cargo=$(cargo --version)
EOF

(
  cd "$STAGE"
  find . -type f ! -name SHA256SUMS.txt | sort | while IFS= read -r file; do
    printf '%s  %s\n' "$(sha256_file "$file")" "${file#./}"
  done
) >"$STAGE/SHA256SUMS.txt"

RAW_TAR="$BUILD_TARGET/$PACKAGE.tar"
python3 - "$STAGE" "$PACKAGE" "$RAW_TAR" "$ARCHIVE_TMP" "$SOURCE_DATE_EPOCH" <<'PY'
import gzip
import pathlib
import shutil
import sys
import tarfile

stage = pathlib.Path(sys.argv[1])
package = sys.argv[2]
raw_tar = pathlib.Path(sys.argv[3])
archive = pathlib.Path(sys.argv[4])
epoch = int(sys.argv[5])

paths = [stage, *sorted(stage.rglob("*"), key=lambda p: p.relative_to(stage).as_posix())]
with tarfile.open(raw_tar, "w", format=tarfile.PAX_FORMAT) as output:
    for path in paths:
        if not (path.is_dir() or path.is_file()):
            raise SystemExit(f"refusing non-regular release entry: {path}")
        relative = path.relative_to(stage)
        arcname = pathlib.PurePosixPath(package)
        if relative.parts:
            arcname /= pathlib.PurePosixPath(relative.as_posix())
        info = output.gettarinfo(str(path), arcname=str(arcname))
        info.uid = 0
        info.gid = 0
        info.uname = "root"
        info.gname = "root"
        info.mtime = epoch
        info.pax_headers = {}
        info.mode = 0o755 if info.isdir() or (relative.parts and relative.parts[0] == "bin") else 0o644
        if info.isfile():
            with path.open("rb") as source:
                output.addfile(info, source)
        else:
            output.addfile(info)

with raw_tar.open("rb") as source, archive.open("xb") as destination:
    with gzip.GzipFile(filename="", mode="wb", fileobj=destination, compresslevel=9, mtime=epoch) as compressed:
        shutil.copyfileobj(source, compressed)
PY
printf '%s  %s\n' "$(sha256_file "$ARCHIVE_TMP")" "$(basename "$FINAL_ARCHIVE")" \
  >"$CHECKSUM_TMP"

# Each publication is an atomic rename on OUT_ROOT's filesystem. The checksum
# is moved last, so consumers can treat its presence as the completion marker.
mv "$STAGE" "$FINAL_STAGE"
mv "$ARCHIVE_TMP" "$FINAL_ARCHIVE"
mv "$CHECKSUM_TMP" "$FINAL_CHECKSUM"

echo "UNSIGNED_REVIEW_ARCHIVE_OK"
echo "layout=$FINAL_STAGE"
echo "archive=$FINAL_ARCHIVE"
echo "archive_checksum=$FINAL_CHECKSUM"
