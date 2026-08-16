//
//  ATSAMMlKem768IncrementalLab.swift
//  RAVENTests — test-target-only validator and optional Rust C-ABI binder.
//
//  The FFI declarations are compiled only when the Debug lab command supplies
//  RAVEN_MLKEM768_INCREMENTAL_FFI and links the Rust static library.
//

#if DEBUG

import CryptoKit
import Foundation

#if RAVEN_MLKEM768_INCREMENTAL_FFI
@_silgen_name("raven_mlkem768_len_seed")
private func raven_mlkem768_len_seed() -> Int
@_silgen_name("raven_mlkem768_len_coins")
private func raven_mlkem768_len_coins() -> Int
@_silgen_name("raven_mlkem768_len_dk")
private func raven_mlkem768_len_dk() -> Int
@_silgen_name("raven_mlkem768_len_header")
private func raven_mlkem768_len_header() -> Int
@_silgen_name("raven_mlkem768_len_ek_vector")
private func raven_mlkem768_len_ek_vector() -> Int
@_silgen_name("raven_mlkem768_len_state")
private func raven_mlkem768_len_state() -> Int
@_silgen_name("raven_mlkem768_len_ct1")
private func raven_mlkem768_len_ct1() -> Int
@_silgen_name("raven_mlkem768_len_ct2")
private func raven_mlkem768_len_ct2() -> Int
@_silgen_name("raven_mlkem768_len_ss")
private func raven_mlkem768_len_ss() -> Int
#endif

enum ATSAMMlKem768IncrementalLab {
    #if RAVEN_MLKEM768_INCREMENTAL_FFI
    static let seedLength = Int(raven_mlkem768_len_seed())
    static let coinsLength = Int(raven_mlkem768_len_coins())
    static let dkLength = Int(raven_mlkem768_len_dk())
    static let headerLength = Int(raven_mlkem768_len_header())
    static let ekVectorLength = Int(raven_mlkem768_len_ek_vector())
    static let encapsStateLength = Int(raven_mlkem768_len_state())
    static let ct1Length = Int(raven_mlkem768_len_ct1())
    static let ct2Length = Int(raven_mlkem768_len_ct2())
    static let sharedSecretLength = Int(raven_mlkem768_len_ss())
    #else
    // Keep in sync with raven_mlkem768_incremental.h macros (§9.4).
    static let seedLength = 64
    static let coinsLength = 32
    static let dkLength = 2_400
    static let headerLength = 64
    static let ekVectorLength = 1_152
    static let encapsStateLength = 2_080
    static let ct1Length = 960
    static let ct2Length = 128
    static let sharedSecretLength = 32
    #endif

    struct Material {
        var seed: Data
        var coins: Data
        var dk: Data
        var header: Data
        var ekVector: Data
        var encapsState: Data
        var ct1: Data
        var ct2: Data
        var sharedSecret: Data

        /// Zero secret-bearing buffers after use (§9.3 / §9.5).
        mutating func wipeSecrets() {
            ATSAMMlKem768IncrementalLab.wipe(&seed)
            ATSAMMlKem768IncrementalLab.wipe(&coins)
            ATSAMMlKem768IncrementalLab.wipe(&dk)
            ATSAMMlKem768IncrementalLab.wipe(&encapsState)
            ATSAMMlKem768IncrementalLab.wipe(&sharedSecret)
        }
    }

    enum ValidationError: Error, Equatable {
        case invalidLength(field: String, expected: Int, actual: Int)
        case sha3Unavailable
        case headerHashMismatch
    }

