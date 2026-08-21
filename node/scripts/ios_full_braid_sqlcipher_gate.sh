#!/usr/bin/env bash
# Task 0A.3 — Apple SQLCipher.swift 4.17.0 package / linkage gate.
#
# Verifies SPM pin, archive checksum, required XCFramework slices, target
# ownership of SQLITE_HAS_CODEC, SQLCipher ios-only platform filter, and that
# Catalyst compilation of the durable probe fails with the exact hold text.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="$ROOT/ios-native/RAVEN"
PBXPROJ="$IOS/RAVEN.xcodeproj/project.pbxproj"
RESOLVED="$IOS/RAVEN.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PROFILE_SWIFT="$IOS/RAVEN/Core/Security/ATSAM/Durable/ATSAMFullBraidSQLCipherProfileV1.swift"

EXPECTED_COMMIT="205df55271aa1ba512a9bfe3fd1813bc9ac52a19"
EXPECTED_ARCHIVE_SHA="dd5a650346c1ba9933d6ba179f8844e03e4a075b3dd3a892796149864cd9ae57"
EXPECTED_URL="https://github.com/sqlcipher/SQLCipher.swift.git"
ARCHIVE_URL="https://github.com/sqlcipher/SQLCipher.swift/releases/download/4.17.0/SQLCipher.xcframework.zip"
CATALYST_HOLD="FULL_BRAID_SQLCIPHER_CATALYST_HOLD"

die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*" >&2; }

[[ -f "$PBXPROJ" ]] || die "missing $PBXPROJ"
[[ -f "$RESOLVED" ]] || die "missing $RESOLVED"
[[ -f "$PROFILE_SWIFT" ]] || die "missing $PROFILE_SWIFT"

grep -F 'stoneburner/SQLCipher' "$PBXPROJ" >/dev/null && die "stoneburner still referenced in pbxproj"
grep -F 'stoneburner/SQLCipher' "$RESOLVED" >/dev/null && die "stoneburner still referenced in Package.resolved"
grep -F "$EXPECTED_URL" "$PBXPROJ" >/dev/null || die "official SQLCipher.swift URL missing from pbxproj"
grep -F "$EXPECTED_COMMIT" "$RESOLVED" >/dev/null || die "Package.resolved missing exact commit $EXPECTED_COMMIT"
grep -E '"version"[[:space:]]*:[[:space:]]*"4\.17\.0"' "$RESOLVED" >/dev/null \
  || die "Package.resolved missing version 4.17.0"
pass "SPM pin (no stoneburner; official 4.17.0 / $EXPECTED_COMMIT)"

# SQLCipher must be ios-only (removed from Catalyst / macOS).
grep -F 'SQLCipher in Frameworks' "$PBXPROJ" | grep -F 'platformFilters = (ios, );' >/dev/null \
  || die "SQLCipher PBXBuildFile missing platformFilters = (ios, )"
pass "SQLCipher linked with ios-only platformFilters"

# Exact compile-time hold must exist in source (not merely a runtime throw).
grep -F "#error(\"$CATALYST_HOLD\")" "$PROFILE_SWIFT" >/dev/null \
  || die "missing compile-time #error(\"$CATALYST_HOLD\")"
pass "compile-time Catalyst #error present"

# Per-target SQLITE_HAS_CODEC ownership (main+tests only; sdk-conditioned).
# Rejects unconditioned/global GCC/OTHER_CFLAGS/SWIFT leaks that would hit Catalyst.
python3 - "$PBXPROJ" <<'PY' || die "SQLITE_HAS_CODEC target ownership failed"
import pathlib, re, sys

ALLOWED_TARGETS = {"RAVEN", "RAVENTests"}
FORBIDDEN_TARGETS = {
    "RavenShareExtension",
    "RAVENNotificationService",
    "RavenWidgetsExtension",
    "RAVEN-Watch",
}
# Only these exact sdk-conditioned keys may carry SQLITE_HAS_CODEC on allowed targets.
ALLOWED_CODEC_KEYS = {
    "GCC_PREPROCESSOR_DEFINITIONS[sdk=iphoneos*]",
    "GCC_PREPROCESSOR_DEFINITIONS[sdk=iphonesimulator*]",
    "OTHER_CFLAGS[sdk=iphoneos*]",
    "OTHER_CFLAGS[sdk=iphonesimulator*]",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator*]",
}
REQUIRED_CODEC_KEYS = {
    "GCC_PREPROCESSOR_DEFINITIONS[sdk=iphoneos*]",
    "GCC_PREPROCESSOR_DEFINITIONS[sdk=iphonesimulator*]",
}


