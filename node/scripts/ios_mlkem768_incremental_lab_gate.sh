#!/usr/bin/env bash
#
# Debug/lab-only Swift XCTest gate for raven-mlkem768-incremental-ffi.
# Builds the frozen three-triple XCFramework (IPHONEOS_DEPLOYMENT_TARGET=17.0),
# then links the host simulator slice. Does not modify Xcode Release settings.
#
# Usage:
#   ./node/scripts/ios_mlkem768_incremental_lab_gate.sh
#   DEST='platform=iOS Simulator,name=RAVEN-iPhone-15,OS=26.5' \
#     ./node/scripts/ios_mlkem768_incremental_lab_gate.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NODE="$ROOT/node"
IOS="$ROOT/ios-native/RAVEN"
PROJECT="$IOS/RAVEN.xcodeproj"
SCHEME="RAVEN"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$NODE/target/mlkem768-incremental-ios-lab}"
INCLUDE_DIR="$NODE/crates/raven-mlkem768-incremental-ffi/include"
XCF_DIR="$CARGO_TARGET_DIR/xcframework"
XCF_NAME="RavenMlKem768Incremental.xcframework"
XCF_PATH="$XCF_DIR/$XCF_NAME"
IOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

DEVICE_TARGET="aarch64-apple-ios"
SIM_ARM_TARGET="aarch64-apple-ios-sim"
SIM_X86_TARGET="x86_64-apple-ios"

for t in "$DEVICE_TARGET" "$SIM_ARM_TARGET" "$SIM_X86_TARGET"; do
  if ! rustup target list --installed | rg -qx "$t"; then
    echo "missing Rust target $t; run: rustup target add $t" >&2
    exit 2
  fi
done

resolve_destination() {
  if [[ -n "${DEST:-}" ]]; then
    echo "$DEST"
    return
  fi
  if [[ -n "${DEVICE_ID:-}" ]]; then
    echo "platform=iOS Simulator,id=${DEVICE_ID}"
    return
  fi

  local simulator_id
  simulator_id="$(
    xcrun simctl list devices available -j | python3 -c '
import json
import sys

devices = json.load(sys.stdin)["devices"]
candidates = [
    (runtime, device)
    for runtime, entries in devices.items()
    for device in entries
    if device.get("isAvailable") and "iPhone" in device.get("name", "")
]
if not candidates:
    raise SystemExit("no available iPhone simulator")

def runtime_version(item):
    raw = item[0].rsplit("iOS-", 1)[-1]
    return tuple(int(part) for part in raw.split("-") if part.isdigit())

print(max(candidates, key=runtime_version)[1]["udid"])
'
  )"
  echo "platform=iOS Simulator,id=${simulator_id}"
}

DESTINATION="$(resolve_destination)"
echo "ML-KEM incremental lab destination: $DESTINATION" >&2
echo "IPHONEOS_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET" >&2

build_rust_target() {
  local target="$1"
  local log
  log="$(mktemp)"
  echo "--- cargo build --target $target (ios min $IOS_DEPLOYMENT_TARGET) ---" >&2
  (
    cd "$NODE"
    export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
    case "$target" in
      aarch64-apple-ios)
        export CFLAGS_aarch64_apple_ios="-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
        export CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS="-C link-arg=-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
        ;;
      aarch64-apple-ios-sim)
        export CFLAGS_aarch64_apple_ios_sim="-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
        export CARGO_TARGET_AARCH64_APPLE_IOS_SIM_RUSTFLAGS="-C link-arg=-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
        ;;
      x86_64-apple-ios)
        export CFLAGS_x86_64_apple_ios="-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
        export CARGO_TARGET_X86_64_APPLE_IOS_RUSTFLAGS="-C link-arg=-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
        ;;
    esac
    CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
      cargo build -p raven-mlkem768-incremental-ffi --target "$target" >"$log" 2>&1
  )
  if rg -n "built for newer iOS|was built for newer" "$log"; then
    echo "Rust archive targets newer iOS than app ($IOS_DEPLOYMENT_TARGET):" >&2
    cat "$log" >&2
    rm -f "$log"
    exit 1
  fi
  cat "$log" >&2
  rm -f "$log"
}

echo "=== Build lab-only Rust FFI for device + both simulators ===" >&2
for t in "$DEVICE_TARGET" "$SIM_ARM_TARGET" "$SIM_X86_TARGET"; do
  build_rust_target "$t"
done

