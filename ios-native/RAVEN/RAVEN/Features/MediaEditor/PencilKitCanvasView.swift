import SwiftUI
import PencilKit

// MARK: - PencilKit Canvas View (UIViewRepresentable)

struct PencilKitCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    @Binding var tool: PKTool
    @Binding var markupImage: UIImage?
    let imageSize: CGSize
    
    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = tool
        canvasView.delegate = context.coordinator
        canvasView.overrideUserInterfaceStyle = .dark
        return canvasView
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.tool = tool
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: PencilKitCanvasView
        
        init(_ parent: PencilKitCanvasView) {
            self.parent = parent
        }
        
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            // ✅ Bug 5 fix: Do NOT render full-resolution image here.
            // For high-res photos, rendering on every stroke end causes OOM (hundreds of MB per render).
            // The final image is rendered only when the user taps Send, in EditorViewModel.export.
        }
    }
}
