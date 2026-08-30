#!/usr/bin/env bash
# Compatibility entrypoint for the current authenticated terminal transport
# regression. The former implementation mixed `raven-node run` with the
# service-only `ash send` protocol and therefore did not test the product path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/lan_direct_two_node.sh" "$@"
