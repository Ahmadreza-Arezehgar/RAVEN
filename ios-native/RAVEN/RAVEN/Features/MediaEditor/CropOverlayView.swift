import SwiftUI

// MARK: - Crop Overlay View (Interactive crop rectangle with handles)

struct CropOverlayView: View {
    @Bindable var viewModel: EditorViewModel
    let imageSize: CGSize      // Size of the displayed image in view coordinates
    let imageOffset: CGPoint   // Offset of the image within its container
    
    @State private var cropRect: CGRect = .zero  // In view coordinates
    @State private var dragHandle: CropHandle? = nil
    @State private var dragStart: CGPoint = .zero
    @State private var initialRect: CGRect = .zero
    @State private var isInitialized = false
    
    enum CropHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case move
    }
    
    var body: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            
            ZStack {
                // Dim outside crop area
                dimOverlay
                
                // Crop rectangle border + grid
                cropBorder
                
                // Corner handles
                cornerHandles
                
                // Edge handles
                edgeHandles
            }
            .onAppear {
                if !isInitialized {
                    initializeCropRect(in: containerSize)
                    isInitialized = true
                }
            }
            .onChange(of: viewModel.recipe.aspectRatio) { _, newRatio in
                constrainToAspectRatio(newRatio, in: containerSize)
            }
            .onChange(of: viewModel.recipe.rotation) { _, _ in
                // Reset crop on rotation
                resetCropRect(in: containerSize)
            }
        }
    }
    
    // MARK: - Dim Overlay
    
    private var dimOverlay: some View {
        Canvas { context, size in
            // Fill entire area with dim
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.55))
            )
            // Cut out the crop rect
            context.blendMode = .destinationOut
            context.fill(
                Path(cropRect),
                with: .color(.white)
            )
        }
        .allowsHitTesting(false)
        .compositingGroup()
    }
    
    // MARK: - Crop Border + Grid
    
    private var cropBorder: some View {
        ZStack {
            // Border
            Rectangle()
                .strokeBorder(.white, lineWidth: 1)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
            
            // Rule of thirds grid
            let thirdW = cropRect.width / 3
            let thirdH = cropRect.height / 3
            
            // Vertical lines
            ForEach(1..<3, id: \.self) { i in
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 0.5, height: cropRect.height)
                    .position(x: cropRect.minX + thirdW * CGFloat(i), y: cropRect.midY)
            }
            
            // Horizontal lines
            ForEach(1..<3, id: \.self) { i in
                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: cropRect.width, height: 0.5)
                    .position(x: cropRect.midX, y: cropRect.minY + thirdH * CGFloat(i))
            }
        }
        .allowsHitTesting(false)
    }
    
    // MARK: - Corner Handles
    
    private var cornerHandles: some View {
        ZStack {
            handleView(position: CGPoint(x: cropRect.minX, y: cropRect.minY), handle: .topLeft)
            handleView(position: CGPoint(x: cropRect.maxX, y: cropRect.minY), handle: .topRight)
            handleView(position: CGPoint(x: cropRect.minX, y: cropRect.maxY), handle: .bottomLeft)
            handleView(position: CGPoint(x: cropRect.maxX, y: cropRect.maxY), handle: .bottomRight)
        }
    }
    
    // MARK: - Edge Handles
    
    private var edgeHandles: some View {
        ZStack {
            // Move handle (center of crop)
            Color.clear
                .frame(width: max(cropRect.width - 60, 20), height: max(cropRect.height - 60, 20))
                .contentShape(Rectangle())
                .position(x: cropRect.midX, y: cropRect.midY)
                .gesture(dragGesture(for: .move))
        }
    }
    
    // MARK: - Handle View
    
    private func handleView(position: CGPoint, handle: CropHandle) -> some View {
        let cornerLength: CGFloat = 20
        let cornerWidth: CGFloat = 3
        
        return ZStack {
            // L-shaped corner indicator
            Group {
                let isLeft = (handle == .topLeft || handle == .bottomLeft)
                let isTop = (handle == .topLeft || handle == .topRight)
                
                // Horizontal arm
                Rectangle()
                    .fill(.white)
                    .frame(width: cornerLength, height: cornerWidth)
                    .offset(x: isLeft ? cornerLength / 2 : -cornerLength / 2, y: 0)
                
                // Vertical arm
                Rectangle()
                    .fill(.white)
                    .frame(width: cornerWidth, height: cornerLength)
                    .offset(x: 0, y: isTop ? cornerLength / 2 : -cornerLength / 2)
            }
        }
        .position(position)
        .contentShape(Circle().scale(2.5))
        .gesture(dragGesture(for: handle))
    }
    
    // MARK: - Drag Gesture
    
    private func dragGesture(for handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragHandle == nil {
                    dragHandle = handle
                    dragStart = value.startLocation
                    initialRect = cropRect
                }
                
                let delta = CGSize(
                    width: value.location.x - dragStart.x,
                    height: value.location.y - dragStart.y
                )
                
                updateCrop(handle: handle, delta: delta)
            }
            .onEnded { _ in
                dragHandle = nil
                commitCropRect()
            }
    }
    
    // MARK: - Update Crop
    
    private func updateCrop(handle: CropHandle, delta: CGSize) {
        let minSize: CGFloat = 40
        var newRect = initialRect
        
        switch handle {
        case .topLeft:
            newRect.origin.x += delta.width
            newRect.origin.y += delta.height
            newRect.size.width -= delta.width
            newRect.size.height -= delta.height
        case .topRight:
            newRect.size.width += delta.width
            newRect.origin.y += delta.height
            newRect.size.height -= delta.height
        case .bottomLeft:
            newRect.origin.x += delta.width
            newRect.size.width -= delta.width
            newRect.size.height += delta.height
        case .bottomRight:
            newRect.size.width += delta.width
            newRect.size.height += delta.height
        case .top:
            newRect.origin.y += delta.height
            newRect.size.height -= delta.height
        case .bottom:
            newRect.size.height += delta.height
        case .left:
            newRect.origin.x += delta.width
            newRect.size.width -= delta.width
        case .right:
            newRect.size.width += delta.width
        case .move:
            newRect.origin.x += delta.width
            newRect.origin.y += delta.height
        }
        
        // Enforce minimum size
        if newRect.width < minSize { newRect.size.width = minSize }
        if newRect.height < minSize { newRect.size.height = minSize }
        
        // Enforce aspect ratio
        if let ratio = viewModel.recipe.aspectRatio.ratio, handle != .move {
            let currentRatio = newRect.width / newRect.height
            if currentRatio > ratio {
                newRect.size.width = newRect.height * ratio
            } else {
                newRect.size.height = newRect.width / ratio
            }
        }
        
        // Clamp to image bounds
        let bounds = CGRect(origin: imageOffset, size: imageSize)
        if handle == .move {
            newRect.origin.x = max(bounds.minX, min(newRect.origin.x, bounds.maxX - newRect.width))
            newRect.origin.y = max(bounds.minY, min(newRect.origin.y, bounds.maxY - newRect.height))
        } else {
            newRect = newRect.intersection(bounds)
        }
        
        cropRect = newRect
    }
    
    // MARK: - Commit Crop to Recipe
    
    private func commitCropRect() {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        
        // Convert view coords to normalized 0..1
        let normalizedX = (cropRect.minX - imageOffset.x) / imageSize.width
        let normalizedY = (cropRect.minY - imageOffset.y) / imageSize.height
        let normalizedW = cropRect.width / imageSize.width
        let normalizedH = cropRect.height / imageSize.height
        
        let normalized = CGRect(
            x: max(0, min(1, normalizedX)),
            y: max(0, min(1, normalizedY)),
            width: max(0.01, min(1, normalizedW)),
            height: max(0.01, min(1, normalizedH))
        )
        
        // Don't save if it's essentially the full image
        if normalized.origin.x < 0.01 && normalized.origin.y < 0.01 &&
           normalized.width > 0.98 && normalized.height > 0.98 {
            viewModel.recipe.cropRect = nil
        } else {
            viewModel.recipe.cropRect = normalized
        }
        
        viewModel.updatePreview()
    }
    
    // MARK: - Initialize / Reset
    
    private func initializeCropRect(in containerSize: CGSize) {
        if let existing = viewModel.recipe.cropRect {
            // Restore from recipe
            cropRect = CGRect(
                x: imageOffset.x + existing.origin.x * imageSize.width,
                y: imageOffset.y + existing.origin.y * imageSize.height,
                width: existing.width * imageSize.width,
                height: existing.height * imageSize.height
            )
        } else {
            // Full image
            cropRect = CGRect(origin: imageOffset, size: imageSize)
            constrainToAspectRatio(viewModel.recipe.aspectRatio, in: containerSize)
        }
    }
    
    private func resetCropRect(in containerSize: CGSize) {
        cropRect = CGRect(origin: imageOffset, size: imageSize)
        viewModel.recipe.cropRect = nil
        constrainToAspectRatio(viewModel.recipe.aspectRatio, in: containerSize)
    }
    
    func constrainToAspectRatio(_ ratio: EditRecipe.AspectRatio, in containerSize: CGSize) {
        guard let r = ratio.ratio else {
            // Free — expand to full image
            if viewModel.recipe.cropRect == nil {
                cropRect = CGRect(origin: imageOffset, size: imageSize)
            }
            return
        }
        
        let imgRect = CGRect(origin: imageOffset, size: imageSize)
        var newW = imgRect.width
        var newH = newW / r
        
        if newH > imgRect.height {
            newH = imgRect.height
            newW = newH * r
        }
        
        cropRect = CGRect(
            x: imgRect.midX - newW / 2,
            y: imgRect.midY - newH / 2,
            width: newW,
            height: newH
        )
        
        commitCropRect()
    }
}
