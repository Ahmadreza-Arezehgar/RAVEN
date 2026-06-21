//
//  DemoSeeder.swift
//  RAVEN
//
//  DEBUG-only. Populates the local store with believable, fully-serverless demo
//  conversations so we can capture App Store screenshots that show RAVEN's
//  features (1:1 E2E chat, mesh/bridge delivery indicators, photos, voice notes,
//  a group, a populated inbox + contacts). NEVER ships in release.
//
//  Trigger:  launch with  -raven.demoSeed YES
//  Idempotent within an install (guarded by raven.demoSeed.done).
//

#if DEBUG
import Foundation
import UIKit
import CryptoKit

enum DemoSeeder {

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "raven.demoSeed") }

    static func seedIfRequested() async {
        guard isRequested else { return }
        guard !UserDefaults.standard.bool(forKey: "raven.demoSeed.done") else { return }
        await seed()
        UserDefaults.standard.set(true, forKey: "raven.demoSeed.done")
        await MainActor.run {
            NotificationCenter.default.post(name: AttachmentService.messageInserted, object: nil)
        }
    }

    // MARK: - Seed

    struct Peer { let id: String; let name: String }

    static func seed() async {
        let me = (await KeychainService.shared.getUserId()) ?? DeviceIdentityService.shared.fingerprint ?? "me"
        let myName = "You"

        let sarah  = Peer(id: "demo-sarah",  name: "Sarah Chen")
        let marcus = Peer(id: "demo-marcus", name: "Marcus Reed")
        let aisha  = Peer(id: "demo-aisha",  name: "Aisha Khan")
        let dad    = Peer(id: "demo-dad",    name: "Dad")
        let leo    = Peer(id: "demo-leo",    name: "Leo Martins")
        let peers  = [sarah, marcus, aisha, dad, leo]

        // Pin every peer as a trusted contact so New Chat / contacts look full.
        for p in peers {
            let key = Data(SHA256.hash(data: Data(p.id.utf8)))
            let dev = FriendDevice(
                friendUserId: p.id, fingerprint: p.id, publicKey: key,
                agreementPublicKey: key, trustState: .trusted, verifiedAt: Date(),
                deviceName: p.name, lastSeenAt: Date()
            )
            try? await FriendDeviceRepository.shared.upsert(dev)
        }

        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        let imgPath = makeDemoImage()

        // ── Sarah — the rich thread we open for the chat screenshot ──────────
        let sarahThread: [ChatMessage] = [
            txt(sarah, me, myName, "Hey! Did you try the new offline mesh mode? 🛰️", incoming: true,  at: ago(58)),
            txt(sarah, me, myName, "Sent you a photo with zero signal — pure peer-to-peer", incoming: false, at: ago(55), status: .delivered),
            img(sarah, me, myName, imgPath, at: ago(54), status: .delivered),
            txt(sarah, me, myName, "Whoa. And it's end-to-end encrypted?", incoming: true,  at: ago(41)),
            txt(sarah, me, myName, "Always. No account, no server ever sees it 🔒", incoming: false, at: ago(39), status: .read),
            voice(sarah, me, myName, seconds: 8, incoming: true, at: ago(18)),
        ]
        for m in sarahThread { try? await persist(m, me: me, image: m.type == .image ? imgPath : nil) }

        // ── A few more conversations so the inbox is alive ──────────────────
        try? await persist(txt(marcus, me, myName, "Landing in 20 — meet at the usual spot?", incoming: true, at: ago(120)), me: me)
        try? await persist(txt(marcus, me, myName, "On my way 👍", incoming: false, at: ago(118), status: .delivered), me: me)

        try? await persist(txt(aisha, me, myName, "These trip pics are unreal 😍", incoming: true, at: ago(310)), me: me)
        try? await persist(voice(aisha, me, myName, seconds: 4, incoming: false, at: ago(305)), me: me)

        try? await persist(txt(dad, me, myName, "Dinner Sunday? Your mom's cooking.", incoming: true, at: ago(1500)), me: me)
        try? await persist(txt(dad, me, myName, "Wouldn't miss it ❤️", incoming: false, at: ago(1495), status: .read), me: me)

        try? await persist(txt(leo, me, myName, "Files synced over mesh — no cloud, nice.", incoming: true, at: ago(2600)), me: me)
    }

    private static func persist(_ m: ChatMessage, me: String, image: String? = nil) async throws {
        try await MessageRepository.shared.upsert(m)
        if m.type == .image || m.type == .voice {
            // Mark media ready so the bubble renders the asset, not a spinner.
            try? await MessageRepository.shared.updateDisplayState(
                clientMessageId: m.id, state: .ready, progress: 1.0)
        }
        try await ConversationRepository.shared.applyMessage(m, currentUserId: me, isGroup: false)
    }

    // MARK: - Message factories

    private static func txt(_ peer: Peer, _ me: String, _ myName: String, _ body: String,
                            incoming: Bool, at: Date, status: MessageStatus = .delivered) -> ChatMessage {
        mk(peer, me, myName, text: body, type: .text, incoming: incoming, at: at, status: status)
    }

    private static func img(_ peer: Peer, _ me: String, _ myName: String, _ localPath: String,
                            at: Date, status: MessageStatus = .delivered) -> ChatMessage {
        mk(peer, me, myName, text: nil, type: .image, incoming: false, at: at, status: status,
           localPath: localPath, fileName: "photo.jpg", mimeType: "image/jpeg")
    }

    private static func voice(_ peer: Peer, _ me: String, _ myName: String, seconds: Int,
                              incoming: Bool, at: Date) -> ChatMessage {
        mk(peer, me, myName, text: nil, type: .voice, incoming: incoming, at: at, status: .delivered,
           fileName: "voice.m4a", mimeType: "audio/m4a", audioDuration: seconds)
    }

    private static func mk(_ peer: Peer, _ me: String, _ myName: String,
                           text: String?, type: MessageType, incoming: Bool, at: Date,
                           status: MessageStatus,
                           localPath: String? = nil, fileName: String? = nil,
                           mimeType: String? = nil, audioDuration: Int? = nil) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            serverId: nil,
            roomId: peer.id,
            senderId: incoming ? peer.id : me,
            senderName: incoming ? peer.name : myName,
            recipientId: incoming ? me : peer.id,
            text: text,
            timestamp: at,
            type: type,
            status: incoming ? .delivered : status,
            deliveryAuthority: .mesh,            // 🟣 "via Direct Mesh"
            createdAt: at,
            deliveredAt: at,
            readAt: status == .read ? at : nil,
            hopCount: 1,
            routePath: [],
            sprayCounter: 0,
            hopLimit: 6,
            originDeviceId: incoming ? peer.id : me,
            needsForwarding: false,
            attachmentUrl: nil,
            thumbnailUrl: nil,
            fileName: fileName,
            mimeType: mimeType,
            fileSize: nil,
            audioDurationSeconds: audioDuration,
            syncState: .localOnly,
            localPath: localPath,
            uploadProgress: nil,
            lastError: nil,
            replyToMessageId: nil,
            replyToTextPreview: nil,
            replyToSenderName: nil,
            replyToType: nil,
            sendMode: nil,
            scheduledAtUtc: nil
        )
    }

    // MARK: - Demo image (gradient + glyph), written to the caches dir

    private static func makeDemoImage() -> String {
        let size = CGSize(width: 1080, height: 1350)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.36, green: 0.20, blue: 0.92, alpha: 1).cgColor,
                          UIColor(red: 0.10, green: 0.45, blue: 0.95, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let glyph = "🛰️"
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 360)]
            let s = NSAttributedString(string: glyph, attributes: attrs)
            let b = s.size()
            s.draw(at: CGPoint(x: (size.width - b.width) / 2, y: (size.height - b.height) / 2))
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("raven_media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("demo-photo.jpg")
        try? img.jpegData(compressionQuality: 0.9)?.write(to: url, options: .atomic)
        return url.path
    }
}
#endif
