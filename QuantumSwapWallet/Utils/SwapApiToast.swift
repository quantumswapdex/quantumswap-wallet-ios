// SwapApiToast.swift
// Transient toast for a Swap Read API request that failed right before
// the bridge fell back to the chain: the bridge reports the failed
// request once as `apiFallback` (kind, HTTP status, server message) on
// the result it then serves from RPC. Deduplicated for a few seconds so
// per-keystroke quotes do not stack toasts. Port of Android
// `SwapApiToast.java`.

import Foundation

public enum SwapApiToast {

    private static let dedupeSeconds: TimeInterval = 5
    static let toastSeconds: TimeInterval = 3.5
    private static var lastMessage = ""
    private static var lastShownAt: TimeInterval = 0
    private static let lock = NSLock()

    public static func showIfFallback(_ data: [String: Any]) {
        guard let fallback = data["apiFallback"] as? [String: Any] else { return }
        var detail = sanitize(fallback["detail"] as? String)
        if detail.isEmpty { detail = sanitize(fallback["kind"] as? String) }
        if detail.isEmpty { detail = "error" }
        let message = Localization.shared.lang("swap-api-fallback-toast",
            fallback: "Swap Read API unavailable ([DETAIL]); using RPC.")
            .replacingOccurrences(of: "[DETAIL]", with: detail)
        let now = Date().timeIntervalSince1970
        lock.lock()
        let duplicate = message == lastMessage && now - lastShownAt < dedupeSeconds
        if !duplicate {
            lastMessage = message
            lastShownAt = now
        }
        lock.unlock()
        if duplicate { return }
        // At least 3 s on screen (the default 2.5 s is too short to read
        // the HTTP code / server message).
        DispatchQueue.main.async { Toast.show(message, duration: toastSeconds, style: .error) }
    }

    static func sanitize(_ s: String?) -> String {
        guard let s else { return "" }
        let cleaned = String(s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 200 ? String(cleaned.prefix(200)) : cleaned
    }
}
