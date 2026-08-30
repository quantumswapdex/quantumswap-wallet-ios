// ReleaseStore.swift
// Source of truth for QuantumSwap "releases" (WQ / factory / router
// contract sets). Port of Android `ReleaseStore.java`: builtin Beta2
// plus user-defined releases in strongbox `secureItems`.
// Android reference:
// app/src/main/java/com/quantumswap/app/utils/ReleaseStore.java

import Foundation

public enum ReleaseStore {

    /// Version suffix of the two secureItems keys below. Bumped when the
    /// persisted release shape changes (v2 added the Swap Read API
    /// fields); older keys are never read and never deleted, so an
    /// install simply starts over from the built-in release. Identical
    /// literals on Android (ReleaseStore.ITEM_RELEASES / ITEM_ACTIVE).
    public static let releasesStoreVersion = 2
    /// secureItems key: JSON array of user-defined releases (v2).
    public static let itemReleases = "dexCustomReleases2"
    /// secureItems key: name of the currently active release (v2).
    public static let itemActive = "dexActiveRelease2"

    public struct Release: Equatable {
        public let name: String
        public let wq: String
        public let factory: String
        public let router: String
        public let builtin: Bool
        /// Swap Read API base URL for this release; "" = off (RPC only).
        public let apiUrl: String
        /// dexId served by that API for this release's factory; "" = off.
        public let dexId: String

        public init(name: String, wq: String, factory: String,
            router: String, builtin: Bool,
            apiUrl: String = SwapApiConfig.defaultApiUrl,
            dexId: String = SwapApiConfig.defaultDexId) {
            self.name = name
            self.wq = wq
            self.factory = factory
            self.router = router
            self.builtin = builtin
            self.apiUrl = apiUrl
            self.dexId = dexId
        }

        public var swapApiEnabled: Bool { !apiUrl.isEmpty && !dexId.isEmpty }
    }

    /// Desktop BUILTIN_SWAP_RELEASES "Beta2" plus the public Swap Read
    /// API defaults (web app chain.ts).
    public static let builtin = Release(
        name: "Beta2",
        wq: "0x45BD01BE5EF8509D9dA183689eA7Faf647331c54c7C9801dE54c9EDE9Ac44D92",
        factory: "0x95085766E20fCBf0106dC7037020Ca069e22080DBEF2615551Bab65D59a99754",
        router: "0xC3666584A70A707E5e929Ba9871083ED8f9528eCe7a56FdbA485272a645D861e",
        builtin: true,
        apiUrl: SwapApiConfig.defaultApiUrl,
        dexId: SwapApiConfig.defaultDexId)

    /// Persisted-field rule (web app resolvePersistedField): absent ->
    /// built-in default; present but "" -> explicitly off; present but
    /// invalid -> default.
    static func persistedApiUrl(_ o: [String: Any]) -> String {
        guard let raw = o["apiUrl"] as? String else { return SwapApiConfig.defaultApiUrl }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        let clean = SwapApiConfig.sanitizeUrl(raw)
        return clean.isEmpty ? SwapApiConfig.defaultApiUrl : clean
    }

