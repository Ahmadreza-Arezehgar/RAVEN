#!/usr/bin/env bash
# Task 0A.5 alias: CommonCrypto↔OpenSSL reciprocal open-profile gate.
# Delegates to the Task 0A.4 signed-simulator orchestrator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$ROOT/node/scripts/full_braid_sqlcipher_open_profile_gate.sh" "$@"
