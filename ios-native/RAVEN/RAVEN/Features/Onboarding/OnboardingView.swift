import SwiftUI

// MARK: - Onboarding Slide Model
struct OnboardingSlide: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    let accentColor: Color
}

// MARK: - App Launch State (First-Time Check)
final class AppLaunchState: ObservableObject {
    @AppStorage("hasSeenOnboarding") var hasSeenOnboarding: Bool = false
    
    func resetOnboarding() {
        hasSeenOnboarding = false
    }
}

// MARK: - Onboarding View (4 Slides with Swipe)
struct OnboardingView: View {
    let onFinish: () -> Void
    
    @State private var currentIndex: Int = 0
    
    private let slides: [OnboardingSlide] = [
        .init(
            title: "Works Offline",
            subtitle: "Even without internet, messages hop device-to-device via Mesh and reach a bridge later.",
            systemImage: "dot.radiowaves.left.and.right",
            accentColor: .purple
        ),
        .init(
            title: "Private & Encrypted",
            subtitle: "Your messages and data are protected with strong end-to-end encryption by design.",
            systemImage: "lock.shield.fill",
            accentColor: .blue
        ),
        .init(
            title: "Local + Friends Feed",
            subtitle: "See your friends' posts, and discover nearby local posts when your account is public.",
            systemImage: "person.2.wave.2.fill",
            accentColor: .green
        ),
        .init(
            title: "Fast Messaging",
            subtitle: "Send text, photos, and voice with a smooth Liquid Glass experience.",
            systemImage: "paperplane.fill",
            accentColor: .cyan
        )
    ]
    
    private var isLastSlide: Bool { currentIndex == slides.count - 1 }
    private var isFirstSlide: Bool { currentIndex == 0 }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    slides[currentIndex].accentColor.opacity(0.3),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: currentIndex)
            
            VStack(spacing: 0) {
                // Top bar: Skip button
                HStack {
                    Spacer()
                    Button("Skip") {
                        Haptics.light()
                        onFinish()
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                
                // Slides (Swipeable)
                TabView(selection: $currentIndex) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        SlideContent(slide: slide)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                
                // Bottom actions
                HStack(spacing: 16) {
                    // Back button
                    Button {
                        Haptics.light()
                        withAnimation(.spring(response: 0.35)) {
                            currentIndex = max(currentIndex - 1, 0)
                        }
                    } label: {
                        Text("Back")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(.white.opacity(isFirstSlide ? 0.3 : 0.9))
                    }
                    .disabled(isFirstSlide)
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                    )
                    
                    // Next / Get Started button
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
                        Text(isLastSlide ? "Get Started" : "Next")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(.white)
                    }
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, slides[currentIndex].accentColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Slide Content View
private struct SlideContent: View {
    let slide: OnboardingSlide
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Icon with glow effect
            ZStack {
                // Glow
                Circle()
                    .fill(slide.accentColor.opacity(0.3))
                    .frame(width: 140, height: 140)
                    .blur(radius: 40)
                
                // Icon
                Image(systemName: slide.systemImage)
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, slide.accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
            }
            
            // Title
            Text(slide.title)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            
            // Subtitle
            Text(slide.subtitle)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 32)
            
            Spacer()
            Spacer()
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Preview
#Preview {
    OnboardingView {
        print("Onboarding finished!")
    }
}
