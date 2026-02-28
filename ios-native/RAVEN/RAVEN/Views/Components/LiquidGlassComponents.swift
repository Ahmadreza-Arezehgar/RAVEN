import SwiftUI

// MARK: - Glass Capsule Button
struct GlassCapsuleButton: View {
    let icon: String
    let action: () -> Void
    var size: CGFloat = 44
    
    @State private var isPressed = false
    
    var body: some View {
        Button {
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Capsule())
                // Apple Native Liquid Glass Effect (iOS 26+)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(GlassButtonStyle())
    }
}

// MARK: - Glass Button Style (Press Animation)
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Glass Avatar
struct GlassAvatar: View {
    let name: String
    let path: String?
    let size: CGFloat
    var showGlow: Bool = true
    var showOnlineIndicator: Bool = false
    
    private func buildFullURL(_ path: String) -> URL? {
        return AppConfig.mediaURL(from: path)
    }
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let path = path, !path.isEmpty, let url = buildFullURL(path) {
                    CachedAsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        initialsView
                    }
                } else {
                    initialsView
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(.primary.opacity(0.25), lineWidth: 1.5)
            )
            .shadow(color: showGlow ? .black.opacity(0.06) : .clear, radius: 8, y: 2)
            
            // Online indicator
            if showOnlineIndicator {
                Circle()
                    .fill(.green)
                    .frame(width: size * 0.25, height: size * 0.25)
                    .overlay(
                        Circle()
                            .stroke(.black, lineWidth: 2)
                    )
                    .offset(x: 2, y: 2)
            }
        }
    }
    
    // Graphite palette for premium feel
    private static let graphiteTones: [Color] = [
        Color(red: 0.17, green: 0.17, blue: 0.18),  // #2B2B2E
        Color(red: 0.23, green: 0.23, blue: 0.25),  // #3A3A3F
        Color(red: 0.12, green: 0.12, blue: 0.13),  // #1F1F22
        Color(red: 0.20, green: 0.20, blue: 0.23),  // #33333A
    ]
    
    private var initialsView: some View {
        let index = abs(name.hashValue % Self.graphiteTones.count)
        return Circle()
            .fill(Self.graphiteTones[index])
            .overlay {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85)) // Always white on dark graphite backgrounds
            }
    }
}

// MARK: - Unread Badge
struct UnreadBadge: View {
    let count: Int
    var isMuted: Bool = false
    
    // Muted gold accent for premium feel
    private let goldAccent = Color(red: 0.72, green: 0.64, blue: 0.42)   // #B8A46A
    private let mutedGray  = Color(red: 0.29, green: 0.29, blue: 0.31)   // #4A4A4E
    private let darkText   = Color(red: 0.10, green: 0.10, blue: 0.11)   // #1A1A1D
    
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(isMuted ? .white.opacity(0.6) : darkText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isMuted ? mutedGray : goldAccent)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Glass Card
struct GlassCard<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = DS.radiusCard
    var padding: CGFloat = DS.space12
    
    init(cornerRadius: CGFloat = DS.radiusCard, padding: CGFloat = DS.space12, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.cornerRadius = cornerRadius
        self.padding = padding
    }
    
    var body: some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: DS.shadowColor, radius: DS.shadowRadius, y: DS.shadowY)
    }
}

// MARK: - Glass Capsule Container
struct GlassCapsule<Content: View>: View {
    let content: Content
    var padding: CGFloat = 12
    
    init(padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
    }
    
