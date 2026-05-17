// Strongbox.swift (Strongbox layer 5)
// In-memory accessor for the decrypted v2 strongbox payload.
// Owns the snapshot lifecycle (rebuilt on unlock, dropped on
// relock) and exposes typed getters/setters for every wallet-
// semantic field. Closes the call-site half of ``.
// Why this exists:
// In an earlier shape of the app, every screen reached into
// `PrefConnect` directly to read or write a wallet-meaningful
// field. That made it structurally impossible to enforce the
// "only the encrypted strongbox holds wallet semantics"
// invariant: a single careless plaintext-pref write re-
// introduced the metadata leak.
// `Strongbox.shared` is the single replacement. Every wallet-
// meaningful read and write goes through this accessor.
// `PrefConnect` is restricted to the small UI-pref allowlist
// documented in `PrefConnect.swift`; any future PR that reads
// a wallet field via `PrefConnect` directly trips the
// grep-based invariant test under `QuantumCoinWalletTests`.
// Threading model: this class is `@unchecked Sendable` and
// coordinates internal state via a single `NSLock`. Reads
// are free across threads; writes serialize. The rationale
// for `NSLock` rather than an actor:
// 1. The existing call sites (`HomeWalletViewController`,
// `WalletsViewController`, `SendViewController`,
// `RestoreFlow`, etc.) are SYNC reads from MainActor-
// confined view-controller code. Wrapping every read in
// `await` would require a UI refactor far beyond the
// scope of .
// 2. The lock is held only across in-memory dictionary
// copies (microseconds). I/O happens outside the lock
// (write paths drop the lock, then call into layer 4 to
// re-encrypt and persist).
// Layered design:
// - This file knows about wallet semantics.
// - It does NOT know about the v2 file layout, MAC, or
// padding (those live in layers 1 / 2).
// - It does NOT know about cryptographic primitives.
// Persistence flows through `UnlockCoordinatorV2` (layer 4)
// -> `Aead.seal` -> `StrongboxPadding.pad` ->
// `StrongboxFileCodec.writeNewGeneration` ->
// `AtomicSlotWriter` (layers 1-3).
// Tradeoffs:
// - The "single in-memory snapshot" model is read-fast,
// write-slow: every mutation rebuilds and re-encrypts the
// entire payload. With StrongboxPadding's 4 MiB bucket and
// AtomicSlotWriter's two-slot rotation that is < ~50 ms per
// write on modern iPhones. User-driven mutations are rare
// enough that this is invisible.
// - Snapshot is wiped on `clearSnapshot` (called from idle-
// relock, sign-out, delete-all). After a wipe, every
// accessor returns its empty-state value (empty array,
// `nil`, `false`) so the UI degrades gracefully into the
// "locked" state without crashing.
// - The write paths require the user's password (to re-
// derive the MAC key + re-encrypt the strongbox). The
// password is collected by the caller via
// `UnlockDialogViewController` and threaded through
// `UnlockCoordinatorV2.appendWallet` /
// `replaceNetworks` / etc. mainKey is never cached
// across operations - every persist re-derives it via
// scrypt and zeroes the bytes on return.

import Foundation

public final class Strongbox: @unchecked Sendable {

    public static let shared = Strongbox()

    private let lock = NSLock()

    /// Decrypted snapshot. `nil` when locked. Set by
    /// `installSnapshot(_:)` from layer 4 after a successful
    /// unlock; cleared by `clearSnapshot` on relock.
    private var _snapshot: StrongboxPayload?

    private init() {}

    // MARK: - Snapshot lifecycle (called from layer 4)

    /// Install a freshly-decrypted payload after unlock. Layer 4
    /// is the only legitimate caller; UI code MUST NOT call this
    /// directly.
    public func installSnapshot(_ payload: StrongboxPayload) {
        lock.lock()
        _snapshot = payload
        lock.unlock()
    }

    /// Read-only view of the current snapshot, or `nil` while locked.
    /// Used by speculative-mutator paths (notably
    /// `UnlockCoordinatorV2.appendWallet`) to capture the prior
    /// snapshot so they can roll back via `installSnapshot` if the
    /// persist round-trip fails after the in-memory mutation has
    /// already been installed. Lock-protected to match
    /// `installSnapshot` / `clearSnapshot`.
    public var snapshotOrNil: StrongboxPayload? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    /// Drop the in-memory snapshot. Called from idle-relock,
    /// sign-out, and delete-all flows. Idempotent.
    public func clearSnapshot() {
        lock.lock()
        _snapshot = nil
        lock.unlock()
    }

