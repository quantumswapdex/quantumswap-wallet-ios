// WalletEntryCodecTests.swift
//
// Verifies the iOS `WalletEntryCodec` matches the Android
// `com.quantumcoinwallet.app.strongbox.WalletEntryCodec`
// byte-for-byte (so the same encoded blob can round-trip
// across platforms) and exercises the round-trip / negative-
// path behaviour the in-memory snapshot relies on.

import XCTest
@testable import QuantumCoinWallet

final class WalletEntryCodecTests: XCTestCase {

    func testRoundTripSeededWalletPreservesAllFields() throws {
        let entry = WalletEntryCodec.WalletEntry(
            address: "0xAbCdEf0123456789AbCdEf0123456789AbCdEf01",
            privateKey: Data((0..<128).map { UInt8($0 & 0xFF) }),
            publicKey: Data((128..<256).map { UInt8($0 & 0xFF) }),
            hasSeed: true,
            seedWords: "abandon,ability,able,about,above,absent,absorb,abstract,absurd,abuse,access,accident")

        let encoded = try WalletEntryCodec.encode(entry)
        let decoded = try WalletEntryCodec.decode(encoded)

        XCTAssertEqual(decoded.address, entry.address)
        XCTAssertEqual(decoded.privateKey, entry.privateKey)
        XCTAssertEqual(decoded.publicKey, entry.publicKey)
        XCTAssertEqual(decoded.hasSeed, true)
        XCTAssertEqual(decoded.seedWords, entry.seedWords)
    }

    func testRoundTripKeyOnlyImportHasNoSeedBytes() throws {
        let entry = WalletEntryCodec.WalletEntry(
            address: "0x1111111111111111111111111111111111111111",
            privateKey: Data(repeating: 0xAA, count: 32),
            publicKey: Data(repeating: 0xBB, count: 64),
            hasSeed: false,
            seedWords: "this,must,be,ignored,when,hasSeed,is,false")

        let encoded = try WalletEntryCodec.encode(entry)
        let decoded = try WalletEntryCodec.decode(encoded)

        XCTAssertEqual(decoded.hasSeed, false)
        XCTAssertEqual(decoded.seedWords, "")
        XCTAssertEqual(decoded.privateKey, entry.privateKey)
        XCTAssertEqual(decoded.publicKey, entry.publicKey)
    }

    func testEip55MixedCaseAddressSurvivesRoundTrip() throws {
        // EIP-55 checksummed addresses encode the address case
        // as a checksum bit; a single case flip makes downstream
        // wallet-map lookups miss. The codec stores the address
        // as UTF-8 text (NOT hex-decoded raw) precisely so this
        // round-trip is verbatim.
        let mixed = "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01"
        let entry = WalletEntryCodec.WalletEntry(
            address: mixed,
            privateKey: Data([0x01, 0x02, 0x03]),
            publicKey: Data([0x04, 0x05, 0x06]),
            hasSeed: true,
            seedWords: "alpha,beta,gamma")

        let encoded = try WalletEntryCodec.encode(entry)
        let decoded = try WalletEntryCodec.decode(encoded)

        XCTAssertEqual(decoded.address, mixed,
            "EIP-55 mixed-case must survive verbatim")
    }

    func testEncodedBlobHasNoInnerJsonQuotes() throws {
        // The whole reason the codec exists (vs. JSON-encoding a
        // typed Wallet struct) is to eliminate inner JSON quote
        // escaping when the blob is stored as the value of a
        // JSON map. Base64 only emits A-Z a-z 0-9 + / = — none
        // of which JSON would escape.
        let entry = WalletEntryCodec.WalletEntry(
            address: "0xdEaDbEeF",
            privateKey: Data(repeating: 0x22, count: 64),
            publicKey: Data(repeating: 0x27, count: 64),
            hasSeed: true,
            seedWords: "quote,test")
        let encoded = try WalletEntryCodec.encode(entry)
        XCTAssertFalse(encoded.contains("\""),
            "encoded blob must not contain JSON-escapable double quotes")
        XCTAssertFalse(encoded.contains("\\"),
            "encoded blob must not contain JSON-escapable backslashes")
    }

