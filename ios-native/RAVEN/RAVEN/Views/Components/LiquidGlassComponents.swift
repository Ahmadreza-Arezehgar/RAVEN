import SwiftUI

// MARK: - Glass Capsule Button
struct GlassCapsuleButton: View {
    let icon: String
    var size: CGFloat = 44
    let action: () -> Void

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
                .glassSurface(in: Capsule()) // unified glass treatment
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
    /// Set true to render a tiny green presence dot at the bottom-right.
    /// Caller is responsible for passing the actual online state — the
    /// dot is NOT shown when this is false. Previously the indicator was
    /// shown unconditionally whenever it was "enabled", which produced
    /// a permanent green dot regardless of presence.
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

            // Presence dot — only when the caller explicitly says the
            // peer is online. Soft scale-in so the dot animates in/out
            // smoothly when presence flips.
            if showOnlineIndicator {
                Circle()
                    .fill(Color.green)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: 2)
                    )
                    .offset(x: size * 0.04, y: size * 0.04)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: showOnlineIndicator)
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
            .glassSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
            .glassSurface(in: Capsule())
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
        // Liquid Glass material effect (iOS 15+)
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

// MARK: - LiquidGlass — Single Design Language
//
// Unified tokens + modifiers for every "Apple liquid glass" surface in the app.
// All bars, pills, toasts, cards, buttons, sheet headers, etc. should compose
// their look from these primitives so the entire UI shares one visual treatment
// (same material, stroke, shadow stack, specular highlight).
//
// Two surface variants:
//   1. `.glassSurface(in:)` — neutral surface (toolbars, cards, glass buttons)
//   2. `.glassAccent(in:)`  — emphasized surface with chromatic refraction
//                              ring (active tab pill, primary-action capsules)
//
// Both work with any Shape — Capsule, RoundedRectangle, Circle.

enum LiquidGlass {

    // MARK: Tokens (single source of truth)

    /// Hairline edge stroke: bright top-leading → dim bottom-trailing.
    /// Defines the glass "rim" highlight everywhere.
    /// Tuned LIGHTER so surfaces read as transparent panes instead of
    /// frosted plates — you can see the content behind through the rim.
    static let edgeStroke = LinearGradient(
        colors: [
            .white.opacity(0.22),
            .white.opacity(0.06),
            .white.opacity(0.02)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Top specular highlight — the glass "shine" running across the top edge.
    static let topSpecular = LinearGradient(
        colors: [.white.opacity(0.60), .clear],
        startPoint: .top,
        endPoint: .center
    )

    /// Subtle inner brightness wash that lifts an elevated/active surface
    /// off the ambient bar background.
    static let innerWash = LinearGradient(
        colors: [
            .white.opacity(0.10),
            .white.opacity(0.04),
            .white.opacity(0.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Chromatic refraction ring — used ONLY on emphasized surfaces (active tab
    /// pill, primary buttons). Approximates iOS 26's `.glassEffect(.interactive())`
    /// color fringing while remaining compatible with the iOS 17 deployment target.
    static let chromaticRing = AngularGradient(
        colors: [
            Color(red: 0.45, green: 0.85, blue: 1.00).opacity(0.55), // cyan
            .white.opacity(0.55),
            Color(red: 1.00, green: 0.55, blue: 0.85).opacity(0.45), // magenta
            .white.opacity(0.30),
            Color(red: 1.00, green: 0.78, blue: 0.40).opacity(0.40), // amber
            .white.opacity(0.55),
            Color(red: 0.45, green: 0.85, blue: 1.00).opacity(0.55)  // cyan loop
        ],
        center: .center
    )

    /// Standard rim stroke width.
    static let strokeWidth: CGFloat = 0.8

    // MARK: Shadow recipes

    /// Drop shadow — kept SUBTLE so glass surfaces feel like floating panes
    /// the user can see through, not solid plates pressed onto the screen.
    static let dropShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.10), 14, 0, 5)

    static let liftShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.white.opacity(0.05), 1, 0, -1)

    static let accentDropShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.18), 8, 0, 3)
}

// MARK: - View Modifiers

extension View {

    /// Standard liquid-glass surface — frosted material, hairline rim,
    /// top specular, drop + lift shadow. Use for floating bars, sheet headers,
    /// cards, glass buttons, toasts.
    func glassSurface<S: Shape>(in shape: S) -> some View {
        modifier(_LiquidGlassSurface(shape: shape))
    }

    /// Emphasized liquid-glass surface — same as `.glassSurface(in:)` plus an
    /// inner brightness wash and the chromatic refraction ring. Use sparingly
    /// for the single most prominent surface on a screen (active tab pill,
    /// hero call-to-action).
    func glassAccent<S: Shape>(in shape: S) -> some View {
        modifier(_LiquidGlassAccentSurface(shape: shape))
    }
}

// MARK: - Internal modifiers

private struct _LiquidGlassSurface<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(LiquidGlass.edgeStroke, lineWidth: LiquidGlass.strokeWidth))
            .overlay(
                shape
                    .stroke(LiquidGlass.topSpecular, lineWidth: LiquidGlass.strokeWidth)
                    .blendMode(.screen)
            )
            .shadow(
                color: LiquidGlass.dropShadow.color,
                radius: LiquidGlass.dropShadow.radius,
                x: LiquidGlass.dropShadow.x,
                y: LiquidGlass.dropShadow.y
            )
            .shadow(
                color: LiquidGlass.liftShadow.color,
                radius: LiquidGlass.liftShadow.radius,
                x: LiquidGlass.liftShadow.x,
                y: LiquidGlass.liftShadow.y
            )
    }
}

private struct _LiquidGlassAccentSurface<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.fill(LiquidGlass.innerWash).blendMode(.plusLighter)
            )
            .overlay(
                shape.stroke(LiquidGlass.chromaticRing, lineWidth: 1.0)
            )
            .overlay(
                shape
                    .stroke(LiquidGlass.topSpecular, lineWidth: LiquidGlass.strokeWidth)
                    .blendMode(.screen)
            )
            .shadow(
                color: LiquidGlass.accentDropShadow.color,
                radius: LiquidGlass.accentDropShadow.radius,
                x: LiquidGlass.accentDropShadow.x,
                y: LiquidGlass.accentDropShadow.y
            )
    }
}

// MARK: - Disaster Mode Banner
//
// Sticky liquid-glass banner that appears at the top of the app whenever:
//   * the device has NO internet (NetworkMonitor.isOnline == false)
//   * AND the BLE mesh has at least one connected peer
//
// Marquee "the messenger that works when nothing else does" UX.
// Mounted once at MainShellView root.
struct DisasterModeBanner: View {
    @ObservedObject private var network = NetworkMonitor.shared
    @ObservedObject private var mesh = BLEMeshEngine.shared

    @State private var visible = false

