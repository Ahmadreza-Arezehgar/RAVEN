import XCTest
@testable import RAVEN

@MainActor
final class MessagingProductBoundaryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = DeepLinkRouter.shared.consumePending()
    }

    override func tearDown() {
        _ = DeepLinkRouter.shared.consumePending()
        super.tearDown()
    }

    func testLegacySocialDestinationsAreRefusedBeforeNavigation() {
        let router = DeepLinkRouter.shared
        let refused: [DeepLinkRouter.Destination] = [
            .post(postId: "post-1"),
            .echo(echoId: "echo-1"),
            .club(clubId: "club-1"),
            .audioRoom(slug: "public-room"),
            .newPost,
        ]

        for destination in refused {
            XCTAssertFalse(destination.isMessagingProductDestination)
            router.route(to: destination)
            XCTAssertNil(router.consumePending(), "refused destination escaped: \(destination)")
        }

        XCTAssertTrue(DeepLinkRouter.Destination.chat(roomId: "chat-1").isMessagingProductDestination)
        XCTAssertTrue(DeepLinkRouter.Destination.profileByUsername(username: "alice").isMessagingProductDestination)
    }

    func testExternalLinksAdmitOnlyOneCanonicalContactSegment() throws {
        let router = DeepLinkRouter.shared
        let refused = [
            "raven://post/post-1",
            "raven://room/public-room",
            "raven://u/alice/extra",
            "https://raven-messager.com/post/post-1",
            "https://raven-messager.com/u/alice/extra",
            "https://example.com/u/alice",
            "https://raven-messager.com/u/alice%20bob",
        ]

        for raw in refused {
            router.handleURL(try XCTUnwrap(URL(string: raw)))
            XCTAssertNil(router.consumePending(), "refused URL escaped: \(raw)")
        }

        router.handleURL(try XCTUnwrap(URL(string: "https://raven-messager.com/u/alice_1")))
        XCTAssertEqual(router.consumePending(), .profileByUsername(username: "alice_1"))
    }

    func testShareLinksAreContactOnlyAndRejectAmbiguousIdentifiers() throws {
        let kind = RavenShareKind.profile(username: "alice_1", displayName: "Alice")
        let url = try XCTUnwrap(RavenShareLink.url(for: kind))
        XCTAssertEqual(url.absoluteString, "https://raven-messager.com/u/alice_1")
        XCTAssertEqual(RavenShareLink.subject(for: kind), "Contact on RAVEN")
        XCTAssertTrue(RavenShareLink.message(for: kind).contains("as a contact"))

        XCTAssertNil(RavenShareLink.url(for: .profile(username: "alice/bob", displayName: nil)))
        XCTAssertNil(RavenShareLink.url(for: .profile(username: "alice bob", displayName: nil)))
        XCTAssertNil(RavenShareLink.url(for: .profile(username: String(repeating: "a", count: 129), displayName: nil)))
    }

    func testPushParserFailsClosedForUnknownAndRetiredSocialTypes() {
        let admitted = ["message", "group_message", "dm_message", "friend_request", "security", "added_to_group"]
        for type in admitted {
            XCTAssertNotNil(PushPayload.parseMessaging(["type": type, "chat_id": "chat-1"]))
        }

        let refused = [
            "like", "comment", "mention", "audio_room", "audio_room_join",
            "post_comment", "post_like", "follow_request", "follow", "unknown",
        ]
        for type in refused {
            XCTAssertNil(PushPayload.parseMessaging(["type": type, "chat_id": "chat-1"]), type)
        }
        XCTAssertNil(PushPayload.parseMessaging(["chat_id": "chat-1"]))

        let parsed = PushPayload.parseMessaging([
            "type": "message",
            "chat_id": "chat-1",
            "sender_id": "alice-device",
            "message_id": "message-1",
            "body": "hello",
        ])
        XCTAssertEqual(parsed?.type, .message)
        XCTAssertEqual(parsed?.chatId, "chat-1")
        XCTAssertEqual(parsed?.messageId, "message-1")
    }

    func testToastAndCachedNotificationAdmissionAreMessagingOnly() {
        let admittedServer = [
            "message", "dm_message", "group_message", "friend_request",
            "added_to_group", "group_invite", "security", "security_alert",
            "vault_access", "reaction", "contact_shared", "screenshot_chat",
            "live_location_started", "live_location_ended",
        ]
        let refusedServer = [
            "like", "comment", "mention", "new_post", "post", "audio_room",
            "audio_room_join", "follow", "profile_view", "unknown",
        ]
        XCTAssertTrue(admittedServer.allSatisfy(ServerNotification.isMessagingProductEventType))
        XCTAssertTrue(refusedServer.allSatisfy { !ServerNotification.isMessagingProductEventType($0) })

        let admittedToast: [ToastType] = [
            .message, .voice, .friendRequest, .security, .groupInvite,
            .appUpdate, .vaultAccess, .meshPeerNearby, .backupDone,
            .twoFactorRequest, .disasterMode,
        ]
        let refusedToast: [ToastType] = [.like, .comment, .audioRoomMention]
        XCTAssertTrue(admittedToast.allSatisfy(\.isMessagingProductEvent))
        XCTAssertTrue(refusedToast.allSatisfy { !$0.isMessagingProductEvent })

        let admittedCached: [LocalNotification.NotificationType] = [
            .message, .groupMessage, .friendRequest, .security, .securityAlert,
            .liveLocationStarted, .liveLocationEnded, .reaction, .contactShared,
            .screenshotChat,
        ]
        let refusedCached: [LocalNotification.NotificationType] = [
            .followRequest, .like, .comment, .mention, .newPost, .audioRoom,
            .profileView, .screenshotProfile,
        ]
        XCTAssertTrue(admittedCached.allSatisfy(\.isMessagingProductEvent))
        XCTAssertTrue(refusedCached.allSatisfy { !$0.isMessagingProductEvent })
    }

    func testWatchSnapshotMigrationIgnoresOldSocialFieldsAndFiltersEvents() throws {
        let json = #"""
        {
          "c": [],
          "n": [
            {"id":"n1","k":"comment","an":"A","ai":"A","s":"post comment","ts":1,"tg":"post:p1"},
            {"id":"n2","k":"follow","an":"B","ai":"B","s":"follow","ts":2,"tg":"profile:b"},
            {"id":"n3","k":"mention","an":"C","ai":"C","s":"chat mention","ts":3,"tg":"chat:c1"},
            {"id":"n4","k":"mention","an":"D","ai":"D","s":"public mention","ts":4,"tg":"post:p2"},
            {"id":"n5","k":"reaction","an":"E","ai":"E","s":"message reaction","ts":5,"tg":"chat:c2"},
            {"id":"n6","k":"bridgeArrived","an":"F","ai":"F","s":"offline message","ts":6,"tg":"chat:c3"}
          ],
          "ts": 7,
          "f": [{"id":"legacy-post"}],
          "r": [{"id":"legacy-room"}],
          "feed": [{"id":"legacy-post-2"}],
          "rooms": [{"id":"legacy-room-2"}]
        }
        """#

        var snapshot = try JSONDecoder().decode(WatchSnapshot.self, from: Data(json.utf8))
        snapshot.notifications.removeAll { !$0.isMessagingProductEvent }

        XCTAssertEqual(snapshot.notifications.map(\.id), ["n3", "n5", "n6"])
        XCTAssertEqual(snapshot.generatedAt, 7)
        XCTAssertTrue(snapshot.conversations.isEmpty)
    }

    func testWatchAuthPayloadNeverContainsPlaintextBearer() throws {
        let payload = try XCTUnwrap(WatchSnapshotProjector.makeEncryptedAuthPayload("sealed-token"))
        XCTAssertEqual(payload["raven.auth.token.enc"] as? String, "sealed-token")
        XCTAssertEqual(payload["raven.auth.token.kid"] as? String, "v1")
        XCTAssertNil(payload["raven.auth.token"])
        XCTAssertNil(WatchSnapshotProjector.makeEncryptedAuthPayload(nil))
        XCTAssertNil(WatchSnapshotProjector.makeEncryptedAuthPayload(""))
    }
}
