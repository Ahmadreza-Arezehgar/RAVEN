#!/usr/bin/env bash
# Verify frozen SQLCipher 4.17.0 provenance.
#
# Modes:
#   SQLCIPHER_VERIFY_MODE=full (default)
#     Requires PROVENANCE.md + NOTICE + amalgamation + LICENSE; checks pins/docs.
#   SQLCIPHER_VERIFY_MODE=generated-only
#     Official generated-artifact verification: sqlite3.c/h, manifest,
#     manifest.uuid, LICENSE required; PROVENANCE.md/NOTICE optional if present.
#
# Allow-list: every top-level entry must be an allowed name; nested entries,
# directories, and symlinks are rejected. Required artifacts must be non-symlink
# regular files.
#
# Usage:
#   ./node/scripts/verify_sqlcipher_4_17.sh
#   SQLCIPHER_PROVENANCE_DIR=/tmp/... ./node/scripts/verify_sqlcipher_4_17.sh
#   SQLCIPHER_VERIFY_MODE=generated-only SQLCIPHER_PROVENANCE_DIR=... ./node/scripts/verify_sqlcipher_4_17.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${SQLCIPHER_PROVENANCE_DIR:-$ROOT/node/third_party/sqlcipher-4.17.0}"
MODE="${SQLCIPHER_VERIFY_MODE:-full}"

CORE_TAG_OBJECT="f9788efa8ac4dfed75c03e4756b1666a1d0845da"
CORE_PEELED_COMMIT="810db22f575ee7cf94ea96a3e91622b5fcece3dc"

EXPECTED_SQLITE3_C="8adaff6b464052a74e7adaa3cfa2725400f48eca68f47856fa806eaf30bdf2c9"
EXPECTED_SQLITE3_H="e564d0492e7556a8ad2f30c8ec645b5a6abb89f32f7b40465a3032d937596401"
EXPECTED_MANIFEST="6703f59d2307674e09b55297c7832819ef44fb590691314a4da36f8240e41473"
EXPECTED_MANIFEST_UUID="3ec90494f84736dd7efd0f49a06b787d3f791e0d6b2b1e0bce66fa792d6107e4"

OPENSSL_SRC_CRATE_VERSION="300.6.1+3.6.3"
OPENSSL_VERSION="3.6.3"
OPENSSL_SRC_CRATE_SHA256="46eb8fb9fb3b61ce1c0f8a026c4c1a0714d3a9e138e7fbde78753ce2babc3846"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

die() {
  echo "FAIL: $*" >&2
  exit 1
}

is_allowed_name() {
  case "$1" in
    PROVENANCE.md|LICENSE|NOTICE|sqlite3.c|sqlite3.h|manifest|manifest.uuid) return 0 ;;
    *) return 1 ;;
  esac
}

require_regular_nonsymlink_file() {
  local path="$1"
  local label="${2:-$path}"
  [[ -e "$path" || -L "$path" ]] || die "missing required file $label"
  if [[ -L "$path" ]]; then
    die "symlink not allowed: $label"
  fi
  if [[ -d "$path" ]]; then
    die "directory not allowed: $label"
  fi
  if [[ ! -f "$path" ]]; then
    die "not a regular file: $label"
  fi
}

case "$MODE" in
  full|generated-only) ;;
  *)
    die "unknown SQLCIPHER_VERIFY_MODE=$MODE (expected full|generated-only)"
    ;;
esac

echo "=== verify SQLCipher 4.17.0 provenance (mode=$MODE) ===" >&2
echo "dir=$DIR" >&2
[[ -n "$DIR" ]] || die "empty provenance dir"
[[ -e "$DIR" || -L "$DIR" ]] || die "missing $DIR"
if [[ -L "$DIR" ]]; then
  die "provenance dir must not be a symlink: $DIR"
fi
[[ -d "$DIR" ]] || die "provenance path is not a directory: $DIR"

# No nested entries anywhere under the provenance dir.
while IFS= read -r path; do
  die "nested entry not allowed: ${path#$DIR/}"
done < <(find "$DIR" -mindepth 2 -print)

