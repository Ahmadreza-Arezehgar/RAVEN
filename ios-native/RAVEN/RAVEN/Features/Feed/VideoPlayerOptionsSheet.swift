//
//  VideoPlayerOptionsSheet.swift
//  RAVEN
//
//  The "..." sheet for the fullscreen video player. Designed to
//  match Twitter / X's video options sheet pixel-for-pixel:
//
//      ─────────                             (drag handle)
//
//      ┌─────┬─────┬─────┬─────┐
//      │ 1×  │1.25×│1.5× │ 2×  │              (segmented speed)
//      └─────┴─────┴─────┴─────┘
//
//      ⚙  Quality                 Auto (720p) ⌃
//      ▶  Auto-advance                        [●─]
//      📺 Airplay & Bluetooth
//      📼 Go to Post
//      ＋ Add to Offline
//      ☹  Not interested in this
//      🚩 Report post                         (red)
//
//  Each row uses a system-fill background, white text on black,
//  matching Twitter's dark sheet style. The sheet itself is
//  presented via SwiftUI `.sheet(...)` with a medium detent so it
//  occupies roughly the bottom half of the screen.
//

import SwiftUI

struct VideoPlayerOptionsSheet: View {

    // MARK: - Bindings

    /// Currently-selected playback rate. Owner mutates this.
    @Binding var playbackRate: Float
    /// Auto-advance preference — persists in UserDefaults so the
    /// toggle state carries across sessions.
    @Binding var autoAdvance: Bool

    /// Optional post — drives the post-aware rows (Go to Post,
    /// Add to Offline, Not interested, Report). When nil those
    /// rows are hidden.
    let post: Post?

    let onAirPlay: () -> Void
    let onGoToPost: () -> Void
    let onAddToOffline: () -> Void
    let onNotInterested: () -> Void
    let onReport: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Twitter shows a small drag handle even though sheets
            // already render one — we draw nothing extra and let
            // `.presentationDragIndicator(.visible)` do its job.

            speedSegmentedControl
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                row(icon: "slider.horizontal.3",
                    title: "Quality",
                    trailing: AnyView(qualityValueView)
                ) { /* future quality picker */ }

                Divider().background(.white.opacity(0.05))

                toggleRow(icon: "play.circle",
                          title: "Auto-advance",
                          isOn: $autoAdvance)

                Divider().background(.white.opacity(0.05))

                row(icon: "airplayvideo",
                    title: "Airplay & Bluetooth"
                ) {
                    onAirPlay()
                    dismiss()
                }

                if post != nil {
                    Divider().background(.white.opacity(0.05))
                    row(icon: "rectangle.split.2x1",
                        title: "Go to Post"
                    ) {
                        onGoToPost()
                        dismiss()
                    }

                    Divider().background(.white.opacity(0.05))
                    row(icon: "plus",
                        title: "Add to Offline"
                    ) {
                        onAddToOffline()
                        dismiss()
                    }

                    Divider().background(.white.opacity(0.05))
                    row(icon: "face.dashed",
                        title: "Not interested in this"
                    ) {
                        onNotInterested()
                        dismiss()
                    }

                    Divider().background(.white.opacity(0.05))
                    row(icon: "flag",
                        title: "Report post",
                        tint: .red
                    ) {
                        onReport()
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Speed segmented control

    private var speedSegmentedControl: some View {
        let options: [Float] = [1.0, 1.25, 1.5, 2.0]
        return HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { idx, rate in
                let isActive = abs(rate - playbackRate) < 0.01
                Button {
                    Haptics.light()
                    playbackRate = rate
                    NotificationCenter.default.post(
                        name: .ravenVideoSetPlaybackRate,
                        object: nil,
                        userInfo: ["rate": rate]
                    )
                } label: {
                    Text(rate == floor(rate)
                         ? "\(Int(rate))x"
                         : "\(rate.formatted(.number.precision(.fractionLength(0...2))))x")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isActive ? Color.white.opacity(0.18) : Color.clear)
                        )
                }
                .buttonStyle(.plain)

                if idx < options.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 0.5, height: 22)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.18))
        )
    }

    // MARK: - Quality value view

    private var qualityValueView: some View {
        HStack(spacing: 4) {
            Text("Auto (720p)")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Row builders

    private func row(
        icon: String,
        title: String,
        tint: Color = .white,
        trailing: AnyView? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                if let trailing = trailing {
                    trailing
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(
        icon: String,
        title: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
