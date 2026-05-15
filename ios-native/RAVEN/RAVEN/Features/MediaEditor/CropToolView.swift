import SwiftUI

// MARK: - Crop Tool View

struct CropToolView: View {
    @Bindable var viewModel: EditorViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // Aspect ratio presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(EditRecipe.AspectRatio.allCases) { ratio in
                        Button {
                            viewModel.saveUndoState()
                            withAnimation(.spring(response: 0.3)) {
                                viewModel.recipe.aspectRatio = ratio
                            }
                            viewModel.updatePreview()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: ratio.icon)
                                    .font(.system(size: 18))
                                Text(ratio.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .frame(width: 56, height: 52)
                            .foregroundStyle(
                                viewModel.recipe.aspectRatio == ratio
                                    ? Color.white
                                    : Color.white.opacity(0.5)
                            )
                            .background {
                                if viewModel.recipe.aspectRatio == ratio {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.white.opacity(0.12))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            
            // Action buttons (Rotate, Flip)
            HStack(spacing: 24) {
                // Rotate 90°
                ToolActionButton(icon: "rotate.right", label: "Rotate") {
                    viewModel.saveUndoState()
                    viewModel.recipe.rotation = viewModel.recipe.rotation.truncatingRemainder(dividingBy: 360) + 90
                    viewModel.updatePreview()
                }
                
                // Flip Horizontal
                ToolActionButton(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip") {
                    viewModel.saveUndoState()
                    viewModel.recipe.isFlippedH.toggle()
                    viewModel.updatePreview()
                }
                
                // Reset
                ToolActionButton(icon: "arrow.counterclockwise", label: "Reset") {
                    viewModel.saveUndoState()
                    viewModel.recipe.resetCrop()
                    viewModel.updatePreview()
                }
            }
            
            // Straighten slider
            VStack(spacing: 4) {
                HStack {
                    Text("Straighten")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text(String(format: "%.1f°", viewModel.recipe.straightenAngle))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                
                GlassSlider(
                    value: Binding(
                        get: { viewModel.recipe.straightenAngle },
                        set: { newVal in
                            viewModel.recipe.straightenAngle = newVal
                        }
                    ),
                    range: -10...10,
                    onEditingChanged: { editing in
                        if !editing {
                            viewModel.saveUndoState()
                            viewModel.updatePreview()
                        }
                    }
                )
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - Tool Action Button

struct ToolActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    
    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 64, height: 52)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass Slider (Reusable)

struct GlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: ((Bool) -> Void)? = nil
    
    @State private var isDragging = false
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbX = CGFloat(normalized) * width
            let centerX = width / 2
            
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(.white.opacity(0.08))
                    .frame(height: 4)
                
                // Center line (for bipolar sliders)
                if range.lowerBound < 0 {
                    Rectangle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 1, height: 10)
                        .position(x: centerX, y: 2)
                }
                
                // Fill
                let fillWidth = range.lowerBound < 0 ? abs(thumbX - centerX) : thumbX
                let fillX = range.lowerBound < 0 ? min(thumbX, centerX) : 0
                
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(width: fillWidth, height: 4)
                    .offset(x: fillX)
                
                // Thumb
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 18 : 14, height: isDragging ? 18 : 14)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    .position(x: thumbX, y: geo.size.height / 2)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        let pct = min(max(drag.location.x / width, 0), 1)
                        value = range.lowerBound + Double(pct) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
            .animation(.spring(response: 0.2), value: isDragging)
        }
        .frame(height: 24)
    }
}

// MARK: - Haptics fallback (if not imported from main app)
// Uses the app's existing Haptics utility