    /// True once `installSnapshot(_:)` has run and the snapshot
    /// has not yet been cleared. UI code uses this to choose
    /// between the locked-screen path and the wallet path.
    public var isSnapshotLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return _snapshot != nil
    }

    // MARK: - Read accessors (snapshot only)

    /// Number of wallets currently in the snapshot. Returns 0
    /// while locked. NOTE: this number is NEVER persisted to
    /// disk in plaintext - it is computed from the in-memory
    /// snapshot only. The on-disk file has fixed-size padding
    /// so the count is undiscoverable pre-unlock.
    public var walletCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.wallets.count ?? 0
    }

    /// All wallets ordered by ascending `idx`. Empty while
    /// locked.
    public var wallets: [StrongboxPayload.Wallet] {
        lock.lock(); defer { lock.unlock() }
        guard let s = _snapshot else { return [] }
        return s.wallets.sorted { $0.idx < $1.idx }
    }

    /// Lookup helper. Returns `nil` for an unknown index OR
    /// while locked.
    public func wallet(at idx: Int) -> StrongboxPayload.Wallet? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.wallets.first(where: { $0.idx == idx })
    }

    /// Fast address-to-index lookup. Returns `nil` for unknown
    /// addresses or while locked. Case-insensitive on the hex
    /// portion of the address: QuantumCoin addresses are case-
    /// insensitive at the protocol layer, and the canonical
    /// mixed-case display rendering is handled at the UI layer
    /// for typo-spotting (see TransactionReviewDialogViewController
    /// and ).
    public func index(forAddress address: String) -> Int? {
        let target = address.lowercased()
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.wallets.first(where: {
                $0.address.lowercased() == target
            })?.idx
    }

    /// Address of the currently-active wallet, or `nil` while
    /// locked / no wallets exist.
    public var currentWalletAddress: String? {
        lock.lock(); defer { lock.unlock() }
        guard let s = _snapshot else { return nil }
        return s.wallets.first(where: { $0.idx == s.currentWalletIndex })?.address
    }

    /// `idx` of the currently-active wallet, or `nil` while
    /// locked.
    public var currentWalletIndex: Int? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.currentWalletIndex
    }

    /// Largest wallet index currently in use. Used by the
    /// create-wallet flow to compute the next available index.
    /// Returns -1 when the snapshot is empty so a caller can
    /// bump it by 1 to get the next free slot.
    public var maxWalletIndex: Int {
        lock.lock(); defer { lock.unlock() }
        guard let s = _snapshot, !s.wallets.isEmpty else { return -1 }
        return s.wallets.map(\.idx).max() ?? -1
    }

    /// `true` when at least one wallet is present in the snapshot.
    /// Returns `false` while locked, matching the locked-state
    /// "no wallet visible" UI contract.
    public var hasAnyWallet: Bool {
        walletCount > 0
    }

    /// Index -> address projection used by the wallets list and
    /// any caller that needs the dictionary-shaped view the
    /// historical KeyStore exposed. Empty while locked. Reads
    /// the snapshot under the lock and constructs the dictionary
    /// from the captured copy so callers can iterate without
    /// holding the lock.
    public var indexToAddress: [Int: String] {
        lock.lock()
        let captured = _snapshot?.wallets ?? []
        lock.unlock()
        var out: [Int: String] = [:]
        out.reserveCapacity(captured.count)
        for w in captured { out[w.idx] = w.address }
        return out
    }

    /// Address -> index projection. Keys are lowercased to make
    /// lookups case-insensitive on the hex portion of the
    /// address (the on-chain identity is the bytes, not the
    /// case). Empty while locked.
    public var addressToIndex: [String: Int] {
        lock.lock()
        let captured = _snapshot?.wallets ?? []
        lock.unlock()
        var out: [String: Int] = [:]
        out.reserveCapacity(captured.count)
        for w in captured { out[w.address.lowercased()] = w.idx }
        return out
    }

    /// Addresses ordered by ascending wallet index. Mirrors the
    /// rendering order the wallets list uses on every platform.
    /// Empty while locked.
    public func allAddressesSortedByIndex() -> [String] {
        lock.lock()
        let captured = _snapshot?.wallets ?? []
        lock.unlock()
        return captured.sorted { $0.idx < $1.idx }.map(\.address)
    }

    /// Convenience accessor for the address at an index. Returns
    /// `nil` for an unknown index OR while locked.
    public func address(forIndex idx: Int) -> String? {
        return wallet(at: idx)?.address
    }

    /// Raw signing-key bytes at an index. Returns `nil` for an
    /// unknown index OR while locked. After v2 the per-wallet
    /// keys are stored in cleartext inside the strongbox
    /// plaintext (the strongbox AEAD is the only encryption
    /// layer); accessing them does not require re-prompting for
    /// the user password.
    public func privateKey(at idx: Int) -> Data? {
        return wallet(at: idx)?.privateKey
    }

    /// Raw verifying-key bytes at an index. Same locking and
    /// access rules as `privateKey(at:)`.
    public func publicKey(at idx: Int) -> Data? {
        return wallet(at: idx)?.publicKey
    }

    /// Seed phrase (comma-joined) for the wallet at `idx`.
    /// Returns the empty string for a key-only-imported wallet
    /// (`hasSeed == false`); returns `nil` for an unknown index
    /// OR while locked.
    public func seedWords(at idx: Int) -> String? {
        return wallet(at: idx)?.seedWords
    }

    /// `true` when the wallet at `idx` was created from / restored
    /// onto a seed phrase. Returns `nil` for an unknown index OR
    /// while locked.
    public func hasSeed(at idx: Int) -> Bool? {
        return wallet(at: idx)?.hasSeed
    }

    /// Custom networks the user has added via the network
    /// picker. Bundled MAINNET is NOT included.
    public var customNetworks: [BlockchainNetwork] {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.customNetworks ?? []
    }

    /// Index into `(bundled || customNetworks)` of the
    /// currently-active network. 0 == bundled MAINNET. Returns
    /// 0 while locked so the UI defaults to MAINNET.
    public var activeNetworkIndex: Int {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.activeNetworkIndex ?? 0
    }

    // No `backupEnabled` accessor by design. The backup-enabled
    // toggle is read directly from `PrefConnect`'s UserDefaults
    // wrapper by `BackupExclusion`; routing it through a
    // Strongbox-gated accessor would create a parity gap with the
    // pre-unlock OS backup agent.

    public var cloudBackupFolderUri: String {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.cloudBackupFolderUri ?? ""
    }

    public var advancedSigningEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.advancedSigning ?? false
    }

    public var cameraPermissionAskedOnce: Bool {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.cameraPermissionAskedOnce ?? false
    }

    /// Generic key->value secure items (e.g. saved per-address
    /// signing passwords). Mirrors Android's
    /// `SecureStorage.getSecureItem(_:)`. Returns `nil` for an
    /// unknown key OR while locked.
    public func secureItem(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot?.secureItems[key]
    }

    /// All currently-stored secureItems keys. Empty while
    /// locked.
    public var secureItemKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(_snapshot?.secureItems.keys ?? Dictionary<String, String>().keys)
    }

    /// Snapshot copy for read-only callers that need an
    /// immutable view of every field at once (e.g. backup
    /// export). Returns `nil` while locked.
    public func snapshotCopy() -> StrongboxPayload? {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    // MARK: - Mutation builders (called from layer 4 write paths)
    // These helpers exist so layer 4 (`KeyStore`) can build the
    // next snapshot without re-implementing the lock dance at
    // every call site. They DO NOT persist - persistence is the
    // caller's responsibility (call `installSnapshot` and then
    // re-encrypt + write through `StrongboxFileCodec`).
    // The "build" verb is deliberate: we never return a snapshot
    // and let the caller mutate it (Swift `Codable` structs are
    // value types, so a returned-copy mutation is safe but
    // confusing). The builder pattern keeps every mutation a
    // single named operation.

    /// Build a new snapshot with `wallet` appended. The current
    /// snapshot must exist (caller must hold an unlocked
    /// session); throws otherwise.
    public func snapshotByAppendingWallet(_ wallet: StrongboxPayload.Wallet) throws -> StrongboxPayload {
        lock.lock(); defer { lock.unlock() }
        guard let cur = _snapshot else { throw Error.locked }
        var wallets = cur.wallets
        wallets.append(wallet)
        return rebuildPayload(from: cur, wallets: wallets)
    }

    /// Build a new snapshot with the wallet at `idx` removed.
    /// If the removed wallet was the active one, the active
    /// index is reset to the smallest remaining `idx`, or 0 if
    /// the wallet list is now empty.
    public func snapshotByRemovingWallet(idx: Int) throws -> StrongboxPayload {
        lock.lock(); defer { lock.unlock() }
        guard let cur = _snapshot else { throw Error.locked }
        let wallets = cur.wallets.filter { $0.idx != idx }
        let newCurrent: Int
        if cur.currentWalletIndex == idx {
            newCurrent = wallets.map(\.idx).min() ?? 0
        } else {
            newCurrent = cur.currentWalletIndex
        }
        return rebuildPayload(from: cur, wallets: wallets,
            currentWalletIndex: newCurrent)
    }

    /// Build a new snapshot with the active-wallet index
    /// changed.
    public func snapshotByChangingCurrentWallet(to idx: Int) throws -> StrongboxPayload {
        lock.lock(); defer { lock.unlock() }
        guard let cur = _snapshot else { throw Error.locked }
        return rebuildPayload(from: cur, currentWalletIndex: idx)
    }

    /// Build a new snapshot with the custom-networks list and
    /// active-network offset replaced atomically.
    public func snapshotByChangingNetworks(
        _ networks: [BlockchainNetwork],
        activeIndex: Int
    ) throws -> StrongboxPayload {
        lock.lock(); defer { lock.unlock() }
        guard let cur = _snapshot else { throw Error.locked }
        return rebuildPayload(from: cur,
            customNetworks: networks,
            activeNetworkIndex: activeIndex)
    }

    /// Build a new snapshot with the active-network offset
    /// changed (custom networks unchanged).
    public func snapshotByChangingActiveNetwork(to idx: Int) throws -> StrongboxPayload {
        lock.lock(); defer { lock.unlock() }
        guard let cur = _snapshot else { throw Error.locked }
        return rebuildPayload(from: cur, activeNetworkIndex: idx)
    }

    /// Build a new snapshot with one of the boolean prefs
    /// flipped. Centralised so the checksum recomputation is
    /// done in one place. The backup-enabled toggle is NOT a
    /// payload field — it lives in UserDefaults and is written
    /// directly by Settings (see `BackupExclusion.swift`).
    public func snapshotByChangingFlag(
        advancedSigning: Bool? = nil,
        cameraPermissionAskedOnce: Bool? = nil,
        cloudBackupFolderUri: String? = nil
    ) throws -> StrongboxPayload {
        lock.lock(); defer { lock.unlock() }
        guard let cur = _snapshot else { throw Error.locked }
        return rebuildPayload(
            from: cur,
            cloudBackupFolderUri: cloudBackupFolderUri ?? cur.cloudBackupFolderUri,
            advancedSigning: advancedSigning ?? cur.advancedSigning,
            cameraPermissionAskedOnce:
            cameraPermissionAskedOnce ?? cur.cameraPermissionAskedOnce)
    }

    // MARK: - secureItems mutation builder

    /// Build a new snapshot with a single secureItems entry
    /// inserted (overwriting any prior value at the same key).
    /// Mirrors Android `SecureStorage.setSecureItem`.
    public func snapshotBySettingSecureItem(_ key: String, value: String) throws -> StrongboxPayload {
        lock.lock(); defer { lock.unlock() }
        guard let cur = _snapshot else { throw Error.locked }
        var items = cur.secureItems
        items[key] = value
        return Self.rebuildPayloadStatic(
            wallets: cur.wallets,
            currentWalletIndex: cur.currentWalletIndex,
            customNetworks: cur.customNetworks,
            activeNetworkIndex: cur.activeNetworkIndex,
            cloudBackupFolderUri: cur.cloudBackupFolderUri,
            advancedSigning: cur.advancedSigning,
            cameraPermissionAskedOnce: cur.cameraPermissionAskedOnce,
            secureItems: items)
    }

    /// Build a new snapshot with `key` removed from secureItems.
    /// Returns the unmodified snapshot if the key is absent.
    public func snapshotByRemovingSecureItem(_ key: String) throws -> StrongboxPayload {
        lock.lock(); defer { lock.unlock() }
        guard let cur = _snapshot else { throw Error.locked }
        var items = cur.secureItems
        items.removeValue(forKey: key)
        return Self.rebuildPayloadStatic(
            wallets: cur.wallets,
            currentWalletIndex: cur.currentWalletIndex,
            customNetworks: cur.customNetworks,
            activeNetworkIndex: cur.activeNetworkIndex,
            cloudBackupFolderUri: cur.cloudBackupFolderUri,
            advancedSigning: cur.advancedSigning,
            cameraPermissionAskedOnce: cur.cameraPermissionAskedOnce,
            secureItems: items)
    }

    // MARK: - Initial-snapshot helper

    /// Construct an empty snapshot for a freshly-created strongbox
    /// (no wallets yet). Used by the first-launch path; the
    /// caller installs it and then writes through layer 4.
    public static func emptySnapshot() -> StrongboxPayload {
        return rebuildPayloadStatic(
            wallets: [],
            currentWalletIndex: 0,
            customNetworks: [],
            activeNetworkIndex: 0,
            cloudBackupFolderUri: "",
            advancedSigning: false,
            cameraPermissionAskedOnce: false,
            secureItems: [:])
    }

    /// Construct a snapshot for a freshly-created strongbox that
    /// already contains `wallet` as the sole entry. Used by
    /// `UnlockCoordinatorV2.createNewStrongboxWithInitialWallet` so
    /// the first-launch bootstrap and the first-wallet-add can
    /// share a single atomic mutation transaction.
    /// the wallet's `idx` should match what `appendWallet` would
    /// have assigned (i.e. 0 for the first wallet) so a future
    /// `appendWallet` can compute `maxWalletIndex + 1` and not
    /// collide. This is the caller's responsibility because the
    /// caller has already derived the raw key bytes from the JS
    /// bridge for this wallet and the idx is part of the
    /// snapshot's wallet-map key.
    /// Cross-references:
    ///   - (atomic
    ///     bootstrap+append closes this).
    public static func snapshotWithInitialWallet(
        _ wallet: StrongboxPayload.Wallet) -> StrongboxPayload {
        return rebuildPayloadStatic(
            wallets: [wallet],
            currentWalletIndex: wallet.idx,
            customNetworks: [],
            activeNetworkIndex: 0,
            cloudBackupFolderUri: "",
            advancedSigning: false,
            cameraPermissionAskedOnce: false,
            secureItems: [:])
    }

    // MARK: - Errors

    public enum Error: Swift.Error, CustomStringConvertible {
        case locked
        public var description: String {
            switch self {
                case .locked:
                return "Strongbox: snapshot is not loaded (wallet is locked)"
            }
        }
    }

    // MARK: - Internal payload rebuild + checksum

    private func rebuildPayload(
        from base: StrongboxPayload,
        wallets: [StrongboxPayload.Wallet]? = nil,
        currentWalletIndex: Int? = nil,
        customNetworks: [BlockchainNetwork]? = nil,
        activeNetworkIndex: Int? = nil,
        cloudBackupFolderUri: String? = nil,
        advancedSigning: Bool? = nil,
        cameraPermissionAskedOnce: Bool? = nil,
        secureItems: [String: String]? = nil
    ) -> StrongboxPayload {
        return Self.rebuildPayloadStatic(
            wallets: wallets ?? base.wallets,
            currentWalletIndex: currentWalletIndex ?? base.currentWalletIndex,
            customNetworks: customNetworks ?? base.customNetworks,
            activeNetworkIndex: activeNetworkIndex ?? base.activeNetworkIndex,
            cloudBackupFolderUri: cloudBackupFolderUri ?? base.cloudBackupFolderUri,
            advancedSigning: advancedSigning ?? base.advancedSigning,
            cameraPermissionAskedOnce:
            cameraPermissionAskedOnce ?? base.cameraPermissionAskedOnce,
            secureItems: secureItems ?? base.secureItems)
    }

    /// Build a v=3 snapshot with `checksum = ""` as a placeholder.
    /// The actual checksum is keyed by `mainKey` and is therefore
    /// only meaningful at persist time; the persist pipeline
    /// (UnlockCoordinatorV2.persistSnapshot, deepVerifyStaged)
    /// calls `Strongbox.stampChecksum(...)` to fill the field
    /// before encoding for AEAD seal. Snapshots constructed
    /// here pass through `Strongbox.shared.installSnapshot(...)`
    /// where the placeholder is irrelevant because reads never
    /// re-verify the checksum (the post-decrypt verifier did
    /// that against the on-disk value).
    private static func rebuildPayloadStatic(
        wallets: [StrongboxPayload.Wallet],
        currentWalletIndex: Int,
        customNetworks: [BlockchainNetwork],
        activeNetworkIndex: Int,
        cloudBackupFolderUri: String,
        advancedSigning: Bool,
        cameraPermissionAskedOnce: Bool,
        secureItems: [String: String]
    ) -> StrongboxPayload {
        return StrongboxPayload(
            v: 3,
            wallets: wallets.sorted { $0.idx < $1.idx },
            currentWalletIndex: currentWalletIndex,
            customNetworks: customNetworks,
            activeNetworkIndex: activeNetworkIndex,
            cloudBackupFolderUri: cloudBackupFolderUri,
            advancedSigning: advancedSigning,
            cameraPermissionAskedOnce: cameraPermissionAskedOnce,
            secureItems: secureItems,
            checksum: "")
    }

    // MARK: - Inner-payload checksum (v=3 keyed HMAC)
    // The on-disk plaintext payload carries a `checksum` field
    // computed as:
    //   key = HKDF(mainKey, salt=nil,
    //              info="strongbox-payload-checksum-v3", L=32)
    //   tag = HMAC-SHA-256(key, canonical(payload-sans-checksum))
    //   checksum = base64(tag)
    // The HKDF info label is distinct from the file-level MAC's
    // `"integrity-v2"` label so the two derived keys cannot
    // collide (RFC 5869 §3.2). The keyed scheme catches partial-
    // decrypt corruption AND prevents an attacker who can flip
    // ciphertext bits but not forge an HMAC under `mainKey` from
    // generating a payload that round-trips. Mirrors Android
    // `StrongboxPayload.computeChecksum(byte[] mainKey)`.
    // The canonical input is the sorted-keys JSON of the
    // payload's typed fields with the literal `"checksum"` key
    // omitted. The encoder is `JSONEncoder` with
    // `outputFormatting = [.sortedKeys]` which produces the same
    // byte sequence as Android's `TreeMap` traversal in
    // `StrongboxFileCodec.canonicalize`.

    /// HKDF info label for the v=3 inner-payload checksum key.
    /// Bumped from "strongbox-payload-checksum-v2" to surface
    /// the schema version in the derivation context, so a v=2
    /// reader cannot accidentally accept a v=3 checksum (the
    /// derived keys differ).
    public static let checksumInfoLabel: String = "strongbox-payload-checksum-v3"

    /// Internal struct that mirrors `StrongboxPayload` minus the
    /// `checksum` field. Used as the canonicalisation input for
    /// the checksum so the checksum cannot be self-referential.
    /// The wallet entries are encoded into the same
    /// `[String: String]` map shape as the on-disk payload (via
    /// `WalletEntryCodec`) so the checksum input is byte-
    /// equivalent to the post-encrypt JSON layout.
    private struct ChecksumDraft: Encodable {
        let v: Int
        let wallets: [StrongboxPayload.Wallet]
        let currentWalletIndex: Int
        let customNetworks: [BlockchainNetwork]
        let activeNetworkIndex: Int
        // `backupEnabled` is intentionally absent from the checksum
        // draft to match the StrongboxPayload schema. The checksum
        // input must be byte-identical to Android's
        // `canonicalBytesForChecksum` output. See
        // `StrongboxPayload.swift` for the rationale.
        let cloudBackupFolderUri: String
        let advancedSigning: Bool
        let cameraPermissionAskedOnce: Bool
        let secureItems: [String: String]

        private enum CodingKeys: String, CodingKey {
            case v
            case wallets
            case currentWalletIndex
            case customNetworks
            case activeNetworkIndex
            case cloudBackupFolderUri
            case advancedSigning
            case cameraPermissionAskedOnce
            case secureItems
        }

        func encode(to encoder: Encoder) throws {
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
                walletMap[String(w.idx)] = try WalletEntryCodec.encode(entry)
            }
            try c.encode(walletMap, forKey: .wallets)
            try c.encode(currentWalletIndex, forKey: .currentWalletIndex)
            try c.encode(customNetworks, forKey: .customNetworks)
            try c.encode(activeNetworkIndex, forKey: .activeNetworkIndex)
            try c.encode(cloudBackupFolderUri, forKey: .cloudBackupFolderUri)
            try c.encode(advancedSigning, forKey: .advancedSigning)
            try c.encode(cameraPermissionAskedOnce, forKey: .cameraPermissionAskedOnce)
            try c.encode(secureItems, forKey: .secureItems)
        }
    }

    /// Compute the keyed-HMAC checksum bytes (32 bytes) for
    /// `payload`, using `mainKey` to derive a fresh checksum
    /// key. The derived key is zeroized before this method
    /// returns. Callers should base64-encode the result for
    /// JSON storage.
    public static func computeChecksum(of payload: StrongboxPayload, mainKey: Data) -> Data {
        let draft = ChecksumDraft(
            v: payload.v,
            wallets: payload.wallets,
            currentWalletIndex: payload.currentWalletIndex,
            customNetworks: payload.customNetworks,
            activeNetworkIndex: payload.activeNetworkIndex,
            cloudBackupFolderUri: payload.cloudBackupFolderUri,
            advancedSigning: payload.advancedSigning,
            cameraPermissionAskedOnce: payload.cameraPermissionAskedOnce,
            secureItems: payload.secureItems)
        let canonical = canonicalBytesForChecksum(draft)
        var derivedKey = Mac.hkdfExtractAndExpand(
            inputKeyMaterial: mainKey,
            salt: Data(),
            info: checksumInfoLabel,
            length: 32)
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }
        return Mac.hmacSha256(message: canonical, keyBytes: derivedKey)
    }

    /// Canonical sorted-keys JSON encoding of the payload-sans-
    /// checksum. Exposed for cross-platform parity tests that
    /// need to inspect the exact bytes that feed the inner
    /// checksum HMAC. NOT for general use.
    public static func canonicalBytesForChecksum(of payload: StrongboxPayload) -> Data {
        let draft = ChecksumDraft(
            v: payload.v,
            wallets: payload.wallets,
            currentWalletIndex: payload.currentWalletIndex,
            customNetworks: payload.customNetworks,
            activeNetworkIndex: payload.activeNetworkIndex,
            cloudBackupFolderUri: payload.cloudBackupFolderUri,
            advancedSigning: payload.advancedSigning,
            cameraPermissionAskedOnce: payload.cameraPermissionAskedOnce,
            secureItems: payload.secureItems)
        return canonicalBytesForChecksum(draft)
    }

    private static func canonicalBytesForChecksum(_ draft: ChecksumDraft) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(draft) else {
            Logger.debug(category: "STRONGBOX_CHECKSUM_ENCODE_FAIL",
                "JSONEncoder().encode(ChecksumDraft) returned nil")
            return Data()
        }
        return data
    }

    /// Stamp the keyed `checksum` field on `payload` using
    /// `mainKey`. Returns a new payload value with the same
    /// fields and a non-empty `checksum`. Layer 4 calls this
    /// inside the persist pipeline (right before encoding for
    /// AEAD seal) and inside the deep-verify path.
    public static func stampChecksum(of payload: StrongboxPayload, mainKey: Data) -> StrongboxPayload {
        let tag = computeChecksum(of: payload, mainKey: mainKey)
        return StrongboxPayload(
            v: payload.v,
            wallets: payload.wallets,
            currentWalletIndex: payload.currentWalletIndex,
            customNetworks: payload.customNetworks,
            activeNetworkIndex: payload.activeNetworkIndex,
            cloudBackupFolderUri: payload.cloudBackupFolderUri,
            advancedSigning: payload.advancedSigning,
            cameraPermissionAskedOnce: payload.cameraPermissionAskedOnce,
            secureItems: payload.secureItems,
            checksum: tag.base64EncodedString())
    }

    /// Verify a snapshot's `checksum` field matches a freshly-
    /// computed one keyed by `mainKey`. Constant-time bytewise
    /// comparison via `Mac.verify` (HMAC.isValidAuthenticationCode).
    /// Layer 4 calls this after a successful `Aead.open` and
    /// `StrongboxPadding.unpad`.
    public static func verifyChecksum(of payload: StrongboxPayload, mainKey: Data) -> Bool {
        guard !payload.checksum.isEmpty,
              let stored = Data(base64Encoded: payload.checksum),
              stored.count == 32 else {
            return false
        }
        let canonical = canonicalBytesForChecksum(of: payload)
        var derivedKey = Mac.hkdfExtractAndExpand(
            inputKeyMaterial: mainKey,
            salt: Data(),
            info: checksumInfoLabel,
            length: 32)
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }
        return Mac.verify(canonical, mac: stored, keyBytes: derivedKey)
    }

}
