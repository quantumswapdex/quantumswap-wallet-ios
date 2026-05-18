// BackupExporter.swift
// Shared helper used by both first-time onboarding
// (`HomeWalletViewController.encryptAndExportBackup`) and the
// Wallets-list backup flow (`BackupOptionsViewController`). Given a
// plaintext seed-phrase, an address, and a backup password, encrypts
// the wallet via `JsBridge` and hands it off to `CloudBackupManager`.
// Lifting this out into a single function ensures the two callers stay
// in lockstep: any change to the encryption envelope shape, error
// messaging, or wait-dialog wording happens in one place rather than
// drifting between onboarding and Wallets-list.
// Android references:
// HomeWalletFragment.startCloudBackupFromOptionsScreen
// HomeWalletFragment.startFileBackupFromOptionsScreen
// WalletsFragment.showBackupChoiceDialog (cloud/file branches)

import UIKit

public enum BackupTarget {
    case file
    case cloud
}

/// Recovery material handed to `BackupExporter.reencryptAndExport`.
/// Mirrors the two-branch shape of Android
/// `CloudBackupManager.encryptWallet`: if the wallet has a seed
/// phrase, the export rides the `seedWords` branch of
/// `bridge.html#encryptWalletJson`; if it is a key-only wallet
/// (`hasSeed == false`, no recoverable BIP39 phrase) the raw
/// signing-key bytes are staged on the binary channel and the
/// bridge rides the `fromBinaryKeys` branch. Both branches
/// produce an interoperable cloud-`.wallet` envelope.
public enum BackupExportPayload {
    case seedWords([String])
    case keys(privateKey: Data, publicKey: Data)
}

public enum BackupExporter {

