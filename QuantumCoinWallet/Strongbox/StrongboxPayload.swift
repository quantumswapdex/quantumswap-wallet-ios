// StrongboxPayload.swift (Strongbox layer 5)
// Typed model of the cleartext JSON inside the encrypted v3
// `strongbox` field. Closes the schema-shape half of the
// on-disk threat profile.
// Cross-platform contract (v=3 unified schema):
// The on-disk plaintext layout below is byte-for-byte identical
// to Android `StrongboxPayload.java` under the same inputs. The
// inner `checksum` is a keyed HMAC-SHA-256 derived via
// HKDF(mainKey, salt=nil, info="strongbox-payload-checksum-v3",
// L=32). Test vectors live under
// tests/fixtures/strongbox-v3-vectors/ and are consumed by
// `StrongboxPortabilityVectorTests` on each platform.
// Why this exists:
// In v1, every per-wallet datum (count, has-seed flag, current
// wallet index, custom networks list, backup-enabled flag,
// ...) was a separate plaintext key in `PrefConnect`. That
// leaked the wallet count and the per-wallet metadata
// structure to anyone who could read the file (the storage-
// medium exfiltration threat profile). The earlier two-tier
// layout encrypted only *some* of these fields and left the
// per-slot wallet ciphertexts visible alongside, so an
// attacker who could read the file knew the wallet count
// from key enumeration alone.
// In v2, the entire wallet semantics live inside this single
// typed payload, AES-GCM-sealed under `mainKey` and padded to
// exactly StrongboxPadding.bucketSize (4 MiB) before sealing. The
// only thing pre-unlock observable on disk is "a strongbox file
// exists" - the count, the per-wallet flags, the network
// customisations, the backup-enabled bit are all hidden by
// construction.
// The shape below is normative: any field added to v2 wallet
// semantics MUST go here, NOT into `PrefConnect`. Every
// legacy plaintext key listed at the top of `PrefConnect` is
// forbidden in v2; this struct is the single replacement.
// Layered design:
// - This file knows about wallet semantics (addresses, custom
// networks, UI state). It does NOT know about file layout
// (slot rotation, MAC, padding) - those live in layer 1
// (`AtomicSlotWriter`) and layer 2 (`StrongboxFileCodec`).
// - This file does NOT know about cryptographic primitives.
// The raw payload bytes are produced by `JSONEncoder` and
// handed to layer 3's `Aead.seal` / `Aead.open` by layer 4
// (`KeyStore` / future `Strongbox` accessor).
// - The inner `checksum` field is defense-in-depth on top of
// the outer AEAD tag: if a partial-decrypt scenario ever
// emerged (e.g. a future codec bug that decrypts only part
// of the buffer), the checksum mismatch surfaces it before
// the wallet snapshot is rebuilt. The outer tag is the
// primary integrity guarantee; checksum is an additional
// belt over the suspenders.
// Per-wallet schema (matches Android byte-for-byte):
// Each `Wallet` carries the raw signing-key bytes
// (`privateKey`, `publicKey`), the address as text, a
// `hasSeed` flag, and the comma-joined seed phrase. There is
// no nested per-wallet envelope: the outer `strongbox` AEAD
// tag is the only encryption layer over the keys. The same
// security model as Android, where the strongbox unlock is
// the single password-gated entry point and the in-memory
// snapshot exposes the raw key bytes for signing without a
// second password-derived unwrap.
// On-disk wallets shape:
//   "wallets": { "0": "<base64-blob>", "1": "<base64-blob>", ... }
// The base64 blob is produced by `WalletEntryCodec`
// (length-prefixed binary, see that file's header for the
// wire-format diagram). The map key is `String(idx)` so the
// canonical sortedKeys JSON is deterministic and identical to
// Android's `Map<String,String>` serialisation.
// Tradeoffs:
// - All wallet-semantic fields are in one buffer, so any
// mutation rewrites the entire 4 MiB. With AtomicSlotWriter's
// two-slot rotation that is 8 MiB physical writes per change.
// On a modern iPhone with sequential write throughput >=
// 200 MiB/s that is < ~50 ms and under user perception.
// - `customNetworks` mirrors the v1 strongbox blob's `networks`
// array. The bundled MAINNET network (loaded from
// `Resources/blockchain_networks.json`) is NOT stored here -
// it is re-prepended on every `applyDecryptedConfig` call,
// keeping the bundled resource as the canonical source for
// the default chain config.

import Foundation

public struct StrongboxPayload: Codable, Sendable, Equatable {

    /// Schema version of the payload. Bumped only when an
    /// incompatible field shape change is needed. v=3 is the
    /// cross-platform-portable schema: same field set, same
    /// keyed-HMAC inner checksum, same canonicalisation rules
    /// as Android. v=2 was iOS-only (the divergence layer).
    public let v: Int

