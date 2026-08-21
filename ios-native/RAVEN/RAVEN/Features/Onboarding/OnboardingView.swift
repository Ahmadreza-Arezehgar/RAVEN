import SwiftUI

// MARK: - Onboarding Slide Model
struct OnboardingSlide: Identifiable {
    let id = UUID()
    let index: Int
    let command: String        // fake shell command typed at the prompt
    let title: String
    let subtitle: String
    let systemImage: String
    let bootLines: [(BootLogLine.Status, String)]
}

// MARK: - App Launch State (First-Time Check)
final class AppLaunchState: ObservableObject {
    @AppStorage("hasSeenOnboarding") var hasSeenOnboarding: Bool = false
    
    func resetOnboarding() {
        hasSeenOnboarding = false
    }
}

// MARK: - Onboarding View (TERMINAL v2 — boot sequence)
/// First-run walkthrough restyled as a CRT boot sequence: each slide is
/// a console panel with a typed command, boot-log lines and a monospace
/// pitch. Swipe or use [ NEXT ] — keyboard-first everywhere else too.
struct OnboardingView: View {
    let onFinish: () -> Void
    
    @State private var currentIndex: Int = 0
    
    private let slides: [OnboardingSlide] = [
        .init(
            index: 0,
            command: "raven --offline",
            title: "works offline",
            subtitle: "no internet needed. messages hop device-to-device over the bluetooth mesh and reach a bridge later.",
            systemImage: "dot.radiowaves.left.and.right",
            bootLines: [
                (.ok, "ble mesh radio up"),
                (.ok, "store-and-forward queue ready"),
                (.pending, "scanning for peers…"),
            ]
        ),
        .init(
            index: 1,
            command: "raven --e2ee status",
            title: "private & encrypted",
            subtitle: "end-to-end encryption by design. keys never leave your device; there is nothing useful to intercept.",
            systemImage: "lock.shield.fill",
            bootLines: [
                (.ok, "identity key sealed in enclave"),
                (.ok, "noise handshake verified"),
                (.ok, "zero plaintext on the wire"),
            ]
        ),
        .init(
            index: 2,
            command: "raven --route trace",
            title: "one message, many paths",
            subtitle: "private conversations travel over nearby and internet paths — never a public feed.",
            systemImage: "point.3.connected.trianglepath.dotted",
            bootLines: [
                (.ok, "path 1: mesh · 2 hops"),
                (.ok, "path 2: lan bridge"),
                (.pending, "path 3: internet relay"),
            ]
        ),
        .init(
            index: 3,
            command: "raven --start",
            title: "fast, keyboard-first",
            subtitle: "monospace everything. type / for commands, @ for people. text, photos, voice — at terminal speed.",
            systemImage: "keyboard.fill",
            bootLines: [
                (.ok, "slash commands loaded"),
                (.ok, "syntax highlighting on"),
                (.ok, "ready."),
            ]
        ),
    ]
    
    private var isLastSlide: Bool { currentIndex == slides.count - 1 }
    private var isFirstSlide: Bool { currentIndex == 0 }
    
    var body: some View {
        ZStack {
            RavenScreenBackground()
            
            VStack(spacing: 0) {
                // Top bar: window chrome + skip
                HStack(spacing: 10) {
                    Circle().fill(DS.accentDanger).frame(width: 9, height: 9)
                    Circle().fill(DS.amber).frame(width: 9, height: 9)
                    Circle().fill(DS.phosphor).frame(width: 9, height: 9)
                    Text("raven — install")
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .foregroundStyle(DS.mist.opacity(0.6))
                    Spacer()
                    Button("skip ⏭") {
                        Haptics.light()
                        onFinish()
                    }
                    .font(.system(.footnote, design: .monospaced, weight: .semibold))
                    .foregroundStyle(DS.mist.opacity(0.6))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                // Slides (Swipeable)
                TabView(selection: $currentIndex) {
                    ForEach(slides, id: \.index) { slide in
                        SlideContent(slide: slide)
                            .tag(slide.index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                
                // Progress: [■][■][□][□] step blocks
                HStack(spacing: 6) {
                    ForEach(slides, id: \.index) { slide in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(slide.index <= currentIndex ? DS.phosphor : DS.phosphor.opacity(0.15))
                            .frame(width: 26, height: 5)
                    }
                }
                .padding(.bottom, 22)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: currentIndex)
                
                // Bottom actions
                HStack(spacing: 12) {
                    Button {
                        Haptics.light()
                        withAnimation(.spring(response: 0.35)) {
                            currentIndex = max(currentIndex - 1, 0)
                        }
                    } label: {
                        Text("[ back ]")
                            .font(.system(.body, design: .monospaced, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .foregroundStyle(DS.mist.opacity(isFirstSlide ? 0.25 : 0.85))
                            .background(
                                RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                                    .fill(DS.inkElevated.opacity(0.92))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: DS.radiusInner, style: .continuous)
                                    .strokeBorder(DS.hairline, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(isFirstSlide)
                    
                    Button {
                        Haptics.medium()
                        if isLastSlide {
                            onFinish()
                        } else {
                            withAnimation(.spring(response: 0.35)) {
                                currentIndex += 1
                            }
                        }
                    } label: {
                        Text(isLastSlide ? "[ execute ]" : "[ next ]")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ravenPrimary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
        }
    }
}

// MARK: - Slide Content View
private struct SlideContent: View {
    let slide: OnboardingSlide
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            
            // Console panel: typed command + boot log
            VStack(alignment: .leading, spacing: 10) {
                PromptLabel(marker: .shell, text: slide.command, color: DS.mist)
                
                Rectangle().fill(DS.hairlineDim).frame(height: 1)
                
                ForEach(Array(slide.bootLines.enumerated()), id: \.offset) { _, line in
                    BootLogLine(status: line.0, text: line.1)
                }
                
                HStack(spacing: 8) {
                    Image(systemName: slide.systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(DS.phosphor)
                        .symbolRenderingMode(.hierarchical)
                    Spacer()
                    BlinkingCursor(height: 16)
                }
                .padding(.top, 8)
            }
            .padding(18)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .fill(DS.inkElevated.opacity(0.92))
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
                    .strokeBorder(DS.hairline, lineWidth: 1)
            }
            .overlay(TerminalCornerTicks(radius: DS.radiusCard))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
            
            // Title + subtitle
            VStack(spacing: 10) {
                Text(slide.title)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(DS.mist)
                    .multilineTextAlignment(.center)
                
                Text(slide.subtitle)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(DS.mist.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 30)
            }
            
            Spacer(minLength: 8)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Preview
#Preview {
    OnboardingView {
        print("Onboarding finished!")
    }
}
