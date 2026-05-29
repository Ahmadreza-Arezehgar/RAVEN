// AuthLandingView — the initial sign-in screen.
//
// Mirrors `ios-native/RAVEN/RAVEN/Features/Auth/AuthLandingView.swift`:
// logo halo → tagline → 3 feature rows → "Continue with Apple" → "or" →
// "Create account (Email)" + "Login (Email)" + "Log in with QR code".
//
// Sign in with Apple uses the official `SignInWithAppleButton` so this
// build can ship through App Review without custom OAuth UI.

import SwiftUI
import AuthenticationServices

struct AuthLandingView: View {
    @EnvironmentObject var auth: AuthService

    @State private var showEmailLogin = false
    @State private var showQrLogin = false

    /// Forward the system Apple-button completion to AuthService. Cancellations
    /// are silent (Apple convention); other errors surface in `auth.lastError`.
    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let identityTokenData = credential.identityToken,
                let identityToken = String(data: identityTokenData, encoding: .utf8),
                let authCodeData = credential.authorizationCode,
                let authorizationCode = String(data: authCodeData, encoding: .utf8)
            else {
                auth.reportSignInError("Apple didn't return a token. Try again.")
                return
            }
            Task {
                await auth.completeAppleSignIn(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode
                )
            }
        case .failure(let err):
            if let aerr = err as? ASAuthorizationError {
                switch aerr.code {
                case .canceled:
                    return  // user dismissed; silent
                case .notHandled:
                    auth.reportSignInError(
                        "Sign in with Apple isn't enabled for this build. Set DEVELOPMENT_TEAM in project.yml and re-sign with a real Apple Developer Team."
                    )
                case .invalidResponse:
                    auth.reportSignInError("Apple returned an invalid response. Try again.")
                case .failed:
                    auth.reportSignInError("Authorization failed. Try again.")
                case .unknown:
                    auth.reportSignInError(
                        "Sign in with Apple couldn't complete. Most often this is the entitlement not being satisfied — make sure the build is signed with a Developer Team."
                    )
                default:
                    auth.reportSignInError(err.localizedDescription)
                }
            } else {
                auth.reportSignInError(err.localizedDescription)
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo + brand
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 140, height: 140)
                            .overlay(
                                Circle().stroke(LinearGradient.ravenLogo, lineWidth: 1)
                            )
                        Image("RavenLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                    }

                    Text("RAVEN")
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundStyle(LinearGradient.ravenLogo)

                    Text("Secure messaging with or without internet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Feature rows
                VStack(spacing: 14) {
                    FeatureRow(icon: "lock.shield", title: "Secure & private messaging")
                    FeatureRow(icon: "antenna.radiowaves.left.and.right",
                               title: "Works offline via mesh")
                    FeatureRow(icon: "bolt.fill", title: "Fast and reliable")
                }
                .padding(.horizontal, 64)

                Spacer()

                // CTAs
                VStack(spacing: 12) {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleAppleResult(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    GoogleSignInButton {
                        Task { await auth.signInWithGoogle() }
                    }

                    PrimaryGradientButton(title: "Create account (Email)") {
                        showEmailLogin = true // re-uses the same screen
                    }

                    SecondaryButton(title: "Login (Email)") {
                        showEmailLogin = true
                    }

                    SecondaryButton(title: "Log in with QR code", systemIcon: "qrcode") {
                        showQrLogin = true
                    }

                    // Only show the inline error when neither sheet is up —
                    // the EmailLoginSheet has its own error label, so showing
                    // both produces a confusing duplicate.
                    if let err = auth.lastError, !showEmailLogin, !showQrLogin {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, 24)

                Spacer().frame(height: 56)
            }
        }
        .sheet(isPresented: $showEmailLogin, onDismiss: { auth.clearSignInError() }) {
            EmailLoginSheet()
                .environmentObject(auth)
        }
        .sheet(isPresented: $showQrLogin, onDismiss: { auth.clearSignInError() }) {
            QrLoginSheet()
                .environmentObject(auth)
        }
    }
}

// MARK: - Reusable bits

struct FeatureRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(RavenColors.logoStart)
                .frame(width: 28)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct PrimaryGradientButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(LinearGradient.ravenBrand)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemIcon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = systemIcon {
                    Image(systemName: icon)
                }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(.ultraThinMaterial)
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Google-branded "Sign in with Google" button. White background, the
/// official multicolor "G" mark on the left, system-default text. Matches
/// Google's brand guidelines closely enough for App Review while staying
/// dependency-free (no `GoogleSignInSwift` SwiftUI view import needed).
struct GoogleSignInButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                GoogleGMark()
                    .frame(width: 18, height: 18)
                Text("Continue with Google")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Multicolor Google "G" mark, drawn as four arcs around a circle. Vector,
/// resolution-independent, no asset catalog entry needed.
private struct GoogleGMark: View {
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let stroke = r * 0.36
            let radius = r - stroke / 2

