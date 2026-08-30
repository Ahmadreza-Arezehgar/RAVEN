#!/usr/bin/env bash
# Install user-scoped raven-node launchd agent (macOS). Does NOT touch /bin/ash.
set -Eeuo pipefail
umask 077

MACOS_LAB_ACK_VALUE="I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK"
if [[ "${RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK:-}" != "$MACOS_LAB_ACK_VALUE" ]]; then
  echo "ERROR: Raven's macOS launchd installer is held at the Keychain identity-handoff gate." >&2
  echo "The separate raven and raven-node executables have not passed the required" >&2
  echo "signed physical-Mac Keychain ACL/identity-continuity test. No files were changed." >&2
  echo "For an isolated, disposable lab only, acknowledge the hang/identity-split risk with:" >&2
  echo "RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK=$MACOS_LAB_ACK_VALUE" >&2
  exit 2
fi
echo "WARNING: unsafe review-only macOS launchd lab override is active" >&2
echo "WARNING: the service may hang on Keychain ACL UI or observe a different identity" >&2

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN_DIR="${RAVEN_BIN_DIR:-$HOME/.local/bin}"
DATA_DIR="${RAVEN_DATA_DIR:-$HOME/.raven}"
INSTALL_STATE_DIR="${RAVEN_INSTALL_STATE_DIR:-$HOME/Library/Caches/com.raven.raven-node-installer}"
LABEL="com.raven.raven-node"

