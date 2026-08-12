//
//  ATSAMMlKemHybridKatTests.swift
//  RAVENTests — CryptoKit ↔ Rust ML-KEM-768 shared ciphertext KAT.
//

import XCTest
import CryptoKit
@testable import RAVEN

final class ATSAMMlKemHybridKatTests: XCTestCase {

    private func vectorsRoot() -> URL? {
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("shared-vectors/rvn1"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func loadJSON(_ rel: String) throws -> [String: Any] {
        guard let root = vectorsRoot() else {
            throw XCTSkip("shared-vectors/rvn1 not found — open monorepo checkout")
        }
        let url = root.appendingPathComponent(rel)
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    private func hex(_ s: String) -> Data {
        var data = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            data.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return data
    }

    private func toHex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    func testCryptoKitDecapsulatesRustDeterministicCiphertext() throws {
        try XCTSkipIf(!ATSAMMLKem.isAvailable, "ML-KEM requires iOS/macOS 26+")
        let v = try loadJSON("atsam/mlkem768_hybrid_kat_001.json")
        let inp = v["input"] as! [String: Any]
        let exp = v["expected"] as! [String: Any]
        let seed = hex(inp["mlkem_seed_hex"] as! String)
        let ct = hex(exp["mlkem_ct_hex"] as! String)
        let ek = try ATSAMMLKem.keyGen() // warm path; real check uses seed
        _ = ek
        // Rebuild from seed via CryptoKit and match EK + decap SS
        let z = try ATSAMMLKem.decapsulate(ciphertext: ct, privateKey: seed)
        XCTAssertEqual(toHex(z), exp["z_pq_hex"] as? String)

        if #available(iOS 26.0, macOS 26.0, *) {
            let priv = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
            XCTAssertEqual(toHex(priv.publicKey.rawRepresentation), exp["mlkem_ek_hex"] as? String)
        }
    }

    func testRustDecapsPathMatchesCryptoKitProducedCiphertextVector() throws {
        try XCTSkipIf(!ATSAMMLKem.isAvailable, "ML-KEM requires iOS/macOS 26+")
        let v = try loadJSON("atsam/mlkem768_hybrid_kat_001.json")
        let inp = v["input"] as! [String: Any]
        let exp = v["expected"] as! [String: Any]
        let seed = hex(inp["mlkem_seed_hex"] as! String)
        let ckCt = hex(exp["cryptokit_ct_hex"] as! String)
        let z = try ATSAMMLKem.decapsulate(ciphertext: ckCt, privateKey: seed)
        XCTAssertEqual(toHex(z), exp["cryptokit_z_pq_hex"] as? String)
    }

    func testHybridRootMatchesSharedVector() throws {
        let v = try loadJSON("atsam/mlkem768_hybrid_kat_001.json")
        let inp = v["input"] as! [String: Any]
        let exp = v["expected"] as! [String: Any]
        let zX = hex(exp["z_x_hex"] as! String)
        let zPQ = hex(exp["z_pq_hex"] as! String)
        let material = Data((inp["transcript_material_utf8"] as! String).utf8)
        // Match Rust transcript_hash = SHA256("ATSAM/v1/transcript" || material)
        var thInput = Data("ATSAM/v1/transcript".utf8)
        thInput.append(material)
        let th = Data(SHA256.hash(data: thInput))
        XCTAssertEqual(toHex(th), exp["transcript_hash_hex"] as? String)

        // Direct HKDF matching Raven atsam_root / ATSAMRootDerivation labels
        // (avoid constructing a full ATSAMTranscript for this known-hash KAT).
        var ikm = Data()
        ikm.append(zX)
        ikm.append(zPQ)
        var info = Data("ATSAM/v1/pair-init".utf8)
        info.append(th)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: th,
            info: info,
            outputByteCount: 32
        )
        let root = derived.withUnsafeBytes { Data($0) }
        XCTAssertEqual(toHex(root), exp["k_root_hex"] as? String)
    }
}