    func testDecodeRejectsUnknownWireVersion() throws {
        // Construct a synthetic blob with a bogus version byte
        // and verify the decoder hard-fails rather than silently
        // misparsing.
        var raw = Data()
        raw.append(0xFF)         // bogus version
        raw.append(0x00)         // flags
        raw.append(0x00); raw.append(0x00) // addr len = 0
        raw.append(0x00); raw.append(0x00); raw.append(0x00); raw.append(0x00) // sk len = 0
        raw.append(0x00); raw.append(0x00); raw.append(0x00); raw.append(0x00) // pk len = 0
        raw.append(0x00); raw.append(0x00); raw.append(0x00); raw.append(0x00) // seed len = 0
        let encoded = raw.base64EncodedString()

        XCTAssertThrowsError(try WalletEntryCodec.decode(encoded)) { err in
            guard case WalletEntryCodec.Error.unsupportedWireVersion(let v) = err else {
                XCTFail("expected unsupportedWireVersion, got \(err)")
                return
            }
            XCTAssertEqual(v, 0xFF)
        }
    }

    func testDecodeRejectsTruncatedBlob() throws {
        // Encode a valid entry, then chop the trailing seed
        // bytes so the seed-length prefix points beyond EOF.
        let entry = WalletEntryCodec.WalletEntry(
            address: "0xABCD",
            privateKey: Data([0xAA, 0xBB]),
            publicKey: Data([0xCC, 0xDD]),
            hasSeed: true,
            seedWords: "alpha,beta")
        let encoded = try WalletEntryCodec.encode(entry)
        guard let raw = Data(base64Encoded: encoded) else {
            XCTFail("test setup: base64 decode failed")
            return
        }
        let truncated = raw.prefix(raw.count - 2)
        let truncatedEncoded = Data(truncated).base64EncodedString()

        XCTAssertThrowsError(try WalletEntryCodec.decode(truncatedEncoded)) { err in
            guard case WalletEntryCodec.Error.truncated = err else {
                XCTFail("expected truncated, got \(err)")
                return
            }
        }
    }

    func testDecodeRejectsEmptyInput() throws {
        XCTAssertThrowsError(try WalletEntryCodec.decode("")) { err in
            guard case WalletEntryCodec.Error.empty = err else {
                XCTFail("expected empty, got \(err)")
                return
            }
        }
    }

    func test256DilithiumWalletsFitInBucket() throws {
        // Sanity check that 256 wallets carrying Dilithium-class
        // raw keys (~7.5 KiB private + ~2.5 KiB public + address
        // + seed framing) fit inside the 4 MiB strongbox bucket
        // with comfortable headroom. Mirrors the same sanity
        // check on Android.
        let blob = WalletEntryCodec.WalletEntry(
            address: "0xdEaDbEeF11223344556677889900aAbBcCdDeEfF",
            privateKey: Data(repeating: 0xAA, count: 7_680),
            publicKey: Data(repeating: 0xBB, count: 2_592),
            hasSeed: true,
            seedWords: Array(repeating: "abandon", count: 24).joined(separator: ","))
        let encoded = try WalletEntryCodec.encode(blob)
        // Base64 inflation: ceil(rawBytes * 4 / 3). The check
        // here is the per-wallet on-disk footprint inside the
        // wallets map ("idx" key + ":" + quoted blob + ",").
        let perWallet = (encoded.utf8.count + 16) // generous map overhead
        let total = perWallet * 256
        XCTAssertLessThan(total, StrongboxPadding.bucketSize,
            "256 Dilithium-class wallets must fit in the 4 MiB strongbox bucket; "
            + "got \(total) bytes")
    }

    func testWireFormatSpecExactBytes() throws {
        // Anchor test pinning the exact byte sequence of the
        // wire format, so any future "innocent" tweak to the
        // codec (or to its big-endian framing) breaks here
        // before it breaks Android compatibility.
        let entry = WalletEntryCodec.WalletEntry(
            address: "AB",                                  // 2 bytes UTF-8
            privateKey: Data([0x01, 0x02, 0x03, 0x04]),     // 4 bytes
            publicKey: Data([0x05, 0x06]),                  // 2 bytes
            hasSeed: true,
            seedWords: "X")                                 // 1 byte UTF-8

        let encoded = try WalletEntryCodec.encode(entry)
        let raw = Data(base64Encoded: encoded)!

        let expected: [UInt8] = [
            0x01,                                           // ver
            0x01,                                           // flags (hasSeed bit)
            0x00, 0x02,                                     // addr len = 2
            0x41, 0x42,                                     // "AB"
            0x00, 0x00, 0x00, 0x04,                         // sk len = 4
            0x01, 0x02, 0x03, 0x04,
            0x00, 0x00, 0x00, 0x02,                         // pk len = 2
            0x05, 0x06,
            0x00, 0x00, 0x00, 0x01,                         // seed len = 1
            0x58                                            // "X"
        ]
        XCTAssertEqual(Array(raw), expected,
            "wire format drifted from the documented spec")
    }
}
