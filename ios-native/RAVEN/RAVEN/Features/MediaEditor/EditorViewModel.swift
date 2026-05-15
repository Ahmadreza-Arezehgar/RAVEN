import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import PencilKit

// MARK: - Editor View Model

@Observable
final class EditorViewModel {
    
    // MARK: - State
    private(set) var originalImage: UIImage  // Only accessed for export, not for display
    let imageSize: CGSize  // Cached for layout; avoids touching UIImage on every render
    var placeholderImage: UIImage?  // Tiny thumb for loading state (fast to render)
    var recipe: EditRecipe = EditRecipe()
    var previewImage: UIImage?
    var activeTab: EditorTab = .crop
    var isExporting: Bool = false
    var exportProgress: Double = 0
    var isReady: Bool = false  // True once CIImage is initialized
    
    // Undo/Redo
    private(set) var undoStack: [EditRecipe] = []
    private(set) var redoStack: [EditRecipe] = []
    
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    
    // MARK: - Core Image
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var ciOriginal: CIImage?
    private let previewSize: CGSize
    private var previewTask: Task<Void, Never>?
    
    // MARK: - Init
    
    init(image: UIImage) {
        #if DEBUG
        print("🔵 [EditorVM] init START — size: \(image.size)")
        #endif
        self.originalImage = image
        self.imageSize = image.size  // ✅ No decode — UIImage stores size in metadata
        self.previewImage = nil
        self.ciOriginal = nil
        self.placeholderImage = nil  // Generated async below
        
        // Calculate preview size (cap at 1024 for performance)
        let maxPreview: CGFloat = 1024
        let scale = min(maxPreview / image.size.width, maxPreview / image.size.height, 1.0)
        self.previewSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        
        #if DEBUG
        print("🔵 [EditorVM] init END — call setup() via .onAppear")
        #endif
        // FIX: Heavy processing moved to setup() — SwiftUI may re-invoke init
        // dozens of times per second, spawning duplicate background work.
    }
    
    // MARK: - Setup (call from .onAppear — runs exactly once)
    
    func setup() {
        guard !isReady, placeholderImage == nil else { return }  // Idempotent guard
        
        let image = originalImage
        
        Task.detached(priority: .userInitiated) { [weak self] in
            #if DEBUG
            print("🟢 [EditorVM] Background task START")
            #endif
            
            // 1. Generate tiny placeholder first (fast, ~5ms)
            let phMaxDim: CGFloat = 64
            let phScale = min(phMaxDim / image.size.width, phMaxDim / image.size.height, 1.0)
            let phSize = CGSize(width: image.size.width * phScale, height: image.size.height * phScale)
            let placeholder = UIGraphicsImageRenderer(size: phSize).image { _ in
                image.draw(in: CGRect(origin: .zero, size: phSize))
            }
            #if DEBUG
            print("🟢 [EditorVM] Placeholder generated")
            #endif
            
            // Publish placeholder immediately so UI shows something
            await MainActor.run {
                self?.placeholderImage = placeholder
            }
            
            // 2. Create downscaled preview
            let preview = image.downscaled(maxDimension: 1024)
            #if DEBUG
            print("🟢 [EditorVM] Preview downscaled")
            #endif
            
            // 3. Create CIImage for editing pipeline
            let ci: CIImage?
            if let cgImage = image.cgImage {
                ci = CIImage(cgImage: cgImage)
            } else {
                ci = CIImage(image: image)
            }
            #if DEBUG
            print("🟢 [EditorVM] CIImage created")
            #endif
            
            await MainActor.run {
                self?.previewImage = preview
                self?.ciOriginal = ci
                self?.isReady = true
                self?.updatePreview()
                #if DEBUG
                print("🟢 [EditorVM] Ready — UI updated")
                #endif
            }
        }
    }
    
    // MARK: - Editor Tabs
    
