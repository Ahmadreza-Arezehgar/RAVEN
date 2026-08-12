#!/usr/bin/env bash
# Safe local two-node DM reliability loop for RAVEN.
# Uses ONLY local temp dirs and ephemeral keys — no secrets committed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/target/debug"
NODE="$BIN/raven-node"
WORKDIR="${TMPDIR:-/tmp}/raven-demo-$$"
mkdir -p "$WORKDIR/a" "$WORKDIR/b"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if [[ ! -x "$NODE" ]]; then
  echo "Building raven-node..."
  (cd "$ROOT" && cargo build -p raven-node -q)
fi

echo "=== RAVEN two-node demo workdir=$WORKDIR ==="

"$NODE" init --data-dir "$WORKDIR/a" | tee "$WORKDIR/a.out"
"$NODE" init --data-dir "$WORKDIR/b" | tee "$WORKDIR/b.out"
A_PUB=$(grep '^pub_hex=' "$WORKDIR/a.out" | cut -d= -f2)
B_PUB=$(grep '^pub_hex=' "$WORKDIR/b.out" | cut -d= -f2)
echo "A $(grep '^address=' "$WORKDIR/a.out")"
echo "B $(grep '^address=' "$WORKDIR/b.out")"

run_once() {
  local round=$1
  local msg="hello-round-$round"
  rm -f "$WORKDIR/b.listen"
  "$NODE" run \
    --data-dir "$WORKDIR/b" \
    --listen "127.0.0.1:0" \
    --peer-pub-hex "$A_PUB" \
    --write-addr "$WORKDIR/b.listen" \
    --exit-after-recv 1 \
    --timeout-secs 15 \
    >"$WORKDIR/b.log" 2>&1 &
  local BPID=$!
  for _ in $(seq 1 50); do
    [[ -f "$WORKDIR/b.listen" ]] && break
    sleep 0.05
  done
  local B_LISTEN
  B_LISTEN=$(cat "$WORKDIR/b.listen")
  printf '%s\n' "$msg" | "$NODE" run \
    --data-dir "$WORKDIR/a" \
    --listen "127.0.0.1:0" \
    --peer "$B_LISTEN" \
    --peer-pub-hex "$B_PUB" \
    --send-stdin \
    --exit-after-ack \
    --timeout-secs 15 \
    >"$WORKDIR/a.log" 2>&1
  wait "$BPID" || true
  grep -q 'ACK delivered' "$WORKDIR/a.log"
  grep -q 'DELIVERED bytes=' "$WORKDIR/b.log"
  echo "round $round OK"
}

echo "=== 3 consecutive happy-path rounds ==="
for r in 1 2 3; do
  run_once "$r"
done

echo "=== restart persistence (re-init dirs keep identity; new send) ==="
run_once 4

echo "=== ALL DEMO CHECKS PASSED (4/4 rounds) ==="
