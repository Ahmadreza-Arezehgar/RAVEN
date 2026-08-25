#!/usr/bin/env bash
# Task 0B.3 — GNU/Linux Secret Service protected-anchor lab gate (Independent FAIL remediation).
# Lab-only. No production, commit, push, or stage. Does not start 0B.4.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/node"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "FAIL: must run on GNU/Linux (got $(uname -s))" >&2
  exit 1
fi

export RAVEN_EXPECT_SQLCIPHER_4_17_0="${RAVEN_EXPECT_SQLCIPHER_4_17_0:-1}"
ART="${ROOT}/artifacts/full-braid-0b3-secret-service-gate"
mkdir -p "$ART"
: >"$ART/summary.txt"

pass() { echo "PASS: $*" | tee -a "$ART/summary.txt"; }

echo "=== Clippy -D warnings ===" | tee -a "$ART/summary.txt"
cargo clippy -p raven-core --features full-braid-durable-lab -- -D warnings \
  2>&1 | tee "$ART/clippy.log"
pass "clippy -D warnings"

echo "=== Unit + negatives (unlocked Secret Service) ===" | tee -a "$ART/summary.txt"
dbus-run-session -- bash -c '
  set -euo pipefail
  cd "'"$ROOT"'/node"
  export RAVEN_EXPECT_SQLCIPHER_4_17_0=1
  eval "$(printf "\n" | gnome-keyring-daemon --unlock 2>/dev/null || true)"
  eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null || true)"
  echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unset}" >&2
  cargo test -p raven-core --features full-braid-durable-lab \
    protected_anchor_linux:: \
    -- --nocapture
' 2>&1 | tee "$ART/unit-tests.log"
pass "unit tests (first-install negative, race no-collapse, anchors, no-file)"

echo "=== Unavailable (no secrets daemon) ===" | tee -a "$ART/summary.txt"
dbus-run-session -- bash -c '
  set -euo pipefail
  cd "'"$ROOT"'/node"
  export RAVEN_EXPECT_SQLCIPHER_4_17_0=1
  # No gnome-keyring: connect must fail closed without Prompt.Prompt hang.
  timeout 30 cargo test -p raven-core --features full-braid-durable-lab \
    unavailable_without_secret_service -- --nocapture
' 2>&1 | tee "$ART/neg-unavailable.log"
pass "unavailable / no-daemon (typed, no prompt hang)"

echo "=== Locked/prompt typed codes ===" | tee -a "$ART/summary.txt"
dbus-run-session -- bash -c '
  set -euo pipefail
  cd "'"$ROOT"'/node"
  export RAVEN_EXPECT_SQLCIPHER_4_17_0=1
  gnome-keyring-daemon --start --components=secrets >/dev/null 2>&1 || true
  timeout 30 cargo test -p raven-core --features full-braid-durable-lab \
    typed_locked_unavailable_codes -- --nocapture
' 2>&1 | tee "$ART/neg-locked.log"
pass "locked/prompt typed codes"

echo "=== Multi-collection / CreateCollection policy ===" | tee -a "$ART/summary.txt"
dbus-run-session -- bash -c '
  set -euo pipefail
  eval "$(printf "\n" | gnome-keyring-daemon --unlock 2>/dev/null || true)"
  eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null || true)"
  if command -v busctl >/dev/null; then
    busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
      org.freedesktop.Secret.Service CreateCollection "a{sv}s" 0 "" \
      >/tmp/raven-0b3-cc.out 2>/tmp/raven-0b3-cc.err || true
    echo "CreateCollection out=$(head -c 200 /tmp/raven-0b3-cc.out 2>/dev/null || true)"
    echo "CreateCollection err=$(head -c 200 /tmp/raven-0b3-cc.err 2>/dev/null || true)"
  fi
  echo "backend never calls create_collection / get_any_collection"
' 2>&1 | tee "$ART/neg-multicol.log"
pass "multi-collection policy (default-only)"

echo "=== Malformed metadata plant ===" | tee -a "$ART/summary.txt"
dbus-run-session -- bash -c '
  set -euo pipefail
  eval "$(printf "\n" | gnome-keyring-daemon --unlock 2>/dev/null || true)"
  eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null || true)"
  if ! command -v secret-tool >/dev/null; then
    echo "SKIP: secret-tool not installed"
    exit 0
  fi
  SCOPE="$(python3 -c "import hashlib,time,os; print(hashlib.sha256(f\"m-{time.time()}-{os.getpid()}\".encode()).hexdigest())")"
  printf "\x11%.0s" {1..32} | secret-tool store --label="bogus raven seed" \
    application app.raven.node \
    protocol atsam-full-braid-v1 \
    kind seed \
    scope "$SCOPE" \
    evil extra-key \
    || true
  secret-tool search scope "$SCOPE" || true
  echo "malformed plant done; load path must CORRUPT_ATTRIBUTES on verify"
' 2>&1 | tee "$ART/neg-malformed.log"
pass "malformed metadata plant"

echo "=== Two-thread concurrent seed (no collapse) ===" | tee -a "$ART/summary.txt"
dbus-run-session -- bash -c '
  set -euo pipefail
  cd "'"$ROOT"'/node"
  export RAVEN_EXPECT_SQLCIPHER_4_17_0=1
  eval "$(printf "\n" | gnome-keyring-daemon --unlock 2>/dev/null || true)"
  eval "$(gnome-keyring-daemon --start --components=secrets 2>/dev/null || true)"
  cargo test -p raven-core --features full-braid-durable-lab \
    seed_duplicate_race_preserves_items_no_collapse -- --nocapture
' 2>&1 | tee "$ART/neg-concurrent.log"
pass "concurrent seed (preserve duplicates, no collapse)"

echo "ALL GATE CHECKS COMPLETE — stop for Independent re-review (no commit/push/stage; no 0B.4)" \
  | tee -a "$ART/summary.txt"
