// `MESH_PROTOCOL.md` §E — exact dedup-key string formats. Every frame type
// has a distinct prefix; iOS-Android interop requires hashing on the same
// key format.
import Foundation

public enum DedupKeys {
    public static func frame(_ messageId: String) -> String { "frame:\(messageId)" }
    public static func stop(_ messageId: String) -> String { "stop:\(messageId)" }

    public static func ack(originalMessageId: String, senderId: String,
                           recipientId: String, status: String) -> String {
        "ack:\(originalMessageId)|\(senderId)|\(recipientId)|\(status)"
    }

    public static func encryptedDm(nonceB64: String) -> String { "enc:\(nonceB64)" }

    /// Signed DM uses the raw clientMessageId per iOS.
    public static func signedDm(clientMessageId: String) -> String { clientMessageId }

    /// Mesh post uses raw postId in iOS's in-memory cache (§I.5 — known
    /// quirk; iOS may adopt a `post:` prefix in v2).
    public static func post(_ postId: String) -> String { postId }
}
