import SwiftUI
import AVFoundation

// MARK: - Scan QR Code View
/// Camera-based QR scanner for friend requests
struct ScanQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = QRScannerViewModel()
    @State private var showConfirmation = false
    @State private var scannedUserId: String?
    @State private var scannedUser: User?
    /// The parsed v2 QR payload — carries displayName / username / keys
    /// so the confirmation sheet renders OFFLINE with no server fetch.
    @State private var scannedPayload: FriendQRPayload?
    @State private var isSendingRequest = false
    /// 🔴 BUG FIX (2026-05-21) — surfaced when a friend-request
    /// genuinely fails (server error / user-not-found / blocked) or
    /// when the user scans their own QR. Shown inside the confirmation
    /// sheet so a failure is never silently swallowed (the old code
    /// dismissed optimistically and the user believed it succeeded).
    @State private var scanError: String?
    /// Set when the scanned QR is a `desktop_login` payload (macOS / Web
    /// app showing its login QR). Drives the approval sheet.
    @State private var desktopLoginPayload: DesktopLoginPayload?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Camera View
                QRScannerCameraView(scanner: scanner)
                    .ignoresSafeArea()
                
                // Overlay
                VStack {
                    Spacer()
                    
                    // Scan Frame
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 250, height: 250)
                        .overlay(
                            // Corner accents
                            GeometryReader { geo in
                                let size = geo.size
                                let cornerLength: CGFloat = 40
                                let lineWidth: CGFloat = 4
                                
                                Path { path in
                                    // Top-left
                                    path.move(to: CGPoint(x: 0, y: cornerLength))
                                    path.addLine(to: CGPoint(x: 0, y: 0))
                                    path.addLine(to: CGPoint(x: cornerLength, y: 0))
                                    
                                    // Top-right
                                    path.move(to: CGPoint(x: size.width - cornerLength, y: 0))
                                    path.addLine(to: CGPoint(x: size.width, y: 0))
                                    path.addLine(to: CGPoint(x: size.width, y: cornerLength))
                                    
                                    // Bottom-right
                                    path.move(to: CGPoint(x: size.width, y: size.height - cornerLength))
                                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                                    path.addLine(to: CGPoint(x: size.width - cornerLength, y: size.height))
                                    
                                    // Bottom-left
                                    path.move(to: CGPoint(x: cornerLength, y: size.height))
                                    path.addLine(to: CGPoint(x: 0, y: size.height))
                                    path.addLine(to: CGPoint(x: 0, y: size.height - cornerLength))
                                }
                                .stroke(Color.cyan, lineWidth: lineWidth)
                            }
                        )
                    
                    Spacer()

                    // Hint
                    Text("Point camera at a RAVEN QR code")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 12)

                    // 🧪 DEBUG-only: paste the QR payload from clipboard.
                    // The iOS Simulator's camera can't actually scan a QR
                    // off the screen — it shows a synthesised 3D scene.
                    // This button lets us live-test the desktop-login
                    // path on a simulator by pasting the payload that
                    // was copied from the macOS QR sheet's "Copy code"
                    // action. Hidden in RELEASE builds.
                    #if DEBUG
                    Button {
                        if let raw = UIPasteboard.general.string,
                           !raw.isEmpty {
                            handleScannedCode(raw)
                        }
                    } label: {
                        Label("Paste login code (DEBUG)", systemImage: "doc.on.clipboard")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, 60)
                    #else
                    Spacer().frame(height: 60)
                    #endif
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onChange(of: scanner.scannedCode) { _, code in
                if let code = code {
                    handleScannedCode(code)
                }
            }
            .sheet(isPresented: $showConfirmation) {
                FriendRequestConfirmationSheet(
                    user: scannedUser,
                    fallbackName: scannedPayload?.displayName,
                    fallbackUsername: scannedPayload?.username,
                    isSending: $isSendingRequest,
                    errorMessage: $scanError,
                    onConfirm: sendFriendRequest,
                    onCancel: {
                        scanError = nil
                        showConfirmation = false
                    }
                )
                .presentationDetents([.height(scanError == nil ? 300 : 360)])
            }
            // Desktop QR-login approval — presented when the scanner
            // reads a base64 `desktop_login` payload from the macOS /
            // Web client. Half-sheet so the user can still see the
            // scanner background.
            .sheet(item: $desktopLoginPayload) { payload in
                DesktopLoginApprovalView(payload: payload) {
                    desktopLoginPayload = nil
                    dismiss()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onDisappear {
                scanner.stopScanning()
            }
    }
    }
    
    // MARK: - Handle Scanned Code
    private func handleScannedCode(_ code: String) {
        // QR types accepted by this scanner:
        //
        //   1. Round 24 — `raven://friend?v=2&d=<base64>`: a
        //      self-contained friend payload carrying display
        //      name + Ed25519 identity pub + X25519 agreement
        //      pub. Scanning it works fully OFFLINE — we stash
        //      the keys in PeerKeyDirectory + the contact info
        //      locally, then queue the server-side
        //      friend-request for whenever connectivity returns.
        //
        //   2. Legacy — `raven://friend?user_id=UUID`: only the
        //      userId. Requires `/api/users/{id}` to look up the
        //      display name. Still accepted for back-compat.
        //
        //   3. A base64-encoded `desktop_login` JSON payload
        //      emitted by the macOS / Web client. Approving it
        //      links the desktop to this account via
        //      `DesktopLoginApprovalView`.

        // 🔴 ROUND 70 — use the verifying parser. Rejects v1 QRs (no
        // integrity), stale QRs (> 24h), and any QR whose embedded
        // Ed25519 signature doesn't match the (userId, agreementPub,
        // identityPub, issuedAt) transcript. Old v2 QRs without
        // round-70 signature/timestamp fields are rejected here too —
        // by design — so a photographed pre-round-70 QR is now dead.
        // Fall back to the legacy parse only for diagnostic / error
        // messaging so the user sees "this QR is too old / unsigned"
        // instead of "not a RAVEN QR".
        if let friend = FriendQRPayload.parseAndVerify(code) {
            // 🔴 BUG FIX (2026-05-21) — self-scan guard. Scanning your
            // OWN QR code must not open a friend-request-to-yourself
            // flow. (The server now rejects it too, but catching it
            // here gives a clear message instead of a generic
            // failure.) Don't stop scanning — let the user scan a
            // different code right away.
            if let me = AuthService.shared.currentUser?.id, friend.userId == me {
                Haptics.error()
                scanError = "That's your own QR code — you can't add yourself."
                return
            }
            Haptics.success()
            scanner.stopScanning()
            scannedUserId = friend.userId
            // 🟥 OFFLINE QR FIX (2026-05-22) — keep the v2 payload so the
            // confirmation sheet can show the scanned person's real name
            // even with no internet. Previously it was discarded and the
            // offline sheet fell back to "User / @unknown".
            scannedPayload = friend

            // Stash the verified agreement key in PeerKeyDirectory
            // immediately so the next DM we send to this contact
            // seals RVNS1 from the very first byte — no cold-start
            // RVNP1 plaintext fallback. The key came directly from
            // the QR (out-of-band, user-verified) so we go through
            // the explicit `setAgreementKey` path that bypasses the
            // server-fetch TOFU check.
            //
            // 🔴 ROUND 70 — only safe BECAUSE we used parseAndVerify
            // above. A pre-round-70 unsigned QR could carry an
            // attacker-substituted agreement key; the verified
            // parser rejects those before they reach this branch.
            Task {
                if let agreementB64 = friend.agreementPubBase64,
                   let agreementKey = Data(base64Encoded: agreementB64),
                   agreementKey.count == 32 {
                    await PeerKeyDirectory.shared.setAgreementKey(
                        agreementKey, for: friend.userId
                    )
                }
            }

            // Show the confirmation sheet immediately. If we're
            // online, `fetchUserInfo` populates `scannedUser` with
            // the full server record (avatar / verified flag).
            // If we're offline, the sheet still renders using
            // whatever the v2 QR carried (displayName/username);
            // the confirm-tap queues the server-side friend-
            // request for when connectivity returns.
            showConfirmation = true
            Task { await fetchUserInfo(userId: friend.userId) }
            return
        } else if FriendQRPayload.parse(code) != nil {
            // 🔴 ROUND 70 — QR parses as a RAVEN friend payload but
            // failed the freshness/signature check. Show a clear
            // error so the user knows why instead of silently doing
            // nothing.
            Haptics.error()
            scanError = "This QR code is too old or unsigned. Ask the person for a fresh one."
            return
        }

        if let payload = DesktopLoginPayload.decode(from: code) {
            Haptics.success()
            scanner.stopScanning()
            desktopLoginPayload = payload
            return
        }

        Haptics.error()
    }
    
    // MARK: - Fetch User Info
    private func fetchUserInfo(userId: String) async {
        do {
            let user: User = try await NetworkService.shared.get(path: "/api/users/\(userId)")
            await MainActor.run {
                scannedUser = user
                showConfirmation = true
            }
        } catch {
            #if DEBUG
            print("❌ Failed to fetch user: \(error)")
            #endif
            // Still show confirmation with minimal info
            await MainActor.run {
                showConfirmation = true
            }
        }
    }
    
    // MARK: - Send Friend Request
    //
    // 🔴 BUG FIX (2026-05-21) — the previous version was "optimistic":
    // it played a success haptic and `dismiss()`ed the whole scanner
    // BEFORE the server request resolved. Any genuine failure
    // (user-not-found, blocked, 500) hit a branch that only did a
    // silent `Haptics.error()` — by then the view was gone, so the
    // user believed the friend request was sent when it never was.
    //
    // Now: we keep the confirmation sheet open with a spinner while
    // the request is in flight, and only dismiss on a GENUINELY good
    // outcome (server confirmed, "already sent/friends", or queued
    // offline). A real failure keeps the sheet open and surfaces the
    // error via `scanError` so the user can retry.
    private func sendFriendRequest() {
        guard let userId = scannedUserId else { return }
        guard !isSendingRequest else { return } // Prevent duplicate calls

        isSendingRequest = true
        scanError = nil

        #if DEBUG
        print("📤 [QR] Sending friend request to user: \(userId)")
        #endif

        // 🟦 ROUND 50 — offline mesh fallback. Broadcast over BLE mesh
        // in parallel with the server POST (signed; receivers verify).
        Task {
            await MeshFriendRequestBroadcaster.broadcastFriendRequest(toUserId: userId)
        }

        Task {
            do {
                let _: EmptyResponse = try await NetworkService.shared.post(
                    path: "/api/users/friend-request?recipient_id=\(userId)",
                    body: EmptyBody()
                )
                #if DEBUG
                print("✅ [QR] Friend request confirmed by server for user: \(userId)")
                #endif
                // Confirmed by the server — NOW it's safe to declare
                // success and dismiss.
                await MainActor.run {
                    isSendingRequest = false
                    Haptics.success()
                    showConfirmation = false
                    dismiss()
                }
            } catch let error as APIError {
                switch error {
                case .badRequest(let message)
                    where message.lowercased().contains("already"):
                    // "already sent" / "already friends" / mutual
                    // auto-accept — all fine outcomes; the
                    // relationship exists. Treat as success.
                    #if DEBUG
                    print("ℹ️ [QR] Friend request already exists — treating as success")
                    #endif
                    await MainActor.run {
                        isSendingRequest = false
                        Haptics.success()
                        showConfirmation = false
                        dismiss()
                    }
                case .rateLimited:
                    await MainActor.run {
                        isSendingRequest = false
                        Haptics.error()
                        scanError = "You've sent too many friend requests. Please try again later."
                    }
                default:
                    // Genuine failure (blocked, user-not-found, server
                    // error). Do NOT pretend it worked — keep the
                    // sheet open and show the error.
                    #if DEBUG
                    print("❌ [QR] Friend request failed: \(error)")
                    #endif
                    await MainActor.run {
                        isSendingRequest = false
                        Haptics.error()
                        scanError = "Couldn't send the friend request. Please try again."
                    }
                }
            } catch {
                // 🔴 ROUND 24 — offline-friendly fallback. Off Wi-Fi is
                // a fine outcome: queue the request, the NetworkMonitor
                // observer flushes it when connectivity returns. This
                // genuinely succeeds (eventually), so dismissing is OK.
                #if DEBUG
                print("⏳ [QR] Friend request to \(userId) queued for offline retry: \(error)")
                #endif
                await PendingFriendRequestQueue.shared.enqueue(recipientId: userId)
                await MainActor.run {
                    isSendingRequest = false
                    Haptics.warning()
                    showConfirmation = false
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Friend Request Confirmation Sheet
struct FriendRequestConfirmationSheet: View {
    let user: User?
    /// Offline fallbacks from the scanned v2 QR payload — used when
    /// `user` is nil because no server record could be fetched (an
    /// offline scan). Without these the sheet showed "User / @unknown"
    /// for a perfectly valid offline friend-add.
    var fallbackName: String? = nil
    var fallbackUsername: String? = nil
    @Binding var isSending: Bool
    /// 🔴 BUG FIX (2026-05-21) — non-nil when the friend-request
    /// genuinely failed. Rendered inline so the failure is visible
    /// instead of being silently swallowed by an optimistic dismiss.
    @Binding var errorMessage: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// Initials from the offline fallback name, for the avatar
    /// placeholder when there is no server record.
    private var fallbackInitials: String? {
        guard let name = fallbackName?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return nil }
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
    
    private var friendshipMessage: String? {
        guard let friendship = user?.friendship else { return nil }
        
        if friendship.alreadyFriends {
            return "You're already friends!"
        } else if friendship.alreadySent {
            return "Friend request already sent"
        } else if friendship.pendingReceived {
            return "This user sent you a request"
        }
        return nil
    }
    
    private var canSendRequest: Bool {
        guard let friendship = user?.friendship else { return true }
        return !friendship.alreadyFriends && !friendship.alreadySent
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // User Avatar
            ProfileAvatarView(
                avatarPath: user?.avatarPath,
                initials: user?.initials ?? fallbackInitials ?? "?",
                size: 80
            )
            
            // User Info
            VStack(spacing: 4) {
                Text(user?.displayName ?? fallbackName ?? "User")
                    .font(.system(size: 20, weight: .semibold))
                
                Text("@\(user?.username ?? fallbackUsername ?? "unknown")")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            
            // Status message or prompt
            if let message = friendshipMessage {
                HStack(spacing: 8) {
                    Image(systemName: user?.friendship?.alreadyFriends == true ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(user?.friendship?.alreadyFriends == true ? .green : .blue)
                    Text(message)
                }
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            } else {
                Text("Send a friend request?")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }

            // 🔴 BUG FIX (2026-05-21) — inline failure message. When a
            // friend request genuinely fails, the sheet stays open and
            // shows this so the user knows it didn't go through.
            if let err = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            }

            // Buttons
            HStack(spacing: 16) {
                Button(canSendRequest ? "Cancel" : "Done") {
                    onCancel()
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(canSendRequest ? Color.secondary : Color.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(canSendRequest ? Color(.systemGray5) : Color.accentColor)
                .clipShape(Capsule())
                
                if canSendRequest {
                    Button {
                        onConfirm()
                    } label: {
                        if isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Send Request")
                        }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                    .disabled(isSending)
                }
            }
        }
        .padding(24)
    }
}

// MARK: - QR Scanner ViewModel
@MainActor
class QRScannerViewModel: NSObject, ObservableObject {
    @Published var scannedCode: String?
    @Published var isScanning = true
    
    var captureSession: AVCaptureSession?
    
    func stopScanning() {
        isScanning = false
        captureSession?.stopRunning()
    }
    
    func resumeScanning() {
        isScanning = true
        scannedCode = nil
        captureSession?.startRunning()
    }
}

// MARK: - QR Scanner Camera View
struct QRScannerCameraView: UIViewRepresentable {
    @ObservedObject var scanner: QRScannerViewModel
    
    func makeUIView(context: Context) -> UIView {
        let view = PreviewView()
        view.backgroundColor = .black
        
        // Check camera authorization first
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard authStatus == .authorized else {
            if authStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted {
                        DispatchQueue.main.async {
                            // Guard: user may have dismissed the view while permission dialog was showing
                            guard self.scanner.isScanning else { return }
                            self.setupCamera(in: view, context: context)
                        }
                    }
                }
            }
            return view
        }
        
        setupCamera(in: view, context: context)
        return view
    }
    
    private func setupCamera(in view: PreviewView, context: Context) {
        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        
        // Use specific back camera
        guard let videoCaptureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            #if DEBUG
            print("❌ QR Scanner: No back camera available")
            #endif
            captureSession.commitConfiguration()
            return
        }
        
        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            #if DEBUG
            print("❌ QR Scanner: Failed to create input: \(error)")
            #endif
            captureSession.commitConfiguration()
            return
        }
        
        guard captureSession.canAddInput(videoInput) else {
            #if DEBUG
            print("❌ QR Scanner: Cannot add video input")
            #endif
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(videoInput)
        
        let metadataOutput = AVCaptureMetadataOutput()
        
        guard captureSession.canAddOutput(metadataOutput) else {
            #if DEBUG
            print("❌ QR Scanner: Cannot add metadata output")
            #endif
            captureSession.commitConfiguration()
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]
        
        captureSession.commitConfiguration()
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        // 90° = portrait. Replaces the iOS 17-deprecated `videoOrientation`.
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        
        // Store for later frame updates
        view.previewLayer = previewLayer
        context.coordinator.previewLayer = previewLayer
        
        // Set on scanner
        Task { @MainActor in
            scanner.captureSession = captureSession
        }
        
        // Start running on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
            #if DEBUG
            print("✅ QR Scanner: Session started running")
            #endif
        }
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewView = uiView as? PreviewView {
            previewView.previewLayer?.frame = uiView.bounds
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(scanner: scanner)
    }
    
    // Custom UIView that properly updates preview layer frame
    class PreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?
        
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
    
    class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let scanner: QRScannerViewModel
        var previewLayer: AVCaptureVideoPreviewLayer?
        
        init(scanner: QRScannerViewModel) {
            self.scanner = scanner
        }
        
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if let metadataObject = metadataObjects.first,
               let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
               let stringValue = readableObject.stringValue {
                // Dispatch to main actor to access isolated properties
                Task { @MainActor in
                    guard scanner.isScanning else { return }
                    scanner.scannedCode = stringValue
                }
            }
        }
    }
}

// MARK: - Empty Bodies
private struct EmptyBody: Encodable {}

// MARK: - Preview
#Preview {
    ScanQRCodeView()
}
