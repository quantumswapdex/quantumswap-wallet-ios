// TxStepsDialogViewController.swift
// iOS port of the desktop transaction-steps dialog (#modalTxSteps,
// src/app/txsteps.ts + txflow.ts) — identical to Android's
// view/dialog/TxStepsDialog.java:
//
//  * Each step: pending (number) → active (spinner, gas estimating) →
//    ready (number, teal row) → [review dialog: fields + "i agree" →
//    unlock] → submitting (spinner, "Submitting...") → confirming
//    (spinner, "Confirming...", scan-API poll) → done (✓) or failed (✕,
//    "Close", no retry).
//  * The footer button carries the step label and is DISABLED while a
//    step executes; "Ok" when everything is done.
//  * Gas chip in the header: pulsing pump while estimating, then the
//    fee; tapping it opens the gas-config dialog. Hidden the moment
//    submission starts.
//  * "Please wait, this can take up to a minute..." from submission
//    start until confirmation; Transaction ID row with copy and
//    block-explorer buttons.
//  * × always dismisses (stops watching; nothing on-chain is
//    cancelled). `onClose` runs on every exit; `onAllDone` runs while
//    the dialog is still open and may contribute a result view.

import UIKit

public struct TxStep {
    public let label: String
    public let kind: GasKind
    public let pairExists: Bool
    /// Kind-specific gas-estimate fields (chain fields are overlaid by
    /// the dialog from its open-time snapshot).
    public let estimatePayload: () -> [String: Any]
    /// Bridge submit method + its kind-specific payload (keys, chain
    /// snapshot and gasLimit are added by the dialog).
    public let submitMethod: String
    public let submitPayload: () -> [String: Any]
    public let reviewOverride: ReviewSpec?
    /// Sees the bridge echo of a successful estimate (never a fallback),
    /// so a screen can react to what the estimate decided -- e.g. the
    /// swap screen restarting when the bridge reports an exact-in
    /// fallback. May dismiss the dialog.
    public let onEstimated: (([String: Any]) -> Void)?

    public init(label: String, kind: GasKind, pairExists: Bool = true,
                estimatePayload: @escaping () -> [String: Any],
                submitMethod: String, submitPayload: @escaping () -> [String: Any],
                reviewOverride: ReviewSpec? = nil,
                onEstimated: (([String: Any]) -> Void)? = nil) {
        self.label = label
        self.kind = kind
        self.pairExists = pairExists
        self.estimatePayload = estimatePayload
        self.submitMethod = submitMethod
        self.submitPayload = submitPayload
        self.reviewOverride = reviewOverride
        self.onEstimated = onEstimated
    }
}

@MainActor
public final class TxStepsDialogViewController: ModalDialogViewController {

    public enum State { case pending, active, ready, confirming, done, failed }

    /// Desktop TX_STEPS_POLL_INTERVAL_MS / TX_STEPS_MAX_POLLS.
    public static let pollIntervalMs = 5000
    public static let maxPolls = 120

    /// Receives the last submit response (txHash, contractAddress...)
    /// and may return a result view shown above the footer.
    public var onAllDone: (([String: Any]) -> UIView?)?
    /// Runs exactly once on every exit.
    public var onClose: (() -> Void)?

    private let dialogTitle: String
    private let walletAddress: String
    private let steps: [TxStep]
    private let baseReview: ReviewSpec
    private let chainSnapshot: [String: Any]

    // Chrome
    private let waitLabel = UILabel()
    private let gasChip = GasChipView()
    private let stepsStack = UIStackView()
    private let hashRow = UIStackView()
    private let hashLabel = UILabel()
    private let hashValueView = UITextView()
    private let resultBlock = UIStackView()
    private let errorLabel = UILabel()
    private let footerSpinner = UIActivityIndicatorView(style: .medium)
    private let actionButton = GreenPillButton(type: .system)
    private var rows: [TxStepRowView] = []

    // State machine
    private var states: [State]
    private var current = 0
    private var runId = 0
    private var running = false
    private var prepareInFlight = false
    private var gasToken = 0
    private var stepGasLimit: Int64 = 0
    private var stepFeeNumber = ""
    private var currentTxHash: String?
    private var lastResponse: [String: Any] = [:]
    private var footerAction: (() -> Void)?
    private var prepareWaiter: (() -> Void)?
    private var poller: TxStatusPoller?
    private weak var reviewDialog: UIViewController?
    private var closed = false

