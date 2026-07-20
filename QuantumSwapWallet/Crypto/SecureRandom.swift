// SecureRandom.swift (Crypto layer 3)
// (CRITICAL): single-source-of-truth wrapper for
// `SecRandomCopyBytes`. Direct calls to `SecRandomCopyBytes`
// anywhere else in the codebase are a build-blocking lint
// failure: every random byte the wallet ever consumes (envelope
// nonces, KDF salts, recipient addresses for sandbox-escape
// probes, file names) MUST be observed to throw on RNG failure
// rather than silently returning zero bytes.
// Why this exists:
// `SecRandomCopyBytes(_:_:_:)` returns an `OSStatus`. On
// failure the destination buffer is left untouched, which in
// our usage means it stays zero-initialized:
// var out = [UInt8](repeating: 0, count: count) // already zero
// _ = SecRandomCopyBytes(kSecRandomDefault, count, &out)
// return Data(out) // potentially still all zeros
// The previous `_ = SecRandomCopyBytes(...)` pattern at three
// storage-layer call sites (KDF salt generation, main-key
// generation, AES-GCM nonce generation) discarded the status
// completely. A failed RNG draw therefore produced:
// - An all-zero scrypt salt -> all wallets on the device
// collapse to the same KDF lattice; one cracked password
// cracks every install with the same failure mode.
// - An all-zero `mainKey` -> the AES-GCM key is a known
// constant; every encrypted blob can be decrypted offline.
// - An all-zero AES-GCM nonce reused across multiple
// encryptions of the same key -> CATASTROPHIC: GCM
// confidentiality and authenticity are both destroyed
// (nonce reuse leaks the authentication key, which lets
// an attacker forge arbitrary ciphertexts).
// This is the kind of failure that:
// * is undetectable by the user (ciphertext "looks random"),
// * is irreversible (already-leaked plaintext cannot be
// un-leaked),
// * is silent (no crash, no log line, no UI surface),
// * is permanent (the on-disk state is now permanently
// compromised).
// grok-4.20, gemini-3.1-pro) flagged this exact pattern. The
// CRITICAL severity is shared by all five.
// The remediation is mechanical: every call site must check the
// `OSStatus` and fail loud on `!= errSecSuccess`. Centralising
// the check in one wrapper is the only way to make this
// regression-proof: the lint rule "no direct call to
// `SecRandomCopyBytes` outside this file" is grep-checkable
// from CI and reviewable from a code review.
// Tradeoffs:
// - Throwing changes the function signature of the call sites.
// Some of those sites are in non-throwing helpers and have to
// be converted to `throws`. That's a tractable, mechanical
// refactor; the only friction is correctness of error mapping
// in callers.
// - Probe-style call sites (`TamperGate.probeSandboxEscape`,
// `CloudBackupManager.randomHexSuffix`) only use the bytes
// for non-secret uniqueness (a temp-file name, a probe file
// name). For those we accept a degraded fallback (pid /
// timestamp) on `try?` failure rather than aborting the whole
// call - documented inline at each call site. The wrapper
// itself ALWAYS throws on RNG failure; the choice to treat a
// throw as "degrade and continue" lives at the call site so
// a future reviewer can see the policy decision in context.
// Relationship to the 5/5 design finding :
// Prior reviews specifically called out three storage-layer
// sites in the original keystore implementation:
// - KDF salt generation -> migrated.
// - main-key generation -> migrated.
// - private `randomBytes` helper used for AES-GCM nonces ->
// migrated.
// plus the two probe-only sites added by Track B work items
// ``/`` (CloudBackupManager) and `` (TamperGate)
// which inherit the same wrapper. After migration, this file is
// the one and only `SecRandomCopyBytes` caller in the repo.

import Foundation
import Security

public enum SecureRandom {

    /// Thrown by `bytes(_:)` when the underlying `SecRandomCopyBytes`
    /// call returns a non-success `OSStatus`. The raw status code
    /// is preserved so a reviewer can map it back to the
    /// `<Security/SecBase.h>` constant that produced it.
    public enum Error: Swift.Error, CustomStringConvertible {
        case osStatus(OSStatus)

        public var description: String {
            switch self {
                case .osStatus(let s):
                return "SecureRandom.Error.osStatus(\(s))"
            }
        }
    }

