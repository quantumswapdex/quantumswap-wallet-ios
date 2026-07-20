// StrongboxPayloadV3Tests.swift
// Pure-Foundation regression coverage of the v=3 unified-schema
// `StrongboxPayload`.
// Pins down the on-disk-shape and crypto-binding invariants that
// the cross-platform vector suite under
// `tests/fixtures/strongbox-v3-vectors/` also enforces, but at
// the per-method level so a regression surfaces as a targeted
// failure rather than a single opaque end-to-end mismatch. The
// expensive byte-for-byte vector comparisons live in
// `StrongboxPortabilityVectorTests`; this class is the everyday
// fast gate.
// Mirrors Android's `StrongboxPayloadV3Test.java` test-for-test.
import XCTest
import Foundation
@testable import QuantumSwapWallet

final class StrongboxPayloadV3Tests: XCTestCase {

    private static let fixedMainKey: Data = Data((1...32).map { UInt8($0) })

    func testSchemaVersionIsThree() {
        let p = Strongbox.emptySnapshot()
        XCTAssertEqual(p.v, 3,
            "v=3 is the cross-platform-portable schema; any "
            + "regression to v=2 will silently break Android "
            + "<-> iOS slot-file portability")
        XCTAssertEqual(StrongboxFileCodec.schemaVersion, 3)
    }

    func testChecksumInfoLabelIsV3Specific() {
        // The HKDF info string MUST surface the schema version so
        // a v=3 mainKey can never collide with a v=2 derived key.
        // Both platforms pin the exact same string verbatim.
        XCTAssertEqual("strongbox-payload-checksum-v3",
            Strongbox.checksumInfoLabel)
    }

    func testNewPayloadHasV3FieldDefaults() {
        let p = Strongbox.emptySnapshot()
        XCTAssertEqual(p.currentWalletIndex, 0)
        XCTAssertEqual(p.activeNetworkIndex, 0)
        // backupEnabled is intentionally NOT a payload field. The
        // OS-level backup-enabled toggle lives in UserDefaults
        // (PrefConnect.backupEnabledKey) so the backup agent can
        // read it pre-unlock.
        XCTAssertEqual(p.cloudBackupFolderUri, "")
        XCTAssertFalse(p.advancedSigning)
        XCTAssertFalse(p.cameraPermissionAskedOnce)
        XCTAssertTrue(p.wallets.isEmpty)
        XCTAssertTrue(p.customNetworks.isEmpty)
        XCTAssertTrue(p.secureItems.isEmpty)
        XCTAssertEqual(p.checksum, "",
            "checksum starts empty until the first stamp")
    }

    func testCanonicalBytesForChecksumIsStableUnderRepeatedCalls() {
        let p = Self.makeSamplePayload()
        let a = Strongbox.canonicalBytesForChecksum(of: p)
        let b = Strongbox.canonicalBytesForChecksum(of: p)
        XCTAssertEqual(a, b,
            "canonicalBytesForChecksum MUST be a pure function of "
            + "payload state — any nondeterminism would break "
            + "the cross-platform inner-checksum")
    }

    func testCanonicalBytesForChecksumOmitsChecksumField() {
        let p = Self.makeSamplePayload()
        let before = Strongbox.canonicalBytesForChecksum(of: p)
        let mutated = StrongboxPayload(
            v: p.v,
            wallets: p.wallets,
            currentWalletIndex: p.currentWalletIndex,
            customNetworks: p.customNetworks,
            activeNetworkIndex: p.activeNetworkIndex,
            cloudBackupFolderUri: p.cloudBackupFolderUri,
            advancedSigning: p.advancedSigning,
            cameraPermissionAskedOnce: p.cameraPermissionAskedOnce,
            secureItems: p.secureItems,
            checksum: "totally-different-checksum-value")
        let after = Strongbox.canonicalBytesForChecksum(of: mutated)
        XCTAssertEqual(before, after,
            "Mutating checksum MUST NOT change the canonical bytes "
            + "used to compute the checksum, or the keyed-HMAC "
            + "chain is circular")
    }

