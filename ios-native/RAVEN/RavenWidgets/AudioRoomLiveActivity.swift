// AudioRoomLiveActivity.swift
// RavenWidgets
//
// Dynamic Island + Lock Screen banner for Audio Room Live Activity.

import WidgetKit
import SwiftUI
import ActivityKit

/// WidgetKit views for Audio Room Dynamic Island + Lock Screen banner.
struct AudioRoomLiveActivity: Widget {
    /// Build the `raven://room/{slug}` deep link used when the user
    /// taps the Dynamic Island or the lock-screen banner. Falls back
    /// to the bare `raven://` scheme (which opens the app's last
    /// screen) for legacy rooms that don't have a shareable slug
    /// stamped on them.
    private func deepLink(for attributes: AudioRoomAttributes) -> URL {
        if let slug = attributes.shareSlug, !slug.isEmpty {
            return URL(string: "raven://room/\(slug)") ?? URL(string: "raven://")!
        }
        return URL(string: "raven://")!
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AudioRoomAttributes.self) { context in
            // MARK: - Lock Screen / StandBy banner
            //
            // `widgetURL` makes the entire banner one tap target that
            // routes through DeepLinkRouter back into the room. Lock
            // Screen Live Activities don't accept arbitrary buttons,
            // so a single deep link is the cleanest UX.
            lockScreenBanner(context)
                .widgetURL(deepLink(for: context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                // MARK: - Expanded
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("\(context.state.listenersCount)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    } icon: {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(context.state.isMuted ? .red.opacity(0.7) : .green.opacity(0.7))
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.roomTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 16) {
                        Label("\(context.state.speakersCount) speaking", systemImage: "waveform")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hue: 0.55, saturation: 0.35, brightness: 0.7))

                        Spacer()

                        HStack(spacing: 4) {
                            Circle().fill(.red).frame(width: 5, height: 5)
                            Text("LIVE")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(.red.opacity(0.8))
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                // MARK: - Compact Leading
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(hue: 0.55, saturation: 0.35, brightness: 0.7))
                    Text("\(context.state.listenersCount)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            } compactTrailing: {
                // MARK: - Compact Trailing
                Image(systemName: context.state.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(context.state.isMuted ? .red.opacity(0.7) : .green.opacity(0.7))
            } minimal: {
                // MARK: - Minimal
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(hue: 0.55, saturation: 0.35, brightness: 0.7))
            }
            // Tapping the compact / minimal Dynamic Island when collapsed
            // (or the expanded view's blank area when open) routes
            // back to the live room via the deep-link scheme.
            .widgetURL(deepLink(for: context.attributes))
            .keylineTint(Color(hue: 0.55, saturation: 0.35, brightness: 0.7))
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenBanner(_ context: ActivityViewContext<AudioRoomAttributes>) -> some View {
        HStack(spacing: 14) {
            // Waveform icon
            ZStack {
                Circle()
                    .fill(Color(hue: 0.55, saturation: 0.35, brightness: 0.55).opacity(0.2))
                    .frame(width: 40, height: 40)
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hue: 0.55, saturation: 0.35, brightness: 0.7))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.roomTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Label("\(context.state.listenersCount)", systemImage: "person.2.fill")
                    Label("\(context.state.speakersCount)", systemImage: "waveform")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            // Mic status
            Image(systemName: context.state.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(context.state.isMuted ? .red.opacity(0.7) : .green.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .padding(16)
        .background(Color(white: 0.08))
    }
}
