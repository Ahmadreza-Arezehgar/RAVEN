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
  Builds ash + raven-node + raven-core, then launches ash with an ephemeral data dir.

  --no-run      build only
  --init-only   build, init identity, print whoami, exit
EOF
      exit 0
      ;;
  esac
done

export PATH="${HOME}/.cargo/bin:${PATH}"

die_tooling() {
  cat <<'EOF' >&2

╔══════════════════════════════════════════════════════════════════╗
║  Missing Rust toolchain (rustc / cargo)                          ║
║  ابزار Rust نصب نیست (rustc / cargo)                             ║
╠══════════════════════════════════════════════════════════════════╣
║  EN: Install from https://rustup.rs then re-run this script.     ║
║  FA: از https://rustup.rs نصب کنید، بعد دوباره این اسکریپت را    ║
║      اجرا کنید.                                                  ║
║                                                                  ║
║  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh  ║
║  source "$HOME/.cargo/env"                                       ║
╚══════════════════════════════════════════════════════════════════╝

EOF
  exit 1
}

command -v rustc >/dev/null 2>&1 || die_tooling
command -v cargo >/dev/null 2>&1 || die_tooling

if [[ ! -f "$NODE_DIR/Cargo.toml" ]]; then
  echo "ERROR: node/Cargo.toml not found under $REPO_ROOT" >&2
  echo "خطا: پوشه node در کنار scripts پیدا نشد — کل ریپو را کلون/کپی کنید." >&2
  exit 1
fi

echo "=== Raven ash first-run ==="
echo "repo:  $REPO_ROOT"
echo "node:  $NODE_DIR"
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

if [[ "$NO_RUN" -eq 1 ]]; then
  echo "Build OK — skip launch (--no-run)."
  echo "Next: DATA=\$(mktemp -d); $ASH --data-dir \"\$DATA\""
  exit 0
fi

DATA="$(mktemp -d "${TMPDIR:-/tmp}/raven-ash-XXXXXX")"
echo "Data dir: $DATA"
echo "(ephemeral — delete when done: rm -rf \"$DATA\")"
echo

if [[ "$INIT_ONLY" -eq 1 ]]; then
  "$ASH" --data-dir "$DATA" init
  echo "--- whoami (share these public bits only) ---"
  "$ASH" --data-dir "$DATA" whoami
  echo
  echo "FA: فقط address / fingerprint / pub_hex را بفرستید — هرگز seed را نه."
  echo "EN: Share address / fingerprint / pub_hex only — never a seed."
  exit 0
fi

echo "Launching interactive ash…"
echo "FA: منوی ۴ Status هویت می‌سازد؛ منوی ۳ مخاطب؛ منوی ۲ ارسال."
echo "EN: Menu 4 Status creates identity; 3 Contacts; 2 Send/Chat."
echo
exec "$ASH" --data-dir "$DATA"
