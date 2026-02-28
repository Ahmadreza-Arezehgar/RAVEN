import SwiftUI

// MARK: - Export Settings Sheet

struct ExportSettingsSheet: View {
    let onExport: (_ quality: ExportQuality, _ stripLocation: Bool) -> Void
    
    @State private var selectedQuality: ExportQuality = .auto
    @State private var stripLocationData = true
    @State private var showPaywall = false
    @State private var isExporting = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            // Title
            HStack {
                Text("Send Options")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            // Quality picker
            VStack(spacing: 8) {
                ForEach(ExportQuality.allCases) { quality in
                    Button {
                        // Gate "High Quality" behind premium
                        if quality == .high && !PremiumLimits.isPremium {
                            showPaywall = true
                            return
                        }
                        withAnimation(.spring(response: 0.25)) {
                            selectedQuality = quality
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: quality.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(selectedQuality == quality ? .white : .secondary)
                                .frame(width: 28)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quality.rawValue)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(quality.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if selectedQuality == quality {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.blue)
                            } else if quality == .high && !PremiumLimits.isPremium {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedQuality == quality
                                      ? Color.blue.opacity(0.1)
                                      : Color(.systemGray6))
                        )
                        .overlay {
                            if selectedQuality == quality {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            
            // Privacy toggle
            Toggle(isOn: $stripLocationData) {
                HStack(spacing: 8) {
                    Image(systemName: "location.slash")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Remove Location Data")
                            .font(.system(size: 13, weight: .medium))
                        Text("Strip GPS metadata for privacy")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.blue)
            .padding(.horizontal, 20)
            
            // Send button
            Button {
                isExporting = true
                onExport(selectedQuality, stripLocationData)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    if isExporting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                    }
                    Text(isExporting ? "Sending..." : "Send")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            }
            .disabled(isExporting)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showPaywall) {
            RavenPlusPaywallView()
        }
    }
}
