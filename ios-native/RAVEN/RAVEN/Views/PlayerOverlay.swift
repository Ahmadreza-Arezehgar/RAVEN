import SwiftUI

// MARK: - Player Overlay (Global, above TabBar)
/// Contains MiniPlayerBar and ExpandedPlayerSheet with drag gestures.
/// Place in MainShellView as overlay.

struct PlayerOverlay: View {
    @State private var audioStore = AudioPlaybackStore.shared
    @GestureState private var dragOffset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            if audioStore.displayState != .hidden {
                Group {
                    switch audioStore.displayState {
                    case .mini:
                        MiniPlayerBar()
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    case .expanded:
                        ExpandedPlayerSheet()
                            .frame(maxHeight: 440)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    case .hidden:
                        EmptyView()
                    }
                }
                .offset(y: dragOffset > 0 ? dragOffset : dragOffset * 0.3)
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($dragOffset) { value, state, _ in
                            state = value.translation.height
                        }
                        .onEnded { value in
                            let velocity = value.predictedEndTranslation.height
                            
                            if audioStore.displayState == .expanded {
                                if value.translation.height > 80 || velocity > 300 {
                                    // Swipe down from expanded → collapse to mini
                                    audioStore.collapse()
                                }
                            } else if audioStore.displayState == .mini {
                                if value.translation.height < -60 || velocity < -200 {
                                    // Swipe up from mini → expand
                                    audioStore.expand()
                                } else if value.translation.height > 80 || velocity > 300 {
                                    // Swipe down from mini → dismiss
                                    audioStore.dismiss()
                                }
                            }
                        }
                )
                .padding(.horizontal, audioStore.displayState == .expanded ? 10 : 14)
                .padding(.bottom, audioStore.displayState == .expanded ? 90 : 76)
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: audioStore.displayState)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: audioStore.displayState)
    }
}