    /// Explicitly zeroize mutable secret bytes (Array or Data storage).
    static func wipe(_ data: inout Data) {
        if data.isEmpty { return }
        data.withUnsafeMutableBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                base.update(repeating: 0, count: raw.count)
            }
        }
    }

    static func wipe(_ bytes: inout [UInt8]) {
        for index in bytes.indices {
            bytes[index] = 0
        }
    }

    static func validate(_ material: Material) throws {
        try requireLength(material.seed, field: "seed_hex", expected: seedLength)
        try requireLength(material.coins, field: "coins_hex", expected: coinsLength)
        try requireLength(material.dk, field: "dk_hex", expected: dkLength)
        try requireLength(material.header, field: "header_hex", expected: headerLength)
        try requireLength(
            material.ekVector,
            field: "ek_vector_hex",
            expected: ekVectorLength
        )
        try requireLength(
            material.encapsState,
            field: "encaps_state_hex",
            expected: encapsStateLength
        )
        try requireLength(material.ct1, field: "ct1_hex", expected: ct1Length)
        try requireLength(material.ct2, field: "ct2_hex", expected: ct2Length)
        try requireLength(
            material.sharedSecret,
            field: "ss_hex",
            expected: sharedSecretLength
        )
        try validateHeader(material.header, ekVector: material.ekVector)
    }

    static func validateHeader(_ header: Data, ekVector: Data) throws {
        try requireLength(header, field: "header_hex", expected: headerLength)
        try requireLength(
            ekVector,
            field: "ek_vector_hex",
            expected: ekVectorLength
        )

        let rho = Data(header.prefix(32))
        var hashInput = ekVector
        hashInput.append(rho)
        let expectedHash: Data
        if #available(iOS 26.0, macOS 26.0, *) {
            expectedHash = Data(SHA3_256.hash(data: hashInput))
        } else {
            throw ValidationError.sha3Unavailable
        }

        guard Data(header.suffix(32)) == expectedHash else {
            throw ValidationError.headerHashMismatch
        }
    }

    fileprivate static func requireLength(
        _ data: Data,
        field: String,
        expected: Int
    ) throws {
        guard data.count == expected else {
            throw ValidationError.invalidLength(
                field: field,
                expected: expected,
                actual: data.count
            )
        }
    }
}

#if RAVEN_MLKEM768_INCREMENTAL_FFI

@_silgen_name("raven_mlkem768_keygen_split")
private func raven_mlkem768_keygen_split(
    _ seed: UnsafePointer<UInt8>,
    _ seedLen: Int,
    _ dkOut: UnsafeMutablePointer<UInt8>,
    _ dkOutLen: Int,
    _ headerOut: UnsafeMutablePointer<UInt8>,
    _ headerOutLen: Int,
    _ vectorOut: UnsafeMutablePointer<UInt8>,
    _ vectorOutLen: Int
) -> Int32

@_silgen_name("raven_mlkem768_validate")
private func raven_mlkem768_validate(
    _ header: UnsafePointer<UInt8>,
    _ headerLen: Int,
    _ vector: UnsafePointer<UInt8>,
    _ vectorLen: Int
) -> Int32

@_silgen_name("raven_mlkem768_encaps1")
private func raven_mlkem768_encaps1(
    _ header: UnsafePointer<UInt8>,
    _ headerLen: Int,
    _ coins: UnsafePointer<UInt8>,
    _ coinsLen: Int,
    _ stateOut: UnsafeMutablePointer<UInt8>,
    _ stateOutLen: Int,
    _ ct1Out: UnsafeMutablePointer<UInt8>,
    _ ct1OutLen: Int,
    _ sharedSecretOut: UnsafeMutablePointer<UInt8>,
    _ sharedSecretOutLen: Int
) -> Int32

@_silgen_name("raven_mlkem768_encaps2")
private func raven_mlkem768_encaps2(
    _ state: UnsafePointer<UInt8>,
    _ stateLen: Int,
    _ header: UnsafePointer<UInt8>,
    _ headerLen: Int,
    _ vector: UnsafePointer<UInt8>,
    _ vectorLen: Int,
    _ ct2Out: UnsafeMutablePointer<UInt8>,
    _ ct2OutLen: Int
) -> Int32

@_silgen_name("raven_mlkem768_decaps")
private func raven_mlkem768_decaps(
    _ dk: UnsafePointer<UInt8>,
    _ dkLen: Int,
    _ ct1: UnsafePointer<UInt8>,
    _ ct1Len: Int,
    _ ct2: UnsafePointer<UInt8>,
    _ ct2Len: Int,
    _ sharedSecretOut: UnsafeMutablePointer<UInt8>,
    _ sharedSecretOutLen: Int
) -> Int32

