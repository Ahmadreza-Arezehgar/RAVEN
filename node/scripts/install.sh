#!/usr/bin/env bash
# RAVEN one-line installer
#   curl -fsSL https://raw.githubusercontent.com/Ahmadreza-Arezehgar/RAVEN/main/node/scripts/install.sh | bash
set -euo pipefail

REPO="https://github.com/Ahmadreza-Arezehgar/RAVEN.git"
DIR="${RAVEN_DIR:-$HOME/RAVEN}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

echo "▸ RAVEN installer — target: $DIR"

HOST_OS="$(uname -s)"
case "$HOST_OS" in
  Darwin) ;;
  Linux)
    die "Linux release install is blocked in R1: no approved protected identity backend is enabled; Raven will not fall back to locked-file or demo identity storage"
    ;;
  *)
    die "this shell installer supports macOS only while Linux R1 is held; use the documented native Windows build/service flow on Windows"
    ;;
esac

# 1) Rust toolchain
if ! command -v cargo >/dev/null 2>&1; then
  echo "▸ Installing Rust toolchain…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
export PATH="$HOME/.cargo/bin:$PATH"

# 2) Source — update only a clean main checkout. Never discard local work.
if [ -d "$DIR/.git" ]; then
  ORIGIN_URL="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
  case "${ORIGIN_URL%.git}" in
    "${REPO%.git}"|"git@github.com:Ahmadreza-Arezehgar/RAVEN"|"ssh://git@github.com/Ahmadreza-Arezehgar/RAVEN") ;;
    *) die "$DIR is not a recognized RAVEN checkout (origin=$ORIGIN_URL); refusing to modify it" ;;
  esac

  BRANCH="$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [ "$BRANCH" = "main" ] || die "$DIR is on branch '${BRANCH:-detached}', not main; preserve it and update manually"

  if ! DIRTY_STATUS="$(git -C "$DIR" status --porcelain --untracked-files=normal)"; then
    die "could not inspect local changes in $DIR; refusing to update it"
  fi
  if [ -n "$DIRTY_STATUS" ]; then
    git -C "$DIR" status --short >&2
    die "$DIR has local changes/untracked files; commit, stash, or choose another RAVEN_DIR"
  fi

  echo "▸ Updating existing checkout…"
  git -C "$DIR" fetch --prune origin main
  if ! git -C "$DIR" merge --ff-only origin/main; then
    die "local main diverged from origin/main; no files were discarded — reconcile manually"
  fi
elif [ -e "$DIR" ]; then
  die "$DIR already exists but is not a Git checkout; choose another RAVEN_DIR or move it aside"
else
  echo "▸ Cloning…"
  git clone --depth 1 "$REPO" "$DIR"
fi

# 3) Build the production profile with default, fail-closed crypto features.
cd "$DIR/node"
echo "▸ Building (first run takes a few minutes)…"
cargo build -q --locked --release -p ash -p raven-node
BIN="$PWD/target/release"

# 4) Stable ad-hoc signature → macOS network/firewall prompt appears once per
#    binary instead of after every rebuild.
if [ "$(uname)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  codesign -f -s - "$BIN/ash" "$BIN/raven-node" >/dev/null 2>&1 || true
fi

# 5) Put `raven` / `raven-node` on PATH
mkdir -p "$HOME/.local/bin"
install_link() {
  local source="$1"
  local destination="$2"
  if [ -L "$destination" ]; then
    local current
    current="$(readlink "$destination")"
    if [ "$current" != "$source" ]; then
      die "$destination is an existing symlink to '$current'; refusing to replace it"
    fi
    return 0
  fi
  if [ -e "$destination" ]; then
    die "$destination already exists and is not this installer's symlink; refusing to overwrite it"
  fi
  ln -s "$source" "$destination"
}
install_link "$BIN/ash" "$HOME/.local/bin/raven"
install_link "$BIN/raven-node" "$HOME/.local/bin/raven-node"
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