    enum EditorTab: String, CaseIterable, Identifiable {
        case crop    = "Crop"
        case adjust  = "Adjust"
        case markup  = "Markup"
        case filters = "Filters"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .crop:    return "crop.rotate"
            case .adjust:  return "slider.horizontal.3"
            case .markup:  return "pencil.tip.crop.circle"
            case .filters: return "camera.filters"
            }
        }
    }
    
    // MARK: - Undo / Redo
    
    func saveUndoState() {
        undoStack.append(recipe)
        redoStack.removeAll()
    }
    
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = previous
        updatePreview()
    }
    
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
        updatePreview()
    }
    
    // MARK: - Preview Pipeline
    
    func updatePreview() {
        guard let ciInput = ciOriginal else {
            // ciOriginal not ready yet — will be called again once isReady is set
            return
        }
        
        // ✅ Cancel previous render to avoid queuing stale work during rapid slider drags
        previewTask?.cancel()
        
        let currentRecipe = recipe
        let ctx = context
        let size = previewSize
        previewTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            let output = Self.applyRecipe(currentRecipe, to: ciInput, context: ctx, outputSize: size)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.previewImage = output
            }
        }
    }
    
    // MARK: - Core Image Pipeline (static for background use)
    
    static func applyRecipe(_ recipe: EditRecipe, to ciInput: CIImage, context: CIContext, outputSize: CGSize?) -> UIImage? {
        var image = ciInput
        
        // 1. Crop (normalized rect)
        if let crop = recipe.cropRect {
            let extent = image.extent
            let cropPixels = CGRect(
                x: crop.origin.x * extent.width,
                y: crop.origin.y * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            )
            image = image.cropped(to: cropPixels)
                .transformed(by: CGAffineTransform(translationX: -cropPixels.origin.x, y: -cropPixels.origin.y))
        }
        
        // 2. Rotation
        if recipe.rotation != 0 {
            let radians = recipe.rotation * .pi / 180
            image = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
        }
        
        // 3. Straighten
        if recipe.straightenAngle != 0 {
            let radians = recipe.straightenAngle * .pi / 180
            image = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(radians)))
        }
        
        // 4. Flip
        if recipe.isFlippedH {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -image.extent.width, y: 0))
        }
        
        // 5. Exposure
        if recipe.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = recipe.exposure * 3  // Scale: -3..+3 EV
            if let out = filter.outputImage { image = out }
        }
        
        // 6. Brightness + Contrast + Saturation
        if recipe.brightness != 0 || recipe.contrast != 0 || recipe.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.brightness = recipe.brightness * 0.3     // Scale: −0.3..+0.3
            filter.contrast = 1.0 + recipe.contrast * 0.5   // Scale: 0.5..1.5
            filter.saturation = 1.0 + recipe.saturation      // Scale: 0..2
            if let out = filter.outputImage { image = out }
        }
        
        // 7. Highlights + Shadows
        if recipe.highlights != 0 || recipe.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = 1.0 - recipe.highlights  // Inverted: reduce highlights
            filter.shadowAmount = recipe.shadows * 0.5 + 0.5  // Scale: 0..1
            if let out = filter.outputImage { image = out }
        }
        
        // 8. Warmth (Temperature)
        if recipe.warmth != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            let neutral = CIVector(x: 6500, y: 0)
            let target = CIVector(x: 6500 + CGFloat(recipe.warmth) * 2000, y: 0)
            filter.neutral = neutral
            filter.targetNeutral = target
            if let out = filter.outputImage { image = out }
        }
        
        // 9. Sharpness
        if recipe.sharpness != 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = recipe.sharpness * 2  // Scale: 0..2
            if let out = filter.outputImage { image = out }
        }
        
        // 10. Vignette
        if recipe.vignette != 0 {
            let filter = CIFilter.vignette()
            filter.inputImage = image
            filter.intensity = recipe.vignette * 2  // Scale: 0..2
            filter.radius = 2
            if let out = filter.outputImage { image = out }
        }
        
        // 11. Tint
        if recipe.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            let neutral = CIVector(x: 6500, y: 0)
            let target = CIVector(x: 6500, y: CGFloat(recipe.tint) * 100)
            filter.neutral = neutral
            filter.targetNeutral = target
            if let out = filter.outputImage { image = out }
        }
        
        // 12. Fade (reduce contrast + lighten shadows)
        if recipe.fade != 0 {
            let fadeAmount = recipe.fade * 0.3  // Subtle effect
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.brightness = fadeAmount * 0.1
            filter.contrast = 1.0 - fadeAmount
            filter.saturation = 1.0 - fadeAmount * 0.3
            if let out = filter.outputImage { image = out }
        }
        
        // 11. Photo filter
        if let filterName = recipe.filterName, !filterName.isEmpty {
            if let filter = CIFilter(name: filterName) {
                filter.setValue(image, forKey: kCIInputImageKey)
                if filter.inputKeys.contains(kCIInputIntensityKey) {
                    filter.setValue(recipe.filterIntensity, forKey: kCIInputIntensityKey)
                }
                if let out = filter.outputImage { image = out }
            }
        }
        
        // Render to UIImage
        let extent = image.extent
        
        // Optionally downscale for preview
        var renderImage = image
        if let targetSize = outputSize {
            let scale = min(targetSize.width / extent.width, targetSize.height / extent.height, 1.0)
            if scale < 1.0 {
                renderImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        
        let renderExtent = renderImage.extent
        guard let cgImage = context.createCGImage(renderImage, from: renderExtent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - Export (Full Resolution)
    
    func export(quality: ExportQuality, stripLocation: Bool = true, markupImage: UIImage? = nil) async -> UIImage? {
        // Fallback to original image if CIImage failed to initialize
        guard let ciInput = ciOriginal else { 
            #if DEBUG
            print("⚠️ [EditorVM] ciOriginal is nil, falling back to originalImage")
            #endif
            return originalImage 
        }
        
        await MainActor.run { isExporting = true }
        defer { Task { @MainActor in isExporting = false } }
        
        // ✅ Run full-resolution pipeline on background thread to prevent UI freeze
        let currentRecipe = recipe
        let currentContext = context
        let markup = markupImage
        let maxDim = quality.maxDimension
        
        return await Task.detached(priority: .userInitiated) {
            // ✅ Bug 4 fix: Downscale DURING filter pipeline to prevent OOM on 48MP ProRAW images.
            // Previously outputSize was nil, causing CoreImage to render at full resolution
            // (8064x6048 = 1.5GB+ RAM) before resizing — triggering iOS OOM kill.
            let exportSize = CGSize(width: maxDim, height: maxDim)
            guard var result = Self.applyRecipe(currentRecipe, to: ciInput, context: currentContext, outputSize: exportSize) else {
                return nil as UIImage?
            }
            
            // 2. Composite markup drawing
            if let markup {
                let size = result.size
                let renderer = UIGraphicsImageRenderer(size: size)
                result = renderer.image { _ in
                    result.draw(in: CGRect(origin: .zero, size: size))
                    markup.draw(in: CGRect(origin: .zero, size: size))
                }
            }
            
            return result
        }.value
    }

    
    // MARK: - Generate Filter Thumbnail
    
    func filterThumbnail(for preset: FilterPreset) async -> UIImage? {
        guard let ciInput = ciOriginal else { return nil }
        
        // ✅ Run CIContext rendering off the cooperative pool to prevent thread contention
        let ctx = context
        return await Task.detached(priority: .utility) {
            let thumbSize = CGSize(width: 80, height: 80)
            
            if preset.ciFilterName.isEmpty {
                return Self.applyRecipe(EditRecipe(), to: ciInput, context: ctx, outputSize: thumbSize)
            }
            
            var tempRecipe = EditRecipe()
            tempRecipe.filterName = preset.ciFilterName
            tempRecipe.filterIntensity = 1.0
            return Self.applyRecipe(tempRecipe, to: ciInput, context: ctx, outputSize: thumbSize)
        }.value
    }
}
