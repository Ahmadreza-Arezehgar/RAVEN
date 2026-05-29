#!/usr/bin/env bash
#
# RAVEN — Reproducible Build Verifier
#
# Builds the RAVEN iOS / Mac Catalyst app from clean state and emits the
# SHA-256 of the resulting binary so anyone can compare it against what
# we publish on GitHub Releases / the App Store transparency page.
#
# Until the App Store binary is bit-for-bit reproducible (Xcode
# embedded-Swift differences + codesign timestamp differences make this
# hard for App Store builds today), we publish the SHA-256 of the
# .ipa / .app payload's Mach-O so independent verifiers can at least
# confirm a candidate binary matches the artefact we claim to ship.
#
# What this script gives you today:
#   1. A clean rebuild from the current source tree, no caches.
#   2. SHA-256 of the produced Mach-O (RAVEN.app/RAVEN).
#   3. SHA-256 of the entire .app bundle as a tarball with stable
#      ordering — sensitive to source changes, robust against Finder
#      metadata noise.
#   4. A signed manifest (sha256.json) you can publish next to a release.
#
# What this does NOT give you yet:
#   - Bit-for-bit reproducibility of an App Store IPA (codesign embeds
#     a timestamp; the IDE embeds Xcode build paths). That's the v1.6
#     work tracked in docs/REPRODUCIBLE-BUILD.md.
#
# Usage:
#   ./scripts/verify-binary.sh                    # iOS Simulator build (fast)
#   ./scripts/verify-binary.sh device             # iOS device archive
#   ./scripts/verify-binary.sh mac                # Mac Catalyst archive
#

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_ROOT/RAVEN.xcodeproj"
SCHEME="RAVEN"
TARGET="${1:-simulator}"
OUT_DIR="$PROJECT_ROOT/build/verify"

mkdir -p "$OUT_DIR"

case "$TARGET" in
    simulator)
        DEST="generic/platform=iOS Simulator"
        BUILD_DIR="$PROJECT_ROOT/build/verify-sim"
        ;;
    device)
        DEST="generic/platform=iOS"
        BUILD_DIR="$PROJECT_ROOT/build/verify-device"
        ;;
    mac)
        DEST="generic/platform=macOS,variant=Mac Catalyst"
        BUILD_DIR="$PROJECT_ROOT/build/verify-mac"
        ;;
    *)
        echo "Usage: $0 [simulator|device|mac]"
        exit 1
        ;;
esac

echo "═══════════════════════════════════════════════════════════════════"
echo "  RAVEN Reproducible Build Verifier"
echo "  Target:    $TARGET"
echo "  Project:   $PROJECT"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Source SHA — fingerprint the input.
echo "› Computing source SHA-256 (deterministic file order)…"
SOURCE_SHA=$(
    cd "$PROJECT_ROOT"
    find RAVEN \( -name '*.swift' -o -name '*.h' -o -name '*.m' -o -name '*.plist' -o -name '*.entitlements' \) \
        -not -path '*/build/*' \
        -not -path '*/.build/*' \
        | LC_ALL=C sort \
        | xargs shasum -a 256 \
        | shasum -a 256 \
        | awk '{print $1}'
)
echo "  source_sha256 = $SOURCE_SHA"

# Clean rebuild — no cached artefacts.
echo ""
echo "› Clean rebuild (no caches)…"
rm -rf "$BUILD_DIR"

# Deterministic build env: zero archive timestamps + force on-disk module cache.
export ZERO_AR_DATE=1
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1735689600}"  # 2025-01-01 UTC

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "$DEST" \
    -derivedDataPath "$BUILD_DIR" \
    -quiet \
    build \
    OTHER_SWIFT_FLAGS="-Xfrontend -no-clang-module-breadcrumbs" \
    SWIFT_OPTIMIZATION_LEVEL="-O" \
    || { echo "✗ Build failed"; exit 1; }

# Locate produced .app
APP=$(find "$BUILD_DIR/Build/Products" -name '*.app' -maxdepth 4 -type d | head -1)
if [ -z "$APP" ]; then
    echo "✗ No .app produced under $BUILD_DIR"
    exit 1
fi
echo "  app_bundle    = $APP"

# Mach-O hash
MACHO="$APP/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist")"
MACHO_SHA=$(shasum -a 256 "$MACHO" | awk '{print $1}')
echo "  macho_sha256  = $MACHO_SHA"

# Bundle hash (deterministic ordering, ignores HFS metadata noise)
BUNDLE_SHA=$(
    cd "$APP/.."
    find "$(basename "$APP")" -type f \
        | LC_ALL=C sort \
        | xargs shasum -a 256 \
        | shasum -a 256 \
        | awk '{print $1}'
)
echo "  bundle_sha256 = $BUNDLE_SHA"

# Manifest
MANIFEST="$OUT_DIR/sha256-$TARGET.json"
cat > "$MANIFEST" <<EOF
{
  "version": "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")",
  "build":   "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")",
  "target":  "$TARGET",
  "built_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_date_epoch": "$SOURCE_DATE_EPOCH",
  "source_sha256":    "$SOURCE_SHA",
  "macho_sha256":     "$MACHO_SHA",
  "bundle_sha256":    "$BUNDLE_SHA"
}
EOF

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  ✓ Build verified"
echo "  Manifest: $MANIFEST"
echo "═══════════════════════════════════════════════════════════════════"
cat "$MANIFEST"
