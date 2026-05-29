//
//  EchoMapView.swift
//  RAVEN
//
//  Full-screen map showing Echo bubbles at their geographic origin.
//  Includes a bottom echo list for all echoes (including non-geotagged).
//

import SwiftUI
import MapKit

struct EchoMapView: View {
    @State private var store = EchoStore.shared
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedEcho: Echo?
    @State private var showComposer = false
    @State private var showList = false
    
    /// Echoes with location (shown on map)
    private var geoEchoes: [Echo] {
        store.receivedEchoes.filter { $0.mapCoordinate != nil }
    }
    
    /// All echoes sorted by recency
    private var allEchoes: [Echo] {
        store.receivedEchoes
    }
    
    var body: some View {
        ZStack {
            // Full-screen map — extends under all safe areas
            Map(position: $camera) {
                UserAnnotation()
                
                ForEach(geoEchoes) { echo in
                    if let coord = echo.mapCoordinate {
                        Annotation(coordinate: coord) {
                            EchoBubblePin(
                                echo: echo,
                                responseSummary: store.responseSummaries[echo.id],
                                isSelected: selectedEcho?.id == echo.id
                            )
                            .onTapGesture {
                                withAnimation(RavenAnimation.snappy) {
                                    selectedEcho = echo
                                }
                            }
                        } label: { EmptyView() }
                    }
                }
            }
            .mapStyle(.standard)
            .ignoresSafeArea()
            
            // Overlays
            VStack(spacing: 0) {
                Spacer()
                
                // Empty state (centered above bottom controls)
                if allEchoes.isEmpty && !store.isLoading {
                    emptyStateView
                        .padding(.bottom, 16)
                }
                
                // Expandable echo list
                if showList && !allEchoes.isEmpty {
                    echoListView
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // Bottom action bar
                bottomActionBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, DS.bottomTabClearance + 8)
            }
        }
        .sheet(isPresented: $showComposer, onDismiss: {
            // Reload echoes after composer closes
            Task { await store.loadEchoes() }
        }) {
            EchoComposerView()
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(item: $selectedEcho) { echo in
            EchoDetailSheet(echo: echo, summary: store.responseSummaries[echo.id])
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
                .presentationDragIndicator(.visible)
        }
        .task {
            await store.loadEchoes()
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            
            Text("No Echoes Yet")
                .font(.subheadline.weight(.semibold))
            
            Text("Be the first to send an\nanonymous broadcast!")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 60)
    }
    
    // MARK: - Bottom Action Bar
    
    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            // Echo count pill / list toggle
            if !allEchoes.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.35)) {
                        showList.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.caption)
                        Text("\(allEchoes.count)")
                            .font(.caption.weight(.bold).monospacedDigit())
                        Image(systemName: showList ? "chevron.down" : "chevron.up")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            
            Spacer()
            
            // FAB — Create Echo
            Button {
                showComposer = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title3)
                    Text("Echo")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [.purple, .indigo],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .shadow(color: .purple.opacity(0.4), radius: 12, y: 4)
            }
        }
    }
    
    // MARK: - Echo List View
    
    private var echoListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(allEchoes) { echo in
                    EchoListCard(
                        echo: echo,
                        summary: store.responseSummaries[echo.id],
                        onTap: {
                            if echo.mapCoordinate != nil {
                                // If geotagged, select on map
                                withAnimation {
                                    selectedEcho = echo
                                }
                            } else {
                                selectedEcho = echo
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 240)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Echo List Card

struct EchoListCard: View {
    let echo: Echo
    let summary: EchoResponseSummary?
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                VStack {
                    Image(systemName: echo.isMine ? "megaphone.fill" : "waveform")
                        .font(.subheadline)
                        .foregroundStyle(echo.isMine ? .purple : .indigo)
                }
                .frame(width: 36, height: 36)
                .background(
                    (echo.isMine ? Color.purple : Color.indigo).opacity(0.15),
                    in: Circle()
                )
                
                // Content
                VStack(alignment: .leading, spacing: 3) {
                    Text(echo.content)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: 8) {
                        if echo.isMine {
                            Text("You")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.purple.opacity(0.12), in: Capsule())
                        }
                        
                        if echo.h3Cell != nil {
                            Image(systemName: "location.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.blue)
                        }
                        
                        Text(echo.timeRemaining)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        // Response count
                        let totalResponses = summary?.counts.values.reduce(0, +) ?? 0
                        if totalResponses > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "face.smiling")
                                    .font(.system(size: 8))
                                Text("\(totalResponses)")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Echo Detail Sheet

struct EchoDetailSheet: View {
    let echo: Echo
    let summary: EchoResponseSummary?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            // Content
            Text(echo.content)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            
            // Pseudonym + time
            HStack {
                Text(echo.authorPseudonym.prefix(8))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Image(systemName: "clock")
                    .font(.caption2)
                Text(echo.timeRemaining)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            
            // Emoji reactions
            HStack(spacing: 16) {
                ForEach(EchoEmoji.allCases, id: \.rawValue) { emoji in
                    let count = summary?.counts[emoji] ?? 0
                    
                    Button {
                        Task {
                            _ = await EchoStore.shared.respond(
                                to: echo.id,
                                with: emoji
                            )
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(emoji.rawValue)
                                .font(.title2)
                            Text("\(count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .liquidGlass(cornerRadius: 14)
                    }
                }
            }
            .padding(.horizontal, 16)
            
            Spacer()
        }
    }
}
