import SwiftUI
import AVFoundation

// MARK: - Story Camera Manager
/// Manages AVCaptureSession for instant story capture
@MainActor
final class StoryCameraManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isReady = false
    @Published var isUsingFront = true
    @Published var capturedImage: UIImage?
    @Published var error: String?
    
    // MARK: - Private Properties
    // AVCaptureSession serialises calls on its own internal queue, so calling
    // its sync APIs from any actor is safe. Marking the property nonisolated
    // lets startRunning/stopRunning run on a background task without hopping.
    nonisolated let session = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private var photoContinuation: CheckedContinuation<UIImage?, Error>?
    
    // MARK: - Setup
    /// Pre-warm camera session (call on Home appear for instant open)
    func prewarm() {
        guard !isReady else { return }
        
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.configure()
        }
    }
    
    /// Full configuration
    private func configure() async {
        // Check permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                await MainActor.run { self.error = "Camera access denied" }
                return
            }
        case .denied, .restricted:
            await MainActor.run { self.error = "Camera access denied" }
            return
        case .authorized:
            break
        @unknown default:
            break
        }
        
        // Configure session
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        // Add camera input
        await setCamera(front: true)
        
        // Add photo output
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        
        session.commitConfiguration()
        
        await MainActor.run {
            self.isReady = true
        }
    }
    
    // MARK: - Camera Control
    func start() {
        Task {
            // Wait for configuration if not ready
            if !isReady {
                await configure()
            }
            
            guard isReady, !session.isRunning else { return }
            
            await Task.detached(priority: .userInitiated) { [weak self] in
                self?.session.startRunning()
            }.value
            
            #if DEBUG
            print("📸 [StoryCamera] Session started, isRunning: \(session.isRunning)")
            #endif
        }
    }
    
    func stop() {
        guard session.isRunning else { return }
        
        Task.detached { [weak self] in
            self?.session.stopRunning()
            #if DEBUG
            print("📸 [StoryCamera] Session stopped")
            #endif
        }
    }
    
    func toggleCamera() {
        Task {
            session.beginConfiguration()
            await setCamera(front: !isUsingFront)
            session.commitConfiguration()
            Haptics.light()
        }
    }
    
    private func setCamera(front: Bool) async {
        // Remove old input
        if let input = currentInput {
            session.removeInput(input)
        }
        
        let position: AVCaptureDevice.Position = front ? .front : .back
        
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position
        ) else {
            await MainActor.run { self.error = "Camera not available" }
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                await MainActor.run {
                    self.isUsingFront = front
                }
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }
    
    // MARK: - Capture Photo
    func capturePhoto() async -> UIImage? {
        guard isReady else { return nil }
        
        return try? await withCheckedThrowingContinuation { continuation in
            // If a continuation already exists (e.g. rapid double-tap), cancel it
            // gracefully. Overwriting without resuming causes a runtime trap:
            // "SWIFT TASK CONTINUATION MISUSE: captured leaked continuation"
            if let existing = self.photoContinuation {
                existing.resume(returning: nil)
            }
            self.photoContinuation = continuation
            
            let settings = AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(.auto) {
                settings.flashMode = .auto
            }
            
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - Photo Capture Delegate
extension StoryCameraManager: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            Task { @MainActor in
                self.photoContinuation?.resume(throwing: error)
                self.photoContinuation = nil
            }
            return
        }
        
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            Task { @MainActor in
                self.photoContinuation?.resume(returning: nil)
                self.photoContinuation = nil
            }
            return
        }
        
        Task { @MainActor in
            // Mirror front camera image
            let finalImage: UIImage
            if self.isUsingFront, let cgImg = image.cgImage {
                finalImage = UIImage(
                    cgImage: cgImg,
                    scale: image.scale,
                    orientation: .leftMirrored
                )
            } else {
                finalImage = image
            }
            
            self.capturedImage = finalImage
            self.photoContinuation?.resume(returning: finalImage)
            self.photoContinuation = nil
        }
    }
}

// MARK: - Camera Preview View (UIKit Bridge)
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(session: session)
        return view
    }
    
    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Session reference update if needed
        uiView.updateSession(session)
    }
}

// MARK: - Custom UIView for Camera Preview
class PreviewUIView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        backgroundColor = .black
        setupPreviewLayer(session: session)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
    
    private func setupPreviewLayer(session: AVCaptureSession) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        self.previewLayer = layer
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Update preview layer frame on every layout pass
        previewLayer?.frame = bounds
    }
    
    func updateSession(_ session: AVCaptureSession) {
        if previewLayer?.session !== session {
            previewLayer?.session = session
        }
    }
}
