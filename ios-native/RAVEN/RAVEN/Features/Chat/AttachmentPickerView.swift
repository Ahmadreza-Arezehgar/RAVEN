import SwiftUI
import AVFoundation
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Attachment Picker (Vertical Droplet Style)
struct AttachmentPickerView: View {
    @Binding var isPresented: Bool
    let onImageSelected: (UIImage) -> Void
    var onVideoSelected: ((URL) -> Void)? = nil
    let onFileSelected: (URL) -> Void
    let onVoiceRecorded: (URL, Int) -> Void
    var onSchedule: (() -> Void)? = nil
    
    @State private var showImagePicker = false
    @State private var showFilePicker = false
    @State private var showVoiceRecorder = false
    @State private var showCamera = false
    
    @State private var appearAnimation = false
    
    var body: some View {
        VStack(spacing: 10) {
            // Photo/Video option (stagger: 0ms)
            DropletButton(
                icon: "photo.fill",
                title: "Photo",
                color: .green,
                delay: 0.0,
                isVisible: appearAnimation
            ) {
                showImagePicker = true
            }
            
            // PDF / File option (stagger: 50ms)
            DropletButton(
                icon: "doc.fill",
                title: "PDF / File",
                color: .blue,
                delay: 0.05,
                isVisible: appearAnimation
            ) {
                showFilePicker = true
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                appearAnimation = true
            }
        }
        .onDisappear {
            appearAnimation = false
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView(
                onImage: { image in
                    onImageSelected(image)
                    isPresented = false
                },
                onVideo: onVideoSelected != nil ? { videoUrl in
                    onVideoSelected?(videoUrl)
                    isPresented = false
                } : nil
            )
        }
        .sheet(isPresented: $showFilePicker) {
            FilePickerView { url in
                onFileSelected(url)
                isPresented = false
            }
        }
    }
}

// MARK: - Droplet Button (Circle + Label)
struct DropletButton: View {
    let icon: String
    let title: String
    let color: Color
    var delay: Double = 0.0
    var isVisible: Bool = true
    let action: () -> Void
    
    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            HStack(spacing: 14) {
                // Droplet circle
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 44, height: 44)
                
                // Label
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(DropletButtonStyle())
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.85)
        .offset(y: isVisible ? 0 : 15)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.72).delay(delay),
            value: isVisible
        )
    }
}

// MARK: - Droplet Button Style
struct DropletButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Image & Video Picker (PHPicker)
struct ImagePickerView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    var onVideo: ((URL) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        // FIX 1: Use .shared() to prevent permission crashes
        var config = PHPickerConfiguration(photoLibrary: .shared())
        if onVideo != nil {
            config.filter = .any(of: [.images, .videos])
        } else {
            config.filter = .images
        }
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // FIX 2: Update coordinator parent reference to prevent stale state
        context.coordinator.parent = self
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: ImagePickerView // FIX 3: var instead of let to allow updates
        
        init(_ parent: ImagePickerView) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                parent.dismiss()
                return
            }
            
            // ✅ Bug 6 fix: Use exact UTI from registeredTypeIdentifiers instead of
            // parent types ("public.movie", "public.image") which silently fail on
            // recent iOS versions when the actual file type is more specific.
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                let exactMovieType = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .movie) == true
                } ?? UTType.movie.identifier
                provider.loadFileRepresentation(forTypeIdentifier: exactMovieType) { [weak self] url, error in
                    guard let url = url else {
                        DispatchQueue.main.async { self?.parent.dismiss() }
                        return
                    }
                    let tempDir = FileManager.default.temporaryDirectory
                    let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                    do {
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        DispatchQueue.main.async { self?.parent.onVideo?(tempURL) }
                    } catch {
                        DispatchQueue.main.async { self?.parent.dismiss() }
                    }
                }
                return
            }
            
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let exactImageType = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .image) == true
                } ?? UTType.image.identifier
                provider.loadFileRepresentation(forTypeIdentifier: exactImageType) { [weak self] url, error in
                    guard let url = url else {
                        self?.loadObjectFallback(provider: provider)
                        return
                    }
                    if let image = Self.downsampledImage(at: url, maxDimension: PremiumLimits.maxImageDimension) {
                        DispatchQueue.main.async { self?.parent.onImage(image) }
                    } else {
                        self?.loadObjectFallback(provider: provider)
                    }
                }
            } else {
                loadObjectFallback(provider: provider)
            }
        }
        
        private static func downsampledImage(at url: URL, maxDimension: CGFloat) -> UIImage? {
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
            let downsampleOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
            return UIImage(cgImage: cgImage)
        }
        
        private func loadObjectFallback(provider: NSItemProvider) {
            guard provider.canLoadObject(ofClass: UIImage.self) else {
                DispatchQueue.main.async { self.parent.dismiss() }
                return
            }
            // Pull the callbacks out of self before crossing the concurrency
            // boundary — capturing `self` (a mutable weak reference) inside
            // the detached Task is a Swift 6 data-race error.
            let onImage = self.parent.onImage
            provider.loadObject(ofClass: UIImage.self) { [weak self] image, _ in
                if let uiImage = image as? UIImage {
                    Task.detached(priority: .userInitiated) {
                        let processed = uiImage.downscaled(maxDimension: PremiumLimits.maxImageDimension)
                        await MainActor.run { onImage(processed) }
                    }
                } else {
                    DispatchQueue.main.async { self?.parent.dismiss() }
                }
            }
        }
    }
}

