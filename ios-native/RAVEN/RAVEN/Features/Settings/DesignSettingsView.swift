import SwiftUI

// MARK: - Design Settings View
struct DesignSettingsView: View {
    @State private var settings = AppSettings.shared
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // TERMINAL v2: CRT accent theme — phosphor green / ion blue /
                // amber. Drives every DS color live via @Observable tracking.
                SettingsSection(title: "Terminal Accent") {
                    VStack(spacing: 0) {
                        ForEach(AppSettings.TerminalAccent.allCases, id: \.rawValue) { accent in
                            TerminalAccentRow(
                                accent: accent,
                                isSelected: settings.terminalAccent == accent,
                                onSelect: {
                                    Haptics.selection()
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        settings.terminalAccent = accent
                                    }
                                }
                            )

                            if accent != AppSettings.TerminalAccent.allCases.last {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                            }
                        }
                    }
                }

                // Accent live preview
                TerminalAccentPreview()
                    .padding(.horizontal, 4)

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
                
                // TERMINAL v2: the light/dark appearance rows are gone —
                // the console design is dark-only; the accent picker above
                // is the personality control now.

                // Footer Note
                Text("terminal is dark by design — pick your phosphor above")
                    .font(.system(.footnote, design: .monospaced))
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

// MARK: - Terminal Accent Row
private struct TerminalAccentRow: View {
    let accent: AppSettings.TerminalAccent
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Swatch — accent block on its own ink
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent.ink)
                    .frame(width: 36, height: 36)
                    .overlay {
                        Text(">_")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent.primary)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(accent.primary.opacity(0.5), lineWidth: 1)
                    }

                Text(accent.displayName)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Text("[x]")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent.primary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Accent Preview
private struct TerminalAccentPreview: View {
    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(DS.accentDanger).frame(width: 8, height: 8)
                    Circle().fill(DS.amber).frame(width: 8, height: 8)
                    Circle().fill(DS.phosphor).frame(width: 8, height: 8)
                    Text("raven:~/chats")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.mist.opacity(0.6))
                }
                .padding(.bottom, 4)

                Text(previewLine1)
                Text(previewLine2)

                HStack(spacing: 6) {
                    Text(">")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(DS.phosphor)
                    Text("type here")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(DS.mist.opacity(0.4))
                    BlinkingCursor(color: DS.phosphor, height: 13)
                }
                .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.ink)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DS.hairline, lineWidth: 1)
            )
        }
    }

    private var previewLine1: AttributedString {
        var time = AttributedString("[12:03] ")
        time.foregroundColor = DS.mist.opacity(0.38)
        time.font = .system(size: 11, design: .monospaced)
        var nick = AttributedString("<nova> ")
        nick.foregroundColor = DS.pathBlue
        nick.font = .system(size: 13, weight: .bold, design: .monospaced)
        let body = TerminalSyntax.highlight("check `raven --mesh` @you", fontSize: 13)
        return time + nick + body
    }

    private var previewLine2: AttributedString {
        var time = AttributedString("[12:04] ")
        time.foregroundColor = DS.mist.opacity(0.38)
        time.font = .system(size: 11, design: .monospaced)
        var nick = AttributedString("<you> ")
        nick.foregroundColor = DS.phosphor
        nick.font = .system(size: 13, weight: .bold, design: .monospaced)
        let body = TerminalSyntax.highlight("on it — 2 hops away", fontSize: 13)
        var status = AttributedString("  ✓✓")
        status.foregroundColor = DS.phosphor
        status.font = .system(size: 11, weight: .bold, design: .monospaced)
        return time + nick + body + status
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
