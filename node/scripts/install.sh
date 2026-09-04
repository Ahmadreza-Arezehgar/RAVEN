#!/usr/bin/env bash
# NOT a production installer. Historical curl|bash convenience path — retired.
#
# This script used to:
#   - clone https://github.com/Ahmadreza-Arezehgar/RAVEN.git (personal fork)
#   - cargo build debug with --features raven-node/unsafe-demo-crypto
#   - ad-hoc codesign on Darwin (`codesign -s -`)
#   - symlink ~/.local/bin/raven → that debug ash
#
# That is not an install path. Operators: use the docs and scripts below.
set -euo pipefail

cat >&2 <<'EOF'

========================================================================
RAVEN: node/scripts/install.sh is NOT a production installer.
========================================================================

This script is fail-closed on purpose. It does not clone, build, codesign,
or put binaries on PATH.

The retired convenience path was unsafe:
  - hardcoded personal-fork remote (Ahmadreza-Arezehgar/RAVEN),
    not Raven-ASHCO/RAVEN
  - debug build with raven-node/unsafe-demo-crypto
  - Darwin ad-hoc codesign -s -
  - ~/.local/bin/raven → those debug binaries

Do not:  curl …/node/scripts/install.sh | bash

Operator install (release / secure build only):
  docs/INSTALL_Linux.md    →  node/scripts/install/linux_systemd_user.sh
  docs/INSTALL_macOS.md    →  node/scripts/install/macos_launchd.sh
  docs/INSTALL_Windows.md  →  node/scripts/install/WINDOWS_SERVICE.md

From a checkout of https://github.com/Raven-ASHCO/RAVEN :

  cd node
  cargo build -p raven-node -p ash --release
  bash scripts/install/linux_systemd_user.sh   # or macos_launchd.sh

Lab / demo feature flags (unsafe-demo-crypto) are for explicit local
experiments only. They must never be the default PATH install.

========================================================================

EOF
exit 1
