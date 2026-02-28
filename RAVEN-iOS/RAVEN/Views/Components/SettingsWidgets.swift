// RAVEN - Settings Widgets
// Converted from Flutter settings_components.dart

import SwiftUI

// MARK: - Settings Row
struct SettingsRow: View {
    let icon: String
    var iconColor: Color = .ravenPrimary
    let title: String
    var subtitle: String?
    var value: String?
    var showDisclosure: Bool = true
    
    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(iconColor)
            }
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Value
            if let value = value {
                Text(value)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Disclosure
            if showDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Settings Toggle Row
struct SettingsToggleRow: View {
    let icon: String
    var iconColor: Color = .ravenPrimary
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(iconColor)
            }
            
            // Text
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .tint(.ravenPrimary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Section Header
struct SettingsSectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title.uppercased())
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

// MARK: - Danger Button
struct DangerButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.headline)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.red.opacity(0.1))
            .cornerRadius(12)
        }
    }
}

// MARK: - Info Card
struct InfoCard: View {
    let icon: String
    let title: String
    let message: String
    var type: InfoCardType = .info
    
    enum InfoCardType {
        case info, warning, success, error
        
        var color: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .success: return .green
            case .error: return .red
            }
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(type.color)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(type.color.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Progress Card
struct ProgressCard: View {
    let title: String
    let current: Int
    let total: Int
    var unit: String = ""
    
    var progress: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                
                Spacer()
                
                Text("\(current)\(unit) / \(total)\(unit)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(UIColor.systemGray5))
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.ravenPrimary)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 8)
        }
        .padding()
        .background(Color(UIColor.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Confirmation Sheet
struct ConfirmationSheet: View {
    let title: String
    let message: String
    var confirmTitle: String = "Confirm"
    var isDestructive: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 12) {
                Button {
                    onConfirm()
                } label: {
                    Text(confirmTitle)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(isDestructive ? Color.red : Color.ravenPrimary)
                        .cornerRadius(12)
                }
                
                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color(UIColor.systemGray5))
                        .cornerRadius(12)
                }
            }
        }
        .padding(24)
        .glassBackground()
    }
}

// MARK: - Version Info
struct VersionInfo: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("RAVEN")
                .font(.headline)
            
            Text("Version 1.0.0 (1)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

#Preview {
    List {
        Section {
            SettingsRow(icon: "bell.fill", title: "Notifications", subtitle: "Manage alerts")
            SettingsToggleRow(icon: "moon.fill", iconColor: .purple, title: "Dark Mode", isOn: .constant(true))
        }
        
        Section {
            InfoCard(
                icon: "lock.shield.fill",
                title: "End-to-End Encryption",
                message: "Your messages are secured with encryption",
                type: .success
            )
        }
        
        Section {
            ProgressCard(title: "Storage Used", current: 256, total: 1024, unit: "MB")
        }
        
        Section {
            DangerButton(title: "Delete Account", icon: "trash") {}
        }
        
        VersionInfo()
    }
    .preferredColorScheme(.dark)
}
