// WalletEntryCodec.swift (Strongbox layer, per-wallet serialization)
// Compact binary codec for the per-wallet entry stored inside
// `StrongboxPayload.wallets`. Byte-for-byte equivalent to the
// Android `com.quantumswap.app.strongbox.WalletEntryCodec`
// so the same encoded blob can be inspected, audited, or
// transported across platforms without re-encoding.
// Why this exists:
// QuantumCoin uses post-quantum signatures whose raw key bytes
// dominate the per-wallet payload (Dilithium-class keys are
// ~7.5 KiB raw). Storing a JSON object per wallet would inflate
// the on-disk shape with field-key + base64 + outer-JSON
// quote-escape overhead. Encoding as a length-prefixed binary
// blob (then base64-wrapping at the JSON boundary) is what
// lets us comfortably fit >= 256 wallets in the 4 MiB strongbox
// bucket without leaning on JSON-encoder peculiarities.
// Wire format (all multi-byte fields big-endian):
//   +---------+---------+---------+---------------------+
//   | u8: ver | u8: flg | u16: aL | aL bytes: address   |
//   +---------+---------+---------+---------------------+
//   | u32: skL                    | skL bytes: privKey  |
//   +---------+---------+---------+---------------------+
//   | u32: pkL                    | pkL bytes: pubKey   |
//   +---------+---------+---------+---------------------+
//   | u32: sL                     | sL bytes: seedWords |
//   +-----------------------------+---------------------+
//   - ver:       wire version (currently 1; bump on any wire
//                change so `decode` can hard-fail rather than
//                silently mis-parse a stale blob).
//   - flg bit 0: hasSeed (1 = seed bytes present; 0 = key-only
//                import).
//   - address:   UTF-8 bytes of the 0x-prefixed hex address as
//                supplied by the JS bridge. Stored as text (NOT
//                hex-decoded) so an EIP-55 checksummed (mixed-
//                case) address survives the round-trip exactly;
//                the upstream wallet maps key on this string and
//                would miss on a case change.
//   - privKey/   raw signing-key bytes as returned by the JS
//     pubKey:    bridge (`WalletEnvelope.privateKey` /
//                `WalletEnvelope.publicKey`); the bulk of the
//                per-wallet size lives here for post-quantum
//                key types.
//   - seedWords: UTF-8 of the comma-joined seed phrase
//                ("abandon,ability,able,..."); empty when
//                hasSeed = false. Comma separator and ordering
//                must match Android's
//                `String.join(",", words)`.
// The codec is fully encapsulated by `Strongbox.swift`'s
// per-wallet accessors and the `StrongboxPayload` Codable
// implementation; UI screens (Send / Reveal / Backup) never see
// the binary blob.

import Foundation

public enum WalletEntryCodec {

    /// Wire-format schema version. Increment on any binary
    /// layout change so `decode(_:)` can hard-fail on a stale
    /// blob rather than silently mis-parsing.
    public static let wireVersion: UInt8 = 1

    private static let flagHasSeed: UInt8 = 0x01

    /// Decoded view of one `StrongboxPayload.wallets` entry.
    /// All fields are non-empty (or the empty-string default)
    /// after a successful `decode(_:)`. `privateKey` /
    /// `publicKey` are mutable copies callers may zeroize.
    public struct WalletEntry: Sendable, Equatable {
        public let address: String
        public var privateKey: Data
        public var publicKey: Data
        public let hasSeed: Bool
        /// Comma-joined seed phrase, or empty when
        /// `hasSeed == false`.
        public let seedWords: String

        public init(address: String,
            privateKey: Data,
            publicKey: Data,
            hasSeed: Bool,
            seedWords: String) {
            self.address = address
            self.privateKey = privateKey
            self.publicKey = publicKey
            self.hasSeed = hasSeed
            self.seedWords = seedWords
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case empty
        case invalidBase64(String)
        case unsupportedWireVersion(Int)
        case truncated(field: String, have: Int, need: Int)
        case addressTooLong(Int)

        public var description: String {
            switch self {
            case .empty:
                return "WalletEntryCodec: encoded entry is empty"
            case .invalidBase64(let m):
                return "WalletEntryCodec: base64 decode failed: \(m)"
            case .unsupportedWireVersion(let v):
                return "WalletEntryCodec: unsupported wire version \(v)"
            case .truncated(let f, let h, let n):
                return "WalletEntryCodec: truncated \(f) (\(h)/\(n))"
            case .addressTooLong(let n):
                return "WalletEntryCodec: address too long: \(n)"
            }
        }
    }

    // MARK: - Encode