            func arc(_ startDeg: Double, _ endDeg: Double, _ color: Color) {
                var path = Path()
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(startDeg),
                    endAngle: .degrees(endDeg),
                    clockwise: false
                )
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: stroke, lineCap: .butt))
            }

            // Approximate Google's G colors and arc sweeps.
            arc(-30, 90, Color(red: 0.26, green: 0.52, blue: 0.96))   // blue
            arc(90, 210, Color(red: 0.20, green: 0.66, blue: 0.33))   // green
            arc(210, 270, Color(red: 0.98, green: 0.74, blue: 0.02))  // yellow
            arc(270, 330, Color(red: 0.92, green: 0.26, blue: 0.21))  // red

            // Inner white horizontal stub so the "G" reads as a G, not an O.
            var stub = Path()
            let stubRect = CGRect(
                x: center.x,
                y: center.y - stroke * 0.55,
                width: r * 0.95,
                height: stroke * 1.1
            )
            stub.addRect(stubRect)
            ctx.fill(stub, with: .color(.white))

            // Blue inner crossbar of the G.
            var bar = Path()
            let barRect = CGRect(
                x: center.x + r * 0.08,
                y: center.y - stroke * 0.18,
                width: r * 0.55,
                height: stroke * 0.55
            )
            bar.addRect(barRect)
            ctx.fill(bar, with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))
        }
    }
}

// MARK: - Email Login Sheet

struct EmailLoginSheet: View {
    @EnvironmentObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Sign in").font(.title2.weight(.bold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .autocorrectionDisabled()

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if let err = auth.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            PrimaryGradientButton(title: busy ? "Signing in…" : "Sign in") {
                Task {
                    busy = true
                    await auth.signIn(username: username, password: password)
                    busy = false
                    if auth.isAuthenticated { dismiss() }
                }
            }
            .disabled(busy || username.isEmpty || password.isEmpty)
        }
        .padding(28)
        .frame(width: 380)
    }
}

// MARK: - QR Login Sheet

struct QrLoginSheet: View {
    @EnvironmentObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var sessionId: String?
    @State private var nonce: String?
    @State private var expiresAt: Date?
    @State private var qrPayload: String?
    @State private var pollTimer: Timer?

