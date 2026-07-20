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
    public static func unwrapData(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let inner = obj["data"] as? [String: Any] else {
            throw JsEngineError.callFailed("DEX response missing data")
        }
        return inner
    }

    /// Parse gas from an estimate response with desktop-style 20% pad.
    public static func parseGas(_ json: String, fallback: Int64) -> Int64 {
        do {
            let data = try unwrapData(json)
            let raw = data["gasLimit"]
            let v: Int64
            if let s = raw as? String, let n = Int64(s) {
                v = n
            } else if let n = raw as? Int64 {
                v = n
            } else if let n = raw as? Int {
                v = Int64(n)
            } else if let n = raw as? NSNumber {
                v = n.int64Value
            } else {
                return fallback
            }
            return max(fallback, (v * 12) / 10)
        } catch {
            return fallback
        }
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
