// `MESH_PROTOCOL.md` §D — the five signing canonicalizers. Each returns the
// byte string that Ed25519 must sign (or verify against).
//
// These are the **most critical** functions in the entire mesh stack:
// any byte difference between iOS / Android / Mac / Windows / Watch breaks
// signature verification, which makes every signed frame appear forged. The
// shared-vectors fixtures (`shared-vectors/v1/canonicalization/`) are the
// canonical test set — both this code and the Kotlin port at
// `RAVEN-Android/modules/mesh/src/main/kotlin/.../signing/Canonicalizers.kt`
// must produce byte-identical output.
import Foundation

public enum DmSigningCanonicalizer {
    /// §D Rule 1 — DM `SecureMeshEnvelope.signingData()`. Pipe-delimited UTF-8.
    /// Only immutable fields. Mutable DTN fields (`sc`, `hc`, `hl`, `rp`,
    /// `nf`, `ttl`, `ib`, `ig`) are excluded.
    public static func bytes(_ env: SecureMeshEnvelope) -> Data {
        var fields: [String] = [
            env.clientMessageId,
            env.roomId,
            env.senderId,
            env.senderName,
            env.recipientId,
            String(env.type),
            env.nonceB64,
            env.senderPublicKeyB64,
            String(Int64((env.timestampSec * 1000).rounded())),
            env.originDeviceId,
            env.text ?? "",
            env.mediaUrl ?? "",
            env.thumbnailUrl ?? "",
            env.fileName ?? "",
            env.mimeType ?? "",
            env.fileSize.map(String.init) ?? "",
            env.audioDurationSec.map(String.init) ?? "",
            env.replyToMessageId ?? "",
            env.replyToTextPreview ?? "",
            env.replyToSenderName ?? "",
        ]
        if let gf = env.geoFence {
            fields.append(gf.h3Cell)
            fields.append(String(gf.radiusInCells))
            fields.append(gf.deliverOnlyInside ? "true" : "false")
        }
        return Data(fields.joined(separator: "|").utf8)
    }
}

public enum PostSigningCanonicalizer {
    /// §D Rule 2 — `MeshPostEnvelope` signing bytes.
    /// Format: `"POST|postId|authorId|authorUsername|authorAvatar|text|createdAtMs|scope|signerPublicKeyB64"`.
    public static func bytes(_ post: MeshPostEnvelope) -> Data {
        let fields: [String] = [
            "POST",
            post.postId,
            post.authorId,
            post.authorUsername,
            post.authorAvatar ?? "",
            post.text,
            String(Int64((post.createdAtSec * 1000).rounded())),
            post.scope,
            post.signerPublicKeyB64 ?? "",
        ]
        return Data(fields.joined(separator: "|").utf8)
    }
}

public enum AckSigningCanonicalizer {
    /// §D Rule 4 — `MeshACKEnvelope` signing bytes. Mutable fields (`pathUsed`,
    /// `hopCount`, `routePath`) are NOT in the signed bytes; see §G.
    public static func bytes(_ ack: MeshACKEnvelope) -> Data {
        let fields: [String] = [
            ack.originalMessageId,
            ack.senderId,
            ack.recipientId,
            ack.status,
            String(Int64((ack.timestampSec * 1000).rounded())),
        ]
        return Data(fields.joined(separator: "|").utf8)
    }
}

public enum StopSigningCanonicalizer {
    /// §D Rule 5 — `StopCommand` signing bytes.
    public static func bytes(_ stop: StopCommand) -> Data {
        let fields: [String] = [
            "STOP",
            stop.messageId,
            String(Int64((stop.timestampSec * 1000).rounded())),
        ]
        return Data(fields.joined(separator: "|").utf8)
    }
}

public enum FrameJsonCanonicalizer {
    /// §D Rule 3 — feature-frame JSON-canonical form: take the entire JSON
    /// object, drop keys `s` and `spk`, re-serialize with sorted keys, UTF-8.
    ///
    /// We emit lexicographically-sorted keys + RFC 8259 string escaping,
    /// matching Apple's `JSONSerialization.sortedKeys` behaviour.
    public static func bytes(rawFrame: [String: Any]) throws -> Data {
        let stripped = rawFrame.filter { $0.key != "s" && $0.key != "spk" }
        return Data(stringify(stripped).utf8)
    }

    static func stringify(_ value: Any) -> String {
        switch value {
        case let dict as [String: Any]:
            let keys = dict.keys.sorted()
            let inner = keys.map { key in
                "\(stringify(key)):\(stringify(dict[key]!))"
            }.joined(separator: ",")
            return "{" + inner + "}"
        case let array as [Any]:
            return "[" + array.map(stringify).joined(separator: ",") + "]"
        case let s as String:
            return jsonString(s)
        case let n as NSNumber:
            // Booleans in Foundation come through as NSNumber too.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            // Integer vs floating: prefer integer rendering if exact.
            if CFNumberIsFloatType(n) {
                return String(format: "%.17g", n.doubleValue)
            }
            return n.stringValue
        case is NSNull:
            return "null"
        default:
            // Fallback — try JSONSerialization for unknown bridged types.
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                return String(data: data, encoding: .utf8) ?? "null"
            }
            return "null"
        }
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x00..<0x20:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out += String(scalar)
            }
        }
        out += "\""
        return out
    }
}
