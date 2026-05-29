#!/usr/bin/env bash
#
# RAVEN — Mac Catalyst → signed + notarized DMG build script
#
# Builds the RAVEN Mac Catalyst app, signs it with Developer ID Application
# (NOT Mac App Store), notarizes via Apple's notary service, staples the
# notarization ticket, and packages a distributable .dmg.
#
# Result: a .dmg the user can double-click → drag-to-Applications → run
# with full BLE-mesh capabilities (no App Sandbox restrictions).
#
# Prerequisites (one-time setup):
#   1. Apple Developer Program membership ($99/year) — already have it
#   2. Developer ID Application certificate installed in Keychain
#      Apple Developer site → Certificates → "+ Create" → Developer ID Application
#   3. App-specific password for notarization
#      appleid.apple.com → Sign-In and Security → App-Specific Passwords → Generate
#   4. Store credentials once with:
#        xcrun notarytool store-credentials "raven-notary" \
#            --apple-id <YOUR_APPLE_ID> \
#            --team-id 72QQ5Q324C \
#            --password <APP_SPECIFIC_PASSWORD>
#   5. (Optional) install create-dmg for a prettier installer:
#        brew install create-dmg
#
# Run:
#   ./scripts/build-mac-dmg.sh
#
# Output:
#   build/RAVEN-<VERSION>.dmg  (~80–120 MB)

set -euo pipefail

# ───────────────────────────────────────────────────────────────────────
# Configuration
# ───────────────────────────────────────────────────────────────────────

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_ROOT/RAVEN.xcodeproj"
SCHEME="RAVEN"
TARGET="RAVEN"
CATALYST_SDK="iphoneos"      # Catalyst still uses iphoneos SDK; destination flips to macos

# Read version from project.pbxproj so DMG name stays in sync with bumps.
VERSION=$(grep -m1 "MARKETING_VERSION = " "$PROJECT/project.pbxproj" | sed 's/[^0-9.]//g')
BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$PROJECT/project.pbxproj" | sed 's/[^0-9]//g')

# Where the built .app and .dmg land
BUILD_DIR="$PROJECT_ROOT/build/mac"
APP_PATH="$BUILD_DIR/Build/Products/Release-maccatalyst/$TARGET.app"
DMG_PATH="$PROJECT_ROOT/build/RAVEN-${VERSION}.dmg"
NOTARY_PROFILE="raven-notary"  # matches `notarytool store-credentials` keychain profile

