#!/usr/bin/env bash
# Slice 3 Task 0A.4 open-profile + reciprocal provider gate.
# Task 0A.5 CI invokes this via full_braid_sqlcipher_cross_provider_gate.sh.
# Does not enable production or start Task 0B.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
IOS_ROOT="$REPO_ROOT/ios-native/RAVEN"
NODE_ROOT="$REPO_ROOT/node"
TEST_ID="RAVENTests/ATSAMFullBraidSQLCipherProfileV1Tests"

for command_name in cargo xcodebuild xcrun python3; do
  command -v "$command_name" >/dev/null || {
    echo "FULL_BRAID_0A4_TOOL_MISSING:$command_name" >&2
    exit 1
  }
done

if [[ -n "${RAVEN_IOS_SIMULATOR_UDID:-}" ]]; then
  SIMULATOR_UDID="$RAVEN_IOS_SIMULATOR_UDID"
else
  SIMULATOR_UDID="$(xcrun simctl list -j devices available | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=[]
for runtime,devices in d.items():
    if "iOS" not in runtime: continue
    version=tuple(int(x) for x in runtime.split("iOS-",1)[-1].split("-") if x.isdigit())
    for dev in devices:
        if dev.get("isAvailable"):
            c.append((dev.get("name") == "RAVEN-Trust-Test", version, dev["udid"]))
if not c: raise SystemExit("FULL_BRAID_0A4_NO_SIMULATOR")
print(sorted(c, reverse=True)[0][2])
')"
fi

DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"
XCODE_ARGS=(
  -quiet
  -project "$IOS_ROOT/RAVEN.xcodeproj"
  -scheme RAVEN
  -destination "$DESTINATION"
  CODE_SIGNING_ALLOWED=YES
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
)

GATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/raven-0a4-open-gate.XXXXXX")"
trap 'rm -rf -- "$GATE_TMP"' EXIT

run_swift_test() {
  local method="$1"
  xcodebuild test "${XCODE_ARGS[@]}" -only-testing:"$TEST_ID/$method"
}

run_swift_base_suite() {
  local methods=(
    testProductionRemainsDisabled
    testLabLinkageProbeAcceptsOfficialCommonCryptoPin
    testCipherVersionAllowListRejectsModifiedPrefixMatch
    testFrozenProfileCreateReopenTempAndNoPlaintext
    testFirstInstallProofCannotBecomeCREATEFallback
    testWrongKeySaltPlaintextAndPublicProfileFailClosed
    testTruncatedCorruptAndUnsafePathsFailBeforeAcceptance
    testIndependentlySwappedWALAndSHMAreRejectedWithoutMutation
  )
  local only=()
  local method
  for method in "${methods[@]}"; do
    only+=("-only-testing:$TEST_ID/$method")
  done
  xcodebuild test "${XCODE_ARGS[@]}" "${only[@]}"
}

run_swift_crash_step() {
  local method="$1"
  xcodebuild test "${XCODE_ARGS[@]}" -only-testing:"$TEST_ID/$method"
}

expect_swift_process_crash() {
  local method="$1"
  local marker="$2"
  local log="$GATE_TMP/$method.log"
  local marker_file="$CRASH_DIR/last-crash.marker"
  local rc
  rm -f -- "$marker_file"
  set +e
  xcodebuild test "${XCODE_ARGS[@]}" -only-testing:"$TEST_ID/$method" >"$log" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FULL_BRAID_0A4_EXPECTED_CRASH_DID_NOT_OCCUR:$method" >&2
    cat "$log" >&2
    exit 1
  fi
  if [[ ! -f "$marker_file" || "$(cat "$marker_file")" != "$marker" ]]; then
    echo "FULL_BRAID_0A4_EXPECTED_CRASH_MARKER_MISSING:$method" >&2
    cat "$log" >&2
    exit 1
  fi
  echo "expected-process-crash $method"
}

