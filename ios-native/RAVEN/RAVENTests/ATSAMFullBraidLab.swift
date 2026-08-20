//
//  ATSAMFullBraidLab.swift
//  RAVENTests — test-target-only Full Braid binder (default-off FFI).
//
//  Always available under DEBUG for vector schema checks.
//  Rust C ABI is compiled only when the Debug lab command supplies
//  RAVEN_FULL_BRAID_FFI and links libraven_fb_ffi.a.
//

#if DEBUG

import Foundation

enum ATSAMFullBraidLab {
    /// Hard-locked: never a production path.
    static let productionEnabled = false

    #if RAVEN_FULL_BRAID_FFI
    static let sizesLength = Int(raven_fb_len_sizes())
    static let metaLength = Int(raven_fb_len_meta())
    static let maxState = Int(raven_fb_max_state())
    static let maxRvbo1 = Int(raven_fb_max_rvbo1())
    static let maxRvbj1 = Int(raven_fb_max_rvbj1())
    static let maxRvorRecord = Int(raven_fb_max_rvor_record())
    #else
    // Keep in sync with raven_fb.h / raven-core constants.
    static let sizesLength = 16
    static let metaLength = 64
    static let maxState = 262_144
    static let maxRvbo1 = 16_545
    static let maxRvbj1 = 279_055
    static let maxRvorRecord = 16_741
    #endif

    static let errOk: Int32 = 0
    static let errNeedCapacity: Int32 = 1
    static let errParse: Int32 = 2
    static let errEpoch: Int32 = 3
    static let errCas: Int32 = 8
    static let errTerminalStateOp: Int32 = 9
    static let errInternal: Int32 = 10

    struct Sizes {
        var candidateLen: UInt32 = 0
        var outputsLen: UInt32 = 0
        var intentLen: UInt32 = 0
        var reserved0: UInt32 = 0
    }

    struct ResultMeta {
        var sendingEpoch: UInt64 = 0
        var receivingEpoch: UInt64 = 0
        var outputKeyEpoch: UInt64 = 0
        var flags: UInt32 = 0
        var terminalReason: UInt16 = 0
        var pendingPhase: UInt16 = 0
        var transitionId: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )

        var transitionIdData: Data {
            withUnsafeBytes(of: transitionId) { Data($0) }
        }
    }

    struct TransitionResult {
        var candidate: Data
        var outputs: Data
        var intent: Data
        var meta: ResultMeta

        mutating func wipeSecrets() {
            ATSAMFullBraidLab.wipe(&candidate)
            ATSAMFullBraidLab.wipe(&outputs)
            ATSAMFullBraidLab.wipe(&intent)
        }
    }

    enum ValidationError: Error, Equatable {
        case productionMustStayOff
        case invalidMagic(field: String)
        case invalidLength(field: String, expected: Int, actual: Int)
    }

    enum FFIError: Error, Equatable {
        case operationFailed(name: String, status: Int32)
    }

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

    static func assertLabLockedOff() throws {
        guard productionEnabled == false else {
            throw ValidationError.productionMustStayOff
        }
    }

    static func requireRvfb1Magic(_ data: Data, field: String) throws {
        let magic = Data("RVFB1".utf8)
        guard data.count >= magic.count, data.prefix(magic.count) == magic else {
            throw ValidationError.invalidMagic(field: field)
        }
    }
}

#if RAVEN_FULL_BRAID_FFI

@_silgen_name("raven_fb_ffi_keep_alive")
private func raven_fb_ffi_keep_alive() -> Int
@_silgen_name("raven_fb_len_sizes")
private func raven_fb_len_sizes() -> Int
@_silgen_name("raven_fb_len_meta")
private func raven_fb_len_meta() -> Int
@_silgen_name("raven_fb_max_state")
private func raven_fb_max_state() -> Int
@_silgen_name("raven_fb_max_rvbo1")
private func raven_fb_max_rvbo1() -> Int
@_silgen_name("raven_fb_max_rvbj1")
private func raven_fb_max_rvbj1() -> Int
@_silgen_name("raven_fb_max_rvor_record")
private func raven_fb_max_rvor_record() -> Int

