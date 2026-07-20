// DexUnlockPrompt.swift
// Shared password gate for DEX flows (Swap / Liquidity / Pools /
// Releases). Mirrors Send's UnlockDialog + verifyPassword path and
// Android `DexUnlockPrompt.java`.
// Android reference:
// app/src/main/java/com/quantumswap/app/view/dialog/DexUnlockPrompt.java

import UIKit

public enum DexUnlockPrompt {

    /// Present the unlock dialog. On success, dismisses and invokes
    /// `onUnlocked` with the trimmed password on the main actor.
    /// Optional `onCancel` runs when the user dismisses without unlocking.
    public static func show(from host: UIViewController,
        onUnlocked: @escaping (String) -> Void,
        onCancel: (() -> Void)? = nil) {
        let L = Localization.shared
        let dlg = UnlockDialogViewController()
        dlg.isMandatory = false
        dlg.onCancel = onCancel
        dlg.onUnlock = { [weak dlg] pw in
            guard let dlg else { return }
            if pw.isEmpty {
                dlg.showOrangeError(L.getEnterAPasswordByLangValues())
                return
            }
            let wait = WaitDialogViewController(
                message: L.getWaitUnlockByLangValues())
            dlg.present(wait, animated: true)
            let trimmed = pw.trimmingCharacters(in: .whitespacesAndNewlines)
            Task.detached(priority: .userInitiated) { [weak dlg, weak wait] in
                do {
                    try UnlockCoordinatorV2.verifyPassword(trimmed)
                    await MainActor.run {
                        wait?.dismiss(animated: true) {
                            dlg?.dismiss(animated: true) {
                                onUnlocked(trimmed)
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        wait?.dismiss(animated: true) {
                            if let uc = error as? UnlockCoordinatorV2Error,
                            case let .tooManyAttempts(seconds) = uc {
                                dlg?.showOrangeError(
                                    UnlockAttemptLimiter.userFacingLockoutMessage(
                                        remainingSeconds: seconds))
                            } else {
                                dlg?.showOrangeError(
                                    L.getWalletPasswordMismatchByErrors())
                            }
                        }
                    }
                }
            }
        }
        host.present(dlg, animated: true)
    }

    /// Unlock then load keys for `walletAddress`. Throws
    /// `CancellationError` if the user cancels.
    public static func unlockAndLoadKeys(
        from host: UIViewController,
        walletAddress: String) async throws -> (Data, Data) {
        try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce()
            Task { @MainActor in
                show(from: host, onUnlocked: { _ in
                    Task.detached {
                        do {
                            let keys = try loadWalletKeys(walletAddress: walletAddress)
                            once.resume { cont.resume(returning: keys) }
                        } catch {
                            once.resume { cont.resume(throwing: error) }
                        }
                    }
                }, onCancel: {
                    once.resume { cont.resume(throwing: CancellationError()) }
                })
            }
        }
    }

    /// Load signing keys for `walletAddress` from the unlocked
    /// strongbox. Background-thread / Task.detached only.
    public static func loadWalletKeys(walletAddress: String) throws -> (Data, Data) {
        let map = Strongbox.shared.indexToAddress
        var index: Int?
        for (idx, addr) in map {
            if addr.caseInsensitiveCompare(walletAddress) == .orderedSame {
                index = idx
                break
            }
        }
        if index == nil {
            let current = PrefConnect.shared.readInt(
                PrefKeys.WALLET_CURRENT_ADDRESS_INDEX_KEY, default: 0)
            if let addr = Strongbox.shared.address(forIndex: current),
            addr.caseInsensitiveCompare(walletAddress) == .orderedSame {
                index = current
            }
        }
        guard let index,
        let priv = Strongbox.shared.privateKey(at: index),
        let pub = Strongbox.shared.publicKey(at: index) else {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        return (priv, pub)
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func resume(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}
