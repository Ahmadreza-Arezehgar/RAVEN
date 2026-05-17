import SwiftUI

// MARK: - Story Camera View
/// Full-screen camera portal with Liquid Glass UI
struct StoryCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = StoryCameraManager()
    
    @State private var capturedImage: UIImage?
    @State private var isCapturing = false
    @State private var showPreview = false
    
    var body: some View {
        ZStack {
            // Camera Preview
            if camera.isReady {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) {
                        camera.toggleCamera()
                    }
            } else {
                Color.black.ignoresSafeArea()
                ProgressView()
                    .tint(.white)
            }
            
            // UI Overlay
            VStack {
                // Top Bar
                HStack {
                    // Close Button
                    Button {
                        Haptics.light()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    // BUG FIX (2026-05-10): VoiceOver had no way to
                    // identify or operate the camera's icon-only
                    // controls; the close button was the only dismiss
                    // path for the screen.
                    .accessibilityLabel("Close camera")
                    .accessibilityHint("Returns to the previous screen.")
                    
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                Spacer()
                
                // Bottom Controls
                HStack(alignment: .center, spacing: 40) {
                    // Balance spacer (matches flip camera button width)
                    Spacer().frame(width: 44, height: 44)
                    
                    // Shutter Button
                    Button {
                        capturePhoto()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 80, height: 80)

                            Circle()
                                .fill(.white)
                                .frame(width: 68, height: 68)
                                .scaleEffect(isCapturing ? 0.85 : 1.0)
                        }
                    }
                    .disabled(isCapturing)
                    .accessibilityLabel("Capture photo")
                    .accessibilityHint(isCapturing ? "Capture in progress." : "Takes a photo with the current camera.")

                    // Flip Camera Button
                    Button {
                        camera.toggleCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Flip camera")
                    .accessibilityHint("Switches between front and back camera.")
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            camera.start()
        }
        .onDisappear {
            camera.stop()
        }
        .fullScreenCover(isPresented: $showPreview) {
            if let image = capturedImage {
                StoryPreviewView(image: image) {
                    // On post success
                    dismiss()
                } onRetake: {
                    capturedImage = nil
                    showPreview = false
                }
            }
        }
    }
    
    private func capturePhoto() {
        guard !isCapturing else { return }
        
        Haptics.medium()
        isCapturing = true
        
        Task {
            if let image = await camera.capturePhoto() {
                capturedImage = image
                showPreview = true
            }
            isCapturing = false
        }
    }
}

#Preview {
    StoryCameraView()
}
