// RAVEN - Shared UI Components
// Liquid Glass design system converted from Flutter

import SwiftUI

// MARK: - Liquid Glass Container
struct LiquidGlassContainer<Content: View>: View {
    let content: Content
    var cornerRadius: CGFloat = 20
    var padding: CGFloat = 16
    
    init(cornerRadius: CGFloat = 20, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(padding)
            // Apple Native Liquid Glass Effect (iOS 26+)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Liquid Glass Button
struct LiquidGlassButton: View {
    let title: String
    var icon: String?
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    if let icon = icon {
                        Image(systemName: icon)
                    }
                    Text(title)
                }
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                Group {
                    if isDisabled {
                        Color.gray.opacity(0.5)
                    } else {
                        LinearGradient(
                            colors: [.ravenPrimary, .ravenSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }
            )
            .cornerRadius(12)
            .shadow(color: isDisabled ? .clear : .ravenPrimary.opacity(0.3), radius: 8, y: 4)
        }
        .disabled(isDisabled || isLoading)
    }
}

// MARK: - Glass Text Field
struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    
    var body: some View {
        HStack(spacing: 12) {
            if let icon = icon {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .frame(width: 20)
            }
            
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
            }
        }
        .padding()
        // Apple Native Liquid Glass Effect (iOS 26+)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Badge Capsule
struct BadgeCapsule: View {
    let text: String
    var color: Color = .ravenPrimary
    var size: BadgeSize = .medium
    
    enum BadgeSize {
        case small, medium, large
        
        var font: Font {
            switch self {
            case .small: return .caption2
            case .medium: return .caption
            case .large: return .subheadline
            }
        }
        
        var padding: EdgeInsets {
            switch self {
            case .small: return EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
            case .medium: return EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            case .large: return EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            }
        }
    }
    
    var body: some View {
        Text(text)
            .font(size.font.bold())
            .foregroundColor(.white)
            .padding(size.padding)
            .background(color)
            .clipShape(Capsule())
    }
}

// MARK: - Icon Badge
struct IconBadge: View {
    let icon: String
    var count: Int = 0
    var color: Color = .red
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: icon)
                .font(.title2)
            
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(color)
                    .clipShape(Capsule())
                    .offset(x: 8, y: -8)
            }
        }
    }
}

// MARK: - Loading Overlay
struct LoadingOverlay: View {
    var message: String?
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                
                if let message = message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
            }
            .padding(32)
            .glassBackground(cornerRadius: 16)
        }
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)?
    var actionTitle: String?
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.ravenPrimary.opacity(0.8), .ravenPrimary.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            if let action = action, let actionTitle = actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.ravenPrimary)
                        .cornerRadius(12)
                }
                .padding(.top, 8)
            }
        }
        .padding(32)
    }
}

// MARK: - Network Status Banner
struct NetworkStatusBanner: View {
    @ObservedObject var networkMonitor = NetworkMonitor.shared
    
    var body: some View {
        if !networkMonitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text("No Internet Connection")
                Spacer()
                Text("Mesh Mode Active")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange)
                    .cornerRadius(8)
            }
            .font(.subheadline)
            .foregroundColor(.white)
            .padding()
            .background(Color.red.opacity(0.9))
        }
    }
}

// MARK: - Pull to Refresh Header
struct RefreshHeader: View {
    var isRefreshing: Bool
    
    var body: some View {
        HStack {
            Spacer()
            if isRefreshing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                Text("Pull to refresh")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Skeleton Loading
struct SkeletonView: View {
    var width: CGFloat?
    var height: CGFloat = 16
    var cornerRadius: CGFloat = 4
    
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(UIColor.systemGray5))
            .frame(width: width, height: height)
            .shimmer()
    }
}

// MARK: - Toast
struct ToastView: View {
    let message: String
    var type: ToastType = .info
    
    enum ToastType {
        case success, error, info, warning
        
        var color: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            case .info: return .blue
            case .warning: return .orange
            }
        }
        
        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: type.icon)
                .foregroundColor(type.color)
            
            Text(message)
                .font(.subheadline)
        }
        .padding()
        // Apple Native Liquid Glass Effect (iOS 26+)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
    }
}

#Preview {
    VStack(spacing: 20) {
        LiquidGlassContainer {
            Text("Glass Container")
        }
        
        LiquidGlassButton(title: "Sign In", icon: "arrow.right") {}
        
        GlassTextField(placeholder: "Username", text: .constant(""), icon: "person")
        
        BadgeCapsule(text: "New")
        
        EmptyStateView(
            icon: "bubble.left.and.bubble.right",
            title: "No Messages",
            message: "Start a conversation!",
            action: {},
            actionTitle: "New Chat"
        )
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
