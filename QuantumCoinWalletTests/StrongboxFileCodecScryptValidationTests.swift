// StrongboxFileCodecScryptValidationTests.swift
// Regression coverage for the scrypt parameter min-bound guard
// inside `StrongboxFileCodec.decodeOnly`.
// Without this guard, an attacker who could place a slot file
// (e.g. via Auto-Backup restore) plus the user's known password
// could craft a valid v=3 envelope with `N=1024, r=1, p=1`; the
// slot's MAC verifies under those weakened params (because the
// MAC key is HKDF(mainKey, salt, "integrity-v2") and `mainKey`
// is the scrypt output), so the only thing standing between a
// brute-forceable slot and unlock is this min-bound check.
// Mirrors Android's `StrongboxFileCodecScryptValidationTest.java`
// test-for-test.
import XCTest
@testable import QuantumCoinWallet

final class StrongboxFileCodecScryptValidationTests: XCTestCase {

    func testValidateScryptParamsAcceptsDocumentedDefaults() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N, r: JsBridge.SCRYPT_R,
            p: JsBridge.SCRYPT_P, keyLen: JsBridge.SCRYPT_KEY_LEN)
        let decoded = try StrongboxFileCodec.decodeOnly(bytes)
        XCTAssertEqual(decoded.kdfParams.N, JsBridge.SCRYPT_N)
        XCTAssertEqual(decoded.kdfParams.r, JsBridge.SCRYPT_R)
        XCTAssertEqual(decoded.kdfParams.p, JsBridge.SCRYPT_P)
        XCTAssertEqual(decoded.kdfParams.keyLen, JsBridge.SCRYPT_KEY_LEN)
    }

    func testValidateScryptParamsAcceptsAboveDefault() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N * 2, r: JsBridge.SCRYPT_R + 1,
            p: JsBridge.SCRYPT_P + 1, keyLen: JsBridge.SCRYPT_KEY_LEN + 1)
        let decoded = try StrongboxFileCodec.decodeOnly(bytes)
        XCTAssertEqual(decoded.kdfParams.N, JsBridge.SCRYPT_N * 2)
    }

    func testValidateScryptParamsRejectsLowN() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: 1024, r: JsBridge.SCRYPT_R,
            p: JsBridge.SCRYPT_P, keyLen: JsBridge.SCRYPT_KEY_LEN)
        StrongboxSlotJsonFixtures.assertCodecRejectsAsMalformed(bytes,
            reason: "N=1024 must be rejected (well below 262144 floor)")
    }

    func testValidateScryptParamsRejectsLowR() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N, r: 1,
            p: JsBridge.SCRYPT_P, keyLen: JsBridge.SCRYPT_KEY_LEN)
        StrongboxSlotJsonFixtures.assertCodecRejectsAsMalformed(bytes,
            reason: "r=1 must be rejected (block-mix bound)")
    }

    func testValidateScryptParamsRejectsLowKeyLen() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N, r: JsBridge.SCRYPT_R,
            p: JsBridge.SCRYPT_P, keyLen: 16)
        StrongboxSlotJsonFixtures.assertCodecRejectsAsMalformed(bytes,
            reason: "keyLen=16 must be rejected "
                + "(we mandate 32 bytes for AES-256-GCM keying)")
    }

    func testValidateScryptParamsRejectsZeroP() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N, r: JsBridge.SCRYPT_R,
            p: 0, keyLen: JsBridge.SCRYPT_KEY_LEN)
        StrongboxSlotJsonFixtures.assertCodecRejectsAsMalformed(bytes,
            reason: "p=0 must be rejected (no parallelism is degenerate)")
    }

    func testKdfParamsPublicCtorAcceptsArbitraryValues() {
        // Defense-in-depth note: the value-type constructor
        // remains permissive. Only the codec / unlock guards
        // enforce the documented minimum; the constructor stays
        // permissive so test cases can model both legal and
        // attacker-crafted shapes.
        let weak = StrongboxFileCodec.KdfParams(N: 1024, r: 1, p: 1, keyLen: 16)
        XCTAssertEqual(weak.N, 1024)
        XCTAssertEqual(weak.r, 1)
        XCTAssertEqual(weak.p, 1)
        XCTAssertEqual(weak.keyLen, 16)
    }
}