@_silgen_name("raven_fb_transition_measure")
private func raven_fb_transition_measure(
    _ stateInPtr: UnsafePointer<UInt8>?,
    _ stateInLen: Int,
    _ inputPtr: UnsafePointer<UInt8>?,
    _ inputLen: Int,
    _ envPtr: UnsafePointer<UInt8>?,
    _ envLen: Int,
    _ outNeed: UnsafeMutablePointer<ATSAMFullBraidLab.Sizes>
) -> Int32

@_silgen_name("raven_fb_transition_write")
private func raven_fb_transition_write(
    _ stateInPtr: UnsafePointer<UInt8>?,
    _ stateInLen: Int,
    _ inputPtr: UnsafePointer<UInt8>?,
    _ inputLen: Int,
    _ envPtr: UnsafePointer<UInt8>?,
    _ envLen: Int,
    _ candidateOutPtr: UnsafeMutablePointer<UInt8>?,
    _ candidateCap: Int,
    _ outputsOutPtr: UnsafeMutablePointer<UInt8>?,
    _ outputsCap: Int,
    _ intentOutPtr: UnsafeMutablePointer<UInt8>?,
    _ intentCap: Int,
    _ metaOut: UnsafeMutablePointer<ATSAMFullBraidLab.ResultMeta>
) -> Int32

extension ATSAMFullBraidLab {
    static func assertExportedLayoutConstants() {
        _ = raven_fb_ffi_keep_alive()
        precondition(sizesLength == 16)
        precondition(metaLength == 64)
        precondition(MemoryLayout<Sizes>.size == sizesLength)
        precondition(MemoryLayout<ResultMeta>.size == metaLength)
        precondition(maxState == 262_144)
        precondition(maxRvbo1 == 16_545)
        precondition(maxRvbj1 == 279_055)
        precondition(maxRvorRecord == 16_741)
    }

    static func transitionPrepare(
        state: Data,
        input: Data,
        env: Data
    ) throws -> TransitionResult {
        var sizes = Sizes()
        let measureStatus: Int32 = state.withUnsafeBytes { stateRaw in
            input.withUnsafeBytes { inputRaw in
                env.withUnsafeBytes { envRaw in
                    raven_fb_transition_measure(
                        stateRaw.bindMemory(to: UInt8.self).baseAddress,
                        state.count,
                        inputRaw.bindMemory(to: UInt8.self).baseAddress,
                        input.count,
                        envRaw.bindMemory(to: UInt8.self).baseAddress,
                        env.count,
                        &sizes
                    )
                }
            }
        }
        guard measureStatus == errOk else {
            throw FFIError.operationFailed(name: "transition_measure", status: measureStatus)
        }

        let candidateCap = Int(sizes.candidateLen)
        let outputsCap = Int(sizes.outputsLen)
        let intentCap = Int(sizes.intentLen)
        var candidate = [UInt8](repeating: 0, count: candidateCap)
        var outputs = [UInt8](repeating: 0, count: outputsCap)
        var intent = [UInt8](repeating: 0, count: intentCap)
        var meta = ResultMeta()

        let writeStatus: Int32 = state.withUnsafeBytes { stateRaw in
            input.withUnsafeBytes { inputRaw in
                env.withUnsafeBytes { envRaw in
                    candidate.withUnsafeMutableBufferPointer { candidateBuf in
                        outputs.withUnsafeMutableBufferPointer { outputsBuf in
                            intent.withUnsafeMutableBufferPointer { intentBuf in
                                raven_fb_transition_write(
                                    stateRaw.bindMemory(to: UInt8.self).baseAddress,
                                    state.count,
                                    inputRaw.bindMemory(to: UInt8.self).baseAddress,
                                    input.count,
                                    envRaw.bindMemory(to: UInt8.self).baseAddress,
                                    env.count,
                                    candidateBuf.baseAddress,
                                    candidateCap,
                                    outputsBuf.baseAddress,
                                    outputsCap,
                                    intentBuf.baseAddress,
                                    intentCap,
                                    &meta
                                )
                            }
                        }
                    }
                }
            }
        }
        guard writeStatus == errOk else {
            wipe(&candidate)
            wipe(&outputs)
            wipe(&intent)
            throw FFIError.operationFailed(name: "transition_write", status: writeStatus)
        }
        let result = TransitionResult(
            candidate: Data(candidate),
            outputs: Data(outputs),
            intent: Data(intent),
            meta: meta
        )
        wipe(&candidate)
        wipe(&outputs)
        wipe(&intent)
        return result
    }
}

#endif

#endif
