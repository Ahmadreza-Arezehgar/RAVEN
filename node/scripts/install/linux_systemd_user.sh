#!/usr/bin/env bash
# Install user-scoped raven-node systemd unit (Linux). Never touches /bin/ash.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN_DIR="${RAVEN_BIN_DIR:-$HOME/.local/bin}"
DATA_DIR="${RAVEN_DATA_DIR:-$HOME/.raven-node}"
UNIT_DIR="$HOME/.config/systemd/user"
UNIT="$UNIT_DIR/raven-node.service"

mkdir -p "$BIN_DIR" "$DATA_DIR" "$UNIT_DIR"
cargo build -p raven-node -p ash --release --manifest-path "$ROOT/Cargo.toml"
install -m 755 "$ROOT/target/release/raven-node" "$BIN_DIR/raven-node"
install -m 755 "$ROOT/target/release/ash" "$BIN_DIR/raven"
ln -sfn "$BIN_DIR/raven" "$BIN_DIR/ash"
echo "user-local ash -> raven (system /bin/ash untouched)"

cat >"$UNIT" <<EOF
[Unit]
Description=RAVEN raven-node service (bridge + IPC)
After=network.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/raven-node service --data-dir ${DATA_DIR} --lan-listen 127.0.0.1:7420 --ble-listen 127.0.0.1:7421 --timeout-secs 0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now raven-node.service
echo "enabled systemd --user raven-node.service"
echo "IPC sock: ${DATA_DIR}/raven-node.sock"
echo "export PATH=\"${BIN_DIR}:\$PATH\""
