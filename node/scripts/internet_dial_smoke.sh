#!/usr/bin/env bash
# InternetTransport smoke: two nodes dial with authenticated hello + capability bits.
# No FastAPI. Opaque framed RavenEnvelopeV1. Safe ephemeral dirs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/target/debug"
NODE="$BIN/raven-node"
WORKDIR="${TMPDIR:-/tmp}/raven-inet-$$"
mkdir -p "$WORKDIR/a" "$WORKDIR/b"
cleanup() {
  [[ -n "${BPID:-}" ]] && kill "$BPID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
source "${HOME}/.cargo/env" 2>/dev/null || true
[[ -x "$NODE" ]] || (cd "$ROOT" && cargo build -p raven-node -q)

"$NODE" init --data-dir "$WORKDIR/a" | tee "$WORKDIR/a.out"
"$NODE" init --data-dir "$WORKDIR/b" | tee "$WORKDIR/b.out"
A_PUB=$(grep '^pub_hex=' "$WORKDIR/a.out" | cut -d= -f2)
B_PUB=$(grep '^pub_hex=' "$WORKDIR/b.out" | cut -d= -f2)

"$NODE" run \
  --data-dir "$WORKDIR/b" \
  --listen "127.0.0.1:0" \
  --write-addr "$WORKDIR/b.addr" \
  --write-pub "$WORKDIR/b.pub" \
  --exit-after-recv 1 \
  --timeout-secs 25 \
  --peer-pub-hex "$A_PUB" \
  >"$WORKDIR/b.log" 2>&1 &
BPID=$!
for _ in $(seq 1 80); do
  [[ -f "$WORKDIR/b.addr" ]] && break
  sleep 0.05
done
B_ADDR=$(cat "$WORKDIR/b.addr")

"$NODE" run \
  --data-dir "$WORKDIR/a" \
  --listen "127.0.0.1:0" \
  --peer "$B_ADDR" \
  --peer-pub-hex "$B_PUB" \
  --send "inet-transport-proof" \
  --exit-after-ack \
  --timeout-secs 25 \
  >"$WORKDIR/a.log" 2>&1

wait "$BPID" || true
grep -q 'ACK delivered' "$WORKDIR/a.log"
grep -q 'DELIVERED' "$WORKDIR/b.log"
# Prove no FastAPI / HTTP API was required
! grep -qiE 'fastapi|localhost:8000|/api/' "$WORKDIR/a.log" "$WORKDIR/b.log"
echo "=== INTERNET TRANSPORT DIAL OK (no FastAPI) ==="
