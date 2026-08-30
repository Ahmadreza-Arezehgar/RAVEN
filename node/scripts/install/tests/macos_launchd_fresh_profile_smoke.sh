#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
INSTALLER="$REPO_ROOT/node/scripts/install/macos_launchd.sh"
FAKE_RAVEN="$REPO_ROOT/node/scripts/install/tests/fake_raven_binary.sh"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/raven-macos-installer-smoke.XXXXXX")"
SMOKE_ROOT="$(cd "$SMOKE_ROOT" && pwd -P)"
trap 'rm -rf -- "$SMOKE_ROOT"' EXIT

cargo() {
  return 0
}

install() {
  local destination="${!#}"
  command cp "$FAKE_RAVEN" "$destination"
  command chmod 755 "$destination"
}

launchctl() {
  case "${1:-}" in
    print)
      [[ -f "$RAVEN_SMOKE_LAUNCHCTL_STATE" ]] || return 1
      printf '%s\n' 'state = running'
      ;;
    bootstrap)
      : >"$RAVEN_SMOKE_LAUNCHCTL_STATE"
      printf '%s\n' '127.0.0.1:7422' >"$RAVEN_DATA_DIR/service-bridge.addr"
      ;;
    bootout)
      rm -f -- "$RAVEN_SMOKE_LAUNCHCTL_STATE"
      ;;
    *) return 0 ;;
  esac
}

plutil() {
  return 0
}

nc() {
  return 0
}

export -f cargo install launchctl plutil nc
export FAKE_RAVEN
export RAVEN_UNSAFE_LAB_MACOS_KEYCHAIN_HANDOFF_ACK="I_ACCEPT_REVIEW_ONLY_KEYCHAIN_HANDOFF_RISK"

run_success_case() {
  local case_root="$SMOKE_ROOT/success"
  export HOME="$case_root/home"
  export RAVEN_BIN_DIR="$case_root/bin"
  export RAVEN_DATA_DIR="$case_root/data"
  export RAVEN_INSTALL_STATE_DIR="$case_root/installer-state"
  export RAVEN_SMOKE_LAUNCHCTL_STATE="$case_root/launchctl.loaded"
  unset RAVEN_SMOKE_INIT_FAIL
  mkdir -p "$HOME"

  if ! bash "$INSTALLER" >"$case_root.stdout" 2>"$case_root.stderr"; then
    command cat "$case_root.stdout" "$case_root.stderr" >&2
    echo "ERROR: fresh-profile installer smoke failed" >&2
    return 1
  fi

  [[ -f "$RAVEN_DATA_DIR/.identity-initialized" ]]
  [[ -f "$RAVEN_DATA_DIR/service-bridge.addr" ]]
  [[ ! -e "$RAVEN_DATA_DIR/.service-install.lock" ]]
  [[ ! -e "$RAVEN_DATA_DIR/install-backups" ]]
  [[ ! -e "$RAVEN_INSTALL_STATE_DIR/.service-install.lock" ]]
  [[ -d "$RAVEN_INSTALL_STATE_DIR/install-backups" ]]
  grep -Fq "installer-state=$RAVEN_INSTALL_STATE_DIR" "$case_root.stdout"
}

run_rollback_case() {
  local case_root="$SMOKE_ROOT/rollback"
  local plist
  export HOME="$case_root/home"
  export RAVEN_BIN_DIR="$case_root/bin"
  export RAVEN_DATA_DIR="$case_root/data"
  export RAVEN_INSTALL_STATE_DIR="$case_root/installer-state"
  export RAVEN_SMOKE_LAUNCHCTL_STATE="$case_root/launchctl.loaded"
  export RAVEN_SMOKE_INIT_FAIL=1
  plist="$HOME/Library/LaunchAgents/com.raven.raven-node.plist"
  mkdir -p "$RAVEN_BIN_DIR" "$HOME/Library/LaunchAgents"
  printf '%s\n' old-node >"$RAVEN_BIN_DIR/raven-node"
  printf '%s\n' old-raven >"$RAVEN_BIN_DIR/raven"
  printf '%s\n' old-plist >"$plist"

  if bash "$INSTALLER" >"$case_root.stdout" 2>"$case_root.stderr"; then
    echo "ERROR: rollback smoke unexpectedly succeeded" >&2
    return 1
  fi

  [[ "$(<"$RAVEN_BIN_DIR/raven-node")" == "old-node" ]]
  [[ "$(<"$RAVEN_BIN_DIR/raven")" == "old-raven" ]]
  [[ "$(<"$plist")" == "old-plist" ]]
  [[ ! -e "$RAVEN_BIN_DIR/ash" ]]
  [[ ! -e "$RAVEN_DATA_DIR/.service-install.lock" ]]
  [[ ! -e "$RAVEN_DATA_DIR/install-backups" ]]
  [[ ! -e "$RAVEN_INSTALL_STATE_DIR/.service-install.lock" ]]
  [[ -d "$RAVEN_INSTALL_STATE_DIR/install-backups" ]]
  grep -Fq "install failed; restoring the previous user-scoped files" "$case_root.stderr"
}

