// RAVEN - Extensions & Utilities
// Converted from Flutter to Swift

import SwiftUI
import Foundation

// MARK: - Date Extensions
extension Date {
    /// Relative time string (e.g., "2m ago", "Yesterday")
    var timeAgo: String {
        let now = Date()
        let diff = now.timeIntervalSince(self)
        
        if diff < 60 { return "Just now" }
        if diff < 3600 { return "\(Int(diff/60))m ago" }
        if diff < 86400 { return "\(Int(diff/3600))h ago" }
        if diff < 172800 { return "Yesterday" }
        if diff < 604800 { return "\(Int(diff/86400))d ago" }
        
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(self, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: self)
    }
    
    /// Chat timestamp (e.g., "2:30 PM" or "Dec 5")
    var chatTimestamp: String {
        let now = Date()
        let formatter = DateFormatter()
        
        if Calendar.current.isDateInToday(self) {
            formatter.dateFormat = "h:mm a"
        } else if Calendar.current.isDateInYesterday(self) {
            return "Yesterday"
        } else if Calendar.current.isDate(self, equalTo: now, toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = "MMM d"
        }
        
        return formatter.string(from: self)
    }
    
    /// Message time only (e.g., "2:30 PM")
    var messageTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: self)
    }
}

// MARK: - String Extensions
extension String {
    /// Validate email format
    var isValidEmail: Bool {
        let regex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        return NSPredicate(format: "SELF MATCHES %@", regex).evaluate(with: self)
    }
    
    /// Validate username (alphanumeric, underscores, 3-20 chars)
    var isValidUsername: Bool {
        let regex = "^[a-zA-Z0-9_]{3,20}$"
        return NSPredicate(format: "SELF MATCHES %@", regex).evaluate(with: self)
    }
    
    /// Get initials from name
    var initials: String {
        let parts = self.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first }.map { String($0) }.joined().uppercased()
    }
    
    /// Truncate with ellipsis
    func truncated(to length: Int) -> String {
        count <= length ? self : String(prefix(length)) + "..."
    }
}

// MARK: - Int Extensions
extension Int {
    /// Format as file size (e.g., "1.5 MB")
    var fileSizeString: String {
        let kb = Double(self) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        let gb = mb / 1024
        return String(format: "%.1f GB", gb)
    }
    
    /// Format as duration (e.g., "1:30")
    var durationString: String {
        let minutes = self / 60
        let seconds = self % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Format with K/M suffix
    var abbreviated: String {
        if self < 1000 { return "\(self)" }
        if self < 1_000_000 { return String(format: "%.1fK", Double(self)/1000) }
        return String(format: "%.1fM", Double(self)/1_000_000)
    }
}

// MARK: - Color Extensions
extension Color {
    // RAVEN Brand Colors
    static let ravenPrimary = Color(red: 0.4, green: 0.3, blue: 1.0)         // #6644FF
    static let ravenSecondary = Color(red: 0.0, green: 0.8, blue: 0.8)       // #00CCCC
    static let ravenAccent = Color(red: 1.0, green: 0.4, blue: 0.6)          // #FF6699
    
    // Semantic Colors
    static let ravenSuccess = Color.green
    static let ravenWarning = Color.orange
    static let ravenError = Color.red
    static let ravenInfo = Color.blue
    
    // Glass Colors
    static let glassWhite = Color.white.opacity(0.1)
    static let glassBorder = Color.white.opacity(0.2)
    static let glassHighlight = Color.white.opacity(0.3)
    
    // Message Bubble Colors
    static let sentBubble = Color.ravenPrimary
    static let receivedBubble = Color(UIColor.systemGray5)
    
    // Gradient
    static var ravenGradient: LinearGradient {
        LinearGradient(
            colors: [.ravenPrimary, .ravenSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [.ravenAccent, .ravenPrimary],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - View Extensions
extension View {
    /// Apply Apple's native Liquid Glass effect (iOS 26+)
    /// Provides authentic liquid glass styling with automatic fallback for older iOS versions
    func glassBackground(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
    
    /// Card style with native liquid glass effect
    func glassCard() -> some View {
        self
            .padding()
            .glassBackground()
    }
    
    /// Hide keyboard
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    /// Conditional modifier
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    /// Shimmer loading effect
    func shimmer() -> some View {
        self.modifier(ShimmerModifier())
    }
    
    /// Corner radius for specific corners
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

// MARK: - Shimmer Modifier
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    Color.white.opacity(0.3)
                        .mask(
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, .white.opacity(0.5), .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .offset(x: phase * geo.size.width)
                        )
                }
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

// MARK: - Rounded Corner Shape
struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Array Extensions
extension Array where Element: Identifiable {
    /// Find element by ID
    func element(with id: Element.ID) -> Element? {
        first { $0.id == id }
    }
    
    /// Find index by ID
    func index(of id: Element.ID) -> Int? {
        firstIndex { $0.id == id }
    }
}

// MARK: - UIImage Extensions
extension UIImage {
    /// Compress image to target size
    func compressed(maxSizeKB: Int = 500) -> Data? {
        let maxBytes = maxSizeKB * 1024
        var compression: CGFloat = 1.0
        var data = jpegData(compressionQuality: compression)
        
        while let d = data, d.count > maxBytes, compression > 0.1 {
            compression -= 0.1
            data = jpegData(compressionQuality: compression)
        }
        
        return data
    }
    
    /// Resize to max dimension
    func resized(maxDimension: CGFloat) -> UIImage {
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        if ratio >= 1 { return self }
        
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Haptic Feedback
struct Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
    
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Keyboard Observer
class KeyboardObserver: ObservableObject {
    @Published var isVisible = false
    @Published var height: CGFloat = 0
    
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }
    
    @objc private func keyboardWillShow(_ notification: Notification) {
        if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            height = frame.height
            isVisible = true
        }
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        height = 0
        isVisible = false
    }
}
