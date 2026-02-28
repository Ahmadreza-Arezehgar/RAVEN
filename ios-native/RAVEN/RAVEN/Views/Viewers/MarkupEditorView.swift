import SwiftUI
import PencilKit

// MARK: - Markup Editor View

struct MarkupEditorView: View {
    let image: UIImage
    var onDone: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    @State private var canvasView = PKCanvasView()
    @State private var toolPicker = PKToolPicker()
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                MarkupCanvasContainer(
                    image: image,
                    canvasView: $canvasView,
                    toolPicker: $toolPicker
                )
            }
            .navigationTitle("Markup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel?()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let editedImage = renderEditedImage()
                        onDone?(editedImage)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
    
    private func renderEditedImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { context in
            // Draw original image
            image.draw(at: .zero)
            
            // Scale canvas drawing to match image size
            let scale = image.size.width / canvasView.bounds.width
            context.cgContext.scaleBy(x: scale, y: scale)
            
            // Draw canvas
            canvasView.drawing.image(from: canvasView.bounds, scale: UIScreen.main.scale)
                .draw(in: canvasView.bounds)
        }
    }
}

// MARK: - Canvas Container (UIViewRepresentable)

struct MarkupCanvasContainer: UIViewRepresentable {
    let image: UIImage
    @Binding var canvasView: PKCanvasView
    @Binding var toolPicker: PKToolPicker
    
    func makeUIView(context: Context) -> UIView {
        let containerView = UIView()
        containerView.backgroundColor = .black
        
        // Image view
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(imageView)
        
        // Canvas view
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.drawingPolicy = .anyInput
        containerView.addSubview(canvasView)
        
        // Constraints
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            
            canvasView.topAnchor.constraint(equalTo: containerView.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])
        
        // Tool picker
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()
        
        return containerView
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

#Preview {
    MarkupEditorView(image: UIImage(systemName: "photo")!)
}