    public init(title: String, walletAddress: String, steps: [TxStep], baseReview: ReviewSpec) {
        self.dialogTitle = title
        self.walletAddress = walletAddress
        self.steps = steps
        self.baseReview = baseReview
        self.states = Array(repeating: .pending, count: steps.count)
        self.chainSnapshot = DexPayloads.chainSnapshot()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    public func show(from host: UIViewController) {
        host.present(self, animated: true)
    }

    // MARK: - Layout

    public override func viewDidLoad() {
        super.viewDidLoad()
        let L = Localization.shared
        CardStyle.applyDexDialog(to: card)

        let title = UILabel()
        title.text = dialogTitle
        title.font = Typography.boldTitle(18)
        title.textColor = .white
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        gasChip.isHidden = true
        gasChip.onTap = { [weak self] in self?.onGasIconTap() }
        let close = UIButton(type: .system)
        close.setTitle("×", for: .normal)
        close.titleLabel?.font = Typography.body(25)
        close.setTitleColor(.white, for: .normal)
        close.widthAnchor.constraint(equalToConstant: 32).isActive = true
        close.heightAnchor.constraint(equalToConstant: 32).isActive = true
        close.addTarget(self, action: #selector(tapClose), for: .touchUpInside)
        let titleRow = UIStackView(arrangedSubviews: [title, gasChip, close])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        waitLabel.text = L.lang("tx-step-please-wait", fallback: "Please wait, this can take up to a minute...")
        waitLabel.font = Typography.body(13)
        waitLabel.textColor = .white
        waitLabel.numberOfLines = 0
        waitLabel.isHidden = true

        stepsStack.axis = .vertical
        stepsStack.spacing = 6
        for s in steps {
            let row = TxStepRowView(label: s.label)
            rows.append(row)
            stepsStack.addArrangedSubview(row)
        }

        hashLabel.text = L.lang("transaction-id", fallback: "Transaction ID")
        hashLabel.font = Typography.boldTitle(13)
        hashLabel.textColor = .white
        hashLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let hashButtons = IconButton.copyAndExplorer(
            copyValue: { [weak self] in self?.currentTxHash },
            explorerUrl: { [weak self] in self.flatMap { $0.currentTxHash }.flatMap { UrlBuilder.txUrl($0) } })
        let hashHeader = UIStackView(arrangedSubviews: [hashLabel, hashButtons])
        hashHeader.axis = .horizontal
        hashHeader.alignment = .center
        hashValueView.isEditable = false
        hashValueView.isScrollEnabled = false
        hashValueView.backgroundColor = .clear
        hashValueView.textContainerInset = .zero
        hashValueView.textContainer.lineFragmentPadding = 0
        hashValueView.textContainer.lineBreakMode = .byCharWrapping
        hashValueView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hashValueView.textColor = UIColor(named: "colorCommon6") ?? .white
        hashRow.axis = .vertical
        hashRow.spacing = 4
        hashRow.addArrangedSubview(hashHeader)
        hashRow.addArrangedSubview(hashValueView)
        hashRow.isHidden = true

        resultBlock.axis = .vertical
        resultBlock.isHidden = true

        errorLabel.font = Typography.body(12)
        errorLabel.textColor = UIColor(rgbHex: 0xDC2626)
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        footerSpinner.color = UIColor(rgbHex: 0xC4B5FD)
        footerSpinner.hidesWhenStopped = true
        actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        actionButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        actionButton.addTarget(self, action: #selector(tapAction), for: .touchUpInside)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = UIStackView(arrangedSubviews: [spacer, footerSpinner, actionButton])
        footer.axis = .horizontal
        footer.spacing = 8
        footer.alignment = .center

        let stack = UIStackView(arrangedSubviews: [titleRow, waitLabel, stepsStack, hashRow,
                                                   resultBlock, errorLabel, footer])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: errorLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            card.widthAnchor.constraint(equalToConstant: 340)
        ])
        view.installPressFeedbackRecursive()

        runId += 1
        if !states.isEmpty { states[0] = .active }
        render()
        setHash(nil)
        setError(nil)
        setButton(L.lang("close", fallback: "Close"), enabled: true, spinning: false)
        footerAction = { [weak self] in self?.dismissSteps() }
        hideGas()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if current == 0 && !running && !prepareInFlight && stepGasLimit == 0 {
            prepareCurrent()
        }
    }

    // MARK: - Lifecycle

    /// Desktop closeTxStepsDialog: abandon in-flight work, close, fire
    /// onClose exactly once.
    public func dismissSteps() {
        guard !closed else { return }
        closed = true
        runId += 1
        poller?.cancel()
        poller = nil
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.dismiss(animated: true) { self.onClose?() }
        }
        if let review = reviewDialog {
            review.dismiss(animated: false, completion: finish)
        } else {
            finish()
        }
    }

