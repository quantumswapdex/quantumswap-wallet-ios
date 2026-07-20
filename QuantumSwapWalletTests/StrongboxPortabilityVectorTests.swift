// StrongboxPortabilityVectorTests.swift
// Cross-platform v=3 portability vector suite (iOS side).
// Bulky test inputs are generated dynamically from one hardcoded
// 32-byte seed using SHAKE-256:
// `SHAKE256(seed || UTF8(label), length)`. The Android
// counterpart (`StrongboxPortabilityVectorTest.java`) uses the
// same seed, labels, and lengths, so both platforms build
// byte-identical wallet entries, payloads, AEAD nonces, MAC
// keys, and canonical JSON without checking large fixture
// blobs into either repo.
// Public RFC vectors remain inline where they add value (HMAC
// RFC 4231 and HKDF RFC 5869). The seed-derived vectors pin the
// app-specific strongbox operations; the RFC vectors pin the
// primitive against a published source.
// Mirrors Android's `StrongboxPortabilityVectorTest.java`
// test-for-test.
import XCTest
import CryptoKit
@testable import QuantumSwapWallet

final class StrongboxPortabilityVectorTests: XCTestCase {

    private static func vectorBytes(_ label: String, count: Int) -> Data {
        return StrongboxPortabilityFixtures.vectorBytes(label, count: count)
    }

    func testSeededShakeGeneratorMatchesPinnedSanityOutput() {
        XCTAssertEqual(
            "3f750698656d309fdc960e2734da21f566c606dd1a6d3eacd4a0accf612e2e5e",
            Self.vectorBytes("sanity", count: 32).portabilityHex)
    }

    func testPublishedRfcVectorsHmacAndHkdfStillPass() {
        let key = Data(repeating: 0x0b, count: 20)
        let message = Data("Hi There".utf8)
        XCTAssertEqual(
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            Mac.hmacSha256(message: message, keyBytes: key).portabilityHex)

        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data(portabilityHex: "000102030405060708090a0b0c")
        let info = Data(portabilityHex: "f0f1f2f3f4f5f6f7f8f9")
        XCTAssertEqual(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            Mac.hkdfExtractAndExpand(
                inputKeyMaterial: ikm,
                salt: salt,
                info: info,
                length: 42).portabilityHex)
    }

    func testSeededVectorsSha256HmacHkdfAndNullSalt() {
        XCTAssertEqual(
            "ff66ba39bd1f20448546e3ffa81b94c825d99146eda08831275091b669b2d6fd",
            Data(SHA256.hash(data: Self.vectorBytes("ui-json", count: 24)))
                .portabilityHex)

        let hmacKey = Self.vectorBytes("hmac-key", count: 32)
        let hmacMsg = Self.vectorBytes("hmac-message", count: 64)
        XCTAssertEqual(
            "26fdba9fbeea48116787b86f18ef76cabd9ea0b9be9bdb051a1f6e03d2e9c0bd",
            Mac.hmacSha256(message: hmacMsg, keyBytes: hmacKey).portabilityHex)

        let mainKey = Self.vectorBytes("main-key", count: 32)
        let derived = Mac.hkdfExtractAndExpand(
            inputKeyMaterial: mainKey,
            salt: Data(),
            info: Strongbox.checksumInfoLabel,
            length: 32)
        XCTAssertEqual(
            "db2b97d934c15e0886ac92c2bfc70d66031224e7e320b75e165dab53fb2e6a28",
            derived.portabilityHex)
    }

    func testSeededVectorsAeadWithInjectedIv() throws {
        let key = Self.vectorBytes("aead-key", count: 32)
        let plaintext = Self.vectorBytes("aead-plaintext", count: 128)
        let iv = Self.vectorBytes("aead-iv", count: 12)
        let envelope = try SecureRandom.withDeterministicSequence(iv) {
            try Aead.seal(plaintext, keyBytes: key)
        }
        let obj = try JSONSerialization.jsonObject(
            with: Data(envelope.utf8)) as! [String: Any]
        let combined = Data(base64Encoded: obj["cipherText"] as! String)!
        XCTAssertEqual(
            "b771bd60f06caaee53dd18a36d955f72041f5861c6f167c54b0321d5fd784feb",
            Data(SHA256.hash(data: combined)).portabilityHex)
        XCTAssertEqual(try Aead.open(envelope, keyBytes: key), plaintext)
    }

    func testSeededVectorsWalletEntryAndPayloadCanonicalization() throws {
        let encoded0 = try WalletEntryCodec.encode(
            StrongboxPortabilityFixtures.generatedWallet(0))
        let raw0 = Data(base64Encoded: encoded0)!
        XCTAssertEqual(
            "18f96856157288d9193d30beeaa1ea5565a3a373899489a0c610b6990897e1fb",
            Data(SHA256.hash(data: raw0)).portabilityHex)
        let decoded0 = try WalletEntryCodec.decode(encoded0)
        XCTAssertEqual("0x682c2d17c3b9826f47e37191e603a02241ece393",
            decoded0.address)
        XCTAssertTrue(decoded0.hasSeed)

        let payload = try StrongboxPortabilityFixtures.generatedPayload()
        // The Android counterpart in
        // `StrongboxPortabilityVectorTest.java` pins the same hash
        // because both platforms feed an identical SHAKE-256-
        // derived payload through the same canonicalization rules.
        XCTAssertEqual(
            "10db07da9d717d49d5eb1a5bce04ebce43f311aebc812719c591deacf564c862",
            Data(SHA256.hash(data: Strongbox.canonicalBytesForChecksum(of: payload)))
                .portabilityHex)

        // Regression: `backupEnabled` MUST NOT appear anywhere in
        // the canonical JSON (it is a UserDefaults pref, not a
        // payload field).
        let canonical = String(
            data: Strongbox.canonicalBytesForChecksum(of: payload),
            encoding: .utf8) ?? ""
        XCTAssertFalse(canonical.contains("backupEnabled"),
            "backupEnabled key must be absent from canonical JSON; "
            + "got: \(canonical)")

        let stamped = Strongbox.stampChecksum(
            of: payload,
            mainKey: Self.vectorBytes("main-key", count: 32))
        XCTAssertTrue(Strongbox.verifyChecksum(
            of: stamped,
            mainKey: Self.vectorBytes("main-key", count: 32)))
        XCTAssertEqual("LEA8Ii0ZbbwhLy0Q8oAEUWFNPvBAGiRgW7k4mzAW4as=",
            stamped.checksum)

        let tampered = StrongboxPayload(
            v: stamped.v,
            wallets: stamped.wallets,
            currentWalletIndex: stamped.currentWalletIndex,
            customNetworks: stamped.customNetworks,
            activeNetworkIndex: stamped.activeNetworkIndex + 1,
            cloudBackupFolderUri: stamped.cloudBackupFolderUri,
            advancedSigning: stamped.advancedSigning,
            cameraPermissionAskedOnce: stamped.cameraPermissionAskedOnce,
            secureItems: stamped.secureItems,
            checksum: stamped.checksum)
        XCTAssertFalse(Strongbox.verifyChecksum(
            of: tampered,
            mainKey: Self.vectorBytes("main-key", count: 32)))
    }

    func testSeededVectorsPaddingBucketRoundTrip() throws {
        let payloadBytes = Strongbox.canonicalBytesForChecksum(
            of: try StrongboxPortabilityFixtures.generatedPayload())
        let padded = try StrongboxPadding.pad(payloadBytes)
        XCTAssertEqual(padded.count, 4_194_304)
        let unpadded = try StrongboxPadding.unpad(padded)
        XCTAssertEqual(unpadded, payloadBytes)
    }
}