# ───────────────────────────────────────────────────────────────────────
# Pretty logging helpers
# ───────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
hdr()  { printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n%s\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" "$1"; }
ok()   { printf "${GREEN}✅ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}⚠️  %s${NC}\n" "$1"; }
die()  { printf "${RED}❌ %s${NC}\n" "$1" >&2; exit 1; }

hdr "RAVEN Mac Build  ·  v${VERSION} build ${BUILD}"

# ───────────────────────────────────────────────────────────────────────
# 0. Sanity checks
# ───────────────────────────────────────────────────────────────────────
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode + xcode-select --install"
command -v xcrun >/dev/null      || die "xcrun not found"
[[ -d "$PROJECT" ]]              || die "Project not found at $PROJECT"

# ───────────────────────────────────────────────────────────────────────
# 0b. Auto-detect best available signing identity
# ───────────────────────────────────────────────────────────────────────
# Order of preference:
#   1. Developer ID Application       — for distribution outside MAS
#                                       (Gatekeeper accepts after notarization)
#   2. Apple Distribution             — for App Store submission
#   3. Apple Development              — for local development & testing on
#                                       this developer's own Macs (this is
#                                       what the user already has installed)
#   4. ad-hoc ("-")                   — last-resort, runs only here, no
#                                       Gatekeeper trust at all
#
# We pick whichever the user has and adjust downstream behavior accordingly:
# notarization is only attempted when path #1 is available.
ALL_IDS=$(security find-identity -p codesigning -v 2>/dev/null)
SIGN_IDENTITY=""
SIGN_TIER=""

# Helper to extract just the certificate's CN line for a tier match.
# `|| true` swallows the non-zero exit when grep finds no match, so
# `set -e` doesn't kill the whole script on a missing tier.
pick_id() {
    echo "$ALL_IDS" | grep -oE "\"$1[^\"]*\"" 2>/dev/null | head -1 | tr -d '"' || true
}

CANDIDATE=$(pick_id "Developer ID Application:")
if [[ -n "$CANDIDATE" ]]; then SIGN_IDENTITY="$CANDIDATE"; SIGN_TIER="developer-id"; fi

if [[ -z "$SIGN_IDENTITY" ]]; then
    CANDIDATE=$(pick_id "Apple Distribution:")
    if [[ -n "$CANDIDATE" ]]; then SIGN_IDENTITY="$CANDIDATE"; SIGN_TIER="apple-distribution"; fi
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
    CANDIDATE=$(pick_id "Apple Development:")
    if [[ -n "$CANDIDATE" ]]; then SIGN_IDENTITY="$CANDIDATE"; SIGN_TIER="apple-development"; fi
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"             # ad-hoc
    SIGN_TIER="ad-hoc"
fi

case "$SIGN_TIER" in
    developer-id)
        ok "Signing with Developer ID Application — supports distribution + notarization"
        ok "  → $SIGN_IDENTITY"
        ;;
    apple-distribution)
        warn "Signing with Apple Distribution. DMG will work for App Store, but"
        warn "Gatekeeper outside MAS will be unhappy. Notarization will be skipped."
        warn "  → $SIGN_IDENTITY"
        ;;
    apple-development)
        warn "Signing with Apple Development — works on YOUR Macs only."
        warn "Other users will get 'unidentified developer' on first open"
        warn "(they can right-click → Open to bypass once)."
        warn "Notarization skipped. To distribute publicly, generate"
        warn "'Developer ID Application' at developer.apple.com → Certificates."
        warn "  → $SIGN_IDENTITY"
        ;;
    ad-hoc)
        warn "No signing identity in keychain — falling back to ad-hoc signing."
        warn "DMG will run only on THIS Mac. Notarization skipped."
        ;;
esac

# Notarization is meaningful ONLY with Developer ID. Other tiers can't be
# notarized (Apple notary refuses) — skip cleanly.
if [[ "$SIGN_TIER" == "developer-id" ]]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        ok "Notary profile '$NOTARY_PROFILE' configured"
        SKIP_NOTARIZE=0
    else
        warn "Notary profile '$NOTARY_PROFILE' not configured."
        warn "Run once: xcrun notarytool store-credentials $NOTARY_PROFILE \\"
        warn "             --apple-id <your@email> --team-id 72QQ5Q324C --password <app-specific-pw>"
        warn "Continuing without notarization."
        SKIP_NOTARIZE=1
    fi
else
    SKIP_NOTARIZE=1
fi

# ───────────────────────────────────────────────────────────────────────
# 1. Clean previous build
# ───────────────────────────────────────────────────────────────────────
hdr "1/5  Clean"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ok "Cleaned $BUILD_DIR"

# ───────────────────────────────────────────────────────────────────────
# 2. Build for Mac Catalyst (Release)
# ───────────────────────────────────────────────────────────────────────
# Signing strategy:
#   - With Developer ID Application: manual signing + the Catalyst
#     entitlements (full features for distribution).
#   - With anything else: AUTOMATIC signing — Xcode picks a matching
#     provisioning profile + cert combination. Some entitlements that
#     require team-level approval (push, app groups, associated-domains)
#     may still work because the team membership grants them; ones that
#     don't will be silently dropped, which is FINE for a local preview.
hdr "2/5  Build (Mac Catalyst Release)"

