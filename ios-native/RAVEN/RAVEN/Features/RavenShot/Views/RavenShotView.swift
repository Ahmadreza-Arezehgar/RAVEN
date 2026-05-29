//
//  RavenShotView.swift
//  RAVEN
//
//  Full-screen social map showing location-tagged Posts, Echoes, and Clubs.
//  Accessed via swipe-right from the Home tab.
//  Uses Apple MapKit with Liquid Glass overlays.
//

import SwiftUI
import MapKit

// MARK: - Raven Shot View

struct RavenShotView: View {
    @Binding var isPresented: Bool
    @State private var store = RavenShotStore.shared
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedItem: RavenShotItem?
    @State private var showFilterMenu = false
    @State private var activeFilter: RavenShotContentType? = nil
    // ⚡ Crash fix: `.standard(elevation: .realistic)` allocates a 3D
    // texture pipeline that's expensive to spin up + tear down on every
    // open/close cycle. Repeated swipes between RavenShot and Home thrashed
    // it. Plain `.standard()` (no elevation) renders identically at typical
    // zoom levels and survives rapid re-presentation.
    @State private var mapStyle: MapStyle = .standard()
    @State private var dismissDragOffset: CGFloat = 0
    @State private var isDismissDragging = false
    @State private var appeared = false
    @State private var heatmapOn = false  // Heatmap overlay toggle
    
    var body: some View {
        let screenWidth = UIScreen.main.bounds.width
        // Progress 0→1 as user drags left to dismiss
        let dismissProgress = min(1, max(0, -dismissDragOffset / screenWidth))
        
        ZStack {
            // Full-screen map
            mapContent
            
            // Top overlay: Title + Controls
            VStack {
                headerOverlay
                
                Spacer()
                
                // Bottom controls
                bottomControls
            }
            .opacity(appeared ? 1 : 0)
        }
        // Interactive dismiss: offset + scale + opacity for smooth feel
        .offset(x: dismissDragOffset)
        .scaleEffect(1 - dismissProgress * 0.05, anchor: .leading)
        .opacity(1 - dismissProgress * 0.3)
        // ⚡ Dismiss gesture — LEFT-EDGE ONLY so panning the map in the
        // middle / right area doesn't accidentally close the view. This is
        // the same constraint we use to OPEN RavenShot (left-edge swipe-
        // right from Home), inverted: now a left-edge swipe-LEFT closes.
        // Claims the `NestedSwipeCoordinator` while active so the parent
        // gesture in MainShellView ignores the same drag.
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    // Only respond to drags that started near the LEFT edge.
                    guard value.startLocation.x < 30 else { return }
                    // Predominantly horizontal.
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }

                    // Claim the gesture so MainShellView's parent edge-swipe
                    // (and any other listeners) bail out.
                    NestedSwipeCoordinator.shared.isHandlingSwipe = true

