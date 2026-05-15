// `MESH_PROTOCOL.md` v1 — wire-protocol constants. Identical on iOS, Mac,
// Windows, Android, and Watch. Any deviation breaks interop.
import Foundation

public enum MeshConstants {
    // MARK: §A — GATT
    public static let serviceUUID = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    public static let characteristicMessageTxRx = UUID(uuidString: "12345678-1234-1234-1234-123456789ABD")!
    public static let characteristicDeviceInfo = UUID(uuidString: "12345678-1234-1234-1234-123456789ABE")!
    public static let advertisementNamePrefix = "RAVEN-"

    // MARK: §B — Chunking
    public static let chunkFlagUnchunked: UInt8 = 0x00
    public static let chunkFlagChunked: UInt8 = 0x01
    public static let chunkHeaderSize = 6
    public static let maxTotalChunks = 255
    public static let maxPendingHashKeys = 64
    public static let reassemblyGcSeconds: TimeInterval = 30
    public static let interChunkPacingMs = 15
    public static let updateValueMaxRetries = 15
    public static let defaultMtuFallback = 180

    // MARK: §D — Crypto
    public static let hkdfSaltRavenMesh = Data("RAVEN-MESH".utf8)
    public static let ed25519KeyLen = 32
    public static let ed25519SigLen = 64
    public static let x25519KeyLen = 32
    public static let ecdhSharedSecretLen = 32
    public static let aesGcmNonceLen = 12
    public static let aesGcmTagLen = 16
    public static let envelopeNonceLen = 16
    public static let rotationGraceSeconds: TimeInterval = 86_400

    // MARK: §E — Routing
    public static let sprayInitialFree = 5
    public static let sprayInitialPremium = 50
    public static let sprayProtocolMax = 50
    public static let sprayWaitThreshold = 1

    public static let ttlSecondsFree: Int64 = 86_400       // 24h
    public static let ttlSecondsPremium: Int64 = 259_200   // 72h
    public static let hopLimitFree = 10
    public static let hopLimitPremium = 50
    public static let hopLimitProtocolMax = 50

    public static let dedupPersistentDays = 30
    public static let dedupMemCacheSize = 10_000
    public static let dedupCleanupIntervalHours = 6
    public static let relayRateMsgsPerPeerPerMin = 60

    // MARK: §C.7 — Message types
    public enum MessageType {
        public static let text = 0
        public static let image = 1
        public static let file = 2
        public static let voice = 3
        public static let location = 4
        public static let postShare = 5
        public static let system = 6
        public static let video = 7
        public static let videoNote = 8
        public static let ephemeralPhoto = 9
    }

    /// Types eligible for mesh forwarding (others wait for internet).
    public static let meshAllowedTypes: Set<Int> = [
        MessageType.text, MessageType.location, MessageType.system,
    ]

    // MARK: §A — CoreBluetooth state restoration identifiers
    public static let centralRestoreId = "com.raven.ble.central.restore"
    public static let peripheralRestoreId = "com.raven.ble.peripheral.restore"
}
