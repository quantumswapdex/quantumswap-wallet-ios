// StrongboxPaddingTests.swift
// Pure-Foundation tests for `StrongboxPadding`. The 0x80 marker
// plus zero-pad scheme is ISO/IEC 7816-4 and is unambiguously
// reversible. The bucket size is 4 MiB on both Android and iOS
// under v=3, so the same plaintext produces identical-length
// ciphertext on every install of either platform — a
// cross-platform backup pair cannot be distinguished by length
// alone.
// Mirrors Android's `StrongboxPaddingTest.java` test-for-test.
import XCTest
@testable import QuantumCoinWallet

final class StrongboxPaddingTests: XCTestCase {

    func testPadThenUnpadRoundTripsEmptyInput() throws {
        let padded = try StrongboxPadding.pad(Data())
        XCTAssertEqual(padded.count, StrongboxPadding.bucketSize)
        XCTAssertEqual(padded[padded.startIndex], 0x80)
        for i in 1..<padded.count {
            XCTAssertEqual(padded[padded.startIndex + i], 0,
                "byte \(i) not zero")
        }
        let unpadded = try StrongboxPadding.unpad(padded)
        XCTAssertEqual(unpadded, Data())
    }

    func testPadThenUnpadRoundTripsTypicalPayload() throws {
        let plain = Data("{\"hello\":\"world\"}".utf8)
        let padded = try StrongboxPadding.pad(plain)
        XCTAssertEqual(padded.count, StrongboxPadding.bucketSize)
        XCTAssertEqual(padded[padded.startIndex + plain.count], 0x80)
        let unpadded = try StrongboxPadding.unpad(padded)
        XCTAssertEqual(unpadded, plain)
    }

    func testPadThenUnpadRoundTripsLargePayload() throws {
        var plain = Data(count: StrongboxPadding.bucketSize - 1)
        for i in 0..<plain.count {
            plain[plain.startIndex + i] = UInt8(i & 0xff)
        }
        let padded = try StrongboxPadding.pad(plain)
        XCTAssertEqual(padded.count, StrongboxPadding.bucketSize)
        XCTAssertEqual(padded[padded.endIndex - 1], 0x80)
        let unpadded = try StrongboxPadding.unpad(padded)
        XCTAssertEqual(unpadded, plain)
    }

    func testPadThrowsWhenPlaintextTooLarge() {
        let oversized = Data(count: StrongboxPadding.bucketSize)
        XCTAssertThrowsError(try StrongboxPadding.pad(oversized)) { err in
            guard case StrongboxPadding.Error.plaintextTooLargeForBucket(
                let actual, let bucket) = err else {
                XCTFail("expected plaintextTooLargeForBucket, got \(err)")
                return
            }
            XCTAssertEqual(actual, StrongboxPadding.bucketSize)
            XCTAssertEqual(bucket, StrongboxPadding.bucketSize)
        }
    }

    func testUnpadThrowsOnWrongLength() {
        let short = Data(count: StrongboxPadding.bucketSize - 1)
        XCTAssertThrowsError(try StrongboxPadding.unpad(short)) { err in
            guard case StrongboxPadding.Error.malformedPadding = err else {
                XCTFail("expected malformedPadding, got \(err)")
                return
            }
        }
    }

    func testUnpadThrowsWhenAllZeros() {
        let padded = Data(count: StrongboxPadding.bucketSize)
        XCTAssertThrowsError(try StrongboxPadding.unpad(padded)) { err in
            guard case StrongboxPadding.Error.malformedPadding = err else {
                XCTFail("expected malformedPadding, got \(err)")
                return
            }
        }
    }

    func testUnpadThrowsWhenWrongMarker() {
        var padded = Data(count: StrongboxPadding.bucketSize)
        padded[padded.startIndex] = 0x42
        XCTAssertThrowsError(try StrongboxPadding.unpad(padded)) { err in
            guard case StrongboxPadding.Error.malformedPadding = err else {
                XCTFail("expected malformedPadding, got \(err)")
                return
            }
        }
    }

    func testBucketSizeIsExactlyFourMiBAndMatchesAndroid() {
        // CRITICAL: changing this constant breaks cross-device AND
        // cross-platform padding length stability. Same plaintext
        // produces identical-length ciphertext on every install of
        // either platform (iOS v=3 + Android v=3), so a backup pair
        // cannot be distinguished by length alone. 4 MiB is sized
        // to fit >= 256 wallets with raw post-quantum key bytes
        // (~10 KiB/wallet after base64-wrapping at the JSON
        // boundary) plus networks/metadata + headroom. The Android
        // counterpart pins the same constant.
        XCTAssertEqual(StrongboxPadding.bucketSize, 4_194_304)
    }
}
