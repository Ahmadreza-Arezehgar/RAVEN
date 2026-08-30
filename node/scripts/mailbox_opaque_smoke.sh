#!/usr/bin/env bash
# Offline mailbox retrieve smoke — opaque store_tag only (no username index).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cargo build --locked -q -p ash -p raven-core
ASH=./target/debug/ash

# Deterministic K_route (32 bytes) in an owner-only file. The secret is never
# placed in argv, shell history, or the process listing.
K_ROUTE_FILE="$TMP/k-route.key"
python3 -c 'import sys; sys.stdout.buffer.write(bytes(32))' >"$K_ROUTE_FILE"
chmod 600 "$K_ROUTE_FILE"
EPOCH=42
SLOT=0

# Pack a strict RavenEnvelopeV1 carrying an opaque ciphertext. The mailbox is
# not an endpoint and therefore preserves, but cannot authenticate, the
# sender's 64-byte signature; endpoint verification happens after retrieval.
ENV_HEX="$(python3 - <<'PY'
import struct
import time

created = int(time.time() * 1000)
expires = created + 24 * 60 * 60 * 1000
header = b""
body = b"opaque-ciphertext"
signature = bytes(64)
packed = b"".join([
    b"RVN1", bytes([1, 1]), struct.pack(">H", 0),
    bytes.fromhex("ab" * 16), bytes.fromhex("cd" * 16),
    struct.pack(">Q", 0), struct.pack(">Q", created),
    struct.pack(">Q", expires), bytes([8, 3]), bytes.fromhex("ef" * 12),
    struct.pack(">H", len(header)), struct.pack(">I", len(body)),
    struct.pack(">H", len(signature)), header, body, signature,
])
print(packed.hex())
PY
)"

RAVEN_ALLOW_EPHEMERAL_DATA_DIR=1 "$ASH" --data-dir "$TMP/store" mailbox put \
  --k-route-file "$K_ROUTE_FILE" --epoch "$EPOCH" --slot "$SLOT" --envelope-hex "$ENV_HEX"

OUT="$(RAVEN_ALLOW_EPHEMERAL_DATA_DIR=1 "$ASH" --data-dir "$TMP/store" mailbox get \
  --k-route-file "$K_ROUTE_FILE" --epoch "$EPOCH" --slot "$SLOT")"

echo "$OUT" | grep -q 'store_tag=' || {
  echo "FAIL: expected opaque store_tag hit"
  echo "$OUT"
  exit 1
}
echo "$OUT" | grep -qi 'username' && {
  echo "FAIL: username must never appear in mailbox index path"
  exit 1
}

# Overlap: previous epoch should still find when epoch advanced without put.
OUT2="$(RAVEN_ALLOW_EPHEMERAL_DATA_DIR=1 "$ASH" --data-dir "$TMP/store" mailbox get \
  --k-route-file "$K_ROUTE_FILE" --epoch $((EPOCH + 1)) --slot "$SLOT")"
echo "$OUT2" | grep -q 'store_tag=' || {
  echo "FAIL: overlap retrieve (prev epoch) expected a hit"
  echo "$OUT2"
  exit 1
}

echo "OK mailbox opaque put/get + epoch overlap"