def parse_target_configs(pbx: str):
    list_to_configs = {}
    for m in re.finditer(
        r'(?P<list>[A-F0-9]+) /\* Build configuration list for PBXNativeTarget "(?P<name>[^"]+)" \*/ = \{\s*'
        r'isa = XCConfigurationList;\s*buildConfigurations = \(\s*(?P<body>.*?)\s*\);',
        pbx,
        flags=re.S,
    ):
        ids = re.findall(r'([A-F0-9]+) /\*', m.group("body"))
        list_to_configs[m.group("list")] = (m.group("name"), ids)

    configs = {}
    for m in re.finditer(
        r'(?P<id>[A-F0-9]+) /\* (?P<cfg>Debug|Release) \*/ = \{\s*isa = XCBuildConfiguration;\s*'
        r'buildSettings = \{(?P<body>.*?)\};\s*name = (?P=cfg);',
        pbx,
        flags=re.S,
    ):
        configs[m.group("id")] = (m.group("cfg"), m.group("body"))
    return list_to_configs, configs


def parse_project_configs(pbx: str):
    """Return [(project_name, cfg_name, settings_body), ...] for PBXProject lists."""
    out = []
    configs = {}
    for m in re.finditer(
        r'(?P<id>[A-F0-9]+) /\* (?P<cfg>Debug|Release) \*/ = \{\s*isa = XCBuildConfiguration;\s*'
        r'buildSettings = \{(?P<body>.*?)\};\s*name = (?P=cfg);',
        pbx,
        flags=re.S,
    ):
        configs[m.group("id")] = (m.group("cfg"), m.group("body"))

    for m in re.finditer(
        r'(?P<list>[A-F0-9]+) /\* Build configuration list for PBXProject "(?P<name>[^"]+)" \*/ = \{\s*'
        r'isa = XCConfigurationList;\s*buildConfigurations = \(\s*(?P<body>.*?)\s*\);',
        pbx,
        flags=re.S,
    ):
        for cid in re.findall(r'([A-F0-9]+) /\*', m.group("body")):
            if cid not in configs:
                continue
            cfg_name, body = configs[cid]
            out.append((m.group("name"), cfg_name, cid, body))
    return out