if [[ "$SIGN_TIER" == "developer-id" ]]; then
    # Distribution build: full Catalyst entitlements + manual sign +
    # specific Developer ID identity. Notarization happens later.
    SIGNING_ARGS=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=$SIGN_IDENTITY"
        "DEVELOPMENT_TEAM=72QQ5Q324C"
        "CODE_SIGN_ENTITLEMENTS=$PROJECT_ROOT/RAVEN/RAVEN-Catalyst.entitlements"
        "PROVISIONING_PROFILE_SPECIFIER="
    )
else
    # ── Local / preview build (ad-hoc) ──
    #
    # Apple Development signing on Mac Catalyst requires the developer's
    # Mac to be registered with the Apple Developer portal. Most devs
    # haven't done that for their own machine, so auto-signing fails.
    #
    # Workaround: build with ad-hoc signing (`-` identity) and SKIP
    # entitlements at xcodebuild time — many of our Catalyst entitlements
    # (multicast, time-sensitive notifications, push) require team-
    # approved provisioning profiles which an ad-hoc build can't have.
    # We re-sign with the entitlements via `codesign --entitlements …`
    # after build, which does work for local execution.
    SIGNING_ARGS=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=-"             # ad-hoc — needs no cert/profile
        "CODE_SIGNING_REQUIRED=NO"
        "CODE_SIGNING_ALLOWED=NO"
        "PROVISIONING_PROFILE_SPECIFIER="
    )
    # Override SIGN_TIER so downstream uses the same code path as ad-hoc
    SIGN_TIER="ad-hoc"
fi

# `-allowProvisioningUpdates` lets Xcode generate / refresh provisioning
# profiles automatically using the credentials of the Apple ID signed
# into Xcode.
#
# We deliberately DON'T pass `SUPPORTS_MACCATALYST=YES` on the command
# line because that forces the setting on ALL targets in the project —
# including the WidgetExtension, which can't run on Mac Catalyst and
# fails the build on missing provisioning. The main app's pbxproj
# already has SUPPORTS_MACCATALYST=YES; the widget target defaults to
# NO so the build system correctly skips it for the Catalyst destination.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates \
    -skipPackagePluginValidation \
    "${SIGNING_ARGS[@]}" \
    GCC_PREPROCESSOR_DEFINITIONS='$(inherited) SQLITE_ENABLE_LOCKING_STYLE=0' \
    build 2>&1 \
    | (command -v xcbeautify >/dev/null && xcbeautify --quieter || cat)
# ↑ SQLITE_ENABLE_LOCKING_STYLE=0 disables proxy-locking (which uses
#   gethostuuid, unavailable on Mac Catalyst). Required to compile
#   SQLCipher's bundled sqlite3.c against the Catalyst SDK.

[[ -d "$APP_PATH" ]] || die "Build did not produce $APP_PATH — check the xcodebuild output above"
ok "Built: $APP_PATH"

# ───────────────────────────────────────────────────────────────────────
# 3. Re-sign — only needed when distributing (Developer ID) since automatic
#    signing already produced a valid signature for non-distribution tiers.
#    Hardened runtime + secure timestamp are notarization requirements;
#    we apply them only when the chosen tier supports notarization.
# ───────────────────────────────────────────────────────────────────────
hdr "3/5  Code-sign"
if [[ "$SIGN_TIER" == "developer-id" ]]; then
    codesign --force --deep --options runtime \
        --entitlements "$PROJECT_ROOT/RAVEN/RAVEN-Catalyst.entitlements" \
        --sign "$SIGN_IDENTITY" \
        --timestamp \
        "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3 || true
    ok "Re-signed with Developer ID + hardened runtime"
