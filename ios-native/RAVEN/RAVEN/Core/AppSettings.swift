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
    
    // MARK: - Terminal Accent (RAVEN://TERMINAL v2)
    /// Selectable CRT accent: phosphor green, ion blue, or amber.
    /// Drives every `DS` color at render time — views observing this
    /// setting re-skin instantly via @Observable access tracking.
    enum TerminalAccent: String, CaseIterable {
        case phosphor = "phosphor"
        case ion = "ion"
        case amber = "amber"

        var displayName: String {
            switch self {
            case .phosphor: return "PHOSPHOR GREEN"
            case .ion: return "ION BLUE"
            case .amber: return "AMBER CRT"
            }
        }

        /// Primary neon accent.
        var primary: Color {
            switch self {
            case .phosphor: return Color(red: 0.231, green: 1.0, blue: 0.443)   // #3BFF71
            case .ion: return Color(red: 0.251, green: 0.769, blue: 1.0)        // #40C4FF
            case .amber: return Color(red: 1.0, green: 0.69, blue: 0.0)         // #FFB000
            }
        }

        /// Deep variant for fills / outgoing tints.
        var deep: Color {
            switch self {
            case .phosphor: return Color(red: 0.055, green: 0.573, blue: 0.267) // #0E9244
            case .ion: return Color(red: 0.055, green: 0.361, blue: 0.541)      // #0E5C8A
            case .amber: return Color(red: 0.541, green: 0.369, blue: 0.0)      // #8A5E00
            }
        }

        /// Soft desaturated variant for secondary text/icons.
        var soft: Color {
            switch self {
            case .phosphor: return Color(red: 0.616, green: 0.878, blue: 0.667) // #9DE0AA
            case .ion: return Color(red: 0.616, green: 0.831, blue: 0.941)      // #9DD4F0
            case .amber: return Color(red: 0.878, green: 0.753, blue: 0.537)    // #E0C089
            }
        }

        /// Near-black screen floor, tinted toward the accent hue.
        var ink: Color {
            switch self {
            case .phosphor: return Color(red: 0.012, green: 0.024, blue: 0.016) // #030604
            case .ion: return Color(red: 0.008, green: 0.020, blue: 0.035)      // #020509
            case .amber: return Color(red: 0.024, green: 0.016, blue: 0.008)    // #060402
            }
        }

        /// Elevated panel surface.
        var inkElevated: Color {
            switch self {
            case .phosphor: return Color(red: 0.031, green: 0.055, blue: 0.039) // #080E0A
            case .ion: return Color(red: 0.027, green: 0.047, blue: 0.071)      // #070C12
            case .amber: return Color(red: 0.055, green: 0.043, blue: 0.024)    // #0E0B06
            }
        }

        /// Highest surface (window bars, chips).
        var charcoal: Color {
            switch self {
            case .phosphor: return Color(red: 0.055, green: 0.094, blue: 0.067) // #0E1811
            case .ion: return Color(red: 0.047, green: 0.078, blue: 0.110)      // #0C141C
            case .amber: return Color(red: 0.102, green: 0.078, blue: 0.039)    // #1A140A
            }
        }

        /// Primary reading text — pale tint of the accent.
        var mist: Color {
            switch self {
            case .phosphor: return Color(red: 0.784, green: 0.902, blue: 0.812) // #C8E6CF
            case .ion: return Color(red: 0.769, green: 0.863, blue: 0.918)      // #C4DCEA
            case .amber: return Color(red: 0.918, green: 0.875, blue: 0.784)    // #EADFC8
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
    private var _terminalAccent: TerminalAccent

    var terminalAccent: TerminalAccent {
        get { access(keyPath: \.terminalAccent); return _terminalAccent }
        set {
            withMutation(keyPath: \.terminalAccent) {
                _terminalAccent = newValue
                UserDefaults.standard.set(newValue.rawValue, forKey: "design_terminalAccent")
            }
        }
    }

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

        if let raw = UserDefaults.standard.string(forKey: "design_terminalAccent"),
           let accent = TerminalAccent(rawValue: raw) {
            _terminalAccent = accent
        } else {
            _terminalAccent = .phosphor
        }

        // Clean up any legacy "design_dynamicThemeSource" key from the
        // earlier experimental full-app theme. The dynamic-logo feature
        // that replaced it is settings-free.
        UserDefaults.standard.removeObject(forKey: "design_dynamicThemeSource")
    }
}