                    if value.translation.width < 0 {
                        isDismissDragging = true
                        dismissDragOffset = value.translation.width * 0.85
                    } else if value.translation.width > 0 {
                        isDismissDragging = true
                        dismissDragOffset = value.translation.width * 0.15
                    }
                }
                .onEnded { value in
                    // Always release the coordinator, even on no-op drags.
                    defer { NestedSwipeCoordinator.shared.isHandlingSwipe = false }

                    guard value.startLocation.x < 30 else { return }
                    isDismissDragging = false
                    let velocity = value.predictedEndTranslation.width - value.translation.width

                    if value.translation.width < -(screenWidth * 0.25) || velocity < -500 {
                        Haptics.light()
                        closeRavenShot()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dismissDragOffset = 0
                        }
                    }
                }
        )
        .sheet(item: $selectedItem) { item in
            RavenShotDetailCard(item: item)
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
                .presentationDragIndicator(.visible)
        }
        .task {
            // Request location permission if needed
            if !LocationManager.shared.hasLocationPermission {
                LocationManager.shared.requestWhenInUse()
            }

            // Only load if items are empty (preload may have already filled them)
            if store.items.isEmpty {
                await store.loadItems(near: LocationManager.shared.lastLocation?.coordinate)
            }

            // Entrance animation
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.1)) {
                appeared = true
            }
        }
        .onDisappear {
            // ⚡ Crash fix: clear NestedSwipeCoordinator + tear down sheet
            // state explicitly. Without this, a rapid open/close cycle
            // could leave `isHandlingSwipe = true` permanently (gestures
            // dead) or `selectedItem` referencing a stale snapshot.
            NestedSwipeCoordinator.shared.isHandlingSwipe = false
            selectedItem = nil
            store.clearSelection()
        }
    }
    
    // MARK: - Map Content
    
    private var mapContent: some View {
        ZStack {
            Map(position: $camera) {
                // User location
                UserAnnotation()

                // Content markers (hidden when heatmap is on — heatmap
                // overlay replaces them at this zoom level)
                if !heatmapOn {
                    ForEach(filteredItems) { item in
                        Annotation(coordinate: item.coordinate) {
                            RavenShotMarker(
                                item: item,
                                isSelected: selectedItem?.id == item.id
                            )
                            .onTapGesture {
                                Haptics.light()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    selectedItem = item
                                }
                            }
                        } label: {
                            EmptyView()
                        }
                    }
                }
            }
            .mapStyle(mapStyle)
            .mapControls {
                MapCompass()
            }
            .ignoresSafeArea()

            // 🔥 Heatmap overlay — translucent density blobs computed from
            // filtered items. Pure SwiftUI Canvas on top of the Map; cheap.
            if heatmapOn {
                HeatmapOverlay(items: filteredItems, camera: camera)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }
    
    // MARK: - Header Overlay
    
    private var headerOverlay: some View {
        HStack(spacing: 12) {
            // Back button
            Button {
                Haptics.light()
                closeRavenShot()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Title
            HStack(spacing: 8) {
                // Animated map pin icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 24, height: 24)
                    
                    Image(systemName: "location.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                
                Text("Raven Shot")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            
            Spacer()
            
            // Filter button
            Menu {
                Button {
                    activeFilter = nil
                } label: {
                    Label("All", systemImage: "square.grid.2x2")
                }
                
                Button {
                    activeFilter = .post
                } label: {
                    Label("Posts", systemImage: "photo.on.rectangle.angled")
                }
                
                Button {
                    activeFilter = .echo
                } label: {
                    Label("Echoes", systemImage: "waveform.circle.fill")
                }
                
                Button {
                    activeFilter = .club
                } label: {
                    Label("Clubs", systemImage: "person.3.fill")
                }
            } label: {
                Image(systemName: activeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(activeFilter == nil ? .primary : .blue)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }

            // 🔥 Heatmap toggle — switches between individual pins and
            // density blobs. Crowded venues (festival, square) read much
            // better as a heatmap than as 200 overlapping markers.
            Button {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.25)) { heatmapOn.toggle() }
            } label: {
                Image(systemName: heatmapOn ? "flame.fill" : "flame")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(heatmapOn ? .orange : .primary)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 60)
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControls: some View {
        HStack(spacing: 12) {
            // Item count badge
            if !filteredItems.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 8, height: 8)
                    Text("\(filteredItems.count) nearby")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
            }
            
            Spacer()
            
            // My Location button
            Button {
                Haptics.light()
                withAnimation {
                    camera = .userLocation(fallback: .automatic)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                    
                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            
            // Refresh button
            Button {
                Haptics.light()
                Task {
                    await store.refresh()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                    
                    Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                        .animation(store.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: store.isLoading)
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 40)
    }
    
    // MARK: - Filtered Items
    
    private var filteredItems: [RavenShotItem] {
        guard let filter = activeFilter else { return store.items }
        return store.items.filter { $0.contentType == filter }
    }
    
    // MARK: - Dismiss Drag Gesture (Legacy — now using inline simultaneousGesture)
    
    // Removed: Old edge-strip gesture replaced by full-screen simultaneousGesture above
    
    // MARK: - Close Helper
    
    private func closeRavenShot() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
            dismissDragOffset = 0
            isPresented = false
        }
    }
}

// MARK: - Heatmap Overlay
//
// Approximate density rendering on top of MapKit. We don't have access to
// the live map's projection from outside, so we estimate visible bounds
// from the camera position and render Gaussian blobs at each item's
// pixel-space location. Cheap, draws at 60 fps via Canvas; precision
// trades off slightly at extreme zoom levels but reads as "where the
// activity is" — which is the actual goal.

private struct HeatmapOverlay: View {
    let items: [RavenShotItem]
    let camera: MapCameraPosition

    var body: some View {
        GeometryReader { geo in
            let bounds = visibleBounds(for: camera, in: geo.size)
            Canvas(opaque: false, rendersAsynchronously: true) { ctx, size in
                guard let bounds else { return }
                for item in items {
                    guard bounds.contains(item.coordinate) else { continue }
                    let p = project(item.coordinate, in: bounds, size: size)
                    // Three concentric soft circles per item — additive
                    // blending naturally builds density where pins overlap.
                    let baseRadius: CGFloat = item.isLive ? 56 : (item.isRecent ? 44 : 34)
                    let typeColor: Color = {
                        switch item.contentType {
                        case .post: return .blue
                        case .echo: return .purple
                        case .club: return .green
                        }
                    }()
                    for (radius, opacity) in [(baseRadius, 0.18), (baseRadius * 0.6, 0.28), (baseRadius * 0.32, 0.42)] {
                        let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                        ctx.fill(
                            Path(ellipseIn: rect),
                            with: .color(typeColor.opacity(opacity)),
                            style: FillStyle(eoFill: false, antialiased: true)
                        )
                    }
                }
            }
            .blur(radius: 8)
            .blendMode(.plusLighter)
        }
    }

    /// Best-effort visible-region estimate from the camera position. When
    /// the camera is `.region(...)` we get exact bounds; for other modes
    /// we approximate around the user's last known location.
    private func visibleBounds(for camera: MapCameraPosition, in size: CGSize) -> MKMapRect? {
        if let region = camera.region {
            return MKMapRect(region: region)
        }
        let fallbackCenter = LocationManager.shared.lastLocation?.coordinate
            ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        return MKMapRect(region: MKCoordinateRegion(center: fallbackCenter, span: span))
    }

    /// Map a lat/lng to a pixel point inside the canvas using the visible
    /// bounds as the linear interpolation domain.
    private func project(_ coord: CLLocationCoordinate2D, in bounds: MKMapRect, size: CGSize) -> CGPoint {
        let mp = MKMapPoint(coord)
        let nx = (mp.x - bounds.origin.x) / bounds.size.width
        let ny = (mp.y - bounds.origin.y) / bounds.size.height
        return CGPoint(x: CGFloat(nx) * size.width, y: CGFloat(ny) * size.height)
    }
}

private extension MKMapRect {
    init(region: MKCoordinateRegion) {
        let topLeft = CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        )
        let bottomRight = CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        )
        let tlPoint = MKMapPoint(topLeft)
        let brPoint = MKMapPoint(bottomRight)
        self = MKMapRect(
            x: min(tlPoint.x, brPoint.x),
            y: min(tlPoint.y, brPoint.y),
            width: abs(tlPoint.x - brPoint.x),
            height: abs(tlPoint.y - brPoint.y)
        )
    }
    func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        contains(MKMapPoint(coord))
    }
}

// MARK: - Preview

#Preview {
    RavenShotView(isPresented: .constant(true))
}
