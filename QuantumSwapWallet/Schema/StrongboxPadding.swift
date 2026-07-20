// StrongboxPadding.swift (Schema layer 2)
// Fixed-size 4 MiB bucket padding for the encrypted `strongbox`
// payload. Closes the size-leak half of the on-disk threat profile.
// Why this exists:
// Without padding, the on-disk ciphertext length is
// approximately the plaintext length. An attacker who can
// read (but not decrypt) the slot file (the storage-medium
// exfiltration threat profile) can therefore distinguish:
// * 0 wallets (~ 200 bytes)
// * 1 wallet (~ 8 KiB)
// * N wallets (linear in N)
// The wallet count is itself sensitive (it tells the
// attacker how high-value the target is, lets them know
// when to invest in a brute-force attempt, and reveals
// "this user has just added their first wallet" timing
// information from a backup diff).
// Padding to a fixed bucket means every slot file's
// `strongbox.ct` is exactly the same length regardless of how
// many wallets the user owns, up to bucketSize - 1 bytes of
// cleartext. A user who legitimately exceeds the bucket will
// hit a clear "strongbox full" error rather than silently
// leak their wallet count by tripping into a larger bucket;
// that is the right failure mode for an asset-storage product.
// Why 4 MiB:
// QuantumCoin uses post-quantum signatures whose raw key bytes
// dominate the per-wallet payload (Dilithium-class private +
// public key together ~10 KiB raw, plus ~200 bytes of address
// + seed-phrase + framing per wallet). The product target is
// >= 256 wallets per install, which yields a worst-case
// payload of ~2.5 MiB before networks/metadata overhead.
// 4 MiB (4 * 1024 * 1024 = 4_194_304 bytes) gives ~1.5x
// headroom over the 256-wallet worst case and rounds to a
// single power-of-two so the AtomicSlotWriter rotation is
// sector-friendly. iOS and Android use the same bucket size
// so the same install with the same wallet count produces the
// same on-disk shape on either platform.
// Format:
// padded = plaintext || 0x80 || 0x00 * (bucketSize - plaintext.count - 1)
// The 0x80 marker byte separates the plaintext from the
// zero pad. On unpad we walk backwards from the end:
// - skip trailing 0x00 bytes,
// - the next byte MUST be 0x80,
// - the bytes before it are the original plaintext.
// This is the ISO/IEC 7816-4 padding scheme (well-known,
// simple, and unambiguously reversible). It tolerates a
// plaintext length of 0..(bucketSize-1) inclusive.
// Tradeoffs:
// - Every write rewrites a full 4 MiB slot file even for a
// single-bool toggle. With AtomicSlotWriter's two-slot
// rotation that is two flash sectors per write; on a modern
// iPhone with sequential write throughput >= 200 MiB/s
// the physical-write latency is < ~50 ms. User-perceptible
// only if a user toggles a setting at >20 Hz, which never
// happens.
// - The bucket size is deliberately not parameterised:
// EVERY install must produce identical `strongbox.ct`
// lengths so a multi-device backup pair (the same user with
// two iPhones) cannot be distinguished by length alone. A
// device-specific bucket size would defeat that property.

import Foundation

public enum StrongboxPadding {

    /// Fixed plaintext bucket size in bytes. The matching
    /// `strongbox.ct.count` after AES-GCM seal is exactly this value
    /// (AES-GCM is a stream cipher and produces ciphertext of
    /// the same length as plaintext; the AEAD tag is stored
    /// separately as `strongbox.tag`).
    /// 4 MiB is sized to fit >= 256 wallets where each wallet
    /// stores its raw post-quantum private + public key bytes
    /// (~10 KiB/wallet) plus address + seed phrase + framing,
    /// plus networks + metadata + headroom. See file header
    /// for the full sizing argument.
    public static let bucketSize: Int = 4_194_304

    public enum Error: Swift.Error, CustomStringConvertible {
        case plaintextTooLargeForBucket(actualBytes: Int, bucketBytes: Int)
        case malformedPadding

        public var description: String {
            switch self {
                case .plaintextTooLargeForBucket(let a, let b):
                return "StrongboxPadding: plaintext \(a) bytes exceeds bucket \(b) bytes"
                case .malformedPadding:
                return "StrongboxPadding: padding marker missing or malformed"
            }
        }
    }

    /// Pad `plaintext` to exactly `bucketSize` bytes using the
    /// `0x80 || 0x00*` scheme. Throws if `plaintext.count >=
    /// bucketSize` because the marker byte itself needs at
    /// least one trailing position.
    public static func pad(_ plaintext: Data) throws -> Data {
        guard plaintext.count < bucketSize else {
            throw Error.plaintextTooLargeForBucket(
                actualBytes: plaintext.count,
                bucketBytes: bucketSize)
        }
        var padded = Data(count: bucketSize)
        padded.replaceSubrange(0..<plaintext.count, with: plaintext)
        padded[plaintext.count] = 0x80
        // Bytes after the marker are already 0x00 from
        // `Data(count:)`; no additional fill needed.
        return padded
    }

    /// Reverse of `pad`. Walks from the tail, skipping zeros,
    /// expects 0x80, returns the prefix.
    public static func unpad(_ padded: Data) throws -> Data {
        guard padded.count == bucketSize else {
            throw Error.malformedPadding
        }
        // Find the marker byte by walking from the end.
        var i = padded.count - 1
        while i >= 0 && padded[i] == 0x00 {
            i -= 1
        }
        guard i >= 0, padded[i] == 0x80 else {
            throw Error.malformedPadding
        }
        return padded.prefix(i)
    }
}
