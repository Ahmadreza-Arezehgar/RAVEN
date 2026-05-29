# RAVEN macOS — Release & Distribution

This directory has two scripts that take the RAVEN-MacApp source and
produce signed, notarized, distributable artifacts. Each one is
gated on credentials you only need to set up once.

| Script | Output | Audience |
|---|---|---|
| `build-appstore.sh` | `RAVEN.pkg` | Mac App Store reviewers + customers |
| `build-website-dmg.sh` | `RAVEN-1.0.dmg` (notarized) | direct download from raven-messenger.com |

## Why two builds

Apple imposes very different rules on these channels:

|  | **Mac App Store** | **Developer ID + DMG** |
|---|---|---|
| Sandbox | Required | Optional (we keep it on for parity) |
| BLE peripheral background | **Restricted** | Works |
| Distribution cert | "Apple Distribution" | "Developer ID Application" |
| Reviewer | Apple App Review | None — direct download |
| Auto-update | App Store / Updater | Sparkle (TODO) or manual |
| Time to ship | days–weeks | minutes |

We ship to BOTH channels so:
- Casual users find us on the App Store (search, automatic updates).
- Power users who need 24/7 mesh-bridge reliability download the
  DMG from our website. The two builds differ only in entitlements
  and signing identity — they speak the same v2 mesh wire format and
  interoperate seamlessly.

## One-time setup

You'll need an active **Apple Developer Program** membership
(team **`72QQ5Q324C`** — the one that already ships the iOS RAVEN
build). Steps you do **once**, in order:

### 1. Register the macOS bundle id

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com) as the team agent.
2. Open `Certificates, Identifiers & Profiles` → `Identifiers` → `+`.
3. Pick `App IDs`, then `App` (not Services).
4. Description: "RAVEN macOS". Bundle ID: `app.raven.macos` (explicit).
5. Capabilities — tick:
   - Sign in with Apple
   - App Sandbox
   - (everything else stays off; we add nothing iOS-specific)
6. Save.

### 2. Create the Mac App Store distribution cert + profile

1. In Xcode → **Settings ▸ Accounts** → select team `72QQ5Q324C` →
   **Manage Certificates** → click `+` → pick:
   - **Apple Distribution** (replaces the old "Mac App Distribution")
   - **3rd Party Mac Developer Installer** (used to sign the .pkg)
2. Both auto-install in the keychain.
3. Back in App Store Connect → `Profiles` → `+` → **Mac App Store**.
4. App ID: `app.raven.macos`. Cert: the Apple Distribution one above.
5. Profile name: **`RAVEN-MacAppStore`** (must match the script).
6. Download the `.provisionprofile` and double-click to install.

Verify with:
```bash
security find-identity -p codesigning -v | grep -E "Apple Distribution|3rd Party Mac"
```

### 3. Create the Developer ID cert (for the DMG path)

1. Same Xcode flow → **Manage Certificates** → `+` → **Developer ID Application**.
2. (Optional but recommended for kext/dmg-stapling completeness:
   **Developer ID Installer** as well.)
3. Back up the private key — Apple won't let you re-issue this cert
   freely; lose the key and you have a 2-week revoke loop.

Verify with:
```bash
security find-identity -p codesigning -v | grep "Developer ID Application"
```

### 4. Store notary credentials

Notary tool needs an app-specific password OR an App Store Connect
API key to upload binaries to Apple for stapling.

**App-specific password (simpler):**

1. Open [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords → +.
2. Label: "RAVEN notary". Copy the generated password.
3. Run:
   ```bash
   xcrun notarytool store-credentials raven-notary \
       --apple-id "<your apple id>" \
       --team-id "72QQ5Q324C" \
       --password "<app-specific password>"
   ```
4. The credential is stored in the login keychain under the profile
   name `raven-notary` — that's the `--keychain-profile` the script
   passes to `notarytool submit`.

**App Store Connect API key (better for CI):**

1. App Store Connect → **Users and Access ▸ Keys** → `+`.
2. Role: Developer. Download the `.p8` key once.
3. Store via:
   ```bash
   xcrun notarytool store-credentials raven-notary \
       --key ~/.appstoreconnect/AuthKey_XXXX.p8 \
       --key-id "<key id>" \
       --issuer "<issuer id from the keys page>"
   ```

### 5. Install build helpers

```bash
brew install xcodegen create-dmg xcbeautify
```

## Run

```bash
cd /Users/ahmd/hybrid_messenger/RAVEN-MacApp

# App Store .pkg → upload via Transporter / altool
./scripts/build-appstore.sh

# Website DMG → upload to your CDN
./scripts/build-website-dmg.sh
```

Each script:

1. Re-generates the .xcodeproj from `project.yml` (xcodegen).
2. Verifies signing identity + provisioning profile / notary creds.
3. `xcodebuild archive` → produces a `.xcarchive`.
4. `xcodebuild -exportArchive` with the right `exportOptions.plist`
   (method = `app-store` or `developer-id`).
5. **App Store path**: produces a `.pkg` ready for Transporter.
6. **DMG path**: notarizes the `.app`, staples it, builds the DMG via
   `create-dmg`, notarizes the DMG, staples that too.

## Distribution checklist

Before pushing either build:

- [ ] Bump `CFBundleShortVersionString` in `RAVEN/Info.plist` AND `project.yml` if needed.
- [ ] Bump `CFBundleVersion` (the build number — must increase monotonically per upload).
- [ ] Tag the commit: `git tag mac-v1.0.x && git push --tags`.
- [ ] Run the relevant script.
- [ ] App Store path: open Transporter, drag `RAVEN.pkg`, click Deliver.
  Build appears in TestFlight within ~10 min, ready for testers /
  submit-for-review.
- [ ] DMG path: upload `RAVEN-X.Y.Z.dmg` to the CDN / website. Update
  the download link on raven-messenger.com. Publish the SHA-256 the
  script printed.

## Updating the running build

For your **own** Mac (the one you developed on):

```bash
cd /Users/ahmd/hybrid_messenger/RAVEN-MacApp
xcodebuild -project RAVEN.xcodeproj -scheme RAVEN -configuration Release \
    build CODE_SIGNING_ALLOWED=NO
cp -R ~/Library/Developer/Xcode/DerivedData/RAVEN-*/Build/Products/Release/RAVEN.app \
      /Applications/RAVEN.app
xattr -dr com.apple.quarantine /Applications/RAVEN.app
open /Applications/RAVEN.app
```

This is the "developer install" used in the live test plan
(`docs/MAC_LIVE_TEST_PLAN.md`); it bypasses Gatekeeper because we
copied locally instead of downloading.
