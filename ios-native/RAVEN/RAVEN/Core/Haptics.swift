import UIKit

// MARK: - Haptic Feedback Helper
/// Respects the vibration setting from Notifications preferences
enum Haptics {
    
    /// Check if vibration is enabled in settings
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "vibrationEnabled") as? Bool ?? true
    }
    
    // 🚨 PERF FIX: All haptics MUST be pushed to Main Thread to avoid deadlocks
    static func light() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
    
    static func medium() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }
    
    static func heavy() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    }
    
    static func soft() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    }
    
    static func rigid() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    }
    
    static func success() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
    
    static func warning() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }
    
    static func error() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    }
    
    static func selection() {
        guard isEnabled else { return }
        DispatchQueue.main.async { UISelectionFeedbackGenerator().selectionChanged() }
    }
}
