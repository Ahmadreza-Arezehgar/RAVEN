import SwiftUI

// MARK: - App Settings Manager
/// Central settings manager using @Observable for reactive updates across the app
/// Handles design settings: text size, message corners, appearance mode
@Observable
final class AppSettings {
    static let shared = AppSettings()
    
    // MARK: - Appearance Mode
    enum AppearanceMode: String, CaseIterable {
        case system = "system"
        case light = "light"
        case dark = "dark"
        
        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        
        var icon: String {
            switch self {
            case .system: return "iphone"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
            }
        }
        
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }
    
    // MARK: - Text Size
    enum TextSize: String, CaseIterable {
        case small = "small"
        case medium = "medium"
        case large = "large"
        case extraLarge = "extraLarge"
        
        var displayName: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            case .extraLarge: return "Extra Large"
            }
        }
        
        var scaleFactor: CGFloat {
            switch self {
            case .small: return 0.85
            case .medium: return 1.0
            case .large: return 1.15
            case .extraLarge: return 1.3
            }
        }
        
        /// Maps to iOS DynamicTypeSize for global font scaling
        var dynamicTypeSize: DynamicTypeSize {
            switch self {
            case .small: return .small
            case .medium: return .medium
            case .large: return .large
            case .extraLarge: return .xLarge
            }
        }
    }
    
    // MARK: - Message Corner Style
    enum MessageCornerStyle: String, CaseIterable {
        case rounded = "rounded"
        case soft = "soft"
        case bubble = "bubble"
        
        var displayName: String {
            switch self {
            case .rounded: return "Rounded"
            case .soft: return "Soft"
            case .bubble: return "Bubble"
            }
        }
        
        var radius: CGFloat {
            switch self {
            case .rounded: return 8
            case .soft: return 16
            case .bubble: return 24
            }
        }
    }
    
    // MARK: - Stored Properties (with backing for @Observable)
    
    /// Backing storage - these trigger @Observable updates
    private var _textSize: TextSize
    private var _messageCornerStyle: MessageCornerStyle  
    private var _appearanceMode: AppearanceMode
    
    var textSize: TextSize {
        get { access(keyPath: \.textSize); return _textSize }
        set {
            withMutation(keyPath: \.textSize) {
                _textSize = newValue
                UserDefaults.standard.set(newValue.rawValue, forKey: "design_textSize")
            }
        }
    }
    
    var messageCornerStyle: MessageCornerStyle {
        get { access(keyPath: \.messageCornerStyle); return _messageCornerStyle }
        set {
            withMutation(keyPath: \.messageCornerStyle) {
                _messageCornerStyle = newValue
                UserDefaults.standard.set(newValue.rawValue, forKey: "design_messageCorners")
            }
        }
    }
    
    var appearanceMode: AppearanceMode {
        get { access(keyPath: \.appearanceMode); return _appearanceMode }
        set {
            withMutation(keyPath: \.appearanceMode) {
                _appearanceMode = newValue
                UserDefaults.standard.set(newValue.rawValue, forKey: "design_appearanceMode")
            }
        }
    }
    
    // MARK: - Computed Properties
    
    var preferredColorScheme: ColorScheme? {
        appearanceMode.colorScheme
    }
    
    var messageCornerRadius: CGFloat {
        messageCornerStyle.radius
    }
    
    var textScaleFactor: CGFloat {
        textSize.scaleFactor
    }
    
    /// Global font scaling for entire app
    var dynamicTypeSize: DynamicTypeSize {
        textSize.dynamicTypeSize
    }
    
    // MARK: - Init
    private init() {
        // Load from UserDefaults
        if let raw = UserDefaults.standard.string(forKey: "design_textSize"),
           let size = TextSize(rawValue: raw) {
            _textSize = size
        } else {
            _textSize = .medium
        }
        
        if let raw = UserDefaults.standard.string(forKey: "design_messageCorners"),
           let style = MessageCornerStyle(rawValue: raw) {
            _messageCornerStyle = style
        } else {
            _messageCornerStyle = .soft
        }
        
        if let raw = UserDefaults.standard.string(forKey: "design_appearanceMode"),
           let mode = AppearanceMode(rawValue: raw) {
            _appearanceMode = mode
        } else {
            _appearanceMode = .system
        }
    }
}
