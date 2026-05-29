//
//  DeliveryDetailSheet.swift
//  RAVEN
//
//  Liquid Glass detail sheet shown when user taps on a delivery state badge.
//  Shows state icon, description, metrics (time, hops), and network average.
//

import SwiftUI

// MARK: - Delivery Detail Sheet

struct DeliveryDetailSheet: View {
    let messageId: String
    @ObservedObject var stateService = DeliveryStateService.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var averageDeliveryTime: TimeInterval?
    @State private var deliveredCount: Int = 0
    
    private var state: MeshConfidenceState {
        stateService.states[messageId] ?? .queued
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // State icon
            CapsuleIcon(
                systemImage: stateIcon,
                tint: stateColor,
                size: 48
            )
            .padding(.top, 32)
            
            // State title
            Text(stateTitle)
                .font(.title2.bold())
                .animation(.featureSpring, value: state.stateKey)
            
            // State description
            Text(stateDescription)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            // Metrics grid
            HStack(spacing: 12) {
                MetricCard(
                    icon: "clock.fill",
                    value: formattedTimeSinceSend,
                    label: String(localized: "از ارسال", comment: "Since send"),
                    tint: FeatureColor.deliveryConfidence.primary
                )
                MetricCard(
                    icon: "arrow.triangle.branch",
                    value: "\(hopCount) hop",
                    label: String(localized: "طی شده", comment: "Hops completed"),
                    tint: FeatureColor.internetBridge.primary
                )
            }
            .padding(.horizontal)
            
            // Network average card (shown after 10+ deliveries)
            if let avgTime = averageDeliveryTime {
                FeatureGlassCard {
                    HStack {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 24))
                            .foregroundStyle(FeatureColor.adaptiveSpray.primary.gradient)
                        VStack(alignment: .leading) {
                            Text("میانگین تحویل شبکه شما")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatDuration(avgTime))
                                .font(.headline)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal)
            }
            
            Spacer()
            
            // Dismiss button
            Button(String(localized: "بستن", comment: "Close")) {
                dismiss()
            }
            .buttonStyle(.glassCapsule)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(32)
        .task {
            await loadMetrics()
        }
    }
    
    // MARK: - Data Loading
    
    private func loadMetrics() async {
        averageDeliveryTime = await DeliveryMetricsRepository.shared.averageLatency()
        deliveredCount = await DeliveryMetricsRepository.shared.deliveredCount()
    }
    
    // MARK: - State Properties
    
    private var stateIcon: String {
        switch state {
        case .queued:     return "tray.fill"
        case .inTransit:  return "paperplane.fill"
        case .delivered:  return "checkmark.circle.fill"
        case .stale:      return "clock.badge.exclamationmark"
        case .failed:     return "xmark.circle.fill"
        }
    }
    
    private var stateColor: Color {
        switch state {
        case .queued:     return .blue
        case .inTransit:  return .yellow
        case .delivered:  return .green
        case .stale:      return .orange
        case .failed:     return .red
        }
    }
    
    private var stateTitle: String {
        switch state {
        case .queued:     return String(localized: "در صف ارسال", comment: "Queued title")
        case .inTransit:  return String(localized: "در حال انتقال", comment: "In transit title")
        case .delivered:  return String(localized: "تحویل شده", comment: "Delivered title")
        case .stale:      return String(localized: "تلاش ادامه دارد", comment: "Stale title")
        case .failed:     return String(localized: "ارسال ناموفق", comment: "Failed title")
        }
    }
    
    private var stateDescription: String {
        switch state {
        case .queued:
            return String(localized: "پیام شما در صف ارسال قرار دارد و منتظر یافتن کاربر نزدیک است", comment: "Queued description")
        case .inTransit(let relayAt, let hops):
            let elapsed = formatDuration(Date().timeIntervalSince(relayAt))
            return String(localized: "پیام شما \(elapsed) پیش ارسال شد و از طریق \(hops) کاربر در حال رسیدن به مقصد است", comment: "In transit description")
        case .delivered:
            return String(localized: "پیام شما با موفقیت به مقصد رسید", comment: "Delivered description")
        case .stale:
            return String(localized: "بیش از نیمی از زمان مجاز گذشته اما هنوز تلاش برای تحویل ادامه دارد", comment: "Stale description")
        case .failed(let reason):
            switch reason {
            case .ttlExpired:
                return String(localized: "زمان مجاز ارسال تمام شده. لطفاً دوباره تلاش کنید", comment: "TTL expired")
            case .noRoute:
                return String(localized: "مسیری به مقصد یافت نشد", comment: "No route")
            case .unknown:
                return String(localized: "ارسال ناموفق بود. لطفاً دوباره تلاش کنید", comment: "Unknown failure")
            }
        }
    }
    
    private var formattedTimeSinceSend: String {
        guard let elapsed = stateService.timeSinceSend(for: messageId) else {
            return "—"
        }
        return formatDuration(elapsed)
    }
    
    private var hopCount: UInt8 {
        stateService.hopCount(for: messageId)
    }
    
    // MARK: - Formatting
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds < 60 {
            return "\(totalSeconds) ثانیه"
        } else if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            return "~\(minutes) دقیقه"
        } else {
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            if minutes > 0 {
                return "~\(hours) ساعت \(minutes) دقیقه"
            }
            return "~\(hours) ساعت"
        }
    }
}

// MARK: - Preview

#Preview("Delivery Detail") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            DeliveryDetailSheet(messageId: "preview-123")
        }
}