    private func stale(_ id: Int) -> Bool { id != runId || closed }

    @objc private func tapClose() { dismissSteps() }

    @objc private func tapAction() { footerAction?() }

    // MARK: - Step machine

    /// Desktop prepareCurrent: spinner + pulsing gas chip while the
    /// step's gas is estimated; ready when it lands.
    private func prepareCurrent() {
        let id = runId
        guard current < steps.count else { finishAll(); return }
        let step = steps[current]
        states[current] = .active
        setHash(nil)
        setError(nil)
        waitLabel.isHidden = true
        render()
        gasChip.isHidden = false
        gasChip.setFeeText("")
        GasIconPulse.start(gasChip.iconView)
        stepGasLimit = 0
        stepFeeNumber = ""
        gasToken += 1
        let token = gasToken
        setButton(step.label, enabled: true, spinning: false)
        footerAction = { [weak self] in self?.runCurrent() }

        prepareInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let result = await GasEstimator.estimate(walletAddress: self.walletAddress, kind: step.kind,
                                                     payload: step.estimatePayload(),
                                                     pairExists: step.pairExists,
                                                     snapshot: self.chainSnapshot)
            guard !self.stale(id) else { return }
            self.prepareInFlight = false
            if token == self.gasToken {
                self.stepGasLimit = result.gasLimit
                self.stepFeeNumber = result.feeNumber
                self.gasChip.setFeeText(GasFee.formatQ(result.feeNumber))
                if result.usedFallback {
                    // The estimate failed (typically the node's revert reason)
                    // and the kind default was substituted. Say so, show the
                    // returned error, and point at the gas icon: silently
                    // submitting with the default limit is how a swap ran out
                    // of gas on-chain with no hint of the underlying revert.
                    let L = Localization.shared
                    var notice = L.err("gasEstimateError",
                        fallback: "Could not fetch the gas fee from the network. Using the default estimate.")
                    if let e = result.error?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty {
                        notice += " " + e
                    }
                    notice += " " + L.lang("gas-set-manually-hint",
                        fallback: "Tap the gas icon to set the gas limit manually.")
                    self.setError(notice)
                } else if let hook = step.onEstimated {
                    hook(result.extra)
                    if self.stale(id) { return }      // the hook may have dismissed
                }
            }
            GasIconPulse.stop(self.gasChip.iconView)
            if self.states[self.current] == .active { self.states[self.current] = .ready }
            self.render()
            let w = self.prepareWaiter
            self.prepareWaiter = nil
            w?()
        }
    }

    /// Desktop runCurrent: the footer click for the current step.
    private func runCurrent() {
        let id = runId
        let L = Localization.shared
        guard !running, current < steps.count, !stale(id) else { return }
        if prepareInFlight {
            // Click before the estimate landed -> wait for it.
            let wait = WaitDialogViewController(message: L.lang("pleaseWaitEstimatingGas",
                                                                 fallback: "Please wait, estimating gas..."))
            present(wait, animated: true)
            prepareWaiter = { [weak self, weak wait] in
                wait?.dismiss(animated: true) {
                    guard let self, !self.stale(id) else { return }
                    self.runCurrent()
                }
            }
            return
        }
        guard stepGasLimit > 0, !stepFeeNumber.isEmpty else {
            failCurrent(L.lang("tx-step-invalid-gas", fallback: "Enter a valid positive gas limit."))
            return
        }
        running = true
        let step = steps[current]
        setButton(step.label, enabled: false, spinning: false)
        footerAction = nil

        let spec = baseReview.mergeOver(step.reviewOverride).gas(stepGasLimit, GasFee.formatQ(stepFeeNumber))
        let review = TransactionReviewDialogViewController(spec: spec, walletAddress: walletAddress)
        review.onCredentials = { [weak self] credentials in
            guard let self, !self.stale(id) else { return }
            self.reviewDialog = nil
            self.onSubmitting()
            self.submit(step: step, credentials: credentials, id: id)
        }
        review.onCancel = { [weak self] in
            guard let self, !self.stale(id) else { return }
            self.reviewDialog = nil
            self.running = false
            self.states[self.current] = .ready
            self.render()
            self.setButton(step.label, enabled: true, spinning: false)
            self.footerAction = { [weak self] in self?.runCurrent() }
        }
        reviewDialog = review
        present(review, animated: true)
    }

    private func submit(step: TxStep, credentials: Credentials, id: Int) {
        var creds = credentials
        let gasLimit = stepGasLimit
        var keyed = DexPayloads.withKeys(privKey: creds.privateKey, pubKey: creds.publicKey)
        DexPayloads.overlay(&keyed.payload, chainSnapshot)
        DexPayloads.overlay(&keyed.payload, step.submitPayload())
        keyed.payload["gasLimit"] = gasLimit
        let method = step.submitMethod
        let payload = keyed.payload
        let priv = keyed.privKey
        let pub = keyed.pubKey
        Task { [weak self] in
            defer { creds.wipe() }
            do {
                let json = try await JsBridge.shared.dexCallAsync(method: method, payload: payload,
                                                                  privKey: priv, pubKey: pub)
                let data = try DexBridgeResult.unwrapData(json)
                guard let hash = data["txHash"] as? String, !hash.isEmpty else {
                    throw JsEngineError.callFailed("No transaction hash returned")
                }
                guard let self, !self.stale(id) else { return }
                self.lastResponse = data
                self.onSubmitted(txHash: hash)
            } catch {
                guard let self, !self.stale(id) else { return }
                self.failCurrent(DexBridgeResult.sanitizeError(error.localizedDescription))
            }
        }
    }

    /// Desktop onSubmitting.
    private func onSubmitting() {
        states[current] = .active
        render()
        hideGas()
        waitLabel.isHidden = false
        setButton(Localization.shared.lang("tx-step-submitting", fallback: "Submitting..."),
                  enabled: false, spinning: true)
    }

    private func onSubmitted(txHash: String) {
        let id = runId
        let L = Localization.shared
        states[current] = .confirming
        render()
        setHash(txHash)
        setButton(L.lang("tx-step-confirming", fallback: "Confirming..."), enabled: false, spinning: true)
        poller = TxStatusPoller.start(address: walletAddress, txHash: txHash,
            intervalMs: TxStepsDialogViewController.pollIntervalMs,
            maxPolls: TxStepsDialogViewController.maxPolls, sleepFirst: true,
            listener: TxStatusPoller.Listener(
                onSucceeded: { [weak self] in
                    guard let self, !self.stale(id) else { return }
                    self.poller = nil
                    self.waitLabel.isHidden = true
                    self.states[self.current] = .done
                    self.render()
                    self.current += 1
                    self.running = false
                    self.prepareCurrent()
                },
                onFailed: { [weak self] message in
                    guard let self, !self.stale(id) else { return }
                    self.poller = nil
                    self.failCurrent(message ?? L.lang("tx-step-failed-onchain",
                                                       fallback: "The transaction failed on-chain."))
                },
                onTimeout: { [weak self] in
                    guard let self, !self.stale(id) else { return }
                    self.poller = nil
                    self.failCurrent(L.lang("tx-step-timeout",
                        fallback: "Timed out waiting for the transaction to confirm. Check the block explorer before retrying."))
                }))
    }

    /// Desktop failCurrent: terminal, footer "Close", no retry.
    private func failCurrent(_ message: String?) {
        let L = Localization.shared
        running = false
        prepareInFlight = false
        waitLabel.isHidden = true
        if current < states.count { states[current] = .failed }
        render()
        setError(L.lang("tx-step-failed", fallback: "Step failed.") + " " + (message ?? ""))
        setButton(L.lang("close", fallback: "Close"), enabled: true, spinning: false)
        footerAction = { [weak self] in self?.dismissSteps() }
    }

    /// Desktop finishAll.
    private func finishAll() {
        hideGas()
        waitLabel.isHidden = true
        if let view = onAllDone?(lastResponse) {
            resultBlock.arrangedSubviews.forEach { $0.removeFromSuperview() }
            resultBlock.addArrangedSubview(view)
            resultBlock.isHidden = false
        }
        setButton(Localization.shared.getOkByLangValues(), enabled: true, spinning: false)
        footerAction = { [weak self] in self?.dismissSteps() }
    }

    // MARK: - Gas chip

    private func hideGas() {
        gasChip.isHidden = true
        gasChip.setFeeText("")
        GasIconPulse.stop(gasChip.iconView)
    }

    private func onGasIconTap() {
        // No estimate yet (or a failed one): open the editor pre-filled with the
        // kind default rather than doing nothing -- that is exactly when the
        // user needs to set the limit by hand. Same fallback GasChipController uses.
        var limit = stepGasLimit
        var fee = stepFeeNumber
        if limit <= 0 || fee.isEmpty {
            guard current >= 0, current < steps.count else { return }
            let s = steps[current]
            limit = s.kind.defaultFor(pairExists: s.pairExists)
            fee = GasFee.feeNumberFor(gasLimit: limit, address: walletAddress)
        }
        let dlg = GasConfigDialogViewController(gasLimit: limit, feeNumber: fee)
        dlg.onOk = { [weak self] limit, fee in
            guard let self else { return }
            self.gasToken += 1
            self.stepGasLimit = limit
            self.stepFeeNumber = fee
            self.gasChip.setFeeText(GasFee.formatQ(fee))
        }
        present(dlg, animated: true)
    }

    // MARK: - Rendering

    private func render() {
        for (i, row) in rows.enumerated() {
            row.apply(state: states[i], index: i)
        }
    }

    private func setButton(_ text: String, enabled: Bool, spinning: Bool) {
        actionButton.setTitle(text, for: .normal)
        actionButton.isEnabled = enabled
        actionButton.alpha = enabled ? 1 : 0.55
        if spinning { footerSpinner.startAnimating() } else { footerSpinner.stopAnimating() }
    }

    private func setHash(_ txHash: String?) {
        currentTxHash = txHash
        hashValueView.text = txHash ?? ""
        hashRow.isHidden = txHash == nil
    }

    private func setError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = (message ?? "").isEmpty
    }
}

