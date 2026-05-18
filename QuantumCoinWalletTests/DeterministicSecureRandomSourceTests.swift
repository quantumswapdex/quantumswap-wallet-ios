// DeterministicSecureRandomSourceTests.swift
// Sanity coverage of the test-only deterministic RNG used by
// the v=3 cross-platform vector suite. If this seam is broken,
// the vector tests will fail with confusing IV-mismatch errors;
// this file makes the seam itself fail loudly first.
// Mirrors the Android-side
// `DeterministicSecureRandomSourceTest.java` test-for-test.
import XCTest
@testable import QuantumCoinWallet

final class DeterministicSecureRandomSourceTests: XCTestCase {

    func testNextBytesReturnsConsecutiveSlicesOfTheSequence() throws {
        let seq = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let src = DeterministicSecureRandomSource(sequence: seq)
        XCTAssertEqual(try src.nextBytes(3), Data([1, 2, 3]))
        XCTAssertEqual(try src.nextBytes(5), Data([4, 5, 6, 7, 8]))
        XCTAssertEqual(src.cursor, 8)
        XCTAssertEqual(src.remaining, 0)
    }

    func testNextBytesThrowsOnExhaustion() {
        let seq = Data([1, 2, 3])
        let src = DeterministicSecureRandomSource(sequence: seq)
        XCTAssertThrowsError(try src.nextBytes(4)) { err in
            guard err is DeterministicSecureRandomSource.ExhaustedError else {
                XCTFail("expected ExhaustedError, got \(err)")
                return
            }
        }
    }

    func testResetReplaysSequenceFromZero() throws {
        let seq = Data([9, 8, 7, 6])
        let src = DeterministicSecureRandomSource(sequence: seq)
        let first = try src.nextBytes(4)
        src.reset()
        let second = try src.nextBytes(4)
        XCTAssertEqual(first, second)
    }

    func testConstructorClonesSequenceSoCallerMutationsAreIgnored() throws {
        var seq = Data([1, 2, 3])
        let src = DeterministicSecureRandomSource(sequence: seq)
        seq[seq.startIndex] = 0xff
        let out = try src.nextBytes(3)
        XCTAssertEqual(out, Data([1, 2, 3]),
            "constructor must defensively copy so a later caller "
            + "mutation cannot retroactively change the deterministic stream")
    }
}