    static func persistedDexId(_ o: [String: Any]) -> String {
        guard let raw = (o["dexId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return SwapApiConfig.defaultDexId }
        if raw.isEmpty { return "" }
        return SwapApiConfig.isValidDexId(raw) ? raw : SwapApiConfig.defaultDexId
    }

    // MARK: - Validation

    /// 0x followed by 64 hex chars (post-quantum 32-byte addresses).
    public static func isValidAddress(_ s: String?) -> Bool {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
        t.count == 66, t.hasPrefix("0x") else { return false }
        return t.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    /// Max 60 plain-text characters, non-empty, no control chars.
    public static func isValidName(_ s: String?) -> Bool {
        guard let raw = s else { return false }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.count > 60 { return false }
        for u in t.unicodeScalars {
            if u.value < 0x20 || u.value == 0x7f { return false }
        }
        return true
    }

    // MARK: - Read

    public static func readAll() -> [Release] {
        var out: [Release] = [builtin]
        guard let json = Strongbox.shared.secureItem(forKey: itemReleases),
        !json.isEmpty,
        let data = json.data(using: .utf8),
        let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return out }
        for o in arr {
            let r = Release(
                name: (o["name"] as? String) ?? "",
                wq: (o["wq"] as? String) ?? "",
                factory: (o["factory"] as? String) ?? "",
                router: (o["router"] as? String) ?? "",
                builtin: false,
                apiUrl: persistedApiUrl(o),
                dexId: persistedDexId(o))
            if isValidName(r.name), isValidAddress(r.wq),
            isValidAddress(r.factory), isValidAddress(r.router) {
                out.append(r)
            }
        }
        return out
    }

    /// Active release; falls back to builtin when the stored name no
    /// longer resolves.
    public static func readActive() -> Release {
        let activeName = Strongbox.shared.secureItem(forKey: itemActive) ?? ""
        if activeName.isEmpty { return builtin }
        for r in readAll() where r.name == activeName { return r }
        return builtin
    }

    /// Add the active release's Swap Read API config (every release) and
    /// contract overrides (custom releases only; the bridge carries the
    /// same built-in addresses) to a DEX bridge payload.
    public static func applyActiveRelease(to payload: inout [String: Any]) {
        let active = readActive()
        payload["releaseApiUrl"] = active.apiUrl
        payload["releaseDexId"] = active.dexId
        if active.builtin { return }
        payload["releaseWq"] = active.wq
        payload["releaseFactory"] = active.factory
        payload["releaseRouter"] = active.router
    }

    // MARK: - Write (password required — persist re-seals)

    public static func persistAddRelease(_ release: Release,
        password: String) throws {
        if !isValidName(release.name) || !isValidAddress(release.wq)
            || !isValidAddress(release.factory) || !isValidAddress(release.router) {
            throw DexStoreError.invalidRelease
        }
        if !release.apiUrl.isEmpty, release.apiUrl != SwapApiConfig.sanitizeUrl(release.apiUrl) {
            throw DexStoreError.invalidRelease
        }
        if !release.dexId.isEmpty, !SwapApiConfig.isValidDexId(release.dexId) {
            throw DexStoreError.invalidRelease
        }
        let trimmed = release.name.trimmingCharacters(in: .whitespacesAndNewlines)
        for existing in readAll() {
            if existing.name.caseInsensitiveCompare(trimmed) == .orderedSame {
                throw DexStoreError.duplicateName
            }
        }
        var arr: [[String: Any]] = []
        if let json = Strongbox.shared.secureItem(forKey: itemReleases),
        !json.isEmpty,
        let data = json.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            arr = parsed
        }
        arr.append([
            "name": trimmed,
            "wq": release.wq.trimmingCharacters(in: .whitespacesAndNewlines),
            "factory": release.factory.trimmingCharacters(in: .whitespacesAndNewlines),
            "router": release.router.trimmingCharacters(in: .whitespacesAndNewlines),
            // Always written: "" means the user switched the API off for
            // this release (absent would mean "use the default").
            "apiUrl": release.apiUrl,
            "dexId": release.dexId
        ])
        let encoded = try JSONSerialization.data(withJSONObject: arr, options: [])
        guard let value = String(data: encoded, encoding: .utf8) else {
            throw DexStoreError.invalidRelease
        }
        try UnlockCoordinatorV2.setSecureItem(key: itemReleases, value: value,
            password: password)
    }

    public static func persistActiveRelease(name: String,
        password: String) throws {
        try UnlockCoordinatorV2.setSecureItem(key: itemActive, value: name,
            password: password)
    }

    public enum DexStoreError: Error, LocalizedError {
        case invalidRelease
        case duplicateName

        public var errorDescription: String? {
            switch self {
            case .invalidRelease: return "invalid release"
            case .duplicateName: return "duplicate release name"
            }
        }
    }
}
