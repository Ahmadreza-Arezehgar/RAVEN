#!/usr/bin/env bash
# Portable first-run for Raven `ash` (serverless terminal).
# Detects repo from this script — never hardcodes /Users/ahmd.
#
# Usage:
#   bash scripts/ash_first_run.sh              # build + interactive ash
#   bash scripts/ash_first_run.sh --no-run     # build only
#   bash scripts/ash_first_run.sh --init-only  # build + init + whoami, then exit
#
# FA / EN — Persian + English errors when rustc/cargo missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NODE_DIR="$REPO_ROOT/node"
# Stable profile — NEVER mktemp (new identity every run breaks iPhone Peer pub).
DATA_DIR="${ASH_DATA_DIR:-$HOME/.raven-ash}"

NO_RUN=0
INIT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --no-run) NO_RUN=1 ;;
    --init-only) INIT_ONLY=1 ;;
    -h|--help)
      cat <<'EOF'
ash_first_run.sh — portable Raven ash bootstrap

  Detects hybrid_messenger repo relative to this script (any username/home).
  Builds ash + raven-node + raven-core, then launches ash with ~/.raven-ash
  (stable identity — re-use the same Mac whoami on iPhone).

  --no-run      build only
  --init-only   build, init identity, print whoami, exit

  Override profile: ASH_DATA_DIR=/path bash scripts/ash_first_run.sh
EOF
      exit 0
      ;;
  esac
done

export PATH="${HOME}/.cargo/bin:${PATH}"
# Avoid macOS Keychain prompts hanging ash whoami/init in Terminal.
export RAVEN_IDENTITY_BACKEND="${RAVEN_IDENTITY_BACKEND:-locked-file}"

die_tooling() {
  echo "ERROR: $1" >&2
  echo "FA: Rust لازم است — https://rustup.rs" >&2
  echo "EN: Install Rust from https://rustup.rs then re-run." >&2
  exit 1
}

command -v rustc >/dev/null || die_tooling "rustc not found"
command -v cargo >/dev/null || die_tooling "cargo not found"

echo "repo:  $REPO_ROOT"
echo "node:  $NODE_DIR"
echo "data:  $DATA_DIR  (stable — keep this for iPhone Peer pub)"
echo "rustc: $(rustc --version)"
echo "cargo: $(cargo --version)"
echo

cd "$NODE_DIR"
echo "Building ash + raven-node + raven-core…"
cargo build -p ash -p raven-node -p raven-core

ASH="$NODE_DIR/target/debug/ash"
if [[ ! -x "$ASH" ]]; then
  echo "ERROR: ash binary missing at $ASH" >&2
  exit 1
fi

mkdir -p "$DATA_DIR"

if [[ "$NO_RUN" -eq 1 ]]; then
  echo "Build OK — skip launch (--no-run)."
  echo "Next: $ASH --data-dir \"$DATA_DIR\""
  echo "Or:   $ASH   (defaults to ~/.raven-ash)"
  exit 0
fi

if [[ "$INIT_ONLY" -eq 1 ]]; then
  "$ASH" --data-dir "$DATA_DIR" init
  echo "--- whoami (share these public bits only) ---"
  "$ASH" --data-dir "$DATA_DIR" whoami
  echo
  echo "FA: فقط address / fingerprint / pub_hex را بفرستید — هرگز seed را نه."
  echo "EN: Share address / fingerprint / pub_hex only — never a seed."
  exit 0
fi

echo "Launching interactive ash…"
echo "FA: منوی ۴ Status هویت می‌سازد؛ منوی ۳ مخاطب؛ منوی ۲ ارسال."
echo "EN: Menu 4 Status creates identity; 3 Contacts; 2 Send/Chat."
echo "FA: دیگر mktemp نزنید — هویت مک ثابت می‌ماند."
echo
exec "$ASH" --data-dir "$DATA_DIR"
