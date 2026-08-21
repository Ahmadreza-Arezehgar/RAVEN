#!/usr/bin/env bash
# Hermetic Mac Catalyst Keychain-deny probe for Task 0A.0C.
#
# Frozen security invariant:
#   - Catalyst config has no application-groups / fullbraid entitlement.
#   - Real MACCATALYST-platform process denies Keychain writes to the exact
#     access group group.app.raven.fullbraid with errSecMissingEntitlement.
#
# Threat model (explicit):
#   - Unsandboxed Catalyst App Group filesystem is untrusted storage, NOT a
#     confidentiality boundary. containerURL is informational only.
#
# Does NOT build or run the full RAVEN Mac Catalyst product.
#
# Usage:
#   ./ios-native/RAVEN/scripts/fullbraid_catalyst_namespace_probe.sh
#   RUNS=2 ./ios-native/RAVEN/scripts/fullbraid_catalyst_namespace_probe.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
IOS="$ROOT/ios-native/RAVEN"
SRC_DIR="$IOS/scripts/FullBraidCatalystNamespaceProbe"
SRC="$SRC_DIR/main.swift"
ENT_IOS="$IOS/RAVEN/RAVEN.entitlements"
ENT_CATALYST="$IOS/RAVEN/RAVEN-Catalyst.entitlements"
PBX="$IOS/RAVEN.xcodeproj/project.pbxproj"
DEDICATED_GROUP="group.app.raven.fullbraid"
RUNS="${RUNS:-2}"
MIN_IOS="${MIN_IOS:-17.0}"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "FAIL: unsupported host arch=$ARCH" >&2
    exit 1
    ;;
esac

TARGET="${ARCH}-apple-ios${MIN_IOS}-macabi"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
OTOOL="$(xcrun --find otool)"
WORKDIR="$(mktemp -d /tmp/raven-fullbraid-catalyst-ns-XXXXXX)"
BIN="$WORKDIR/fullbraid_catalyst_ns_probe"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== Task 0A.0C hermetic Mac Catalyst Keychain-deny probe ===" >&2
echo "target=${TARGET}" >&2
echo "sdk=${SDKROOT}" >&2
echo "workdir=${WORKDIR}" >&2
echo "threat_model: unsandboxed Catalyst App Group FS = untrusted storage (not a confidentiality boundary)" >&2

test -f "$SRC"
test -f "$ENT_IOS"
test -f "$ENT_CATALYST"
test -f "$PBX"

# ---------------------------------------------------------------------------
# Static product wiring (does not build RAVEN Catalyst)
# ---------------------------------------------------------------------------
echo "=== static: Catalyst CODE_SIGN_ENTITLEMENTS wiring ===" >&2
WIRE_HIT=$(grep -c '"CODE_SIGN_ENTITLEMENTS\[sdk=macosx\*\]" = RAVEN/RAVEN-Catalyst.entitlements;' "$PBX" || true)
if [[ "$WIRE_HIT" -lt 2 ]]; then
  echo "FAIL: expected Debug+Release macosx* CODE_SIGN_ENTITLEMENTS → RAVEN-Catalyst.entitlements (found=$WIRE_HIT)" >&2
  exit 1
fi
echo "PASS: Debug+Release use RAVEN/RAVEN-Catalyst.entitlements for sdk=macosx* (hits=$WIRE_HIT)" >&2

echo "=== static: Catalyst entitlements lack application-groups/fullbraid ===" >&2
if plutil -extract 'com.apple.security.application-groups' raw "$ENT_CATALYST" >/dev/null 2>&1; then
  echo "FAIL: RAVEN-Catalyst.entitlements unexpectedly declares application-groups" >&2
  exit 1
fi
if grep -q 'fullbraid\|group\.app\.raven' "$ENT_CATALYST"; then
  echo "FAIL: RAVEN-Catalyst.entitlements mentions fullbraid/group.app.raven" >&2
  exit 1
fi
# Product Catalyst is intentionally unsandboxed for mesh — FS App Groups are untrusted there.
if ! plutil -extract 'com.apple.security.app-sandbox' raw "$ENT_CATALYST" 2>/dev/null | grep -Eq '^(false|0)$'; then
  echo "WARN: could not confirm app-sandbox=false on Catalyst entitlements (informational)" >&2
fi
plutil -lint "$ENT_CATALYST" >/dev/null
echo "PASS: Catalyst entitlements have no application-groups/fullbraid" >&2

echo "=== static: iOS main entitlements include dedicated group ===" >&2
plutil -lint "$ENT_IOS" >/dev/null
if ! grep -q "$DEDICATED_GROUP" "$ENT_IOS"; then
  echo "FAIL: RAVEN.entitlements missing $DEDICATED_GROUP" >&2
  exit 1
fi
echo "PASS: RAVEN.entitlements declares $DEDICATED_GROUP (iPhone positive config)" >&2

