import SwiftUI

// MARK: - Filters Tool View

struct FiltersToolView: View {
    @Bindable var viewModel: EditorViewModel
    
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var selectedPreset: FilterPreset? = nil
    
    var body: some View {
        VStack(spacing: 12) {
            // Filter thumbnails (horizontal scroll)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FilterPreset.all) { preset in
                        filterThumbnailView(preset)
                    }
                }
                .padding(.horizontal, 16)
            }
            
            // Intensity slider (only when a filter is selected)
            if viewModel.recipe.filterName != nil && !viewModel.recipe.filterName!.isEmpty {
                VStack(spacing: 4) {
                    HStack {
                        Text("Intensity")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text(String(format: "%.0f%%", viewModel.recipe.filterIntensity * 100))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    
                    GlassSlider(
                        value: Binding(
                            get: { Double(viewModel.recipe.filterIntensity) },
                            set: { viewModel.recipe.filterIntensity = Float($0) }
                        ),
                        range: 0...1,
                        onEditingChanged: { editing in
                            if !editing {
                                viewModel.saveUndoState()
                                viewModel.updatePreview()
                            }
                        }
                    )
                }
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .task {
            await generateThumbnails()
        }
    }
    
    // MARK: - Filter Thumbnail View
    
    private func filterThumbnailView(_ preset: FilterPreset) -> some View {
        let isSelected = (preset.ciFilterName.isEmpty && viewModel.recipe.filterName == nil) ||
                         (viewModel.recipe.filterName == preset.ciFilterName)
        
        return Button {
            viewModel.saveUndoState()
            withAnimation(.spring(response: 0.25)) {
                if preset.ciFilterName.isEmpty {
                    viewModel.recipe.filterName = nil
                } else {
                    viewModel.recipe.filterName = preset.ciFilterName
                    viewModel.recipe.filterIntensity = 1.0
                }
            }
            viewModel.updatePreview()
        } label: {
            VStack(spacing: 4) {
                // Thumbnail
                Group {
                    if let thumb = thumbnails[preset.id] {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(.white.opacity(0.05))
                            .overlay {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .tint(.white.opacity(0.3))
                            }
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? .white : .white.opacity(0.1), lineWidth: isSelected ? 2 : 0.5)
                }
                
                // Label
                Text(preset.name)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Generate Thumbnails
    
    private func generateThumbnails() async {
        // ✅ Generate all filter thumbnails concurrently instead of one-by-one
        let presetsToGenerate = FilterPreset.all.filter { thumbnails[$0.id] == nil }
        guard !presetsToGenerate.isEmpty else { return }
        
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for preset in presetsToGenerate {
                group.addTask {
                    let thumb = await self.viewModel.filterThumbnail(for: preset)
                    return (preset.id, thumb)
                }
            }
            
            for await (id, thumb) in group {
                if let thumb {
                    thumbnails[id] = thumb
                }
            }
        }
    }
}
