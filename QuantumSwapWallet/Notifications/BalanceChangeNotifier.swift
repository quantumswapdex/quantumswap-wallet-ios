// BalanceChangeNotifier.swift
// Background balance-change notifier. Parity with the Android
// `HomeActivity.notificationThread` loop that compares the formatted
// balance from the previous tick to the current tick and posts a
// system notification when the value changes while the app is not in
// the foreground.
//
// Android reference:
// app/src/main/java/com/quantumcoin/app/view/activities/HomeActivity.java
//   - notificationThread (lines 1487-1549)
//   - sendNotificationChannel
//
// iOS notification permission UX: we ask once after the first
// successful wallet unlock (the moment Android starts its
// notification thread). If the user denies, every subsequent
// `observeBalance` call silently no-ops; we never re-prompt - the
// user can re-enable from Settings -> Notifications.

import Foundation
import UIKit
import UserNotifications

/// Singleton that tracks the last-seen formatted balance per wallet
/// address and fires a local notification when the value changes
/// while the app is backgrounded. Designed to be invoked from
/// `HomeViewController.refreshBalance` on every success tick and
/// from the first successful unlock callback for the permission
/// prompt.
public final class BalanceChangeNotifier {

    public static let shared = BalanceChangeNotifier()

    /// `[normalisedAddress: lastSeenFormattedBalance]`. First entry
    /// for an address is seeded silently so the very first tick does
    /// not surface a "balance changed" notification on a freshly-
    /// unlocked wallet. The normalisation step lowercases the address
    /// so the cache survives mixed-case displays.
    private var lastSeen: [String: String] = [:]
    private let lock = NSLock()

    /// Throwaway identifier prefix used when scheduling notifications.
    /// Each notification carries a fresh UUID so iOS does not coalesce
    /// successive balance changes onto a single banner.
    private static let identifierPrefix = "quantum-coin.balance-change."

    private init() {}

    /// Ask iOS for permission to display alerts + play a sound. Safe
    /// to call repeatedly; iOS short-circuits the prompt once the user
    /// has answered. Errors and denials are silently swallowed because
    /// the rest of the wallet keeps working without notification
    /// support.
    public func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in
                // Result intentionally discarded: a denial here just
                // makes `observeBalance` a no-op; there is no
                // remediation flow inside the wallet UI.
            }
    }

    /// Compare `formatted` to the cached last-seen value for the
    /// supplied address. On the first call for an address the cache
    /// is seeded silently. On a subsequent change while the app is
    /// not active, schedules a local notification with the localized
    /// title + description + new balance.
    public func observeBalance(_ formatted: String, address: String) {
        let key = address.lowercased()
        let previous: String?
        lock.lock()
        previous = lastSeen[key]
        lastSeen[key] = formatted
        lock.unlock()

        guard let previous = previous else {
            // First observation for this address - seed the cache
            // without firing. Mirrors Android's `previousBalance ==
            // null` short-circuit at the top of `notificationThread`.
            return
        }
        guard previous != formatted else { return }

        // Only fire when the user is not in the app. Both `.background`
        // and `.inactive` (e.g. locked screen, control-center
        // overlay, multitasking switcher) count as "not visibly
        // looking at the in-app balance".
        let state = UIApplication.shared.applicationState
        guard state != .active else { return }

        scheduleNotification(formatted: formatted)
    }

    private func scheduleNotification(formatted: String) {
        let content = UNMutableNotificationContent()
        let L = Localization.shared
        content.title = L.getNotificationTitleByLangValues()
        let prefix = L.getNotificationDescriptionByLangValues()
        content.body = prefix.isEmpty ? formatted : "\(prefix) \(formatted)"
        content.sound = .default

        // `UNTimeIntervalNotificationTrigger` requires a positive
        // interval, so `0.1s` is the smallest "effectively immediate"
        // value iOS accepts.
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 0.1, repeats: false)
        let identifier = Self.identifierPrefix + UUID().uuidString
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in
            // Errors silently dropped: a failed schedule (e.g.
            // permission revoked between authorization callback
            // and add) leaves the in-app balance display unchanged,
            // which is the correct fallback.
        }
    }

    #if DEBUG
    /// Test hook to reset the per-address cache so deterministic test
    /// suites can re-run the seed-then-change sequence.
    func _resetCacheForTests() {
        lock.lock(); defer { lock.unlock() }
        lastSeen.removeAll()
    }
    #endif
}
