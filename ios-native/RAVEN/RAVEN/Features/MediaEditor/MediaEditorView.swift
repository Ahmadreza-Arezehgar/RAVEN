import SwiftUI
import PencilKit

// MARK: - Media Editor View (Full-screen Container)

struct MediaEditorView: View {
    let image: UIImage
    let onSend: (UIImage) -> Void
    let onCancel: () -> Void
    
    @State private var viewModel: EditorViewModel
    @State private var showExportSheet = false
    @State private var markupCanvasImage: UIImage? = nil
    @State private var pkCanvasView = PKCanvasView()
    @State private var currentPKTool: PKTool = PKInkingTool(.pen, color: .white, width: 3)
    @Environment(\.dismiss) private var dismiss
    
    init(image: UIImage, onSend: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void = {}) {
        self.image = image
        self.onSend = onSend
        self.onCancel = onCancel
        self._viewModel = State(initialValue: EditorViewModel(image: image))
    }
    
    var body: some View {
        // Layout approach: split the topBar so the safe-area spacer
        // above is a SEPARATE Color view (not padding on the topBar
        // itself). This prevents SwiftUI from including the 60pt
        // spacer inside the topBar's hit-test region — earlier
        // attempts where `.padding(.top, 60)` was applied directly to
        // the topBar caused the buttons' hit area to include the
        // empty space above, pushing the actual hit target above the
        // visible buttons.
        ZStack {
            Color(hex: "1C1C1E")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Dynamic Island clearance — pure background, no
                // hit-testable content.
                Color(hex: "1C1C1E").opacity(0.85)
                    .background(.ultraThinMaterial)
                    .frame(height: 60)
                    .allowsHitTesting(false)

                topBar
                    .padding(.bottom, 4)
                    .background(
                        Color(hex: "1C1C1E").opacity(0.85)
                            .background(.ultraThinMaterial)
                    )

                imagePreviewWithOverlays
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 8) {
                    activeToolPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    toolDock
                }
                .padding(.bottom, 24)
                .background(
                    Color(hex: "1C1C1E").opacity(0.85)
                        .background(.ultraThinMaterial)
                )
            }
        }
        .onAppear { viewModel.setup() }
        // Note: status bar is intentionally NOT hidden — `.statusBarHidden()`
        // collapses the top safe-area inset on Dynamic Island devices, which
        // pushed the Send pill up against the camera cutout.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showExportSheet) {
            ExportSettingsSheet { quality, stripLocation in
                exportAndSend(quality: quality, stripLocation: stripLocation)
            }
            // 280 pt clipped the Send button — title + 3 quality rows +
            // privacy toggle + send pill needs ~420 pt to stay tappable.
            .presentationDetents([.height(440)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(24)
            .presentationBackground(.ultraThinMaterial)
        }
    }
    
    // MARK: - Top Bar (Glass Capsule)
    
    private var topBar: some View {
        HStack(spacing: 16) {
            // Close — 44pt hit target per iOS HIG. Visible circle stays
            // 36pt (matches the undo/redo capsule height) but the tappable
            // area extends to 44pt so the button doesn't miss-fire when
            // the user's thumb lands near the edge of the visible circle.
            Button {
                onCancel()
                // ✅ Do NOT call dismiss() here — parent sets showMediaEditor = false
                // which drives the fullScreenCover. Double-dismiss causes stuck state.
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "E5E5EA"))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()
            
            // Undo / Redo
            HStack(spacing: 12) {
                Button {
                    if viewModel.activeTab == .markup {
                        pkCanvasView.undoManager?.undo()
                    } else {
                        withAnimation(.spring(response: 0.25)) { viewModel.undo() }
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: "E5E5EA").opacity(
                            (viewModel.activeTab == .markup ? pkCanvasView.undoManager?.canUndo ?? false : viewModel.canUndo) ? 1.0 : 0.3
                        ))
                }
                
                Button {
                    if viewModel.activeTab == .markup {
                        pkCanvasView.undoManager?.redo()
                    } else {
                        withAnimation(.spring(response: 0.25)) { viewModel.redo() }
                    }
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: "E5E5EA").opacity(
                            (viewModel.activeTab == .markup ? pkCanvasView.undoManager?.canRedo ?? false : viewModel.canRedo) ? 1.0 : 0.3
                        ))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            
            Spacer()
            
            // Done → Export Sheet. Padding raised so the visible capsule
            // hits the 44pt iOS HIG minimum without needing extra hit
            // shapes (which broke clicks via `.fullScreenCover`).
            Button {
                showExportSheet = true
            } label: {
                HStack(spacing: 4) {
                    if viewModel.isExporting {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15))
                    }
                    Text(viewModel.isExporting ? "Exporting…" : "Send")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [Color(hex: "2D7A5F"), Color(hex: "1B5E45")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
            }
            .disabled(viewModel.isExporting || !viewModel.isReady)
            .opacity((viewModel.isExporting || !viewModel.isReady) ? 0.5 : 1.0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
    
    // MARK: - Image Preview with Overlays
    
    private var imagePreviewWithOverlays: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let imageAspect = viewModel.imageSize.width / viewModel.imageSize.height
            let containerAspect = containerSize.width / containerSize.height
            
            let displaySize: CGSize = {
                if imageAspect > containerAspect {
                    // Image is wider — fit by width
                    let w = containerSize.width
                    let h = w / imageAspect
                    return CGSize(width: w, height: h)
                } else {
                    // Image is taller — fit by height
                    let h = containerSize.height
                    let w = h * imageAspect
                    return CGSize(width: w, height: h)
                }
            }()
            
            let imageOffset = CGPoint(
                x: (containerSize.width - displaySize.width) / 2,
                y: (containerSize.height - displaySize.height) / 2
            )
            
            ZStack {
                // Base preview image
                if let preview = viewModel.previewImage {
                    Image(uiImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .position(x: containerSize.width / 2, y: containerSize.height / 2)
                } else if !viewModel.isReady {
                    // ✅ Show tiny placeholder while CIImage initializes (no full decode on main)
                    if let placeholder = viewModel.placeholderImage {
                        Image(uiImage: placeholder)
                            .resizable()
                            .interpolation(.low)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: displaySize.width, height: displaySize.height)
                            .position(x: containerSize.width / 2, y: containerSize.height / 2)
                            .blur(radius: 4)
                            .overlay {
                                ProgressView()
                                    .tint(.white)
                            }
                    } else {
                        ProgressView()
                            .tint(.white)
                            .position(x: containerSize.width / 2, y: containerSize.height / 2)
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                        .position(x: containerSize.width / 2, y: containerSize.height / 2)
                }
                
                // Crop overlay (only when crop tab is active)
                if viewModel.activeTab == .crop {
                    CropOverlayView(
                        viewModel: viewModel,
                        imageSize: displaySize,
                        imageOffset: imageOffset
                    )
                }
                
                // PencilKit canvas overlay — always present to avoid SwiftUI AttributeGraph crash.
                // Hiding via opacity + allowsHitTesting instead of `if` prevents UIView reuse crash.
                PencilKitCanvasView(
                    canvasView: $pkCanvasView,
                    tool: $currentPKTool,
                    markupImage: $markupCanvasImage,
                    imageSize: viewModel.imageSize
                )
                .frame(width: displaySize.width, height: displaySize.height)
                .position(x: containerSize.width / 2, y: containerSize.height / 2)
                .opacity(viewModel.activeTab == .markup ? 1 : 0)
                .allowsHitTesting(viewModel.activeTab == .markup)
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeTab)
    }
    
    // MARK: - Active Tool Panel
    
    @ViewBuilder
    private var activeToolPanel: some View {
        switch viewModel.activeTab {
        case .crop:
            CropToolView(viewModel: viewModel)
        case .adjust:
            AdjustToolView(viewModel: viewModel)
        case .markup:
            MarkupToolView(
                viewModel: viewModel,
                canvasImage: $markupCanvasImage,
                canvasView: $pkCanvasView,
                currentTool: $currentPKTool
            )
        case .filters:
            FiltersToolView(viewModel: viewModel)
        }
    }
    
    // MARK: - Tool Dock (Glass Capsule Tabs)
    
    private var toolDock: some View {
        HStack(spacing: 0) {
            ForEach(EditorViewModel.EditorTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        viewModel.activeTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: viewModel.activeTab == tab ? .semibold : .regular))
                            .foregroundStyle(
                                viewModel.activeTab == tab
                                    ? Color(hex: "4ECBA0")  // Emerald accent
                                    : Color(hex: "E5E5EA").opacity(0.6)
                            )
                        
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(
                                viewModel.activeTab == tab
                                    ? Color(hex: "4ECBA0")
                                    : Color(hex: "E5E5EA").opacity(0.4)
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if viewModel.activeTab == tab {
                            Capsule()
                                .fill(Color(hex: "4ECBA0").opacity(0.12))
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
    
    // MARK: - Export & Send
    
    private func exportAndSend(quality: ExportQuality, stripLocation: Bool) {
        // Bug fix: markupCanvasImage is permanently nil (live rendering disabled for OOM prevention).
        // Render the PencilKit drawing synchronously right before export.
        let drawingImage: UIImage?
        if !pkCanvasView.drawing.bounds.isEmpty {
            drawingImage = pkCanvasView.drawing.image(
                from: pkCanvasView.bounds,
                scale: UIScreen.main.scale
            )
        } else {
            drawingImage = markupCanvasImage
        }
        
        Task {
            // Wait for ExportSettingsSheet to fully dismiss before modifying MediaEditorView state
            try? await Task.sleep(nanoseconds: 300_000_000)
            
            if let exported = await viewModel.export(
                quality: quality,
                stripLocation: stripLocation,
                markupImage: drawingImage
            ) {
                await MainActor.run {
                    onSend(exported)
                }
            } else {
                // Fallback to sending original image if export fails for any reason
                await MainActor.run {
                    onSend(viewModel.originalImage)
                }
            }
        }
    }
}
