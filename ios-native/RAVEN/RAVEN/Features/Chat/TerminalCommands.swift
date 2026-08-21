import SwiftUI

// MARK: - Terminal Commands (2026-08 "RAVEN://TERMINAL v2")
/// BitChat-style IRC slash commands. Typing `/` in the composer opens the
/// autocomplete strip; sending a `/command` line executes it locally in
/// ChatView (`handleSlashCommand`). Keyboard-first by design: every core
/// chat action is reachable without leaving the text field.

struct TerminalCommand: Identifiable, Equatable {
    let name: String       // "/clear"
    let signature: String  // "/me <action>"
    let help: String
    var id: String { name }
}

enum TerminalCommandRegistry {
    static let all: [TerminalCommand] = [
        TerminalCommand(name: "/clear", signature: "/clear", help: "wipe the input line"),
        TerminalCommand(name: "/me", signature: "/me <action>", help: "send an action message"),
        TerminalCommand(name: "/shrug", signature: "/shrug [text]", help: "append ¯\\_(ツ)_/¯"),
        TerminalCommand(name: "/search", signature: "/search [query]", help: "search this chat"),
        TerminalCommand(name: "/reply", signature: "/reply", help: "reply to last received"),
        TerminalCommand(name: "/edit", signature: "/edit", help: "edit your last message"),
        TerminalCommand(name: "/help", signature: "/help", help: "list all commands"),
    ]

    /// Prefix-match against what the user typed (e.g. "/se" → /search).
    static func matches(for input: String) -> [TerminalCommand] {
        guard input.hasPrefix("/"), !input.contains(" "), !input.contains("\n") else { return [] }
        let needle = input.lowercased()
        if needle == "/" { return all }
        return all.filter { $0.name.hasPrefix(needle) }
    }
}

// MARK: - Autocomplete strip

/// Floating console panel listing matching commands above the composer.
/// Tap a row to complete it into the input line.
struct CommandPickerView: View {
    let matches: [TerminalCommand]
    let onSelect: (TerminalCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("//")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(DS.phosphor)
                Text("commands")
                    .font(.system(.caption2, design: .monospaced, weight: .semibold))
                    .foregroundStyle(DS.mist.opacity(0.6))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(DS.charcoal.opacity(0.95))

            Rectangle().fill(DS.hairline).frame(height: 1)

            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                Button {
                    Haptics.selection()
                    onSelect(command)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(command.signature)
                            .font(.system(.footnote, design: .monospaced, weight: .bold))
                            .foregroundStyle(DS.phosphor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(command.help)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(DS.mist.opacity(0.55))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < matches.count - 1 {
                    Rectangle().fill(DS.hairlineDim).frame(height: 1)
                }
            }
        }
        .background(DS.inkElevated.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }
}

// MARK: - /help sheet

/// Full command reference — terminal man-page style.
struct CommandHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TerminalWindowBar(title: "raven — man commands", trailing: "\(TerminalCommandRegistry.all.count) cmds")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TerminalSectionRule("slash commands")
                        .padding(.top, 16)

                    ForEach(TerminalCommandRegistry.all) { command in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(command.signature)
                                .font(.system(.subheadline, design: .monospaced, weight: .bold))
                                .foregroundStyle(DS.phosphor)
                            Text(command.help)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(DS.mist.opacity(0.7))
                        }
                    }

                    TerminalSectionRule("hardware keyboard")
                        .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 6) {
                        keyRow("⌘F", "search in chat")
                        keyRow("⌘R", "reply to last received")
                        keyRow("⌘E", "edit last sent")
                        keyRow("⌘↓", "jump to latest")
                        keyRow("esc", "dismiss search / reply / edit")
                    }
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
            }

            Button("[ close ]") { dismiss() }
                .buttonStyle(.ravenPrimary)
                .padding(.bottom, 18)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .ravenScreen()
    }

    private func keyRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(DS.ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(DS.phosphorSoft))
            Text(label)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(DS.mist.opacity(0.7))
        }
    }
}
