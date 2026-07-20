// ReleaseStore.swift
// Source of truth for QuantumSwap "releases" (WQ / factory / router
// contract sets). Port of Android `ReleaseStore.java`: builtin Beta2
// plus user-defined releases in strongbox `secureItems`.
// Android reference:
// app/src/main/java/com/quantumswap/app/utils/ReleaseStore.java

import Foundation

public enum ReleaseStore {

    /// secureItems key: JSON array of user-defined releases.
    public static let itemReleases = "dexCustomReleases"
    /// secureItems key: name of the currently active release.
    public static let itemActive = "dexActiveRelease"

    public struct Release: Equatable {
        public let name: String
        public let wq: String
        public let factory: String
        public let router: String
        public let builtin: Bool

        public init(name: String, wq: String, factory: String,
            router: String, builtin: Bool) {
            self.name = name
            self.wq = wq
            self.factory = factory
            self.router = router
            self.builtin = builtin
        }
    }

    /// Desktop BUILTIN_SWAP_RELEASES "Beta2".
    public static let builtin = Release(
        name: "Beta2",
        wq: "0x45BD01BE5EF8509D9dA183689eA7Faf647331c54c7C9801dE54c9EDE9Ac44D92",
        factory: "0x95085766E20fCBf0106dC7037020Ca069e22080DBEF2615551Bab65D59a99754",
        router: "0xC3666584A70A707E5e929Ba9871083ED8f9528eCe7a56FdbA485272a645D861e",
        builtin: true)

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
                builtin: false)
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

    /// Add active-release contract overrides to a DEX bridge payload.
    /// Built-in release adds nothing (the bridge carries the same
    /// built-in addresses).
    public static func applyActiveRelease(to payload: inout [String: Any]) {
        let active = readActive()
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
            "router": release.router.trimmingCharacters(in: .whitespacesAndNewlines)
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
