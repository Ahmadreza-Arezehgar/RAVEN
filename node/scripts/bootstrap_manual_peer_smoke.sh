#!/usr/bin/env bash
# §30: prove network startup with only a manually supplied peer — no Raven-owned bootstrap.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SMOKE_TARGET="$ROOT/target/bootstrap-manual-peer-smoke"
BIN="$SMOKE_TARGET/debug"
NODE="$BIN/raven-node"
SWARM="$BIN/raven-swarm"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/raven-boot.XXXXXX")"
mkdir -p "$WORKDIR/a" "$WORKDIR/b"
cleanup() {
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "--- bootstrap smoke failed: sender log ---" >&2
    [[ -f "$WORKDIR/a.log" ]] && tail -n 120 "$WORKDIR/a.log" >&2 || true
    echo "--- bootstrap smoke failed: receiver log ---" >&2
    [[ -f "$WORKDIR/b.log" ]] && tail -n 120 "$WORKDIR/b.log" >&2 || true
  fi
  if [[ -n "${BPID:-}" ]]; then
    kill "$BPID" 2>/dev/null || true
    wait "$BPID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
  return "$rc"
}
trap cleanup EXIT
source "${HOME}/.cargo/env" 2>/dev/null || true
export RAVEN_IDENTITY_BACKEND=locked-file
(cd "$ROOT" && CARGO_TARGET_DIR="$SMOKE_TARGET" cargo build --locked \
  -p raven-node -p raven-swarm --features raven-node/unsafe-demo-crypto -q)

# bootstrap.json: raven defaults disabled/empty; only manual peer
"$SWARM" bootstrap-init \
  --data-dir "$WORKDIR/b" \
  --manual-peer "127.0.0.1:0" \
  --no-raven-defaults
SHOW=$("$SWARM" bootstrap-show --data-dir "$WORKDIR/b")
echo "$SHOW" | grep -q 'manual_peer_only=true'
echo "$SHOW" | grep -q 'raven_defaults_count=0'
echo "$SHOW" | grep -q 'use_raven_defaults=false'

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

# Rewrite bootstrap to the live manual peer only
"$SWARM" bootstrap-init \
  --data-dir "$WORKDIR/a" \
  --manual-peer "$B_ADDR" \
  --no-raven-defaults
"$SWARM" bootstrap-show --data-dir "$WORKDIR/a" | grep -q "peer=$B_ADDR"

printf '%s\n' "manual-bootstrap-only" | "$NODE" run \
  --data-dir "$WORKDIR/a" \
  --listen "127.0.0.1:0" \
  --peer "$B_ADDR" \
  --peer-pub-hex "$B_PUB" \
  --send-stdin --body-mode unsafe-interim \
  --exit-after-ack \
  --timeout-secs 25 \
  >"$WORKDIR/a.log" 2>&1

wait "$BPID" || true
grep -q 'ACK delivered' "$WORKDIR/a.log"
grep -q 'DELIVERED' "$WORKDIR/b.log"
! grep -qiE 'fastapi|bootstrap\.raven|raven-owned' "$WORKDIR/a.log" "$WORKDIR/b.log"
echo "=== MANUAL-PEER-ONLY BOOTSTRAP SMOKE OK ==="
