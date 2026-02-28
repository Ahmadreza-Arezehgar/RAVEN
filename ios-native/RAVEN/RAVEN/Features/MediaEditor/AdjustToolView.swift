import SwiftUI

// MARK: - Adjust Tool View (Core Image Sliders)

struct AdjustToolView: View {
    @Bindable var viewModel: EditorViewModel
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                adjustmentRow(label: "Exposure", icon: "sun.max", value: floatBinding(\.exposure))
                adjustmentRow(label: "Brightness", icon: "sun.min", value: floatBinding(\.brightness))
                adjustmentRow(label: "Contrast", icon: "circle.lefthalf.filled", value: floatBinding(\.contrast))
                adjustmentRow(label: "Highlights", icon: "sun.max.trianglebadge.exclamationmark", value: floatBinding(\.highlights))
                adjustmentRow(label: "Shadows", icon: "moon.fill", value: floatBinding(\.shadows))
                adjustmentRow(label: "Saturation", icon: "drop.fill", value: floatBinding(\.saturation))
                adjustmentRow(label: "Warmth", icon: "thermometer.medium", value: floatBinding(\.warmth))
                adjustmentRow(label: "Tint", icon: "paintpalette", value: floatBinding(\.tint))
                adjustmentRow(label: "Sharpness", icon: "triangle", value: floatBinding(\.sharpness))
                adjustmentRow(label: "Vignette", icon: "circle.dashed", value: floatBinding(\.vignette))
                adjustmentRow(label: "Fade", icon: "aqi.medium", value: floatBinding(\.fade))
                
                // Reset all
                Button {
                    viewModel.saveUndoState()
                    viewModel.recipe.resetAdjustments()
                    viewModel.updatePreview()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset All")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
    }
    
    // MARK: - Adjustment Row
    
    private func adjustmentRow(label: String, icon: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 20)
                
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                
                Spacer()
                
                Text(String(format: "%+.0f", value.wrappedValue * 100))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 36, alignment: .trailing)
            }
            
            GlassSlider(
                value: value,
                range: -1...1,
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
    
    // MARK: - Float Binding Helper
    
    private func floatBinding(_ keyPath: WritableKeyPath<EditRecipe, Float>) -> Binding<Double> {
        Binding<Double>(
            get: { Double(viewModel.recipe[keyPath: keyPath]) },
            set: { viewModel.recipe[keyPath: keyPath] = Float($0) }
        )
    }
}
