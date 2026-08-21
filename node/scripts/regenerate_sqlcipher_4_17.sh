#!/usr/bin/env bash
# Regenerate SQLCipher 4.17.0 amalgamation provenance into node/third_party/sqlcipher-4.17.0.
#
# Two clean, isolated clones at the exact peeled commit are built with:
#   ./configure --with-tempstore=yes
# plus the required SQLCipher CFLAGS. Trees are compared byte-for-byte.
#
# Workdir safety:
#   User may supply WORK_PARENT (or legacy WORK_ROOT as parent only).
#   A dedicated child is always created with mktemp under that parent.
#   User-supplied paths are never rm -rf'd directly.
#   Cleanup requires an ownership sentinel + exact basename prefix.
#
# Usage:
#   ./node/scripts/regenerate_sqlcipher_4_17.sh
#   OUT_DIR=$(mktemp -d) WORK_PARENT=/tmp ./node/scripts/regenerate_sqlcipher_4_17.sh
#   SQLCIPHER_PROVENANCE_DIR="$OUT_DIR" ./node/scripts/verify_sqlcipher_4_17.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SQLCIPHER_TEMPLATE_DIR:-$SCRIPT_DIR/sqlcipher_4_17_templates}"
OUT_DIR="${OUT_DIR:-$ROOT/node/third_party/sqlcipher-4.17.0}"
KEEP_WORK="${KEEP_WORK:-0}"

CORE_TAG_OBJECT="f9788efa8ac4dfed75c03e4756b1666a1d0845da"
CORE_PEELED_COMMIT="810db22f575ee7cf94ea96a3e91622b5fcece3dc"
REPO_URL="${SQLCIPHER_GIT_URL:-https://github.com/sqlcipher/sqlcipher.git}"
REQUIRED_TAG_REF="refs/tags/v4.17.0"

EXPECTED_SQLITE3_C="8adaff6b464052a74e7adaa3cfa2725400f48eca68f47856fa806eaf30bdf2c9"
EXPECTED_SQLITE3_H="e564d0492e7556a8ad2f30c8ec645b5a6abb89f32f7b40465a3032d937596401"
EXPECTED_MANIFEST="6703f59d2307674e09b55297c7832819ef44fb590691314a4da36f8240e41473"
EXPECTED_MANIFEST_UUID="3ec90494f84736dd7efd0f49a06b787d3f791e0d6b2b1e0bce66fa792d6107e4"

WORK_PREFIX="raven-sqlcipher-4.17.0-regen-"
SENTINEL_NAME=".raven_sqlcipher_4_17_regen_owned"
SENTINEL_MAGIC="RAVEN_SQLCIPHER_4_17_REGEN_OWNED_v1"

WORK_DIR=""
WORK_PARENT_RESOLVED=""
CLEANUP_ENABLED=0

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

die() {
  echo "FAIL: $*" >&2
  exit 1
}

reject_work_parent() {
  die "SQLCIPHER_WORK_PARENT_REJECTED: $*"
}

is_symlink() {
  [[ -L "$1" ]]
}

realpath_physical() {
  # Prefer GNU/BSD realpath -P when available; fall back to pwd -P via cd.
  if command -v realpath >/dev/null 2>&1; then
    realpath -P "$1" 2>/dev/null || realpath "$1"
  else
    (cd "$1" && pwd -P)
  fi
}

path_owner_uid() {
  local path="$1"
  if stat -f '%u' "$path" >/dev/null 2>&1; then
    stat -f '%u' "$path"
  else
    stat -c '%u' "$path"
  fi
}

is_sticky_dir() {
  # Bash -k is true when the sticky bit is set on the referenced directory.
  [[ -d "$1" && -k "$1" ]]
}

is_trusted_sticky_temp_root() {
  local p="$1"
  case "$p" in
    /tmp|/private/tmp|/var/tmp)
      is_sticky_dir "$p"
      return
      ;;
  esac
  return 1
}

parent_ownership_ok() {
  local parent="$1"
  local owner me
  me="$(id -u)"
  owner="$(path_owner_uid "$parent")"
  if [[ "$owner" == "$me" ]]; then
    return 0
  fi
  if is_trusted_sticky_temp_root "$parent"; then
    return 0
  fi
  return 1
}