    /// All wallets the user has created. Order is by `idx`
    /// ascending; that ordering is also what the UI renders.
    /// In-memory shape is a typed array so callers do not need
    /// to deal with the on-disk `[String: String]` map; the
    /// `Codable` implementation below handles the conversion.
    public let wallets: [Wallet]

    /// Index of the currently-active wallet (one of the
    /// `wallets[*].idx` values). Persisted so the home strip
    /// re-opens to the same wallet across relaunches.
    public let currentWalletIndex: Int

    /// User-added custom networks. Bundled MAINNET is NOT
    /// included; layer 5 re-prepends it whenever the network
    /// list is rendered. See file header for rationale.
    public let customNetworks: [BlockchainNetwork]

    /// Index into `(bundled || customNetworks)` of the
    /// currently-active network. 0 == bundled MAINNET.
    public let activeNetworkIndex: Int

    // The `backupEnabled` toggle is intentionally NOT a payload
    // field. `BackupExclusion` and the iCloud Backup gate both
    // read the UserDefaults pref (`PrefConnect.backupEnabledKey`)
    // BEFORE the user unlocks the wallet, so duplicating it inside
    // the encrypted payload would create a parity gap (the on-disk
    // pref could disagree with the on-disk payload after a crash
    // during the pref->payload mirror) without any actual consumer
    // reading the payload field. UserDefaults is the SOLE source
    // of truth for the backup-enabled toggle; the OS-level backup
    // decision never needs the password. Mirrored on Android in
    // `StrongboxPayload.java` / `UnlockCoordinator.java`.

    /// User-selected iCloud Drive folder for `.wallet` exports.
    /// Empty string when the user has not selected a folder yet.
    public let cloudBackupFolderUri: String

    /// User toggle: enable advanced signing UX (raw transaction
    /// preview, custom gas fields, etc.).
    public let advancedSigning: Bool

    /// Idempotency flag for the camera-permission prompt.
    /// `true` once we have asked the user (regardless of their
    /// answer) so we never re-prompt automatically.
    public let cameraPermissionAskedOnce: Bool

    /// Generic key->value secure items (e.g. saved per-address
    /// signing passwords). Each value is opaque to this layer.
    /// Mirrors Android `StrongboxPayload.secureItems`. Empty by
    /// default; iOS does not currently use this slot but keeps
    /// the field for byte-equivalent v=3 schema parity.
    public let secureItems: [String: String]

    /// Defense-in-depth keyed integrity tag. HMAC-SHA-256 over
    /// the canonical JSON of every preceding field, keyed by
    /// HKDF(mainKey, salt=nil, info="strongbox-payload-checksum-v3").
    /// Verified post-decrypt; on mismatch we hard-fail the
    /// unlock with a tamper-detected error rather than rebuild
    /// a corrupted snapshot. Domain-separated from the file MAC
    /// so a key compromise of either does not weaken the other.
    public let checksum: String

    /// Decoded view of one entry. Mirrors Android's
    /// `WalletEntryCodec.WalletEntry` plus an `idx` (which is
    /// the wallet-map key on disk; carried in-memory so callers
    /// can use a single typed value).
    public struct Wallet: Sendable, Equatable {
        public let idx: Int
        public let address: String
        /// Raw signing-key bytes as returned by the JS bridge
        /// (`WalletEnvelope.privateKey`). Stored in cleartext
        /// inside the strongbox plaintext; the strongbox AEAD
        /// is the only encryption layer over this material.
        public let privateKey: Data
        /// Raw verifying-key bytes
        /// (`WalletEnvelope.publicKey`). Same storage rules as
        /// `privateKey`.
        public let publicKey: Data
        /// True when the wallet was created from / restored
        /// onto a seed phrase (so a seed-reveal flow is
        /// offered). False when the wallet was imported by raw
        /// private key.
        public let hasSeed: Bool
        /// Comma-joined seed phrase
        /// ("abandon,ability,able,..."). Empty when
        /// `hasSeed == false`. Comma separator and ordering
        /// must match Android's `String.join(",", words)` so
        /// the encoded blob is byte-equivalent across
        /// platforms.
        public let seedWords: String

        public init(idx: Int,
            address: String,
            privateKey: Data,
            publicKey: Data,
            hasSeed: Bool,
            seedWords: String) {
            self.idx = idx
            self.address = address
            self.privateKey = privateKey
            self.publicKey = publicKey
            self.hasSeed = hasSeed
            self.seedWords = seedWords
        }
    }

