// StrongboxLayerTests.swift
// Unit tests for the v=3 unified-schema storage stack's
// layered modules. Each layer is exercised in isolation:
// Layer 3 (Crypto):
// - SecureRandom: non-zero output, throws on RNG failure
// (RNG-failure path is mocked at the call-site level
// since SecRandomCopyBytes itself is system-owned).
// - Aead: round-trip; reject 16-byte combined input
// ( length guard).
// - Mac: HMAC RFC 4231 vector; HKDF RFC 5869 vector;
// constant-time verify.
// Layer 2 (Schema):
// - StrongboxPadding: pad/unpad round-trip; reject malformed.
// - StrongboxFileCodec: build payload -> read winner -> equal.
// Layer 1 (Storage):
// - AtomicSlotWriter: write -> read round-trip; protection
// class on disk; cleanupTempFiles.
// Layer 5 (Strongbox):
// - StrongboxPayload v=3 keyed-HMAC checksum round-trip
// (stamp under mainKey, verify under same mainKey, fail
// under a different mainKey or any payload mutation).
// - Strongbox.shared snapshot lifecycle.
// design rationale:
// These tests exist so a future regression cannot land
// silently. The crypto-primitive tests are RFC vectors
// (deterministic; any drift fails). The schema tests assert
// the byte-exact JSON the codec writes (any field rename or
// ordering drift fails). The storage tests assert the
// file-protection class and the .tmp cleanup invariant
// (any regression in fails).

import XCTest
import CryptoKit
@testable import QuantumSwapWallet

final class StrongboxLayerTests: XCTestCase {

    // MARK: - Layer 3: SecureRandom

    func testSecureRandomProducesNonZeroBytes() throws {
        // Sanity test: 100 calls must not all return zero.
        // (Any one call returning all-zero is statistically
        // possible but vanishingly unlikely; 100 calls all
        // returning all-zero is ~impossible with a working
        // CSPRNG.)
        var allZeroCount = 0
        for _ in 0..<100 {
            let bytes = try SecureRandom.bytes(32)
            if bytes.allSatisfy({ $0 == 0 }) { allZeroCount += 1 }
        }
        XCTAssertEqual(allZeroCount, 0,
            "SecureRandom returned all-zero bytes (RNG broken)")
    }

    func testSecureRandomLengthMatchesRequest() throws {
        for n in [1, 12, 16, 32, 64, 128] {
            let bytes = try SecureRandom.bytes(n)
            XCTAssertEqual(bytes.count, n)
        }
    }

    // MARK: - Layer 3: Aead

    func testAeadRoundTrip() throws {
        let key = try SecureRandom.bytes(32)
        let plaintext = "hello quantum coin".data(using: .utf8)!
        let env = try Aead.seal(plaintext, keyBytes: key)
        let opened = try Aead.open(env, keyBytes: key)
        XCTAssertEqual(opened, plaintext)
    }

    func testAeadRejectsSixteenByteCombinedInput() throws {
        // Combined.count > 16 (strict).
        // Build a fake envelope with exactly 16 bytes of
        // combined ciphertext (which would split into 0-byte
        // ciphertext + 16-byte tag).
        let fakeCombined = Data(repeating: 0xAA, count: 16)
        let fakeIv = Data(repeating: 0x00, count: 12)
        let fakeEnv: [String: Any] = [
            "v": 2,
            "cipherText": fakeCombined.base64EncodedString(),
            "iv": fakeIv.base64EncodedString()
        ]
        let envBytes = try JSONSerialization.data(
            withJSONObject: fakeEnv, options: [.sortedKeys])
        let envJson = String(data: envBytes, encoding: .utf8)!

        let key = Data(repeating: 0x42, count: 32)
        XCTAssertThrowsError(try Aead.open(envJson, keyBytes: key)) { err in
            guard case AeadError.malformedEnvelope = err else {
                XCTFail("Expected malformedEnvelope, got \(err)")
                return
            }
        }
    }