validate_work_parent() {
  local raw="$1"
  local parent

  [[ -n "$raw" ]] || reject_work_parent "empty parent"
  [[ "$raw" == /* ]] || reject_work_parent "parent must be absolute: $raw"
  [[ -e "$raw" ]] || reject_work_parent "parent does not exist: $raw"
  [[ -d "$raw" ]] || reject_work_parent "parent is not a directory: $raw"

  # Resolve symlinks to a physical directory (e.g. macOS /tmp -> /private/tmp).
  # Reject symlink parents whose physical target is unsafe (/, workspace, etc.).
  parent="$(realpath_physical "$raw")"
  [[ -n "$parent" ]] || reject_work_parent "cannot resolve parent: $raw"
  [[ -d "$parent" ]] || reject_work_parent "resolved parent is not a directory: $parent"
  # After resolution the path must not itself remain a symlink node we would mutate.
  if is_symlink "$parent"; then
    reject_work_parent "resolved parent is still a symlink: $parent"
  fi

  [[ "$parent" != "/" ]] || reject_work_parent "filesystem root is not an allowed parent"
  [[ "$parent" != "$ROOT" ]] || reject_work_parent "workspace root is not an allowed parent: $ROOT"

  case "$parent" in
    "$ROOT"|"$ROOT"/*)
      reject_work_parent "parent inside workspace is not allowed: $parent"
      ;;
  esac

  # If the user supplied a symlink, it must not retarget into the workspace.
  if is_symlink "$raw"; then
    case "$parent" in
      "$ROOT"|"$ROOT"/*|"/")
        reject_work_parent "symlink parent resolves to unsafe path: $raw -> $parent"
        ;;
    esac
  fi

  [[ -w "$parent" ]] || reject_work_parent "parent is not writable: $parent"

  # Ownership: current UID, or an explicit trusted sticky temp root (e.g. /private/tmp).
  # Writable foreign non-sticky parents are rejected (rename/replace race).
  if ! parent_ownership_ok "$parent"; then
    reject_work_parent "unowned/non-sticky parent not allowed (uid=$(path_owner_uid "$parent")): $parent"
  fi

  WORK_PARENT_RESOLVED="$parent"
}

write_sentinel() {
  local dir="$1"
  local base
  base="$(basename "$dir")"
  printf '%s\nparent=%s\nbasename=%s\npid=%s\nowner_uid=%s\n' \
    "$SENTINEL_MAGIC" "$WORK_PARENT_RESOLVED" "$base" "$$" "$(id -u)" \
    >"$dir/$SENTINEL_NAME"
  chmod 600 "$dir/$SENTINEL_NAME"
}

sentinel_is_valid() {
  local dir="$1"
  local base
  local magic parent_line base_line owner_line
  local me

  me="$(id -u)"
  [[ -d "$dir" ]] || return 1
  if is_symlink "$dir"; then
    return 1
  fi
  base="$(basename "$dir")"
  [[ "$base" == ${WORK_PREFIX}* ]] || return 1
  [[ -e "$dir/$SENTINEL_NAME" || -L "$dir/$SENTINEL_NAME" ]] || return 1
  if is_symlink "$dir/$SENTINEL_NAME"; then
    return 1
  fi
  [[ -f "$dir/$SENTINEL_NAME" ]] || return 1

  # Re-check ownership of workdir and sentinel at cleanup time.
  [[ "$(path_owner_uid "$dir")" == "$me" ]] || return 1
  [[ "$(path_owner_uid "$dir/$SENTINEL_NAME")" == "$me" ]] || return 1
  if ! parent_ownership_ok "$WORK_PARENT_RESOLVED"; then
    return 1
  fi

  magic="$(head -n 1 "$dir/$SENTINEL_NAME" 2>/dev/null || true)"
  [[ "$magic" == "$SENTINEL_MAGIC" ]] || return 1

  parent_line="$(sed -n '2p' "$dir/$SENTINEL_NAME" 2>/dev/null || true)"
  base_line="$(sed -n '3p' "$dir/$SENTINEL_NAME" 2>/dev/null || true)"
  owner_line="$(sed -n '5p' "$dir/$SENTINEL_NAME" 2>/dev/null || true)"
  [[ "$parent_line" == "parent=$WORK_PARENT_RESOLVED" ]] || return 1
  [[ "$base_line" == "basename=$base" ]] || return 1
  [[ "$owner_line" == "owner_uid=$me" ]] || return 1

  # Directory must still live directly under the resolved parent.
  local parent_of_dir
  parent_of_dir="$(cd "$(dirname "$dir")" && pwd -P)"
  [[ "$parent_of_dir" == "$WORK_PARENT_RESOLVED" ]] || return 1
  return 0
}

safe_cleanup_work_dir() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  if ! sentinel_is_valid "$dir"; then
    echo "WARN: refusing cleanup; sentinel/ownership check failed for: $dir" >&2
    return 0
  fi
  # Final basename/prefix gate before mutation.
  local base
  base="$(basename "$dir")"
  [[ "$base" == ${WORK_PREFIX}* ]] || {
    echo "WARN: refusing cleanup; basename prefix mismatch: $base" >&2
    return 0
  }
  rm -rf "$dir"
}

cleanup() {
  if [[ "$CLEANUP_ENABLED" != "1" ]]; then
    return 0
  fi
  if [[ "$KEEP_WORK" == "1" ]]; then
    echo "KEEP_WORK=1 work_dir=$WORK_DIR" >&2
    return 0
  fi
  safe_cleanup_work_dir "$WORK_DIR"
}
trap cleanup EXIT

command -v git >/dev/null || die "git required"
command -v tclsh >/dev/null || die "tclsh required for SQLCipher amalgamation"
command -v shasum >/dev/null || die "shasum required"

# WORK_PARENT (preferred) or legacy WORK_ROOT interpreted strictly as parent.
# Never rm -rf the user-supplied value. Default to the physical temp dir
# (macOS /tmp is a symlink to /private/tmp).
DEFAULT_TMP="$(realpath_physical /tmp)"
USER_PARENT="${WORK_PARENT:-${WORK_ROOT:-$DEFAULT_TMP}}"
validate_work_parent "$USER_PARENT"

WORK_DIR="$(mktemp -d "${WORK_PARENT_RESOLVED}/${WORK_PREFIX}XXXXXX")"
[[ "$(basename "$WORK_DIR")" == ${WORK_PREFIX}* ]] || die "mktemp basename prefix mismatch: $WORK_DIR"
write_sentinel "$WORK_DIR"
CLEANUP_ENABLED=1

test -d "$TEMPLATE_DIR" || die "missing template dir: $TEMPLATE_DIR"
test -f "$TEMPLATE_DIR/PROVENANCE.md" || die "missing $TEMPLATE_DIR/PROVENANCE.md"
test -f "$TEMPLATE_DIR/NOTICE" || die "missing $TEMPLATE_DIR/NOTICE"

mkdir -p "$OUT_DIR"
A_DIR="$WORK_DIR/clone-a"
B_DIR="$WORK_DIR/clone-b"
A_OUT="$WORK_DIR/out-a"
B_OUT="$WORK_DIR/out-b"
mkdir -p "$A_OUT" "$B_OUT"

echo "=== regenerate SQLCipher 4.17.0 provenance ===" >&2
echo "work_parent=$WORK_PARENT_RESOLVED" >&2
echo "work_dir=$WORK_DIR" >&2
echo "out_dir=$OUT_DIR" >&2
echo "peeled_commit=$CORE_PEELED_COMMIT" >&2

require_official_tag() {
  local clone_dir="$1"
  local label="$2"

  if ! git -C "$clone_dir" show-ref --verify --quiet "$REQUIRED_TAG_REF"; then
    die "SQLCIPHER_TAG_MISSING: $REQUIRED_TAG_REF required (clone=${label})"
  fi

  local tag_obj peeled
  tag_obj="$(git -C "$clone_dir" rev-parse "$REQUIRED_TAG_REF")"
  peeled="$(git -C "$clone_dir" rev-parse "${REQUIRED_TAG_REF}^{}")"

  [[ "$tag_obj" == "$CORE_TAG_OBJECT" ]] || \
    die "${label}: tag object $tag_obj expected $CORE_TAG_OBJECT"
  [[ "$peeled" == "$CORE_PEELED_COMMIT" ]] || \
    die "${label}: peeled commit $peeled expected $CORE_PEELED_COMMIT"
}

build_one() {
  local clone_dir="$1"
  local out_dir="$2"
  local label="$3"

  echo "=== clone ${label}: ${REPO_URL} ===" >&2
  git -c advice.detachedHead=false clone --quiet "$REPO_URL" "$clone_dir"

  # Tag must exist before any configure/build.
  require_official_tag "$clone_dir" "$label"

  echo "=== checkout peeled commit (${label}): ${CORE_PEELED_COMMIT} ===" >&2
  git -C "$clone_dir" checkout --quiet "$CORE_PEELED_COMMIT"

  local head
  head="$(git -C "$clone_dir" rev-parse HEAD)"
  [[ "$head" == "$CORE_PEELED_COMMIT" ]] || die "${label}: HEAD=$head expected $CORE_PEELED_COMMIT"

  # Re-verify tag object/peel after checkout (no optional branch).
  require_official_tag "$clone_dir" "$label"

  echo "=== configure/build amalgamation (${label}) ===" >&2
  (
    cd "$clone_dir"
    ./configure --with-tempstore=yes \
      CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown" \
      >/dev/null
    if make -n sqlite3.c >/dev/null 2>&1; then
      make sqlite3.c >/dev/null
    else
      make >/dev/null
    fi
    test -f sqlite3.c || die "${label}: sqlite3.c missing after build"
    test -f sqlite3.h || die "${label}: sqlite3.h missing after build"
    test -f manifest || die "${label}: manifest missing"
    test -f manifest.uuid || die "${label}: manifest.uuid missing"
  )

  cp "$clone_dir/sqlite3.c" "$out_dir/sqlite3.c"
  cp "$clone_dir/sqlite3.h" "$out_dir/sqlite3.h"
  cp "$clone_dir/manifest" "$out_dir/manifest"
  cp "$clone_dir/manifest.uuid" "$out_dir/manifest.uuid"
  if [[ -f "$clone_dir/LICENSE" ]]; then
    cp "$clone_dir/LICENSE" "$out_dir/LICENSE"
  elif [[ -f "$clone_dir/LICENSE.md" ]]; then
    cp "$clone_dir/LICENSE.md" "$out_dir/LICENSE"
  else
    die "${label}: LICENSE missing in SQLCipher checkout"
  fi

  echo "=== hashes (${label}) ===" >&2
  local hc hh hm hu
  hc="$(sha256_file "$out_dir/sqlite3.c")"
  hh="$(sha256_file "$out_dir/sqlite3.h")"
  hm="$(sha256_file "$out_dir/manifest")"
  hu="$(sha256_file "$out_dir/manifest.uuid")"
  echo "sqlite3.c     $hc" >&2
  echo "sqlite3.h     $hh" >&2
  echo "manifest      $hm" >&2
  echo "manifest.uuid $hu" >&2
  [[ "$hc" == "$EXPECTED_SQLITE3_C" ]] || die "${label}: sqlite3.c hash mismatch"
  [[ "$hh" == "$EXPECTED_SQLITE3_H" ]] || die "${label}: sqlite3.h hash mismatch"
  [[ "$hm" == "$EXPECTED_MANIFEST" ]] || die "${label}: manifest hash mismatch"
  [[ "$hu" == "$EXPECTED_MANIFEST_UUID" ]] || die "${label}: manifest.uuid hash mismatch"
}

build_one "$A_DIR" "$A_OUT" "A"
build_one "$B_DIR" "$B_OUT" "B"

echo "=== byte-for-byte compare A vs B ===" >&2
diff -qr "$A_OUT" "$B_OUT" >/dev/null || die "clone A and B outputs differ"
for f in sqlite3.c sqlite3.h manifest manifest.uuid LICENSE; do
  cmp -s "$A_OUT/$f" "$B_OUT/$f" || die "byte mismatch on $f"
done
echo "PASS: A and B outputs identical" >&2

echo "=== reject untracked generated amalgamation sidecars ===" >&2
for clone_dir in "$A_DIR" "$B_DIR"; do
  count="$(find "$clone_dir" -maxdepth 1 -type f -name 'sqlite3*.c' | wc -l | tr -d ' ')"
  [[ "$count" == "1" ]] || die "expected exactly one sqlite3*.c at repo root, found $count"
  while IFS= read -r path; do
    base="$(basename "$path")"
    [[ "$base" == "sqlite3.c" ]] || die "unexpected generated C at repo root: $path"
  done < <(find "$clone_dir" -maxdepth 1 -type f -name 'sqlite3*.c' -print)
done
echo "PASS: no unexpected amalgamation sidecars" >&2

echo "=== install into ${OUT_DIR} ===" >&2
mkdir -p "$OUT_DIR"
cp "$A_OUT/sqlite3.c" "$OUT_DIR/sqlite3.c"
cp "$A_OUT/sqlite3.h" "$OUT_DIR/sqlite3.h"
cp "$A_OUT/manifest" "$OUT_DIR/manifest"
cp "$A_OUT/manifest.uuid" "$OUT_DIR/manifest.uuid"
cp "$A_OUT/LICENSE" "$OUT_DIR/LICENSE"
# Deterministic provenance docs so custom OUT_DIR is fully verifiable.
cp "$TEMPLATE_DIR/PROVENANCE.md" "$OUT_DIR/PROVENANCE.md"
cp "$TEMPLATE_DIR/NOTICE" "$OUT_DIR/NOTICE"

echo "PASS: regenerated SQLCipher 4.17.0 amalgamation into $OUT_DIR" >&2
echo "VERIFY: SQLCIPHER_PROVENANCE_DIR=\"$OUT_DIR\" ./node/scripts/verify_sqlcipher_4_17.sh" >&2
