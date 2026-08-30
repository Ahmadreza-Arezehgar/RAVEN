#!/usr/bin/env bash
set -Eeuo pipefail

data_dir=""
command_name=""
while (( $# > 0 )); do
  case "$1" in
    --data-dir)
      [[ $# -ge 2 ]] || { echo "missing --data-dir value" >&2; exit 64; }
      data_dir="$2"
      shift 2
      ;;
    init|ipc-ping)
      command_name="$1"
      shift
      ;;
    *) shift ;;
  esac
done

[[ -n "$data_dir" ]] || { echo "fake raven received no --data-dir" >&2; exit 64; }

directory_is_empty() (
  shopt -s nullglob dotglob
  local entries=("$1"/*)
  (( ${#entries[@]} == 0 ))
)

case "$command_name" in
  init)
    if ! directory_is_empty "$data_dir"; then
      echo "fake raven: fresh profile was not empty before init" >&2
      exit 90
    fi
    if [[ "${RAVEN_SMOKE_INIT_FAIL:-0}" == "1" ]]; then
      echo "fake raven: requested init failure" >&2
      exit 91
    fi
    printf '%s\n' initialized >"$data_dir/.identity-initialized"
    ;;
  ipc-ping)
    [[ -f "$data_dir/.identity-initialized" ]]
    ;;
  *)
    echo "fake raven received unsupported command" >&2
    exit 64
    ;;
esac