# ---------------------------------------------------------------------------
# Signed iOS product audit (reuse latest DerivedData products if present)
# ---------------------------------------------------------------------------
echo "=== signed iOS product audit (preserves physical iPhone positive evidence) ===" >&2
DD_ROOT="${DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"
AUDIT_OK=0
for CONF in Debug Release; do
  APP="$(ls -dt "$DD_ROOT"/RAVEN-*/Build/Products/${CONF}-iphoneos/RAVEN.app 2>/dev/null | head -1 || true)"
  if [[ -z "$APP" || ! -d "$APP" ]]; then
    echo "WARN: no ${CONF}-iphoneos/RAVEN.app under DerivedData — skip signed audit for $CONF" >&2
    continue
  fi
  MAIN_COUNT="$(codesign -d --entitlements :- "$APP" 2>/dev/null \
    | plutil -convert xml1 -o - - 2>/dev/null \
    | grep -c "$DEDICATED_GROUP" || true)"
  if [[ "$MAIN_COUNT" -lt 1 ]]; then
    echo "FAIL: signed $(basename "$APP") ($CONF) missing $DEDICATED_GROUP" >&2
    exit 1
  fi
  echo "PASS: ${CONF} RAVEN.app fullbraid=${MAIN_COUNT}" >&2
  while IFS= read -r -d '' EMBED; do
    EMBED_COUNT="$(codesign -d --entitlements :- "$EMBED" 2>/dev/null \
      | plutil -convert xml1 -o - - 2>/dev/null \
      | grep -c "$DEDICATED_GROUP" || true)"
    rel="${EMBED#$APP/}"
    if [[ "$EMBED_COUNT" -ne 0 ]]; then
      echo "FAIL: embedded $rel ($CONF) fullbraid=${EMBED_COUNT} (must be 0)" >&2
      exit 1
    fi
    echo "PASS: ${CONF} embedded $rel fullbraid=0" >&2
  done < <(find "$APP/PlugIns" "$APP/Watch" \( -name '*.appex' -o -name '*.app' \) -print0 2>/dev/null || true)
  AUDIT_OK=1
done
if [[ "$AUDIT_OK" -ne 1 ]]; then
  echo "FAIL: no signed Debug/Release iPhoneOS RAVEN.app found for audit" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build / sign / verify / run hermetic Catalyst executable
# ---------------------------------------------------------------------------
build_and_run_once() {
  local run_id="$1"
  echo "=== hermetic run ${run_id}/${RUNS}: compile ${TARGET} ===" >&2
  rm -f "$BIN"
  "$SWIFTC" \
    -parse-as-library \
    -target "$TARGET" \
    -sdk "$SDKROOT" \
    -F "$SDKROOT/System/iOSSupport/System/Library/Frameworks" \
    -I "$SDKROOT/System/iOSSupport/usr/lib/swift" \
    -L "$SDKROOT/System/iOSSupport/usr/lib/swift" \
    -framework Foundation \
    -framework Security \
    -o "$BIN" \
    "$SRC"

  echo "=== hermetic run ${run_id}/${RUNS}: LC_BUILD_VERSION platform ===" >&2
  local lc
  lc="$("$OTOOL" -l "$BIN")"
  if ! printf '%s\n' "$lc" | awk '
    /cmd LC_BUILD_VERSION/ { in_bv=1; next }
    in_bv && /cmd / { in_bv=0 }
    in_bv && /platform/ {
      if ($2 == 6 || $2 == "6" || toupper($2) ~ /MACCATALYST/) found=1
    }
    END { exit(found ? 0 : 1) }
  '; then
    echo "FAIL: LC_BUILD_VERSION does not show MACCATALYST (platform 6)" >&2
    printf '%s\n' "$lc" | awk '/LC_BUILD_VERSION/,/cmd LC_/' >&2 || true
    exit 1
  fi
  echo "PASS: LC_BUILD_VERSION platform=MACCATALYST" >&2

  echo "=== hermetic run ${run_id}/${RUNS}: ad-hoc codesign (no application-groups; sandbox=false mirrors product) ===" >&2
  local ent="$SRC_DIR/probe.entitlements"
  test -f "$ent"
  if plutil -extract 'com.apple.security.application-groups' raw "$ent" >/dev/null 2>&1; then
    echo "FAIL: probe.entitlements must not declare application-groups" >&2
    exit 1
  fi
  if grep -Eq 'fullbraid|group\.app\.raven' "$ent"; then
    echo "FAIL: probe.entitlements must not mention fullbraid/group.app.raven" >&2
    exit 1
  fi
  codesign --force -s - --entitlements "$ent" "$BIN" >/dev/null
  codesign --verify --verbose=2 "$BIN" >/dev/null
  local signed_ent
  signed_ent="$(codesign -d --entitlements :- "$BIN" 2>/dev/null | plutil -convert xml1 -o - -)"
  if printf '%s\n' "$signed_ent" | grep -q "$DEDICATED_GROUP"; then
    echo "FAIL: ad-hoc signed probe unexpectedly carries $DEDICATED_GROUP" >&2
    exit 1
  fi
  if printf '%s\n' "$signed_ent" | grep -q 'application-groups'; then
    echo "FAIL: ad-hoc signed probe unexpectedly carries application-groups" >&2
    exit 1
  fi
  echo "PASS: ad-hoc signature verified without application-groups/$DEDICATED_GROUP" >&2

  echo "=== hermetic run ${run_id}/${RUNS}: runtime Keychain deny ===" >&2
  "$BIN"
}

for ((i=1; i<=RUNS; i++)); do
  build_and_run_once "$i"
done

echo "" >&2
echo "PASS: Catalyst Keychain deny invariant (exact access group)" >&2
echo "PASS: Catalyst config has no App Group / fullbraid entitlement" >&2
echo "THREAT_MODEL: Catalyst App Group filesystem = untrusted storage (unsandboxed); not a confidentiality boundary" >&2
echo "NOTE: full RAVEN Mac Catalyst product was NOT built or run." >&2
echo "" >&2
echo "=== Task 0A.1 prerequisites (explicit; not started) ===" >&2
echo "  - All RVFB/RVBJ/RVOR and body-stages on disk MUST be AEAD-encrypted." >&2
echo "  - Keys MUST live ThisDeviceOnly in the iOS-only Keychain access group." >&2
echo "  - Catalyst backend initialization MUST fail-closed." >&2
echo "  - Ciphertext tampering MUST be rejected before parse/state mutation." >&2
echo "NOTE: STOP-LINE for Task 0A.1 still requires explicit owner approval." >&2
