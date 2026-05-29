#!/usr/bin/env bash
# build-website-dmg.sh — produce a notarized DMG for direct download
# from raven-messenger.com (or wherever).
#
# Why this exists alongside the App Store build:
#   • App Store sandbox blocks BLE peripheral background mode, which
#     the v1 mesh code path ideally wants.
#   • A "Developer ID + DMG" build can keep BLE peripheral working in
#     the background and ships outside Apple review.
#   • The two builds are SIBLING distributions — same code, different
#     entitlements + signing identity.
#
# Prerequisites (one-time setup on this Mac):
#   1. An active Apple Developer Program membership.
#   2. A "Developer ID Application" certificate installed in keychain:
#        • Generate via Xcode → Settings ▸ Accounts ▸ Manage Certificates
#          → "+ Developer ID Application".
#   3. Notary credentials stored in keychain via:
#        xcrun notarytool store-credentials raven-notary \
#          --apple-id "<your apple id>" \
#          --team-id "72QQ5Q324C" \
#          --password "<app-specific password from appleid.apple.com>"
#      (Or use an App Store Connect API key — `--key`, `--key-id`, `--issuer`.)
#   4. `create-dmg` installed: `brew install create-dmg`.
#
# Run:
#   ./scripts/build-website-dmg.sh
#
# Output:
#   build/website/RAVEN-1.0.dmg — notarized + stapled, ready for upload.

set -euo pipefail

cd "$(dirname "$0")/.."

# ── Config ───────────────────────────────────────────────────────────
TEAM_ID="72QQ5Q324C"
SIGN_IDENTITY="Developer ID Application: ASH Robotic Industry ($TEAM_ID)"
NOTARY_PROFILE="raven-notary"      # name passed to `notarytool store-credentials`
APP_NAME="RAVEN"
SCHEME="RAVEN"
BUILD_DIR="build/website"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_PATH=""    # set after we read the version out of Info.plist

# ── Pre-flight ────────────────────────────────────────────────────────
which xcodegen >/dev/null 2>&1 || { echo "✗ brew install xcodegen"; exit 1; }
which create-dmg >/dev/null 2>&1 || { echo "✗ brew install create-dmg"; exit 1; }
xcodegen generate

if ! security find-identity -p codesigning -v | grep -q "$SIGN_IDENTITY"; then
    echo "✗ signing identity '$SIGN_IDENTITY' not in keychain"
    echo "  Open Xcode → Settings ▸ Accounts ▸ Manage Certificates → +Developer ID Application"
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "✗ notary credentials not stored under profile '$NOTARY_PROFILE'"
    echo "  Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID --password <app-specific-pw>"
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Archive ──────────────────────────────────────────────────────────
echo "▶ Archiving for Developer ID distribution"
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    | xcbeautify || true

[ -d "$ARCHIVE_PATH" ] || { echo "✗ archive failed"; exit 1; }

# ── Export ───────────────────────────────────────────────────────────
echo "▶ Exporting for Developer ID distribution"
cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
    | xcbeautify || true

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "✗ export failed — no $APP_PATH"; exit 1; }

# ── Read version from Info.plist for the DMG filename ────────────────
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

# ── Notarize the .app ────────────────────────────────────────────────
echo "▶ Notarizing $APP_PATH"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "▶ Stapling notarization ticket onto .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# ── Build DMG ────────────────────────────────────────────────────────
echo "▶ Building DMG"
create-dmg \
    --volname "$APP_NAME" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "$APP_NAME.app" 140 200 \
    --app-drop-link 400 200 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

# ── Notarize the DMG too ─────────────────────────────────────────────
# The .app inside is already notarized + stapled, but Gatekeeper on
# fresh download checks the DMG container too.
echo "▶ Notarizing $DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo ""
echo "✓ DMG ready: $DMG_PATH"
echo ""
echo "Verify by:"
echo "  spctl --assess --type open --context context:primary-signature -vv \"$DMG_PATH\""
echo "  → should print 'accepted' + 'source=Notarized Developer ID'"
echo ""
echo "Upload steps:"
echo "  1. Upload $DMG_PATH to your CDN / website."
echo "  2. Update raven-messenger.com download link to the new file."
echo "  3. SHA-256 of the DMG: $(shasum -a 256 "$DMG_PATH" 2>/dev/null | cut -d' ' -f1)"
