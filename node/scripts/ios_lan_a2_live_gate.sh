#!/usr/bin/env bash
# Task 17 — A2 live gate harness (automated prerequisites + operator checklist).
#
# Runs everything that can be automated without a physical iPhone, then prints
# PASS/FAIL templates for manual Terminal↔iPhone steps.
#
# Usage:
#   ./node/scripts/ios_lan_a2_live_gate.sh
#   DEST='platform=iOS Simulator,name=RAVEN-iPhone-15' ./node/scripts/ios_lan_a2_live_gate.sh
#   SKIP_RUST=1 ./node/scripts/ios_lan_a2_live_gate.sh   # iOS-only pass
#
# Required for live steps (operator):
#   RAVEN_LAB_TEST_A=1  (or -ravenLabTestA / Settings → Lab Test A)
#   iPhone device_ed_pub in Mac contacts.json pub_hex
#   Mac lab cert pasted on iPhone; iPhone cert imported on Mac
#   iPhone foreground on Serverless LAN screen; listen port saved (default 7421)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/ios-native/RAVEN"
PROJECT="$IOS/RAVEN.xcodeproj"
SCHEME="RAVEN"
DEST="${DEST:-platform=iOS Simulator,name=RAVEN-iPhone-15}"

AUTOMATED_OK=1
LIVE_STATUS="PENDING_OPERATOR"

echo "=== Task 17 A2 gate — automated prerequisites ===" >&2
echo "repo: $ROOT" >&2
echo "ios destination: $DEST" >&2
echo "" >&2
echo "Live env (operator must set before manual steps):" >&2
echo "  export RAVEN_LAB_TEST_A=1" >&2
echo "  Mac contacts.json pub_hex = iPhone device_ed_pub (32-byte hex)" >&2
echo "  iPhone Settings → Serverless LAN → Lab Test A ON, listen port saved" >&2
echo "  iPhone foreground on LAN screen; Mac raven-node/ash with lan_dial to iPhone" >&2
echo "" >&2

run_step() {
  local label="$1"
  shift
  echo "--- $label ---" >&2
  if "$@"; then
    echo "PASS: $label" >&2
  else
    echo "FAIL: $label" >&2
    AUTOMATED_OK=0
  fi
  echo "" >&2
}

if [[ "${SKIP_RUST:-}" != "1" ]]; then
  run_step "Rust LAN vectors (cargo test lan_)" bash -c \
    "cd '$ROOT/node' && cargo test -p raven-core --lib lan_ -q"
  run_step "Rust two-node lan_direct slice" bash -c \
    "'$ROOT/node/scripts/lan_direct_two_node.sh'"
else
  echo "SKIP_RUST=1 — skipping Rust prerequisites" >&2
  echo "" >&2
fi

run_step "iOS LAN KAT (Noise + RLB1 + Release gate)" bash -c \
  "'$ROOT/node/scripts/ios_lan_kat.sh'"

run_step "iOS A2 memory-duplex gate tests" bash -c \
  "cd '$IOS' && xcodebuild test \
    -project '$PROJECT' \
    -scheme '$SCHEME' \
    -destination '$DEST' \
    -parallel-testing-enabled NO \
    -only-testing:RAVENTests/RavenSecureLanLoopbackIntegrationTests \
    -only-testing:RAVENTests/RavenSecureLanA2GateTests"

echo "=== Automated summary ===" >&2
if [[ "$AUTOMATED_OK" -eq 1 ]]; then
  echo "AUTOMATED: PASS (memory duplex + Rust prerequisites)" >&2
else
  echo "AUTOMATED: FAIL — fix above before live A2 gate" >&2
  LIVE_STATUS="BLOCKED_AUTOMATED_FAIL"
fi

echo "" >&2
echo "=== A2 NOT COMPLETE until operator confirms live steps ===" >&2
echo "Checklist: node/scripts/ios_lan_lab_checklist.md (Task 17 gate section)" >&2
echo "" >&2
cat <<'EOF'
Live operator template (mark PASS/FAIL on device):

| # | Scenario | Operator result |
|---|----------|-----------------|
| 1 | Terminal → iPhone: PairInit, indexed message, sealed ACK | [ ] PASS  [ ] FAIL |
| 2 | iPhone → Terminal: reverse PairInit, message, ACK | [ ] PASS  [ ] FAIL |
| 3 | Kill/relaunch iPhone; session continues; retry/ACK | [ ] PASS  [ ] FAIL |
| 4 | ACK loss + PairResponse loss; retry exact same bytes | [ ] PASS  [ ] FAIL |
| 5 | Duplicate frame → identical ACK; no second decrypt | [ ] PASS  [ ] FAIL |
| 6 | Contact delete → refuse message/ACK/PairInit | [ ] PASS  [ ] FAIL |
| 7 | Block peer → refuse | [ ] PASS  [ ] FAIL |
| 8 | Revoke/expiry → fail-closed abandon | [ ] PASS  [ ] FAIL |
| 9 | Confirm no raw/RVNP1/interim fallback on secure path | [ ] PASS  [ ] FAIL |

A2 COMPLETE: YES only when rows 1–9 are PASS on real iPhone + Mac Terminal.
EOF

if [[ "$AUTOMATED_OK" -ne 1 ]]; then
  exit 1
fi

echo "" >&2
echo "Automated prerequisites green. Run live rows on physical iPhone." >&2
exit 0