if [[ "$MODE" == "full" ]]; then
  REQUIRED=(PROVENANCE.md LICENSE NOTICE sqlite3.c sqlite3.h manifest manifest.uuid)
else
  REQUIRED=(LICENSE sqlite3.c sqlite3.h manifest manifest.uuid)
fi

for f in "${REQUIRED[@]}"; do
  require_regular_nonsymlink_file "$DIR/$f" "$f"
done

# Every top-level entry must be an allow-listed non-symlink regular file.
while IFS= read -r -d '' path; do
  name="$(basename "$path")"
  if [[ "$name" == "." || "$name" == ".." ]]; then
    continue
  fi
  if [[ -L "$path" ]]; then
    die "symlink not allowed: $name"
  fi
  if [[ -d "$path" ]]; then
    die "directory not allowed: $name"
  fi
  if [[ ! -f "$path" ]]; then
    die "not a regular file: $name"
  fi
  if ! is_allowed_name "$name"; then
    die "unexpected top-level entry: $name"
  fi
done < <(find "$DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)

# full mode: exact set — no optional extras beyond the seven required names.
if [[ "$MODE" == "full" ]]; then
  count="$(find "$DIR" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
  [[ "$count" == "7" ]] || die "full mode expects exactly 7 top-level entries, found $count"
fi

hc="$(sha256_file "$DIR/sqlite3.c")"
hh="$(sha256_file "$DIR/sqlite3.h")"
hm="$(sha256_file "$DIR/manifest")"
hu="$(sha256_file "$DIR/manifest.uuid")"

echo "sqlite3.c     $hc" >&2
echo "sqlite3.h     $hh" >&2
echo "manifest      $hm" >&2
echo "manifest.uuid $hu" >&2

[[ "$hc" == "$EXPECTED_SQLITE3_C" ]] || die "sqlite3.c SHA-256 mismatch"
[[ "$hh" == "$EXPECTED_SQLITE3_H" ]] || die "sqlite3.h SHA-256 mismatch"
[[ "$hm" == "$EXPECTED_MANIFEST" ]] || die "manifest SHA-256 mismatch"
[[ "$hu" == "$EXPECTED_MANIFEST_UUID" ]] || die "manifest.uuid SHA-256 mismatch"
echo "PASS: amalgamation SHA-256 pins match plan" >&2

if [[ "$MODE" == "full" ]]; then
  grep -q "$CORE_PEELED_COMMIT" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing peeled commit"
  grep -q "$CORE_TAG_OBJECT" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing tag object"
  grep -q "$EXPECTED_SQLITE3_C" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing sqlite3.c hash"
  grep -q "$EXPECTED_SQLITE3_H" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing sqlite3.h hash"
  grep -q "$EXPECTED_MANIFEST" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing manifest hash"
  grep -q "$EXPECTED_MANIFEST_UUID" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing manifest.uuid hash"
  grep -q "make verify-source" "$DIR/PROVENANCE.md" || die "PROVENANCE.md must explain verify-source rejection"
  grep -q "$OPENSSL_SRC_CRATE_VERSION" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing openssl-src crate version"
  grep -q "$OPENSSL_VERSION" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing OpenSSL version"
  grep -q "$OPENSSL_SRC_CRATE_SHA256" "$DIR/PROVENANCE.md" || die "PROVENANCE.md missing openssl-src crate checksum"
  grep -q "SQLCIPHER_TAG_MISSING" "$DIR/PROVENANCE.md" || die "PROVENANCE.md must document mandatory tag diagnostic"
  grep -q "generated-only" "$DIR/PROVENANCE.md" || die "PROVENANCE.md must document generated-only verify mode"
  grep -q "OpenSSL" "$DIR/NOTICE" || die "NOTICE missing OpenSSL notice"
  echo "PASS: PROVENANCE.md / NOTICE pin content" >&2
else
  echo "PASS: generated-only mode (docs optional; amalgamation pins enforced)" >&2
fi

echo "PASS: SQLCipher 4.17.0 provenance verification" >&2
