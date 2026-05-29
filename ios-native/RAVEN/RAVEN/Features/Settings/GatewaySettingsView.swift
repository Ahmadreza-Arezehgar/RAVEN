//
//  GatewaySettingsView.swift
//  RAVEN
//
//  Settings panel for Internet Bridge Gateway feature.
//  Liquid Glass design with explicit consent, privacy notice, and daily stats.
//

import SwiftUI

// MARK: - Gateway Settings View

struct GatewaySettingsView: View {
    @StateObject private var gatewayService = GatewayService.shared
    @StateObject private var meshGateway = MeshGatewayService.shared
    @AppStorage("raven.gateway_enabled") private var gatewayEnabled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header icon — switches to a "Raven Helper" badge when
                // the v1.6 mesh gateway is actively relaying.
                if meshGateway.isActiveGateway {
                    helperBadge
                        .padding(.top, 16)
                } else {
                    CapsuleIcon(
                        systemImage: "wifi.circle.fill",
                        tint: FeatureColor.internetBridge.primary,
                        size: 48
                    )
                    .padding(.top, 16)
                }

                // Title + description
                VStack(spacing: 8) {
                    Text(String(localized: "پل اینترنتی", comment: "Internet Bridge"))
                        .font(.title2.bold())

                    Text(String(localized: "به کاربران آفلاین کمک کنید پیام‌هایشان را از طریق اینترنت شما ارسال کنند", comment: "Bridge description"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                // v1.6 Helper Mode card — separate from the legacy toggle
                // because the new service uses a richer score model and
                // we want to expose the breakdown to the user explicitly.
                helperModeCard
                    .padding(.horizontal)
                
                // Toggle with consent
                FeatureGlassCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $gatewayEnabled) {
                            HStack(spacing: 12) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(FeatureColor.internetBridge.primary)
                                    .font(.title3)
                                VStack(alignment: .leading) {
                                    Text(String(localized: "فعال‌سازی Gateway", comment: "Enable Gateway"))
                                        .font(.headline)
                                    Text(String(localized: "اجازه پل زدن پیام‌ها", comment: "Allow message bridging"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(FeatureColor.internetBridge.primary)
                        .onChange(of: gatewayEnabled) { _, _ in
                            gatewayService.refresh()
                        }
                        
                        // Conditions
                        VStack(alignment: .leading, spacing: 8) {
                            conditionRow(icon: "wifi", text: String(localized: "فقط روی Wi-Fi", comment: "Wi-Fi only"), met: true)
                            conditionRow(icon: "battery.75percent", text: String(localized: "باتری بالای ۳۰٪", comment: "Battery > 30%"), met: UIDevice.current.batteryLevel < 0 || UIDevice.current.batteryLevel > 0.30)
                            conditionRow(icon: "clock", text: String(localized: "حداکثر ۲۰ پیام/دقیقه", comment: "Max 20 msg/min"), met: true)
                        }
                    }
                }
                .padding(.horizontal)
                
                // Privacy notice
                PrivacyNotice(
                    icon: "lock.shield.fill",
                    text: String(localized: "پیام‌ها رمزنگاری سرتاسری هستند — دستگاه شما نمی‌تواند محتوا را ببیند", comment: "E2E privacy notice"),
                    tint: FeatureColor.internetBridge.primary
                )
                .padding(.horizontal)
                
                // Daily stats card
                if gatewayEnabled {
                    FeatureGlassCard {
                        VStack(spacing: 12) {
                            Text(String(localized: "آمار امروز", comment: "Today's stats"))
                                .font(.headline)
                            
                            HStack(spacing: 16) {
                                MetricCard(
                                    icon: "envelope.fill",
                                    value: "\(gatewayService.todayStats.messagesRelayed)",
                                    label: String(localized: "پیام", comment: "Messages"),
                                    tint: FeatureColor.internetBridge.primary
                                )
                                MetricCard(
                                    icon: "arrow.up.arrow.down",
                                    value: gatewayService.todayStats.bytesRelayedFormatted,
                                    label: String(localized: "حجم", comment: "Volume"),
                                    tint: FeatureColor.deliveryConfidence.primary
                                )
                                MetricCard(
                                    icon: "person.2.fill",
                                    value: "\(gatewayService.todayStats.uniqueUsersHelped.count)",
                                    label: String(localized: "کاربر", comment: "Users"),
                                    tint: FeatureColor.dataMules.primary
                                )
                            }
                        }
                    }
                    .padding(.horizontal)
                    .transition(.glassMorph)
                }
                
                Spacer(minLength: DS.bottomTabClearance)
            }
        }
        .navigationTitle(String(localized: "پل اینترنتی", comment: "Internet Bridge"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            gatewayService.refresh()
        }
    }
    
    // MARK: - v1.6 Helper Mode

    /// Compact "Raven Helper" badge shown when this device is acting as a
    /// gateway. Visual nod to the spec's "Raven Helper" recognition pin.
    private var helperBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
            Text(String(localized: "Raven Helper", comment: "Active gateway badge"))
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(FeatureColor.internetBridge.primary))
    }

