#!/usr/bin/env bash
# build-appstore.sh — produce a Mac App Store-ready .pkg.
#
# Prerequisites (one-time setup on this Mac):
#   1. An active Apple Developer Program membership.
#   2. The paid team that ships the iOS RAVEN build (`72QQ5Q324C`)
#      added to Xcode under Settings ▸ Accounts.
#   3. The bundle id `app.raven.macos` registered against that team in
#      App Store Connect (with App Sandbox capability).
#   4. Two distribution certificates installed locally:
#        • "Apple Distribution: <Team> (72QQ5Q324C)"
#        • "3rd Party Mac Developer Installer: <Team> (72QQ5Q324C)"
#      Generate via Xcode → Settings ▸ Accounts ▸ Manage Certificates.
#   5. A Mac App Store provisioning profile downloaded:
#        • Type: Mac App Store
#        • Bundle id: app.raven.macos
#        • App ID configured with the Sandbox + entitlements this app
#          uses (com.apple.security.app-sandbox, network.client/server,
#          device.bluetooth, etc.).
#      Saved as `~/Library/MobileDevice/Provisioning Profiles/<uuid>.provisionprofile`.
#
# Run:
#   ./scripts/build-appstore.sh
#
# Output:
#   build/appstore/RAVEN.pkg — ready to upload via Transporter or
#                              `xcrun altool --upload-app`.

set -euo pipefail

cd "$(dirname "$0")/.."  # repo root for the Mac project

# ── Config — edit these once your Apple Developer account is set up ──
TEAM_ID="72QQ5Q324C"
SIGN_IDENTITY="Apple Distribution: ASH Robotic Industry ($TEAM_ID)"
INSTALLER_IDENTITY="3rd Party Mac Developer Installer: ASH Robotic Industry ($TEAM_ID)"
PROVISIONING_PROFILE_NAME="RAVEN-MacAppStore"   # downloaded profile name
APP_NAME="RAVEN"
SCHEME="RAVEN"
BUILD_DIR="build/appstore"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# ── Pre-flight ────────────────────────────────────────────────────────
echo "▶ Pre-flight: re-generating Xcode project from project.yml"
which xcodegen >/dev/null 2>&1 || { echo "✗ install xcodegen first: brew install xcodegen"; exit 1; }
xcodegen generate

echo "▶ Verifying signing identity"
if ! security find-identity -p codesigning -v | grep -q "$SIGN_IDENTITY"; then
    echo "✗ signing identity '$SIGN_IDENTITY' not in keychain"
    echo "  Open Xcode → Settings ▸ Accounts ▸ Manage Certificates → +Apple Distribution"
    exit 1
fi

echo "▶ Cleaning previous build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Archive ──────────────────────────────────────────────────────────
echo "▶ Archiving for Mac App Store"
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER="$PROVISIONING_PROFILE_NAME" \
    | xcbeautify || true

[ -d "$ARCHIVE_PATH" ] || { echo "✗ archive failed"; exit 1; }

# ── Export ───────────────────────────────────────────────────────────
echo "▶ Exporting for App Store distribution"
cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store</string>
    <key>destination</key><string>export</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
    <key>installerSigningCertificate</key><string>$INSTALLER_IDENTITY</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>app.raven.macos</key>
        <string>$PROVISIONING_PROFILE_NAME</string>
    </dict>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
    | xcbeautify || true

PKG_PATH="$EXPORT_PATH/$APP_NAME.pkg"
[ -f "$PKG_PATH" ] || { echo "✗ export failed"; exit 1; }

echo ""
echo "✓ App Store package ready: $PKG_PATH"
echo ""
echo "Next steps:"
echo "  1. Open Transporter.app, drag $PKG_PATH in, click Deliver."
echo "     OR run: xcrun altool --upload-app -f \"$PKG_PATH\" -t macos --apiKey <key> --apiIssuer <issuer>"
echo "  2. In App Store Connect, the build appears under TestFlight → macOS within ~10 min."
echo "  3. Submit for review when ready."