// MARK: - Step row

/// Desktop .tx-step row: 22pt badge (number / spinner / ✓ / ✕) + label
/// + substatus, tinted per state (Android tx_step_row.xml +
/// tx_step_row_bg_{pending,active,ready}.xml).
final class TxStepRowView: UIView {
    private let badge = UILabel()
    private let badgeBg = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let substatus = UILabel()

    init(label text: String) {
        super.init(frame: .zero)
        layer.cornerRadius = 9
        layer.borderWidth = 1
        layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        badgeBg.layer.cornerRadius = 11
        badgeBg.translatesAutoresizingMaskIntoConstraints = false
        badge.font = Typography.boldTitle(12)
        badge.textAlignment = .center
        badge.textColor = .white
        badge.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = UIColor(rgbHex: 0xC4B5FD)
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        badgeBg.addSubview(badge)
        badgeBg.addSubview(spinner)

        label.text = text
        label.font = Typography.body(14)
        label.textColor = .white
        substatus.font = Typography.body(12)
        substatus.textColor = UIColor(argbHex: 0xBFFFFFFF)
        substatus.isHidden = true
        let text = UIStackView(arrangedSubviews: [label, substatus, UIView()])
        text.axis = .horizontal
        text.spacing = 6
        text.alignment = .center

        let row = UIStackView(arrangedSubviews: [badgeBg, text])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            badgeBg.widthAnchor.constraint(equalToConstant: 22),
            badgeBg.heightAnchor.constraint(equalToConstant: 22),
            badge.centerXAnchor.constraint(equalTo: badgeBg.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: badgeBg.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: badgeBg.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: badgeBg.centerYAnchor),
            row.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(state: TxStepsDialogViewController.State, index: Int) {
        spinner.stopAnimating()
        substatus.isHidden = true
        badge.isHidden = false
        label.textColor = .white
        badge.textColor = .white
        layer.borderColor = UIColor.clear.cgColor
        switch state {
        case .active, .confirming:
            backgroundColor = UIColor(argbHex: 0x38724EDB)
            layer.borderColor = UIColor(argbHex: 0x8C724EDB).cgColor
            badge.text = ""
            badgeBg.backgroundColor = UIColor(argbHex: 0x73724EDB)
            spinner.startAnimating()
            if state == .confirming {
                substatus.text = Localization.shared.lang("tx-step-confirming", fallback: "Confirming...")
                substatus.isHidden = false
            }
        case .ready:
            backgroundColor = UIColor(argbHex: 0x470D9488)
            layer.borderColor = UIColor(argbHex: 0xB82DD4BF).cgColor
            badge.text = String(index + 1)
            badgeBg.backgroundColor = UIColor(argbHex: 0xA60D9488)
        case .done:
            backgroundColor = UIColor(argbHex: 0x0FFFFFFF)
            badge.text = "✓"
            badge.textColor = UIColor(rgbHex: 0x16A34A)
            badgeBg.backgroundColor = UIColor(argbHex: 0x2E16A34A)
            label.textColor = UIColor(argbHex: 0xBFFFFFFF)
        case .failed:
            backgroundColor = UIColor(argbHex: 0x0FFFFFFF)
            badge.text = "✕"
            badge.textColor = UIColor(rgbHex: 0xDC2626)
            badgeBg.backgroundColor = UIColor(argbHex: 0x2EDC2626)
            label.textColor = UIColor(rgbHex: 0xDC2626)
        case .pending:
            backgroundColor = UIColor(argbHex: 0x0FFFFFFF)
            badge.text = String(index + 1)
            badgeBg.backgroundColor = UIColor(argbHex: 0x1FFFFFFF)
        }
    }
}