    var body: some View {
        content
            .padding(.horizontal, padding)
            .padding(.vertical, padding * 0.66)
            // Apple Native Liquid Glass Effect (iOS 26+)
            .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - Liquid Glass TextField
struct LiquidGlassTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    
    @State private var isSecureVisible = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            
            if isSecure && !isSecureVisible {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
            
            if isSecure {
                Button {
                    isSecureVisible.toggle()
                } label: {
                    Image(systemName: isSecureVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        // Apple Native Liquid Glass Effect (iOS 26+)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Social Sign In Button
struct SocialSignInButton: View {
    enum Provider {
        case google, apple
        
        var name: String {
            switch self {
            case .google: return "Google"
            case .apple: return "Apple"
            }
        }
        
        var icon: String {
            switch self {
            case .google: return "g.circle.fill"
            case .apple: return "apple.logo"
            }
        }
        
        var backgroundColor: Color {
            switch self {
            case .google: return .white
            case .apple: return .black
            }
        }
        
        var foregroundColor: Color {
            switch self {
            case .google: return .black
            case .apple: return .white
            }
        }
    }
    
    let provider: Provider
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: provider.icon)
                    .font(.title3)
                Text("Continue with \(provider.name)")
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(provider.backgroundColor)
            .foregroundStyle(provider.foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.secondary.opacity(0.3), lineWidth: 1)
            )
        }
    }
}

// MARK: - OTP Input Field
struct OTPInputView: View {
    @Binding var code: String
    let length: Int = 6
    @FocusState private var isFocused: Bool
    
    var body: some View {
        ZStack {
            // Hidden TextField
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFocused)
                .opacity(0)
                .onChange(of: code) { _, newValue in
                    if newValue.count > length {
                        code = String(newValue.prefix(length))
                    }
                }
            
            // Visual boxes
            HStack(spacing: 12) {
                ForEach(0..<length, id: \.self) { index in
                    let character = index < code.count 
                        ? String(code[code.index(code.startIndex, offsetBy: index)])
                        : ""
                    
                    Text(character)
                        .font(.title)
                        .fontWeight(.bold)
                        .frame(width: 48, height: 56)
                        .background(
                            index == code.count ? AnyShapeStyle(Color.blue.opacity(0.08)) : AnyShapeStyle(.regularMaterial),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                }
            }
        }
        .onTapGesture {
            isFocused = true
        }
        .onAppear {
            isFocused = true
        }
    }
}

// MARK: - Keyboard Helper
extension View {
    /// Dismisses the keyboard globally
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Glass Effect Container
struct GlassEffectContainer<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content
    
    var body: some View {
        VStack(spacing: spacing) {
            content()
        }
    }
}

// MARK: - Connection Status System

/// Represents the current connectivity state for the status pill.
enum ConnectionStatus {
    case bluetoothOff
    case bluetoothDenied
    case offline
    case serviceUnavailable
    
    var icon: String {
        switch self {
        case .bluetoothOff:        return "bluetooth"
        case .bluetoothDenied:     return "exclamationmark.triangle"
        case .offline:             return "network.slash"
        case .serviceUnavailable:  return "exclamationmark.icloud"
        }
    }
    
    var label: String {
        switch self {
        case .bluetoothOff:        return "Bluetooth off · Offline disabled"
        case .bluetoothDenied:     return "Bluetooth denied · Tap to enable"
        case .offline:             return "No internet · Showing cached"
        case .serviceUnavailable:  return "Service issue · Try again"
        }
    }
    
    var ctaLabel: String {
        switch self {
        case .bluetoothOff:        return "Enable"
        case .bluetoothDenied:     return "Settings"
        case .offline:             return "Check"
        case .serviceUnavailable:  return "Retry"
        }
    }
    
    var tintColor: Color {
        switch self {
        case .bluetoothOff:        return .blue
        case .bluetoothDenied:     return .red
        case .offline:             return .red
        case .serviceUnavailable:  return .orange
        }
    }
    
    var sheetTitle: String {
        switch self {
        case .bluetoothOff:        return "Bluetooth Required"
        case .bluetoothDenied:     return "Permission Needed"
        case .offline:             return "No Internet Connection"
        case .serviceUnavailable:  return "Service Unavailable"
        }
    }
    
    var sheetDescription: String {
        switch self {
        case .bluetoothOff:
            return "Bluetooth is required for offline mesh messaging. Enable it to send and receive messages without internet."
        case .bluetoothDenied:
            return "RAVEN needs Bluetooth access for offline mesh messaging. Please enable it in Settings."
        case .offline:
            return "You're currently offline. Cached messages are shown. Connect to the internet to sync."
        case .serviceUnavailable:
            return "RAVEN's servers are temporarily unreachable. Your messages are queued and will be sent when the connection is restored."
        }
    }
    
    /// Whether the CTA should open iOS Settings
    var opensSettings: Bool {
        switch self {
        case .bluetoothOff, .bluetoothDenied: return true
        case .offline, .serviceUnavailable:  return false
        }
    }
}

// MARK: - Connection Status Pill
/// A small, floating glass capsule that replaces the old full-width status banners.
/// Matches the Raven Liquid Glass design language.
struct ConnectionStatusPill: View {
    let status: ConnectionStatus
    var onTapPill: () -> Void = {}
    var onCTA: () -> Void = {}
    
    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Image(systemName: status.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(status.tintColor.opacity(0.9))
            
            // Short label
            Text(status.label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
            
            // CTA button
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                onCTA()
            } label: {
                Text(status.ctaLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(status.tintColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(status.tintColor.opacity(0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .onTapGesture {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            onTapPill()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

// MARK: - Connection Status Detail Sheet
/// Compact sheet shown when user taps the status pill. Provides explanation + action buttons.
struct ConnectionStatusSheet: View {
    let status: ConnectionStatus
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: status.icon)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(status.tintColor.opacity(0.8))
                .padding(.top, 8)
            
            // Title
            Text(status.sheetTitle)
                .font(.headline)
                .fontWeight(.semibold)
            
            // Description
            Text(status.sheetDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Spacer()
            
            // Actions
            VStack(spacing: 10) {
                if status.opensSettings {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                        dismiss()
                    } label: {
                        Text("Open Settings")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(status.tintColor.opacity(0.8))
                            .clipShape(Capsule())
                    }
                }
                
                Button {
                    dismiss()
                } label: {
                    Text("Not now")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .padding(.top, 24)
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}

#Preview("TextField") {
    VStack {
        LiquidGlassTextField(icon: "envelope", placeholder: "Email", text: .constant(""))
        LiquidGlassTextField(icon: "lock", placeholder: "Password", text: .constant(""), isSecure: true)
    }
    .padding()
}

#Preview("OTP") {
    OTPInputView(code: .constant("123"))
}
