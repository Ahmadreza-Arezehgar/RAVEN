//
//  DeliveryStateBadge.swift
//  RAVEN
//
//  Compact capsule badge showing delivery state in chat list.
//  Color-coded dot + localized label, glass material background.
//

import SwiftUI

// MARK: - Delivery State Badge

/// Compact capsule badge. `.delivered` is ACK-only (`onDestinationACK`);
/// per-channel `JobState.transmitted` must not be passed in as delivered.
struct DeliveryStateBadge: View {
    let state: MeshConfidenceState
    
    @State private var isPulsing = false
    
    var body: some View {
        HStack(spacing: 4) {
            // Color-coded dot
            Circle()
                .fill(stateColor.gradient)
                .frame(width: 6, height: 6)
                .shadow(color: stateColor.opacity(0.6), radius: 3)
                .scaleEffect(shouldPulse ? (isPulsing ? 1.3 : 1.0) : 1.0)
                .opacity(shouldPulse ? (isPulsing ? 0.6 : 1.0) : 1.0)
                .animation(
                    shouldPulse
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .default,
                    value: isPulsing
                )
            
            // State label
            Text(stateLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .stroke(stateColor.opacity(0.3), lineWidth: 0.5)
                }
        }
        .onAppear {
            if shouldPulse {
                isPulsing = true
            }
        }
        .onChange(of: state.stateKey) { _, newKey in
            isPulsing = (newKey == "inTransit")
        }
        .accessibilityLabel(accessibilityText)
    }
    
    // MARK: - State Properties
    
    private var stateColor: Color {
        switch state {
        case .queued:     return .blue
        case .inTransit:  return .yellow
        case .delivered:  return .green
        case .stale:      return .orange
        case .failed:     return .red
        }
    }
    
    private var stateLabel: String {
        switch state {
        case .queued:     return String(localized: "در صف", comment: "Delivery state: queued")
        case .inTransit:  return String(localized: "در حال انتقال", comment: "Delivery state: in transit")
        case .delivered:  return String(localized: "تحویل شده", comment: "Delivery state: delivered")
        case .stale:      return String(localized: "تلاش ادامه دارد", comment: "Delivery state: stale")
        case .failed:     return String(localized: "ناموفق", comment: "Delivery state: failed")
        }
    }
    
    private var shouldPulse: Bool {
        if case .inTransit = state { return true }
        return false
    }
    
    private var accessibilityText: String {
        switch state {
        case .queued:
            return "Message queued for delivery"
        case .inTransit(_, let hops):
            return "Message in transit, \(hops) hops confirmed"
        case .delivered:
            return "Message delivered"
        case .stale:
            return "Message delivery delayed, still attempting"
        case .failed(let reason):
            switch reason {
            case .ttlExpired: return "Message delivery failed, expired"
            case .noRoute:    return "Message delivery failed, no route found"
            case .unknown:    return "Message delivery failed"
            }
        }
    }
}

// MARK: - Preview

#Preview("Badge States") {
    VStack(spacing: 16) {
        DeliveryStateBadge(state: .queued)
        DeliveryStateBadge(state: .inTransit(firstRelayAt: Date(), hopsConfirmed: 3))
        DeliveryStateBadge(state: .delivered(at: Date()))
        DeliveryStateBadge(state: .stale(since: Date()))
        DeliveryStateBadge(state: .failed(reason: .ttlExpired))
    }
    .padding()
    .background(.black)
}
