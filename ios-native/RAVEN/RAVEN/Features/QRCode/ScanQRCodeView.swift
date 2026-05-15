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
    @State private var isSendingRequest = false
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
                    isSending: $isSendingRequest,
                    onConfirm: sendFriendRequest,
                    onCancel: { showConfirmation = false }
                )
                .presentationDetents([.height(300)])
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
        // Two QR types are accepted in this scanner:
        //
        //   1. `raven://friend?user_id=UUID` — the legacy in-app
        //      friend-add flow. Fetches the target user and shows
        //      the friend-request confirmation sheet.
        //
        //   2. A base64-encoded `desktop_login` JSON payload emitted
        //      by the macOS / Web client when the user clicks "Log in
        //      with QR code". Approving it links the desktop to this
        //      account via `Features/QRCode/DesktopLoginApprovalView`.
        //      This is the iOS half of the WhatsApp-Web pattern.

        if code.hasPrefix("raven://friend?user_id=") {
            let userId = String(code.dropFirst("raven://friend?user_id=".count))
            scannedUserId = userId
            Haptics.success()
            scanner.stopScanning()
            Task { await fetchUserInfo(userId: userId) }
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
    private func sendFriendRequest() {
        guard let userId = scannedUserId else { return }
        guard !isSendingRequest else { return } // Prevent duplicate calls
        
        // ⚡ Optimistic: immediately show success and dismiss
        isSendingRequest = true
        Haptics.success()
        showConfirmation = false
        dismiss()
        
        #if DEBUG
        print("📤 [QR] Sending friend request to user: \(userId)")
        #endif
        
        Task {
            do {
                let _: EmptyResponse = try await NetworkService.shared.post(
                    path: "/api/users/friend-request?recipient_id=\(userId)",
                    body: EmptyBody()
                )
                #if DEBUG
                print("✅ [QR] Friend request confirmed by server for user: \(userId)")
                #endif
            } catch let error as APIError {
                switch error {
                case .badRequest(let message) where message.lowercased().contains("already sent"):
                    // Already sent - no rollback needed
                    #if DEBUG
                    print("ℹ️ [QR] Friend request already sent - no action needed")
                    #endif
                case .rateLimited:
                    #if DEBUG
                    print("⚠️ [QR] Rate limited")
                    #endif
                    await MainActor.run { Haptics.error() }
                default:
                    #if DEBUG
                    print("❌ [QR] Friend request failed: \(error)")
                    #endif
                    await MainActor.run { Haptics.error() }
                }
            } catch {
                #if DEBUG
                print("❌ [QR] Friend request failed: \(error)")
                #endif
                await MainActor.run { Haptics.error() }
            }
        }
    }
}

// MARK: - Friend Request Confirmation Sheet
struct FriendRequestConfirmationSheet: View {
    let user: User?
    @Binding var isSending: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
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
                initials: user?.initials ?? "?",
                size: 80
            )
            
            // User Info
            VStack(spacing: 4) {
                Text(user?.displayName ?? "User")
                    .font(.system(size: 20, weight: .semibold))
                
                Text("@\(user?.username ?? "unknown")")
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