    func testStampChecksumThenVerifyChecksumSucceeds() {
        let p = Self.makeSamplePayload()
        let stamped = Strongbox.stampChecksum(of: p, mainKey: Self.fixedMainKey)
        XCTAssertTrue(Strongbox.verifyChecksum(
            of: stamped, mainKey: Self.fixedMainKey),
            "Freshly-stamped payload must verify under the same mainKey")
    }

    func testVerifyChecksumFailsUnderDifferentMainKey() {
        let p = Self.makeSamplePayload()
        let stamped = Strongbox.stampChecksum(of: p, mainKey: Self.fixedMainKey)
        var other = Self.fixedMainKey
        other[0] ^= 0x01
        XCTAssertFalse(Strongbox.verifyChecksum(
            of: stamped, mainKey: other),
            "A different mainKey MUST NOT verify — that is the "
            + "whole point of switching from unkeyed SHA-256 to a "
            + "keyed HMAC under v=3")
    }

    func testVerifyChecksumFailsAfterAnyMutation() {
        let p = Self.makeSamplePayload()
        let stamped = Strongbox.stampChecksum(of: p, mainKey: Self.fixedMainKey)
        // Flip a tracked field to invalidate the canonical bytes.
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
            of: tampered, mainKey: Self.fixedMainKey),
            "Any mutation to a checksummed field must fail "
            + "verifyChecksum on next read")
    }

    func testCanonicalBytesOmitBackupEnabled() {
        // The `backupEnabled` field is intentionally absent from
        // the v=3 schema. A regression that re-adds it would
        // silently re-introduce a parity gap with Android.
        let p = Self.makeSamplePayload()
        let canonical = String(
            data: Strongbox.canonicalBytesForChecksum(of: p),
            encoding: .utf8) ?? ""
        XCTAssertFalse(canonical.contains("backupEnabled"),
            "backupEnabled MUST NOT appear in canonical JSON: \(canonical)")
    }

    func testStampedMainKeyArrayIsNotMutated() {
        // Defensive: stampChecksum / verifyChecksum must not
        // mutate the caller-provided mainKey buffer. Mirror the
        // Android assertion that the buffer survives across both
        // calls.
        let keyCopy = Self.fixedMainKey
        let p = Self.makeSamplePayload()
        _ = Strongbox.stampChecksum(of: p, mainKey: keyCopy)
        XCTAssertEqual(keyCopy, Self.fixedMainKey,
            "stampChecksum must not mutate the caller's mainKey buffer")
        let stamped = Strongbox.stampChecksum(of: p, mainKey: keyCopy)
        _ = Strongbox.verifyChecksum(of: stamped, mainKey: keyCopy)
        XCTAssertEqual(keyCopy, Self.fixedMainKey,
            "verifyChecksum must not mutate the caller's mainKey buffer")
    }

    /// Build a deterministic sample payload that exercises
    /// the wallets map, an active custom network, secure items,
    /// and the cloud-backup folder URI. Byte-equivalent (modulo
    /// Wallet binary representation) to Android's
    /// `StrongboxPayloadV3Test.makeSamplePayload()`.
    private static func makeSamplePayload() -> StrongboxPayload {
        let wallet0 = StrongboxPayload.Wallet(
            idx: 0,
            address: "0x0000000000000000000000000000000000000000",
            privateKey: Data([0xAA, 0xBB]),
            publicKey: Data([0xCC, 0xDD]),
            hasSeed: false,
            seedWords: "")
        let wallet1 = StrongboxPayload.Wallet(
            idx: 1,
            address: "0x1111111111111111111111111111111111111111",
            privateKey: Data([0x11, 0x22]),
            publicKey: Data([0x33, 0x44]),
            hasSeed: true,
            seedWords: "alpha,beta,gamma")
        let net = BlockchainNetwork(
            name: "test-net",
            chainId: "424242",
            scanApiDomain: "scan.example",
            rpcEndpoint: "https://rpc.example",
            blockExplorerUrl: "https://explorer.example")
        return StrongboxPayload(
            v: StrongboxFileCodec.schemaVersion,
            wallets: [wallet0, wallet1],
            currentWalletIndex: 1,
            customNetworks: [net],
            activeNetworkIndex: 1,
            cloudBackupFolderUri: "file:///example/folder",
            advancedSigning: false,
            cameraPermissionAskedOnce: true,
            secureItems: ["k1": "opaque-value-1"],
            checksum: "")
    }
}
