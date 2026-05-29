//
//  DesktopLoginApprovalView.swift
//  RAVEN
//
//  Mobile side of the desktop QR-login flow. Triggered when the
//  in-app scanner reads a `desktop_login` payload (base64 JSON
//  emitted by the macOS / Web client's `QRCodeView`).
//
//  Flow
//  ────
//  1. We immediately POST `/api/auth/qr-login/scan` with an Ed25519
//     signature. That moves the server-side session pending → scanned
//     and tells the desktop "your code was seen". The response carries
//     the desktop's source IP + the session expiry so we can show the
//     user what they're approving (basic anti-phishing UX — Telegram
//     shows the same details).
//  2. The user reviews + taps Approve or Deny.
//  3. Approve → POST `/api/auth/qr-login/approve` (signed). The desktop
//     wakes up on its next poll and receives the access token. Deny
//     → POST `/api/auth/qr-login/deny` (no signature; the server
//     just records the rejection). Both close the sheet.
//
//  Server contract
//  ───────────────
//  • Scan signature payload: `v1|<sid>|<nonce>|<deviceFp>|<ts>`
//  • Approve signature payload: `<sid>|approved|<ts>`
//  • Both signatures are raw Ed25519 (64 bytes) base64-encoded.
//    Server verifies against `User.public_key`, which we upload via
//    `NetworkService.uploadIdentityKey` on first launch after login.
//

import SwiftUI
import UIKit
import CryptoKit

struct DesktopLoginPayload: Equatable, Identifiable {
    /// `Identifiable` for SwiftUI's `.sheet(item:)`. Session id is
    /// already a server-issued unique token.
    var id: String { sessionId }
    let sessionId: String
    let nonce: String
    let expiresAt: Date
    /// Optional BLE-fallback block. When present, the phone can
    /// approve this login over Bluetooth if the internet path fails.
    let ble: DesktopLoginBLEBlock?

    /// Decode the QR payload the desktop displayed. Two encodings
    /// supported for forward-compat:
    ///   • Base64-of-JSON (current macOS): `{"v":1,"type":"desktop_login","sid":"…","n":"…","exp":171…}`
    ///   • Direct JSON: same shape, no base64 wrapper.
    /// Returns nil for any other input (the scanner falls through to
    /// the friend-handler in that case).
    static func decode(from raw: String) -> DesktopLoginPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try direct JSON first.
        if let data = trimmed.data(using: .utf8),
           let payload = parseJSON(data) {
            return payload
        }

        // Try base64url and standard base64.
        let candidates = [
            trimmed
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
                .padding(toLength: ((trimmed.count + 3) / 4) * 4, withPad: "=", startingAt: 0),
            trimmed
        ]
        for c in candidates {
            if let data = Data(base64Encoded: c), let payload = parseJSON(data) {
                return payload
            }
        }
        return nil
    }

    private static func parseJSON(_ data: Data) -> DesktopLoginPayload? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (obj["type"] as? String) == "desktop_login" else { return nil }
        guard let sid = obj["sid"] as? String, !sid.isEmpty,
              let n = obj["n"] as? String, !n.isEmpty,
              let exp = obj["exp"] as? Int else { return nil }

        // Optional BLE block — if the desktop included its identity
        // pubkey + service UUID, we can fall back to a BLE-mediated
        // approval when the internet path fails. The optional
        // `agreement` field (Phase 2) is the X25519 pubkey we ECDH
        // against to encrypt the bridged JWT.
        var ble: DesktopLoginBLEBlock?
        if let bleObj = obj["ble"] as? [String: Any],
           let peer = bleObj["peer"] as? String, !peer.isEmpty,
           let svc = bleObj["svc"] as? String, !svc.isEmpty {
            let agreement = bleObj["agreement"] as? String
            ble = DesktopLoginBLEBlock(peer: peer, svc: svc, agreement: agreement)
        }

        return DesktopLoginPayload(
            sessionId: sid,
            nonce: n,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(exp)),
            ble: ble
        )
    }
}

@MainActor
struct DesktopLoginApprovalView: View {
    let payload: DesktopLoginPayload
    let onClose: () -> Void

    @State private var phase: Phase = .preparing
    @State private var requesterIp: String?
    @State private var serverExpiresAt: Date?
    @State private var errorMessage: String?

    enum Phase {
        case preparing            // signing + posting /scan
        case awaitingUser         // user reviews + decides
        case sending              // posting /approve or /deny
        case tryingBluetooth      // /scan failed → broadcasting BLE envelope
        case bluetoothSent        // envelope on the air; desktop will pick it up
        case approved
        case denied
        case failed
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Approve desktop login")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 14)