    /// Re-encrypt the wallet's recovery material under
    /// `backupPassword` and hand the result off to
    /// `CloudBackupManager` for the chosen `target`. Presents a
    /// `WaitDialog` while the bridge runs and a toast / error toast on
    /// completion. All UI work happens on the main actor; the
    /// encryption itself runs on a detached task because the JS bridge
    /// `encryptWalletJson` blocks on a `WKWebView` round-trip.
    public static func reencryptAndExport(
        payload: BackupExportPayload,
        address: String,
        backupPassword: String,
        target: BackupTarget,
        presenter: UIViewController
    ) {
        switch payload {
            case .seedWords(let words):
            guard !words.isEmpty else {
                Toast.showError(Localization.shared.getBackupFailedByLangValues())
                return
            }
            case .keys(let priv, let pub):
            guard !priv.isEmpty, !pub.isEmpty else {
                Toast.showError(Localization.shared.getBackupFailedByLangValues())
                return
            }
        }
        let wait = WaitDialogViewController(
            message: Localization.shared.getWaitWalletSaveByLangValues())
        presenter.present(wait, animated: true)

        Task.detached(priority: .userInitiated) { [weak presenter, weak wait] in
            var encryptedJson: String? = nil
            do {
                switch payload {
                    case .seedWords(let words):
                    let walletInputJson = encodeWalletInput(seedWords: words)
                    let envelope = try JsBridge.shared.encryptWalletJson(
                        walletInputJson: walletInputJson, password: backupPassword)
                    encryptedJson = extractEncryptedJson(envelope)
                    case .keys(let priv, let pub):
                    // Take local mutable copies so the `defer`
                    // can zeroize them the moment the bridge call
                    // returns. The bridge itself zeroes the
                    // staged binary slots in its `finally`
                    // handler (bridge.html lines 670-672); this
                    // wipe covers the Swift-side residue.
                    var privCopy = priv
                    var pubCopy = pub
                    defer {
                        privCopy.resetBytes(in: 0..<privCopy.count)
                        pubCopy.resetBytes(in: 0..<pubCopy.count)
                    }
                    let envelope = try JsBridge.shared.encryptWalletJson(
                        privateKey: privCopy, publicKey: pubCopy,
                        password: backupPassword)
                    encryptedJson = extractEncryptedJson(envelope)
                }
            } catch {
                encryptedJson = nil
            }
            let resultJson = encryptedJson
            await MainActor.run {
                wait?.dismiss(animated: true) {
                    guard let presenter = presenter, let json = resultJson else {
                        Toast.showError(Localization.shared.getBackupFailedByLangValues())
                        return
                    }
                    switch target {
                        case .file:
                        CloudBackupManager.shared.exportWalletFile(
                            address: address, walletJson: json, from: presenter)
                        case .cloud:
                        CloudBackupManager.shared.presentFolderPicker(from: presenter) { [weak presenter] ok in
                            guard ok else { return }
                            // `writeWalletFile` returns a
                            // `BackupWriteOutcome` enum that
                            // distinguishes:
                            //   - `.completedLocal(url)`: a
                            //     non-iCloud destination (Files
                            //     app folder, external drive,
                            //     app sandbox folder). The local
                            //     write is durable; the existing
                            //     green success toast is the
                            //     correct user signal.
                            //   - `.submittedToCloud(url)`: an
                            //     iCloud-managed destination.
                            //     The local staging file write
                            //     has been verified, but iCloud
                            //     upload is asynchronous and has
                            //     NOT yet completed. We surface
                            //     a MODAL dialog with an OK
                            //     button instead of a toast so
                            //     the user must explicitly
                            //     acknowledge the upload has
                            //     been *submitted*, not
                            //     completed. This protects
                            //     against the failure mode where
                            //     the user reads the green
                            //     toast, assumes the backup is
                            //     fully durable in iCloud, and
                            //     immediately wipes the device /
                            //     loses the device / suffers a
                            //     power loss before the File
                            //     Provider extension finishes
                            //     uploading.
                            //   - `.failed`: writer already
                            //     surfaced its own error toast;
                            //     no further user action.
                            // Why a modal (not just a longer
                            // toast):
                            //   Toasts auto-dismiss and are
                            //   easy to miss. A modal "OK"
                            //   button forces the user to read
                            //   the message and consciously
                            //   acknowledge the
                            //   "submitted, not yet uploaded"
                            //   semantics before continuing.
                            // Cross-references:
                            //   - `CloudBackupManager.writeWalletFile`
                            //   - `CloudBackupManager.formatBackupSubmittedToCloudMessage`
                            //   - `MessageInformationDialogViewController`
                            let outcome = CloudBackupManager.shared.writeWalletFile(
                                address: address, walletJson: json)
                            switch outcome {
                                case .completedLocal(let url):
                                Toast.showMessage(
                                    CloudBackupManager.formatBackupSavedMessage(forURL: url))
                                case .submittedToCloud(let url):
                                guard let presenter = presenter else { return }
                                let dialog = MessageInformationDialogViewController(
                                    title: Localization.shared.getBackupSubmittedCloudTitleByLangValues(),
                                    message: CloudBackupManager.formatBackupSubmittedToCloudMessage(forURL: url),
                                    icon: UIImage(systemName: "icloud.and.arrow.up"),
                                    iconTint: .systemBlue,
                                    closeTitle: Localization.shared.getOkByLangValues())
                                presenter.present(dialog, animated: true)
                                case .failed:
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bridge envelope helpers

    /// JSON-encode the `walletInput` payload that
    /// `bridge.html#encryptWalletJson` expects for the seed-words
    /// branch. The matching key-bytes branch lives behind the
    /// `JsBridge.encryptWalletJson(privateKey:publicKey:password:)`
    /// overload, which stages the bytes on the binary channel and
    /// sets `walletInput` to the `{"fromBinaryKeys":true}`
    /// discriminator directly — so this helper is only invoked
    /// from `.seedWords` payloads.
    static func encodeWalletInput(seedWords: [String]) -> String {
        let walletInput: [String: Any] = ["seedWords": seedWords]
        guard let data = try? JSONSerialization.data(withJSONObject: walletInput),
        let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    /// Extract the already-encrypted wallet JSON from `encryptWalletJson`'s
    /// bridge envelope. The bridge returns the payload under the key `json`
    /// (see bridge.html lines 375 / 383). The bridge sometimes returns the
    /// payload as a JSON-string and sometimes as a nested object (depending
    /// on platform); accept both shapes so the caller always gets a string.
    static func extractEncryptedJson(_ envelope: String) -> String? {
        guard let data = envelope.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let inner = obj["data"] as? [String: Any]
        else { return nil }
        if let s = inner["json"] as? String { return s }
        if let o = inner["json"] as? [String: Any],
        let d = try? JSONSerialization.data(withJSONObject: o),
        let s = String(data: d, encoding: .utf8) { return s }
        return nil
    }

    /// Note: previously this file exposed
    /// `extractSeedWords(fromDecryptEnvelope:)` and
    /// `extractRecoveredAddress(fromDecryptEnvelope:)` which parsed
    /// `JsBridge.decryptWalletJson`'s legacy JSON envelope.
    /// That helper was moved into `JsBridge.WalletEnvelope`
    /// (a Swift struct with `Data`-typed key material), so callers
    /// now read `.seedWords` / `.address` directly off the
    /// envelope without parsing JSON, and the binary key bytes
    /// can be `resetBytes`-zeroized as soon as they leave scope.
}