    #if DEBUG
    // ------------------------------------------------------------------
    // Test-only deterministic-sequence seam.
    // Cross-platform vector tests (StrongboxPortabilityVectorTests on
    // iOS, StrongboxPortabilityVectorTest on Android) need to drive
    // the strongbox create + persist pipeline with PRE-CHOSEN bytes
    // for the scrypt salt, the random `mainKey`, and every AES-GCM
    // nonce, so the resulting slot file is byte-identical to the
    // golden fixture. The seam below is conditionally compiled into
    // DEBUG builds only; a release build cannot accidentally consume
    // a deterministic sequence (the `else` arm of the `#if` guard
    // does not exist).
    // Usage:
    //   SecureRandom.withDeterministicSequence(
    //       Data([0xAA, 0xBB, ...])) {
    //       try createNewStrongbox(password: "...")
    //   }
    // The closure runs with `bytes(_:)` returning slices of the
    // supplied byte sequence in call order. The seam is per-thread
    // (Thread.threadDictionary-backed) so concurrent test cases
    // do not interfere. A test that consumes more bytes than the
    // pre-loaded sequence holds gets a precondition failure (loud
    // signal that the fixture was authored with the wrong byte
    // budget).
    // ------------------------------------------------------------------

    private static let deterministicQueueKey = "org.quantumswap.SecureRandom.deterministic"

    private final class DeterministicState {
        var bytes: Data
        var cursor: Int = 0
        init(_ b: Data) { self.bytes = b }
    }

    /// Run `block` with `SecureRandom.bytes(_:)` returning slices
    /// of `sequence` in call order. Restores the prior random
    /// source on exit. DEBUG-only; never present in release
    /// binaries. Used exclusively by `StrongboxPortabilityVectorTests`
    /// to reproduce a golden slot file byte-for-byte from the
    /// shared `tests/fixtures/strongbox-v3-vectors/` inputs.
    public static func withDeterministicSequence<T>(
        _ sequence: Data,
        body: () throws -> T
    ) rethrows -> T {
        let dict = Thread.current.threadDictionary
        let prior = dict[deterministicQueueKey] as? DeterministicState
        dict[deterministicQueueKey] = DeterministicState(sequence)
        defer {
            if let prior = prior {
                dict[deterministicQueueKey] = prior
            } else {
                dict.removeObject(forKey: deterministicQueueKey)
            }
        }
        return try body()
    }

    private static func consumeDeterministic(_ count: Int) -> Data? {
        guard let state = Thread.current.threadDictionary[deterministicQueueKey]
            as? DeterministicState else { return nil }
        precondition(state.cursor + count <= state.bytes.count,
            "SecureRandom.deterministic sequence exhausted: "
            + "asked for \(count) bytes at cursor \(state.cursor), "
            + "have \(state.bytes.count) bytes total")
        let lo = state.bytes.startIndex + state.cursor
        let hi = lo + count
        let slice = state.bytes.subdata(in: lo..<hi)
        state.cursor += count
        return slice
    }
    #endif

    /// Draw `count` cryptographically-secure random bytes from
    /// `kSecRandomDefault`. Throws `Error.osStatus` on RNG
    /// failure; the destination buffer is NEVER returned in a
    /// partially-filled state (see header for why this matters).
    /// Threading: thread-safe (the underlying API is documented
    /// thread-safe by Apple).
    public static func bytes(_ count: Int) throws -> Data {
        precondition(count >= 0, "SecureRandom.bytes count must be non-negative")
        if count == 0 {
            // SecRandomCopyBytes accepts 0-length on iOS but the
            // `&out[0]` UnsafePointer below would crash on an
            // empty array. Short-circuit with an empty Data so a
            // caller asking for 0 bytes gets a deterministic,
            // safe value rather than a precondition failure.
            return Data()
        }
        #if DEBUG
        if let injected = consumeDeterministic(count) {
            return injected
        }
        #endif
        var out = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        guard status == errSecSuccess else {
            // Defense-in-depth: zero the buffer before throwing
            // so a future change that catches the throw and
            // accidentally returns `out` cannot leak whatever
            // partial state the syscall left behind.
            for i in 0..<out.count { out[i] = 0 }
            throw Error.osStatus(status)
        }
        return Data(out)
    }

    /// Convenience byte-array form. Same throwing contract as
    /// `bytes(_:)`. Provided so call sites that need a mutable
    /// `[UInt8]` (e.g. for in-place ASN.1 wrapping) do not have
    /// to round-trip through `Data`.
    public static func byteArray(_ count: Int) throws -> [UInt8] {
        let data = try bytes(count)
        return [UInt8](data)
    }
}
