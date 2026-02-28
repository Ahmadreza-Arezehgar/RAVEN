import Foundation
import CoreGraphics

// MARK: - Edit Recipe (Non-destructive edit model)
/// Stores all edits as a recipe that can be applied at export time.
/// Supports undo/redo by snapshotting the entire recipe.
struct EditRecipe: Equatable {
    
    // MARK: - Crop & Transform
    var cropRect: CGRect?            // Normalized 0..1
    var rotation: Double = 0         // Degrees (0, 90, 180, 270)
    var straightenAngle: Double = 0  // −10° to +10°
    var isFlippedH: Bool = false
    var aspectRatio: AspectRatio = .free
    
    // MARK: - Adjustments (range: −1..1, 0 = neutral)
    var exposure: Float = 0
    var brightness: Float = 0
    var contrast: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var saturation: Float = 0
    var warmth: Float = 0
    var tint: Float = 0
    var sharpness: Float = 0
    var vignette: Float = 0
    var fade: Float = 0
    
    // MARK: - Filter
    var filterName: String? = nil
    var filterIntensity: Float = 1.0
    
    // MARK: - Markup (PencilKit data)
    var markupData: Data? = nil
    
    // MARK: - Aspect Ratio Presets
    enum AspectRatio: String, CaseIterable, Identifiable {
        case free       = "Free"
        case square     = "1:1"
        case fourThree  = "4:3"
        case sixteenNine = "16:9"
        case nineSixteen = "9:16"
        
        var id: String { rawValue }
        
        var ratio: CGFloat? {
            switch self {
            case .free:         return nil
            case .square:       return 1.0
            case .fourThree:    return 4.0 / 3.0
            case .sixteenNine:  return 16.0 / 9.0
            case .nineSixteen:  return 9.0 / 16.0
            }
        }
        
        var icon: String {
            switch self {
            case .free:         return "crop"
            case .square:       return "square"
            case .fourThree:    return "rectangle"
            case .sixteenNine:  return "rectangle.landscape.rotate"
            case .nineSixteen:  return "rectangle.portrait"
            }
        }
    }
    
    // MARK: - Helpers
    
    var hasAdjustments: Bool {
        exposure != 0 || brightness != 0 || contrast != 0 ||
        highlights != 0 || shadows != 0 || saturation != 0 ||
        warmth != 0 || tint != 0 || sharpness != 0 ||
        vignette != 0 || fade != 0
    }
    
    var hasCrop: Bool {
        cropRect != nil || rotation != 0 || straightenAngle != 0 || isFlippedH
    }
    
    var hasFilter: Bool {
        filterName != nil
    }
    
    var hasMarkup: Bool {
        markupData != nil
    }
    
    var isEmpty: Bool {
        !hasAdjustments && !hasCrop && !hasFilter && !hasMarkup
    }
    
    /// Reset all adjustments to neutral
    mutating func resetAdjustments() {
        exposure = 0; brightness = 0; contrast = 0
        highlights = 0; shadows = 0; saturation = 0
        warmth = 0; tint = 0; sharpness = 0
        vignette = 0; fade = 0
    }
    
    /// Reset crop to original
    mutating func resetCrop() {
        cropRect = nil; rotation = 0
        straightenAngle = 0; isFlippedH = false
        aspectRatio = .free
    }
}

// MARK: - Export Quality

enum ExportQuality: String, CaseIterable, Identifiable {
    case auto     = "Auto"
    case high     = "High Quality"
    case dataSaver = "Data Saver"
    
    var id: String { rawValue }
    
    var compressionQuality: CGFloat {
        switch self {
        case .auto:      return 0.82
        case .high:      return 0.95
        case .dataSaver: return 0.55
        }
    }
    
    var maxDimension: CGFloat {
        switch self {
        case .auto:      return 2048
        case .high:      return 4096
        case .dataSaver: return 1024
        }
    }
    
    var subtitle: String {
        switch self {
        case .auto:      return "Balanced quality & size"
        case .high:      return "Original resolution"
        case .dataSaver: return "Smaller file, faster send"
        }
    }
    
    var icon: String {
        switch self {
        case .auto:      return "wand.and.stars"
        case .high:      return "sparkles"
        case .dataSaver: return "bolt.fill"
        }
    }
}

// MARK: - Filter Preset

struct FilterPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let ciFilterName: String
    
    static let all: [FilterPreset] = [
        FilterPreset(id: "original", name: "Original", ciFilterName: ""),
        FilterPreset(id: "vivid",    name: "Vivid",    ciFilterName: "CIPhotoEffectChrome"),
        FilterPreset(id: "mono",     name: "Mono",     ciFilterName: "CIPhotoEffectMono"),
        FilterPreset(id: "noir",     name: "Noir",     ciFilterName: "CIPhotoEffectNoir"),
        FilterPreset(id: "dramatic", name: "Dramatic", ciFilterName: "CIPhotoEffectProcess"),
        FilterPreset(id: "chrome",   name: "Chrome",   ciFilterName: "CIPhotoEffectInstant"),
        FilterPreset(id: "fade",     name: "Fade",     ciFilterName: "CIPhotoEffectFade"),
        FilterPreset(id: "tonal",    name: "Tonal",    ciFilterName: "CIPhotoEffectTonal"),
        FilterPreset(id: "transfer", name: "Transfer", ciFilterName: "CIPhotoEffectTransfer"),
        FilterPreset(id: "sepia",    name: "Sepia",    ciFilterName: "CISepiaTone"),
    ]
}
