import SwiftUI

// MARK: - Glass Navigation Bar
/// Consistent header for all detail pages.
///
/// Layout: `[← Back]  [Title / Subtitle]  [Action]`
///
/// Usage:
/// ```swift
/// GlassNavBar(title: "Post", subtitle: "@username") {
///     dismiss()
/// } trailing: {
///     Button { ... } label: { Image(systemName: "ellipsis") }
/// }
/// ```
struct GlassNavBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    
    var body: some View {
        HStack(spacing: DS.space12) {
            // Back button
            if let onBack {
                Button {
                    Haptics.light()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: DS.navButtonSize, height: DS.navButtonSize)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            
            Spacer()
            
            // Center title
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Trailing action (same width as back button for centering)
            trailing()
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: DS.navButtonSize, height: DS.navButtonSize)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.horizontal, DS.space16)
        .padding(.top, DS.space8)
        .padding(.bottom, DS.space12)
        .frame(maxWidth: .infinity)
        .background(
            .ultraThinMaterial
                .shadow(.drop(color: .black.opacity(0.06), radius: 8, y: 4))
        )
    }
}

// MARK: - Convenience init when no trailing button
extension GlassNavBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, onBack: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.trailing = { EmptyView() }
    }
}

#Preview {
    VStack {
        GlassNavBar(title: "Post", subtitle: "@ahmd") {
            // dismiss
        } trailing: {
            Button {} label: { Image(systemName: "ellipsis") }
        }
        Spacer()
    }
    .background(Color.black)
}