normalize_absolute_path() {
  local input="$1"
  local component
  local normalized=""
  local -a components
  case "$input" in
    *$'\n'*|*$'\r'*)
      echo "ERROR: install paths must not contain newlines" >&2
      exit 2
      ;;
  esac
  case "$input" in
    /*) ;;
    *)
      echo "ERROR: install paths must be absolute: $input" >&2
      exit 2
      ;;
  esac
  IFS='/' read -r -a components <<<"$input"
  for component in "${components[@]}"; do
    case "$component" in
      "") continue ;;
      .|..)
        echo "ERROR: install paths must not contain . or .. components: $input" >&2
        exit 2
        ;;
      *) normalized="${normalized}/${component}" ;;
    esac
  done
  [[ -n "$normalized" ]] || normalized="/"
  printf '%s' "$normalized"
}

BIN_DIR="$(normalize_absolute_path "$BIN_DIR")"
DATA_DIR="$(normalize_absolute_path "$DATA_DIR")"
INSTALL_STATE_DIR="$(normalize_absolute_path "$INSTALL_STATE_DIR")"
LAUNCH_AGENTS_DIR="$(normalize_absolute_path "$HOME/Library/LaunchAgents")"
PLIST="$LAUNCH_AGENTS_DIR/${LABEL}.plist"

for directory in "$BIN_DIR" "$DATA_DIR" "$INSTALL_STATE_DIR"; do
  if [[ "$directory" == "/" ]]; then
    echo "ERROR: refusing to use the filesystem root as an install directory" >&2
    exit 2
  fi
done

reject_symlink_components() {
  local current="$1"
  case "$current" in
    /*) ;;
    *)
      echo "ERROR: install paths must be absolute: $current" >&2
      exit 2
      ;;
  esac
  while [[ "$current" != "/" ]]; do
    if [[ -L "$current" ]]; then
      echo "ERROR: refusing a symlinked install path component: $current" >&2
      exit 2
    fi
    current="$(dirname "$current")"
  done
}

for value in "$BIN_DIR" "$DATA_DIR" "$INSTALL_STATE_DIR" "$PLIST"; do
  case "$value" in
    *$'\n'*|*$'\r'*)
      echo "ERROR: install paths must not contain newlines" >&2
      exit 2
      ;;
  esac
done
reject_symlink_components "$BIN_DIR"
reject_symlink_components "$DATA_DIR"
reject_symlink_components "$INSTALL_STATE_DIR"
reject_symlink_components "$LAUNCH_AGENTS_DIR"
reject_symlink_components "$PLIST"

path_contains() {
  local parent
  local candidate
  # Default APFS volumes are case-insensitive. Fold ASCII before comparing so
  # a case-variant spelling cannot put binaries or installer metadata inside
  # the protected identity profile (or vice versa). Paths were newline-checked
  # and normalized above, so this bytewise fold is unambiguous.
  parent="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  candidate="$(printf '%s' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ "$candidate" == "$parent" || "$candidate" == "$parent/"* ]]
}
if path_contains "$DATA_DIR" "$BIN_DIR" \
    || path_contains "$BIN_DIR" "$DATA_DIR" \
    || path_contains "$DATA_DIR" "$INSTALL_STATE_DIR" \
    || path_contains "$INSTALL_STATE_DIR" "$DATA_DIR" \
    || path_contains "$BIN_DIR" "$INSTALL_STATE_DIR" \
    || path_contains "$INSTALL_STATE_DIR" "$BIN_DIR"; then
  echo "ERROR: binary, identity-data, and installer-state directories must be separate" >&2
  echo "and none may contain another" >&2
  exit 2
fi

directory_is_empty() (
  shopt -s nullglob dotglob
  local entries=("$1"/*)
  (( ${#entries[@]} == 0 ))
)

# Text comparison catches ordinary mistakes before mutation, but APFS applies
# Unicode normalization/case rules that Bash 3.2 cannot reproduce. Record every
# directory component this installer may create, create only the empty directory
# skeleton, then ask the filesystem for each physical path. If the physical
# paths overlap, remove only empty directories created by this preflight and
# stop before cargo, backups, binaries, identity state, or launchd are touched.
CREATED_INSTALL_DIRS=()
record_missing_install_dirs() {
  local current="$1"
  local parent
  while [[ ! -e "$current" && ! -L "$current" ]]; do
    CREATED_INSTALL_DIRS+=("$current")
    parent="$(dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
  done
}

cleanup_created_install_dirs() {
  local pass
  local directory
  # Multiple target paths can share newly-created parents. Repeating bounded
  # rmdir passes removes children first without ever deleting non-empty data.
  for ((pass = 0; pass <= ${#CREATED_INSTALL_DIRS[@]}; pass++)); do
    for directory in "${CREATED_INSTALL_DIRS[@]}"; do
      rmdir "$directory" 2>/dev/null || true
    done
  done
}

filesystem_path_contains() {
  local parent="$1"
  local candidate="$2"
  local parent_identity
  local candidate_identity
  local next

  # `pwd -P` is not a sufficient canonicalizer on case-insensitive APFS: it
  # may retain the caller's Unicode/case spelling even when two spellings name
  # the same inode. Compare device+inode identities while walking the candidate
  # toward `/` instead. This also makes the containment decision independent of
  # Bash 3.2's locale/Unicode behavior.
  parent_identity="$(stat -f '%d:%i' "$parent")" || return 2
  while :; do
    candidate_identity="$(stat -f '%d:%i' "$candidate")" || return 2
    [[ "$candidate_identity" == "$parent_identity" ]] && return 0
    [[ "$candidate" == "/" ]] && return 1
    next="$(dirname "$candidate")"
    [[ "$next" != "$candidate" ]] || return 1
    candidate="$next"
  done
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

for directory in "$BIN_DIR" "$DATA_DIR" "$INSTALL_STATE_DIR" "$LAUNCH_AGENTS_DIR"; do
  record_missing_install_dirs "$directory"
done
if ! mkdir -p "$BIN_DIR" "$DATA_DIR" "$INSTALL_STATE_DIR" "$LAUNCH_AGENTS_DIR"; then
  cleanup_created_install_dirs
  echo "ERROR: could not create the user-scoped install directory skeleton" >&2
  exit 2
fi

for directory in "$BIN_DIR" "$DATA_DIR" "$INSTALL_STATE_DIR"; do
  if ! stat -f '%d:%i' "$directory" >/dev/null; then
    cleanup_created_install_dirs
    echo "ERROR: could not inspect the physical install directories" >&2
    exit 2
  fi
done
if filesystem_path_contains "$DATA_DIR" "$BIN_DIR" \
    || filesystem_path_contains "$BIN_DIR" "$DATA_DIR" \
    || filesystem_path_contains "$DATA_DIR" "$INSTALL_STATE_DIR" \
    || filesystem_path_contains "$INSTALL_STATE_DIR" "$DATA_DIR" \
    || filesystem_path_contains "$BIN_DIR" "$INSTALL_STATE_DIR" \
    || filesystem_path_contains "$INSTALL_STATE_DIR" "$BIN_DIR"; then
  cleanup_created_install_dirs
  echo "ERROR: binary, identity-data, and installer-state directories resolve to overlapping filesystem paths" >&2
  echo "and none may contain another" >&2
  exit 2
fi

for owned_directory in "$BIN_DIR" "$DATA_DIR" "$INSTALL_STATE_DIR" "$LAUNCH_AGENTS_DIR"; do
  if [[ "$(stat -f '%u' "$owned_directory")" != "$(id -u)" ]]; then
    echo "ERROR: user-scoped install directory is not owned by the current user: $owned_directory" >&2
    exit 2
  fi
  directory_mode="$(stat -f '%Lp' "$owned_directory")"
  if (( (8#$directory_mode & 8#022) != 0 )); then
    echo "ERROR: install directory is group/world-writable: $owned_directory (mode $directory_mode)" >&2
    exit 2
  fi
done
chmod 700 "$DATA_DIR" "$INSTALL_STATE_DIR"
DATA_DIR_WAS_EMPTY=0
if directory_is_empty "$DATA_DIR"; then
  DATA_DIR_WAS_EMPTY=1
fi
cargo build --locked -p raven-node -p ash --release --manifest-path "$ROOT/Cargo.toml"

INSTALL_LOCK_DIR="$INSTALL_STATE_DIR/.service-install.lock"
if ! mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
  echo "ERROR: another Raven service install is running (or left a stale lock): $INSTALL_LOCK_DIR" >&2
  exit 2
fi
release_install_lock() {
  rmdir "$INSTALL_LOCK_DIR" 2>/dev/null || true
}
trap release_install_lock EXIT
trap 'exit 130' HUP INT TERM

BACKUP_DIR="$INSTALL_STATE_DIR/install-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
NODE_EXISTED=0
RAVEN_EXISTED=0
PLIST_EXISTED=0
ASH_CREATED=0
PLIST_TMP=""
OLD_SERVICE_LOADED=0
SERVICE_REPLACEMENT_STARTED=0
if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
  OLD_SERVICE_LOADED=1
fi
if [[ -L "$BIN_DIR/raven-node" || -L "$BIN_DIR/raven" ]]; then
  echo "ERROR: refusing to replace symlinked service binaries in $BIN_DIR" >&2
  echo "Move those links aside explicitly before installing the launchd copy." >&2
  exit 2
fi
if [[ -e "$BIN_DIR/raven-node" || -L "$BIN_DIR/raven-node" ]]; then
  cp -pP "$BIN_DIR/raven-node" "$BACKUP_DIR/raven-node"
  NODE_EXISTED=1
fi
if [[ -e "$BIN_DIR/raven" || -L "$BIN_DIR/raven" ]]; then
  cp -pP "$BIN_DIR/raven" "$BACKUP_DIR/raven"
  RAVEN_EXISTED=1
fi
if [[ -e "$PLIST" || -L "$PLIST" ]]; then
  [[ ! -L "$PLIST" ]] || { echo "ERROR: refusing a symlinked launchd plist: $PLIST" >&2; exit 2; }
  cp -p "$PLIST" "$BACKUP_DIR/${LABEL}.plist"
  PLIST_EXISTED=1
fi

INSTALL_COMMITTED=0
rollback() {
  [[ "$INSTALL_COMMITTED" -eq 0 ]] || return 0
  echo "ERROR: install failed; restoring the previous user-scoped files" >&2
  if [[ "$SERVICE_REPLACEMENT_STARTED" -eq 1 ]]; then
    launchctl bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
  fi
  if [[ "$NODE_EXISTED" -eq 1 ]]; then
    cp -pP "$BACKUP_DIR/raven-node" "$BIN_DIR/raven-node"
  else
    rm -f -- "$BIN_DIR/raven-node"
  fi
  if [[ "$RAVEN_EXISTED" -eq 1 ]]; then
    cp -pP "$BACKUP_DIR/raven" "$BIN_DIR/raven"
  else
    rm -f -- "$BIN_DIR/raven"
  fi
  if [[ "$PLIST_EXISTED" -eq 1 ]]; then
    cp -p "$BACKUP_DIR/${LABEL}.plist" "$PLIST"
    if [[ "$OLD_SERVICE_LOADED" -eq 1 ]]; then
      launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
    fi
  else
    rm -f -- "$PLIST"
  fi
  if [[ "$ASH_CREATED" -eq 1 ]] && [[ -L "$BIN_DIR/ash" ]] \
    && [[ "$(readlink "$BIN_DIR/ash")" == "$BIN_DIR/raven" ]]; then
    rm -f -- "$BIN_DIR/ash"
  fi
  if [[ -n "$PLIST_TMP" ]]; then
    rm -f -- "$PLIST_TMP"
  fi
}
finish_install() {
  local status=$?
  local rollback_status=0
  trap - EXIT
  set +e
  rollback
  rollback_status=$?
  release_install_lock
  if [[ "$rollback_status" -ne 0 ]]; then
    echo "ERROR: installer rollback did not complete cleanly" >&2
    [[ "$status" -ne 0 ]] || status="$rollback_status"
  fi
  exit "$status"
}
trap finish_install EXIT

install -m 755 "$ROOT/target/release/raven-node" "$BIN_DIR/raven-node"
install -m 755 "$ROOT/target/release/raven" "$BIN_DIR/raven"
# Optional user-local ash launcher. Never replace an unrelated path.
if [[ -L "$BIN_DIR/ash" ]] && [[ "$(readlink "$BIN_DIR/ash")" == "$BIN_DIR/raven" ]]; then
  : # already our link
elif [[ -e "$BIN_DIR/ash" || -L "$BIN_DIR/ash" ]]; then
  echo "NOTE: $BIN_DIR/ash already exists — leaving it untouched; use '$BIN_DIR/raven'"
else
  ln -s "$BIN_DIR/raven" "$BIN_DIR/ash"
  ASH_CREATED=1
  echo "linked $BIN_DIR/ash -> raven (user-local only)"
fi

BIN_DIR_XML="$(xml_escape "$BIN_DIR")"
DATA_DIR_XML="$(xml_escape "$DATA_DIR")"
PLIST_TMP="$(mktemp "$LAUNCH_AGENTS_DIR/${LABEL}.plist.XXXXXX")"
cat >"$PLIST_TMP" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN_DIR_XML}/raven-node</string>
    <string>service</string>
    <string>--data-dir</string>
    <string>${DATA_DIR_XML}</string>
    <string>--lan-listen</string>
    <string>0.0.0.0:7420</string>
    <string>--bridge-listen</string>
    <string>0.0.0.0:7422</string>
    <string>--ble-listen</string>
    <string>127.0.0.1:7421</string>
    <string>--timeout-secs</string>
    <string>0</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${DATA_DIR_XML}/raven-node.log</string>
  <key>StandardErrorPath</key><string>${DATA_DIR_XML}/raven-node.err</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST_TMP" >/dev/null
chmod 600 "$PLIST_TMP"
mv "$PLIST_TMP" "$PLIST"

# Identity + prekey must exist before LAN preflight will keep the service up.
if [[ "$DATA_DIR_WAS_EMPTY" -eq 1 ]] && ! directory_is_empty "$DATA_DIR"; then
  echo "ERROR: installer metadata polluted a fresh identity profile before raven init" >&2
  exit 2
fi
"${BIN_DIR}/raven" --data-dir "${DATA_DIR}" init

SERVICE_REPLACEMENT_STARTED=1
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
SERVICE_READY=0
for _ in {1..100}; do
  if grep -Fq 'state = running' \
      < <(launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null) \
    && "${BIN_DIR}/raven" --data-dir "${DATA_DIR}" ipc-ping >/dev/null 2>&1 \
    && grep -Eq ':7422$' "${DATA_DIR}/service-bridge.addr" 2>/dev/null \
    && nc -z -w 1 127.0.0.1 7422 >/dev/null 2>&1; then
    SERVICE_READY=1
    break
  fi
  sleep 0.1
done
if [[ "$SERVICE_READY" -ne 1 ]]; then
  echo "ERROR: launchd accepted the job but Raven IPC + authenticated bridge did not become ready" >&2
  exit 2
fi
INSTALL_COMMITTED=1
echo "installed launchd agent ${LABEL}"
echo "rollback backup=$BACKUP_DIR"
echo "installer-state=${INSTALL_STATE_DIR}"
echo "data-dir=${DATA_DIR}"
echo "IPC sock: ${DATA_DIR}/raven-node.sock (service = lan_direct + bridge + ipc)"
echo "Bridge endpoint: ${DATA_DIR}/service-bridge.addr (authenticated pull only)"
echo "Firewall: allow inbound TCP 7420 and 7422 on the LAN (System Settings → Network → Firewall)."
echo "PATH tip: export PATH=\"${BIN_DIR}:\$PATH\""
