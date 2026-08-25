#!/usr/bin/env bash
# RAVEN one-line installer
#   curl -fsSL https://raw.githubusercontent.com/Ahmadreza-Arezehgar/RAVEN/main/scripts/install.sh | bash
set -euo pipefail

REPO="https://github.com/Ahmadreza-Arezehgar/RAVEN.git"
DIR="${RAVEN_DIR:-$HOME/RAVEN}"

echo "▸ RAVEN installer — target: $DIR"

# 1) Rust toolchain
if ! command -v cargo >/dev/null 2>&1; then
  echo "▸ Installing Rust toolchain…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
export PATH="$HOME/.cargo/bin:$PATH"

# 2) Source — clone or hard-reset to origin/main (history is rewritten-safe)
if [ -d "$DIR/.git" ]; then
  echo "▸ Updating existing checkout…"
  git -C "$DIR" fetch origin
  git -C "$DIR" reset --hard origin/main
else
  echo "▸ Cloning…"
  git clone --depth 1 "$REPO" "$DIR"
fi

# 3) Build (debug + lab feature so the two-Mac demo lane works)
cd "$DIR/node"
echo "▸ Building (first run takes a few minutes)…"
cargo build -q -p ash -p raven-node --features raven-node/unsafe-demo-crypto
BIN="$PWD/target/debug"

# 4) Stable ad-hoc signature → macOS network/firewall prompt appears once per
#    binary instead of after every rebuild.
if [ "$(uname)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  codesign -f -s - "$BIN/ash" "$BIN/raven-node" >/dev/null 2>&1 || true
fi

# 5) Put `raven` / `raven-node` on PATH
mkdir -p "$HOME/.local/bin"
ln -sf "$BIN/ash"        "$HOME/.local/bin/raven"
ln -sf "$BIN/raven-node" "$HOME/.local/bin/raven-node"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -f "$rc" ] || continue
      grep -q '.local/bin' "$rc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >>"$rc"
    done
    ;;
esac

echo
echo "✅ RAVEN ready."
echo "   New terminal, then just run:   raven"
echo "   (identity → menu 8 Tutorial · receive → menu 4 Listen)"