run_overlap_rejection_case() {
  local case_root="$SMOKE_ROOT/overlap"
  local unicode_parent
  local unicode_lower_inode
  local unicode_upper_inode
  export HOME="$case_root/home"
  export RAVEN_DATA_DIR="$case_root/profile"
  export RAVEN_BIN_DIR="$RAVEN_DATA_DIR/bin"
  export RAVEN_INSTALL_STATE_DIR="$case_root/installer-state"
  export RAVEN_SMOKE_LAUNCHCTL_STATE="$case_root/launchctl.loaded"
  unset RAVEN_SMOKE_INIT_FAIL
  mkdir -p "$HOME"

  if bash "$INSTALLER" >"$case_root.stdout" 2>"$case_root.stderr"; then
    echo "ERROR: overlapping DataDir/BinDir smoke unexpectedly succeeded" >&2
    return 1
  fi
  [[ ! -e "$RAVEN_DATA_DIR" ]]
  [[ ! -e "$RAVEN_INSTALL_STATE_DIR" ]]
  grep -Fq "none may contain another" "$case_root.stderr"

  export RAVEN_DATA_DIR="$case_root/case-profile"
  export RAVEN_BIN_DIR="$case_root/CASE-PROFILE/bin"
  export RAVEN_INSTALL_STATE_DIR="$case_root/case-installer-state"
  if bash "$INSTALLER" >"$case_root.case.stdout" 2>"$case_root.case.stderr"; then
    echo "ERROR: case-variant overlapping DataDir/BinDir smoke unexpectedly succeeded" >&2
    return 1
  fi
  [[ ! -e "$RAVEN_DATA_DIR" ]]
  [[ ! -e "$RAVEN_BIN_DIR" ]]
  [[ ! -e "$RAVEN_INSTALL_STATE_DIR" ]]
  grep -Fq "none may contain another" "$case_root.case.stderr"

  # On the default case-insensitive APFS, these two Unicode spellings resolve
  # to one directory even though Bash's C-locale ASCII fold cannot equate them.
  # The installer must use the filesystem as the final overlap authority and
  # remove the empty `bin` probe it created before refusing.
  unicode_parent="$case_root/unicode"
  mkdir -p "$unicode_parent/é"
  unicode_lower_inode="$(stat -f '%d:%i' "$unicode_parent/é")"
  unicode_upper_inode="$(stat -f '%d:%i' "$unicode_parent/É" 2>/dev/null || true)"
  if [[ -n "$unicode_upper_inode" && "$unicode_lower_inode" == "$unicode_upper_inode" ]]; then
    printf '%s\n' profile-sentinel >"$unicode_parent/é/sentinel"
    export RAVEN_DATA_DIR="$unicode_parent/é"
    export RAVEN_BIN_DIR="$unicode_parent/É/bin"
    export RAVEN_INSTALL_STATE_DIR="$case_root/unicode-installer-state"
    if bash "$INSTALLER" >"$case_root.unicode.stdout" 2>"$case_root.unicode.stderr"; then
      echo "ERROR: Unicode case-variant overlap smoke unexpectedly succeeded" >&2
      return 1
    fi
    [[ "$(<"$unicode_parent/é/sentinel")" == "profile-sentinel" ]]
    [[ ! -e "$unicode_parent/é/bin" ]]
    [[ ! -e "$RAVEN_INSTALL_STATE_DIR" ]]
    if ! grep -Fq "overlapping filesystem paths" "$case_root.unicode.stderr"; then
      command cat "$case_root.unicode.stdout" "$case_root.unicode.stderr" >&2
      echo "ERROR: Unicode overlap was not rejected by the physical-path gate" >&2
      return 1
    fi
  fi
}

run_success_case
run_rollback_case
run_overlap_rejection_case
printf '%s\n' MACOS_LAUNCHD_FRESH_PROFILE_AND_ROLLBACK_OK