// MARK: - Camera Picker
struct CameraPickerView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraPickerView
        
        init(_ parent: CameraPickerView) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - File Picker
struct FilePickerView: UIViewControllerRepresentable {
    let onFile: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.pdf, .plainText, .rtf, .data, .item]
        // FIX 4: asCopy: true — iOS copies the file before handing it to us,
        // eliminating the security-scoped access race condition entirely
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self // FIX 5: Keep coordinator reference fresh
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FilePickerView // FIX 6: var instead of let
        
        init(_ parent: FilePickerView) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            
            // With asCopy: true, the file is already copied to a temp location by iOS.
            // We copy again with a unique name to prevent collisions.
            let tempDir = FileManager.default.temporaryDirectory
            let destURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: url, to: destURL)
                parent.onFile(destURL)
            } catch {
                print("Failed to copy file: \(error)")
            }
        }
    }
}

// MARK: - Voice Recorder
struct VoiceRecorderView: View {
    let onRecorded: (URL, Int) -> Void
    
    @State private var isRecording = false
    @State private var recordingTime = 0
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    
    @Environment(\.dismiss) private var dismiss
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Time display
            Text(formattedTime)
                .font(.system(size: 48, weight: .light, design: .monospaced))
                .foregroundStyle(isRecording ? .red : .primary)
            
            // Recording indicator
            if isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                    Text("Recording...")
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Controls
            HStack(spacing: 48) {
                // Cancel
                Button {
                    cancelRecording()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
                
                // Record/Stop
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isRecording ? .red : .blue)
                            .frame(width: 72, height: 72)
                        
                        if isRecording {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.white)
                                .frame(width: 24, height: 24)
                        } else {
                            Circle()
                                .fill(.white)
                                .frame(width: 24, height: 24)
                        }
                    }
                }
                
                // Send (only after recording)
                Button {
                    sendRecording()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(recordingURL != nil && !isRecording ? .blue : .secondary)
                }
                .disabled(recordingURL == nil || isRecording)
            }
            .padding(.bottom, 48)
        }
        .onReceive(timer) { _ in
            if isRecording {
                recordingTime += 1
            }
        }
        .onAppear {
            setupAudioSession()
        }
        // FIX: Stop recording safely if sheet is dismissed via swipe-down
        .onDisappear {
            if isRecording {
                stopRecording()
                if let url = recordingURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
    
    var formattedTime: String {
        let minutes = recordingTime / 60
        let seconds = recordingTime % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("Failed to setup audio session: \(error)")
            #endif
        }
    }
    
    private func startRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        recordingURL = url
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            isRecording = true
            recordingTime = 0
        } catch {
            #if DEBUG
            print("Failed to start recording: \(error)")
            #endif
        }
    }
    
    private func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
    }
    
    private func cancelRecording() {
        stopRecording()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        dismiss()
    }
    
    private func sendRecording() {
        guard let url = recordingURL else { return }
        
        // ✅ Get actual duration from file, not from timer
        var actualDuration = recordingTime
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            actualDuration = Int(player.duration)
            #if DEBUG
            print("📊 Voice duration from file: \(actualDuration)s")
            #endif
        } catch {
            #if DEBUG
            print("⚠️ Could not read duration from file, using timer: \(recordingTime)s")
            #endif
        }
        
        // Send and clear
        onRecorded(url, actualDuration)
        recordingURL = nil  // Prevent duplicate sends
        dismiss()
    }
}

#Preview {
    AttachmentPickerView(
        isPresented: .constant(true),
        onImageSelected: { _ in },
        onFileSelected: { _ in },
        onVoiceRecorded: { _, _ in }
    )
}