    enum Phase { case loading, ready, scanned, approved, denied, expired, error }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Log in with QR").font(.title2.weight(.bold))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            content
                .frame(width: 280, height: 280)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // 🧪 Copy raw payload to clipboard. Useful for live-
            // testing the iPhone-side scan flow on the iOS Simulator
            // (where the camera can't actually read a QR off the
            // screen). On the simulator, paste this into the
            // "Paste login code" DEBUG button on `ScanQRCodeView`.
            if let p = qrPayload, phase == .ready || phase == .scanned {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p, forType: .string)
                } label: {
                    Label("Copy code", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Spacer().frame(height: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Open RAVEN on your phone")
                Text("2. Settings → Linked Devices")
                Text("3. Tap “Link a desktop” and scan this code")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
        .frame(width: 380)
        .task { await start() }
        .onDisappear { pollTimer?.invalidate() }
        // 🔵 Bluetooth fallback observer (2026-05-09): when the
        // phone broadcasts a signed login-approval envelope over
        // BLE because the internet path failed, BLEMeshEngine fires
        // this notification. We only act if the envelope's
        // `sessionId` matches the one this sheet is currently
        // showing — drops stray envelopes from concurrent sessions.
        .onReceive(NotificationCenter.default.publisher(for: .ravenBluetoothLoginApproved)) { note in
            guard let env = note.userInfo?["envelope"] as? MeshLoginApprovalEnvelope,
                  env.sessionId == sessionId else { return }
            pollTimer?.invalidate()
            phase = .approved
            auth.completeBluetoothLogin(env)
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        }
        // 🔵 Phase 2: phone-bridged JWT envelope. End-to-end
        // encrypted under THIS desktop's X25519 pubkey (carried in
        // the QR's `ble.agreement` block). When it lands we get a
        // real server token — not a mesh-only session — so we use
        // `completeQrLogin` (the same path the /poll success would
        // hit) instead of `completeBluetoothLogin`.
        .onReceive(NotificationCenter.default.publisher(for: .ravenBluetoothLoginTokenReceived)) { note in
            guard let sid = note.userInfo?["sessionId"] as? String, sid == sessionId,
                  let p = note.userInfo?["payload"] as? MeshLoginTokenPayload else { return }
            pollTimer?.invalidate()
            phase = .approved
            auth.completeQrLogin(QrPollResponse(
                status: "approved",
                token: p.token,
                refreshToken: p.refreshToken,
                userId: p.userId,
                username: p.username
            ))
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .ready, .scanned:
            if let payload = qrPayload {
                QRCodeView(string: payload)
                    .padding(20)
            }
        case .approved:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
        case .denied, .expired, .error:
            Image(systemName: "xmark.circle")
                .font(.system(size: 64))
                .foregroundStyle(.red)
        }
    }

    private var message: String {
        switch phase {
        case .loading: return "Generating code…"
        case .ready: return "Scan with RAVEN on your phone"
        case .scanned: return "Confirm on your phone…"
        case .approved: return "Logged in!"
        case .denied: return "Login denied on your phone."
        case .expired: return "QR code expired. Refresh and try again."
        case .error: return "Couldn't reach the server."
        }
    }

    private func start() async {
        do {
            let init_ = try await NetworkService.shared.qrLoginInit()
            sessionId = init_.sessionId
            nonce = init_.nonce
            expiresAt = init_.expiresAt
            qrPayload = encodePayload(sessionId: init_.sessionId, nonce: init_.nonce, exp: init_.expiresAt)
            phase = .ready
            startPolling()
        } catch {
            phase = .error
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { await poll() }
        }
    }

    private func poll() async {
        guard let sid = sessionId, let n = nonce else { return }
        do {
            let r = try await NetworkService.shared.qrLoginPoll(sessionId: sid, nonce: n)
            switch r.status {
            case "pending": break
            case "scanned": phase = .scanned
            case "approved":
                pollTimer?.invalidate()
                phase = .approved
                auth.completeQrLogin(r)
                try? await Task.sleep(nanoseconds: 600_000_000)
                dismiss()
            case "denied":
                pollTimer?.invalidate()
                phase = .denied
            case "expired":
                pollTimer?.invalidate()
                phase = .expired
            default: break
            }
        } catch {
            // Tolerate transient errors; keep polling until the session
            // window closes.
            if let exp = expiresAt, Date() > exp {
                pollTimer?.invalidate()
                phase = .expired
            }
        }
    }

    private func encodePayload(sessionId: String, nonce: String, exp: Date) -> String {
        // 🔵 BLE-fallback block (2026-05-09): when present, lets the
        // phone approve this login over Bluetooth if the internet
        // path to `/api/auth/qr-login/scan` fails. The phone reads
        // `ble.peer` (our identity Ed25519 pubkey) so it knows whom
        // to send the signed envelope to, and `ble.svc` (the RAVEN
        // mesh service UUID) so it knows which BLE service to scan.
        // Both fields optional — the phone falls back to internet-
        // only behaviour when the block is missing.
        var body: [String: Any] = [
            "v": 1,
            "type": "desktop_login",
            "sid": sessionId,
            "n": nonce,
            "exp": Int(exp.timeIntervalSince1970),
        ]
        if let pub = DeviceIdentityService.shared.publicKeyBase64 {
            // 🔵 Phase 2 (2026-05-09): include the X25519 (key-agreement)
            // pubkey so the phone can ECDH-encrypt the bridged JWT
            // when forwarding it via `MeshLoginTokenEnvelope`. The
            // identity (Ed25519) pubkey continues to authenticate
            // Phase-1 envelopes; the agreement pubkey is for the
            // Phase-2 encrypted token forward only.
            var ble: [String: Any] = [
                "peer": pub,
                "svc": BLEMeshEngine.serviceUUID.uuidString,
            ]
            if let agreement = DeviceIdentityService.shared.agreementPublicKeyBase64 {
                ble["agreement"] = agreement
            }
            body["ble"] = ble
        }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - QR rendering

import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    let string: String

    var body: some View {
        if let cg = generate() {
            Image(decorative: cg, scale: 1.0)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray
        }
    }

    private func generate() -> CGImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard
            let output = filter.outputImage?
                .transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
