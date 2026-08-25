#!/usr/bin/env bash
# Task 0B.2 physical gate — host-side negatives (no device / no xcodebuild).
#
# 1) last_phase=C + PHASE=B fails in ORDER_CHECK_ONLY before preflight
# 2) ok!=true result refuses state/evidence write; fixture state unchanged
# 3) completed-phase re-run refusals (B after B, C after C, …)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/node/scripts/ios_full_braid_protected_anchor_physical_gate.sh"
LIB="$ROOT/node/scripts/lib/ios_full_braid_protected_anchor_physical_gate_lib.sh"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*" >&2; }

[[ -x "$GATE" || -f "$GATE" ]] || die "missing gate script"
[[ -f "$LIB" ]] || die "missing gate lib"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/raven-fb-physical-gate-neg.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

FIXTURE_UDID="00008140-000C399A367B001C"
FIXTURE_RUN="98c6d028-0292-4cab-a6a3-8b2b87f04ce0"

write_phase_c_fixture() {
  local dest="$1"
  python3 - "$dest" "$FIXTURE_UDID" "$FIXTURE_RUN" <<'PY'
import json,sys
path, udid, run_id = sys.argv[1:4]
state = {
  "harness": "raven.atsam.full-braid.physical-gate.v1",
  "run_id": run_id,
  "device_udid": udid,
  "last_phase": "C",
  "last_outcome": "LOCK_UNLOCK_MATCH_NO_REWRITE",
  "production_enabled": False,
  "release_hold": "FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED",
  "scope_id_hex": "232ad76f93775518cdb0660fcbcdd392d1ce54cc95e729b00a1a8990f7ea53bb",
  "seed_digest_sha256": "4217b35435e45fbf1e564a40b12d7caeb6fedb234a8732776c915170ba46b8cb",
  "record_key_digest_sha256": "4f2958dbd376dbd73521b05f276a5b754baa389ad16f05d27daa75c081d8b249",
  "seq1_digest_sha256": "b9c4983b42609ede87c931fa6f1fc0dfa55ca3014338a98c3263062a68557e5f",
  "seq2_digest_sha256": "c7264f62604c134a5d86144dcc8432f5476873771eafdfa6791c035b3a3726ef",
  "chain_digest_sha256": "be3f0a49633aa39203c70884d383f762cbfca5d065150cc7fa50cebd6e1ecfc5",
  "phases": [
    {"phase": "A", "ok": True, "outcome": "CREATED_SEED_AND_SEQ1", "detail": None, "platform_hold_code": None},
    {"phase": "B", "ok": True, "outcome": "RELAUNCH_MATCH_AND_APPEND_SEQ2", "detail": None, "platform_hold_code": None},
    {"phase": "C", "ok": True, "outcome": "LOCK_UNLOCK_MATCH_NO_REWRITE", "detail": None, "platform_hold_code": None},
  ],
}
with open(path, "w") as f:
    json.dump(state, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# --- 1) last_phase=C + PHASE=B fails before preflight/xcodebuild ---
EV1="$TMP/order-c-then-b"
mkdir -p "$EV1"
write_phase_c_fixture "$EV1/state.json"
set +e
out1="$(
  ORDER_CHECK_ONLY=1 \
  DEVICE_UDID="$FIXTURE_UDID" \
  PHASE=B \
  EVIDENCE_DIR="$EV1" \
  bash "$GATE" 2>&1
)"
rc1=$?
set -e
[[ "$rc1" -ne 0 ]] || die "C→B order: expected non-zero exit"
echo "$out1" | grep -Eq 'exact predecessor A/A_RESUME|already completed' \
  || die "C→B order: missing predecessor diagnostic; got: $out1"
echo "$out1" | grep -Eqi 'xcodebuild|Preflight|build-for-testing' \
  && die "C→B order: must not reach preflight/xcodebuild; got: $out1"
pass "last_phase=C + PHASE=B fails before preflight"

# --- 2) ok!=true refuses write; state hash unchanged ---
EV2="$TMP/refuse-ok-false"
mkdir -p "$EV2"
write_phase_c_fixture "$EV2/state.json"
before="$(sha256_file "$EV2/state.json")"
export STATE="$EV2/state.json"
export DEVICE_UDID="$FIXTURE_UDID"
export HARNESS_ID="raven.atsam.full-braid.physical-gate.v1"
# shellcheck source=lib/ios_full_braid_protected_anchor_physical_gate_lib.sh
source "$LIB"
bad_json='{"ok":false,"phase":"B","run_id":"'"$FIXTURE_RUN"'","device_udid":"'"$FIXTURE_UDID"'","outcome":"SHOULD_NOT_WRITE","harness":"raven.atsam.full-braid.physical-gate.v1"}'
set +e
out2="$(write_state_from_result "$bad_json" 2>&1)"
rc2=$?
set -e
[[ "$rc2" -ne 0 ]] || die "ok=false write: expected failure"
echo "$out2" | grep -Fq 'result.ok is not true' \
  || die "ok=false write: missing refuse diagnostic; got: $out2"
after="$(sha256_file "$EV2/state.json")"
[[ "$before" == "$after" ]] || die "ok=false write: state.json mutated"
pass "ok=false refuses state/evidence write"

# False success JSON for wrong phase must also be rejected by order (not applied here),
# and write_state with ok=true for B against last_phase=C is a harness misuse —
# operator path never reaches write when order fails. Still refuse if ok true but
# we only test write gate here with a spoofed success that would corrupt digests:
spoof='{"ok":true,"phase":"B","run_id":"'"$FIXTURE_RUN"'","device_udid":"'"$FIXTURE_UDID"'","outcome":"RELAUNCH_MATCH_AND_APPEND_SEQ2","harness":"raven.atsam.full-braid.physical-gate.v1","seed_digest_sha256":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef","seq1_digest_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","seq2_digest_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","chain_digest_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","scope_id_hex":"232ad76f93775518cdb0660fcbcdd392d1ce54cc95e729b00a1a8990f7ea53bb","production_enabled":false,"release_hold":"FULL_BRAID_PROTECTED_ANCHOR_NOT_APPROVED"}'
# Order check alone is the guard; duplicate-seq2 is covered by Swift fail-fast + no emit.
# Confirm ORDER_CHECK_ONLY still blocks even if someone tries PHASE=B after C:
set +e
out3="$(
  ORDER_CHECK_ONLY=1 \
  DEVICE_UDID="$FIXTURE_UDID" \
  PHASE=B \
  EVIDENCE_DIR="$EV2" \
  bash "$GATE" 2>&1
)"
rc3=$?
set -e
[[ "$rc3" -ne 0 ]] || die "spoof path: order must still block PHASE=B"
after2="$(sha256_file "$EV2/state.json")"
[[ "$before" == "$after2" ]] || die "spoof path: state mutated without write_state"
pass "duplicate-seq2 path: order blocks before any evidence write"

# --- 3) completed phase not re-runnable ---
EV3="$TMP/no-rerun"
mkdir -p "$EV3"
write_phase_c_fixture "$EV3/state.json"
set +e
out4="$(
  ORDER_CHECK_ONLY=1 \
  DEVICE_UDID="$FIXTURE_UDID" \
  PHASE=C \
  EVIDENCE_DIR="$EV3" \
  bash "$GATE" 2>&1
)"
rc4=$?
set -e
[[ "$rc4" -ne 0 ]] || die "re-run C: expected failure"
echo "$out4" | grep -Fq 'already completed' \
  || die "re-run C: missing refuse diagnostic; got: $out4"
pass "Phase C already completed refuses re-run"

echo "PASS: physical gate host negatives" >&2
