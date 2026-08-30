# Signing & notarization checklist (operator)

Software in this repo builds **review-only unsigned** layouts via
`node/scripts/release/build_unsigned.sh`. Every layout/artifact must retain the
generated `THIRD_PARTY_LICENSES_AND_NOTICES.txt`; generation is pinned to
`cargo-about 0.9.1` and is a hard packaging gate. The following signing steps
require **your** certificates and portal access. Agents cannot complete them.

---

## macOS — Developer ID + notarization

**Stop:** signing/notarization does not currently authorize distribution. First
clear the separate-executable Keychain handoff gate: on a physical Mac, the
final signed `raven` must create/load the identity and the final signed
`raven-node` launchd job must read the same public identity across restart with
no UI prompt, hang, or second identity. The default installer/archive refusals
must remain in place until that evidence is reviewed.

1. Enroll in [Apple Developer Program](https://developer.apple.com).
2. Create **Developer ID Application** certificate in Xcode / Certificates portal.
3. Import cert + private key into the signing Mac’s Keychain.
4. Build release binaries (or unpack unsigned tarball from `build_unsigned.sh`).
5. Sign:

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <YOUR NAME> (<TEAMID>)" \
  dist/.../bin/raven dist/.../bin/ash \
  dist/.../bin/raven-node dist/.../bin/raven-swarm
codesign --verify --verbose=2 dist/.../bin/raven
```

6. Zip/app-bundle as required by `notarytool`.
7. Submit:

```bash
xcrun notarytool submit <archive.zip> \
  --apple-id "<apple-id>" --team-id "<TEAMID>" --password "<app-specific-password>" \
  --wait
xcrun stapler staple <artifact>
```

8. Gatekeeper check: download on a clean Mac; open without right-click bypass.
9. Optional: Developer ID Installer + productbuild for `.pkg`.
10. Confirm `THIRD_PARTY_LICENSES_AND_NOTICES.txt` remains beside the signed
    binaries and is included in the final package manifest.

**Blocked without:** Apple ID with paid membership, certs, app-specific password / API key.

---

## Windows — Authenticode / MSI

**Stop:** the steps below are future-only until native Windows validation is
reviewed. Two independent profiles on a physical Windows host must complete
PairInit, an indexed message, and an authenticated ACK through the named-pipe
and LAN-direct paths. Authenticode does not clear that transport gate; do not
present a signed MSI/MSIX as a complete release before it passes.

1. Obtain Authenticode code-signing certificate (EV recommended for SmartScreen reputation).
2. Import into certificate store or use USB token.
3. Sign:

```powershell
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a ash.exe
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a raven.exe
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /a raven-node.exe
signtool verify /pa raven.exe
```

4. Build MSI/MSIX with WiX / Advanced Installer / your pipeline (not shipped here).
5. Sign the installer package similarly.
6. Optional: Microsoft Store submission (separate Partner Center account).
7. Retain `THIRD_PARTY_LICENSES_AND_NOTICES.txt` in the signed package and
   regenerate the checksum/provenance manifest after signing.

**Blocked without:** org signing cert, timestamp URL access, installer project.

---

## Linux packaging (optional)

**Stop:** Linux distribution is held at the R1 protected identity-store gate.
Fresh Release identity creation must pass the approved add-only/no-prompt
Secret Service integration and native continuity/error tests first. The current
override creates a review-only archive; it must not be repackaged, signed, or
published as deb/rpm. The steps below apply only after that hold is removed.

1. Build with `build_unsigned.sh` on the target distro.
2. Package deb/rpm with distro tooling; sign with your GPG key for apt/yum repos.
3. Publish to your repository — **do not** claim Raven-operated mandatory relays.

---

## After signing

- Recompute SHA256 of **signed** artifacts (they differ from unsigned sums).
- Attach signed hashes to the GitHub Release (when you choose to publish).
- Keep notarization / signtool logs offline for auditors.
