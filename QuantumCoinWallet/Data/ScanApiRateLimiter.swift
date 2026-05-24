// ScanApiRateLimiter.swift
// Process-wide guard for the public scan API (`app.readrelay…`).
// Serializes GETs, spaces them out, and caps volume below the
// server's ~5-request window so iOS does not burn the budget with
// parallel balance + token fetches before the first 429 is seen.

import Foundation

public final class ScanApiRateLimiter: @unchecked Sendable {

    public static let shared = ScanApiRateLimiter()

    /// Cap scan GET volume per window (balance + tokens + pagination).
    static let maxRequestsPerWindow = 10
    static let requestWindowSeconds: TimeInterval = 10
    static let minSpacingSeconds: TimeInterval = 1

    private let lock = NSLock()
    private var blockedUntil: Date?
    private var recentStarts: [Date] = []

    /// Only one scan GET in flight; additional callers await their turn.
    private var gateHeld = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Body / status checks for relay rate-limit responses (429 or plain text).
    public static func looksLikeRateLimit(body: String?, status: Int) -> Bool {
        if status == 429 { return true }
        guard let lower = body?.lowercased() else { return false }
        return lower.contains("exceeded limit")
            && (lower.contains("retry after") || lower.contains("retry"))
    }

    /// Wait for the global gate, spacing, and per-minute budget before a GET.
    func acquireRequestSlot() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !gateHeld {
                gateHeld = true
                lock.unlock()
                cont.resume()
            } else {
                gateWaiters.append(cont)
                lock.unlock()
            }
        }
        while true {
            let delay = nextAllowedDelay()
            if delay <= 0 {
                markRequestStarting()
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if isThrottled() { return }
        }
    }

    func releaseRequestSlot() {
        lock.lock()
        defer { lock.unlock() }
        if gateWaiters.isEmpty {
            gateHeld = false
        } else {
            gateWaiters.removeFirst().resume()
        }
    }

    /// Record a 429 (or equivalent) and pause further scan traffic.
    public func recordRateLimit(retryAfter: TimeInterval? = nil) {
        let delay = max(30, retryAfter ?? 60)
        lock.lock()
        let wasActive: Bool
        if let until = blockedUntil, Date() < until {
            wasActive = true
        } else {
            wasActive = false
        }
        blockedUntil = Date().addingTimeInterval(delay)
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .scanApiThrottleDidChange, object: nil)
            if !wasActive {
                NotificationCenter.default.post(
                    name: .scanApiRateLimitNotifyUser, object: nil)
            }
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

    // MARK: - Private

    private func nextAllowedDelay(now: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        if let until = blockedUntil, now < until {
            return until.timeIntervalSince(now)
        }

        pruneRecentStarts(now: now)

        if recentStarts.count >= Self.maxRequestsPerWindow,
           let oldest = recentStarts.first {
            let wait = Self.requestWindowSeconds - now.timeIntervalSince(oldest)
            if wait > 0 { return wait }
        }

        if let last = recentStarts.last {
            let since = now.timeIntervalSince(last)
            if since < Self.minSpacingSeconds {
                return Self.minSpacingSeconds - since
            }
        }

        return 0
    }

    private func markRequestStarting(now: Date = Date()) {
        lock.lock()
        recentStarts.append(now)
        pruneRecentStarts(now: now)
        lock.unlock()
    }

    private func pruneRecentStarts(now: Date) {
        recentStarts.removeAll {
            now.timeIntervalSince($0) >= Self.requestWindowSeconds
        }
    }
}
