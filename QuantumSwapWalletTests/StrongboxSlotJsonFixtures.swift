// StrongboxSlotJsonFixtures.swift
// Shared test-only helper that builds a minimal but
// well-shaped v=3 strongbox slot JSON for the scrypt-validation
// and decode-only paths in the codec. The Android equivalent is
// the inline `StrongboxFileCodecScryptValidationTest` helper;
// extracting it here lets the dedicated Swift port and the
// existing `StrongboxLayerTests` share the same shape.
import Foundation
import XCTest
import CryptoKit
@testable import QuantumSwapWallet

enum StrongboxSlotJsonFixtures {

    /// Build a minimal but well-shaped v=3 slot JSON with the
    /// supplied scrypt parameters. The AEAD bytes do not need
    /// to actually decrypt; the JSON just needs to be well
    /// formed enough that `decodeOnly` reaches `kdf.params`
    /// validation. The `mac` field is a placeholder because
    /// MAC verification is a separate post-decode step
    /// (`verifyFileLevelMac`).
    static func buildSlotJsonBytes(
        N: Int, r: Int, p: Int, keyLen: Int
    ) throws -> Data {
        let salt = Data((1...32).map { UInt8($0) })
        let iv = Data((1...12).map { UInt8($0) })
        let ct = Data((0..<32).map { UInt8($0) })
        let tag = Data((0..<16).map { UInt8($0) })

        let envelope: [String: Any] = [
            "alg": "AES-GCM",
            "iv": iv.base64EncodedString(),
            "ct": ct.base64EncodedString(),
            "tag": tag.base64EncodedString(),
        ]

        let kdfParamsJson: [String: Any] = [
            "N": N, "r": r, "p": p, "keyLen": keyLen,
        ]
        let kdf: [String: Any] = [
            "algorithm": "scrypt",
            "salt": salt.base64EncodedString(),
            "params": kdfParamsJson,
        ]

        let wrap: [String: Any] = ["passwordWrap": envelope]

        let uiHash = Data(SHA256.hash(data: Data("{}".utf8)))

        let root: [String: Any] = [
            "v": StrongboxFileCodec.schemaVersion,
            "generation": 1,
            "kdf": kdf,
            "wrap": wrap,
            "strongbox": envelope,
            "ui": [String: Any](),
            "uiBlockHash": uiHash.base64EncodedString(),
            "mac": Data(repeating: 0, count: 32).base64EncodedString(),
        ]

        return try JSONSerialization.data(withJSONObject: root,
            options: [.sortedKeys])
    }

    /// Assert that `decodeOnly` rejects the given slot bytes
    /// with a `malformedJson` error whose message references
    /// the documented-minimum wording (the same shape Android
    /// asserts in `StrongboxFileCodecScryptValidationTest`).
    static func assertCodecRejectsAsMalformed(
        _ slotBytes: Data, reason: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            _ = try StrongboxFileCodec.decodeOnly(slotBytes)
            XCTFail("\(reason) — decodeOnly returned without throwing",
                file: file, line: line)
        } catch let StrongboxFileCodec.Error.malformedJson(message) {
            XCTAssertTrue(message.contains("below documented minimum"),
                "expected the documented-minimum wording, got: \(message)",
                file: file, line: line)
        } catch {
            XCTFail("\(reason) — unexpected error type: \(error)",
                file: file, line: line)
        }
    }
}
