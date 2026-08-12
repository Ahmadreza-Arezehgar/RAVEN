#!/usr/bin/env bash
# Install user-scoped raven-node launchd agent (macOS). Does NOT touch /bin/ash.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN_DIR="${RAVEN_BIN_DIR:-$HOME/.local/bin}"
DATA_DIR="${RAVEN_DATA_DIR:-$HOME/.raven-node}"
LABEL="com.raven.raven-node"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

mkdir -p "$BIN_DIR" "$DATA_DIR" "$HOME/Library/LaunchAgents"
cargo build -p raven-node -p ash --release --manifest-path "$ROOT/Cargo.toml"
install -m 755 "$ROOT/target/release/raven-node" "$BIN_DIR/raven-node"
install -m 755 "$ROOT/target/release/ash" "$BIN_DIR/raven"
# Optional ash launcher only if safe (not overwriting /bin/ash)
if [[ ! -e /bin/ash ]] || [[ "$(readlink -f "$BIN_DIR/ash" 2>/dev/null || true)" == "$BIN_DIR/raven" ]]; then
  ln -sfn "$BIN_DIR/raven" "$BIN_DIR/ash"
  echo "linked $BIN_DIR/ash -> raven (user-local only)"
else
  echo "NOTE: system /bin/ash exists — use '$BIN_DIR/raven' (never overwrite /bin/ash)"
fi

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN_DIR}/raven-node</string>
    <string>bridge</string>
    <string>--data-dir</string>
    <string>${DATA_DIR}</string>
    <string>--lan-listen</string>
    <string>127.0.0.1:7420</string>
    <string>--ble-listen</string>
    <string>127.0.0.1:7421</string>
    <string>--timeout-secs</string>
    <string>0</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${DATA_DIR}/raven-node.log</string>
  <key>StandardErrorPath</key><string>${DATA_DIR}/raven-node.err</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed launchd agent ${LABEL}"
echo "data-dir=${DATA_DIR} (IPC sock: ${DATA_DIR}/raven-node.sock when enabled)"
echo "PATH tip: export PATH=\"${BIN_DIR}:\$PATH\""
