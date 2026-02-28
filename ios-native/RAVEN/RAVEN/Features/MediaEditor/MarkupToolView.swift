import SwiftUI
import PencilKit

// MARK: - Markup Tool View (PencilKit Controls)

struct MarkupToolView: View {
    @Bindable var viewModel: EditorViewModel
    @Binding var canvasImage: UIImage?
    @Binding var canvasView: PKCanvasView
    @Binding var currentTool: PKTool
    
    @State private var selectedTool: MarkupTool = .pen
    @State private var selectedColor: Color = .white
    @State private var strokeWidth: CGFloat = 3
    
    enum MarkupTool: String, CaseIterable, Identifiable {
        case pen        = "Pen"
        case marker     = "Marker"
        case highlighter = "Highlighter"
        case eraser     = "Eraser"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .pen:         return "pencil.tip"
            case .marker:      return "paintbrush.pointed"
            case .highlighter: return "highlighter"
            case .eraser:      return "eraser"
            }
        }
    }
    
    private let quickColors: [Color] = [.white, .red, .yellow, .green, .blue, .orange, .purple]
    
    var body: some View {
        VStack(spacing: 12) {
            // Tool selector
            HStack(spacing: 8) {
                ForEach(MarkupTool.allCases) { tool in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            selectedTool = tool
                            applyToolToPencilKit()
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 17, weight: selectedTool == tool ? .semibold : .regular))
                            Text(tool.rawValue)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(
                            selectedTool == tool ? .white : .white.opacity(0.5)
                        )
                        .frame(width: 58, height: 44)
                        .background {
                            if selectedTool == tool {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.white.opacity(0.12))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Color picker row
            if selectedTool != .eraser {
                HStack(spacing: 10) {
                    // Quick colors
                    ForEach(quickColors, id: \.self) { color in
                        Button {
                            selectedColor = color
                            applyToolToPencilKit()
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if selectedColor == color {
                                        Circle()
                                            .strokeBorder(.white, lineWidth: 2)
                                            .frame(width: 28, height: 28)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // Full color picker
                    ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 28, height: 28)
                        .onChange(of: selectedColor) { _, _ in
                            applyToolToPencilKit()
                        }
                }
                .padding(.horizontal, 16)
            }
            
            // Thickness slider
            HStack(spacing: 8) {
                Circle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 4, height: 4)
                
                GlassSlider(
                    value: Binding(
                        get: { Double(strokeWidth) },
                        set: { strokeWidth = CGFloat($0) }
                    ),
                    range: 1...20,
                    onEditingChanged: { editing in
                        if !editing {
                            applyToolToPencilKit()
                        }
                    }
                )
                
                Circle()
                    .fill(.white.opacity(0.4))
                    .frame(width: 12, height: 12)
            }
            .padding(.horizontal, 16)
            
            // Clear / Undo actions
            HStack {
                Button {
                    canvasView.drawing = PKDrawing()
                    canvasImage = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Clear")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                }
                
                Spacer()
                
                Text("Draw on the image above")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .onAppear {
            applyToolToPencilKit()
        }
    }
    
    // MARK: - Apply Tool to PencilKit
    
    private func applyToolToPencilKit() {
        let uiColor = UIColor(selectedColor)
        
        let tool: PKTool
        switch selectedTool {
        case .pen:
            tool = PKInkingTool(.pen, color: uiColor, width: strokeWidth)
        case .marker:
            tool = PKInkingTool(.marker, color: uiColor, width: strokeWidth * 2)
        case .highlighter:
            tool = PKInkingTool(.marker, color: uiColor.withAlphaComponent(0.3), width: strokeWidth * 3)
        case .eraser:
            tool = PKEraserTool(.bitmap)
        }
        
        currentTool = tool
    }
}
