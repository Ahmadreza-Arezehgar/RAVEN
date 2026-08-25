#!/usr/bin/env bash
# Negative tests for the read-only R0 provenance verifier.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/node/third_party/secret-service-2.0.2-raven-noprompt"
VERIFY="$ROOT/node/scripts/verify_secret_service_2_0_2_raven_noprompt.sh"
WORK_PARENT="${RAVEN_SS_VERIFY_WORK_PARENT:-${TMPDIR:-/tmp}}"
[[ -d "$WORK_PARENT" && ! -L "$WORK_PARENT" && -w "$WORK_PARENT" ]] || {
  echo "SECRET_SERVICE_R0_SELFTEST_FAIL: unsafe work parent" >&2
  exit 1
}
WORK="$(mktemp -d "$WORK_PARENT/raven-secret-service-r0-selftest.XXXXXX")"
SENTINEL="$WORK/.raven-secret-service-r0-owned"
: >"$SENTINEL"

cleanup() {
  [[ -n "${WORK:-}" && -d "$WORK" && ! -L "$WORK" ]] || return 0
  [[ "$(basename "$WORK")" == raven-secret-service-r0-selftest.* ]] || return 0
  [[ -f "$SENTINEL" ]] || return 0
  find "$WORK" -depth -delete
}
trap cleanup EXIT

ARCHIVE="$WORK/secret-service-2.0.2.crate"
curl -A 'cargo/1.97' -fsSL \
  https://static.crates.io/crates/secret-service/secret-service-2.0.2.crate \
  -o "$ARCHIVE"

run_verify() {
  RAVEN_SS_CRATE_ARCHIVE="$ARCHIVE" RAVEN_SS_FORK_DIR="$1" "$VERIFY"
}

expect_reject() {
  local name="$1"
  local fork="$2"
  if run_verify "$fork" >"$WORK/$name.log" 2>&1; then
    echo "SECRET_SERVICE_R0_SELFTEST_FAIL: accepted $name" >&2
    exit 1
  fi
  printf 'negative-ok %s\n' "$name"
}

run_verify "$SOURCE"

cp -R "$SOURCE" "$WORK/modified-unlisted"
printf '\n// provenance negative\n' >>"$WORK/modified-unlisted/src/lib.rs"
expect_reject modified_unlisted "$WORK/modified-unlisted"

cp -R "$SOURCE" "$WORK/extra-file"
printf 'unexpected\n' >"$WORK/extra-file/EXTRA"
expect_reject extra_file "$WORK/extra-file"

cp -R "$SOURCE" "$WORK/symlink"
ln -s Cargo.toml "$WORK/symlink/UNSAFE_LINK"
expect_reject symlink "$WORK/symlink"

cp -R "$SOURCE" "$WORK/missing"
mv "$WORK/missing/src/lib.rs" "$WORK/missing/src/lib.rs.removed"
expect_reject missing_file "$WORK/missing"

cp -R "$SOURCE" "$WORK/stale-digest"
printf '\n# stale digest negative\n' >>"$WORK/stale-digest/src/item.rs"
expect_reject stale_digest "$WORK/stale-digest"

echo "SECRET_SERVICE_R0_PROVENANCE_SELFTEST_OK"
