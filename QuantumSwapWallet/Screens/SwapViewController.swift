// SwapViewController.swift
// Port of Android `SwapFragment.java`: quote via swapGetAmountsOut,
// execute approve + swap through the pull-model DEX bridge.

import UIKit

public final class SwapViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private static let approvalPollMax = 24
    private static let approvalPollIntervalNs: UInt64 = 5_000_000_000

    private var walletAddress = ""
    private var fromPicker: DexTokenPickerView!
    private var toPicker: DexTokenPickerView!
    private let amountInField = DexScreenChrome.makeField(
        placeholder: "", keyboard: .decimalPad)
    private let slippageField = DexScreenChrome.makeField(
        placeholder: "1", keyboard: .decimalPad)
    private let amountOutLabel = UILabel()
    private let routeLabel = UILabel()
    private let statusLabel = UILabel()
    private let quoteButton = GreenPillButton(type: .system)
    private let swapButton = GreenPillButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var lastQuotedAmountOut: String?
    private var flowInFlight = false
    private var didShowEarlyWarn = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "colorBackground") ?? .systemBackground
        let L = Localization.shared
        walletAddress = DexScreenChrome.currentWalletAddress()

        let backBar = makeBackBar(action: #selector(tapBack))
        let title = UILabel()
        title.text = L.lang("swap", fallback: "Swap")
        title.font = Typography.boldTitle(20)
        title.textColor = UIColor(named: "colorCommon6") ?? .label

        let releaseBanner = UILabel()
        releaseBanner.font = Typography.body(12)
        releaseBanner.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel
        releaseBanner.numberOfLines = 0
        let active = ReleaseStore.readActive()
        if !active.builtin {
            releaseBanner.text = L.lang("custom-release-banner-prefix",
                fallback: "Custom release contracts: ") + active.name
        } else {
            releaseBanner.isHidden = true
        }

        let customLabel = L.lang("custom-contract-address", fallback: "Custom...")
        fromPicker = DexTokenPickerView(customLabel: customLabel)
        toPicker = DexTokenPickerView(customLabel: customLabel)
        let clearQuote: () -> Void = { [weak self] in
            self?.lastQuotedAmountOut = nil
            self?.amountOutLabel.text = "-"
            self?.routeLabel.isHidden = true
        }
        fromPicker.onChanged = clearQuote
        toPicker.onChanged = clearQuote

        amountInField.placeholder = L.lang("swap-from-quantity", fallback: "From quantity")
        slippageField.text = "1"
        amountOutLabel.text = "-"
        amountOutLabel.font = Typography.body(16)
        amountOutLabel.textColor = UIColor(named: "colorCommon6") ?? .label

        routeLabel.font = Typography.body(12)
        routeLabel.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel
        routeLabel.numberOfLines = 0
        routeLabel.isHidden = true

        statusLabel.font = Typography.body(12)
        statusLabel.textColor = UIColor(named: "colorCommon10") ?? .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true

        quoteButton.setTitle(L.lang("get-quote", fallback: "Get Quote"), for: .normal)
        quoteButton.addTarget(self, action: #selector(requestQuote), for: .touchUpInside)
        swapButton.setTitle(L.lang("swap", fallback: "Swap"), for: .normal)
        swapButton.addTarget(self, action: #selector(startSwap), for: .touchUpInside)
        spinner.hidesWhenStopped = true

        let buttonRow = UIStackView(arrangedSubviews: [quoteButton, swapButton, spinner])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .center

        let content = UIStackView(arrangedSubviews: [
            backBar, title, DexScreenChrome.makeDivider(), releaseBanner,
            DexScreenChrome.makeLabel(L.lang("swap-from-token", fallback: "From token")),
            fromPicker,
            DexScreenChrome.makeLabel(L.lang("swap-to-token", fallback: "To token")),
            toPicker,
            DexScreenChrome.makeLabel(L.lang("swap-from-quantity", fallback: "From quantity")),
            amountInField,
            DexScreenChrome.makeLabel(L.lang("swap-to-quantity", fallback: "To quantity")),
            amountOutLabel,
            routeLabel,
            DexScreenChrome.makeLabel(L.lang("slippage", fallback: "Slippage")),
            slippageField,
            buttonRow,
            statusLabel
        ])
        content.axis = .vertical
        content.spacing = 10
        content.setCustomSpacing(8, after: backBar)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24)
        ])

        Task { [weak self] in
            guard let self else { return }
            let tokens = await DexScreenChrome.loadRecognizedTokens(for: self.walletAddress)
            await MainActor.run {
                self.fromPicker.setTokens(tokens)
                self.toPicker.setTokens(tokens)
            }
        }

        view.installPressFeedbackRecursive()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didShowEarlyWarn else { return }
        didShowEarlyWarn = true
        let L = Localization.shared
        let warn = ConfirmDialogViewController(
            title: L.lang("swap", fallback: "Swap"),
            message: L.lang("swapEarlyPhaseWarn",
                fallback: "This is a feature still in early phases of testing. Do you want to continue?"))
        warn.onCancel = { [weak self] in
            (self?.parent as? HomeViewController)?.showMain()
        }
        present(warn, animated: true)
    }

    @objc private func tapBack() {
        (parent as? HomeViewController)?.showMain()
    }

    // MARK: - Quote

    @objc private func requestQuote() {
        let amountIn = text(amountInField)
        guard validateInputs(amountIn) else { return }
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.resolveMeta(self.fromPicker)
                try await self.resolveMeta(self.toPicker)
                try await self.doQuote(amountIn: amountIn)
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func resolveMeta(_ picker: DexTokenPickerView) async throws {
        guard picker.needsMetadata() else { return }
        let addr = picker.tokenValue()
        var payload = DexPayloads.base()
        payload["contractAddress"] = addr
        payload["ownerAddress"] = walletAddress
        let json = try await JsBridge.shared.dexCallAsync(
            method: "swapGetTokenMetadata", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        let symbol = (data["symbol"] as? String) ?? ""
        let decimals = (data["decimals"] as? Int)
            ?? (data["decimals"] as? NSNumber)?.intValue ?? 18
        let contract = (data["contractAddress"] as? String) ?? addr
        await MainActor.run {
            picker.setResolvedMeta(address: contract, symbol: symbol, decimals: decimals)
        }
    }

    private func doQuote(amountIn: String) async throws {
        var payload = DexPayloads.base()
        payload["fromTokenValue"] = fromPicker.tokenValue()
        payload["toTokenValue"] = toPicker.tokenValue()
        payload["fromDecimals"] = fromPicker.decimals()
        payload["toDecimals"] = toPicker.decimals()
        payload["amountIn"] = amountIn
        let json = try await JsBridge.shared.dexCallAsync(
            method: "swapGetAmountsOut", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        let out = (data["amountOut"] as? String) ?? ""
        await MainActor.run {
            self.lastQuotedAmountOut = out
            self.amountOutLabel.text = out.isEmpty ? "-" : out
        }
        try await fetchRoute()
    }

    private func fetchRoute() async throws {
        var payload = DexPayloads.base()
        payload["fromTokenValue"] = fromPicker.tokenValue()
        payload["toTokenValue"] = toPicker.tokenValue()
        let json = try await JsBridge.shared.dexCallAsync(
            method: "swapCheckPairExists", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        let exists = (data["exists"] as? Bool) ?? false
        let path = data["path"] as? [Any]
        let symbols = data["pathSymbols"] as? [Any]
        await MainActor.run {
            self.setBusy(false)
            guard exists, let path, !path.isEmpty else {
                self.routeLabel.isHidden = true
                return
            }
            let L = Localization.shared
            var parts: [String] = []
            for i in 0..<path.count {
                let sym = (symbols?[safe: i] as? String)
                let addr = (path[i] as? String) ?? ""
                if let sym, !sym.isEmpty, sym != "null" {
                    parts.append(DexBridgeResult.sanitizeSymbol(sym))
                } else {
                    parts.append(DexBridgeResult.shortAddr(addr))
                }
            }
            self.routeLabel.text = L.lang("swap-route", fallback: "Route")
                + ": " + parts.joined(separator: " > ")
            self.routeLabel.isHidden = false
        }
    }

    // MARK: - Swap execute

    @objc private func startSwap() {
        let L = Localization.shared
        let amountIn = text(amountInField)
        guard validateInputs(amountIn) else { return }
        if lastQuotedAmountOut == nil || lastQuotedAmountOut?.isEmpty == true {
            requestQuote()
            return
        }
        if flowInFlight { return }

        let message = L.lang("swap-execute-confirm-message",
            fallback: "You are swapping [FROM_AMOUNT] [FROM_SYMBOL] for at least [TO_AMOUNT] [TO_SYMBOL].")
            .replacingOccurrences(of: "[FROM_AMOUNT]", with: amountIn)
            .replacingOccurrences(of: "[FROM_SYMBOL]",
                with: DexBridgeResult.sanitizeSymbol(fromPicker.symbol()))
            .replacingOccurrences(of: "[TO_AMOUNT]", with: minOutForDisplay())
            .replacingOccurrences(of: "[TO_SYMBOL]",
                with: DexBridgeResult.sanitizeSymbol(toPicker.symbol()))

        let confirm = ConfirmDialogViewController(
            title: L.lang("swap", fallback: "Swap"), message: message)
        confirm.onConfirm = { [weak self] in
            guard let self else { return }
            DexUnlockPrompt.show(from: self) { [weak self] _ in
                self?.runSwapFlow()
            }
        }
        present(confirm, animated: true)
    }

    private func runSwapFlow() {
        flowInFlight = true
        setBusy(true)
        let address = walletAddress
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try DexUnlockPrompt.loadWalletKeys(walletAddress: address)
                var priv = loaded.0
                var pub = loaded.1
                defer {
                    priv.resetBytes(in: 0..<priv.count)
                    pub.resetBytes(in: 0..<pub.count)
                }
                try await self.checkAllowanceThen(priv: priv, pub: pub)
            } catch {
                await MainActor.run { self.failFlow("\(error)") }
            }
        }
    }

    private func checkAllowanceThen(priv: Data, pub: Data) async throws {
        var payload = DexPayloads.base()
        payload["fromTokenValue"] = fromPicker.tokenValue()
        payload["fromDecimals"] = fromPicker.decimals()
        payload["requiredAmount"] = text(amountInField)
        payload["ownerAddress"] = walletAddress
        let json = try await JsBridge.shared.dexCallAsync(
            method: "swapCheckAllowance", payload: payload)
        let data = try DexBridgeResult.unwrapData(json)
        let sufficient = (data["sufficient"] as? Bool) ?? false
        if sufficient {
            try await estimateAndSubmitSwap(priv: priv, pub: pub)
        } else {
            try await confirmApproval(priv: priv, pub: pub)
        }
    }

    private func confirmApproval(priv: Data, pub: Data) async throws {
        let L = Localization.shared
        let message = L.lang("swap-approval-confirm-message",
            fallback: "You are approving [QUANTITY] tokens for use in QuantumSwap.")
            .replacingOccurrences(of: "[QUANTITY]", with: text(amountInField))
        let approved: Bool = await withCheckedContinuation { cont in
            Task { @MainActor in
                let dlg = ConfirmDialogViewController(
                    title: L.lang("approve", fallback: "Approve"), message: message)
                dlg.onConfirm = { cont.resume(returning: true) }
                dlg.onCancel = { cont.resume(returning: false) }
                self.present(dlg, animated: true)
            }
        }
        if !approved {
            await MainActor.run { self.failFlow(nil) }
            return
        }
        try await submitApproval(priv: priv, pub: pub)
    }

    private func submitApproval(priv: Data, pub: Data) async throws {
        await MainActor.run {
            self.setStatus(Localization.shared.lang("swap-approval-status-wait",
                fallback: "Please wait, checking..."))
        }
        var estimate = DexPayloads.base()
        estimate["fromTokenValue"] = fromPicker.tokenValue()
        estimate["fromDecimals"] = fromPicker.decimals()
        estimate["amount"] = text(amountInField)
        estimate["fromAddress"] = walletAddress
        var gasLimit: Int64 = 84_000
        do {
            let estJson = try await JsBridge.shared.dexCallAsync(
                method: "swapEstimateApproveGas", payload: estimate)
            gasLimit = DexBridgeResult.parseGas(estJson, fallback: 84_000)
        } catch {
            gasLimit = 84_000
        }
        var keyed = DexPayloads.withKeys(privKey: priv, pubKey: pub)
        keyed.payload["fromTokenValue"] = fromPicker.tokenValue()
        keyed.payload["fromDecimals"] = fromPicker.decimals()
        keyed.payload["amount"] = text(amountInField)
        keyed.payload["gasLimit"] = Int(gasLimit)
        _ = try await JsBridge.shared.dexCallAsync(
            method: "swapSubmitApproval", payload: keyed.payload,
            privKey: keyed.privKey, pubKey: keyed.pubKey)
        await MainActor.run {
            self.setStatus(Localization.shared.lang("swap-approval-status-pending",
                fallback: "Transaction is still pending..."))
        }
        try await pollAllowance(priv: priv, pub: pub, attempt: 0)
    }

    private func pollAllowance(priv: Data, pub: Data, attempt: Int) async throws {
        let L = Localization.shared
        if attempt >= Self.approvalPollMax {
            await MainActor.run {
                self.failFlow(L.lang("swap-approval-may-close",
                    fallback: "You may close this dialog, the transaction for approval has already been submitted."))
            }
            return
        }
        if attempt > 2 {
            await MainActor.run {
                self.setStatus(L.lang("swap-approval-status-minute",
                    fallback: "This can take up to a minute..."))
            }
        }
        try await Task.sleep(nanoseconds: Self.approvalPollIntervalNs)
        var payload = DexPayloads.base()
        payload["fromTokenValue"] = fromPicker.tokenValue()
        payload["fromDecimals"] = fromPicker.decimals()
        payload["requiredAmount"] = text(amountInField)
        payload["ownerAddress"] = walletAddress
        do {
            let json = try await JsBridge.shared.dexCallAsync(
                method: "swapCheckAllowance", payload: payload)
            let data = try DexBridgeResult.unwrapData(json)
            let sufficient = (data["sufficient"] as? Bool) ?? false
            if sufficient {
                await MainActor.run {
                    self.setStatus(L.lang("swap-approval-completed",
                        fallback: "Token approval completed. You can continue with Swap."))
                }
                try await estimateAndSubmitSwap(priv: priv, pub: pub)
            } else {
                try await pollAllowance(priv: priv, pub: pub, attempt: attempt + 1)
            }
        } catch {
            try await pollAllowance(priv: priv, pub: pub, attempt: attempt + 1)
        }
    }

    private func estimateAndSubmitSwap(priv: Data, pub: Data) async throws {
        await MainActor.run {
            self.setStatus(Localization.shared.getSubmittingTransactionByLangValues())
        }
        var estimate = DexPayloads.base()
        putSwapArgs(&estimate)
        estimate["recipientAddress"] = walletAddress
        var gasLimit: Int64 = 300_000
        do {
            let estJson = try await JsBridge.shared.dexCallAsync(
                method: "swapEstimateGas", payload: estimate)
            gasLimit = DexBridgeResult.parseGas(estJson, fallback: 300_000)
        } catch {
            gasLimit = 300_000
        }
        var keyed = DexPayloads.withKeys(privKey: priv, pubKey: pub)
        putSwapArgs(&keyed.payload)
        keyed.payload["recipientAddress"] = walletAddress
        keyed.payload["gasLimit"] = Int(gasLimit)
        let json = try await JsBridge.shared.dexCallAsync(
            method: "swapSubmitSwap", payload: keyed.payload,
            privKey: keyed.privKey, pubKey: keyed.pubKey)
        let data = try DexBridgeResult.unwrapData(json)
        let txHash = (data["txHash"] as? String) ?? ""
        await MainActor.run {
            self.flowInFlight = false
            self.setBusy(false)
            self.clearStatus()
            self.lastQuotedAmountOut = nil
            self.amountOutLabel.text = "-"
            let L = Localization.shared
            let dlg = MessageInformationDialogViewController(
                title: L.lang("swap", fallback: "Swap"),
                message: L.lang("swap-succeeded",
                    fallback: "Swap transaction succeeded.") + "\n\n" + txHash)
            self.present(dlg, animated: true)
        }
    }

    private func putSwapArgs(_ payload: inout [String: Any]) {
        payload["fromTokenValue"] = fromPicker.tokenValue()
        payload["toTokenValue"] = toPicker.tokenValue()
        payload["fromDecimals"] = fromPicker.decimals()
        payload["toDecimals"] = toPicker.decimals()
        payload["amountIn"] = text(amountInField)
        payload["lastChanged"] = "from"
        payload["slippagePercent"] = slippagePercent()
    }

    // MARK: - Helpers

    private func validateInputs(_ amountIn: String) -> Bool {
        let L = Localization.shared
        if fromPicker.tokenValue().caseInsensitiveCompare(toPicker.tokenValue()) == .orderedSame {
            DexScreenChrome.presentError(from: self, message: L.err(
                "identicalTokens", fallback: "From and To tokens must differ."))
            return false
        }
        if amountIn.isEmpty || amountIn.range(of: #"^\d*\.?\d+$"#, options: .regularExpression) == nil
            || (Double(amountIn) ?? 0) <= 0 {
            DexScreenChrome.presentError(from: self, message: L.err(
                "invalidQuantity", fallback: "Enter a valid quantity."))
            return false
        }
        return true
    }

    private func slippagePercent() -> Double {
        let v = Double(text(slippageField)) ?? 1
        return max(0, min(100, v))
    }

    private func minOutForDisplay() -> String {
        guard let quoted = lastQuotedAmountOut,
        let out = Decimal(string: quoted) else {
            return lastQuotedAmountOut ?? "-"
        }
        let pct = Decimal(100 - Int(slippagePercent())) / 100
        let minOut = out * pct
        var result = minOut
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 18, .plain)
        return "\(rounded)"
    }

    private func text(_ f: UITextField) -> String {
        f.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        quoteButton.isEnabled = !busy
        swapButton.isEnabled = !busy
    }

    private func setStatus(_ message: String) {
        statusLabel.text = message
        statusLabel.isHidden = false
    }

    private func clearStatus() {
        statusLabel.isHidden = true
    }

    private func failFlow(_ error: String?) {
        flowInFlight = false
        setBusy(false)
        clearStatus()
        if let error, !error.isEmpty {
            DexScreenChrome.presentError(from: self, message: error)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
