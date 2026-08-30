#!/usr/bin/env bash
# Install user-scoped raven-node systemd unit (Linux). Never touches /bin/ash.
set -euo pipefail

# R1 intentionally has no approved prompt-free protected identity backend for
# a fresh Linux service. Fail before creating directories, copying binaries,
# replacing links, or registering a partial unit.
echo "ERROR: Linux service installation is held at the protected identity-store gate." >&2
echo "No files, links, or systemd units were changed." >&2
echo "Use a source checkout for review/tests only; do not present it as a Linux release install." >&2
exit 2