DEVICE_LIB="$CARGO_TARGET_DIR/$DEVICE_TARGET/debug/libraven_mlkem768_incremental_ffi.a"
SIM_ARM_LIB="$CARGO_TARGET_DIR/$SIM_ARM_TARGET/debug/libraven_mlkem768_incremental_ffi.a"
SIM_X86_LIB="$CARGO_TARGET_DIR/$SIM_X86_TARGET/debug/libraven_mlkem768_incremental_ffi.a"
for lib in "$DEVICE_LIB" "$SIM_ARM_LIB" "$SIM_X86_LIB"; do
  if [[ ! -f "$lib" ]]; then
    echo "Rust FFI archive not found: $lib" >&2
    exit 1
  fi
done

echo "=== Create universal simulator archive + XCFramework ===" >&2
rm -rf "$XCF_DIR"
mkdir -p "$XCF_DIR"
SIM_UNIVERSAL="$XCF_DIR/libraven_mlkem768_incremental_ffi-sim-universal.a"
lipo -create "$SIM_ARM_LIB" "$SIM_X86_LIB" -output "$SIM_UNIVERSAL"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$INCLUDE_DIR" \
  -library "$SIM_UNIVERSAL" -headers "$INCLUDE_DIR" \
  -output "$XCF_PATH"

# Validate frozen triples are present in the XCFramework.
python3 - <<PY
from pathlib import Path
import subprocess
import sys

xcf = Path("$XCF_PATH")
if not xcf.is_dir():
    sys.exit(f"missing XCFramework: {xcf}")

slices = sorted(p.name for p in xcf.iterdir() if p.is_dir())
print("XCFramework slices:", slices)

# Exact device slice name — do not accept ios-arm64_* simulator prefixes.
if "ios-arm64" not in slices:
    sys.exit(f"exact device slice ios-arm64 missing in {slices}")

sim_slices = [s for s in slices if "simulator" in s]
if not sim_slices:
    sys.exit(f"simulator slice missing in {slices}")

sim_libs = [p for p in xcf.rglob("*.a") if "simulator" in str(p)]
if not sim_libs:
    sys.exit("no simulator .a inside XCFramework")
archs = subprocess.check_output(["lipo", "-archs", str(sim_libs[0])], text=True).split()
print("simulator archive archs:", archs)
if "arm64" not in archs or "x86_64" not in archs:
    sys.exit(f"simulator universal archive must contain arm64+x86_64, got {archs}")
print("XCFramework OK:", xcf)
PY

case "$(uname -m)" in
  arm64 | aarch64)
    HOST_SIM_ARCH="arm64"
    ;;
  x86_64)
    HOST_SIM_ARCH="x86_64"
    ;;
  *)
    echo "unsupported simulator host architecture: $(uname -m)" >&2
    exit 2
    ;;
esac

FFI_LIBRARY="$XCF_DIR/libraven_mlkem768_incremental_ffi-sim-${HOST_SIM_ARCH}.a"
lipo -extract "$HOST_SIM_ARCH" "$SIM_UNIVERSAL" -output "$FFI_LIBRARY"

echo "=== Run Swift fixture + linked FFI XCTests ===" >&2
XCODE_LOG="$(mktemp)"
(
  cd "$IOS"
  set +e
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG RAVEN_MLKEM768_INCREMENTAL_FFI' \
    'OTHER_LDFLAGS=$(inherited) $(RAVEN_MLKEM_LIB_$(PLATFORM_NAME))' \
    "RAVEN_MLKEM_LIB_iphonesimulator=$FFI_LIBRARY" \
    -only-testing:RAVENTests/ATSAMMlKem768IncrementalLabTests \
    >"$XCODE_LOG" 2>&1
  status=$?
  set -e
  if rg -n "built for newer iOS|was built for newer" "$XCODE_LOG"; then
    echo "xcodebuild reported newer-iOS object files; failing gate" >&2
    tail -n 80 "$XCODE_LOG" >&2
    rm -f "$XCODE_LOG"
    exit 1
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -n 120 "$XCODE_LOG" >&2
    rm -f "$XCODE_LOG"
    exit "$status"
  fi
  # Keep a short success summary visible.
  rg -n "TEST SUCCEEDED|Executed .* tests" "$XCODE_LOG" >&2 || true
  rm -f "$XCODE_LOG"
)

echo "ios_mlkem768_incremental_lab_gate: PASS (XCFramework + XCTest)" >&2
