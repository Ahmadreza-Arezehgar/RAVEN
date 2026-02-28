// RAVEN - Onboarding View
// Converted from Flutter onboarding_screen.dart

import SwiftUI

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentPage = 0
    
    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "bubble.left.and.bubble.right.fill",
            title: "Connect Anywhere",
            description: "Send messages even without internet using Bluetooth mesh networking",
            color: .ravenPrimary
        ),
        OnboardingPage(
            icon: "lock.shield.fill",
            title: "Private & Secure",
            description: "End-to-end encryption keeps your conversations safe from prying eyes",
            color: .green
        ),
        OnboardingPage(
            icon: "antenna.radiowaves.left.and.right",
            title: "Mesh Networking",
            description: "Messages hop between nearby devices to reach their destination",
            color: .orange
        ),
        OnboardingPage(
            icon: "person.2.fill",
            title: "Social Feed",
            description: "Share posts, discover content, and connect with your community",
            color: .ravenSecondary
        )
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Pages
            TabView(selection: $currentPage) {
                ForEach(0..<pages.count, id: \.self) { index in
                    pageView(pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            
            // Page Indicator
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(currentPage == index ? Color.ravenPrimary : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut, value: currentPage)
                }
            }
            .padding(.vertical, 24)
            
            // Button
            Button {
                if currentPage < pages.count - 1 {
                    withAnimation {
                        currentPage += 1
                    }
                } else {
                    completeOnboarding()
                }
            } label: {
                Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.ravenGradient)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
            
            // Skip button
            if currentPage < pages.count - 1 {
                Button("Skip") {
                    completeOnboarding()
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 32)
            } else {
                Spacer().frame(height: 50)
            }
        }
        .background(Color.black)
    }
    
    @ViewBuilder
    func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Icon
            ZStack {
                Circle()
                    .fill(page.color.opacity(0.2))
                    .frame(width: 150, height: 150)
                
                Image(systemName: page.icon)
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(colors: [page.color, page.color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            
            // Text
            VStack(spacing: 16) {
                Text(page.title)
                    .font(.title.bold())
                
                Text(page.description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
            Spacer()
        }
    }
    
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        withAnimation {
            hasCompletedOnboarding = true
        }
    }
}

struct OnboardingPage {
    let icon: String
    let title: String
    let description: String
    let color: Color
}

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false))
}
