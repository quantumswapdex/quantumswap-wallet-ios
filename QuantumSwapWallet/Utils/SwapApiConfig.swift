// SwapApiConfig.swift
// Per-release Swap Read API configuration (web app releases.ts /
// sanitize.ts): the built-in defaults, the URL sanitiser and the dexId
// rule. Pure; shared by ReleaseStore and the Releases screen. Port of
// Android `SwapApiConfig.java`; the bridge applies the same rules.

import Foundation

public enum SwapApiConfig {

    public static let defaultApiUrl = "https://api.quantumswap.com"
    public static let defaultDexId = "quantumswap-beta2"
    public static let maxUrlLen = 200

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"^(https?)://([a-zA-Z0-9.-]+|\[[0-9a-fA-F:]+\])(:\d{1,5})?(/[A-Za-z0-9._~/-]*)?$"#)
    private static let dexIdPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]{1,64}$"#)

    /// http(s) origin + path only (no credentials, query or fragment), no
    /// trailing slash, at most `maxUrlLen` characters; "" when the input
    /// is not acceptable.
    public static func sanitizeUrl(_ raw: String?) -> String {
        guard let raw else { return "" }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.count > maxUrlLen { return "" }
        let ns = s as NSString
        guard let m = urlPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return "" }
        func group(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        var path = group(4)
        while path.hasSuffix("/") { path.removeLast() }
        return group(1) + "://" + group(2) + group(3) + path
    }

    public static func isValidDexId(_ s: String?) -> Bool {
        guard let s else { return false }
        let ns = s as NSString
        return dexIdPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }
}
