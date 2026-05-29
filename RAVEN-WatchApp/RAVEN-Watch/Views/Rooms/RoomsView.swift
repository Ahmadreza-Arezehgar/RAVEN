// RoomsView.swift
//
// Active voice rooms only. We never show empty state for rooms because
// the tab is hidden from RootView when there are none. Tap to join,
// tap-and-hold the big mic to talk (push-to-talk). All RTC plumbing
// lives on the phone — the Watch UI just sends room-membership + ptt
// intents.

import SwiftUI

struct RoomsView: View {
    @EnvironmentObject var store: WatchStore

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.snapshot.rooms) { room in
                    NavigationLink {
                        RoomDetailView(room: room)
                    } label: {
                        RoomRow(room: room)
                    }
                }
            }
            .listStyle(.carousel)
            .navigationTitle("Rooms")
        }
    }
}

private struct RoomRow: View {
    let room: RoomSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(room.name).font(.headline).lineLimit(1)
                Spacer()
                if room.joinedByMe {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.caption2)
                Text("\(room.participantCount)").font(.caption2)
            }
            .foregroundStyle(.secondary)
            if let speaker = room.activeSpeakerName {
                Label(speaker, systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct RoomDetailView: View {
    let room: RoomSummary
    @EnvironmentObject var bridge: PhoneBridge
    @State private var talking = false

    var body: some View {
        VStack(spacing: 8) {
            Text(room.name).font(.headline)
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.caption)
                Text("\(room.participantCount)").font(.caption)
            }
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task {
                    talking.toggle()
                    _ = await bridge.setPTT(roomId: room.id, talking: talking)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(talking ? .red : .gray.opacity(0.4))
                        .frame(width: 70, height: 70)
                    Image(systemName: "mic.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(!room.joinedByMe)
            Text(talking ? "Talking…" : (room.joinedByMe ? "Hold to talk" : "Join first"))
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button(room.joinedByMe ? "Leave" : "Join") {
                    Task {
                        _ = await bridge.setRoomMembership(
                            roomId: room.id, joined: !room.joinedByMe
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(room.joinedByMe ? .red : .accentColor)
            }
        }
        .padding(6)
        .navigationTitle("Room")
        .navigationBarTitleDisplayMode(.inline)
    }
}
