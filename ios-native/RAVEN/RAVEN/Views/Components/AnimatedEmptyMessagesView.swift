import SwiftUI

// MARK: - Animated Empty Messages State View
/// Shows a chill skeleton sitting at a desk with a pipe, smoke animating
/// Used when there are no conversations in the inbox (SwiftUI fallback)
struct AnimatedEmptyMessagesView: View {
    let onNewChat: () -> Void
    var onScanQR: (() -> Void)? = nil
    @State private var showScanQR = false
    
    // Animation lifecycle control - CRITICAL for CPU/battery
    @State private var isAnimating = false
    
    // Smoke particle states (limited to 6 for performance)
    @State private var smokeOpacity: [Double] = [0.3, 0.4, 0.35, 0.25, 0.3, 0.2]
    @State private var smokeOffset: [CGFloat] = [0, 0, 0, 0, 0, 0]
    @State private var smokeScale: [CGFloat] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    
    // Particle count - limited for CPU efficiency
    private let particleCount = 6
    
    var body: some View {
        VStack(spacing: 24) {
            // MARK: - Animation Area with Glass Panel
            ZStack {
                // Subtle glass background panel (Liquid Glass style)
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial.opacity(0.25))
                    .frame(height: 300)
                
                // Animation content
                ZStack {
                    // Desk
                    deskView
                        .offset(y: 60)
                    
                    // Skeleton at desk with pipe
                    skeletonWithPipe
                        .offset(y: 20)
                    
                    // Animated smoke particles (only when animating)
                    if isAnimating {
                        smokeParticles
                            .offset(x: 35, y: -45)
                    }
                }
            }
            .accessibilityLabel("No messages animation")
            
            // MARK: - Text Content (Capsule style)
            textCapsule
            
            // MARK: - Action Buttons
            actionButtons
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isAnimating = true
            if !reduceMotion {
                startSmokeAnimations()
            }
        }
        .onDisappear {
            // CRITICAL: Stop animations when view leaves screen
            isAnimating = false
            resetSmokeAnimations()
        }
        .sheet(isPresented: $showScanQR) {
            ScanQRCodeView()
        }
    }
    
    // MARK: - Text Capsule (Liquid Glass style)
    private var textCapsule: some View {
        VStack(spacing: 6) {
            Text("No messages yet.")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            
            Text("Why no one is messaging me?")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.5))
        .clipShape(Capsule())
    }
    
    // MARK: - Action Buttons
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.medium()
                onNewChat()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.message.fill")
                    Text("New Chat")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())
                .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
            }
            
            Button {
                Haptics.light()
                #if DEBUG
                print("📷 [EmptyMessages] Scan QR tapped")
                #endif
                if let onScanQR = onScanQR {
                    onScanQR()
                } else {
                    showScanQR = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode.viewfinder")
                    Text("Scan QR")
                }
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.2), lineWidth: 0.5)
                )
            }
        }
    }
    
    // MARK: - Desk View
    private var deskView: some View {
        ZStack {
            // Desk surface
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.45, green: 0.32, blue: 0.22),
                            Color(red: 0.35, green: 0.22, blue: 0.14)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 180, height: 12)
            
            // Desk legs
            HStack(spacing: 140) {
                Rectangle()
                    .fill(Color(red: 0.35, green: 0.22, blue: 0.14))
                    .frame(width: 8, height: 50)
                Rectangle()
                    .fill(Color(red: 0.35, green: 0.22, blue: 0.14))
                    .frame(width: 8, height: 50)
            }
            .offset(y: 30)
        }
    }
    
    // MARK: - Skeleton with Pipe
    private var skeletonWithPipe: some View {
        ZStack {
            // Body (slouched, relaxed)
            skeletonBody
            
            // Skull
            skeletonSkull
                .offset(y: -55)
            
            // Arm holding pipe
            armWithPipe
                .offset(x: 25, y: -15)
            
            // Leg on desk (chill pose)
            legOnDesk
                .offset(x: 30, y: 25)
        }
    }
    
    private var skeletonSkull: some View {
        ZStack {
            // Skull shape (matte)
            Circle()
                .fill(skeletonColor)
                .frame(width: 50, height: 50)
            
            // Eye sockets (relaxed/chill expression)
            HStack(spacing: 14) {
                Circle()
                    .fill(.black.opacity(0.4))
                    .frame(width: 10, height: 10)
                    .offset(y: 1)
                Circle()
                    .fill(.black.opacity(0.4))
                    .frame(width: 10, height: 10)
                    .offset(y: -1)
            }
            .offset(y: -4)
            
            // Relaxed smile
            Path { path in
                path.move(to: CGPoint(x: 12, y: 5))
                path.addQuadCurve(
                    to: CGPoint(x: 28, y: 5),
                    control: CGPoint(x: 20, y: -3)
                )
            }
            .stroke(.black.opacity(0.35), lineWidth: 2)
            .frame(width: 30, height: 12)
            .offset(y: 8)
        }
    }
    
    private var skeletonBody: some View {
        VStack(spacing: 0) {
            // Ribcage/torso (slouched back)
            RoundedRectangle(cornerRadius: 10)
                .fill(skeletonColor.opacity(0.9))
                .frame(width: 40, height: 60)
                .rotationEffect(.degrees(-5))
            
            // Hip area
            Ellipse()
                .fill(skeletonColor.opacity(0.85))
                .frame(width: 45, height: 20)
        }
    }
    
    private var armWithPipe: some View {
        ZStack {
            // Upper arm
            RoundedRectangle(cornerRadius: 4)
                .fill(skeletonColor.opacity(0.8))
                .frame(width: 30, height: 10)
                .rotationEffect(.degrees(-30))
            
            // Forearm
            RoundedRectangle(cornerRadius: 4)
                .fill(skeletonColor.opacity(0.8))
                .frame(width: 25, height: 8)
                .rotationEffect(.degrees(45))
                .offset(x: 20, y: -8)
            
            // Hand (simplified)
            Circle()
                .fill(skeletonColor.opacity(0.75))
                .frame(width: 12, height: 12)
                .offset(x: 35, y: -15)
            
            // Pipe
            pipeView
                .offset(x: 45, y: -25)
        }
    }
    
    private var pipeView: some View {
        ZStack {
            // Pipe bowl
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.5, green: 0.25, blue: 0.1),
                            Color(red: 0.3, green: 0.15, blue: 0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 14, height: 20)
            
            // Pipe stem
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: 0.4, green: 0.2, blue: 0.08))
                .frame(width: 30, height: 5)
                .offset(x: -18, y: 5)
        }
    }
    
    private var legOnDesk: some View {
        ZStack {
            // Thigh (angled up on desk)
            RoundedRectangle(cornerRadius: 5)
                .fill(skeletonColor.opacity(0.8))
                .frame(width: 45, height: 12)
                .rotationEffect(.degrees(-15))
            
            // Shin
            RoundedRectangle(cornerRadius: 4)
                .fill(skeletonColor.opacity(0.75))
                .frame(width: 40, height: 10)
                .rotationEffect(.degrees(10))
                .offset(x: 40, y: 5)
            
            // Foot
            Ellipse()
                .fill(skeletonColor.opacity(0.7))
                .frame(width: 18, height: 10)
                .rotationEffect(.degrees(-20))
                .offset(x: 75, y: 8)
        }
    }
    
    // MARK: - Smoke Particles (Performance optimized)
    private var smokeParticles: some View {
        ZStack {
            ForEach(0..<particleCount, id: \.self) { index in
                Circle()
                    .fill(luminousSmokeColor.opacity(smokeOpacity[index]))
                    .frame(width: smokeSize(for: index), height: smokeSize(for: index))
                    .scaleEffect(smokeScale[index])
                    .offset(
                        x: smokeXOffset(for: index),
                        y: smokeOffset[index] + smokeBaseY(for: index)
                    )
                    .blur(radius: 3)
            }
        }
    }
    
    private func smokeSize(for index: Int) -> CGFloat {
        [10, 14, 12, 8, 11, 7][index]
    }
    
    private func smokeXOffset(for index: Int) -> CGFloat {
        [0, 6, -4, 10, -2, 8][index]
    }
    
    private func smokeBaseY(for index: Int) -> CGFloat {
        [0, -12, -24, -36, -48, -58][index]
    }
    
    // Luminous smoke for glass effect
    private var luminousSmokeColor: Color {
        colorScheme == .dark
            ? Color.white
            : Color.gray
    }
    
    // Matte skeleton color
    private var skeletonColor: Color {
        colorScheme == .dark
            ? Color(white: 0.70)
            : Color(white: 0.60)
    }
    
    // MARK: - Smoke Animation (CPU efficient)
    private func startSmokeAnimations() {
        guard isAnimating else { return }
        
        for i in 0..<particleCount {
            let delay = Double(i) * 0.3
            let duration = 3.0 + Double(i) * 0.2
            
            // Gentle smoke rising - single animation per particle
            withAnimation(
                .easeInOut(duration: duration)
                .repeatForever(autoreverses: true)
                .delay(delay)
            ) {
                smokeOffset[i] = -10
                smokeOpacity[i] = [0.5, 0.6, 0.55, 0.4, 0.45, 0.35][i]
                smokeScale[i] = 1.1
            }
        }
    }
    
    private func resetSmokeAnimations() {
        // Reset to initial values when stopping
        smokeOpacity = [0.3, 0.4, 0.35, 0.25, 0.3, 0.2]
        smokeOffset = [0, 0, 0, 0, 0, 0]
        smokeScale = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
    }
}

// MARK: - Preview
#Preview {
    AnimatedEmptyMessagesView(onNewChat: {})
}