else
    # Ad-hoc: re-sign with entitlements so app-sandbox=false (and the
    # other no-provision-required entitlements) actually take effect.
    # Use a permissive entitlements file that strips the team-required
    # capabilities (multicast, push, time-sensitive notifications) so
    # the ad-hoc sign accepts it.
    # Pure ad-hoc — no restricted entitlements. AMFI would reject the
    # binary at launch ("ad-hoc signed with restricted entitlements") if
    # we tried to add `application-identifier` or `keychain-access-groups`,
    # because those require a real cert chain + provisioning profile.
    # Consequence: the system Keychain (data-protection) refuses every
    # SecItem operation. KeychainService and DatabaseService fall back to
    # a file-based store under ~/Library/Application Support/RAVEN/.
    # GoogleSignIn does NOT use our service — it goes through GTMAppAuth
    # which hard-codes the data-protection keychain — so Google sign-in
    # surfaces "keychain error" on Catalyst ad-hoc builds. The Mac shell
    # detects this at runtime and hides the Google button.
    PERMISSIVE_ENT="/tmp/raven-catalyst-adhoc.entitlements"
    cat > "$PERMISSIVE_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.bluetooth</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.device.microphone</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.location</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
PLIST
    codesign --force --deep \
        --entitlements "$PERMISSIVE_ENT" \
        --sign - \
        "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH" 2>&1 | tail -3 || true
    ok "Re-signed ad-hoc with permissive entitlements (BLE + network + mic + location)"
fi

# ───────────────────────────────────────────────────────────────────────
# 4. Build the DMG
# ───────────────────────────────────────────────────────────────────────
hdr "4/5  Package DMG"

# If create-dmg is installed, use it (fancier window with drag-to-Applications).
if command -v create-dmg >/dev/null; then
    create-dmg \
        --volname "RAVEN ${VERSION}" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "RAVEN.app" 175 200 \
        --hide-extension "RAVEN.app" \
        --app-drop-link 425 200 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_PATH" \
        || die "create-dmg failed"
else
    # Fallback: plain hdiutil DMG (no fancy layout, but works everywhere)
    warn "create-dmg not installed — using plain hdiutil. brew install create-dmg for a nicer installer."
    STAGE="$BUILD_DIR/dmg-staging"
    mkdir -p "$STAGE"
    cp -R "$APP_PATH" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG_PATH"
    hduitil_log=$(hdiutil create \
        -volname "RAVEN ${VERSION}" \
        -srcfolder "$STAGE" \
        -ov -format UDZO \
        "$DMG_PATH" 2>&1)
    rm -rf "$STAGE"
fi
ok "DMG created: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"

# Sign the DMG only if we have Developer ID. Apple Development / ad-hoc
# signing on a DMG is meaningless — Gatekeeper looks at the inner .app
# bundle's signature, not the DMG wrapper.
if [[ "$SIGN_TIER" == "developer-id" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
    ok "DMG signed with Developer ID"
else
    warn "Skipping DMG-level signing (only meaningful with Developer ID)"
fi

# ───────────────────────────────────────────────────────────────────────
# 5. Notarize + staple
# ───────────────────────────────────────────────────────────────────────
hdr "5/5  Notarize"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    warn "Skipped notarization (no profile). DMG will run on YOUR Mac (you signed it)"
    warn "but Gatekeeper will block it for everyone else."
    warn "To distribute publicly, set up notary credentials and re-run."
else
    echo "Submitting to Apple notary service (typically 1–10 minutes)…"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        || die "Notarization failed — check the log with: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    ok "Notarized"

    echo "Stapling ticket to DMG…"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    ok "Stapled — DMG runs on any Mac without warnings"
fi

# ───────────────────────────────────────────────────────────────────────
# Done
# ───────────────────────────────────────────────────────────────────────
hdr "🎉 Done"
echo "  📦 $DMG_PATH"
echo "  📐 $(du -h "$DMG_PATH" | cut -f1)"
echo "  🏷️  Version $VERSION (build $BUILD)"
echo ""
echo "  Distribute: upload $DMG_PATH to your CDN / website / GitHub release"
echo "  Verify:     spctl --assess --type open --context context:primary-signature -vv \"$DMG_PATH\""
