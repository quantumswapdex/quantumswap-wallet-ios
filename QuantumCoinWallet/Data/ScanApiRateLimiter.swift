// ScanApiRateLimiter.swift
// Process-wide guard for the public scan API (`app.readrelay…`).
// When any caller receives HTTP 429, all scan GETs pause until the
// backoff window expires so balance polling + token fetches do not
// keep hammering the limiter and extend the outage.

import Foundation

public final class ScanApiRateLimiter: @unchecked Sendable {

    public static let shared = ScanApiRateLimiter()

    private let lock = NSLock()
    private var blockedUntil: Date?

    private init() {}

    /// `true` when callers should not issue another scan GET yet.
    public func isThrottled(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = blockedUntil else { return false }
        if now >= until {
            blockedUntil = nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .scanApiThrottleDidChange, object: nil)
            }
            return false
        }
        return true
    }

    /// Whole seconds remaining in the current backoff window, if any.
    public func remainingSeconds(now: Date = Date()) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let until = blockedUntil, until > now else { return nil }
        return max(1, Int(ceil(until.timeIntervalSince(now))))
    }

    /// Record a 429 (or equivalent) and pause further scan traffic.
    public func recordRateLimit(retryAfter: TimeInterval? = nil) {
        let delay = max(30, retryAfter ?? 60)
        lock.lock()
        blockedUntil = Date().addingTimeInterval(delay)
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .scanApiThrottleDidChange, object: nil)
        }
    }

    /// Parse `Retry-After` when the server supplies a delay hint.
    public static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds > 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}
