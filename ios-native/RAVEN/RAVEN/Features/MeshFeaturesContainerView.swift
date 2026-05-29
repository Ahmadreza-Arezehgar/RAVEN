//
//  MeshFeaturesContainerView.swift
//  RAVEN
//
//  Swipe-navigable container for Echo, Club, and Vault.
//  Uses a custom swipe gesture + matchedGeometryEffect tab indicator
//  because nested NavigationStacks inside TabView(.page) steal gestures.
//

import SwiftUI

// MARK: - Mesh Page

enum MeshPage: Int, CaseIterable {
    case vault = 0, club = 1, echo = 2
    
    var title: String {
        switch self {
        case .vault: return "Vault"
        case .club:  return "Club"
        case .echo:  return "Echo"
        }
    }
    
    var icon: String {
        switch self {
        case .vault: return "lock.fill"
        case .club:  return "person.3.fill"
        case .echo:  return "waveform"
        }
    }
}

// MARK: - Container View

struct MeshFeaturesContainerView: View {
    @State private var selectedPage: MeshPage = .club
    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Page indicator at top
            MeshPageIndicator(selected: $selectedPage)
                .padding(.top, 8)
                .padding(.bottom, 4)
            
            // Content area with swipe gesture
            GeometryReader { geo in
                HStack(spacing: 0) {
                    // Vault
                    VaultListView()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    
                    // Club
                    ClubListView()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    
                    // Echo
                    EchoMapView()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .offset(x: -CGFloat(selectedPage.rawValue) * geo.size.width + dragOffset)
                .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.86), value: selectedPage)
                .animation(.interactiveSpring(response: 0.2, dampingFraction: 1.0), value: dragOffset)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .updating($isDragging) { _, state, _ in
                            state = true
                        }
                        .onChanged { value in
                            // Only accept mostly-horizontal drags
                            let horizontal = abs(value.translation.width)
                            let vertical = abs(value.translation.height)
                            guard horizontal > vertical * 1.2 else { return }

                            // 🚧 Claim the gesture so the root TabPager
                            // doesn't also switch tabs on this drag.
                            NestedSwipeCoordinator.shared.isHandlingSwipe = true

                            // Resistance at edges
                            let atLeadingEdge = selectedPage.rawValue == 0 && value.translation.width > 0
                            let atTrailingEdge = selectedPage.rawValue == MeshPage.allCases.count - 1 && value.translation.width < 0

                            if atLeadingEdge || atTrailingEdge {
                                dragOffset = value.translation.width * 0.2 // Rubber band
                            } else {
                                dragOffset = value.translation.width
                            }
                        }
                        .onEnded { value in
                            // Release the claim regardless of outcome
                            defer { NestedSwipeCoordinator.shared.isHandlingSwipe = false }

                            let threshold: CGFloat = geo.size.width * 0.2
                            let velocity = value.predictedEndTranslation.width - value.translation.width
                            let totalOffset = value.translation.width + velocity * 0.5

                            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                                if totalOffset < -threshold,
                                   selectedPage.rawValue < MeshPage.allCases.count - 1 {
                                    selectedPage = MeshPage(rawValue: selectedPage.rawValue + 1)!
                                } else if totalOffset > threshold,
                                          selectedPage.rawValue > 0 {
                                    selectedPage = MeshPage(rawValue: selectedPage.rawValue - 1)!
                                }
                                dragOffset = 0
                            }
                        }
                )
            }
            .clipped() // Prevent off-screen pages from bleeding through
        }
        .navigationBarHidden(true)
        .onDisappear {
            // Belt-and-suspenders cleanup if the view is dismissed mid-drag
            NestedSwipeCoordinator.shared.isHandlingSwipe = false
        }
    }
}

// MARK: - Page Indicator

struct MeshPageIndicator: View {
    @Binding var selected: MeshPage
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(MeshPage.allCases, id: \.rawValue) { page in
                Button {
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                        selected = page
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: page.icon)
                            .font(.caption)
                        
                        if selected == page {
                            Text(page.title)
                                .font(.caption.bold())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, selected == page ? 16 : 12)
                    .padding(.vertical, 10)
                    .foregroundStyle(selected == page ? .primary : .secondary)
                    .background {
                        if selected == page {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .matchedGeometryEffect(id: "pageTab", in: namespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .liquidCapsule()
    }
    
    @Namespace private var namespace
}
