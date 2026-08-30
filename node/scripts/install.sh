#!/usr/bin/env bash
# RAVEN source installer. Download it, inspect it, then run it; do not pipe a
# mutable network response directly into a shell.
set -euo pipefail

REPO="https://github.com/Ahmadreza-Arezehgar/RAVEN.git"
DIR="${RAVEN_DIR:-$HOME/RAVEN}"
REF="${RAVEN_INSTALL_REF:-main}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "Git is required"
case "$REF" in
  HEAD|refs/*)
    die "RAVEN_INSTALL_REF must be an unqualified branch or tag name, not '$REF'"
    ;;
  -*|*@{*)
    die "RAVEN_INSTALL_REF contains option/reflog syntax and is not allowed: '$REF'"
    ;;
esac
if ! git check-ref-format --branch "$REF" >/dev/null 2>&1; then
  die "RAVEN_INSTALL_REF is not a safe Git branch/tag name: '$REF'"
fi

echo "▸ RAVEN installer — target: $DIR"
echo "▸ Requested Git ref: $REF"

HOST_OS="$(uname -s)"
case "$HOST_OS" in
  Darwin)
    MACOS_LAB_ACK_VALUE="I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK"
    if [ "${RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK:-}" != "$MACOS_LAB_ACK_VALUE" ]; then
      echo "ERROR: macOS source installation is held at the Keychain identity-handoff gate." >&2
      echo "The separate raven and raven-node Release executables have not passed the" >&2
      echo "required signed physical-Mac identity-continuity test. No files were changed." >&2
      echo "For an isolated, disposable lab only, acknowledge the hang/identity-split risk with:" >&2
      echo "RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK=$MACOS_LAB_ACK_VALUE" >&2
      exit 2
    fi
    echo "WARNING: unsafe review-only macOS source-install override is active" >&2
    echo "WARNING: do not treat the linked raven-node binary as a validated service" >&2
    ;;
  Linux)
    die "Linux release install is blocked in R1: no approved protected identity backend is enabled; Raven will not fall back to locked-file or demo identity storage"
    ;;
  *)
    die "this shell installer supports macOS only while Linux R1 is held; use the documented native Windows build/service flow on Windows"
    ;;
esac

# 1) Rust toolchain. The installer never pipes remote code into a shell or
# silently modifies the user's toolchain; install Rust separately and rerun.
if ! command -v cargo >/dev/null 2>&1; then
  die "Rust/Cargo is required; install it from https://rustup.rs, verify the installer, then rerun Raven setup"
fi
export PATH="$HOME/.cargo/bin:$PATH"

# 2) Source — resolve the requested branch/tag to one commit, then check out
# that exact commit. The default remains `main`; feature testing can explicitly
# set RAVEN_INSTALL_REF. Never discard local work.
if [ -d "$DIR/.git" ]; then
  [ ! -L "$DIR" ] || die "$DIR is a symlink; choose the real checkout path explicitly"
  ORIGIN_URL="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
  case "${ORIGIN_URL%.git}" in
    "${REPO%.git}"|"git@github.com:Ahmadreza-Arezehgar/RAVEN"|"ssh://git@github.com/Ahmadreza-Arezehgar/RAVEN") ;;
    *) die "$DIR is not a recognized RAVEN checkout (origin=$ORIGIN_URL); refusing to modify it" ;;
  esac

  BRANCH="$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "$REF" ]; then
    die "$DIR is on branch '$BRANCH', not requested ref '$REF'; preserve it and use another RAVEN_DIR or switch it explicitly"
  fi

  if ! DIRTY_STATUS="$(git -C "$DIR" status --porcelain --untracked-files=normal)"; then
    die "could not inspect local changes in $DIR; refusing to update it"
  fi
  if [ -n "$DIRTY_STATUS" ]; then
    git -C "$DIR" status --short >&2
    die "$DIR has local changes/untracked files; commit, stash, or choose another RAVEN_DIR"
  fi

  echo "▸ Fetching requested ref into the existing clean checkout…"
  git -C "$DIR" fetch --depth 1 origin "$REF"
  RESOLVED_COMMIT="$(git -C "$DIR" rev-parse --verify 'FETCH_HEAD^{commit}')" \
    || die "requested ref '$REF' did not resolve to a commit"
  git -C "$DIR" checkout --detach "$RESOLVED_COMMIT"
elif [ -e "$DIR" ]; then
  die "$DIR already exists but is not a Git checkout; choose another RAVEN_DIR or move it aside"
else
  echo "▸ Cloning requested ref…"
  git clone --depth 1 --single-branch --branch "$REF" "$REPO" "$DIR"
  RESOLVED_COMMIT="$(git -C "$DIR" rev-parse --verify 'HEAD^{commit}')" \
    || die "requested ref '$REF' did not resolve to a commit"
  git -C "$DIR" checkout --detach "$RESOLVED_COMMIT"
fi

ACTUAL_COMMIT="$(git -C "$DIR" rev-parse --verify HEAD)"
[ "$ACTUAL_COMMIT" = "$RESOLVED_COMMIT" ] \
  || die "checkout verification failed: expected $RESOLVED_COMMIT, found $ACTUAL_COMMIT"
echo "▸ Checked out exact commit: $ACTUAL_COMMIT"

# 3) Build the production profile with default, fail-closed crypto features.
cd "$DIR/node"
echo "▸ Building (first run takes a few minutes)…"
cargo build -q --locked --release -p ash -p raven-node
BIN="$PWD/target/release"

# 4) Stable ad-hoc signature → macOS network/firewall prompt appears once per
#    binary instead of after every rebuild.
if [ "$(uname)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  codesign -f -s - "$BIN/raven" "$BIN/raven-node" >/dev/null 2>&1 || true
fi

# 5) Put `raven` / `raven-node` on PATH
if [ -L "$HOME/.local" ] || [ -L "$HOME/.local/bin" ]; then
  die "refusing a symlinked ~/.local or ~/.local/bin; choose/install the links manually"
fi
mkdir -p "$HOME/.local/bin"
validate_link() {
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
}
RAVEN_LINK="$HOME/.local/bin/raven"
NODE_LINK="$HOME/.local/bin/raven-node"
validate_link "$BIN/raven" "$RAVEN_LINK"
validate_link "$BIN/raven-node" "$NODE_LINK"

# Validate both destinations before changing either one, then roll back only
# links created by this run if the second filesystem operation fails.
RAVEN_LINK_CREATED=0
NODE_LINK_CREATED=0
LINK_INSTALL_COMMITTED=0
rollback_links() {
  [ "$LINK_INSTALL_COMMITTED" -eq 0 ] || return 0
  if [ "$NODE_LINK_CREATED" -eq 1 ] && [ -L "$NODE_LINK" ] \
    && [ "$(readlink "$NODE_LINK")" = "$BIN/raven-node" ]; then
    rm -f -- "$NODE_LINK"
  fi
  if [ "$RAVEN_LINK_CREATED" -eq 1 ] && [ -L "$RAVEN_LINK" ] \
    && [ "$(readlink "$RAVEN_LINK")" = "$BIN/raven" ]; then
    rm -f -- "$RAVEN_LINK"
  fi
}
trap rollback_links EXIT HUP INT TERM
if [ ! -L "$RAVEN_LINK" ]; then
  ln -s "$BIN/raven" "$RAVEN_LINK"
  RAVEN_LINK_CREATED=1
fi
if [ ! -L "$NODE_LINK" ]; then
  ln -s "$BIN/raven-node" "$NODE_LINK"
  NODE_LINK_CREATED=1
fi
LINK_INSTALL_COMMITTED=1
trap - EXIT HUP INT TERM
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    echo "NOTE: ~/.local/bin is not on PATH. Raven did not edit shell startup files."
    echo 'Add this yourself: export PATH="$HOME/.local/bin:$PATH"'
    ;;
esac

echo
echo "⚠️  RAVEN macOS lab links installed — REVIEW ONLY."
echo "   Foreground terminal inspection: raven --help"
echo "   Do not distribute this layout or run raven-node as an always-on service"
echo "   until the signed physical-Keychain identity-continuity gate is cleared."