    /// Live Helper Mode card: opt-in toggle, computed score, penalty
    /// breakdown ("you got penalised because you're hot"), counters.
    private var helperModeCard: some View {
        FeatureGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // Opt-in toggle bound directly to the @Published flag.
                Toggle(isOn: Binding(
                    get: { meshGateway.helperModeEnabled },
                    set: { meshGateway.helperModeEnabled = $0 }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.line.dotted.person.fill")
                            .foregroundStyle(FeatureColor.internetBridge.primary)
                            .font(.title3)
                        VStack(alignment: .leading) {
                            Text(String(localized: "Helper Mode (v1.6)", comment: "v1.6 mesh helper toggle"))
                                .font(.headline)
                            Text(String(localized: "Relay encrypted envelopes for nearby offline neighbours", comment: "Helper subtitle"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(FeatureColor.internetBridge.primary)

                // Live score breakdown.
                if meshGateway.helperModeEnabled {
                    Divider()
                    helperScoreBreakdown
                    Divider()
                    helperCounters
                }
            }
        }
    }

    private var helperScoreBreakdown: some View {
        let s = meshGateway.lastScore
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Score", comment: "Gateway score"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f", s.final))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(meshGateway.isActiveGateway ? .green : .orange)
            }
            HStack(spacing: 10) {
                breakdownPill(
                    label: String(localized: "Weighted", comment: "Pre-penalty weighted score"),
                    value: String(format: "%.2f", s.weighted)
                )
                breakdownPill(
                    label: String(localized: "Battery×", comment: "Battery penalty multiplier"),
                    value: String(format: "%.1f", s.batteryPenalty)
                )
                breakdownPill(
                    label: String(localized: "Thermal×", comment: "Thermal penalty multiplier"),
                    value: String(format: "%.1f", s.thermalPenalty)
                )
            }
            // Honest disclosure when a penalty is dragging the score down.
            if s.batteryPenalty < 1.0 {
                Text(String(localized: "Battery is low — score reduced.", comment: "Battery penalty disclosure"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if s.thermalPenalty < 1.0 {
                Text(String(localized: "Device is warm — score reduced.", comment: "Thermal penalty disclosure"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var helperCounters: some View {
        let stats = meshGateway.stats
        return HStack(spacing: 12) {
            counterPill(label: String(localized: "Inbound", comment: "Inbound forward count"), value: "\(stats.messagesForwardedInbound)")
            counterPill(label: String(localized: "Outbound", comment: "Outbound forward count"), value: "\(stats.messagesForwardedOutbound)")
            counterPill(label: String(localized: "Bytes", comment: "Bytes relayed"), value: byteString(stats.bytesRelayed))
        }
    }

    private func breakdownPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func counterPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private func byteString(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .binary
        return f.string(fromByteCount: Int64(n))
    }

    // MARK: - Condition Row

    private func conditionRow(icon: String, text: String, met: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(met ? .green : .orange)
                .frame(width: 20)
            
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(met ? .green : .orange)
        }
    }
}

// MARK: - Preview

#Preview("Gateway Settings") {
    NavigationStack {
        GatewaySettingsView()
    }
}
