//
//  LocationMessageCard.swift
//  RAVEN
//
//  Compact map preview card for location messages - uses static snapshot to avoid Metal crashes
//

import SwiftUI
import MapKit

struct LocationMessageCard: View {
    let payload: LocationPayload
    let isFromMe: Bool
    
    // 🚨 FIX: Removed internal sheet and use callback
    var onTap: (() -> Void)? = nil
    
    @State private var mapSnapshot: UIImage?
    
    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng)
    }
    
    private var title: String {
        switch payload.kind {
        case .current:
            return "Current Location"
        case .live:
            return "Live Location"
        }
    }
    
    private var subtitle: String {
        switch payload.kind {
        case .current:
            return "Tap to view"
        case .live:
            if let expires = payload.expiresAt {
                let remaining = expires.timeIntervalSince(Date())
                if remaining > 0 {
                    return "Active · \(formatDuration(remaining))"
                } else {
                    return "Expired"
                }
            }
            return "Tap to view"
        }
    }
    
    private var isLive: Bool { payload.kind == .live }
    
    private var isExpired: Bool {
        if isLive, let expires = payload.expiresAt {
            return expires < Date()
        }
        return false
    }
    
    var body: some View {
        Button {
            Haptics.light()
            onTap?()
        } label: {
            VStack(spacing: 0) {
                // Static Map Snapshot (avoids Metal crashes)
                mapPreview
                    .frame(height: 80)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: isFromMe ? 16 : 4,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: isFromMe ? 4 : 16
                    ))
                
                // Info Row
                HStack(spacing: 8) {
                    Image(systemName: isLive ? "location.north.circle.fill" : "location.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isLive ? .green : .cyan)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            if isLive && !isExpired {
                                liveBadge
                            }
                            
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(isFromMe ? .white : .primary)
                        }
                        
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(isFromMe ? .white.opacity(0.7) : .secondary)
                    }
                    
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isFromMe ? Color.blue.opacity(0.85) : Color(.systemGray5))
            }
            .frame(width: 200)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .task {
            await loadSnapshot()
        }
    }
    
    // Map Preview - static image
    @ViewBuilder
    private var mapPreview: some View {
        if let snapshot = mapSnapshot {
            Image(uiImage: snapshot)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .overlay {
                    // Pin marker
                    Image(systemName: isLive ? "location.north.circle.fill" : "mappin.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(isLive ? .green : .cyan)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                }
        } else {
            // Placeholder while loading
            Rectangle()
                .fill(Color(.systemGray4))
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "map.fill")
                            .foregroundColor(.gray)
                        Text("Tap to open map")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                .onAppear {
                    // Retry snapshot if it failed before and we reappear
                    if mapSnapshot == nil {
                        Task { await loadSnapshot() }
                    }
                }
        }
    }
    
    // Load static map snapshot
    private func loadSnapshot() async {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        )
        options.size = CGSize(width: 200, height: 80)
        options.scale = UIScreen.main.scale
        options.mapType = .standard
        
        let snapshotter = MKMapSnapshotter(options: options)
        
        do {
            let snapshot = try await snapshotter.start()
            await MainActor.run {
                self.mapSnapshot = snapshot.image
            }
        } catch {
            #if DEBUG
            print("❌ Map snapshot failed: \(error)")
            #endif
        }
    }
    
    private var liveBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            
            Text("LIVE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(.green.opacity(0.15)))
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        } else {
            return "\(minutes)m left"
        }
    }
}

// MARK: - Map Sheet (Half-sheet with 3D camera)

struct LocationMapSheet: View {
    let payload: LocationPayload
    
    @State private var camera: MapCameraPosition = .automatic
    @Environment(\.dismiss) private var dismiss
    
    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lng)
    }
    
    private var title: String {
        switch payload.kind {
        case .current:
            return payload.label ?? "Shared Location"
        case .live:
            return "Live Location"
        }
    }
    
    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                Marker(title, coordinate: coordinate)
                    .tint(payload.kind == .live ? .green : .blue)
                
                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.5)) {
                    camera = .camera(MapCamera(
                        centerCoordinate: coordinate,
                        distance: 800,
                        heading: 0,
                        pitch: 50
                    ))
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    infoCard
                    actionButtons
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    private var infoCard: some View {
        HStack(spacing: 10) {
            Image(systemName: payload.kind == .live ? "location.north.circle.fill" : "location.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(payload.kind == .live ? .green : .blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                
                Text(timeAgo)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if let accuracy = payload.accuracy {
                Text("±\(Int(accuracy))m")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    private var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Shared \(formatter.localizedString(for: payload.timestamp, relativeTo: Date()))"
    }
    
    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button { openInMaps() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "map.fill")
                    Text("Open in Maps")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            
            Button { getDirections() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    Text("Directions")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
    
    private func openInMaps() {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = title
        mapItem.openInMaps()
    }
    
    private func getDirections() {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = title
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}

#Preview("Current Location") {
    ZStack {
        Color.black.ignoresSafeArea()
        LocationMessageCard(
            payload: .current(from: CLLocation(latitude: 40.4168, longitude: -3.7038), label: "Madrid"),
            isFromMe: true
        )
    }
}

#Preview("Live Location") {
    ZStack {
        Color.black.ignoresSafeArea()
        LocationMessageCard(
            payload: .live(from: CLLocation(latitude: 40.4168, longitude: -3.7038), sessionId: "test", expiresAt: Date().addingTimeInterval(600)),
            isFromMe: false
        )
    }
}
