#!/usr/bin/env bash
# Install user-scoped raven-node systemd unit (Linux). Never touches /bin/ash.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN_DIR="${RAVEN_BIN_DIR:-$HOME/.local/bin}"
DATA_DIR="${RAVEN_DATA_DIR:-$HOME/.raven}"
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
ExecStart=${BIN_DIR}/raven-node service --data-dir ${DATA_DIR} --lan-listen 0.0.0.0:7420 --ble-listen 127.0.0.1:7421 --timeout-secs 0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
# Identity + prekey must exist before LAN preflight will keep the service up.
"${BIN_DIR}/raven" --data-dir "${DATA_DIR}" init
systemctl --user enable --now raven-node.service
echo "enabled systemd --user raven-node.service"
echo "IPC sock: ${DATA_DIR}/raven-node.sock"
echo "Firewall: allow inbound TCP 7420 (e.g. ufw allow 7420/tcp)."
echo "export PATH=\"${BIN_DIR}:\$PATH\""