    public init(v: Int,
        wallets: [Wallet],
        currentWalletIndex: Int,
        customNetworks: [BlockchainNetwork],
        activeNetworkIndex: Int,
        cloudBackupFolderUri: String,
        advancedSigning: Bool,
        cameraPermissionAskedOnce: Bool,
        secureItems: [String: String] = [:],
        checksum: String) {
        self.v = v
        self.wallets = wallets
        self.currentWalletIndex = currentWalletIndex
        self.customNetworks = customNetworks
        self.activeNetworkIndex = activeNetworkIndex
        self.cloudBackupFolderUri = cloudBackupFolderUri
        self.advancedSigning = advancedSigning
        self.cameraPermissionAskedOnce = cameraPermissionAskedOnce
        self.secureItems = secureItems
        self.checksum = checksum
    }

    // MARK: - Codable
    // On disk the wallets collection is a `[String: String]`
    // map keyed by `String(idx)` whose values are the
    // base64-wrapped `WalletEntryCodec` binary blobs. That
    // shape is byte-equivalent to Android's
    // `StrongboxPayload.wallets` (Java `Map<String,String>`).
    // In memory we expose a typed `[Wallet]` so callers do not
    // need to know about the binary codec; this `Codable`
    // implementation translates between the two on every
    // encode/decode boundary.

    private enum CodingKeys: String, CodingKey {
        case v
        case wallets
        case currentWalletIndex
        case customNetworks
        case activeNetworkIndex
        // `backupEnabled` is intentionally NOT a payload field; the
        // backup-enabled toggle is a UserDefaults pref (see file
        // header). Omitted from CodingKeys so the encoder cannot
        // emit it accidentally and the decoder silently ignores
        // any legacy field on read (Swift's Codable ignores unknown
        // keys by default).
        case cloudBackupFolderUri
        case advancedSigning
        case cameraPermissionAskedOnce
        case secureItems
        case checksum
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try c.decode(Int.self, forKey: .v)

        let walletMap = try c.decode([String: String].self, forKey: .wallets)
        var decoded: [Wallet] = []
        decoded.reserveCapacity(walletMap.count)
        for (idxStr, blob) in walletMap {
            guard let idx = Int(idxStr) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .wallets,
                    in: c,
                    debugDescription: "wallet map key is not a base-10 integer: \(idxStr)")
            }
            let entry: WalletEntryCodec.WalletEntry
            do {
                entry = try WalletEntryCodec.decode(blob)
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .wallets,
                    in: c,
                    debugDescription: "WalletEntryCodec.decode failed for idx=\(idxStr): \(error)")
            }
            decoded.append(Wallet(
                idx: idx,
                address: entry.address,
                privateKey: entry.privateKey,
                publicKey: entry.publicKey,
                hasSeed: entry.hasSeed,
                seedWords: entry.seedWords))
        }
        decoded.sort { $0.idx < $1.idx }
        self.wallets = decoded

        self.currentWalletIndex = try c.decode(Int.self, forKey: .currentWalletIndex)
        self.customNetworks = try c.decode([BlockchainNetwork].self, forKey: .customNetworks)
        self.activeNetworkIndex = try c.decode(Int.self, forKey: .activeNetworkIndex)
        self.cloudBackupFolderUri = try c.decode(String.self, forKey: .cloudBackupFolderUri)
        self.advancedSigning = try c.decode(Bool.self, forKey: .advancedSigning)
        self.cameraPermissionAskedOnce = try c.decode(Bool.self, forKey: .cameraPermissionAskedOnce)
        self.secureItems = (try? c.decode([String: String].self, forKey: .secureItems)) ?? [:]
        self.checksum = try c.decode(String.self, forKey: .checksum)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)

        var walletMap: [String: String] = [:]
        walletMap.reserveCapacity(wallets.count)
        for w in wallets {
            let entry = WalletEntryCodec.WalletEntry(
                address: w.address,
                privateKey: w.privateKey,
                publicKey: w.publicKey,
                hasSeed: w.hasSeed,
                seedWords: w.seedWords)
            do {
                walletMap[String(w.idx)] = try WalletEntryCodec.encode(entry)
            } catch {
                throw EncodingError.invalidValue(w, EncodingError.Context(
                    codingPath: c.codingPath + [CodingKeys.wallets],
                    debugDescription: "WalletEntryCodec.encode failed for idx=\(w.idx): \(error)"))
            }
        }
        try c.encode(walletMap, forKey: .wallets)

        try c.encode(currentWalletIndex, forKey: .currentWalletIndex)
        try c.encode(customNetworks, forKey: .customNetworks)
        try c.encode(activeNetworkIndex, forKey: .activeNetworkIndex)
        try c.encode(cloudBackupFolderUri, forKey: .cloudBackupFolderUri)
        try c.encode(advancedSigning, forKey: .advancedSigning)
        try c.encode(cameraPermissionAskedOnce, forKey: .cameraPermissionAskedOnce)
        try c.encode(secureItems, forKey: .secureItems)
        try c.encode(checksum, forKey: .checksum)
    }
}
