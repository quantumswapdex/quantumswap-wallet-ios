// StrongboxPortabilityFixtures.swift
// Shared, test-only fixtures consumed by every Swift port of an
// Android strongbox test class. The pinned 32-byte seed and the
// SHAKE-256 expansion contract are described in
// `tests/fixtures/strongbox-v3-vectors/INDEX.md`; the Android
// counterpart lives under
// `app/src/test/java/com/quantumcoin/app/strongbox/`. Both sides
// consume the same seed and labels so they produce byte-identical
// wallet entries, payloads, AEAD nonces, MAC keys, and canonical
// JSON without checking large blobs into either repo.
import Foundation
@testable import QuantumCoinWallet

enum StrongboxPortabilityFixtures {

    /// Canonical 32-byte seed pinned in
    /// `tests/fixtures/strongbox-v3-vectors/INDEX.md`. Identical
    /// to the constant of the same name in the Android
    /// `StrongboxPortabilityVectorTest`.
    static let vectorSeed = Data(portabilityHex:
        "368f07e78cfc016d5c1c84ed617b37d15490ce98578643309c5c91b4de736921")

    /// `SHAKE256(seed || UTF8(label), count)`. Mirrors
    /// BouncyCastle `SHAKEDigest(256)` on the Android side.
    static func vectorBytes(_ label: String, count: Int) -> Data {
        return PortabilityShake256.expand(
            seed: vectorSeed, label: label, count: count)
    }

    /// Build the i-th portability wallet entry under the
    /// canonical fixture contract (even idx -> seeded, odd ->
    /// keys-only). Byte-equivalent to Android's
    /// `StrongboxPortabilityVectorTest.generatedWallet(int)`.
    static func generatedWallet(_ idx: Int) -> WalletEntryCodec.WalletEntry {
        let address = "0x" + vectorBytes("wallet-\(idx)-address", count: 20).portabilityHex
        let hasSeed = idx % 2 == 0
        let seedWords = hasSeed
            ? "word\(idx),word\(idx + 1),word\(idx + 2)"
            : ""
        return WalletEntryCodec.WalletEntry(
            address: address,
            privateKey: vectorBytes("wallet-\(idx)-private-key", count: 32),
            publicKey: vectorBytes("wallet-\(idx)-public-key", count: 32),
            hasSeed: hasSeed,
            seedWords: seedWords)
    }

    /// Build a deterministic 3-wallet payload using the fixture
    /// SHAKE expansion. Byte-equivalent to Android's
    /// `StrongboxPortabilityVectorTest.generatedPayload()`.
    static func generatedPayload() throws -> StrongboxPayload {
        let wallets = (0..<3).map { idx -> StrongboxPayload.Wallet in
            let entry = generatedWallet(idx)
            return StrongboxPayload.Wallet(
                idx: idx,
                address: entry.address,
                privateKey: entry.privateKey,
                publicKey: entry.publicKey,
                hasSeed: entry.hasSeed,
                seedWords: entry.seedWords)
        }
        return StrongboxPayload(
            v: StrongboxFileCodec.schemaVersion,
            wallets: wallets,
            currentWalletIndex: 1,
            customNetworks: [],
            activeNetworkIndex: 0,
            cloudBackupFolderUri: "",
            advancedSigning: false,
            cameraPermissionAskedOnce: false,
            secureItems: [:],
            checksum: "")
    }
}

extension Data {
    init(portabilityHex hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self.init(bytes)
    }

    var portabilityHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Test-only SHAKE-256 implementation used to expand the
/// hardcoded portability seed into deterministic vector inputs.
/// Production code does not depend on SHAKE; the helper lives in
/// the test target so Android and iOS can generate identical
/// fixtures without checking large JSON/hex blobs into either repo.
enum PortabilityShake256 {
    private static let rate = 136
    private static let rounds: [UInt64] = [
        0x0000000000000001, 0x0000000000008082,
        0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088,
        0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b,
        0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080,
        0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080,
        0x0000000080000001, 0x8000000080008008
    ]
    private static let rot: [[UInt64]] = [
        [0, 36, 3, 41, 18],
        [1, 44, 10, 45, 2],
        [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14]
    ]

    static func expand(seed: Data, label: String, count: Int) -> Data {
        var input = Data()
        input.append(seed)
        input.append(Data(label.utf8))
        var state = [UInt64](repeating: 0, count: 25)
        var offset = 0
        while offset + rate <= input.count {
            absorb(input.subdata(in: offset..<(offset + rate)), into: &state)
            keccakF(&state)
            offset += rate
        }
        var block = [UInt8](repeating: 0, count: rate)
        let tail = input.suffix(input.count - offset)
        block.replaceSubrange(0..<tail.count, with: tail)
        block[tail.count] ^= 0x1f
        block[rate - 1] ^= 0x80
        absorb(Data(block), into: &state)
        keccakF(&state)

        var out = Data()
        while out.count < count {
            let block = squeezeBlock(state)
            out.append(block.prefix(count - out.count))
            if out.count < count { keccakF(&state) }
        }
        return out
    }

    private static func absorb(_ block: Data, into state: inout [UInt64]) {
        for i in 0..<(rate / 8) {
            var lane: UInt64 = 0
            for j in 0..<8 {
                lane |= UInt64(block[block.startIndex + i * 8 + j]) << UInt64(8 * j)
            }
            state[i] ^= lane
        }
    }

    private static func squeezeBlock(_ state: [UInt64]) -> Data {
        var out = Data()
        for i in 0..<(rate / 8) {
            var lane = state[i]
            for _ in 0..<8 {
                out.append(UInt8(lane & 0xff))
                lane >>= 8
            }
        }
        return out
    }

    private static func keccakF(_ a: inout [UInt64]) {
        for rc in rounds {
            var c = [UInt64](repeating: 0, count: 5)
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20]
            }
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ c[(x + 1) % 5].portabilityRotateLeft(1)
            }
            for x in 0..<5 {
                for y in 0..<5 { a[x + 5 * y] ^= d[x] }
            }

            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = a[x + 5 * y].portabilityRotateLeft(rot[x][y])
                }
            }

            for x in 0..<5 {
                for y in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y])
                }
            }
            a[0] ^= rc
        }
    }
}

private extension UInt64 {
    func portabilityRotateLeft(_ n: UInt64) -> UInt64 {
        let s = n & 63
        return s == 0 ? self : (self << s) | (self >> (64 - s))
    }
}