def setting_entries(settings_body: str):
    """Yield (key, value_text) for each top-level build setting assignment."""
    entries = []
    i = 0
    body = settings_body
    n = len(body)
    while i < n:
        while i < n and body[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        # Quoted keys may contain '=' (e.g. "GCC_...[sdk=iphoneos*]").
        # Unquoted keys may include sdk condition brackets without '=' inside.
        m = re.match(
            r'("[^"]+"|[A-Za-z0-9_]+(?:\[[^\]=\n]+\])*)\s*=\s*',
            body[i:],
        )
        if not m:
            nl = body.find("\n", i)
            i = n if nl < 0 else nl + 1
            continue
        key = m.group(1).strip().strip('"')
        i += m.end()
        if i < n and body[i] == "(":
            depth = 0
            j = i
            while j < n:
                if body[j] == "(":
                    depth += 1
                elif body[j] == ")":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            value = body[i:j]
            while j < n and body[j] in " \t":
                j += 1
            if j < n and body[j] == ";":
                j += 1
            entries.append((key, value))
            i = j
        else:
            j = body.find(";", i)
            if j < 0:
                value = body[i:]
                i = n
            else:
                value = body[i:j]
                i = j + 1
            entries.append((key, value))
    return entries


def codec_keys_in_settings(settings_body: str):
    """Return list of setting keys whose value mentions SQLITE_HAS_CODEC."""
    out = []
    for key, value in setting_entries(settings_body):
        if "SQLITE_HAS_CODEC" in value or "SQLITE_HAS_CODEC" in key:
            out.append(key)
    return out


def validate_ownership(pbx: str) -> None:
    # Project-level settings are inherited via $(inherited) — never allow the macro here.
    for pname, cfg_name, _cid, body in parse_project_configs(pbx):
        keys = codec_keys_in_settings(body)
        if keys:
            raise SystemExit(
                f"PBXProject/{pname}/{cfg_name}: SQLITE_HAS_CODEC forbidden at project level "
                f"(would inherit into Catalyst); found keys={keys}"
            )

    list_to_configs, configs = parse_target_configs(pbx)
    seen_allowed = set()
    for _list_id, (tname, cfg_ids) in list_to_configs.items():
        for cid in cfg_ids:
            if cid not in configs:
                continue
            cfg_name, body = configs[cid]
            keys = codec_keys_in_settings(body)
            if tname in ALLOWED_TARGETS:
                present = set(keys)
                if not REQUIRED_CODEC_KEYS.issubset(present):
                    raise SystemExit(
                        f"{tname}/{cfg_name}: missing required iphone* SQLITE_HAS_CODEC keys; "
                        f"have={sorted(present)}"
                    )
                illegal = [k for k in keys if k not in ALLOWED_CODEC_KEYS]
                if illegal:
                    raise SystemExit(
                        f"{tname}/{cfg_name}: SQLITE_HAS_CODEC only allowed under "
                        f"iphoneos*/iphonesimulator* keys; illegal={illegal}"
                    )
                seen_allowed.add(tname)
            elif tname in FORBIDDEN_TARGETS:
                if keys:
                    raise SystemExit(
                        f"{tname}/{cfg_name}: SQLITE_HAS_CODEC must be absent; found keys={keys}"
                    )
            elif keys:
                raise SystemExit(
                    f"{tname}/{cfg_name}: unexpected SQLITE_HAS_CODEC keys={keys}"
                )

    missing = ALLOWED_TARGETS - seen_allowed
    if missing:
        raise SystemExit(f"allowed targets missing codec settings: {sorted(missing)}")


def _inject_after_build_settings(pbx: str, config_id: str, inject: str) -> str:
    marker = f"{config_id} /* Debug */"
    idx = pbx.find(marker)
    if idx < 0:
        marker = f"{config_id} /* Release */"
        idx = pbx.find(marker)
    if idx < 0:
        raise SystemExit(f"mutation setup: config {config_id} block missing")
    bs = pbx.find("buildSettings = {", idx)
    if bs < 0:
        raise SystemExit("mutation setup: buildSettings missing")
    insert_at = bs + len("buildSettings = {")
    return pbx[:insert_at] + inject + pbx[insert_at:]


def _leak_inject(form: str) -> str:
    if form.endswith("GCC") or form == "bare_GCC" or form == "project_bare_GCC":
        return (
            "\n\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n"
            "\t\t\t\t\t\"$(inherited)\",\n"
            "\t\t\t\t\t\"SQLITE_HAS_CODEC=1\",\n"
            "\t\t\t\t);\n"
        )
    if form.endswith("OTHER_CFLAGS") or form == "bare_OTHER_CFLAGS" or form == "project_bare_OTHER_CFLAGS":
        return (
            "\n\t\t\t\tOTHER_CFLAGS = (\n"
            "\t\t\t\t\t\"$(inherited)\",\n"
            "\t\t\t\t\t\"-DSQLITE_HAS_CODEC=1\",\n"
            "\t\t\t\t);\n"
        )
    if form.endswith("SWIFT") or form == "bare_SWIFT" or form == "project_bare_SWIFT":
        return (
            '\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "SQLITE_HAS_CODEC $(inherited)";\n'
        )
    raise SystemExit(f"unknown mutation form {form}")


def mutate_inject_global(pbx: str, form: str) -> str:
    """Inject an unconditioned SQLITE_HAS_CODEC setting into RAVEN Debug buildSettings."""
    list_to_configs, configs = parse_target_configs(pbx)
    raven_debug_id = None
    for _lid, (tname, cfg_ids) in list_to_configs.items():
        if tname != "RAVEN":
            continue
        for cid in cfg_ids:
            if cid in configs and configs[cid][0] == "Debug":
                raven_debug_id = cid
                break
    if not raven_debug_id:
        raise SystemExit("mutation setup: RAVEN Debug config not found")
    return _inject_after_build_settings(pbx, raven_debug_id, _leak_inject(form))


def mutate_inject_project_global(pbx: str, form: str) -> str:
    """Inject SQLITE_HAS_CODEC into PBXProject Debug — inherited by all targets."""
    projects = parse_project_configs(pbx)
    debug = next((p for p in projects if p[1] == "Debug"), None)
    if not debug:
        raise SystemExit("mutation setup: PBXProject Debug config not found")
    _pname, _cfg, cid, _body = debug
    return _inject_after_build_settings(pbx, cid, _leak_inject(form))


pbx_path = pathlib.Path(sys.argv[1])
pbx = pbx_path.read_text(encoding="utf-8", errors="replace")
validate_ownership(pbx)

# Target-level negative mutations.
for form in ("bare_GCC", "bare_OTHER_CFLAGS", "bare_SWIFT"):
    mutated = mutate_inject_global(pbx, form)
    try:
        validate_ownership(mutated)
    except SystemExit as exc:
        msg = str(exc)
        if "illegal=" not in msg:
            raise SystemExit(f"{form}: rejected but unexpected diagnostic: {msg}") from exc
        print(f"negative-ok {form}")
        continue
    raise SystemExit(f"{form}: GLOBAL_LEAK_ACCEPTED_BY_GATE")

# Project-level negative mutations (inherited via $(inherited)).
for form in ("project_bare_GCC", "project_bare_OTHER_CFLAGS", "project_bare_SWIFT"):
    mutated = mutate_inject_project_global(pbx, form)
    try:
        validate_ownership(mutated)
    except SystemExit as exc:
        msg = str(exc)
        if "PBXProject/" not in msg or "project level" not in msg:
            raise SystemExit(
                f"{form}: rejected but unexpected diagnostic: {msg}"
            ) from exc
        print(f"negative-ok {form}")
        continue
    raise SystemExit(f"{form}: PROJECT_GLOBAL_LEAK_ACCEPTED_BY_GATE")

print("ownership-ok")
PY
pass "SQLITE_HAS_CODEC owned by RAVEN + RAVENTests only (iphone sdks; no target/project global leak)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/raven-0a3-sqlcipher-XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

curl -fsSL -o "$WORKDIR/SQLCipher.xcframework.zip" "$ARCHIVE_URL"
GOT_SHA="$(shasum -a 256 "$WORKDIR/SQLCipher.xcframework.zip" | awk '{print $1}')"
[[ "$GOT_SHA" == "$EXPECTED_ARCHIVE_SHA" ]] || die "archive SHA mismatch got=$GOT_SHA expected=$EXPECTED_ARCHIVE_SHA"
pass "archive SHA-256"

unzip -q "$WORKDIR/SQLCipher.xcframework.zip" -d "$WORKDIR"
XCFW="$WORKDIR/SQLCipher.xcframework"
for slice in ios-arm64 ios-arm64_x86_64-simulator ios-arm64_x86_64-maccatalyst macos-arm64_x86_64; do
  [[ -d "$XCFW/$slice" ]] || die "missing XCFramework slice $slice"
done
pass "required XCFramework slices"

BIN="$XCFW/ios-arm64/SQLCipher.framework/SQLCipher"
[[ -f "$BIN" ]] || die "missing ios-arm64 binary"
# Avoid `grep -q` under pipefail: early close SIGPIPEs `strings` (exit 141).
strings "$BIN" | grep -F '4.17.0' >/dev/null || die "binary missing 4.17.0 string"
strings "$BIN" | grep -Fi 'commoncrypto' >/dev/null || die "binary missing commoncrypto provider string"
strings "$BIN" | grep -F 'TEMP_STORE=2' >/dev/null || die "binary missing TEMP_STORE=2 compile evidence"
if command -v otool >/dev/null; then
  if otool -L "$BIN" | grep -E 'libsqlite3\.dylib' >/dev/null; then
    die "SQLCipher framework dynamically links system libsqlite3"
  fi
  pass "no dynamic libsqlite3 in official framework"
fi

[[ -f "$IOS/RAVENTests/ATSAMFullBraidSQLCipherProfileV1Tests.swift" ]] \
  || die "missing ATSAMFullBraidSQLCipherProfileV1Tests.swift"
pass "lab probe sources present"

# Catalyst negative: compile-time hold with exact diagnostic (not RavenLibp2p).
command -v xcrun >/dev/null || die "xcrun required for Catalyst negative"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
set +e
CAT_OUT="$(
  xcrun swiftc -typecheck \
    -sdk "$MAC_SDK" \
    -target arm64-apple-ios17.0-macabi \
    "$PROFILE_SWIFT" 2>&1
)"
CAT_RC=$?
set -e
[[ "$CAT_RC" -ne 0 ]] || die "Catalyst typecheck unexpectedly succeeded"
echo "$CAT_OUT" | grep -F "$CATALYST_HOLD" >/dev/null \
  || die "Catalyst negative missing exact diagnostic $CATALYST_HOLD; got: $CAT_OUT"
