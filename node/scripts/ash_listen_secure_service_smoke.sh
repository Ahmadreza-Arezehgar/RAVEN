#!/usr/bin/env bash
# Actual-process regression: `ash listen` starts the same raven-node service
# consumed by `ash send`, and a second listen reuses it without killing/replacing
# any process. Uses only disposable locked-file test material.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
PROFILE="$TMP/profile"
LISTEN_PID=""
SECOND_LISTEN_PID=""
NODE_PID=""
cleanup() {
  if [[ "$NODE_PID" =~ ^[0-9]+$ ]]; then
    kill -CONT "$NODE_PID" 2>/dev/null || true
  fi
  if [[ "$NODE_PID" =~ ^[0-9]+$ ]] && kill -0 "$NODE_PID" 2>/dev/null; then
    kill "$NODE_PID" 2>/dev/null || true
  fi
  if [[ "$LISTEN_PID" =~ ^[0-9]+$ ]] && kill -0 "$LISTEN_PID" 2>/dev/null; then
    kill "$LISTEN_PID" 2>/dev/null || true
  fi
  if [[ "$SECOND_LISTEN_PID" =~ ^[0-9]+$ ]] && kill -0 "$SECOND_LISTEN_PID" 2>/dev/null; then
    kill "$SECOND_LISTEN_PID" 2>/dev/null || true
  fi
  if [[ "$LISTEN_PID" =~ ^[0-9]+$ ]]; then
    wait "$LISTEN_PID" 2>/dev/null || true
  fi
  if [[ "$SECOND_LISTEN_PID" =~ ^[0-9]+$ ]]; then
    wait "$SECOND_LISTEN_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$PROFILE"
cargo build -q --locked -p ash -p raven-node
ASH="$ROOT/target/debug/ash"
NODE="$ROOT/target/debug/raven-node"

export RAVEN_ALLOW_EPHEMERAL_DATA_DIR=1
export RAVEN_IDENTITY_BACKEND=locked-file
export RAVEN_PREKEY_BACKEND=locked-file
export RAVEN_NODE_BIN="$NODE"
export NO_COLOR=1

INIT="$($ASH --data-dir "$PROFILE" init)"
ADDRESS="$(sed -n 's/^address=//p' <<<"$INIT")"
FINGERPRINT="$(sed -n 's/^fingerprint=//p' <<<"$INIT")"
PUB_HEX="$(sed -n 's/^pub_hex=//p' <<<"$INIT")"
[[ -n "$ADDRESS" && -n "$FINGERPRINT" && -n "$PUB_HEX" ]]

LAN_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
export RAVEN_SERVICE_LAN_LISTEN="127.0.0.1:$LAN_PORT"
export RAVEN_SERVICE_BRIDGE_LISTEN="127.0.0.1:0"

$ASH --data-dir "$PROFILE" contact add \
  --address "$ADDRESS" --pub-hex "$PUB_HEX" \
  --petname Self --tag self --verify-fp "$FINGERPRINT" \
  --lan-dial "127.0.0.1:$LAN_PORT" >"$TMP/contact.log"

$ASH --data-dir "$PROFILE" listen >"$TMP/listen-a.log" 2>&1 &
LISTEN_PID=$!
$ASH --data-dir "$PROFILE" listen >"$TMP/listen-b.log" 2>&1 &
SECOND_LISTEN_PID=$!

for _ in {1..200}; do
  if $ASH --data-dir "$PROFILE" ipc-ping >"$TMP/ping.log" 2>&1; then
    break
  fi
  if ! kill -0 "$LISTEN_PID" 2>/dev/null && ! kill -0 "$SECOND_LISTEN_PID" 2>/dev/null; then
    echo "FAIL: both simultaneous ash listen launchers exited before service readiness"
    sed -n '1,200p' "$TMP/listen-a.log"
    sed -n '1,200p' "$TMP/listen-b.log"
    exit 1
  fi
  sleep 0.05
done
grep -q 'ipc pong' "$TMP/ping.log"

# Exactly one launcher owns and waits on the winning raven-node child. The
# other launcher must return success after reusing that winner; it must never
# return its own lock-losing child as Started.
for _ in {1..100}; do
  A_ALIVE=0
  B_ALIVE=0
  kill -0 "$LISTEN_PID" 2>/dev/null && A_ALIVE=1
  kill -0 "$SECOND_LISTEN_PID" 2>/dev/null && B_ALIVE=1
  [[ "$A_ALIVE:$B_ALIVE" == "1:0" || "$A_ALIVE:$B_ALIVE" == "0:1" ]] && break
  sleep 0.05
done
if [[ "$A_ALIVE:$B_ALIVE" == "1:0" ]]; then
  LOSER_PID="$SECOND_LISTEN_PID"
  WINNER_LOG="$TMP/listen-a.log"
  LOSER_LOG="$TMP/listen-b.log"
elif [[ "$A_ALIVE:$B_ALIVE" == "0:1" ]]; then
  LOSER_PID="$LISTEN_PID"
  LISTEN_PID="$SECOND_LISTEN_PID"
  WINNER_LOG="$TMP/listen-b.log"
  LOSER_LOG="$TMP/listen-a.log"
else
  echo "FAIL: simultaneous listen launch did not converge to one owner"
  sed -n '1,200p' "$TMP/listen-a.log"
  sed -n '1,200p' "$TMP/listen-b.log"
  exit 1
fi
if ! wait "$LOSER_PID"; then
  echo "FAIL: simultaneous lock-losing ash listen returned nonzero"
  sed -n '1,200p' "$LOSER_LOG"
  exit 1
fi
grep -q 'already listening and IPC-ready' "$LOSER_LOG"

NODE_PID="$(pgrep -P "$LISTEN_PID" -x raven-node | head -n 1 || true)"
[[ "$NODE_PID" =~ ^[0-9]+$ ]] || {
  echo "FAIL: ash listen did not retain its exact raven-node child"
  sed -n '1,200p' "$WINNER_LOG"
  exit 1
}

# A transiently unresponsive daemon must not lose its IPC pathname. Stop only
# the exact child, let `ash listen` time out and attempt a replacement, then
# prove the held instance lock refused that replacement and the original socket
# inode is untouched.
SOCKET_PATH="$PROFILE/raven-node.sock"
if SOCKET_INODE="$(stat -f '%i' "$SOCKET_PATH" 2>/dev/null)"; then
  :
else
  SOCKET_INODE="$(stat -c '%i' "$SOCKET_PATH")"
fi
kill -STOP "$NODE_PID"
if $ASH --data-dir "$PROFILE" listen >"$TMP/transient-ipc.log" 2>&1; then
  echo "FAIL: ash listen accepted an unresponsive service"
  kill -CONT "$NODE_PID"
  exit 1
fi
grep -Eq 'already running|exited before readiness|could not start' "$TMP/transient-ipc.log"
[[ -S "$SOCKET_PATH" ]]
if CURRENT_INODE="$(stat -f '%i' "$SOCKET_PATH" 2>/dev/null)"; then
  :
else
  CURRENT_INODE="$(stat -c '%i' "$SOCKET_PATH")"
fi
[[ "$CURRENT_INODE" == "$SOCKET_INODE" ]]
kill -CONT "$NODE_PID"
for _ in {1..100}; do
  if $ASH --data-dir "$PROFILE" ipc-ping >"$TMP/resumed-ping.log" 2>&1; then
    break
  fi
  sleep 0.05
done
grep -q 'ipc pong' "$TMP/resumed-ping.log"

# A parseable but stale publication is not readiness. Keep the authenticated
# IPC service alive, replace only its public address file with a closed port,
# and require `ash listen` to fail without launching or killing any process.
BRIDGE_ADDR_FILE="$PROFILE/service-bridge.addr"
[[ -f "$BRIDGE_ADDR_FILE" ]]
LIVE_BRIDGE_ADDR="$(<"$BRIDGE_ADDR_FILE")"
printf '%s' '127.0.0.1:0' >"$BRIDGE_ADDR_FILE"
if $ASH --data-dir "$PROFILE" listen >"$TMP/stale-bridge.log" 2>&1; then
  echo "FAIL: ash listen accepted a stale bridge publication"
  sed -n '1,200p' "$TMP/stale-bridge.log"
  exit 1
fi
grep -q 'listeners are not ready' "$TMP/stale-bridge.log"
kill -0 "$LISTEN_PID"
kill -0 "$NODE_PID"
printf '%s' "$LIVE_BRIDGE_ADDR" >"$BRIDGE_ADDR_FILE"

REUSED="$($ASH --data-dir "$PROFILE" listen)"
grep -q 'already listening and IPC-ready' <<<"$REUSED"
kill -0 "$LISTEN_PID"
kill -0 "$NODE_PID"

# A different profile cannot steal the live LAN port. Its `ash listen` must
# propagate the child startup failure with a nonzero status, while the original
# exact service remains alive.
BLOCKED_PROFILE="$TMP/blocked-profile"
mkdir -p "$BLOCKED_PROFILE"
BLOCKED_INIT="$($ASH --data-dir "$BLOCKED_PROFILE" init)"
BLOCKED_ADDRESS="$(sed -n 's/^address=//p' <<<"$BLOCKED_INIT")"
BLOCKED_FP="$(sed -n 's/^fingerprint=//p' <<<"$BLOCKED_INIT")"
BLOCKED_PUB="$(sed -n 's/^pub_hex=//p' <<<"$BLOCKED_INIT")"
$ASH --data-dir "$BLOCKED_PROFILE" contact add \
  --address "$BLOCKED_ADDRESS" --pub-hex "$BLOCKED_PUB" \
  --petname Self --tag self --verify-fp "$BLOCKED_FP" \
  --lan-dial "127.0.0.1:$LAN_PORT" >"$TMP/blocked-contact.log"
if $ASH --data-dir "$BLOCKED_PROFILE" listen >"$TMP/blocked-listen.log" 2>&1; then
  echo "FAIL: ash listen reported success after its service failed to bind"
  sed -n '1,200p' "$TMP/blocked-listen.log"
  exit 1
fi
grep -Eq 'exited before readiness|listeners are not ready|could not start' "$TMP/blocked-listen.log"
kill -0 "$LISTEN_PID"
kill -0 "$NODE_PID"

echo "OK ash listen validates live bridge, starts/reuses service, and propagates failure"