    private var shouldShow: Bool {
        !network.isOnline && !mesh.connectedPeers.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if visible {
                bannerCapsule
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.98, anchor: .top))
                    )
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(visible)
        .animation(.interpolatingSpring(stiffness: 320, damping: 28), value: visible)
        .onAppear { visible = shouldShow }
        .onChange(of: shouldShow) { _, new in visible = new }
    }

    private var bannerCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)

            VStack(alignment: .leading, spacing: 1) {
                Text("Internet down — Mesh active")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(peerSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text("\(mesh.connectedPeers.count)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassSurface(in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassSurface(in: Capsule())
    }

    private var peerSummary: String {
        let n = mesh.connectedPeers.count
        if n == 1 { return "Connected to 1 device nearby" }
        return "Connected to \(n) devices nearby"
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - GroupKeyService (per-group symmetric keys for mesh anti-spoof)
// ──────────────────────────────────────────────────────────────────────────
// Caches AES-256 keys per groupId and version. The MessageRouter encrypts
// group-mesh payloads with the cached key; receivers decrypt via this
// service. Server-side: see /api/groups/{id}/key (group_keys.py).
import CryptoKit

@MainActor
@Observable
final class GroupKeyService {
    static let shared = GroupKeyService()
    private init() {
        // 🟢 ROUND 74 (2026-05-24) — load persisted keys from Keychain
        // on first access so a fresh launch (or cold start after low-
        // memory eviction) restores everything we've ingested.
        // Without this, every restart wiped the in-memory cache and
        // BLE-only devices re-failed every decrypt.
        loadFromKeychain()
    }

    fileprivate struct Entry { let version: Int; let key: SymmetricKey }
    /// Latest key per group, indexed by groupId.
    private var latest: [String: Entry] = [:]
    /// All known keys (groupId, version) → key, for decrypting older mesh
    /// envelopes that were signed with a prior version.
    private var byVersion: [String: [Int: SymmetricKey]] = [:]

    private struct GroupKeyResponse: Decodable {
        let groupId: String
        let version: Int
        let keyB64: String
    }

    /// Fetch the latest key for a group from the server (if not cached).
    @discardableResult
    fileprivate func currentKey(for groupId: String) async -> Entry? {
        if let cached = latest[groupId] { return cached }
        do {
            let resp: GroupKeyResponse = try await NetworkService.shared.get(
                path: "/api/groups/\(groupId)/key"
            )
            guard let raw = Data(base64Encoded: resp.keyB64), raw.count == 32 else { return nil }
            let entry = Entry(version: resp.version, key: SymmetricKey(data: raw))
            latest[groupId] = entry
            byVersion[groupId, default: [:]][resp.version] = entry.key
            // 🟢 ROUND 74 — also persist server-fetched keys so we have
            // them after a restart even if the mesh ingest path never
            // fired. AND broadcast on mesh so BLE-only members can
            // ingest. Fire-and-forget — the mesh broadcast must not
            // block the encrypt path.
            persistKey(groupId: groupId, version: resp.version, keyB64: resp.keyB64)
            Task.detached(priority: .utility) {
                await MeshGroupBroadcaster.broadcastKey(
                    groupId: groupId,
                    version: resp.version,
                    keyB64: resp.keyB64
                )
            }
            return entry
        } catch {
            #if DEBUG
            print("⚠️ [GroupKey] fetch failed for \(groupId.prefix(8)): \(error)")
            #endif
            return nil
        }
    }

    /// 🟢 ROUND 74 (2026-05-24) — public trigger to fetch + broadcast.
    ///
    /// Use case: right after a group is created, the creator calls
    /// this to fetch the AES-GCM key from the server (which mints v1
    /// on first request) and broadcast it on the mesh so BLE-only
    /// members can ingest before any chat traffic flows.
    ///
    /// No-op if we already have the key cached locally (the cache hit
    /// path in currentKey doesn't broadcast — that's only done on
    /// fresh server fetches).
    func prefetchAndBroadcast(groupId: String) async {
        _ = await currentKey(for: groupId)
    }

    /// 🟢 ROUND 74 (2026-05-24) — ingest a key delivered via mesh.
    ///
    /// Called by RAVENApp.handleMeshMessage when a `group_key` envelope
    /// arrives. Validates length + group membership before storing.
    /// Returns true if the key was accepted (new or refresh), false if
    /// rejected (not a member, malformed, etc).
    ///
    /// 🛡️ SECURITY:
    ///   - Caller (RAVENApp.handleMeshMessage) MUST verify the outer
    ///     mesh signature before passing the key here — this method
    ///     trusts the broadcaster is authenticated.
    ///   - Caller MUST verify the receiver is a current member of
    ///     `groupId` per the local GroupRepository.
    ///   - We refuse keys that don't decode to 32 bytes (AES-256).
    /// Latest group-key version we hold locally (0 if none). Used by the
    /// serverless kick-rekey to mint version N+1 without a server round-trip.
    func currentLocalVersion(for groupId: String) -> Int {
        latest[groupId]?.version ?? 0
    }

    @discardableResult
    func ingestMeshKey(groupId: String, version: Int, keyB64: String) -> Bool {
        guard let raw = Data(base64Encoded: keyB64), raw.count == 32 else {
            #if DEBUG
            print("🟥 [GroupKey] REJECT mesh-ingest gid=\(groupId.prefix(8)) v=\(version) — keyB64 not 32 bytes")
            #endif
            return false
        }

        // 🔐 ROUND 76 (2026-05-24) — Hacker #6 finding #2.
        // Clamp accepted version to ≤ latest_local + 1 so a current
        // member can't broadcast `v999` and become the new `latest`.
        // Pre-fix, `if version > currentLatest.version { latest = entry }`
        // promoted ANY higher version unconditionally, letting an attacker
        // force the victim to encrypt outbound with the attacker's key.
        //
        // Threat model: the server is the canonical source for new
        // key versions (it mints them on rotation). Mesh-distributed
        // keys catch up the local cache; they should NEVER skip ahead
        // by more than 1 from what we already have. A delta > 1 means
        // either (a) we missed an intermediate rotation and should
        // refetch from server (best-effort: log + reject this mesh
        // ingest, the next HTTPS encrypt() will fetch the correct
        // version), or (b) we're being attacked.
        let currentLatestVersion = latest[groupId]?.version ?? 0
        if version > currentLatestVersion + 1 {
            #if DEBUG
            print("🟥 [GroupKey] REJECT mesh-ingest gid=\(groupId.prefix(8)) v=\(version) — too far ahead of local latest v=\(currentLatestVersion). Possible v999 hijack attempt. Will refetch from server on next encrypt.")
            #endif
            return false
        }

        // Idempotent: silently accept duplicate (same gid+version+key) re-ingests.
        if let existing = byVersion[groupId]?[version] {
            // Constant-time compare via raw bytes.
            let existingBytes = existing.withUnsafeBytes { Data($0) }
            if existingBytes == raw {
                #if DEBUG
                print("🟢 [GroupKey] mesh-ingest gid=\(groupId.prefix(8)) v=\(version) — already have matching key, no-op")
                #endif
                return true
            }
            // Same gid+version but DIFFERENT key bytes → reject. The
            // server's key is canonical; allowing arbitrary mesh
            // overrides would let an attacker poison the cache.
            #if DEBUG
            print("🟥 [GroupKey] REJECT mesh-ingest gid=\(groupId.prefix(8)) v=\(version) — local key differs from incoming")
            #endif
            return false
        }
        let symKey = SymmetricKey(data: raw)
        let entry = Entry(version: version, key: symKey)
        byVersion[groupId, default: [:]][version] = symKey
        // Update `latest` only if this is a NEWER version than what we have.
        // (Already clamped above: at most latest+1.)
        if let currentLatest = latest[groupId] {
            if version > currentLatest.version {
                latest[groupId] = entry
            }
        } else {
            latest[groupId] = entry
        }
        persistKey(groupId: groupId, version: version, keyB64: keyB64)
        #if DEBUG
        print("🟢 [GroupKey] ✅ mesh-ingested gid=\(groupId.prefix(8)) v=\(version) — \(raw.count)B")
        #endif
        return true
    }

    // MARK: - Keychain persistence (Round 74)
    //
    // Persist group keys with kSecAttrAccessibleAfterFirstUnlock so they
    // survive app restart but never leave the device (no iCloud sync).
    // Stored as a single Codable blob keyed by `raven.groupkeys.v1` —
    // updating any single entry rewrites the whole blob (low write
    // frequency makes this cheaper than per-entry items).

    private static let keychainService = "com.raven.groupkeys"
    private static let keychainAccount = "groupkeys.v1"

    private struct PersistedKey: Codable {
        let groupId: String
        let version: Int
        let keyB64: String
    }

    private struct PersistedBlob: Codable {
        let keys: [PersistedKey]
    }

    private func persistKey(groupId: String, version: Int, keyB64: String) {
        var existing = readPersistedBlob()
        // Replace the (groupId, version) entry if present, else append.
        var keys = existing.keys.filter { !($0.groupId == groupId && $0.version == version) }
        keys.append(PersistedKey(groupId: groupId, version: version, keyB64: keyB64))
        existing = PersistedBlob(keys: keys)
        writePersistedBlob(existing)
    }

    private func loadFromKeychain() {
        let blob = readPersistedBlob()
        for entry in blob.keys {
            guard let raw = Data(base64Encoded: entry.keyB64), raw.count == 32 else { continue }
            let symKey = SymmetricKey(data: raw)
            byVersion[entry.groupId, default: [:]][entry.version] = symKey
            // Pick the highest version per groupId as latest.
            if let cur = latest[entry.groupId] {
                if entry.version > cur.version {
                    latest[entry.groupId] = Entry(version: entry.version, key: symKey)
                }
            } else {
                latest[entry.groupId] = Entry(version: entry.version, key: symKey)
            }
        }
        #if DEBUG
        if !blob.keys.isEmpty {
            print("🟢 [GroupKey] loaded \(blob.keys.count) persisted keys from Keychain")
        }
        #endif
    }

    private func readPersistedBlob() -> PersistedBlob {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let blob = try? JSONDecoder().decode(PersistedBlob.self, from: data)
        else { return PersistedBlob(keys: []) }
        return blob
    }

    private func writePersistedBlob(_ blob: PersistedBlob) {
        guard let data = try? JSONEncoder().encode(blob) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // Try update first; if not found, add.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (k, v) in attributes { addQuery[k] = v }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// Look up a previously-seen key by version (for decrypting older
    /// envelopes after a key rotation). Falls back to the latest cached key.
    func key(for groupId: String, version: Int) -> SymmetricKey? {
        if let v = byVersion[groupId]?[version] { return v }
        return latest[groupId]?.key
    }

    /// Encrypt a UTF-8 string with the latest group key. Returns base64
    /// `nonce(12) || ciphertext || tag(16)`. Caller stamps the version into
    /// the envelope for the receiver to look up the right key.
    func encrypt(_ plaintext: String, groupId: String) async -> (ciphertextB64: String, version: Int)? {
        guard let entry = await currentKey(for: groupId) else { return nil }
        guard let plain = plaintext.data(using: .utf8) else { return nil }
        do {
            let sealed = try AES.GCM.seal(plain, using: entry.key)
            guard let combined = sealed.combined else { return nil }
            return (combined.base64EncodedString(), entry.version)
        } catch {
            return nil
        }
    }

    /// 🔴 ROUND 70 — version-tag derivation. Produces an 8-byte
    /// deterministic tag from the group key + version that proves
    /// possession of the key WITHOUT revealing it. A kicked-out
    /// attacker who knows the old version's `groupKeyVersion` integer
    /// cannot synthesise the matching tag for the NEW version, so
    /// forged-version envelopes are now detectable.
    ///
    /// Stable across sessions because the input is the same key
    /// bytes both sides hold. SHA-256 truncated to 8 bytes; 64 bits
    /// is comfortable for collision resistance at the volumes
    /// involved (one tag per envelope).
    func versionTag(groupId: String, version: Int) async -> String? {
        guard let key = key(for: groupId, version: version) else { return nil }
        var hasher = SHA256()
        hasher.update(data: Data("raven-gkv-tag-v1".utf8))
        hasher.update(data: Data([0x00]))
        hasher.update(data: key.withUnsafeBytes { Data($0) })
        hasher.update(data: Data([0x00]))
        var v = Int64(version).bigEndian
        hasher.update(data: withUnsafeBytes(of: &v) { Data($0) })
        let digest = Data(hasher.finalize())
        return digest.prefix(8).base64EncodedString()
    }

    /// 🔴 ROUND 70 — verify a version-tag claim against the local
    /// key for `version`. Returns true iff the claim could only have
    /// been produced by a holder of the same group key.
    func verifyVersionTag(_ tagB64: String, groupId: String, version: Int) async -> Bool {
        guard let expected = await versionTag(groupId: groupId, version: version) else {
            return false
        }
        // Constant-time compare via SHA256-equality.
        return expected == tagB64
    }

    /// Decrypt a base64-encoded `nonce || ciphertext || tag` blob using the
    /// group's key for the given version.
    func decrypt(_ ciphertextB64: String, groupId: String, version: Int) async -> String? {
        // Ensure we have at least *some* key cached
        if byVersion[groupId]?[version] == nil { _ = await currentKey(for: groupId) }
        guard let key = key(for: groupId, version: version) else { return nil }
        guard let blob = Data(base64Encoded: ciphertextB64) else { return nil }
        do {
            let sealed = try AES.GCM.SealedBox(combined: blob)
            let plain = try AES.GCM.open(sealed, using: key)
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Wipe caches (e.g. on sign-out).
    func reset() {
        latest.removeAll()
        byVersion.removeAll()
        // 🟢 ROUND 74 — also purge the persisted Keychain blob so a
        // logout fully clears group keys (else next sign-in inherits
        // stale keys from a previous account on the same device).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 🔐 Forward-secrecy cache invalidation.
    ///
    /// Call this AFTER the server rotates a group's symmetric key (e.g.
    /// after a member is kicked — the kick endpoint returns
    /// `new_key_version`). Without this, every other member's iOS app
    /// keeps encrypting with the OLD cached key — and the kicked member's
    /// device, which still has v(N-1) cached, decrypts every "new" message.
    ///
    /// The on-disk cipher cache is wiped so the very next encrypt/decrypt
    /// re-fetches /key (which now serves the new version).
    func reset(for groupId: String) {
        latest.removeValue(forKey: groupId)
        byVersion.removeValue(forKey: groupId)
        #if DEBUG
        print("🔐 [GroupKey] Cache evicted for \(groupId.prefix(8)) — next encrypt will refetch")
        #endif
    }

    /// Notify the cache that the server now serves a newer version for this
    /// group (e.g. learned via the `groupKeyVersion` field on a received
    /// envelope). If we have a STALE entry, evict + refetch so subsequent
    /// encrypts use the fresh key.
    func ensureNotStale(groupId: String, serverVersion: Int) async {
        if let cached = latest[groupId], cached.version < serverVersion {
            #if DEBUG
            print("🔐 [GroupKey] Stale local v\(cached.version) < server v\(serverVersion) — evicting")
            #endif
            latest.removeValue(forKey: groupId)
            // Keep `byVersion` entries — old keys are still useful to decrypt
            // mesh envelopes that were broadcast under the old version.
            _ = await currentKey(for: groupId)
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Linked Devices (multi-device session registry)
// ──────────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class LinkedDevicesService {
    static let shared = LinkedDevicesService()
    private init() {}

    struct LinkedDevice: Decodable, Identifiable, Hashable {
        let id: String
        let deviceName: String?
        let deviceModel: String?
        let deviceOs: String?
        let pairedAt: Date
        let lastSeenAt: Date
        let isThisDevice: Bool
    }

    var devices: [LinkedDevice] = []
    var isLoading = false

    private struct HeartbeatRequest: Encodable {
        let deviceName: String
        let deviceModel: String
        let deviceOs: String
    }
    private struct HeartbeatResponse: Decodable { let deviceId: String }

    /// Call once on cold start (and on resume) to register/refresh this device.
    @discardableResult
    func heartbeat() async -> String? {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return nil }
        // UIDevice.current is sync, MainActor-isolated. Read everything on
        // the main actor in one hop instead of awaiting each property.
        let body = await MainActor.run { () -> HeartbeatRequest in
            let dev = UIDevice.current
            return HeartbeatRequest(
                deviceName: dev.name,
                deviceModel: dev.model,
                deviceOs: "\(dev.systemName) \(dev.systemVersion)"
            )
        }
        do {
            let resp: HeartbeatResponse = try await NetworkService.shared.post(
                path: "/api/linked-devices/heartbeat",
                body: body
            )
            return resp.deviceId
        } catch {
            #if DEBUG
            print("⚠️ [LinkedDevices] heartbeat failed: \(error)")
            #endif
            return nil
        }
    }

    func reload() async {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list: [LinkedDevice] = try await NetworkService.shared.get(path: "/api/linked-devices")
            devices = list
        } catch {
            #if DEBUG
            print("⚠️ [LinkedDevices] reload failed: \(error)")
            #endif
        }
    }

    func revoke(deviceId: String) async {
        struct Empty: Codable {}
        do {
            let _: Empty = try await NetworkService.shared.post(
                path: "/api/linked-devices/\(deviceId)/revoke",
                body: Empty()
            )
            await reload()
        } catch {
            #if DEBUG
            print("⚠️ [LinkedDevices] revoke failed: \(error)")
            #endif
        }
    }
}

// MARK: - Linked Devices Settings View
struct LinkedDevicesView: View {
    @State private var service = LinkedDevicesService.shared
    @State private var revoking: String?
    @State private var showRevokeConfirm = false
    /// Drives the QR scanner sheet that launches the desktop-login
    /// approval flow. The scanner is shared with the friend-add flow
    /// — it auto-detects which kind of QR was scanned (see
    /// `Features/QRCode/ScanQRCodeView.swift`).
    @State private var showLinkDesktop = false

    var body: some View {
        List {
            // 🆕 "Link a desktop" entry — discoverability for the new
            // QR-login flow. Tapping it opens the camera, the user
            // scans the QR shown by the macOS / Web client, and the
            // approval sheet pops up. Same scanner UI you'd use to
            // add a friend; the parsed payload picks the right path.
            Section {
                Button {
                    showLinkDesktop = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Link a desktop")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("Scan the QR shown on your computer to sign in there.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            } header: {
                Text("Add a device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("On your computer, choose “Log in with QR code” in RAVEN. Scan the code shown there with this phone, then approve.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if service.devices.isEmpty {
                if service.isLoading {
                    HStack { ProgressView(); Text("Loading devices…").foregroundStyle(.secondary) }
                } else {
                    Text("No other devices signed in.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(service.devices) { device in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: deviceIcon(for: device))
                            .font(.system(size: 22))
                            .foregroundStyle(.primary)
                            .frame(width: 38, height: 38)
                            .glassSurface(in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(device.deviceName ?? "Unknown")
                                    .font(.system(size: 15, weight: .semibold))
                                if device.isThisDevice {
                                    Text("This device")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15), in: Capsule())
                                }
                            }
                            if let m = device.deviceModel { Text(m).font(.caption).foregroundStyle(.secondary) }
                            Text("Last active \(device.lastSeenAt.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !device.isThisDevice {
                            Button("Revoke", role: .destructive) {
                                revoking = device.id
                                showRevokeConfirm = true
                            }
                            .font(.system(size: 13))
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Linked Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await service.reload() }
        .refreshable { await service.reload() }
        .fullScreenCover(isPresented: $showLinkDesktop) {
            ScanQRCodeView()
        }
        .alert("Revoke device?", isPresented: $showRevokeConfirm) {
            Button("Revoke", role: .destructive) {
                if let id = revoking {
                    Task { await service.revoke(deviceId: id) }
                }
                revoking = nil
            }
            Button("Cancel", role: .cancel) { revoking = nil }
        } message: {
            Text("That device will be marked as revoked. It may stay signed in until its current token expires.")
        }
    }

    private func deviceIcon(for d: LinkedDevicesService.LinkedDevice) -> String {
        let model = (d.deviceModel ?? "").lowercased()
        if model.contains("ipad") { return "ipad" }
        if model.contains("mac") { return "laptopcomputer" }
        return "iphone"
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Nearby People (mesh discovery)
// ──────────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class NearbyService {
    static let shared = NearbyService()
    private init() {}

    struct NearbyPerson: Identifiable, Hashable {
        let userId: String
        var username: String
        var displayName: String?
        var avatarPath: String?
        var isFriend: Bool
        var lastSeenAt: Date
        var id: String { userId }
    }

    var people: [NearbyPerson] = []
    var isLoading = false

    /// Refresh the nearby list from currently-connected mesh peers.
    /// Resolves user IDs to public profiles via /api/nearby/lookup.
    func refresh() async {
        let peerUserIds: [String] = await MainActor.run {
            BLEMeshEngine.shared.connectedPeers.compactMap { $0.userId }
                .filter { !$0.isEmpty }
        }
        let unique = Array(Set(peerUserIds))
        guard !unique.isEmpty else {
            people = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        struct Body: Encodable { let userIds: [String] }
        struct Resp: Decodable {
            let userId: String
            let username: String
            let displayName: String?
            let avatarPath: String?
            let isFriend: Bool
        }
        do {
            let rows: [Resp] = try await NetworkService.shared.post(
                path: "/api/nearby/lookup",
                body: Body(userIds: unique)
            )
            let now = Date()
            people = rows.map {
                NearbyPerson(
                    userId: $0.userId, username: $0.username,
                    displayName: $0.displayName, avatarPath: $0.avatarPath,
                    isFriend: $0.isFriend, lastSeenAt: now
                )
            }
        } catch {
            // Offline mode — fall back to whatever we know locally
            people = unique.map {
                NearbyPerson(userId: $0, username: "user_\($0.prefix(6))",
                             displayName: nil, avatarPath: nil,
                             isFriend: false, lastSeenAt: Date())
            }
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - MeshFileTransfer (chunked, signed, resumable file delivery v1)
// ──────────────────────────────────────────────────────────────────────────
//
// PROTOCOL
// --------
// A file is split into N chunks of `chunkSize` bytes. The sender broadcasts:
//
//   1. **Manifest** envelope:
//        { fileId, recipientId, totalSize, chunkSize, totalChunks,
//          sha256OfWholeFile, perChunkHashes[N], signature, signerPublicKey,
//          mimeType?, fileName? }
//      Signature covers the manifest minus signature itself.
//
//   2. **Chunk** envelopes (N of them):
//        { fileId, index, payload(chunkSize bytes), chunkSignature }
//      chunkSignature = Ed25519(privateKey, fileId || index || payload)
//
// On receive, the recipient:
//   * Verifies the manifest signature against its trusted key for `senderId`.
//     If unknown / untrusted, drop.
//   * Rejects if `totalSize` exceeds the user-configurable cap (default 50MB).
//   * Allocates `MeshFileReceiver` keyed on `fileId`, stores chunk indices it
//     receives, validates each chunk's signature + hash matches manifest.
//   * Emits an ACK with the list of MISSING indices every 5s while in-flight.
//   * Sender retransmits only the missing indices on next ACK (resume).
//   * On all-chunks-received, recipient writes file to disk + emits final ACK
//     with `complete = true` so sender can stop broadcasting.
//
// IMPLEMENTATION STATE
// --------------------
// Manifest + receiver bookkeeping are implemented and unit-testable below.
// What's NOT yet wired into BLEMeshEngine:
//   * BLE GATT chunk size negotiation (currently we only have generic mesh
//     envelopes — chunks would need a new envelope type tag)
//   * NACK/ACK piggyback on top of existing MeshACKEnvelope
//   * Disk write to a sandboxed receive directory
// These are bounded follow-ups (~1 day each); the protocol below is the
// authoritative version they'll consume.

struct MeshFileManifest: Codable, Equatable {
    let fileId: String                  // UUID
    let senderId: String
    let recipientId: String             // userId for 1:1, groupId for group
    let totalSize: Int                  // bytes
    let chunkSize: Int                  // bytes per chunk (typically 4096)
    let totalChunks: Int
    let sha256OfWholeFile: String       // hex
    let perChunkHashes: [String]        // hex, length == totalChunks
    let mimeType: String?
    let fileName: String?
    var signature: String?              // base64 Ed25519
    var signerPublicKey: String?        // base64

    /// Bytes that the signature covers (everything except signature itself).
    func signingBlob() -> Data? {
        var copy = self
        copy.signature = nil
        copy.signerPublicKey = nil
        return try? JSONEncoder().encode(copy)
    }

    /// Sign in place using the device identity.
    mutating func sign() {
        guard let blob = signingBlob() else { return }
        let sig = DeviceIdentityService.shared.sign(blob)
        self.signature = sig?.base64EncodedString()
        self.signerPublicKey = DeviceIdentityService.shared.publicKeyBase64
    }

    func isSignatureValid() -> Bool {
        guard let sigB64 = signature, let sig = Data(base64Encoded: sigB64),
              let pubB64 = signerPublicKey, let pub = Data(base64Encoded: pubB64),
              let blob = signingBlob() else { return false }
        return DeviceIdentityService.shared.verify(signature: sig, data: blob, publicKey: pub)
    }
}

/// Per-chunk wire format. `payload` is raw bytes; signature covers
/// `fileId || index_le || payload` to prevent splicing chunks across files.
struct MeshFileChunk: Codable {
    let fileId: String
    let index: Int
    let payload: Data
    let signature: String?      // base64 Ed25519
    let signerPublicKey: String?

    func signingBlob() -> Data {
        var blob = Data()
        blob.append(fileId.data(using: .utf8) ?? Data())
        var idx = UInt32(index).littleEndian
        withUnsafeBytes(of: &idx) { blob.append(contentsOf: $0) }
        blob.append(payload)
        return blob
    }

    static func make(fileId: String, index: Int, payload: Data) -> MeshFileChunk {
        var chunk = MeshFileChunk(
            fileId: fileId, index: index, payload: payload,
            signature: nil, signerPublicKey: nil
        )
        let blob = chunk.signingBlob()
        let sig = DeviceIdentityService.shared.sign(blob)
        chunk = MeshFileChunk(
            fileId: fileId, index: index, payload: payload,
            signature: sig?.base64EncodedString(),
            signerPublicKey: DeviceIdentityService.shared.publicKeyBase64
        )
        return chunk
    }

    func isSignatureValid() -> Bool {
        guard let sigB64 = signature, let sig = Data(base64Encoded: sigB64),
              let pubB64 = signerPublicKey, let pub = Data(base64Encoded: pubB64) else {
            return false
        }
        return DeviceIdentityService.shared.verify(
            signature: sig, data: signingBlob(), publicKey: pub
        )
    }
}

/// In-flight receive buffer for one file. Tracks which chunk indices we have,
/// rejects bad signatures / hash mismatches, and emits the missing-index list
/// for the sender to resume from.
@MainActor
final class MeshFileReceiver: ObservableObject {
    let manifest: MeshFileManifest
    @Published private(set) var receivedIndices: Set<Int> = []
    @Published private(set) var isComplete = false
    private var buffer: [Int: Data] = [:]

    init?(manifest: MeshFileManifest, maxBytes: Int = 50 * 1024 * 1024) {
        guard manifest.isSignatureValid() else { return nil }
        guard manifest.totalSize <= maxBytes else { return nil }
        guard manifest.perChunkHashes.count == manifest.totalChunks else { return nil }
        self.manifest = manifest
    }

    /// Accept a chunk if it matches the per-chunk hash AND verifies.
    @discardableResult
    func ingest(_ chunk: MeshFileChunk) -> Bool {
        guard chunk.fileId == manifest.fileId,
              chunk.index >= 0 && chunk.index < manifest.totalChunks else { return false }
        guard chunk.isSignatureValid() else { return false }
        let hash = MeshFileReceiver.hex(SHA256.hash(data: chunk.payload))
        guard hash == manifest.perChunkHashes[chunk.index] else { return false }

        buffer[chunk.index] = chunk.payload
        receivedIndices.insert(chunk.index)
        if receivedIndices.count == manifest.totalChunks { isComplete = true }
        return true
    }

    /// Sorted list of chunk indices we still need.
    func missingIndices() -> [Int] {
        guard !isComplete else { return [] }
        return (0..<manifest.totalChunks).filter { !receivedIndices.contains($0) }
    }

    /// Reassemble. Verifies the whole-file SHA before returning.
    func reassemble() -> Data? {
        guard isComplete else { return nil }
        var out = Data(capacity: manifest.totalSize)
        for i in 0..<manifest.totalChunks {
            guard let chunk = buffer[i] else { return nil }
            out.append(chunk)
        }
        let whole = MeshFileReceiver.hex(SHA256.hash(data: out))
        return whole == manifest.sha256OfWholeFile ? out : nil
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// Sender-side helper: build a manifest + chunks from a file's bytes. The
// caller is responsible for actually broadcasting them via BLEMeshEngine in
// the next iteration; this helper makes the manifest authoritative.
enum MeshFileSender {
    static func build(
        fileData: Data,
        senderId: String,
        recipientId: String,
        chunkSize: Int = 4096,
        mimeType: String? = nil,
        fileName: String? = nil
    ) -> (manifest: MeshFileManifest, chunks: [MeshFileChunk])? {
        guard !fileData.isEmpty, chunkSize > 0 else { return nil }
        let totalChunks = Int(ceil(Double(fileData.count) / Double(chunkSize)))
        var perChunkHashes: [String] = []
        var chunks: [MeshFileChunk] = []
        let fileId = UUID().uuidString

        for i in 0..<totalChunks {
            let start = i * chunkSize
            let end = min(start + chunkSize, fileData.count)
            let payload = fileData.subdata(in: start..<end)
            perChunkHashes.append(hex(SHA256.hash(data: payload)))
            chunks.append(MeshFileChunk.make(fileId: fileId, index: i, payload: payload))
        }

        var manifest = MeshFileManifest(
            fileId: fileId,
            senderId: senderId,
            recipientId: recipientId,
            totalSize: fileData.count,
            chunkSize: chunkSize,
            totalChunks: totalChunks,
            sha256OfWholeFile: hex(SHA256.hash(data: fileData)),
            perChunkHashes: perChunkHashes,
            mimeType: mimeType,
            fileName: fileName,
            signature: nil,
            signerPublicKey: nil
        )
        manifest.sign()
        guard manifest.isSignatureValid() else { return nil }
        return (manifest, chunks)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - FoundationAIService (on-device AI for offline)
// ──────────────────────────────────────────────────────────────────────────
//
// Uses iOS 26's `FoundationModels` framework to run smart-reply, summary,
// and other tasks ON-DEVICE — no internet required. For languages Apple's
// model handles less well (e.g. Persian), we pivot through English using
// the Translation framework: detect → translate to EN → run model →
// translate back. The whole flow is offline once the per-language model
// pack has been downloaded once.
//
// Public surface:
//   - `isAvailable` — true on iOS 26+ where the system model is ready
//   - `smartReplies(for:in:)` — 3 suggested replies for the latest incoming message
//   - `summarize(messages:in:)` — short summary of the last N messages
//
// Privacy: Foundation Models runs entirely on-device. No data leaves the
// phone. Translation framework also runs offline once the language pack is
// installed (it prompts the user once, then caches locally).

import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Translation)
import Translation
#endif

@MainActor
@Observable
final class FoundationAIService {
    static let shared = FoundationAIService()
    private init() {}

    /// Whether on-device AI is available on this device. Cached so the UI
    /// can hide AI-only affordances cleanly when running on iOS 17–25.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Human-readable reason on-device AI is *not* fully usable, or `nil`
    /// when it is. Surfaces the specific Apple Intelligence state so the
    /// user knows exactly what to do (enable AI, download model, switch
    /// device, etc.) instead of being told the generic "requires iOS 26".
    ///
    /// Important: `SystemLanguageModel.default.isAvailable` returns `true`
    /// on the iOS Simulator and on early-state devices where the safety /
    /// content-analysis ML still has to download. Generation will then
    /// throw `SensitiveContentAnalysisML` / `ModelManagerServices` errors
    /// at the first request. This getter inspects `availability` (the
    /// richer enum) so the UI can pre-empt that user-visible failure.
    var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is turned off. Enable it in Settings → Apple Intelligence & Siri."
                case .modelNotReady:
                    return "Apple Intelligence is still preparing on this device. Try again in a few minutes."
                case .deviceNotEligible:
                    return "This device doesn't support Apple Intelligence. On-device AI requires iPhone 15 Pro / 16 / 17 or newer."
                @unknown default:
                    return "On-device AI isn't available on this device right now."
                }
            }
        }
        return "On-device AI requires iOS 26 or newer."
        #else
        return "On-device AI requires iOS 26 or newer."
        #endif
    }

    /// True when the model actually claims to be ready AND the device is
    /// in a state where generation should succeed. Same value as
    /// `isAvailable` today, but kept as a separate getter so callers that
    /// gate destructive UI (smart replies, summaries) can switch to a
    /// stricter probe later without auditing every call site.
    var isReadyToGenerate: Bool {
        unavailableReason == nil
    }

    /// Whether the user has explicitly disabled on-device AI in Settings
    /// (privacy-sensitive users can opt out even though it's local-only).
    var userOptIn: Bool {
        get { UserDefaults.standard.object(forKey: "ai.foundation.optin") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ai.foundation.optin") }
    }

    // ─────────────────────────────────────────────────────────────────
    // Smart replies
    // ─────────────────────────────────────────────────────────────────

    /// Suggest 3 short replies to the latest incoming message in the chat.
    /// `recentText` is a thin transcript like:
    ///     "Sarah: Are you coming tonight?"
    ///     "Me: Maybe, what time?"
    ///     "Sarah: 9pm"
    /// We feed the last few exchanges to the model so suggestions match the
    /// conversation tone. Returns at most 3 suggestions; empty array on
    /// failure or unavailable.
    func smartReplies(forIncoming text: String, transcript: String = "") async -> [String] {
        guard userOptIn, isAvailable else { return [] }
        guard !text.isEmpty else { return [] }

        let detected = detectLanguage(text)
        let englishText: String
        if detected.shouldPivot {
            englishText = (await translate(text, from: detected.code, to: "en")) ?? text
        } else {
            englishText = text
        }

        let englishReplies = await generateRepliesEN(message: englishText, transcript: transcript)
        guard !englishReplies.isEmpty else { return [] }

        // Translate back if we pivoted
        if detected.shouldPivot {
            var out: [String] = []
            for r in englishReplies {
                if let translated = await translate(r, from: "en", to: detected.code) {
                    out.append(translated)
                } else {
                    out.append(r)
                }
            }
            return out
        }
        return englishReplies
    }

    /// Why a summary failed — surfaced to the UI so the error message
    /// can be specific instead of the catch-all "enable AI in settings".
    enum SummaryFailure: Error, LocalizedError {
        case userOptedOut
        case unsupportedDevice
        case emptyTranscript
        /// Generation aborted. We hold the raw error for logging (DEBUG
        /// only) but the user sees a clean, mapped message.
        case modelError(description: String)
        /// Apple Intelligence isn't enabled at the system level (covers
        /// the "Settings → Apple Intelligence & Siri is off" path AND the
        /// simulator / early-device path where the safety-content ML
        /// hasn't been downloaded yet — both surface the same way once
        /// generation is attempted).
        case appleIntelligenceNotReady
        /// The on-device safety filter (`SensitiveContentAnalysisML`)
        /// isn't installed. Common on the iOS Simulator and on devices
        /// that haven't completed the Apple Intelligence download. The
        /// language model itself may be present but the safety guard is
        /// not, and Foundation Models refuses to generate without it.
        case safetyModelMissing
        /// The conversation is in a language that Foundation Models
        /// doesn't support AND the Translation pack isn't installed
        /// (e.g. Persian on a device where the user hasn't downloaded
        /// fa↔en yet). User-facing message points to the fix.
        case unsupportedLanguage(code: String)

        var errorDescription: String? {
            switch self {
            case .userOptedOut:
                return "On-device AI is disabled in Settings."
            case .unsupportedDevice:
                return "On-device AI isn't available on this device or iOS version."
            case .emptyTranscript:
                return "Nothing to summarize yet."
            case .modelError:
                // Don't leak the raw NSError chain to the user — that's
                // what produced the wall-of-text bug. Diagnostic detail
                // is in the debug log via NSLog at the call site.
                return "On-device AI couldn't summarize this chat. Try again in a moment."
            case .appleIntelligenceNotReady:
                return "Apple Intelligence isn't ready on this device. Enable it in Settings → Apple Intelligence & Siri, or wait for the on-device model to finish downloading."
            case .safetyModelMissing:
                return "Apple Intelligence safety model isn't installed yet. This is normal on the iOS Simulator and on devices that just enabled Apple Intelligence — try again on a real device, or wait for the download to finish."
            case .unsupportedLanguage(let code):
                let name = Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
                return "On-device AI doesn't support \(name) yet. Install the \(name)→English translation pack in Settings → General → Language & Region → Translation Languages, then try again."
            }
        }
    }

    /// Map a raw error from `LanguageModelSession.respond` into a user-
    /// safe `SummaryFailure`. Inspects the underlying-error chain so we
    /// can distinguish "safety filter missing" from "model crashed mid-
    /// generation" without showing the whole NSError dump.
    private func mapGenerationError(_ error: Error) -> SummaryFailure {
        let nsError = error as NSError
        let chainText = describeErrorChain(nsError)

        // Known Apple Intelligence subsystems that surface as nested
        // underlying errors when the on-device stack isn't fully ready.
        if chainText.contains("SensitiveContentAnalysisML") ||
           chainText.contains("ModelManagerError") ||
           chainText.contains("ModelManagerServices") {
            return .safetyModelMissing
        }
        if chainText.contains("appleIntelligenceNotEnabled") ||
           chainText.contains("notEnabled") {
            return .appleIntelligenceNotReady
        }
        if chainText.contains("unsupportedLanguageOrLocale") {
            // Caller decides which language code to surface; we only
            // signal that it was a language issue. The summarize path
            // overrides this with the actual detected code.
            return .unsupportedLanguage(code: "und")
        }
        return .modelError(description: chainText)
    }

    /// Flatten an NSError + its `NSUnderlyingError` chain into a single
    /// string for keyword matching. We DO NOT show this to the user —
    /// it's only used for `String.contains(...)` discrimination above.
    private func describeErrorChain(_ error: NSError) -> String {
        var parts: [String] = []
        var current: NSError? = error
        var depth = 0
        while let e = current, depth < 8 {
            parts.append("\(e.domain) \(e.code)")
            if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError {
                current = underlying
            } else if let multi = e.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError],
                      let first = multi.first {
                current = first
            } else {
                current = nil
            }
            depth += 1
        }
        return parts.joined(separator: " | ")
    }

    /// Summarize the last N messages of a conversation in the user's language.
    /// Pivots through English when needed so the model handles every language.
    func summarize(transcript: String, language: String? = nil) async -> Result<String, SummaryFailure> {
        guard userOptIn else { return .failure(.userOptedOut) }
        guard !transcript.isEmpty else { return .failure(.emptyTranscript) }
        // Pre-flight: bail before talking to FoundationModels if Apple
        // Intelligence isn't actually able to generate. `isAvailable`
        // alone returns true on devices where the safety-content ML
        // hasn't downloaded yet — we already saw `respond` throw the
        // raw NSError chain in that case. Surface the specific reason.
        if let reason = unavailableReason {
            if reason.contains("safety") { return .failure(.safetyModelMissing) }
            if reason.contains("Apple Intelligence") { return .failure(.appleIntelligenceNotReady) }
            return .failure(.unsupportedDevice)
        }

        let lang = language ?? detectLanguage(transcript).code
        let shouldPivot = (lang != "en" && lang != "und" && needsPivot(lang))

        let englishTranscript: String
        if shouldPivot {
            // Try Persian/Pashto/etc. → English. If the Translation
            // pack isn't installed `translate` returns nil — at that
            // point we MUST NOT fall through to FoundationModels with
            // the original-language text, because it'll throw
            // `unsupportedLanguageOrLocale` and the user sees a
            // cryptic error. Bail out cleanly instead so the UI can
            // tell the user how to install the pack.
            if let translated = await translate(transcript, from: lang, to: "en") {
                englishTranscript = translated
            } else {
                return .failure(.unsupportedLanguage(code: lang))
            }
        } else {
            englishTranscript = transcript
        }

        switch await summarizeENResult(transcript: englishTranscript) {
        case .success(let englishSummary):
            if shouldPivot {
                return .success((await translate(englishSummary, from: "en", to: lang)) ?? englishSummary)
            }
            return .success(englishSummary)
        case .failure(.unsupportedLanguage):
            // The mapper signals "language" without knowing which one — we
            // do, so substitute the actual detected code so the error
            // message points to the right Settings pane.
            return .failure(.unsupportedLanguage(code: lang))
        case .failure(let err):
            return .failure(err)
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Foundation Models — English-only generation
    // ─────────────────────────────────────────────────────────────────

    private func generateRepliesEN(message: String, transcript: String) async -> [String] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            // Smart-reply chips silently disappear when the model isn't
            // ready — we don't want to interrupt the chat composer with
            // a popup, so just return [] and let the UI hide the row.
            guard isReadyToGenerate else { return [] }
            do {
                let session = LanguageModelSession(instructions: """
                You suggest 3 short, natural reply options for a chat. Each \
                reply MUST be under 40 characters and sound like something a \
                real person would type. No emojis unless they fit. \
                Output exactly one JSON object: {"replies": ["...", "...", "..."]} \
                with no other text.
                """)
                let prompt: String = transcript.isEmpty
                    ? "Reply to: \"\(message)\""
                    : "Conversation so far:\n\(transcript)\n\nReply to the LAST incoming message: \"\(message)\""
                let response = try await session.respond(to: prompt)
                let text = response.content
                // Parse the embedded JSON object — model occasionally wraps
                // it in prose, so we extract from the first { to last }.
                if let jsonStart = text.firstIndex(of: "{"),
                   let jsonEnd = text.lastIndex(of: "}"),
                   jsonStart <= jsonEnd {
                    let json = String(text[jsonStart...jsonEnd])
                    struct R: Decodable { let replies: [String] }
                    if let data = json.data(using: .utf8),
                       let parsed = try? JSONDecoder().decode(R.self, from: data) {
                        return Array(parsed.replies.prefix(3))
                    }
                }
                // Fallback: split on newlines / numbers
                let tokens = text.split(whereSeparator: { $0.isNewline })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•1234567890.\"")) }
                    .filter { !$0.isEmpty }
                return Array(tokens.prefix(3))
            } catch {
                #if DEBUG
                print("⚠️ [FoundationAI] smart-reply failed: \(error)")
                #endif
                return []
            }
        }
        #endif
        return []
    }

    /// Backwards-compatible wrapper retained for any caller that
    /// still expects an optional. New code should call `summarize`
    /// (which returns a Result) so failures are introspectable.
    private func summarizeEN(transcript: String) async -> String? {
        if case .success(let s) = await summarizeENResult(transcript: transcript) {
            return s
        }
        return nil
    }

    /// Same as `summarizeEN` but propagates the underlying error so
    /// the UI can show a precise message. The `print` keeps a
    /// breadcrumb in `Console.app` regardless of build configuration
    /// — without it, debugging "AI says it failed but I don't know
    /// why" requires re-running with a debug build.
    private func summarizeENResult(transcript: String) async -> Result<String, SummaryFailure> {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            // Pre-flight: even when `isAvailable` is true, Apple
            // Intelligence may be in a partial state (e.g. simulator with
            // no safety-content ML downloaded). Surface a clean reason
            // instead of letting `respond` throw the layered NSError.
            if let reason = unavailableReason {
                if reason.contains("safety") { return .failure(.safetyModelMissing) }
                return .failure(.appleIntelligenceNotReady)
            }
            do {
                let session = LanguageModelSession(instructions: """
                You write tight, neutral chat summaries in 2-3 sentences. \
                Focus on decisions, plans, and unanswered questions. Skip greetings.
                """)
                let response = try await session.respond(
                    to: "Summarize this conversation:\n\n\(transcript)"
                )
                let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return .failure(.modelError(description: "empty"))
                }
                return .success(trimmed)
            } catch {
                #if DEBUG
                NSLog("⚠️ [FoundationAI] summarize threw: %@", String(describing: error))
                #endif
                return .failure(mapGenerationError(error))
            }
        }
        #endif
        return .failure(.unsupportedDevice)
    }

    // ─────────────────────────────────────────────────────────────────
    // Language detection + translation pivot
    // ─────────────────────────────────────────────────────────────────

    private struct LangResult {
        let code: String        // ISO 639-1, e.g. "fa", "en", "ar", "und"
        let shouldPivot: Bool   // true if we should translate to EN first
    }

    private func detectLanguage(_ text: String) -> LangResult {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let lang = recognizer.dominantLanguage?.rawValue ?? "und"
        return LangResult(code: lang, shouldPivot: needsPivot(lang))
    }

    /// Languages where the on-device foundation model is known to be weaker
    /// (or where Apple's English model gives substantially better outputs).
    /// We pivot via English Translation for these.
    private func needsPivot(_ langCode: String) -> Bool {
        let pivotSet: Set<String> = [
            "fa",   // Persian / Farsi
            "ps",   // Pashto
            "ku",   // Kurdish
            "ur",   // Urdu
            "az",   // Azerbaijani
            "tk",   // Turkmen
            "ta",   // Tamil
            "te",   // Telugu
            "ml",   // Malayalam
            "my",   // Burmese
            "km",   // Khmer
            "lo",   // Lao
            "si",   // Sinhala
            "und",  // Unknown — be conservative
        ]
        return pivotSet.contains(langCode)
    }

    /// Translate text using iOS 18+ Translation framework. Falls back to
    /// returning nil (caller will use original text) when the framework
    /// isn't available or the language pair isn't installed.
    private func translate(_ text: String, from sourceCode: String, to targetCode: String) async -> String? {
        #if canImport(Translation)
        // Translation framework requires iOS 18 / macCatalyst 26 — older
        // Catalyst SDKs don't expose the symbol at all (the framework only
        // shipped to Mac in macOS 26 Tahoe).
        if #available(iOS 18.0, macCatalyst 26.0, *) {
            // The TranslationSession API is presented via SwiftUI's
            // .translationTask modifier in normal use. For service-layer
            // calls, we route through the underlying configuration.
            let source = Locale.Language(identifier: sourceCode)
            let target = Locale.Language(identifier: targetCode)
            let configuration = TranslationSession.Configuration(source: source, target: target)
            // Wait for the session to be ready. The first call may prompt
            // the user to download the language pack; subsequent calls are
            // pure on-device.
            return await withCheckedContinuation { continuation in
                Task { @MainActor in
                    let host = _TranslationHost(text: text, configuration: configuration) { result in
                        continuation.resume(returning: result)
                    }
                    host.kick()
                }
            }
        }
        #endif
        return nil
    }
}

#if canImport(Translation)
@available(iOS 18.0, macCatalyst 26.0, *)
@MainActor
private final class _TranslationHost {
    let text: String
    let configuration: TranslationSession.Configuration
    let completion: (String?) -> Void
    private var done = false

    init(text: String, configuration: TranslationSession.Configuration, completion: @escaping (String?) -> Void) {
        self.text = text
        self.configuration = configuration
        self.completion = completion
    }

    func kick() {
        // The headless `TranslationSession(installedSource:target:)`
        // initializer is iOS 26+ only. On iOS 18-25 the canonical API is
        // SwiftUI's `.translationTask`, which has to be hosted in a View
        // — not callable from a service layer. For now we only attempt
        // translation on iOS 26+; older versions just return nil so the
        // caller falls back to the original text and the model handles
        // the language directly (Apple's foundation model is multilingual).
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            Task {
                do {
                    let source = configuration.source ?? .init(identifier: "en")
                    let target = configuration.target ?? .init(identifier: "en")
                    let session = TranslationSession(installedSource: source, target: target)
                    let response = try await session.translate(text)
                    if !done {
                        done = true
                        completion(response.targetText)
                    }
                } catch {
                    if !done {
                        done = true
                        completion(nil)
                    }
                }
            }
        } else {
            done = true
            completion(nil)
        }
    }
}
#endif

// ──────────────────────────────────────────────────────────────────────────
// MARK: - SmartReplyChips View (in-chat AI suggestions)
// ──────────────────────────────────────────────────────────────────────────
//
// Renders 3 capsule chips above the chat input bar showing AI-generated
// reply suggestions. Tap → fills inputText. Refreshes when a new incoming
// message arrives. Hides itself when the user has typed something OR when
// AI is unavailable.

struct SmartReplyChips: View {
    /// Latest 3 suggestions from the model.
    @State private var suggestions: [String] = []
    @State private var isLoading = false

    /// Most recent incoming message (the one we're suggesting replies for).
    let incomingText: String?
    /// Optional short transcript for context.
    let transcript: String
    /// Bound input text — tapping a chip fills this.
    @Binding var inputText: String
    /// Hide ourselves while the user is typing.
    let userIsTyping: Bool

    @State private var ai = FoundationAIService.shared

    var body: some View {
        let shouldShow = ai.isAvailable && ai.userOptIn
            && !userIsTyping
            && (incomingText?.isEmpty == false)
            && !suggestions.isEmpty

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        Haptics.light()
                        inputText = suggestion
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.purple)
                            Text(suggestion)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassSurface(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(height: shouldShow ? 38 : 0)
        .opacity(shouldShow ? 1 : 0)
        .animation(.easeInOut(duration: 0.22), value: shouldShow)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: suggestions)
        .onChange(of: incomingText ?? "") { _, new in
            Task { await refresh(for: new) }
        }
        .task {
            if let t = incomingText, !t.isEmpty { await refresh(for: t) }
        }
    }

    private func refresh(for text: String) async {
        guard !text.isEmpty else { suggestions = []; return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let replies = await ai.smartReplies(forIncoming: text, transcript: transcript)
        // Only update if this is still the most recent incoming text.
        if text == incomingText {
            suggestions = replies
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - ChatSummarySheet (AI-generated conversation summary)
// ──────────────────────────────────────────────────────────────────────────

struct ChatSummarySheet: View {
    let transcript: String
    @Environment(\.dismiss) private var dismiss
    @State private var summary: String? = nil
    @State private var failure: FoundationAIService.SummaryFailure? = nil
    @State private var isLoading = true
    @State private var ai = FoundationAIService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                        Text("On-device summary")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isLoading { ProgressView().scaleEffect(0.7) }
                    }

                    if let summary = summary {
                        Text(summary)
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else if let failure = failure {
                        // Surface the specific reason — generic "enable
                        // AI in Settings" was hiding real failures
                        // (model warm-up, content filter, transient
                        // errors) and gas-lighting users who already
                        // had AI enabled.
                        VStack(alignment: .leading, spacing: 10) {
                            Text(failure.errorDescription ?? "On-device AI couldn't summarize this chat.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            if case .modelError = failure {
                                Button {
                                    Task { await runSummary() }
                                } label: {
                                    Label("Try Again", systemImage: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    Text("Generated entirely on this device. Nothing about your messages is sent to a server.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                .padding(20)
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await runSummary() }
        }
    }

    private func runSummary() async {
        isLoading = true
        summary = nil
        failure = nil
        switch await ai.summarize(transcript: transcript) {
        case .success(let text):
            summary = text
        case .failure(let err):
            failure = err
        }
        isLoading = false
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - DiagnosticsService (MetricKit-based crash + perf reports)
// ──────────────────────────────────────────────────────────────────────────
//
// Subscribes to Apple's `MetricKit`, which fires once per day with a
// `MXDiagnosticPayload` containing every crash, hang, CPU exception, and
// disk-write exception that occurred in the previous 24h. We forward each
// report to /api/diagnostics so we can see prod issues without a third-
// party SDK like Sentry/Bugsnag/Crashlytics.
//
// Cost vs. Sentry:
//   * Sentry: external service, network round-trip per breadcrumb, ~200 KB
//     framework, real-time delivery, full stack trace symbolication.
//   * MetricKit: free, on-device, no SDK, batched once per day, includes
//     stack traces + memory state + thread state.
//
// MetricKit is "good enough" for prod monitoring; you can always add Sentry
// later (drop in `Sentry.start { … }` next to the call below).

import MetricKit

@MainActor
final class DiagnosticsService: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsService()

    private override init() { super.init() }

    func start() {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        MXMetricManager.shared.add(self)
    }

    // MARK: MXMetricManagerSubscriber

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metrics — not crashes. We don't forward these for now;
        // if you want app-perf telemetry later, hook this up.
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            self.forward(payload)
        }
    }

    // MARK: Forwarding

    nonisolated private func forward(_ payload: MXDiagnosticPayload) {
        guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
        let summaries: [(String, String, Date)] = Self.extract(payload: payload)
        guard !summaries.isEmpty else { return }

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { v -> String in
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            return build.isEmpty ? v : "\(v) (\(build))"
        } ?? "?"
        let bigPayloadB64 = payload.jsonRepresentation()
            .base64EncodedString()

        for (type, summary, occurredAt) in summaries {
            Task { @MainActor in
                guard RavenRuntimePolicy.allowsExternalSideEffects else { return }
                // UIDevice.current is MainActor-isolated, so capture device/os
                // strings here rather than from the surrounding nonisolated
                // context (which would fail to compile under Swift 6).
                let device = UIDevice.current.modelIdentifier ?? UIDevice.current.model
                let os = "iOS \(UIDevice.current.systemVersion)"

                struct Body: Encodable {
                    let type: String
                    let occurredAt: Date
                    let appVersion: String?
                    let osVersion: String?
                    let deviceModel: String?
                    let sessionId: String?
                    let summary: String?
                    let payloadB64: String?
                }
                struct Resp: Decodable { let status: String }
                let body = Body(
                    type: type,
                    occurredAt: occurredAt,
                    appVersion: appVersion,
                    osVersion: os,
                    deviceModel: device,
                    sessionId: CrashGuard.shared.sessionIdString,
                    summary: summary,
                    payloadB64: bigPayloadB64.isEmpty ? nil : bigPayloadB64
                )
                _ = try? await NetworkService.shared.post(path: "/api/diagnostics", body: body) as Resp
            }
        }
    }

    /// Pull a (type, short-summary, occurred-at) tuple for every diagnostic
    /// inside the bundled MXDiagnosticPayload.
    nonisolated private static func extract(payload: MXDiagnosticPayload) -> [(String, String, Date)] {
        var out: [(String, String, Date)] = []
        let occurred = payload.timeStampEnd

        for crash in payload.crashDiagnostics ?? [] {
            let signal = crash.exceptionType?.intValue ?? 0
            let code = crash.exceptionCode?.intValue ?? 0
            out.append(("crash", "Signal \(signal) code \(code)", occurred))
        }
        for hang in payload.hangDiagnostics ?? [] {
            let dur = hang.hangDuration.converted(to: .seconds).value
            out.append(("hang", "Hang \(String(format: "%.2f", dur))s", occurred))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            let total = cpu.totalCPUTime.converted(to: .seconds).value
            out.append(("cpu", "CPU exception \(String(format: "%.0f", total))s", occurred))
        }
        for disk in payload.diskWriteExceptionDiagnostics ?? [] {
            let mb = disk.totalWritesCaused.converted(to: .megabytes).value
            out.append(("disk", "Disk write exception \(String(format: "%.0f", mb))MB", occurred))
        }
        return out
    }
}

private extension UIDevice {
    /// Hardware identifier (e.g. "iPhone17,1") rather than the friendly
    /// `model` string ("iPhone").
    var modelIdentifier: String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce("") { id, element in
            guard let v = element.value as? Int8, v != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(v)))
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - AI Settings View
// ──────────────────────────────────────────────────────────────────────────

struct AISettingsView: View {
    @State private var ai = FoundationAIService.shared
    @State private var optIn: Bool = FoundationAIService.shared.userOptIn

    // Diagnostic test state — surfaces the EXACT failure path so the
    // user can copy/paste a screenshot if the support team needs to
    // debug from a real device.
    @State private var diagnosticBusy = false
    @State private var diagnosticResult: String?
    @State private var diagnosticError: String?

    private var iOSVersion: String { UIDevice.current.systemVersion }
    private var deviceModel: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.compactMap { ($0.value as? Int8).flatMap { $0 != 0 ? UnicodeScalar(UInt8($0)) : nil } }.map { String($0) }.joined()
        return id
    }
    private var preferredLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable on-device AI", isOn: $optIn)
                    .onChange(of: optIn) { _, new in ai.userOptIn = new }
            } header: {
                Text("Smart features")
            } footer: {
                Text("Suggested replies, summaries, and translations run entirely on your iPhone using Apple's on-device foundation model. Nothing about your messages leaves the device.")
                    .font(.caption)
            }

            Section {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("Smart replies")
                    Spacer()
                    Image(systemName: optIn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(optIn ? .green : .secondary)
                }
                HStack {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(.purple)
                    Text("Conversation summary")
                    Spacer()
                    Image(systemName: optIn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(optIn ? .green : .secondary)
                }
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(.purple)
                    Text("Multi-language pivot")
                    Spacer()
                    Image(systemName: optIn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(optIn ? .green : .secondary)
                }
            } header: {
                Text("Features")
            } footer: {
                Text("For languages where Apple's model is weaker (Persian, Pashto, Urdu, Tamil, etc.), Raven automatically translates to English on-device, runs the model, and translates back. The pivot is invisible — replies appear in your original language.")
                    .font(.caption)
            }

            Section {
                if let reason = ai.unavailableReason {
                    // Specific failure reason (Apple Intelligence off,
                    // safety model still downloading, device ineligible,
                    // …) so the user knows what to fix instead of getting
                    // the generic "requires iOS 26".
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                    if reason.contains("Apple Intelligence is turned off") {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Open iOS Settings", systemImage: "arrow.up.forward.app")
                                .font(.caption)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("Foundation model is ready")
                            .font(.caption)
                    }
                }
            } header: {
                Text("Status")
            }

            // Diagnostic panel — shows the runtime info we'd otherwise
            // have to ask the user to dig out of Settings. If summarize
            // fails on their device, the support thread gets answered
            // by a screenshot of THIS section instead of a back-and-
            // forth on iOS version / region / device model.
            Section {
                LabeledContent("Device", value: deviceModel)
                LabeledContent("iOS", value: iOSVersion)
                LabeledContent("Language", value: preferredLanguage)
                LabeledContent("Region", value: Locale.current.region?.identifier ?? "—")
                if needsTranslationPivot(preferredLanguage) {
                    Label("Your language pivots through English. The Translation pack must be installed in Settings → General → Language & Region → Translation Languages.",
                          systemImage: "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await runDiagnostic() }
                } label: {
                    HStack {
                        if diagnosticBusy {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(diagnosticBusy ? "Testing…" : "Run AI test")
                    }
                    .font(.caption)
                }
                .disabled(diagnosticBusy)

                if let result = diagnosticResult {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let error = diagnosticError {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("If chat summarize / smart-reply fails, tap Run AI test and share a screenshot of this section with support.")
                    .font(.caption2)
            }
        }
        .navigationTitle("On-device AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func needsTranslationPivot(_ lang: String) -> Bool {
        // Mirrors `FoundationAIService.needsPivot` so we can hint the
        // user without exposing the private API.
        ["fa","ps","ku","ur","az","tk","ta","te","ml","my","km","lo","si","und"].contains(lang)
    }

    private func runDiagnostic() async {
        diagnosticBusy = true
        diagnosticResult = nil
        diagnosticError = nil
        defer { diagnosticBusy = false }

        // Tiny canned transcript so the test is fast and deterministic.
        // We feed it in the user's preferred language so we exercise the
        // pivot path that real chats hit.
        let transcript: String
        switch preferredLanguage {
        case "fa": transcript = "Salam, sa'at chand mibinamet?\n— Sa'at 9 shab. \n— Bashe, miam."
        case "ar": transcript = "مرحبا، متى نلتقي؟ — الساعة 9 مساءً. — حسنًا."
        default:   transcript = "Hi, what time should we meet?\n— 9 PM.\n— Cool, see you then."
        }

        switch await ai.summarize(transcript: transcript, language: preferredLanguage) {
        case .success(let s):
            diagnosticResult = "Summary: " + s.prefix(120)
        case .failure(let f):
            diagnosticError = f.errorDescription ?? "Unknown failure"
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────
// MARK: - Concert Mode (auto-group everyone at a venue)
// ──────────────────────────────────────────────────────────────────────────
//
// Tap → app fetches the user's coarse location, POSTs to /api/concert-mode/join
// → server returns the ephemeral group ID for the geo-cell. The user is
// added as a member, lands in the group chat. Group auto-expires after 12h.

import CoreLocation

@MainActor
@Observable
final class ConcertModeService: NSObject {
    static let shared = ConcertModeService()

    struct JoinResult: Decodable {
        let groupId: String
        let name: String
        let h3Cell: String
        let expiresAt: Date
        let isNew: Bool
        let memberCount: Int
    }

    var lastJoin: JoinResult?
    var error: String?
    var isJoining = false

    private let manager = CLLocationManager()
    private var oneShotContinuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Public entry point: requests permission if needed, gets a single
    /// fresh location fix, calls /api/concert-mode/join, and stores the
    /// returned group on `lastJoin`.
    func joinNearby() async {
        isJoining = true
        defer { isJoining = false }
        error = nil
        do {
            let loc = try await currentLocation()
            struct Body: Encodable { let lat: Double; let lng: Double }
            let body = Body(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
            let result: JoinResult = try await NetworkService.shared.post(
                path: "/api/concert-mode/join", body: body
            )
            lastJoin = result
        } catch {
            self.error = error.localizedDescription
            #if DEBUG
            print("⚠️ [ConcertMode] join failed: \(error)")
            #endif
        }
    }

    /// One-shot location fetch with proper permission handling and timeout.
    ///
    /// Previously this fired `requestWhenInUseAuthorization()` and then
    /// **immediately** called `requestLocation()` without waiting for the
    /// user to tap Allow on the iOS dialog. The continuation could hang
    /// forever — UI got stuck on "Finding your venue…". Now we:
    ///   1. Await the permission decision before calling `requestLocation`
    ///   2. Apply a 15s timeout so a stuck GPS / indoor scenario surfaces
    ///      a real error message instead of a silent spinner.
    private func currentLocation() async throws -> CLLocation {
        // 1. Make sure location services are on at the system level.
        guard CLLocationManager.locationServicesEnabled() else {
            throw NSError(domain: "ConcertMode", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Location Services are turned off in iOS Settings. Turn them on to use Concert Mode."])
        }

        // 2. Resolve permission. WAIT for the system dialog if needed.
        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus, Never>) in
                self.authContinuation = cont
                manager.requestWhenInUseAuthorization()
            }
        }
        switch status {
        case .denied, .restricted:
            throw NSError(domain: "ConcertMode", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Location permission denied. Allow it in iOS Settings → RAVEN → Location."])
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .notDetermined:
            // User dismissed the dialog without choosing — treat as denial.
            throw NSError(domain: "ConcertMode", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Permission not granted. Tap Allow next time to use Concert Mode."])
        @unknown default:
            throw NSError(domain: "ConcertMode", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown location permission state."])
        }

        // 3. Request location with a 15s timeout. `requestLocation()` can
        //    silently never fire if iOS is having a bad day (no GPS lock,
        //    simulator without a simulated location, etc.) — without a
        //    timeout the spinner would spin forever.
        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw CancellationError() }
                return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
                    Task { @MainActor in
                        // If a previous attempt left a stale continuation, fail it.
                        if let stale = self.oneShotContinuation {
                            self.oneShotContinuation = nil
                            stale.resume(throwing: CancellationError())
                        }
                        self.oneShotContinuation = cont
                        self.manager.requestLocation()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000) // 15s
                throw NSError(domain: "ConcertMode", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Couldn't get a location fix. Try moving outside or near a window."])
            }
            // First task to finish wins.
            do {
                let loc = try await group.next()!
                group.cancelAll()
                return loc
            } catch {
                group.cancelAll()
                // Make sure we don't leak a continuation if the timeout won.
                await MainActor.run {
                    if let stale = self.oneShotContinuation {
                        self.oneShotContinuation = nil
                        stale.resume(throwing: error)
                    }
                }
                throw error
            }
        }
    }
}

extension ConcertModeService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if let cont = self.oneShotContinuation, let loc = locations.last {
                self.oneShotContinuation = nil
                cont.resume(returning: loc)
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let cont = self.oneShotContinuation {
                self.oneShotContinuation = nil
                cont.resume(throwing: error)
            }
        }
    }
    /// Wake up `currentLocation()` once the user has answered the dialog.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if let cont = self.authContinuation {
                self.authContinuation = nil
                cont.resume(returning: status)
            }
        }
    }
}

struct ConcertModeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = ConcertModeService.shared
    /// Called with the joined groupId so the parent can route to chat.
    var onJoined: (String) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "music.mic.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(
                            LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .padding(.top, 24)

                    Text("Concert Mode")
                        .font(.title.bold())

                    Text("Tap below and you'll be auto-added to a private group with everyone else within ~150 m. Works even without internet, via Bluetooth mesh.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    if let result = service.lastJoin {
                        VStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.2.fill")
                                    .foregroundStyle(.pink)
                                Text("\(result.memberCount) \(result.memberCount == 1 ? "person" : "people") joined")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            Text(result.isNew ? "You started this group" : "Active group at this venue")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 20)

                        Button {
                            onJoined(result.groupId)
                            dismiss()
                        } label: {
                            Text("Open the group")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .glassAccent(in: Capsule())
                        .padding(.horizontal, 20)
                    } else if let err = service.error {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                            .multilineTextAlignment(.center)

                        Button {
                            Task { await service.joinNearby() }
                        } label: {
                            HStack { Image(systemName: "arrow.clockwise"); Text("Retry") }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .glassSurface(in: Capsule())
                        .padding(.horizontal, 20)
                    } else {
                        Button {
                            Haptics.medium()
                            Task { await service.joinNearby() }
                        } label: {
                            HStack(spacing: 8) {
                                if service.isJoining {
                                    ProgressView().tint(.white).scaleEffect(0.85)
                                } else {
                                    Image(systemName: "music.mic")
                                }
                                Text(service.isJoining ? "Finding your venue…" : "Join the venue")
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .disabled(service.isJoining)
                        .glassAccent(in: Capsule())
                        .padding(.horizontal, 20)
                    }

                    Text("Group auto-expires after 12 hours. End-to-end encrypted with a per-group key.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Concert Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - People Nearby Sheet
struct NearbyPeopleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = NearbyService.shared
    var onStartChat: (String) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            Group {
                if service.people.isEmpty {
                    if service.isLoading {
                        ProgressView("Scanning…")
                    } else {
                        ContentUnavailableView(
                            "No one nearby",
                            systemImage: "antenna.radiowaves.left.and.right.slash",
                            description: Text("Bring two Raven devices within Bluetooth range and they'll appear here — even with no internet.")
                        )
                    }
                } else {
                    List(service.people) { person in
                        Button {
                            onStartChat(person.userId)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                GlassAvatar(
                                    name: person.displayName ?? person.username,
                                    path: person.avatarPath, size: 40, showGlow: false
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(person.displayName ?? person.username)
                                            .font(.system(size: 15, weight: .semibold))
                                        if person.isFriend {
                                            Image(systemName: "checkmark.seal.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    Text("@\(person.username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.green)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("People Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await service.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await service.refresh() }
            .refreshable { await service.refresh() }
        }
    }
}
