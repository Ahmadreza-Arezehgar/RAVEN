#!/usr/bin/env bash
# Non-interactive smoke for ash menus 1–4 + q (first-run + empty contacts).
# Safe: ephemeral mktemp data dirs only. No secrets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/target/debug"
ASH="$BIN/ash"
export PATH="${HOME}/.cargo/bin:${PATH}"
export NO_COLOR=1

if [[ ! -x "$ASH" ]]; then
  echo "Building ash…"
  (cd "$ROOT" && cargo build -p ash -p raven-node -q)
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/raven-ash-menu-XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Share identity across ash menu smoke without Keychain ACL issues.
export RAVEN_IDENTITY_BACKEND=locked-file

echo "=== ash menu smoke workdir=$WORKDIR ==="

# --- First-run: no identity → menu 4 creates identity ---
DATA1="$WORKDIR/fresh"
mkdir -p "$DATA1"
# Drive: 4 (status/create) → 1 (messages empty) → 2 (send → n no contact) → 3 (list → Enter) → q
printf '4\n1\n2\nn\n3\n\nq\n' | "$ASH" --data-dir "$DATA1" >"$WORKDIR/fresh.log" 2>&1 || true
grep -q 'identity created\|● identity' "$WORKDIR/fresh.log"
grep -q 'No outgoing queue yet\|Queue empty\|No local chat history' "$WORKDIR/fresh.log"
grep -q 'no contacts yet\|Add someone first\|Add a contact first' "$WORKDIR/fresh.log"
grep -q 'Contacts\|No contacts yet\|Contacts menu' "$WORKDIR/fresh.log"
grep -q 'fly safe' "$WORKDIR/fresh.log"
echo "fresh menus OK"

# --- With identity: whoami + contact add CLI + send empty-path teaches ---
DATA2="$WORKDIR/ready"
mkdir -p "$DATA2"
"$ASH" --data-dir "$DATA2" init >"$WORKDIR/init.out"
ADDR=$(grep '^address=' "$WORKDIR/init.out" | cut -d= -f2)
PUB=$(grep '^pub_hex=' "$WORKDIR/init.out" | cut -d= -f2)
FP=$(grep '^fingerprint=' "$WORKDIR/init.out" | cut -d= -f2)
[[ -n "$ADDR" && -n "$PUB" && -n "$FP" ]]
"$ASH" --data-dir "$DATA2" whoami | tee "$WORKDIR/whoami.out"
grep -q "$ADDR" "$WORKDIR/whoami.out"
grep -q "$PUB" "$WORKDIR/whoami.out"

# Self-contact (public bits only) with lan_dial for dial-reuse path
"$ASH" --data-dir "$DATA2" contact add \
  --address "$ADDR" \
  --pub-hex "$PUB" \
  --petname "Me" \
  --tag me \
  --lan-dial "127.0.0.1:17999" \
  --verify-fp "$FP" | tee "$WORKDIR/contact.out"
grep -q 'contact saved' "$WORKDIR/contact.out"
grep -q 'lan_dial' "$WORKDIR/contact.out"

"$ASH" --data-dir "$DATA2" contact list | tee "$WORKDIR/clist.out"
grep -q 'Me' "$WORKDIR/clist.out"
grep -q '127.0.0.1:17999' "$WORKDIR/clist.out"

# Interactive: 1 messages → 3 list → Enter → 2 pick #1 → n (no chat) → empty msg → q
# Empty message exits send without spawning raven-node (avoids hang when nothing listens).
# Do NOT send a blank line before `n` — blank answers open-chat as default Yes.
printf '1\n3\n\n2\n1\nn\n\nq\n' | "$ASH" --data-dir "$DATA2" >"$WORKDIR/ready.log" 2>&1 || true
grep -q 'Using saved LAN dial\|Saved LAN dial\|Send / Chat' "$WORKDIR/ready.log"
grep -q 'empty message\|fly safe' "$WORKDIR/ready.log"
grep -q 'fly safe' "$WORKDIR/ready.log"
echo "ready menus OK"

# Banner / doctor non-interactive (avoid SIGPIPE panic from grep -q closing early)
"$ASH" --data-dir "$DATA2" banner >"$WORKDIR/banner.out"
grep -q 'Welcome to Raven Node' "$WORKDIR/banner.out"
"$ASH" --data-dir "$DATA2" doctor >"$WORKDIR/doctor.out" 2>&1 || true
grep -qE 'messaging_path|identity' "$WORKDIR/doctor.out"

echo "=== ASH MENU SMOKE PASSED ==="