pass "Catalyst negative ($CATALYST_HOLD)"

if [[ "${RAVEN_0A3_RUN_XCTEST:-0}" == "1" ]]; then
  command -v xcodebuild >/dev/null || die "xcodebuild required when RAVEN_0A3_RUN_XCTEST=1"
  DEST="${DEST:-}"
  if [[ -z "$DEST" ]]; then
    DEST="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone|RAVEN-Trust/{gsub(/ /,"",$2); if ($2 ~ /^[0-9A-F-]{36}$/) { print $2; exit }}')"
  fi
  [[ -n "$DEST" ]] || {
    echo "FULL_BRAID_IOS_SIMULATOR_UNAVAILABLE" >&2
    exit 2
  }
  cd "$IOS"
  xcodebuild test \
    -project RAVEN.xcodeproj \
    -scheme RAVEN \
    -destination "platform=iOS Simulator,id=$DEST" \
    -only-testing:RAVENTests/ATSAMFullBraidSQLCipherProfileV1Tests \
    | tee "$WORKDIR/xcodebuild.log"
  pass "XCTest ATSAMFullBraidSQLCipherProfileV1Tests"
else
  echo "INFO: XCTest skipped (set RAVEN_0A3_RUN_XCTEST=1 and DEST/simulator to run)" >&2
fi

echo "PASS: ios_full_braid_sqlcipher_gate" >&2
