import SwiftUI

// MARK: - Design Settings View
struct DesignSettingsView: View {
    @State private var settings = AppSettings.shared
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Text Size Section
                SettingsSection(title: "Text Size") {
                    VStack(spacing: 0) {
                        ForEach(AppSettings.TextSize.allCases, id: \.rawValue) { size in
                            TextSizeRow(
                                size: size,
                                isSelected: settings.textSize == size,
                                onSelect: {
                                    Haptics.selection()
                                    settings.textSize = size
                                }
                            )
                            
                            if size != AppSettings.TextSize.allCases.last {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                            }
                        }
                    }
                }
                
                // Text Size Preview
                TextSizePreview(scaleFactor: settings.textScaleFactor)
                    .padding(.horizontal, 4)
                
                // Message Corners Section
                SettingsSection(title: "Message Corners") {
                    VStack(spacing: 0) {
                        ForEach(AppSettings.MessageCornerStyle.allCases, id: \.rawValue) { style in
                            MessageCornerRow(
                                style: style,
                                isSelected: settings.messageCornerStyle == style,
                                onSelect: {
                                    Haptics.selection()
                                    settings.messageCornerStyle = style
                                }
                            )
                            
                            if style != AppSettings.MessageCornerStyle.allCases.last {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                            }
                        }
                    }
                }
                
                // Message Corner Preview
                MessageCornerPreview(cornerRadius: settings.messageCornerRadius)
                    .padding(.horizontal, 4)
                
                // Appearance Section
                SettingsSection(title: "Appearance") {
                    VStack(spacing: 0) {
                        ForEach(AppSettings.AppearanceMode.allCases, id: \.rawValue) { mode in
                            AppearanceRow(
                                mode: mode,
                                isSelected: settings.appearanceMode == mode,
                                onSelect: {
                                    Haptics.selection()
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        settings.appearanceMode = mode
                                    }
                                }
                            )
                            
                            if mode != AppSettings.AppearanceMode.allCases.last {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                            }
                        }
                    }
                }
                
                // Footer Note
                Text("System uses your device's appearance settings")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
        .navigationTitle("Design")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Text Size Row
private struct TextSizeRow: View {
    let size: AppSettings.TextSize
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Text("Aa")
                    .font(.system(size: 16 * size.scaleFactor, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Circle())
                
                Text(size.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Text Size Preview
private struct TextSizePreview: View {
    let scaleFactor: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("This is how your text will look")
                    .font(.system(size: 15 * scaleFactor))
                    .foregroundStyle(.primary)
                
                Text("Messages and content will scale accordingly")
                    .font(.system(size: 13 * scaleFactor))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Message Corner Row
private struct MessageCornerRow: View {
    let style: AppSettings.MessageCornerStyle
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Mini bubble preview
                RoundedRectangle(cornerRadius: style.radius * 0.5)
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 36, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: style.radius * 0.5)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
                
                Text(style.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message Corner Preview
private struct MessageCornerPreview: View {
    let cornerRadius: CGFloat
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 8) {
                // Received message
                HStack {
                    Text("Hey there! 👋")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    
                    Spacer()
                }
                
                // Sent message
                HStack {
                    Spacer()
                    
                    Text("Hi! How are you?")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Appearance Row
private struct AppearanceRow: View {
    let mode: AppSettings.AppearanceMode
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)
                    .background(iconColor.opacity(0.15))
                    .clipShape(Circle())
                
                Text(mode.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    var iconColor: Color {
        switch mode {
        case .system: return .gray
        case .light: return .orange
        case .dark: return .indigo
        }
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        DesignSettingsView()
    }
}
