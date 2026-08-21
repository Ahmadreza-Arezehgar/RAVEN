import SwiftUI

// MARK: - Launch View ("RAVEN://TERMINAL" boot sequence)
/// TERMINAL REDESIGN (2026-08): the splash is a console boot log —
/// lines type in sequentially with `[ok]` status prefixes, ending in a
/// blinking block cursor while auth is validated against the Keychain.
struct LaunchView: View {
    /// Boot log revealed line-by-line.
    @State private var revealedLines = 0
    @State private var logoVisible = false

    private let bootLog: [(BootLogLine.Status, String)] = [
        (.ok, "raven terminal v2.6.0"),
        (.ok, "keychain identity verified"),
        (.ok, "encrypted store mounted"),
        (.pending, "starting mesh daemon"),
    ]

    private var bootComplete: Bool { revealedLines >= bootLog.count }

    var body: some View {
        ZStack {
            RavenScreenBackground()

            VStack(alignment: .leading, spacing: 28) {
                Spacer(minLength: 40)

                // Console window chrome around the logo.
                VStack(spacing: 0) {
                    TerminalWindowBar(title: "raven — /usr/local/bin", trailing: "tty1")
                    VStack(spacing: 14) {
                        Image("RavenLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                                    .strokeBorder(DS.hairline, lineWidth: 1)
                            )
                            .shadow(color: DS.phosphor.opacity(0.35), radius: 14, y: 0)

                        Text("RAVEN")
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .foregroundStyle(DS.mist)
                            .tracking(6)

                        Text("secure mesh messaging")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(DS.phosphorSoft.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                }
                .overlay(TerminalCornerTicks(radius: DS.radiusCard))
                .opacity(logoVisible ? 1 : 0)
                .offset(y: logoVisible ? 0 : 8)

                // Boot log
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(bootLog.prefix(revealedLines).enumerated()), id: \.offset) { _, line in
                        BootLogLine(status: line.0, text: line.1)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    HStack(spacing: 6) {
                        Text("$")
                            .font(.system(.footnote, design: .monospaced, weight: .bold))
                            .foregroundStyle(DS.phosphor)
                        if bootComplete {
                            BlinkingCursor(height: 14)
                        }
                    }
                }
                .padding(.horizontal, 2)

                Spacer(minLength: 60)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            withAnimation(DS.openChatSpring) {
                logoVisible = true
            }
            revealBootLog()
        }
    }

    private func revealBootLog() {
        // Respect Reduce Motion: show everything at once.
        guard !UIAccessibility.isReduceMotionEnabled else {
            revealedLines = bootLog.count
            return
        }
        for index in bootLog.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + Double(index) * 0.32) {
                withAnimation(.easeOut(duration: 0.18)) {
                    revealedLines = max(revealedLines, index + 1)
                }
            }
        }
    }
}

#Preview {
    LaunchView()
}