echo "0A4: Rust profile suite"
(
  cd "$NODE_ROOT"
  RAVEN_EXPECT_SQLCIPHER_4_17_0=1 \
    cargo test -p raven-core --features full-braid-durable-lab \
      --test full_braid_sqlcipher_profile -- --test-threads=1
)

echo "0A4: signed Swift profile suite"
run_swift_base_suite

xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b >/dev/null
GROUP_CONTAINER="$(xcrun simctl get_app_container \
  "$SIMULATOR_UDID" app.raven.ios group.app.raven.fullbraid)"
case "$GROUP_CONTAINER" in
  */data/Containers/Shared/AppGroup/*) ;;
  *)
    echo "FULL_BRAID_0A4_GROUP_CONTAINER_REJECTED" >&2
    exit 1
    ;;
esac
INTEROP_DIR="$GROUP_CONTAINER/Task0A4Interop"
CRASH_DIR="$GROUP_CONTAINER/Task0A4Crash"
if [[ -L "$CRASH_DIR" || ( -e "$CRASH_DIR" && ! -d "$CRASH_DIR" ) ]]; then
  echo "FULL_BRAID_0A4_CRASH_DIRECTORY_REJECTED" >&2
  exit 1
fi
mkdir -p "$CRASH_DIR"
rm -f -- \
  "$CRASH_DIR/commoncrypto-crash.db" \
  "$CRASH_DIR/commoncrypto-crash.db-wal" \
  "$CRASH_DIR/commoncrypto-crash.db-shm" \
  "$CRASH_DIR/last-crash.marker" \
  "$CRASH_DIR/orchestrator.token"
printf 'RAVEN_0A4_CRASH_GATE_V1\n' >"$CRASH_DIR/orchestrator.token"

echo "0A4: CommonCrypto process-crash boundaries"
run_swift_crash_step testCrashPhaseInitializeCommonCryptoFixture
expect_swift_process_crash \
  testCrashPhaseExitWithUncommittedTransaction \
  RAVEN_0A4_COMMONCRYPTO_CRASH_UNCOMMITTED
run_swift_crash_step testCrashPhaseVerifyUncommittedWasRolledBack
expect_swift_process_crash \
  testCrashPhaseExitAfterCommit \
  RAVEN_0A4_COMMONCRYPTO_CRASH_COMMITTED
run_swift_crash_step testCrashPhaseVerifyCommittedTransaction
expect_swift_process_crash \
  testCrashPhaseExitAfterCheckpoint \
  RAVEN_0A4_COMMONCRYPTO_CRASH_CHECKPOINTED
run_swift_crash_step testCrashPhaseVerifyCheckpointedTransaction

echo "0A4: CommonCrypto creates encrypted-header fixture"
run_swift_test testInteropPhase1SwiftCreatesCommonCryptoFixture

run_rust_interop() {
  local phase="$1"
  (
    cd "$NODE_ROOT"
    RAVEN_EXPECT_SQLCIPHER_4_17_0=1 \
    RAVEN_0A4_INTEROP_PHASE="$phase" \
    RAVEN_0A4_INTEROP_DIR="$INTEROP_DIR" \
      cargo test -p raven-core --features full-braid-durable-lab \
        --test full_braid_sqlcipher_profile \
        commoncrypto_openssl_reciprocal_interop_phase -- \
        --ignored --exact --test-threads=1
  )
}

echo "0A4: OpenSSL opens/mutates CommonCrypto and creates reciprocal fixture"
run_rust_interop rust-middle

echo "0A4: CommonCrypto reopens both files and mutates both"
run_swift_test testInteropPhase3SwiftOpensAndMutatesBothProviders

echo "0A4: OpenSSL final reopen after CommonCrypto mutation"
run_rust_interop rust-final

echo "PASS: Full Braid SQLCipher Task 0A.4 open profile"
echo "  CommonCrypto <-> OpenSSL reciprocal encrypted-file mutation"
echo "  SQLCipher 4.17.0 / SQLite 3.53.3 / header=32 / page=4096"