extension ATSAMMlKem768IncrementalLab {
    struct KeyPair {
        var dk: Data
        var header: Data
        var ekVector: Data

        mutating func wipeSecrets() {
            ATSAMMlKem768IncrementalLab.wipe(&dk)
        }
    }

    struct Encaps1Output {
        var state: Data
        var ct1: Data
        var sharedSecret: Data

        mutating func wipeSecrets() {
            ATSAMMlKem768IncrementalLab.wipe(&state)
            ATSAMMlKem768IncrementalLab.wipe(&sharedSecret)
        }
    }

    enum FFIError: Error, Equatable {
        case operationFailed(name: String, status: Int32)
    }

    static func assertExportedLengthConstants() {
        precondition(seedLength == 64)
        precondition(coinsLength == 32)
        precondition(dkLength == 2_400)
        precondition(headerLength == 64)
        precondition(ekVectorLength == 1_152)
        precondition(encapsStateLength == 2_080)
        precondition(ct1Length == 960)
        precondition(ct2Length == 128)
        precondition(sharedSecretLength == 32)
    }

    static func keygenSplit(seed: Data) throws -> KeyPair {
        try requireLength(seed, field: "seed", expected: seedLength)
        var seedBytes = [UInt8](seed)
        var dk = [UInt8](repeating: 0, count: dkLength)
        var header = [UInt8](repeating: 0, count: headerLength)
        var vector = [UInt8](repeating: 0, count: ekVectorLength)

        let status = seedBytes.withUnsafeBufferPointer { seedBuffer in
            dk.withUnsafeMutableBufferPointer { dkBuffer in
                header.withUnsafeMutableBufferPointer { headerBuffer in
                    vector.withUnsafeMutableBufferPointer { vectorBuffer in
                        raven_mlkem768_keygen_split(
                            seedBuffer.baseAddress!,
                            seedBuffer.count,
                            dkBuffer.baseAddress!,
                            dkBuffer.count,
                            headerBuffer.baseAddress!,
                            headerBuffer.count,
                            vectorBuffer.baseAddress!,
                            vectorBuffer.count
                        )
                    }
                }
            }
        }
        wipe(&seedBytes)
        defer {
            wipe(&dk)
            wipe(&header)
            wipe(&vector)
        }
        try requireSuccess(status, operation: "keygen_split")
        return KeyPair(
            dk: Data(dk),
            header: Data(header),
            ekVector: Data(vector)
        )
    }

    static func validateSplit(header: Data, ekVector: Data) throws {
        try requireLength(header, field: "header", expected: headerLength)
        try requireLength(
            ekVector,
            field: "ek_vector",
            expected: ekVectorLength
        )
        let headerBytes = [UInt8](header)
        let vectorBytes = [UInt8](ekVector)
        let status = headerBytes.withUnsafeBufferPointer { headerBuffer in
            vectorBytes.withUnsafeBufferPointer { vectorBuffer in
                raven_mlkem768_validate(
                    headerBuffer.baseAddress!,
                    headerBuffer.count,
                    vectorBuffer.baseAddress!,
                    vectorBuffer.count
                )
            }
        }
        try requireSuccess(status, operation: "validate")
    }