            content
                .frame(maxWidth: .infinity, minHeight: 220)
                .padding(.horizontal)

            if phase == .awaitingUser {
                actionButtons
                    .padding(.horizontal)
                    .padding(.bottom, 18)
            } else if phase == .approved || phase == .denied || phase == .failed || phase == .bluetoothSent {
                Button {
                    onClose()
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.bottom, 18)
            }
        }
        .background(Color(.systemBackground))
        .task {
            await scan()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing, .sending:
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.4)
                Text(phase == .preparing ? "Verifying request…" : "Sending response…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .awaitingUser:
            VStack(alignment: .leading, spacing: 14) {
                row(icon: "desktopcomputer",
                    title: "A new desktop wants to sign in to your account",
                    subtitle: "Only approve if you started this on your computer just now.")
                if let ip = requesterIp {
                    row(icon: "network", title: "From IP", subtitle: ip)
                }
                if let exp = serverExpiresAt ?? Optional(payload.expiresAt) {
                    row(icon: "clock", title: "Expires",
                        subtitle: relativeString(exp))
                }
            }

        case .approved:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                Text("Desktop signed in")
                    .font(.system(size: 16, weight: .semibold))
                Text("You can close this and continue on your computer.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .denied:
            VStack(spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                Text("Login denied")
                    .font(.system(size: 16, weight: .semibold))
                Text("The desktop will be told the request was rejected.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .tryingBluetooth:
            VStack(spacing: 14) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)
                ProgressView()
                Text("Couldn't reach the server — trying Bluetooth…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .bluetoothSent:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                Text("Sent over Bluetooth")
                    .font(.system(size: 16, weight: .semibold))
                Text("Look at your computer — it should now be signed in. Full server features will resume the next time both devices are online.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)
                Text("Couldn't process")
                    .font(.system(size: 16, weight: .semibold))
                if let msg = errorMessage {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await deny() }
            } label: {
                Text("Deny")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
            }
            .buttonStyle(.plain)

            Button {
                Task { await approve() }
            } label: {
                Text("Approve")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        }
    }

    private func row(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Network steps

    private func scan() async {
        // 🔴 Bug fix (2026-05-10): the server's `/qr-login/scan`
        // verifies our signature against `User.public_key`. If the
        // launch-time `uploadIdentityKey()` lost its race with
        // `AuthService.isAuthenticated` (it lives inside an `if
        // isAuthenticated` block that may run before login lands),
        // the server returns "User has no registered public key" and
        // the user sees a generic failure. Push the key on-demand
        // here as well — best-effort, idempotent (server returns
        // `unchanged` when the key already matches).
        if let pub = DeviceIdentityService.shared.publicKeyBase64 {
            NSLog("🔐 [QRLogin] Uploading identity key (len=\(pub.count))")
            do {
                let resp = try await NetworkService.shared.uploadIdentityKey(publicKeyBase64: pub)
                NSLog("🔐 [QRLogin] Identity key upload: \(resp.status)")
            } catch {
                NSLog("🔐 [QRLogin] Identity key upload FAILED: \(error.localizedDescription)")
            }
        } else {
            NSLog("🔐 [QRLogin] DeviceIdentityService.publicKeyBase64 is nil — can't upload")
        }

        let ts = Int(Date().timeIntervalSince1970)
        let deviceFp = DeviceIdentityService.shared.fingerprint ?? "unknown"
        let payloadString = "v1|\(payload.sessionId)|\(payload.nonce)|\(deviceFp)|\(ts)"

        guard let sigB64 = signString(payloadString) else {
            errorMessage = "Couldn't sign the scan request — identity key missing on this device."
            phase = .failed
            return
        }

        do {
            let resp = try await NetworkService.shared.qrLoginScan(
                QRScanRequest(
                    sessionId: payload.sessionId,
                    nonce: payload.nonce,
                    deviceFingerprint: deviceFp,
                    timestamp: ts,
                    signature: sigB64
                )
            )
            requesterIp = resp.requesterIp
            serverExpiresAt = resp.expiresAt
            phase = .awaitingUser
        } catch {
            // 🔵 Bluetooth fallback. If the QR included a `ble` block
            // (macOS published its identity pubkey + service UUID) AND
            // the failure looks like a transport problem (no connection,
            // timeout, hostname unreachable), try approving over BLE
            // instead of giving up. The user gets a single scan that
            // works in either environment — internet OR mesh.
            if payload.ble != nil, isNetworkError(error) {
                await tryBluetoothFallback()
                return
            }
            errorMessage = friendly(error)
            phase = .failed
        }
    }

    /// Pure transport-level errors → eligible for BLE fallback.
    /// Application errors (4xx / 5xx) → don't retry over BLE; the
    /// server already saw + rejected the scan.
    private func isNetworkError(_ error: Error) -> Bool {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Build, sign, broadcast the BLE login-approval envelope. The
    /// macOS side, while its QR sheet is open, listens on the same
    /// `BLEMeshEngine` channel for envelopes whose `sessionId`
    /// matches the one it advertised — and completes a *mesh-only*
    /// login locally. See `Core/Mesh/MeshLoginEnvelope.swift` for
    /// the wire format and signature contract.
    @MainActor
    private func tryBluetoothFallback() async {
        phase = .tryingBluetooth
        let ts = Int(Date().timeIntervalSince1970)
        guard let userId = AuthService.shared.currentUser?.id, !userId.isEmpty else {
            errorMessage = "Not signed in — cannot approve a desktop login."
            phase = .failed
            return
        }
        let username = AuthService.shared.currentUser?.username ?? ""

        let signedBytes = MeshLoginApprovalEnvelope.signedPayload(
            sessionId: payload.sessionId, userId: userId, timestamp: ts
        )
        guard let sig = DeviceIdentityService.shared.sign(signedBytes),
              let pub = DeviceIdentityService.shared.publicKeyBase64 else {
            errorMessage = "Couldn't sign the Bluetooth approval — identity key missing."
            phase = .failed
            return
        }

        let envelope = MeshLoginApprovalEnvelope(
            kind: "raven.login.approval.v1",
            sessionId: payload.sessionId,
            userId: userId,
            username: username,
            phonePublicKey: pub,
            timestamp: ts,
            signature: sig.base64EncodedString()
        )

        guard let bytes = try? JSONEncoder().encode(envelope) else {
            errorMessage = "Couldn't encode Bluetooth envelope."
            phase = .failed
            return
        }

        // Reuse the existing post-broadcast channel as the carrier.
        // The macOS receiver dispatches on `jsonDict["k"]` so it sees
        // our envelope alongside other mesh frames without needing a
        // dedicated GATT characteristic.
        await BLEMeshEngine.shared.broadcastPostData(bytes)

        phase = .bluetoothSent
    }

    private func approve() async {
        phase = .sending
        let ts = Int(Date().timeIntervalSince1970)
        let payloadString = "\(payload.sessionId)|approved|\(ts)"
        guard let sigB64 = signString(payloadString) else {
            errorMessage = "Couldn't sign the approval — identity key missing on this device."
            phase = .failed
            return
        }
        do {
            _ = try await NetworkService.shared.qrLoginApprove(
                QRApproveRequest(
                    sessionId: payload.sessionId,
                    timestamp: ts,
                    signature: sigB64,
                    desktopDeviceName: UIDevice.current.name + " (linked)",
                    desktopDeviceModel: nil,
                    desktopDeviceOs: nil
                )
            )
            phase = .approved

            // 🔵 Phase 2: phone-bridged JWT forward.
            //
            // The desktop normally collects its tokens by polling
            // `/api/auth/qr-login/poll/{sid}` itself. When the desktop
            // is offline (or can't reach the server through a corporate
            // proxy / captive portal), that poll never succeeds and the
            // user is stuck with a "scanned but never finished" QR.
            //
            // Best-effort fix: after our /approve returns, the phone —
            // which is by definition online — fetches the same token
            // via /poll, encrypts it under the desktop's X25519 pubkey
            // (carried in the QR's `ble.agreement` block), and
            // broadcasts a `MeshLoginTokenEnvelope` over BLE. The
            // desktop's BLE engine peeks the kind discriminator,
            // decrypts, and feeds the token into its existing
            // `completeQrLogin(...)` path — the user gets a real
            // server-grade session, no mesh-only limitation.
            //
            // If the desktop is online and grabbed the token via /poll
            // first, our envelope is harmless duplicate (same session).
            //
            // We don't surface bridge failures to the user — the
            // approval already succeeded; the worst case is a slower
            // desktop sign-in.
            if payload.ble?.agreement != nil {
                await bridgeTokenViaBLE()
            }
        } catch {
            errorMessage = friendly(error)
            phase = .failed
        }
    }

    /// Phase-2 worker: fetch the JWT from `/poll`, ECDH-encrypt to
    /// the desktop, broadcast over BLE. All errors swallowed +
    /// logged in DEBUG — bridging is a UX improvement, not the
    /// happy-path requirement.
    @MainActor
    private func bridgeTokenViaBLE() async {
        guard let ble = payload.ble,
              let agreementB64 = ble.agreement,
              let desktopAgreementRaw = Data(base64Encoded: agreementB64) else {
            return
        }

        // Step 1: pull tokens from server. We accept "approved" only
        // — `pending` / `scanned` mean our /approve is still in flight
        // server-side; in that rare case we just skip the bridge.
        let poll: QRPollResponse
        do {
            poll = try await NetworkService.shared.qrLoginPoll(
                sessionId: payload.sessionId,
                nonce: payload.nonce
            )
        } catch {
            #if DEBUG
            print("🔵 [LoginBridge] /poll for forward failed: \(error.localizedDescription)")
            #endif
            return
        }
        guard poll.status == "approved",
              let token = poll.token,
              let userId = poll.userId,
              let username = poll.username else {
            #if DEBUG
            print("🔵 [LoginBridge] /poll returned status=\(poll.status), no token to forward")
            #endif
            return
        }

        // Step 2: ECDH(eph_priv, desktop_agreement_pub) → HKDF → key.
        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephPub = ephPriv.publicKey.rawRepresentation
        let desktopPub: Curve25519.KeyAgreement.PublicKey
        do {
            desktopPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: desktopAgreementRaw)
        } catch {
            #if DEBUG
            print("🔵 [LoginBridge] desktop agreement key invalid: \(error)")
            #endif
            return
        }
        let symmetricKey: SymmetricKey
        do {
            let shared = try ephPriv.sharedSecretFromKeyAgreement(with: desktopPub)
            // 🔐 BUG FIX (2026-05-10): bind ephPub ‖ desktopAgreementPub
            // into the HKDF salt so the derived key is uniquely tied
            // to this (sender-eph, recipient) pair. Previously the
            // salt was empty — a transcript-binding gap that opened
            // the door to unknown-key-share / cross-session
            // confusion attacks. Same pattern as
            // SealedSenderEnvelope.seal at line 181-183.
            var salt = ephPriv.publicKey.rawRepresentation
            salt.append(desktopPub.rawRepresentation)
            symmetricKey = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("raven.login.token.v1".utf8),
                outputByteCount: 32
            )
        } catch {
            #if DEBUG
            print("🔵 [LoginBridge] ECDH failed: \(error)")
            #endif
            return
        }

        // Step 3: encrypt the JSON token payload.
        let plaintext = MeshLoginTokenPayload(
            token: token,
            refreshToken: poll.refreshToken,
            userId: userId,
            username: username
        )
        guard let plainBytes = try? JSONEncoder().encode(plaintext) else { return }
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        let r = SecRandomCopyBytes(kSecRandomDefault, 12, &nonceBytes)
        guard r == errSecSuccess else { return }
        let nonce = Data(nonceBytes)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(
                plainBytes,
                using: symmetricKey,
                nonce: try AES.GCM.Nonce(data: nonce)
            )
        } catch {
            #if DEBUG
            print("🔵 [LoginBridge] AES-GCM seal failed: \(error)")
            #endif
            return
        }
        // SealedBox stores ciphertext + 16-byte tag; concatenate so
        // the desktop can split deterministically (last 16 bytes = tag).
        let ct = sealed.ciphertext + sealed.tag

        let envelope = MeshLoginTokenEnvelope(
            kind: "raven.login.token.v1",
            sessionId: payload.sessionId,
            ephemeralPub: ephPub.base64EncodedString(),
            nonce: nonce.base64EncodedString(),
            ciphertext: ct.base64EncodedString(),
            timestamp: Int(Date().timeIntervalSince1970)
        )
        guard let bytes = try? JSONEncoder().encode(envelope) else { return }
        await BLEMeshEngine.shared.broadcastPostData(bytes)

        #if DEBUG
        print("🔵 [LoginBridge] forwarded JWT to desktop sid=\(payload.sessionId.prefix(8)) (\(bytes.count) B)")
        #endif
    }

    private func deny() async {
        phase = .sending
        do {
            _ = try await NetworkService.shared.qrLoginDeny(
                QRDenyRequest(sessionId: payload.sessionId)
            )
            phase = .denied
        } catch {
            errorMessage = friendly(error)
            phase = .failed
        }
    }

    // MARK: - Helpers

    private func signString(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let sig = DeviceIdentityService.shared.sign(data) else { return nil }
        return sig.base64EncodedString()
    }

    private func friendly(_ error: Error) -> String {
        let raw = (error as NSError).localizedDescription
        // Strip the long URL prefixes the URLSession errors include
        // so the bottom-of-screen line stays readable.
        return raw.split(separator: "\n").first.map(String.init) ?? raw
    }

    private func relativeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
