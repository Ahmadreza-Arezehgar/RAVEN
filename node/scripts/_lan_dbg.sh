#!/usr/bin/env bash
# Simulates the flagged iOS→raven-node LAN path using raven-node itself:
#  1) interim seal (decryptable) — full DELIVERED
#  2) opaque-atsam body — DELIVERED opaque_atsam + ACK (honest bridge)
# Safe: ephemeral /tmp identities only. No secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/target/debug"
NODE="$BIN/raven-node"
WORKDIR="${TMPDIR:-/tmp}/raven-lan-smoke-$$"
mkdir -p "$WORKDIR/a" "$WORKDIR/b"

source "${HOME}/.cargo/env" 2>/dev/null || true
if [[ ! -x "$NODE" ]]; then
  echo "Building raven-node..."
  (cd "$ROOT" && cargo build -p raven-node --features raven-node/unsafe-demo-crypto -q)
fi

echo "=== LAN path smoke (interim + opaque ATSAM) workdir=$WORKDIR ==="
"$NODE" init --data-dir "$WORKDIR/a" | tee "$WORKDIR/a.out"
"$NODE" init --data-dir "$WORKDIR/b" | tee "$WORKDIR/b.out"
A_PUB=$(grep '^pub_hex=' "$WORKDIR/a.out" | cut -d= -f2)
B_PUB=$(grep '^pub_hex=' "$WORKDIR/b.out" | cut -d= -f2)

run_mode() {
  local mode=$1
  local expect=$2
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
  printf '%s\n' "lan-smoke-$mode" | "$NODE" run \
    --data-dir "$WORKDIR/a" \
    --listen "127.0.0.1:0" \
    --peer "$B_LISTEN" \
    --peer-pub-hex "$B_PUB" \
    --send-stdin \
    --body-mode "$mode" \
    --exit-after-ack \
    --timeout-secs 15 \
    >"$WORKDIR/a.log" 2>&1
  wait "$BPID" || true
  grep -q 'ACK delivered' "$WORKDIR/a.log"
  grep -q "$expect" "$WORKDIR/b.log"
  echo "mode=$mode OK"
}

run_mode interim 'DELIVERED bytes='
run_mode opaque-atsam 'DELIVERED opaque_atsam'

echo "=== LAN PATH SMOKE PASSED ==="