    static func encaps1(header: Data, coins: Data) throws -> Encaps1Output {
        try requireLength(header, field: "header", expected: headerLength)
        try requireLength(coins, field: "coins", expected: coinsLength)
        let headerBytes = [UInt8](header)
        var coinsBytes = [UInt8](coins)
        var state = [UInt8](repeating: 0, count: encapsStateLength)
        var ct1 = [UInt8](repeating: 0, count: ct1Length)
        var sharedSecret = [UInt8](
            repeating: 0,
            count: sharedSecretLength
        )

        let status = headerBytes.withUnsafeBufferPointer { headerBuffer in
            coinsBytes.withUnsafeBufferPointer { coinsBuffer in
                state.withUnsafeMutableBufferPointer { stateBuffer in
                    ct1.withUnsafeMutableBufferPointer { ct1Buffer in
                        sharedSecret.withUnsafeMutableBufferPointer {
                            sharedSecretBuffer in
                            raven_mlkem768_encaps1(
                                headerBuffer.baseAddress!,
                                headerBuffer.count,
                                coinsBuffer.baseAddress!,
                                coinsBuffer.count,
                                stateBuffer.baseAddress!,
                                stateBuffer.count,
                                ct1Buffer.baseAddress!,
                                ct1Buffer.count,
                                sharedSecretBuffer.baseAddress!,
                                sharedSecretBuffer.count
                            )
                        }
                    }
                }
            }
        }
        wipe(&coinsBytes)
        defer {
            wipe(&state)
            wipe(&ct1)
            wipe(&sharedSecret)
        }
        try requireSuccess(status, operation: "encaps1")
        return Encaps1Output(
            state: Data(state),
            ct1: Data(ct1),
            sharedSecret: Data(sharedSecret)
        )
    }

    static func encaps2(
        state: Data,
        header: Data,
        ekVector: Data
    ) throws -> Data {
        try requireLength(
            state,
            field: "encaps_state",
            expected: encapsStateLength
        )
        try requireLength(header, field: "header", expected: headerLength)
        try requireLength(
            ekVector,
            field: "ek_vector",
            expected: ekVectorLength
        )
        var stateBytes = [UInt8](state)
        let headerBytes = [UInt8](header)
        let vectorBytes = [UInt8](ekVector)
        var ct2 = [UInt8](repeating: 0, count: ct2Length)

        let status = stateBytes.withUnsafeBufferPointer { stateBuffer in
            headerBytes.withUnsafeBufferPointer { headerBuffer in
                vectorBytes.withUnsafeBufferPointer { vectorBuffer in
                    ct2.withUnsafeMutableBufferPointer { ct2Buffer in
                        raven_mlkem768_encaps2(
                            stateBuffer.baseAddress!,
                            stateBuffer.count,
                            headerBuffer.baseAddress!,
                            headerBuffer.count,
                            vectorBuffer.baseAddress!,
                            vectorBuffer.count,
                            ct2Buffer.baseAddress!,
                            ct2Buffer.count
                        )
                    }
                }
            }
        }
        wipe(&stateBytes)
        defer { wipe(&ct2) }
        try requireSuccess(status, operation: "encaps2")
        return Data(ct2)
    }

    static func decaps(dk: Data, ct1: Data, ct2: Data) throws -> Data {
        try requireLength(dk, field: "dk", expected: dkLength)
        try requireLength(ct1, field: "ct1", expected: ct1Length)
        try requireLength(ct2, field: "ct2", expected: ct2Length)
        var dkBytes = [UInt8](dk)
        let ct1Bytes = [UInt8](ct1)
        let ct2Bytes = [UInt8](ct2)
        var sharedSecret = [UInt8](
            repeating: 0,
            count: sharedSecretLength
        )

        let status = dkBytes.withUnsafeBufferPointer { dkBuffer in
            ct1Bytes.withUnsafeBufferPointer { ct1Buffer in
                ct2Bytes.withUnsafeBufferPointer { ct2Buffer in
                    sharedSecret.withUnsafeMutableBufferPointer {
                        sharedSecretBuffer in
                        raven_mlkem768_decaps(
                            dkBuffer.baseAddress!,
                            dkBuffer.count,
                            ct1Buffer.baseAddress!,
                            ct1Buffer.count,
                            ct2Buffer.baseAddress!,
                            ct2Buffer.count,
                            sharedSecretBuffer.baseAddress!,
                            sharedSecretBuffer.count
                        )
                    }
                }
            }
        }
        wipe(&dkBytes)
        defer { wipe(&sharedSecret) }
        try requireSuccess(status, operation: "decaps")
        return Data(sharedSecret)
    }

    private static func requireSuccess(
        _ status: Int32,
        operation: String
    ) throws {
        guard status == 0 else {
            throw FFIError.operationFailed(name: operation, status: status)
        }
    }
}

#endif

#endif
