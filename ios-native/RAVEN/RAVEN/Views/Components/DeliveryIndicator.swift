//
//  DeliveryIndicator.swift
//  RAVEN
//
//  UI component for showing message delivery status
//  Blue 🔵 = Server path | Purple 🟣 = Mesh path
//

import SwiftUI

/// Shows delivery status with colored checkmarks
/// Blue for server-delivered, Purple for mesh-delivered.
/// `.delivered` / `.read` are ACK-driven; transport write success is `.sent`.
struct DeliveryIndicator: View {
    let status: MessageStatus
    let authority: DeliveryAuthority
    
    var body: some View {
        HStack(spacing: 2) {
            statusIcon
                .foregroundStyle(indicatorColor)
            
            // Double checkmark for delivered/read
            if status == .delivered || status == .read {
                statusIcon
                    .foregroundStyle(indicatorColor)
            }
        }
        .font(.system(size: 10, weight: .medium))
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            
        case .sending, .forwarding, .accepted:
            Image(systemName: "arrow.up.circle")
                .foregroundStyle(.secondary)
            
        case .sent:
            Image(systemName: "checkmark")
            
        case .delivered:
            Image(systemName: "checkmark")
            
        case .read:
            Image(systemName: "checkmark")
            
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            
        case .scheduled:
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.secondary)
        }
    }
    
    private var indicatorColor: Color {
        switch status {
        case .failed:
            return .red
        case .pending, .sending, .forwarding, .scheduled:
            return .secondary
        default:
            // Use authority color for sent/delivered/read
            switch authority {
            case .unknown:
                return .gray     // ⚪ Unknown/pending
            case .server:
                return .blue     // 🔵 Server path
            case .mesh:
                return .purple   // 🟣 Mesh path
            }
        }
    }
}

// MARK: - Status Badge

/// Larger badge for message details view
struct DeliveryStatusBadge: View {
    let status: MessageStatus
    let authority: DeliveryAuthority
    
    var body: some View {
        HStack(spacing: 4) {
            DeliveryIndicator(status: status, authority: authority)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .clipShape(Capsule())
    }
    
    private var statusText: String {
        switch status {
        case .pending: return "Pending"
        case .sending: return "Sending"
        case .forwarding: return "Relaying"
        case .accepted: return "Accepted"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .read: return "Read"
        case .failed: return "Failed"
        case .scheduled: return "Scheduled"
        }
    }
    
    private var textColor: Color {
        switch status {
        case .failed:
            return .red
        case .pending, .sending, .forwarding, .scheduled:
            return .secondary
        default:
            return authority == .server ? .blue : .purple
        }
    }
    
    private var backgroundColor: Color {
        switch status {
        case .failed:
            return .red.opacity(0.1)
        case .pending, .sending, .forwarding, .scheduled:
            return .secondary.opacity(0.1)
        default:
            return (authority == .server ? Color.blue : Color.purple).opacity(0.1)
        }
    }
}

// MARK: - Route Path View (Debug)

/// Shows the mesh route path for debugging
struct RoutePathView: View {
    let routePath: [String]
    let hopCount: Int
    let hopLimit: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Route:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Text("\(hopCount)/\(hopLimit) hops")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(routePath.enumerated()), id: \.offset) { index, deviceId in
                        HStack(spacing: 2) {
                            if index > 0 {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Text(String(deviceId.prefix(8)))
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Delivery Indicators") {
    VStack(alignment: .leading, spacing: 16) {
        Group {
            Text("Server Path (Blue)").font(.headline)
            HStack(spacing: 16) {
                VStack {
                    DeliveryIndicator(status: .sent, authority: .server)
                    Text("Sent").font(.caption2)
                }
                VStack {
                    DeliveryIndicator(status: .delivered, authority: .server)
                    Text("Delivered").font(.caption2)
                }
                VStack {
                    DeliveryIndicator(status: .read, authority: .server)
                    Text("Read").font(.caption2)
                }
            }
        }
        
        Divider()
        
        Group {
            Text("Mesh Path (Purple)").font(.headline)
            HStack(spacing: 16) {
                VStack {
                    DeliveryIndicator(status: .forwarding, authority: .mesh)
                    Text("Relaying").font(.caption2)
                }
                VStack {
                    DeliveryIndicator(status: .sent, authority: .mesh)
                    Text("Sent").font(.caption2)
                }
                VStack {
                    DeliveryIndicator(status: .delivered, authority: .mesh)
                    Text("Delivered").font(.caption2)
                }
            }
        }
        
        Divider()
        
        Group {
            Text("Status Badges").font(.headline)
            HStack(spacing: 8) {
                DeliveryStatusBadge(status: .sent, authority: .server)
                DeliveryStatusBadge(status: .delivered, authority: .mesh)
                DeliveryStatusBadge(status: .failed, authority: .server)
            }
        }
        
        Divider()
        
        Group {
            Text("Route Path").font(.headline)
            RoutePathView(
                routePath: ["abc12345", "def67890", "ghi11111"],
                hopCount: 2,
                hopLimit: 10
            )
        }
    }
    .padding()
}