    /// Encode a `WalletEntry` to the compact base64-wrapped
    /// binary form. Output is ASCII-safe so it can be stored
    /// as the value of a JSON map without any inner escaping.
    public static func encode(_ entry: WalletEntry) throws -> String {
        guard let addrBytes = entry.address.data(using: .utf8) else {
            throw Error.invalidBase64("address is not UTF-8")
        }
        let seedBytes: Data
        if entry.hasSeed {
            seedBytes = entry.seedWords.data(using: .utf8) ?? Data()
        } else {
            seedBytes = Data()
        }
        if addrBytes.count > 0xFFFF {
            throw Error.addressTooLong(addrBytes.count)
        }

        var out = Data()
        out.reserveCapacity(
            /*ver*/1 + /*flg*/1 + /*aL*/2 + addrBytes.count
            + /*skL*/4 + entry.privateKey.count
            + /*pkL*/4 + entry.publicKey.count
            + /*sL*/4 + seedBytes.count)

        out.append(wireVersion)
        out.append(entry.hasSeed ? flagHasSeed : 0)
        appendUInt16BE(UInt16(addrBytes.count), to: &out)
        out.append(addrBytes)
        appendUInt32BE(UInt32(entry.privateKey.count), to: &out)
        out.append(entry.privateKey)
        appendUInt32BE(UInt32(entry.publicKey.count), to: &out)
        out.append(entry.publicKey)
        appendUInt32BE(UInt32(seedBytes.count), to: &out)
        out.append(seedBytes)

        return out.base64EncodedString()
    }

    // MARK: - Decode

    /// Decode a base64-wrapped binary blob into a typed
    /// `WalletEntry`. Validates the wire version up front so a
    /// stale or foreign blob fails loudly rather than feeding
    /// the upstream signer junk bytes.
    public static func decode(_ encoded: String) throws -> WalletEntry {
        if encoded.isEmpty {
            throw Error.empty
        }
        guard let raw = Data(base64Encoded: encoded) else {
            throw Error.invalidBase64("not valid base64")
        }

        var cursor = 0
        let ver = try readUInt8(raw, &cursor, field: "ver")
        if ver != wireVersion {
            throw Error.unsupportedWireVersion(Int(ver))
        }
        let flags = try readUInt8(raw, &cursor, field: "flags")
        let hasSeed = (flags & flagHasSeed) != 0
        let addrLen = Int(try readUInt16BE(raw, &cursor, field: "addrLen"))
        let addrBytes = try readExact(raw, &cursor, n: addrLen, field: "address")
        let skLen = Int(try readUInt32BE(raw, &cursor, field: "skLen"))
        let sk = try readExact(raw, &cursor, n: skLen, field: "privateKey")
        let pkLen = Int(try readUInt32BE(raw, &cursor, field: "pkLen"))
        let pk = try readExact(raw, &cursor, n: pkLen, field: "publicKey")
        let sLen = Int(try readUInt32BE(raw, &cursor, field: "seedLen"))
        let seedBytes = try readExact(raw, &cursor, n: sLen, field: "seedWords")

        let address = String(data: addrBytes, encoding: .utf8) ?? ""
        let seedWords = hasSeed
            ? (String(data: seedBytes, encoding: .utf8) ?? "")
            : ""

        return WalletEntry(
            address: address,
            privateKey: sk,
            publicKey: pk,
            hasSeed: hasSeed,
            seedWords: seedWords)
    }

    // MARK: - Helpers

    private static func appendUInt16BE(_ v: UInt16, to data: inout Data) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    private static func appendUInt32BE(_ v: UInt32, to data: inout Data) {
        data.append(UInt8((v >> 24) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    private static func readUInt8(_ raw: Data, _ cursor: inout Int,
        field: String) throws -> UInt8 {
        guard cursor + 1 <= raw.count else {
            throw Error.truncated(field: field, have: raw.count - cursor, need: 1)
        }
        let v = raw[raw.startIndex + cursor]
        cursor += 1
        return v
    }

    private static func readUInt16BE(_ raw: Data, _ cursor: inout Int,
        field: String) throws -> UInt16 {
        guard cursor + 2 <= raw.count else {
            throw Error.truncated(field: field, have: raw.count - cursor, need: 2)
        }
        let base = raw.startIndex + cursor
        let v = (UInt16(raw[base]) << 8) | UInt16(raw[base + 1])
        cursor += 2
        return v
    }

    private static func readUInt32BE(_ raw: Data, _ cursor: inout Int,
        field: String) throws -> UInt32 {
        guard cursor + 4 <= raw.count else {
            throw Error.truncated(field: field, have: raw.count - cursor, need: 4)
        }
        let base = raw.startIndex + cursor
        let v = (UInt32(raw[base]) << 24)
            | (UInt32(raw[base + 1]) << 16)
            | (UInt32(raw[base + 2]) << 8)
            | UInt32(raw[base + 3])
        cursor += 4
        return v
    }

    private static func readExact(_ raw: Data, _ cursor: inout Int,
        n: Int, field: String) throws -> Data {
        if n == 0 { return Data() }
        guard n >= 0 else {
            throw Error.truncated(field: field, have: 0, need: n)
        }
        guard cursor + n <= raw.count else {
            throw Error.truncated(field: field,
                have: raw.count - cursor, need: n)
        }
        let base = raw.startIndex + cursor
        let slice = raw.subdata(in: base..<(base + n))
        cursor += n
        return slice
    }
}