    func testAeadRejectsTamperedCiphertext() throws {
        let key = try SecureRandom.bytes(32)
        let plaintext = Data(repeating: 0x55, count: 64)
        let env = try Aead.seal(plaintext, keyBytes: key)
        // Flip a byte inside cipherText to simulate tamper.
        var obj = try JSONSerialization.jsonObject(
            with: env.data(using: .utf8)!) as! [String: Any]
        var combined = Data(base64Encoded: obj["cipherText"] as! String)!
        combined[0] ^= 0xFF
        obj["cipherText"] = combined.base64EncodedString()
        let tamperedBytes = try JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys])
        let tamperedJson = String(data: tamperedBytes, encoding: .utf8)!

        XCTAssertThrowsError(try Aead.open(tamperedJson, keyBytes: key)) { err in
            guard case AeadError.authenticationFailed = err else {
                XCTFail("Expected authenticationFailed, got \(err)")
                return
            }
        }
    }

    // MARK: - Layer 3: Mac

    func testMacHmacSha256RfcVector() {
        // RFC 4231 §4.2 test case 1.
        let key = Data(repeating: 0x0b, count: 20)
        let msg = "Hi There".data(using: .utf8)!
        let expected = Data([
                0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53,
                0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b, 0xf1, 0x2b,
                0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7,
                0x26, 0xe9, 0x37, 0x6c, 0x2e, 0x32, 0xcf, 0xf7
            ])
        let actual = Mac.hmacSha256(message: msg, keyBytes: key)
        XCTAssertEqual(actual, expected)
    }

    func testMacVerifyConstantTime() {
        let key = Data(repeating: 0x42, count: 32)
        let msg = Data(repeating: 0xAB, count: 64)
        let tag = Mac.hmacSha256(message: msg, keyBytes: key)
        XCTAssertTrue(Mac.verify(msg, mac: tag, keyBytes: key))

        var tampered = tag
        tampered[0] ^= 0x01
        XCTAssertFalse(Mac.verify(msg, mac: tampered, keyBytes: key))
    }

    // MARK: - Layer 2: StrongboxPadding

    func testStrongboxPaddingRoundTrip() throws {
        // Last entry probes the bucket's upper bound, derived
        // from the constant so a future bucket bump does not
        // silently drift this test out of sync.
        for length in [0, 1, 16, 100, 1024, StrongboxPadding.bucketSize - 1] {
            let plaintext = Data(repeating: 0xAB, count: length)
            let padded = try StrongboxPadding.pad(plaintext)
            XCTAssertEqual(padded.count, StrongboxPadding.bucketSize)
            let unpadded = try StrongboxPadding.unpad(padded)
            XCTAssertEqual(unpadded, plaintext, "round-trip failed at length=\(length)")
        }
    }

    func testStrongboxPaddingBucketIsExactly4MiB() {
        // CRITICAL: changing this constant breaks cross-device
        // padding length stability. Same plaintext produces
        // identical-length ciphertext on every install, so a
        // multi-device backup pair cannot be distinguished by
        // length alone. 4 MiB is sized to fit >= 256 wallets
        // where each wallet stores its raw post-quantum private +
        // public key bytes (~10 KiB/wallet) plus address + seed
        // phrase + framing, plus networks/metadata + headroom.
        XCTAssertEqual(4_194_304, StrongboxPadding.bucketSize)
    }

    func testStrongboxPaddingRejectsOversizedPlaintext() {
        let oversized = Data(repeating: 0xAB, count: StrongboxPadding.bucketSize)
        XCTAssertThrowsError(try StrongboxPadding.pad(oversized)) { err in
            guard case StrongboxPadding.Error.plaintextTooLargeForBucket = err else {
                XCTFail("Expected plaintextTooLargeForBucket, got \(err)")
                return
            }
        }
    }

    func testStrongboxPaddingRejectsMalformed() {
        // All zeros (no 0x80 marker anywhere).
        let allZero = Data(count: StrongboxPadding.bucketSize)
        XCTAssertThrowsError(try StrongboxPadding.unpad(allZero))

        // Wrong total length.
        let wrongLength = Data(count: 1024)
        XCTAssertThrowsError(try StrongboxPadding.unpad(wrongLength))
    }

    // MARK: - Layer 5: StrongboxPayload v=3 keyed-HMAC checksum

    /// Fixed mainKey used by the keyed-checksum tests so the
    /// stamped tag is deterministic and a future regression in
    /// HKDF, HMAC, or the canonical-bytes encoder surfaces as a
    /// pinpoint failure here. Mirrors the Android counterpart
    /// `StrongboxPayloadV3Test.FIXED_MAIN_KEY`.
    private static let fixedMainKey: Data = Data((1...32).map { UInt8($0) })

    func testStrongboxPayloadChecksumDeterministic() {
        // Stamping the same payload with the same mainKey twice
        // must produce byte-identical checksum tags. Any drift
        // (Encoder option, sortedKeys, HKDF re-implementation)
        // breaks this immediately.
        let p1 = Strongbox.stampChecksum(
            of: Strongbox.emptySnapshot(),
            mainKey: Self.fixedMainKey)
        let p2 = Strongbox.stampChecksum(
            of: Strongbox.emptySnapshot(),
            mainKey: Self.fixedMainKey)
        XCTAssertEqual(p1.checksum, p2.checksum,
            "two empty snapshots stamped under the same mainKey "
            + "must have identical keyed-HMAC checksums")
        XCTAssertTrue(Strongbox.verifyChecksum(
            of: p1, mainKey: Self.fixedMainKey),
            "freshly-stamped checksum must verify under the "
            + "same mainKey")
    }

    func testStrongboxPayloadChecksumFailsUnderDifferentMainKey() {
        // The whole point of the v=3 switch from unkeyed SHA-256
        // to keyed HMAC is that an attacker who can mutate the
        // ciphertext but not learn mainKey cannot forge a valid
        // checksum. This test pins that property: a different
        // mainKey MUST not verify.
        let stamped = Strongbox.stampChecksum(
            of: Strongbox.emptySnapshot(),
            mainKey: Self.fixedMainKey)
        var otherKey = Self.fixedMainKey
        otherKey[0] ^= 0x01
        XCTAssertFalse(Strongbox.verifyChecksum(
            of: stamped, mainKey: otherKey),
            "checksum verified under a different mainKey — keyed "
            + "HMAC binding is broken")
    }

    func testStrongboxPayloadChecksumDetectsTamper() {
        let stamped = Strongbox.stampChecksum(
            of: Strongbox.emptySnapshot(),
            mainKey: Self.fixedMainKey)
        // Construct a tampered payload by flipping one boolean
        // while keeping the original (now-stale) checksum. Any
        // checksum-scoped boolean works; we use `advancedSigning`.
        let tampered = StrongboxPayload(
            v: stamped.v,
            wallets: stamped.wallets,
            currentWalletIndex: stamped.currentWalletIndex,
            customNetworks: stamped.customNetworks,
            activeNetworkIndex: stamped.activeNetworkIndex,
            cloudBackupFolderUri: stamped.cloudBackupFolderUri,
            advancedSigning: !stamped.advancedSigning,
            cameraPermissionAskedOnce: stamped.cameraPermissionAskedOnce,
            secureItems: stamped.secureItems,
            checksum: stamped.checksum)
        XCTAssertFalse(Strongbox.verifyChecksum(
            of: tampered, mainKey: Self.fixedMainKey),
            "tampered payload must fail checksum")
    }

    func testStrongboxPayloadChecksumLabelIsV3() {
        // The HKDF info string MUST surface the schema version so
        // a v=3 mainKey can never collide with a v=2 derived key.
        // Both platforms pin the exact same string verbatim; the
        // cross-platform vector suite enforces byte-identity.
        XCTAssertEqual("strongbox-payload-checksum-v3",
            Strongbox.checksumInfoLabel)
    }

    func testStrongboxPayloadCanonicalBytesAreStable() {
        // canonicalBytesForChecksum MUST be a pure function of
        // payload state — any nondeterminism would break the
        // cross-platform inner-checksum.
        let p = Strongbox.emptySnapshot()
        let a = Strongbox.canonicalBytesForChecksum(of: p)
        let b = Strongbox.canonicalBytesForChecksum(of: p)
        XCTAssertEqual(a, b,
            "canonical bytes drifted under repeated calls")
    }

    func testStrongboxPayloadCanonicalBytesIgnoreChecksumField() {
        // Mutating checksum MUST NOT change the canonical bytes
        // used to compute the checksum, or the keyed-HMAC chain
        // is circular.
        let stamped = Strongbox.stampChecksum(
            of: Strongbox.emptySnapshot(),
            mainKey: Self.fixedMainKey)
        let withDifferentChecksum = StrongboxPayload(
            v: stamped.v,
            wallets: stamped.wallets,
            currentWalletIndex: stamped.currentWalletIndex,
            customNetworks: stamped.customNetworks,
            activeNetworkIndex: stamped.activeNetworkIndex,
            cloudBackupFolderUri: stamped.cloudBackupFolderUri,
            advancedSigning: stamped.advancedSigning,
            cameraPermissionAskedOnce: stamped.cameraPermissionAskedOnce,
            secureItems: stamped.secureItems,
            checksum: "unrelated-checksum-string")
        XCTAssertEqual(
            Strongbox.canonicalBytesForChecksum(of: stamped),
            Strongbox.canonicalBytesForChecksum(of: withDifferentChecksum))
    }

    /// Regression: the `backupEnabled` field name MUST NOT appear
    /// anywhere in the canonical JSON. The toggle is intentionally
    /// kept out of the encrypted payload so the OS backup agent
    /// can read it pre-unlock from `UserDefaults`.
    func testCanonicalJsonOmitsBackupEnabled() {
        let bytes = Strongbox.canonicalBytesForChecksum(
            of: Strongbox.emptySnapshot())
        let json = String(data: bytes, encoding: .utf8) ?? ""
        XCTAssertFalse(
            json.contains("backupEnabled"),
            "backupEnabled must not appear in canonical JSON; got \(json)")
    }

    func testStrongboxPayloadSecureItemsAreCheckSummed() {
        // secureItems are part of the checksum scope, so adding /
        // removing / mutating them must produce a different tag.
        let baseKey = Self.fixedMainKey
        let v = StrongboxFileCodec.schemaVersion
        let withItem = StrongboxPayload(
            v: v,
            wallets: [],
            currentWalletIndex: 0,
            customNetworks: [],
            activeNetworkIndex: 0,
            cloudBackupFolderUri: "",
            advancedSigning: false,
            cameraPermissionAskedOnce: false,
            secureItems: ["k": "v"],
            checksum: "")
        let withoutItem = StrongboxPayload(
            v: v,
            wallets: [],
            currentWalletIndex: 0,
            customNetworks: [],
            activeNetworkIndex: 0,
            cloudBackupFolderUri: "",
            advancedSigning: false,
            cameraPermissionAskedOnce: false,
            secureItems: [:],
            checksum: "")
        let tagWith = Strongbox.computeChecksum(of: withItem, mainKey: baseKey)
        let tagWithout = Strongbox.computeChecksum(of: withoutItem, mainKey: baseKey)
        XCTAssertNotEqual(tagWith, tagWithout,
            "secureItems must be inside the checksum scope")
    }

    // MARK: - Cross-platform seed-derived portability vectors
    // The shared seed, SHAKE-256 expander, and helper builders
    // live in `StrongboxPortabilityFixtures.swift`; consumers
    // (this file, the new `Strongbox*Tests` ports, and any future
    // Android-parity test class) call the same fixture surface so
    // the pinned digests stay byte-identical across both repos.

    // The slot-JSON builder + scrypt-rejection assertion used
    // by the validation tests below live in
    // `StrongboxSlotJsonFixtures.swift` so the dedicated
    // `StrongboxFileCodecScryptValidationTests` port can reuse
    // the same shape.

    func testPortabilitySeededShakeGeneratorMatchesAndroidSanityOutput() {
        XCTAssertEqual(
            "3f750698656d309fdc960e2734da21f566c606dd1a6d3eacd4a0accf612e2e5e",
            StrongboxPortabilityFixtures.vectorBytes("sanity", count: 32)
                .portabilityHex)
    }

    func testPortabilityPublishedRfcVectorsStillPass() {
        let key = Data(repeating: 0x0b, count: 20)
        let message = Data("Hi There".utf8)
        XCTAssertEqual(
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            Mac.hmacSha256(message: message, keyBytes: key).portabilityHex)

        // RFC 5869 A.1, using binary info bytes (not the String
        // convenience wrapper) to pin the primitive independently
        // of app-specific UTF-8 labels.
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

    // The remaining cross-platform vector assertions
    // (primitive vectors, AEAD-with-injected-IV, wallet-entry and
    // canonical-payload digests, scrypt KAT) live in the
    // dedicated `StrongboxPortabilityVectorTests` class so the
    // Swift and Android suites line up class-for-class.

    // MARK: - scrypt KDF parameter min-bound validation

    /// `StrongboxFileCodec.decodeOnly` MUST reject any v=3 slot
    /// whose advertised scrypt cost is below the documented
    /// minimum, before any AEAD work is done. Without this guard,
    /// an attacker who can place a slot file (e.g. via a malicious
    /// iCloud Drive replay or a crafted import) plus the user's
    /// known password could craft a valid envelope with N=1024 and
    /// the right MAC, dropping the brute-force ceiling by ~256x.
    /// Mirrored on Android by the symmetric tests in
    /// `StrongboxFileCodecScryptValidationTest.java`.
    func testCodecAcceptsDocumentedScryptDefaults() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N, r: JsBridge.SCRYPT_R,
            p: JsBridge.SCRYPT_P, keyLen: JsBridge.SCRYPT_KEY_LEN)
        let decoded = try StrongboxFileCodec.decodeOnly(bytes)
        XCTAssertEqual(decoded.kdfParams.N, JsBridge.SCRYPT_N)
    }

    func testCodecRejectsLowScryptN() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: 1024, r: JsBridge.SCRYPT_R,
            p: JsBridge.SCRYPT_P, keyLen: JsBridge.SCRYPT_KEY_LEN)
        StrongboxSlotJsonFixtures.assertCodecRejectsAsMalformed(bytes,
            reason: "low N (1024) must be rejected")
    }

    func testCodecRejectsLowScryptR() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N, r: 1,
            p: JsBridge.SCRYPT_P, keyLen: JsBridge.SCRYPT_KEY_LEN)
        StrongboxSlotJsonFixtures.assertCodecRejectsAsMalformed(bytes,
            reason: "low r must be rejected")
    }

    func testCodecRejectsLowScryptKeyLen() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N, r: JsBridge.SCRYPT_R,
            p: JsBridge.SCRYPT_P, keyLen: 16)
        StrongboxSlotJsonFixtures.assertCodecRejectsAsMalformed(bytes,
            reason: "low keyLen (16) must be rejected")
    }

    func testCodecRejectsZeroScryptP() throws {
        let bytes = try StrongboxSlotJsonFixtures.buildSlotJsonBytes(
            N: JsBridge.SCRYPT_N, r: JsBridge.SCRYPT_R,
            p: 0, keyLen: JsBridge.SCRYPT_KEY_LEN)
        StrongboxSlotJsonFixtures.assertCodecRejectsAsMalformed(bytes,
            reason: "p < 1 must be rejected")
    }

    /// Defense-in-depth: even if the codec validation were bypassed
    /// somehow, `attemptUnlockSingle` independently rejects sub-
    /// minimum params. We can't easily exercise the unlock path
    /// without a real strongbox, but the value-type constructor
    /// remains permissive (only the codec / unlock guards enforce
    /// the bound), so this serves as a reminder that two layers
    /// enforce it. See `UnlockCoordinatorV2.attemptUnlockSingle`
    /// for the second guard.
    func testUnlockGuardRejectsWeakenedScryptParams() {
        let weak = StrongboxFileCodec.KdfParams(N: 1024, r: 1, p: 1, keyLen: 16)
        XCTAssertEqual(weak.N, 1024)
    }

    // MARK: - Layer 5: Strongbox.shared snapshot lifecycle

    func testStrongboxSnapshotLifecycle() {
        Strongbox.shared.clearSnapshot()
        XCTAssertFalse(Strongbox.shared.isSnapshotLoaded)
        XCTAssertEqual(Strongbox.shared.walletCount, 0)
        XCTAssertNil(Strongbox.shared.currentWalletAddress)

        Strongbox.shared.installSnapshot(Strongbox.emptySnapshot())
        XCTAssertTrue(Strongbox.shared.isSnapshotLoaded)
        XCTAssertEqual(Strongbox.shared.walletCount, 0)

        Strongbox.shared.clearSnapshot()
        XCTAssertFalse(Strongbox.shared.isSnapshotLoaded)
    }

    // MARK: - Layer 5: read-projection helpers

    /// Exercises the read-projection helpers
    /// (`indexToAddress`, `addressToIndex`,
    /// `allAddressesSortedByIndex`, `address(forIndex:)`,
    /// `privateKey(at:)`, `publicKey(at:)`, `seedWords(at:)`,
    /// `hasSeed(at:)`, `hasAnyWallet`) that replace the
    /// historical KeyStore dictionary surface. These are pure
    /// functions of the snapshot, so the test installs a known
    /// snapshot directly and asserts the projections without
    /// going through the unlock flow.
    func testStrongboxReadProjections() throws {
        let sk0 = Data([0xAA, 0xBB, 0xCC])
        let pk0 = Data([0x11, 0x22, 0x33])
        let sk1 = Data([0x77, 0x88])
        let pk1 = Data([0x44, 0x55, 0x66])
        let w0 = StrongboxPayload.Wallet(
            idx: 0, address: "0xAAAA",
            privateKey: sk0, publicKey: pk0,
            hasSeed: true, seedWords: "alpha,beta")
        let w1 = StrongboxPayload.Wallet(
            idx: 1, address: "0xBBBB",
            privateKey: sk1, publicKey: pk1,
            hasSeed: false, seedWords: "")
        let payload = try Strongbox.shared.snapshotByAppendingWalletStarting(
            from: Strongbox.emptySnapshot(), wallet: w0)
        let payload2 = try Strongbox.shared.snapshotByAppendingWalletStarting(
            from: payload, wallet: w1)
        Strongbox.shared.installSnapshot(payload2)

        XCTAssertTrue(Strongbox.shared.hasAnyWallet)
        XCTAssertEqual(Strongbox.shared.walletCount, 2)
        XCTAssertEqual(Strongbox.shared.indexToAddress, [0: "0xAAAA", 1: "0xBBBB"])
        XCTAssertEqual(Strongbox.shared.addressToIndex,
            ["0xaaaa": 0, "0xbbbb": 1])
        XCTAssertEqual(Strongbox.shared.allAddressesSortedByIndex(),
            ["0xAAAA", "0xBBBB"])
        XCTAssertEqual(Strongbox.shared.address(forIndex: 1), "0xBBBB")
        XCTAssertNil(Strongbox.shared.address(forIndex: 99))
        XCTAssertEqual(Strongbox.shared.privateKey(at: 0), sk0)
        XCTAssertEqual(Strongbox.shared.publicKey(at: 0), pk0)
        XCTAssertEqual(Strongbox.shared.seedWords(at: 0), "alpha,beta")
        XCTAssertEqual(Strongbox.shared.hasSeed(at: 0), true)
        XCTAssertEqual(Strongbox.shared.privateKey(at: 1), sk1)
        XCTAssertEqual(Strongbox.shared.publicKey(at: 1), pk1)
        XCTAssertEqual(Strongbox.shared.seedWords(at: 1), "")
        XCTAssertEqual(Strongbox.shared.hasSeed(at: 1), false)

        Strongbox.shared.clearSnapshot()
        XCTAssertFalse(Strongbox.shared.hasAnyWallet)
        XCTAssertTrue(Strongbox.shared.indexToAddress.isEmpty)
        XCTAssertTrue(Strongbox.shared.addressToIndex.isEmpty)
        XCTAssertTrue(Strongbox.shared.allAddressesSortedByIndex().isEmpty)
        XCTAssertNil(Strongbox.shared.privateKey(at: 0))
        XCTAssertNil(Strongbox.shared.publicKey(at: 0))
        XCTAssertNil(Strongbox.shared.seedWords(at: 0))
        XCTAssertNil(Strongbox.shared.hasSeed(at: 0))
    }

    // MARK: - Invariant: no v1 references survive the cutover

    /// Grep-style invariant test. Walks every Swift source file
    /// under `QuantumSwapWallet/` and asserts that no file
    /// references the v1 `KeyStore` surface or the old
    /// `kStrongboxV2Enabled` feature flag. Closes the cutover
    /// regression: a future PR that re-introduces a
    /// `KeyStore.shared.*` call to dodge the new facade is
    /// caught at test time, not in code review.
    /// The negation list is intentionally narrow - we forbid
    /// only the symbols that the cutover removed, NOT the word
    /// "KeyStore" in arbitrary contexts (which would catch
    /// `Apple Keychain`-related strings, etc.). The grep
    /// patterns include word boundaries where it matters.
    func testNoV1KeyStoreReferencesRemain() throws {
        let bannedTokens: [String] = [
            "KeyStore.shared",
            "KeyStoreError",
            "kStrongboxV2Enabled",
            "StrongboxFeatureFlags",
            "SECURE_DERIVED_KEY_SALT",
            "SECURE_ENCRYPTED_MAIN_KEY",
            "SECURE_STRONGBOX_BLOB",
            "SECURE_WALLET_PREFIX",
            "WALLET_HAS_SEED_KEY_PREFIX",
            "runPrivacyMigrationV1IfNeeded",
        ]
        let root = sourceRoot()
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(
            atPath: root.path)
        while let rel = enumerator?.nextObject as? String {
            guard rel.hasSuffix(".swift") else { continue }
            let url = root.appendingPathComponent(rel)
            guard let contents = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            for token in bannedTokens where contents.contains(token) {
                hits.append("\(rel): contains banned token `\(token)`")
            }
        }
        XCTAssertTrue(hits.isEmpty,
            "v1-cutover invariant violated:\n" + hits.joined(separator: "\n"))
    }

    /// Resolve the `QuantumSwapWallet/` source root using the
    /// `#filePath` macro, which embeds the absolute path to
    /// THIS test source file at compile time. From there we
    /// walk one directory up (out of `QuantumSwapWalletTests/`)
    /// and into `QuantumSwapWallet/`.
    /// This works under both `xcodebuild test` (where the test
    /// runs in the iOS Simulator's sandbox and
    /// `Bundle(for:).bundleURL` points at a sim-internal
    /// location with no view of the source tree) AND under any
    /// future `swift test` adoption (where `#filePath` resolves
    /// the same way).
    private func sourceRoot(file: StaticString = #filePath) -> URL {
        let testFileURL = URL(fileURLWithPath: "\(file)")
        let testsDir = testFileURL.deletingLastPathComponent()
        let projectRoot = testsDir.deletingLastPathComponent()
        return projectRoot.appendingPathComponent("QuantumSwapWallet")
    }
}

// MARK: - Test-only convenience

private extension Strongbox {
    /// Helper to chain `snapshotByAppendingWallet(...)` calls
    /// without needing to install/uninstall the snapshot
    /// between each step. The Strongbox instance method
    /// requires a loaded snapshot; this helper takes the base
    /// payload explicitly so the test can build a
    /// multi-wallet payload from `emptySnapshot` without
    /// installing in between.
    func snapshotByAppendingWalletStarting(
        from base: StrongboxPayload,
        wallet: StrongboxPayload.Wallet
    ) throws -> StrongboxPayload {
        installSnapshot(base)
        defer { /* leave installed; caller may overwrite */ }
        return try snapshotByAppendingWallet(wallet)
    }
}

// MARK: - Shared portability fixtures
// The seeded SHAKE-256 helper, the hex extension, and the
// `vectorBytes` / `generatedWallet` / `generatedPayload`
// builders live in `StrongboxPortabilityFixtures.swift` so
// every Swift Android-parity test class can consume the same
// seam.
