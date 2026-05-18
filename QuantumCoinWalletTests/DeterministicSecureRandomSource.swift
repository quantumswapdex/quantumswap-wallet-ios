// DeterministicSecureRandomSource.swift
// Test-only deterministic random source. Wraps a fixed byte
// sequence and yields it in order across successive `nextBytes`
// calls. Used by the v=3 cross-platform vector test suite (see
// `tests/fixtures/strongbox-v3-vectors/`) to inject pinned scrypt
// salts, mainKey material, and AEAD nonces so a re-seal of a
// fixture envelope produces byte-identical output.
// Mirrors the Android-side
// `com.quantumcoin.app.strongbox.DeterministicSecureRandomSource`
// 1-to-1 in API surface. The production code path consumes the
// same byte sequence through `SecureRandom.withDeterministicSequence`
// (a per-thread seam in `Crypto/SecureRandom.swift`); this class is
// the explicit, standalone counterpart for tests that want to assert
// against the source primitive directly.
import Foundation

public final class DeterministicSecureRandomSource {

    /// Thrown when callers ask for more bytes than the wrapped
    /// sequence holds. Fixture authors must extend the
    /// sequence; falling back to randomness would break the
    /// "byte-identical to Android" contract this class enforces.
    public struct ExhaustedError: Error, CustomStringConvertible {
        public let requested: Int
        public let cursor: Int
        public let remaining: Int

        public var description: String {
            return "DeterministicSecureRandomSource exhausted: "
                + "requested \(requested) bytes at cursor=\(cursor) "
                + "but only \(remaining) bytes remain. Extend the "
                + "fixture sequence."
        }
    }

    private let sequence: Data
    private var cursorOffset: Int

    /// Wrap `sequence` (defensively copied so a later caller
    /// mutation cannot retroactively change the deterministic
    /// stream). The cursor starts at index 0.
    public init(sequence: Data) {
        self.sequence = Data(sequence)
        self.cursorOffset = 0
    }

    /// Copy the next `count` bytes from the sequence into the
    /// returned `Data`. Throws `ExhaustedError` when the
    /// sequence does not have enough bytes left.
    public func nextBytes(_ count: Int) throws -> Data {
        precondition(count >= 0,
            "DeterministicSecureRandomSource: negative count")
        if count == 0 { return Data() }
        guard cursorOffset + count <= sequence.count else {
            throw ExhaustedError(
                requested: count,
                cursor: cursorOffset,
                remaining: sequence.count - cursorOffset)
        }
        let base = sequence.startIndex + cursorOffset
        let slice = sequence.subdata(in: base..<(base + count))
        cursorOffset += count
        return slice
    }

    /// Bytes consumed so far.
    public var cursor: Int { return cursorOffset }

    /// Bytes remaining in the wrapped sequence.
    public var remaining: Int { return sequence.count - cursorOffset }

    /// Reset the cursor to zero so the same sequence can be
    /// replayed from the start.
    public func reset() { cursorOffset = 0 }
}
