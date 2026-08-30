// DexPayloads.swift
// Builders for JSON payloads staged toward the bridge DEX methods.
// Port of Android `DexPayloads.java`. Signing key material is staged
// on the binary channel by `JsBridge.dexCall` (iOS bridge.html uses
// `dexWalletFromBinaryKeys`); this helper only adds `advancedSigning`
// alongside the base network / release fields.
// Android reference:
// app/src/main/java/com/quantumswap/app/utils/DexPayloads.java

import Foundation

public enum DexPayloads {

    /// Payload for a DEX submit that also carries binary key material
    /// for `JsBridge.dexCall(privKey:pubKey:)`.
    public struct Keyed {
        public var payload: [String: Any]
        public let privKey: Data
        public let pubKey: Data
    }

    public static func base() -> [String: Any] {
        let snap = NetworkConfig.currentSync
        var p: [String: Any] = [
            "chainId": snap.chainId,
            "rpcEndpoint": snap.rpcEndpoint
        ]
        ReleaseStore.applyActiveRelease(to: &p)
        return p
    }

    /// Chain fields captured now (chainId, rpcEndpoint, release
    /// addresses). The tx-steps dialog captures this once at open and
    /// overlays it on every step payload so a network switch mid-flow
    /// cannot re-target a later step (Android TxStepsDialog.chainSnapshot).
    public static func chainSnapshot() -> [String: Any] { base() }

    /// Shallow key-by-key copy of `source` over `target`
    /// (Android TxStepsDialog.overlay).
    public static func overlay(_ target: inout [String: Any], _ source: [String: Any]) {
        for (k, v) in source { target[k] = v }
    }

    /// `base()` + `advancedSigning`, plus key bytes for binary staging.
    /// Keys are NOT placed in the JSON (iOS pull-binary channel).
    public static func withKeys(privKey: Data, pubKey: Data) -> Keyed {
        var p = base()
        p["advancedSigning"] = PrefConnect.shared.readBool(
            PrefKeys.ADVANCED_SIGNING_ENABLED_KEY)
        return Keyed(payload: p, privKey: privKey, pubKey: pubKey)
    }
}

// MARK: - Envelope helpers

public enum DexBridgeResult {

    /// Unwrap `{ success, data }` from a DEX bridge response.
    /// Unwraps the bridge envelope and surfaces a Swap Read API fallback
    /// (`apiFallback`) as a transient toast before the caller renders
    /// the RPC result. Submit results never carry the field.
    public static func unwrapData(_ json: String) throws -> [String: Any] {
        let data = try unwrapDataRaw(json)
        SwapApiToast.showIfFallback(data)
        return data
    }

    public static func unwrapDataRaw(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let inner = obj["data"] as? [String: Any] else {
            throw JsEngineError.callFailed("DEX response missing data")
        }
        return inner
    }

    /// Coerce a loosely-typed JSON number (String / Int / NSNumber).
    public static func int64(_ raw: Any?) -> Int64? {
        if let s = raw as? String { return Int64(s.trimmingCharacters(in: .whitespaces)) }
        if let n = raw as? Int64 { return n }
        if let n = raw as? Int { return Int64(n) }
        if let n = raw as? NSNumber { return n.int64Value }
        return nil
    }

    public static func sanitizeError(_ s: String?) -> String {
        guard let s else { return "" }
        var out = ""
        for u in s.unicodeScalars {
            if u.value < 0x20 || u.value == 0x7f {
                out.append(" ")
            } else {
                out.append(Character(u))
            }
        }
        return out.count > 300 ? String(out.prefix(300)) : out
    }

    public static func sanitizeSymbol(_ s: String?) -> String {
        guard let s else { return "" }
        var out = ""
        for u in s.unicodeScalars {
            if u.value < 0x20 || u.value == 0x7f { continue }
            out.append(Character(u))
        }
        return out.count > 20 ? String(out.prefix(20)) : out
    }

    public static func shortAddr(_ addr: String?) -> String {
        guard let addr, !addr.isEmpty else { return "" }
        if addr.count > 14 {
            return String(addr.prefix(8)) + "..." + String(addr.suffix(4))
        }
        return addr
    }
}
