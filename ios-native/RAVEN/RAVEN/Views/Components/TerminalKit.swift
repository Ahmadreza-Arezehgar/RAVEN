import SwiftUI

// MARK: - TerminalKit (2026-08 "RAVEN://TERMINAL" redesign)
/// Reusable console primitives shared across the app:
/// scanlines, CRT grid, blinking cursor, window chrome, prompt
/// labels, section rules, corner ticks, and typed boot lines.

// MARK: Scanlines — CRT horizontal refresh lines

struct ScanlineOverlay: View {
    /// Distance between scanlines in points.
    var spacing: CGFloat = 3
    /// Per-line darkening strength.
    var opacity: Double = 0.05

    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                let line = Path(CGRect(x: 0, y: y.rounded(), width: size.width, height: 1))
                context.fill(line, with: .color(.black.opacity(opacity)))
                y += spacing
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: CRT grid — faint phosphor engineering grid

struct TerminalGrid: View {
    var cell: CGFloat = 44
    var opacity: Double = 0.035

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                let vline = Path(CGRect(x: x.rounded(), y: 0, width: 1, height: size.height))
                context.fill(vline, with: .color(DS.phosphor.opacity(opacity)))
                x += cell
            }
            var y: CGFloat = 0
            while y < size.height {
                let hline = Path(CGRect(x: 0, y: y.rounded(), width: size.width, height: 1))
                context.fill(hline, with: .color(DS.phosphor.opacity(opacity)))
                y += cell
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Blinking block cursor ▍

struct BlinkingCursor: View {
    var color: Color = DS.phosphor
    var height: CGFloat = 18
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 8, height: height)
            .opacity(visible ? 1 : 0)
            .onAppear {
                // Respect Reduce Motion: steady cursor instead of blink.
                guard !UIAccessibility.isReduceMotionEnabled else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Window chrome bar — ● ● ● + path title

struct TerminalWindowBar: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(DS.accentDanger).frame(width: 9, height: 9)
            Circle().fill(DS.amber).frame(width: 9, height: 9)
            Circle().fill(DS.phosphor).frame(width: 9, height: 9)
            Spacer(minLength: 8)
            Text(title)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(DS.mist.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Group {
                if let trailing {
                    Text(trailing)
                        .foregroundStyle(DS.phosphor.opacity(0.85))
                } else {
                    Text(" ")
                }
            }
            .font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DS.charcoal.opacity(0.9))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: Prompt label — `$ command` / `> output`

struct PromptLabel: View {
    enum Marker: String {
        case shell = "$"
        case quote = ">"
        case hash = "#"
    }

    let marker: Marker
    let text: String
    var color: Color = DS.mist

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker.rawValue)
                .font(.system(.callout, design: .monospaced, weight: .bold))
                .foregroundStyle(DS.phosphor)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: Section rule ─── title ───

struct TerminalSectionRule: View {
    let title: String
    var color: Color = DS.phosphor.opacity(0.55)

    init(_ title: String, color: Color? = nil) {
        self.title = title
        self.color = color ?? DS.phosphor.opacity(0.55)
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(color).frame(height: 1)
            Text(title)
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(color)
                .textCase(.uppercase)
                .fixedSize()
            Rectangle().fill(color).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: Corner ticks — panel signature brackets

struct TerminalCornerTicks: View {
    var radius: CGFloat
    var color: Color = DS.phosphor.opacity(0.65)
    var length: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            context.stroke(Path { p in
                p.move(to: CGPoint(x: 0.5, y: length))
                p.addLine(to: CGPoint(x: 0.5, y: min(radius, length)))
                p.addQuadCurve(
                    to: CGPoint(x: min(radius, length), y: 0.5),
                    control: CGPoint(x: 0.5, y: 0.5)
                )
                p.addLine(to: CGPoint(x: length, y: 0.5))
            }, with: .color(color), lineWidth: 1.5)

            context.translateBy(x: size.width, y: 0)
            context.stroke(Path { p in
                p.move(to: CGPoint(x: -0.5, y: length))
                p.addLine(to: CGPoint(x: -0.5, y: min(radius, length)))
                p.addQuadCurve(
                    to: CGPoint(x: -min(radius, length), y: 0.5),
                    control: CGPoint(x: -0.5, y: 0.5)
                )
                p.addLine(to: CGPoint(x: -length, y: 0.5))
            }, with: .color(color), lineWidth: 1.5)

            context.translateBy(x: 0, y: size.height)
            context.stroke(Path { p in
                p.move(to: CGPoint(x: -0.5, y: -length))
                p.addLine(to: CGPoint(x: -0.5, y: -min(radius, length)))
                p.addQuadCurve(
                    to: CGPoint(x: -min(radius, length), y: -0.5),
                    control: CGPoint(x: -0.5, y: -0.5)
                )
                p.addLine(to: CGPoint(x: -length, y: -0.5))
            }, with: .color(color), lineWidth: 1.5)

            context.translateBy(x: -size.width, y: 0)
            context.stroke(Path { p in
                p.move(to: CGPoint(x: 0.5, y: -length))
                p.addLine(to: CGPoint(x: 0.5, y: -min(radius, length)))
                p.addQuadCurve(
                    to: CGPoint(x: min(radius, length), y: -0.5),
                    control: CGPoint(x: 0.5, y: -0.5)
                )
                p.addLine(to: CGPoint(x: length, y: -0.5))
            }, with: .color(color), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Inverse block badge — [ 3 ] unread counter

struct TerminalBlockBadge: View {
    let text: String
    var color: Color = DS.phosphor

    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .foregroundStyle(DS.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusPill, style: .continuous)
                    .fill(color)
                    .shadow(color: color.opacity(0.45), radius: 5, y: 0)
            )
            .accessibilityLabel("\(text) unread")
    }
}

// MARK: Boot log line — [ ok ] / [ .. ] prefixes

struct BootLogLine: View {
    enum Status: String {
        case pending = ".."
        case ok = "ok"
        case fail = "!!"
    }

    let status: Status
    let text: String

    private var statusColor: Color {
        switch status {
        case .ok: return DS.phosphor
        case .pending: return DS.amber
        case .fail: return DS.accentDanger
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("[\(status.rawValue)]")
                .font(.system(.footnote, design: .monospaced, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 42, alignment: .leading)
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(DS.mist)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("TerminalKit") {
    ZStack {
        RavenScreenBackground()
        VStack(spacing: 20) {
            TerminalWindowBar(title: "raven — ~/chats", trailing: "PID 1337")
            TerminalSectionRule("conversations")
            PromptLabel(marker: .shell, text: "grep -i \"hello\"")
            BootLogLine(status: .ok, text: "keychain identity verified")
            BootLogLine(status: .pending, text: "starting mesh daemon")
            HStack {
                TerminalBlockBadge(text: "12")
                BlinkingCursor()
            }
            Text("panel")
                .foregroundStyle(DS.mist)
                .ravenCard()
        }
        .padding(24)
    }
}
